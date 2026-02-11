import { useRef } from 'react';

export default function MatrixToolbar({
  departments,
  filterDept,
  setFilterDept,
  filterText,
  setFilterText,
  palette,
  activeBrush,
  setActiveBrush,
  onUndo,
  onClearAll,
  onExport,
  onImport,
  onResetOrder,
  hasCustomOrder,
  stats,
}) {
  const fileInputRef = useRef(null);

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
          <button
            key={color.key}
            onClick={() => setActiveBrush(activeBrush === color.key ? null : color.key)}
            className={`px-2 py-1 rounded text-xs font-medium border-2 transition-all ${
              activeBrush === color.key
                ? 'border-gray-800 shadow-md scale-110'
                : 'border-transparent hover:border-gray-300'
            }`}
            style={{ backgroundColor: color.hex }}
            title={color.label}
          >
            {color.label}
          </button>
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

        {hasCustomOrder && (
          <>
            <div className="border-l border-gray-300 h-5 mx-1" />
            <button
              onClick={onResetOrder}
              className="px-2 py-1 rounded text-xs text-gray-600 hover:bg-gray-100 border border-gray-200"
              title="Reset row order to default"
            >
              Reset Order
            </button>
          </>
        )}
      </div>
    </div>
  );
}
