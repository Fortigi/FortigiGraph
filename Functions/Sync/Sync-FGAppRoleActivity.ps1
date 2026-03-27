function Sync-FGAppRoleActivity {
    <#
    .SYNOPSIS
    Syncs per-app sign-in activity from the Entra ID audit log into the PrincipalActivity table.

    .DESCRIPTION
    Queries the Microsoft Graph sign-in audit log for a rolling window of days (default: 30)
    and aggregates per-user per-app last sign-in times. Results are written to PrincipalActivity
    with activityType = 'AppSignIn' and resourceId pointing to the matching EntraAppRole resource.

    This answers the role-mining question: "Does the user actually use this app?"
    An assignment exists without any activity record = potential stale/orphaned access.

    Matching strategy:
    - Sign-in log entries have an appId (the application registration client ID)
    - Resources table has EntraAppRole rows with extendedAttributes.appId
    - Match: signIn.appId == JSON_VALUE(Resources.extendedAttributes, '$.appId')
    - If multiple roles exist for the same app, ONE PrincipalActivity row is written per
      (user, app) pair — the activityType 'AppSignIn' signals that the app was used;
      extendedAttributes carries the appId for cross-resource lookups.

    .PARAMETER DaysBack
    Number of days of sign-in history to query. Default: 30. Max: 30 (Azure AD sign-in log retention).

    .PARAMETER SystemId
    Optional system ID to use. If not provided, auto-detects from Systems table where systemType='EntraID'.

    .EXAMPLE
    Sync-FGAppRoleActivity

    Syncs the last 30 days of app sign-in activity.

    .EXAMPLE
    Sync-FGAppRoleActivity -DaysBack 7

    Syncs only the last 7 days.

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Valid Graph access token (Get-FGAccessToken)
    - Initialize-FGActivityTables to have been run
    - Resources table populated by Sync-FGEntraAppRoleAssignment
    - Permissions: AuditLog.Read.All
    #>

    [CmdletBinding()]
    [Alias("Sync-AppRoleActivity")]
    Param(
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 30)]
        [int]$DaysBack = 30,

        [Parameter(Mandatory = $false)]
        [int]$SystemId
    )

    $syncStartTime = Get-Date
    $syncStatus = "Failed"
    $syncErrorMessage = $null
    $syncRecordCount = 0

    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    if (-not $global:AccessToken) {
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

    # Load the appId → resourceId mapping from the Resources table
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Loading app role resource map from SQL..." -ForegroundColor Cyan

    $appResourceMap = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = @"
SELECT
    id AS resourceId,
    JSON_VALUE(extendedAttributes, '$.appId')              AS appId,
    JSON_VALUE(extendedAttributes, '$.servicePrincipalId') AS servicePrincipalId,
    JSON_VALUE(extendedAttributes, '$.appDisplayName')     AS appDisplayName
FROM dbo.Resources
WHERE resourceType = 'EntraAppRole'
  AND extendedAttributes IS NOT NULL
  AND JSON_VALUE(extendedAttributes, '$.appId') IS NOT NULL
"@
        $reader = $cmd.ExecuteReader()
        $map = @{}
        while ($reader.Read()) {
            $appId = $reader['appId']
            if (-not [string]::IsNullOrEmpty($appId) -and -not $map.ContainsKey($appId)) {
                $map[$appId] = @{
                    ResourceId      = $reader['resourceId']
                    ServicePrincipalId = if ($reader['servicePrincipalId'] -is [DBNull]) { $null } else { $reader['servicePrincipalId'] }
                    AppDisplayName  = if ($reader['appDisplayName'] -is [DBNull]) { $null } else { $reader['appDisplayName'] }
                }
            }
        }
        $reader.Close()
        $cmd.Dispose()
        return $map
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Found $($appResourceMap.Count) distinct apps in Resources table" -ForegroundColor Green

    if ($appResourceMap.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No EntraAppRole resources found. Run Sync-FGEntraAppRoleAssignment first."
        $syncStatus = "Success"
        return
    }

    # Query sign-in audit log
    $cutoff = (Get-Date).AddDays(-$DaysBack).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Querying sign-in audit log (last $DaysBack days, since $cutoff)..." -ForegroundColor Cyan

    $uri = "https://graph.microsoft.com/v1.0/auditLogs/signIns?`$select=userId,appId,appDisplayName,createdDateTime,status&`$filter=createdDateTime ge $cutoff and userId ne null&`$top=999"

    $graphStart = Get-Date
    $allSignIns = @()
    try {
        $allSignIns = Invoke-FGGetRequest -URI $uri
        if (-not $allSignIns) { $allSignIns = @() }
    }
    catch {
        throw "Failed to fetch sign-in audit log from Graph: $_"
    }
    $graphElapsed = (Get-Date) - $graphStart
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Fetched $($allSignIns.Count) sign-in events (took $([math]::Round($graphElapsed.TotalSeconds, 1))s)" -ForegroundColor Green

    if ($allSignIns.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No sign-in events found in the audit log for the last $DaysBack days."
        $syncStatus = "Success"
        return
    }

    # Aggregate: (userId, appId) → max createdDateTime
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Aggregating sign-in events by user + app..." -ForegroundColor Cyan

    $aggregated = @{}
    foreach ($signIn in $allSignIns) {
        if ([string]::IsNullOrEmpty($signIn.userId) -or [string]::IsNullOrEmpty($signIn.appId)) { continue }
        $key = "$($signIn.userId)|$($signIn.appId)"
        $eventTime = $null
        if ($signIn.createdDateTime) {
            try { $eventTime = [datetime]$signIn.createdDateTime } catch { continue }
        }
        if (-not $eventTime) { continue }

        if (-not $aggregated.ContainsKey($key) -or $eventTime -gt $aggregated[$key].LastDateTime) {
            $aggregated[$key] = @{
                UserId         = $signIn.userId
                AppId          = $signIn.appId
                AppDisplayName = $signIn.appDisplayName
                LastDateTime   = $eventTime
            }
        }
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Aggregated to $($aggregated.Count) unique (user, app) pairs" -ForegroundColor Green

    # Match aggregated pairs to Resources and Principals
    $activityRows = @()
    $nilGuid = [guid]'00000000-0000-0000-0000-000000000000'
    $unmatchedApps = @{}

    foreach ($entry in $aggregated.Values) {
        $appInfo = $appResourceMap[$entry.AppId]
        if (-not $appInfo) {
            # App not in our Resources table (not synced or not an enterprise app with roles)
            if (-not $unmatchedApps.ContainsKey($entry.AppId)) {
                $unmatchedApps[$entry.AppId] = $entry.AppDisplayName
            }
            continue
        }

        $resourceId = [guid]$appInfo.ResourceId
        $extAttrs = @{
            appId              = $entry.AppId
            servicePrincipalId = $appInfo.ServicePrincipalId
            appDisplayName     = if ($entry.AppDisplayName) { $entry.AppDisplayName } else { $appInfo.AppDisplayName }
        } | ConvertTo-Json -Compress

        $activityRows += @{
            PrincipalId          = $entry.UserId
            ResourceId           = $resourceId
            LastActivityDateTime = $entry.LastDateTime
            ExtendedAttributes   = $extAttrs
        }
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Matched $($activityRows.Count) (user, app) pairs to resources" -ForegroundColor Green
    if ($unmatchedApps.Count -gt 0) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $($unmatchedApps.Count) apps not matched (not in Resources table — no app roles or not synced)" -ForegroundColor Gray
    }

    if ($activityRows.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No matching activity rows found. Check that Sync-FGEntraAppRoleAssignment has run."
        $syncStatus = "Success"
        return
    }

    # Build DataTable for bulk upsert
    $dataTable = New-Object System.Data.DataTable
    $dataTable.Columns.Add("principalId", [string]) | Out-Null
    $dataTable.Columns.Add("resourceId", [guid]) | Out-Null
    $dataTable.Columns.Add("systemId", [int]) | Out-Null
    $dataTable.Columns.Add("activityType", [string]) | Out-Null
    $dataTable.Columns.Add("lastActivityDateTime", [datetime]) | Out-Null
    $dataTable.Columns.Add("extendedAttributes", [string]) | Out-Null
    $dataTable.Columns.Add("syncedAt", [datetime]) | Out-Null

    $now = Get-Date
    foreach ($row in $activityRows) {
        $principalIdStr = $row.PrincipalId
        # Validate it's a GUID before adding (userId in sign-in log should always be a GUID)
        $parsedGuid = [guid]::Empty
        if (-not [guid]::TryParse($principalIdStr, [ref]$parsedGuid)) { continue }

        $dr = $dataTable.NewRow()
        $dr["principalId"]          = $principalIdStr
        $dr["resourceId"]           = $row.ResourceId
        $dr["systemId"]             = $SystemId
        $dr["activityType"]         = 'AppSignIn'
        $dr["lastActivityDateTime"] = $row.LastActivityDateTime
        $dr["extendedAttributes"]   = $row.ExtendedAttributes
        $dr["syncedAt"]             = $now
        $dataTable.Rows.Add($dr)
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Upserting $($dataTable.Rows.Count) app activity rows..." -ForegroundColor Cyan

    $upsertResult = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        $tempCreate = $connection.CreateCommand()
        $tempCreate.CommandText = @"
CREATE TABLE #AppActivityStaging (
    principalId             NVARCHAR(36) NOT NULL,
    resourceId              UNIQUEIDENTIFIER NOT NULL,
    systemId                INT NOT NULL,
    activityType            NVARCHAR(100) NOT NULL,
    lastActivityDateTime    DATETIME2 NOT NULL,
    extendedAttributes      NVARCHAR(MAX) NULL,
    syncedAt                DATETIME2 NOT NULL
);
"@
        $tempCreate.ExecuteNonQuery() | Out-Null
        $tempCreate.Dispose()

        $bulkCopy = New-Object System.Data.SqlClient.SqlBulkCopy($connection)
        $bulkCopy.DestinationTableName = "#AppActivityStaging"
        $bulkCopy.BulkCopyTimeout = 600
        $bulkCopy.WriteToServer($dataTable)
        $bulkCopy.Close()

        # Only upsert rows where the principalId exists in the Principals table
        # (sign-in log may include service accounts, guests, or users not yet synced)
        $mergeCmd = $connection.CreateCommand()
        $mergeCmd.CommandText = @"
MERGE dbo.PrincipalActivity AS target
USING (
    SELECT CAST(s.principalId AS UNIQUEIDENTIFIER) AS principalId,
           s.resourceId, s.systemId, s.activityType,
           s.lastActivityDateTime, s.extendedAttributes, s.syncedAt
    FROM #AppActivityStaging s
    WHERE EXISTS (
        SELECT 1 FROM dbo.Principals p
        WHERE p.id = CAST(s.principalId AS UNIQUEIDENTIFIER)
          AND p.ValidTo = '9999-12-31 23:59:59.9999999'
    )
) AS source
ON  target.principalId  = source.principalId
AND target.resourceId   = source.resourceId
AND target.systemId     = source.systemId
AND target.activityType = source.activityType
WHEN MATCHED THEN UPDATE SET
    lastActivityDateTime = source.lastActivityDateTime,
    extendedAttributes   = source.extendedAttributes,
    syncedAt             = source.syncedAt
WHEN NOT MATCHED BY TARGET THEN INSERT (
    principalId, resourceId, systemId, activityType,
    lastActivityDateTime, extendedAttributes, syncedAt
) VALUES (
    source.principalId, source.resourceId, source.systemId, source.activityType,
    source.lastActivityDateTime, source.extendedAttributes, source.syncedAt
);
"@
        $mergeCmd.CommandTimeout = 600
        $affected = $mergeCmd.ExecuteNonQuery()
        $mergeCmd.Dispose()

        $dropCmd = $connection.CreateCommand()
        $dropCmd.CommandText = "DROP TABLE IF EXISTS #AppActivityStaging;"
        $dropCmd.ExecuteNonQuery() | Out-Null
        $dropCmd.Dispose()

        return $affected
    }

    $syncRecordCount = $activityRows.Count
    $syncStatus = "Success"

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "App Role Activity Sync Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "System ID:         $SystemId" -ForegroundColor White
    Write-Host "Days back:         $DaysBack" -ForegroundColor White
    Write-Host "Sign-in events:    $($allSignIns.Count)" -ForegroundColor White
    Write-Host "Unique (user,app): $($aggregated.Count)" -ForegroundColor White
    Write-Host "Matched to resources: $($activityRows.Count)" -ForegroundColor White
    Write-Host "Rows upserted:     $upsertResult" -ForegroundColor White
    if ($unmatchedApps.Count -gt 0) {
        Write-Host "Unmatched apps:    $($unmatchedApps.Count) (not in Resources table)" -ForegroundColor Gray
    }
    Write-Host "========================================`n" -ForegroundColor Green

    return @{
        SystemId          = $SystemId
        SignInEvents      = $allSignIns.Count
        UniqueUserAppPairs = $aggregated.Count
        MatchedRows       = $activityRows.Count
        RowsUpserted      = $upsertResult
        UnmatchedApps     = $unmatchedApps.Count
    }

    }
    catch {
        $syncErrorMessage = $_.Exception.Message
        $syncStatus = "Failed"
        throw
    }
    finally {
        Write-FGSyncLog -SyncType "AppRoleActivity" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName "PrincipalActivity"
    }
}
