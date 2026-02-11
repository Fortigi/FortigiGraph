import { useMemo, useState } from 'react';

const membershipColors = {
  Direct:   { bg: '#dcfce7', text: '#166534', label: 'D' },
  Indirect: { bg: '#dbeafe', text: '#1e40af', label: 'I' },
  Eligible: { bg: '#fef9c3', text: '#854d0e', label: 'E' },
  Owner:    { bg: '#fce7f3', text: '#9d174d', label: 'O' },
};

export default function MatrixView({ data }) {
  const [rowAxis, setRowAxis] = useState('groupDisplayName');
  const [colAxis, setColAxis] = useState('memberDisplayName');
  const [filterText, setFilterText] = useState('');
  const [filterDept, setFilterDept] = useState('');

  // Derive available departments for filtering
  const departments = useMemo(() => {
    const depts = new Set();
    data.forEach(d => { if (d.department) depts.add(d.department); });
    return [...depts].sort();
  }, [data]);

  // Filter data
  const filteredData = useMemo(() => {
    let result = data;
    if (filterDept) {
      result = result.filter(d => d.department === filterDept);
    }
    if (filterText) {
      const lower = filterText.toLowerCase();
      result = result.filter(d =>
        (d.memberDisplayName || '').toLowerCase().includes(lower) ||
        (d.groupDisplayName || '').toLowerCase().includes(lower) ||
        (d.memberUPN || '').toLowerCase().includes(lower)
      );
    }
    return result;
  }, [data, filterDept, filterText]);

  // Build the matrix
  const { rowLabels, colLabels, matrix } = useMemo(() => {
    const rowSet = new Map();
    const colSet = new Map();
    const cells = new Map(); // key: "rowVal|colVal" -> { types: Set, user?, group? }

    filteredData.forEach(d => {
      const rowVal = d[rowAxis] || '(unknown)';
      const colVal = d[colAxis] || '(unknown)';

      if (!rowSet.has(rowVal)) rowSet.set(rowVal, rowSet.size);
      if (!colSet.has(colVal)) colSet.set(colVal, colSet.size);

      const key = `${rowVal}|${colVal}`;
      if (!cells.has(key)) {
        cells.set(key, { types: new Set() });
      }
      cells.get(key).types.add(d.membershipType);
    });

    const rowLabels = [...rowSet.keys()].sort();
    const colLabels = [...colSet.keys()].sort();

    return { rowLabels, colLabels, matrix: cells };
  }, [filteredData, rowAxis, colAxis]);

  // Limit rendering for performance
  const maxCols = 50;
  const maxRows = 200;
  const displayCols = colLabels.slice(0, maxCols);
  const displayRows = rowLabels.slice(0, maxRows);
  const truncatedCols = colLabels.length > maxCols;
  const truncatedRows = rowLabels.length > maxRows;

  const axisOptions = [
    { value: 'memberDisplayName', label: 'User' },
    { value: 'department', label: 'Department' },
    { value: 'jobTitle', label: 'Job Title' },
    { value: 'groupDisplayName', label: 'Group' },
    { value: 'membershipType', label: 'Membership Type' },
  ];

  return (
    <div className="flex flex-col gap-3">
      {/* Controls */}
      <div className="flex flex-wrap items-center gap-4 text-sm">
        <div className="flex items-center gap-2">
          <label className="font-medium text-gray-700">Rows:</label>
          <select
            value={rowAxis}
            onChange={e => setRowAxis(e.target.value)}
            className="px-2 py-1 border border-gray-300 rounded text-sm"
          >
            {axisOptions.filter(o => o.value !== colAxis).map(o => (
              <option key={o.value} value={o.value}>{o.label}</option>
            ))}
          </select>
        </div>
        <div className="flex items-center gap-2">
          <label className="font-medium text-gray-700">Columns:</label>
          <select
            value={colAxis}
            onChange={e => setColAxis(e.target.value)}
            className="px-2 py-1 border border-gray-300 rounded text-sm"
          >
            {axisOptions.filter(o => o.value !== rowAxis).map(o => (
              <option key={o.value} value={o.value}>{o.label}</option>
            ))}
          </select>
        </div>
        <div className="flex items-center gap-2">
          <label className="font-medium text-gray-700">Department:</label>
          <select
            value={filterDept}
            onChange={e => setFilterDept(e.target.value)}
            className="px-2 py-1 border border-gray-300 rounded text-sm"
          >
            <option value="">All</option>
            {departments.map(d => (
              <option key={d} value={d}>{d}</option>
            ))}
          </select>
        </div>
        <div className="flex items-center gap-2">
          <label className="font-medium text-gray-700">Search:</label>
          <input
            type="text"
            value={filterText}
            onChange={e => setFilterText(e.target.value)}
            placeholder="Filter users or groups..."
            className="px-2 py-1 border border-gray-300 rounded text-sm w-48"
          />
        </div>
      </div>

      {/* Stats & Legend */}
      <div className="flex items-center justify-between text-xs text-gray-500">
        <span>
          {displayRows.length} rows x {displayCols.length} columns
          {(truncatedRows || truncatedCols) && ' (use filters to narrow down)'}
        </span>
        <div className="flex items-center gap-3">
          {Object.entries(membershipColors).map(([type, color]) => (
            <span key={type} className="flex items-center gap-1">
              <span
                className="inline-block w-4 h-4 rounded text-center text-[10px] font-bold leading-4"
                style={{ backgroundColor: color.bg, color: color.text }}
              >
                {color.label}
              </span>
              {type}
            </span>
          ))}
        </div>
      </div>

      {/* Matrix table */}
      <div className="border border-gray-200 rounded-lg overflow-auto max-h-[calc(100vh-300px)]">
        <table className="text-xs border-collapse">
          <thead className="sticky top-0 z-10 bg-gray-50">
            <tr>
              <th className="sticky left-0 z-20 bg-gray-100 px-3 py-2 text-left font-medium text-gray-700 border-b border-r border-gray-200 min-w-[180px]">
                {axisOptions.find(o => o.value === rowAxis)?.label} / {axisOptions.find(o => o.value === colAxis)?.label}
              </th>
              {displayCols.map(col => (
                <th
                  key={col}
                  className="px-1 py-2 font-medium text-gray-600 border-b border-gray-200 whitespace-nowrap"
                  style={{ writingMode: 'vertical-lr', textOrientation: 'mixed', maxHeight: '160px' }}
                  title={col}
                >
                  {col}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {displayRows.map(row => (
              <tr key={row} className="hover:bg-gray-50/50">
                <td className="sticky left-0 bg-white px-3 py-1 font-medium text-gray-700 border-r border-b border-gray-200 whitespace-nowrap">
                  {row}
                </td>
                {displayCols.map(col => {
                  const cell = matrix.get(`${row}|${col}`);
                  if (!cell) {
                    return <td key={col} className="border-b border-gray-100 px-1 py-1" />;
                  }
                  const types = [...cell.types];
                  return (
                    <td
                      key={col}
                      className="border-b border-gray-100 px-0.5 py-0.5 text-center"
                      title={`${row} - ${col}: ${types.join(', ')}`}
                    >
                      <div className="flex gap-px justify-center">
                        {types.map(t => {
                          const color = membershipColors[t] || { bg: '#e5e7eb', text: '#374151', label: '?' };
                          return (
                            <span
                              key={t}
                              className="inline-block w-4 h-4 rounded text-[10px] font-bold leading-4 text-center"
                              style={{ backgroundColor: color.bg, color: color.text }}
                            >
                              {color.label}
                            </span>
                          );
                        })}
                      </div>
                    </td>
                  );
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
