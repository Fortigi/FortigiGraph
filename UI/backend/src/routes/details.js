import { Router } from 'express';
import * as db from '../db/connection.js';
import { timedRequest } from '../perf/sqlTimer.js';

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

async function getPermissionTable(pool) {
  try {
    await pool.request().query('SELECT TOP 0 * FROM mat_UserPermissionAssignments');
    return 'mat_UserPermissionAssignments';
  } catch {
    return 'vw_UserPermissionAssignments';
  }
}

// ────────────────────────────────────────────────────────────────
// GET /api/user/:id — Lightweight: attributes, tags, counts only
// ────────────────────────────────────────────────────────────────
router.get('/user/:id', async (req, res) => {
  if (!useSql) return res.json({ attributes: {}, tags: [], membershipCount: 0, accessPackageCount: 0, hasHistory: false });
  try {
    const pool = await db.getPool();
    const userId = req.params.id;

    // 1. Current attributes
    const userResult = await timedRequest(pool, 'user-attributes', res)
      .input('id', userId)
      .query('SELECT * FROM GraphUsers WHERE id = @id');

    if (userResult.recordset.length === 0) {
      return res.status(404).json({ error: 'User not found' });
    }
    const attributes = cleanRow(userResult.recordset[0]);

    // 2. Tags
    let tags = [];
    try {
      const r = await timedRequest(pool, 'user-tags', res)
        .input('id', userId)
        .query(`
        SELECT t.id, t.name, t.color
        FROM GraphTagAssignments ta
        JOIN GraphTags t ON ta.tagId = t.id
        WHERE ta.entityId = @id AND t.entityType = 'user'
      `);
      tags = r.recordset;
    } catch { /* table may not exist */ }

    // 3. Counts only (fast)
    let membershipCount = 0;
    try {
      const table = await getPermissionTable(pool);
      const r = await timedRequest(pool, 'user-membership-count', res)
        .input('id', userId)
        .query(`
        SELECT COUNT(DISTINCT groupId) AS cnt FROM ${table} WHERE memberId = @id
      `);
      membershipCount = r.recordset[0].cnt;
    } catch { /* view may not exist */ }

    let accessPackageCount = 0;
    try {
      const r = await timedRequest(pool, 'user-ap-count', res)
        .input('id', userId)
        .query(`
        SELECT COUNT(DISTINCT accessPackageId) AS cnt
        FROM GraphAccessPackageAssignments WHERE targetId = @id
      `);
      accessPackageCount = r.recordset[0].cnt;
    } catch { /* table may not exist */ }

    let hasHistory = false;
    try {
      const r = await timedRequest(pool, 'user-history-check', res)
        .input('id', userId)
        .query(`
        SELECT TOP 1 1 AS found FROM GraphUsers FOR SYSTEM_TIME ALL
        WHERE id = @id AND ValidTo <> '9999-12-31 23:59:59.9999999'
      `);
      hasHistory = r.recordset.length > 0;
    } catch {
      hasHistory = false;
    }

    res.json({ attributes, tags, membershipCount, accessPackageCount, hasHistory });
  } catch (err) {
    console.error('Error fetching user detail:', err.message);
    res.status(500).json({ error: 'Failed to fetch user details' });
  }
});

// ────────────────────────────────────────────────────────────────
// GET /api/user/:id/memberships — Lazy-loaded group memberships
// ────────────────────────────────────────────────────────────────
router.get('/user/:id/memberships', async (req, res) => {
  if (!useSql) return res.json([]);
  try {
    const pool = await db.getPool();
    const table = await getPermissionTable(pool);
    const r = await timedRequest(pool, 'user-memberships', res)
      .input('id', req.params.id)
      .query(`
      SELECT groupId, groupDisplayName, groupTypeCalculated,
             membershipType, managedByAccessPackage
      FROM ${table}
      WHERE memberId = @id
      ORDER BY groupDisplayName, membershipType
    `);
    res.json(r.recordset);
  } catch (err) {
    console.error('Error fetching user memberships:', err.message);
    res.status(500).json({ error: 'Failed to fetch memberships' });
  }
});

