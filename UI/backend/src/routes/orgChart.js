// ─── Org Chart API Routes ─────────────────────────────────────────────
//
// Reads manager hierarchy from the managerId column on GraphUsers and
// builds a nested tree for org-chart visualization.  Risk columns are
// included when present (riskScore, riskTier, riskHierarchy*).
//
// GET    /api/org-chart                  - Full manager tree (cached 5 min)
// GET    /api/org-chart/subtree/:id      - Single manager's subtree
// POST   /api/org-chart/invalidate       - Clear the cache
// GET    /api/org-chart/user/:id/manager - User's direct manager
// GET    /api/org-chart/user/:id/reports - User's direct reports

import { Router } from 'express';
import { timedRequest } from '../perf/sqlTimer.js';

const router = Router();
const useSql = process.env.USE_SQL === 'true';

let db = null;
if (useSql) {
  db = await import('../db/connection.js');
}

// ─── Cache (5-minute TTL) ────────────────────────────────────────────
let cachedUsers = null;
let cacheTimestamp = 0;
const CACHE_TTL_MS = 5 * 60 * 1000;

function isCacheValid() {
  return cachedUsers !== null && (Date.now() - cacheTimestamp) < CACHE_TTL_MS;
}

// ─── Column detection helpers ────────────────────────────────────────

async function hasManagerColumn(pool, res) {
  try {
    const result = await timedRequest(pool, 'org-col-check-managerId', res).query(`
      SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
      WHERE TABLE_NAME = 'GraphUsers' AND TABLE_SCHEMA = 'dbo' AND COLUMN_NAME = 'managerId'
    `);
    return result.recordset.length > 0;
  } catch {
    return false;
  }
}

async function hasRiskColumns(pool, res) {
  try {
    const result = await timedRequest(pool, 'org-col-check-risk', res).query(`
      SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
      WHERE TABLE_NAME = 'GraphUsers' AND TABLE_SCHEMA = 'dbo' AND COLUMN_NAME = 'riskScore'
    `);
    return result.recordset.length > 0;
  } catch {
    return false;
  }
}

async function hasHierarchyColumns(pool, res) {
  try {
    const result = await timedRequest(pool, 'org-col-check-hierarchy', res).query(`
      SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
      WHERE TABLE_NAME = 'GraphUsers' AND TABLE_SCHEMA = 'dbo'
        AND COLUMN_NAME = 'riskHierarchyDirectReports'
    `);
    return result.recordset.length > 0;
  } catch {
    return false;
  }
}

// ─── Tree building ───────────────────────────────────────────────────

function buildTree(users) {
  const byId = new Map();
  for (const u of users) {
    byId.set(u.id, { ...u, children: [] });
  }

  const roots = [];
  const orphans = [];

  for (const node of byId.values()) {
    if (node.managerId && byId.has(node.managerId)) {
      byId.get(node.managerId).children.push(node);
    } else if (!node.managerId) {
      // No manager — will be classified as root or orphan below
      roots.push(node);
    } else {
      // Has managerId but manager not in dataset
      orphans.push(node);
    }
  }

  // Separate roots (have children) from orphans (no manager, no children)
  const realRoots = [];
  for (const node of roots) {
    if (node.children.length > 0) {
      realRoots.push(node);
    } else {
      orphans.push(node);
    }
  }

  // Compute subtree aggregates (totalUsers, riskCounts per tier)
  function computeAggregates(node) {
    let total = 1;
    const riskCounts = {};
    if (node.riskTier) {
      riskCounts[node.riskTier] = (riskCounts[node.riskTier] || 0) + 1;
    }

    for (const child of node.children) {
      const childAgg = computeAggregates(child);
      total += childAgg.totalUsers;
      for (const [tier, count] of Object.entries(childAgg.riskCounts)) {
        riskCounts[tier] = (riskCounts[tier] || 0) + count;
      }
    }

    node.totalUsers = total;
    node.riskCounts = riskCounts;
    return { totalUsers: total, riskCounts };
  }

  for (const root of realRoots) {
    computeAggregates(root);
  }

  // Sort roots by subtree size descending
  realRoots.sort((a, b) => b.totalUsers - a.totalUsers);

  // Build department summary
  const departments = {};
  for (const u of users) {
    const dept = u.department || 'Unknown';
    departments[dept] = (departments[dept] || 0) + 1;
  }

  return {
    available: true,
    totalUsers: users.length,
    roots: realRoots,
    orphans: orphans.slice(0, 100),
    departments,
  };
}

// ─── Fetch flat user list ────────────────────────────────────────────

async function fetchUsers(pool, res) {
  const hasRisk = await hasRiskColumns(pool, res);
  const hasHierarchy = hasRisk && await hasHierarchyColumns(pool, res);

  let cols = 'id, managerId, displayName, department, jobTitle, companyName, accountEnabled, userType';
  if (hasRisk) {
    cols += ', riskScore, riskTier';
  }
  if (hasHierarchy) {
    cols += ', riskHierarchyDirectReports, riskHierarchyTotalReports';
  }

  const result = await timedRequest(pool, 'org-chart-users', res).query(`
    SELECT ${cols} FROM dbo.GraphUsers
  `);

  return result.recordset;
}

