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

async function safeScalar(pool, label, res, sql, defaultVal = 0) {
  try {
    const r = await timedRequest(pool, label, res).query(sql);
    return r.recordset[0] ? Object.values(r.recordset[0])[0] : defaultVal;
  } catch {
    return defaultVal;
  }
}

// ────────────────────────────────────────────────────────────────
// GET /api/governance/summary — Top-level KPI numbers
// ────────────────────────────────────────────────────────────────
router.get('/governance/summary', async (req, res) => {
  if (!useSql) return res.json({});
  try {
    const pool = await db.getPool();

    // Determine best permission table (materialized or view)
    let permTable = 'vw_UserPermissionAssignments';
    try {
      await pool.request().query('SELECT TOP 0 * FROM mat_UserPermissionAssignments');
      permTable = 'mat_UserPermissionAssignments';
    } catch { /* use view */ }

    // Run all queries in parallel
    const [
      totalUsers,
      totalGroups,
      totalAccessPackages,
      managedAssignments,
      unmanagedAssignments,
      assignmentMethods,
      requestMetrics,
      pendingRequests,
      reviewCompliance,
    ] = await Promise.all([
      // Total users
      safeScalar(pool, 'gov-total-users', res,
        `SELECT COUNT(*) FROM GraphUsers`),

      // Total groups
      safeScalar(pool, 'gov-total-groups', res,
        `SELECT COUNT(*) FROM GraphGroups`),

      // Total access packages
      safeScalar(pool, 'gov-total-aps', res,
        `SELECT COUNT(*) FROM GraphAccessPackages`),

      // Managed (SOLL) assignment count — distinct user-group pairs managed by AP
      safeScalar(pool, 'gov-managed', res,
        `SELECT COUNT(*) FROM ${permTable} WHERE managedByAccessPackage = 1 AND membershipType IN ('Direct', 'Eligible')`),

      // Unmanaged (IST) assignment count — distinct user-group pairs NOT managed by AP
      safeScalar(pool, 'gov-unmanaged', res,
        `SELECT COUNT(*) FROM ${permTable} WHERE managedByAccessPackage = 0 AND membershipType IN ('Direct', 'Eligible')`),

      // Assignment method breakdown (auto vs requested vs admin vs unknown)
      safeQuery(pool, 'gov-methods', res,
        `SELECT
          assignmentMethod,
          COUNT(*) AS cnt
        FROM vw_AccessPackageAssignmentDetails
        GROUP BY assignmentMethod`),

      // Aggregate request metrics (across all APs)
      safeQuery(pool, 'gov-request-metrics', res,
        `SELECT
          SUM(totalRequests) AS totalRequests,
          SUM(approvedCount) AS approvedCount,
          SUM(deniedCount) AS deniedCount,
          CASE WHEN SUM(totalRequests) > 0
            THEN CAST(ROUND((CAST(SUM(approvedCount) AS FLOAT) / SUM(totalRequests)) * 100, 1) AS DECIMAL(5,1))
            ELSE 0
          END AS approvalRatePercent,
          CAST(ROUND(AVG(avgResponseHours), 1) AS DECIMAL(10,1)) AS avgResponseHours,
          CAST(ROUND(AVG(avgResponseDays), 1) AS DECIMAL(10,1)) AS avgResponseDays
        FROM vw_RequestResponseMetrics`),

      // Pending requests
      safeQuery(pool, 'gov-pending', res,
        `SELECT COUNT(*) AS total,
          SUM(CASE WHEN isOverdue = 1 THEN 1 ELSE 0 END) AS overdue
        FROM vw_PendingRequestTimeline`),

      // Review compliance: on-time vs expired
      // A review is "on time" if the decision was made before the instance end date
      safeQuery(pool, 'gov-review-compliance', res,
        `SELECT
          COUNT(*) AS totalDecisions,
          SUM(CASE WHEN reviewedDateTime <= reviewInstanceEndDateTime THEN 1 ELSE 0 END) AS onTime,
          SUM(CASE WHEN reviewedDateTime > reviewInstanceEndDateTime THEN 1 ELSE 0 END) AS overdue,
          SUM(CASE WHEN decision = 'NotReviewed' THEN 1 ELSE 0 END) AS notReviewed
        FROM GraphAccessPackageAccessReviewDecisions
        WHERE decision IS NOT NULL`),
    ]);

    const reqMetrics = requestMetrics[0] || {};
    const pending = pendingRequests[0] || {};
    const compliance = reviewCompliance[0] || {};

    res.json({
      totalUsers,
      totalGroups,
      totalAccessPackages,
      managedAssignments,
      unmanagedAssignments,
      managedPercent: (managedAssignments + unmanagedAssignments) > 0
        ? Math.round((managedAssignments / (managedAssignments + unmanagedAssignments)) * 1000) / 10
        : 0,
      assignmentMethods: assignmentMethods.reduce((acc, r) => { acc[r.assignmentMethod] = r.cnt; return acc; }, {}),
      requests: {
        total: reqMetrics.totalRequests || 0,
        approved: reqMetrics.approvedCount || 0,
        denied: reqMetrics.deniedCount || 0,
        approvalRatePercent: reqMetrics.approvalRatePercent || 0,
        avgResponseHours: reqMetrics.avgResponseHours || 0,
        avgResponseDays: reqMetrics.avgResponseDays || 0,
        pendingTotal: pending.total || 0,
        pendingOverdue: pending.overdue || 0,
      },
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
// GET /api/governance/response-times — Response time distribution
// ────────────────────────────────────────────────────────────────
router.get('/governance/response-times', async (req, res) => {
  if (!useSql) return res.json({ approved: [], denied: [] });
  try {
    const pool = await db.getPool();

    const [approvedBuckets, deniedBuckets] = await Promise.all([
      safeQuery(pool, 'gov-approved-buckets', res,
        `SELECT responseTimeBucket, COUNT(*) AS cnt
         FROM vw_ApprovedRequestTimeline
         GROUP BY responseTimeBucket`),
      safeQuery(pool, 'gov-denied-buckets', res,
        `SELECT responseTimeBucket, COUNT(*) AS cnt
         FROM vw_DeniedRequestTimeline
         GROUP BY responseTimeBucket`),
    ]);

    // Normalize to ordered buckets
    const BUCKET_ORDER = [
      'Less than 1 hour', '1-4 hours', '4-24 hours',
      '1-3 days', '3-7 days', '1-2 weeks', 'Over 2 weeks'
    ];

    function toBucketArray(rows) {
      const map = {};
      for (const r of rows) map[r.responseTimeBucket] = r.cnt;
      return BUCKET_ORDER.map(b => ({ bucket: b, count: map[b] || 0 }));
    }

    res.json({
      approved: toBucketArray(approvedBuckets),
      denied: toBucketArray(deniedBuckets),
    });
  } catch (err) {
    res.json({ approved: [], denied: [] });
  }
});

// ────────────────────────────────────────────────────────────────
// GET /api/governance/per-package — Per-AP request metrics
// ────────────────────────────────────────────────────────────────
router.get('/governance/per-package', async (req, res) => {
  if (!useSql) return res.json([]);
  try {
    const pool = await db.getPool();
    const rows = await safeQuery(pool, 'gov-per-package', res,
      `SELECT
        accessPackageId, accessPackageName, catalogName,
        totalRequests, approvedCount, deniedCount,
        approvalRatePercent, avgResponseHours, avgResponseDays,
        avgResponseCategory
      FROM vw_RequestResponseMetrics
      ORDER BY totalRequests DESC`);
    res.json(rows);
  } catch (err) {
    res.json([]);
  }
});

// ────────────────────────────────────────────────────────────────
// GET /api/governance/review-status — Per-AP review status
// ────────────────────────────────────────────────────────────────
router.get('/governance/review-status', async (req, res) => {
  if (!useSql) return res.json([]);
  try {
    const pool = await db.getPool();
    const rows = await safeQuery(pool, 'gov-review-status', res,
      `SELECT
        accessPackageId, accessPackageName, catalogName,
        lastReviewedByName, lastReviewDateTime,
        lastReviewDecision, daysSinceLastReview, reviewInstanceStatus
      FROM vw_AccessPackageLastReview
      ORDER BY daysSinceLastReview DESC`);
    res.json(rows);
  } catch (err) {
    res.json([]);
  }
});

// ────────────────────────────────────────────────────────────────
// GET /api/governance/pending-requests — Currently pending requests
// ────────────────────────────────────────────────────────────────
router.get('/governance/pending-requests', async (req, res) => {
  if (!useSql) return res.json([]);
  try {
    const pool = await db.getPool();
    const rows = await safeQuery(pool, 'gov-pending-list', res,
      `SELECT
        requestId, userDisplayName, userPrincipalName,
        accessPackageName, catalogName,
        requestState, daysPending, pendingTimeBucket, isOverdue
      FROM vw_PendingRequestTimeline
      ORDER BY daysPending DESC`);
    res.json(rows);
  } catch (err) {
    res.json([]);
  }
});

// ────────────────────────────────────────────────────────────────
// GET /api/governance/review-compliance — Drill-down: per-AP review compliance
// ?filter=overdue|not-reviewed|on-time (optional)
// ────────────────────────────────────────────────────────────────
router.get('/governance/review-compliance', async (req, res) => {
  if (!useSql) return res.json([]);
  try {
    const pool = await db.getPool();
    const filter = req.query.filter; // 'overdue', 'not-reviewed', 'on-time'

    // Build a WHERE clause based on filter
    let filterClause = '';
    if (filter === 'overdue') {
      filterClause = 'AND r.reviewedDateTime > r.reviewInstanceEndDateTime';
    } else if (filter === 'not-reviewed') {
      filterClause = "AND r.decision = 'NotReviewed'";
    } else if (filter === 'on-time') {
      filterClause = 'AND r.reviewedDateTime <= r.reviewInstanceEndDateTime';
    }

    const rows = await safeQuery(pool, 'gov-review-compliance-detail', res,
      `SELECT
        ap.id AS accessPackageId,
        ap.displayName AS accessPackageName,
        c.displayName AS catalogName,
        COUNT(*) AS totalDecisions,
        SUM(CASE WHEN r.reviewedDateTime <= r.reviewInstanceEndDateTime THEN 1 ELSE 0 END) AS onTime,
        SUM(CASE WHEN r.reviewedDateTime > r.reviewInstanceEndDateTime THEN 1 ELSE 0 END) AS overdue,
        SUM(CASE WHEN r.decision = 'NotReviewed' THEN 1 ELSE 0 END) AS notReviewed,
        MAX(r.reviewedDateTime) AS lastReviewDate,
        MAX(r.reviewInstanceEndDateTime) AS lastInstanceEndDate
      FROM GraphAccessPackageAccessReviewDecisions r
        INNER JOIN GraphAccessPackages ap ON r.accessPackageId = ap.id
        INNER JOIN GraphCatalogs c ON ap.catalogId = c.id
      WHERE r.decision IS NOT NULL ${filterClause}
      GROUP BY ap.id, ap.displayName, c.displayName
      ORDER BY
        SUM(CASE WHEN r.decision = 'NotReviewed' THEN 1 ELSE 0 END) DESC,
        SUM(CASE WHEN r.reviewedDateTime > r.reviewInstanceEndDateTime THEN 1 ELSE 0 END) DESC`);
    res.json(rows);
  } catch (err) {
    res.json([]);
  }
});

export default router;
