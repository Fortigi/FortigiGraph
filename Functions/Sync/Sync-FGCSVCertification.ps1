function Sync-FGCSVCertification {
    <#
    .SYNOPSIS
    Syncs certification decisions from a semicolon-delimited CSV file (CRAs.csv) to the CertificationDecisions table.

    .DESCRIPTION
    Loads CRAs.csv and maps rows to the CertificationDecisions table. Each row represents a
    certification/recertification decision for a resource assignment.

    Uses the global $FGCSVSystemLookup to resolve SystemName to systemId, and
    $FGCSVPrincipalLookup to resolve GlobID to principalId (falls back to IdentityId as GUID).

    Skips rows where ResourceId or IdentityId is empty. Uses bulk operations for the
    potentially large dataset (37K+ rows).

    .PARAMETER Path
    Path to the CRAs.csv file (semicolon-delimited, quoted, UTF8).

    .PARAMETER TableName
    Name of the SQL table to sync to. Default: "CertificationDecisions"

    .EXAMPLE
    Sync-FGCSVCertification -Path ".\data\CRAs.csv"

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - $Global:FGCSVSystemLookup hashtable populated (system name -> systemId INT)
    - $Global:FGCSVPrincipalLookup hashtable populated (GlobID -> principalId GUID)
    #>

    [CmdletBinding()]
    [Alias("Sync-CSVCertification")]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [string]$TableName = "CertificationDecisions"
    )

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

    # Check lookups
    if (-not $Global:FGCSVSystemLookup -or $Global:FGCSVSystemLookup.Count -eq 0) {
        throw "Global system lookup is empty. Please populate `$Global:FGCSVSystemLookup before calling this function."
    }

    if (-not $Global:FGCSVPrincipalLookup -or $Global:FGCSVPrincipalLookup.Count -eq 0) {
        throw "Global principal lookup is empty. Please populate `$Global:FGCSVPrincipalLookup before calling this function."
    }

    try {

    # Ensure CertificationDecisions table exists
    $cdColumns = @{
        'id'                      = 'UNIQUEIDENTIFIER'
        'systemId'                = 'INT'
        'businessRoleId'          = 'UNIQUEIDENTIFIER'
        'resourceId'              = 'UNIQUEIDENTIFIER'
        'certificationScopeType'  = 'NVARCHAR(100)'
        'principalId'             = 'UNIQUEIDENTIFIER'
        'principalDisplayName'    = 'NVARCHAR(500)'
        'decision'                = 'NVARCHAR(255)'
        'extendedAttributes'      = 'NVARCHAR(MAX)'
    }

    $tableReady = Initialize-FGSyncTable -TableName $TableName -Columns $cdColumns -PrimaryKey 'id'
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

    # Map CSV rows to CertificationDecision objects
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Mapping CSV rows to CertificationDecisions..." -ForegroundColor Cyan

    $mappedRows = @()
    $skippedEmpty = 0
    $skippedPrincipal = 0

    foreach ($row in $csvData) {
        # Skip rows where ResourceId or IdentityId is empty
        if ([string]::IsNullOrWhiteSpace($row.ResourceId) -or [string]::IsNullOrWhiteSpace($row.IdentityId)) {
            $skippedEmpty++
            continue
        }

        # Resolve systemId
        $systemId = $Global:FGCSVSystemLookup[$row.SystemName]

        # Resolve principalId: try GlobID lookup first, fall back to IdentityId as GUID
        $principalId = $null
        if ($row.GlobID -and $Global:FGCSVPrincipalLookup.ContainsKey($row.GlobID)) {
            $principalId = $Global:FGCSVPrincipalLookup[$row.GlobID]
        }
        else {
            try {
                $principalId = [guid]$row.IdentityId
            }
            catch {
                $skippedPrincipal++
                continue
            }
        }

        # Build extendedAttributes
        $extendedAttrs = @{}
        if ($row.PSObject.Properties.Name -contains 'TechName' -and $row.TechName) { $extendedAttrs['TechName'] = $row.TechName }
        if ($row.PSObject.Properties.Name -contains 'AccountAssignment' -and $row.AccountAssignment) { $extendedAttrs['AccountAssignment'] = $row.AccountAssignment }
        if ($row.PSObject.Properties.Name -contains 'AccountName' -and $row.AccountName) { $extendedAttrs['AccountName'] = $row.AccountName }
        if ($row.PSObject.Properties.Name -contains 'ValidFrom' -and $row.ValidFrom) { $extendedAttrs['ValidFrom'] = $row.ValidFrom }
        if ($row.PSObject.Properties.Name -contains 'ValidTo' -and $row.ValidTo) { $extendedAttrs['ValidTo'] = $row.ValidTo }
        if ($row.PSObject.Properties.Name -contains 'IdentityValidTo' -and $row.IdentityValidTo) { $extendedAttrs['IdentityValidTo'] = $row.IdentityValidTo }

        $mappedRows += [PSCustomObject]@{
            id                     = New-DeterministicGuid -InputString "cert:$($row.ResourceId):$($row.IdentityId):$($row.SystemName)"
            systemId               = $systemId
            businessRoleId         = $null
            resourceId             = [guid]$row.ResourceId
            certificationScopeType = 'ResourceAssignment'
            principalId            = $principalId
            principalDisplayName   = $row.DisplayName
            decision               = $row.ComplianceState
            extendedAttributes     = if ($extendedAttrs.Count -gt 0) { $extendedAttrs | ConvertTo-Json -Depth 10 -Compress } else { $null }
        }
    }

    if ($skippedEmpty -gt 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] Skipped $skippedEmpty rows with empty ResourceId or IdentityId"
    }
    if ($skippedPrincipal -gt 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] Skipped $skippedPrincipal rows (GlobID not in lookup and IdentityId not a valid GUID)"
    }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Mapped $($mappedRows.Count) certification decisions" -ForegroundColor Green

    if ($mappedRows.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No valid certification decisions to sync after mapping."
        $syncStatus = "Success"
        $syncRecordCount = 0
        return
    }

    # Check for duplicate IDs
    $groupedById = $mappedRows | Group-Object -Property id
    $duplicates = $groupedById | Where-Object { $_.Count -gt 1 }

    if ($duplicates) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] Found $($mappedRows.Count - $groupedById.Count) duplicate IDs, deduplicating..."
        $mappedRows = $groupedById | ForEach-Object { $_.Group[0] }
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] After deduplication: $($mappedRows.Count) unique decisions" -ForegroundColor Green
    }

    # Build DataTable
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Preparing data for bulk sync..." -ForegroundColor Cyan

    $cdAttributes = @('id', 'systemId', 'businessRoleId', 'resourceId', 'certificationScopeType', 'principalId', 'principalDisplayName', 'decision', 'extendedAttributes')

    $dataTable = New-FGDataTableFromGraphObjects -GraphObjects $mappedRows -Columns $cdColumns -Attributes $cdAttributes

    # Sync to SQL
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing certification decisions to SQL Server..." -ForegroundColor Cyan

    $syncResult = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        $transaction = $connection.BeginTransaction()
        $syncStartTime = Get-Date

        try {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($dataTable.Rows.Count) certification decisions..." -ForegroundColor Cyan

            $mergeResult = Invoke-FGSQLBulkMerge `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName $TableName `
                -DataTable $dataTable `
                -KeyColumns @('id')

            $syncElapsed = (Get-Date) - $syncStartTime
            $syncedCount = $mergeResult.Inserted + $mergeResult.Updated
            $rate = if ($syncElapsed.TotalSeconds -gt 0) { [math]::Round($syncedCount / $syncElapsed.TotalSeconds, 1) } else { 0 }
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merge completed: $($mergeResult.Inserted) inserted, $($mergeResult.Updated) updated ($rate records/sec)" -ForegroundColor Green

            # Handle deletions
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking for deleted decisions..." -ForegroundColor Cyan

            $deletedCount = Invoke-FGSQLBulkDelete `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName $TableName `
                -DataTable $dataTable `
                -KeyColumns @('id')

            if ($deletedCount -gt 0) {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedCount decisions that no longer exist in source" -ForegroundColor Yellow
            }
            else {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] No deleted decisions found" -ForegroundColor Green
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
    Write-Host "CSV Certification Decision Sync Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Table:               $TableName" -ForegroundColor White
    Write-Host "CSV Rows:            $($csvData.Count)" -ForegroundColor White
    Write-Host "Mapped:              $($mappedRows.Count)" -ForegroundColor White
    Write-Host "Skipped (empty):     $skippedEmpty" -ForegroundColor White
    Write-Host "Skipped (principal): $skippedPrincipal" -ForegroundColor White
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
        SkippedEmpty     = $skippedEmpty
        SkippedPrincipal = $skippedPrincipal
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
        Write-FGSyncLog -SyncType "CSVCertificationDecisions" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName $TableName
    }
}
