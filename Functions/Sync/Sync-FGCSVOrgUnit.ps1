function Sync-FGCSVOrgUnit {
    <#
    .SYNOPSIS
    Syncs Omada Identity Orgunits.csv data to the Contexts table.

    .DESCRIPTION
    Loads organizational units from an Omada Identity CSV export and syncs them to the Contexts table
    with contextType='OrgUnit'. Uses deterministic GUIDs generated from OU_KEY values.

    Populates $Global:FGCSVOrgUnitLookup (OU_KEY -> GUID) for downstream use by Sync-FGCSVIdentity
    when resolving Employment.csv org unit references.

    CSV columns mapped:
    - OU_KEY -> id (deterministic GUID from "OrgUnit|{OU_KEY}")
    - OU_Name -> displayName
    - Parent_OU_Key -> parentContextId (deterministic GUID, null for root)
    - OU_Description -> department
    - Managers_Key -> extendedAttributes JSON
    - contextType hardcoded to 'OrgUnit'
    - sourceType hardcoded to 'Synced'

    .PARAMETER Path
    Path to the Orgunits.csv file (semicolon-delimited, UTF-8).

    .EXAMPLE
    Sync-FGCSVOrgUnit -Path "C:\Exports\Orgunits.csv"

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Contexts table to exist (run Initialize-FGSystemTables first)
    #>

    [CmdletBinding()]
    [Alias("Sync-CSVOrgUnit")]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $TableName = "Contexts"

    # Deterministic GUID helper
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

    try {

    # Import CSV
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Loading org units from CSV: $Path" -ForegroundColor Cyan
    $csvRows = Import-Csv -Path $Path -Delimiter ';' -Encoding UTF8

    if (-not $csvRows -or $csvRows.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No rows found in CSV file."
        $syncStatus = "Success"
        $syncRecordCount = 0
        return
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Loaded $($csvRows.Count) org unit(s) from CSV" -ForegroundColor Green

    # Build global lookup: OU_KEY -> deterministic GUID
    $Global:FGCSVOrgUnitLookup = @{}
    foreach ($row in $csvRows) {
        $ouKey = $row.OU_KEY.Trim().Trim('"')
        if ($ouKey -ne '') {
            $Global:FGCSVOrgUnitLookup[$ouKey] = (New-DeterministicGuid -InputString "OrgUnit|$ouKey")
        }
    }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Built OrgUnit lookup: $($Global:FGCSVOrgUnitLookup.Count) entries" -ForegroundColor Green

    # Ensure Contexts table exists with correct schema
    $contextColumns = @{
        'id'                 = 'UNIQUEIDENTIFIER'
        'systemId'           = 'INT'
        'displayName'        = 'NVARCHAR(500)'
        'contextType'        = 'NVARCHAR(50)'
        'parentContextId'    = 'UNIQUEIDENTIFIER'
        'managerId'          = 'UNIQUEIDENTIFIER'
        'managerIdentityId'  = 'UNIQUEIDENTIFIER'
        'department'         = 'NVARCHAR(255)'
        'division'           = 'NVARCHAR(255)'
        'costCenter'         = 'NVARCHAR(255)'
        'officeLocation'     = 'NVARCHAR(255)'
        'memberCount'        = 'INT'
        'totalMemberCount'   = 'INT'
        'sourceType'         = 'NVARCHAR(50)'
        'lastCalculatedAt'   = 'DATETIME2'
        'extendedAttributes' = 'NVARCHAR(MAX)'
    }

    $tableReady = Initialize-FGSyncTable -TableName $TableName -Columns $contextColumns -PrimaryKey 'id' -RecreateTable:$false
    if ($tableReady -eq $false) { return }

    # Build DataTable
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Preparing org unit data..." -ForegroundColor Cyan

    $attributes = @('id', 'displayName', 'contextType', 'parentContextId', 'department', 'sourceType', 'extendedAttributes')

    $valueResolvers = @{
        'id' = {
            param($obj)
            $ouKey = $obj.OU_KEY.Trim().Trim('"')
            New-DeterministicGuid -InputString "OrgUnit|$ouKey"
        }
        'displayName' = {
            param($obj)
            $name = $obj.OU_Name.Trim().Trim('"')
            if ($name -ne '') { $name } else { $obj.OU_KEY.Trim().Trim('"') }
        }
        'contextType' = {
            param($obj)
            'OrgUnit'
        }
        'parentContextId' = {
            param($obj)
            $parentKey = $obj.Parent_OU_Key.Trim().Trim('"')
            if ($parentKey -ne '') {
                New-DeterministicGuid -InputString "OrgUnit|$parentKey"
            }
            else {
                $null
            }
        }
        'department' = {
            param($obj)
            $desc = $obj.OU_Description.Trim().Trim('"')
            if ($desc -ne '') { $desc } else { $null }
        }
        'sourceType' = {
            param($obj)
            'Synced'
        }
        'extendedAttributes' = {
            param($obj)
            $extended = @{}
            $ouKey = $obj.OU_KEY.Trim().Trim('"')
            if ($ouKey -ne '') { $extended['OU_KEY'] = $ouKey }
            $mgrKey = $obj.Managers_Key.Trim().Trim('"')
            if ($mgrKey -ne '') { $extended['Managers_Key'] = $mgrKey }
            if ($extended.Count -gt 0) {
                $extended | ConvertTo-Json -Depth 10 -Compress
            }
            else {
                $null
            }
        }
    }

    $dataTable = New-FGDataTableFromGraphObjects -GraphObjects $csvRows -Columns $contextColumns -Attributes $attributes -ValueResolvers $valueResolvers

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Prepared $($dataTable.Rows.Count) org units for sync" -ForegroundColor Green

    # Sync to SQL
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing org units to SQL Server..." -ForegroundColor Cyan

    $syncResult = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        $transaction = $connection.BeginTransaction()

        try {
            # Bulk merge org units
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($dataTable.Rows.Count) org units..." -ForegroundColor Cyan

            $mergeResult = Invoke-FGSQLBulkMerge `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName $TableName `
                -DataTable $dataTable `
                -KeyColumns @('id')

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Org units: $($mergeResult.Inserted) inserted, $($mergeResult.Updated) updated" -ForegroundColor Green

            # Scoped deletion: only delete OrgUnit rows with sourceType='Synced' that are not in this batch
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking for deleted org units (scoped to synced OrgUnits)..." -ForegroundColor Cyan

            $deleteCmd = $connection.CreateCommand()
            $deleteCmd.Transaction = $transaction
            $deleteCmd.CommandTimeout = 120
            $deleteCmd.CommandText = "CREATE TABLE #CSVOrgUnitIds (id UNIQUEIDENTIFIER PRIMARY KEY)"
            $deleteCmd.ExecuteNonQuery() | Out-Null
            $idTable = New-Object System.Data.DataTable
            [void]$idTable.Columns.Add("id", [System.Guid])
            foreach ($row in $dataTable.Rows) { [void]$idTable.Rows.Add($row["id"]) }
            $bc = New-Object System.Data.SqlClient.SqlBulkCopy($connection, [System.Data.SqlClient.SqlBulkCopyOptions]::Default, $transaction)
            $bc.DestinationTableName = "#CSVOrgUnitIds"
            $bc.WriteToServer($idTable)
            $bc.Close()
            $deleteCmd.CommandText = @"
DELETE c FROM dbo.$TableName c
LEFT JOIN #CSVOrgUnitIds s ON c.id = s.id
WHERE c.contextType = 'OrgUnit' AND c.sourceType = 'Synced' AND s.id IS NULL AND c.ValidTo = '9999-12-31 23:59:59.9999999'
"@
            $deletedCount = $deleteCmd.ExecuteNonQuery()
            $deleteCmd.CommandText = "DROP TABLE #CSVOrgUnitIds"
            $deleteCmd.ExecuteNonQuery() | Out-Null
            $deleteCmd.Dispose()
            $idTable.Dispose()

            if ($deletedCount -gt 0) {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedCount org units that no longer exist in CSV source" -ForegroundColor Yellow
            }
            else {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] No deleted org units found" -ForegroundColor Green
            }

            # Commit transaction
            $transaction.Commit()
            $transaction.Dispose()

            return @{
                Inserted = $mergeResult.Inserted
                Updated = $mergeResult.Updated
                DeletedCount = $deletedCount
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
    Write-Host "CSV OrgUnit Sync Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Total Org Units:   $($csvRows.Count)" -ForegroundColor White
    Write-Host "  Inserted:        $($syncResult.Inserted)" -ForegroundColor White
    Write-Host "  Updated:         $($syncResult.Updated)" -ForegroundColor White
    Write-Host "  Deleted:         $($syncResult.DeletedCount)" -ForegroundColor White
    Write-Host "========================================`n" -ForegroundColor Green

    $syncStatus = "Success"

    return @{
        TotalRecords = $csvRows.Count
        Inserted = $syncResult.Inserted
        Updated = $syncResult.Updated
        DeletedCount = $syncResult.DeletedCount
    }

    } # End try
    catch {
        $syncErrorMessage = $_.Exception.Message
        $syncStatus = "Failed"
        throw
    }
    finally {
        # Write sync log entry
        Write-FGSyncLog -SyncType "CSVOrgUnits" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName $TableName
    }
}
