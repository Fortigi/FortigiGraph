function Initialize-FGGroupMembershipViews {
    <#
    .SYNOPSIS
    Creates helpful SQL views for analyzing group memberships (direct vs nested/transitive).

    .DESCRIPTION
    Creates two views that make it easy to work with group membership data:

    1. vw_GraphGroupNestedMembers
       - Shows ONLY members who have access through nested groups (not direct members)
       - Useful for finding indirect access paths

    2. vw_GraphGroupMembershipType
       - Shows ALL members with an indicator of Direct vs Indirect membership
       - Combines data from both GraphGroupMembers and GraphGroupTransitiveMembers
       - Includes memberType for filtering by user/group/device/etc

    .PARAMETER DirectMembersTable
    Name of the table containing direct group memberships. Default: "GraphGroupMembers"

    .PARAMETER TransitiveMembersTable
    Name of the table containing transitive group memberships. Default: "GraphGroupTransitiveMembers"

    .PARAMETER DropIfExists
    If specified, drops existing views before creating new ones

    .EXAMPLE
    Initialize-FGGroupMembershipViews

    Creates both membership analysis views using default table names

    .EXAMPLE
    Initialize-FGGroupMembershipViews -DropIfExists

    Recreates the views (drops existing ones first)

    .EXAMPLE
    Initialize-FGGroupMembershipViews -DirectMembersTable "CustomGroupMembers" -TransitiveMembersTable "CustomTransitiveMembers"

    Creates views using custom table names

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - GraphGroupMembers table to exist (run Sync-FGGroupMember first)
    - GraphGroupTransitiveMembers table to exist (run Sync-FGGroupTransitiveMember first)

    Views Created:
    - vw_GraphGroupNestedMembers: Only indirect/nested members
    - vw_GraphGroupMembershipType: All members with Direct/Indirect indicator
    #>

    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $false)]
        [string]$DirectMembersTable = "GraphGroupMembers",

        [Parameter(Mandatory = $false)]
        [string]$TransitiveMembersTable = "GraphGroupTransitiveMembers",

        [Parameter(Mandatory = $false)]
        [switch]$DropIfExists
    )

    # Check SQL connection
    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Creating group membership analysis views..." -ForegroundColor Cyan

    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        # Check if source tables exist
        $checkTablesCmd = $connection.CreateCommand()
        $checkTablesCmd.CommandText = @"
SELECT
    CASE WHEN EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = '$DirectMembersTable') THEN 1 ELSE 0 END AS DirectExists,
    CASE WHEN EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = '$TransitiveMembersTable') THEN 1 ELSE 0 END AS TransitiveExists
"@
        $reader = $checkTablesCmd.ExecuteReader()
        $reader.Read()
        $directExists = $reader.GetInt32(0) -eq 1
        $transitiveExists = $reader.GetInt32(1) -eq 1
        $reader.Close()

        if (-not $directExists) {
            Write-Warning "Table '$DirectMembersTable' does not exist. Run Sync-FGGroupMember first."
        }
        if (-not $transitiveExists) {
            Write-Warning "Table '$TransitiveMembersTable' does not exist. Run Sync-FGGroupTransitiveMember first."
        }

        if (-not $directExists -or -not $transitiveExists) {
            throw "Required tables do not exist. Please run Sync-FGGroupMember and Sync-FGGroupTransitiveMember first."
        }

        # View 1: Nested Members Only (Indirect access)
        Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Creating view: vw_GraphGroupNestedMembers" -ForegroundColor Cyan
        Write-Host "  Purpose: Shows only members with indirect/nested access (not direct members)" -ForegroundColor Gray

        if ($DropIfExists) {
            $dropView1Cmd = $connection.CreateCommand()
            $dropView1Cmd.CommandText = "IF EXISTS (SELECT * FROM sys.views WHERE name = 'vw_GraphGroupNestedMembers') DROP VIEW dbo.vw_GraphGroupNestedMembers;"
            $dropView1Cmd.ExecuteNonQuery() | Out-Null
        }

        $createView1SQL = @"
CREATE VIEW dbo.vw_GraphGroupNestedMembers AS
SELECT
    t.groupId,
    t.memberId,
    t.memberType,
    t.ValidFrom,
    t.ValidTo
FROM dbo.$TransitiveMembersTable t
LEFT JOIN dbo.$DirectMembersTable d
    ON t.groupId = d.groupId
    AND t.memberId = d.memberId
    AND d.ValidTo = '9999-12-31 23:59:59.9999999'  -- Only current direct members
WHERE d.memberId IS NULL  -- Not in direct members = nested only
    AND t.ValidTo = '9999-12-31 23:59:59.9999999';  -- Only current records
"@

        $createView1Cmd = $connection.CreateCommand()
        $createView1Cmd.CommandText = $createView1SQL
        $createView1Cmd.ExecuteNonQuery() | Out-Null
        Write-Host "  ✅ Created: vw_GraphGroupNestedMembers" -ForegroundColor Green

        # View 2: All Members with Membership Type Indicator
        Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Creating view: vw_GraphGroupMembershipType" -ForegroundColor Cyan
        Write-Host "  Purpose: Shows all members with Direct/Indirect indicator" -ForegroundColor Gray

        if ($DropIfExists) {
            $dropView2Cmd = $connection.CreateCommand()
            $dropView2Cmd.CommandText = "IF EXISTS (SELECT * FROM sys.views WHERE name = 'vw_GraphGroupMembershipType') DROP VIEW dbo.vw_GraphGroupMembershipType;"
            $dropView2Cmd.ExecuteNonQuery() | Out-Null
        }

        $createView2SQL = @"
CREATE VIEW dbo.vw_GraphGroupMembershipType AS
SELECT
    t.groupId,
    t.memberId,
    t.memberType,
    CASE
        WHEN d.memberId IS NOT NULL THEN 'Direct'
        ELSE 'Indirect'
    END AS membershipType,
    t.ValidFrom,
    t.ValidTo
FROM dbo.$TransitiveMembersTable t
LEFT JOIN dbo.$DirectMembersTable d
    ON t.groupId = d.groupId
    AND t.memberId = d.memberId
    AND d.ValidTo = '9999-12-31 23:59:59.9999999'  -- Only current direct members
WHERE t.ValidTo = '9999-12-31 23:59:59.9999999';  -- Only current records
"@

        $createView2Cmd = $connection.CreateCommand()
        $createView2Cmd.CommandText = $createView2SQL
        $createView2Cmd.ExecuteNonQuery() | Out-Null
        Write-Host "  ✅ Created: vw_GraphGroupMembershipType" -ForegroundColor Green

        Write-Host "`n========================================" -ForegroundColor Green
        Write-Host "Views Created Successfully!" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "View 1: vw_GraphGroupNestedMembers" -ForegroundColor White
        Write-Host "  - Shows only indirect/nested members" -ForegroundColor Gray
        Write-Host "  - Excludes direct members" -ForegroundColor Gray
        Write-Host "`nView 2: vw_GraphGroupMembershipType" -ForegroundColor White
        Write-Host "  - Shows all members (direct + indirect)" -ForegroundColor Gray
        Write-Host "  - Includes membershipType column (Direct/Indirect)" -ForegroundColor Gray
        Write-Host "========================================`n" -ForegroundColor Green

        return $true
    }
}
