/**
 * Sync Session Management — Handles chunked multi-request sync operations.
 *
 * When a crawler sends data in multiple batches (start → continue → end),
 * the session keeps a temp table alive across requests.
 */
import crypto from 'crypto';
import { discoverColumns, ingest, writeSyncLog } from './engine.js';
import sql from 'mssql';

// Active sessions: syncId → { tempTable, tableName, keyColumns, systemId, scope, startedAt, recordCount }
const sessions = new Map();
const SESSION_TIMEOUT_MS = 30 * 60 * 1000; // 30 minutes

// Cleanup expired sessions every 5 minutes
setInterval(() => {
  const now = Date.now();
  for (const [id, session] of sessions) {
    if (now - session.startedAt > SESSION_TIMEOUT_MS) {
      // Drop temp table if it still exists
      session.pool?.request().query(`DROP TABLE IF EXISTS [${session.tempTable}]`).catch(() => {});
      sessions.delete(id);
    }
  }
}, 5 * 60 * 1000);

/**
 * Start a new sync session.
 * Creates a temp table and merges the first batch.
 */
export async function startSession(pool, tableName, keyColumns, records, options) {
  const syncId = crypto.randomUUID();
  const tempTable = `##TempSession_${syncId.replace(/-/g, '').slice(0, 16)}`;

  // Discover columns and create temp table
  const columns = await discoverColumns(pool, tableName);
  const recordKeys = new Set();
  for (const rec of records) {
    for (const k of Object.keys(rec)) recordKeys.add(k);
  }
  const activeColumns = columns.filter(c => recordKeys.has(c.name));
  const colDefs = activeColumns.map(c => `[${c.name}] ${c.sqlTypeName.toUpperCase()}`).join(', ');
  await pool.request().query(`CREATE TABLE [${tempTable}] (${colDefs})`);

  // Merge first batch into temp table (no delete yet)
  const result = await ingest(pool, tableName, keyColumns, records, {
    ...options,
    syncMode: 'delta', // Never delete during session batches
    tempTable,
  });

  sessions.set(syncId, {
    tempTable,
    tableName,
    keyColumns,
    systemId: options.systemId,
    scope: options.scope || {},
    systemIdColumn: options.systemIdColumn || 'systemId',
    pool,
    startedAt: Date.now(),
    recordCount: records.length,
    inserted: result.inserted,
    updated: result.updated,
  });

  return { syncId, ...result };
}

/**
 * Continue an existing sync session with another batch.
 */
export async function continueSession(syncId, pool, records, keyColumns) {
  const session = sessions.get(syncId);
  if (!session) {
    throw new Error(`Sync session '${syncId}' not found or expired`);
  }

  const result = await ingest(pool, session.tableName, keyColumns, records, {
    syncMode: 'delta',
    tempTable: session.tempTable,
  });

  session.recordCount += records.length;
  session.inserted += result.inserted;
  session.updated += result.updated;

  return { syncId, ...result };
}

/**
 * End a sync session: merge final batch, run scoped delete, clean up.
 */
export async function endSession(syncId, pool, records, keyColumns, options = {}) {
  const session = sessions.get(syncId);
  if (!session) {
    throw new Error(`Sync session '${syncId}' not found or expired`);
  }

  // Merge final batch
  let finalResult = { inserted: 0, updated: 0 };
  if (records && records.length > 0) {
    finalResult = await ingest(pool, session.tableName, keyColumns, records, {
      syncMode: 'delta',
      tempTable: session.tempTable,
    });
    session.recordCount += records.length;
  }

  // Run scoped delete using the accumulated temp table
  let deleted = 0;
  const syncMode = options.syncMode || 'full';
  if (syncMode === 'full') {
    // Import scopedDelete by using the engine's ingest function with full mode
    // We need to run the delete manually since we have a custom temp table
    const { scopedDelete } = await import('./engine.js');

    // The temp table already has all records from all batches merged into the target.
    // But for delete detection, we need the IDs in the temp table.
    // The engine's ingest function already merged into temp table, so it has all IDs.

    // Run scoped delete
    const notExistsJoin = session.keyColumns.map(k => `t.[${k}] = source.[${k}]`).join(' AND ');
    let where = `t.ValidTo = '9999-12-31 23:59:59.9999999'`;

    if (session.systemId !== null && session.systemId !== undefined) {
      where += ` AND t.[${session.systemIdColumn}] = @systemId`;
    }

    const scopeParams = [];
    let paramIndex = 0;
    for (const [key, value] of Object.entries(session.scope)) {
      if (value !== undefined && value !== null) {
        const paramName = `scope${paramIndex}`;
        where += ` AND t.[${key}] = @${paramName}`;
        scopeParams.push({ name: paramName, value });
        paramIndex++;
      }
    }

    const deleteSql = `
      DELETE t FROM dbo.[${session.tableName}] t
      WHERE ${where}
        AND NOT EXISTS (
          SELECT 1 FROM [${session.tempTable}] source WHERE ${notExistsJoin}
        )
    `;

    const request = pool.request();
    if (session.systemId !== null && session.systemId !== undefined) {
      request.input('systemId', session.systemId);
    }
    for (const p of scopeParams) {
      request.input(p.name, p.value);
    }

    const deleteResult = await request.query(deleteSql);
    deleted = deleteResult.rowsAffected[0] || 0;
  }

  // Drop temp table
  await pool.request().query(`DROP TABLE IF EXISTS [${session.tempTable}]`).catch(() => {});

  // Write sync log
  const startTime = new Date(session.startedAt);
  const totalInserted = session.inserted + finalResult.inserted;
  const totalUpdated = session.updated + finalResult.updated;
  await writeSyncLog(
    pool, `API-${session.tableName}`, session.tableName, startTime,
    session.recordCount, totalInserted, totalUpdated, deleted, null
  );

  // Clean up session
  sessions.delete(syncId);

  return {
    syncId,
    inserted: totalInserted,
    updated: totalUpdated,
    deleted,
    totalRecords: session.recordCount,
  };
}

/**
 * Check if a session exists.
 */
export function hasSession(syncId) {
  return sessions.has(syncId);
}
