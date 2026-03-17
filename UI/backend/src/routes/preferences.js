import { Router } from 'express';
import * as db from '../db/connection.js';

const router = Router();
const useSql = process.env.USE_SQL === 'true';

// Optional tabs that can be toggled. Default = hidden.
const OPTIONAL_TABS = ['risk-scores', 'identities', 'org-chart', 'performance'];

let tableEnsured = false;

async function ensurePreferencesTable(pool) {
  if (tableEnsured) return;
  try {
    await pool.request().query(`
      IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'GraphUserPreferences')
      BEGIN
        CREATE TABLE dbo.GraphUserPreferences (
          userId        NVARCHAR(255)  NOT NULL PRIMARY KEY,
          displayName   NVARCHAR(255)  NULL,
          email         NVARCHAR(255)  NULL,
          visibleTabs   NVARCHAR(MAX)  NULL,
          updatedAt     DATETIME2      NOT NULL DEFAULT SYSUTCDATETIME()
        );
      END
    `);
    tableEnsured = true;
  } catch (err) {
    console.error('Failed to ensure preferences table:', err.message);
  }
}

function getUserId(req) {
  // Entra ID JWT: oid = user object ID, preferred_username = email/UPN
  if (req.user?.oid) return req.user.oid;
  // Fallback for no-auth mode: use a default user
  return 'anonymous';
}

function getUserInfo(req) {
  return {
    displayName: req.user?.name || req.user?.preferred_username || null,
    email: req.user?.preferred_username || req.user?.upn || null,
  };
}

// ────────────────────────────────────────────────────────────────
// GET /api/preferences — Get current user's tab preferences
// ────────────────────────────────────────────────────────────────
router.get('/preferences', async (req, res) => {
  // Default: all optional tabs hidden
  const defaults = { visibleTabs: [] };

  if (!useSql) return res.json(defaults);

  try {
    const pool = await db.getPool();
    await ensurePreferencesTable(pool);

    const userId = getUserId(req);
    const r = await pool.request()
      .input('userId', userId)
      .query('SELECT visibleTabs FROM dbo.GraphUserPreferences WHERE userId = @userId');

    if (r.recordset.length === 0) {
      return res.json(defaults);
    }

    let visibleTabs = [];
    try {
      visibleTabs = JSON.parse(r.recordset[0].visibleTabs || '[]');
    } catch { /* invalid JSON — return defaults */ }

    // Filter to only known optional tabs
    visibleTabs = visibleTabs.filter(t => OPTIONAL_TABS.includes(t));

    res.json({ visibleTabs });
  } catch (err) {
    console.error('Error fetching preferences:', err.message);
    res.json(defaults);
  }
});

// ────────────────────────────────────────────────────────────────
// PUT /api/preferences — Update current user's tab preferences
// ────────────────────────────────────────────────────────────────
router.put('/preferences', async (req, res) => {
  if (!useSql) return res.json({ ok: true });

  try {
    const pool = await db.getPool();
    await ensurePreferencesTable(pool);

    const userId = getUserId(req);
    const { displayName, email } = getUserInfo(req);

    // Validate input: only accept known tab keys
    let visibleTabs = req.body.visibleTabs;
    if (!Array.isArray(visibleTabs)) {
      return res.status(400).json({ error: 'visibleTabs must be an array' });
    }
    visibleTabs = visibleTabs.filter(t => OPTIONAL_TABS.includes(t));
    const tabsJson = JSON.stringify(visibleTabs);

    // Upsert (MERGE)
    await pool.request()
      .input('userId', userId)
      .input('displayName', displayName)
      .input('email', email)
      .input('visibleTabs', tabsJson)
      .query(`
        MERGE dbo.GraphUserPreferences AS target
        USING (SELECT @userId AS userId) AS source
        ON target.userId = source.userId
        WHEN MATCHED THEN
          UPDATE SET visibleTabs = @visibleTabs, displayName = @displayName, email = @email, updatedAt = SYSUTCDATETIME()
        WHEN NOT MATCHED THEN
          INSERT (userId, displayName, email, visibleTabs, updatedAt)
          VALUES (@userId, @displayName, @email, @visibleTabs, SYSUTCDATETIME());
      `);

    res.json({ ok: true, visibleTabs });
  } catch (err) {
    console.error('Error saving preferences:', err.message);
    res.status(500).json({ error: 'Failed to save preferences' });
  }
});

export { OPTIONAL_TABS };
export default router;
