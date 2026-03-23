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
    - Assignment method analysis: Shows HOW access was granted (automatic, user-requested, admin-assigned)

    The views enable complete governance analysis:
    - "Soll" (should-be): Permissions defined by access packages
    - "Ist" (as-is): Current direct permissions
    - Gap: Direct permissions not governed by access packages (potential compliance risk)
    - Assignment method: Automatic (policy rules) vs Requested (user initiated) vs Admin (directly assigned)

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

    .PARAMETER AssignmentRequestsTable
    Name of the assignment requests table. Default: "GraphAccessPackageAssignmentRequests"

    .PARAMETER AssignmentPoliciesTable
    Name of the assignment policies table. Default: "GraphAccessPackageAssignmentPolicies"

    .PARAMETER AccessReviewDecisionsTable
    Name of the access review decisions table. Default: "GraphAccessPackageAccessReviewDecisions"

    .PARAMETER ResourcesTable
    Name of the universal resources table. Default: "Resources". If this table exists, views will prefer it over GraphGroups.

    .PARAMETER ResourceAssignmentsTable
    Name of the universal resource assignments table. Default: "ResourceAssignments". If this table exists, views will prefer it over GraphGroupMembers/GraphGroupOwners.

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
    - vw_UserPermissionAssignmentViaAccessPackage: User → Access Package → Group/Resource → Role mapping
    - vw_DirectGroupMemberships: Group memberships that exist but are NOT from access packages (ist vs soll gap)
    - vw_DirectGroupOwnerships: Group ownerships that exist but are NOT from access packages (ist vs soll gap)
    - vw_UnmanagedPermissions: Combined view of all direct permissions not managed by access packages
    - vw_AccessPackageAssignmentDetails: Shows HOW access was granted (automatic, requested, admin-assigned)
    - vw_AccessPackageLastReview: Shows when each access package was last reviewed and by whom
    - vw_ApprovedRequestTimeline: Shows approved requests with response time metrics (hours/days)
    - vw_DeniedRequestTimeline: Shows denied requests with response time metrics
    - vw_PendingRequestTimeline: Shows pending requests with days pending
    - vw_RequestResponseMetrics: Aggregate view showing average/median response times by access package
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
        [string]$GroupOwnersTable = "GraphGroupOwners",

        [Parameter(Mandatory = $false)]
        [string]$AssignmentRequestsTable = "GraphAccessPackageAssignmentRequests",

        [Parameter(Mandatory = $false)]
        [string]$AssignmentPoliciesTable = "GraphAccessPackageAssignmentPolicies",

        [Parameter(Mandatory = $false)]
        [string]$AccessReviewDecisionsTable = "GraphAccessPackageAccessReviewDecisions",

        [Parameter(Mandatory = $false)]
        [string]$ResourcesTable = "Resources",

        [Parameter(Mandatory = $false)]
        [string]$ResourceAssignmentsTable = "ResourceAssignments"
    )

    # Check SQL connection
    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Creating access package analysis views..." -ForegroundColor Cyan

    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        # Check if the universal resource model tables exist
        $checkCmd = $connection.CreateCommand()
        $checkCmd.CommandText = @"
SELECT
    CASE WHEN EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = '$ResourcesTable') THEN 1 ELSE 0 END AS ResourcesExists,
    CASE WHEN EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = '$ResourceAssignmentsTable') THEN 1 ELSE 0 END AS ResourceAssignmentsExists
