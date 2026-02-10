import { Router } from 'express';
import { users, groups, permissionAssignments, unmanagedPermissions } from '../mock/data.js';

const router = Router();
const useSql = process.env.USE_SQL === 'true';

let db = null;
if (useSql) {
  db = await import('../db/connection.js');
}

// GET /api/permissions - vw_UserPermissionAssignments
router.get('/permissions', async (req, res) => {
  try {
    if (useSql) {
      const result = await db.query('SELECT * FROM vw_UserPermissionAssignments');
      return res.json(result.recordset);
    }
    res.json(permissionAssignments);
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
