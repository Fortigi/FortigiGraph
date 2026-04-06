/**
 * Crawler job management endpoints.
 * Jobs are stored in dbo.CrawlerJobs and picked up by the PowerShell worker.
 */
import { Router } from 'express';
import * as db from '../db/connection.js';

const router = Router();
const useSql = process.env.USE_SQL === 'true';

const VALID_JOB_TYPES = ['demo', 'entra-id', 'csv'];
const MAX_RECENT_JOBS = 50;

// ─── POST /api/admin/crawler-jobs — Create a new job ────────────
router.post('/admin/crawler-jobs', async (req, res) => {
  if (!useSql) return res.status(503).json({ error: 'SQL not configured' });

  const { jobType, config } = req.body;
  if (!jobType || !VALID_JOB_TYPES.includes(jobType)) {
    return res.status(400).json({ error: `jobType must be one of: ${VALID_JOB_TYPES.join(', ')}` });
  }

  // Validate type-specific config
  if (jobType === 'entra-id') {
    if (!config?.tenantId || !config?.clientId || !config?.clientSecret) {
      return res.status(400).json({ error: 'Entra ID jobs require tenantId, clientId, and clientSecret in config' });
    }
  }

  try {
    const pool = await db.getPool();
    const createdBy = req.user?.preferred_username || req.user?.name || 'ui';

    // Prevent duplicate demo jobs — don't queue if one is already queued or running
    if (jobType === 'demo') {
      const dup = await pool.request().query(
        `SELECT 1 FROM dbo.CrawlerJobs WHERE jobType = 'demo' AND status IN ('queued', 'running')`
      );
      if (dup.recordset.length > 0) {
        return res.status(409).json({ error: 'A demo data job is already queued or running' });
      }
    }

    // For Entra ID, encrypt clientSecret before storing
    let configJson = null;
    if (config) {
      const sanitized = { ...config };
      // TODO: encrypt clientSecret with AES-256-GCM (Step 6)
      // For now, store as-is — the CrawlerJobs table is only accessible to SQL admins
      configJson = JSON.stringify(sanitized);
    }

    const result = await pool.request()
      .input('jobType', jobType)
      .input('config', configJson)
      .input('createdBy', createdBy)
      .query(`INSERT INTO dbo.CrawlerJobs (jobType, config, createdBy)
              OUTPUT INSERTED.*
              VALUES (@jobType, @config, @createdBy)`);

    res.status(201).json(result.recordset[0]);
  } catch (err) {
    console.error('Error creating crawler job:', err.message);
    res.status(500).json({ error: 'Failed to create job' });
  }
});

// ─── GET /api/admin/crawler-jobs — List recent jobs ─────────────
router.get('/admin/crawler-jobs', async (req, res) => {
  if (!useSql) return res.json([]);

  try {
    const pool = await db.getPool();
    const limit = Math.min(parseInt(req.query.limit, 10) || 20, MAX_RECENT_JOBS);
    const result = await pool.request()
      .input('limit', limit)
      .query(`SELECT TOP (@limit) * FROM dbo.CrawlerJobs ORDER BY createdAt DESC`);
    res.json(result.recordset);
  } catch (err) {
    console.error('Error listing crawler jobs:', err.message);
    res.status(500).json({ error: 'Failed to list jobs' });
  }
});

// ─── GET /api/admin/crawler-jobs/:id — Single job with progress ──
router.get('/admin/crawler-jobs/:id', async (req, res) => {
  if (!useSql) return res.status(404).json({ error: 'Not found' });
  const id = parseInt(req.params.id, 10);
  if (isNaN(id)) return res.status(400).json({ error: 'Invalid job ID' });

  try {
    const pool = await db.getPool();
    const result = await pool.request()
      .input('id', id)
      .query(`SELECT * FROM dbo.CrawlerJobs WHERE id = @id`);
    if (result.recordset.length === 0) return res.status(404).json({ error: 'Job not found' });
    res.json(result.recordset[0]);
  } catch (err) {
    console.error('Error fetching crawler job:', err.message);
    res.status(500).json({ error: 'Failed to fetch job' });
  }
});

// ─── DELETE /api/admin/crawler-jobs/:id — Cancel a queued job ────
router.delete('/admin/crawler-jobs/:id', async (req, res) => {
  if (!useSql) return res.status(503).json({ error: 'SQL not configured' });
  const id = parseInt(req.params.id, 10);
  if (isNaN(id)) return res.status(400).json({ error: 'Invalid job ID' });

  try {
    const pool = await db.getPool();
    const result = await pool.request()
      .input('id', id)
      .query(`UPDATE dbo.CrawlerJobs SET status = 'cancelled', completedAt = SYSUTCDATETIME()
              WHERE id = @id AND status = 'queued'`);
    if (result.rowsAffected[0] === 0) {
      return res.status(404).json({ error: 'Job not found or not in queued state' });
    }
    res.json({ message: 'Job cancelled' });
  } catch (err) {
    console.error('Error cancelling job:', err.message);
    res.status(500).json({ error: 'Failed to cancel job' });
  }
});

// ─── GET /api/admin/status — System status for getting-started UI ─
router.get('/admin/status', async (req, res) => {
  if (!useSql) {
    return res.json({ hasData: true, hasCrawlers: false, pendingJobs: 0, runningJobs: 0 });
  }

  try {
    const pool = await db.getPool();
    const result = await pool.request().query(`
      SELECT
        (SELECT CASE WHEN EXISTS (
          SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'Principals' AND TABLE_SCHEMA = 'dbo'
        ) THEN (SELECT CASE WHEN COUNT(*) > 0 THEN 1 ELSE 0 END FROM dbo.Principals)
        ELSE 0 END) AS hasData,

        (SELECT CASE WHEN EXISTS (
          SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'Crawlers' AND TABLE_SCHEMA = 'dbo'
        ) THEN (SELECT COUNT(*) FROM dbo.Crawlers WHERE enabled = 1)
        ELSE 0 END) AS crawlerCount,

        (SELECT CASE WHEN EXISTS (
          SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'CrawlerJobs' AND TABLE_SCHEMA = 'dbo'
        ) THEN (SELECT COUNT(*) FROM dbo.CrawlerJobs WHERE status = 'queued')
        ELSE 0 END) AS pendingJobs,

        (SELECT CASE WHEN EXISTS (
          SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'CrawlerJobs' AND TABLE_SCHEMA = 'dbo'
        ) THEN (SELECT COUNT(*) FROM dbo.CrawlerJobs WHERE status = 'running')
        ELSE 0 END) AS runningJobs
    `);

    const row = result.recordset[0];
    res.json({
      hasData: row.hasData === 1,
      hasCrawlers: row.crawlerCount > 0,
      pendingJobs: row.pendingJobs,
      runningJobs: row.runningJobs,
    });
  } catch (err) {
    console.error('Error fetching status:', err.message);
    res.status(500).json({ error: 'Failed to fetch status' });
  }
});

export default router;
