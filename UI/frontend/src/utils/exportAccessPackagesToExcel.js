import ExcelJS from 'exceljs';

function formatDate(dateStr) {
  if (!dateStr) return '';
  const d = new Date(dateStr);
  return d.toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' });
}

function thinBorder() {
  return {
    top:    { style: 'thin', color: { argb: 'FFD1D5DB' } },
    left:   { style: 'thin', color: { argb: 'FFD1D5DB' } },
    bottom: { style: 'thin', color: { argb: 'FFD1D5DB' } },
    right:  { style: 'thin', color: { argb: 'FFD1D5DB' } },
  };
}

function setHeaderCell(cell, value) {
  cell.value = value;
  cell.font = { size: 11, bold: true, color: { argb: 'FF374151' } };
  cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFF3F4F6' } };
  cell.border = thinBorder();
}

// Fetch all APs matching current filters (up to 2000)
async function fetchAllPackages(authFetch, { search, categoryFilter, sortCol, sortDir }) {
  const params = new URLSearchParams({ limit: 2000, offset: 0 });
  if (search) params.set('search', search);
  if (categoryFilter !== null) {
    if (categoryFilter === 'uncategorized') {
      params.set('uncategorized', 'true');
    } else {
      params.set('categoryId', categoryFilter);
    }
  }
  if (sortCol) { params.set('sortCol', sortCol); params.set('sortDir', sortDir); }
  const res = await authFetch(`/api/access-packages?${params}`);
  if (!res.ok) throw new Error('Failed to fetch access packages');
  const json = await res.json();
  return json.data;
}

// Fetch resource roles for a single AP, return comma-separated group names
async function fetchResourceNames(authFetch, apId) {
  try {
    const res = await authFetch(`/api/access-package/${apId}/resource-roles`);
    if (!res.ok) return '';
    const roles = await res.json();
    const names = roles.map(r => r.groupDisplayName || r.scopeDisplayName || '').filter(Boolean);
    // Deduplicate (a group can appear multiple times with different roles)
    return [...new Set(names)].join(', ');
  } catch {
    return '';
  }
}

export async function exportAccessPackagesToExcel({ authFetch, search, categoryFilter, sortCol, sortDir, typeFilter, onProgress }) {
  // 1. Fetch all matching APs
  onProgress?.('Fetching access packages...');
  const allPackages = await fetchAllPackages(authFetch, { search, categoryFilter, sortCol, sortDir });

  // Apply client-side type filter (same as the page does)
  const packages = typeFilter ? allPackages.filter(p => p.assignmentType === typeFilter) : allPackages;

  // 2. Fetch resource roles for all APs in parallel (batches of 10)
  onProgress?.('Fetching resource assignments...');
  const resourceNames = new Array(packages.length).fill('');
  const batchSize = 10;
  for (let i = 0; i < packages.length; i += batchSize) {
    const batch = packages.slice(i, i + batchSize);
    const results = await Promise.all(batch.map(p => fetchResourceNames(authFetch, p.id)));
    results.forEach((name, j) => { resourceNames[i + j] = name; });
    onProgress?.(`Fetching resource assignments... (${Math.min(i + batchSize, packages.length)}/${packages.length})`);
  }

  // 3. Build workbook
  onProgress?.('Building Excel file...');
  const wb = new ExcelJS.Workbook();
  wb.creator = 'FortigiGraph';
  wb.created = new Date();

  const ws = wb.addWorksheet('Access Packages');

  const columns = [
    { header: 'Name',                 key: 'displayName',      width: 40 },
    { header: 'Catalog',              key: 'catalogName',      width: 25 },
    { header: 'Category',             key: 'category',         width: 20 },
    { header: 'Type',                 key: 'assignmentType',   width: 30 },
    { header: 'Assignments',          key: 'totalAssignments', width: 14 },
    { header: 'Review Status',        key: 'complianceStatus', width: 22 },
    { header: 'Review Date',          key: 'lastReviewDate',   width: 16 },
    { header: 'Reviewed By',          key: 'lastReviewedBy',   width: 25 },
    { header: 'Description',          key: 'description',      width: 50 },
    { header: 'Resource Assignments', key: 'resources',        width: 60 },
  ];

  columns.forEach((col, i) => {
    ws.getColumn(i + 1).width = col.width;
  });

  // Header row
  const headerRow = ws.getRow(1);
  headerRow.height = 20;
  columns.forEach((col, i) => {
    setHeaderCell(ws.getCell(1, i + 1), col.header);
  });

  // Freeze header row
  ws.views = [{ state: 'frozen', xSplit: 0, ySplit: 1 }];

  // Data rows
  packages.forEach((pkg, idx) => {
    const rowNum = idx + 2;
    const row = ws.getRow(rowNum);
    row.height = 18;

    const values = [
      pkg.displayName || '',
      pkg.catalogName || '',
      pkg.category?.name || '',
      pkg.assignmentType || '',
      pkg.totalAssignments ?? '',
      pkg.complianceStatus || (pkg.hasReviewConfigured ? 'Pending first review' : 'Not required'),
      formatDate(pkg.lastReviewDate),
      pkg.lastReviewedBy || '',
      pkg.description || '',
      resourceNames[idx],
    ];

    values.forEach((val, i) => {
      const cell = ws.getCell(rowNum, i + 1);
      cell.value = val;
      cell.font = { size: 11 };
      cell.border = thinBorder();
      // Right-align the assignments count
      if (i === 4) cell.alignment = { horizontal: 'center' };
    });
  });

  // Auto-filter on header row
  ws.autoFilter = { from: { row: 1, column: 1 }, to: { row: 1, column: columns.length } };

  // Generate & download
  const buffer = await wb.xlsx.writeBuffer();
  const blob = new Blob([buffer], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `access-packages-${new Date().toISOString().slice(0, 10)}.xlsx`;
  a.click();
  URL.revokeObjectURL(url);
}
