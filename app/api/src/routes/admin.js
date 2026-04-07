import { Router } from 'express';
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import http from 'http';
import * as db from '../db/connection.js';

const __dirname = dirname(fileURLToPath(import.meta.url));

// Universal classifiers bundled with the module (same file Invoke-FGRiskScoring falls back to)
let _universalClassifiers = null;
function getUniversalClassifiers() {
  if (!_universalClassifiers) {
    try {
      const p = join(__dirname, '../risk/classifiers/universal.json');
      _universalClassifiers = JSON.parse(readFileSync(p, 'utf-8'));
    } catch { _universalClassifiers = null; }
  }
  return _universalClassifiers;
}

// Hardcoded resource-type multiplier defaults (mirrors Invoke-FGRiskScoring defaults)
const DEFAULT_MULTIPLIERS = {
  EntraGroup:         1.0,
  EntraDirectoryRole: 1.5,
  EntraAppRole:       1.2,
  AzureRBACRole:      1.4,
  SharePointSite:     0.8,
  DevOpsPermission:   1.1,
  FileShare:          0.7,
};
const DEFAULT_PROPAGATION = {
  EntraDirectoryRole: 0.40,
  EntraAppRole:       0.35,
  EntraGroup:         0.30,
};

const router = Router();
const useSql = process.env.USE_SQL === 'true';

// ── Helpers ──────────────────────────────────────────────────────

async function tableExists(pool, tableName) {
  // Use OBJECT_ID — more reliable than INFORMATION_SCHEMA for temporal tables
  const r = await pool.request().query(
    `SELECT OBJECT_ID('dbo.${tableName}', 'U') AS oid`
  );
  return r.recordset[0].oid !== null;
}

function safeParseJson(str) {
  try { return str ? JSON.parse(str) : null; } catch { return null; }
}

// ── GET /api/admin/risk-profile ───────────────────────────────────
// Returns the most recently saved risk profile from GraphRiskProfiles.
router.get('/admin/risk-profile', async (req, res) => {
  if (!useSql) return res.json({ available: false });

  try {
    const pool = await db.getPool();
    if (!await tableExists(pool, 'GraphRiskProfiles')) {
      return res.json({ available: true, source: 'defaults', multipliers: DEFAULT_MULTIPLIERS, propagation: DEFAULT_PROPAGATION });
    }

    const r = await pool.request().query(`
      SELECT TOP 1 id, domain, industry, country, llmProvider, generatedAt, profileJson
      FROM dbo.GraphRiskProfiles
      ORDER BY generatedAt DESC
    `);

    if (r.recordset.length === 0) {
      return res.json({ available: true, source: 'defaults', multipliers: DEFAULT_MULTIPLIERS, propagation: DEFAULT_PROPAGATION });
    }

    const row = r.recordset[0];
    res.json({
      available: true,
      source: 'sql',
      id: row.id,
      domain: row.domain,
      industry: row.industry,
      country: row.country,
      llmProvider: row.llmProvider,
      generatedAt: row.generatedAt,
      profile: safeParseJson(row.profileJson),
    });
  } catch (err) {
    console.error('Error fetching risk profile:', err.message);
    res.status(500).json({ error: 'Failed to load risk profile' });
  }
});

// ── GET /api/admin/classifiers ────────────────────────────────────
// Returns the most recently saved classifier ruleset from GraphRiskClassifiers.
// Falls back to the universal classifiers bundled with the module (same fallback
// that Invoke-FGRiskScoring uses when no custom classifiers are saved).
router.get('/admin/classifiers', async (req, res) => {
  if (!useSql) {
    const uc = getUniversalClassifiers();
    if (uc) return res.json({ available: true, source: 'universal', classifiers: uc });
    return res.json({ available: false });
  }

  try {
    const pool = await db.getPool();
    if (await tableExists(pool, 'GraphRiskClassifiers')) {
      const r = await pool.request().query(`
        SELECT TOP 1 id, version, customer, generatedAt, llmProvider, classifierJson
        FROM dbo.GraphRiskClassifiers
        ORDER BY generatedAt DESC
      `);
      if (r.recordset.length > 0) {
        const row = r.recordset[0];
        return res.json({
          available: true,
          source: 'sql',
          id: row.id,
          version: row.version,
          customer: row.customer,
          generatedAt: row.generatedAt,
          llmProvider: row.llmProvider,
          classifiers: safeParseJson(row.classifierJson),
        });
      }
    }

    // Fall back to universal classifiers (what Invoke-FGRiskScoring used)
    const uc = getUniversalClassifiers();
    if (uc) return res.json({ available: true, source: 'universal', classifiers: uc });
    return res.json({ available: false });
  } catch (err) {
    console.error('Error fetching classifiers:', err.message);
    res.status(500).json({ error: 'Failed to load classifiers' });
  }
});

