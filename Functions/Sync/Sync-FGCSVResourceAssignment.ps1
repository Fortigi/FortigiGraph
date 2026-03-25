function Sync-FGCSVResourceAssignment {
    <#
    .SYNOPSIS
    Syncs resource assignments from a semicolon-delimited CSV file (Account-Permission.csv) to the ResourceAssignments table.

    .DESCRIPTION
    Loads Account-Permission.csv and maps rows to the ResourceAssignments table in the universal resource model.
    Uses the global $FGCSVPrincipalLookup hashtable to resolve Employee_ID to principalId.
    Rows where the Employee_ID is not found in the lookup are skipped.
    Deduplicates on (resourceId, principalId, assignmentType) before MERGE.

    .PARAMETER Path
    Path to the Account-Permission.csv file (semicolon-delimited, quoted, UTF8).

    .EXAMPLE
    Sync-FGCSVResourceAssignment -Path ".\data\Account-Permission.csv"

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - $Global:FGCSVPrincipalLookup hashtable populated (Employee_ID -> principalId GUID)
    #>

    [CmdletBinding()]
    [Alias("Sync-CSVResourceAssignment")]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $TableName = "ResourceAssignments"

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

    # Check principal lookup
    if (-not $Global:FGCSVPrincipalLookup -or $Global:FGCSVPrincipalLookup.Count -eq 0) {
        throw "Global principal lookup is empty. Please populate `$Global:FGCSVPrincipalLookup before calling this function."
    }

    try {

    # Ensure ResourceAssignments table exists
    $raColumns = @{
        'resourceId'      = 'UNIQUEIDENTIFIER'
        'principalId'     = 'UNIQUEIDENTIFIER'
        'principalType'   = 'NVARCHAR(50)'
        'assignmentType'  = 'NVARCHAR(50)'
        'complianceState' = 'NVARCHAR(255)'
    }

    $tableReady = Initialize-FGSyncTable -TableName $TableName -Columns $raColumns -CompositePrimaryKey @('resourceId', 'principalId', 'assignmentType')
    if ($tableReady -eq $false) { return }

    # Load CSV
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Loading CSV from $Path..." -ForegroundColor Cyan

    if (-not (Test-Path $Path)) {
        throw "CSV file not found: $Path"
    }

    $csvData = Import-Csv -Path $Path -Delimiter ';' -Encoding UTF8
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Loaded $($csvData.Count) rows from CSV" -ForegroundColor Green

    if ($csvData.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No rows found in CSV."
        $syncStatus = "Success"
        $syncRecordCount = 0
        return
    }

    # Map CSV rows to ResourceAssignment objects, skipping rows without a matching principal
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Mapping CSV rows to ResourceAssignments..." -ForegroundColor Cyan

    $mappedRows = @()
    $skippedCount = 0

    foreach ($row in $csvData) {
        # Look up principalId from Employee_ID
        $principalId = $Global:FGCSVPrincipalLookup[$row.Employee_ID]
        if (-not $principalId) {
            $skippedCount++
            continue
        }

        $mappedRows += [PSCustomObject]@{
            resourceId      = [guid]$row.ResouceUID
            principalId     = $principalId
            principalType   = 'user'
            assignmentType  = 'Direct'
            complianceState = $row.ComplianceState
        }
    }

    if ($skippedCount -gt 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] Skipped $skippedCount rows (Employee_ID not found in principal lookup)"
    }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Mapped $($mappedRows.Count) rows" -ForegroundColor Green

    if ($mappedRows.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No valid resource assignments to sync after mapping."
        $syncStatus = "Success"
        $syncRecordCount = 0
        return
    }

    # Deduplicate on composite key (resourceId, principalId, assignmentType)
    $groupedRows = $mappedRows | Group-Object -Property { "$($_.resourceId)|$($_.principalId)|$($_.assignmentType)" }
    $duplicates = $groupedRows | Where-Object { $_.Count -gt 1 }

    if ($duplicates) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] Found $($mappedRows.Count - $groupedRows.Count) duplicate rows, deduplicating..."
        $mappedRows = $groupedRows | ForEach-Object { $_.Group[0] }
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] After deduplication: $($mappedRows.Count) unique assignments" -ForegroundColor Green
    }

    # Build DataTable
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Preparing data for bulk sync..." -ForegroundColor Cyan

    $raAttributes = @('resourceId', 'principalId', 'principalType', 'assignmentType', 'complianceState')

    $dataTable = New-FGDataTableFromGraphObjects -GraphObjects $mappedRows -Columns $raColumns -Attributes $raAttributes

    # Sync to SQL
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing resource assignments to SQL Server..." -ForegroundColor Cyan

    $syncResult = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        $transaction = $connection.BeginTransaction()
        $syncStartTime = Get-Date

        try {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($dataTable.Rows.Count) resource assignments..." -ForegroundColor Cyan

            $mergeResult = Invoke-FGSQLBulkMerge `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName $TableName `
                -DataTable $dataTable `
                -KeyColumns @('resourceId', 'principalId', 'assignmentType')

            $syncElapsed = (Get-Date) - $syncStartTime
            $syncedCount = $mergeResult.Inserted + $mergeResult.Updated
            $rate = if ($syncElapsed.TotalSeconds -gt 0) { [math]::Round($syncedCount / $syncElapsed.TotalSeconds, 1) } else { 0 }
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merge completed: $($mergeResult.Inserted) inserted, $($mergeResult.Updated) updated ($rate records/sec)" -ForegroundColor Green

            # Handle deletions
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking for deleted assignments..." -ForegroundColor Cyan

            $deletedCount = Invoke-FGSQLBulkDelete `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName $TableName `
                -DataTable $dataTable `
                -KeyColumns @('resourceId', 'principalId', 'assignmentType')

            if ($deletedCount -gt 0) {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedCount assignments that no longer exist in source" -ForegroundColor Yellow
            }
            else {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] No deleted assignments found" -ForegroundColor Green
            }

            # Commit transaction
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Committing transaction..." -ForegroundColor Cyan
            $transaction.Commit()
            $transaction.Dispose()

            return @{
                SyncedCount  = $syncedCount
                Inserted     = $mergeResult.Inserted
                Updated      = $mergeResult.Updated
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

    $syncRecordCount = $mappedRows.Count

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "CSV Resource Assignment Sync Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Table:               $TableName" -ForegroundColor White
    Write-Host "CSV Rows:            $($csvData.Count)" -ForegroundColor White
    Write-Host "Mapped:              $($mappedRows.Count)" -ForegroundColor White
    Write-Host "Skipped:             $skippedCount" -ForegroundColor White
    Write-Host "  Inserted:          $($syncResult.Inserted)" -ForegroundColor White
    Write-Host "  Updated:           $($syncResult.Updated)" -ForegroundColor White
    Write-Host "  Deleted:           $($syncResult.DeletedCount)" -ForegroundColor White
    Write-Host "`nAll changes tracked in ${TableName}_History" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Green

    $syncStatus = "Success"

    return @{
        TableName        = $TableName
        TotalCSVRows     = $csvData.Count
        MappedCount      = $mappedRows.Count
        SkippedCount     = $skippedCount
        Inserted         = $syncResult.Inserted
        Updated          = $syncResult.Updated
        DeletedCount     = $syncResult.DeletedCount
    }

    } # End try
    catch {
        $syncErrorMessage = $_.Exception.Message
        $syncStatus = "Failed"
        throw
    }
    finally {
        # Write sync log entry
        Write-FGSyncLog -SyncType "CSVResourceAssignments" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName $TableName
    }
}
