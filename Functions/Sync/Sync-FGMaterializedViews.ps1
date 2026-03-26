function Sync-FGMaterializedViews {
    <#
    .SYNOPSIS
    Materializes analysis views into tables for fast UI queries.

    .DESCRIPTION
    Converts the complex analysis views (vw_UserPermissionAssignments and
    vw_UserPermissionAssignmentViaBusinessRole) into physical tables with indexes.
    This eliminates the expensive recursive CTE and EXISTS subqueries that run on
    every API request, reducing query time from minutes to milliseconds.

    The materialized tables use the "mat_" prefix:
    - mat_UserPermissionAssignments (from vw_UserPermissionAssignments)
    - mat_UserPermissionAssignmentViaBusinessRole (from vw_UserPermissionAssignmentViaBusinessRole)

    The UI backend automatically detects and prefers materialized tables, falling
    back to the views if they don't exist.

    Performance optimizations over direct SELECT * INTO FROM view:
    - Multi-step materialization: recursive CTE -> temp table -> final table
    - Skips path and ValidFrom/ValidTo columns (not used by UI, avoids NVARCHAR(MAX) LOB overhead)
    - Uses LEFT JOIN instead of correlated EXISTS for managedByAccessPackage (set-based vs row-by-row)
    - Materializes AP table first, then uses it for the managed check

    .PARAMETER CommandTimeout
    Maximum seconds per SQL step. Default 1800 (30 minutes).
    Increase for very large tenants or lower-tier Azure SQL databases.

    .EXAMPLE
    Sync-FGMaterializedViews

    Materializes all available views into indexed tables.

    .EXAMPLE
    Sync-FGMaterializedViews -CommandTimeout 3600

    Materializes with a 1-hour timeout per step (for very large tenants).

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Views to exist (run Initialize-FGGroupMembershipViews and Initialize-FGAccessPackageViews first)

    This function should be called:
    - At the end of Start-FGSync (automatic)
    - Via the Sync-FGMaterializedViews Azure Automation runbook (scheduled after all syncs)

    Memory: SQL commands execute server-side. PowerShell memory usage is negligible
    (only row counts are returned), so this is safe for Azure Automation sandboxes.
    #>

    [alias("Sync-MaterializedViews")]
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $false)]
        [int]$CommandTimeout = 1800
    )

    # Track sync timing for logging
    $syncStartTime = Get-Date
    $syncStatus = "Failed"
    $syncErrorMessage = $null
    $syncRecordCount = 0

    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    try {

    $result = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Materializing views for UI performance (timeout: ${CommandTimeout}s per step)..." -ForegroundColor Cyan

        # Check which views and source tables exist
        $checkCmd = $connection.CreateCommand()
        $checkCmd.CommandTimeout = 60
        $checkCmd.CommandText = @"
SELECT
    CASE WHEN EXISTS (SELECT 1 FROM sys.views WHERE name = 'vw_UserPermissionAssignmentViaBusinessRole') THEN 1 ELSE 0 END AS ApViewExists,
    CASE WHEN EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'ResourceAssignments') THEN 1 ELSE 0 END AS DirectMembersExists,
    CASE WHEN EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'ResourceAssignments') THEN 1 ELSE 0 END AS OwnersExists,
    CASE WHEN EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'ResourceAssignments') THEN 1 ELSE 0 END AS EligibleExists
