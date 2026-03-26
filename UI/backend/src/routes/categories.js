import { Router } from 'express';

const router = Router();
const useSql = process.env.USE_SQL === 'true';

let db = null;
if (useSql) {
  db = await import('../db/connection.js');
}

// ─── Auto-create category tables if they don't exist ─────────────
let tablesReady = false;

async function ensureCategoryTables(pool) {
  if (tablesReady) return;
  // Create each table in a separate statement to avoid partial failures
  await pool.request().query(`
    IF OBJECT_ID('dbo.GovernanceCategories', 'U') IS NULL
    CREATE TABLE dbo.GovernanceCategories (
      id INT IDENTITY(1,1) PRIMARY KEY,
      name NVARCHAR(100) NOT NULL UNIQUE,
      color NVARCHAR(7) NOT NULL DEFAULT '#3b82f6',
      createdAt DATETIME2 DEFAULT GETUTCDATE()
    );
  `);
  await pool.request().query(`
    IF OBJECT_ID('dbo.GovernanceCategoryAssignments', 'U') IS NULL
    CREATE TABLE dbo.GovernanceCategoryAssignments (
      resourceId NVARCHAR(36) NOT NULL PRIMARY KEY,
      categoryId INT NOT NULL REFERENCES dbo.GovernanceCategories(id) ON DELETE CASCADE
    );
  `);
  // Migrate: rename businessRoleId -> resourceId if the old column still exists
  try {
    const colCheck = await pool.request().query(`
      SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
      WHERE TABLE_NAME = 'GovernanceCategoryAssignments' AND COLUMN_NAME = 'businessRoleId'
    `);
    if (colCheck.recordset.length > 0) {
      await pool.request().query(`EXEC sp_rename 'dbo.GovernanceCategoryAssignments.businessRoleId', 'resourceId', 'COLUMN'`);
      console.log('[categories] Migrated GovernanceCategoryAssignments: businessRoleId -> resourceId');
    }
  } catch { /* column already renamed or table is new */ }
  tablesReady = true;
}

export { ensureCategoryTables };

const TAG_COLORS = [
  '#3b82f6', '#10b981', '#f59e0b', '#ef4444', '#8b5cf6',
  '#ec4899', '#14b8a6', '#f97316', '#6366f1', '#84cc16',
];

// Validate hex color format (#000000 – #ffffff)
const HEX_COLOR_RE = /^#[0-9a-fA-F]{6}$/;

