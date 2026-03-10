import { Router } from 'express';
import { getUserColumns as getUserCols, getGroupColumns as getGroupCols, getUserColumnValues, getGroupColumnValues, FILTERABLE_TYPES } from '../db/columnCache.js';

const router = Router();
const useSql = process.env.USE_SQL === 'true';

// Validate hex color format (#000000 – #ffffff)
const HEX_COLOR_RE = /^#[0-9a-fA-F]{6}$/;

let db = null;
if (useSql) {
  db = await import('../db/connection.js');
}

// ─── Auto-create tag tables if they don't exist ──────────────────
let tablesReady = false;

async function ensureTagTables(pool) {
  if (tablesReady) return;
  await pool.request().query(`
    IF OBJECT_ID('dbo.GraphTags', 'U') IS NULL
    CREATE TABLE dbo.GraphTags (
      id INT IDENTITY(1,1) PRIMARY KEY,
      name NVARCHAR(100) NOT NULL,
      color NVARCHAR(7) NOT NULL DEFAULT '#3b82f6',
      entityType NVARCHAR(10) NOT NULL,
      createdAt DATETIME2 DEFAULT GETUTCDATE(),
      CONSTRAINT UQ_GraphTags_Name_Type UNIQUE(name, entityType),
      CONSTRAINT CK_GraphTags_EntityType CHECK(entityType IN ('user', 'group'))
    );
    IF OBJECT_ID('dbo.GraphTagAssignments', 'U') IS NULL
    CREATE TABLE dbo.GraphTagAssignments (
      tagId INT NOT NULL,
      entityId NVARCHAR(36) NOT NULL,
      PRIMARY KEY (tagId, entityId),
      CONSTRAINT FK_TagAssignment_Tag FOREIGN KEY (tagId) REFERENCES dbo.GraphTags(id) ON DELETE CASCADE
    );
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_GraphTagAssignments_entityId' AND object_id = OBJECT_ID('dbo.GraphTagAssignments'))
      CREATE INDEX IX_GraphTagAssignments_entityId ON dbo.GraphTagAssignments(entityId) INCLUDE(tagId);
  `);
  tablesReady = true;
}

// Re-export for other routes to use
export { ensureTagTables };

// ─── Column discovery helpers (shared TTL cache from db/columnCache.js) ──

// Build parameterized WHERE clause from filters object, validating against actual columns
function buildFilterWhere(requestObj, filters, validColNames, alias, paramPrefix = 'fl') {
  let where = '';
  let idx = 0;
  for (const [field, value] of Object.entries(filters)) {
    if (validColNames.has(field) && value != null && String(value) !== '') {
      const paramName = `${paramPrefix}${idx}`;
      where += ` AND CAST(${alias}.[${field}] AS NVARCHAR(400)) = @${paramName}`;
      requestObj.input(paramName, String(value));
      idx++;
    }
  }
  return where;
}

