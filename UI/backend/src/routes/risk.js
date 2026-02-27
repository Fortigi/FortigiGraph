// ─── Risk Scoring API Routes ──────────────────────────────────────────
//
// GET /api/risk-scores         - Run scoring engine and return all scores + summary
// GET /api/risk-scores/groups  - Group scores only (paginated)
// GET /api/risk-scores/users   - User scores only (paginated)
// GET /api/risk-classifiers    - Return loaded classifiers for review

import { Router } from 'express';
import { scoreAll, loadClassifiers, RISK_TIERS } from '../risk/engine.js';
import { timedRequest } from '../perf/sqlTimer.js';

const router = Router();
const useSql = process.env.USE_SQL === 'true';

let db = null;
if (useSql) {
  db = await import('../db/connection.js');
}

// ─── Cache for scored results (invalidated on re-score) ──────────────
let _cachedResult = null;
let _cacheTimestamp = 0;
const CACHE_TTL_MS = 5 * 60 * 1000; // 5 minutes

function isCacheValid() {
  return _cachedResult && (Date.now() - _cacheTimestamp) < CACHE_TTL_MS;
}

// ─── Data Loading ─────────────────────────────────────────────────────

async function loadDataFromSQL(res) {
  const p = await db.getPool();

  // Load users
  const usersResult = await timedRequest(p, 'risk-load-users', res).query(`
    SELECT id, displayName, userPrincipalName, department, jobTitle,
           companyName, accountEnabled, userType, mail,
           lastSignInDateTime, createdDateTime
    FROM dbo.GraphUsers
  `);

  // Load groups
  const groupsResult = await timedRequest(p, 'risk-load-groups', res).query(`
    SELECT id, displayName, description, mailEnabled, securityEnabled,
           isAssignableToRole, membershipRuleProcessingState,
           groupTypeCalculated, createdDateTime
    FROM dbo.GraphGroups
  `);

  // Load assignments from the permission view
  // Try materialized table first, fall back to view
  const matCheck = await timedRequest(p, 'risk-mat-check', res).query(`
    SELECT OBJECT_ID('dbo.mat_UserPermissionAssignments', 'U') AS matExists
  `);
  const permSource = matCheck.recordset[0]?.matExists
    ? 'mat_UserPermissionAssignments'
    : 'vw_UserPermissionAssignments';

  const assignmentsResult = await timedRequest(p, 'risk-load-assignments', res).query(`
    SELECT groupId, memberId, membershipType
    FROM dbo.${permSource}
  `);

  return {
    users: usersResult.recordset,
    groups: groupsResult.recordset,
    assignments: assignmentsResult.recordset,
  };
}

function loadDataFromMock() {
  // Lazy import to avoid loading mock data when using SQL
  const { users, groups, permissionAssignments } = require('../mock/data.js');
  return {
    users,
    groups,
    assignments: permissionAssignments.map(pa => ({
      groupId: pa.groupId,
      memberId: pa.memberId,
      membershipType: pa.membershipType,
    })),
  };
}

async function loadDataFromMockAsync() {
  const mockModule = await import('../mock/data.js');
  return {
    users: mockModule.users,
    groups: mockModule.groups,
    assignments: mockModule.permissionAssignments.map(pa => ({
      groupId: pa.groupId,
      memberId: pa.memberId,
      membershipType: pa.membershipType,
    })),
  };
}

// ─── GET /api/risk-scores ─────────────────────────────────────────────
// Runs the full scoring engine and returns summary + all scored entities.
// Query params:
//   force=true  - bypass cache and re-score
//   tier        - filter by risk tier label (e.g. "Critical", "High")

router.get('/risk-scores', async (req, res) => {
  try {
    const forceRefresh = req.query.force === 'true';

    if (!forceRefresh && isCacheValid()) {
      return respondWithScores(res, _cachedResult, req.query);
    }

    // Load data
    const data = useSql
      ? await loadDataFromSQL(res)
      : await loadDataFromMockAsync();

    // Run scoring engine
    const result = scoreAll(data);

    // Cache
    _cachedResult = result;
    _cacheTimestamp = Date.now();

    return respondWithScores(res, result, req.query);
  } catch (err) {
    console.error('Risk scoring failed:', err.message);
    return res.status(500).json({ error: 'Risk scoring failed: ' + err.message });
  }
});

