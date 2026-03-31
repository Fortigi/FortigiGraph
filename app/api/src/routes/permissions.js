import { Router } from 'express';
import { permissionAssignments } from '../mock/data.js';
import { ensureTagTables } from './tags.js';
import { ensureCategoryTables } from './categories.js';
import { getUserColumns, getGroupColumns, getResourceColumns, getPrincipalOrUserColumns, getUserColumnValues, getPrincipalOrUserColumnValues, FILTERABLE_TYPES } from '../db/columnCache.js';
import { timedRequest } from '../perf/sqlTimer.js';

const router = Router();
const useSql = process.env.USE_SQL === 'true';

let db = null;
if (useSql) {
  db = await import('../db/connection.js');
}

// Columns always handled with explicit aliases (not included in dynamic list)
const ALIASED_COLS = new Set(['displayName', 'userPrincipalName']);

// Aliases: Resources/GraphGroups column names → permission query aliases
// New model uses resourceDisplayName/resourceDescription, but we keep group aliases for backward compat
const GROUP_COL_ALIASES = { displayName: 'resourceDisplayName', description: 'resourceDescription' };
const GROUP_ALIAS_TO_COL = {
  resourceDisplayName: 'displayName', resourceDescription: 'description',
  // backward compat
  groupDisplayName: 'displayName', groupDescription: 'description',
};

