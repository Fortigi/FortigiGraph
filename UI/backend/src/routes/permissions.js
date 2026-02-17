import { Router } from 'express';
import { permissionAssignments } from '../mock/data.js';

const router = Router();
const useSql = process.env.USE_SQL === 'true';

let db = null;
if (useSql) {
  db = await import('../db/connection.js');
}

// ─── User column discovery (cached) ───────────────────────────────
// Columns from GraphUsers that are excluded from dynamic SELECT/filter
const SYSTEM_COLS = new Set(['id', 'ValidFrom', 'ValidTo', 'SysStartTime', 'SysEndTime']);
// Data types useful for filtering (skip datetime, uniqueidentifier, etc.)
const FILTERABLE_TYPES = new Set(['nvarchar', 'varchar', 'char', 'bit', 'int', 'smallint', 'tinyint']);
// Columns always handled with explicit aliases (not included in dynamic list)
const ALIASED_COLS = new Set(['displayName', 'userPrincipalName']);

let userColumnsCache = null;

async function getUserColumns(pool) {
  if (userColumnsCache) return userColumnsCache;
  const result = await pool.request().query(`
    SELECT COLUMN_NAME, DATA_TYPE
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_NAME = 'GraphUsers'
      AND COLUMN_NAME NOT IN ('id', 'ValidFrom', 'ValidTo', 'SysStartTime', 'SysEndTime')
    ORDER BY ORDINAL_POSITION
  `);
  userColumnsCache = result.recordset.map(r => ({
    name: r.COLUMN_NAME,
    type: r.DATA_TYPE,
  }));
  return userColumnsCache;
}

// ─── GET /api/user-columns ────────────────────────────────────────
// Returns column names + distinct values from GraphUsers for filter dropdowns.
// Values come from the FULL dataset (not limited by userLimit), so dropdowns
// show all possible options regardless of which page of users is loaded.
router.get('/user-columns', async (req, res) => {
  try {
    if (!useSql) {
      // Mock: derive from mock data
      const mockCols = {};
      for (const row of permissionAssignments) {
        for (const [key, val] of Object.entries(row)) {
          if (['groupId', 'memberId', 'memberDisplayName', 'memberUPN', 'memberType',
               'groupDisplayName', 'groupTypeCalculated', 'groupDescription',
               'membershipType', 'managedByAccessPackage'].includes(key)) continue;
          if (val == null || val === '') continue;
          if (!mockCols[key]) mockCols[key] = new Set();
          mockCols[key].add(String(val));
        }
      }
      return res.json(
        Object.entries(mockCols)
          .filter(([, vals]) => vals.size >= 1 && vals.size <= 500)
          .map(([column, vals]) => ({ column, values: [...vals].sort() }))
      );
    }

    const p = await db.getPool();
    const cols = await getUserColumns(p);
    const filterableCols = cols.filter(c => FILTERABLE_TYPES.has(c.type));

    if (filterableCols.length === 0) return res.json([]);

    // Single UNION ALL query to get all distinct values in one roundtrip
    const parts = filterableCols.map(c =>
      `SELECT '${c.name}' AS col, CAST(val AS NVARCHAR(400)) AS val ` +
      `FROM (SELECT DISTINCT TOP 500 [${c.name}] AS val FROM GraphUsers ` +
      `WHERE [${c.name}] IS NOT NULL AND CAST([${c.name}] AS NVARCHAR(400)) != '' ` +
      `AND ValidTo = '9999-12-31 23:59:59.9999999') t`
    );

    const unionSql = parts.join('\nUNION ALL\n') + '\nORDER BY col, val';
    const result = await p.request().query(unionSql);

    // Group by column
    const grouped = {};
    for (const r of result.recordset) {
      if (!grouped[r.col]) grouped[r.col] = [];
      grouped[r.col].push(r.val);
    }

    return res.json(
      Object.entries(grouped).map(([column, values]) => ({ column, values }))
    );
  } catch (err) {
    console.error('user-columns query failed:', err.message);
    return res.json([]);
  }
});

