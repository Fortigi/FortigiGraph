const views = [
  { id: 'grid', label: 'Grid View', description: 'Filter, sort, and group permission assignments' },
  { id: 'pivot', label: 'Pivot View', description: 'Drag-and-drop pivot analysis with heatmap' },
];

export default function ViewToggle({ activeView, onViewChange }) {
  return (
    <div className="flex gap-1 bg-gray-100 rounded-lg p-1">
      {views.map(view => (
        <button
          key={view.id}
          onClick={() => onViewChange(view.id)}
          className={`px-4 py-2 rounded-md text-sm font-medium transition-colors ${
            activeView === view.id
              ? 'bg-white text-gray-900 shadow-sm'
              : 'text-gray-600 hover:text-gray-900'
          }`}
          title={view.description}
        >
          {view.label}
        </button>
      ))}
    </div>
  );
}
