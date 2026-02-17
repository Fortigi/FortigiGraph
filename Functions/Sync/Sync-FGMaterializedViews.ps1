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

        # Check which views exist
        $checkCmd = $connection.CreateCommand()
        $checkCmd.CommandText = @"
SELECT
    CASE WHEN EXISTS (SELECT 1 FROM sys.views WHERE name = 'vw_UserPermissionAssignments') THEN 1 ELSE 0 END AS PermViewExists,
    CASE WHEN EXISTS (SELECT 1 FROM sys.views WHERE name = 'vw_UserPermissionAssignmentViaAccessPackage') THEN 1 ELSE 0 END AS ApViewExists
"@
        $reader = $checkCmd.ExecuteReader()
        $reader.Read()
        $permViewExists = $reader.GetInt32(0) -eq 1
        $apViewExists = $reader.GetInt32(1) -eq 1
        $reader.Close()

        $materialized = 0

        # Materialize vw_UserPermissionAssignments
        if ($permViewExists) {
            Write-Host "  Materializing vw_UserPermissionAssignments..." -ForegroundColor Cyan

            $cmd = $connection.CreateCommand()
            $cmd.CommandTimeout = 600  # 10 minutes for large datasets
            $cmd.CommandText = @"
-- Drop existing materialized table
IF OBJECT_ID('dbo.mat_UserPermissionAssignments', 'U') IS NOT NULL
    DROP TABLE dbo.mat_UserPermissionAssignments;

-- Materialize from view
SELECT *
INTO dbo.mat_UserPermissionAssignments
FROM dbo.vw_UserPermissionAssignments;

-- Create indexes for common query patterns
CREATE NONCLUSTERED INDEX IX_mat_UPA_memberId
    ON dbo.mat_UserPermissionAssignments (memberId)
    INCLUDE (groupId, memberType, membershipType, managedByAccessPackage);

CREATE NONCLUSTERED INDEX IX_mat_UPA_groupId
    ON dbo.mat_UserPermissionAssignments (groupId)
    INCLUDE (memberId, memberType, membershipType);

CREATE NONCLUSTERED INDEX IX_mat_UPA_memberType
    ON dbo.mat_UserPermissionAssignments (memberType)
    INCLUDE (memberId, groupId);
"@
            $cmd.ExecuteNonQuery() | Out-Null

            $countCmd = $connection.CreateCommand()
            $countCmd.CommandText = "SELECT COUNT(*) FROM dbo.mat_UserPermissionAssignments"
            $rowCount = $countCmd.ExecuteScalar()

            Write-Host "  Materialized mat_UserPermissionAssignments: $rowCount rows" -ForegroundColor Green
            $materialized++
        }
        else {
            Write-Warning "  View vw_UserPermissionAssignments does not exist. Run Initialize-FGGroupMembershipViews first."
        }

        # Materialize vw_UserPermissionAssignmentViaAccessPackage
        if ($apViewExists) {
            Write-Host "  Materializing vw_UserPermissionAssignmentViaAccessPackage..." -ForegroundColor Cyan

            $cmd = $connection.CreateCommand()
            $cmd.CommandTimeout = 600
            $cmd.CommandText = @"
-- Drop existing materialized table
IF OBJECT_ID('dbo.mat_UserPermissionAssignmentViaAccessPackage', 'U') IS NOT NULL
    DROP TABLE dbo.mat_UserPermissionAssignmentViaAccessPackage;

-- Materialize from view
SELECT *
INTO dbo.mat_UserPermissionAssignmentViaAccessPackage
FROM dbo.vw_UserPermissionAssignmentViaAccessPackage;

-- Create indexes for UI query patterns
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

            Write-Host "  Materialized mat_UserPermissionAssignmentViaAccessPackage: $rowCount rows" -ForegroundColor Green
            $materialized++
        }
        else {
            Write-Host "  View vw_UserPermissionAssignmentViaAccessPackage does not exist (optional)" -ForegroundColor Yellow
        }

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Materialization complete: $materialized table(s) refreshed" -ForegroundColor Green

        return @{
            MaterializedTables = $materialized
        }
    }
}
