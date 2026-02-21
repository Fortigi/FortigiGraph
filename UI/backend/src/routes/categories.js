import { Router } from 'express';

const router = Router();
const useSql = process.env.USE_SQL === 'true';

let db = null;
if (useSql) {
  db = await import('../db/connection.js');
}

// ─── Auto-create category tables if they don't exist ─────────────
let tablesReady = false;

async function ensureCategoryTables(pool) {
  if (tablesReady) return;
  await pool.request().query(`
    IF OBJECT_ID('dbo.GraphCategories', 'U') IS NULL
    CREATE TABLE dbo.GraphCategories (
      id INT IDENTITY(1,1) PRIMARY KEY,
      name NVARCHAR(100) NOT NULL UNIQUE,
      color NVARCHAR(7) NOT NULL DEFAULT '#3b82f6',
      createdAt DATETIME2 DEFAULT GETUTCDATE()
    );
    IF OBJECT_ID('dbo.GraphCategoryAssignments', 'U') IS NULL
    CREATE TABLE dbo.GraphCategoryAssignments (
      accessPackageId NVARCHAR(36) NOT NULL,
      categoryId INT NOT NULL,
      CONSTRAINT PK_GraphCategoryAssignments PRIMARY KEY (accessPackageId),
      CONSTRAINT FK_CategoryAssignment_Category FOREIGN KEY (categoryId) REFERENCES dbo.GraphCategories(id) ON DELETE CASCADE
    );
  `);
  tablesReady = true;
}

export { ensureCategoryTables };

const TAG_COLORS = [
  '#3b82f6', '#10b981', '#f59e0b', '#ef4444', '#8b5cf6',
  '#ec4899', '#14b8a6', '#f97316', '#6366f1', '#84cc16',
];