// ── GET /api/admin/correlation-ruleset ───────────────────────────
// Returns the most recently saved correlation ruleset from GraphCorrelationRulesets.
router.get('/admin/correlation-ruleset', async (req, res) => {
  if (!useSql) return res.json({ available: false });

  try {
    const pool = await db.getPool();
    if (!await tableExists(pool, 'GraphCorrelationRulesets')) {
      return res.json({ available: false });
    }

    const r = await pool.request().query(`
      SELECT TOP 1 id, version, generatedAt, rulesetJson
      FROM dbo.GraphCorrelationRulesets
      ORDER BY generatedAt DESC
    `);

    if (r.recordset.length === 0) return res.json({ available: false });

    const row = r.recordset[0];
    res.json({
      available: true,
      id: row.id,
      version: row.version,
      generatedAt: row.generatedAt,
      ruleset: safeParseJson(row.rulesetJson),
    });
  } catch (err) {
    console.error('Error fetching correlation ruleset:', err.message);
    res.status(500).json({ error: 'Failed to load correlation ruleset' });
  }
});

// ── GET /api/admin/export/curated ────────────────────────────────
// Exports tags (with assignments) and categories (with AP assignments) to JSON.
// Compatible with the PowerShell Export-FGCuratedData / Import-FGCuratedData format.
router.get('/admin/export/curated', async (req, res) => {
  if (!useSql) return res.status(400).json({ error: 'SQL mode required' });

  try {
    const pool = await db.getPool();

    // ── Tags + assignments ────────────────────────────────────────
    let tags = [];
    if (await tableExists(pool, 'GraphTags')) {
      // Detect which tables exist for display-name resolution
      const hasPrincipals = await tableExists(pool, 'Principals');
      const hasResources  = await tableExists(pool, 'Resources');

      const userJoin = hasPrincipals
        ? `LEFT JOIN dbo.Principals       gu  ON t.entityType = 'user'
             AND gu.id = TRY_CAST(ta.entityId AS UNIQUEIDENTIFIER)
             AND gu.ValidTo = '9999-12-31 23:59:59.9999999'`
        : `LEFT JOIN dbo.GraphUsers        gu  ON t.entityType = 'user'
             AND gu.id = TRY_CAST(ta.entityId AS UNIQUEIDENTIFIER)`;

      const resourceJoin = hasResources
        ? `LEFT JOIN dbo.Resources          r   ON t.entityType IN ('resource','group')
             AND r.id = TRY_CAST(ta.entityId AS UNIQUEIDENTIFIER)
             AND r.ValidTo = '9999-12-31 23:59:59.9999999'`
        : `LEFT JOIN dbo.GraphGroups        r   ON t.entityType IN ('group','resource')
             AND r.id = TRY_CAST(ta.entityId AS UNIQUEIDENTIFIER)`;

      const tagRows = await pool.request().query(`
        SELECT t.id, t.name, t.color, t.entityType,
               ta.entityId,
               COALESCE(gu.displayName, r.displayName) AS entityDisplayName,
               ${hasResources ? 'r.resourceType' : 'NULL'} AS resourceType
        FROM dbo.GraphTags t
        LEFT JOIN dbo.GraphTagAssignments ta ON ta.tagId = t.id
        ${userJoin}
        ${resourceJoin}
        ORDER BY t.entityType, t.name, ta.entityId
      `);

      // Group into tag objects
      const byId = new Map();
      for (const row of tagRows.recordset) {
        const key = String(row.id);
        if (!byId.has(key)) {
          byId.set(key, { name: row.name, color: row.color, entityType: row.entityType, assignments: [] });
        }
        if (row.entityId) {
          byId.get(key).assignments.push({
            entityId:    row.entityId,
            displayName: row.entityDisplayName || null,
            resourceType: row.resourceType || null,
          });
        }
      }
      tags = Array.from(byId.values());
    }

    // ── Categories + AP assignments ───────────────────────────────
    let categories = [];
    if (await tableExists(pool, 'GovernanceCategories')) {
      const catRows = await pool.request().query(`
        SELECT c.id, c.name, c.color, ca.resourceId, ap.displayName AS businessRoleDisplayName
        FROM dbo.GovernanceCategories c
        LEFT JOIN dbo.GovernanceCategoryAssignments ca ON ca.categoryId = c.id
        LEFT JOIN dbo.Resources ap
          ON LOWER(ap.id) = ca.resourceId
          AND ap.resourceType = 'BusinessRole'
          AND ap.ValidTo = '9999-12-31 23:59:59.9999999'
        ORDER BY c.name, ca.resourceId
      `);

      const byCatId = new Map();
      for (const row of catRows.recordset) {
        const key = String(row.id);
        if (!byCatId.has(key)) {
          byCatId.set(key, { name: row.name, color: row.color, assignments: [] });
        }
        if (row.resourceId) {
          byCatId.get(key).assignments.push({
            accessPackageId:          row.resourceId,
            accessPackageDisplayName: row.businessRoleDisplayName || null,
          });
        }
      }
      categories = Array.from(byCatId.values());
    }

    const payload = {
      exportedAt:       new Date().toISOString(),
      version:          '1.0',
      tags,
      categories,
      analystOverrides: [],   // not managed via UI — exported by PowerShell only
    };

    res.setHeader('Content-Disposition', `attachment; filename="FGCuratedData_${new Date().toISOString().slice(0,10)}.json"`);
    res.setHeader('Content-Type', 'application/json');
    res.send(JSON.stringify(payload, null, 2));
  } catch (err) {
    console.error('Export curated data failed:', err.message);
    res.status(500).json({ error: 'Export failed' });
  }
});

