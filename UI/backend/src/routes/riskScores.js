// ─── Risk Scores API Routes ───────────────────────────────────────────
//
// Reads pre-computed risk scores from SQL columns on GraphUsers and GraphGroups.
// Scores are computed by the PowerShell cmdlet Invoke-FGRiskScoring (batch process).
// This route does NO computation — it's a simple SELECT.
//
// GET    /api/risk-scores                    - Summary + top entities by score
// GET    /api/risk-scores/groups             - Paginated group scores
// GET    /api/risk-scores/users              - Paginated user scores
// PUT    /api/risk-scores/:type/:id/override - Set analyst override (+/- adjustment)
// DELETE /api/risk-scores/:type/:id/override - Remove analyst override

import { Router } from 'express';
import { timedRequest } from '../perf/sqlTimer.js';

const router = Router();
const useSql = process.env.USE_SQL === 'true';

let db = null;
if (useSql) {
  db = await import('../db/connection.js');
}

// Parse JSON columns from SQL row
function parseJsonColumns(row) {
  const r = { ...row };
  try { r.classifierMatches = r.riskClassifierMatches ? JSON.parse(r.riskClassifierMatches) : []; }
  catch { r.classifierMatches = []; }
  delete r.riskClassifierMatches;

  try { r.explanation = r.riskExplanation ? JSON.parse(r.riskExplanation) : null; }
  catch { r.explanation = null; }
  delete r.riskExplanation;

  // Compute effective score (computed + analyst override, clamped 0-100)
  r.riskOverride = r.riskOverride ?? null;
  r.riskOverrideReason = r.riskOverrideReason ?? null;
  r.effectiveScore = r.riskOverride != null
    ? Math.max(0, Math.min(100, (r.riskScore || 0) + r.riskOverride))
    : r.riskScore;

  return r;
}

// Check if risk score columns exist
const ALLOWED_RISK_TABLES = new Set(['GraphUsers', 'GraphGroups', 'Resources', 'Principals']);

async function hasRiskColumns(pool, tableName, res) {
  if (!ALLOWED_RISK_TABLES.has(tableName)) return false;
  try {
    const result = await timedRequest(pool, `risk-col-check-${tableName}`, res)
      .input('tableName', tableName)
      .query(`
        SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_NAME = @tableName AND TABLE_SCHEMA = 'dbo' AND COLUMN_NAME = 'riskScore'
      `);
    return result.recordset.length > 0;
  } catch {
    return false;
  }
}

// Determine the best table for resource/group risk scores (Resources preferred over GraphGroups)
async function getResourceRiskSource(pool, res) {
  const hasResources = await hasRiskColumns(pool, 'Resources', res);
  if (hasResources) return 'Resources';
  const hasGroups = await hasRiskColumns(pool, 'GraphGroups', res);
  if (hasGroups) return 'GraphGroups';
  return null;
}

// Determine the best table for user risk scores (Principals preferred over GraphUsers)
async function getUserRiskSource(pool, res) {
  const hasPrincipals = await hasRiskColumns(pool, 'Principals', res);
  if (hasPrincipals) return 'Principals';
  const hasUsers = await hasRiskColumns(pool, 'GraphUsers', res);
  if (hasUsers) return 'GraphUsers';
  return null;
}

// Select columns shared across queries
const GROUP_COLS = `id, displayName, description, groupTypeCalculated,
  riskScore, riskTier,
  riskDirectScore, riskMembershipScore, riskStructuralScore, riskPropagatedScore,
  riskClassifierMatches, riskExplanation, riskScoredAt,
  riskOverride, riskOverrideReason`;

const RESOURCE_COLS = `id, displayName, description, resourceType,
  riskScore, riskTier,
  riskDirectScore, riskMembershipScore, riskStructuralScore, riskPropagatedScore,
  riskClassifierMatches, riskExplanation, riskScoredAt,
  riskOverride, riskOverrideReason`;

