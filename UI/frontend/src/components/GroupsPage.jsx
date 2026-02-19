import { useState, useEffect, useCallback, useRef } from 'react';
import { useAuth } from '../auth/AuthGate';

const TAG_COLORS = [
  '#3b82f6', '#10b981', '#f59e0b', '#ef4444', '#8b5cf6',
  '#ec4899', '#14b8a6', '#f97316', '#6366f1', '#84cc16',
];

const PAGE_SIZE = 100;

export default function GroupsPage({ onBack }) {
  const { authFetch } = useAuth();

  // Data state
  const [groups, setGroups] = useState([]);
  const [total, setTotal] = useState(0);
  const [tags, setTags] = useState([]);
  const [loading, setLoading] = useState(true);

  // Filter state
  const [search, setSearch] = useState('');
  const [debouncedSearch, setDebouncedSearch] = useState('');
  const [tagFilter, setTagFilter] = useState('');
  const [page, setPage] = useState(0);

  // Selection state
  const [selected, setSelected] = useState(new Set());

  // Tag creation state
  const [showCreateTag, setShowCreateTag] = useState(false);
  const [newTagName, setNewTagName] = useState('');
  const [newTagColor, setNewTagColor] = useState(TAG_COLORS[0]);

  // Action state
  const [actionTag, setActionTag] = useState('');
  const [busy, setBusy] = useState(false);

  const fetchVersion = useRef(0);

  // Debounce search
  useEffect(() => {
    const timer = setTimeout(() => setDebouncedSearch(search), 400);
    return () => clearTimeout(timer);
  }, [search]);

  // Reset page & selection when filters change
  useEffect(() => { setPage(0); setSelected(new Set()); }, [debouncedSearch, tagFilter]);

  // Fetch tags
  const fetchTags = useCallback(async () => {
    try {
      const res = await authFetch('/api/tags?entityType=group');
      if (res.ok) setTags(await res.json());
    } catch { /* ignore */ }
  }, [authFetch]);

  useEffect(() => { fetchTags(); }, [fetchTags]);

  // Fetch groups
  const fetchGroups = useCallback(async () => {
    const version = ++fetchVersion.current;
    setLoading(true);
    try {
      const params = new URLSearchParams({ limit: PAGE_SIZE, offset: page * PAGE_SIZE });
      if (debouncedSearch) params.set('search', debouncedSearch);
      if (tagFilter) params.set('tagId', tagFilter);
      const res = await authFetch(`/api/groups?${params}`);
      if (res.ok && version === fetchVersion.current) {
        const json = await res.json();
        setGroups(json.data);
        setTotal(json.total);
      }
    } catch { /* ignore */ }
    if (version === fetchVersion.current) setLoading(false);
  }, [page, debouncedSearch, tagFilter, authFetch]);

  useEffect(() => { fetchGroups(); }, [fetchGroups]);

  // Selection helpers
  const toggleSelect = (id) => {
    setSelected(prev => {
      const next = new Set(prev);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });
  };

  const toggleSelectAll = () => {
    if (selected.size === groups.length) {
      setSelected(new Set());
    } else {
      setSelected(new Set(groups.map(g => g.id)));
    }
  };

  // Tag operations
  const createTag = async () => {
    if (!newTagName.trim()) return;
    setBusy(true);
    try {
      const res = await authFetch('/api/tags', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: newTagName.trim(), color: newTagColor, entityType: 'group' }),
      });
      if (res.ok) {
        setNewTagName('');
        setShowCreateTag(false);
        await fetchTags();
      } else {
        const err = await res.json().catch(() => ({}));
        alert(err.error || 'Failed to create tag');
      }
    } finally { setBusy(false); }
  };

  const assignTag = async () => {
    if (!actionTag || selected.size === 0) return;
    setBusy(true);
    try {
      await authFetch(`/api/tags/${actionTag}/assign`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ entityIds: [...selected] }),
      });
      setActionTag('');
      await Promise.all([fetchGroups(), fetchTags()]);
    } finally { setBusy(false); }
  };

  const assignTagToAll = async () => {
    if (!actionTag || !debouncedSearch) return;
    setBusy(true);
    try {
      const res = await authFetch(`/api/tags/${actionTag}/assign-by-filter`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ entityType: 'group', search: debouncedSearch }),
      });
      if (res.ok) {
        const json = await res.json();
        alert(`Tagged ${json.inserted} groups`);
      }
      setActionTag('');
      await Promise.all([fetchGroups(), fetchTags()]);
    } finally { setBusy(false); }
  };

  const removeTagFromSelected = async () => {
    if (!actionTag || selected.size === 0) return;
    setBusy(true);
    try {
      await authFetch(`/api/tags/${actionTag}/unassign`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ entityIds: [...selected] }),
      });
      setActionTag('');
      await Promise.all([fetchGroups(), fetchTags()]);
    } finally { setBusy(false); }
  };

  const deleteTag = async (tagId) => {
    if (!confirm('Delete this tag and all its assignments?')) return;
    setBusy(true);
    try {
      await authFetch(`/api/tags/${tagId}`, { method: 'DELETE' });
      if (tagFilter === String(tagId)) setTagFilter('');
      await Promise.all([fetchTags(), fetchGroups()]);
    } finally { setBusy(false); }
  };

  const totalPages = Math.ceil(total / PAGE_SIZE);
  const allOnPageSelected = groups.length > 0 && selected.size === groups.length;

  return (
    <div className="max-w-7xl mx-auto">
      {/* Header */}
      <div className="flex items-center gap-4 mb-4">
        <button
          onClick={onBack}
          className="px-3 py-1.5 rounded text-sm text-gray-600 hover:bg-gray-100 border border-gray-200"
        >
          &larr; Matrix
        </button>
        <h2 className="text-lg font-semibold text-gray-900">Groups</h2>
        <span className="text-sm text-gray-500">{total.toLocaleString()} total</span>
      </div>

      {/* Tag bar */}
      <div className="flex flex-wrap items-center gap-2 mb-3 text-sm">
        <span className="font-medium text-gray-600">Tags:</span>
        {tags.map(t => (
          <span
            key={t.id}
            className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium cursor-pointer border ${
              tagFilter === String(t.id)
                ? 'ring-2 ring-offset-1 ring-blue-400'
                : 'hover:opacity-80'
            }`}
            style={{ backgroundColor: t.color + '20', borderColor: t.color, color: t.color }}
            onClick={() => setTagFilter(tagFilter === String(t.id) ? '' : String(t.id))}
            title={`${t.assignmentCount} groups tagged — click to filter`}
          >
            {t.name}
            <span className="text-[10px] opacity-70">({t.assignmentCount})</span>
            <button
              onClick={(e) => { e.stopPropagation(); deleteTag(t.id); }}
              className="ml-0.5 hover:opacity-100 opacity-50"
              title="Delete tag"
            >
              &times;
            </button>
          </span>
        ))}
        <button
          onClick={() => setShowCreateTag(!showCreateTag)}
          className="px-2 py-0.5 rounded text-xs text-blue-600 hover:bg-blue-50 border border-blue-200 border-dashed"
        >
          + New Tag
        </button>
        {tagFilter && (
          <button
            onClick={() => setTagFilter('')}
            className="px-2 py-0.5 rounded text-xs text-gray-500 hover:bg-gray-100"
          >
            Clear filter
          </button>
        )}
      </div>

      {/* Create tag form */}
      {showCreateTag && (
        <div className="flex items-center gap-2 mb-3 p-3 bg-gray-50 border border-gray-200 rounded-lg text-sm">
          <input
            type="text"
            value={newTagName}
            onChange={e => setNewTagName(e.target.value)}
            onKeyDown={e => e.key === 'Enter' && createTag()}
            placeholder="Tag name..."
            className="px-2 py-1 border border-gray-300 rounded text-sm w-48"
            autoFocus
          />
          <div className="flex items-center gap-1">
            {TAG_COLORS.map(c => (
              <button
                key={c}
                onClick={() => setNewTagColor(c)}
                className={`w-5 h-5 rounded-full border-2 ${newTagColor === c ? 'border-gray-800 scale-110' : 'border-transparent'}`}
                style={{ backgroundColor: c }}
              />
            ))}
          </div>
          <button
            onClick={createTag}
            disabled={!newTagName.trim() || busy}
            className="px-3 py-1 rounded text-sm font-medium text-white bg-blue-600 hover:bg-blue-700 disabled:opacity-50"
          >
            Create
          </button>
          <button
            onClick={() => setShowCreateTag(false)}
            className="px-2 py-1 rounded text-sm text-gray-500 hover:bg-gray-200"
          >
            Cancel
          </button>
        </div>
      )}

      {/* Search */}
      <div className="flex items-center gap-3 mb-3">
        <input
          type="text"
          value={search}
          onChange={e => setSearch(e.target.value)}
          placeholder="Search by group name or description..."
          className="px-3 py-1.5 border border-gray-300 rounded text-sm w-72"
        />
        {debouncedSearch && (
          <span className="text-xs text-gray-500">{total} groups match &quot;{debouncedSearch}&quot;</span>
        )}
      </div>

      {/* Action bar */}
      {selected.size > 0 && (
        <div className="flex items-center gap-3 mb-3 p-2 bg-blue-50 border border-blue-200 rounded-lg text-sm">
          <span className="font-medium text-blue-700">{selected.size} selected</span>
          <div className="border-l border-blue-200 h-5" />
          <select
            value={actionTag}
            onChange={e => setActionTag(e.target.value)}
            className="px-2 py-1 border border-gray-300 rounded text-sm"
          >
            <option value="">Select tag...</option>
            {tags.map(t => (
              <option key={t.id} value={t.id}>{t.name}</option>
            ))}
          </select>
          <button
            onClick={assignTag}
            disabled={!actionTag || busy}
            className="px-3 py-1 rounded text-sm font-medium text-white bg-green-600 hover:bg-green-700 disabled:opacity-50"
          >
            Assign Tag
          </button>
          <button
            onClick={removeTagFromSelected}
            disabled={!actionTag || busy}
            className="px-3 py-1 rounded text-sm font-medium text-red-600 hover:bg-red-50 border border-red-200 disabled:opacity-50"
          >
            Remove Tag
          </button>
          {debouncedSearch && total > PAGE_SIZE && (
            <>
              <div className="border-l border-blue-200 h-5" />
              <button
                onClick={assignTagToAll}
                disabled={!actionTag || busy}
                className="px-3 py-1 rounded text-sm font-medium text-blue-700 hover:bg-blue-100 border border-blue-300 disabled:opacity-50"
                title={`Tag all ${total} groups matching "${debouncedSearch}"`}
              >
                Tag all {total} matching
              </button>
            </>
          )}
          <button
            onClick={() => setSelected(new Set())}
            className="px-2 py-1 rounded text-xs text-gray-500 hover:bg-gray-100 ml-auto"
          >
            Clear selection
          </button>
        </div>
      )}

      {/* Table */}
      {loading ? (
        <div className="text-center text-gray-500 py-12">Loading groups...</div>
      ) : groups.length === 0 ? (
        <div className="text-center text-gray-500 py-12">
          {debouncedSearch || tagFilter ? 'No groups match the current filters.' : 'No groups found.'}
        </div>
      ) : (
        <div className="border border-gray-200 rounded-lg overflow-hidden">
          <table className="w-full text-sm">
            <thead>
              <tr className="bg-gray-50 border-b border-gray-200">
                <th className="w-10 px-3 py-2">
                  <input
                    type="checkbox"
                    checked={allOnPageSelected}
                    onChange={toggleSelectAll}
                    className="rounded"
                  />
                </th>
                <th className="text-left px-3 py-2 font-medium text-gray-700">Display Name</th>
                <th className="text-left px-3 py-2 font-medium text-gray-700">Type</th>
                <th className="text-left px-3 py-2 font-medium text-gray-700">Description</th>
                <th className="text-left px-3 py-2 font-medium text-gray-700">Tags</th>
              </tr>
            </thead>
            <tbody>
              {groups.map(g => (
                <tr
                  key={g.id}
                  className={`border-b border-gray-100 hover:bg-gray-50 cursor-pointer ${
                    selected.has(g.id) ? 'bg-blue-50' : ''
                  }`}
                  onClick={() => toggleSelect(g.id)}
                >
                  <td className="px-3 py-2 text-center" onClick={e => e.stopPropagation()}>
                    <input
                      type="checkbox"
                      checked={selected.has(g.id)}
                      onChange={() => toggleSelect(g.id)}
                      className="rounded"
                    />
                  </td>
                  <td className="px-3 py-2 font-medium text-gray-900">{g.displayName}</td>
                  <td className="px-3 py-2 text-gray-600 text-xs">{g.groupTypeCalculated || ''}</td>
                  <td className="px-3 py-2 text-gray-500 text-xs max-w-xs truncate" title={g.description || ''}>
                    {g.description || ''}
                  </td>
                  <td className="px-3 py-2">
                    <div className="flex flex-wrap gap-1">
                      {g.tags.map(t => (
                        <span
                          key={t.id}
                          className="inline-block px-1.5 py-0.5 rounded-full text-[10px] font-medium border"
                          style={{ backgroundColor: t.color + '20', borderColor: t.color, color: t.color }}
                        >
                          {t.name}
                        </span>
                      ))}
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {/* Pagination */}
      {totalPages > 1 && (
        <div className="flex items-center justify-between mt-3 text-sm text-gray-600">
          <span>
            Showing {page * PAGE_SIZE + 1}&ndash;{Math.min((page + 1) * PAGE_SIZE, total)} of {total.toLocaleString()}
          </span>
          <div className="flex items-center gap-2">
            <button
              onClick={() => setPage(p => Math.max(0, p - 1))}
              disabled={page === 0}
              className="px-3 py-1 rounded border border-gray-300 hover:bg-gray-50 disabled:opacity-40"
            >
              Prev
            </button>
            <span>Page {page + 1} of {totalPages}</span>
            <button
              onClick={() => setPage(p => Math.min(totalPages - 1, p + 1))}
              disabled={page >= totalPages - 1}
              className="px-3 py-1 rounded border border-gray-300 hover:bg-gray-50 disabled:opacity-40"
            >
              Next
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