// ── POST /api/admin/import/curated ───────────────────────────────
// Imports tags and categories from a JSON file (same format as export).
// Strategy per assignment:
//   1. GUID match — look up entityId / accessPackageId directly.
//   2. Soft-match — if GUID not found, search by displayName
//      (+ resourceType for group/resource entities).
// Skips assignments whose entity cannot be resolved in either way.
router.post('/admin/import/curated', async (req, res) => {
  if (!useSql) return res.status(400).json({ error: 'SQL mode required' });

  const { tags = [], categories = [] } = req.body;
  if (!Array.isArray(tags) || !Array.isArray(categories)) {
    return res.status(400).json({ error: 'tags and categories must be arrays' });
  }

  const HEX_COLOR_RE = /^#[0-9a-fA-F]{6}$/;
  const stats = {
    tagsInserted: 0, tagsSkipped: 0,
    assignmentsInserted: 0, assignmentsSkipped: 0,
    assignmentsSoftMatched: 0, assignmentsNotFound: 0,
    catsInserted: 0, catsSkipped: 0,
    catAssignInserted: 0, catAssignSkipped: 0,
    catAssignSoftMatched: 0, catAssignNotFound: 0,
  };

  try {
    const pool = await db.getPool();

    // Ensure tag + category tables exist
    const { ensureTagTables }      = await import('./tags.js');
    const { ensureCategoryTables } = await import('./categories.js');
    await ensureTagTables(pool);
    await ensureCategoryTables(pool);

    // Detect available tables for entity resolution
    const hasPrincipals = await tableExists(pool, 'Principals');
    const hasResources  = await tableExists(pool, 'Resources');

    // ── Helper: resolve entity GUID ──────────────────────────────
    async function resolveEntity(entityId, entityType, displayName, resourceType) {
      // 1. GUID match — check if the entity still exists with this ID
      let exists = false;
      try {
        if (entityType === 'user') {
          const tbl = hasPrincipals ? 'Principals' : 'GraphUsers';
          const vtFilter = hasPrincipals ? `AND ValidTo = '9999-12-31 23:59:59.9999999'` : '';
          const r = await pool.request()
            .input('id', entityId)
            .query(`SELECT COUNT(*) AS n FROM dbo.${tbl} WHERE UPPER(CAST(id AS NVARCHAR(36))) = UPPER(@id) ${vtFilter}`);
          exists = r.recordset[0].n > 0;
        } else {
          const tbl = hasResources ? 'Resources' : 'GraphGroups';
          const vtFilter = hasResources ? `AND ValidTo = '9999-12-31 23:59:59.9999999'` : '';
          const r = await pool.request()
            .input('id', entityId)
            .query(`SELECT COUNT(*) AS n FROM dbo.${tbl} WHERE UPPER(CAST(id AS NVARCHAR(36))) = UPPER(@id) ${vtFilter}`);
          exists = r.recordset[0].n > 0;
        }
      } catch { /* table might not exist */ }

      if (exists) return { id: entityId.toUpperCase(), softMatched: false };

      // 2. Soft-match by displayName (+ resourceType for resources/groups)
      if (!displayName) return null;
      try {
        if (entityType === 'user') {
          const tbl = hasPrincipals ? 'Principals' : 'GraphUsers';
          const vtFilter = hasPrincipals ? `AND ValidTo = '9999-12-31 23:59:59.9999999'` : '';
          const r = await pool.request()
            .input('displayName', displayName)
            .query(`SELECT TOP 1 UPPER(CAST(id AS NVARCHAR(36))) AS id FROM dbo.${tbl}
                    WHERE displayName = @displayName ${vtFilter}`);
          if (r.recordset.length > 0) return { id: r.recordset[0].id, softMatched: true };
        } else {
          // group / resource — match on displayName + resourceType if available
          const tbl = hasResources ? 'Resources' : 'GraphGroups';
          const vtFilter = hasResources ? `AND ValidTo = '9999-12-31 23:59:59.9999999'` : '';
          let req2 = pool.request().input('displayName', displayName);
          let rtClause = '';
          if (resourceType && hasResources) {
            req2 = req2.input('resourceType', resourceType);
            rtClause = 'AND resourceType = @resourceType';
          }
          const r = await req2.query(
            `SELECT TOP 1 UPPER(CAST(id AS NVARCHAR(36))) AS id FROM dbo.${tbl}
             WHERE displayName = @displayName ${rtClause} ${vtFilter}`
          );
          if (r.recordset.length > 0) return { id: r.recordset[0].id, softMatched: true };
        }
      } catch { /* ignore */ }

      return null; // not found
    }

    // ── Tags ─────────────────────────────────────────────────────
    for (const tag of tags) {
      if (!tag.name || !tag.entityType) continue;
      const color = HEX_COLOR_RE.test(tag.color || '') ? tag.color : '#3b82f6';

      // Upsert tag (name + entityType is unique)
      const tagResult = await pool.request()
        .input('name', String(tag.name).slice(0, 100))
        .input('color', color)
        .input('entityType', tag.entityType)
        .query(`
          MERGE dbo.GraphTags AS target
          USING (SELECT @name AS name, @entityType AS entityType) AS source
          ON target.name = source.name AND target.entityType = source.entityType
          WHEN NOT MATCHED THEN
            INSERT (name, color, entityType) VALUES (@name, @color, @entityType);
          SELECT id FROM dbo.GraphTags WHERE name = @name AND entityType = @entityType;
        `);

      const tagId = tagResult.recordset[0]?.id;
      if (!tagId) continue;

      // Track inserted vs skipped (tag itself)
      // A simple check: re-query to see if it was just created
      // (MERGE OUTPUT would be cleaner but mssql handles OUTPUT differently)
      const tagCheck = await pool.request()
        .input('name', String(tag.name).slice(0, 100))
        .input('entityType', tag.entityType)
        .query(`SELECT createdAt FROM dbo.GraphTags WHERE name = @name AND entityType = @entityType`);

      // We can't distinguish insert vs update in the MERGE without OUTPUT.
      // Count assignments instead — always bump tagsSkipped if already existed.
      // Track tag inserts via a secondary check.
      const wasNew = await pool.request()
        .input('tagId', tagId)
        .query(`SELECT COUNT(*) AS n FROM dbo.GraphTagAssignments WHERE tagId = @tagId`);
      if (wasNew.recordset[0].n === 0 && (!tag.assignments || tag.assignments.length === 0)) {
        stats.tagsInserted++;
      } else {
        stats.tagsSkipped++;
      }

      for (const a of (tag.assignments || [])) {
        if (!a.entityId) continue;
        const resolved = await resolveEntity(a.entityId, tag.entityType, a.displayName, a.resourceType);
        if (!resolved) { stats.assignmentsNotFound++; continue; }

        // Insert assignment if not already there
        const r = await pool.request()
          .input('tagId', tagId)
          .input('entityId', resolved.id)
          .query(`
            IF NOT EXISTS (SELECT 1 FROM dbo.GraphTagAssignments WHERE tagId = @tagId AND entityId = @entityId)
            BEGIN
              INSERT INTO dbo.GraphTagAssignments (tagId, entityId) VALUES (@tagId, @entityId);
              SELECT 1 AS inserted;
            END ELSE SELECT 0 AS inserted;
          `);

        const inserted = r.recordset[0]?.inserted === 1;
        if (inserted) {
          stats.assignmentsInserted++;
          if (resolved.softMatched) stats.assignmentsSoftMatched++;
        } else {
          stats.assignmentsSkipped++;
        }
      }
    }

    // ── Categories ───────────────────────────────────────────────
    for (const cat of categories) {
      if (!cat.name) continue;
      const color = HEX_COLOR_RE.test(cat.color || '') ? cat.color : '#3b82f6';

      // Upsert category (name is unique)
      await pool.request()
        .input('name', String(cat.name).slice(0, 100))
        .input('color', color)
        .query(`
          MERGE dbo.GovernanceCategories AS target
          USING (SELECT @name AS name) AS source ON target.name = source.name
          WHEN NOT MATCHED THEN INSERT (name, color) VALUES (@name, @color);
        `);

      const catResult = await pool.request()
        .input('name', String(cat.name).slice(0, 100))
        .query(`SELECT id FROM dbo.GovernanceCategories WHERE name = @name`);
      const catId = catResult.recordset[0]?.id;
      if (!catId) continue;
      stats.catsInserted++; // simplified: count all as processed

      for (const a of (cat.assignments || [])) {
        if (!a.accessPackageId) continue;

        // 1. GUID match
        let apId = null;
        try {
          const r = await pool.request()
            .input('apId', a.accessPackageId.toLowerCase())
            .query(`SELECT TOP 1 LOWER(CAST(id AS NVARCHAR(36))) AS id
                    FROM dbo.Resources
                    WHERE LOWER(CAST(id AS NVARCHAR(36))) = @apId
                      AND resourceType = 'BusinessRole'
                      AND ValidTo = '9999-12-31 23:59:59.9999999'`);
          if (r.recordset.length > 0) apId = r.recordset[0].id;
        } catch { /* ignore */ }

        let softMatched = false;
        // 2. Soft-match by displayName
        if (!apId && a.accessPackageDisplayName) {
          try {
            const r = await pool.request()
              .input('displayName', a.accessPackageDisplayName)
              .query(`SELECT TOP 1 LOWER(CAST(id AS NVARCHAR(36))) AS id
                      FROM dbo.Resources
                      WHERE displayName = @displayName
                        AND resourceType = 'BusinessRole'
                        AND ValidTo = '9999-12-31 23:59:59.9999999'`);
            if (r.recordset.length > 0) { apId = r.recordset[0].id; softMatched = true; }
          } catch { /* ignore */ }
        }

        if (!apId) { stats.catAssignNotFound++; continue; }

        // Insert or skip (AP can only have one category — MERGE replaces)
        const existing = await pool.request()
          .input('apId', apId)
          .query(`SELECT categoryId FROM dbo.GovernanceCategoryAssignments WHERE resourceId = @apId`);

        if (existing.recordset.length > 0) {
          stats.catAssignSkipped++;
        } else {
          await pool.request()
            .input('catId', catId)
            .input('apId', apId)
            .query(`INSERT INTO dbo.GovernanceCategoryAssignments (resourceId, categoryId) VALUES (@apId, @catId)`);
          stats.catAssignInserted++;
          if (softMatched) stats.catAssignSoftMatched++;
        }
      }
    }

    res.json({ ok: true, stats });
  } catch (err) {
    console.error('Import curated data failed:', err.message);
    res.status(500).json({ error: 'Import failed' });
  }
});

