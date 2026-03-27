function Sync-FGPrincipalActivity {
    <#
    .SYNOPSIS
    Syncs principal sign-in activity (lastSignInDateTime) into the PrincipalActivity table.

    .DESCRIPTION
    Populates the PrincipalActivity table with general sign-in activity for Entra ID users.

    By default (SQL mode), reads lastSignInDateTime from the extendedAttributes JSON column
    on the Principals table — no Graph API call needed. This is efficient because
    Sync-FGPrincipal already fetches this data.

    With -FetchFromGraph, makes a fresh Graph API call with the signInActivity expand to get
    the latest data directly, regardless of when Sync-FGPrincipal last ran.

    Each row written to PrincipalActivity:
    - principalId = the principal's GUID
    - resourceId  = '00000000-0000-0000-0000-000000000000' (nil GUID = general sign-in)
    - systemId    = EntraID system ID
    - activityType = 'SignIn'
    - lastActivityDateTime = last sign-in timestamp

    After calling this function, lastSignInDateTime is no longer needed in
    Principals.extendedAttributes (Sync-FGPrincipal no longer writes it there).

    .PARAMETER FetchFromGraph
    If specified, fetches fresh sign-in activity directly from the Graph API
    (signInActivity expand on /v1.0/users) instead of reading from the Principals table.

    .PARAMETER SystemId
    Optional system ID to use. If not provided, auto-detects from Systems table where systemType='EntraID'.

    .PARAMETER Filter
    OData filter for user selection (only used with -FetchFromGraph).
    Example: "accountEnabled eq true"

    .EXAMPLE
    Sync-FGPrincipalActivity

    Reads lastSignInDateTime from existing Principals.extendedAttributes and writes to PrincipalActivity.

    .EXAMPLE
    Sync-FGPrincipalActivity -FetchFromGraph

    Fetches fresh sign-in data from Graph API and writes to PrincipalActivity.

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Initialize-FGActivityTables to have been run
    - For -FetchFromGraph: Valid Graph access token (Get-FGAccessToken), Permission: User.Read.All
    #>

    [CmdletBinding()]
    [Alias("Sync-PrincipalActivity")]
    Param(
        [Parameter(Mandatory = $false)]
        [switch]$FetchFromGraph,

        [Parameter(Mandatory = $false)]
        [int]$SystemId,

        [Parameter(Mandatory = $false)]
        [string]$Filter
    )

    $syncStartTime = Get-Date
    $syncStatus = "Failed"
    $syncErrorMessage = $null
    $syncRecordCount = 0

    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    if ($FetchFromGraph -and -not $global:AccessToken) {
        throw "No Graph access token found. Please run Get-FGAccessToken first."
    }

    try {

    # Resolve SystemId
    if (-not $SystemId) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Auto-detecting system ID for EntraID..." -ForegroundColor Cyan
        $SystemId = Sync-FGSystem -SystemType 'EntraID' -TenantId $Global:TenantId -DisplayName 'Entra ID'
        if (-not $SystemId) {
            throw "Could not find or create a system record for EntraID. Please run Initialize-FGSystemTables first."
        }
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Using system ID: $SystemId" -ForegroundColor Green
    }

    # Ensure PrincipalActivity table exists
    Initialize-FGActivityTables

    # Collect (principalId, lastSignInDateTime) pairs
    $activityRows = @()

    if ($FetchFromGraph) {
        # --- Graph API mode: fresh data ---
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Fetching sign-in activity from Microsoft Graph..." -ForegroundColor Cyan

        $selectProps = "id,userPrincipalName"
        $uri = "https://graph.microsoft.com/v1.0/users?`$select=$selectProps,signInActivity"
        if ($Filter) { $uri += "&`$filter=$Filter" }

        $graphStart = Get-Date
        try {
            $users = Invoke-FGGetRequest -URI $uri
            if (-not $users) { $users = @() }
        }
        catch {
            throw "Failed to fetch users from Graph: $_"
        }
        $graphElapsed = (Get-Date) - $graphStart
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Fetched $($users.Count) users (took $([math]::Round($graphElapsed.TotalSeconds, 1))s)" -ForegroundColor Green

        foreach ($user in $users) {
            if ($user.signInActivity -and $user.signInActivity.lastSignInDateTime) {
                $activityRows += @{
                    PrincipalId           = [guid]$user.id
                    LastActivityDateTime  = $user.signInActivity.lastSignInDateTime
                }
            }
        }
    }
    else {
        # --- SQL mode: read from existing Principals.extendedAttributes ---
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Reading sign-in activity from Principals table..." -ForegroundColor Cyan

        $sqlRows = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            $cmd = $connection.CreateCommand()
            $cmd.CommandText = @"
SELECT id, JSON_VALUE(extendedAttributes, '$.lastSignInDateTime') AS lastSignInDateTime
FROM dbo.Principals
WHERE ValidTo = '9999-12-31 23:59:59.9999999'
  AND principalType = 'User'
  AND JSON_VALUE(extendedAttributes, '$.lastSignInDateTime') IS NOT NULL
"@
            $reader = $cmd.ExecuteReader()
            $rows = @()
            while ($reader.Read()) {
                $rows += @{
                    Id               = $reader['id']
                    LastSignInDateTime = $reader['lastSignInDateTime']
                }
            }
            $reader.Close()
            $cmd.Dispose()
            return $rows
        }

        if ($sqlRows) {
            foreach ($row in $sqlRows) {
                $activityRows += @{
                    PrincipalId          = $row.Id
                    LastActivityDateTime = $row.LastSignInDateTime
                }
            }
        }
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Found $($activityRows.Count) principals with sign-in activity" -ForegroundColor Green
    }

    if ($activityRows.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No sign-in activity found to sync."
        $syncStatus = "Success"
        return
    }

    # Build DataTable for bulk upsert
    $nilGuid = [guid]'00000000-0000-0000-0000-000000000000'
    $dataTable = New-Object System.Data.DataTable
    $dataTable.Columns.Add("principalId", [guid]) | Out-Null
    $dataTable.Columns.Add("resourceId", [guid]) | Out-Null
    $dataTable.Columns.Add("systemId", [int]) | Out-Null
    $dataTable.Columns.Add("activityType", [string]) | Out-Null
    $dataTable.Columns.Add("lastActivityDateTime", [object]) | Out-Null
    $dataTable.Columns.Add("syncedAt", [datetime]) | Out-Null

    $now = Get-Date
    foreach ($row in $activityRows) {
        $dr = $dataTable.NewRow()
        $dr["principalId"]          = $row.PrincipalId
        $dr["resourceId"]           = $nilGuid
        $dr["systemId"]             = $SystemId
        $dr["activityType"]         = 'SignIn'
        $dr["lastActivityDateTime"] = if ($row.LastActivityDateTime) { [datetime]$row.LastActivityDateTime } else { [DBNull]::Value }
        $dr["syncedAt"]             = $now
        $dataTable.Rows.Add($dr)
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Upserting $($dataTable.Rows.Count) activity rows..." -ForegroundColor Cyan

    $upsertResult = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        # Bulk load into temp table
        $tempCreate = $connection.CreateCommand()
        $tempCreate.CommandText = @"
CREATE TABLE #ActivityStaging (
    principalId             UNIQUEIDENTIFIER NOT NULL,
    resourceId              UNIQUEIDENTIFIER NOT NULL,
    systemId                INT NOT NULL,
    activityType            NVARCHAR(100) NOT NULL,
    lastActivityDateTime    DATETIME2 NULL,
    syncedAt                DATETIME2 NOT NULL
);
"@
        $tempCreate.ExecuteNonQuery() | Out-Null
        $tempCreate.Dispose()

        $bulkCopy = New-Object System.Data.SqlClient.SqlBulkCopy($connection)
        $bulkCopy.DestinationTableName = "#ActivityStaging"
        $bulkCopy.BulkCopyTimeout = 600
        $bulkCopy.WriteToServer($dataTable)
        $bulkCopy.Close()

        # MERGE from staging into PrincipalActivity
        $mergeCmd = $connection.CreateCommand()
        $mergeCmd.CommandText = @"
