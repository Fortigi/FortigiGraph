// ─── OrgUnits API Routes ──────────────────────────────────────────────
//
// Reads organizational units from the OrgUnits table and builds
// hierarchy trees for org-chart visualization.
//
// GET    /api/org-units              - List all OrgUnits with hierarchy info
// GET    /api/org-units/tree         - Pre-built tree structure for org chart
// GET    /api/org-units/:id          - Single OrgUnit detail with members and sub-units
// GET    /api/org-units/:id/members  - Paginated member list

import { Router } from 'express';
import { timedRequest } from '../perf/sqlTimer.js';

const router = Router();
const useSql = process.env.USE_SQL === 'true';
const UUID_RE = /^[0-9a-f-]{36}$/i;

let db = null;
if (useSql) {
  db = await import('../db/connection.js');
}

// ─── Table detection (cached 5 min) ─────────────────────────────────

let hasOrgUnitsTable = null;
let orgUnitsCheckTime = 0;

async function checkOrgUnits(pool) {
  const now = Date.now();
  if (hasOrgUnitsTable !== null && now - orgUnitsCheckTime < 300000) return hasOrgUnitsTable;
  try {
    const r = await pool.request().query(`
      SELECT OBJECT_ID('dbo.OrgUnits', 'U') AS orgUnitsExists
    `);
    hasOrgUnitsTable = !!r.recordset[0].orgUnitsExists;
    orgUnitsCheckTime = now;
  } catch {
    hasOrgUnitsTable = false;
  }
  return hasOrgUnitsTable;
}

// ─── GET /api/org-units ─────────────────────────────────────────────
router.get('/org-units', async (req, res) => {
  try {
    if (!useSql) return res.json({ data: [], total: 0 });

    const p = await db.getPool();
    if (!(await checkOrgUnits(p))) {
      return res.json({ data: [], total: 0, available: false, message: 'OrgUnits table not found.' });
    }

    const result = await timedRequest(p, 'org-units-list', res).query(`
      SELECT ou.*,
          mgr.displayName AS managerDisplayName,
          mgr.email AS managerEmail,
          parent.displayName AS parentDisplayName
      FROM OrgUnits ou
      LEFT JOIN Principals mgr ON ou.managerId = mgr.id AND mgr.ValidTo = '9999-12-31 23:59:59.9999999'
      LEFT JOIN OrgUnits parent ON ou.parentOrgUnitId = parent.id AND parent.ValidTo = '9999-12-31 23:59:59.9999999'
      WHERE ou.ValidTo = '9999-12-31 23:59:59.9999999'
      ORDER BY ou.displayName
    `);

    res.json({ data: result.recordset, total: result.recordset.length, available: true });
  } catch (err) {
    console.error('GET /org-units failed:', err.message);
    res.status(500).json({ error: 'Failed to load org units' });
  }
});

// ─── GET /api/org-units/tree ────────────────────────────────────────
router.get('/org-units/tree', async (req, res) => {
  try {
    if (!useSql) return res.json([]);

    const p = await db.getPool();
    if (!(await checkOrgUnits(p))) {
      return res.json([]);
    }

    const result = await timedRequest(p, 'org-units-tree', res).query(`
      SELECT ou.id, ou.displayName, ou.orgUnitType, ou.parentOrgUnitId,
             ou.memberCount, ou.totalMemberCount, ou.managerId, ou.department,
             mgr.displayName AS managerDisplayName
      FROM OrgUnits ou
      LEFT JOIN Principals mgr ON ou.managerId = mgr.id AND mgr.ValidTo = '9999-12-31 23:59:59.9999999'
      WHERE ou.ValidTo = '9999-12-31 23:59:59.9999999'
      ORDER BY ou.displayName
    `);

    const rows = result.recordset;
    if (rows.length === 0) return res.json([]);

    // Build tree in memory
    const map = new Map();
    rows.forEach(r => map.set(r.id, { ...r, children: [] }));

    const roots = [];
    map.forEach(node => {
      if (node.parentOrgUnitId && map.has(node.parentOrgUnitId)) {
        map.get(node.parentOrgUnitId).children.push(node);
      } else {
        roots.push(node);
      }
    });

    // Sort children by displayName at each level
    function sortChildren(node) {
      node.children.sort((a, b) => (a.displayName || '').localeCompare(b.displayName || ''));
      node.children.forEach(sortChildren);
    }
    roots.sort((a, b) => (a.displayName || '').localeCompare(b.displayName || ''));
    roots.forEach(sortChildren);

    res.json(roots);
  } catch (err) {
    console.error('GET /org-units/tree failed:', err.message);
    res.status(500).json({ error: 'Failed to load org unit tree' });
  }
});

