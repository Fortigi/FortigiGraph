import { Router } from 'express';

const router = Router();
const useSql = process.env.USE_SQL === 'true';

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
  `);
  tablesReady = true;
}

// Re-export for other routes to use
export { ensureTagTables };

// ─── GET /api/tags ────────────────────────────────────────────────
router.get('/tags', async (req, res) => {
  try {
    if (!useSql) return res.json([]);
    const p = await db.getPool();
    await ensureTagTables(p);
    const { entityType } = req.query;
    const request = p.request();
    let sql = `
      SELECT t.*,
             (SELECT COUNT(*) FROM dbo.GraphTagAssignments ta WHERE ta.tagId = t.id) AS assignmentCount
      FROM dbo.GraphTags t
    `;
    if (entityType) {
      sql += ` WHERE t.entityType = @entityType`;
      request.input('entityType', entityType);
    }
    sql += ` ORDER BY t.name`;
    const result = await request.query(sql);
    res.json(result.recordset);
  } catch (err) {
    console.error('GET /tags failed:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─── POST /api/tags ───────────────────────────────────────────────
router.post('/tags', async (req, res) => {
  try {
    if (!useSql) return res.status(400).json({ error: 'SQL mode required' });
    const { name, color, entityType } = req.body;
    if (!name || !entityType) return res.status(400).json({ error: 'name and entityType required' });
    if (!['user', 'group'].includes(entityType)) return res.status(400).json({ error: 'entityType must be user or group' });

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
    res.status(500).json({ error: err.message });
  }
});

// ─── PATCH /api/tags/:id ──────────────────────────────────────────
router.patch('/tags/:id', async (req, res) => {
  try {
    if (!useSql) return res.status(400).json({ error: 'SQL mode required' });
    const { name, color } = req.body;
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
    res.status(500).json({ error: err.message });
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
    res.status(500).json({ error: err.message });
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

    let inserted = 0;
    for (const eid of entityIds) {
      const result = await p.request()
        .input('tagId', tagId)
        .input('entityId', String(eid).toUpperCase())
        .query(`
          IF NOT EXISTS (SELECT 1 FROM dbo.GraphTagAssignments WHERE tagId = @tagId AND entityId = @entityId)
          BEGIN
            INSERT INTO dbo.GraphTagAssignments (tagId, entityId) VALUES (@tagId, @entityId)
            SELECT 1 AS inserted
          END
        `);
      if (result.recordset?.length > 0) inserted++;
    }
    res.json({ ok: true, inserted });
  } catch (err) {
    console.error('POST /tags/:id/assign failed:', err.message);
    res.status(500).json({ error: err.message });
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

    for (const eid of entityIds) {
      await p.request()
        .input('tagId', tagId)
        .input('entityId', String(eid).toUpperCase())
        .query('DELETE FROM dbo.GraphTagAssignments WHERE tagId = @tagId AND entityId = @entityId');
    }
    res.json({ ok: true });
  } catch (err) {
    console.error('POST /tags/:id/unassign failed:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─── POST /api/tags/:id/assign-by-filter ──────────────────────────
// Bulk-assign: tags ALL entities matching a search filter (server-side)
router.post('/tags/:id/assign-by-filter', async (req, res) => {
  try {
    if (!useSql) return res.status(400).json({ error: 'SQL mode required' });
    const { entityType, search } = req.body;
    if (!entityType) return res.status(400).json({ error: 'entityType required' });

    const p = await db.getPool();
    await ensureTagTables(p);
    const tagId = parseInt(req.params.id);
    const table = entityType === 'user' ? 'GraphUsers' : 'GraphGroups';

    const request = p.request().input('tagId', tagId);
    let where = '1=1';
    if (search) {
      request.input('search', `%${search}%`);
      if (entityType === 'user') {
        where = `(displayName LIKE @search OR userPrincipalName LIKE @search)`;
      } else {
        where = `(displayName LIKE @search OR description LIKE @search)`;
      }
    }

    const result = await request.query(`
      INSERT INTO dbo.GraphTagAssignments (tagId, entityId)
      SELECT @tagId, UPPER(CAST(id AS NVARCHAR(36)))
      FROM dbo.${table}
      WHERE (${where})
        AND UPPER(CAST(id AS NVARCHAR(36))) NOT IN (
          SELECT entityId FROM dbo.GraphTagAssignments WHERE tagId = @tagId
        );
      SELECT @@ROWCOUNT AS inserted;
    `);
    res.json({ ok: true, inserted: result.recordset[0]?.inserted || 0 });
  } catch (err) {
    console.error('POST /tags/:id/assign-by-filter failed:', err.message);
    res.status(500).json({ error: err.message });
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

// ─── GET /api/users ───────────────────────────────────────────────
router.get('/users', async (req, res) => {
  try {
    if (!useSql) return res.json({ data: [], total: 0 });

    const search = req.query.search || '';
    const tagId = req.query.tagId ? parseInt(req.query.tagId) : null;
    const limit = Math.min(Math.max(parseInt(req.query.limit) || 100, 1), 500);
    const offset = Math.max(parseInt(req.query.offset) || 0, 0);

    const p = await db.getPool();
    await ensureTagTables(p);

    const request = p.request();
    request.input('limit', limit);
    request.input('offset', offset);

    let where = '1=1';
    if (search) {
      where += ` AND (u.displayName LIKE @search OR u.userPrincipalName LIKE @search)`;
      request.input('search', `%${search}%`);
    }
    if (tagId) {
      where += ` AND EXISTS (SELECT 1 FROM dbo.GraphTagAssignments ta WHERE ta.tagId = @tagId AND ta.entityId = UPPER(CAST(u.id AS NVARCHAR(36))))`;
      request.input('tagId', tagId);
    }

    const result = await request.query(`
      SELECT u.id, u.displayName, u.userPrincipalName, u.department, u.jobTitle,
             u.companyName, u.accountEnabled,
             (SELECT STRING_AGG(CONCAT(CAST(t.id AS NVARCHAR(10)), ':', t.name, ':', t.color), '|')
              FROM dbo.GraphTagAssignments ta
              INNER JOIN dbo.GraphTags t ON ta.tagId = t.id AND t.entityType = 'user'
              WHERE ta.entityId = UPPER(CAST(u.id AS NVARCHAR(36)))
             ) AS tagString
      FROM dbo.GraphUsers u
      WHERE ${where}
      ORDER BY u.displayName
      OFFSET @offset ROWS FETCH NEXT @limit ROWS ONLY;

      SELECT COUNT(*) AS total FROM dbo.GraphUsers u WHERE ${where};
    `);

    const data = result.recordsets[0].map(r => {
      const { tagString, ...rest } = r;
      return { ...rest, tags: parseTags(tagString) };
    });

    res.json({ data, total: result.recordsets[1][0].total });
  } catch (err) {
    console.error('GET /users failed:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─── GET /api/groups ──────────────────────────────────────────────
router.get('/groups', async (req, res) => {
  try {
    if (!useSql) return res.json({ data: [], total: 0 });

    const search = req.query.search || '';
    const tagId = req.query.tagId ? parseInt(req.query.tagId) : null;
    const limit = Math.min(Math.max(parseInt(req.query.limit) || 100, 1), 500);
    const offset = Math.max(parseInt(req.query.offset) || 0, 0);

    const p = await db.getPool();
    await ensureTagTables(p);

    const request = p.request();
    request.input('limit', limit);
    request.input('offset', offset);

    let where = '1=1';
    if (search) {
      where += ` AND (g.displayName LIKE @search OR g.description LIKE @search)`;
      request.input('search', `%${search}%`);
    }
    if (tagId) {
      where += ` AND EXISTS (SELECT 1 FROM dbo.GraphTagAssignments ta WHERE ta.tagId = @tagId AND ta.entityId = UPPER(CAST(g.id AS NVARCHAR(36))))`;
      request.input('tagId', tagId);
    }

    const result = await request.query(`
      SELECT g.id, g.displayName, g.groupTypeCalculated, g.description,
             (SELECT STRING_AGG(CONCAT(CAST(t.id AS NVARCHAR(10)), ':', t.name, ':', t.color), '|')
              FROM dbo.GraphTagAssignments ta
              INNER JOIN dbo.GraphTags t ON ta.tagId = t.id AND t.entityType = 'group'
              WHERE ta.entityId = UPPER(CAST(g.id AS NVARCHAR(36)))
             ) AS tagString
      FROM dbo.GraphGroups g
      WHERE ${where}
      ORDER BY g.displayName
      OFFSET @offset ROWS FETCH NEXT @limit ROWS ONLY;

      SELECT COUNT(*) AS total FROM dbo.GraphGroups g WHERE ${where};
    `);

    const data = result.recordsets[0].map(r => {
      const { tagString, ...rest } = r;
      return { ...rest, tags: parseTags(tagString) };
    });

    res.json({ data, total: result.recordsets[1][0].total });
  } catch (err) {
    console.error('GET /groups failed:', err.message);
    res.status(500).json({ error: err.message });
  }
});

export default router;
