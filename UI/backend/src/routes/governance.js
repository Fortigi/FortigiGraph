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

// ────────────────────────────────────────────────────────────────
// GET /api/governance/summary — Access review compliance KPIs
// ────────────────────────────────────────────────────────────────
router.get('/governance/summary', async (req, res) => {
  if (!useSql) return res.json({});
  try {
    const pool = await db.getPool();

    // Review compliance: on-time vs expired
    // A review is "on time" if the decision was made before the instance end date
    const reviewCompliance = await safeQuery(pool, 'gov-review-compliance', res,
      `SELECT
        COUNT(*) AS totalDecisions,
        SUM(CASE WHEN reviewedDateTime <= reviewInstanceEndDateTime THEN 1 ELSE 0 END) AS onTime,
        SUM(CASE WHEN reviewedDateTime > reviewInstanceEndDateTime THEN 1 ELSE 0 END) AS overdue,
        SUM(CASE WHEN decision = 'NotReviewed' THEN 1 ELSE 0 END) AS notReviewed
      FROM GraphAccessPackageAccessReviewDecisions
      WHERE decision IS NOT NULL`);

    const compliance = reviewCompliance[0] || {};

    res.json({
      reviews: {
        totalDecisions: compliance.totalDecisions || 0,
        onTime: compliance.onTime || 0,
        overdue: compliance.overdue || 0,
        notReviewed: compliance.notReviewed || 0,
        onTimePercent: compliance.totalDecisions > 0
          ? Math.round(((compliance.onTime || 0) / compliance.totalDecisions) * 1000) / 10
          : 0,
      },
    });
  } catch (err) {
    console.error('Error fetching governance summary:', err.message);
    res.status(500).json({ error: 'Failed to fetch governance summary' });
  }
});

// ────────────────────────────────────────────────────────────────
// GET /api/governance/review-compliance — Drill-down: per-AP review compliance
// ?filter=overdue|not-reviewed|on-time (optional)
// ?category=categoryId (optional — filter to APs in a specific category)
// ────────────────────────────────────────────────────────────────
router.get('/governance/review-compliance', async (req, res) => {
  if (!useSql) return res.json([]);
  try {
    const pool = await db.getPool();
    const filter = req.query.filter; // 'overdue', 'not-reviewed', 'on-time'
    const categoryId = req.query.category; // optional category filter

    // Build a WHERE clause based on filter
    let filterClause = '';
    if (filter === 'overdue') {
      filterClause = 'AND r.reviewedDateTime > r.reviewInstanceEndDateTime';
    } else if (filter === 'not-reviewed') {
      filterClause = "AND r.decision = 'NotReviewed'";
    } else if (filter === 'on-time') {
      filterClause = 'AND r.reviewedDateTime <= r.reviewInstanceEndDateTime';
    }

    // Category filter
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
      `SELECT
        ap.id AS accessPackageId,
        ap.displayName AS accessPackageName,
        c.displayName AS catalogName,
        cat.name AS categoryName,
        cat.color AS categoryColor,
        COUNT(*) AS totalDecisions,
        SUM(CASE WHEN r.reviewedDateTime <= r.reviewInstanceEndDateTime THEN 1 ELSE 0 END) AS onTime,
        SUM(CASE WHEN r.reviewedDateTime > r.reviewInstanceEndDateTime THEN 1 ELSE 0 END) AS overdue,
        SUM(CASE WHEN r.decision = 'NotReviewed' THEN 1 ELSE 0 END) AS notReviewed,
        MAX(r.reviewedDateTime) AS lastReviewDate,
        MAX(r.reviewInstanceEndDateTime) AS lastInstanceEndDate
      FROM GraphAccessPackageAccessReviewDecisions r
        INNER JOIN GraphAccessPackages ap ON r.accessPackageId = ap.id
        LEFT JOIN GraphCatalogs c ON ap.catalogId = c.id
        LEFT JOIN dbo.GraphCategoryAssignments ca ON LOWER(ap.id) = ca.accessPackageId
        LEFT JOIN dbo.GraphCategories cat ON ca.categoryId = cat.id
      WHERE r.decision IS NOT NULL ${filterClause} ${categoryClause}
      GROUP BY ap.id, ap.displayName, c.displayName, cat.name, cat.color
      ORDER BY
        SUM(CASE WHEN r.decision = 'NotReviewed' THEN 1 ELSE 0 END) DESC,
        SUM(CASE WHEN r.reviewedDateTime > r.reviewInstanceEndDateTime THEN 1 ELSE 0 END) DESC`);
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
      `SELECT id, name, color FROM dbo.GraphCategories ORDER BY name`);
    res.json(rows);
  } catch {
    res.json([]);
  }
});

export default router;
