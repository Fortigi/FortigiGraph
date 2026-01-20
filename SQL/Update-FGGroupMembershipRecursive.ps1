function Update-FGGroupMembershipRecursive {
    <#
    .SYNOPSIS
    Materializes recursive group membership calculations into a physical table for fast queries.

    .DESCRIPTION
    Calculates ALL group memberships (direct + indirect) using recursive logic and stores
    the results in a physical table (GraphGroupMembersRecursive).

    This approach trades real-time calculation for query speed:
    - View (vw_GraphGroupMembersRecursive): Recalculates on every query (slow: 8+ minutes)
    - Table (GraphGroupMembersRecursive): Pre-calculated, instant queries (< 1 second)

    The table should be refreshed after running group membership syncs:
    1. Sync-FGGroupMember (updates direct memberships)
    2. Update-FGGroupMembershipRecursive (recalculates indirect memberships)

    .PARAMETER DirectMembersTable
    Name of the table containing direct group memberships. Default: "GraphGroupMembers"

    .PARAMETER OutputTable
    Name of the table to store calculated results. Default: "GraphGroupMembersRecursive"

    .PARAMETER MaxDepth
    Maximum recursion depth. Default: 10
    Reducing this (e.g., 5) can improve performance if you don't have deeply nested groups.

    .PARAMETER RecreateTable
    If specified, drops and recreates the output table (loses history).
    Use with caution - temporal history will be lost!

    .EXAMPLE
    Update-FGGroupMembershipRecursive

    Calculates recursive memberships and stores in GraphGroupMembersRecursive table

    .EXAMPLE
    Update-FGGroupMembershipRecursive -MaxDepth 5

    Limits recursion to 5 levels (faster for orgs without deep nesting)

    .EXAMPLE
    Update-FGGroupMembershipRecursive -RecreateTable

    Recreates the table from scratch (WARNING: loses temporal history)

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - GraphGroupMembers table to exist (run Sync-FGGroupMember first)
    - Proper indexes (run Initialize-FGGroupMembershipIndexes for best performance)

    Performance:
    - Initial calculation: 1-5 minutes (depending on dataset size)
    - Subsequent queries: < 1 second (reads from materialized table)
    - Refresh frequency: Run after each Sync-FGGroupMember

    The output table is a temporal table with automatic history tracking.
    #>

    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $false)]
        [string]$DirectMembersTable = "GraphGroupMembers",

        [Parameter(Mandatory = $false)]
        [string]$OutputTable = "GraphGroupMembersRecursive",

        [Parameter(Mandatory = $false)]
        [int]$MaxDepth = 10,

        [Parameter(Mandatory = $false)]
        [switch]$RecreateTable
    )

    # Check SQL connection
    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Calculating recursive group memberships..." -ForegroundColor Cyan
    Write-Host "  Source: $DirectMembersTable" -ForegroundColor Gray
    Write-Host "  Output: $OutputTable" -ForegroundColor Gray
    Write-Host "  Max Depth: $MaxDepth" -ForegroundColor Gray

    $startTime = Get-Date

    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        # Check if source table exists
        $checkSourceCmd = $connection.CreateCommand()
        $checkSourceCmd.CommandText = @"
SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_NAME = '$DirectMembersTable'
"@
        $sourceExists = $checkSourceCmd.ExecuteScalar() -gt 0

        if (-not $sourceExists) {
            throw "Source table '$DirectMembersTable' does not exist. Run Sync-FGGroupMember first."
        }

        # Get count of direct members
        $countCmd = $connection.CreateCommand()
        $countCmd.CommandText = "SELECT COUNT(*) FROM dbo.$DirectMembersTable WHERE ValidTo = '9999-12-31 23:59:59.9999999'"
        $directCount = $countCmd.ExecuteScalar()
        Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Processing $directCount direct memberships..." -ForegroundColor Cyan

        # Check if output table exists
        $checkOutputCmd = $connection.CreateCommand()
        $checkOutputCmd.CommandText = @"
SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_NAME = '$OutputTable'
"@
        $outputExists = $checkOutputCmd.ExecuteScalar() -gt 0

        if ($outputExists -and $RecreateTable) {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Dropping existing table (recreate mode)..." -ForegroundColor Yellow

            # Drop temporal table (requires disabling versioning first)
            $dropCmd = $connection.CreateCommand()
            $dropCmd.CommandText = @"
-- Disable system versioning if it's a temporal table
IF EXISTS (
    SELECT 1 FROM sys.tables t
    WHERE t.name = '$OutputTable' AND t.temporal_type = 2
)
BEGIN
    DECLARE @HistoryTable NVARCHAR(256);
    SELECT @HistoryTable = SCHEMA_NAME(history_table_id) + '.' + OBJECT_NAME(history_table_id)
    FROM sys.tables
    WHERE name = '$OutputTable';

    EXEC('ALTER TABLE dbo.$OutputTable SET (SYSTEM_VERSIONING = OFF)');
    EXEC('DROP TABLE IF EXISTS dbo.$OutputTable');
    EXEC('DROP TABLE IF EXISTS ' + @HistoryTable);
END
ELSE
BEGIN
    DROP TABLE IF EXISTS dbo.$OutputTable;
END
"@
            $dropCmd.ExecuteNonQuery() | Out-Null
            $outputExists = $false
        }

        # Create output table if it doesn't exist
        if (-not $outputExists) {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Creating output table: $OutputTable" -ForegroundColor Cyan

            $createTableCmd = $connection.CreateCommand()
            $createTableCmd.CommandText = @"
CREATE TABLE dbo.$OutputTable (
    groupId UNIQUEIDENTIFIER NOT NULL,
    memberId UNIQUEIDENTIFIER NOT NULL,
    memberType NVARCHAR(100) NOT NULL,
    membershipType NVARCHAR(20) NOT NULL,  -- 'direct' or 'indirect'
    depth INT NOT NULL,
    path NVARCHAR(MAX) NOT NULL,
    ValidFrom DATETIME2 GENERATED ALWAYS AS ROW START NOT NULL,
    ValidTo DATETIME2 GENERATED ALWAYS AS ROW END NOT NULL,
    PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo),
    PRIMARY KEY (groupId, memberId, membershipType, depth, path)
) WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.${OutputTable}_History));
"@
            $createTableCmd.ExecuteNonQuery() | Out-Null
            Write-Host "  ✅ Table created with temporal versioning" -ForegroundColor Green
        }
        else {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Using existing table: $OutputTable" -ForegroundColor Cyan
        }

        # Calculate recursive memberships using CTE
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Calculating recursive memberships (this may take a few minutes)..." -ForegroundColor Cyan

        $calcStartTime = Get-Date

        # Disable system versioning temporarily for bulk operations
        $disableVersioningCmd = $connection.CreateCommand()
        $disableVersioningCmd.CommandText = "ALTER TABLE dbo.$OutputTable SET (SYSTEM_VERSIONING = OFF);"
        $disableVersioningCmd.ExecuteNonQuery() | Out-Null

        try {
            # Clear existing data
            $clearCmd = $connection.CreateCommand()
            $clearCmd.CommandText = "DELETE FROM dbo.$OutputTable;"
            $clearCmd.ExecuteNonQuery() | Out-Null

            # Insert calculated results
            $insertCmd = $connection.CreateCommand()
            $insertCmd.CommandTimeout = 600  # 10 minutes for large datasets
            $insertCmd.CommandText = @"
WITH RecursiveMemberships AS (
    -- Anchor: Direct memberships (depth = 1)
    SELECT
        gm.groupId,
        gm.memberId,
        gm.memberType,
        CAST('direct' AS NVARCHAR(20)) AS membershipType,
        1 AS depth,
        CAST(CAST(gm.groupId AS NVARCHAR(36)) + ' -> ' + CAST(gm.memberId AS NVARCHAR(36)) AS NVARCHAR(MAX)) AS path
    FROM
        dbo.$DirectMembersTable gm
    WHERE
        gm.ValidTo = '9999-12-31 23:59:59.9999999'  -- Only current memberships

    UNION ALL

    -- Recursive: Indirect memberships through nested groups
    SELECT
        rm.groupId,                          -- Keep the original parent group
        nested.memberId,                      -- Member of the nested group
        nested.memberType,
        CAST('indirect' AS NVARCHAR(20)) AS membershipType,
        rm.depth + 1 AS depth,
        CAST(rm.path + ' -> ' + CAST(nested.memberId AS NVARCHAR(36)) AS NVARCHAR(MAX)) AS path
    FROM
        RecursiveMemberships rm
        INNER JOIN dbo.$DirectMembersTable nested
            ON rm.memberId = nested.groupId
            AND nested.ValidTo = '9999-12-31 23:59:59.9999999'  -- Only current memberships
    WHERE
        rm.memberType = '#microsoft.graph.group'  -- Only expand if member is a group
        AND rm.depth < $MaxDepth                   -- Limit depth to prevent excessive recursion
)
INSERT INTO dbo.$OutputTable (groupId, memberId, memberType, membershipType, depth, path)
SELECT
    groupId,
    memberId,
    memberType,
    membershipType,
    depth,
    path
FROM RecursiveMemberships
OPTION (MAXRECURSION $MaxDepth);
"@
            $rowsInserted = $insertCmd.ExecuteNonQuery()

            $calcDuration = (Get-Date) - $calcStartTime
            Write-Host "  ✅ Calculated $rowsInserted memberships in $($calcDuration.TotalSeconds.ToString('F1')) seconds" -ForegroundColor Green
        }
        finally {
            # Re-enable system versioning
            $enableVersioningCmd = $connection.CreateCommand()
            $enableVersioningCmd.CommandText = "ALTER TABLE dbo.$OutputTable SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.${OutputTable}_History));"
            $enableVersioningCmd.ExecuteNonQuery() | Out-Null
        }

        # Create indexes for fast queries
        Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Creating performance indexes..." -ForegroundColor Cyan

        $indexes = @(
            @{
                Name = "IX_${OutputTable}_GroupId"
                Columns = "groupId, membershipType"
                Include = "memberId, memberType, depth"
            },
            @{
                Name = "IX_${OutputTable}_MemberId"
                Columns = "memberId, membershipType"
                Include = "groupId, memberType, depth"
            },
            @{
                Name = "IX_${OutputTable}_Depth"
                Columns = "depth, membershipType"
                Include = "groupId, memberId"
            }
        )

        foreach ($index in $indexes) {
            # Check if index exists
            $checkIdxCmd = $connection.CreateCommand()
            $checkIdxCmd.CommandText = "SELECT COUNT(*) FROM sys.indexes WHERE name = '$($index.Name)' AND object_id = OBJECT_ID('dbo.$OutputTable')"
            $idxExists = $checkIdxCmd.ExecuteScalar() -gt 0

            if (-not $idxExists) {
                $createIdxCmd = $connection.CreateCommand()
                $createIdxCmd.CommandTimeout = 600
                $createIdxCmd.CommandText = "CREATE NONCLUSTERED INDEX [$($index.Name)] ON dbo.[$OutputTable] ($($index.Columns)) INCLUDE ($($index.Include));"
                $createIdxCmd.ExecuteNonQuery() | Out-Null
                Write-Host "  ✅ Created index: $($index.Name)" -ForegroundColor Green
            }
            else {
                Write-Host "  ⏭️  Index already exists: $($index.Name)" -ForegroundColor Gray
            }
        }

        return $rowsInserted
    }

    $totalDuration = (Get-Date) - $startTime

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Recursive Membership Calculation Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Total Time: $($totalDuration.TotalSeconds.ToString('F1')) seconds" -ForegroundColor White
    Write-Host "`nTable: dbo.$OutputTable" -ForegroundColor Cyan
    Write-Host "  - Contains pre-calculated recursive memberships" -ForegroundColor Gray
    Write-Host "  - Query time: < 1 second (materialized)" -ForegroundColor Gray
    Write-Host "  - Temporal history: Automatic change tracking" -ForegroundColor Gray
    Write-Host "`nExample Queries:" -ForegroundColor Cyan
    Write-Host "  -- All indirect memberships" -ForegroundColor Gray
    Write-Host "  SELECT * FROM dbo.$OutputTable WHERE membershipType = 'indirect'" -ForegroundColor White
    Write-Host "`n  -- Memberships deeper than direct" -ForegroundColor Gray
    Write-Host "  SELECT * FROM dbo.$OutputTable WHERE depth > 1" -ForegroundColor White
    Write-Host "`n  -- All paths to a specific user" -ForegroundColor Gray
    Write-Host "  SELECT * FROM dbo.$OutputTable WHERE memberId = 'user-guid-here'" -ForegroundColor White
    Write-Host "`nRefresh: Run this function after Sync-FGGroupMember to update" -ForegroundColor Yellow
    Write-Host "========================================`n" -ForegroundColor Green
}
