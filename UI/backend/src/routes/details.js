import { Router } from 'express';
import * as db from '../db/connection.js';
import { timedRequest } from '../perf/sqlTimer.js';

const router = Router();

const useSql = process.env.USE_SQL === 'true';
const SYSTEM_COLS = new Set(['SysStartTime', 'SysEndTime']);
const UUID_RE = /^[0-9a-f-]{36}$/i;

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
  if (!UUID_RE.test(req.params.id)) return res.status(400).json({ error: 'Invalid ID format' });
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
        SELECT TOP 1 1 AS found FROM GraphUsers_History
        WHERE id = @id
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
  if (!UUID_RE.test(req.params.id)) return res.status(400).json({ error: 'Invalid ID format' });
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
  if (!UUID_RE.test(req.params.id)) return res.status(400).json({ error: 'Invalid ID format' });
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
  if (!UUID_RE.test(req.params.id)) return res.status(400).json({ error: 'Invalid ID format' });
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
  if (!UUID_RE.test(req.params.id)) return res.status(400).json({ error: 'Invalid ID format' });
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
        SELECT TOP 1 1 AS found FROM GraphGroups_History
        WHERE id = @id
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
  if (!UUID_RE.test(req.params.id)) return res.status(400).json({ error: 'Invalid ID format' });
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
  if (!UUID_RE.test(req.params.id)) return res.status(400).json({ error: 'Invalid ID format' });
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
  if (!UUID_RE.test(req.params.id)) return res.status(400).json({ error: 'Invalid ID format' });
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

// ────────────────────────────────────────────────────────────────
// GET /api/access-package/:id — Lightweight: attributes, counts only
// ────────────────────────────────────────────────────────────────
router.get('/access-package/:id', async (req, res) => {
  if (!UUID_RE.test(req.params.id)) return res.status(400).json({ error: 'Invalid ID format' });
  if (!useSql) return res.json({ attributes: {}, assignmentCount: 0, groupCount: 0, hasHistory: false });
  try {
    const pool = await db.getPool();
    const apId = req.params.id;

    // 1. Current attributes + catalog name
    let apResult;
    try {
      apResult = await timedRequest(pool, 'ap-attributes', res)
        .input('id', apId)
        .query(`
        SELECT ap.*, c.displayName AS catalogName
        FROM GraphAccessPackages ap
        LEFT JOIN GraphCatalogs c ON ap.catalogId = c.id
        WHERE ap.id = @id
      `);
    } catch {
      // GraphCatalogs may not exist — fall back to AP-only query
      apResult = await timedRequest(pool, 'ap-attributes', res)
        .input('id', apId)
        .query('SELECT * FROM GraphAccessPackages WHERE id = @id');
    }

    if (apResult.recordset.length === 0) {
      return res.status(404).json({ error: 'Access package not found' });
    }
    const attributes = cleanRow(apResult.recordset[0]);

    // 2. Assignment count
    let assignmentCount = 0;
    try {
      const r = await timedRequest(pool, 'ap-assignment-count', res)
        .input('id', apId)
        .query(`
        SELECT COUNT(*) AS cnt FROM GraphAccessPackageAssignments WHERE accessPackageId = @id
      `);
      assignmentCount = r.recordset[0].cnt;
    } catch { /* table may not exist */ }

    // 3. Group count (resources linked to this AP)
    let groupCount = 0;
    try {
      const r = await timedRequest(pool, 'ap-group-count', res)
        .input('id', apId)
        .query(`
        SELECT COUNT(DISTINCT scopeOriginId) AS cnt
        FROM GraphAccessPackageResourceRoleScopes
        WHERE accessPackageId = @id AND scopeOriginSystem = 'AadGroup'
      `);
      groupCount = r.recordset[0].cnt;
    } catch { /* table may not exist */ }

    // 4. Review count
    let reviewCount = 0;
    try {
      const r = await timedRequest(pool, 'ap-review-count', res)
        .input('id', apId)
        .query(`
        SELECT COUNT(*) AS cnt FROM GraphAccessPackageAccessReviewDecisions WHERE accessPackageId = @id
      `);
      reviewCount = r.recordset[0].cnt;
    } catch { /* table may not exist */ }

    // 5. Pending request count — skipped (was 26-76s on large request tables).
    // The Pending Requests section lazy-loads its own data when expanded.
    const pendingRequestCount = null;

    // 5b. Last review date + reviewer
    let lastReviewDate = null;
    let lastReviewedBy = null;
    try {
      const r = await timedRequest(pool, 'ap-last-review-date', res)
        .input('id', apId)
        .query(`
        SELECT TOP 1 reviewedDateTime, reviewedByDisplayName
        FROM GraphAccessPackageAccessReviewDecisions
        WHERE accessPackageId = @id AND decision IS NOT NULL AND decision <> 'NotReviewed'
        ORDER BY reviewedDateTime DESC
      `);
      lastReviewDate = r.recordset[0]?.reviewedDateTime || null;
      lastReviewedBy = r.recordset[0]?.reviewedByDisplayName || null;
    } catch { /* table may not exist */ }

    // 6. Policy summary — auto-assigned vs request-based vs auto-removal
    let policyCount = 0;
    let autoAddPolicyCount = 0;
    let autoRemovePolicyCount = 0;
    try {
      const r = await timedRequest(pool, 'ap-policy-summary', res)
        .input('id', apId)
        .query(`
        SELECT
          COUNT(*) AS total,
          SUM(CASE WHEN hasAutoAddRule = 1 THEN 1 ELSE 0 END) AS autoAdd,
          SUM(CASE WHEN ISNULL(hasAutoAddRule, 0) = 0 AND hasAutoRemoveRule = 1 THEN 1 ELSE 0 END) AS autoRemoveOnly
        FROM GraphAccessPackageAssignmentPolicies
        WHERE accessPackageId = @id
      `);
      policyCount = r.recordset[0].total;
      autoAddPolicyCount = r.recordset[0].autoAdd;
      autoRemovePolicyCount = r.recordset[0].autoRemoveOnly;
    } catch { /* table may not exist */ }

    // Derive assignment type label
    let assignmentType = null;
    if (policyCount > 0) {
      const requestBasedCount = policyCount - autoAddPolicyCount - autoRemovePolicyCount;
      if (autoAddPolicyCount > 0 && (requestBasedCount > 0 || autoRemovePolicyCount > 0)) {
        assignmentType = 'Both';
      } else if (autoAddPolicyCount > 0) {
        assignmentType = 'Auto-assigned';
      } else if (autoRemovePolicyCount > 0) {
        assignmentType = 'Request-based with auto-removal';
      } else {
        assignmentType = 'Request-based';
      }
    }

    // 6b. Category
    let category = null;
    try {
      const { ensureCategoryTables } = await import('./categories.js');
      await ensureCategoryTables(pool);
      const r = await timedRequest(pool, 'ap-category', res)
        .input('id', apId)
        .query(`
        SELECT cat.id, cat.name, cat.color
        FROM dbo.GraphCategoryAssignments ca
        INNER JOIN dbo.GraphCategories cat ON ca.categoryId = cat.id
        WHERE ca.accessPackageId = LOWER(@id)
      `);
      if (r.recordset.length > 0) {
        category = r.recordset[0];
      }
    } catch { /* category tables may not exist */ }

    // 7. History check
    let hasHistory = false;
    try {
      const r = await timedRequest(pool, 'ap-history-check', res)
        .input('id', apId)
        .query(`
        SELECT TOP 1 1 AS found FROM GraphAccessPackages_History
        WHERE id = @id
      `);
      hasHistory = r.recordset.length > 0;
    } catch {
      hasHistory = false;
    }

    res.json({ attributes, assignmentCount, groupCount, reviewCount, pendingRequestCount, lastReviewDate, lastReviewedBy, hasHistory, policyCount, autoAddPolicyCount, assignmentType, category });
  } catch (err) {
    console.error('Error fetching access package detail:', err.message);
    res.status(500).json({ error: 'Failed to fetch access package details' });
  }
});

