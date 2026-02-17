import { useState, useMemo } from 'react';

export default function MatrixToolbar({
  filterFields,
  activeFilters,
  getOptionsForField,
  onAddFilter,
  onRemoveFilter,
  onClearAllFilters,
  filterText,
  setFilterText,
  managedFilter,
  setManagedFilter,
  userLimit,
  setUserLimit,
  onExportExcel,
  onResetRowOrder,
  hasCustomRowOrder,
  stats,
}) {
  const [addingFilter, setAddingFilter] = useState(false);
  const [newFilterField, setNewFilterField] = useState('');

  // Fields not yet used in active filters
  const availableFields = useMemo(() => {
    const usedFields = new Set(activeFilters.map(f => f.field));
    return filterFields.filter(f => !usedFields.has(f.key));
  }, [filterFields, activeFilters]);

  // Options for the field being added
  const newFilterOptions = useMemo(() => {
    if (!newFilterField) return [];
    return getOptionsForField(newFilterField);
  }, [newFilterField, getOptionsForField]);

  const handleAddFilterValue = (value) => {
    if (newFilterField && value) {
      onAddFilter(newFilterField, value);
    }
    setAddingFilter(false);
    setNewFilterField('');
  };

  return (
    <div className="flex flex-col gap-2">
      {/* Row 1: Active filters + add filter + controls */}
      <div className="flex flex-wrap items-center gap-2 text-sm">
        <span className="font-medium text-gray-700">Filters:</span>

        {/* Active filter pills */}
        {activeFilters.map(af => {
          const field = filterFields.find(f => f.key === af.field);
          return (
            <span
              key={af.field}
              className="inline-flex items-center gap-1 px-2 py-1 bg-blue-50 border border-blue-200 rounded text-xs"
            >
              <span className="font-medium text-blue-700">{field?.label || af.field}:</span>
              <select
                value={af.value}
                onChange={e => onAddFilter(af.field, e.target.value)}
                className="bg-transparent border-none text-blue-900 text-xs font-medium cursor-pointer p-0 pr-4"
              >
                {getOptionsForField(af.field).map(v => (
                  <option key={v} value={v}>{v}</option>
                ))}
              </select>
              <button
                onClick={() => onRemoveFilter(af.field)}
                className="text-blue-400 hover:text-blue-700 font-bold ml-0.5"
                title="Remove filter"
              >
                &times;
              </button>
            </span>
          );
        })}

        {/* Add filter button / inline selector */}
        {addingFilter ? (
          <span className="inline-flex items-center gap-1 px-2 py-1 bg-gray-50 border border-gray-300 rounded text-xs">
            <select
              autoFocus
              value={newFilterField}
              onChange={e => setNewFilterField(e.target.value)}
              className="bg-transparent border-none text-xs p-0 pr-4"
            >
              <option value="">Select field...</option>
              {availableFields.map(f => (
                <option key={f.key} value={f.key}>{f.label}</option>
              ))}
            </select>
            {newFilterField && (
              <>
                <span className="text-gray-400">=</span>
                <select
                  value=""
                  onChange={e => handleAddFilterValue(e.target.value)}
                  className="bg-transparent border-none text-xs p-0 pr-4"
                >
                  <option value="">Select value...</option>
                  {newFilterOptions.map(v => (
                    <option key={v} value={v}>{v}</option>
                  ))}
                </select>
              </>
            )}
            <button
              onClick={() => { setAddingFilter(false); setNewFilterField(''); }}
              className="text-gray-400 hover:text-gray-700 font-bold"
            >
              &times;
            </button>
          </span>
        ) : (
          availableFields.length > 0 && (
            <button
              onClick={() => setAddingFilter(true)}
              className="px-2 py-1 rounded text-xs text-blue-600 hover:bg-blue-50 border border-blue-200 border-dashed"
            >
              + Add filter
            </button>
          )
        )}

        {activeFilters.length > 1 && (
          <button
            onClick={onClearAllFilters}
            className="px-2 py-1 rounded text-xs text-gray-500 hover:bg-gray-100"
            title="Clear all filters"
          >
            Clear all
          </button>
        )}

        <div className="border-l border-gray-300 h-5 mx-1" />

        <div className="flex items-center gap-2">
          <input
            type="text"
            value={filterText}
            onChange={e => setFilterText(e.target.value)}
            placeholder="Search users or groups..."
            className="px-2 py-1 border border-gray-300 rounded text-xs w-44"
          />
        </div>

        <div className="border-l border-gray-300 h-5 mx-1" />

        <div className="inline-flex rounded border border-gray-300 overflow-hidden">
          {[
            { key: 'all',       label: 'All' },
            { key: 'unmanaged', label: 'Unmanaged' },
            { key: 'managed',   label: 'Managed' },
          ].map(opt => (
            <button
              key={opt.key}
              onClick={() => setManagedFilter(opt.key)}
              className={`px-2 py-1 text-xs font-medium transition-colors ${
                managedFilter === opt.key
                  ? 'bg-blue-600 text-white'
                  : 'bg-white text-gray-600 hover:bg-gray-50'
              }`}
            >
              {opt.label}
            </button>
          ))}
        </div>

        <div className="border-l border-gray-300 h-5 mx-1" />

        <div className="flex items-center gap-2">
          <label className="text-xs text-gray-600 whitespace-nowrap">Users:</label>
          <input
            type="range"
            min={5}
            max={stats.totalUsers}
            step={1}
            value={userLimit <= 0 ? stats.totalUsers : Math.min(userLimit, stats.totalUsers)}
            onChange={e => {
              const val = Number(e.target.value);
              setUserLimit(val >= stats.totalUsers ? 0 : val);
            }}
            className="w-24 h-1 accent-blue-600"
          />
          <button
            onClick={() => setUserLimit(userLimit <= 0 ? 25 : 0)}
            className={`px-1.5 py-0.5 rounded text-[10px] font-medium border transition-colors ${
              userLimit <= 0
                ? 'bg-blue-600 text-white border-blue-600'
                : 'bg-white text-gray-500 border-gray-300 hover:bg-gray-50'
            }`}
            title={userLimit <= 0 ? 'Click to limit to 25 users' : 'Click to show all users'}
          >
            All
          </button>
          <span className="text-xs text-gray-700 font-medium tabular-nums w-8 text-right">
            {userLimit <= 0 ? stats.totalUsers : Math.min(userLimit, stats.totalUsers)}
          </span>
        </div>

        <div className="border-l border-gray-300 h-5 mx-1" />

        <button
          onClick={onExportExcel}
          className="px-2 py-1 rounded text-xs text-white bg-green-600 hover:bg-green-700 border border-green-700 font-medium"
          title="Export matrix to Excel (.xlsx)"
        >
          Export Excel
        </button>

        {hasCustomRowOrder && (
          <>
            <div className="border-l border-gray-300 h-5 mx-1" />
            <button
              onClick={onResetRowOrder}
              className="px-2 py-1 rounded text-xs text-gray-600 hover:bg-gray-100 border border-gray-200"
              title="Reset row order to default"
            >
              Reset Rows
            </button>
          </>
        )}

        <div className="text-xs text-gray-500 ml-auto">
          {stats.users === stats.totalUsers ? (
            <>{stats.users} users</>
          ) : (
            <span className="text-amber-600 font-medium">
              Showing {stats.users} of {stats.totalUsers} users
            </span>
          )}
          {' '}&times; {stats.groups} groups &middot; {stats.memberships} assignments
        </div>
      </div>
    </div>
  );
}
