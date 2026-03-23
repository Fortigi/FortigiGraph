function Initialize-FGResourceViews {
    <#
    .SYNOPSIS
    Creates SQL views for analyzing the universal resource model (Resources, ResourceAssignments, ResourceRelationships).

    .DESCRIPTION
    Creates views that make it easy to work with resource membership data:

    1. vw_ResourceMembersRecursive
       - Calculates ALL memberships (direct + indirect via nested groups) recursively
       - Uses ONLY ResourceAssignments (no need for separate transitive sync)
       - Includes complete path showing how membership was obtained
       - Shows depth level for each membership
       - Cycle prevention via depth limit (max 10 levels of nesting)

    2. vw_ResourceUserPermissionAssignments
       - Comprehensive view combining ALL assignment types (Direct/Indirect/Owner/Eligible)
       - Includes cross-resource indirect access via ResourceRelationships (GrantsAccessTo)
       - Single query to get complete permission picture
       - Includes managedByAccessPackage column (if AP views exist)

    .EXAMPLE
    Initialize-FGResourceViews

    Creates all resource analysis views

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Resources and ResourceAssignments tables to exist
    - ResourceRelationships table is optional (cross-resource indirect access)
    - vw_UserPermissionAssignmentViaAccessPackage is optional (for managedByAccessPackage column)
    #>

    [CmdletBinding()]
    [Alias("Initialize-ResourceViews")]
    Param()

    # Check SQL connection
    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Creating resource analysis views..." -ForegroundColor Cyan

        # Check which tables/views exist
        $checkCmd = $connection.CreateCommand()
        $checkCmd.CommandText = @"
SELECT
    CASE WHEN EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'Resources' AND TABLE_SCHEMA = 'dbo') THEN 1 ELSE 0 END AS ResourcesExists,
    CASE WHEN EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'ResourceAssignments' AND TABLE_SCHEMA = 'dbo') THEN 1 ELSE 0 END AS AssignmentsExists,
    CASE WHEN EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'ResourceRelationships' AND TABLE_SCHEMA = 'dbo') THEN 1 ELSE 0 END AS RelationshipsExists,
    CASE WHEN EXISTS (SELECT 1 FROM sys.views WHERE name = 'vw_UserPermissionAssignmentViaAccessPackage') THEN 1 ELSE 0 END AS SollViewExists
"@
        $reader = $checkCmd.ExecuteReader()
        $reader.Read()
        $resourcesExists = $reader.GetInt32(0) -eq 1
        $assignmentsExists = $reader.GetInt32(1) -eq 1
        $relationshipsExists = $reader.GetInt32(2) -eq 1
        $sollViewExists = $reader.GetInt32(3) -eq 1
        $reader.Close()

        if (-not $resourcesExists) {
            throw "Required table 'Resources' does not exist. Please run Initialize-FGSystemTables first."
        }

        if (-not $assignmentsExists) {
            throw "Required table 'ResourceAssignments' does not exist. Please run Initialize-FGSystemTables first."
        }

        if (-not $relationshipsExists) {
            Write-Warning "Table 'ResourceRelationships' does not exist. Cross-resource indirect access will not be included. Run Sync-FGResourceRelationship to populate."
        }

        if (-not $sollViewExists) {
            Write-Warning "View 'vw_UserPermissionAssignmentViaAccessPackage' does not exist. managedByAccessPackage will always be 0."
        }

        # View 1: Recursive Resource Memberships
        Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Creating view: vw_ResourceMembersRecursive" -ForegroundColor Cyan
        Write-Host "  Purpose: Calculates ALL memberships (direct + indirect via nested groups)" -ForegroundColor Gray
        Write-Host "  Benefit: Eliminates need for separate transitive membership sync" -ForegroundColor Gray

        $dropView1Cmd = $connection.CreateCommand()
        $dropView1Cmd.CommandText = "IF EXISTS (SELECT * FROM sys.views WHERE name = 'vw_ResourceMembersRecursive') DROP VIEW dbo.vw_ResourceMembersRecursive;"
        $dropView1Cmd.ExecuteNonQuery() | Out-Null

        $createView1SQL = @"
