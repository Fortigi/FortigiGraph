import { useRef, useState } from 'react';

export default function MatrixToolbar({
  departments,
  filterDept,
  setFilterDept,
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

  return (
    <div className="flex flex-col gap-2">
      {/* Row 1: Filters */}
      <div className="flex flex-wrap items-center gap-4 text-sm">
        <div className="flex items-center gap-2">
          <label className="font-medium text-gray-700">Department:</label>
          <select
            value={filterDept}
            onChange={e => setFilterDept(e.target.value)}
            className="px-2 py-1 border border-gray-300 rounded text-sm"
          >
            <option value="">All departments</option>
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
        <div className="text-xs text-gray-500">
          {stats.users} users x {stats.groups} groups &middot; {stats.memberships} assignments
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