// ─── GET /api/permissions ─────────────────────────────────────────
// Query params:
//   userLimit (int)  - limit to top N users by assignment count
//   filters  (JSON)  - server-side filters: {"department":"HR","costCenter":"CC100"}
//                       Only columns that exist in GraphUsers are applied; unknown fields ignored.
router.get('/permissions', async (req, res) => {
  try {
    const userLimit = parseInt(req.query.userLimit) || 0;

    // Parse filters (JSON object of field:value pairs)
    let requestedFilters = {};
    if (req.query.filters) {
      try { requestedFilters = JSON.parse(req.query.filters); } catch { /* ignore bad JSON */ }
    }

    if (useSql) {
      const p = await db.getPool();

      // Prefer materialized tables (fast) with view fallback (slow but always current)
      const matCheck = await p.request().query(`
        SELECT
          OBJECT_ID('dbo.mat_UserPermissionAssignments', 'U') AS matPermExists,
          OBJECT_ID('dbo.mat_UserPermissionAssignmentViaAccessPackage', 'U') AS matApExists
      `);
      const permSource = matCheck.recordset[0].matPermExists
        ? 'mat_UserPermissionAssignments'
        : 'vw_UserPermissionAssignments';
      const apSource = matCheck.recordset[0].matApExists
        ? 'mat_UserPermissionAssignmentViaAccessPackage'
        : 'vw_UserPermissionAssignmentViaAccessPackage';

      // Discover user columns dynamically
      const allCols = await getUserColumns(p);
      const colNames = new Set(allCols.map(c => c.name));

      // Build dynamic user column SELECT (exclude aliased cols handled explicitly)
      const dynamicUserCols = allCols
        .filter(c => !ALIASED_COLS.has(c.name))
        .map(c => `u.[${c.name}]`)
        .join(',\n            ');

      // Validate and build filter WHERE clause (parameterized)
      const validFilters = [];
      for (const [field, value] of Object.entries(requestedFilters)) {
        if (colNames.has(field) && value != null && String(value) !== '') {
          validFilters.push({ field, value: String(value) });
        }
      }

      let filterWhere = '';
      const addParams = (request) => {
        for (let i = 0; i < validFilters.length; i++) {
          const f = validFilters[i];
          // Use CAST for consistent string comparison (handles bit/int columns)
          filterWhere += ` AND CAST(u.[${f.field}] AS NVARCHAR(400)) = @f${i}`;
          request.input(`f${i}`, f.value);
        }
      };

      // Main permissions query
      let result;
      if (userLimit > 0) {
        const request = p.request();
        request.input('userLimit', userLimit);
        filterWhere = ''; // reset before building
        addParams(request);

        result = await request.query(`
          WITH TopUsers AS (
            SELECT TOP (@userLimit) p.memberId
            FROM ${permSource} p
            INNER JOIN GraphUsers u ON p.memberId = u.id
            WHERE p.memberType != '#microsoft.graph.group'
              ${filterWhere}
            GROUP BY p.memberId
            ORDER BY COUNT(*) DESC
          )
          SELECT
            p.groupId,
            g.displayName AS groupDisplayName,
            g.groupTypeCalculated,
            g.description AS groupDescription,
            p.memberId,
            u.displayName AS memberDisplayName,
            u.userPrincipalName AS memberUPN,
            p.memberType,
            p.membershipType,
            ${dynamicUserCols},
            p.managedByAccessPackage
          FROM ${permSource} p
          INNER JOIN GraphUsers u ON p.memberId = u.id
          LEFT JOIN GraphGroups g ON p.groupId = g.id
          WHERE p.memberType != '#microsoft.graph.group'
            AND p.memberId IN (SELECT memberId FROM TopUsers);

          SELECT COUNT(DISTINCT p.memberId) AS totalUsers
          FROM ${permSource} p
          INNER JOIN GraphUsers u ON p.memberId = u.id
          WHERE p.memberType != '#microsoft.graph.group'
            ${filterWhere};
        `);
      } else {
        const request = p.request();
        filterWhere = '';
        addParams(request);

        result = await request.query(`
          SELECT
            p.groupId,
            g.displayName AS groupDisplayName,
            g.groupTypeCalculated,
            g.description AS groupDescription,
            p.memberId,
            u.displayName AS memberDisplayName,
            u.userPrincipalName AS memberUPN,
            p.memberType,
            p.membershipType,
            ${dynamicUserCols},
            p.managedByAccessPackage
          FROM ${permSource} p
          INNER JOIN GraphUsers u ON p.memberId = u.id
          LEFT JOIN GraphGroups g ON p.groupId = g.id
          WHERE p.memberType != '#microsoft.graph.group'
            ${filterWhere};
        `);
      }

      // AP mapping query — scope to same user set (with filters applied)
      let managedByPackages = [];
      try {
        let apSql;
        if (userLimit > 0) {
          const apRequest = p.request();
          apRequest.input('userLimit', userLimit);
          filterWhere = '';
          const apAddParams = (req2) => {
            for (let i = 0; i < validFilters.length; i++) {
              filterWhere += ` AND CAST(u.[${validFilters[i].field}] AS NVARCHAR(400)) = @f${i}`;
              req2.input(`f${i}`, validFilters[i].value);
            }
          };
          apAddParams(apRequest);

          apSql = `
            WITH TopUsers AS (
              SELECT TOP (@userLimit) p.memberId
              FROM ${permSource} p
              INNER JOIN GraphUsers u ON p.memberId = u.id
              WHERE p.memberType != '#microsoft.graph.group'
                ${filterWhere}
              GROUP BY p.memberId
              ORDER BY COUNT(*) DESC
            )
            SELECT
              ap.userId AS memberId,
              ap.groupId,
              STRING_AGG(CAST(ap.accessPackageId AS NVARCHAR(36)), ',') AS accessPackageIds
            FROM ${apSource} ap
            WHERE ap.userId IN (SELECT memberId FROM TopUsers)
            GROUP BY ap.userId, ap.groupId;
          `;
          const apResult = await apRequest.query(apSql);
          managedByPackages = (apResult.recordset || [])
            .filter(r => r.memberId)
            .map(r => ({
              memberId: r.memberId,
              groupId: r.groupId,
              accessPackageIds: r.accessPackageIds ? r.accessPackageIds.split(',') : [],
            }));
        } else {
          apSql = `
            SELECT
              ap.userId AS memberId,
              ap.groupId,
              STRING_AGG(CAST(ap.accessPackageId AS NVARCHAR(36)), ',') AS accessPackageIds
            FROM ${apSource} ap
            GROUP BY ap.userId, ap.groupId;
          `;
          const apResult = await p.request().query(apSql);
          managedByPackages = (apResult.recordset || [])
            .filter(r => r.memberId)
            .map(r => ({
              memberId: r.memberId,
              groupId: r.groupId,
              accessPackageIds: r.accessPackageIds ? r.accessPackageIds.split(',') : [],
            }));
        }
      } catch (apErr) {
        console.error('AP mapping query failed (non-fatal):', apErr.message);
      }

      if (userLimit > 0) {
        return res.json({
          data: result.recordsets[0],
          totalUsers: result.recordsets[1][0].totalUsers,
          managedByPackages,
        });
      }
      return res.json({
        data: result.recordsets[0],
        totalUsers: new Set(result.recordsets[0].map(r => r.memberId)).size,
        managedByPackages,
      });
    }

    // Mock data path (supports filters for local dev)
    let mockData = permissionAssignments;
    // Apply mock filters
    for (const [field, value] of Object.entries(requestedFilters)) {
      if (value != null && value !== '') {
        mockData = mockData.filter(r => String(r[field] ?? '') === String(value));
      }
    }
    const allUserIds = [...new Set(mockData.map(r => r.memberId))];
    if (userLimit > 0) {
      const userCounts = {};
      mockData.forEach(r => { userCounts[r.memberId] = (userCounts[r.memberId] || 0) + 1; });
      const topUserIds = new Set(
        Object.entries(userCounts)
          .sort((a, b) => b[1] - a[1])
          .slice(0, userLimit)
          .map(e => e[0])
      );
      mockData = mockData.filter(r => topUserIds.has(r.memberId));
    }
    res.json({ data: mockData, totalUsers: allUserIds.length, managedByPackages: [] });
  } catch (err) {
    console.error('permissions query failed:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// GET /api/access-package-groups - Access package to group mapping
router.get('/access-package-groups', async (req, res) => {
  try {
    if (useSql) {
      const result = await db.query(`
        SELECT
          rrs.accessPackageId,
          ap.displayName AS accessPackageName,
          c.displayName  AS catalogName,
          UPPER(rrs.scopeOriginId) AS groupId,
          g.displayName  AS groupName,
          rrs.roleDisplayName AS roleName,
          ISNULL(ac.cnt, 0) AS totalAssignments
        FROM dbo.GraphAccessPackageResourceRoleScopes rrs
        INNER JOIN dbo.GraphAccessPackages ap ON rrs.accessPackageId = ap.id
        INNER JOIN dbo.GraphCatalogs c ON ap.catalogId = c.id
        LEFT  JOIN dbo.GraphGroups g ON UPPER(rrs.scopeOriginId) = g.id
        LEFT  JOIN (
          SELECT accessPackageId, COUNT(*) AS cnt
          FROM dbo.GraphAccessPackageAssignments
          WHERE assignmentState = 'delivered'
          GROUP BY accessPackageId
        ) ac ON rrs.accessPackageId = ac.accessPackageId
        WHERE rrs.scopeOriginSystem = 'AadGroup'
      `);
      return res.json(result.recordset);
    }
    res.json([]);
  } catch (err) {
    // Table may not exist in this environment — return empty instead of 500
    console.error('access-package-groups query failed:', err.message);
    res.json([]);
  }
});

// GET /api/sync-log - Recent sync log entries from GraphSyncLog
router.get('/sync-log', async (req, res) => {
  try {
    const limit = Math.min(Math.max(parseInt(req.query.limit) || 20, 1), 100);

    if (useSql) {
      const p = await db.getPool();
      const request = p.request();
      request.input('limit', limit);

      // Check if GraphSyncLog table exists before querying
      const tableCheck = await request.query(`
        SELECT OBJECT_ID('dbo.GraphSyncLog', 'U') AS tableExists
      `);
      if (!tableCheck.recordset[0].tableExists) {
        return res.json([]);
      }

      const result = await p.request().input('limit', limit).query(`
        SELECT TOP (@limit)
          Id, SyncType, StartTime, EndTime, DurationSeconds,
          RecordCount, Status, ErrorMessage, TableName, CreatedAt
        FROM dbo.GraphSyncLog
        ORDER BY StartTime DESC
      `);
      return res.json(result.recordset);
    }

    // Mock data: generate realistic sync log entries
    const syncTypes = [
      { type: 'Users', table: 'GraphUsers', records: 1247 },
      { type: 'Groups', table: 'GraphGroups', records: 389 },
      { type: 'GroupMembers', table: 'GraphGroupMembers', records: 4521 },
      { type: 'GroupTransitiveMembers', table: 'GraphGroupTransitiveMembers', records: 8932 },
      { type: 'GroupEligibleMembers', table: 'GraphGroupEligibleMembers', records: 156 },
      { type: 'GroupOwners', table: 'GraphGroupOwners', records: 412 },
      { type: 'Catalogs', table: 'GraphCatalogs', records: 12 },
      { type: 'AccessPackages', table: 'GraphAccessPackages', records: 67 },
      { type: 'AccessPackageAssignments', table: 'GraphAccessPackageAssignments', records: 834 },
      { type: 'AccessPackageResourceRoleScopes', table: 'GraphAccessPackageResourceRoleScopes', records: 203 },
      { type: 'AccessPackageAssignmentPolicies', table: 'GraphAccessPackageAssignmentPolicies', records: 71 },
      { type: 'AccessPackageAssignmentRequests', table: 'GraphAccessPackageAssignmentRequests', records: 2103 },
      { type: 'AccessPackageAccessReviews', table: 'GraphAccessPackageAccessReviews', records: 45 },
    ];
    const mockLogs = [];
    let id = 1;
    // Generate 2 full sync runs
    for (let run = 0; run < 2; run++) {
      const baseTime = new Date(Date.now() - (run * 24 * 60 * 60 * 1000) - (2 * 60 * 60 * 1000));
      let offset = 0;
      for (const st of syncTypes) {
        const duration = Math.floor(Math.random() * 120) + 5;
        const start = new Date(baseTime.getTime() + offset * 1000);
        const end = new Date(start.getTime() + duration * 1000);
        const isFailed = run === 1 && st.type === 'AccessPackageAccessReviews';
        mockLogs.push({
          Id: id++,
          SyncType: st.type,
          StartTime: start.toISOString(),
          EndTime: end.toISOString(),
          DurationSeconds: duration,
          RecordCount: isFailed ? 0 : st.records + Math.floor(Math.random() * 20),
          Status: isFailed ? 'Failed' : 'Success',
          ErrorMessage: isFailed ? 'The remote server returned an error: (403) Forbidden.' : null,
          TableName: st.table,
          CreatedAt: end.toISOString(),
        });
        offset += duration + 2;
      }
    }
    mockLogs.sort((a, b) => new Date(b.StartTime) - new Date(a.StartTime));
    res.json(mockLogs.slice(0, limit));
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

export default router;