// ─── GET /api/user-columns ────────────────────────────────────────
// Returns column names + distinct values from GraphUsers for filter dropdowns.
// Values come from the FULL dataset (not limited by userLimit), so dropdowns
// show all possible options regardless of which page of users is loaded.
router.get('/user-columns', async (req, res) => {
  // ?schema=true — return column names only (no distinct values). Fast path (~100ms).
  // Used by the frontend to immediately recognise which filters are server-side,
  // without waiting for the expensive UNION ALL distinct-values query.
  const schemaOnly = req.query.schema === 'true';

  try {
    if (!useSql) {
      const mockCols = {};
      for (const row of permissionAssignments) {
        for (const [key, val] of Object.entries(row)) {
          if (['groupId', 'memberId', 'memberDisplayName', 'memberUPN', 'memberType',
               'groupDisplayName', 'groupTypeCalculated', 'groupDescription',
               'membershipType', 'managedByAccessPackage'].includes(key)) continue;
          if (val == null || val === '') continue;
          if (!mockCols[key]) mockCols[key] = new Set();
          if (!schemaOnly) mockCols[key].add(String(val));
        }
      }
      return res.json(
        Object.entries(mockCols)
          .filter(([, vals]) => schemaOnly || (vals.size >= 1 && vals.size <= 500))
          .map(([column, vals]) => ({ column, values: schemaOnly ? [] : [...vals].sort() }))
      );
    }

    const p = await db.getPool();

    let grouped;
    if (schemaOnly) {
      // Fast: just schema names, no distinct value scan
      const cols = await getPrincipalOrUserColumns(p);
      grouped = Object.fromEntries(cols.map(c => [c.name, []]));
    } else {
      // Slow: cached distinct values (5-min TTL — avoids 44s UNION ALL on every load)
      grouped = { ...await getPrincipalOrUserColumnValues(p) };
    }

    // Add virtual __userTag column
    try {
      await ensureTagTables(p);
      const tagResult = await timedRequest(p, 'user-columns-tags', res).query(`
        SELECT t.name
        FROM dbo.GraphTags t
        WHERE t.entityType = 'user'
          AND EXISTS (SELECT 1 FROM dbo.GraphTagAssignments ta WHERE ta.tagId = t.id)
        ORDER BY t.name
      `);
      const userTags = tagResult.recordset.map(r => r.name);
      grouped['__userTag'] = userTags; // always include values — tag query is fast
    } catch { /* tag tables may not exist yet — skip silently */ }

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
//   filters  (JSON)  - server-side filters: {"department":"HR","groupTypeCalculated":"Security Group"}
//                       User columns (GraphUsers) and group columns (GraphGroups) both supported.
router.get('/permissions', async (req, res) => {
  try {
    const userLimit = Math.min(Math.max(parseInt(req.query.userLimit) || 0, 0), 10000);

    // Parse filters (JSON object of field:value pairs)
    let requestedFilters = {};
    if (req.query.filters) {
      try { requestedFilters = JSON.parse(req.query.filters); } catch { /* ignore bad JSON */ }
    }

    if (useSql) {
      const p = await db.getPool();

      // Return empty data when sync hasn't run yet (no tables exist yet)
      const tableCheck = await p.request().query(
        `SELECT OBJECT_ID('dbo.Principals', 'U') AS principalsExists, OBJECT_ID('dbo.GraphUsers', 'U') AS graphUsersExists`
      );
      if (!tableCheck.recordset[0].principalsExists && !tableCheck.recordset[0].graphUsersExists) {
        return res.json({ data: [], totalUsers: 0, managedByPackages: [] });
      }

      // Prefer materialized tables (fast), then new resource views, then old views as fallback
      const matCheck = await timedRequest(p, 'perm-mat-check', res).query(`
        SELECT
          OBJECT_ID('dbo.mat_UserPermissionAssignments', 'U') AS matPermExists,
          OBJECT_ID('dbo.mat_UserPermissionAssignmentViaBusinessRole', 'U') AS matApExists,
          OBJECT_ID('dbo.mat_UserCounts', 'U') AS matCountsExists,
          OBJECT_ID('dbo.vw_ResourceUserPermissionAssignments', 'V') AS resourceViewExists,
          OBJECT_ID('dbo.Principals', 'U') AS principalsExists
      `);
      const permSource = matCheck.recordset[0].matPermExists
        ? 'mat_UserPermissionAssignments'
        : matCheck.recordset[0].resourceViewExists
          ? 'vw_ResourceUserPermissionAssignments'
          : 'vw_UserPermissionAssignments';
      // Detect whether the permission source uses resourceId or groupId
      const useResourceId = !!matCheck.recordset[0].resourceViewExists && !matCheck.recordset[0].matPermExists;
      // Column names differ between old views (groupId/memberId/memberType) and new views (resourceId/principalId/principalType)
      const COL_RES = useResourceId ? 'resourceId' : 'groupId';
      const COL_PRINC = useResourceId ? 'principalId' : 'memberId';
      const COL_PTYPE = useResourceId ? 'principalType' : 'memberType';
      const apSource = matCheck.recordset[0].matApExists
        ? 'mat_UserPermissionAssignmentViaBusinessRole'
        : 'vw_UserPermissionAssignmentViaBusinessRole';
      const hasPrecomputedCounts = !!matCheck.recordset[0].matCountsExists;

      // Determine user table: prefer Principals, fall back to GraphUsers
      const userTable = matCheck.recordset[0].principalsExists ? 'Principals' : 'GraphUsers';
      const upnCol = userTable === 'Principals' ? 'u.email' : 'u.userPrincipalName';

      // Discover user and group columns dynamically
      const allCols = await getPrincipalOrUserColumns(p);
      const colNames = new Set(allCols.map(c => c.name));
      // Use Resources columns if available, fall back to GraphGroups
      let allGroupCols;
      try {
        allGroupCols = await getResourceColumns(p);
      } catch {
        allGroupCols = await getGroupColumns(p);
      }
      const groupColNames = new Set(allGroupCols.map(c => GROUP_COL_ALIASES[c.name] || c.name));

      // Build dynamic user column SELECT (exclude aliased cols handled explicitly)
      const dynamicUserCols = allCols
        .filter(c => !ALIASED_COLS.has(c.name))
        .map(c => `u.[${c.name}]`)
        .join(',\n            ');

      // Extract special tag filters before regular validation
      let userTagFilter = null;
      let groupTagFilter = null;
      if (requestedFilters['__userTag']) {
        userTagFilter = String(requestedFilters['__userTag']);
        delete requestedFilters['__userTag'];
      }
      if (requestedFilters['__groupTag']) {
        groupTagFilter = String(requestedFilters['__groupTag']);
        delete requestedFilters['__groupTag'];
      }

      // Ensure tag tables exist for tag filter queries
      if (userTagFilter || groupTagFilter) {
        try {
          await ensureTagTables(p);
        } catch {
          userTagFilter = null;
          groupTagFilter = null;
        }
      }

      // Validate and split filters into user vs group columns (parameterized)
      const validUserFilters = [];
      const validGroupFilters = [];
      for (const [field, value] of Object.entries(requestedFilters)) {
        if (value == null || String(value) === '') continue;
        if (colNames.has(field)) {
          validUserFilters.push({ field, value: String(value) });
        } else if (groupColNames.has(field)) {
          validGroupFilters.push({ field, value: String(value) });
        }
      }

      let filterWhere = '';
      let groupFilterWhere = '';
      let userTagJoin = '';
      let groupTagJoin = '';
      const addParams = (request) => {
        for (let i = 0; i < validUserFilters.length; i++) {
          const f = validUserFilters[i];
          // Use CAST for consistent string comparison (handles bit/int columns)
          filterWhere += ` AND CAST(u.[${f.field}] AS NVARCHAR(400)) = @f${i}`;
          request.input(`f${i}`, f.value);
        }
        for (let i = 0; i < validGroupFilters.length; i++) {
          const f = validGroupFilters[i];
          // Map aliased names back to real Resources column names
          const realCol = GROUP_ALIAS_TO_COL[f.field] || f.field;
          groupFilterWhere += ` AND CAST(r.[${realCol}] AS NVARCHAR(400)) = @gf${i}`;
          request.input(`gf${i}`, f.value);
        }
        if (userTagFilter) {
          userTagJoin = `
            INNER JOIN dbo.GraphTagAssignments _uta ON _uta.entityId = UPPER(CAST(u.id AS NVARCHAR(36)))
            INNER JOIN dbo.GraphTags _ut ON _uta.tagId = _ut.id AND _ut.name = @__userTag AND _ut.entityType = 'user'`;
          request.input('__userTag', userTagFilter);
        }
        if (groupTagFilter) {
          groupTagJoin = `
            INNER JOIN dbo.GraphTagAssignments _gta ON _gta.entityId = UPPER(CAST(p.${COL_RES} AS NVARCHAR(36)))
            INNER JOIN dbo.GraphTags _gt ON _gta.tagId = _gt.id AND _gt.name = @__groupTag AND _gt.entityType IN ('resource', 'group')`;
          request.input('__groupTag', groupTagFilter);
        }
      };

      // Combined query — single batch eliminates redundant table scans
      // Source indicator (mat/view/pre) visible in Performance page timings
      const sourceTag = permSource.startsWith('mat_') ? 'mat' : 'view';

      if (userLimit > 0) {
        filterWhere = '';
        groupFilterWhere = '';

        // When no filters are active and pre-computed counts exist, skip the
        // expensive GROUP BY entirely — just read top N from mat_UserCounts
        // (instant clustered index scan vs full table scan + hash aggregate)
        const noFilters = validUserFilters.length === 0 && validGroupFilters.length === 0
          && !userTagFilter && !groupTagFilter;
        const usePrecomputed = hasPrecomputedCounts && noFilters;

        const request = timedRequest(p, `perm-combined[${usePrecomputed ? 'pre' : sourceTag}]`, res);
        request.input('userLimit', userLimit);
        addParams(request);

        // Join Resources in user-count step only when group/resource filters are active
        const topUsersGroupJoin = validGroupFilters.length > 0 || groupTagJoin
          ? `LEFT JOIN Resources r ON p.${COL_RES} = r.id` : '';

        // Step 1: Get top users — pre-computed (instant) or computed (GROUP BY)
        const step1Sql = usePrecomputed
          ? `SELECT TOP (@userLimit) memberId, cnt
             INTO #UserCounts
             FROM dbo.mat_UserCounts
             ORDER BY cnt DESC`
          : `SELECT TOP (@userLimit) p.${COL_PRINC} AS memberId, COUNT(*) AS cnt
             INTO #UserCounts
             FROM ${permSource} p
             INNER JOIN ${userTable} u ON p.${COL_PRINC} = u.id
             ${topUsersGroupJoin}
             ${userTagJoin}
             ${groupTagJoin}
             WHERE p.${COL_PTYPE} != '#microsoft.graph.group'
               ${filterWhere}
               ${groupFilterWhere}
             GROUP BY p.${COL_PRINC}
             ORDER BY cnt DESC`;

        // Step 3: Total count — must reflect ALL matching users, not just the TOP N
        const step3Sql = usePrecomputed
          ? `SELECT COUNT(*) AS totalUsers FROM dbo.mat_UserCounts`
          : `SELECT COUNT(DISTINCT p.${COL_PRINC}) AS totalUsers
             FROM ${permSource} p
             INNER JOIN ${userTable} u ON p.${COL_PRINC} = u.id
             ${topUsersGroupJoin}
             ${userTagJoin}
             ${groupTagJoin}
             WHERE p.${COL_PTYPE} != '#microsoft.graph.group'
               ${filterWhere}
               ${groupFilterWhere}`;

        const result = await request.query(`
          -- Step 1: Top users ${usePrecomputed ? '(pre-computed — no GROUP BY)' : '(computed — GROUP BY)'}
          ${step1Sql};

          -- Step 2: Main data for top N users (index seek on memberId)
          SELECT
            p.${COL_RES} AS resourceId,
            p.${COL_RES} AS groupId,
            r.displayName AS resourceDisplayName,
            r.displayName AS groupDisplayName,
            r.resourceType,
            r.resourceType AS groupTypeCalculated,
            r.description AS resourceDescription,
            r.description AS groupDescription,
            r.systemId,
            sys.displayName AS systemName,
            p.${COL_PRINC} AS memberId,
            u.displayName AS memberDisplayName,
            ${upnCol} AS memberUPN,
            p.${COL_PTYPE} AS memberType,
            p.membershipType,
            ${dynamicUserCols},
            p.managedByAccessPackage
          FROM ${permSource} p
          INNER JOIN ${userTable} u ON p.${COL_PRINC} = u.id
          LEFT JOIN Resources r ON p.${COL_RES} = r.id
          LEFT JOIN Systems sys ON r.systemId = sys.id
          ${groupTagJoin}
          WHERE p.${COL_PTYPE} != '#microsoft.graph.group'
            AND p.${COL_PRINC} IN (
              SELECT memberId FROM #UserCounts
            )
            ${groupFilterWhere};

          -- Step 3: Total user count
          ${step3Sql};

          -- Step 4: AP mapping for same top N users (non-fatal)
          BEGIN TRY
            SELECT
              ap.userId AS memberId,
              ap.groupId AS resourceId,
              ap.groupId,
              STRING_AGG(CAST(ap.businessRoleId AS NVARCHAR(36)), ',') AS accessPackageIds
            FROM ${apSource} ap
            WHERE ap.userId IN (
              SELECT memberId FROM #UserCounts
            )
            GROUP BY ap.userId, ap.groupId;
          END TRY
          BEGIN CATCH
            SELECT CAST(NULL AS NVARCHAR(36)) AS memberId,
                   CAST(NULL AS NVARCHAR(36)) AS resourceId,
                   CAST(NULL AS NVARCHAR(36)) AS groupId,
                   CAST(NULL AS NVARCHAR(MAX)) AS accessPackageIds
            WHERE 1 = 0;
          END CATCH

          DROP TABLE #UserCounts;
        `);

        // recordsets: [0]=main data, [1]=totalUsers, [2]=AP mapping
        const managedByPackages = (result.recordsets[2] || [])
          .filter(r => r.memberId)
          .map(r => ({
            memberId: r.memberId,
            resourceId: r.resourceId || r.groupId,
            groupId: r.groupId || r.resourceId,
            accessPackageIds: r.accessPackageIds ? r.accessPackageIds.split(',') : [],
          }));

        return res.json({
          data: result.recordsets[0],
          totalUsers: result.recordsets[1][0].totalUsers,
          managedByPackages,
        });
      }

      // No user limit — single batch for main data + AP mapping
      const request = timedRequest(p, `perm-combined[${sourceTag}]`, res);
      filterWhere = '';
      groupFilterWhere = '';
      addParams(request);

      const result = await request.query(`
        SELECT
          p.${COL_RES} AS resourceId,
          p.${COL_RES} AS groupId,
          r.displayName AS resourceDisplayName,
          r.displayName AS groupDisplayName,
          r.resourceType,
          r.resourceType AS groupTypeCalculated,
          r.description AS resourceDescription,
          r.description AS groupDescription,
          r.systemId,
          sys.displayName AS systemName,
          p.${COL_PRINC} AS memberId,
          u.displayName AS memberDisplayName,
          ${upnCol} AS memberUPN,
          p.${COL_PTYPE} AS memberType,
          p.membershipType,
          ${dynamicUserCols},
          p.managedByAccessPackage
        FROM ${permSource} p
        INNER JOIN ${userTable} u ON p.${COL_PRINC} = u.id
        LEFT JOIN Resources r ON p.${COL_RES} = r.id
        LEFT JOIN Systems sys ON r.systemId = sys.id
        ${userTagJoin}
        ${groupTagJoin}
        WHERE p.${COL_PTYPE} != '#microsoft.graph.group'
          ${filterWhere}
          ${groupFilterWhere};

        BEGIN TRY
          SELECT
            ap.userId AS memberId,
            ap.groupId AS resourceId,
            ap.groupId,
            STRING_AGG(CAST(ap.businessRoleId AS NVARCHAR(36)), ',') AS accessPackageIds
          FROM ${apSource} ap
          GROUP BY ap.userId, ap.groupId;
        END TRY
        BEGIN CATCH
          SELECT CAST(NULL AS NVARCHAR(36)) AS memberId,
                 CAST(NULL AS NVARCHAR(36)) AS resourceId,
                 CAST(NULL AS NVARCHAR(36)) AS groupId,
                 CAST(NULL AS NVARCHAR(MAX)) AS accessPackageIds
          WHERE 1 = 0;
        END CATCH
      `);

      // recordsets: [0]=main data, [1]=AP mapping
      const managedByPackages = (result.recordsets[1] || [])
        .filter(r => r.memberId)
        .map(r => ({
          memberId: r.memberId,
          resourceId: r.resourceId || r.groupId,
          groupId: r.groupId || r.resourceId,
          accessPackageIds: r.accessPackageIds ? r.accessPackageIds.split(',') : [],
        }));

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
    res.status(500).json({ error: 'Internal server error' });
  }
});

// GET /api/access-package-groups - Access package to group/resource mapping
// Also aliased as /api/access-package-resources
router.get('/access-package-groups', accessPackageResourcesHandler);
router.get('/access-package-resources', accessPackageResourcesHandler);

async function accessPackageResourcesHandler(req, res) {
  try {
    if (useSql) {
      const p = await db.getPool();
      try { await ensureCategoryTables(p); } catch { /* category tables optional */ }
      const result = await timedRequest(p, 'ap-groups', res).query(`
        SELECT
          rrs.parentResourceId AS businessRoleId,
          rrs.parentResourceId AS accessPackageId,
          ap.displayName AS accessPackageName,
          c.displayName  AS catalogName,
          UPPER(rrs.childResourceId) AS resourceId,
          UPPER(rrs.childResourceId) AS groupId,
          r.displayName  AS resourceName,
          r.displayName  AS groupName,
          r.resourceType,
          r.systemId,
          rrs.roleName,
          ISNULL(ac.cnt, 0) AS totalAssignments,
          cat.id AS categoryId,
          cat.name AS categoryName,
          cat.color AS categoryColor
        FROM dbo.ResourceRelationships rrs
        INNER JOIN dbo.Resources ap ON rrs.parentResourceId = ap.id
                   AND ap.resourceType = 'BusinessRole'
                   AND ap.ValidTo = '9999-12-31 23:59:59.9999999'
        LEFT JOIN dbo.GovernanceCatalogs c ON ap.catalogId = c.id
                   AND c.ValidTo = '9999-12-31 23:59:59.9999999'
        LEFT  JOIN dbo.Resources r ON UPPER(rrs.childResourceId) = r.id
                   AND r.ValidTo = '9999-12-31 23:59:59.9999999'
        LEFT  JOIN (
          SELECT resourceId, COUNT(*) AS cnt
          FROM dbo.ResourceAssignments
          WHERE (state = 'delivered' OR state IS NULL) AND assignmentType = 'Governed'
          GROUP BY resourceId
        ) ac ON rrs.parentResourceId = ac.resourceId
        LEFT  JOIN dbo.GovernanceCategoryAssignments ca ON LOWER(rrs.parentResourceId) = ca.resourceId
        LEFT  JOIN dbo.GovernanceCategories cat ON ca.categoryId = cat.id
        WHERE rrs.relationshipType = 'Contains'
          AND rrs.ValidTo = '9999-12-31 23:59:59.9999999'
      `);
      return res.json(result.recordset);
    }
    res.json([]);
  } catch (err) {
    // Table may not exist in this environment — return empty instead of 500
    console.error('access-package-groups query failed:', err.message);
    res.json([]);
  }
}

// GET /api/sync-log - Recent sync log entries from GraphSyncLog
router.get('/sync-log', async (req, res) => {
  try {
    const limit = Math.min(Math.max(parseInt(req.query.limit) || 20, 1), 100);

    if (useSql) {
      const p = await db.getPool();
      // Check if GraphSyncLog table exists before querying
      const tableCheck = await timedRequest(p, 'sync-log-check', res).query(`
        SELECT OBJECT_ID('dbo.GraphSyncLog', 'U') AS tableExists
      `);
      if (!tableCheck.recordset[0].tableExists) {
        return res.json([]);
      }

      const result = await timedRequest(p, 'sync-log-data', res).input('limit', limit).query(`
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
      { type: 'Catalogs', table: 'GovernanceCatalogs', records: 12 },
      { type: 'AccessPackages', table: 'Resources (BusinessRole)', records: 67 },
      { type: 'AccessPackageAssignments', table: 'ResourceAssignments (Governed)', records: 834 },
      { type: 'AccessPackageResourceRoleScopes', table: 'ResourceRelationships (Contains)', records: 203 },
      { type: 'AccessPackageAssignmentPolicies', table: 'AssignmentPolicies', records: 71 },
      { type: 'AccessPackageAssignmentRequests', table: 'AssignmentRequests', records: 2103 },
      { type: 'AccessPackageAccessReviews', table: 'CertificationDecisions', records: 45 },
      { type: 'MaterializedViews', table: 'mat_UserPermissionAssignments', records: 0 },
      { type: 'RiskScoring', table: 'GraphUsers,GraphGroups', records: 1636 },
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
    console.error('sync-log query failed:', err.message);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// GET /api/groups-with-nested - resource/group IDs that are members of other groups
// (i.e., groups whose members gain indirect access to parent groups)
router.get('/groups-with-nested', async (req, res) => {
  try {
    if (!useSql) return res.json({ groupIds: [] });
    const p = await db.getPool();
    const result = await timedRequest(p, 'groups-with-nested', res).query(`
      BEGIN TRY
        SELECT DISTINCT UPPER(principalId) AS groupId
        FROM dbo.ResourceAssignments
        WHERE principalType LIKE '%group%'
          AND assignmentType = 'Direct'
          AND ValidTo = '9999-12-31 23:59:59.9999999'
      END TRY
      BEGIN CATCH
        -- Fall back to old table if ResourceAssignments doesn't exist
        BEGIN TRY
          SELECT DISTINCT UPPER(memberId) AS groupId
          FROM dbo.GraphGroupMembers
          WHERE memberType = '#microsoft.graph.group'
        END TRY
        BEGIN CATCH
          SELECT CAST(NULL AS NVARCHAR(36)) AS groupId WHERE 1 = 0
        END CATCH
      END CATCH
    `);
    return res.json({ groupIds: result.recordset.map(r => r.groupId) });
  } catch (err) {
    console.error('groups-with-nested query failed:', err.message);
    return res.json({ groupIds: [] });
  }
});

// GET /api/group/:groupId/nested-groups - parent groups this group is a member of,
// plus user memberships for those parent groups (showing indirect access gained)
router.get('/group/:groupId/nested-groups', async (req, res) => {
  try {
    if (!useSql) return res.json({ groups: [], memberships: [] });
    const p = await db.getPool();
    const groupId = req.params.groupId;

    const matCheck = await timedRequest(p, 'nested-mat-check', res).query(`
      SELECT OBJECT_ID('dbo.mat_UserPermissionAssignments', 'U') AS matPermExists,
             OBJECT_ID('dbo.vw_ResourceUserPermissionAssignments', 'V') AS resourceViewExists
    `);
    const permSource = matCheck.recordset[0].matPermExists
      ? 'mat_UserPermissionAssignments'
      : matCheck.recordset[0].resourceViewExists
        ? 'vw_ResourceUserPermissionAssignments'
        : 'vw_UserPermissionAssignments';
    const COL_RES_N = matCheck.recordset[0].resourceViewExists && !matCheck.recordset[0].matPermExists ? 'resourceId' : 'groupId';
    const COL_PRINC_N = matCheck.recordset[0].resourceViewExists && !matCheck.recordset[0].matPermExists ? 'principalId' : 'memberId';

    const request = timedRequest(p, 'nested-groups-data', res);
    request.input('childGroupId', groupId);

    const result = await request.query(`
      -- Resources/groups that this group is a member of (parent groups)
      -- Try ResourceAssignments first, fall back to GraphGroupMembers
      BEGIN TRY
        SELECT
          UPPER(ra.resourceId) AS groupId,
          UPPER(ra.resourceId) AS resourceId,
          r.displayName,
          r.resourceType,
          r.resourceType AS groupTypeCalculated,
          r.description
        FROM dbo.ResourceAssignments ra
        LEFT JOIN dbo.Resources r ON UPPER(ra.resourceId) = r.id
          AND r.ValidTo = '9999-12-31 23:59:59.9999999'
        WHERE UPPER(ra.principalId) = UPPER(@childGroupId)
          AND ra.principalType LIKE '%group%'
          AND ra.assignmentType = 'Direct'
          AND ra.ValidTo = '9999-12-31 23:59:59.9999999';
      END TRY
      BEGIN CATCH
        SELECT
          UPPER(gm.groupId) AS groupId,
          UPPER(gm.groupId) AS resourceId,
          g.displayName,
          g.groupTypeCalculated AS resourceType,
          g.groupTypeCalculated,
          g.description
        FROM dbo.GraphGroupMembers gm
        LEFT JOIN dbo.GraphGroups g ON UPPER(gm.groupId) = g.id
        WHERE UPPER(gm.memberId) = UPPER(@childGroupId)
          AND gm.memberType = '#microsoft.graph.group';
      END CATCH

      -- User memberships for those parent groups
      SELECT
        p.${COL_RES_N} AS resourceId,
        p.${COL_RES_N} AS groupId,
        p.${COL_PRINC_N} AS memberId,
        p.membershipType
      FROM ${permSource} p
      WHERE p.${COL_RES_N} IN (
        SELECT UPPER(ra2.resourceId)
        FROM dbo.ResourceAssignments ra2
        WHERE UPPER(ra2.principalId) = UPPER(@childGroupId)
          AND ra2.principalType LIKE '%group%'
          AND ra2.assignmentType = 'Direct'
          AND ra2.ValidTo = '9999-12-31 23:59:59.9999999'
      )
      AND p.${COL_PRINC_N === 'principalId' ? 'principalType' : 'memberType'} != '#microsoft.graph.group'
    `);

    return res.json({
      groups: result.recordsets[0] || [],
      memberships: result.recordsets[1] || [],
    });
  } catch (err) {
    console.error('nested-groups query failed:', err.message);
    return res.json({ groups: [], memberships: [] });
  }
});

export default router;
