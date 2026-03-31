import crypto from 'crypto';
import * as db from '../db/connection.js';

const useSql = process.env.USE_SQL === 'true';

// In-memory rate limit tracking: crawlerId -> { count, windowStart }
const rateLimits = new Map();
const RATE_WINDOW_MS = 60 * 1000; // 1 minute

function checkRateLimit(crawlerId, limit) {
  const now = Date.now();
  const entry = rateLimits.get(crawlerId);

  if (!entry || now - entry.windowStart > RATE_WINDOW_MS) {
    rateLimits.set(crawlerId, { count: 1, windowStart: now });
    return true;
  }

  entry.count++;
  return entry.count <= limit;
}

function hashKey(apiKey, salt) {
  return crypto.createHash('sha256').update(Buffer.concat([salt, Buffer.from(apiKey, 'utf8')])).digest();
}

async function logAudit(pool, crawlerId, action, endpoint, statusCode, ipAddress) {
  try {
    await pool.request()
      .input('crawlerId', crawlerId)
      .input('action', action)
      .input('endpoint', endpoint)
      .input('statusCode', statusCode)
      .input('ipAddress', (ipAddress || '').slice(0, 45))
      .query(`INSERT INTO dbo.CrawlerAuditLog (crawlerId, action, endpoint, statusCode, ipAddress)
              VALUES (@crawlerId, @action, @endpoint, @statusCode, @ipAddress)`);
  } catch {
    // Audit log failure should not block the request
  }
}

export async function crawlerAuthMiddleware(req, res, next) {
  if (!useSql) {
    return res.status(503).json({ error: 'SQL not configured' });
  }

  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith('Bearer fgc_')) {
    return res.status(401).json({ error: 'Missing or invalid API key' });
  }

  const apiKey = authHeader.slice(7); // Remove "Bearer "
  const prefix = apiKey.slice(0, 8);

  let pool;
  try {
    pool = await db.getPool();
  } catch {
    return res.status(503).json({ error: 'Database unavailable' });
  }

  // Look up crawler by prefix
  let crawler;
  try {
    const result = await pool.request()
      .input('prefix', prefix)
      .query(`SELECT id, displayName, apiKeyHash, apiKeySalt, systemIds, permissions,
                     enabled, expiresAt, rateLimit
              FROM dbo.Crawlers
              WHERE apiKeyPrefix = @prefix`);

    if (result.recordset.length === 0) {
      await logAudit(pool, 0, 'auth_failed', req.originalUrl, 401, req.ip);
      return res.status(401).json({ error: 'Invalid API key' });
    }

    crawler = result.recordset[0];
  } catch (err) {
    console.error('Crawler auth DB error:', err.message);
    return res.status(500).json({ error: 'Authentication service error' });
  }

  // Verify hash
  const computedHash = hashKey(apiKey, crawler.apiKeySalt);
  if (!crypto.timingSafeEqual(computedHash, crawler.apiKeyHash)) {
    await logAudit(pool, crawler.id, 'auth_failed', req.originalUrl, 401, req.ip);
    return res.status(401).json({ error: 'Invalid API key' });
  }

  // Check enabled
  if (!crawler.enabled) {
    await logAudit(pool, crawler.id, 'auth_disabled', req.originalUrl, 403, req.ip);
    return res.status(403).json({ error: 'Crawler is disabled' });
  }

  // Check expiry
  if (crawler.expiresAt && new Date(crawler.expiresAt) < new Date()) {
    await logAudit(pool, crawler.id, 'auth_expired', req.originalUrl, 401, req.ip);
    return res.status(401).json({ error: 'API key has expired' });
  }

  // Rate limiting
  if (!checkRateLimit(crawler.id, crawler.rateLimit || 100)) {
    await logAudit(pool, crawler.id, 'rate_limited', req.originalUrl, 429, req.ip);
    return res.status(429).json({ error: 'Rate limit exceeded' });
  }

  // Parse permissions and system scope
  let systemIds = null;
  let permissions = ['ingest'];
  try { systemIds = crawler.systemIds ? JSON.parse(crawler.systemIds) : null; } catch { /* null = all */ }
  try { permissions = crawler.permissions ? JSON.parse(crawler.permissions) : ['ingest']; } catch { /* default */ }

  // Attach crawler info to request
  req.crawler = {
    id: crawler.id,
    displayName: crawler.displayName,
    systemIds,
    permissions,
  };

  // Update lastUsedAt (fire-and-forget)
  pool.request()
    .input('id', crawler.id)
    .query('UPDATE dbo.Crawlers SET lastUsedAt = SYSUTCDATETIME() WHERE id = @id')
    .catch(() => {});

  next();
}

// Helper: check if crawler has access to a specific system
export function crawlerHasSystemAccess(req, systemId) {
  if (!req.crawler) return false;
  if (!req.crawler.systemIds) return true; // null = all systems
  return req.crawler.systemIds.includes(systemId);
}

// Helper: check if crawler has a specific permission
export function crawlerHasPermission(req, permission) {
  if (!req.crawler) return false;
  return req.crawler.permissions.includes(permission);
}