// ─── GET /api/categories ─────────────────────────────────────────
router.get('/categories', async (req, res) => {
  try {
    if (!useSql) return res.json([]);
    const p = await db.getPool();
    await ensureCategoryTables(p);
    const result = await p.request().query(`
      SELECT c.*, ISNULL(COUNT(ca.categoryId), 0) AS assignmentCount
      FROM dbo.GovernanceCategories c
      LEFT JOIN dbo.GovernanceCategoryAssignments ca ON ca.categoryId = c.id
      GROUP BY c.id, c.name, c.color, c.createdAt
      ORDER BY c.name
    `);
    res.json(result.recordset);
  } catch (err) {
    console.error('GET /categories failed:', err.message);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ─── POST /api/categories ────────────────────────────────────────
router.post('/categories', async (req, res) => {
  try {
    if (!useSql) return res.status(400).json({ error: 'SQL mode required' });
    const { name, color } = req.body;
    if (!name) return res.status(400).json({ error: 'name required' });
    if (color && !HEX_COLOR_RE.test(color)) return res.status(400).json({ error: 'color must be a hex value like #3b82f6' });

    const p = await db.getPool();
    await ensureCategoryTables(p);
    const result = await p.request()
      .input('name', name.trim())
      .input('color', color || TAG_COLORS[0])
      .query(`
        INSERT INTO dbo.GovernanceCategories (name, color)
        OUTPUT INSERTED.*
        VALUES (@name, @color)
      `);
    res.status(201).json(result.recordset[0]);
  } catch (err) {
    if (err.message?.includes('UQ__Governance') || err.message?.includes('UQ__GraphCat') || err.message?.includes('UNIQUE')) {
      return res.status(409).json({ error: 'A category with this name already exists' });
    }
    console.error('POST /categories failed:', err.message);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ─── PATCH /api/categories/:id ───────────────────────────────────
router.patch('/categories/:id', async (req, res) => {
  try {
    if (!useSql) return res.status(400).json({ error: 'SQL mode required' });
    const { name, color } = req.body;
    if (color && !HEX_COLOR_RE.test(color)) return res.status(400).json({ error: 'color must be a hex value like #3b82f6' });
    const p = await db.getPool();
    await ensureCategoryTables(p);
    const id = parseInt(req.params.id, 10);
    if (isNaN(id)) return res.status(400).json({ error: 'Invalid category ID' });
    const request = p.request().input('id', id);
    const sets = [];
    if (name) { sets.push('name = @name'); request.input('name', name.trim()); }
    if (color) { sets.push('color = @color'); request.input('color', color); }
    if (sets.length === 0) return res.status(400).json({ error: 'Nothing to update' });
    const result = await request.query(
      `UPDATE dbo.GovernanceCategories SET ${sets.join(', ')} OUTPUT INSERTED.* WHERE id = @id`
    );
    res.json(result.recordset[0] || null);
  } catch (err) {
    console.error('PATCH /categories failed:', err.message);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ─── DELETE /api/categories/:id ──────────────────────────────────
router.delete('/categories/:id', async (req, res) => {
  try {
    if (!useSql) return res.status(400).json({ error: 'SQL mode required' });
    const id = parseInt(req.params.id, 10);
    if (isNaN(id)) return res.status(400).json({ error: 'Invalid category ID' });
    const p = await db.getPool();
    await ensureCategoryTables(p);
    await p.request()
      .input('id', id)
      .query('DELETE FROM dbo.GovernanceCategories WHERE id = @id');
    res.json({ ok: true });
  } catch (err) {
    console.error('DELETE /categories failed:', err.message);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ─── POST /api/categories/:id/assign ─────────────────────────────
// Assigns category to an access package. Since an AP can only have ONE category,
// this replaces any existing assignment for that AP.
router.post('/categories/:id/assign', async (req, res) => {
  try {
    if (!useSql) return res.status(400).json({ error: 'SQL mode required' });
    const { businessRoleId, resourceId: bodyResourceId } = req.body;
    const resId = bodyResourceId || businessRoleId;
    if (!resId) return res.status(400).json({ error: 'resourceId required' });

    const p = await db.getPool();
    await ensureCategoryTables(p);
    const categoryId = parseInt(req.params.id, 10);
    if (isNaN(categoryId)) return res.status(400).json({ error: 'Invalid category ID' });

    // MERGE: insert or replace the category for this AP (only one allowed)
    await p.request()
      .input('categoryId', categoryId)
      .input('resourceId', String(resId).toLowerCase())
      .query(`
        MERGE dbo.GovernanceCategoryAssignments AS target
        USING (SELECT @resourceId AS resourceId) AS source
        ON target.resourceId = source.resourceId
        WHEN MATCHED THEN UPDATE SET categoryId = @categoryId
        WHEN NOT MATCHED THEN INSERT (resourceId, categoryId) VALUES (@resourceId, @categoryId);
      `);
    res.json({ ok: true });
  } catch (err) {
    console.error('POST /categories/:id/assign failed:', err.message);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ─── POST /api/categories/unassign ───────────────────────────────
// Removes the category assignment from an access package.
router.post('/categories/unassign', async (req, res) => {
  try {
    if (!useSql) return res.status(400).json({ error: 'SQL mode required' });
    const { businessRoleId, resourceId: bodyResourceId } = req.body;
    const resId = bodyResourceId || businessRoleId;
    if (!resId) return res.status(400).json({ error: 'resourceId required' });

    const p = await db.getPool();
    await ensureCategoryTables(p);

    await p.request()
      .input('resourceId', String(resId).toLowerCase())
      .query('DELETE FROM dbo.GovernanceCategoryAssignments WHERE resourceId = @resourceId');
    res.json({ ok: true });
  } catch (err) {
    console.error('POST /categories/unassign failed:', err.message);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ─── GET /api/access-packages ────────────────────────────────────
// Paginated list of access packages with category info
router.get('/access-packages', async (req, res) => {
  try {
    if (!useSql) return res.json({ data: [], total: 0 });

    const search = (req.query.search || '').trim().slice(0, 200);
    const limit = Math.min(Math.max(parseInt(req.query.limit) || 100, 1), 500);
    const offset = Math.max(parseInt(req.query.offset) || 0, 0);

    // Parse category filter
    let categoryFilter = null;
    if (req.query.categoryId) {
      categoryFilter = parseInt(req.query.categoryId);
    }
    let showUncategorized = req.query.uncategorized === 'true';

    // Server-side sorting
    const SORT_COL_MAP = {
      'displayName':      'ap.displayName',
      'assignmentType':   'ISNULL(pol.autoAddCount, 0)',  // approximate: auto-add first
      'complianceStatus': `CASE
                             WHEN rev.complianceStatus = 'Missed' THEN 1
                             WHEN rev.complianceStatus = 'Reviewed Late' THEN 2
                             WHEN rev.complianceStatus = 'In Progress' THEN 3
                             WHEN rev.complianceStatus IS NULL AND ISNULL(pol.hasReviewConfigured, 0) = 1 THEN 4
                             WHEN rev.complianceStatus = 'Compliant' THEN 5
                             ELSE 6 END`,
      'lastReviewDate':   'rev.lastReviewDate',
      'lastReviewedBy':   'rev.lastReviewedBy',
      'category':         'cat.name',
    };
    let sortExpr = SORT_COL_MAP[req.query.sortCol] || 'ap.displayName';
    const sortDir = req.query.sortDir === 'desc' ? 'DESC' : 'ASC';

    const p = await db.getPool();
    await ensureCategoryTables(p);

    const request = p.request();
    request.input('limit', limit);
    request.input('offset', offset);

    let where = '1=1';
    if (search) {
      where += ` AND (ap.displayName LIKE @search OR c.displayName LIKE @search)`;
      request.input('search', `%${search}%`);
    }
    if (categoryFilter) {
      where += ` AND ca.categoryId = @categoryId`;
      request.input('categoryId', categoryFilter);
    } else if (showUncategorized) {
      where += ` AND ca.resourceId IS NULL`;
    }

    // Check if the review decisions table exists (it may not if reviews haven't been synced)
    let hasReviewTable = false;
    try {
      const check = await p.request().query(`
        SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'CertificationDecisions'
      `);
      hasReviewTable = check.recordset.length > 0;
    } catch { /* ignore */ }

    // Check if hasAccessReview column exists (added after re-syncing policies)
    let hasReviewCol = false;
    try {
      const check = await p.request().query(`
        SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_NAME = 'AssignmentPolicies' AND COLUMN_NAME = 'hasAccessReview'
      `);
      hasReviewCol = check.recordset.length > 0;
    } catch { /* ignore */ }

    // Check if reviewSettings column exists (for extracting reviewer names)
    let hasReviewSettingsCol = false;
    try {
      const check = await p.request().query(`
        SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_NAME = 'AssignmentPolicies' AND COLUMN_NAME = 'reviewSettings'
      `);
      hasReviewSettingsCol = check.recordset.length > 0;
    } catch { /* ignore */ }

    // If no review table, fall back to displayName for review-based sort columns
    const isReviewSort = ['complianceStatus', 'lastReviewDate', 'lastReviewedBy'].includes(req.query.sortCol);

    // Build review CTE + JOIN (uses same compliance logic as governance.js)
    let reviewCte = '';
    let reviewJoin = '';
    let reviewCols = ', NULL AS lastReviewDate, NULL AS lastReviewedBy, NULL AS complianceStatus, NULL AS reviewDeadline, 0 AS daysOverdue, 0 AS missedReviewsCount';
    if (hasReviewTable) {
      reviewCte = `,
        _LatestInstance AS (
          SELECT resourceId,
                 MAX(reviewInstanceId) AS reviewInstanceId,
                 MAX(reviewInstanceEndDateTime) AS reviewInstanceEndDateTime
          FROM CertificationDecisions
          WHERE reviewInstanceEndDateTime = (
            SELECT MAX(r2.reviewInstanceEndDateTime)
            FROM CertificationDecisions r2
            WHERE r2.resourceId = CertificationDecisions.resourceId
          )
          GROUP BY resourceId
        ),
        _LastReviewPerAP AS (
          SELECT
            li.resourceId,
            li.reviewInstanceEndDateTime AS deadline,
            MAX(CASE WHEN d.decision <> 'NotReviewed' THEN d.reviewedDateTime END) AS lastReviewDate,
            MAX(CASE WHEN d.decision <> 'NotReviewed' THEN d.reviewedByDisplayName END) AS lastReviewedBy,
            CASE
              WHEN SUM(CASE WHEN d.decision = 'NotReviewed' THEN 1 ELSE 0 END) = 0
               AND SUM(CASE WHEN d.decision <> 'NotReviewed' AND CAST(d.reviewedDateTime AS DATE) > CAST(li.reviewInstanceEndDateTime AS DATE) THEN 1 ELSE 0 END) = 0
              THEN 'Compliant'
              WHEN SUM(CASE WHEN d.decision = 'NotReviewed' THEN 1 ELSE 0 END) > 0
               AND CAST(li.reviewInstanceEndDateTime AS DATE) >= CAST(GETUTCDATE() AS DATE)
              THEN 'In Progress'
              WHEN SUM(CASE WHEN d.decision = 'NotReviewed' THEN 1 ELSE 0 END) > 0
               AND CAST(li.reviewInstanceEndDateTime AS DATE) < CAST(GETUTCDATE() AS DATE)
              THEN 'Missed'
              ELSE 'Reviewed Late'
            END AS complianceStatus,
            CASE
              WHEN CAST(li.reviewInstanceEndDateTime AS DATE) < CAST(GETUTCDATE() AS DATE)
              THEN DATEDIFF(DAY, CAST(li.reviewInstanceEndDateTime AS DATE), CAST(GETUTCDATE() AS DATE))
              ELSE 0
            END AS daysOverdue
          FROM _LatestInstance li
            INNER JOIN CertificationDecisions d
              ON d.resourceId = li.resourceId
              AND d.reviewInstanceId = li.reviewInstanceId
          GROUP BY li.resourceId, li.reviewInstanceEndDateTime
        ),
        _MissedReviewCount AS (
          SELECT resourceId, COUNT(*) AS missedCount
          FROM (
            SELECT resourceId, reviewInstanceId
            FROM dbo.CertificationDecisions
            WHERE reviewInstanceEndDateTime < GETUTCDATE()
            GROUP BY resourceId, reviewInstanceId
            HAVING SUM(CASE WHEN decision <> 'NotReviewed' THEN 1 ELSE 0 END) = 0
          ) x
          GROUP BY resourceId
        )`;
      reviewJoin = `LEFT JOIN _LastReviewPerAP rev ON ap.id = rev.resourceId
        LEFT JOIN _MissedReviewCount mrc ON ap.id = mrc.resourceId`;
      reviewCols = ', rev.lastReviewDate, rev.lastReviewedBy, rev.complianceStatus, rev.deadline AS reviewDeadline, ISNULL(rev.daysOverdue, 0) AS daysOverdue, ISNULL(mrc.missedCount, 0) AS missedReviewsCount';
    } else if (isReviewSort) {
      // No review data — fall back to default sort
      sortExpr = 'ap.displayName';
    }

    const result = await request.query(`
      WITH _assignmentCounts AS (
        SELECT resourceId, COUNT(*) AS cnt
        FROM dbo.ResourceAssignments
        WHERE state = 'delivered' AND assignmentType = 'Governed'
        GROUP BY resourceId
      ),
      _policyCounts AS (
        SELECT resourceId,
               COUNT(*) AS policyCount,
               SUM(CASE WHEN hasAutoAddRule = 1 THEN 1 ELSE 0 END) AS autoAddCount,
               SUM(CASE WHEN ISNULL(hasAutoAddRule, 0) = 0 AND hasAutoRemoveRule = 1 THEN 1 ELSE 0 END) AS autoRemoveOnlyCount${
                 hasReviewCol
                   ? `,\n               MAX(CAST(ISNULL(hasAccessReview, 0) AS INT)) AS hasReviewConfigured`
                   : `,\n               0 AS hasReviewConfigured`
               }
        FROM dbo.AssignmentPolicies
        GROUP BY resourceId
      )${hasReviewSettingsCol ? `,
      _reviewerInfo AS (
        SELECT p.resourceId,
               STRING_AGG(
                 CASE rv.[odata_type]
                   WHEN '#microsoft.graph.singleUser'       THEN ISNULL(rv.[description], rv.[userId])
                   WHEN '#microsoft.graph.requestorManager' THEN 'Requestor''s manager'
                   WHEN '#microsoft.graph.targetManager'    THEN 'User''s manager'
                   WHEN '#microsoft.graph.groupMembers'     THEN 'Group members'
                   WHEN '#microsoft.graph.internalSponsors' THEN 'Internal sponsors'
                   WHEN '#microsoft.graph.externalSponsors' THEN 'External sponsors'
                   ELSE rv.[odata_type]
                 END, ', '
               ) AS reviewers
        FROM dbo.AssignmentPolicies p
        CROSS APPLY OPENJSON(JSON_QUERY(p.reviewSettings, '$.primaryReviewers'))
          WITH (
            [odata_type]  NVARCHAR(100) '$."@odata.type"',
            [userId]      NVARCHAR(255) '$.userId',
            [description] NVARCHAR(255) '$.description'
          ) rv
        WHERE p.reviewSettings IS NOT NULL
        GROUP BY p.resourceId
      )` : ''}
      ${reviewCte}
      SELECT ap.id, ap.displayName, ap.description,
             c.displayName AS catalogName, c.id AS catalogId,
             ISNULL(ac.cnt, 0) AS totalAssignments,
             cat.id AS categoryId, cat.name AS categoryName, cat.color AS categoryColor,
             ISNULL(pol.policyCount, 0) AS policyCount,
             ISNULL(pol.autoAddCount, 0) AS autoAddCount,
             ISNULL(pol.autoRemoveOnlyCount, 0) AS autoRemoveOnlyCount,
             ISNULL(pol.hasReviewConfigured, 0) AS hasReviewConfigured
             ${reviewCols}
             ${hasReviewSettingsCol ? ', ri.reviewers AS reviewerInfo' : ', NULL AS reviewerInfo'}
      FROM dbo.Resources ap
      INNER JOIN dbo.GovernanceCatalogs c ON ap.catalogId = c.id
      LEFT JOIN _assignmentCounts ac ON ap.id = ac.resourceId
      LEFT JOIN dbo.GovernanceCategoryAssignments ca ON LOWER(ap.id) = ca.resourceId
      LEFT JOIN dbo.GovernanceCategories cat ON ca.categoryId = cat.id
      LEFT JOIN _policyCounts pol ON ap.id = pol.resourceId
      ${reviewJoin}
      ${hasReviewSettingsCol ? 'LEFT JOIN _reviewerInfo ri ON ap.id = ri.resourceId' : ''}
      WHERE ap.resourceType = 'BusinessRole' AND ${where}
      ORDER BY ${sortExpr} ${sortDir}
      OFFSET @offset ROWS FETCH NEXT @limit ROWS ONLY;

      SELECT COUNT(*) AS total
      FROM dbo.Resources ap
      INNER JOIN dbo.GovernanceCatalogs c ON ap.catalogId = c.id
      LEFT JOIN dbo.GovernanceCategoryAssignments ca ON LOWER(ap.id) = ca.resourceId
      LEFT JOIN dbo.GovernanceCategories cat ON ca.categoryId = cat.id
      WHERE ap.resourceType = 'BusinessRole' AND ${where};
    `);

    const data = result.recordsets[0].map(r => {
      // Derive assignment type from policy counts
      let assignmentType = null;
      if (r.policyCount > 0) {
        const requestBasedCount = r.policyCount - r.autoAddCount - r.autoRemoveOnlyCount;
        if (r.autoAddCount > 0 && (requestBasedCount > 0 || r.autoRemoveOnlyCount > 0)) {
          assignmentType = 'Both';
        } else if (r.autoAddCount > 0) {
          assignmentType = 'Auto-assigned';
        } else if (r.autoRemoveOnlyCount > 0) {
          assignmentType = 'Request-based with auto-removal';
        } else {
          assignmentType = 'Request-based';
        }
      }
      return {
        id: r.id,
        displayName: r.displayName,
        description: r.description,
        catalogName: r.catalogName,
        catalogId: r.catalogId,
        totalAssignments: r.totalAssignments,
        category: r.categoryId ? { id: r.categoryId, name: r.categoryName, color: r.categoryColor } : null,
        assignmentType,
        lastReviewDate: r.lastReviewDate || null,
        lastReviewedBy: r.lastReviewedBy || null,
        // Suppress Overdue/In Progress when there are no active assignments — the reviewer
        // would see nothing pending, so showing overdue is misleading.
        complianceStatus: (r.totalAssignments === 0 && (r.complianceStatus === 'Overdue' || r.complianceStatus === 'In Progress'))
          ? null
          : r.complianceStatus || null,
        reviewDeadline: r.reviewDeadline || null,
        daysOverdue: r.daysOverdue || 0,
        hasReviewConfigured: !!r.hasReviewConfigured,
        reviewerInfo: r.reviewerInfo || null,
        missedReviewsCount: r.missedReviewsCount || 0,
      };
    });

    res.json({ data, total: result.recordsets[1][0].total });
  } catch (err) {
    console.error('GET /access-packages failed:', err.message);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ─── GET /api/category-assignments ───────────────────────────────
// Returns all category assignments as a flat list (for matrix column ordering)
router.get('/category-assignments', async (req, res) => {
  try {
    if (!useSql) return res.json([]);
    const p = await db.getPool();
    await ensureCategoryTables(p);
    const result = await p.request().query(`
      SELECT ca.resourceId, ca.resourceId AS businessRoleId, c.id AS categoryId, c.name AS categoryName, c.color AS categoryColor
      FROM dbo.GovernanceCategoryAssignments ca
      INNER JOIN dbo.GovernanceCategories c ON ca.categoryId = c.id
      ORDER BY c.name, ca.resourceId
    `);
    res.json(result.recordset);
  } catch (err) {
    console.error('GET /category-assignments failed:', err.message);
    res.json([]);
  }
});

export default router;