// ─── Clean Database — wipes all identity data, keeps configs ─────────────────
//
// Deletes all rows from data tables (Principals, Resources, Identities, etc.)
// but preserves crawler configs, risk profiles, and audit log so the user can
// re-sync from a clean slate without losing their setup.
router.post('/admin/clean-database', async (req, res) => {
  if (process.env.USE_SQL !== 'true') return res.status(503).json({ error: 'SQL not configured' });

  // Tables to wipe (data only — configs/profiles/audit preserved)
  // Listed in dependency order: child tables first to avoid FK issues
  const TABLES_TO_WIPE = [
    // Identity correlation
    'IdentityMembers', 'Identities',
    // Resource graph
    'ResourceAssignments', 'ResourceRelationships',
    'AssignmentRequests', 'AssignmentPolicies', 'CertificationDecisions',
    'Resources',
    // Principals, contexts, systems
    'Principals', 'Contexts', 'OrgUnits',
    // Governance + risk artifacts
    'GovernanceCatalogs', 'RiskScores',
    // Systems is wiped LAST so any FK references from above are gone first
    'Systems',
    // Crawler runtime artifacts (jobs, sync log) — but NOT configs
    'CrawlerJobs', 'SyncLog', 'GraphSyncLog',
    // Legacy tables
    'GraphGroupMembers', 'GraphGroupOwners', 'GraphGroups', 'GraphUsers',
  ];

  try {
    const pool = await db.getPool();
    const wiped = [];
    const skipped = [];

    for (const table of TABLES_TO_WIPE) {
      try {
        // Check if table exists
        const check = await pool.request().input('t', table)
          .query(`SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = @t AND TABLE_SCHEMA = 'dbo'`);
        if (check.recordset.length === 0) {
          skipped.push({ table, reason: 'does not exist' });
          continue;
        }

        // Detect temporal table (system-versioned) — must disable versioning before DELETE
        const tempCheck = await pool.request().input('t', table)
          .query(`SELECT temporal_type FROM sys.tables WHERE name = @t AND schema_id = SCHEMA_ID('dbo')`);
        const isTemporal = tempCheck.recordset[0]?.temporal_type === 2;

        if (isTemporal) {
          // Disable versioning, delete from main + history, re-enable
          await pool.request().query(`ALTER TABLE dbo.[${table}] SET (SYSTEM_VERSIONING = OFF)`);
          const delMain = await pool.request().query(`DELETE FROM dbo.[${table}]`);
          // Try to find and clear the history table
          try {
            const histRes = await pool.request().input('t', table)
              .query(`SELECT name FROM sys.tables WHERE object_id = (SELECT history_table_id FROM sys.tables WHERE name = @t AND schema_id = SCHEMA_ID('dbo'))`);
            const histName = histRes.recordset[0]?.name;
            if (histName) {
              await pool.request().query(`DELETE FROM dbo.[${histName}]`);
            }
          } catch {}
          // Re-enable versioning
          try {
            const histRes2 = await pool.request().input('t', table)
              .query(`SELECT name FROM sys.tables WHERE name = @t + 'History' AND schema_id = SCHEMA_ID('dbo')`);
            const histName = histRes2.recordset[0]?.name;
            if (histName) {
              await pool.request().query(`ALTER TABLE dbo.[${table}] SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.[${histName}]))`);
            }
          } catch {}
          wiped.push({ table, rowsAffected: delMain.rowsAffected[0], temporal: true });
        } else {
          const result = await pool.request().query(`DELETE FROM dbo.[${table}]`);
          wiped.push({ table, rowsAffected: result.rowsAffected[0], temporal: false });
        }
      } catch (err) {
        skipped.push({ table, reason: err.message });
      }
    }

    // Reset lastRunAt on crawler configs so the UI shows them as "never run"
    try {
      await pool.request().query(`UPDATE dbo.CrawlerConfigs SET lastRunAt = NULL, lastRunStatus = NULL`);
    } catch {}

    res.json({ message: 'Database cleaned', wiped, skipped });
  } catch (err) {
    console.error('Clean database failed:', err.message);
    res.status(500).json({ error: 'Clean database failed: ' + err.message });
  }
});

