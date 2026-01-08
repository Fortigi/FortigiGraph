function Initialize-FGGroupMembershipViews {
    <#
    .SYNOPSIS
    Creates helpful SQL views for analyzing group memberships (direct, indirect, eligible, and owners).

    .DESCRIPTION
    Creates views that make it easy to work with group membership data:

    1. vw_GraphGroupNestedMembers
       - Shows ONLY members who have access through nested groups (not direct members)
       - Useful for finding indirect access paths

    2. vw_GraphGroupEligibleMembers
       - Shows ONLY eligible members (PIM eligible, not active)
       - Useful for finding who can activate membership

    3. vw_GraphGroupMembershipType
       - Shows ALL members with an indicator of Owner, Direct, Indirect, or Eligible membership
       - Combines data from Owners, Direct, Transitive, and Eligible members tables
       - Includes memberType for filtering by user/group/device/etc

    .PARAMETER DirectMembersTable
    Name of the table containing direct group memberships. Default: "GraphGroupMembers"

    .PARAMETER TransitiveMembersTable
    Name of the table containing transitive group memberships. Default: "GraphGroupTransitiveMembers"

    .PARAMETER EligibleMembersTable
    Name of the table containing eligible group memberships (PIM). Default: "GraphGroupEligibleMembers"

    .PARAMETER OwnersTable
    Name of the table containing group ownership relationships. Default: "GraphGroupOwners"

    .PARAMETER DropIfExists
    If specified, drops existing views before creating new ones

    .EXAMPLE
    Initialize-FGGroupMembershipViews

    Creates all membership analysis views using default table names

    .EXAMPLE
    Initialize-FGGroupMembershipViews -DropIfExists

    Recreates the views (drops existing ones first)

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - GraphGroupMembers table to exist (run Sync-FGGroupMember first)
    - GraphGroupTransitiveMembers table to exist (run Sync-FGGroupTransitiveMember first)
    - GraphGroupOwners table (optional, run Sync-FGGroupOwner for owner tracking)
    - GraphGroupEligibleMembers table (optional, run Sync-FGGroupEligibleMember for PIM)

    Views Created:
    - vw_GraphGroupNestedMembers: Only indirect/nested members
    - vw_GraphGroupEligibleMembers: Only eligible members (PIM - if table exists)
    - vw_GraphGroupMembershipType: All members with Owner/Direct/Indirect/Eligible indicator
    #>

    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $false)]
        [string]$DirectMembersTable = "GraphGroupMembers",

        [Parameter(Mandatory = $false)]
        [string]$TransitiveMembersTable = "GraphGroupTransitiveMembers",

        [Parameter(Mandatory = $false)]
        [string]$EligibleMembersTable = "GraphGroupEligibleMembers",

        [Parameter(Mandatory = $false)]
        [string]$OwnersTable = "GraphGroupOwners",

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
    CASE WHEN EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = '$TransitiveMembersTable') THEN 1 ELSE 0 END AS TransitiveExists,
    CASE WHEN EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = '$EligibleMembersTable') THEN 1 ELSE 0 END AS EligibleExists,
    CASE WHEN EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = '$OwnersTable') THEN 1 ELSE 0 END AS OwnersExists