const USER_COLS_GRAPH = `id, displayName, userPrincipalName, department, jobTitle,
  riskScore, riskTier,
  riskDirectScore, riskMembershipScore, riskStructuralScore, riskPropagatedScore,
  riskClassifierMatches, riskExplanation, riskScoredAt,
  riskOverride, riskOverrideReason`;

const USER_COLS_PRINCIPALS = `id, displayName, email AS userPrincipalName, department, jobTitle,
  riskScore, riskTier,
  riskDirectScore, riskMembershipScore, riskStructuralScore, riskPropagatedScore,
  riskClassifierMatches, riskExplanation, riskScoredAt,
  riskOverride, riskOverrideReason`;

// ─── GET /api/risk-scores ─────────────────────────────────────────────
router.get('/risk-scores', async (req, res) => {
  try {
    if (!useSql) {
      return res.json({ available: false, message: 'Risk scoring requires SQL mode. Run Invoke-FGRiskScoring in PowerShell first.' });
    }

    const p = await db.getPool();

    // Check if scoring has been run — prefer Resources table over GraphGroups, Principals over GraphUsers
    const resourceSource = await getResourceRiskSource(p, res);
    const userSource = await getUserRiskSource(p, res);

    if (!resourceSource && !userSource) {
      return res.json({ available: false, message: 'Risk scores not yet computed. Run Invoke-FGRiskScoring in PowerShell.' });
    }

    const hasUsers = !!userSource;
    const usePrincipals = userSource === 'Principals';
    const userTable = userSource || 'GraphUsers';
    const USER_COLS = usePrincipals ? USER_COLS_PRINCIPALS : USER_COLS_GRAPH;
    const userSearchCol = usePrincipals ? 'email' : 'userPrincipalName';

    const useResources = resourceSource === 'Resources';
    const groupTable = resourceSource || 'GraphGroups';
    const groupCols = useResources ? RESOURCE_COLS : GROUP_COLS;

    // Summary: tier distribution
    const groupTiers = resourceSource ? await timedRequest(p, 'risk-group-tiers', res).query(`
      SELECT riskTier, COUNT(*) as count
      FROM dbo.${groupTable}
      WHERE riskScore IS NOT NULL
      GROUP BY riskTier
    `) : { recordset: [] };

    const userTiers = hasUsers ? await timedRequest(p, 'risk-user-tiers', res).query(`
      SELECT riskTier, COUNT(*) as count
      FROM dbo.${userTable}
      WHERE riskScore IS NOT NULL
      GROUP BY riskTier
    `) : { recordset: [] };

    // Top 10 groups/resources by score (use effective score: computed + override)
    const topGroups = resourceSource ? await timedRequest(p, 'risk-top-groups', res).query(`
      SELECT TOP 10 ${groupCols}
      FROM dbo.${groupTable}
      WHERE riskScore IS NOT NULL
      ORDER BY COALESCE(riskScore + COALESCE(riskOverride, 0), riskScore) DESC
    `) : { recordset: [] };

    // Top 10 users by score
    const topUsers = hasUsers ? await timedRequest(p, 'risk-top-users', res).query(`
      SELECT TOP 10 ${USER_COLS}
      FROM dbo.${userTable}
      WHERE riskScore IS NOT NULL
      ORDER BY COALESCE(riskScore + COALESCE(riskOverride, 0), riskScore) DESC
    `) : { recordset: [] };

    // Totals
    const totalGroups = resourceSource ? await timedRequest(p, 'risk-total-groups', res).query(`
      SELECT COUNT(*) as total FROM dbo.${groupTable} WHERE riskScore IS NOT NULL
    `) : { recordset: [{ total: 0 }] };

    const totalUsers = hasUsers ? await timedRequest(p, 'risk-total-users', res).query(`
      SELECT COUNT(*) as total FROM dbo.${userTable} WHERE riskScore IS NOT NULL
    `) : { recordset: [{ total: 0 }] };

    // Override counts
    const groupOverrides = resourceSource ? await timedRequest(p, 'risk-group-overrides', res).query(`
      SELECT COUNT(*) as count FROM dbo.${groupTable} WHERE riskOverride IS NOT NULL
    `) : { recordset: [{ count: 0 }] };

    const userOverrides = hasUsers ? await timedRequest(p, 'risk-user-overrides', res).query(`
      SELECT COUNT(*) as count FROM dbo.${userTable} WHERE riskOverride IS NOT NULL
    `) : { recordset: [{ count: 0 }] };

    // Scored timestamp (most recent)
    let scoredAt = null;
    if (resourceSource) {
      const ts = await timedRequest(p, 'risk-scored-at', res).query(`
        SELECT TOP 1 riskScoredAt FROM dbo.${groupTable} WHERE riskScoredAt IS NOT NULL ORDER BY riskScoredAt DESC
      `);
      if (ts.recordset.length > 0) scoredAt = ts.recordset[0].riskScoredAt;
    }

    // Resource type breakdown (Resources table only)
    let resourceTypeBreakdown = null;
    if (useResources) {
      try {
        const typeResult = await timedRequest(p, 'risk-resource-types', res).query(`
          SELECT resourceType, COUNT(*) as count, AVG(CAST(riskScore AS FLOAT)) as avgScore
          FROM dbo.Resources
          WHERE riskScore IS NOT NULL
          GROUP BY resourceType
          ORDER BY AVG(CAST(riskScore AS FLOAT)) DESC
        `);
        resourceTypeBreakdown = typeResult.recordset;
      } catch { resourceTypeBreakdown = null; }
    }

    // Build tier summary objects
    const groupsByTier = {};
    const usersByTier = {};
    for (const row of groupTiers.recordset) groupsByTier[row.riskTier || 'None'] = row.count;
    for (const row of userTiers.recordset) usersByTier[row.riskTier || 'None'] = row.count;

    return res.json({
      available: true,
      useResources,
      summary: {
        totalGroups: totalGroups.recordset[0].total,
        totalUsers: totalUsers.recordset[0].total,
        groupOverrides: groupOverrides.recordset[0].count,
        userOverrides: userOverrides.recordset[0].count,
        groupsByTier,
        usersByTier,
        topGroups: topGroups.recordset.map(parseJsonColumns),
        topUsers: topUsers.recordset.map(parseJsonColumns),
        resourceTypeBreakdown,
      },
      scoredAt,
    });
  } catch (err) {
    console.error('Risk scores summary failed:', err.message);
    return res.status(500).json({ error: 'Failed to load risk scores' });
  }
});