// ─── Feature flag toggle (persisted in WorkerConfig) ─────────────────────────
// POST /api/admin/features/toggle  body: { feature: 'riskScoring'|'accountCorrelation', enabled: boolean }
//
// Stores the override in WorkerConfig as FEATURE_<UPPER_SNAKE>. The /api/features
// endpoint reads this and overrides the matching env var. Survives container restarts.
router.post('/admin/features/toggle', async (req, res) => {
  if (process.env.USE_SQL !== 'true') return res.status(503).json({ error: 'SQL not configured' });
  const { feature, enabled } = req.body || {};
  const VALID = { riskScoring: 'FEATURE_RISK_SCORING', accountCorrelation: 'FEATURE_ACCOUNT_CORRELATION' };
  const key = VALID[feature];
  if (!key) return res.status(400).json({ error: `feature must be one of: ${Object.keys(VALID).join(', ')}` });
  if (typeof enabled !== 'boolean') return res.status(400).json({ error: 'enabled must be boolean' });

  try {
    const pool = await db.getPool();
    await pool.request()
      .input('k', key)
      .input('v', enabled ? 'true' : 'false')
      .query(`MERGE dbo.WorkerConfig AS t
              USING (SELECT @k AS configKey) AS s ON t.configKey = s.configKey
              WHEN MATCHED THEN UPDATE SET configValue = @v, updatedAt = SYSUTCDATETIME()
              WHEN NOT MATCHED THEN INSERT (configKey, configValue) VALUES (@k, @v);`);
    res.json({ feature, enabled });
  } catch (err) {
    console.error('Feature toggle failed:', err.message);
    res.status(500).json({ error: 'Feature toggle failed' });
  }
});