// ────────────────────────────────────────────────────────────────
// GET /api/access-package/:id/assignments — Lazy-loaded user assignments
// ────────────────────────────────────────────────────────────────
router.get('/access-package/:id/assignments', async (req, res) => {
  if (!UUID_RE.test(req.params.id)) return res.status(400).json({ error: 'Invalid ID format' });
  if (!useSql) return res.json([]);
  try {
    const pool = await db.getPool();
    const r = await timedRequest(pool, 'ap-assignments', res)
      .input('id', req.params.id)
      .query(`
      SELECT
        a.id, a.targetId, a.assignmentState, a.assignmentStatus,
        u.displayName AS targetDisplayName,
        u.userPrincipalName AS targetUPN,
        a.ValidFrom AS assignedDate
      FROM GraphAccessPackageAssignments a
      LEFT JOIN GraphUsers u ON a.targetId = u.id
      WHERE a.accessPackageId = @id
        AND a.assignmentState = 'Delivered'
      ORDER BY u.displayName
    `);
    res.json(r.recordset);
  } catch (err) {
    res.json([]);
  }
});

// ────────────────────────────────────────────────────────────────
// GET /api/access-package/:id/resource-roles — Lazy-loaded resource role scopes
// ────────────────────────────────────────────────────────────────
router.get('/access-package/:id/resource-roles', async (req, res) => {
  if (!UUID_RE.test(req.params.id)) return res.status(400).json({ error: 'Invalid ID format' });
  if (!useSql) return res.json([]);
  try {
    const pool = await db.getPool();
    const r = await timedRequest(pool, 'ap-resource-roles', res)
      .input('id', req.params.id)
      .query(`
      SELECT
        rrs.id, rrs.roleDisplayName, rrs.roleOriginSystem,
        rrs.scopeDisplayName, rrs.scopeOriginId, rrs.scopeOriginSystem,
        rrs.createdDateTime,
        g.displayName AS groupDisplayName
      FROM GraphAccessPackageResourceRoleScopes rrs
      LEFT JOIN GraphGroups g ON UPPER(rrs.scopeOriginId) = UPPER(g.id)
      WHERE rrs.accessPackageId = @id
      ORDER BY g.displayName, rrs.roleDisplayName
    `);
    res.json(r.recordset);
  } catch (err) {
    res.json([]);
  }
});

