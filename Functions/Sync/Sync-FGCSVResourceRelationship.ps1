function Sync-FGCSVResourceRelationship {
    <#
    .SYNOPSIS
    Syncs Omada Identity Permission-Nesting.csv data to the ResourceRelationships table.

    .DESCRIPTION
    Loads permission parent-child nesting relationships from an Omada Identity CSV export and
    syncs them to the ResourceRelationships table with relationshipType='Contains'.

    CSV columns mapped:
    - ParentUID -> parentResourceId (direct GUID)
    - ChildUID -> childResourceId (direct GUID)
    - relationshipType hardcoded to 'Contains'
    - Application_Name -> roleName
    - Child_Application_Name -> roleOriginSystem
    - Permission_Name, Parent_AT, Child_Permission_Name, Child_AT -> extendedAttributes JSON

    .PARAMETER Path
    Path to the Permission-Nesting.csv file (semicolon-delimited, UTF-8).

    .EXAMPLE
    Sync-FGCSVResourceRelationship -Path "C:\Exports\Permission-Nesting.csv"

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Resources table to be populated (run Sync-FGCSVResource first)
    - ResourceRelationships table to exist (run Initialize-FGSystemTables first)
    #>

    [CmdletBinding()]
    [Alias("Sync-CSVResourceRelationship")]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $TableName = "ResourceRelationships"

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
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Loading resource relationships from CSV: $Path" -ForegroundColor Cyan
    $csvRows = Import-Csv -Path $Path -Delimiter ';' -Encoding UTF8

    if (-not $csvRows -or $csvRows.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No rows found in CSV file."
        $syncStatus = "Success"
        $syncRecordCount = 0
        return
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Loaded $($csvRows.Count) relationship(s) from CSV" -ForegroundColor Green

    # Ensure ResourceRelationships table exists
    $relationshipColumns = @{
        'parentResourceId'   = 'UNIQUEIDENTIFIER'
        'childResourceId'    = 'UNIQUEIDENTIFIER'
        'relationshipType'   = 'NVARCHAR(50)'
        'roleName'           = 'NVARCHAR(255)'
        'roleOriginSystem'   = 'NVARCHAR(100)'
        'extendedAttributes' = 'NVARCHAR(MAX)'
    }

    $tableReady = Initialize-FGSyncTable -TableName $TableName -Columns $relationshipColumns -CompositePrimaryKey @('parentResourceId', 'childResourceId', 'relationshipType')
    if ($tableReady -eq $false) { return }

    # Build objects, skipping rows with empty GUIDs
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Preparing relationship data..." -ForegroundColor Cyan

    $relationshipObjects = @()
    $skippedCount = 0
    $deduplicationSet = @{}

    foreach ($row in $csvRows) {
        $parentUid = $row.ParentUID.Trim().Trim('"')
        $childUid = $row.ChildUID.Trim().Trim('"')

        # Skip rows with empty parent or child UIDs
        if ([string]::IsNullOrWhiteSpace($parentUid) -or [string]::IsNullOrWhiteSpace($childUid)) {
            $skippedCount++
            continue
        }

        # Validate GUIDs
        $parentGuid = $null
        $childGuid = $null
        try {
            $parentGuid = [guid]$parentUid
            $childGuid = [guid]$childUid
        }
        catch {
            $skippedCount++
            continue
        }

        # Deduplicate on composite key
        $dedupeKey = "$parentGuid|$childGuid|Contains"
        if ($deduplicationSet.ContainsKey($dedupeKey)) { continue }
        $deduplicationSet[$dedupeKey] = $true

        # Build extended attributes
        $extended = @{}
        $permName = $row.Permission_Name.Trim().Trim('"')
        if ($permName -ne '') { $extended['Permission_Name'] = $permName }
        $parentAt = $row.Parent_AT.Trim().Trim('"')
        if ($parentAt -ne '') { $extended['Parent_AT'] = $parentAt }
        $childPermName = $row.Child_Permission_Name.Trim().Trim('"')
        if ($childPermName -ne '') { $extended['Child_Permission_Name'] = $childPermName }
        $childAt = $row.Child_AT.Trim().Trim('"')
        if ($childAt -ne '') { $extended['Child_AT'] = $childAt }

        $extendedJson = $null
        if ($extended.Count -gt 0) {
            $extendedJson = $extended | ConvertTo-Json -Depth 10 -Compress
        }

        $relationshipObjects += [PSCustomObject]@{
            parentResourceId = $parentGuid
            childResourceId  = $childGuid
            relationshipType = 'Contains'
            roleName         = $row.Application_Name.Trim().Trim('"')
            roleOriginSystem = $row.Child_Application_Name.Trim().Trim('"')
            extendedAttributes = $extendedJson
        }
    }

    if ($skippedCount -gt 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] Skipped $skippedCount rows with empty or invalid GUIDs"
    }

    if ($relationshipObjects.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No valid relationships to sync after filtering."
        $syncStatus = "Success"
        return
    }

    $attributes = @('parentResourceId', 'childResourceId', 'relationshipType', 'roleName', 'roleOriginSystem', 'extendedAttributes')
    $dataTable = New-FGDataTableFromGraphObjects -GraphObjects $relationshipObjects -Columns $relationshipColumns -Attributes $attributes

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Prepared $($dataTable.Rows.Count) relationships for sync" -ForegroundColor Green

    # Sync to SQL
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing resource relationships to SQL Server..." -ForegroundColor Cyan

    $syncResult = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        $transaction = $connection.BeginTransaction()

        try {
            # Bulk merge relationships
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($dataTable.Rows.Count) relationships..." -ForegroundColor Cyan

            $mergeResult = Invoke-FGSQLBulkMerge `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName $TableName `
                -DataTable $dataTable `
                -KeyColumns @('parentResourceId', 'childResourceId', 'relationshipType')

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Relationships: $($mergeResult.Inserted) inserted, $($mergeResult.Updated) updated" -ForegroundColor Green

            # Scoped deletion: only delete CSV-sourced Contains relationships
            # Protect Entra-sourced relationships and BusinessRole relationships
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking for deleted relationships (scoped to CSV systems)..." -ForegroundColor Cyan

            $csvSystemIds = @()
            if ($Global:FGCSVSystemLookup -and $Global:FGCSVSystemLookup.Count -gt 0) {
                $csvSystemIds = @($Global:FGCSVSystemLookup.Values | Sort-Object -Unique)
            }

            $deletedCount = 0
            if ($csvSystemIds.Count -eq 0) {
                Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No CSV system IDs found. Skipping delete step."
            }
            else {
                $deleteCmd = $connection.CreateCommand()
                $deleteCmd.Transaction = $transaction
                $deleteCmd.CommandTimeout = 120
                $deleteCmd.CommandText = "CREATE TABLE #CSVRelSourceIds (parentResourceId UNIQUEIDENTIFIER, childResourceId UNIQUEIDENTIFIER, relationshipType NVARCHAR(50), PRIMARY KEY (parentResourceId, childResourceId, relationshipType))"
                $deleteCmd.ExecuteNonQuery() | Out-Null
                $idTable = New-Object System.Data.DataTable
                [void]$idTable.Columns.Add("parentResourceId", [System.Guid])
                [void]$idTable.Columns.Add("childResourceId", [System.Guid])
                [void]$idTable.Columns.Add("relationshipType", [string])
                foreach ($row in $dataTable.Rows) {
                    [void]$idTable.Rows.Add($row["parentResourceId"], $row["childResourceId"], $row["relationshipType"])
                }
                $bc = New-Object System.Data.SqlClient.SqlBulkCopy($connection, [System.Data.SqlClient.SqlBulkCopyOptions]::Default, $transaction)
                $bc.DestinationTableName = "#CSVRelSourceIds"
                $bc.WriteToServer($idTable)
                $bc.Close()

                # Only delete Contains relationships where parent resource belongs to a CSV system
                $systemIdList = ($csvSystemIds | ForEach-Object { $_.ToString() }) -join ','
                $deleteCmd.CommandText = @"
DELETE rr FROM dbo.$TableName rr
INNER JOIN dbo.Resources r ON rr.parentResourceId = r.id AND r.ValidTo = '9999-12-31 23:59:59.9999999'
LEFT JOIN #CSVRelSourceIds s ON rr.parentResourceId = s.parentResourceId AND rr.childResourceId = s.childResourceId AND rr.relationshipType = s.relationshipType
WHERE rr.relationshipType = 'Contains'
  AND r.systemId IN ($systemIdList)
  AND r.resourceType <> 'BusinessRole'
  AND s.parentResourceId IS NULL
  AND rr.ValidTo = '9999-12-31 23:59:59.9999999'
"@
                $deletedCount = $deleteCmd.ExecuteNonQuery()
                $deleteCmd.CommandText = "DROP TABLE #CSVRelSourceIds"
                $deleteCmd.ExecuteNonQuery() | Out-Null
                $deleteCmd.Dispose()
                $idTable.Dispose()
            }

            if ($deletedCount -gt 0) {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedCount relationships that no longer exist in CSV source" -ForegroundColor Yellow
            }
            else {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] No deleted relationships found" -ForegroundColor Green
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

    $syncRecordCount = $relationshipObjects.Count

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "CSV Resource Relationship Sync Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Total Relationships: $($relationshipObjects.Count)" -ForegroundColor White
    Write-Host "  Inserted:          $($syncResult.Inserted)" -ForegroundColor White
    Write-Host "  Updated:           $($syncResult.Updated)" -ForegroundColor White
    Write-Host "  Deleted:           $($syncResult.DeletedCount)" -ForegroundColor White
    if ($skippedCount -gt 0) {
        Write-Host "  Skipped:           $skippedCount" -ForegroundColor Yellow
    }
    Write-Host "========================================`n" -ForegroundColor Green

    $syncStatus = "Success"

    return @{
        TotalRecords = $relationshipObjects.Count
        Inserted = $syncResult.Inserted
        Updated = $syncResult.Updated
        DeletedCount = $syncResult.DeletedCount
        Skipped = $skippedCount
    }

    } # End try
    catch {
        $syncErrorMessage = $_.Exception.Message
        $syncStatus = "Failed"
        throw
    }
    finally {
        # Write sync log entry
        Write-FGSyncLog -SyncType "CSVResourceRelationships" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName $TableName
    }
}
