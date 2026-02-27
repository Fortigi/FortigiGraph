import { useState, useEffect, useCallback, useMemo, useRef } from 'react';
import { useAuth } from '../auth/AuthGate';

const TAG_COLORS = [
  '#3b82f6', '#10b981', '#f59e0b', '#ef4444', '#8b5cf6',
  '#ec4899', '#14b8a6', '#f97316', '#6366f1', '#84cc16',
];

const PAGE_SIZE = 100;

const ASSIGNMENT_TYPE_STYLES = {
  'Auto-assigned': 'bg-green-100 text-green-800 border-green-200',
  'Request-based': 'bg-blue-100 text-blue-800 border-blue-200',
  'Request-based with auto-removal': 'bg-orange-100 text-orange-800 border-orange-200',
  'Both': 'bg-purple-100 text-purple-800 border-purple-200',
};

const ASSIGNMENT_TYPES = ['Auto-assigned', 'Request-based', 'Request-based with auto-removal', 'Both'];

export default function AccessPackagesPage({ onOpenDetail }) {
  const { authFetch } = useAuth();

  // Data state
  const [packages, setPackages] = useState([]);
  const [total, setTotal] = useState(0);
  const [categories, setCategories] = useState([]);
  const [loading, setLoading] = useState(true);

  // Filter state
  const [search, setSearch] = useState('');
  const [debouncedSearch, setDebouncedSearch] = useState('');
  const [page, setPage] = useState(0);
  const [categoryFilter, setCategoryFilter] = useState(null); // null = all, number = categoryId, 'uncategorized' = no category
  const [typeFilter, setTypeFilter] = useState(null); // null = all, string = assignment type

  // Selection state
  const [selected, setSelected] = useState(new Set());

  // Sort state
  const [sortCol, setSortCol] = useState(null);
  const [sortDir, setSortDir] = useState('asc');

  // Category creation state
  const [showCreateCategory, setShowCreateCategory] = useState(false);
  const [newCategoryName, setNewCategoryName] = useState('');
  const [newCategoryColor, setNewCategoryColor] = useState(TAG_COLORS[0]);

  // Action state
  const [actionCategory, setActionCategory] = useState('');
  const [busy, setBusy] = useState(false);

  const fetchVersion = useRef(0);

  // Debounce search
  useEffect(() => {
    const timer = setTimeout(() => setDebouncedSearch(search), 400);
    return () => clearTimeout(timer);
  }, [search]);

  // Reset page & selection when filters change
  useEffect(() => { setPage(0); setSelected(new Set()); }, [debouncedSearch, categoryFilter, typeFilter]);

  // Fetch categories
  const fetchCategories = useCallback(async () => {
    try {
      const res = await authFetch('/api/categories');
      if (res.ok) setCategories(await res.json());
    } catch { /* ignore */ }
  }, [authFetch]);

  useEffect(() => { fetchCategories(); }, [fetchCategories]);

  // Fetch access packages
  const fetchPackages = useCallback(async () => {
    const version = ++fetchVersion.current;
    setLoading(true);
    try {
      const params = new URLSearchParams({ limit: PAGE_SIZE, offset: page * PAGE_SIZE });
      if (debouncedSearch) params.set('search', debouncedSearch);
      if (categoryFilter !== null) {
        if (categoryFilter === 'uncategorized') {
          params.set('uncategorized', 'true');
        } else {
          params.set('categoryId', categoryFilter);
        }
      }
      const res = await authFetch(`/api/access-packages?${params}`);
      if (res.ok && version === fetchVersion.current) {
        const json = await res.json();
        setPackages(json.data);
        setTotal(json.total);
      }
    } catch { /* ignore */ }
    if (version === fetchVersion.current) setLoading(false);
  }, [page, debouncedSearch, categoryFilter, authFetch]);

  useEffect(() => { fetchPackages(); }, [fetchPackages]);

  // Selection helpers
  const toggleSelect = (id) => {
    setSelected(prev => {
      const next = new Set(prev);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });
  };

  const toggleSelectAll = () => {
    if (selected.size === packages.length) {
      setSelected(new Set());
    } else {
      setSelected(new Set(packages.map(p => p.id)));
    }
  };

  // Sort helpers
  const toggleSort = (col) => {
    if (sortCol === col) {
      setSortDir(d => d === 'asc' ? 'desc' : 'asc');
    } else {
      setSortCol(col);
      setSortDir('asc');
    }
  };

  // Apply client-side type filter, then sort
  const filteredPackages = useMemo(() => {
    if (!typeFilter) return packages;
    return packages.filter(p => p.assignmentType === typeFilter);
  }, [packages, typeFilter]);

  const sortedPackages = useMemo(() => {
    if (!sortCol) return filteredPackages;
    return [...filteredPackages].sort((a, b) => {
      let av, bv;
      if (sortCol === 'totalAssignments') {
        av = a.totalAssignments || 0;
        bv = b.totalAssignments || 0;
        const cmp = av - bv;
        return sortDir === 'asc' ? cmp : -cmp;
      }
      if (sortCol === 'category') {
        av = (a.category?.name ?? '').toLowerCase();
        bv = (b.category?.name ?? '').toLowerCase();
      } else if (sortCol === 'assignmentType') {
        av = (a.assignmentType ?? '').toLowerCase();
        bv = (b.assignmentType ?? '').toLowerCase();
      } else {
        av = (a[sortCol] ?? '').toString().toLowerCase();
        bv = (b[sortCol] ?? '').toString().toLowerCase();
      }
      const cmp = av.localeCompare(bv);
      return sortDir === 'asc' ? cmp : -cmp;
    });
  }, [filteredPackages, sortCol, sortDir]);

  // Category operations
  const createCategory = async () => {
    if (!newCategoryName.trim()) return;
    setBusy(true);
    try {
      const res = await authFetch('/api/categories', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: newCategoryName.trim(), color: newCategoryColor }),
      });
      if (res.ok) {
        setNewCategoryName('');
        setShowCreateCategory(false);
        await fetchCategories();
      } else {
        const err = await res.json().catch(() => ({}));
        alert(err.error || 'Failed to create category');
      }
    } finally { setBusy(false); }
  };

  const assignCategory = async () => {
    if (!actionCategory || selected.size === 0) return;
    setBusy(true);
    try {
      for (const apId of selected) {
        await authFetch(`/api/categories/${actionCategory}/assign`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ accessPackageId: apId }),
        });
      }
      setActionCategory('');
      await Promise.all([fetchPackages(), fetchCategories()]);
    } finally { setBusy(false); }
  };

  const removeCategoryFromSelected = async () => {
    if (selected.size === 0) return;
    setBusy(true);
    try {
      for (const apId of selected) {
        await authFetch('/api/categories/unassign', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ accessPackageId: apId }),
        });
      }
      await Promise.all([fetchPackages(), fetchCategories()]);
    } finally { setBusy(false); }
  };

  const deleteCategory = async (catId) => {
    if (!confirm('Delete this category and all its assignments?')) return;
    setBusy(true);
    try {
      await authFetch(`/api/categories/${catId}`, { method: 'DELETE' });
      if (categoryFilter === catId) setCategoryFilter(null);
      await Promise.all([fetchCategories(), fetchPackages()]);
    } finally { setBusy(false); }
  };

  // Quick-assign category from dropdown in table row
  const assignCategoryToOne = async (apId, catId) => {
    setBusy(true);
    try {
      if (catId) {
        await authFetch(`/api/categories/${catId}/assign`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ accessPackageId: apId }),
        });
      } else {
        await authFetch('/api/categories/unassign', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ accessPackageId: apId }),
        });
      }
      await Promise.all([fetchPackages(), fetchCategories()]);
    } finally { setBusy(false); }
  };

  const totalPages = Math.ceil(total / PAGE_SIZE);
  const allOnPageSelected = packages.length > 0 && selected.size === packages.length;
  const hasAnyFilter = categoryFilter !== null || typeFilter !== null || debouncedSearch;

  return (
    <div className="max-w-7xl mx-auto">
      {/* Header */}
      <div className="flex items-center gap-4 mb-4">
        <h2 className="text-lg font-semibold text-gray-900">Access Packages</h2>
        <span className="text-sm text-gray-500">{total.toLocaleString()} total</span>
      </div>

      {/* Category management bar */}
      <div className="flex flex-wrap items-center gap-2 mb-3 text-sm">
        <span className="font-medium text-gray-600">Categories:</span>
        {categories.map(c => (
          <span
            key={c.id}
            className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium cursor-pointer border ${
              categoryFilter === c.id
                ? 'ring-2 ring-offset-1 ring-blue-400'
                : 'hover:opacity-80'
            }`}
            style={{ backgroundColor: c.color + '20', borderColor: c.color, color: c.color }}
            onClick={() => setCategoryFilter(categoryFilter === c.id ? null : c.id)}
            title={`${c.assignmentCount} access packages — click to filter`}
          >
            {c.name}
            <span className="text-[10px] opacity-70">({c.assignmentCount})</span>
            <button
              onClick={(e) => { e.stopPropagation(); deleteCategory(c.id); }}
              className="ml-0.5 hover:opacity-100 opacity-50"
              title="Delete category"
            >
              &times;
            </button>
          </span>
        ))}
        <span
          className={`inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium cursor-pointer border ${
            categoryFilter === 'uncategorized'
              ? 'ring-2 ring-offset-1 ring-blue-400 bg-gray-100 border-gray-400 text-gray-600'
              : 'hover:opacity-80 bg-gray-50 border-gray-300 text-gray-500'
          }`}
          onClick={() => setCategoryFilter(categoryFilter === 'uncategorized' ? null : 'uncategorized')}
          title="Show access packages without a category"
        >
          Uncategorized
        </span>
        <button
          onClick={() => setShowCreateCategory(!showCreateCategory)}
          className="px-2 py-0.5 rounded text-xs text-blue-600 hover:bg-blue-50 border border-blue-200 border-dashed"
        >
          + New Category
        </button>
      </div>

      {/* Create category form */}
      {showCreateCategory && (
        <div className="flex items-center gap-2 mb-3 p-3 bg-gray-50 border border-gray-200 rounded-lg text-sm">
          <input
            type="text"
            value={newCategoryName}
            onChange={e => setNewCategoryName(e.target.value)}
            onKeyDown={e => e.key === 'Enter' && createCategory()}
            placeholder="Category name..."
            className="px-2 py-1 border border-gray-300 rounded text-sm w-48"
            autoFocus
          />
          <div className="flex items-center gap-1">
            {TAG_COLORS.map(c => (
              <button
                key={c}
                onClick={() => setNewCategoryColor(c)}
                className={`w-5 h-5 rounded-full border-2 ${newCategoryColor === c ? 'border-gray-800 scale-110' : 'border-transparent'}`}
                style={{ backgroundColor: c }}
              />
            ))}
          </div>
          <button
            onClick={createCategory}
            disabled={!newCategoryName.trim() || busy}
            className="px-3 py-1 rounded text-sm font-medium text-white bg-blue-600 hover:bg-blue-700 disabled:opacity-50"
          >
            Create
          </button>
          <button
            onClick={() => setShowCreateCategory(false)}
            className="px-2 py-1 rounded text-sm text-gray-500 hover:bg-gray-200"
          >
            Cancel
          </button>
        </div>
      )}

      {/* Search bar + type filter */}
      <div className="flex flex-wrap items-center gap-2 mb-3 text-sm">
        <input
          type="text"
          value={search}
          onChange={e => setSearch(e.target.value)}
          placeholder="Search by name or catalog..."
          className="px-2 py-1 border border-gray-300 rounded text-xs w-56"
        />
        <select
          value={typeFilter || ''}
          onChange={e => setTypeFilter(e.target.value || null)}
          className="px-2 py-1 border border-gray-300 rounded text-xs"
        >
          <option value="">All types</option>
          {ASSIGNMENT_TYPES.map(t => (
            <option key={t} value={t}>{t}</option>
          ))}
        </select>
        {hasAnyFilter && (
          <>
            <div className="border-l border-gray-300 h-5 mx-1" />
            <button
              onClick={() => { setCategoryFilter(null); setTypeFilter(null); setSearch(''); }}
              className="px-2 py-1 rounded text-xs text-gray-500 hover:bg-gray-100 border border-gray-200"
            >
              Clear all
            </button>
          </>
        )}
      </div>

      {/* Action bar (visible when items selected) */}
      {selected.size > 0 && (
        <div className="flex items-center gap-3 mb-3 p-2 bg-blue-50 border border-blue-200 rounded-lg text-sm">
          <span className="font-medium text-blue-700">{selected.size} selected</span>
          <div className="border-l border-blue-200 h-5" />
          <select
            value={actionCategory}
            onChange={e => setActionCategory(e.target.value)}
            className="px-2 py-1 border border-gray-300 rounded text-sm"
          >
            <option value="">Select category...</option>
            {categories.map(c => (
              <option key={c.id} value={c.id}>{c.name}</option>
            ))}
          </select>
          <button
            onClick={assignCategory}
            disabled={!actionCategory || busy}
            className="px-3 py-1 rounded text-sm font-medium text-white bg-green-600 hover:bg-green-700 disabled:opacity-50"
          >
            Set Category
          </button>
          <button
            onClick={removeCategoryFromSelected}
            disabled={busy}
            className="px-3 py-1 rounded text-sm font-medium text-red-600 hover:bg-red-50 border border-red-200 disabled:opacity-50"
          >
            Remove Category
          </button>
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
        <div className="text-center text-gray-500 py-12">Loading access packages...</div>
      ) : packages.length === 0 ? (
        <div className="text-center text-gray-500 py-12">
          {hasAnyFilter ? 'No access packages match the current filters.' : 'No access packages found.'}
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
                {[
                  { key: 'displayName',      label: 'Name' },
                  { key: 'catalogName',      label: 'Catalog' },
                  { key: 'totalAssignments', label: 'Assignments' },
                  { key: 'assignmentType',   label: 'Type' },
                ].map(col => (
                  <th
                    key={col.key}
                    onClick={() => toggleSort(col.key)}
                    className="text-left px-3 py-2 font-medium text-gray-700 cursor-pointer select-none hover:bg-gray-100"
                  >
                    <span className="inline-flex items-center gap-1">
                      {col.label}
                      {sortCol === col.key ? (
                        <span className="text-blue-600 text-[10px]">{sortDir === 'asc' ? '\u25B2' : '\u25BC'}</span>
                      ) : (
                        <span className="text-gray-300 text-[10px]">{'\u25B4'}</span>
                      )}
                    </span>
                  </th>
                ))}
                <th
                  onClick={() => toggleSort('category')}
                  className="text-left px-3 py-2 font-medium text-gray-700 cursor-pointer select-none hover:bg-gray-100"
                >
                  <span className="inline-flex items-center gap-1">
                    Category
                    {sortCol === 'category' ? (
                      <span className="text-blue-600 text-[10px]">{sortDir === 'asc' ? '\u25B2' : '\u25BC'}</span>
                    ) : (
                      <span className="text-gray-300 text-[10px]">{'\u25B4'}</span>
                    )}
                  </span>
                </th>
                <th className="text-left px-3 py-2 font-medium text-gray-700">Description</th>
              </tr>
            </thead>
            <tbody>
              {sortedPackages.map(ap => (
                <tr
                  key={ap.id}
                  className={`border-b border-gray-100 hover:bg-gray-50 cursor-pointer ${
                    selected.has(ap.id) ? 'bg-blue-50' : ''
                  }`}
                  onClick={() => toggleSelect(ap.id)}
                >
                  <td className="px-3 py-2 text-center" onClick={e => e.stopPropagation()}>
                    <input
                      type="checkbox"
                      checked={selected.has(ap.id)}
                      onChange={() => toggleSelect(ap.id)}
                      className="rounded"
                    />
                  </td>
                  <td className="px-3 py-2 font-medium" onClick={e => e.stopPropagation()}>
                    <button
                      onClick={() => onOpenDetail?.('access-package', ap.id, ap.displayName)}
                      className="text-blue-600 hover:text-blue-800 hover:underline text-left"
                    >
                      {ap.displayName}
                    </button>
                  </td>
                  <td className="px-3 py-2 text-gray-600">{ap.catalogName || ''}</td>
                  <td className="px-3 py-2 text-gray-600">{ap.totalAssignments}</td>
                  <td className="px-3 py-2">
                    {ap.assignmentType && (
                      <span className={`inline-block px-2 py-0.5 rounded-full text-xs font-medium border ${ASSIGNMENT_TYPE_STYLES[ap.assignmentType] || 'bg-gray-100 text-gray-600 border-gray-200'}`}>
                        {ap.assignmentType}
                      </span>
                    )}
                  </td>
                  <td className="px-3 py-2" onClick={e => e.stopPropagation()}>
                    <select
                      value={ap.category?.id || ''}
                      onChange={e => assignCategoryToOne(ap.id, e.target.value ? parseInt(e.target.value) : null)}
                      disabled={busy}
                      className="px-1.5 py-0.5 border border-gray-200 rounded text-xs bg-white"
                      style={ap.category ? {
                        backgroundColor: ap.category.color + '20',
                        borderColor: ap.category.color,
                        color: ap.category.color,
                      } : {}}
                    >
                      <option value="">None</option>
                      {categories.map(c => (
                        <option key={c.id} value={c.id}>{c.name}</option>
                      ))}
                    </select>
                  </td>
                  <td className="px-3 py-2 text-gray-500 text-xs truncate max-w-xs" title={ap.description || ''}>
                    {ap.description || ''}
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