// ─── GET /api/categories ─────────────────────────────────────────
router.get('/categories', async (req, res) => {
  try {
    if (!useSql) return res.json([]);
    const p = await db.getPool();
    await ensureCategoryTables(p);
    const result = await p.request().query(`
      SELECT c.*, ISNULL(COUNT(ca.categoryId), 0) AS assignmentCount
      FROM dbo.GraphCategories c
      LEFT JOIN dbo.GraphCategoryAssignments ca ON ca.categoryId = c.id
      GROUP BY c.id, c.name, c.color, c.createdAt
      ORDER BY c.name
    `);
    res.json(result.recordset);
  } catch (err) {
    console.error('GET /categories failed:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─── POST /api/categories ────────────────────────────────────────
router.post('/categories', async (req, res) => {
  try {
    if (!useSql) return res.status(400).json({ error: 'SQL mode required' });
    const { name, color } = req.body;
    if (!name) return res.status(400).json({ error: 'name required' });

    const p = await db.getPool();
    await ensureCategoryTables(p);
    const result = await p.request()
      .input('name', name.trim())
      .input('color', color || TAG_COLORS[0])
      .query(`
        INSERT INTO dbo.GraphCategories (name, color)
        OUTPUT INSERTED.*
        VALUES (@name, @color)
      `);
    res.status(201).json(result.recordset[0]);
  } catch (err) {
    if (err.message?.includes('UQ__GraphCat') || err.message?.includes('UNIQUE')) {
      return res.status(409).json({ error: 'A category with this name already exists' });
    }
    console.error('POST /categories failed:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─── PATCH /api/categories/:id ───────────────────────────────────
router.patch('/categories/:id', async (req, res) => {
  try {
    if (!useSql) return res.status(400).json({ error: 'SQL mode required' });
    const { name, color } = req.body;
    const p = await db.getPool();
    await ensureCategoryTables(p);
    const request = p.request().input('id', parseInt(req.params.id));
    const sets = [];
    if (name) { sets.push('name = @name'); request.input('name', name.trim()); }
    if (color) { sets.push('color = @color'); request.input('color', color); }
    if (sets.length === 0) return res.status(400).json({ error: 'Nothing to update' });
    const result = await request.query(
      `UPDATE dbo.GraphCategories SET ${sets.join(', ')} OUTPUT INSERTED.* WHERE id = @id`
    );
    res.json(result.recordset[0] || null);
  } catch (err) {
    console.error('PATCH /categories failed:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─── DELETE /api/categories/:id ──────────────────────────────────
router.delete('/categories/:id', async (req, res) => {
  try {
    if (!useSql) return res.status(400).json({ error: 'SQL mode required' });
    const p = await db.getPool();
    await ensureCategoryTables(p);
    await p.request()
      .input('id', parseInt(req.params.id))
      .query('DELETE FROM dbo.GraphCategories WHERE id = @id');
    res.json({ ok: true });
  } catch (err) {
    console.error('DELETE /categories failed:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─── POST /api/categories/:id/assign ─────────────────────────────
// Assigns category to an access package. Since an AP can only have ONE category,
// this replaces any existing assignment for that AP.
router.post('/categories/:id/assign', async (req, res) => {
  try {
    if (!useSql) return res.status(400).json({ error: 'SQL mode required' });
    const { accessPackageId } = req.body;
    if (!accessPackageId) return res.status(400).json({ error: 'accessPackageId required' });

    const p = await db.getPool();
    await ensureCategoryTables(p);
    const categoryId = parseInt(req.params.id);

    // MERGE: insert or replace the category for this AP (only one allowed)
    await p.request()
      .input('categoryId', categoryId)
      .input('accessPackageId', String(accessPackageId).toLowerCase())
      .query(`
        MERGE dbo.GraphCategoryAssignments AS target
        USING (SELECT @accessPackageId AS accessPackageId) AS source
        ON target.accessPackageId = source.accessPackageId
        WHEN MATCHED THEN UPDATE SET categoryId = @categoryId
        WHEN NOT MATCHED THEN INSERT (accessPackageId, categoryId) VALUES (@accessPackageId, @categoryId);
      `);
    res.json({ ok: true });
  } catch (err) {
    console.error('POST /categories/:id/assign failed:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─── POST /api/categories/unassign ───────────────────────────────
// Removes the category assignment from an access package.
router.post('/categories/unassign', async (req, res) => {
  try {
    if (!useSql) return res.status(400).json({ error: 'SQL mode required' });
    const { accessPackageId } = req.body;
    if (!accessPackageId) return res.status(400).json({ error: 'accessPackageId required' });

    const p = await db.getPool();
    await ensureCategoryTables(p);

    await p.request()
      .input('accessPackageId', String(accessPackageId).toLowerCase())
      .query('DELETE FROM dbo.GraphCategoryAssignments WHERE accessPackageId = @accessPackageId');
    res.json({ ok: true });
  } catch (err) {
    console.error('POST /categories/unassign failed:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─── GET /api/access-packages ────────────────────────────────────
// Paginated list of access packages with category info
router.get('/access-packages', async (req, res) => {
  try {
    if (!useSql) return res.json({ data: [], total: 0 });

    const search = req.query.search || '';
    const limit = Math.min(Math.max(parseInt(req.query.limit) || 100, 1), 500);
    const offset = Math.max(parseInt(req.query.offset) || 0, 0);

    // Parse category filter
    let categoryFilter = null;
    if (req.query.categoryId) {
      categoryFilter = parseInt(req.query.categoryId);
    }
    let showUncategorized = req.query.uncategorized === 'true';

    const p = await db.getPool();
    await ensureCategoryTables(p);

    const request = p.request();
    request.input('limit', limit);
    request.input('offset', offset);

    let where = '1=1';
    if (search) {
      where += ` AND (ap.displayName LIKE @search OR c.displayName LIKE @search)`;
      request.input('search', `%${search}%`);
    }
    if (categoryFilter) {
      where += ` AND ca.categoryId = @categoryId`;
      request.input('categoryId', categoryFilter);
    } else if (showUncategorized) {
      where += ` AND ca.accessPackageId IS NULL`;
    }

    const result = await request.query(`
      SELECT ap.id, ap.displayName, ap.description,
             c.displayName AS catalogName, c.id AS catalogId,
             ISNULL(ac.cnt, 0) AS totalAssignments,
             cat.id AS categoryId, cat.name AS categoryName, cat.color AS categoryColor
      FROM dbo.GraphAccessPackages ap
      INNER JOIN dbo.GraphCatalogs c ON ap.catalogId = c.id
      LEFT JOIN (
        SELECT accessPackageId, COUNT(*) AS cnt
        FROM dbo.GraphAccessPackageAssignments
        WHERE assignmentState = 'delivered'
        GROUP BY accessPackageId
      ) ac ON ap.id = ac.accessPackageId
      LEFT JOIN dbo.GraphCategoryAssignments ca ON LOWER(ap.id) = ca.accessPackageId
      LEFT JOIN dbo.GraphCategories cat ON ca.categoryId = cat.id
      WHERE ${where}
      ORDER BY ap.displayName
      OFFSET @offset ROWS FETCH NEXT @limit ROWS ONLY;

      SELECT COUNT(*) AS total
      FROM dbo.GraphAccessPackages ap
      INNER JOIN dbo.GraphCatalogs c ON ap.catalogId = c.id
      LEFT JOIN dbo.GraphCategoryAssignments ca ON LOWER(ap.id) = ca.accessPackageId
      LEFT JOIN dbo.GraphCategories cat ON ca.categoryId = cat.id
      WHERE ${where};
    `);

    const data = result.recordsets[0].map(r => ({
      id: r.id,
      displayName: r.displayName,
      description: r.description,
      catalogName: r.catalogName,
      catalogId: r.catalogId,
      totalAssignments: r.totalAssignments,
      category: r.categoryId ? { id: r.categoryId, name: r.categoryName, color: r.categoryColor } : null,
    }));

    res.json({ data, total: result.recordsets[1][0].total });
  } catch (err) {
    console.error('GET /access-packages failed:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─── GET /api/category-assignments ───────────────────────────────
// Returns all category assignments as a flat list (for matrix column ordering)
router.get('/category-assignments', async (req, res) => {
  try {
    if (!useSql) return res.json([]);
    const p = await db.getPool();
    await ensureCategoryTables(p);
    const result = await p.request().query(`
      SELECT ca.accessPackageId, c.id AS categoryId, c.name AS categoryName, c.color AS categoryColor
      FROM dbo.GraphCategoryAssignments ca
      INNER JOIN dbo.GraphCategories c ON ca.categoryId = c.id
      ORDER BY c.name, ca.accessPackageId
    `);
    res.json(result.recordset);
  } catch (err) {
    console.error('GET /category-assignments failed:', err.message);
    res.json([]);
  }
});

export default router;