// ─── GET /api/org-units/:id ─────────────────────────────────────────
router.get('/org-units/:id', async (req, res) => {
  if (!UUID_RE.test(req.params.id)) return res.status(400).json({ error: 'Invalid ID format' });

  try {
    if (!useSql) return res.json({ attributes: null, members: [], subUnits: [] });

    const p = await db.getPool();
    if (!(await checkOrgUnits(p))) {
      return res.status(404).json({ error: 'OrgUnits table not found' });
    }

    // 1. OrgUnit attributes
    const attrResult = await timedRequest(p, 'org-unit-detail', res)
      .input('id', req.params.id)
      .query(`SELECT * FROM OrgUnits WHERE id = @id AND ValidTo = '9999-12-31 23:59:59.9999999'`);

    if (attrResult.recordset.length === 0) {
      return res.status(404).json({ error: 'OrgUnit not found' });
    }

    // 2. Members (Principals in this OrgUnit)
    let members = [];
    try {
      const membersResult = await timedRequest(p, 'org-unit-members', res)
        .input('id', req.params.id)
        .query(`
          SELECT p.id, p.displayName, p.email, p.jobTitle, p.accountEnabled, p.principalType
          FROM Principals p
          WHERE p.orgUnitId = @id AND p.ValidTo = '9999-12-31 23:59:59.9999999'
          ORDER BY p.displayName
        `);
      members = membersResult.recordset;
    } catch { /* Principals table may not have orgUnitId column */ }

    // 3. Sub-units
    let subUnits = [];
    try {
      const subResult = await timedRequest(p, 'org-unit-subunits', res)
        .input('id', req.params.id)
        .query(`
          SELECT id, displayName, memberCount
          FROM OrgUnits
          WHERE parentOrgUnitId = @id AND ValidTo = '9999-12-31 23:59:59.9999999'
          ORDER BY displayName
        `);
      subUnits = subResult.recordset;
    } catch { /* ignore */ }

    res.json({
      attributes: attrResult.recordset[0],
      members,
      subUnits,
    });
  } catch (err) {
    console.error('GET /org-units/:id failed:', err.message);
    res.status(500).json({ error: 'Failed to load org unit details' });
  }
});

// ─── GET /api/org-units/:id/members ─────────────────────────────────
router.get('/org-units/:id/members', async (req, res) => {
  if (!UUID_RE.test(req.params.id)) return res.status(400).json({ error: 'Invalid ID format' });

  try {
    if (!useSql) return res.json({ data: [], total: 0 });

    const p = await db.getPool();
    if (!(await checkOrgUnits(p))) {
      return res.json({ data: [], total: 0 });
    }

    const limit = Math.min(Math.max(parseInt(req.query.limit) || 100, 1), 500);
    const offset = Math.max(parseInt(req.query.offset) || 0, 0);
    const search = (req.query.search || '').trim().slice(0, 200);

    const request = timedRequest(p, 'org-unit-members-paged', res);
    request.input('id', req.params.id);
    request.input('limit', limit);
    request.input('offset', offset);

    let where = `p.orgUnitId = @id AND p.ValidTo = '9999-12-31 23:59:59.9999999'`;
    if (search) {
      where += ` AND (p.displayName LIKE @search OR p.email LIKE @search OR p.jobTitle LIKE @search)`;
      request.input('search', `%${search}%`);
    }

    const result = await request.query(`
      SELECT p.id, p.displayName, p.email, p.jobTitle, p.accountEnabled, p.principalType
      FROM Principals p
      WHERE ${where}
      ORDER BY p.displayName
      OFFSET @offset ROWS FETCH NEXT @limit ROWS ONLY;

      SELECT COUNT(*) AS total FROM Principals p WHERE ${where};
    `);

    res.json({
      data: result.recordsets[0],
      total: result.recordsets[1][0].total,
    });
  } catch (err) {
    console.error('GET /org-units/:id/members failed:', err.message);
    res.status(500).json({ error: 'Failed to load org unit members' });
  }
});

// Export the detection helper so orgChart.js can use it
export { checkOrgUnits };
export default router;
