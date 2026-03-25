function Sync-FGCSVResource {
    <#
    .SYNOPSIS
    Syncs Omada Identity ResourceSystem.csv data to the Resources table.

    .DESCRIPTION
    Loads resources from an Omada Identity CSV export and syncs them to the Resources table
    in the universal data model. Uses bulk merge for high-performance sync.

    The function requires $Global:FGCSVSystemLookup to be populated (by Sync-FGCSVSystem)
    to resolve system names to system IDs.

    CSV columns mapped:
    - Id -> id (GUID, used directly)
    - SystemName -> systemId (via $Global:FGCSVSystemLookup)
    - DisplayName -> displayName
    - ResourceType -> resourceType
    - CreatedTime -> createdDateTime
    - Deleted -> enabled (inverted: Deleted=1 means enabled=false)
    - TechName, ResourcePoolId, ResourceTypeId, JoinKey, SkipProvisioning,
      ProvTypeAccounts, ProvTypeAssignments, ODWBusiKey, AssignmentsChangedTime -> extendedAttributes JSON

    .PARAMETER Path
    Path to the ResourceSystem.csv file (semicolon-delimited, UTF-8).

    .PARAMETER TableName
    Target SQL table name. Default: 'Resources'

    .EXAMPLE
    Sync-FGCSVResource -Path "C:\Exports\ResourceSystem.csv"

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - $Global:FGCSVSystemLookup to be populated (run Sync-FGCSVSystem first)
    - Resources table to exist (run Initialize-FGSystemTables first)
    #>

    [CmdletBinding()]
    [Alias("Sync-CSVResource")]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [string]$TableName = "Resources"
    )

    # Deterministic GUID helper for rows without a native GUID
    function New-DeterministicGuid {
        param([string]$InputString)
        if ([string]::IsNullOrEmpty($InputString)) { throw "InputString must not be null or empty" }
        $md5 = [System.Security.Cryptography.MD5]::Create()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputString)
        $hash = $md5.ComputeHash($bytes)
        $md5.Dispose()
        $hex = ($hash | ForEach-Object { $_.ToString('x2') }) -join ''
        return [guid]"$($hex.Substring(0,8))-$($hex.Substring(8,4))-$($hex.Substring(12,4))-$($hex.Substring(16,4))-$($hex.Substring(20,12))"
    }

    # Track sync timing for logging
    $syncStartTime = Get-Date
    $syncStatus = "Failed"
    $syncErrorMessage = $null
    $syncRecordCount = 0

    # Check SQL connection
    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    # Validate file exists
    if (-not (Test-Path $Path)) {
        throw "CSV file not found: $Path"
    }

    # Validate system lookup is available
    if (-not $Global:FGCSVSystemLookup -or $Global:FGCSVSystemLookup.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] System lookup is empty. System IDs will not be resolved. Run Sync-FGCSVSystem first."
    }

    try {

    # Import CSV
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Loading resources from CSV: $Path" -ForegroundColor Cyan
    $csvRows = Import-Csv -Path $Path -Delimiter ';' -Encoding UTF8

    if (-not $csvRows -or $csvRows.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No rows found in CSV file."
        $syncStatus = "Success"
        $syncRecordCount = 0
        return
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Loaded $($csvRows.Count) resource(s) from CSV" -ForegroundColor Green

    # Ensure Resources table exists with correct schema
    $resourceColumns = @{
        'id'                 = 'UNIQUEIDENTIFIER'
        'systemId'           = 'INT'
        'displayName'        = 'NVARCHAR(500)'
        'resourceType'       = 'NVARCHAR(100)'
        'enabled'            = 'BIT'
        'createdDateTime'    = 'DATETIME2'
        'extendedAttributes' = 'NVARCHAR(MAX)'
    }

    $tableReady = Initialize-FGSyncTable -TableName $TableName -Columns $resourceColumns -PrimaryKey 'id' -RecreateTable:$false
    if ($tableReady -eq $false) { return }

    # Build DataTable
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Preparing resource data..." -ForegroundColor Cyan

    $attributes = @('id', 'systemId', 'displayName', 'resourceType', 'enabled', 'createdDateTime', 'extendedAttributes')

    $unmappedSystems = @{}

    $valueResolvers = @{
        'id' = {
            param($obj)
            # Use the CSV Id column directly as GUID
            if ($obj.Id -and $obj.Id.Trim() -ne '') {
                try {
                    [guid]$obj.Id.Trim()
                }
                catch {
                    # If not a valid GUID, generate deterministic one
                    New-DeterministicGuid -InputString $obj.Id.Trim()
                }
            }
            else {
                # Fallback: generate from DisplayName + SystemName
                $key = "$($obj.DisplayName)|$($obj.SystemName)"
                New-DeterministicGuid -InputString $key
            }
        }
        'systemId' = {
            param($obj)
            if ($Global:FGCSVSystemLookup -and $obj.SystemName -and $Global:FGCSVSystemLookup.ContainsKey($obj.SystemName)) {
                $Global:FGCSVSystemLookup[$obj.SystemName]
            }
            else {
                if ($obj.SystemName -and -not $unmappedSystems.ContainsKey($obj.SystemName)) {
                    $unmappedSystems[$obj.SystemName] = $true
                }
                $null
            }
        }
        'displayName' = {
            param($obj)
            $obj.DisplayName
        }
        'resourceType' = {
            param($obj)
            if ($obj.ResourceType -and $obj.ResourceType.Trim() -ne '') { $obj.ResourceType.Trim() } else { 'Unknown' }
        }
        'enabled' = {
            param($obj)
            if ($obj.Deleted -eq '1') { $false } else { $true }
        }
        'createdDateTime' = {
            param($obj)
            if ($obj.CreatedTime -and $obj.CreatedTime.Trim() -ne '') {
                try { [datetime]$obj.CreatedTime.Trim() } catch { $null }
            }
            else { $null }
        }
        'extendedAttributes' = {
            param($obj)
            $extended = @{}
            if ($obj.TechName -and $obj.TechName.Trim() -ne '') { $extended['TechName'] = $obj.TechName.Trim() }
            if ($obj.ResourcePoolId -and $obj.ResourcePoolId.Trim() -ne '') { $extended['ResourcePoolId'] = $obj.ResourcePoolId.Trim() }
            if ($obj.ResourceTypeId -and $obj.ResourceTypeId.Trim() -ne '') { $extended['ResourceTypeId'] = $obj.ResourceTypeId.Trim() }
            if ($obj.JoinKey -and $obj.JoinKey.Trim() -ne '') { $extended['JoinKey'] = $obj.JoinKey.Trim() }
            if ($obj.SkipProvisioning -and $obj.SkipProvisioning.Trim() -ne '') { $extended['SkipProvisioning'] = $obj.SkipProvisioning.Trim() }
            if ($obj.ProvTypeAccounts -and $obj.ProvTypeAccounts.Trim() -ne '') { $extended['ProvTypeAccounts'] = $obj.ProvTypeAccounts.Trim() }
            if ($obj.ProvTypeAssignments -and $obj.ProvTypeAssignments.Trim() -ne '') { $extended['ProvTypeAssignments'] = $obj.ProvTypeAssignments.Trim() }
            if ($obj.ODWBusiKey -and $obj.ODWBusiKey.Trim() -ne '') { $extended['ODWBusiKey'] = $obj.ODWBusiKey.Trim() }
            if ($obj.AssignmentsChangedTime -and $obj.AssignmentsChangedTime.Trim() -ne '') { $extended['AssignmentsChangedTime'] = $obj.AssignmentsChangedTime.Trim() }

            if ($extended.Count -gt 0) {
                $extended | ConvertTo-Json -Depth 10 -Compress
            }
            else {
                $null
            }
        }
    }

    $dataTable = New-FGDataTableFromGraphObjects -GraphObjects $csvRows -Columns $resourceColumns -Attributes $attributes -ValueResolvers $valueResolvers

    # Warn about unmapped systems
    if ($unmappedSystems.Count -gt 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] $($unmappedSystems.Count) system name(s) could not be mapped to system IDs: $($unmappedSystems.Keys -join ', ')"
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Prepared $($dataTable.Rows.Count) resources for sync" -ForegroundColor Green

    # Sync to SQL
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing resources to SQL Server..." -ForegroundColor Cyan

    $syncResult = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        $transaction = $connection.BeginTransaction()

        try {
            # Bulk merge resources
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($dataTable.Rows.Count) resources..." -ForegroundColor Cyan

            $mergeResult = Invoke-FGSQLBulkMerge `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName $TableName `
                -DataTable $dataTable `
                -KeyColumns @('id')

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Resources: $($mergeResult.Inserted) inserted, $($mergeResult.Updated) updated" -ForegroundColor Green

            # Commit transaction
            $transaction.Commit()
            $transaction.Dispose()

            return @{
                Inserted = $mergeResult.Inserted
                Updated = $mergeResult.Updated
            }
        }
        catch {
            Write-Error "[$(Get-Date -Format 'HH:mm:ss')] Failed during sync: $_"
            if ($transaction) {
                $transaction.Rollback()
                $transaction.Dispose()
            }
            throw
        }
    }

    $syncRecordCount = $csvRows.Count

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "CSV Resource Sync Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Total Resources:   $($csvRows.Count)" -ForegroundColor White
    Write-Host "  Inserted:        $($syncResult.Inserted)" -ForegroundColor White
    Write-Host "  Updated:         $($syncResult.Updated)" -ForegroundColor White
    if ($unmappedSystems.Count -gt 0) {
        Write-Host "  Unmapped Systems: $($unmappedSystems.Count)" -ForegroundColor Yellow
    }
    Write-Host "========================================`n" -ForegroundColor Green

    $syncStatus = "Success"

    return @{
        TotalRecords = $csvRows.Count
        Inserted = $syncResult.Inserted
        Updated = $syncResult.Updated
        UnmappedSystems = $unmappedSystems.Count
    }

    } # End try
    catch {
        $syncErrorMessage = $_.Exception.Message
        $syncStatus = "Failed"
        throw
    }
    finally {
        # Write sync log entry
        Write-FGSyncLog -SyncType "CSVResources" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName $TableName
    }
}
