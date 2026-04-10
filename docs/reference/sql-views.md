# SQL Views

FortigiGraph creates a set of SQL views automatically during sync. These views handle the heavy lifting — recursive membership resolution, IST/SOLL gap analysis, approval timeline metrics — so your queries stay simple.

Views are created by the relevant `Initialize-FG*Views` function and refreshed automatically by `Start-FGSync`. You can also run the initializers directly after a schema change.

---

## Resource Permission Views

Created by `Initialize-FGResourceViews`.

| View | Purpose |
|------|---------|
| `vw_ResourceMembersRecursive` | All memberships (direct + indirect via nested groups) using a recursive CTE. Cycle-safe, max 10 levels deep. Includes the full membership path. |
| `vw_ResourceUserPermissionAssignments` | All assignment types (Direct, Indirect, Owner, Eligible, CrossResourceIndirect) in a single queryable surface. Includes the `managedByAccessPackage` flag for IST vs SOLL analysis. |

```sql
-- Who has access to a specific resource, including indirect memberships?
SELECT principalId, displayName, assignmentType, depth, membershipPath
FROM vw_ResourceMembersRecursive
WHERE resourceId = 'your-resource-guid'
ORDER BY depth;

-- A user's complete permission picture across all resources
SELECT resourceId, resourceName, assignmentType, managedByAccessPackage
FROM vw_ResourceUserPermissionAssignments
WHERE principalId = 'user-guid-here';

-- How many permissions does each user hold?
SELECT principalId, displayName, COUNT(*) AS permissionCount
FROM vw_ResourceUserPermissionAssignments
GROUP BY principalId, displayName
ORDER BY permissionCount DESC;
```

---

## Governance Analysis Views

Created by `Initialize-FGAccessPackageViews`.

| View | Purpose |
|------|---------|
| `vw_UserPermissionAssignmentViaBusinessRole` | Maps users through business roles to the resources those roles grant |
| `vw_DirectGroupMemberships` | Direct memberships that are **not** governed by a business role (IST vs SOLL gap) |
| `vw_DirectGroupOwnerships` | Direct ownerships that are not governed by a business role |
| `vw_UnmanagedPermissions` | Union of unmanaged memberships and ownerships — the full IST/SOLL gap |
| `vw_BusinessRoleAssignmentDetails` | How each business role was assigned: automatic, requested, or admin-assigned |
| `vw_BusinessRoleLastReview` | Most recent certification review per business role |
| `vw_ApprovedRequestTimeline` | Approved requests with full response time metrics and time-bucket breakdown |
| `vw_DeniedRequestTimeline` | Denied requests with response time analysis |
| `vw_PendingRequestTimeline` | Pending requests with aging metrics and an `isOverdue` flag (threshold: 7 days) |
| `vw_RequestResponseMetrics` | Aggregate approval statistics per business role (avg, min, max response hours) |

```sql
-- Find all permissions that exist outside of business role governance
SELECT principalId, displayName, resourceId, resourceName, assignmentType
FROM vw_UnmanagedPermissions
ORDER BY displayName;

-- Average approval time per business role
SELECT resourceId, resourceName, avgResponseHours, totalApproved
FROM vw_RequestResponseMetrics
ORDER BY avgResponseHours DESC;

-- Pending requests older than 24 hours
SELECT resourceId, resourceName, principalId, requestedDateTime, hoursPending, isOverdue
FROM vw_PendingRequestTimeline
WHERE hoursPending > 24
ORDER BY hoursPending DESC;

-- Last review date per business role
SELECT resourceId, resourceName, lastReviewDateTime, lastDecision
FROM vw_BusinessRoleLastReview
ORDER BY lastReviewDateTime ASC;
```

---

## Materialized Views

For large environments, the recursive and multi-join views above can be slow to query on every page load. `Sync-FGMaterializedViews` pre-computes the most expensive views into indexed tables that the UI queries directly.

| Materialized Table | Source View | Why It Exists |
|---|---|---|
| `mat_UserPermissionAssignmentViaBusinessRole` | `vw_UserPermissionAssignmentViaBusinessRole` | Eliminates multi-table join on every business role lookup |
| `mat_UserPermissionAssignments` | `vw_ResourceUserPermissionAssignments` | Eliminates recursive CTE on every matrix page load |
| `mat_UserCounts` | Aggregation over assignments | "Top N users by permission count" becomes an instant index scan |

```powershell
# Refresh all materialized views manually (also runs at end of Start-FGSync)
Sync-FGMaterializedViews
```

!!! note
    Materialized tables contain a point-in-time snapshot. They are refreshed at the end of each sync run. For real-time accuracy, query the underlying views directly.

---

## Historical Queries

All core tables (`Principals`, `Resources`, `ResourceAssignments`, etc.) are tracked by the `_history` audit table via PostgreSQL triggers. Every insert, update, and delete is recorded as a JSONB snapshot, enabling full change history queries.

```sql
-- Current data (standard query, no change needed)
SELECT * FROM "Principals" WHERE department = 'Finance';

-- Full change history for a specific principal
SELECT "changedAt", operation, "rowData", "prevData"
FROM "_history"
WHERE "tableName" = 'Principals'
  AND "rowId" = 'principal-guid-here'
ORDER BY "changedAt" DESC;

-- All assignment changes in the last 30 days
SELECT "rowId", operation, "changedAt", "rowData"
FROM "_history"
WHERE "tableName" = 'ResourceAssignments'
  AND "changedAt" >= now() - interval '30 days'
ORDER BY "changedAt" DESC;

-- Deleted resources (no longer in the current table)
SELECT "rowId", "changedAt", "rowData"->>'displayName' AS name
FROM "_history"
WHERE "tableName" = 'Resources'
  AND operation = 'D'
ORDER BY "changedAt" DESC;
```

For more on audit history usage and query patterns, see [Audit History & Historical Queries](temporal-tables.md).