"@
        $reader = $checkCmd.ExecuteReader()
        $reader.Read() | Out-Null
        $resourcesExists = [bool]$reader["ResourcesExists"]
        $resourceAssignmentsExists = [bool]$reader["ResourceAssignmentsExists"]
        $reader.Close()
        $checkCmd.Dispose()

        if ($resourcesExists) {
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Resources table found - views will use universal resource model" -ForegroundColor Cyan
        }
        if ($resourceAssignmentsExists) {
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] ResourceAssignments table found - IST views will use universal resource model" -ForegroundColor Cyan
        }

        # View 1: User Permission Assignment Via Access Package
        # Shows: Which resources (groups) and roles users get from their access packages
        $view1Name = "vw_UserPermissionAssignmentViaAccessPackage"
        if ($resourcesExists) {
            # Use universal Resources table for resource name lookup
            $view1Sql = @"
-- User Permission Assignment Via Access Package View
-- Shows which resources (groups) and roles users receive from their access packages
-- Uses universal Resources table for resource name resolution
CREATE VIEW dbo.$view1Name AS
SELECT
    a.targetId AS userId,
    u.userPrincipalName,
    u.displayName AS userDisplayName,
    ap.id AS accessPackageId,
    ap.displayName AS accessPackageName,
    c.displayName AS catalogName,
    UPPER(rrs.scopeOriginId) AS groupId,
    r.displayName AS groupName,
    rrs.scopeOriginSystem AS resourceType,
    rrs.roleDisplayName AS roleName
FROM dbo.$AssignmentsTable a
    INNER JOIN dbo.$UsersTable u ON a.targetId = u.id
    INNER JOIN dbo.$AccessPackagesTable ap ON a.accessPackageId = ap.id
    INNER JOIN dbo.$CatalogsTable c ON ap.catalogId = c.id
    INNER JOIN dbo.$ResourceRoleScopesTable rrs ON ap.id = rrs.accessPackageId
    LEFT JOIN dbo.$ResourcesTable r ON UPPER(rrs.scopeOriginId) = r.id
WHERE a.assignmentState = 'delivered'  -- Only active assignments
"@
        }
        else {
            # Fall back to GraphGroups table
            $view1Sql = @"
-- User Permission Assignment Via Access Package View
-- Shows which resources (groups) and roles users receive from their access packages
CREATE VIEW dbo.$view1Name AS
SELECT
    a.targetId AS userId,
    u.userPrincipalName,
    u.displayName AS userDisplayName,
    ap.id AS accessPackageId,
    ap.displayName AS accessPackageName,
    c.displayName AS catalogName,
    UPPER(rrs.scopeOriginId) AS groupId,
    g.displayName AS groupName,
    rrs.scopeOriginSystem AS resourceType,
    rrs.roleDisplayName AS roleName
FROM dbo.$AssignmentsTable a
    INNER JOIN dbo.$UsersTable u ON a.targetId = u.id
    INNER JOIN dbo.$AccessPackagesTable ap ON a.accessPackageId = ap.id
    INNER JOIN dbo.$CatalogsTable c ON ap.catalogId = c.id
    INNER JOIN dbo.$ResourceRoleScopesTable rrs ON ap.id = rrs.accessPackageId
    LEFT JOIN dbo.$GroupsTable g ON UPPER(rrs.scopeOriginId) = g.id
WHERE a.assignmentState = 'delivered'  -- Only active assignments
"@
        }

        # View 2: Direct Group Memberships (NOT from Access Packages)
        # Shows: The gap between "ist" (as-is) and "soll" (should-be) for memberships
        $view2Name = "vw_DirectGroupMemberships"
        if ($resourceAssignmentsExists -and $resourcesExists) {
            # Use universal ResourceAssignments table
            $view2Sql = @"
-- Direct Group Memberships View (IST vs SOLL Gap)
-- Shows group memberships that exist but are NOT assigned via access packages
-- Uses universal ResourceAssignments table for membership data
CREATE VIEW dbo.$view2Name AS
SELECT
    ra.principalId AS userId,
    u.userPrincipalName,
    u.displayName AS userDisplayName,
    ra.resourceId AS groupId,
    r.displayName AS groupName,
    r.mail AS groupMail,
    'Direct' AS sourceType,
    'Direct Assignment' AS source,
    'Member' AS roleName
FROM dbo.$ResourceAssignmentsTable ra
    INNER JOIN dbo.$UsersTable u ON ra.principalId = u.id
    INNER JOIN dbo.$ResourcesTable r ON ra.resourceId = r.id
    LEFT JOIN dbo.vw_UserPermissionAssignmentViaAccessPackage ap
        ON ra.principalId = ap.userId
        AND ra.resourceId = ap.groupId
        AND ap.resourceType = 'AadGroup'
        AND ap.roleName = 'Member'
WHERE ra.assignmentType = 'Direct'
  AND ra.ValidTo = '9999-12-31 23:59:59.9999999'
  AND ap.userId IS NULL  -- No matching access package assignment
"@
        }
        else {
            # Fall back to GraphGroupMembers table
            $view2Sql = @"
-- Direct Group Memberships View (IST vs SOLL Gap)
-- Shows group memberships that exist but are NOT assigned via access packages
CREATE VIEW dbo.$view2Name AS
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
    LEFT JOIN dbo.vw_UserPermissionAssignmentViaAccessPackage ap
        ON gm.memberId = ap.userId
        AND gm.groupId = ap.groupId
        AND ap.resourceType = 'AadGroup'
        AND ap.roleName = 'Member'
WHERE ap.userId IS NULL  -- No matching access package assignment
"@
        }

        # View 3: Direct Group Ownerships (NOT from Access Packages)
        # Shows: The gap between "ist" (as-is) and "soll" (should-be) for ownerships
        $view3Name = "vw_DirectGroupOwnerships"
        if ($resourceAssignmentsExists -and $resourcesExists) {
            # Use universal ResourceAssignments table
            $view3Sql = @"
-- Direct Group Ownerships View (IST vs SOLL Gap)
-- Shows group ownerships that exist but are NOT assigned via access packages
-- Uses universal ResourceAssignments table for ownership data
CREATE VIEW dbo.$view3Name AS
SELECT
    ra.principalId AS userId,
    u.userPrincipalName,
    u.displayName AS userDisplayName,
    ra.resourceId AS groupId,
    r.displayName AS groupName,
    r.mail AS groupMail,
    'Direct' AS sourceType,
    'Direct Assignment' AS source,
    'Owner' AS roleName
FROM dbo.$ResourceAssignmentsTable ra
    INNER JOIN dbo.$UsersTable u ON ra.principalId = u.id
    INNER JOIN dbo.$ResourcesTable r ON ra.resourceId = r.id
    LEFT JOIN dbo.vw_UserPermissionAssignmentViaAccessPackage ap
        ON ra.principalId = ap.userId
        AND ra.resourceId = ap.groupId
        AND ap.resourceType = 'AadGroup'
        AND ap.roleName = 'Owner'
WHERE ra.assignmentType = 'Owner'
  AND ra.ValidTo = '9999-12-31 23:59:59.9999999'
  AND ap.userId IS NULL  -- No matching access package assignment
"@
        }
        else {
            # Fall back to GraphGroupOwners table
            $view3Sql = @"
-- Direct Group Ownerships View (IST vs SOLL Gap)
-- Shows group ownerships that exist but are NOT assigned via access packages
CREATE VIEW dbo.$view3Name AS
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
    LEFT JOIN dbo.vw_UserPermissionAssignmentViaAccessPackage ap
        ON go.ownerId = ap.userId
        AND go.groupId = ap.groupId
        AND ap.resourceType = 'AadGroup'
        AND ap.roleName = 'Owner'
WHERE ap.userId IS NULL  -- No matching access package assignment
"@
        }

        # View 4: Unmanaged Permissions (Combined)
        # Shows: All direct permissions (memberships + ownerships) not managed by access packages
        $view4Name = "vw_UnmanagedPermissions"
        $view4Sql = @"