-- Calculates ALL memberships (direct + indirect via nested groups) with path tracking
-- Uses ResourceAssignments only - groups that are assigned to resources and have their own members
CREATE VIEW dbo.vw_ResourceMembersRecursive AS
WITH RecursiveMemberships AS (
    -- Anchor: Direct assignments from ResourceAssignments
    SELECT
        ra.resourceId,
        ra.principalId,
        ra.principalType,
        CAST('Direct' AS NVARCHAR(50)) AS membershipType,
        1 AS depth,
        CAST(CAST(ra.resourceId AS NVARCHAR(36)) + ' -> ' + CAST(ra.principalId AS NVARCHAR(36)) AS NVARCHAR(MAX)) AS path,
        ra.ValidFrom,
        ra.ValidTo
    FROM dbo.ResourceAssignments ra
    WHERE ra.ValidTo = '9999-12-31 23:59:59.9999999'
      AND ra.assignmentType = 'Direct'

    UNION ALL

    -- Recursive: Nested group members
    -- If a group (principalId) is itself a resource that has members,
    -- those members get indirect access to the parent resource
    SELECT
        rm.resourceId,              -- Original target resource
        ra2.principalId,            -- Member of the nested group
        ra2.principalType,
        CAST('Indirect' AS NVARCHAR(50)) AS membershipType,
        rm.depth + 1,
        CAST(rm.path + ' -> ' + CAST(rm.principalId AS NVARCHAR(36)) AS NVARCHAR(MAX)) AS path,
        -- ValidFrom: Later of the two dates
        CASE WHEN rm.ValidFrom > ra2.ValidFrom THEN rm.ValidFrom ELSE ra2.ValidFrom END AS ValidFrom,
        -- ValidTo: Earlier of the two dates
        CASE WHEN rm.ValidTo < ra2.ValidTo THEN rm.ValidTo ELSE ra2.ValidTo END AS ValidTo
    FROM RecursiveMemberships rm
    INNER JOIN dbo.ResourceAssignments ra2
        ON rm.principalId = ra2.resourceId   -- The group member IS a resource with its own members
        AND ra2.ValidTo = '9999-12-31 23:59:59.9999999'
        AND ra2.assignmentType = 'Direct'
    WHERE rm.principalType LIKE '%group%'    -- Only recurse through groups
      AND rm.depth < 10                      -- Prevent infinite loops
)
SELECT resourceId, principalId, principalType, membershipType, depth, path, ValidFrom, ValidTo
FROM RecursiveMemberships;
"@

        $createView1Cmd = $connection.CreateCommand()
        $createView1Cmd.CommandText = $createView1SQL
        $createView1Cmd.ExecuteNonQuery() | Out-Null
        Write-Host "  Created: vw_ResourceMembersRecursive" -ForegroundColor Green

        # View 2: User Permission Assignments (combines all types)
        Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Creating view: vw_ResourceUserPermissionAssignments" -ForegroundColor Cyan

        $types = @("Direct", "Indirect", "Owner", "Eligible")
        if ($relationshipsExists) { $types += "CrossResourceIndirect" }
        Write-Host "  Purpose: Comprehensive view with all assignment types ($($types -join '/'))" -ForegroundColor Gray

        $dropView2Cmd = $connection.CreateCommand()
        $dropView2Cmd.CommandText = "IF EXISTS (SELECT * FROM sys.views WHERE name = 'vw_ResourceUserPermissionAssignments') DROP VIEW dbo.vw_ResourceUserPermissionAssignments;"
        $dropView2Cmd.ExecuteNonQuery() | Out-Null

        $createView2SQL = @"
