# Access Package Sync Configuration Example

This document shows how to configure the new access package sync operations in your config file.

## Complete Sync Section Example

Add these sections to your `config.json` file under the `Sync` object:

```json
{
  "Azure": {
    // ... your Azure config ...
  },
  "Graph": {
    // ... your Graph config ...
  },
  "Sync": {
    "ParallelExecution": true,

    "Users": {
      "Enabled": true,
      "TableName": "GraphUsers",
      "Filter": "",
      "AdditionalAttributes": []
    },

    "Groups": {
      "Enabled": true,
      "TableName": "GraphGroups",
      "Filter": ""
    },

    "GroupMembers": {
      "Enabled": true,
      "TableName": "GraphGroupMembers"
    },

    "GroupEligibleMembers": {
      "Enabled": true,
      "TableName": "GraphGroupEligibleMembers"
    },

    "GroupOwners": {
      "Enabled": true,
      "TableName": "GraphGroupOwners"
    },

    "Catalogs": {
      "Enabled": true,
      "TableName": "GraphCatalogs"
    },

    "AccessPackages": {
      "Enabled": true,
      "TableName": "GraphAccessPackages"
    },

    "AccessPackageAssignments": {
      "Enabled": true,
      "TableName": "GraphAccessPackageAssignments"
    },

    "AccessPackageResourceRoleScopes": {
      "Enabled": true,
      "TableName": "GraphAccessPackageResourceRoleScopes"
    },

    "AccessPackageAssignmentPolicies": {
      "Enabled": true,
      "TableName": "GraphAccessPackageAssignmentPolicies"
    },

    "AccessPackageAssignmentRequests": {
      "Enabled": true,
      "TableName": "GraphAccessPackageAssignmentRequests"
    },

    "AccessPackageAccessReviews": {
      "Enabled": true,
      "TableName": "GraphAccessPackageAccessReviewDecisions"
    },

    "Views": {
      "Enabled": true
    }
  }
}
```

## New Sections Explained

### AccessPackageAssignmentPolicies
- **Purpose**: Syncs assignment policies that define how users can request access
- **Contains**: Policy rules, automatic assignment settings, approval requirements
- **Used by views**: `vw_AccessPackageAssignmentDetails`, `vw_AutomaticAssignments`
- **Default table**: `GraphAccessPackageAssignmentPolicies`

### AccessPackageAssignmentRequests
- **Purpose**: Syncs user requests for access packages
- **Contains**: Request type (UserAdd/AdminAdd/SystemAdd), state, status, approval timeline
- **Used by views**:
  - `vw_RequestedAssignments` - Shows approval status and days to approve
  - `vw_ApprovedRequestTimeline` - Shows approved requests with response metrics
  - `vw_DeniedRequestTimeline` - Shows denied requests with response metrics
  - `vw_PendingRequestTimeline` - Shows pending requests with overdue flagging
  - `vw_RequestResponseMetrics` - Aggregate approval metrics
- **Default table**: `GraphAccessPackageAssignmentRequests`

### AccessPackageAccessReviews
- **Purpose**: Syncs access review decisions for access packages
- **Contains**: Reviewer, review date, decision, justification
- **Used by views**: `vw_AccessPackageLastReview` - Shows when each package was last reviewed
- **Default table**: `GraphAccessPackageAccessReviewDecisions`

## Minimal Configuration

If you want to sync only the core access package data without the additional governance features:

```json
{
  "Sync": {
    "Catalogs": { "Enabled": true },
    "AccessPackages": { "Enabled": true },
    "AccessPackageAssignments": { "Enabled": true },
    "AccessPackageResourceRoleScopes": { "Enabled": true },
    "AccessPackageAssignmentPolicies": { "Enabled": false },
    "AccessPackageAssignmentRequests": { "Enabled": false },
    "AccessPackageAccessReviews": { "Enabled": false }
  }
}
```

## Use Cases

### 1. Full Governance Tracking
Enable all sync operations to get complete IST vs SOLL analysis with:
- Who has what access packages
- Which group memberships come from access packages
- Which memberships are direct (ungoverned)
- How access was granted (automatic/requested/admin)
- Approval timelines and response metrics
- Access review history

```json
"AccessPackageAssignmentPolicies": { "Enabled": true },
"AccessPackageAssignmentRequests": { "Enabled": true },
"AccessPackageAccessReviews": { "Enabled": true }
```

### 2. Current State Only
Disable requests and reviews if you only care about current assignments:

```json
"AccessPackageAssignmentPolicies": { "Enabled": true },
"AccessPackageAssignmentRequests": { "Enabled": false },
"AccessPackageAccessReviews": { "Enabled": false }
```

### 3. Approval Metrics Focus
Enable requests to track approval performance:

```json
"AccessPackageAssignmentPolicies": { "Enabled": true },
"AccessPackageAssignmentRequests": { "Enabled": true },
"AccessPackageAccessReviews": { "Enabled": false }
```

## Custom Table Names

You can customize table names for all sync operations:

```json
{
  "Sync": {
    "AccessPackageAssignmentRequests": {
      "Enabled": true,
      "TableName": "Custom_APRequests"
    }
  }
}
```

## Views Created

When `Views.Enabled = true`, the following 16 views are created:

### Basic Access Package Views (1-4)
1. `vw_UserAccessPackages` - User → Access Package → Catalog mapping
2. `vw_UserAccessPackageResources` - User → Access Package → Group/Resource → Role
3. `vw_UserAccessPackageGroupMemberships` - Group Member roles from access packages
4. `vw_UserAccessPackageGroupOwnerships` - Group Owner roles from access packages

### IST vs SOLL Gap Analysis (5-7)
5. `vw_DirectGroupMemberships` - Memberships NOT from access packages
6. `vw_DirectGroupOwnerships` - Ownerships NOT from access packages
7. `vw_UnmanagedPermissions` - Combined ungoverned permissions

### Assignment Method Analysis (8-11)
8. `vw_AccessPackageAssignmentDetails` - Shows how access was granted
9. `vw_AutomaticAssignments` - Policy-based automatic assignments
10. `vw_RequestedAssignments` - User-requested with approval status
11. `vw_AdminAssignments` - Admin-assigned directly

### Access Review Tracking (12)
12. `vw_AccessPackageLastReview` - Last review date and reviewer per package

### Approval Timeline Metrics (13-16) - NEW
13. `vw_ApprovedRequestTimeline` - Approved requests with response time buckets
14. `vw_DeniedRequestTimeline` - Denied requests with response time buckets
15. `vw_PendingRequestTimeline` - Pending requests with overdue flagging
16. `vw_RequestResponseMetrics` - Aggregate metrics (avg/min/max, approval rates)

## Command-Line Override

All config file settings can be overridden via command-line parameters:

```powershell
# Disable access review sync via command line
Start-FGSync -ConfigFile .\config.json -SyncAccessPackageAccessReviews:$false

# Sync only specific operations
Start-FGSync -ConfigFile .\config.json `
    -SyncUsers:$false `
    -SyncGroups:$false `
    -SyncCatalogs:$true `
    -SyncAccessPackages:$true
```

## Performance Considerations

- **Parallel Execution**: Set `ParallelExecution: true` for faster sync (recommended)
- **Sequential Execution**: Set `ParallelExecution: false` for debugging or resource-constrained environments
- **Selective Sync**: Disable operations you don't need to reduce sync time

## SQL Server Requirements

All tables support:
- **Temporal versioning** - Automatic change history tracking
- **Point-in-time queries** - Query data as it existed at any date/time
- **Bulk operations** - High-performance data loading
- **Automatic schema evolution** - Add columns without recreating tables
