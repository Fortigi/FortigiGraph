import { Router } from 'express';
import crypto from 'crypto';
import * as db from '../db/connection.js';

const adminCrawlersRouter = Router();
const selfServiceCrawlersRouter = Router();
const useSql = process.env.USE_SQL === 'true';

const KEY_PREFIX = 'fgc_';
const KEY_RANDOM_BYTES = 32;

function generateApiKey() {
  const random = crypto.randomBytes(KEY_RANDOM_BYTES).toString('hex');
  return `${KEY_PREFIX}${random}`;
}

function hashKey(apiKey, salt) {
  return crypto.createHash('sha256').update(Buffer.concat([salt, Buffer.from(apiKey, 'utf8')])).digest();
}

async function ensureCrawlerTables(pool) {
  const result = await pool.request().query(
    `SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'Crawlers' AND TABLE_SCHEMA = 'dbo'`
  );
  if (result.recordset.length === 0) {
    await pool.request().query(`
      CREATE TABLE dbo.Crawlers (
        id              INT IDENTITY(1,1) PRIMARY KEY,
        displayName     NVARCHAR(255) NOT NULL,
        description     NVARCHAR(MAX),
        apiKeyHash      VARBINARY(64) NOT NULL,
        apiKeySalt      VARBINARY(32) NOT NULL,
        apiKeyPrefix    NVARCHAR(8) NOT NULL,
        systemIds       NVARCHAR(MAX),
        permissions     NVARCHAR(MAX) NOT NULL DEFAULT '["ingest"]',
        enabled         BIT NOT NULL DEFAULT 1,
        createdAt       DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
        createdBy       NVARCHAR(255),
        lastUsedAt      DATETIME2,
        lastRotatedAt   DATETIME2,
        expiresAt       DATETIME2,
        rateLimit       INT NOT NULL DEFAULT 100
      );
      CREATE NONCLUSTERED INDEX IX_Crawlers_ApiKeyPrefix
      ON dbo.Crawlers (apiKeyPrefix) INCLUDE (apiKeyHash, apiKeySalt, enabled, expiresAt);
    `);
    await pool.request().query(`
      CREATE TABLE dbo.CrawlerAuditLog (
        id              INT IDENTITY(1,1) PRIMARY KEY,
        crawlerId       INT NOT NULL,
        action          NVARCHAR(50) NOT NULL,
        endpoint        NVARCHAR(255),
        recordCount     INT,
        statusCode      INT,
        ipAddress       NVARCHAR(45),
        timestamp       DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
      );
      CREATE NONCLUSTERED INDEX IX_CrawlerAuditLog_CrawlerId
      ON dbo.CrawlerAuditLog (crawlerId, timestamp DESC);
    `);
  }
}

// ─── Admin endpoints (Entra ID auth) ─────────────────────────────

// GET /api/admin/crawlers — List all crawlers
adminCrawlersRouter.get('/admin/crawlers', async (req, res) => {
  if (!useSql) return res.json([]);
  try {
    const pool = await db.getPool();
    await ensureCrawlerTables(pool);
    const result = await pool.request().query(`
      SELECT id, displayName, description, apiKeyPrefix, systemIds, permissions,
             enabled, createdAt, createdBy, lastUsedAt, lastRotatedAt, expiresAt, rateLimit
      FROM dbo.Crawlers
      ORDER BY createdAt DESC
    `);
    res.json(result.recordset);
  } catch (err) {
    console.error('Error listing crawlers:', err.message);
    res.status(500).json({ error: 'Failed to list crawlers' });
  }
});

