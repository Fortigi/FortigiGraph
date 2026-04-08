// Auto-bootstrap: runs DB migrations + creates the built-in worker crawler
// on first startup. Idempotent — safe to run on every web container start.
//
// In v5 (postgres) the schema is created entirely by the migration files in
// db/migrations/. This file no longer creates tables — it just runs the
// migrations runner and seeds the built-in worker crawler if it's missing.
// MVCC means we no longer need to enable snapshot isolation explicitly; it's
// the default behavior in postgres.
//
// The built-in worker API key is also written to a file inside the shared
// `job_data` volume so the worker container can pick it up on startup
// without needing direct DB access. The file is written with restrictive
// permissions and only contains the plaintext key — the same value the
// worker would have read from WorkerConfig in v4.

import crypto from 'crypto';
import { writeFileSync, mkdirSync } from 'fs';
import { dirname } from 'path';
import * as db from './db/connection.js';
import { runMigrations } from './db/migrate.js';

const WORKER_KEY_FILE = process.env.WORKER_KEY_FILE || '/data/uploads/.builtin-worker-key';

function writeWorkerKeyFile(apiKey) {
  try {
    mkdirSync(dirname(WORKER_KEY_FILE), { recursive: true });
    writeFileSync(WORKER_KEY_FILE, apiKey, { mode: 0o600, encoding: 'utf8' });
    console.log(`Built-in worker key written to ${WORKER_KEY_FILE}`);
  } catch (err) {
    console.warn(`Could not write worker key file (${WORKER_KEY_FILE}): ${err.message}`);
  }
}

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

async function ensureBuiltinCrawler() {
  const existing = await db.queryOne(
    `SELECT id FROM "Crawlers" WHERE "displayName" = $1 AND "enabled" = TRUE`,
    [BUILTIN_CRAWLER_NAME]
  );

  if (existing) {
    const cfg = await db.queryOne(
      `SELECT "configValue" FROM "WorkerConfig" WHERE "configKey" = 'BUILTIN_CRAWLER_API_KEY'`
    );
    if (cfg) {
      // Existing key — re-write the shared-volume file in case the volume
      // was nuked since the last restart (common during dev iteration).
      writeWorkerKeyFile(cfg.configValue);
      return;
    }

    console.log('Built-in Worker crawler exists but WorkerConfig key missing — rotating...');
    const apiKey = generateApiKey();
    const salt = crypto.randomBytes(32);
    const hash = hashKey(apiKey, salt);
    const prefix = apiKey.slice(0, 8);

    await db.query(
      `UPDATE "Crawlers"
          SET "apiKeyHash" = $1, "apiKeySalt" = $2, "apiKeyPrefix" = $3,
              "lastRotatedAt" = (now() AT TIME ZONE 'utc')
        WHERE id = $4`,
      [hash, salt, prefix, existing.id]
    );
    await db.query(
      `INSERT INTO "WorkerConfig" ("configKey", "configValue") VALUES ('BUILTIN_CRAWLER_API_KEY', $1)`,
      [apiKey]
    );
    writeWorkerKeyFile(apiKey);
    console.log('Built-in Worker key rotated and stored in WorkerConfig');
    return;
  }

  console.log('Creating Built-in Worker crawler...');
  const apiKey = generateApiKey();
  const salt = crypto.randomBytes(32);
  const hash = hashKey(apiKey, salt);
  const prefix = apiKey.slice(0, 8);

  await db.query(
    `INSERT INTO "Crawlers"
       ("displayName", "description", "apiKeyHash", "apiKeySalt", "apiKeyPrefix", "createdBy", "permissions")
     VALUES ($1, $2, $3, $4, $5, 'system-bootstrap', '["ingest","refreshViews","admin"]'::jsonb)`,
    [BUILTIN_CRAWLER_NAME, 'Auto-created crawler for the Docker worker container. Do not delete.',
     hash, salt, prefix]
  );

  await db.query(
    `INSERT INTO "WorkerConfig" ("configKey", "configValue")
     VALUES ('BUILTIN_CRAWLER_API_KEY', $1)
     ON CONFLICT ("configKey") DO UPDATE
       SET "configValue" = EXCLUDED."configValue", "updatedAt" = now()`,
    [apiKey]
  );

  writeWorkerKeyFile(apiKey);
  console.log(`Built-in Worker crawler created (prefix: ${prefix})`);
}

// Periodic prune of the `_history` audit table. Reads the retention setting
// from WorkerConfig (default 180 days) and deletes anything older. Runs once
// at startup (60s warm-up so it doesn't fight migrations) and then every 6 hours.
// Setting retention to 0 disables pruning entirely.
function startHistoryPruneJob() {
  const PRUNE_INTERVAL_MS = 6 * 60 * 60 * 1000;
  const FIRST_RUN_DELAY_MS = 60 * 1000;
  const DEFAULT_DAYS = 180;

  async function prune() {
    try {
      const r = await db.queryOne(
        `SELECT "configValue" FROM "WorkerConfig" WHERE "configKey" = $1`,
        ['HISTORY_RETENTION_DAYS']
      );
      const days = r ? parseInt(r.configValue, 10) : DEFAULT_DAYS;
      if (days <= 0) return; // disabled
      const del = await db.query(
        `DELETE FROM "_history" WHERE "changedAt" < now() - ($1::int * interval '1 day')`,
        [days]
      );
      if (del.rowCount > 0) {
        console.log(`History prune: deleted ${del.rowCount} row(s) older than ${days} days`);
      }
    } catch (err) {
      console.error('History prune failed (will retry next interval):', err.message);
    }
  }

  setTimeout(prune, FIRST_RUN_DELAY_MS);
  setInterval(prune, PRUNE_INTERVAL_MS);
}

export async function bootstrapWorker() {
  if (process.env.USE_SQL !== 'true') return;
  try {
    const pool = await db.getPool();
    await runMigrations(pool);
    await ensureBuiltinCrawler();
    startHistoryPruneJob();
    console.log('Bootstrap complete');
  } catch (err) {
    console.error('Bootstrap failed (will retry on next request):', err.message);
  }
}
