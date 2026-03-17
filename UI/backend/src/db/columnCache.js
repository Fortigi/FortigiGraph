// Shared column discovery cache with TTL.
// Used by both permissions.js and tags.js to avoid querying INFORMATION_SCHEMA on every request.
// Also caches the expensive DISTINCT-values queries (UNION ALL per column).

const COLUMN_CACHE_TTL = 5 * 60 * 1000; // 5 minutes

const SYSTEM_COLS = new Set(['id', 'ValidFrom', 'ValidTo', 'SysStartTime', 'SysEndTime']);
const FILTERABLE_TYPES = new Set(['nvarchar', 'varchar', 'char', 'bit', 'int', 'smallint', 'tinyint']);

// ─── Column schema cache ────────────────────────────────────────

let userColumnsCache = null;
let userColumnsCacheTime = 0;
let groupColumnsCache = null;
let groupColumnsCacheTime = 0;

async function discoverColumns(pool, table) {
  const result = await pool.request()
    .input('tableName', table)
    .query(`
      SELECT COLUMN_NAME, DATA_TYPE
      FROM INFORMATION_SCHEMA.COLUMNS
      WHERE TABLE_NAME = @tableName
        AND COLUMN_NAME NOT IN ('id', 'ValidFrom', 'ValidTo', 'SysStartTime', 'SysEndTime')
      ORDER BY ORDINAL_POSITION
    `);
  return result.recordset.map(r => ({ name: r.COLUMN_NAME, type: r.DATA_TYPE }));
}

export async function getUserColumns(pool) {
  const now = Date.now();
  if (userColumnsCache && (now - userColumnsCacheTime) < COLUMN_CACHE_TTL) {
    return userColumnsCache;
  }
  userColumnsCache = await discoverColumns(pool, 'GraphUsers');
  userColumnsCacheTime = now;
  return userColumnsCache;
}

export async function getGroupColumns(pool) {
  const now = Date.now();
  if (groupColumnsCache && (now - groupColumnsCacheTime) < COLUMN_CACHE_TTL) {
    return groupColumnsCache;
  }
  groupColumnsCache = await discoverColumns(pool, 'GraphGroups');
  groupColumnsCacheTime = now;
  return groupColumnsCache;
}

// ─── Column distinct values cache ───────────────────────────────
// These queries (UNION ALL of SELECT DISTINCT per column) are the
// single most expensive operations: 44s for users, 29s for groups.
// Caching with the same 5-min TTL makes subsequent loads instant.

let userValuesCache = null;
let userValuesCacheTime = 0;
let userValuesInflight = null;
let groupValuesCache = null;
let groupValuesCacheTime = 0;
let groupValuesInflight = null;

// Validate SQL identifier to prevent injection via schema-derived names
const SAFE_IDENT_RE = /^[a-zA-Z0-9_]+$/;

async function discoverColumnValues(pool, table, columns) {
  const filterableCols = columns.filter(c => FILTERABLE_TYPES.has(c.type) && SAFE_IDENT_RE.test(c.name));
  if (filterableCols.length === 0) return {};

  if (!SAFE_IDENT_RE.test(table)) throw new Error(`Invalid table name: ${table}`);

  const parts = filterableCols.map(c =>
    `SELECT '${c.name}' AS col, CAST(val AS NVARCHAR(400)) AS val ` +
    `FROM (SELECT DISTINCT TOP 500 [${c.name}] AS val FROM ${table} ` +
    `WHERE [${c.name}] IS NOT NULL AND CAST([${c.name}] AS NVARCHAR(400)) != '' ` +
    `AND ValidTo = '9999-12-31 23:59:59.9999999') t`
  );

  const result = await pool.request().query(parts.join('\nUNION ALL\n') + '\nORDER BY col, val');

  const grouped = {};
  for (const r of result.recordset) {
    if (!grouped[r.col]) grouped[r.col] = [];
    grouped[r.col].push(r.val);
  }
  return grouped;
}

/**
 * Returns { [columnName]: [value1, value2, ...] } for GraphUsers.
 * Cached for 5 minutes.
 */
export async function getUserColumnValues(pool) {
  const now = Date.now();
  if (userValuesCache && (now - userValuesCacheTime) < COLUMN_CACHE_TTL) {
    return userValuesCache;
  }
  // Deduplicate concurrent callers — only run one expensive query at a time
  if (userValuesInflight) return userValuesInflight;
  userValuesInflight = (async () => {
    try {
      const cols = await getUserColumns(pool);
      const result = await discoverColumnValues(pool, 'GraphUsers', cols);
      userValuesCache = result;
      userValuesCacheTime = Date.now();
      return result;
    } finally {
      userValuesInflight = null;
    }
  })();
  return userValuesInflight;
}

/**
 * Returns { [columnName]: [value1, value2, ...] } for GraphGroups.
 * Cached for 5 minutes.
 */
export async function getGroupColumnValues(pool) {
  const now = Date.now();
  if (groupValuesCache && (now - groupValuesCacheTime) < COLUMN_CACHE_TTL) {
    return groupValuesCache;
  }
  // Deduplicate concurrent callers — only run one expensive query at a time
  if (groupValuesInflight) return groupValuesInflight;
  groupValuesInflight = (async () => {
    try {
      const cols = await getGroupColumns(pool);
      const result = await discoverColumnValues(pool, 'GraphGroups', cols);
      groupValuesCache = result;
      groupValuesCacheTime = Date.now();
      return result;
    } finally {
      groupValuesInflight = null;
    }
  })();
  return groupValuesInflight;
}

export { SYSTEM_COLS, FILTERABLE_TYPES };
