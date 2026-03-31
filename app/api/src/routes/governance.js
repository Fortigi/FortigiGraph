import { Router } from 'express';
import * as db from '../db/connection.js';
import { timedRequest } from '../perf/sqlTimer.js';

const router = Router();
const useSql = process.env.USE_SQL === 'true';

// Helper: try query, return empty on failure (view/table may not exist)
async function safeQuery(pool, label, res, sql) {
  try {
    const r = await timedRequest(pool, label, res).query(sql);
    return r.recordset;
  } catch {
    return [];
  }
}

// ── Shared CTE: per-AP last review instance status ──────────
// For each access package, finds the most recent review instance,
// then summarizes decisions within that instance only.
// Earlier instances are ignored — only the latest matters.
const LAST_REVIEW_CTE = `
WITH LatestInstance AS (
  -- Find the most recent review instance per access package
  SELECT
    resourceId,
    MAX(reviewInstanceId) AS reviewInstanceId,
    MAX(reviewInstanceEndDateTime) AS reviewInstanceEndDateTime,
    MAX(reviewInstanceStartDateTime) AS reviewInstanceStartDateTime,
    MAX(reviewInstanceStatus) AS reviewInstanceStatus
  FROM CertificationDecisions
  WHERE reviewInstanceEndDateTime = (
    SELECT MAX(r2.reviewInstanceEndDateTime)
    FROM CertificationDecisions r2
    WHERE r2.resourceId = CertificationDecisions.resourceId
  )
  GROUP BY resourceId
),
LastReviewPerAP AS (
  -- Summarize decisions within the latest instance only
  SELECT
    li.resourceId,
    li.reviewInstanceEndDateTime AS deadline,
    li.reviewInstanceStartDateTime AS reviewStart,
    li.reviewInstanceStatus,
    COUNT(*) AS totalDecisions,
    SUM(CASE WHEN d.decision <> 'NotReviewed' AND d.reviewedDateTime <= li.reviewInstanceEndDateTime THEN 1 ELSE 0 END) AS onTime,
    SUM(CASE WHEN d.decision <> 'NotReviewed' AND CAST(d.reviewedDateTime AS DATE) > CAST(li.reviewInstanceEndDateTime AS DATE) THEN 1 ELSE 0 END) AS reviewedLate,
    SUM(CASE WHEN d.decision = 'NotReviewed' THEN 1 ELSE 0 END) AS notReviewed,
    MAX(d.reviewedDateTime) AS lastReviewedDate,
    MAX(d.reviewedByDisplayName) AS lastReviewedBy,
    CASE
      -- All decisions completed on time (same day or before deadline)
      WHEN SUM(CASE WHEN d.decision = 'NotReviewed' THEN 1 ELSE 0 END) = 0
       AND SUM(CASE WHEN d.decision <> 'NotReviewed' AND CAST(d.reviewedDateTime AS DATE) > CAST(li.reviewInstanceEndDateTime AS DATE) THEN 1 ELSE 0 END) = 0
      THEN 'Compliant'
      -- Some decisions still pending but deadline day hasn't passed yet
      WHEN SUM(CASE WHEN d.decision = 'NotReviewed' THEN 1 ELSE 0 END) > 0
       AND CAST(li.reviewInstanceEndDateTime AS DATE) >= CAST(GETUTCDATE() AS DATE)
      THEN 'In Progress'
      -- Deadline day passed with unreviewed decisions
      WHEN SUM(CASE WHEN d.decision = 'NotReviewed' THEN 1 ELSE 0 END) > 0
       AND CAST(li.reviewInstanceEndDateTime AS DATE) < CAST(GETUTCDATE() AS DATE)
      THEN 'Missed'
      -- All reviewed but some were late
      ELSE 'Reviewed Late'
    END AS complianceStatus,
    CASE
      WHEN CAST(li.reviewInstanceEndDateTime AS DATE) < CAST(GETUTCDATE() AS DATE)
      THEN DATEDIFF(DAY, CAST(li.reviewInstanceEndDateTime AS DATE), CAST(GETUTCDATE() AS DATE))
      ELSE 0
    END AS daysOverdue
  FROM LatestInstance li
    INNER JOIN CertificationDecisions d
      ON d.resourceId = li.resourceId
      AND d.reviewInstanceId = li.reviewInstanceId
  GROUP BY li.resourceId, li.reviewInstanceEndDateTime, li.reviewInstanceStartDateTime, li.reviewInstanceStatus
)`;