// ─── Container stats (Docker socket) ─────────────────────────────────────────
const DOCKER_SOCKET = process.env.DOCKER_SOCKET || '/var/run/docker.sock';

function dockerRequest(path) {
  return new Promise((resolve, reject) => {
    const req = http.request({ socketPath: DOCKER_SOCKET, path, method: 'GET' }, (res) => {
      let body = '';
      res.on('data', (c) => { body += c; });
      res.on('end', () => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          try { resolve(JSON.parse(body)); } catch (e) { reject(e); }
        } else {
          reject(new Error(`Docker API ${res.statusCode}`));
        }
      });
    });
    req.on('error', reject);
    req.setTimeout(5000, () => { req.destroy(new Error('Docker API timeout')); });
    req.end();
  });
}

function calcCpuPercent(stats) {
  const cpu = stats.cpu_stats || {};
  const pre = stats.precpu_stats || {};
  const cpuDelta = (cpu.cpu_usage?.total_usage || 0) - (pre.cpu_usage?.total_usage || 0);
  const sysDelta = (cpu.system_cpu_usage || 0) - (pre.system_cpu_usage || 0);
  const cores = cpu.online_cpus || cpu.cpu_usage?.percpu_usage?.length || 1;
  if (sysDelta > 0 && cpuDelta > 0) return (cpuDelta / sysDelta) * cores * 100;
  return 0;
}

