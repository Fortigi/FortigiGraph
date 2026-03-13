'use strict';

const { sql, getPool } = require('../db/connection');

/**
 * Build a paged list query against a temporal table.
 * Supports $page, $limit, asOf (point-in-time), and simple equality filters.
 *
 * @param {object} opts
 * @param {string} opts.table       - SQL table name (e.g. 'dbo.GraphUsers')
 * @param {string} opts.idColumn    - Primary key column name (e.g. 'id')
 * @param {object} opts.query       - Express req.query
 * @param {string[]} [opts.filterColumns] - Column names allowed in $filter
 * @param {string[]} [opts.extraWhere]    - Additional WHERE clauses (parameterized)
 * @param {Array}    [opts.extraParams]   - Additional mssql params for extraWhere
 * @returns {Promise<{data: any[], total: number, page: number, limit: number, hasMore: boolean}>}
 */
async function pagedList(opts) {
  const { table, idColumn = 'id', query = {}, filterColumns = [], extraWhere = [], extraParams = [] } = opts;

  const page  = Math.max(1, parseInt(query['$page']  || '1', 10));
  const limit = Math.min(1000, Math.max(1, parseInt(query['$limit'] || '100', 10)));
  const offset = (page - 1) * limit;
  const asOf = query.asOf ? new Date(query.asOf) : null;

  const whereClauses = [...extraWhere];
  const params = [...extraParams];
  let paramIdx = extraParams.length;

  // Parse simple equality $filter: "field eq 'value'"
  if (query['$filter']) {
    const match = /^(\w+)\s+eq\s+'?([^']+)'?$/.exec(query['$filter']);
    if (match) {
      const [, col, val] = match;
      if (filterColumns.includes(col)) {
        whereClauses.push(`[${col}] = @f${paramIdx}`);
        params.push({ name: `f${paramIdx}`, type: sql.NVarChar, value: val });
        paramIdx++;
      }
    }
  }

  const tableClause = asOf
    ? `${table} FOR SYSTEM_TIME AS OF @asOf`
    : table;

  if (asOf) {
    params.push({ name: 'asOf', type: sql.DateTime2, value: asOf });
  }

  const whereStr = whereClauses.length ? `WHERE ${whereClauses.join(' AND ')}` : '';

  const p = await getPool();

  // Count query
  const countReq = p.request();
  for (const { name, type, value } of params) countReq.input(name, type, value);
  const countResult = await countReq.query(
    `SELECT COUNT(*) AS total FROM ${tableClause} ${whereStr}`
  );
  const total = countResult.recordset[0].total;

  // Data query
  const dataReq = p.request();
  for (const { name, type, value } of params) dataReq.input(name, type, value);
  dataReq.input('offset', sql.Int, offset);
  dataReq.input('limit', sql.Int, limit);

  let selectCols = '*';
  if (query['$select']) {
    // Whitelist columns to prevent injection
    const allowed = query['$select']
      .split(',')
      .map((c) => c.trim())
      .filter((c) => /^[a-zA-Z_][a-zA-Z0-9_]*$/.test(c))
      .map((c) => `[${c}]`)
      .join(', ');
    if (allowed) selectCols = allowed;
  }

  const dataResult = await dataReq.query(
    `SELECT ${selectCols} FROM ${tableClause} ${whereStr}
     ORDER BY [${idColumn}]
     OFFSET @offset ROWS FETCH NEXT @limit ROWS ONLY`
  );

  return {
    data: dataResult.recordset,
    total,
    page,
    limit,
    hasMore: offset + limit < total,
  };
}

/**
 * Generic upsert (MERGE) for a single record.
 * @param {object} opts
 * @param {string} opts.table        - e.g. 'dbo.GraphUsers'
 * @param {string} opts.keyColumn    - Primary key column (e.g. 'id')
 * @param {object} opts.record       - The record to upsert
 * @returns {Promise<object>}        - The record after upsert
 */
async function upsertRecord(opts) {
  const { table, keyColumn, record } = opts;
  const keys = Object.keys(record).filter((k) => record[k] !== undefined);

  if (keys.length === 0) throw new Error('Record has no fields');
  if (!keys.includes(keyColumn)) throw new Error(`Key column '${keyColumn}' is required`);

  const p = await getPool();
  const req = p.request();

  // Build column lists
  const cols = keys.map((k) => `[${k}]`).join(', ');
  const vals = keys.map((k) => `@${k}`).join(', ');
  const updateSet = keys
    .filter((k) => k !== keyColumn)
    .map((k) => `target.[${k}] = source.[${k}]`)
    .join(', ');

  for (const k of keys) {
    const v = record[k];
    req.input(k, inferSqlType(v), v === undefined ? null : v);
  }

  const mergeQuery = `
    MERGE ${table} AS target
    USING (VALUES (${vals})) AS source (${cols})
    ON target.[${keyColumn}] = source.[${keyColumn}]
    WHEN MATCHED THEN UPDATE SET ${updateSet || '[id]=[id]'}
    WHEN NOT MATCHED THEN INSERT (${cols}) VALUES (${vals});
  `;

  await req.query(mergeQuery);
  return record;
}