"@
        $reader = $checkTablesCmd.ExecuteReader()
        $reader.Read()
        $directExists = $reader.GetInt32(0) -eq 1
        $transitiveExists = $reader.GetInt32(1) -eq 1
        $eligibleExists = $reader.GetInt32(2) -eq 1
        $ownersExists = $reader.GetInt32(3) -eq 1
        $reader.Close()

        if (-not $directExists) {
            Write-Warning "Table '$DirectMembersTable' does not exist. Run Sync-FGGroupMember first."
        }
        if (-not $transitiveExists) {
            Write-Warning "Table '$TransitiveMembersTable' does not exist. Run Sync-FGGroupTransitiveMember first."
        }
        if (-not $eligibleExists) {
            Write-Warning "Table '$EligibleMembersTable' does not exist. Run Sync-FGGroupEligibleMember for PIM support (optional)."
        }
        if (-not $ownersExists) {
            Write-Warning "Table '$OwnersTable' does not exist. Run Sync-FGGroupOwner to include owners in views (optional)."
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

        # View 2: Eligible Members Only (PIM eligible, not active)
        if ($eligibleExists) {
            Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Creating view: vw_GraphGroupEligibleMembers" -ForegroundColor Cyan
            Write-Host "  Purpose: Shows only eligible members (PIM - can activate membership)" -ForegroundColor Gray

            if ($DropIfExists) {
                $dropView2Cmd = $connection.CreateCommand()
                $dropView2Cmd.CommandText = "IF EXISTS (SELECT * FROM sys.views WHERE name = 'vw_GraphGroupEligibleMembers') DROP VIEW dbo.vw_GraphGroupEligibleMembers;"
                $dropView2Cmd.ExecuteNonQuery() | Out-Null
            }

            $createView2SQL = @"
CREATE VIEW dbo.vw_GraphGroupEligibleMembers AS
SELECT
    e.groupId,
    e.memberId,
    e.memberType,
    e.ValidFrom,
    e.ValidTo
FROM dbo.$EligibleMembersTable e
WHERE e.ValidTo = '9999-12-31 23:59:59.9999999';  -- Only current records
"@

            $createView2Cmd = $connection.CreateCommand()
            $createView2Cmd.CommandText = $createView2SQL
            $createView2Cmd.ExecuteNonQuery() | Out-Null
            Write-Host "  ✅ Created: vw_GraphGroupEligibleMembers" -ForegroundColor Green
        }
        else {
            Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Skipping vw_GraphGroupEligibleMembers (table doesn't exist)" -ForegroundColor Yellow
        }

        # View 3: All Members with Membership Type Indicator
        Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Creating view: vw_GraphGroupMembershipType" -ForegroundColor Cyan
        $types = @()
        if ($ownersExists) { $types += "Owner" }
        $types += "Direct"
        if ($eligibleExists) { $types += "Eligible" }
        $types += "Indirect"
        Write-Host "  Purpose: Shows all members with $($types -join '/') indicator" -ForegroundColor Gray

        if ($DropIfExists) {
            $dropView3Cmd = $connection.CreateCommand()
            $dropView3Cmd.CommandText = "IF EXISTS (SELECT * FROM sys.views WHERE name = 'vw_GraphGroupMembershipType') DROP VIEW dbo.vw_GraphGroupMembershipType;"
            $dropView3Cmd.ExecuteNonQuery() | Out-Null
        }

        # Build the view SQL based on which optional tables exist
        $createView3SQL = @"
CREATE VIEW dbo.vw_GraphGroupMembershipType AS
SELECT
    t.groupId,
    t.memberId,
    t.memberType,
    CASE
"@

        # Add owner check first if owners table exists
        if ($ownersExists) {
            $createView3SQL += @"

        WHEN o.ownerId IS NOT NULL THEN 'Owner'
"@
        }

        # Always check for direct membership
        $createView3SQL += @"

        WHEN d.memberId IS NOT NULL THEN 'Direct'
"@

        # Add eligible check if eligible table exists
        if ($eligibleExists) {
            $createView3SQL += @"

        WHEN e.memberId IS NOT NULL THEN 'Eligible'
"@
        }

        $createView3SQL += @"

        ELSE 'Indirect'
    END AS membershipType,
    t.ValidFrom,
    t.ValidTo
FROM dbo.$TransitiveMembersTable t
LEFT JOIN dbo.$DirectMembersTable d
    ON t.groupId = d.groupId
    AND t.memberId = d.memberId
    AND d.ValidTo = '9999-12-31 23:59:59.9999999'  -- Only current direct members
"@

        if ($ownersExists) {
            $createView3SQL += @"

LEFT JOIN dbo.$OwnersTable o
    ON t.groupId = o.groupId
    AND t.memberId = o.ownerId
    AND o.ValidTo = '9999-12-31 23:59:59.9999999'  -- Only current owners
"@
        }

        if ($eligibleExists) {
            $createView3SQL += @"

LEFT JOIN dbo.$EligibleMembersTable e
    ON t.groupId = e.groupId
    AND t.memberId = e.memberId
    AND e.ValidTo = '9999-12-31 23:59:59.9999999'  -- Only current eligible members
"@
        }

        $createView3SQL += @"

WHERE t.ValidTo = '9999-12-31 23:59:59.9999999'  -- Only current records
"@

        # Add UNION for eligible members not in transitive if eligible exists
        if ($eligibleExists) {
            $createView3SQL += @"


UNION

-- Add eligible members who are not in transitive members (eligible but not active)
SELECT
    e.groupId,
    e.memberId,
    e.memberType,
    'Eligible' AS membershipType,
    e.ValidFrom,
    e.ValidTo
FROM dbo.$EligibleMembersTable e
LEFT JOIN dbo.$TransitiveMembersTable t
    ON e.groupId = t.groupId
    AND e.memberId = t.memberId
    AND t.ValidTo = '9999-12-31 23:59:59.9999999'
WHERE e.ValidTo = '9999-12-31 23:59:59.9999999'
    AND t.memberId IS NULL  -- Not in active members
"@
        }

        # Add UNION for owners not in transitive if owners exists
        if ($ownersExists) {
            $createView3SQL += @"


UNION

-- Add owners who are not in transitive members (owner but not member)
SELECT
    o.groupId,
    o.ownerId AS memberId,
    '#microsoft.graph.user' AS memberType,  -- Owners are typically users
    'Owner' AS membershipType,
    o.ValidFrom,
    o.ValidTo
FROM dbo.$OwnersTable o
LEFT JOIN dbo.$TransitiveMembersTable t
    ON o.groupId = t.groupId
    AND o.ownerId = t.memberId
    AND t.ValidTo = '9999-12-31 23:59:59.9999999'
WHERE o.ValidTo = '9999-12-31 23:59:59.9999999'
    AND t.memberId IS NULL;  -- Not in members
"@
        }
        else {
            $createView3SQL += ";"
        }

        $createView3Cmd = $connection.CreateCommand()
        $createView3Cmd.CommandText = $createView3SQL
        $createView3Cmd.ExecuteNonQuery() | Out-Null
        Write-Host "  ✅ Created: vw_GraphGroupMembershipType" -ForegroundColor Green

        Write-Host "`n========================================" -ForegroundColor Green
        Write-Host "Views Created Successfully!" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "View 1: vw_GraphGroupNestedMembers" -ForegroundColor White
        Write-Host "  - Shows only indirect/nested members" -ForegroundColor Gray
        Write-Host "  - Excludes direct members" -ForegroundColor Gray

        if ($eligibleExists) {
            Write-Host "`nView 2: vw_GraphGroupEligibleMembers" -ForegroundColor White
            Write-Host "  - Shows only eligible members (PIM)" -ForegroundColor Gray
            Write-Host "  - Members who can activate access" -ForegroundColor Gray
        }

        Write-Host "`nView 3: vw_GraphGroupMembershipType" -ForegroundColor White
        $desc = @("direct", "indirect")
        if ($ownersExists) { $desc = @("owner") + $desc }
        if ($eligibleExists) { $desc += "eligible" }
        Write-Host "  - Shows all members ($($desc -join ' + '))" -ForegroundColor Gray

        $types = @("Direct", "Indirect")
        if ($ownersExists) { $types = @("Owner") + $types }
        if ($eligibleExists) { $types += "Eligible" }
        Write-Host "  - Includes membershipType column ($($types -join '/'))" -ForegroundColor Gray
        Write-Host "========================================`n" -ForegroundColor Green

        return $true
    }
}
