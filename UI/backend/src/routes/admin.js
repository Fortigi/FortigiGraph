import { Router } from 'express';
import { ensureTagTables } from './tags.js';
import { ensureCategoryTables } from './categories.js';

const router = Router();
const useSql = process.env.USE_SQL === 'true';

let db = null;
if (useSql) {
  db = await import('../db/connection.js');
}

// Safe identifier regex — only allow alphanumeric + underscore
const SAFE_IDENT_RE = /^[a-zA-Z_][a-zA-Z0-9_]*$/;

// Helper: check if a table exists
// OBJECT_ID() needs a literal, so we validate with SAFE_IDENT_RE and interpolate safely
async function tableExists(pool, tableName) {
  if (!SAFE_IDENT_RE.test(tableName)) return false;
  const result = await pool.request()
    .query(`SELECT OBJECT_ID('dbo.${tableName}', 'U') AS oid`);
  return result.recordset[0].oid != null;
}

// Helper: check if a column exists on a table
async function columnExists(pool, tableName, columnName) {
  if (!SAFE_IDENT_RE.test(tableName) || !SAFE_IDENT_RE.test(columnName)) return false;
  const result = await pool.request()
    .query(`
      SELECT 1 AS found FROM INFORMATION_SCHEMA.COLUMNS
      WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = '${tableName}' AND COLUMN_NAME = '${columnName}'
    `);
  return result.recordset.length > 0;
}

// ─── GET /api/admin/export ──────────────────────────────────────
// Exports all manually-added data as a single JSON bundle
router.get('/admin/export', async (req, res) => {
  try {
    if (!useSql) return res.json({ error: 'SQL not configured' });
    const p = await db.getPool();

    const exportData = {
      exportedAt: new Date().toISOString(),
      version: '1.0',
      tags: [],
      tagAssignments: [],
      categories: [],
      categoryAssignments: [],
      riskOverrides: { users: [], groups: [] },
      identityVerifications: [],
      identityMemberOverrides: [],
      clusterOwners: [],
    };

    // ── Tags & Tag Assignments ───────────────────────────────────
    if (await tableExists(p, 'GraphTags')) {
      const tags = await p.request().query(
        `SELECT id, name, color, entityType FROM dbo.GraphTags ORDER BY id`
      );
      exportData.tags = tags.recordset;

      if (await tableExists(p, 'GraphTagAssignments')) {
        const tagAssignments = await p.request().query(
          `SELECT ta.tagId, t.name AS tagName, t.entityType, ta.entityId
           FROM dbo.GraphTagAssignments ta
           JOIN dbo.GraphTags t ON t.id = ta.tagId
           ORDER BY ta.tagId, ta.entityId`
        );
        exportData.tagAssignments = tagAssignments.recordset;
      }
    }

    // ── Categories & Category Assignments ────────────────────────
    if (await tableExists(p, 'GraphCategories')) {
      const cats = await p.request().query(
        `SELECT id, name, color FROM dbo.GraphCategories ORDER BY id`
      );
      exportData.categories = cats.recordset;

      if (await tableExists(p, 'GraphCategoryAssignments')) {
        const catAssignments = await p.request().query(
          `SELECT ca.accessPackageId, c.name AS categoryName
           FROM dbo.GraphCategoryAssignments ca
           JOIN dbo.GraphCategories c ON c.id = ca.categoryId
           ORDER BY c.name, ca.accessPackageId`
        );
        exportData.categoryAssignments = catAssignments.recordset;
      }
    }

    // ── Risk Overrides (users & groups) ──────────────────────────
    if (await tableExists(p, 'GraphUsers') && await columnExists(p, 'GraphUsers', 'riskOverride')) {
      const userOverrides = await p.request().query(
        `SELECT id, displayName, userPrincipalName, riskOverride, riskOverrideReason
         FROM dbo.GraphUsers WHERE riskOverride IS NOT NULL`
      );
      exportData.riskOverrides.users = userOverrides.recordset;
    }

    if (await tableExists(p, 'GraphGroups') && await columnExists(p, 'GraphGroups', 'riskOverride')) {
      const groupOverrides = await p.request().query(
        `SELECT id, displayName, riskOverride, riskOverrideReason
         FROM dbo.GraphGroups WHERE riskOverride IS NOT NULL`
      );
      exportData.riskOverrides.groups = groupOverrides.recordset;
    }

    // ── Identity Verifications ───────────────────────────────────
    if (await tableExists(p, 'GraphIdentities') && await columnExists(p, 'GraphIdentities', 'analystVerified')) {
      const identities = await p.request().query(
        `SELECT id, displayName, analystVerified, analystNotes
         FROM dbo.GraphIdentities
         WHERE analystVerified = 1 OR analystNotes IS NOT NULL`
      );
      exportData.identityVerifications = identities.recordset;
    }

    // ── Identity Member Overrides ────────────────────────────────
    if (await tableExists(p, 'GraphIdentityMembers') && await columnExists(p, 'GraphIdentityMembers', 'analystOverride')) {
      const memberOverrides = await p.request().query(
        `SELECT identityId, userId, analystOverride, analystReason
         FROM dbo.GraphIdentityMembers
         WHERE analystOverride IS NOT NULL`
      );
      exportData.identityMemberOverrides = memberOverrides.recordset;
    }

    // ── Cluster Owner Assignments ────────────────────────────────
    if (await tableExists(p, 'GraphResourceClusters') && await columnExists(p, 'GraphResourceClusters', 'ownerUserId')) {
      const clusters = await p.request().query(
        `SELECT id, clusterName, ownerUserId, ownerDisplayName, ownerAssignedBy
         FROM dbo.GraphResourceClusters
         WHERE ownerUserId IS NOT NULL`
      );
      exportData.clusterOwners = clusters.recordset;
    }

    // Set download headers
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-').substring(0, 19);
    res.setHeader('Content-Disposition', `attachment; filename="fortigraph-export-${timestamp}.json"`);
    res.setHeader('Content-Type', 'application/json');
    res.json(exportData);
  } catch (err) {
    console.error('GET /admin/export failed:', err.message);
    res.status(500).json({ error: 'Export failed' });
  }
});