function sumNet(stats) {
  const nets = stats.networks || {};
  let rx = 0, tx = 0;
  for (const k of Object.keys(nets)) { rx += nets[k].rx_bytes || 0; tx += nets[k].tx_bytes || 0; }
  return { rx, tx };
}

router.get('/admin/container-stats', async (req, res) => {
  try {
    const containers = await dockerRequest('/containers/json?all=0');
    const wanted = containers.filter(c => {
      const names = (c.Names || []).map(n => n.replace(/^\//, ''));
      return names.some(n => /fortigigraph[-_](sql|web|worker)/i.test(n));
    });

    const results = await Promise.all(wanted.map(async (c) => {
      const name = (c.Names[0] || '').replace(/^\//, '');
      const service = (name.match(/(sql|web|worker)/i) || [])[1]?.toLowerCase() || name;
      try {
        const stats = await dockerRequest(`/containers/${c.Id}/stats?stream=false`);
        const memUsage = stats.memory_stats?.usage || 0;
        const memLimit = stats.memory_stats?.limit || 0;
        const net = sumNet(stats);
        return {
          name, service,
          state: c.State,
          status: c.Status,
          cpuPercent: calcCpuPercent(stats),
          memUsageBytes: memUsage,
          memLimitBytes: memLimit,
          memPercent: memLimit > 0 ? (memUsage / memLimit) * 100 : 0,
          netRxBytes: net.rx,
          netTxBytes: net.tx,
          pids: stats.pids_stats?.current || 0,
        };
      } catch (err) {
        return { name, service, state: c.State, status: c.Status, error: err.message };
      }
    }));

    const order = { web: 0, worker: 1, sql: 2 };
    results.sort((a, b) => (order[a.service] ?? 99) - (order[b.service] ?? 99));
    res.json({ containers: results, timestamp: new Date().toISOString() });
  } catch (err) {
    res.status(500).json({ error: err.message, hint: 'Mount /var/run/docker.sock into the web container.' });
  }
});

export default router;