"@
        $reader = $checkCmd.ExecuteReader()
        $reader.Read()
        $apViewExists = $reader.GetInt32(0) -eq 1
        $directMembersExists = $reader.GetInt32(1) -eq 1
        $ownersExists = $reader.GetInt32(2) -eq 1
        $eligibleExists = $reader.GetInt32(3) -eq 1
        $reader.Close()

        $materialized = 0

        # ═══════════════════════════════════════════════════════════════
        # Step 1: Materialize vw_UserPermissionAssignmentViaBusinessRole
        # Simple 6-table join, no recursion — materialize first so we can
        # use it for the managedByAccessPackage LEFT JOIN in step 2.
        # ═══════════════════════════════════════════════════════════════
        if ($apViewExists) {
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Step 1/3: Materializing AP permissions..." -ForegroundColor Cyan

            try {
                $cmd = $connection.CreateCommand()
                $cmd.CommandTimeout = $CommandTimeout
                $cmd.CommandText = @"
IF OBJECT_ID('dbo.mat_UserPermissionAssignmentViaBusinessRole', 'U') IS NOT NULL
    DROP TABLE dbo.mat_UserPermissionAssignmentViaBusinessRole;

SELECT *
INTO dbo.mat_UserPermissionAssignmentViaBusinessRole
FROM dbo.vw_UserPermissionAssignmentViaBusinessRole;

CREATE NONCLUSTERED INDEX IX_mat_UPAVAP_userId_groupId
    ON dbo.mat_UserPermissionAssignmentViaBusinessRole (userId, groupId)
    INCLUDE (businessRoleId);

CREATE NONCLUSTERED INDEX IX_mat_UPAVBR_businessRoleId
    ON dbo.mat_UserPermissionAssignmentViaBusinessRole (businessRoleId);
"@
                $cmd.ExecuteNonQuery() | Out-Null

                $countCmd = $connection.CreateCommand()
                $countCmd.CommandTimeout = 120
                $countCmd.CommandText = "SELECT COUNT(*) FROM dbo.mat_UserPermissionAssignmentViaBusinessRole"
                $rowCount = $countCmd.ExecuteScalar()

                Write-Host "    Materialized mat_UserPermissionAssignmentViaBusinessRole: $rowCount rows" -ForegroundColor Green
                $materialized++
            }
            catch {
                Write-Host "    Step 1 FAILED (AP permissions): $_" -ForegroundColor Red
                Write-Host "    Continuing with remaining steps..." -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "  View vw_UserPermissionAssignmentViaBusinessRole does not exist (optional)" -ForegroundColor Yellow
        }

        # ═══════════════════════════════════════════════════════════════
        # Step 2: Compute recursive memberships into temp table
        # Key optimizations vs SELECT * FROM vw_UserPermissionAssignments:
        # - Skips path column (NVARCHAR(MAX) concatenation per recursion = LOB overhead)
        # - Skips ValidFrom/ValidTo (CASE expressions per recursion, not used by UI)
        # - Runs as isolated step with its own timeout
        # ═══════════════════════════════════════════════════════════════
        if ($directMembersExists) {
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Step 2/3: Computing recursive memberships..." -ForegroundColor Cyan

            try {
                $cmd = $connection.CreateCommand()
                $cmd.CommandTimeout = $CommandTimeout
                $cmd.CommandText = @"
IF OBJECT_ID('tempdb..#RecursiveMemberships') IS NOT NULL DROP TABLE #RecursiveMemberships;

;WITH RecursiveMemberships AS (
    -- Anchor: Direct assignments from ResourceAssignments
    SELECT
        ra.resourceId AS groupId,
        ra.principalId AS memberId,
        ra.principalType AS memberType,
        CAST('Direct' AS NVARCHAR(20)) AS membershipType,
        1 AS depth
    FROM dbo.ResourceAssignments ra
    WHERE ra.ValidTo = '9999-12-31 23:59:59.9999999'
      AND ra.assignmentType = 'Direct'

    UNION ALL

    -- Recursive: Indirect memberships through nested groups
    SELECT
        rm.groupId,
        ra2.principalId AS memberId,
        ra2.principalType AS memberType,
        CAST('Indirect' AS NVARCHAR(20)) AS membershipType,
        rm.depth + 1
    FROM RecursiveMemberships rm
    INNER JOIN dbo.ResourceAssignments ra2
        ON rm.memberId = ra2.resourceId
        AND ra2.ValidTo = '9999-12-31 23:59:59.9999999'
        AND ra2.assignmentType = 'Direct'
    WHERE rm.memberType LIKE '%group%'
        AND rm.depth < 10
)
SELECT groupId, memberId, memberType, membershipType
INTO #RecursiveMemberships
FROM RecursiveMemberships
OPTION (MAXRECURSION 100);
"@
                $cmd.ExecuteNonQuery() | Out-Null

                $countCmd = $connection.CreateCommand()
                $countCmd.CommandTimeout = 120
                $countCmd.CommandText = "SELECT COUNT(*) FROM #RecursiveMemberships"
                $recursiveCount = $countCmd.ExecuteScalar()
                Write-Host "    Recursive memberships computed: $recursiveCount rows" -ForegroundColor Green
            }
            catch {
                Write-Host "    Step 2 FAILED (recursive memberships): $_" -ForegroundColor Red
                Write-Host "    This is often caused by a low Azure SQL tier (DTU limit). Consider scaling up temporarily or increasing -CommandTimeout." -ForegroundColor Yellow
                Write-Host "    Skipping Step 3 (depends on Step 2)." -ForegroundColor Yellow
                $directMembersExists = $false
            }

            # ═══════════════════════════════════════════════════════════════
            # Step 3: Build final materialized table from temp + owners + eligible
            # Uses LEFT JOIN against materialized AP table for managedByAccessPackage
            # instead of correlated EXISTS (set-based vs row-by-row).
            # ═══════════════════════════════════════════════════════════════
            if ($directMembersExists) {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Step 3/3: Building materialized permission table..." -ForegroundColor Cyan

                try {
                    # Build UNION ALL dynamically based on available tables
                    $unionParts = @()
                    $unionParts += "SELECT groupId, memberId, memberType, membershipType FROM #RecursiveMemberships"

                    if ($ownersExists) {
                        $unionParts += @"
SELECT resourceId AS groupId, principalId AS memberId, principalType AS memberType, 'Owner' AS membershipType
FROM dbo.ResourceAssignments WHERE assignmentType = 'Owner' AND ValidTo = '9999-12-31 23:59:59.9999999'
"@
                    }

                    if ($eligibleExists) {
                        $unionParts += @"
SELECT resourceId AS groupId, principalId AS memberId, principalType AS memberType, 'Eligible' AS membershipType
FROM dbo.ResourceAssignments WHERE assignmentType = 'Eligible' AND ValidTo = '9999-12-31 23:59:59.9999999'
"@
                    }

                    $unionAllSQL = $unionParts -join "`nUNION ALL`n"

                    # LEFT JOIN for managedByAccessPackage (replaces correlated EXISTS)
                    $apJoinSQL = ""
                    $apColumnSQL = "CAST(0 AS BIT) AS managedByAccessPackage"

                    if ($apViewExists) {
                        # Use the materialized AP table we just created in Step 1
                        $apJoinSQL = @"
LEFT JOIN (
    SELECT DISTINCT userId, groupId
    FROM dbo.mat_UserPermissionAssignmentViaBusinessRole
) ap ON ap.userId = a.memberId AND ap.groupId = a.groupId
"@
                        $apColumnSQL = "CAST(CASE WHEN ap.userId IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS managedByAccessPackage"
                    }

                    $cmd = $connection.CreateCommand()
                    $cmd.CommandTimeout = $CommandTimeout
                    $cmd.CommandText = @"
IF OBJECT_ID('dbo.mat_UserPermissionAssignments', 'U') IS NOT NULL
    DROP TABLE dbo.mat_UserPermissionAssignments;

SELECT
    a.groupId,
    a.memberId,
    a.memberType,
    a.membershipType,
    $apColumnSQL
INTO dbo.mat_UserPermissionAssignments
FROM (
    $unionAllSQL
) a
$apJoinSQL;

CREATE NONCLUSTERED INDEX IX_mat_UPA_memberId
    ON dbo.mat_UserPermissionAssignments (memberId)
    INCLUDE (groupId, memberType, membershipType, managedByAccessPackage);

CREATE NONCLUSTERED INDEX IX_mat_UPA_groupId
    ON dbo.mat_UserPermissionAssignments (groupId)
    INCLUDE (memberId, memberType, membershipType);

CREATE NONCLUSTERED INDEX IX_mat_UPA_memberType
    ON dbo.mat_UserPermissionAssignments (memberType)
    INCLUDE (memberId, groupId);

DROP TABLE #RecursiveMemberships;
"@
                    $cmd.ExecuteNonQuery() | Out-Null

                    $countCmd = $connection.CreateCommand()
                    $countCmd.CommandTimeout = 120
                    $countCmd.CommandText = "SELECT COUNT(*) FROM dbo.mat_UserPermissionAssignments"
                    $rowCount = $countCmd.ExecuteScalar()

                    Write-Host "    Materialized mat_UserPermissionAssignments: $rowCount rows" -ForegroundColor Green
                    $materialized++
                }
                catch {
                    Write-Host "    Step 3 FAILED (build permission table): $_" -ForegroundColor Red
                    Write-Host "    Consider scaling up the Azure SQL tier or increasing -CommandTimeout." -ForegroundColor Yellow
                }
            }
        }
        else {
            Write-Warning "  Table GraphGroupMembers does not exist. Run Sync-FGGroupMember first."
        }

        # ═══════════════════════════════════════════════════════════════
        # Step 4: Update statistics + pre-compute user counts
        # SELECT INTO doesn't create statistics, so the query optimizer
        # chooses terrible plans. Also pre-compute per-user membership
        # counts so the UI doesn't need GROUP BY on every page load.
        # ═══════════════════════════════════════════════════════════════
        if ($materialized -gt 0) {
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Step 4: Updating statistics and building user counts..." -ForegroundColor Cyan

            try {
                $cmd = $connection.CreateCommand()
                $cmd.CommandTimeout = $CommandTimeout
                $cmd.CommandText = @"
-- Update statistics so the query optimizer has accurate data distribution info
UPDATE STATISTICS dbo.mat_UserPermissionAssignments;

-- Pre-compute per-user membership counts (eliminates GROUP BY from every API request)
IF OBJECT_ID('dbo.mat_UserCounts', 'U') IS NOT NULL
    DROP TABLE dbo.mat_UserCounts;

SELECT memberId, COUNT(*) AS cnt
INTO dbo.mat_UserCounts
FROM dbo.mat_UserPermissionAssignments
WHERE memberType != '#microsoft.graph.group'
GROUP BY memberId;

CREATE CLUSTERED INDEX IX_mat_UC_cnt_desc
    ON dbo.mat_UserCounts (cnt DESC, memberId);

CREATE NONCLUSTERED INDEX IX_mat_UC_memberId
    ON dbo.mat_UserCounts (memberId)
    INCLUDE (cnt);

UPDATE STATISTICS dbo.mat_UserCounts;
"@
                $cmd.ExecuteNonQuery() | Out-Null

                $countCmd = $connection.CreateCommand()
                $countCmd.CommandTimeout = 120
                $countCmd.CommandText = "SELECT COUNT(*) FROM dbo.mat_UserCounts"
                $userCountRows = $countCmd.ExecuteScalar()

                Write-Host "    Updated statistics and built mat_UserCounts: $userCountRows users" -ForegroundColor Green
            }
            catch {
                Write-Host "    Step 4 FAILED (statistics/user counts): $_" -ForegroundColor Red
                Write-Host "    Continuing — UI will fall back to GROUP BY." -ForegroundColor Yellow
            }
        }

        # Update statistics on AP table too if it was materialized
        if ($apViewExists) {
            try {
                $cmd = $connection.CreateCommand()
                $cmd.CommandTimeout = 300
                $cmd.CommandText = "UPDATE STATISTICS dbo.mat_UserPermissionAssignmentViaBusinessRole"
                $cmd.ExecuteNonQuery() | Out-Null
            }
            catch {
                Write-Host "    AP statistics update failed (non-critical): $_" -ForegroundColor Yellow
            }
        }

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Materialization complete: $materialized table(s) refreshed" -ForegroundColor Green

        return @{
            MaterializedTables = $materialized
        }
    }

    $syncRecordCount = $result.MaterializedTables
    $syncStatus = if ($syncRecordCount -ge 2) { "Success" } elseif ($syncRecordCount -ge 1) { "PartialSuccess" } else { "Failed" }

    } # End try
    catch {
        $syncErrorMessage = $_.Exception.Message
        $syncStatus = "Failed"
        throw
    }
    finally {
        Write-FGSyncLog -SyncType "MaterializedViews" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName "mat_UserPermissionAssignments"
    }
}
