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

    // 1. Current attributes — try Principals first, fall back to GraphUsers
    let userResult;
    let usingPrincipals = false;
    try {
      userResult = await timedRequest(pool, 'user-attributes', res)
        .input('id', userId)
        .query(`SELECT * FROM Principals WHERE id = @id AND ValidTo = '9999-12-31 23:59:59.9999999'`);
      if (userResult.recordset.length > 0) {
        usingPrincipals = true;
      } else {
        // Principals exists but user not found there — try GraphUsers
        userResult = await timedRequest(pool, 'user-attributes-legacy', res)
          .input('id', userId)
          .query('SELECT * FROM GraphUsers WHERE id = @id');
      }
    } catch {
      // Principals table doesn't exist — fall back to GraphUsers
      userResult = await timedRequest(pool, 'user-attributes-legacy', res)
        .input('id', userId)
        .query('SELECT * FROM GraphUsers WHERE id = @id');
    }

    if (userResult.recordset.length === 0) {
      return res.status(404).json({ error: 'User not found' });
    }
    const attributes = cleanRow(userResult.recordset[0]);

    // Parse extendedAttributes JSON if present (Principals model)
    if (attributes.extendedAttributes) {
      try {
        attributes.extendedAttributesParsed = JSON.parse(attributes.extendedAttributes);
      } catch { /* ignore bad JSON */ }
    }

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
      let r;
      try {
        r = await timedRequest(pool, 'user-membership-count', res)
          .input('id', userId)
          .query(`SELECT COUNT(DISTINCT resourceId) AS cnt FROM ${table} WHERE memberId = @id`);
      } catch {
        r = await timedRequest(pool, 'user-membership-count-legacy', res)
          .input('id', userId)
          .query(`SELECT COUNT(DISTINCT groupId) AS cnt FROM ${table} WHERE memberId = @id`);
      }
      membershipCount = r.recordset[0].cnt;
    } catch { /* view may not exist */ }

    let accessPackageCount = 0;
    try {
      const r = await timedRequest(pool, 'user-ap-count', res)
        .input('id', userId)
        .query(`
        SELECT COUNT(DISTINCT resourceId) AS cnt
        FROM ResourceAssignments WHERE principalId = @id AND assignmentType = 'Governed'
      `);
      accessPackageCount = r.recordset[0].cnt;
    } catch { /* table may not exist */ }

    let hasHistory = false;
    try {
      if (usingPrincipals) {
        const r = await timedRequest(pool, 'user-history-check', res)
          .input('id', userId)
          .query(`SELECT TOP 1 1 AS found FROM Principals FOR SYSTEM_TIME ALL WHERE id = @id AND ValidTo != '9999-12-31 23:59:59.9999999'`);
        hasHistory = r.recordset.length > 0;
      } else {
        const r = await timedRequest(pool, 'user-history-check', res)
          .input('id', userId)
          .query(`SELECT TOP 1 1 AS found FROM GraphUsers_History WHERE id = @id`);
        hasHistory = r.recordset.length > 0;
      }
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
    let r;
    try {
      // New model: resourceId, resourceDisplayName, resourceType
      r = await timedRequest(pool, 'user-memberships', res)
        .input('id', req.params.id)
        .query(`
        SELECT resourceId, resourceId AS groupId,
               resourceDisplayName, resourceDisplayName AS groupDisplayName,
               resourceType, resourceType AS groupTypeCalculated,
               membershipType, managedByAccessPackage
        FROM ${table}
        WHERE memberId = @id
        ORDER BY resourceDisplayName, membershipType
      `);
    } catch {
      // Fall back to old column names
      r = await timedRequest(pool, 'user-memberships-legacy', res)
        .input('id', req.params.id)
        .query(`
        SELECT groupId, groupId AS resourceId,
               groupDisplayName, groupDisplayName AS resourceDisplayName,
               groupTypeCalculated, groupTypeCalculated AS resourceType,
               membershipType, managedByAccessPackage
        FROM ${table}
        WHERE memberId = @id
        ORDER BY groupDisplayName, membershipType
      `);
    }
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
        a.resourceId,
        ap.displayName AS accessPackageName,
        a.state,
        a.assignedDateTime
      FROM ResourceAssignments a
      LEFT JOIN Resources ap ON a.resourceId = ap.id AND ap.resourceType = 'BusinessRole'
      WHERE a.principalId = @id AND a.assignmentType = 'Governed'
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
    let r;
    try {
      // Try Principals temporal table first (new model)
      r = await timedRequest(pool, 'user-history', res)
        .input('id', req.params.id)
        .query(`
        SELECT * FROM Principals FOR SYSTEM_TIME ALL
        WHERE id = @id
        ORDER BY ValidFrom DESC
      `);
    } catch {
      // Fall back to GraphUsers temporal table (old model)
      r = await timedRequest(pool, 'user-history-legacy', res)
        .input('id', req.params.id)
        .query(`
        SELECT * FROM GraphUsers FOR SYSTEM_TIME ALL
        WHERE id = @id
        ORDER BY ValidFrom DESC
      `);
    }
    res.json(r.recordset.map(cleanRow));
  } catch (err) {
    // Not temporal — return empty
    res.json([]);
  }
});

