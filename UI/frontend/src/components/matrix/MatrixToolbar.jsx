import { useRef, useState, useMemo } from 'react';

export default function MatrixToolbar({
  filterFields,
  activeFilters,
  getOptionsForField,
  onAddFilter,
  onRemoveFilter,
  onClearAllFilters,
  filterText,
  setFilterText,
  palette,
  activeBrush,
  setActiveBrush,
  onUpdatePaletteLabel,
  onUndo,
  onClearAll,
  onExport,
  onImport,
  onResetRowOrder,
  onResetColumnOrder,
  hasCustomRowOrder,
  hasCustomColumnOrder,
  stats,
}) {
  const fileInputRef = useRef(null);
  const [editingKey, setEditingKey] = useState(null);
  const [editValue, setEditValue] = useState('');
  const [addingFilter, setAddingFilter] = useState(false);
  const [newFilterField, setNewFilterField] = useState('');

  const startEditing = (color) => {
    setEditingKey(color.key);
    setEditValue(color.label);
  };

  const finishEditing = () => {
    if (editingKey && editValue.trim()) {
      onUpdatePaletteLabel(editingKey, editValue.trim());
    }
    setEditingKey(null);
  };

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
      {/* Row 1: Active filters + add filter */}
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

        <div className="text-xs text-gray-500 ml-auto">
          {stats.users} users &times; {stats.groups} groups &middot; {stats.memberships} assignments
        </div>
      </div>

      {/* Row 2: Annotation palette */}
      <div className="flex flex-wrap items-center gap-2 text-sm">
        <span className="font-medium text-gray-700">Brush:</span>
        {palette.map(color => (
          <div key={color.key} className="relative">
            {editingKey === color.key ? (
              <input
                autoFocus
                value={editValue}
                onChange={e => setEditValue(e.target.value)}
                onBlur={finishEditing}
                onKeyDown={e => {
                  if (e.key === 'Enter') finishEditing();
                  if (e.key === 'Escape') setEditingKey(null);
                }}
                className="px-2 py-1 rounded text-xs font-medium border-2 border-gray-800 w-24"
                style={{ backgroundColor: color.hex }}
              />
            ) : (
              <button
                onClick={() => setActiveBrush(activeBrush === color.key ? null : color.key)}
                onDoubleClick={() => startEditing(color)}
                className={`px-2 py-1 rounded text-xs font-medium border-2 transition-all ${
                  activeBrush === color.key
                    ? 'border-gray-800 shadow-md scale-110'
                    : 'border-transparent hover:border-gray-300'
                }`}
                style={{ backgroundColor: color.hex }}
                title={`${color.label}${color.marker ? ` (${color.marker})` : ''} — double-click to rename`}
              >
                {color.marker && <span className="mr-0.5 font-bold">{color.marker}</span>}
                {color.label}
              </button>
            )}
          </div>
        ))}
        <button
          onClick={() => setActiveBrush(activeBrush === 'clear' ? null : 'clear')}
          className={`px-2 py-1 rounded text-xs font-medium border-2 transition-all ${
            activeBrush === 'clear'
              ? 'border-gray-800 shadow-md scale-110'
              : 'border-gray-300 hover:border-gray-400'
          }`}
          title="Eraser - click cells to remove annotation"
        >
          Eraser
        </button>

        <div className="border-l border-gray-300 h-5 mx-1" />

        <button
          onClick={onUndo}
          className="px-2 py-1 rounded text-xs text-gray-600 hover:bg-gray-100 border border-gray-200"
          title="Undo (Ctrl+Z)"
        >
          Undo
        </button>
        <button
          onClick={onClearAll}
          className="px-2 py-1 rounded text-xs text-red-600 hover:bg-red-50 border border-red-200"
          title="Clear all annotations"
        >
          Clear All
        </button>

        <div className="border-l border-gray-300 h-5 mx-1" />

        <button
          onClick={onExport}
          className="px-2 py-1 rounded text-xs text-gray-600 hover:bg-gray-100 border border-gray-200"
          title="Export annotations as JSON"
        >
          Export
        </button>
        <button
          onClick={() => fileInputRef.current?.click()}
          className="px-2 py-1 rounded text-xs text-gray-600 hover:bg-gray-100 border border-gray-200"
          title="Import annotations from JSON"
        >
          Import
        </button>
        <input
          ref={fileInputRef}
          type="file"
          accept=".json"
          className="hidden"
          onChange={e => {
            const file = e.target.files[0];
            if (file) {
              const reader = new FileReader();
              reader.onload = () => onImport(reader.result);
              reader.readAsText(file);
            }
            e.target.value = '';
          }}
        />

        {(hasCustomRowOrder || hasCustomColumnOrder) && (
          <>
            <div className="border-l border-gray-300 h-5 mx-1" />
            {hasCustomRowOrder && (
              <button
                onClick={onResetRowOrder}
                className="px-2 py-1 rounded text-xs text-gray-600 hover:bg-gray-100 border border-gray-200"
                title="Reset row order to default"
              >
                Reset Rows
              </button>
            )}
            {hasCustomColumnOrder && (
              <button
                onClick={onResetColumnOrder}
                className="px-2 py-1 rounded text-xs text-gray-600 hover:bg-gray-100 border border-gray-200"
                title="Reset column order to default"
              >
                Reset Columns
              </button>
            )}
          </>
        )}
      </div>

      {/* Row 3: Hints */}
      <div className="text-[10px] text-gray-400">
        Keys 1-6: select brush &middot; 0: eraser &middot; Esc: deselect &middot; Ctrl+Z: undo &middot; Shift+click: fill range &middot; Double-click brush to rename &middot; Drag column headers or rows to reorder
      </div>
    </div>
  );
}
