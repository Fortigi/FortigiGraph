import { Router } from 'express';
import { permissionAssignments } from '../mock/data.js';

const router = Router();
const useSql = process.env.USE_SQL === 'true';

let db = null;
if (useSql) {
  db = await import('../db/connection.js');
}

// GET /api/permissions - vw_UserPermissionAssignments enriched with display names
// Optional query params: userLimit (int) - limit to top N users by assignment count
router.get('/permissions', async (req, res) => {
  try {
    const userLimit = parseInt(req.query.userLimit) || 0;

    if (useSql) {
      const p = await db.getPool();
      const request = p.request();

      let dataSql;
      if (userLimit > 0) {
        request.input('userLimit', userLimit);
        dataSql = `
          WITH TopUsers AS (
            SELECT TOP (@userLimit) p.memberId
            FROM vw_UserPermissionAssignments p
            WHERE p.memberType != '#microsoft.graph.group'
            GROUP BY p.memberId
            ORDER BY COUNT(*) DESC
          )
          SELECT
            p.groupId,
            g.displayName AS groupDisplayName,
            g.groupTypeCalculated,
            g.description AS groupDescription,
            p.memberId,
            u.displayName AS memberDisplayName,
            u.userPrincipalName AS memberUPN,
            p.memberType,
            p.membershipType,
            u.department,
            u.jobTitle,
            u.companyName,
            u.accountEnabled,
            u.userType,
            u.employeeType,
            p.managedByAccessPackage
          FROM vw_UserPermissionAssignments p
          LEFT JOIN GraphUsers u ON p.memberId = u.id
          LEFT JOIN GraphGroups g ON p.groupId = g.id
          WHERE p.memberType != '#microsoft.graph.group'
            AND p.memberId IN (SELECT memberId FROM TopUsers);

          SELECT COUNT(DISTINCT p.memberId) AS totalUsers
          FROM vw_UserPermissionAssignments p
          WHERE p.memberType != '#microsoft.graph.group';
        `;
      } else {
        dataSql = `
          SELECT
            p.groupId,
            g.displayName AS groupDisplayName,
            g.groupTypeCalculated,
            g.description AS groupDescription,
            p.memberId,
            u.displayName AS memberDisplayName,
            u.userPrincipalName AS memberUPN,
            p.memberType,
            p.membershipType,
            u.department,
            u.jobTitle,
            u.companyName,
            u.accountEnabled,
            u.userType,
            u.employeeType,
            p.managedByAccessPackage
          FROM vw_UserPermissionAssignments p
          LEFT JOIN GraphUsers u ON p.memberId = u.id
          LEFT JOIN GraphGroups g ON p.groupId = g.id
          WHERE p.memberType != '#microsoft.graph.group';
        `;
      }

      const result = await request.query(dataSql);

      if (userLimit > 0) {
        return res.json({
          data: result.recordsets[0],
          totalUsers: result.recordsets[1][0].totalUsers,
        });
      }
      return res.json({
        data: result.recordset,
        totalUsers: new Set(result.recordset.map(r => r.memberId)).size,
      });
    }

    // Mock data path
    let mockData = permissionAssignments;
    const allUserIds = [...new Set(mockData.map(r => r.memberId))];
    if (userLimit > 0) {
      const userCounts = {};
      mockData.forEach(r => { userCounts[r.memberId] = (userCounts[r.memberId] || 0) + 1; });
      const topUserIds = new Set(
        Object.entries(userCounts)
          .sort((a, b) => b[1] - a[1])
          .slice(0, userLimit)
          .map(e => e[0])
      );
      mockData = mockData.filter(r => topUserIds.has(r.memberId));
    }
    res.json({ data: mockData, totalUsers: allUserIds.length });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// GET /api/access-package-groups - Access package to group mapping
router.get('/access-package-groups', async (req, res) => {
  try {
    if (useSql) {
      const result = await db.query(`
        SELECT
          rrs.accessPackageId,
          ap.displayName AS accessPackageName,
          c.displayName  AS catalogName,
          UPPER(rrs.scopeOriginId) AS groupId,
          g.displayName  AS groupName,
          rrs.roleDisplayName AS roleName
        FROM dbo.GraphAccessPackageResourceRoleScopes rrs
        INNER JOIN dbo.GraphAccessPackages ap ON rrs.accessPackageId = ap.id
        INNER JOIN dbo.GraphCatalogs c ON ap.catalogId = c.id
        LEFT  JOIN dbo.GraphGroups g ON UPPER(rrs.scopeOriginId) = g.id
        WHERE rrs.scopeOriginSystem = 'AadGroup'
      `);
      return res.json(result.recordset);
    }
    res.json([]);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// GET /api/sync-log - Recent sync log entries from GraphSyncLog
router.get('/sync-log', async (req, res) => {
  try {
    const limit = Math.min(Math.max(parseInt(req.query.limit) || 20, 1), 100);

    if (useSql) {
      const p = await db.getPool();
      const request = p.request();
      request.input('limit', limit);

      // Check if GraphSyncLog table exists before querying
      const tableCheck = await request.query(`
        SELECT OBJECT_ID('dbo.GraphSyncLog', 'U') AS tableExists
      `);
      if (!tableCheck.recordset[0].tableExists) {
        return res.json([]);
      }

      const result = await p.request().input('limit', limit).query(`
        SELECT TOP (@limit)
          Id, SyncType, StartTime, EndTime, DurationSeconds,
          RecordCount, Status, ErrorMessage, TableName, CreatedAt
        FROM dbo.GraphSyncLog
        ORDER BY StartTime DESC
      `);
      return res.json(result.recordset);
    }

    // Mock data: generate realistic sync log entries
    const syncTypes = [
      { type: 'Users', table: 'GraphUsers', records: 1247 },
      { type: 'Groups', table: 'GraphGroups', records: 389 },
      { type: 'GroupMembers', table: 'GraphGroupMembers', records: 4521 },
      { type: 'GroupTransitiveMembers', table: 'GraphGroupTransitiveMembers', records: 8932 },
      { type: 'GroupEligibleMembers', table: 'GraphGroupEligibleMembers', records: 156 },
      { type: 'GroupOwners', table: 'GraphGroupOwners', records: 412 },
      { type: 'Catalogs', table: 'GraphCatalogs', records: 12 },
      { type: 'AccessPackages', table: 'GraphAccessPackages', records: 67 },
      { type: 'AccessPackageAssignments', table: 'GraphAccessPackageAssignments', records: 834 },
      { type: 'AccessPackageResourceRoleScopes', table: 'GraphAccessPackageResourceRoleScopes', records: 203 },
      { type: 'AccessPackageAssignmentPolicies', table: 'GraphAccessPackageAssignmentPolicies', records: 71 },
      { type: 'AccessPackageAssignmentRequests', table: 'GraphAccessPackageAssignmentRequests', records: 2103 },
      { type: 'AccessPackageAccessReviews', table: 'GraphAccessPackageAccessReviews', records: 45 },
    ];
    const mockLogs = [];
    let id = 1;
    // Generate 2 full sync runs
    for (let run = 0; run < 2; run++) {
      const baseTime = new Date(Date.now() - (run * 24 * 60 * 60 * 1000) - (2 * 60 * 60 * 1000));
      let offset = 0;
      for (const st of syncTypes) {
        const duration = Math.floor(Math.random() * 120) + 5;
        const start = new Date(baseTime.getTime() + offset * 1000);
        const end = new Date(start.getTime() + duration * 1000);
        const isFailed = run === 1 && st.type === 'AccessPackageAccessReviews';
        mockLogs.push({
          Id: id++,
          SyncType: st.type,
          StartTime: start.toISOString(),
          EndTime: end.toISOString(),
          DurationSeconds: duration,
          RecordCount: isFailed ? 0 : st.records + Math.floor(Math.random() * 20),
          Status: isFailed ? 'Failed' : 'Success',
          ErrorMessage: isFailed ? 'The remote server returned an error: (403) Forbidden.' : null,
          TableName: st.table,
          CreatedAt: end.toISOString(),
        });
        offset += duration + 2;
      }
    }
    mockLogs.sort((a, b) => new Date(b.StartTime) - new Date(a.StartTime));
    res.json(mockLogs.slice(0, limit));
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

export default router;
