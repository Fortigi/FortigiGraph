// Shared column discovery cache with TTL.
// Used by both permissions.js and tags.js to avoid querying INFORMATION_SCHEMA on every request.

const COLUMN_CACHE_TTL = 5 * 60 * 1000; // 5 minutes

const SYSTEM_COLS = new Set(['id', 'ValidFrom', 'ValidTo', 'SysStartTime', 'SysEndTime']);
const FILTERABLE_TYPES = new Set(['nvarchar', 'varchar', 'char', 'bit', 'int', 'smallint', 'tinyint']);

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

export { SYSTEM_COLS, FILTERABLE_TYPES };
