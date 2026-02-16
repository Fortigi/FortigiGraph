import { useMemo, useState } from 'react';
import {
  useReactTable,
  getCoreRowModel,
  getFilteredRowModel,
  getGroupedRowModel,
  getExpandedRowModel,
  getSortedRowModel,
  getFacetedRowModel,
  getFacetedUniqueValues,
  flexRender,
} from '@tanstack/react-table';

const membershipColors = {
  Direct: 'membership-direct',
  Indirect: 'membership-indirect',
  Eligible: 'membership-eligible',
  Owner: 'membership-owner',
};

function ColumnFilter({ column }) {
  const columnFilterValue = column.getFilterValue();
  const facetedUniqueValues = column.getFacetedUniqueValues();

  const uniqueValues = useMemo(() => {
    return [...facetedUniqueValues.keys()]
      .filter(v => v != null && v !== '')
      .sort();
  }, [facetedUniqueValues]);

  // Use dropdown for low-cardinality columns
  if (uniqueValues.length <= 20) {
    return (
      <select
        value={columnFilterValue ?? ''}
        onChange={e => column.setFilterValue(e.target.value || undefined)}
        className="w-full px-1 py-0.5 text-xs border border-gray-300 rounded"
      >
        <option value="">All</option>
        {uniqueValues.map(val => (
          <option key={val} value={val}>{val}</option>
        ))}
      </select>
    );
  }

  // Use text input for high-cardinality columns
  return (
    <input
      type="text"
      value={columnFilterValue ?? ''}
      onChange={e => column.setFilterValue(e.target.value || undefined)}
      placeholder="Filter..."
      className="w-full px-1 py-0.5 text-xs border border-gray-300 rounded"
    />
  );
}

export default function PermissionGrid({ data }) {
  const [sorting, setSorting] = useState([]);
  const [columnFilters, setColumnFilters] = useState([]);
  const [grouping, setGrouping] = useState([]);
  const [expanded, setExpanded] = useState({});

  const columns = useMemo(() => [
    {
      accessorKey: 'memberDisplayName',
      header: 'User',
      enableGrouping: true,
      size: 180,
    },
    {
      accessorKey: 'memberUPN',
      header: 'UPN',
      size: 220,
    },
    {
      accessorKey: 'department',
      header: 'Department',
      enableGrouping: true,
      size: 120,
    },
    {
      accessorKey: 'jobTitle',
      header: 'Job Title',
      enableGrouping: true,
      size: 150,
    },
    {
      accessorKey: 'groupDisplayName',
      header: 'Group',
      enableGrouping: true,
      size: 200,
    },
    {
      accessorKey: 'membershipType',
      header: 'Type',
      enableGrouping: true,
      size: 100,
      cell: ({ getValue }) => {
        const value = getValue();
        return (
          <span className={`px-2 py-0.5 rounded text-xs font-medium ${membershipColors[value] || ''}`}>
            {value}
          </span>
        );
      },
    },
  ], []);

  const table = useReactTable({
    data,
    columns,
    state: { sorting, columnFilters, grouping, expanded },
    onSortingChange: setSorting,
    onColumnFiltersChange: setColumnFilters,
    onGroupingChange: setGrouping,
    onExpandedChange: setExpanded,
    getCoreRowModel: getCoreRowModel(),
    getFilteredRowModel: getFilteredRowModel(),
    getSortedRowModel: getSortedRowModel(),
    getGroupedRowModel: getGroupedRowModel(),
    getExpandedRowModel: getExpandedRowModel(),
    getFacetedRowModel: getFacetedRowModel(),
    getFacetedUniqueValues: getFacetedUniqueValues(),
    enableGrouping: true,
  });

  const groupableColumns = columns.filter(c => c.enableGrouping);

  return (
    <div className="flex flex-col gap-3">
      {/* Grouping controls */}
      <div className="flex items-center gap-2 text-sm">
        <span className="font-medium text-gray-700">Group by:</span>
        {groupableColumns.map(col => {
          const isGrouped = grouping.includes(col.accessorKey);
          return (
            <button
              key={col.accessorKey}
              onClick={() => {
                setGrouping(prev =>
                  isGrouped
                    ? prev.filter(g => g !== col.accessorKey)
                    : [...prev, col.accessorKey]
                );
              }}
              className={`px-2 py-1 rounded text-xs font-medium border transition-colors ${
                isGrouped
                  ? 'bg-blue-100 text-blue-800 border-blue-300'
                  : 'bg-white text-gray-600 border-gray-300 hover:bg-gray-50'
              }`}
            >
              {col.header}
            </button>
          );
        })}
        {grouping.length > 0 && (
          <button
            onClick={() => setGrouping([])}
            className="px-2 py-1 rounded text-xs text-red-600 hover:bg-red-50"
          >
            Clear
          </button>
        )}
      </div>

      {/* Stats bar */}
      <div className="text-xs text-gray-500">
        {table.getFilteredRowModel().rows.length} of {data.length} assignments shown
      </div>

      {/* Table */}
      <div className="border border-gray-200 rounded-lg overflow-auto max-h-[calc(100vh-280px)]">
        <table className="w-full text-sm">
          <thead className="bg-gray-50 sticky top-0 z-10">
            {table.getHeaderGroups().map(headerGroup => (
              <tr key={headerGroup.id}>
                {headerGroup.headers.map(header => (
                  <th
                    key={header.id}
                    className="px-3 py-2 text-left font-medium text-gray-700 border-b border-gray-200"
                    style={{ width: header.getSize() }}
                  >
                    {header.isPlaceholder ? null : (
                      <div className="flex flex-col gap-1">
                        <div
                          className={`flex items-center gap-1 ${
                            header.column.getCanSort() ? 'cursor-pointer select-none hover:text-blue-600' : ''
                          }`}
                          onClick={header.column.getToggleSortingHandler()}
                        >
                          {flexRender(header.column.columnDef.header, header.getContext())}
                          {{ asc: ' \u2191', desc: ' \u2193' }[header.column.getIsSorted()] ?? ''}
                        </div>
                        {header.column.getCanFilter() && (
                          <ColumnFilter column={header.column} />
                        )}
                      </div>
                    )}
                  </th>
                ))}
              </tr>
            ))}
          </thead>
          <tbody>
            {table.getRowModel().rows.map(row => (
              <tr
                key={row.id}
                className="hover:bg-gray-50 border-b border-gray-100"
              >
                {row.getVisibleCells().map(cell => {
                  const rawVal = row.original?.managedByAccessPackage;
                  const managed = !!rawVal && rawVal !== '0' && rawVal !== 'false';
                  return (
                  <td key={cell.id} className="px-3 py-1.5" style={managed ? { color: '#dc2626' } : undefined}>
                    {cell.getIsGrouped() ? (
                      <button
                        onClick={row.getToggleExpandedHandler()}
                        className="flex items-center gap-1 font-medium text-blue-700"
                      >
                        {row.getIsExpanded() ? '\u25BC' : '\u25B6'}{' '}
                        {flexRender(cell.column.columnDef.cell, cell.getContext())}
                        <span className="text-xs text-gray-500 font-normal">
                          ({row.subRows.length})
                        </span>
                      </button>
                    ) : cell.getIsAggregated() ? (
                      flexRender(
                        cell.column.columnDef.aggregatedCell ?? cell.column.columnDef.cell,
                        cell.getContext()
                      )
                    ) : cell.getIsPlaceholder() ? null : (
                      flexRender(cell.column.columnDef.cell, cell.getContext())
                    )}
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