-- Unmanaged Permissions View (IST vs SOLL Gap - Combined)
-- Shows all group permissions that exist directly but are NOT managed by access packages
CREATE VIEW dbo.$view4Name AS
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

        # View 8: Access Package Assignment Details (with Request Type)
        # Shows HOW each access package was assigned (automatic, requested, admin)
        # Enhanced: uses policy data as fallback when request records are missing
        $view5Name = "vw_AccessPackageAssignmentDetails"

        # Check if hasAutoAddRule column exists in the policies table (requires re-sync after upgrade)
        $hasAutoAddColumn = $false
        try {
            $checkCmd = $connection.CreateCommand()
            $checkCmd.CommandText = "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = '$AssignmentPoliciesTable' AND COLUMN_NAME = 'hasAutoAddRule'"
            $result = $checkCmd.ExecuteScalar()
            $checkCmd.Dispose()
            $hasAutoAddColumn = ($null -ne $result)
        } catch { }

        if ($hasAutoAddColumn) {
            # Enhanced view: uses policy data to infer assignment method when request data is missing
            $view5Sql = @"
-- Access Package Assignment Details View (Enhanced with Policy-Based Inference)
-- When a matching request record exists, uses requestType directly (SystemAdd/UserAdd/AdminAdd).
-- When no request record exists, falls back to policy analysis:
--   - If AP only has auto-add policies -> 'Automatic (Policy Rule)'
--   - If AP has no auto-add policies -> 'Requested / Admin Assigned'
--   - If AP has a mix of both -> 'Unknown (Mixed Policies)'
-- Auto-remove-only policies (requestAccessForAllowedTargets=false) are NOT counted as auto-add.
CREATE VIEW dbo.$view5Name AS
WITH APPolicyType AS (
    SELECT
        accessPackageId,
        COUNT(*) AS totalPolicies,
        SUM(CASE WHEN hasAutoAddRule = 1 THEN 1 ELSE 0 END) AS autoAddPolicies
    FROM dbo.$AssignmentPoliciesTable
    GROUP BY accessPackageId
)
SELECT
    a.id AS assignmentId,
    a.targetId AS userId,
    u.userPrincipalName,
    u.displayName AS userDisplayName,
    a.accessPackageId,
    ap.displayName AS accessPackageName,
    c.displayName AS catalogName,
    a.assignmentState AS assignmentState,
    COALESCE(req.requestType, 'Unknown') AS requestType,
    COALESCE(req.requestState, 'Unknown') AS requestState,
    COALESCE(req.requestStatus, 'Unknown') AS requestStatus,
    req.justification,
    req.createdDateTime AS requestCreatedDateTime,
    req.completedDateTime AS requestCompletedDateTime,
    CASE
        WHEN req.requestType = 'SystemAdd' THEN 'Automatic (Policy Rule)'
        WHEN req.requestType = 'UserAdd' THEN 'User Requested'
        WHEN req.requestType = 'AdminAdd' THEN 'Admin Assigned'
        -- Fallback: infer from policy types when no request record exists
        WHEN apt.totalPolicies > 0 AND apt.autoAddPolicies = apt.totalPolicies THEN 'Automatic (Policy Rule)'
        WHEN apt.totalPolicies > 0 AND apt.autoAddPolicies = 0 THEN 'Requested / Admin Assigned'
        WHEN apt.totalPolicies > 0 AND apt.autoAddPolicies > 0 AND apt.autoAddPolicies < apt.totalPolicies THEN 'Unknown (Mixed Policies)'
        ELSE 'Unknown'
    END AS assignmentMethod
FROM dbo.$AssignmentsTable a
    INNER JOIN dbo.$UsersTable u ON a.targetId = u.id
    INNER JOIN dbo.$AccessPackagesTable ap ON a.accessPackageId = ap.id
    INNER JOIN dbo.$CatalogsTable c ON ap.catalogId = c.id
    LEFT JOIN dbo.$AssignmentRequestsTable req
        ON a.accessPackageId = req.accessPackageId
        AND a.targetId = req.requestorId
        AND req.requestType IN ('SystemAdd', 'UserAdd', 'AdminAdd')
        AND req.requestState = 'Delivered'
    LEFT JOIN APPolicyType apt
        ON a.accessPackageId = apt.accessPackageId
WHERE a.assignmentState = 'delivered'
"@
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Using enhanced assignment method detection (policy-based fallback)" -ForegroundColor Cyan
        }
        else {
            # Original view: no policy data available yet
            $view5Sql = @"
-- Access Package Assignment Details View
-- Shows how each access package assignment was granted (automatic, user-requested, or admin-assigned)
-- NOTE: Re-sync assignment policies (Sync-FGAccessPackageAssignmentPolicy) to enable policy-based inference
CREATE VIEW dbo.$view5Name AS
SELECT
    a.id AS assignmentId,
    a.targetId AS userId,
    u.userPrincipalName,
    u.displayName AS userDisplayName,
    a.accessPackageId,
    ap.displayName AS accessPackageName,
    c.displayName AS catalogName,
    a.assignmentState AS assignmentState,
    COALESCE(req.requestType, 'Unknown') AS requestType,
    COALESCE(req.requestState, 'Unknown') AS requestState,
    COALESCE(req.requestStatus, 'Unknown') AS requestStatus,
    req.justification,
    req.createdDateTime AS requestCreatedDateTime,
    req.completedDateTime AS requestCompletedDateTime,
    CASE
        WHEN req.requestType = 'SystemAdd' THEN 'Automatic (Policy Rule)'
        WHEN req.requestType = 'UserAdd' THEN 'User Requested'
        WHEN req.requestType = 'AdminAdd' THEN 'Admin Assigned'
        ELSE 'Unknown'
    END AS assignmentMethod
FROM dbo.$AssignmentsTable a
    INNER JOIN dbo.$UsersTable u ON a.targetId = u.id
    INNER JOIN dbo.$AccessPackagesTable ap ON a.accessPackageId = ap.id
    INNER JOIN dbo.$CatalogsTable c ON ap.catalogId = c.id
    LEFT JOIN dbo.$AssignmentRequestsTable req
        ON a.accessPackageId = req.accessPackageId
        AND a.targetId = req.requestorId
        AND req.requestType IN ('SystemAdd', 'UserAdd', 'AdminAdd')
        AND req.requestState = 'Delivered'
WHERE a.assignmentState = 'delivered'
"@
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Using basic assignment method detection (re-sync policies to enable policy-based inference)" -ForegroundColor Yellow
        }

        # View 6: Last Access Review Per Access Package
        # Shows when each access package was last reviewed and by whom
        $view6Name = "vw_AccessPackageLastReview"
        $view6Sql = @"