// POST /api/admin/crawlers — Register a new crawler
adminCrawlersRouter.post('/admin/crawlers', async (req, res) => {
  if (!useSql) return res.status(503).json({ error: 'SQL not configured' });
  const { displayName, description, systemIds, permissions, expiresAt, rateLimit } = req.body;

  if (!displayName || typeof displayName !== 'string' || displayName.trim().length === 0) {
    return res.status(400).json({ error: 'displayName is required' });
  }

  try {
    const pool = await db.getPool();
    await ensureCrawlerTables(pool);

    const apiKey = generateApiKey();
    const salt = crypto.randomBytes(32);
    const hash = hashKey(apiKey, salt);
    const prefix = apiKey.slice(0, 8);
    const createdBy = req.user?.preferred_username || req.user?.name || 'system';

    const result = await pool.request()
      .input('displayName', displayName.trim().slice(0, 255))
      .input('description', (description || '').slice(0, 4000))
      .input('apiKeyHash', hash)
      .input('apiKeySalt', salt)
      .input('apiKeyPrefix', prefix)
      .input('systemIds', systemIds ? JSON.stringify(systemIds) : null)
      .input('permissions', JSON.stringify(permissions || ['ingest']))
      .input('createdBy', createdBy)
      .input('expiresAt', expiresAt || null)
      .input('rateLimit', rateLimit || 100)
      .query(`INSERT INTO dbo.Crawlers
              (displayName, description, apiKeyHash, apiKeySalt, apiKeyPrefix, systemIds, permissions, createdBy, expiresAt, rateLimit)
              OUTPUT INSERTED.id, INSERTED.displayName, INSERTED.apiKeyPrefix, INSERTED.createdAt
              VALUES (@displayName, @description, @apiKeyHash, @apiKeySalt, @apiKeyPrefix, @systemIds, @permissions, @createdBy, @expiresAt, @rateLimit)`);

    const crawler = result.recordset[0];

    res.status(201).json({
      ...crawler,
      apiKey, // Plaintext key — shown ONCE
      message: 'Store this API key securely. It will not be shown again.',
    });
  } catch (err) {
    console.error('Error registering crawler:', err.message);
    res.status(500).json({ error: 'Failed to register crawler' });
  }
});

// PATCH /api/admin/crawlers/:id — Update crawler metadata
adminCrawlersRouter.patch('/admin/crawlers/:id', async (req, res) => {
  if (!useSql) return res.status(503).json({ error: 'SQL not configured' });
  const id = parseInt(req.params.id, 10);
  if (isNaN(id)) return res.status(400).json({ error: 'Invalid crawler ID' });

  const { displayName, description, enabled, systemIds, permissions, expiresAt, rateLimit } = req.body;
  const sets = [];
  const request = (await db.getPool()).request().input('id', id);

  if (displayName !== undefined) {
    sets.push('displayName = @displayName');
    request.input('displayName', String(displayName).slice(0, 255));
  }
  if (description !== undefined) {
    sets.push('description = @description');
    request.input('description', String(description).slice(0, 4000));
  }
  if (enabled !== undefined) {
    sets.push('enabled = @enabled');
    request.input('enabled', enabled ? 1 : 0);
  }
  if (systemIds !== undefined) {
    sets.push('systemIds = @systemIds');
    request.input('systemIds', systemIds ? JSON.stringify(systemIds) : null);
  }
  if (permissions !== undefined) {
    sets.push('permissions = @permissions');
    request.input('permissions', JSON.stringify(permissions));
  }
  if (expiresAt !== undefined) {
    sets.push('expiresAt = @expiresAt');
    request.input('expiresAt', expiresAt || null);
  }
  if (rateLimit !== undefined) {
    sets.push('rateLimit = @rateLimit');
    request.input('rateLimit', parseInt(rateLimit, 10) || 100);
  }

  if (sets.length === 0) return res.status(400).json({ error: 'No fields to update' });

  try {
    const result = await request.query(`UPDATE dbo.Crawlers SET ${sets.join(', ')} OUTPUT INSERTED.* WHERE id = @id`);
    if (result.recordset.length === 0) return res.status(404).json({ error: 'Crawler not found' });
    const row = result.recordset[0];
    // Strip sensitive fields
    const { apiKeyHash, apiKeySalt, ...safe } = row;
    res.json(safe);
  } catch (err) {
    console.error('Error updating crawler:', err.message);
    res.status(500).json({ error: 'Failed to update crawler' });
  }
});

// DELETE /api/admin/crawlers/:id — Soft-delete (disable) crawler
adminCrawlersRouter.delete('/admin/crawlers/:id', async (req, res) => {
  if (!useSql) return res.status(503).json({ error: 'SQL not configured' });
  const id = parseInt(req.params.id, 10);
  if (isNaN(id)) return res.status(400).json({ error: 'Invalid crawler ID' });

  try {
    const pool = await db.getPool();
    const result = await pool.request()
      .input('id', id)
      .query('UPDATE dbo.Crawlers SET enabled = 0 WHERE id = @id');
    if (result.rowsAffected[0] === 0) return res.status(404).json({ error: 'Crawler not found' });
    res.json({ message: 'Crawler disabled' });
  } catch (err) {
    console.error('Error disabling crawler:', err.message);
    res.status(500).json({ error: 'Failed to disable crawler' });
  }
});

