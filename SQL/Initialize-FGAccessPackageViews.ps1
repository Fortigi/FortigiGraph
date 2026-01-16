function Initialize-FGAccessPackageViews {
    <#
    .SYNOPSIS
    Creates SQL views for analyzing access package assignments and their resulting permissions.

    .DESCRIPTION
    This function creates comprehensive SQL views for analyzing access packages:
    - Which access packages users have
    - Which catalog each package belongs to
    - Which group memberships/ownerships users get from access packages
    - Complete user entitlement view (both direct and access package-based)
    - IST vs SOLL gap analysis: Shows which permissions exist directly but are NOT managed by access packages

    The views enable complete governance analysis:
    - "Soll" (should-be): Permissions defined by access packages
    - "Ist" (as-is): Current direct permissions
    - Gap: Direct permissions not governed by access packages (potential compliance risk)

    .PARAMETER DropIfExists
    If specified, drops existing views before creating new ones

    .PARAMETER CatalogsTable
    Name of the catalogs table. Default: "GraphCatalogs"

    .PARAMETER AccessPackagesTable
    Name of the access packages table. Default: "GraphAccessPackages"

    .PARAMETER AssignmentsTable
    Name of the assignments table. Default: "GraphAccessPackageAssignments"

    .PARAMETER ResourceRoleScopesTable
    Name of the resource role scopes table. Default: "GraphAccessPackageResourceRoleScopes"

    .PARAMETER UsersTable
    Name of the users table. Default: "GraphUsers"

    .PARAMETER GroupsTable
    Name of the groups table. Default: "GraphGroups"

    .PARAMETER GroupMembersTable
    Name of the group members table. Default: "GraphGroupMembers"

    .PARAMETER GroupOwnersTable
    Name of the group owners table. Default: "GraphGroupOwners"

    .EXAMPLE
    Initialize-FGAccessPackageViews

    Creates all access package analysis views with default table names

    .EXAMPLE
    Initialize-FGAccessPackageViews -DropIfExists

    Drops and recreates all views

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Access package sync tables to exist (run Sync-FGCatalog, Sync-FGAccessPackage, etc. first)

    Creates these views:
    - vw_UserAccessPackages: User → Access Package → Catalog mapping
    - vw_UserAccessPackageResources: User → Access Package → Group/Resource → Role mapping
    - vw_UserAccessPackageGroupMemberships: Filtered view for group Member roles from access packages
    - vw_UserAccessPackageGroupOwnerships: Filtered view for group Owner roles from access packages
    - vw_DirectGroupMemberships: Group memberships that exist but are NOT from access packages (ist vs soll gap)
    - vw_DirectGroupOwnerships: Group ownerships that exist but are NOT from access packages (ist vs soll gap)
    - vw_UnmanagedPermissions: Combined view of all direct permissions not managed by access packages
    #>

    [CmdletBinding()]
    [Alias("Initialize-AccessPackageViews")]
    Param(
        [Parameter(Mandatory = $false)]
        [switch]$DropIfExists,

        [Parameter(Mandatory = $false)]
        [string]$CatalogsTable = "GraphCatalogs",

        [Parameter(Mandatory = $false)]
        [string]$AccessPackagesTable = "GraphAccessPackages",

        [Parameter(Mandatory = $false)]
        [string]$AssignmentsTable = "GraphAccessPackageAssignments",

        [Parameter(Mandatory = $false)]
        [string]$ResourceRoleScopesTable = "GraphAccessPackageResourceRoleScopes",

        [Parameter(Mandatory = $false)]
        [string]$UsersTable = "GraphUsers",

        [Parameter(Mandatory = $false)]
        [string]$GroupsTable = "GraphGroups",

        [Parameter(Mandatory = $false)]
        [string]$GroupMembersTable = "GraphGroupMembers",

        [Parameter(Mandatory = $false)]
        [string]$GroupOwnersTable = "GraphGroupOwners"
    )

    # Check SQL connection
    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Creating access package analysis views..." -ForegroundColor Cyan

    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        # View 1: User Access Packages with Catalog Info
        # Shows: Which users have which access packages from which catalogs
        $view1Name = "vw_UserAccessPackages"
        $view1Sql = @"
-- User Access Packages View
-- Shows which access packages each user has and from which catalog
CREATE VIEW dbo.$view1Name AS
SELECT
    a.targetId AS userId,
    u.userPrincipalName,
    u.displayName AS userDisplayName,
    a.id AS assignmentId,
    a.state AS assignmentState,
    a.status AS assignmentStatus,
    ap.id AS accessPackageId,
    ap.displayName AS accessPackageName,
    ap.description AS accessPackageDescription,
    c.id AS catalogId,
    c.displayName AS catalogName,
    c.catalogType,
    a.createdDateTime AS assignedDateTime
FROM dbo.$AssignmentsTable a
    INNER JOIN dbo.$UsersTable u ON a.targetId = u.id
    INNER JOIN dbo.$AccessPackagesTable ap ON a.accessPackageId = ap.id
    INNER JOIN dbo.$CatalogsTable c ON ap.catalogId = c.id
WHERE a.state = 'delivered'  -- Only active assignments
"@

        # View 2: User Access Package Resources
        # Shows: Which resources (groups) and roles users get from their access packages
        $view2Name = "vw_UserAccessPackageResources"
        $view2Sql = @"
-- User Access Package Resources View
-- Shows which resources (groups) and roles users receive from their access packages
CREATE VIEW dbo.$view2Name AS
SELECT
    a.targetId AS userId,
    u.userPrincipalName,
    u.displayName AS userDisplayName,
    ap.id AS accessPackageId,
    ap.displayName AS accessPackageName,
    c.displayName AS catalogName,
    rrs.resourceId AS groupId,
    g.displayName AS groupName,
    g.mail AS groupMail,
    rrs.resourceType,
    rrs.resourceOriginSystem,
    rrs.roleId,
    rrs.roleDisplayName AS roleName,
    rrs.roleDescription,
    a.createdDateTime AS assignedDateTime
FROM dbo.$AssignmentsTable a
    INNER JOIN dbo.$UsersTable u ON a.targetId = u.id
    INNER JOIN dbo.$AccessPackagesTable ap ON a.accessPackageId = ap.id
    INNER JOIN dbo.$CatalogsTable c ON ap.catalogId = c.id
    INNER JOIN dbo.$ResourceRoleScopesTable rrs ON ap.id = rrs.accessPackageId
    LEFT JOIN dbo.$GroupsTable g ON rrs.resourceId = g.id
WHERE a.state = 'delivered'  -- Only active assignments
"@

        # View 3: User Access Package Group Memberships
        # Filtered view showing only Member roles for groups
        $view3Name = "vw_UserAccessPackageGroupMemberships"
        $view3Sql = @"
-- User Access Package Group Memberships View
-- Shows group Member roles that users receive from access packages
CREATE VIEW dbo.$view3Name AS
SELECT
    userId,
    userPrincipalName,
    userDisplayName,
    accessPackageId,
    accessPackageName,
    catalogName,
    groupId,
    groupName,
    groupMail,
    assignedDateTime,
    'AccessPackage' AS sourceType,
    catalogName + ' > ' + accessPackageName AS source
FROM dbo.vw_UserAccessPackageResources
WHERE resourceType = 'AadGroup'
    AND roleName = 'Member'
"@

        # View 4: User Access Package Group Ownerships
        # Filtered view showing only Owner roles for groups
        $view4Name = "vw_UserAccessPackageGroupOwnerships"
        $view4Sql = @"
-- User Access Package Group Ownerships View
-- Shows group Owner roles that users receive from access packages
CREATE VIEW dbo.$view4Name AS
SELECT
    userId,
    userPrincipalName,
    userDisplayName,
    accessPackageId,
    accessPackageName,
    catalogName,
    groupId,
    groupName,
    groupMail,
    assignedDateTime,
    'AccessPackage' AS sourceType,
    catalogName + ' > ' + accessPackageName AS source
FROM dbo.vw_UserAccessPackageResources
WHERE resourceType = 'AadGroup'
    AND roleName = 'Owner'
"@

        # View 5: Direct Group Memberships (NOT from Access Packages)
        # Shows: The gap between "ist" (as-is) and "soll" (should-be) for memberships
        $view5Name = "vw_DirectGroupMemberships"
        $view5Sql = @"
-- Direct Group Memberships View (IST vs SOLL Gap)
-- Shows group memberships that exist but are NOT assigned via access packages
CREATE VIEW dbo.$view5Name AS
SELECT
    gm.memberId AS userId,
    u.userPrincipalName,
    u.displayName AS userDisplayName,
    gm.groupId,
    g.displayName AS groupName,
    g.mail AS groupMail,
    'Direct' AS sourceType,
    'Direct Assignment' AS source,
    'Member' AS roleName
FROM dbo.$GroupMembersTable gm
    INNER JOIN dbo.$UsersTable u ON gm.memberId = u.id
    INNER JOIN dbo.$GroupsTable g ON gm.groupId = g.id
    LEFT JOIN dbo.vw_UserAccessPackageGroupMemberships ap
        ON gm.memberId = ap.userId
        AND gm.groupId = ap.groupId
WHERE ap.userId IS NULL  -- No matching access package assignment
"@

        # View 6: Direct Group Ownerships (NOT from Access Packages)
        # Shows: The gap between "ist" (as-is) and "soll" (should-be) for ownerships
        $view6Name = "vw_DirectGroupOwnerships"
        $view6Sql = @"
-- Direct Group Ownerships View (IST vs SOLL Gap)
-- Shows group ownerships that exist but are NOT assigned via access packages
CREATE VIEW dbo.$view6Name AS
SELECT
    go.ownerId AS userId,
    u.userPrincipalName,
    u.displayName AS userDisplayName,
    go.groupId,
    g.displayName AS groupName,
    g.mail AS groupMail,
    'Direct' AS sourceType,
    'Direct Assignment' AS source,
    'Owner' AS roleName
FROM dbo.$GroupOwnersTable go
    INNER JOIN dbo.$UsersTable u ON go.ownerId = u.id
    INNER JOIN dbo.$GroupsTable g ON go.groupId = g.id
    LEFT JOIN dbo.vw_UserAccessPackageGroupOwnerships ap
        ON go.ownerId = ap.userId
        AND go.groupId = ap.groupId
WHERE ap.userId IS NULL  -- No matching access package assignment
"@

        # View 7: Unmanaged Permissions (Combined)
        # Shows: All direct permissions (memberships + ownerships) not managed by access packages
        $view7Name = "vw_UnmanagedPermissions"
        $view7Sql = @"
-- Unmanaged Permissions View (IST vs SOLL Gap - Combined)
-- Shows all group permissions that exist directly but are NOT managed by access packages
CREATE VIEW dbo.$view7Name AS
SELECT
    userId,
    userPrincipalName,
    userDisplayName,
    groupId,
    groupName,
    groupMail,
    roleName,
    sourceType,
    source,
    'Membership' AS permissionType
FROM dbo.vw_DirectGroupMemberships

UNION ALL

SELECT
    userId,
    userPrincipalName,
    userDisplayName,
    groupId,
    groupName,
    groupMail,
    roleName,
    sourceType,
    source,
    'Ownership' AS permissionType
FROM dbo.vw_DirectGroupOwnerships
"@

        # Array of views to create
        $views = @(
            @{ Name = $view1Name; SQL = $view1Sql },
            @{ Name = $view2Name; SQL = $view2Sql },
            @{ Name = $view3Name; SQL = $view3Sql },
            @{ Name = $view4Name; SQL = $view4Sql },
            @{ Name = $view5Name; SQL = $view5Sql },
            @{ Name = $view6Name; SQL = $view6Sql },
            @{ Name = $view7Name; SQL = $view7Sql }
        )

        foreach ($view in $views) {
            try {
                # Drop if exists (if requested)
                if ($DropIfExists) {
                    $dropCmd = $connection.CreateCommand()
                    $dropCmd.CommandText = "IF OBJECT_ID('dbo.$($view.Name)', 'V') IS NOT NULL DROP VIEW dbo.$($view.Name)"
                    [void]$dropCmd.ExecuteNonQuery()
                    $dropCmd.Dispose()
                    Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Dropped existing view: $($view.Name)" -ForegroundColor Gray
                }

                # Create view
                $createCmd = $connection.CreateCommand()
                $createCmd.CommandText = $view.SQL
                [void]$createCmd.ExecuteNonQuery()
                $createCmd.Dispose()

                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Created view: $($view.Name)" -ForegroundColor Green
            }
            catch {
                Write-Warning "  [$(Get-Date -Format 'HH:mm:ss')] Failed to create view $($view.Name): $_"
            }
        }

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Access package views created successfully" -ForegroundColor Green
    }
}