-- Last Access Review View
-- Shows when each access package was last reviewed and by which user (actual reviewer)
CREATE VIEW dbo.$view6Name AS
WITH LatestReviews AS (
    SELECT
        r.accessPackageId,
        r.reviewedBy,
        r.reviewedByDisplayName,
        r.reviewedDateTime,
        r.decision,
        r.justification,
        r.reviewInstanceStatus,
        ROW_NUMBER() OVER (
            PARTITION BY r.accessPackageId
            ORDER BY r.reviewedDateTime DESC
        ) AS rn
    FROM dbo.$AccessReviewDecisionsTable r
    WHERE r.reviewedDateTime IS NOT NULL
        AND r.reviewedBy IS NOT NULL  -- Only actual user reviews, not system actions
        AND r.decision IS NOT NULL
        AND r.decision != 'NotReviewed'  -- Exclude non-decisions
)
SELECT
    lr.accessPackageId,
    ap.displayName AS accessPackageName,
    c.displayName AS catalogName,
    lr.reviewedBy AS lastReviewedBy,
    lr.reviewedByDisplayName AS lastReviewedByName,
    lr.reviewedDateTime AS lastReviewDateTime,
    lr.decision AS lastReviewDecision,
    lr.justification AS lastReviewJustification,
    lr.reviewInstanceStatus,
    DATEDIFF(day, lr.reviewedDateTime, GETDATE()) AS daysSinceLastReview
