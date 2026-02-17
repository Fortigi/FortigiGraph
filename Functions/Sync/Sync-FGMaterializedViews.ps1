function Sync-FGMaterializedViews {
    <#
    .SYNOPSIS
    Materializes analysis views into tables for fast UI queries.

    .DESCRIPTION
    Converts the complex analysis views (vw_UserPermissionAssignments and
    vw_UserPermissionAssignmentViaAccessPackage) into physical tables with indexes.
    This eliminates the expensive recursive CTE and EXISTS subqueries that run on
    every API request, reducing query time from minutes to milliseconds.

    The materialized tables use the "mat_" prefix:
    - mat_UserPermissionAssignments (from vw_UserPermissionAssignments)
    - mat_UserPermissionAssignmentViaAccessPackage (from vw_UserPermissionAssignmentViaAccessPackage)

    The UI backend automatically detects and prefers materialized tables, falling
    back to the views if they don't exist.

    Performance optimizations over direct SELECT * INTO FROM view:
    - Multi-step materialization: recursive CTE -> temp table -> final table
    - Skips path and ValidFrom/ValidTo columns (not used by UI, avoids NVARCHAR(MAX) LOB overhead)
    - Uses LEFT JOIN instead of correlated EXISTS for managedByAccessPackage (set-based vs row-by-row)
    - Materializes AP table first, then uses it for the managed check

    .EXAMPLE
    Sync-FGMaterializedViews

    Materializes all available views into indexed tables.

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
    Param()

    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Materializing views for UI performance..." -ForegroundColor Cyan

        # Check which views and source tables exist
        $checkCmd = $connection.CreateCommand()
        $checkCmd.CommandText = @"
SELECT
    CASE WHEN EXISTS (SELECT 1 FROM sys.views WHERE name = 'vw_UserPermissionAssignmentViaAccessPackage') THEN 1 ELSE 0 END AS ApViewExists,
    CASE WHEN EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'GraphGroupMembers') THEN 1 ELSE 0 END AS DirectMembersExists,
    CASE WHEN EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'GraphGroupOwners') THEN 1 ELSE 0 END AS OwnersExists,
    CASE WHEN EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'GraphGroupEligibleMembers') THEN 1 ELSE 0 END AS EligibleExists
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
        # Step 1: Materialize vw_UserPermissionAssignmentViaAccessPackage
        # Simple 6-table join, no recursion — materialize first so we can
        # use it for the managedByAccessPackage LEFT JOIN in step 2.
        # ═══════════════════════════════════════════════════════════════
        if ($apViewExists) {
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Step 1/3: Materializing AP permissions..." -ForegroundColor Cyan

            $cmd = $connection.CreateCommand()
            $cmd.CommandTimeout = 300  # 5 minutes
            $cmd.CommandText = @"
IF OBJECT_ID('dbo.mat_UserPermissionAssignmentViaAccessPackage', 'U') IS NOT NULL
    DROP TABLE dbo.mat_UserPermissionAssignmentViaAccessPackage;

SELECT *
INTO dbo.mat_UserPermissionAssignmentViaAccessPackage
FROM dbo.vw_UserPermissionAssignmentViaAccessPackage;

CREATE NONCLUSTERED INDEX IX_mat_UPAVAP_userId_groupId
    ON dbo.mat_UserPermissionAssignmentViaAccessPackage (userId, groupId)
    INCLUDE (accessPackageId);

CREATE NONCLUSTERED INDEX IX_mat_UPAVAP_accessPackageId
    ON dbo.mat_UserPermissionAssignmentViaAccessPackage (accessPackageId);
"@
            $cmd.ExecuteNonQuery() | Out-Null

            $countCmd = $connection.CreateCommand()
            $countCmd.CommandText = "SELECT COUNT(*) FROM dbo.mat_UserPermissionAssignmentViaAccessPackage"
            $rowCount = $countCmd.ExecuteScalar()

            Write-Host "    Materialized mat_UserPermissionAssignmentViaAccessPackage: $rowCount rows" -ForegroundColor Green
            $materialized++
        }
        else {
            Write-Host "  View vw_UserPermissionAssignmentViaAccessPackage does not exist (optional)" -ForegroundColor Yellow
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

            $cmd = $connection.CreateCommand()
            $cmd.CommandTimeout = 600  # 10 minutes for large tenants
            $cmd.CommandText = @"
IF OBJECT_ID('tempdb..#RecursiveMemberships') IS NOT NULL DROP TABLE #RecursiveMemberships;

;WITH RecursiveMemberships AS (
    -- Anchor: Direct memberships
    SELECT
        gm.groupId,
        gm.memberId,
        gm.memberType,
        CAST('Direct' AS NVARCHAR(20)) AS membershipType,
        1 AS depth
    FROM dbo.GraphGroupMembers gm
    WHERE gm.ValidTo = '9999-12-31 23:59:59.9999999'

    UNION ALL

    -- Recursive: Indirect memberships through nested groups
    SELECT
        rm.groupId,
        gm2.memberId,
        gm2.memberType,
        CAST('Indirect' AS NVARCHAR(20)) AS membershipType,
        rm.depth + 1
    FROM RecursiveMemberships rm
    INNER JOIN dbo.GraphGroupMembers gm2
        ON rm.memberId = gm2.groupId
        AND gm2.ValidTo = '9999-12-31 23:59:59.9999999'
    WHERE rm.memberType = '#microsoft.graph.group'
        AND rm.depth < 10
)
SELECT groupId, memberId, memberType, membershipType
INTO #RecursiveMemberships
FROM RecursiveMemberships
OPTION (MAXRECURSION 100);
"@
            $cmd.ExecuteNonQuery() | Out-Null

            $countCmd = $connection.CreateCommand()
            $countCmd.CommandText = "SELECT COUNT(*) FROM #RecursiveMemberships"
            $recursiveCount = $countCmd.ExecuteScalar()
            Write-Host "    Recursive memberships computed: $recursiveCount rows" -ForegroundColor Green

            # ═══════════════════════════════════════════════════════════════
            # Step 3: Build final materialized table from temp + owners + eligible
            # Uses LEFT JOIN against materialized AP table for managedByAccessPackage
            # instead of correlated EXISTS (set-based vs row-by-row).
            # ═══════════════════════════════════════════════════════════════
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Step 3/3: Building materialized permission table..." -ForegroundColor Cyan

            # Build UNION ALL dynamically based on available tables
            $unionParts = @()
            $unionParts += "SELECT groupId, memberId, memberType, membershipType FROM #RecursiveMemberships"

            if ($ownersExists) {
                $unionParts += @"
SELECT groupId, ownerId AS memberId, 'user' AS memberType, 'Owner' AS membershipType
FROM dbo.GraphGroupOwners WHERE ValidTo = '9999-12-31 23:59:59.9999999'
"@
            }

            if ($eligibleExists) {
                $unionParts += @"
SELECT groupId, memberId, memberType, 'Eligible' AS membershipType
FROM dbo.GraphGroupEligibleMembers WHERE ValidTo = '9999-12-31 23:59:59.9999999'
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
    FROM dbo.mat_UserPermissionAssignmentViaAccessPackage
) ap ON ap.userId = a.memberId AND ap.groupId = a.groupId
"@
                $apColumnSQL = "CAST(CASE WHEN ap.userId IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS managedByAccessPackage"
            }

            $cmd = $connection.CreateCommand()
            $cmd.CommandTimeout = 600  # 10 minutes
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
            $countCmd.CommandText = "SELECT COUNT(*) FROM dbo.mat_UserPermissionAssignments"
            $rowCount = $countCmd.ExecuteScalar()

            Write-Host "    Materialized mat_UserPermissionAssignments: $rowCount rows" -ForegroundColor Green
            $materialized++
        }
        else {
            Write-Warning "  Table GraphGroupMembers does not exist. Run Sync-FGGroupMember first."
        }

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Materialization complete: $materialized table(s) refreshed" -ForegroundColor Green

        return @{
            MaterializedTables = $materialized
        }
    }
}
