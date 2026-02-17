import { Router } from 'express';
import { users, groups, permissionAssignments, unmanagedPermissions } from '../mock/data.js';

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

// GET /api/unmanaged - vw_UnmanagedPermissions
router.get('/unmanaged', async (req, res) => {
  try {
    if (useSql) {
      const result = await db.query('SELECT * FROM vw_UnmanagedPermissions');
      return res.json(result.recordset);
    }
    res.json(unmanagedPermissions);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// GET /api/users - GraphUsers
router.get('/users', async (req, res) => {
  try {
    if (useSql) {
      const result = await db.query('SELECT id, displayName, userPrincipalName, department, jobTitle FROM GraphUsers');
      return res.json(result.recordset);
    }
    res.json(users);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// GET /api/groups - GraphGroups
router.get('/groups', async (req, res) => {
  try {
    if (useSql) {
      const result = await db.query('SELECT id, displayName, description FROM GraphGroups');
      return res.json(result.recordset);
    }
    res.json(groups);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

export default router;