FROM LatestReviews lr
    INNER JOIN dbo.$AccessPackagesTable ap ON lr.accessPackageId = ap.id
    INNER JOIN dbo.$CatalogsTable c ON ap.catalogId = c.id
WHERE lr.rn = 1  -- Only the most recent review
"@

        # View 13: Approved Request Timeline
        # Shows approved requests with response time metrics
        $view7Name = "vw_ApprovedRequestTimeline"
        $view7Sql = @"
-- Approved Request Timeline View
-- Shows access package requests that were approved with response time metrics
CREATE VIEW dbo.$view7Name AS
SELECT
    req.id AS requestId,
    req.requestorId AS userId,
    u.userPrincipalName,
    u.displayName AS userDisplayName,
    req.accessPackageId,
    ap.displayName AS accessPackageName,
    c.displayName AS catalogName,
    req.requestType,
    req.requestState,
    req.requestStatus,
    req.justification,
    req.createdDateTime AS requestCreatedDateTime,
    req.completedDateTime AS requestCompletedDateTime,
    DATEDIFF(hour, req.createdDateTime, req.completedDateTime) AS hoursToApprove,
    DATEDIFF(day, req.createdDateTime, req.completedDateTime) AS daysToApprove,
    CASE
        WHEN DATEDIFF(hour, req.createdDateTime, req.completedDateTime) < 1 THEN 'Less than 1 hour'
        WHEN DATEDIFF(hour, req.createdDateTime, req.completedDateTime) < 4 THEN '1-4 hours'
        WHEN DATEDIFF(hour, req.createdDateTime, req.completedDateTime) < 24 THEN '4-24 hours'
        WHEN DATEDIFF(day, req.createdDateTime, req.completedDateTime) < 3 THEN '1-3 days'
        WHEN DATEDIFF(day, req.createdDateTime, req.completedDateTime) < 7 THEN '3-7 days'
        WHEN DATEDIFF(day, req.createdDateTime, req.completedDateTime) < 14 THEN '1-2 weeks'
        ELSE 'Over 2 weeks'
    END AS responseTimeBucket
FROM dbo.$AssignmentRequestsTable req
    INNER JOIN dbo.$UsersTable u ON req.requestorId = u.id
    INNER JOIN dbo.$AccessPackagesTable ap ON req.accessPackageId = ap.id
    INNER JOIN dbo.$CatalogsTable c ON ap.catalogId = c.id
