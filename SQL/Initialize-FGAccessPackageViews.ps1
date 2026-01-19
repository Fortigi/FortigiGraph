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
    - vw_AccessPackageAssignmentDetails: Shows HOW access was granted (automatic, requested, admin-assigned)
    - vw_AutomaticAssignments: Assignments automatically granted by system based on policy rules
    - vw_RequestedAssignments: Assignments that were user-requested (with approval status)
    - vw_AdminAssignments: Assignments directly made by administrators
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
        [string]$AccessReviewDecisionsTable = "GraphAccessPackageAccessReviewDecisions"
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
    a.assignmentState AS assignmentState,
    a.assignmentStatus AS assignmentStatus,
    ap.id AS accessPackageId,
    ap.displayName AS accessPackageName,
    ap.description AS accessPackageDescription,
    c.id AS catalogId,
    c.displayName AS catalogName,
    c.catalogType
FROM dbo.$AssignmentsTable a
    INNER JOIN dbo.$UsersTable u ON a.targetId = u.id
    INNER JOIN dbo.$AccessPackagesTable ap ON a.accessPackageId = ap.id
    INNER JOIN dbo.$CatalogsTable c ON ap.catalogId = c.id
WHERE a.assignmentState = 'delivered'  -- Only active assignments
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
    rrs.scopeOriginId AS groupId,
    g.displayName AS groupName,
    g.mail AS groupMail,
    rrs.scopeOriginSystem AS resourceType,
    rrs.roleId,
    rrs.roleDisplayName AS roleName,
    rrs.roleDescription
FROM dbo.$AssignmentsTable a
    INNER JOIN dbo.$UsersTable u ON a.targetId = u.id
    INNER JOIN dbo.$AccessPackagesTable ap ON a.accessPackageId = ap.id
    INNER JOIN dbo.$CatalogsTable c ON ap.catalogId = c.id
    INNER JOIN dbo.$ResourceRoleScopesTable rrs ON ap.id = rrs.accessPackageId
    LEFT JOIN dbo.$GroupsTable g ON rrs.scopeOriginId = g.id
WHERE a.assignmentState = 'delivered'  -- Only active assignments
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

        # View 8: Access Package Assignment Details (with Request Type)
        # Shows HOW each access package was assigned (automatic, requested, admin)
        $view8Name = "vw_AccessPackageAssignmentDetails"
        $view8Sql = @"
-- Access Package Assignment Details View
-- Shows how each access package assignment was granted (automatic, user-requested, or admin-assigned)
CREATE VIEW dbo.$view8Name AS
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

        # View 9: Automatic Assignments
        # Shows assignments automatically granted by system based on policy rules
        $view9Name = "vw_AutomaticAssignments"
        $view9Sql = @"
-- Automatic Assignments View
-- Shows access package assignments that were automatically granted based on policy rules
CREATE VIEW dbo.$view9Name AS
SELECT
    assignmentId,
    userId,
    userPrincipalName,
    userDisplayName,
    accessPackageId,
    accessPackageName,
    catalogName,
    assignmentState,
    requestCreatedDateTime,
    'Automatic (Policy Rule)' AS assignmentMethod
FROM dbo.vw_AccessPackageAssignmentDetails
WHERE requestType = 'SystemAdd'
"@

        # View 10: Requested Assignments
        # Shows assignments that were user-requested (may have required approval)
        $view10Name = "vw_RequestedAssignments"
        $view10Sql = @"
-- Requested Assignments View
-- Shows access package assignments that were requested by users (includes approval info)
CREATE VIEW dbo.$view10Name AS
SELECT
    assignmentId,
    userId,
    userPrincipalName,
    userDisplayName,
    accessPackageId,
    accessPackageName,
    catalogName,
    assignmentState,
    requestState,
    requestStatus,
    justification,
    requestCreatedDateTime,
    requestCompletedDateTime,
    DATEDIFF(day, requestCreatedDateTime, requestCompletedDateTime) AS daysToApprove,
    'User Requested' AS assignmentMethod
FROM dbo.vw_AccessPackageAssignmentDetails
WHERE requestType = 'UserAdd'
"@

        # View 11: Admin Assignments
        # Shows assignments directly made by administrators
        $view11Name = "vw_AdminAssignments"
        $view11Sql = @"
-- Admin Assignments View
-- Shows access package assignments that were directly made by administrators
CREATE VIEW dbo.$view11Name AS
SELECT
    assignmentId,
    userId,
    userPrincipalName,
    userDisplayName,
    accessPackageId,
    accessPackageName,
    catalogName,
    assignmentState,
    requestCreatedDateTime,
    'Admin Assigned' AS assignmentMethod
FROM dbo.vw_AccessPackageAssignmentDetails
WHERE requestType = 'AdminAdd'
"@

        # View 12: Last Access Review Per Access Package
        # Shows when each access package was last reviewed and by whom
        $view12Name = "vw_AccessPackageLastReview"
        $view12Sql = @"
-- Last Access Review View
-- Shows when each access package was last reviewed and by which user (actual reviewer)
CREATE VIEW dbo.$view12Name AS
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
        $view13Name = "vw_ApprovedRequestTimeline"
        $view13Sql = @"
-- Approved Request Timeline View
-- Shows access package requests that were approved with response time metrics
CREATE VIEW dbo.$view13Name AS
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
        $view14Name = "vw_DeniedRequestTimeline"
        $view14Sql = @"
-- Denied Request Timeline View
-- Shows access package requests that were denied with response time metrics
CREATE VIEW dbo.$view14Name AS
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
        $view15Name = "vw_PendingRequestTimeline"
        $view15Sql = @"
-- Pending Request Timeline View
-- Shows access package requests that are still pending approval with days waiting
CREATE VIEW dbo.$view15Name AS
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
        $view16Name = "vw_RequestResponseMetrics"
        $view16Sql = @"
-- Request Response Metrics View (Aggregate)
-- Shows average, median, min, max response times and approval rates by access package
CREATE VIEW dbo.$view16Name AS
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
            @{ Name = $view10Name; SQL = $view10Sql },
            @{ Name = $view11Name; SQL = $view11Sql },
            @{ Name = $view12Name; SQL = $view12Sql },
            @{ Name = $view13Name; SQL = $view13Sql },
            @{ Name = $view14Name; SQL = $view14Sql },
            @{ Name = $view15Name; SQL = $view15Sql },
            @{ Name = $view16Name; SQL = $view16Sql }
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