// ─── GET /api/tags ────────────────────────────────────────────────
router.get('/tags', async (req, res) => {
  try {
    if (!useSql) return res.json([]);
    const p = await db.getPool();
    await ensureTagTables(p);
    const { entityType } = req.query;
    const request = p.request();
    let sql = `
      SELECT t.*, ISNULL(COUNT(ta.tagId), 0) AS assignmentCount
      FROM dbo.GraphTags t
      LEFT JOIN dbo.GraphTagAssignments ta ON ta.tagId = t.id
    `;
    if (entityType) {
      sql += ` WHERE t.entityType = @entityType`;
      request.input('entityType', entityType);
    }
    sql += ` GROUP BY t.id, t.name, t.color, t.entityType, t.createdAt`;
    sql += ` ORDER BY t.name`;
    const result = await request.query(sql);
    res.json(result.recordset);
  } catch (err) {
    console.error('GET /tags failed:', err.message);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ─── POST /api/tags ───────────────────────────────────────────────
router.post('/tags', async (req, res) => {
  try {
    if (!useSql) return res.status(400).json({ error: 'SQL mode required' });
    const { name, color, entityType } = req.body;
    if (!name || !entityType) return res.status(400).json({ error: 'name and entityType required' });
    if (!['user', 'group'].includes(entityType)) return res.status(400).json({ error: 'entityType must be user or group' });
    if (color && !HEX_COLOR_RE.test(color)) return res.status(400).json({ error: 'color must be a hex value like #3b82f6' });

    const p = await db.getPool();
    await ensureTagTables(p);
    const result = await p.request()
      .input('name', name.trim())
      .input('color', color || '#3b82f6')
      .input('entityType', entityType)
      .query(`
        INSERT INTO dbo.GraphTags (name, color, entityType)
        OUTPUT INSERTED.*
        VALUES (@name, @color, @entityType)
      `);
    res.status(201).json(result.recordset[0]);
  } catch (err) {
    if (err.message?.includes('UQ_GraphTags_Name_Type')) {
      return res.status(409).json({ error: 'A tag with this name already exists for this entity type' });
    }
    console.error('POST /tags failed:', err.message);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ─── PATCH /api/tags/:id ──────────────────────────────────────────
router.patch('/tags/:id', async (req, res) => {
  try {
    if (!useSql) return res.status(400).json({ error: 'SQL mode required' });
    const { name, color } = req.body;
    if (color && !HEX_COLOR_RE.test(color)) return res.status(400).json({ error: 'color must be a hex value like #3b82f6' });
    const p = await db.getPool();
    await ensureTagTables(p);
    const request = p.request().input('id', parseInt(req.params.id));
    const sets = [];
    if (name) { sets.push('name = @name'); request.input('name', name.trim()); }
    if (color) { sets.push('color = @color'); request.input('color', color); }
    if (sets.length === 0) return res.status(400).json({ error: 'Nothing to update' });
    const result = await request.query(
      `UPDATE dbo.GraphTags SET ${sets.join(', ')} OUTPUT INSERTED.* WHERE id = @id`
    );
    res.json(result.recordset[0] || null);
  } catch (err) {
    console.error('PATCH /tags failed:', err.message);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ─── DELETE /api/tags/:id ─────────────────────────────────────────
router.delete('/tags/:id', async (req, res) => {
  try {
    if (!useSql) return res.status(400).json({ error: 'SQL mode required' });
    const p = await db.getPool();
    await ensureTagTables(p);
    await p.request()
      .input('id', parseInt(req.params.id))
      .query('DELETE FROM dbo.GraphTags WHERE id = @id');
    res.json({ ok: true });
  } catch (err) {
    console.error('DELETE /tags failed:', err.message);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ─── POST /api/tags/:id/assign ────────────────────────────────────
router.post('/tags/:id/assign', async (req, res) => {
  try {
    if (!useSql) return res.status(400).json({ error: 'SQL mode required' });
    const { entityIds } = req.body;
    if (!Array.isArray(entityIds) || entityIds.length === 0) {
      return res.status(400).json({ error: 'entityIds array required' });
    }
    const p = await db.getPool();
    await ensureTagTables(p);
    const tagId = parseInt(req.params.id);

    // Batch insert all assignments in a single query (avoids N+1 round-trips)
    const request = p.request().input('tagId', tagId);
    const valueParams = entityIds.map((eid, i) => {
      request.input(`eid${i}`, String(eid).toUpperCase());
      return `@eid${i}`;
    });
    const result = await request.query(`
      INSERT INTO dbo.GraphTagAssignments (tagId, entityId)
      SELECT @tagId, eid FROM (VALUES ${valueParams.map(p => `(${p})`).join(',')}) AS t(eid)
      WHERE NOT EXISTS (
        SELECT 1 FROM dbo.GraphTagAssignments WHERE tagId = @tagId AND entityId = t.eid
      );
      SELECT @@ROWCOUNT AS inserted;
    `);
    res.json({ ok: true, inserted: result.recordset[0]?.inserted || 0 });
  } catch (err) {
    console.error('POST /tags/:id/assign failed:', err.message);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ─── POST /api/tags/:id/unassign ──────────────────────────────────
router.post('/tags/:id/unassign', async (req, res) => {
  try {
    if (!useSql) return res.status(400).json({ error: 'SQL mode required' });
    const { entityIds } = req.body;
    if (!Array.isArray(entityIds) || entityIds.length === 0) {
      return res.status(400).json({ error: 'entityIds array required' });
    }
    const p = await db.getPool();
    await ensureTagTables(p);
    const tagId = parseInt(req.params.id);

    // Batch delete all assignments in a single query (avoids N+1 round-trips)
    const request = p.request().input('tagId', tagId);
    const idParams = entityIds.map((eid, i) => {
      request.input(`eid${i}`, String(eid).toUpperCase());
      return `@eid${i}`;
    });
    const result = await request.query(`
      DELETE FROM dbo.GraphTagAssignments
      WHERE tagId = @tagId AND entityId IN (${idParams.join(',')});
      SELECT @@ROWCOUNT AS deleted;
    `);
    res.json({ ok: true, deleted: result.recordset[0]?.deleted || 0 });
  } catch (err) {
    console.error('POST /tags/:id/unassign failed:', err.message);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ─── POST /api/tags/:id/assign-by-filter ──────────────────────────
// Bulk-assign: tags ALL entities matching a search filter (server-side)
router.post('/tags/:id/assign-by-filter', async (req, res) => {
  try {
    if (!useSql) return res.status(400).json({ error: 'SQL mode required' });
    const { entityType, search: rawSearch, filters } = req.body;
    if (!entityType) return res.status(400).json({ error: 'entityType required' });

    const p = await db.getPool();
    await ensureTagTables(p);
    const tagId = parseInt(req.params.id);
    const table = entityType === 'user' ? 'GraphUsers' : 'GraphGroups';
    const alias = 'e';
    const search = (rawSearch || '').trim().slice(0, 200);

    const request = p.request().input('tagId', tagId);
    let where = '1=1';
    if (search) {
      request.input('search', `%${search}%`);
      if (entityType === 'user') {
        where += ` AND (${alias}.displayName LIKE @search OR ${alias}.userPrincipalName LIKE @search)`;
      } else {
        where += ` AND (${alias}.displayName LIKE @search OR ${alias}.description LIKE @search)`;
      }
    }

    // Apply attribute filters
    if (filters && typeof filters === 'object') {
      const cols = entityType === 'user' ? await getUserCols(p) : await getGroupCols(p);
      const colNames = new Set(cols.map(c => c.name));
      where += buildFilterWhere(request, filters, colNames, alias, 'bf');
    }

    // Safety cap: limit bulk assignment to 50,000 rows to prevent runaway operations
    const result = await request.query(`
      INSERT INTO dbo.GraphTagAssignments (tagId, entityId)
      SELECT TOP 50000 @tagId, UPPER(CAST(${alias}.id AS NVARCHAR(36)))
      FROM dbo.${table} ${alias}
      WHERE (${where})
        AND UPPER(CAST(${alias}.id AS NVARCHAR(36))) NOT IN (
          SELECT entityId FROM dbo.GraphTagAssignments WHERE tagId = @tagId
        );
      SELECT @@ROWCOUNT AS inserted;
    `);
    res.json({ ok: true, inserted: result.recordset[0]?.inserted || 0 });
  } catch (err) {
    console.error('POST /tags/:id/assign-by-filter failed:', err.message);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ─── Helper: parse tag string from SQL into array ─────────────────
function parseTags(tagString) {
  if (!tagString) return [];
  return tagString.split('|').map(t => {
    const parts = t.split(':');
    return { id: parseInt(parts[0]), name: parts[1], color: parts[2] };
  });
}

// ─── GET /api/user-columns-page ──────────────────────────────────
// Column discovery for the Users page (distinct values from GraphUsers)
router.get('/user-columns-page', async (req, res) => {
  try {
    if (!useSql) return res.json([]);
    const p = await db.getPool();

    // Use cached distinct values (5-min TTL — avoids 44s UNION ALL on every load)
    const grouped = { ...await getUserColumnValues(p) };

    // Add virtual __userTag column (tag names as values)
    try {
      await ensureTagTables(p);
      const tagResult = await p.request().query(`
        SELECT t.name
        FROM dbo.GraphTags t
        WHERE t.entityType = 'user'
          AND EXISTS (SELECT 1 FROM dbo.GraphTagAssignments ta WHERE ta.tagId = t.id)
        ORDER BY t.name
      `);
      const userTags = tagResult.recordset.map(r => r.name);
      if (userTags.length > 0) grouped['__userTag'] = userTags;
    } catch { /* tag tables may not exist yet */ }

    return res.json(Object.entries(grouped).map(([column, values]) => ({ column, values })));
  } catch (err) {
    console.error('user-columns-page query failed:', err.message);
    return res.json([]);
  }
});

// ─── GET /api/group-columns ──────────────────────────────────────
// Column discovery for the Groups page (distinct values from GraphGroups)
router.get('/group-columns', async (req, res) => {
  try {
    if (!useSql) return res.json([]);
    const p = await db.getPool();
    const grouped = { ...await getGroupColumnValues(p) };

    // Add virtual __groupTag column (tag names as values)
    try {
      await ensureTagTables(p);
      const tagResult = await p.request().query(`
        SELECT t.name
        FROM dbo.GraphTags t
        WHERE t.entityType = 'group'
          AND EXISTS (SELECT 1 FROM dbo.GraphTagAssignments ta WHERE ta.tagId = t.id)
        ORDER BY t.name
      `);
      const groupTags = tagResult.recordset.map(r => r.name);
      if (groupTags.length > 0) grouped['__groupTag'] = groupTags;
    } catch { /* tag tables may not exist yet */ }

    return res.json(Object.entries(grouped).map(([column, values]) => ({ column, values })));
  } catch (err) {
    console.error('group-columns query failed:', err.message);
    return res.json([]);
  }
});

// ─── GET /api/users ───────────────────────────────────────────────
router.get('/users', async (req, res) => {
  try {
    if (!useSql) return res.json({ data: [], total: 0 });

    const search = (req.query.search || '').trim().slice(0, 200);
    const tagId = req.query.tagId ? parseInt(req.query.tagId) : null;
    const limit = Math.min(Math.max(parseInt(req.query.limit) || 100, 1), 500);
    const offset = Math.max(parseInt(req.query.offset) || 0, 0);

    // Parse attribute filters
    let attrFilters = {};
    if (req.query.filters) {
      try { attrFilters = JSON.parse(req.query.filters); } catch { /* ignore bad JSON */ }
    }

    // Extract virtual tag filter before column validation
    let userTagFilter = null;
    if (attrFilters['__userTag']) {
      userTagFilter = String(attrFilters['__userTag']);
      delete attrFilters['__userTag'];
    }

    const p = await db.getPool();
    await ensureTagTables(p);

    const request = p.request();
    request.input('limit', limit);
    request.input('offset', offset);

    // Validate attribute filters against actual columns
    const cols = await getUserCols(p);
    const colNames = new Set(cols.map(c => c.name));
    const filterWhere = buildFilterWhere(request, attrFilters, colNames, 'u');

    let where = '1=1';
    if (search) {
      where += ` AND (u.displayName LIKE @search OR u.userPrincipalName LIKE @search)`;
      request.input('search', `%${search}%`);
    }
    if (tagId) {
      where += ` AND EXISTS (SELECT 1 FROM dbo.GraphTagAssignments ta WHERE ta.tagId = @tagId AND ta.entityId = UPPER(CAST(u.id AS NVARCHAR(36))))`;
      request.input('tagId', tagId);
    }
    let userTagJoin = '';
    if (userTagFilter) {
      userTagJoin = `
        INNER JOIN dbo.GraphTagAssignments _uta ON _uta.entityId = UPPER(CAST(u.id AS NVARCHAR(36)))
        INNER JOIN dbo.GraphTags _ut ON _uta.tagId = _ut.id AND _ut.name = @__userTag AND _ut.entityType = 'user'`;
      request.input('__userTag', userTagFilter);
    }
    where += filterWhere;

    const result = await request.query(`
      SELECT u.id, u.displayName, u.userPrincipalName, u.department, u.jobTitle,
             u.companyName, u.accountEnabled,
             (SELECT STRING_AGG(CONCAT(CAST(t.id AS NVARCHAR(10)), ':', t.name, ':', t.color), '|')
              FROM dbo.GraphTagAssignments ta
              INNER JOIN dbo.GraphTags t ON ta.tagId = t.id AND t.entityType = 'user'
              WHERE ta.entityId = UPPER(CAST(u.id AS NVARCHAR(36)))
             ) AS tagString
      FROM dbo.GraphUsers u
      ${userTagJoin}
      WHERE ${where}
      ORDER BY u.displayName
      OFFSET @offset ROWS FETCH NEXT @limit ROWS ONLY;

      SELECT COUNT(*) AS total FROM dbo.GraphUsers u ${userTagJoin} WHERE ${where};
    `);

    const data = result.recordsets[0].map(r => {
      const { tagString, ...rest } = r;
      return { ...rest, tags: parseTags(tagString) };
    });

    res.json({ data, total: result.recordsets[1][0].total });
  } catch (err) {
    console.error('GET /users failed:', err.message);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ─── GET /api/groups ──────────────────────────────────────────────
router.get('/groups', async (req, res) => {
  try {
    if (!useSql) return res.json({ data: [], total: 0 });

    const search = (req.query.search || '').trim().slice(0, 200);
    const tagId = req.query.tagId ? parseInt(req.query.tagId) : null;
    const limit = Math.min(Math.max(parseInt(req.query.limit) || 100, 1), 500);
    const offset = Math.max(parseInt(req.query.offset) || 0, 0);

    // Parse attribute filters
    let attrFilters = {};
    if (req.query.filters) {
      try { attrFilters = JSON.parse(req.query.filters); } catch { /* ignore bad JSON */ }
    }

    // Extract virtual tag filter before column validation
    let groupTagFilter = null;
    if (attrFilters['__groupTag']) {
      groupTagFilter = String(attrFilters['__groupTag']);
      delete attrFilters['__groupTag'];
    }

    const p = await db.getPool();
    await ensureTagTables(p);

    const request = p.request();
    request.input('limit', limit);
    request.input('offset', offset);

    // Validate attribute filters against actual columns
    const cols = await getGroupCols(p);
    const colNames = new Set(cols.map(c => c.name));
    const filterWhere = buildFilterWhere(request, attrFilters, colNames, 'g');

    let where = '1=1';
    if (search) {
      where += ` AND (g.displayName LIKE @search OR g.description LIKE @search)`;
      request.input('search', `%${search}%`);
    }
    if (tagId) {
      where += ` AND EXISTS (SELECT 1 FROM dbo.GraphTagAssignments ta WHERE ta.tagId = @tagId AND ta.entityId = UPPER(CAST(g.id AS NVARCHAR(36))))`;
      request.input('tagId', tagId);
    }
    let groupTagJoin = '';
    if (groupTagFilter) {
      groupTagJoin = `
        INNER JOIN dbo.GraphTagAssignments _gta ON _gta.entityId = UPPER(CAST(g.id AS NVARCHAR(36)))
        INNER JOIN dbo.GraphTags _gt ON _gta.tagId = _gt.id AND _gt.name = @__groupTag AND _gt.entityType = 'group'`;
      request.input('__groupTag', groupTagFilter);
    }
    where += filterWhere;

    const result = await request.query(`
      SELECT g.id, g.displayName, g.groupTypeCalculated, g.description,
             (SELECT STRING_AGG(CONCAT(CAST(t.id AS NVARCHAR(10)), ':', t.name, ':', t.color), '|')
              FROM dbo.GraphTagAssignments ta
              INNER JOIN dbo.GraphTags t ON ta.tagId = t.id AND t.entityType = 'group'
              WHERE ta.entityId = UPPER(CAST(g.id AS NVARCHAR(36)))
             ) AS tagString
      FROM dbo.GraphGroups g
      ${groupTagJoin}
      WHERE ${where}
      ORDER BY g.displayName
      OFFSET @offset ROWS FETCH NEXT @limit ROWS ONLY;

      SELECT COUNT(*) AS total FROM dbo.GraphGroups g ${groupTagJoin} WHERE ${where};
    `);

    const data = result.recordsets[0].map(r => {
      const { tagString, ...rest } = r;
      return { ...rest, tags: parseTags(tagString) };
    });

    res.json({ data, total: result.recordsets[1][0].total });
  } catch (err) {
    console.error('GET /groups failed:', err.message);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ─── GET /api/entity-tags ────────────────────────────────────────
// Returns all tag assignments for a given entity type as a flat list.
// Query params: entityType ('user' | 'group')
// Response: [{ entityId, tagId, tagName, tagColor }]
router.get('/entity-tags', async (req, res) => {
  try {
    if (!useSql) return res.json([]);
    const { entityType } = req.query;
    if (!entityType || !['user', 'group'].includes(entityType)) {
      return res.status(400).json({ error: 'entityType must be user or group' });
    }
    const p = await db.getPool();
    await ensureTagTables(p);
    const result = await p.request().input('entityType', entityType).query(`
      SELECT ta.entityId, t.id AS tagId, t.name AS tagName, t.color AS tagColor
      FROM dbo.GraphTagAssignments ta
      INNER JOIN dbo.GraphTags t ON ta.tagId = t.id
      WHERE t.entityType = @entityType
      ORDER BY ta.entityId, t.name
    `);
    res.json(result.recordset);
  } catch (err) {
    console.error('GET /entity-tags failed:', err.message);
    res.json([]);
  }
});

export default router;