WHERE req.requestState = 'Delivered'
    AND req.completedDateTime IS NOT NULL
    AND req.requestType IN ('UserAdd', 'AdminAdd')  -- Only requested/admin assignments
"@

        # View 14: Denied Request Timeline
        # Shows denied requests with response time metrics
        $view8Name = "vw_DeniedRequestTimeline"
        $view8Sql = @"
-- Denied Request Timeline View
-- Shows access package requests that were denied with response time metrics
CREATE VIEW dbo.$view8Name AS
SELECT
    req.id AS requestId,
    req.requestorId AS userId,
    u.userPrincipalName,
    u.displayName AS userDisplayName,
    req.accessPackageId,
    ap.displayName AS accessPackageName,
    c.displayName AS catalogName,
    req.requestType,
    req.requestState,
    req.requestStatus,
    req.justification,
    req.createdDateTime AS requestCreatedDateTime,
    req.completedDateTime AS requestCompletedDateTime,
    DATEDIFF(hour, req.createdDateTime, req.completedDateTime) AS hoursToDeny,
    DATEDIFF(day, req.createdDateTime, req.completedDateTime) AS daysToDeny,
    CASE
        WHEN DATEDIFF(hour, req.createdDateTime, req.completedDateTime) < 1 THEN 'Less than 1 hour'
        WHEN DATEDIFF(hour, req.createdDateTime, req.completedDateTime) < 4 THEN '1-4 hours'
        WHEN DATEDIFF(hour, req.createdDateTime, req.completedDateTime) < 24 THEN '4-24 hours'
        WHEN DATEDIFF(day, req.createdDateTime, req.completedDateTime) < 3 THEN '1-3 days'
        WHEN DATEDIFF(day, req.createdDateTime, req.completedDateTime) < 7 THEN '3-7 days'
        WHEN DATEDIFF(day, req.createdDateTime, req.completedDateTime) < 14 THEN '1-2 weeks'
        ELSE 'Over 2 weeks'
    END AS responseTimeBucket
FROM dbo.$AssignmentRequestsTable req
    INNER JOIN dbo.$UsersTable u ON req.requestorId = u.id
    INNER JOIN dbo.$AccessPackagesTable ap ON req.accessPackageId = ap.id
    INNER JOIN dbo.$CatalogsTable c ON ap.catalogId = c.id
WHERE req.requestState = 'Denied'
    AND req.completedDateTime IS NOT NULL
"@

        # View 15: Pending Request Timeline
        # Shows pending requests with days waiting
        $view9Name = "vw_PendingRequestTimeline"
        $view9Sql = @"
-- Pending Request Timeline View
-- Shows access package requests that are still pending approval with days waiting
CREATE VIEW dbo.$view9Name AS
SELECT
    req.id AS requestId,
    req.requestorId AS userId,
    u.userPrincipalName,
    u.displayName AS userDisplayName,
    req.accessPackageId,
    ap.displayName AS accessPackageName,
    c.displayName AS catalogName,
    req.requestType,
    req.requestState,
    req.requestStatus,
    req.justification,
    req.createdDateTime AS requestCreatedDateTime,
    DATEDIFF(hour, req.createdDateTime, GETDATE()) AS hoursPending,
    DATEDIFF(day, req.createdDateTime, GETDATE()) AS daysPending,
    CASE
        WHEN DATEDIFF(day, req.createdDateTime, GETDATE()) < 1 THEN 'Less than 1 day'
        WHEN DATEDIFF(day, req.createdDateTime, GETDATE()) < 3 THEN '1-3 days'
        WHEN DATEDIFF(day, req.createdDateTime, GETDATE()) < 7 THEN '3-7 days'
        WHEN DATEDIFF(day, req.createdDateTime, GETDATE()) < 14 THEN '1-2 weeks'
        ELSE 'Over 2 weeks'
    END AS pendingTimeBucket,
    CASE
        WHEN DATEDIFF(day, req.createdDateTime, GETDATE()) > 7 THEN 1
        ELSE 0
    END AS isOverdue
FROM dbo.$AssignmentRequestsTable req
    INNER JOIN dbo.$UsersTable u ON req.requestorId = u.id
    INNER JOIN dbo.$AccessPackagesTable ap ON req.accessPackageId = ap.id
    INNER JOIN dbo.$CatalogsTable c ON ap.catalogId = c.id
