function Sync-FGCSVAgentActivity {
    <#
    .SYNOPSIS
    Imports AI agent invocation activity from a CSV file into the PrincipalActivity table.

    .DESCRIPTION
    Loads agent invocation activity exported from any external system (Azure Monitor, APIM,
    Copilot Studio analytics, etc.) into the PrincipalActivity table. This enables role mining
    signals for AI agents (service principals, managed identities) that do not have a native
    Graph API integration.

    CSV columns (semicolon-delimited):
    - principalId       (required) GUID matching the agent's Principals.id (service principal or managed identity)
    - resourceId        (optional) GUID matching a Resources.id value; use nil GUID for general invocation
    - activityType      (optional) Default: 'Invocation'. Also valid: 'ToolCall', 'DataAccess', 'ExternalCall'
    - lastActivityDateTime (required) ISO 8601 last invocation timestamp
    - activityCount     (optional) Total invocations in the period
    - periodStart       (optional) ISO 8601 start of aggregation window
    - periodEnd         (optional) ISO 8601 end of aggregation window
    - extendedAttributes (optional) JSON string for agent context, e.g. {"modelVersion":"gpt-4o","orchestratorType":"Copilot Studio","callerSystem":"APIM"}

    .PARAMETER FilePath
    Path to the semicolon-delimited CSV file.

    .PARAMETER SystemId
    The system ID this activity belongs to. If not provided, a default CSV system is used.

    .PARAMETER DefaultActivityType
    Activity type to use when the CSV row does not specify one. Default: 'Invocation'.

    .EXAMPLE
    Sync-FGCSVAgentActivity -FilePath ".\exports\agent_activity.csv"

    .EXAMPLE
    Sync-FGCSVAgentActivity -FilePath ".\apim_calls.csv" -DefaultActivityType "ToolCall"

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Initialize-FGActivityTables to have been run
    #>

    [CmdletBinding()]
    [Alias("Sync-CSVAgentActivity")]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $false)]
        [int]$SystemId,

        [Parameter(Mandatory = $false)]
        [string]$DefaultActivityType = 'Invocation'
    )

    $syncStartTime = Get-Date
    $syncStatus = "Failed"
    $syncErrorMessage = $null
    $syncRecordCount = 0

    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    if (-not (Test-Path $FilePath)) {
        throw "CSV file not found: $FilePath"
    }

    try {

    if (-not $SystemId) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] SystemId not provided — will use 0 as placeholder (CSV system)" -ForegroundColor Yellow
        $SystemId = 0
    }

    Initialize-FGActivityTables

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Loading CSV from: $FilePath" -ForegroundColor Cyan
    $csvRows = Import-Csv -Path $FilePath -Delimiter ';'
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Loaded $($csvRows.Count) rows" -ForegroundColor Green

    if ($csvRows.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] CSV file is empty."
        $syncStatus = "Success"
        return
    }

    $nilGuid = [guid]'00000000-0000-0000-0000-000000000000'
    $dataTable = New-Object System.Data.DataTable
    $dataTable.Columns.Add("principalId", [guid]) | Out-Null
    $dataTable.Columns.Add("resourceId", [guid]) | Out-Null
    $dataTable.Columns.Add("systemId", [int]) | Out-Null
    $dataTable.Columns.Add("activityType", [string]) | Out-Null
    $dataTable.Columns.Add("lastActivityDateTime", [object]) | Out-Null
    $dataTable.Columns.Add("activityCount", [object]) | Out-Null
    $dataTable.Columns.Add("periodStart", [object]) | Out-Null
    $dataTable.Columns.Add("periodEnd", [object]) | Out-Null
    $dataTable.Columns.Add("extendedAttributes", [string]) | Out-Null
    $dataTable.Columns.Add("syncedAt", [datetime]) | Out-Null

    $now = Get-Date
    $skipped = 0

    foreach ($row in $csvRows) {
        # principalId is required and must be a valid GUID
        $principalId = [guid]::Empty
        if ([string]::IsNullOrEmpty($row.principalId) -or -not [guid]::TryParse($row.principalId, [ref]$principalId)) {
            $skipped++
            continue
        }

        # lastActivityDateTime is required
        $lastActivity = $null
        if (-not [string]::IsNullOrEmpty($row.lastActivityDateTime)) {
            try { $lastActivity = [datetime]$row.lastActivityDateTime }
            catch { $skipped++; continue }
        } else {
            $skipped++
            continue
        }

        # resourceId is optional — default to nil GUID
        $resourceId = $nilGuid
        if (-not [string]::IsNullOrEmpty($row.resourceId)) {
            $parsedResource = [guid]::Empty
            if ([guid]::TryParse($row.resourceId, [ref]$parsedResource)) {
                $resourceId = $parsedResource
            }
        }

        $activityType = if (-not [string]::IsNullOrEmpty($row.activityType)) { $row.activityType } else { $DefaultActivityType }

        $dr = $dataTable.NewRow()
        $dr["principalId"]          = $principalId
        $dr["resourceId"]           = $resourceId
        $dr["systemId"]             = $SystemId
        $dr["activityType"]         = $activityType
        $dr["lastActivityDateTime"] = $lastActivity
        $dr["activityCount"]        = if (-not [string]::IsNullOrEmpty($row.activityCount) -and [int64]::TryParse($row.activityCount, [ref]0)) { [int64]$row.activityCount } else { [DBNull]::Value }
        $dr["periodStart"]          = if (-not [string]::IsNullOrEmpty($row.periodStart)) { try { [datetime]$row.periodStart } catch { [DBNull]::Value } } else { [DBNull]::Value }
        $dr["periodEnd"]            = if (-not [string]::IsNullOrEmpty($row.periodEnd)) { try { [datetime]$row.periodEnd } catch { [DBNull]::Value } } else { [DBNull]::Value }
        $dr["extendedAttributes"]   = if (-not [string]::IsNullOrEmpty($row.extendedAttributes)) { $row.extendedAttributes } else { [DBNull]::Value }
        $dr["syncedAt"]             = $now
        $dataTable.Rows.Add($dr)
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Prepared $($dataTable.Rows.Count) valid rows ($skipped skipped)" -ForegroundColor Gray

    if ($dataTable.Rows.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No valid rows to import."
        $syncStatus = "Success"
        return
    }

    $upsertResult = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        $tempCreate = $connection.CreateCommand()
        $tempCreate.CommandText = @"
CREATE TABLE #CSVActivityStaging (
    principalId             UNIQUEIDENTIFIER NOT NULL,
    resourceId              UNIQUEIDENTIFIER NOT NULL,
    systemId                INT NOT NULL,
    activityType            NVARCHAR(100) NOT NULL,
    lastActivityDateTime    DATETIME2 NULL,
    activityCount           BIGINT NULL,
    periodStart             DATETIME2 NULL,
    periodEnd               DATETIME2 NULL,
    extendedAttributes      NVARCHAR(MAX) NULL,
    syncedAt                DATETIME2 NOT NULL
);
"@
        $tempCreate.ExecuteNonQuery() | Out-Null
        $tempCreate.Dispose()

        $bulkCopy = New-Object System.Data.SqlClient.SqlBulkCopy($connection)
        $bulkCopy.DestinationTableName = "#CSVActivityStaging"
        $bulkCopy.BulkCopyTimeout = 600
        $bulkCopy.WriteToServer($dataTable)
        $bulkCopy.Close()

        $mergeCmd = $connection.CreateCommand()
        $mergeCmd.CommandText = @"