// ────────────────────────────────────────────────────────────────
// GET /api/access-package/:id/reviews — Lazy-loaded access reviews
// ────────────────────────────────────────────────────────────────
router.get('/access-package/:id/reviews', async (req, res) => {
  if (!UUID_RE.test(req.params.id)) return res.status(400).json({ error: 'Invalid ID format' });
  if (!useSql) return res.json([]);
  try {
    const pool = await db.getPool();
    const r = await timedRequest(pool, 'ap-reviews', res)
      .input('id', req.params.id)
      .query(`
      SELECT
        id, reviewInstanceId, reviewDefinitionId,
        principalDisplayName,
        reviewedByDisplayName,
        reviewedDateTime, decision, justification, recommendation,
        reviewInstanceStartDateTime, reviewInstanceEndDateTime,
        reviewInstanceStatus
      FROM GraphAccessPackageAccessReviewDecisions
      WHERE accessPackageId = @id
      ORDER BY reviewedDateTime DESC
    `);
    res.json(r.recordset);
  } catch (err) {
    res.json([]);
  }
});

// ────────────────────────────────────────────────────────────────
// GET /api/access-package/:id/requests — Lazy-loaded assignment requests
// ────────────────────────────────────────────────────────────────
router.get('/access-package/:id/requests', async (req, res) => {
  if (!UUID_RE.test(req.params.id)) return res.status(400).json({ error: 'Invalid ID format' });
  if (!useSql) return res.json([]);
  try {
    const pool = await db.getPool();
    const r = await timedRequest(pool, 'ap-requests', res)
      .input('id', req.params.id)
      .query(`
      SELECT
        req.id, req.requestType, req.requestState, req.requestStatus,
        req.justification, req.createdDateTime, req.completedDateTime,
        u.displayName AS requestorDisplayName, u.userPrincipalName AS requestorUPN
      FROM GraphAccessPackageAssignmentRequests req
      LEFT JOIN GraphUsers u ON req.requestorId = u.id
      WHERE req.accessPackageId = @id
        AND req.requestState IN ('PendingApproval', 'Delivering', 'Accepted')
      ORDER BY req.createdDateTime DESC
    `);
    res.json(r.recordset);
  } catch (err) {
    res.json([]);
  }
});

// ────────────────────────────────────────────────────────────────
// GET /api/access-package/:id/history — Lazy-loaded version history
// ────────────────────────────────────────────────────────────────
router.get('/access-package/:id/history', async (req, res) => {
  if (!UUID_RE.test(req.params.id)) return res.status(400).json({ error: 'Invalid ID format' });
  if (!useSql) return res.json([]);
  try {
    const pool = await db.getPool();
    const r = await timedRequest(pool, 'ap-history', res)
      .input('id', req.params.id)
      .query(`
      SELECT * FROM GraphAccessPackages FOR SYSTEM_TIME ALL
      WHERE id = @id
      ORDER BY ValidFrom DESC
    `);
    res.json(r.recordset.map(cleanRow));
  } catch (err) {
    res.json([]);
  }
});

// ────────────────────────────────────────────────────────────────
// GET /api/access-package/:id/policies — Lazy-loaded assignment policies
// ────────────────────────────────────────────────────────────────
router.get('/access-package/:id/policies', async (req, res) => {
  if (!UUID_RE.test(req.params.id)) return res.status(400).json({ error: 'Invalid ID format' });
  if (!useSql) return res.json([]);
  try {
    const pool = await db.getPool();
    const r = await timedRequest(pool, 'ap-policies', res)
      .input('id', req.params.id)
      .query(`
      SELECT id, displayName, description, allowedTargetScope,
             ISNULL(hasAutoAddRule, CAST(0 AS BIT)) AS hasAutoAddRule,
             ISNULL(hasAutoRemoveRule, CAST(0 AS BIT)) AS hasAutoRemoveRule,
             createdDateTime, modifiedDateTime
      FROM GraphAccessPackageAssignmentPolicies
      WHERE accessPackageId = @id
      ORDER BY displayName
    `);
    res.json(r.recordset);
  } catch {
    res.json([]);
  }
});

export default router;
