import { Router } from 'express';
import { users, groups, permissionAssignments, unmanagedPermissions } from '../mock/data.js';

const router = Router();
const useSql = process.env.USE_SQL === 'true';

let db = null;
if (useSql) {
  db = await import('../db/connection.js');
}

// GET /api/permissions - vw_UserPermissionAssignments enriched with display names
router.get('/permissions', async (req, res) => {
  try {
    if (useSql) {
      const result = await db.query(`
        SELECT
          p.groupId,
          g.displayName AS groupDisplayName,
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
          u.employeeType
        FROM vw_UserPermissionAssignments p
        LEFT JOIN GraphUsers u ON p.memberId = u.id
        LEFT JOIN GraphGroups g ON p.groupId = g.id
        WHERE p.memberType != '#microsoft.graph.group'
      `);
      return res.json(result.recordset);
    }
    res.json(permissionAssignments);
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