// ─── Helper: find node by id in tree ─────────────────────────────────

function findNode(roots, id) {
  for (const root of roots) {
    if (root.id === id) return root;
    const found = findNode(root.children, id);
    if (found) return found;
  }
  return null;
}

// ─── GET /api/org-chart ──────────────────────────────────────────────
router.get('/org-chart', async (req, res) => {
  try {
    if (!useSql) {
      return res.json({ available: false, message: 'Org chart requires SQL mode.' });
    }

    const p = await db.getPool();

    if (!(await hasManagerColumn(p, res))) {
      return res.json({ available: false, message: 'managerId column not found on GraphUsers. Sync users with manager data first.' });
    }

    if (isCacheValid()) {
      return res.json({ available: true, users: cachedUsers });
    }

    const users = await fetchUsers(p, res);
    cachedUsers = users;
    cacheTimestamp = Date.now();

    return res.json({ available: true, users });
  } catch (err) {
    console.error('Org chart query failed:', err.message);
    return res.status(500).json({ error: 'Failed to load org chart' });
  }
});

// ─── GET /api/org-chart/subtree/:id ──────────────────────────────────
router.get('/org-chart/subtree/:id', async (req, res) => {
  try {
    if (!useSql) {
      return res.json({ available: false, message: 'Org chart requires SQL mode.' });
    }

    const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    if (!uuidRegex.test(req.params.id)) {
      return res.status(400).json({ error: 'Invalid ID format' });
    }

    const p = await db.getPool();

    if (!(await hasManagerColumn(p, res))) {
      return res.json({ available: false, message: 'managerId column not found on GraphUsers.' });
    }

    // Ensure cache is populated
    if (!isCacheValid()) {
      cachedUsers = await fetchUsers(p, res);
      cacheTimestamp = Date.now();
    }

    // Build tree on demand for subtree lookup
    const tree = buildTree(cachedUsers);
    const node = findNode(tree.roots, req.params.id);
    if (!node) {
      return res.status(404).json({ error: 'Manager not found in org tree' });
    }

    return res.json({ available: true, subtree: node });
  } catch (err) {
    console.error('Org chart subtree query failed:', err.message);
    return res.status(500).json({ error: 'Failed to load subtree' });
  }
});

// ─── POST /api/org-chart/invalidate ──────────────────────────────────
router.post('/org-chart/invalidate', async (req, res) => {
  cachedUsers = null;
  cacheTimestamp = 0;
  return res.json({ success: true });
});

// ─── GET /api/org-chart/user/:id/manager ─────────────────────────────
router.get('/org-chart/user/:id/manager', async (req, res) => {
  try {
    if (!useSql) {
      return res.json({ manager: null, available: false });
    }

    const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    if (!uuidRegex.test(req.params.id)) {
      return res.status(400).json({ error: 'Invalid ID format' });
    }

    const p = await db.getPool();

    if (!(await hasManagerColumn(p, res))) {
      return res.json({ manager: null, available: false });
    }

    const hasRisk = await hasRiskColumns(p, res);

    let managerCols = 'm.id, m.displayName, m.jobTitle, m.department';
    if (hasRisk) {
      managerCols += ', m.riskScore, m.riskTier';
    }

    const request = timedRequest(p, 'org-user-manager', res);
    request.input('id', req.params.id);

    const result = await request.query(`
      SELECT ${managerCols}
      FROM dbo.GraphUsers u
      INNER JOIN dbo.GraphUsers m ON u.managerId = m.id
      WHERE u.id = @id
    `);

    return res.json({
      manager: result.recordset.length > 0 ? result.recordset[0] : null,
      available: true,
    });
  } catch (err) {
    console.error('Org chart manager query failed:', err.message);
    return res.status(500).json({ error: 'Failed to load manager' });
  }
});

// ─── GET /api/org-chart/user/:id/reports ─────────────────────────────
router.get('/org-chart/user/:id/reports', async (req, res) => {
  try {
    if (!useSql) {
      return res.json({ reports: [], available: false });
    }

    const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    if (!uuidRegex.test(req.params.id)) {
      return res.status(400).json({ error: 'Invalid ID format' });
    }

    const p = await db.getPool();

    if (!(await hasManagerColumn(p, res))) {
      return res.json({ reports: [], available: false });
    }

    const hasRisk = await hasRiskColumns(p, res);

    let cols = 'id, displayName, jobTitle, department';
    if (hasRisk) {
      cols += ', riskScore, riskTier';
    }

    const request = timedRequest(p, 'org-user-reports', res);
    request.input('id', req.params.id);

    const result = await request.query(`
      SELECT ${cols}
      FROM dbo.GraphUsers
      WHERE managerId = @id
      ORDER BY displayName
    `);

    return res.json({
      reports: result.recordset,
      available: true,
    });
  } catch (err) {
    console.error('Org chart reports query failed:', err.message);
    return res.status(500).json({ error: 'Failed to load direct reports' });
  }
});

export default router;