// ────────────────────────────────────────────────────────────────
// GET /api/governance/summary — AP-centric review compliance KPIs
// ────────────────────────────────────────────────────────────────
router.get('/governance/summary', async (req, res) => {
  if (!useSql) return res.json({});
  try {
    const pool = await db.getPool();

    const rows = await safeQuery(pool, 'gov-summary', res,
      `${LAST_REVIEW_CTE}
      SELECT
        COUNT(*) AS totalAPs,
        SUM(CASE WHEN complianceStatus = 'Compliant' THEN 1 ELSE 0 END) AS compliant,
        SUM(CASE WHEN complianceStatus = 'Missed' THEN 1 ELSE 0 END) AS overdue,
        SUM(CASE WHEN complianceStatus = 'Reviewed Late' THEN 1 ELSE 0 END) AS reviewedLate,
        SUM(CASE WHEN complianceStatus = 'In Progress' THEN 1 ELSE 0 END) AS inProgress
      FROM LastReviewPerAP`);

    const s = rows[0] || {};

    res.json({
      totalAPs: s.totalAPs || 0,
      compliant: s.compliant || 0,
      overdue: s.overdue || 0,
      reviewedLate: s.reviewedLate || 0,
      inProgress: s.inProgress || 0,
    });
  } catch (err) {
    console.error('Error fetching governance summary:', err.message);
    res.status(500).json({ error: 'Failed to fetch governance summary' });
  }
});

// ────────────────────────────────────────────────────────────────
// GET /api/governance/review-compliance — Per-AP last review status
// ?filter=compliant|overdue|reviewed-late|in-progress (optional)
// ?category=categoryId (optional)
// ────────────────────────────────────────────────────────────────
router.get('/governance/review-compliance', async (req, res) => {
  if (!useSql) return res.json([]);
  try {
    const pool = await db.getPool();
    const filter = req.query.filter;
    const categoryId = req.query.category;

    let filterClause = '';
    if (filter === 'overdue') {
      filterClause = "AND lr.complianceStatus = 'Missed'";
    } else if (filter === 'reviewed-late') {
      filterClause = "AND lr.complianceStatus = 'Reviewed Late'";
    } else if (filter === 'compliant') {
      filterClause = "AND lr.complianceStatus = 'Compliant'";
    } else if (filter === 'in-progress') {
      filterClause = "AND lr.complianceStatus = 'In Progress'";
    }

    let categoryClause = '';
    const request = timedRequest(pool, 'gov-review-compliance-detail', res);
    if (categoryId) {
      if (categoryId === 'uncategorized') {
        categoryClause = 'AND ca.categoryId IS NULL';
      } else {
        categoryClause = 'AND ca.categoryId = @categoryId';
        request.input('categoryId', categoryId);
      }
    }

    const result = await request.query(
      `${LAST_REVIEW_CTE}
      SELECT
        ap.id AS resourceId,
        ap.displayName AS accessPackageName,
        c.displayName AS catalogName,
        cat.name AS categoryName,
        cat.color AS categoryColor,
        lr.complianceStatus,
        lr.deadline,
        lr.daysOverdue,
        lr.totalDecisions,
        lr.onTime,
        lr.reviewedLate,
        lr.notReviewed,
        lr.lastReviewedDate,
        lr.lastReviewedBy,
        lr.reviewInstanceStatus
      FROM LastReviewPerAP lr
        INNER JOIN Resources ap ON lr.resourceId = ap.id AND ap.resourceType = 'BusinessRole'
        LEFT JOIN GovernanceCatalogs c ON ap.catalogId = c.id
        LEFT JOIN dbo.GovernanceCategoryAssignments ca ON LOWER(ap.id) = ca.resourceId
        LEFT JOIN dbo.GovernanceCategories cat ON ca.categoryId = cat.id
      WHERE 1=1 ${filterClause} ${categoryClause}
      ORDER BY
        CASE lr.complianceStatus
          WHEN 'Missed' THEN 1
          WHEN 'Reviewed Late' THEN 2
          WHEN 'In Progress' THEN 3
          WHEN 'Compliant' THEN 4
          ELSE 5
        END,
        lr.daysOverdue DESC`);
    res.json(result.recordset);
  } catch (err) {
    res.json([]);
  }
});

// ────────────────────────────────────────────────────────────────
// GET /api/governance/categories — Available categories for filtering
// ────────────────────────────────────────────────────────────────
router.get('/governance/categories', async (req, res) => {
  if (!useSql) return res.json([]);
  try {
    const pool = await db.getPool();
    const rows = await safeQuery(pool, 'gov-categories', res,
      `SELECT id, name, color FROM dbo.GovernanceCategories ORDER BY name`);
    res.json(rows);
  } catch {
    res.json([]);
  }
});

export default router;
