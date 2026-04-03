/**
 * Ingest Engine — Core bulk MERGE + scoped delete logic.
 *
 * Replicates the PowerShell Invoke-FGSQLBulkMerge + scoped delete pattern
 * using the mssql npm package (native TDS bulk load).
 */
import sql from 'mssql';
import * as db from '../db/connection.js';

const CURRENT_ROW = "'9999-12-31 23:59:59.9999999'";

// Map JS types to SQL types for temp table creation
const SQL_TYPE_MAP = {
  'uniqueidentifier': sql.UniqueIdentifier,
  'nvarchar(max)':    sql.NVarChar(sql.MAX),
  'nvarchar(500)':    sql.NVarChar(500),
  'nvarchar(255)':    sql.NVarChar(255),
  'nvarchar(100)':    sql.NVarChar(100),
  'nvarchar(50)':     sql.NVarChar(50),
  'nvarchar(20)':     sql.NVarChar(20),
  'nvarchar(8)':      sql.NVarChar(8),
  'int':              sql.Int,
  'bigint':           sql.BigInt,
  'bit':              sql.Bit,
  'datetime2':        sql.DateTime2,
  'decimal':          sql.Decimal(10, 2),
};

function getSqlType(sqlTypeName) {
  const key = sqlTypeName.toLowerCase().trim();
  // Handle nvarchar(N) dynamically
  const nvarcharMatch = key.match(/^nvarchar\((\d+)\)$/);
  if (nvarcharMatch) {
    const len = parseInt(nvarcharMatch[1], 10);
    return sql.NVarChar(len);
  }
  if (key === 'nvarchar(max)') return sql.NVarChar(sql.MAX);
  return SQL_TYPE_MAP[key] || sql.NVarChar(sql.MAX);
}

/**
 * Discover the column schema for a target table.
 * Returns array of { name, sqlType, sqlTypeName, isNullable }.
 */
export async function discoverColumns(pool, tableName) {
  const result = await pool.request()
    .input('table', tableName)
    .query(`
      SELECT c.COLUMN_NAME, c.DATA_TYPE, c.CHARACTER_MAXIMUM_LENGTH, c.IS_NULLABLE,
             COLUMNPROPERTY(OBJECT_ID('dbo.' + @table), c.COLUMN_NAME, 'IsIdentity') AS IsIdentity
      FROM INFORMATION_SCHEMA.COLUMNS c
      WHERE c.TABLE_NAME = @table AND c.TABLE_SCHEMA = 'dbo'
        AND c.COLUMN_NAME NOT IN ('ValidFrom', 'ValidTo')
      ORDER BY c.ORDINAL_POSITION
    `);

  return result.recordset.map(r => {
      let typeName = r.DATA_TYPE.toLowerCase();
      if (typeName === 'nvarchar' || typeName === 'varchar') {
        const len = r.CHARACTER_MAXIMUM_LENGTH === -1 ? 'max' : r.CHARACTER_MAXIMUM_LENGTH;
        typeName = `${r.DATA_TYPE}(${len})`;
      }
      return {
        name: r.COLUMN_NAME,
        sqlType: getSqlType(typeName),
        sqlTypeName: typeName,
        isNullable: r.IS_NULLABLE === 'YES',
        isIdentity: !!r.IsIdentity,
      };
    });
}

/**
 * Core ingest operation: bulk merge records into a target table with optional scoped delete.
 *
 * @param {object} pool - mssql connection pool
 * @param {string} tableName - Target table (e.g., 'Resources')
 * @param {string[]} keyColumns - Primary key columns (e.g., ['id'] or ['resourceId','principalId','assignmentType'])
 * @param {object[]} records - Array of record objects to merge
 * @param {object} options
 * @param {string} options.syncMode - 'full' (merge + delete) or 'delta' (merge only)
 * @param {number} options.systemId - System ID for scoped deletes
 * @param {object} options.scope - Additional scope filters (e.g., { resourceType: 'Group' })
 * @param {string} options.systemIdColumn - Column name for system scoping (default: 'systemId')
 * @param {string} [options.tempTable] - Existing temp table name (for sessions)
 * @returns {{ inserted: number, updated: number, deleted: number }}
 */