// ─── GET /api/risk-scores/groups ──────────────────────────────────────
router.get('/risk-scores/groups', async (req, res) => {
  try {
    if (!useSql) {
      return res.json({ data: [], total: 0, available: false });
    }

    const p = await db.getPool();
    const resourceSource = await getResourceRiskSource(p, res);
    if (!resourceSource) {
      return res.json({ data: [], total: 0, available: false });
    }

    const useResources = resourceSource === 'Resources';
    const groupTable = resourceSource;
    const groupCols = useResources ? RESOURCE_COLS : GROUP_COLS;

    const limit = Math.min(parseInt(req.query.limit) || 100, 500);
    const offset = parseInt(req.query.offset) || 0;
    const tier = req.query.tier || '';
    const search = req.query.search || '';
    const resourceType = req.query.resourceType || '';
    const overridesOnly = req.query.overridesOnly === 'true';

    let whereClause = 'WHERE riskScore IS NOT NULL';
    const request = timedRequest(p, 'risk-groups-list', res);

    if (tier) {
      whereClause += ' AND riskTier = @tier';
      request.input('tier', tier);
    }
    if (search) {
      whereClause += ' AND (displayName LIKE @search OR description LIKE @search)';
      request.input('search', `%${search}%`);
    }
    if (resourceType && useResources) {
      whereClause += ' AND resourceType = @resourceType';
      request.input('resourceType', resourceType);
    }
    if (overridesOnly) {
      whereClause += ' AND riskOverride IS NOT NULL';
    }

    request.input('offset', offset);
    request.input('limit', limit);
    const result = await request.query(`
      SELECT ${groupCols}
      FROM dbo.${groupTable}
      ${whereClause}
      ORDER BY COALESCE(riskScore + COALESCE(riskOverride, 0), riskScore) DESC
      OFFSET @offset ROWS FETCH NEXT @limit ROWS ONLY
    `);

    const countReq = timedRequest(p, 'risk-groups-count', res);
    if (tier) countReq.input('tier', tier);
    if (search) countReq.input('search', `%${search}%`);
    if (resourceType && useResources) countReq.input('resourceType', resourceType);
    const countResult = await countReq.query(`SELECT COUNT(*) as total FROM dbo.${groupTable} ${whereClause}`);

    return res.json({
      data: result.recordset.map(parseJsonColumns),
      total: countResult.recordset[0].total,
      available: true,
      useResources,
    });
  } catch (err) {
    console.error('Risk groups query failed:', err.message);
    return res.status(500).json({ error: 'Failed to load risk scores' });
  }
});