// ────────────────────────────────────────────────────────────────
// GET /api/group/:id — Lightweight: attributes, tags, counts only
// Now queries Resources table (new model) with GraphGroups fallback
// ────────────────────────────────────────────────────────────────
router.get('/group/:id', async (req, res) => {
  if (!UUID_RE.test(req.params.id)) return res.status(400).json({ error: 'Invalid ID format' });
  if (!useSql) return res.json({ attributes: {}, tags: [], memberCount: 0, accessPackageCount: 0, hasHistory: false });
  try {
    const pool = await db.getPool();
    const groupId = req.params.id;

    // 1. Current attributes — try Resources first, fall back to GraphGroups
    let groupResult;
    let usingResources = false;
    try {
      groupResult = await timedRequest(pool, 'group-attributes', res)
        .input('id', groupId)
        .query(`SELECT * FROM Resources WHERE id = @id AND ValidTo = '9999-12-31 23:59:59.9999999'`);
      usingResources = true;
    } catch {
      groupResult = await timedRequest(pool, 'group-attributes-legacy', res)
        .input('id', groupId)
        .query('SELECT * FROM GraphGroups WHERE id = @id');
    }

    if (groupResult.recordset.length === 0) {
      return res.status(404).json({ error: 'Group not found' });
    }
    const attributes = cleanRow(groupResult.recordset[0]);

    // Parse extendedAttributes if present (Resources model)
    if (attributes.extendedAttributes) {
      try {
        attributes.extendedAttributesParsed = JSON.parse(attributes.extendedAttributes);
      } catch { /* ignore bad JSON */ }
    }

    // 2. Tags (support both 'resource' and 'group' entity types)
    let tags = [];
    try {
      const r = await timedRequest(pool, 'group-tags', res)
        .input('id', groupId)
        .query(`
        SELECT t.id, t.name, t.color
        FROM GraphTagAssignments ta
        JOIN GraphTags t ON ta.tagId = t.id
        WHERE ta.entityId = @id AND t.entityType IN ('resource', 'group')
      `);
      tags = r.recordset;
    } catch { /* table may not exist */ }

    // 3. Counts only (fast) — try resourceId first, fall back to groupId
    let memberCount = 0;
    try {
      const table = await getPermissionTable(pool);
      let r;
      try {
        r = await timedRequest(pool, 'group-member-count', res)
          .input('id', groupId)
          .query(`SELECT COUNT(DISTINCT memberId) AS cnt FROM ${table} WHERE resourceId = @id`);
      } catch {
        r = await timedRequest(pool, 'group-member-count-legacy', res)
          .input('id', groupId)
          .query(`SELECT COUNT(DISTINCT memberId) AS cnt FROM ${table} WHERE groupId = @id`);
      }
      memberCount = r.recordset[0].cnt;
    } catch { /* view may not exist */ }

    let accessPackageCount = 0;
    try {
      const r = await timedRequest(pool, 'group-ap-count', res)
        .input('id', groupId)
        .query(`
        SELECT COUNT(DISTINCT rrs.parentResourceId) AS cnt
        FROM ResourceRelationships rrs
        WHERE UPPER(rrs.childResourceId) = UPPER(@id)
          AND rrs.relationshipType = 'Contains'
      `);
      accessPackageCount = r.recordset[0].cnt;
    } catch { /* table may not exist */ }

    let hasHistory = false;
    try {
      if (usingResources) {
        const r = await timedRequest(pool, 'group-history-check', res)
          .input('id', groupId)
          .query(`SELECT TOP 1 1 AS found FROM Resources FOR SYSTEM_TIME ALL WHERE id = @id AND ValidTo != '9999-12-31 23:59:59.9999999'`);
        hasHistory = r.recordset.length > 0;
      } else {
        const r = await timedRequest(pool, 'group-history-check', res)
          .input('id', groupId)
          .query(`SELECT TOP 1 1 AS found FROM GraphGroups_History WHERE id = @id`);
        hasHistory = r.recordset.length > 0;
      }
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
// GET /api/group/:id/members — Lazy-loaded group/resource members
// ────────────────────────────────────────────────────────────────
router.get('/group/:id/members', async (req, res) => {
  if (!UUID_RE.test(req.params.id)) return res.status(400).json({ error: 'Invalid ID format' });
  if (!useSql) return res.json([]);
  try {
    const pool = await db.getPool();
    const table = await getPermissionTable(pool);
    let r;
    try {
      r = await timedRequest(pool, 'group-members', res)
        .input('id', req.params.id)
        .query(`
        SELECT memberId, memberDisplayName, memberUPN,
               membershipType, managedByAccessPackage
        FROM ${table}
        WHERE resourceId = @id
        ORDER BY memberDisplayName, membershipType
      `);
    } catch {
      // Fall back to groupId column name
      r = await timedRequest(pool, 'group-members-legacy', res)
        .input('id', req.params.id)
        .query(`
        SELECT memberId, memberDisplayName, memberUPN,
               membershipType, managedByAccessPackage
        FROM ${table}
        WHERE groupId = @id
        ORDER BY memberDisplayName, membershipType
      `);
    }
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
        rrs.parentResourceId AS resourceId,
        ap.displayName AS accessPackageName,
        rrs.roleName
      FROM ResourceRelationships rrs
      LEFT JOIN Resources ap ON rrs.parentResourceId = ap.id AND ap.resourceType = 'BusinessRole'
      WHERE UPPER(rrs.childResourceId) = UPPER(@id)
        AND rrs.relationshipType = 'Contains'
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
    let r;
    try {
      // Try Resources temporal table first (new model)
      r = await timedRequest(pool, 'group-history', res)
        .input('id', req.params.id)
        .query(`
        SELECT * FROM Resources FOR SYSTEM_TIME ALL
        WHERE id = @id
        ORDER BY ValidFrom DESC
      `);
    } catch {
      // Fall back to GraphGroups temporal table (old model)
      r = await timedRequest(pool, 'group-history-legacy', res)
        .input('id', req.params.id)
        .query(`
        SELECT * FROM GraphGroups FOR SYSTEM_TIME ALL
        WHERE id = @id
        ORDER BY ValidFrom DESC
      `);
    }
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
        FROM Resources ap
        LEFT JOIN GovernanceCatalogs c ON ap.catalogId = c.id
        WHERE ap.id = @id AND ap.resourceType = 'BusinessRole'
      `);
    } catch {
      // GovernanceCatalogs may not exist — fall back to AP-only query
      apResult = await timedRequest(pool, 'ap-attributes', res)
        .input('id', apId)
        .query(`SELECT * FROM Resources WHERE id = @id AND resourceType = 'BusinessRole'`);
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
        SELECT COUNT(*) AS cnt FROM ResourceAssignments WHERE resourceId = @id AND assignmentType = 'Governed'
      `);
      assignmentCount = r.recordset[0].cnt;
    } catch { /* table may not exist */ }

    // 3. Group count (resources linked to this AP)
    let groupCount = 0;
    try {
      const r = await timedRequest(pool, 'ap-group-count', res)
        .input('id', apId)
        .query(`
        SELECT COUNT(DISTINCT childResourceId) AS cnt
        FROM ResourceRelationships
        WHERE parentResourceId = @id AND relationshipType = 'Contains'
      `);
      groupCount = r.recordset[0].cnt;
    } catch { /* table may not exist */ }

    // 4. Review count
    let reviewCount = 0;
    try {
      const r = await timedRequest(pool, 'ap-review-count', res)
        .input('id', apId)
        .query(`
        SELECT COUNT(*) AS cnt FROM CertificationDecisions WHERE resourceId = @id
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
        FROM CertificationDecisions
        WHERE resourceId = @id AND decision IS NOT NULL AND decision <> 'NotReviewed'
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
        FROM AssignmentPolicies
        WHERE resourceId = @id
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
        FROM dbo.GovernanceCategoryAssignments ca
        INNER JOIN dbo.GovernanceCategories cat ON ca.categoryId = cat.id
        WHERE ca.resourceId = LOWER(@id)
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
        SELECT TOP 1 1 AS found FROM Resources FOR SYSTEM_TIME ALL
        WHERE id = @id AND resourceType = 'BusinessRole' AND ValidTo != '9999-12-31 23:59:59.9999999'
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
    let r;
    try {
      // Try Principals first (new model — email instead of userPrincipalName)
      r = await timedRequest(pool, 'ap-assignments', res)
        .input('id', req.params.id)
        .query(`
        SELECT
          a.id, a.principalId, a.state, a.status AS assignmentStatus,
          u.displayName AS targetDisplayName,
          u.email AS targetUPN,
          a.ValidFrom AS assignedDate
        FROM ResourceAssignments a
        LEFT JOIN Principals u ON a.principalId = u.id
        WHERE a.resourceId = @id
          AND a.assignmentType = 'Governed'
          AND a.state = 'Delivered'
        ORDER BY u.displayName
      `);
    } catch {
      // Fall back to GraphUsers (old model)
      r = await timedRequest(pool, 'ap-assignments-legacy', res)
        .input('id', req.params.id)
        .query(`
        SELECT
          a.id, a.principalId, a.state, a.status AS assignmentStatus,
          u.displayName AS targetDisplayName,
          u.userPrincipalName AS targetUPN,
          a.ValidFrom AS assignedDate
        FROM ResourceAssignments a
        LEFT JOIN GraphUsers u ON a.principalId = u.id
        WHERE a.resourceId = @id
          AND a.assignmentType = 'Governed'
          AND a.state = 'Delivered'
        ORDER BY u.displayName
      `);
    }
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
        rrs.id, rrs.roleName, rrs.roleOriginSystem,
        r.displayName AS scopeDisplayName, rrs.childResourceId, rrs.roleOriginSystem AS scopeOriginSystem,
        rrs.createdDateTime,
        COALESCE(r.displayName, g.displayName) AS groupDisplayName,
        COALESCE(r.displayName, g.displayName) AS resourceDisplayName,
        r.resourceType, r.systemId
      FROM ResourceRelationships rrs
      LEFT JOIN Resources r ON UPPER(rrs.childResourceId) = UPPER(r.id)
        AND r.ValidTo = '9999-12-31 23:59:59.9999999'
      LEFT JOIN GraphGroups g ON UPPER(rrs.childResourceId) = UPPER(g.id)
        AND r.id IS NULL
      WHERE rrs.parentResourceId = @id AND rrs.relationshipType = 'Contains'
      ORDER BY COALESCE(r.displayName, g.displayName), rrs.roleName
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
      FROM CertificationDecisions
      WHERE resourceId = @id
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
    let r;
    try {
      // Try Principals first (new model — email instead of userPrincipalName)
      r = await timedRequest(pool, 'ap-requests', res)
        .input('id', req.params.id)
        .query(`
        SELECT
          req.id, req.requestType, req.requestState, req.requestStatus,
          req.justification, req.createdDateTime, req.completedDateTime,
          u.displayName AS requestorDisplayName, u.email AS requestorUPN
        FROM AssignmentRequests req
        LEFT JOIN Principals u ON req.requestorId = u.id
        WHERE req.resourceId = @id
          AND req.requestState IN ('PendingApproval', 'Delivering', 'Accepted')
        ORDER BY req.createdDateTime DESC
      `);
    } catch {
      // Fall back to GraphUsers (old model)
      r = await timedRequest(pool, 'ap-requests-legacy', res)
        .input('id', req.params.id)
        .query(`
        SELECT
          req.id, req.requestType, req.requestState, req.requestStatus,
          req.justification, req.createdDateTime, req.completedDateTime,
          u.displayName AS requestorDisplayName, u.userPrincipalName AS requestorUPN
        FROM AssignmentRequests req
        LEFT JOIN GraphUsers u ON req.requestorId = u.id
        WHERE req.resourceId = @id
          AND req.requestState IN ('PendingApproval', 'Delivering', 'Accepted')
        ORDER BY req.createdDateTime DESC
      `);
    }
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
      SELECT * FROM Resources FOR SYSTEM_TIME ALL
      WHERE id = @id AND resourceType = 'BusinessRole'
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
             JSON_VALUE(automaticRequestSettings, '$.filter.rule') AS autoAssignmentFilter,
             createdDateTime, modifiedDateTime
      FROM AssignmentPolicies
      WHERE resourceId = @id
      ORDER BY displayName
    `);
    res.json(r.recordset);
  } catch {
    res.json([]);
  }
});

export default router;