// ─── POST /api/admin/import ─────────────────────────────────────
// Imports previously exported data. Uses name-based matching for
// tags/categories (so IDs don't need to match between environments).
router.post('/admin/import', async (req, res) => {
  try {
    if (!useSql) return res.status(400).json({ error: 'SQL not configured' });
    const data = req.body;
    if (!data || !data.version) {
      return res.status(400).json({ error: 'Invalid export file format' });
    }

    const p = await db.getPool();
    const results = {
      tags: { created: 0, skipped: 0 },
      tagAssignments: { created: 0, skipped: 0 },
      categories: { created: 0, skipped: 0 },
      categoryAssignments: { created: 0, skipped: 0 },
      riskOverrides: { users: 0, groups: 0 },
      identityVerifications: { updated: 0, skipped: 0 },
      identityMemberOverrides: { updated: 0, skipped: 0 },
      clusterOwners: { updated: 0, skipped: 0 },
    };

    // ── Import Tags ──────────────────────────────────────────────
    if (Array.isArray(data.tags) && data.tags.length > 0) {
      await ensureTagTables(p);
      const tagIdMap = {}; // oldId -> newId (for assignment mapping)

      for (const tag of data.tags) {
        if (!tag.name || !tag.entityType) continue;

        // Check if tag with same name+entityType exists
        const existing = await p.request()
          .input('name', tag.name)
          .input('entityType', tag.entityType)
          .query(`SELECT id FROM dbo.GraphTags WHERE name = @name AND entityType = @entityType`);

        if (existing.recordset.length > 0) {
          tagIdMap[tag.id] = existing.recordset[0].id;
          // Update color if different
          await p.request()
            .input('id', existing.recordset[0].id)
            .input('color', tag.color || '#3b82f6')
            .query(`UPDATE dbo.GraphTags SET color = @color WHERE id = @id`);
          results.tags.skipped++;
        } else {
          const inserted = await p.request()
            .input('name', tag.name)
            .input('color', tag.color || '#3b82f6')
            .input('entityType', tag.entityType)
            .query(`INSERT INTO dbo.GraphTags (name, color, entityType) OUTPUT INSERTED.id VALUES (@name, @color, @entityType)`);
          tagIdMap[tag.id] = inserted.recordset[0].id;
          results.tags.created++;
        }
      }

      // Import Tag Assignments
      if (Array.isArray(data.tagAssignments)) {
        for (const ta of data.tagAssignments) {
          if (!ta.entityId) continue;

          // Resolve tag by name+entityType (more reliable than ID mapping)
          let resolvedTagId = null;
          if (ta.tagName && ta.entityType) {
            const resolved = await p.request()
              .input('name', ta.tagName)
              .input('entityType', ta.entityType)
              .query(`SELECT id FROM dbo.GraphTags WHERE name = @name AND entityType = @entityType`);
            if (resolved.recordset.length > 0) resolvedTagId = resolved.recordset[0].id;
          }
          // Fallback to ID mapping
          if (!resolvedTagId && ta.tagId && tagIdMap[ta.tagId]) {
            resolvedTagId = tagIdMap[ta.tagId];
          }
          if (!resolvedTagId) { results.tagAssignments.skipped++; continue; }

          const entityId = ta.entityId.toUpperCase();
          const exists = await p.request()
            .input('tagId', resolvedTagId)
            .input('entityId', entityId)
            .query(`SELECT 1 FROM dbo.GraphTagAssignments WHERE tagId = @tagId AND entityId = @entityId`);
          if (exists.recordset.length > 0) {
            results.tagAssignments.skipped++;
          } else {
            await p.request()
              .input('tagId', resolvedTagId)
              .input('entityId', entityId)
              .query(`INSERT INTO dbo.GraphTagAssignments (tagId, entityId) VALUES (@tagId, @entityId)`);
            results.tagAssignments.created++;
          }
        }
      }
    }

    // ── Import Categories ────────────────────────────────────────
    if (Array.isArray(data.categories) && data.categories.length > 0) {
      await ensureCategoryTables(p);
      const catIdMap = {}; // oldId -> newId

      for (const cat of data.categories) {
        if (!cat.name) continue;

        const existing = await p.request()
          .input('name', cat.name)
          .query(`SELECT id FROM dbo.GraphCategories WHERE name = @name`);

        if (existing.recordset.length > 0) {
          catIdMap[cat.id] = existing.recordset[0].id;
          await p.request()
            .input('id', existing.recordset[0].id)
            .input('color', cat.color || '#3b82f6')
            .query(`UPDATE dbo.GraphCategories SET color = @color WHERE id = @id`);
          results.categories.skipped++;
        } else {
          const inserted = await p.request()
            .input('name', cat.name)
            .input('color', cat.color || '#3b82f6')
            .query(`INSERT INTO dbo.GraphCategories (name, color) OUTPUT INSERTED.id VALUES (@name, @color)`);
          catIdMap[cat.id] = inserted.recordset[0].id;
          results.categories.created++;
        }
      }

      // Import Category Assignments
      if (Array.isArray(data.categoryAssignments)) {
        for (const ca of data.categoryAssignments) {
          if (!ca.accessPackageId) continue;

          // Resolve category by name
          let resolvedCatId = null;
          if (ca.categoryName) {
            const resolved = await p.request()
              .input('name', ca.categoryName)
              .query(`SELECT id FROM dbo.GraphCategories WHERE name = @name`);
            if (resolved.recordset.length > 0) resolvedCatId = resolved.recordset[0].id;
          }
          if (!resolvedCatId && ca.categoryId && catIdMap[ca.categoryId]) {
            resolvedCatId = catIdMap[ca.categoryId];
          }
          if (!resolvedCatId) { results.categoryAssignments.skipped++; continue; }

          // Upsert (one category per AP)
          const exists = await p.request()
            .input('apId', ca.accessPackageId)
            .query(`SELECT 1 FROM dbo.GraphCategoryAssignments WHERE accessPackageId = @apId`);
          if (exists.recordset.length > 0) {
            await p.request()
              .input('apId', ca.accessPackageId)
              .input('catId', resolvedCatId)
              .query(`UPDATE dbo.GraphCategoryAssignments SET categoryId = @catId WHERE accessPackageId = @apId`);
            results.categoryAssignments.skipped++;
          } else {
            await p.request()
              .input('apId', ca.accessPackageId)
              .input('catId', resolvedCatId)
              .query(`INSERT INTO dbo.GraphCategoryAssignments (accessPackageId, categoryId) VALUES (@apId, @catId)`);
            results.categoryAssignments.created++;
          }
        }
      }
    }

    // ── Import Risk Overrides ────────────────────────────────────
    if (data.riskOverrides) {
      if (Array.isArray(data.riskOverrides.users) && data.riskOverrides.users.length > 0) {
        if (await tableExists(p, 'GraphUsers') && await columnExists(p, 'GraphUsers', 'riskOverride')) {
          for (const u of data.riskOverrides.users) {
            if (!u.id || u.riskOverride == null) continue;
            const adjustment = Math.max(-50, Math.min(50, parseInt(u.riskOverride, 10)));
            if (isNaN(adjustment)) continue;
            const reason = (u.riskOverrideReason || '').substring(0, 500);
            await p.request()
              .input('id', u.id)
              .input('adj', adjustment)
              .input('reason', reason || null)
              .query(`UPDATE dbo.GraphUsers SET riskOverride = @adj, riskOverrideReason = @reason WHERE id = @id`);
            results.riskOverrides.users++;
          }
        }
      }
      if (Array.isArray(data.riskOverrides.groups) && data.riskOverrides.groups.length > 0) {
        if (await tableExists(p, 'GraphGroups') && await columnExists(p, 'GraphGroups', 'riskOverride')) {
          for (const g of data.riskOverrides.groups) {
            if (!g.id || g.riskOverride == null) continue;
            const adjustment = Math.max(-50, Math.min(50, parseInt(g.riskOverride, 10)));
            if (isNaN(adjustment)) continue;
            const reason = (g.riskOverrideReason || '').substring(0, 500);
            await p.request()
              .input('id', g.id)
              .input('adj', adjustment)
              .input('reason', reason || null)
              .query(`UPDATE dbo.GraphGroups SET riskOverride = @adj, riskOverrideReason = @reason WHERE id = @id`);
            results.riskOverrides.groups++;
          }
        }
      }
    }

    // ── Import Identity Verifications ────────────────────────────
    if (Array.isArray(data.identityVerifications) && data.identityVerifications.length > 0) {
      if (await tableExists(p, 'GraphIdentities') && await columnExists(p, 'GraphIdentities', 'analystVerified')) {
        for (const iv of data.identityVerifications) {
          if (!iv.id) continue;
          const notes = (iv.analystNotes || '').substring(0, 2000) || null;
          const result = await p.request()
            .input('id', iv.id)
            .input('verified', iv.analystVerified ? 1 : 0)
            .input('notes', notes)
            .query(`UPDATE dbo.GraphIdentities SET analystVerified = @verified, analystNotes = @notes WHERE id = @id`);
          if (result.rowsAffected[0] > 0) results.identityVerifications.updated++;
          else results.identityVerifications.skipped++;
        }
      }
    }

    // ── Import Identity Member Overrides ─────────────────────────
    if (Array.isArray(data.identityMemberOverrides) && data.identityMemberOverrides.length > 0) {
      if (await tableExists(p, 'GraphIdentityMembers') && await columnExists(p, 'GraphIdentityMembers', 'analystOverride')) {
        const validActions = ['confirmed', 'rejected', 'moved'];
        for (const mo of data.identityMemberOverrides) {
          if (!mo.identityId || !mo.userId || !mo.analystOverride) continue;
          if (!validActions.includes(mo.analystOverride)) continue;
          const reason = (mo.analystReason || '').substring(0, 500) || null;
          const result = await p.request()
            .input('identityId', mo.identityId)
            .input('userId', mo.userId)
            .input('action', mo.analystOverride)
            .input('reason', reason)
            .query(`UPDATE dbo.GraphIdentityMembers SET analystOverride = @action, analystReason = @reason WHERE identityId = @identityId AND userId = @userId`);
          if (result.rowsAffected[0] > 0) results.identityMemberOverrides.updated++;
          else results.identityMemberOverrides.skipped++;
        }
      }
    }

    // ── Import Cluster Owners ────────────────────────────────────
    if (Array.isArray(data.clusterOwners) && data.clusterOwners.length > 0) {
      if (await tableExists(p, 'GraphResourceClusters') && await columnExists(p, 'GraphResourceClusters', 'ownerUserId')) {
        for (const co of data.clusterOwners) {
          if (!co.id || !co.ownerUserId) continue;
          const result = await p.request()
            .input('id', co.id)
            .input('ownerUserId', co.ownerUserId)
            .input('ownerDisplayName', co.ownerDisplayName || null)
            .input('ownerAssignedBy', co.ownerAssignedBy || null)
            .query(`
              UPDATE dbo.GraphResourceClusters
              SET ownerUserId = @ownerUserId, ownerDisplayName = @ownerDisplayName,
                  ownerAssignedAt = GETUTCDATE(), ownerAssignedBy = @ownerAssignedBy
              WHERE id = @id
            `);
          if (result.rowsAffected[0] > 0) results.clusterOwners.updated++;
          else results.clusterOwners.skipped++;
        }
      }
    }

    res.json({ success: true, results });
  } catch (err) {
    console.error('POST /admin/import failed:', err.message);
    res.status(500).json({ error: 'Import failed' });
  }
});

export default router;