// ─── GET /api/risk-scores/users ───────────────────────────────────────
router.get('/risk-scores/users', async (req, res) => {
  try {
    if (!useSql) {
      return res.json({ data: [], total: 0, available: false });
    }

    const p = await db.getPool();
    const userSource = await getUserRiskSource(p, res);
    if (!userSource) {
      return res.json({ data: [], total: 0, available: false });
    }

    const usePrincipalsForList = userSource === 'Principals';
    const userTableForList = userSource;
    const userColsForList = usePrincipalsForList ? USER_COLS_PRINCIPALS : USER_COLS_GRAPH;
    const searchCol = usePrincipalsForList ? 'email' : 'userPrincipalName';

    const limit = Math.min(parseInt(req.query.limit) || 100, 500);
    const offset = parseInt(req.query.offset) || 0;
    const tier = req.query.tier || '';
    const search = req.query.search || '';
    const overridesOnly = req.query.overridesOnly === 'true';

    let whereClause = 'WHERE riskScore IS NOT NULL';
    const request = timedRequest(p, 'risk-users-list', res);

    if (tier) {
      whereClause += ' AND riskTier = @tier';
      request.input('tier', tier);
    }
    if (search) {
      whereClause += ` AND (displayName LIKE @search OR ${searchCol} LIKE @search OR department LIKE @search)`;
      request.input('search', `%${search}%`);
    }
    if (overridesOnly) {
      whereClause += ' AND riskOverride IS NOT NULL';
    }

    request.input('offset', offset);
    request.input('limit', limit);
    const result = await request.query(`
      SELECT ${userColsForList}
      FROM dbo.${userTableForList}
      ${whereClause}
      ORDER BY COALESCE(riskScore + COALESCE(riskOverride, 0), riskScore) DESC
      OFFSET @offset ROWS FETCH NEXT @limit ROWS ONLY
    `);

    const countReq = timedRequest(p, 'risk-users-count', res);
    if (tier) countReq.input('tier', tier);
    if (search) countReq.input('search', `%${search}%`);
    const countResult = await countReq.query(`SELECT COUNT(*) as total FROM dbo.${userTableForList} ${whereClause}`);

    return res.json({
      data: result.recordset.map(parseJsonColumns),
      total: countResult.recordset[0].total,
      available: true,
    });
  } catch (err) {
    console.error('Risk users query failed:', err.message);
    return res.status(500).json({ error: 'Failed to load risk scores' });
  }
});

