function Sync-FGCSVResourceDetail {
    <#
    .SYNOPSIS
    Enriches existing Resources from Omada Identity Permission-full-details.csv.

    .DESCRIPTION
    Loads rich permission metadata from an Omada Identity Permission-full-details.csv export
    and merges it into the existing Resources table. This function enriches resources that were
    previously loaded by Sync-FGCSVResource (from ResourceSystem.csv) with additional fields
    like descriptions, role categories, and role type classifications.

    Resources not already in the table will be inserted as new rows (Permission-full-details.csv
    may contain resources not present in ResourceSystem.csv).

    CSV columns mapped:
    - _UID -> id (GUID)
    - _DISPLAYNAME -> displayName
    - SYSTEMREF_VALUE -> systemId (via $Global:FGCSVSystemLookup)
    - ROLECATEGORY_ENGLISH -> resourceType (if not already set)
    - RESOURCESTATUS_ENGLISH -> enabled ('Active' = true)
    - DESCRIPTION -> description
    - NAME, ROLEID, ROLETYPEREF_VALUE, ROLEFOLDER_VALUE, VALIDFROM, VALIDTO,
      ODWBUSIKEY, Resource_AT, Rolefolder_AT -> extendedAttributes JSON

    .PARAMETER Path
    Path to the Permission-full-details.csv file (semicolon-delimited, UTF-8).

    .EXAMPLE
    Sync-FGCSVResourceDetail -Path "C:\Exports\Permission-full-details.csv"

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - $Global:FGCSVSystemLookup to be populated (run Sync-FGCSVSystem first)
    - Resources table to exist (run Initialize-FGSystemTables or Sync-FGCSVResource first)
    - Run AFTER Sync-FGCSVResource to enrich existing rows
    #>

    [CmdletBinding()]
    [Alias("Sync-CSVResourceDetail")]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $TableName = "Resources"

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
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Loading resource details from CSV: $Path" -ForegroundColor Cyan
    $csvRows = Import-Csv -Path $Path -Delimiter ';' -Encoding UTF8

    if (-not $csvRows -or $csvRows.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No rows found in CSV file."
        $syncStatus = "Success"
        $syncRecordCount = 0
        return
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Loaded $($csvRows.Count) resource detail(s) from CSV" -ForegroundColor Green

    # Ensure Resources table exists with correct schema (including description)
    $resourceColumns = @{
        'id'                 = 'UNIQUEIDENTIFIER'
        'systemId'           = 'INT'
        'displayName'        = 'NVARCHAR(500)'
        'description'        = 'NVARCHAR(MAX)'
        'resourceType'       = 'NVARCHAR(100)'
        'enabled'            = 'BIT'
        'createdDateTime'    = 'DATETIME2'
        'extendedAttributes' = 'NVARCHAR(MAX)'
    }

    $tableReady = Initialize-FGSyncTable -TableName $TableName -Columns $resourceColumns -PrimaryKey 'id' -RecreateTable:$false
    if ($tableReady -eq $false) { return }

    # Build DataTable
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Preparing resource detail data..." -ForegroundColor Cyan

    $attributes = @('id', 'systemId', 'displayName', 'description', 'resourceType', 'enabled', 'extendedAttributes')

    $unmappedSystems = @{}
    $skippedCount = 0

    $valueResolvers = @{
        'id' = {
            param($obj)
            $uid = $obj._UID.Trim().Trim('"')
            if ($uid -ne '') {
                try { [guid]$uid }
                catch { $null }
            }
            else { $null }
        }
        'systemId' = {
            param($obj)
            $sysName = $obj.SYSTEMREF_VALUE.Trim().Trim('"')
            if ($Global:FGCSVSystemLookup -and $sysName -and $Global:FGCSVSystemLookup.ContainsKey($sysName)) {
                $Global:FGCSVSystemLookup[$sysName]
            }
            else {
                if ($sysName -and -not $unmappedSystems.ContainsKey($sysName)) {
                    $unmappedSystems[$sysName] = $true
                }
                $null
            }
        }
        'displayName' = {
            param($obj)
            $obj._DISPLAYNAME.Trim().Trim('"')
        }
        'description' = {
            param($obj)
            $desc = $obj.DESCRIPTION.Trim().Trim('"')
            if ($desc -ne '') { $desc } else { $null }
        }
        'resourceType' = {
            param($obj)
            # ROLETYPEREF_VALUE = "Business Role" is the definitive indicator for business roles
            $roleType = $obj.ROLETYPEREF_VALUE.Trim().Trim('"')
            if ($roleType -eq 'Business Role') { return 'BusinessRole' }
            $cat = $obj.ROLECATEGORY_ENGLISH.Trim().Trim('"')
            if ($cat -eq 'Business Role') { return 'BusinessRole' }
            if ($cat -ne '') { $cat } else { 'Unknown' }
        }
        'enabled' = {
            param($obj)
            $status = $obj.RESOURCESTATUS_ENGLISH.Trim().Trim('"')
            $status -eq 'Active'
        }
        'extendedAttributes' = {
            param($obj)
            $extended = @{}
            $name = $obj.NAME.Trim().Trim('"')
            if ($name -ne '') { $extended['NAME'] = $name }
            $roleId = $obj.ROLEID.Trim().Trim('"')
            if ($roleId -ne '') { $extended['ROLEID'] = $roleId }
            $roleType = $obj.ROLETYPEREF_VALUE.Trim().Trim('"')
            if ($roleType -ne '') { $extended['ROLETYPEREF_VALUE'] = $roleType }
            $roleFolder = $obj.ROLEFOLDER_VALUE.Trim().Trim('"')
            if ($roleFolder -ne '') { $extended['ROLEFOLDER_VALUE'] = $roleFolder }
            $validFrom = $obj.VALIDFROM.Trim().Trim('"')
            if ($validFrom -ne '') { $extended['VALIDFROM'] = $validFrom }
            $validTo = $obj.VALIDTO.Trim().Trim('"')
            if ($validTo -ne '') { $extended['VALIDTO'] = $validTo }
            $odwKey = $obj.ODWBUSIKEY.Trim().Trim('"')
            if ($odwKey -ne '') { $extended['ODWBUSIKEY'] = $odwKey }
            $resAt = $obj.Resource_AT.Trim().Trim('"')
            if ($resAt -ne '') { $extended['Resource_AT'] = $resAt }
            $rfAt = $obj.Rolefolder_AT.Trim().Trim('"')
            if ($rfAt -ne '') { $extended['Rolefolder_AT'] = $rfAt }
            $objGuid = $obj.OBJECTGUID.Trim().Trim('"')
            if ($objGuid -ne '') { $extended['OBJECTGUID'] = $objGuid }

            if ($extended.Count -gt 0) {
                $extended | ConvertTo-Json -Depth 10 -Compress
            }
            else {
                $null
            }
        }
    }

    # Filter out rows with invalid/empty GUIDs and deduplicate by _UID
    $validRows = @()
    $seenUids = @{}
    foreach ($row in $csvRows) {
        $uid = $row._UID.Trim().Trim('"')
        if ([string]::IsNullOrWhiteSpace($uid)) { $skippedCount++; continue }
        try { [guid]$uid | Out-Null }
        catch { $skippedCount++; continue }
        # Deduplicate: keep first row per _UID
        if ($seenUids.ContainsKey($uid)) { $skippedCount++; continue }
        $seenUids[$uid] = $true
        $validRows += $row
    }

    if ($skippedCount -gt 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] Skipped $skippedCount rows with empty or invalid _UID"
    }

    if ($validRows.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No valid resource details to sync after filtering."
        $syncStatus = "Success"
        return
    }

    $dataTable = New-FGDataTableFromGraphObjects -GraphObjects $validRows -Columns $resourceColumns -Attributes $attributes -ValueResolvers $valueResolvers

    # Warn about unmapped systems
    if ($unmappedSystems.Count -gt 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] $($unmappedSystems.Count) system name(s) could not be mapped: $($unmappedSystems.Keys | Select-Object -First 10 | ForEach-Object { $_ }) $(if ($unmappedSystems.Count -gt 10) { '...' })"
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Prepared $($dataTable.Rows.Count) resource details for sync" -ForegroundColor Green

    # Sync to SQL — merge only, no deletion (this enriches existing rows)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Enriching resources in SQL Server..." -ForegroundColor Cyan

    $syncResult = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        $transaction = $connection.BeginTransaction()

        try {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($dataTable.Rows.Count) resource details..." -ForegroundColor Cyan

            $mergeResult = Invoke-FGSQLBulkMerge `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName $TableName `
                -DataTable $dataTable `
                -KeyColumns @('id')

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Resource details: $($mergeResult.Inserted) inserted, $($mergeResult.Updated) updated" -ForegroundColor Green

            # No deletion — this function only enriches
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

    $syncRecordCount = $validRows.Count

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "CSV Resource Detail Sync Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Total Details:     $($validRows.Count)" -ForegroundColor White
    Write-Host "  Inserted (new):  $($syncResult.Inserted)" -ForegroundColor White
    Write-Host "  Updated:         $($syncResult.Updated)" -ForegroundColor White
    if ($skippedCount -gt 0) {
        Write-Host "  Skipped:         $skippedCount" -ForegroundColor Yellow
    }
    if ($unmappedSystems.Count -gt 0) {
        Write-Host "  Unmapped Systems: $($unmappedSystems.Count)" -ForegroundColor Yellow
    }
    Write-Host "========================================`n" -ForegroundColor Green

    $syncStatus = "Success"

    return @{
        TotalRecords = $validRows.Count
        Inserted = $syncResult.Inserted
        Updated = $syncResult.Updated
        Skipped = $skippedCount
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
        Write-FGSyncLog -SyncType "CSVResourceDetails" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName $TableName
    }
}