MERGE dbo.PrincipalActivity AS target
USING #CSVActivityStaging AS source
ON  target.principalId  = source.principalId
AND target.resourceId   = source.resourceId
AND target.systemId     = source.systemId
AND target.activityType = source.activityType
WHEN MATCHED THEN UPDATE SET
    lastActivityDateTime = source.lastActivityDateTime,
    activityCount        = source.activityCount,
    periodStart          = source.periodStart,
    periodEnd            = source.periodEnd,
    extendedAttributes   = source.extendedAttributes,
    syncedAt             = source.syncedAt
WHEN NOT MATCHED BY TARGET THEN INSERT (
    principalId, resourceId, systemId, activityType,
    lastActivityDateTime, activityCount, periodStart, periodEnd,
    extendedAttributes, syncedAt
) VALUES (
    source.principalId, source.resourceId, source.systemId, source.activityType,
    source.lastActivityDateTime, source.activityCount, source.periodStart, source.periodEnd,
    source.extendedAttributes, source.syncedAt
);
"@
        $mergeCmd.CommandTimeout = 600
        $affected = $mergeCmd.ExecuteNonQuery()
        $mergeCmd.Dispose()

        $dropCmd = $connection.CreateCommand()
        $dropCmd.CommandText = "DROP TABLE IF EXISTS #CSVActivityStaging;"
        $dropCmd.ExecuteNonQuery() | Out-Null
        $dropCmd.Dispose()

        return $affected
    }

    $syncRecordCount = $dataTable.Rows.Count
    $syncStatus = "Success"

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "CSV Agent Activity Import Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "File:          $FilePath" -ForegroundColor White
    Write-Host "Rows in CSV:   $($csvRows.Count)" -ForegroundColor White
    Write-Host "Rows imported: $($dataTable.Rows.Count)" -ForegroundColor White
    Write-Host "Rows skipped:  $skipped" -ForegroundColor White
    Write-Host "Rows upserted: $upsertResult" -ForegroundColor White
    Write-Host "========================================`n" -ForegroundColor Green

    return @{
        FilePath      = $FilePath
        TotalRows     = $csvRows.Count
        ImportedRows  = $dataTable.Rows.Count
        SkippedRows   = $skipped
        RowsUpserted  = $upsertResult
    }

    }
    catch {
        $syncErrorMessage = $_.Exception.Message
        $syncStatus = "Failed"
        throw
    }
    finally {
        Write-FGSyncLog -SyncType "CSVAgentActivity" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName "PrincipalActivity"
    }
}