export async function ingest(pool, tableName, keyColumns, records, options = {}) {
  const {
    syncMode = 'delta',
    systemId = null,
    scope = {},
    systemIdColumn = 'systemId',
    tempTable: existingTempTable = null,
  } = options;

  if (!records || records.length === 0) {
    return { inserted: 0, updated: 0, deleted: 0 };
  }

  // Discover target table schema
  const columns = await discoverColumns(pool, tableName);
  if (columns.length === 0) {
    throw new Error(`Table '${tableName}' not found or has no columns`);
  }

  const columnMap = new Map(columns.map(c => [c.name, c]));

  // Filter to columns present in the records
  const recordKeys = new Set();
  for (const rec of records) {
    for (const k of Object.keys(rec)) {
      recordKeys.add(k);
    }
  }
  // Exclude IDENTITY columns — SQL auto-generates them, they can't be inserted
  const activeColumns = columns.filter(c => recordKeys.has(c.name) && !c.isIdentity);

  // Create temp table
  const tempName = existingTempTable || `##TempIngest_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;

  if (!existingTempTable) {
    const colDefs = activeColumns.map(c => `[${c.name}] ${c.sqlTypeName.toUpperCase()}`).join(', ');
    await pool.request().query(`CREATE TABLE [${tempName}] (${colDefs})`);
  }

  // Bulk insert into temp table
  const table = new sql.Table(tempName);
  table.create = false;
  for (const col of activeColumns) {
    table.columns.add(col.name, col.sqlType, { nullable: true });
  }
  for (const rec of records) {
    const row = activeColumns.map(c => {
      const val = rec[c.name];
      if (val === undefined || val === null) return null;
      return val;
    });
    table.rows.add(...row);
  }

  const bulkRequest = pool.request();
  bulkRequest.timeout = 300000; // 5 minutes
  await bulkRequest.bulk(table);

  // Build MERGE statement
  const nonKeyColumns = activeColumns.filter(c => !keyColumns.includes(c.name));
  const onClause = keyColumns.map(k => `target.[${k}] = source.[${k}]`).join(' AND ');
  const updateSet = nonKeyColumns.map(c => `target.[${c.name}] = source.[${c.name}]`).join(', ');
  const insertCols = activeColumns.map(c => `[${c.name}]`).join(', ');
  const insertVals = activeColumns.map(c => `source.[${c.name}]`).join(', ');

  let mergeSql = `
    MERGE dbo.[${tableName}] AS target
    USING [${tempName}] AS source
    ON ${onClause}
  `;

  if (updateSet) {
    mergeSql += `WHEN MATCHED THEN UPDATE SET ${updateSet}\n`;
  }
  mergeSql += `WHEN NOT MATCHED BY TARGET THEN INSERT (${insertCols}) VALUES (${insertVals})\n`;
  mergeSql += `OUTPUT $action;`;

  const mergeResult = await pool.request().query(mergeSql);

  let inserted = 0;
  let updated = 0;
  if (mergeResult.recordset) {
    for (const row of mergeResult.recordset) {
      if (row['$action'] === 'INSERT') inserted++;
      else if (row['$action'] === 'UPDATE') updated++;
    }
  }

  // Scoped delete (only in full sync mode)
  let deleted = 0;
  if (syncMode === 'full') {
    const tableColumnNames = new Set(columns.map(c => c.name));
    deleted = await scopedDelete(pool, tableName, keyColumns, tempName, systemId, scope, systemIdColumn, tableColumnNames);
  }

  // Clean up temp table (only if we created it)
  if (!existingTempTable) {
    await pool.request().query(`DROP TABLE IF EXISTS [${tempName}]`).catch(() => {});
  }

  return { inserted, updated, deleted };
}

/**
 * Scoped delete: remove records in the target table that are NOT in the temp table,
 * scoped by systemId and optional attribute filters.
 */
async function scopedDelete(pool, tableName, keyColumns, tempTable, systemId, scope, systemIdColumn, tableColumnNames) {
  // Build NOT EXISTS join on key columns
  const notExistsJoin = keyColumns.map(k => `t.[${k}] = source.[${k}]`).join(' AND ');

  let where = `t.ValidTo = ${CURRENT_ROW}`;

  // System scope — only if the table actually has the systemId column
  if (systemId !== null && systemId !== undefined && (!tableColumnNames || tableColumnNames.has(systemIdColumn))) {
    where += ` AND t.[${systemIdColumn}] = @systemId`;
  }

  // Additional scope filters — only if the column exists on the table
  const scopeParams = [];
  let paramIndex = 0;
  for (const [key, value] of Object.entries(scope)) {
    if (value !== undefined && value !== null && (!tableColumnNames || tableColumnNames.has(key))) {
      const paramName = `scope${paramIndex}`;
      where += ` AND t.[${key}] = @${paramName}`;
      scopeParams.push({ name: paramName, value, key });
      paramIndex++;
    }
  }

  const deleteSql = `
    DELETE t FROM dbo.[${tableName}] t
    WHERE ${where}
      AND NOT EXISTS (
        SELECT 1 FROM [${tempTable}] source WHERE ${notExistsJoin}
      )
  `;

  const request = pool.request();
  if (systemId !== null && systemId !== undefined) {
    request.input('systemId', systemId);
  }
  for (const p of scopeParams) {
    request.input(p.name, p.value);
  }

  const result = await request.query(deleteSql);
  return result.rowsAffected[0] || 0;
}

/**
 * Write a sync log entry to GraphSyncLog.
 */
export async function writeSyncLog(pool, syncType, tableName, startTime, recordCount, inserted, updated, deleted, error) {
  const endTime = new Date();
  const durationSeconds = Math.round((endTime - startTime) / 1000);
  const status = error ? 'Failed' : 'Success';

  try {
    // Check if GraphSyncLog exists
    const check = await pool.request().query(
      `SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'GraphSyncLog' AND TABLE_SCHEMA = 'dbo'`
    );
    if (check.recordset.length === 0) return;

    await pool.request()
      .input('syncType', syncType)
      .input('startTime', startTime)
      .input('endTime', endTime)
      .input('durationSeconds', durationSeconds)
      .input('recordCount', recordCount)
      .input('status', status)
      .input('errorMessage', error || null)
      .input('tableName', tableName)
      .query(`INSERT INTO dbo.GraphSyncLog
              (SyncType, StartTime, EndTime, DurationSeconds, RecordCount, Status, ErrorMessage, TableName)
              VALUES (@syncType, @startTime, @endTime, @durationSeconds, @recordCount, @status, @errorMessage, @tableName)`);
  } catch {
    // Sync log failure should not fail the ingest
  }
}