WHERE req.requestState IN ('PendingApproval', 'Submitted', 'Accepted')
    AND req.completedDateTime IS NULL
"@

        # View 16: Request Response Metrics (Aggregate)
        # Shows aggregate response time metrics by access package and catalog
        $view10Name = "vw_RequestResponseMetrics"
        $view10Sql = @"
-- Request Response Metrics View (Aggregate)
-- Shows average, median, min, max response times and approval rates by access package
CREATE VIEW dbo.$view10Name AS
WITH RequestMetrics AS (
    SELECT
        req.accessPackageId,
        ap.displayName AS accessPackageName,
        c.id AS catalogId,
        c.displayName AS catalogName,
        req.requestState,
        DATEDIFF(hour, req.createdDateTime, req.completedDateTime) AS responseHours,
        DATEDIFF(day, req.createdDateTime, req.completedDateTime) AS responseDays
    FROM dbo.$AssignmentRequestsTable req
        INNER JOIN dbo.$AccessPackagesTable ap ON req.accessPackageId = ap.id
        INNER JOIN dbo.$CatalogsTable c ON ap.catalogId = c.id
    WHERE req.completedDateTime IS NOT NULL
        AND req.requestType IN ('UserAdd', 'AdminAdd')
        AND req.requestState IN ('Delivered', 'Denied')
),
ApprovalStats AS (
    SELECT
        accessPackageId,
        accessPackageName,
        catalogId,
        catalogName,
        COUNT(*) AS totalRequests,
        SUM(CASE WHEN requestState = 'Delivered' THEN 1 ELSE 0 END) AS approvedCount,
        SUM(CASE WHEN requestState = 'Denied' THEN 1 ELSE 0 END) AS deniedCount,
        AVG(CAST(responseHours AS FLOAT)) AS avgResponseHours,
        AVG(CAST(responseDays AS FLOAT)) AS avgResponseDays,
        MIN(responseHours) AS minResponseHours,
        MAX(responseHours) AS maxResponseHours,
        MIN(responseDays) AS minResponseDays,
        MAX(responseDays) AS maxResponseDays
    FROM RequestMetrics
    GROUP BY accessPackageId, accessPackageName, catalogId, catalogName
)
SELECT
    accessPackageId,
    accessPackageName,
    catalogId,
    catalogName,
    totalRequests,
    approvedCount,
    deniedCount,
    CAST(ROUND(avgResponseHours, 1) AS DECIMAL(10,1)) AS avgResponseHours,
    CAST(ROUND(avgResponseDays, 1) AS DECIMAL(10,1)) AS avgResponseDays,
    minResponseHours,
    maxResponseHours,
    minResponseDays,
    maxResponseDays,
    CASE
        WHEN totalRequests > 0 THEN
            CAST(ROUND((CAST(approvedCount AS FLOAT) / totalRequests) * 100, 1) AS DECIMAL(5,1))
        ELSE 0
    END AS approvalRatePercent,
    CASE
        WHEN avgResponseDays < 1 THEN 'Same Day'
        WHEN avgResponseDays < 3 THEN '1-3 Days'
        WHEN avgResponseDays < 7 THEN '3-7 Days'
        WHEN avgResponseDays < 14 THEN '1-2 Weeks'
        ELSE 'Over 2 Weeks'
    END AS avgResponseCategory
FROM ApprovalStats
"@

        # Array of views to create
        $views = @(
            @{ Name = $view1Name; SQL = $view1Sql },
            @{ Name = $view2Name; SQL = $view2Sql },
            @{ Name = $view3Name; SQL = $view3Sql },
            @{ Name = $view4Name; SQL = $view4Sql },
            @{ Name = $view5Name; SQL = $view5Sql },
            @{ Name = $view6Name; SQL = $view6Sql },
            @{ Name = $view7Name; SQL = $view7Sql },
            @{ Name = $view8Name; SQL = $view8Sql },
            @{ Name = $view9Name; SQL = $view9Sql },
            @{ Name = $view10Name; SQL = $view10Sql }
        )

        foreach ($view in $views) {
            try {
                # Always drop if exists to ensure clean recreation
                $dropCmd = $connection.CreateCommand()
                $dropCmd.CommandText = "IF OBJECT_ID('dbo.$($view.Name)', 'V') IS NOT NULL DROP VIEW dbo.$($view.Name)"
                [void]$dropCmd.ExecuteNonQuery()
                $dropCmd.Dispose()

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