// ─── PUT /api/risk-scores/:type/:id/override ─────────────────────────
// Set an analyst override on a user or group risk score.
// Body: { adjustment: number (-50 to +50), reason: string (required) }
router.put('/risk-scores/:type/:id/override', async (req, res) => {
  try {
    if (!useSql) {
      return res.status(400).json({ error: 'SQL mode required' });
    }

    const { type, id } = req.params;
    if (type !== 'groups' && type !== 'users' && type !== 'resources') {
      return res.status(400).json({ error: 'Type must be "groups", "users", or "resources"' });
    }

    // Validate UUID format
    const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    if (!uuidRegex.test(id)) {
      return res.status(400).json({ error: 'Invalid entity ID format' });
    }

    const { adjustment, reason } = req.body || {};
    if (typeof adjustment !== 'number' || adjustment < -50 || adjustment > 50 || !Number.isInteger(adjustment)) {
      return res.status(400).json({ error: 'Adjustment must be an integer between -50 and +50' });
    }
    if (!reason || typeof reason !== 'string' || reason.trim().length < 3) {
      return res.status(400).json({ error: 'Reason is required (minimum 3 characters)' });
    }
    if (reason.length > 500) {
      return res.status(400).json({ error: 'Reason must be 500 characters or fewer' });
    }

    const p = await db.getPool();

    // For groups/resources, determine the best table
    let tableName;
    if (type === 'users') {
      const userSrc = await getUserRiskSource(p, res);
      tableName = userSrc || 'GraphUsers';
    } else if (type === 'resources') {
      tableName = 'Resources';
    } else {
      const resourceSource = await getResourceRiskSource(p, res);
      tableName = resourceSource || 'GraphGroups';
    }

    const request = timedRequest(p, `risk-override-set-${type}`, res);
    request.input('id', id);
    request.input('adjustment', adjustment);
    request.input('reason', reason.trim());

    const result = await request.query(`
      UPDATE dbo.${tableName}
      SET riskOverride = @adjustment, riskOverrideReason = @reason
      WHERE id = @id AND riskScore IS NOT NULL
    `);

    if (result.rowsAffected[0] === 0) {
      return res.status(404).json({ error: 'Entity not found or not yet scored' });
    }

    return res.json({ success: true, adjustment, reason: reason.trim() });
  } catch (err) {
    console.error('Risk override set failed:', err.message);
    return res.status(500).json({ error: 'Failed to set override' });
  }
});

// ─── DELETE /api/risk-scores/:type/:id/override ──────────────────────
// Remove an analyst override from a user or group.
router.delete('/risk-scores/:type/:id/override', async (req, res) => {
  try {
    if (!useSql) {
      return res.status(400).json({ error: 'SQL mode required' });
    }

    const { type, id } = req.params;
    if (type !== 'groups' && type !== 'users' && type !== 'resources') {
      return res.status(400).json({ error: 'Type must be "groups", "users", or "resources"' });
    }

    const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    if (!uuidRegex.test(id)) {
      return res.status(400).json({ error: 'Invalid entity ID format' });
    }

    const p = await db.getPool();

    // For groups/resources, determine the best table
    let tableName;
    if (type === 'users') {
      const userSrc = await getUserRiskSource(p, res);
      tableName = userSrc || 'GraphUsers';
    } else if (type === 'resources') {
      tableName = 'Resources';
    } else {
      const resourceSource = await getResourceRiskSource(p, res);
      tableName = resourceSource || 'GraphGroups';
    }

    const request = timedRequest(p, `risk-override-clear-${type}`, res);
    request.input('id', id);

    await request.query(`
      UPDATE dbo.${tableName}
      SET riskOverride = NULL, riskOverrideReason = NULL
      WHERE id = @id
    `);

    return res.json({ success: true });
  } catch (err) {
    console.error('Risk override clear failed:', err.message);
    return res.status(500).json({ error: 'Failed to clear override' });
  }
});

export default router;