/**
 * Batch MERGE for up to 1000 records.
 */
async function batchUpsert(opts) {
  const { table, keyColumn, records, mode = 'upsert' } = opts;

  if (!records || records.length === 0) {
    return { inserted: 0, updated: 0, deleted: 0, skipped: 0, errors: [] };
  }

  if (records.length > 1000) {
    throw new Error('Batch size exceeds maximum of 1000 records');
  }

  const result = { inserted: 0, updated: 0, deleted: 0, skipped: 0, errors: [] };

  if (mode === 'replace') {
    const p = await getPool();
    await p.request().query(`DELETE FROM ${table}`);
    result.deleted = -1; // unknown count, full replace
  }

  // Process in chunks of 100 to avoid param limits
  const CHUNK = 100;
  for (let i = 0; i < records.length; i += CHUNK) {
    const chunk = records.slice(i, i + CHUNK);
    for (const record of chunk) {
      try {
        if (mode === 'insert') {
          await insertRecord({ table, record });
          result.inserted++;
        } else {
          const existed = await recordExists(table, keyColumn, record[keyColumn]);
          await upsertRecord({ table, keyColumn, record });
          if (existed) result.updated++;
          else result.inserted++;
        }
      } catch (err) {
        result.errors.push({ record, message: err.message });
        result.skipped++;
      }
    }
  }

  return result;
}

async function recordExists(table, keyColumn, keyValue) {
  const p = await getPool();
  const req = p.request();
  req.input('keyval', inferSqlType(keyValue), keyValue);
  const res = await req.query(
    `SELECT 1 FROM ${table} WHERE [${keyColumn}] = @keyval`
  );
  return res.recordset.length > 0;
}

async function insertRecord({ table, record }) {
  const keys = Object.keys(record).filter((k) => record[k] !== undefined);
  const p = await getPool();
  const req = p.request();
  const cols = keys.map((k) => `[${k}]`).join(', ');
  const vals = keys.map((k) => `@${k}`).join(', ');
  for (const k of keys) {
    req.input(k, inferSqlType(record[k]), record[k] ?? null);
  }
  await req.query(`INSERT INTO ${table} (${cols}) VALUES (${vals})`);
}

async function deleteRecord(table, keyColumn, keyValue) {
  const p = await getPool();
  const req = p.request();
  req.input('keyval', inferSqlType(keyValue), keyValue);
  const res = await req.query(
    `DELETE FROM ${table} WHERE [${keyColumn}] = @keyval; SELECT @@ROWCOUNT AS affected`
  );
  return res.recordset[0].affected;
}

async function deleteComposite(table, conditions) {
  const p = await getPool();
  const req = p.request();
  const clauses = Object.entries(conditions).map(([col, val], i) => {
    req.input(`p${i}`, inferSqlType(val), val);
    return `[${col}] = @p${i}`;
  });
  const res = await req.query(
    `DELETE FROM ${table} WHERE ${clauses.join(' AND ')}; SELECT @@ROWCOUNT AS affected`
  );
  return res.recordset[0].affected;
}

async function getById(table, keyColumn, keyValue, asOf) {
  const p = await getPool();
  const req = p.request();
  req.input('keyval', inferSqlType(keyValue), keyValue);
  const tableClause = asOf
    ? `${table} FOR SYSTEM_TIME AS OF @asOf`
    : table;
  if (asOf) req.input('asOf', sql.DateTime2, new Date(asOf));
  const res = await req.query(
    `SELECT * FROM ${tableClause} WHERE [${keyColumn}] = @keyval`
  );
  return res.recordset[0] || null;
}

function inferSqlType(value) {
  if (value === null || value === undefined) return sql.NVarChar;
  if (typeof value === 'boolean') return sql.Bit;
  if (typeof value === 'number') return Number.isInteger(value) ? sql.Int : sql.Float;
  if (value instanceof Date) return sql.DateTime2;
  if (typeof value === 'string') {
    // UUID pattern → NVarChar (SQL UNIQUEIDENTIFIER needs special handling)
    if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)) {
      return sql.UniqueIdentifier;
    }
    if (/^\d{4}-\d{2}-\d{2}T/.test(value)) return sql.DateTime2;
    return sql.NVarChar;
  }
  return sql.NVarChar;
}

/**
 * Sanitize error messages to prevent SQL schema leakage.
 */
function sanitizeError(err) {
  const msg = err.message || 'An unexpected error occurred';
  // Strip SQL Server internal details
  return msg.replace(/\[.*?\]/g, '').replace(/at line \d+/gi, '').trim().slice(0, 200);
}

module.exports = {
  pagedList,
  upsertRecord,
  batchUpsert,
  deleteRecord,
  deleteComposite,
  getById,
  inferSqlType,
  sanitizeError,
};
