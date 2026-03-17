import ExcelJS from 'exceljs';

function formatDate(dateStr) {
  if (!dateStr) return '';
  const d = new Date(dateStr);
  return d.toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' });
}

function thinBorder(omitBottom = false, omitTop = false) {
  return {
    top:    omitTop    ? undefined : { style: 'thin', color: { argb: 'FFD1D5DB' } },
    left:   { style: 'thin', color: { argb: 'FFD1D5DB' } },
    bottom: omitBottom ? undefined : { style: 'thin', color: { argb: 'FFD1D5DB' } },
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

// Fetch resource roles for a single AP — returns array of "Group (Role)" strings
async function fetchResourceRoles(authFetch, apId) {
  try {
    const res = await authFetch(`/api/access-package/${apId}/resource-roles`);
    if (!res.ok) return [];
    const roles = await res.json();
    return roles.map(r => {
      const name = r.groupDisplayName || r.scopeDisplayName || '';
      const role = r.roleDisplayName || '';
      return name ? (role ? `${name} (${role})` : name) : '';
    }).filter(Boolean);
  } catch {
    return [];
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
  const resourceRoles = new Array(packages.length).fill(null).map(() => []);
  const batchSize = 10;
  for (let i = 0; i < packages.length; i += batchSize) {
    const batch = packages.slice(i, i + batchSize);
    const results = await Promise.all(batch.map(p => fetchResourceRoles(authFetch, p.id)));
    results.forEach((roles, j) => { resourceRoles[i + j] = roles; });
    onProgress?.(`Fetching resource assignments... (${Math.min(i + batchSize, packages.length)}/${packages.length})`);
  }

  // 3. Build workbook
  onProgress?.('Building Excel file...');
  const wb = new ExcelJS.Workbook();
  wb.creator = 'FortigiGraph';
  wb.created = new Date();

  const ws = wb.addWorksheet('Access Packages');

  const columns = [
    { header: 'Name',          width: 40 },
    { header: 'Catalog',       width: 25 },
    { header: 'Category',      width: 20 },
    { header: 'Type',          width: 30 },
    { header: 'Assignments',   width: 14 },
    { header: 'Review Status', width: 22 },
    { header: 'Review Date',   width: 16 },
    { header: 'Reviewed By',   width: 25 },
    { header: 'Description',   width: 50 },
    { header: 'Group',         width: 45 },
    { header: 'Role',          width: 15 },
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

  // AP detail columns (0-based indices 0..8)
  const AP_COL_COUNT = 9;

  let rowNum = 2;

  packages.forEach((pkg, idx) => {
    const roles = resourceRoles[idx];
    const rowCount = Math.max(roles.length, 1);
    const startRow = rowNum;

    const apValues = [
      pkg.displayName || '',
      pkg.catalogName || '',
      pkg.category?.name || '',
      pkg.assignmentType || '',
      pkg.totalAssignments ?? '',
      pkg.complianceStatus || (pkg.hasReviewConfigured ? 'Pending first review' : 'Not required'),
      formatDate(pkg.lastReviewDate),
      pkg.lastReviewedBy || '',
      pkg.description || '',
    ];

    for (let r = 0; r < rowCount; r++) {
      const currentRow = ws.getRow(rowNum);
      currentRow.height = 18;

      // AP detail columns — only write value on first row; all rows get border
      apValues.forEach((val, c) => {
        const cell = ws.getCell(rowNum, c + 1);
        if (r === 0) cell.value = val;
        cell.font = { size: 11 };
        // Border: suppress bottom on non-last rows and top on non-first rows so merged block looks clean
        cell.border = thinBorder(r < rowCount - 1, r > 0);
        if (c === 4) cell.alignment = { horizontal: 'center', vertical: 'top' };
        else cell.alignment = { vertical: 'top', wrapText: c === 8 };
      });

      // Group & Role columns
      if (roles.length > 0) {
        const entry = roles[r] || '';
        // entry is "GroupName (Role)" — split into separate cells
        const parenIdx = entry.lastIndexOf(' (');
        let groupName = entry;
        let roleName = '';
        if (parenIdx !== -1 && entry.endsWith(')')) {
          groupName = entry.slice(0, parenIdx);
          roleName = entry.slice(parenIdx + 2, -1);
        }

        const groupCell = ws.getCell(rowNum, AP_COL_COUNT + 1);
        groupCell.value = groupName;
        groupCell.font = { size: 11 };
        groupCell.border = thinBorder();

        const roleCell = ws.getCell(rowNum, AP_COL_COUNT + 2);
        roleCell.value = roleName;
        roleCell.font = { size: 11 };
        roleCell.border = thinBorder();
        if (roleName === 'Owner') {
          roleCell.font = { size: 11, color: { argb: 'FF6B21A8' } }; // purple
        } else if (roleName === 'Member') {
          roleCell.font = { size: 11, color: { argb: 'FF1D4ED8' } }; // blue
        }
      } else {
        // No resources — empty cells with border
        for (let c = AP_COL_COUNT; c < columns.length; c++) {
          const cell = ws.getCell(rowNum, c + 1);
          cell.border = thinBorder();
        }
      }

      rowNum++;
    }

    // Merge AP detail columns vertically when there are multiple resource rows
    if (rowCount > 1) {
      for (let c = 0; c < AP_COL_COUNT; c++) {
        ws.mergeCells(startRow, c + 1, startRow + rowCount - 1, c + 1);
        // Re-apply alignment on the merged cell (merging resets it)
        const cell = ws.getCell(startRow, c + 1);
        cell.alignment = { vertical: 'top', wrapText: c === 8, horizontal: c === 4 ? 'center' : undefined };
      }
    }
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
