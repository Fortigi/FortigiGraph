import { Router } from 'express';
import * as db from '../db/connection.js';

const router = Router();

const useSql = process.env.USE_SQL === 'true';
const SYSTEM_COLS = new Set(['SysStartTime', 'SysEndTime']);

function cleanRow(row) {
  const clean = {};
  for (const [key, value] of Object.entries(row)) {
    if (!SYSTEM_COLS.has(key)) clean[key] = value;
  }
  return clean;
}

// ────────────────────────────────────────────────────────────────
// GET /api/user/:id — Full user detail with memberships, APs, history
// ────────────────────────────────────────────────────────────────
router.get('/user/:id', async (req, res) => {
  if (!useSql) return res.json({ attributes: {}, tags: [], memberships: [], accessPackages: [], history: [] });
  try {
    const pool = await db.getPool();
    const userId = req.params.id;

    // 1. Current attributes
    const userResult = await pool.request()
      .input('id', userId)
      .query('SELECT * FROM GraphUsers WHERE id = @id');

    if (userResult.recordset.length === 0) {
      return res.status(404).json({ error: 'User not found' });
    }
    const attributes = cleanRow(userResult.recordset[0]);

    // 2. Tags
    let tags = [];
    try {
      const r = await pool.request().input('id', userId).query(`
        SELECT t.id, t.name, t.color
        FROM GraphTagAssignments ta
        JOIN GraphTags t ON ta.tagId = t.id
        WHERE ta.entityId = @id AND t.entityType = 'user'
      `);
      tags = r.recordset;
    } catch { /* table may not exist */ }

    // 3. Group memberships (via permission view)
    let memberships = [];
    try {
      let table = 'vw_UserPermissionAssignments';
      try {
        await pool.request().query('SELECT TOP 0 * FROM mat_UserPermissionAssignments');
        table = 'mat_UserPermissionAssignments';
      } catch { /* use view */ }

      const r = await pool.request().input('id', userId).query(`
        SELECT groupId, groupDisplayName, groupTypeCalculated,
               membershipType, managedByAccessPackage
        FROM ${table}
        WHERE memberId = @id
        ORDER BY groupDisplayName, membershipType
      `);
      memberships = r.recordset;
    } catch { /* view may not exist */ }

    // 4. Access package assignments
    let accessPackages = [];
    try {
      const r = await pool.request().input('id', userId).query(`
        SELECT DISTINCT
          a.accessPackageId,
          ap.displayName AS accessPackageName,
          a.assignmentState AS state,
          a.assignedDateTime
        FROM GraphAccessPackageAssignments a
        LEFT JOIN GraphAccessPackages ap ON a.accessPackageId = ap.id
        WHERE a.targetId = @id
        ORDER BY ap.displayName
      `);
      accessPackages = r.recordset;
    } catch { /* table may not exist */ }

    // 5. Version history (temporal table)
    let history = [];
    try {
      const r = await pool.request().input('id', userId).query(`
        SELECT * FROM GraphUsers FOR SYSTEM_TIME ALL
        WHERE id = @id
        ORDER BY ValidFrom DESC
      `);
      history = r.recordset.map(cleanRow);
    } catch {
      // Not temporal or syntax unsupported — return current only
      history = [attributes];
    }

    res.json({ attributes, tags, memberships, accessPackages, history });
  } catch (err) {
    console.error('Error fetching user detail:', err.message);
    res.status(500).json({ error: 'Failed to fetch user details' });
  }
});

// ────────────────────────────────────────────────────────────────
// GET /api/group/:id — Full group detail with members, APs, history
// ────────────────────────────────────────────────────────────────
router.get('/group/:id', async (req, res) => {
  if (!useSql) return res.json({ attributes: {}, tags: [], members: [], accessPackages: [], history: [] });
  try {
    const pool = await db.getPool();
    const groupId = req.params.id;

    // 1. Current attributes
    const groupResult = await pool.request()
      .input('id', groupId)
      .query('SELECT * FROM GraphGroups WHERE id = @id');

    if (groupResult.recordset.length === 0) {
      return res.status(404).json({ error: 'Group not found' });
    }
    const attributes = cleanRow(groupResult.recordset[0]);

    // 2. Tags
    let tags = [];
    try {
      const r = await pool.request().input('id', groupId).query(`
        SELECT t.id, t.name, t.color
        FROM GraphTagAssignments ta
        JOIN GraphTags t ON ta.tagId = t.id
        WHERE ta.entityId = @id AND t.entityType = 'group'
      `);
      tags = r.recordset;
    } catch { /* table may not exist */ }

    // 3. Members (via permission view)
    let members = [];
    try {
      let table = 'vw_UserPermissionAssignments';
      try {
        await pool.request().query('SELECT TOP 0 * FROM mat_UserPermissionAssignments');
        table = 'mat_UserPermissionAssignments';
      } catch { /* use view */ }

      const r = await pool.request().input('id', groupId).query(`
        SELECT memberId, memberDisplayName, memberUPN,
               membershipType, managedByAccessPackage
        FROM ${table}
        WHERE groupId = @id
        ORDER BY memberDisplayName, membershipType
      `);
      members = r.recordset;
    } catch { /* view may not exist */ }

    // 4. Access packages that include this group
    let accessPackages = [];
    try {
      const r = await pool.request().input('id', groupId).query(`
        SELECT DISTINCT
          rrs.accessPackageId,
          ap.displayName AS accessPackageName,
          rrs.roleDisplayName AS roleName
        FROM GraphAccessPackageResourceRoleScopes rrs
        LEFT JOIN GraphAccessPackages ap ON rrs.accessPackageId = ap.id
        WHERE UPPER(rrs.scopeOriginId) = UPPER(@id)
          AND rrs.scopeOriginSystem = 'AadGroup'
        ORDER BY ap.displayName
      `);
      accessPackages = r.recordset;
    } catch { /* table may not exist */ }

    // 5. Version history (temporal table)
    let history = [];
    try {
      const r = await pool.request().input('id', groupId).query(`
        SELECT * FROM GraphGroups FOR SYSTEM_TIME ALL
        WHERE id = @id
        ORDER BY ValidFrom DESC
      `);
      history = r.recordset.map(cleanRow);
    } catch {
      history = [attributes];
    }

    res.json({ attributes, tags, members, accessPackages, history });
  } catch (err) {
    console.error('Error fetching group detail:', err.message);
    res.status(500).json({ error: 'Failed to fetch group details' });
  }
});

export default router;