function respondWithScores(res, result, query) {
  const tierFilter = query.tier;
  let groups = result.groups;
  let users = result.users;

  if (tierFilter) {
    groups = groups.filter(g => g.riskTier.label === tierFilter);
    users = users.filter(u => u.riskTier.label === tierFilter);
  }

  return res.json({
    summary: result.summary,
    groups: groups.map(formatScore),
    users: users.map(formatScore),
    riskTiers: RISK_TIERS,
    cachedAt: _cacheTimestamp ? new Date(_cacheTimestamp).toISOString() : null,
  });
}

// Strip internal fields from response
function formatScore(s) {
  return {
    entityId: s.entityId,
    entityType: s.entityType,
    displayName: s.displayName,
    description: s.description,
    userPrincipalName: s.userPrincipalName,
    department: s.department,
    jobTitle: s.jobTitle,
    finalScore: s.finalScore,
    riskTier: s.riskTier,
    directScore: s.directScore,
    membershipScore: s.membershipScore,
    structuralScore: s.structuralScore,
    propagatedScore: s.propagatedScore,
    classifierMatches: s.classifierMatches,
    membershipSignals: s.membershipSignals,
    structuralSignals: s.structuralSignals,
    propagationSource: s.propagationSource,
  };
}

// ─── GET /api/risk-scores/groups ──────────────────────────────────────
router.get('/risk-scores/groups', async (req, res) => {
  try {
    if (!isCacheValid()) {
      const data = useSql
        ? await loadDataFromSQL(res)
        : await loadDataFromMockAsync();
      _cachedResult = scoreAll(data);
      _cacheTimestamp = Date.now();
    }

    const limit = Math.min(parseInt(req.query.limit) || 100, 500);
    const offset = parseInt(req.query.offset) || 0;
    const tierFilter = req.query.tier;
    const search = (req.query.search || '').toLowerCase();

    let groups = _cachedResult.groups;
    if (tierFilter) groups = groups.filter(g => g.riskTier.label === tierFilter);
    if (search) groups = groups.filter(g =>
      g.displayName?.toLowerCase().includes(search) ||
      g.description?.toLowerCase().includes(search)
    );

    return res.json({
      data: groups.slice(offset, offset + limit).map(formatScore),
      total: groups.length,
    });
  } catch (err) {
    console.error('Risk groups query failed:', err.message);
    return res.status(500).json({ error: err.message });
  }
});

// ─── GET /api/risk-scores/users ───────────────────────────────────────
router.get('/risk-scores/users', async (req, res) => {
  try {
    if (!isCacheValid()) {
      const data = useSql
        ? await loadDataFromSQL(res)
        : await loadDataFromMockAsync();
      _cachedResult = scoreAll(data);
      _cacheTimestamp = Date.now();
    }

    const limit = Math.min(parseInt(req.query.limit) || 100, 500);
    const offset = parseInt(req.query.offset) || 0;
    const tierFilter = req.query.tier;
    const search = (req.query.search || '').toLowerCase();

    let users = _cachedResult.users;
    if (tierFilter) users = users.filter(u => u.riskTier.label === tierFilter);
    if (search) users = users.filter(u =>
      u.displayName?.toLowerCase().includes(search) ||
      u.userPrincipalName?.toLowerCase().includes(search) ||
      u.department?.toLowerCase().includes(search)
    );

    return res.json({
      data: users.slice(offset, offset + limit).map(formatScore),
      total: users.length,
    });
  } catch (err) {
    console.error('Risk users query failed:', err.message);
    return res.status(500).json({ error: err.message });
  }
});

// ─── GET /api/risk-classifiers ────────────────────────────────────────
router.get('/risk-classifiers', (req, res) => {
  try {
    const classifiers = loadClassifiers();
    return res.json(classifiers);
  } catch (err) {
    console.error('Failed to load classifiers:', err.message);
    return res.status(500).json({ error: err.message });
  }
});

export default router;
