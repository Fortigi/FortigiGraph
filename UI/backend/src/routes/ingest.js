/**
 * Ingest API Routes — All 12 entity type endpoints.
 *
 * Each endpoint follows the same pattern:
 * 1. Validate envelope (systemId, syncMode, records)
 * 2. Validate records against entity schema
 * 3. Normalize records (type coercion, GUID generation, extendedAttributes)
 * 4. Delegate to engine (merge + optional scoped delete)
 * 5. Write sync log
 * 6. Return summary
 */
import { Router } from 'express';
import * as db from '../db/connection.js';
import { ingest, writeSyncLog } from '../ingest/engine.js';
import { normalizeRecords } from '../ingest/normalization.js';
import { validateEnvelope, validateRecords, ENTITY_TABLE_MAP, ENTITY_KEY_MAP, ENTITY_SCOPE_MAP } from '../ingest/validation.js';
import { startSession, continueSession, endSession, hasSession } from '../ingest/sessions.js';
import { crawlerHasSystemAccess, crawlerHasPermission } from '../middleware/crawlerAuth.js';

const router = Router();
const useSql = process.env.USE_SQL === 'true';

/**
 * Generic ingest handler factory — creates the route handler for any entity type.
 */
function createIngestHandler(entityType) {
  const tableName = ENTITY_TABLE_MAP[entityType];
  const keyColumns = ENTITY_KEY_MAP[entityType];
  const scopeColumns = ENTITY_SCOPE_MAP[entityType] || [];

  return async (req, res) => {
    if (!useSql) return res.status(503).json({ error: 'SQL not configured' });

    // Check permission
    if (!crawlerHasPermission(req, 'ingest')) {
      return res.status(403).json({ error: 'Insufficient permissions' });
    }

    const body = req.body;

    // Validate envelope
    const envResult = validateEnvelope(body, entityType);
    if (!envResult.valid) {
      return res.status(400).json({ error: 'Validation failed', details: envResult.errors });
    }

    // Check system access
    if (entityType !== 'systems' && !crawlerHasSystemAccess(req, body.systemId)) {
      return res.status(403).json({ error: `Crawler does not have access to system ${body.systemId}` });
    }

    // Validate records
    const recResult = validateRecords(body.records, entityType, body.idGeneration);
    if (!recResult.valid) {
      return res.status(400).json({ error: 'Record validation failed', details: recResult.errors });
    }

    const startTime = new Date();

    try {
      const pool = await db.getPool();

      // Discover target table columns for normalization
      const colResult = await pool.request()
        .input('table', tableName)
        .query(`SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS
                WHERE TABLE_NAME = @table AND TABLE_SCHEMA = 'dbo'
                  AND COLUMN_NAME NOT IN ('ValidFrom', 'ValidTo')`);
      const coreColumns = colResult.recordset.map(r => r.COLUMN_NAME);

      // Normalize records
      const normalized = normalizeRecords(body.records, coreColumns, {
        idGeneration: body.idGeneration || 'native',
        idPrefix: body.idPrefix || '',
        systemId: body.systemId,
      });

      // Build scope from request
      const scope = {};
      if (body.scope) {
        for (const col of scopeColumns) {
          if (body.scope[col] !== undefined) scope[col] = body.scope[col];
        }
      }

      // Handle sync sessions
      if (body.syncSession === 'start') {
        const result = await startSession(pool, tableName, keyColumns, normalized, {
          systemId: body.systemId,
          scope,
          syncMode: body.syncMode || 'full',
        });
        return res.status(201).json({
          syncId: result.syncId,
          table: tableName,
          inserted: result.inserted,
          updated: result.updated,
          session: 'started',
        });
      }

      if (body.syncSession === 'continue') {
        if (!body.syncId || !hasSession(body.syncId)) {
          return res.status(400).json({ error: 'Invalid or expired syncId' });
        }
        const result = await continueSession(body.syncId, pool, normalized, keyColumns);
        return res.status(200).json({
          syncId: result.syncId,
          table: tableName,
          inserted: result.inserted,
          updated: result.updated,
          session: 'continued',
        });
      }

      if (body.syncSession === 'end') {
        if (!body.syncId || !hasSession(body.syncId)) {
          return res.status(400).json({ error: 'Invalid or expired syncId' });
        }
        const result = await endSession(body.syncId, pool, normalized, keyColumns, {
          syncMode: body.syncMode || 'full',
        });
        return res.status(200).json({
          syncId: result.syncId,
          table: tableName,
          inserted: result.inserted,
          updated: result.updated,
          deleted: result.deleted,
          totalRecords: result.totalRecords,
          session: 'completed',
        });
      }

      // Single-batch ingest (no session)
      const result = await ingest(pool, tableName, keyColumns, normalized, {
        syncMode: body.syncMode || 'delta',
        systemId: body.systemId,
        scope,
      });

      // Write sync log
      const syncType = `API-${entityType}`;
      await writeSyncLog(pool, syncType, tableName, startTime, body.records.length,
        result.inserted, result.updated, result.deleted, null);

      // Log to crawler audit
      if (req.crawler) {
        pool.request()
          .input('crawlerId', req.crawler.id)
          .input('endpoint', req.originalUrl)
          .input('recordCount', body.records.length)
          .input('ipAddress', (req.ip || '').slice(0, 45))
          .query(`INSERT INTO dbo.CrawlerAuditLog (crawlerId, action, endpoint, recordCount, statusCode, ipAddress)
                  VALUES (@crawlerId, 'ingest', @endpoint, @recordCount, 201, @ipAddress)`)
          .catch(() => {});
      }

      const durationMs = Date.now() - startTime.getTime();
      return res.status(201).json({
        table: tableName,
        inserted: result.inserted,
        updated: result.updated,
        deleted: result.deleted,
        records: body.records.length,
        durationMs,
      });

    } catch (err) {
      console.error(`Ingest error (${entityType}):`, err.message);
      await writeSyncLog(
        await db.getPool().catch(() => null),
        `API-${entityType}`, tableName, startTime, body.records?.length || 0,
        0, 0, 0, err.message
      ).catch(() => {});
      return res.status(500).json({ error: 'Ingest failed', message: err.message });
    }
  };
}

