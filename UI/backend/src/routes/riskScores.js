// ─── Risk Scores API Routes ───────────────────────────────────────────
//
// Reads pre-computed risk scores from SQL columns on GraphUsers and GraphGroups.
// Scores are computed by the PowerShell cmdlet Invoke-FGRiskScoring (batch process).
// This route does NO computation — it's a simple SELECT.
//
// GET /api/risk-scores         - Summary + top entities by score
// GET /api/risk-scores/groups  - Paginated group scores
// GET /api/risk-scores/users   - Paginated user scores

import { Router } from 'express';
import { timedRequest } from '../perf/sqlTimer.js';

const router = Router();
const useSql = process.env.USE_SQL === 'true';

let db = null;
if (useSql) {
  db = await import('../db/connection.js');
}

// Check if risk score columns exist
async function hasRiskColumns(pool, tableName, res) {
  try {
    const result = await timedRequest(pool, `risk-col-check-${tableName}`, res).query(`
      SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
      WHERE TABLE_NAME = '${tableName}' AND TABLE_SCHEMA = 'dbo' AND COLUMN_NAME = 'riskScore'
    `);
    return result.recordset.length > 0;
  } catch {
    return false;
  }
}

// ─── GET /api/risk-scores ─────────────────────────────────────────────
router.get('/risk-scores', async (req, res) => {
  try {
    if (!useSql) {
      return res.json({ available: false, message: 'Risk scoring requires SQL mode. Run Invoke-FGRiskScoring in PowerShell first.' });
    }

    const p = await db.getPool();

    // Check if scoring has been run
    const hasGroups = await hasRiskColumns(p, 'GraphGroups', res);
    const hasUsers = await hasRiskColumns(p, 'GraphUsers', res);

    if (!hasGroups && !hasUsers) {
      return res.json({ available: false, message: 'Risk scores not yet computed. Run Invoke-FGRiskScoring in PowerShell.' });
    }

    // Summary: tier distribution
    const groupTiers = hasGroups ? await timedRequest(p, 'risk-group-tiers', res).query(`
      SELECT riskTier, COUNT(*) as count
      FROM dbo.GraphGroups
      WHERE riskScore IS NOT NULL
      GROUP BY riskTier
    `) : { recordset: [] };

    const userTiers = hasUsers ? await timedRequest(p, 'risk-user-tiers', res).query(`
      SELECT riskTier, COUNT(*) as count
      FROM dbo.GraphUsers
      WHERE riskScore IS NOT NULL
      GROUP BY riskTier
    `) : { recordset: [] };

    // Top 10 groups by score
    const topGroups = hasGroups ? await timedRequest(p, 'risk-top-groups', res).query(`
      SELECT TOP 10 id, displayName, description, riskScore, riskTier,
             riskDirectScore, riskMembershipScore, riskStructuralScore, riskPropagatedScore,
             riskClassifierMatches, riskScoredAt
      FROM dbo.GraphGroups
      WHERE riskScore IS NOT NULL
      ORDER BY riskScore DESC
    `) : { recordset: [] };

    // Top 10 users by score
    const topUsers = hasUsers ? await timedRequest(p, 'risk-top-users', res).query(`
      SELECT TOP 10 id, displayName, userPrincipalName, department, jobTitle,
             riskScore, riskTier,
             riskDirectScore, riskMembershipScore, riskStructuralScore, riskPropagatedScore,
             riskClassifierMatches, riskScoredAt
      FROM dbo.GraphUsers
      WHERE riskScore IS NOT NULL
      ORDER BY riskScore DESC
    `) : { recordset: [] };

    // Totals
    const totalGroups = hasGroups ? await timedRequest(p, 'risk-total-groups', res).query(`
      SELECT COUNT(*) as total FROM dbo.GraphGroups WHERE riskScore IS NOT NULL
    `) : { recordset: [{ total: 0 }] };

    const totalUsers = hasUsers ? await timedRequest(p, 'risk-total-users', res).query(`
      SELECT COUNT(*) as total FROM dbo.GraphUsers WHERE riskScore IS NOT NULL
    `) : { recordset: [{ total: 0 }] };

    // Scored timestamp (most recent)
    let scoredAt = null;
    if (hasGroups) {
      const ts = await timedRequest(p, 'risk-scored-at', res).query(`
        SELECT TOP 1 riskScoredAt FROM dbo.GraphGroups WHERE riskScoredAt IS NOT NULL ORDER BY riskScoredAt DESC
      `);
      if (ts.recordset.length > 0) scoredAt = ts.recordset[0].riskScoredAt;
    }

    // Build tier summary objects
    const groupsByTier = {};
    const usersByTier = {};
    for (const row of groupTiers.recordset) groupsByTier[row.riskTier || 'None'] = row.count;
    for (const row of userTiers.recordset) usersByTier[row.riskTier || 'None'] = row.count;

    // Parse classifier matches JSON for top entities
    const parseMatches = (row) => {
      const r = { ...row };
      try {
        r.classifierMatches = r.riskClassifierMatches ? JSON.parse(r.riskClassifierMatches) : [];
      } catch { r.classifierMatches = []; }
      delete r.riskClassifierMatches;
      return r;
    };

    return res.json({
      available: true,
      summary: {
        totalGroups: totalGroups.recordset[0].total,
        totalUsers: totalUsers.recordset[0].total,
        groupsByTier,
        usersByTier,
        topGroups: topGroups.recordset.map(parseMatches),
        topUsers: topUsers.recordset.map(parseMatches),
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
    if (!(await hasRiskColumns(p, 'GraphGroups', res))) {
      return res.json({ data: [], total: 0, available: false });
    }

    const limit = Math.min(parseInt(req.query.limit) || 100, 500);
    const offset = parseInt(req.query.offset) || 0;
    const tier = req.query.tier || '';
    const search = req.query.search || '';

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

    const result = await request.query(`
      SELECT id, displayName, description, groupTypeCalculated,
             riskScore, riskTier,
             riskDirectScore, riskMembershipScore, riskStructuralScore, riskPropagatedScore,
             riskClassifierMatches, riskScoredAt
      FROM dbo.GraphGroups
      ${whereClause}
      ORDER BY riskScore DESC
      OFFSET ${offset} ROWS FETCH NEXT ${limit} ROWS ONLY
    `);

    const countReq = timedRequest(p, 'risk-groups-count', res);
    if (tier) countReq.input('tier', tier);
    if (search) countReq.input('search', `%${search}%`);
    const countResult = await countReq.query(`SELECT COUNT(*) as total FROM dbo.GraphGroups ${whereClause}`);

    const parseMatches = (row) => {
      const r = { ...row };
      try { r.classifierMatches = r.riskClassifierMatches ? JSON.parse(r.riskClassifierMatches) : []; }
      catch { r.classifierMatches = []; }
      delete r.riskClassifierMatches;
      return r;
    };

    return res.json({
      data: result.recordset.map(parseMatches),
      total: countResult.recordset[0].total,
      available: true,
    });
  } catch (err) {
    console.error('Risk groups query failed:', err.message);
    return res.status(500).json({ error: err.message });
  }
});

// ─── GET /api/risk-scores/users ───────────────────────────────────────
router.get('/risk-scores/users', async (req, res) => {
  try {
    if (!useSql) {
      return res.json({ data: [], total: 0, available: false });
    }

    const p = await db.getPool();
    if (!(await hasRiskColumns(p, 'GraphUsers', res))) {
      return res.json({ data: [], total: 0, available: false });
    }

    const limit = Math.min(parseInt(req.query.limit) || 100, 500);
    const offset = parseInt(req.query.offset) || 0;
    const tier = req.query.tier || '';
    const search = req.query.search || '';

    let whereClause = 'WHERE riskScore IS NOT NULL';
    const request = timedRequest(p, 'risk-users-list', res);

    if (tier) {
      whereClause += ' AND riskTier = @tier';
      request.input('tier', tier);
    }
    if (search) {
      whereClause += ' AND (displayName LIKE @search OR userPrincipalName LIKE @search OR department LIKE @search)';
      request.input('search', `%${search}%`);
    }

    const result = await request.query(`
      SELECT id, displayName, userPrincipalName, department, jobTitle,
             riskScore, riskTier,
             riskDirectScore, riskMembershipScore, riskStructuralScore, riskPropagatedScore,
             riskClassifierMatches, riskScoredAt
      FROM dbo.GraphUsers
      ${whereClause}
      ORDER BY riskScore DESC
      OFFSET ${offset} ROWS FETCH NEXT ${limit} ROWS ONLY
    `);

    const countReq = timedRequest(p, 'risk-users-count', res);
    if (tier) countReq.input('tier', tier);
    if (search) countReq.input('search', `%${search}%`);
    const countResult = await countReq.query(`SELECT COUNT(*) as total FROM dbo.GraphUsers ${whereClause}`);

    const parseMatches = (row) => {
      const r = { ...row };
      try { r.classifierMatches = r.riskClassifierMatches ? JSON.parse(r.riskClassifierMatches) : []; }
      catch { r.classifierMatches = []; }
      delete r.riskClassifierMatches;
      return r;
    };

    return res.json({
      data: result.recordset.map(parseMatches),
      total: countResult.recordset[0].total,
      available: true,
    });
  } catch (err) {
    console.error('Risk users query failed:', err.message);
    return res.status(500).json({ error: err.message });
  }
});

export default router;
