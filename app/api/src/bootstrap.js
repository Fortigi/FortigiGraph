/**
 * Auto-bootstrap: creates the built-in worker crawler and infrastructure tables
 * on first startup. This enables the worker container to discover its API key
 * via SQL and the UI to submit jobs without manual crawler registration.
 */
import crypto from 'crypto';
import * as db from './db/connection.js';

const KEY_PREFIX = 'fgc_';
const KEY_RANDOM_BYTES = 32;
const BUILTIN_CRAWLER_NAME = 'Built-in Worker';

function generateApiKey() {
  const random = crypto.randomBytes(KEY_RANDOM_BYTES).toString('hex');
  return `${KEY_PREFIX}${random}`;
}

function hashKey(apiKey, salt) {
  return crypto.createHash('sha256').update(Buffer.concat([salt, Buffer.from(apiKey, 'utf8')])).digest();
}

async function ensureTable(pool, tableName, createSql) {
  const check = await pool.request()
    .input('table', tableName)
    .query(`SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = @table AND TABLE_SCHEMA = 'dbo'`);
  if (check.recordset.length === 0) {
    await pool.request().query(createSql);
  }
}

async function ensureWorkerConfigTable(pool) {
  await ensureTable(pool, 'WorkerConfig', `
    CREATE TABLE dbo.WorkerConfig (
      configKey   NVARCHAR(100) PRIMARY KEY,
      configValue NVARCHAR(MAX) NOT NULL,
      updatedAt   DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
    );
  `);
}

async function ensureCrawlerJobsTable(pool) {
  await ensureTable(pool, 'CrawlerJobs', `
    CREATE TABLE dbo.CrawlerJobs (
      id            INT IDENTITY(1,1) PRIMARY KEY,
      jobType       NVARCHAR(50) NOT NULL,
      status        NVARCHAR(20) NOT NULL DEFAULT 'queued',
      config        NVARCHAR(MAX),
      progress      NVARCHAR(MAX),
      result        NVARCHAR(MAX),
      errorMessage  NVARCHAR(MAX),
      createdAt     DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
      startedAt     DATETIME2,
      completedAt   DATETIME2,
      createdBy     NVARCHAR(255) DEFAULT 'ui'
    );
  `);
}

async function ensureSyncLogTable(pool) {
  await ensureTable(pool, 'GraphSyncLog', `
    CREATE TABLE dbo.GraphSyncLog (
      Id              INT IDENTITY(1,1) PRIMARY KEY,
      SyncType        NVARCHAR(100) NOT NULL,
      TableName       NVARCHAR(100),
      StartTime       DATETIME2 NOT NULL,
      EndTime         DATETIME2,
      DurationSeconds INT,
      RecordCount     INT,
      Status          NVARCHAR(20) NOT NULL,
      ErrorMessage    NVARCHAR(MAX),
      CreatedAt       DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX IX_GraphSyncLog_StartTime ON dbo.GraphSyncLog (StartTime DESC);
  `);
}

async function ensureCrawlerConfigsTable(pool) {
  await ensureTable(pool, 'CrawlerConfigs', `
    CREATE TABLE dbo.CrawlerConfigs (
      id            INT IDENTITY(1,1) PRIMARY KEY,
      crawlerType   NVARCHAR(50) NOT NULL,
      displayName   NVARCHAR(255) NOT NULL,
      config        NVARCHAR(MAX) NOT NULL,
      enabled       BIT NOT NULL DEFAULT 1,
      lastRunAt     DATETIME2,
      lastRunStatus NVARCHAR(20),
      createdAt     DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
      updatedAt     DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
    );
  `);
}

async function ensureBuiltinCrawler(pool) {
  // Check if built-in crawler already exists
  const existing = await pool.request()
    .input('name', BUILTIN_CRAWLER_NAME)
    .query(`SELECT id FROM dbo.Crawlers WHERE displayName = @name AND enabled = 1`);

  if (existing.recordset.length > 0) {
    // Crawler exists — check if WorkerConfig has the key
    const configCheck = await pool.request()
      .input('key', 'BUILTIN_CRAWLER_API_KEY')
      .query(`SELECT 1 FROM dbo.WorkerConfig WHERE configKey = @key`);

    if (configCheck.recordset.length > 0) {
      return; // Already bootstrapped
    }

    // WorkerConfig missing — rotate key and store it
    console.log('Built-in Worker crawler exists but WorkerConfig key missing — rotating...');
    const crawlerId = existing.recordset[0].id;
    const apiKey = generateApiKey();
    const salt = crypto.randomBytes(32);
    const hash = hashKey(apiKey, salt);
    const prefix = apiKey.slice(0, 8);

    await pool.request()
      .input('id', crawlerId)
      .input('hash', hash)
      .input('salt', salt)
      .input('prefix', prefix)
      .query(`UPDATE dbo.Crawlers
              SET apiKeyHash = @hash, apiKeySalt = @salt, apiKeyPrefix = @prefix,
                  lastRotatedAt = SYSUTCDATETIME()
              WHERE id = @id`);

    await pool.request()
      .input('key', 'BUILTIN_CRAWLER_API_KEY')
      .input('value', apiKey)
      .query(`INSERT INTO dbo.WorkerConfig (configKey, configValue) VALUES (@key, @value)`);

    console.log('Built-in Worker key rotated and stored in WorkerConfig');
    return;
  }

  // No built-in crawler — create one
  console.log('Creating Built-in Worker crawler...');
  const apiKey = generateApiKey();
  const salt = crypto.randomBytes(32);
  const hash = hashKey(apiKey, salt);
  const prefix = apiKey.slice(0, 8);

  await pool.request()
    .input('name', BUILTIN_CRAWLER_NAME)
    .input('desc', 'Auto-created crawler for the Docker worker container. Do not delete.')
    .input('hash', hash)
    .input('salt', salt)
    .input('prefix', prefix)
    .input('createdBy', 'system-bootstrap')
    .query(`INSERT INTO dbo.Crawlers
            (displayName, description, apiKeyHash, apiKeySalt, apiKeyPrefix, createdBy)
            VALUES (@name, @desc, @hash, @salt, @prefix, @createdBy)`);

  // Store plaintext key in WorkerConfig for the worker to discover
  await pool.request()
    .input('key', 'BUILTIN_CRAWLER_API_KEY')
    .input('value', apiKey)
    .query(`MERGE dbo.WorkerConfig AS t
            USING (SELECT @key AS configKey) AS s ON t.configKey = s.configKey
            WHEN MATCHED THEN UPDATE SET configValue = @value, updatedAt = SYSUTCDATETIME()
            WHEN NOT MATCHED THEN INSERT (configKey, configValue) VALUES (@key, @value);`);

  console.log(`Built-in Worker crawler created (prefix: ${prefix})`);
}

/**
 * Run all bootstrap tasks. Called once after the server starts listening.
 * Failures are logged but do not crash the server.
 */
export async function bootstrapWorker() {
  if (process.env.USE_SQL !== 'true') return;

  try {
    const pool = await db.getPool();
    await ensureWorkerConfigTable(pool);
    await ensureCrawlerJobsTable(pool);
    await ensureCrawlerConfigsTable(pool);
    await ensureSyncLogTable(pool);
    await ensureBuiltinCrawler(pool);
    console.log('Bootstrap complete');
  } catch (err) {
    console.error('Bootstrap failed (will retry on next request):', err.message);
  }
}