// ─── Register all entity endpoints ───────────────────────────────

router.post('/ingest/systems',                  createIngestHandler('systems'));
router.post('/ingest/principals',               createIngestHandler('principals'));
router.post('/ingest/resources',                createIngestHandler('resources'));
router.post('/ingest/resource-assignments',     createIngestHandler('resource-assignments'));
router.post('/ingest/resource-relationships',   createIngestHandler('resource-relationships'));
router.post('/ingest/identities',               createIngestHandler('identities'));
router.post('/ingest/identity-members',         createIngestHandler('identity-members'));
router.post('/ingest/contexts',                 createIngestHandler('contexts'));
router.post('/ingest/governance/catalogs',      createIngestHandler('governance/catalogs'));
router.post('/ingest/governance/policies',      createIngestHandler('governance/policies'));
router.post('/ingest/governance/requests',      createIngestHandler('governance/requests'));
router.post('/ingest/governance/certifications', createIngestHandler('governance/certifications'));

// ─── Utility endpoints ───────────────────────────────────────────

// POST /api/ingest/refresh-views — Trigger materialized view refresh
router.post('/ingest/refresh-views', async (req, res) => {
  if (!useSql) return res.status(503).json({ error: 'SQL not configured' });
  if (!crawlerHasPermission(req, 'refreshViews') && !crawlerHasPermission(req, 'admin')) {
    return res.status(403).json({ error: 'Insufficient permissions (requires refreshViews)' });
  }

  try {
    const pool = await db.getPool();

    // Check if materialized table exists
    const check = await pool.request().query(
      `SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'mat_UserPermissionAssignments' AND TABLE_SCHEMA = 'dbo'`
    );

    if (check.recordset.length > 0) {
      // Truncate and repopulate from view
      const viewCheck = await pool.request().query(
        `SELECT 1 FROM INFORMATION_SCHEMA.VIEWS WHERE TABLE_NAME = 'vw_ResourceUserPermissionAssignments' AND TABLE_SCHEMA = 'dbo'`
      );
      if (viewCheck.recordset.length > 0) {
        await pool.request().query(`
          TRUNCATE TABLE dbo.mat_UserPermissionAssignments;
          INSERT INTO dbo.mat_UserPermissionAssignments
          SELECT * FROM dbo.vw_ResourceUserPermissionAssignments;
        `);
        return res.json({ message: 'Materialized views refreshed' });
      }
    }

    res.json({ message: 'No materialized views to refresh' });
  } catch (err) {
    console.error('View refresh error:', err.message);
    res.status(500).json({ error: 'Failed to refresh views' });
  }
});

export default router;
