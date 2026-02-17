import ExcelJS from 'exceljs';

/**
 * Exports the matrix view to an Excel workbook matching the on-screen layout.
 *
 * Layout:
 *   Row 1: (3 blank info cols) | Job Title merged headers | # | % | Type | Description
 *   Row 2: (empty) | Category | Group Name | user names... | # | % | Type | Description
 *   Row 3+: group rows with colored cells
 *
 * Plus a "Legend" sheet showing membership types and active filters.
 */

function hexToArgb(hex) {
  // Strip # and convert to ARGB (FF prefix for full opacity)
  const clean = hex.replace('#', '');
  if (clean.length === 6) return 'FF' + clean.toUpperCase();
  if (clean.length === 8) return clean.toUpperCase();
  return 'FFFFFFFF';
}

// Membership type colors (matching MatrixCell TYPE_INDICATORS)
const TYPE_COLORS = {
  Direct:   { bg: '166534', text: 'FFFFFF' },
  Indirect: { bg: '1E40AF', text: 'FFFFFF' },
  Eligible: { bg: '854D0E', text: 'FFFFFF' },
  Owner:    { bg: '9D174D', text: 'FFFFFF' },
};

export async function exportToExcel({ users, orderedGroups, memberships, managedApMap, apIdToIndex, activeFilters, filterFields, accessPackages = [], apGroupMap }) {
  const wb = new ExcelJS.Workbook();
  wb.creator = 'FortigiGraph Role Mining';
  wb.created = new Date();

  const ws = wb.addWorksheet('Role Mining Matrix', {
    views: [{ state: 'frozen', xSplit: 3, ySplit: 2 }],
  });

  const infoColCount = 3; // (empty) | Category | Group Name
  const userCount = users.length;
  const metaColStart = infoColCount + userCount + 1; // 1-based

  // ---------- Column widths ----------
  ws.getColumn(1).width = 4;   // empty / drag handle
  ws.getColumn(2).width = 14;  // Category
  ws.getColumn(3).width = 35;  // Group Name
  for (let u = 0; u < userCount; u++) {
    ws.getColumn(infoColCount + u + 1).width = 4;
  }
  ws.getColumn(metaColStart).width = 5;     // #
  ws.getColumn(metaColStart + 1).width = 6;  // %
  ws.getColumn(metaColStart + 2).width = 10; // Type
  ws.getColumn(metaColStart + 3).width = 30; // Description

  // Access package columns start after metadata
  const apColStart = metaColStart + 4; // 1-based
  const apCount = accessPackages.length;
  for (let a = 0; a < apCount; a++) {
    ws.getColumn(apColStart + a).width = 4;
  }

  // ===== ROW 1: Job titles (merged) =====
  const row1 = ws.getRow(1);
  row1.height = 90;

  // Build job title spans from ordered users
  const jobTitleSpans = [];
  let i = 0;
  while (i < users.length) {
    const title = users[i].jobTitle || '';
    let span = 1;
    while (i + span < users.length && (users[i + span].jobTitle || '') === title) {
      span++;
    }
    jobTitleSpans.push({ title, span, startIndex: i });
    i += span;
  }

  // Merge & style job title header cells (neutral gray)
  for (const jts of jobTitleSpans) {
    const startCol = infoColCount + jts.startIndex + 1;
    const endCol = startCol + jts.span - 1;
    if (jts.span > 1) {
      ws.mergeCells(1, startCol, 1, endCol);
    }
    const cell = ws.getCell(1, startCol);
    cell.value = jts.title || '(no title)';
    cell.font = { size: 8, bold: true };
    cell.alignment = { textRotation: 90, vertical: 'bottom', horizontal: 'center' };
    cell.fill = {
      type: 'pattern',
      pattern: 'solid',
      fgColor: { argb: 'FFF3F4F6' },
    };
    cell.border = thinBorder();
  }

  // Row 1 meta headers
  setHeaderCell(ws.getCell(1, metaColStart), '#', true);
  setHeaderCell(ws.getCell(1, metaColStart + 1), '%', true);
  setHeaderCell(ws.getCell(1, metaColStart + 2), 'Type', true);
  setHeaderCell(ws.getCell(1, metaColStart + 3), 'Description', true);

  // Row 1 access package banner
  if (apCount > 0) {
    if (apCount > 1) {
      ws.mergeCells(1, apColStart, 1, apColStart + apCount - 1);
    }
    const apBanner = ws.getCell(1, apColStart);
    apBanner.value = 'Access Packages (SOLL)';
    apBanner.font = { size: 8, bold: true, color: { argb: 'FF3730A3' } };
    apBanner.alignment = { textRotation: 90, vertical: 'bottom', horizontal: 'center' };
    apBanner.fill = {
      type: 'pattern',
      pattern: 'solid',
      fgColor: { argb: 'FFE0E7FF' },
    };
    apBanner.border = thinBorder();
  }

  // ===== ROW 2: User display names =====
  const row2 = ws.getRow(2);
  row2.height = 80;

  setHeaderCell(ws.getCell(2, 1), '');
  setHeaderCell(ws.getCell(2, 2), 'Category');
  setHeaderCell(ws.getCell(2, 3), 'Group Name');

  for (let u = 0; u < userCount; u++) {
    const cell = ws.getCell(2, infoColCount + u + 1);
    cell.value = users[u].displayName;
    cell.font = { size: 7, bold: false };
    cell.alignment = { textRotation: 90, vertical: 'bottom', horizontal: 'center' };
    cell.fill = {
      type: 'pattern',
      pattern: 'solid',
      fgColor: { argb: 'FFF3F4F6' },
    };
    cell.border = thinBorder();

    // Add user details as comment
    const comment = [users[u].upn, users[u].jobTitle, users[u].department].filter(Boolean).join('\n');
    if (comment) {
      cell.note = comment;
    }
  }

  // Row 2 access package name headers (each AP gets a distinct color)
  for (let a = 0; a < apCount; a++) {
    const cell = ws.getCell(2, apColStart + a);
    cell.value = accessPackages[a].displayName;
    cell.font = { size: 7, bold: false };
    cell.alignment = { textRotation: 90, vertical: 'bottom', horizontal: 'center' };
    cell.fill = {
      type: 'pattern',
      pattern: 'solid',
      fgColor: { argb: hexToArgb(getApColorHex(a)) },
    };
    cell.border = thinBorder();
    if (accessPackages[a].catalogName) {
      cell.note = `Catalog: ${accessPackages[a].catalogName}`;
    }
  }

  // ===== ROW 3+: Group rows =====
  orderedGroups.forEach((group, gIdx) => {
    const rowNum = gIdx + 3;
    const row = ws.getRow(rowNum);
    row.height = 18;

    // Info columns
    ws.getCell(rowNum, 1).border = thinBorder();
    const catCell = ws.getCell(rowNum, 2);
    catCell.value = group.category;
    catCell.font = { size: 8 };
    catCell.border = thinBorder();

    const nameCell = ws.getCell(rowNum, 3);
    nameCell.value = group.displayName;
    nameCell.font = { size: 8, bold: true };
    nameCell.border = thinBorder();

    // Intersection cells
    for (let u = 0; u < userCount; u++) {
      const cellKey = `${group.id}|${users[u].id}`;
      const memberTypes = memberships.get(cellKey);
      const hasMembership = memberTypes && memberTypes.size > 0;

      const excelCell = ws.getCell(rowNum, infoColCount + u + 1);

      // Cell content
      if (hasMembership) {
        const types = [...memberTypes];
        const letters = types.map(t => TYPE_COLORS[t] ? t.charAt(0) : '?').join('');
        excelCell.value = letters;
        excelCell.font = { size: 7, bold: true, color: { argb: 'FFFFFFFF' } };
        excelCell.alignment = { horizontal: 'center', vertical: 'middle' };

        // Use the first type's background color for the letter
        if (types.length === 1 && TYPE_COLORS[types[0]]) {
          excelCell.font = { size: 7, bold: true, color: { argb: 'FF' + TYPE_COLORS[types[0]].text } };
        }
      }

      // Cell background: AP color for managed cells, green for unmanaged
      if (hasMembership) {
        const apIds = managedApMap?.get(cellKey) || managedApMap?.get(`${group.id.toUpperCase()}|${users[u].id}`);
        let bgArgb = 'FFDCFCE7'; // default: light green (unmanaged)
        if (apIds && apIds.length > 0 && apIdToIndex) {
          const firstIdx = apIdToIndex.get(apIds[0]);
          if (firstIdx != null) {
            bgArgb = hexToArgb(getApColorHex(firstIdx));
          } else {
            bgArgb = 'FFDBEAFE'; // fallback blue for managed without index
          }
          if (apIds.length > 1) {
            excelCell.note = `Managed by: ${apIds.length} access packages`;
          }
        }
        excelCell.fill = {
          type: 'pattern',
          pattern: 'solid',
          fgColor: { argb: bgArgb },
        };
      }

      excelCell.border = thinBorder();
    }

    // Meta columns
    const memberCount = group.memberCount;
    const pct = userCount > 0 ? Math.round((memberCount / userCount) * 100) : 0;

    const countCell = ws.getCell(rowNum, metaColStart);
    countCell.value = memberCount;
    countCell.font = { size: 8 };
    countCell.alignment = { horizontal: 'center' };
    countCell.border = thinBorder();

    const pctCell = ws.getCell(rowNum, metaColStart + 1);
    pctCell.value = pct / 100;
    pctCell.numFmt = '0%';
    pctCell.font = {
      size: 8,
      color: { argb: pct === 100 ? 'FF166534' : pct >= 75 ? 'FF854D0E' : 'FF000000' },
    };
    pctCell.alignment = { horizontal: 'center' };
    pctCell.border = thinBorder();

    const typeCell = ws.getCell(rowNum, metaColStart + 2);
    typeCell.value = group.groupType || '';
    typeCell.font = { size: 8 };
    typeCell.border = thinBorder();

    const descCell = ws.getCell(rowNum, metaColStart + 3);
    descCell.value = group.description;
    descCell.font = { size: 8, color: { argb: 'FF666666' } };
    descCell.border = thinBorder();

    // Access package cells (each AP column uses its own color)
    for (let a = 0; a < apCount; a++) {
      const apKey = `${group.id}|${accessPackages[a].id}`;
      const roleName = apGroupMap?.get(apKey);
      const apCell = ws.getCell(rowNum, apColStart + a);

      if (roleName) {
        apCell.value = roleName === 'Owner' ? 'O' : 'M';
        apCell.font = { size: 7, bold: true };
        apCell.alignment = { horizontal: 'center', vertical: 'middle' };
        apCell.fill = {
          type: 'pattern',
          pattern: 'solid',
          fgColor: { argb: hexToArgb(getApColorHex(a)) },
        };
      }
      apCell.border = thinBorder();
    }
  });

  // ===== Legend Sheet =====
  const legendWs = wb.addWorksheet('Legend');
  legendWs.getColumn(1).width = 18;
  legendWs.getColumn(2).width = 10;
  legendWs.getColumn(3).width = 14;

  // Membership type legend
  setHeaderCell(legendWs.getCell(1, 1), 'Membership Type');
  setHeaderCell(legendWs.getCell(1, 2), 'Letter');
  setHeaderCell(legendWs.getCell(1, 3), 'Color');

  Object.entries(TYPE_COLORS).forEach(([type, colors], idx) => {
    const r = idx + 2;
    legendWs.getCell(r, 1).value = type;
    legendWs.getCell(r, 1).font = { size: 9 };
    legendWs.getCell(r, 1).border = thinBorder();

    legendWs.getCell(r, 2).value = type.charAt(0);
    legendWs.getCell(r, 2).font = { size: 9, bold: true, color: { argb: 'FF' + colors.text } };
    legendWs.getCell(r, 2).fill = {
      type: 'pattern',
      pattern: 'solid',
      fgColor: { argb: 'FF' + colors.bg },
    };
    legendWs.getCell(r, 2).alignment = { horizontal: 'center' };
    legendWs.getCell(r, 2).border = thinBorder();

    legendWs.getCell(r, 3).value = '#' + colors.bg;
    legendWs.getCell(r, 3).font = { size: 9 };
    legendWs.getCell(r, 3).border = thinBorder();
  });

  // Filters info
  if (activeFilters && activeFilters.length > 0) {
    const filterStart = Object.keys(TYPE_COLORS).length + 3;
    setHeaderCell(legendWs.getCell(filterStart, 1), 'Active Filters');
    setHeaderCell(legendWs.getCell(filterStart, 2), 'Value');

    activeFilters.forEach((af, idx) => {
      const r = filterStart + idx + 1;
      const field = filterFields?.find(f => f.key === af.field);
      legendWs.getCell(r, 1).value = field?.label || af.field;
      legendWs.getCell(r, 1).font = { size: 9, bold: true };
      legendWs.getCell(r, 1).border = thinBorder();

      legendWs.getCell(r, 2).value = af.value;
      legendWs.getCell(r, 2).font = { size: 9 };
      legendWs.getCell(r, 2).border = thinBorder();
    });
  }

  // ===== Generate & download =====
  const buffer = await wb.xlsx.writeBuffer();
  const blob = new Blob([buffer], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  const filterLabel = activeFilters?.length > 0
    ? activeFilters.map(f => f.value).join('-')
    : 'all';
  a.download = `role-mining-${filterLabel}-${new Date().toISOString().slice(0, 10)}.xlsx`;
  a.click();
  URL.revokeObjectURL(url);
}

// ---------- Helpers ----------

function thinBorder() {
  return {
    top: { style: 'thin', color: { argb: 'FFD1D5DB' } },
    left: { style: 'thin', color: { argb: 'FFD1D5DB' } },
    bottom: { style: 'thin', color: { argb: 'FFD1D5DB' } },
    right: { style: 'thin', color: { argb: 'FFD1D5DB' } },
  };
}

function setHeaderCell(cell, value, rotated = false) {
  cell.value = value;
  cell.font = { size: 8, bold: true, color: { argb: 'FF374151' } };
  cell.fill = {
    type: 'pattern',
    pattern: 'solid',
    fgColor: { argb: 'FFF3F4F6' },
  };
  cell.border = thinBorder();
  if (rotated) {
    cell.alignment = { textRotation: 90, vertical: 'bottom', horizontal: 'center' };
  }
}

// Access package color palette (matches MatrixColumnHeaders AP_COLORS)
const AP_COLORS_HEX = [
  '#fde68a', '#a7f3d0', '#bfdbfe', '#ddd6fe', '#fbcfe8',
  '#fed7aa', '#99f6e4', '#c7d2fe', '#fecdd3', '#d9f99d',
  '#fef08a', '#a5f3fc', '#c4b5fd', '#fda4af', '#bef264',
];

function getApColorHex(index) {
  return AP_COLORS_HEX[index % AP_COLORS_HEX.length];
}