// GET /api/admin/crawlers/:id/audit — Paginated audit log
router.get('/admin/crawlers/:id/audit', async (req, res) => {
  if (!useSql) return res.json({ data: [], total: 0 });
  const id = parseInt(req.params.id, 10);
  if (isNaN(id)) return res.status(400).json({ error: 'Invalid crawler ID' });

  const limit = Math.min(parseInt(req.query.limit, 10) || 50, 200);
  const offset = parseInt(req.query.offset, 10) || 0;

  try {
    const pool = await db.getPool();
    const result = await pool.request()
      .input('id', id)
      .input('limit', limit)
      .input('offset', offset)
      .query(`SELECT action, endpoint, recordCount, statusCode, ipAddress, timestamp
              FROM dbo.CrawlerAuditLog
              WHERE crawlerId = @id
              ORDER BY timestamp DESC
              OFFSET @offset ROWS FETCH NEXT @limit ROWS ONLY;
              SELECT COUNT(*) AS total FROM dbo.CrawlerAuditLog WHERE crawlerId = @id;`);
    res.json({
      data: result.recordsets[0],
      total: result.recordsets[1][0].total,
    });
  } catch (err) {
    console.error('Error fetching audit log:', err.message);
    res.status(500).json({ error: 'Failed to fetch audit log' });
  }
});

// POST /api/admin/crawlers/:id/reset — Admin-initiated key reset
router.post('/admin/crawlers/:id/reset', async (req, res) => {
  if (!useSql) return res.status(503).json({ error: 'SQL not configured' });
  const id = parseInt(req.params.id, 10);
  if (isNaN(id)) return res.status(400).json({ error: 'Invalid crawler ID' });

  try {
    const pool = await db.getPool();
    const apiKey = generateApiKey();
    const salt = crypto.randomBytes(32);
    const hash = hashKey(apiKey, salt);
    const prefix = apiKey.slice(0, 8);

    const result = await pool.request()
      .input('id', id)
      .input('apiKeyHash', hash)
      .input('apiKeySalt', salt)
      .input('apiKeyPrefix', prefix)
      .query(`UPDATE dbo.Crawlers
              SET apiKeyHash = @apiKeyHash, apiKeySalt = @apiKeySalt, apiKeyPrefix = @apiKeyPrefix,
                  lastRotatedAt = SYSUTCDATETIME()
              WHERE id = @id AND enabled = 1`);

    if (result.rowsAffected[0] === 0) return res.status(404).json({ error: 'Crawler not found or disabled' });

    res.json({
      apiKey,
      apiKeyPrefix: prefix,
      rotatedAt: new Date().toISOString(),
      message: 'Store this API key securely. It will not be shown again.',
    });
  } catch (err) {
    console.error('Error resetting crawler key:', err.message);
    res.status(500).json({ error: 'Failed to reset key' });
  }
});

// ─── Crawler self-service endpoints (API key auth) ───────────────

// GET /api/crawlers/whoami — Return own metadata
selfServiceCrawlersRouter.get('/crawlers/whoami', (req, res) => {
  if (!req.crawler) return res.status(401).json({ error: 'Not authenticated' });
  res.json(req.crawler);
});

// POST /api/crawlers/rotate — Rotate own key
selfServiceCrawlersRouter.post('/crawlers/rotate', async (req, res) => {
  if (!req.crawler) return res.status(401).json({ error: 'Not authenticated' });
  if (!useSql) return res.status(503).json({ error: 'SQL not configured' });

  try {
    const pool = await db.getPool();
    const apiKey = generateApiKey();
    const salt = crypto.randomBytes(32);
    const hash = hashKey(apiKey, salt);
    const prefix = apiKey.slice(0, 8);

    await pool.request()
      .input('id', req.crawler.id)
      .input('apiKeyHash', hash)
      .input('apiKeySalt', salt)
      .input('apiKeyPrefix', prefix)
      .query(`UPDATE dbo.Crawlers
              SET apiKeyHash = @apiKeyHash, apiKeySalt = @apiKeySalt, apiKeyPrefix = @apiKeyPrefix,
                  lastRotatedAt = SYSUTCDATETIME()
              WHERE id = @id`);

    // Log rotation
    await pool.request()
      .input('crawlerId', req.crawler.id)
      .input('ipAddress', (req.ip || '').slice(0, 45))
      .query(`INSERT INTO dbo.CrawlerAuditLog (crawlerId, action, statusCode, ipAddress)
              VALUES (@crawlerId, 'key_rotated', 200, @ipAddress)`);

    res.json({
      apiKey,
      apiKeyPrefix: prefix,
      rotatedAt: new Date().toISOString(),
      message: 'Store this API key securely. The previous key is now invalid.',
    });
  } catch (err) {
    console.error('Error rotating crawler key:', err.message);
    res.status(500).json({ error: 'Failed to rotate key' });
  }
});

export { adminCrawlersRouter, selfServiceCrawlersRouter };
