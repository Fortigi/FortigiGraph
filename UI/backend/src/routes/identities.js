// ─── Account Correlation / Identities API Routes ─────────────────────────
//
// Reads pre-computed identity correlations from SQL.
// Identities are computed by Invoke-FGAccountCorrelation (PowerShell).
// This route reads identity data and manages analyst overrides.
//
// GET    /api/identities                    - Summary + paginated identity list
// GET    /api/identities/:id                - Single identity with all linked accounts
// PUT    /api/identities/:id/verify         - Mark identity as analyst-verified
// DELETE /api/identities/:id/verify         - Remove analyst verification
// PUT    /api/identities/:id/members/:userId/override - Analyst override on member link
// DELETE /api/identities/:id/members/:userId/override - Remove analyst override

import { Router } from 'express';
import { timedRequest } from '../perf/sqlTimer.js';

const router = Router();
const useSql = process.env.USE_SQL === 'true';

let db = null;
if (useSql) {
  db = await import('../db/connection.js');
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function hasTable(pool, tableName) {
  const result = await pool.request()
    .input('tableName', tableName)
    .query(`SELECT COUNT(*) AS cnt FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = @tableName AND TABLE_SCHEMA = 'dbo'`);
  return result.recordset[0].cnt > 0;
}

// GET /api/identities — summary + paginated list
router.get('/identities', async (req, res) => {
  if (!useSql) return res.json({ available: false, data: [], total: 0, summary: null });

  try {
    const p = await db.getPool();

    if (!(await hasTable(p, 'GraphIdentities'))) {
      return res.json({ available: false, data: [], total: 0, summary: null });
    }

    const { search, minAccounts, accountType, confidence, verified, hrAnchored, orphanStatus, sort, limit, offset } = req.query;
    const pageLimit = Math.min(parseInt(limit) || 50, 500);
    const pageOffset = parseInt(offset) || 0;

    // Build summary
    // Check if HR columns exist (schema may be pre-1.1)
    const colCheck = await p.request().query(`
      SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS
      WHERE TABLE_NAME = 'GraphIdentities' AND COLUMN_NAME IN ('isHrAnchored', 'orphanStatus')
    `);
    const hasHrCols = colCheck.recordset.length >= 2;

    const summaryResult = await timedRequest(p, 'identity-summary', res)
      .query(`
        SELECT
          COUNT(*) AS totalIdentities,
          SUM(CASE WHEN accountCount > 1 THEN 1 ELSE 0 END) AS multiAccountIdentities,
          SUM(CASE WHEN accountCount = 1 THEN 1 ELSE 0 END) AS singleAccountIdentities,
          SUM(accountCount) AS totalAccounts,
          SUM(CASE WHEN analystVerified = 1 THEN 1 ELSE 0 END) AS verifiedCount,
          AVG(CAST(correlationConfidence AS FLOAT)) AS avgConfidence,
          MAX(correlatedAt) AS lastCorrelatedAt
          ${hasHrCols ? `, SUM(CASE WHEN isHrAnchored = 1 THEN 1 ELSE 0 END) AS hrAnchoredCount,
          SUM(CASE WHEN orphanStatus IS NOT NULL THEN 1 ELSE 0 END) AS orphanCount` : ''}
        FROM dbo.GraphIdentities
      `);
    const summary = summaryResult.recordset[0];

    // Account type distribution
    const typeDistResult = await timedRequest(p, 'identity-type-dist', res)
      .query(`
        SELECT accountType, COUNT(*) AS cnt
        FROM dbo.GraphIdentityMembers
        GROUP BY accountType
        ORDER BY cnt DESC
      `);
    summary.accountTypeDistribution = typeDistResult.recordset;

    // Build filtered query
    let where = 'WHERE 1=1';
    const inputs = {};

    if (search) {
      where += ' AND (displayName LIKE @search OR primaryAccountUpn LIKE @search OR mail LIKE @search OR department LIKE @search)';
      inputs.search = `%${search}%`;
    }

    if (minAccounts) {
      const min = parseInt(minAccounts);
      if (min > 1) {
        where += ' AND accountCount >= @minAccounts';
        inputs.minAccounts = min;
      }
    }

    if (accountType) {
      where += ' AND accountTypes LIKE @accountType';
      inputs.accountType = `%${accountType}%`;
    }

    if (confidence) {
      where += ' AND correlationConfidence >= @confidence';
      inputs.confidence = parseInt(confidence);
    }

    if (verified === 'true') {
      where += ' AND analystVerified = 1';
    } else if (verified === 'false') {
      where += ' AND analystVerified = 0';
    }

    if (hasHrCols) {
      if (hrAnchored === 'true') {
        where += ' AND isHrAnchored = 1';
      } else if (hrAnchored === 'false') {
        where += ' AND isHrAnchored = 0';
      }

      if (orphanStatus === 'any') {
        where += ' AND orphanStatus IS NOT NULL';
      } else if (orphanStatus === 'none') {
        where += ' AND orphanStatus IS NULL';
      } else if (orphanStatus) {
        where += ' AND orphanStatus = @orphanStatus';
        inputs.orphanStatus = orphanStatus;
      }
    }

    // Count
    const countReq = timedRequest(p, 'identity-count', res);
    for (const [k, v] of Object.entries(inputs)) countReq.input(k, v);
    const countResult = await countReq.query(`SELECT COUNT(*) AS total FROM dbo.GraphIdentities ${where}`);
    const total = countResult.recordset[0].total;

    // Sort
    const ALLOWED_SORTS = {
      'accountCount': 'accountCount DESC',
      'confidence': 'correlationConfidence DESC',
      'displayName': 'displayName ASC',
      'department': 'department ASC',
      'correlatedAt': 'correlatedAt DESC',
    };
    const orderBy = ALLOWED_SORTS[sort] || 'accountCount DESC, displayName ASC';

    // Paginated data
    const dataReq = timedRequest(p, 'identity-list', res);
    for (const [k, v] of Object.entries(inputs)) dataReq.input(k, v);
    const dataResult = await dataReq.query(`
      SELECT id, displayName, primaryAccountId, primaryAccountUpn, accountCount, accountTypes,
        correlationConfidence, correlationSignals, department, jobTitle, managerId, mail,
        givenName, surname, employeeId, companyName, employeeType, city, country, officeLocation,
        accountEnabled, correlatedAt, analystVerified, analystNotes
        ${hasHrCols ? ', isHrAnchored, hrAccountId, orphanStatus' : ''}
      FROM dbo.GraphIdentities
      ${where}
      ORDER BY ${orderBy}
      OFFSET ${pageOffset} ROWS FETCH NEXT ${pageLimit} ROWS ONLY
    `);

    res.json({
      available: true,
      summary,
      data: dataResult.recordset,
      total,
      hasHrColumns: hasHrCols,
    });
  } catch (err) {
    console.error('Error fetching identities:', err);
    res.status(500).json({ error: 'Failed to fetch identities' });
  }
});

// GET /api/identities/:id — single identity with all linked accounts
router.get('/identities/:id', async (req, res) => {
  if (!useSql) return res.status(404).json({ error: 'SQL not configured' });

  const identityId = req.params.id;
  if (!UUID_RE.test(identityId)) return res.status(400).json({ error: 'Invalid identity ID' });

  try {
    const p = await db.getPool();

    // Fetch identity
    const identityResult = await timedRequest(p, 'identity-detail', res)
      .input('id', identityId)
      .query(`SELECT * FROM dbo.GraphIdentities WHERE id = @id`);

    if (identityResult.recordset.length === 0) {
      return res.status(404).json({ error: 'Identity not found' });
    }

    const identity = identityResult.recordset[0];

    // Fetch all member accounts
    const membersResult = await timedRequest(p, 'identity-members', res)
      .input('identityId', identityId)
      .query(`
        SELECT m.*, u.department, u.jobTitle, u.lastSignInDateTime, u.createdDateTime, u.accountEnabled AS userAccountEnabled
        FROM dbo.GraphIdentityMembers m
        LEFT JOIN dbo.GraphUsers u ON m.userId = u.id
        WHERE m.identityId = @identityId
        ORDER BY m.isPrimary DESC, m.accountType ASC
      `);

    // Fetch group memberships per account for context
    let memberGroupCounts = [];
    try {
      const groupCountResult = await timedRequest(p, 'identity-member-groups', res)
        .input('identityId', identityId)
        .query(`
          SELECT m.userId, COUNT(DISTINCT gm.groupId) AS groupCount
          FROM dbo.GraphIdentityMembers m
          LEFT JOIN dbo.GraphGroupMembers gm ON m.userId = gm.memberId
          WHERE m.identityId = @identityId
          GROUP BY m.userId
        `);
      memberGroupCounts = groupCountResult.recordset;
    } catch {
      // GraphGroupMembers may not exist
    }

    // Enrich members with group counts
    const groupCountMap = {};
    for (const gc of memberGroupCounts) {
      groupCountMap[gc.userId] = gc.groupCount;
    }
    for (const member of membersResult.recordset) {
      member.groupCount = groupCountMap[member.userId] || 0;
    }

    res.json({
      identity,
      members: membersResult.recordset,
    });
  } catch (err) {
    console.error('Error fetching identity detail:', err);
    res.status(500).json({ error: 'Failed to fetch identity detail' });
  }
});

// PUT /api/identities/:id/verify — mark as analyst-verified
router.put('/identities/:id/verify', async (req, res) => {
  if (!useSql) return res.status(400).json({ error: 'SQL not configured' });

  const identityId = req.params.id;
  if (!UUID_RE.test(identityId)) return res.status(400).json({ error: 'Invalid identity ID' });

  const { notes } = req.body || {};

  try {
    const p = await db.getPool();
    await timedRequest(p, 'identity-verify', res)
      .input('id', identityId)
      .input('notes', notes || null)
      .query(`UPDATE dbo.GraphIdentities SET analystVerified = 1, analystNotes = @notes WHERE id = @id`);

    res.json({ success: true });
  } catch (err) {
    console.error('Error verifying identity:', err);
    res.status(500).json({ error: 'Failed to verify identity' });
  }
});

// DELETE /api/identities/:id/verify — remove verification
router.delete('/identities/:id/verify', async (req, res) => {
  if (!useSql) return res.status(400).json({ error: 'SQL not configured' });

  const identityId = req.params.id;
  if (!UUID_RE.test(identityId)) return res.status(400).json({ error: 'Invalid identity ID' });

  try {
    const p = await db.getPool();
    await timedRequest(p, 'identity-unverify', res)
      .input('id', identityId)
      .query(`UPDATE dbo.GraphIdentities SET analystVerified = 0, analystNotes = NULL WHERE id = @id`);

    res.json({ success: true });
  } catch (err) {
    console.error('Error removing identity verification:', err);
    res.status(500).json({ error: 'Failed to remove verification' });
  }
});

// PUT /api/identities/:id/members/:userId/override — analyst override on member
router.put('/identities/:id/members/:userId/override', async (req, res) => {
  if (!useSql) return res.status(400).json({ error: 'SQL not configured' });

  const { id: identityId, userId } = req.params;
  if (!UUID_RE.test(identityId) || !UUID_RE.test(userId)) {
    return res.status(400).json({ error: 'Invalid ID format' });
  }

  const { action, reason } = req.body || {};
  if (!action || !['confirmed', 'rejected', 'moved'].includes(action)) {
    return res.status(400).json({ error: 'Action must be one of: confirmed, rejected, moved' });
  }
  if (!reason || reason.trim().length < 3) {
    return res.status(400).json({ error: 'Reason is required (min 3 characters)' });
  }

  try {
    const p = await db.getPool();
    await timedRequest(p, 'identity-member-override', res)
      .input('identityId', identityId)
      .input('userId', userId)
      .input('action', action)
      .input('reason', reason.trim())
      .query(`
        UPDATE dbo.GraphIdentityMembers
        SET analystOverride = @action, analystReason = @reason
        WHERE identityId = @identityId AND userId = @userId
      `);

    res.json({ success: true, action, reason: reason.trim() });
  } catch (err) {
    console.error('Error setting member override:', err);
    res.status(500).json({ error: 'Failed to set member override' });
  }
});

// DELETE /api/identities/:id/members/:userId/override — remove analyst override
router.delete('/identities/:id/members/:userId/override', async (req, res) => {
  if (!useSql) return res.status(400).json({ error: 'SQL not configured' });

  const { id: identityId, userId } = req.params;
  if (!UUID_RE.test(identityId) || !UUID_RE.test(userId)) {
    return res.status(400).json({ error: 'Invalid ID format' });
  }

  try {
    const p = await db.getPool();
    await timedRequest(p, 'identity-member-remove-override', res)
      .input('identityId', identityId)
      .input('userId', userId)
      .query(`
        UPDATE dbo.GraphIdentityMembers
        SET analystOverride = NULL, analystReason = NULL
        WHERE identityId = @identityId AND userId = @userId
      `);

    res.json({ success: true });
  } catch (err) {
    console.error('Error removing member override:', err);
    res.status(500).json({ error: 'Failed to remove member override' });
  }
});

export default router;
