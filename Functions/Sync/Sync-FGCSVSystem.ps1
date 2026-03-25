function Sync-FGCSVSystem {
    <#
    .SYNOPSIS
    Syncs Omada Identity System.csv data to the Systems table.

    .DESCRIPTION
    Loads systems from an Omada Identity CSV export and syncs them to the Systems table
    in the universal data model. For each row, checks if a system with matching
    displayName + systemType already exists; if not, creates it.

    Builds a lookup hashtable mapping CSV display names to SQL system IDs, stored in
    $Global:FGCSVSystemLookup for use by downstream sync functions.

    CSV columns mapped:
    - _DISPLAYNAME -> displayName
    - SYSTEMCATEGORY_VALUE -> systemType (fallback to 'Unknown')
    - DESCRIPTION -> description
    - SYSTEMID -> tenantId (external identifier)
    - IsApplication, WoHMV_OIS_Classification, _ID, ODWBUSIKEY -> extendedAttributes JSON

    .PARAMETER Path
    Path to the System.csv file (semicolon-delimited, UTF-8).

    .PARAMETER ParentSystemId
    ID of the parent system record (the Omada Identity system itself).

    .EXAMPLE
    $lookup = Sync-FGCSVSystem -Path "C:\Exports\System.csv" -ParentSystemId 1

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Systems table to exist (run Initialize-FGSystemTables first)
    #>

    [CmdletBinding()]
    [Alias("Sync-CSVSystem")]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [int]$ParentSystemId
    )

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
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Loading systems from CSV: $Path" -ForegroundColor Cyan
    $csvRows = Import-Csv -Path $Path -Delimiter ';' -Encoding UTF8

    if (-not $csvRows -or $csvRows.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No rows found in CSV file."
        $syncStatus = "Success"
        $syncRecordCount = 0
        return @{}
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Loaded $($csvRows.Count) system(s) from CSV" -ForegroundColor Green

    # Build lookup hashtable: CSV displayName -> SQL systemId
    $systemLookup = @{}
    $insertedCount = 0
    $existingCount = 0

    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        foreach ($row in $csvRows) {
            $displayName = $row._DISPLAYNAME
            $systemType = if ($row.SYSTEMCATEGORY_VALUE -and $row.SYSTEMCATEGORY_VALUE.Trim() -ne '') { $row.SYSTEMCATEGORY_VALUE.Trim() } else { 'Unknown' }
            $description = $row.DESCRIPTION
            $tenantId = $row.SYSTEMID

            # Build extendedAttributes JSON
            $extended = @{}
            if ($row.IsApplication -and $row.IsApplication.Trim() -ne '') { $extended['IsApplication'] = $row.IsApplication.Trim() }
            if ($row.WoHMV_OIS_Classification -and $row.WoHMV_OIS_Classification.Trim() -ne '') { $extended['WoHMV_OIS_Classification'] = $row.WoHMV_OIS_Classification.Trim() }
            if ($row._ID -and $row._ID.Trim() -ne '') { $extended['_ID'] = $row._ID.Trim() }
            if ($row.ODWBUSIKEY -and $row.ODWBUSIKEY.Trim() -ne '') { $extended['ODWBUSIKEY'] = $row.ODWBUSIKEY.Trim() }
            $extendedJson = if ($extended.Count -gt 0) { $extended | ConvertTo-Json -Depth 10 -Compress } else { $null }

            # Check if system already exists
            $checkCmd = $connection.CreateCommand()
            $checkCmd.CommandText = "SELECT id FROM dbo.Systems WHERE displayName = @displayName AND systemType = @systemType AND ValidTo = '9999-12-31 23:59:59.9999999'"
            $checkCmd.Parameters.AddWithValue("@displayName", $displayName) | Out-Null
            $checkCmd.Parameters.AddWithValue("@systemType", $systemType) | Out-Null
            $existingId = $checkCmd.ExecuteScalar()
            $checkCmd.Dispose()

            if ($null -ne $existingId) {
                # Update existing record
                $updateCmd = $connection.CreateCommand()
                $updateCmd.CommandText = @"
UPDATE dbo.Systems
SET description = @description,
    tenantId = @tenantId,
    extendedAttributes = @extendedAttributes
WHERE id = @id
"@
                $updateCmd.Parameters.AddWithValue("@description", $(if ($description) { $description } else { [DBNull]::Value })) | Out-Null
                $updateCmd.Parameters.AddWithValue("@tenantId", $(if ($tenantId) { $tenantId } else { [DBNull]::Value })) | Out-Null
                $updateCmd.Parameters.AddWithValue("@extendedAttributes", $(if ($extendedJson) { $extendedJson } else { [DBNull]::Value })) | Out-Null
                $updateCmd.Parameters.AddWithValue("@id", $existingId) | Out-Null
                $updateCmd.ExecuteNonQuery() | Out-Null
                $updateCmd.Dispose()

                $systemLookup[$displayName] = $existingId
                $existingCount++
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Updated existing system '$displayName' (id: $existingId)" -ForegroundColor Gray
            }
            else {
                # Insert new system
                $insertCmd = $connection.CreateCommand()
                $insertCmd.CommandText = @"
INSERT INTO dbo.Systems (systemType, displayName, description, tenantId, enabled, syncEnabled, extendedAttributes)
OUTPUT INSERTED.id
VALUES (@systemType, @displayName, @description, @tenantId, 1, 0, @extendedAttributes)
"@
                $insertCmd.Parameters.AddWithValue("@systemType", $systemType) | Out-Null
                $insertCmd.Parameters.AddWithValue("@displayName", $displayName) | Out-Null
                $insertCmd.Parameters.AddWithValue("@description", $(if ($description) { $description } else { [DBNull]::Value })) | Out-Null
                $insertCmd.Parameters.AddWithValue("@tenantId", $(if ($tenantId) { $tenantId } else { [DBNull]::Value })) | Out-Null
                $insertCmd.Parameters.AddWithValue("@extendedAttributes", $(if ($extendedJson) { $extendedJson } else { [DBNull]::Value })) | Out-Null

                $newId = $insertCmd.ExecuteScalar()
                $insertCmd.Dispose()

                $systemLookup[$displayName] = $newId
                $insertedCount++
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Created system '$displayName' (id: $newId)" -ForegroundColor Green
            }
        }
    }

    $syncRecordCount = $csvRows.Count

    # Store lookup in global scope for downstream functions
    $Global:FGCSVSystemLookup = $systemLookup

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "CSV System Sync Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Total Systems:     $($csvRows.Count)" -ForegroundColor White
    Write-Host "  New:             $insertedCount" -ForegroundColor White
    Write-Host "  Existing:        $existingCount" -ForegroundColor White
    Write-Host "Lookup entries:    $($systemLookup.Count)" -ForegroundColor White
    Write-Host "========================================`n" -ForegroundColor Green

    $syncStatus = "Success"

    return $systemLookup

    } # End try
    catch {
        $syncErrorMessage = $_.Exception.Message
        $syncStatus = "Failed"
        throw
    }
    finally {
        # Write sync log entry
        Write-FGSyncLog -SyncType "CSVSystems" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName "Systems"
    }
}