// ────────────────────────────────────────────────────────────────
// GET /api/user/:id/access-packages — Lazy-loaded AP assignments
// ────────────────────────────────────────────────────────────────
router.get('/user/:id/access-packages', async (req, res) => {
  if (!useSql) return res.json([]);
  try {
    const pool = await db.getPool();
    const r = await timedRequest(pool, 'user-access-packages', res)
      .input('id', req.params.id)
      .query(`
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
    res.json(r.recordset);
  } catch (err) {
    console.error('Error fetching user access packages:', err.message);
    res.status(500).json({ error: 'Failed to fetch access packages' });
  }
});

// ────────────────────────────────────────────────────────────────
// GET /api/user/:id/history — Lazy-loaded version history
// ────────────────────────────────────────────────────────────────
router.get('/user/:id/history', async (req, res) => {
  if (!useSql) return res.json([]);
  try {
    const pool = await db.getPool();
    const r = await timedRequest(pool, 'user-history', res)
      .input('id', req.params.id)
      .query(`
      SELECT * FROM GraphUsers FOR SYSTEM_TIME ALL
      WHERE id = @id
      ORDER BY ValidFrom DESC
    `);
    res.json(r.recordset.map(cleanRow));
  } catch (err) {
    // Not temporal — return empty
    res.json([]);
  }
});

// ────────────────────────────────────────────────────────────────
// GET /api/group/:id — Lightweight: attributes, tags, counts only
// ────────────────────────────────────────────────────────────────
router.get('/group/:id', async (req, res) => {
  if (!useSql) return res.json({ attributes: {}, tags: [], memberCount: 0, accessPackageCount: 0, hasHistory: false });
  try {
    const pool = await db.getPool();
    const groupId = req.params.id;

    // 1. Current attributes
    const groupResult = await timedRequest(pool, 'group-attributes', res)
      .input('id', groupId)
      .query('SELECT * FROM GraphGroups WHERE id = @id');

    if (groupResult.recordset.length === 0) {
      return res.status(404).json({ error: 'Group not found' });
    }
    const attributes = cleanRow(groupResult.recordset[0]);

    // 2. Tags
    let tags = [];
    try {
      const r = await timedRequest(pool, 'group-tags', res)
        .input('id', groupId)
        .query(`
        SELECT t.id, t.name, t.color
        FROM GraphTagAssignments ta
        JOIN GraphTags t ON ta.tagId = t.id
        WHERE ta.entityId = @id AND t.entityType = 'group'
      `);
      tags = r.recordset;
    } catch { /* table may not exist */ }

    // 3. Counts only (fast)
    let memberCount = 0;
    try {
      const table = await getPermissionTable(pool);
      const r = await timedRequest(pool, 'group-member-count', res)
        .input('id', groupId)
        .query(`
        SELECT COUNT(DISTINCT memberId) AS cnt FROM ${table} WHERE groupId = @id
      `);
      memberCount = r.recordset[0].cnt;
    } catch { /* view may not exist */ }

    let accessPackageCount = 0;
    try {
      const r = await timedRequest(pool, 'group-ap-count', res)
        .input('id', groupId)
        .query(`
        SELECT COUNT(DISTINCT rrs.accessPackageId) AS cnt
        FROM GraphAccessPackageResourceRoleScopes rrs
        WHERE UPPER(rrs.scopeOriginId) = UPPER(@id)
          AND rrs.scopeOriginSystem = 'AadGroup'
      `);
      accessPackageCount = r.recordset[0].cnt;
    } catch { /* table may not exist */ }

    let hasHistory = false;
    try {
      const r = await timedRequest(pool, 'group-history-check', res)
        .input('id', groupId)
        .query(`
        SELECT TOP 1 1 AS found FROM GraphGroups FOR SYSTEM_TIME ALL
        WHERE id = @id AND ValidTo <> '9999-12-31 23:59:59.9999999'
      `);
      hasHistory = r.recordset.length > 0;
    } catch {
      hasHistory = false;
    }

    res.json({ attributes, tags, memberCount, accessPackageCount, hasHistory });
  } catch (err) {
    console.error('Error fetching group detail:', err.message);
    res.status(500).json({ error: 'Failed to fetch group details' });
  }
});

// ────────────────────────────────────────────────────────────────
// GET /api/group/:id/members — Lazy-loaded group members
// ────────────────────────────────────────────────────────────────
router.get('/group/:id/members', async (req, res) => {
  if (!useSql) return res.json([]);
  try {
    const pool = await db.getPool();
    const table = await getPermissionTable(pool);
    const r = await timedRequest(pool, 'group-members', res)
      .input('id', req.params.id)
      .query(`
      SELECT memberId, memberDisplayName, memberUPN,
             membershipType, managedByAccessPackage
      FROM ${table}
      WHERE groupId = @id
      ORDER BY memberDisplayName, membershipType
    `);
    res.json(r.recordset);
  } catch (err) {
    console.error('Error fetching group members:', err.message);
    res.status(500).json({ error: 'Failed to fetch members' });
  }
});

// ────────────────────────────────────────────────────────────────
// GET /api/group/:id/access-packages — Lazy-loaded APs for group
// ────────────────────────────────────────────────────────────────
router.get('/group/:id/access-packages', async (req, res) => {
  if (!useSql) return res.json([]);
  try {
    const pool = await db.getPool();
    const r = await timedRequest(pool, 'group-access-packages', res)
      .input('id', req.params.id)
      .query(`
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
    res.json(r.recordset);
  } catch (err) {
    console.error('Error fetching group access packages:', err.message);
    res.status(500).json({ error: 'Failed to fetch access packages' });
  }
});

// ────────────────────────────────────────────────────────────────
// GET /api/group/:id/history — Lazy-loaded version history
// ────────────────────────────────────────────────────────────────
router.get('/group/:id/history', async (req, res) => {
  if (!useSql) return res.json([]);
  try {
    const pool = await db.getPool();
    const r = await timedRequest(pool, 'group-history', res)
      .input('id', req.params.id)
      .query(`
      SELECT * FROM GraphGroups FOR SYSTEM_TIME ALL
      WHERE id = @id
      ORDER BY ValidFrom DESC
    `);
    res.json(r.recordset.map(cleanRow));
  } catch (err) {
    res.json([]);
  }
});

export default router;