CREATE VIEW dbo.vw_ResourceUserPermissionAssignments AS
WITH CurrentMembers AS (
    -- Recursive memberships (Direct + Indirect via nesting)
    SELECT
        resourceId,
        principalId,
        principalType,
        membershipType,
        ValidFrom,
        ValidTo
    FROM dbo.vw_ResourceMembersRecursive
    WHERE ValidTo = '9999-12-31 23:59:59.9999999'
),
AllAssignments AS (
    -- Direct and Indirect memberships
    SELECT
        resourceId,
        principalId,
        principalType,
        membershipType,
        ValidFrom,
        ValidTo
    FROM CurrentMembers

    UNION ALL

    -- Owner assignments
    SELECT
        ra.resourceId,
        ra.principalId,
        ra.principalType,
        CAST('Owner' AS NVARCHAR(50)) AS membershipType,
        ra.ValidFrom,
        ra.ValidTo
    FROM dbo.ResourceAssignments ra
    WHERE ra.ValidTo = '9999-12-31 23:59:59.9999999'
      AND ra.assignmentType = 'Owner'

    UNION ALL

    -- Eligible assignments (PIM)
    SELECT
        ra.resourceId,
        ra.principalId,
        ra.principalType,
        CAST('Eligible' AS NVARCHAR(50)) AS membershipType,
        ra.ValidFrom,
        ra.ValidTo
    FROM dbo.ResourceAssignments ra
    WHERE ra.ValidTo = '9999-12-31 23:59:59.9999999'
      AND ra.assignmentType = 'Eligible'
"@

        # Add cross-resource indirect access via ResourceRelationships if table exists
        if ($relationshipsExists) {
            $createView2SQL += @"

    UNION ALL

    -- Cross-resource indirect: User has direct access to resource A,
    -- resource A GrantsAccessTo resource B -> user has indirect access to B
    SELECT
        rel.childResourceId AS resourceId,
        ra3.principalId,
        ra3.principalType,
        CAST('Indirect' AS NVARCHAR(50)) AS membershipType,
        ra3.ValidFrom,
        ra3.ValidTo
    FROM dbo.ResourceRelationships rel
    INNER JOIN dbo.ResourceAssignments ra3
        ON rel.parentResourceId = ra3.resourceId
        AND ra3.ValidTo = '9999-12-31 23:59:59.9999999'
        AND ra3.assignmentType = 'Direct'
    WHERE rel.ValidTo = '9999-12-31 23:59:59.9999999'
      AND rel.relationshipType = 'GrantsAccessTo'
"@
        }

        # Close AllAssignments CTE and add final SELECT
        $createView2SQL += @"

)
SELECT
    a.resourceId,
    a.principalId,
    a.principalType,
    a.membershipType,
    a.ValidFrom,
    a.ValidTo,
"@

        if ($sollViewExists) {
            $createView2SQL += @"

    CAST(CASE WHEN EXISTS (
        SELECT 1 FROM dbo.vw_UserPermissionAssignmentViaAccessPackage ap
        WHERE ap.userId = a.principalId
          AND ap.groupId = a.resourceId
    ) THEN 1 ELSE 0 END AS BIT) AS managedByAccessPackage
FROM AllAssignments a;
"@
        }
        else {
            $createView2SQL += @"

    CAST(0 AS BIT) AS managedByAccessPackage
FROM AllAssignments a;
"@
        }

        $createView2Cmd = $connection.CreateCommand()
        $createView2Cmd.CommandText = $createView2SQL
        $createView2Cmd.ExecuteNonQuery() | Out-Null
        Write-Host "  Created: vw_ResourceUserPermissionAssignments" -ForegroundColor Green

        Write-Host "`n========================================" -ForegroundColor Green
        Write-Host "Resource Views Created Successfully!" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green

        Write-Host "`nView 1: vw_ResourceMembersRecursive" -ForegroundColor White
        Write-Host "  - Calculates ALL memberships (direct + indirect) recursively" -ForegroundColor Gray
        Write-Host "  - Uses ResourceAssignments table only" -ForegroundColor Gray
        Write-Host "  - Includes complete path for each membership" -ForegroundColor Gray
        Write-Host "  - Shows depth level (how many groups deep)" -ForegroundColor Gray
        Write-Host "  - Cycle prevention via depth limit (max 10 levels)" -ForegroundColor Gray
        Write-Host "  - Columns: resourceId, principalId, principalType, membershipType, depth, path, ValidFrom, ValidTo" -ForegroundColor Gray

        Write-Host "`nView 2: vw_ResourceUserPermissionAssignments" -ForegroundColor White
        Write-Host "  - Comprehensive view combining ALL assignment types" -ForegroundColor Gray
        Write-Host "  - Includes: $($types -join ', ')" -ForegroundColor Gray
        Write-Host "  - Single query to get complete permission picture" -ForegroundColor Gray
        Write-Host "  - Columns: resourceId, principalId, principalType, membershipType, ValidFrom, ValidTo, managedByAccessPackage" -ForegroundColor Gray
        if ($sollViewExists) {
            Write-Host "  - managedByAccessPackage: Checks against vw_UserPermissionAssignmentViaAccessPackage (SOLL)" -ForegroundColor Gray
        }
        else {
            Write-Host "  - managedByAccessPackage: Always 0 (run Initialize-FGAccessPackageViews first, then re-run this)" -ForegroundColor Yellow
        }
        if (-not $relationshipsExists) {
            Write-Host "  - Cross-resource indirect: NOT included (run Sync-FGResourceRelationship first, then re-run this)" -ForegroundColor Yellow
        }
        Write-Host "========================================`n" -ForegroundColor Green

        return $true
    }
}