MERGE dbo.PrincipalActivity AS target
USING #ActivityStaging AS source
ON  target.principalId  = source.principalId
AND target.resourceId   = source.resourceId
AND target.systemId     = source.systemId
AND target.activityType = source.activityType
WHEN MATCHED THEN UPDATE SET
    lastActivityDateTime = source.lastActivityDateTime,
    syncedAt             = source.syncedAt
WHEN NOT MATCHED BY TARGET THEN INSERT (
    principalId, resourceId, systemId, activityType,
    lastActivityDateTime, syncedAt
) VALUES (
    source.principalId, source.resourceId, source.systemId, source.activityType,
    source.lastActivityDateTime, source.syncedAt
);
"@
        $mergeCmd.CommandTimeout = 600
        $affected = $mergeCmd.ExecuteNonQuery()
        $mergeCmd.Dispose()

        $dropCmd = $connection.CreateCommand()
        $dropCmd.CommandText = "DROP TABLE IF EXISTS #ActivityStaging;"
        $dropCmd.ExecuteNonQuery() | Out-Null
        $dropCmd.Dispose()

        return $affected
    }

    $syncRecordCount = $activityRows.Count
    $syncStatus = "Success"

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Principal Activity Sync Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    $mode = if ($FetchFromGraph) { "Graph API" } else { "SQL (from Principals)" }
    Write-Host "Mode:              $mode" -ForegroundColor White
    Write-Host "System ID:         $SystemId" -ForegroundColor White
    Write-Host "Activity rows:     $($activityRows.Count)" -ForegroundColor White
    Write-Host "Rows upserted:     $upsertResult" -ForegroundColor White
    Write-Host "========================================`n" -ForegroundColor Green

    return @{
        SystemId      = $SystemId
        ActivityRows  = $activityRows.Count
        RowsUpserted  = $upsertResult
    }

    }
    catch {
        $syncErrorMessage = $_.Exception.Message
        $syncStatus = "Failed"
        throw
    }
    finally {
        Write-FGSyncLog -SyncType "PrincipalActivity" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName "PrincipalActivity"
    }
}
