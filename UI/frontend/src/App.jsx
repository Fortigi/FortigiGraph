import { useState, useEffect, useCallback, useMemo } from 'react';
import { usePermissions } from './hooks/usePermissions';
import { useAuth } from './auth/AuthGate';
import MatrixView from './components/MatrixView';
import SyncLogPage from './components/SyncLogPage';
import UsersPage from './components/UsersPage';
import GroupsPage from './components/GroupsPage';

// ─── URL helpers ──────────────────────────────────────────────────

function parseHash() {
  const raw = window.location.hash.replace('#', '') || 'matrix';
  const qIndex = raw.indexOf('?');
  const page = qIndex >= 0 ? raw.substring(0, qIndex) : raw;
  const params = new URLSearchParams(qIndex >= 0 ? raw.substring(qIndex + 1) : '');
  return { page, params };
}

function parseMatrixParams(params) {
  const limit = params.has('limit') ? (parseInt(params.get('limit')) || 0) : 25;
  const filters = [];
  for (const [key, value] of params.entries()) {
    if (key.startsWith('f.')) {
      filters.push({ field: key.slice(2), value });
    }
  }
  const managed = params.get('managed') || 'all';
  const search = params.get('q') || '';
  return { limit, filters, managed, search };
}

function buildMatrixHash(state) {
  const params = new URLSearchParams();
  if (state.limit > 0) params.set('limit', String(state.limit));
  if (state.limit === 0) params.set('limit', '0');
  for (const f of state.filters || []) {
    params.set(`f.${f.field}`, f.value);
  }
  if (state.managed && state.managed !== 'all') params.set('managed', state.managed);
  if (state.search) params.set('q', state.search);
  const qs = params.toString();
  return `matrix${qs ? '?' + qs : ''}`;
}

export function buildMatrixUrl(state) {
  const hash = buildMatrixHash(state);
  return `${window.location.origin}${window.location.pathname}#${hash}`;
}

// ─── Hash route hook ──────────────────────────────────────────────

function useHashRoute() {
  const getPage = () => {
    const raw = window.location.hash.replace('#', '') || 'matrix';
    const qIndex = raw.indexOf('?');
    return qIndex >= 0 ? raw.substring(0, qIndex) : raw;
  };
  const [page, setPage] = useState(getPage());
  useEffect(() => {
    const onHash = () => setPage(getPage());
    window.addEventListener('hashchange', onHash);
    return () => window.removeEventListener('hashchange', onHash);
  }, []);
  const navigate = useCallback((p) => { window.location.hash = p; }, []);
  return [page, navigate];
}

const NAV_TABS = [
  { key: 'matrix',   label: 'Matrix' },
  { key: 'users',    label: 'Users' },
  { key: 'groups',   label: 'Groups' },
  { key: 'sync-log', label: 'Sync Log' },
];

export default function App() {
  // Parse initial state from URL (runs once)
  const initial = useMemo(() => {
    const { page, params } = parseHash();
    if (page === 'matrix') return parseMatrixParams(params);
    return { limit: 25, filters: [], managed: 'all', search: '' };
  }, []);

  // All shareable matrix state lives here
  const [userLimit, setUserLimit] = useState(initial.limit);
  const [activeFilters, setActiveFilters] = useState(initial.filters);
  const [managedFilter, setManagedFilter] = useState(initial.managed);
  const [filterText, setFilterText] = useState(initial.search);

  const { data, totalUsers, accessPackageGroups, managedByPackages, userColumns, loading, refreshing, error } = usePermissions(userLimit, activeFilters);
  const { account, logout } = useAuth();
  const [page, navigate] = useHashRoute();

  // Sync URL when on matrix page (debounced replaceState — no history entry)
  useEffect(() => {
    if (page !== 'matrix') return;
    const timer = setTimeout(() => {
      const newHash = buildMatrixHash({
        limit: userLimit,
        filters: activeFilters,
        managed: managedFilter,
        search: filterText,
      });
      if (window.location.hash !== '#' + newHash) {
        history.replaceState(null, '', '#' + newHash);
      }
    }, 300);
    return () => clearTimeout(timer);
  }, [page, userLimit, activeFilters, managedFilter, filterText]);

  // Build shareable URL (stable reference for children)
  const shareUrl = useMemo(() => buildMatrixUrl({
    limit: userLimit,
    filters: activeFilters,
    managed: managedFilter,
    search: filterText,
  }), [userLimit, activeFilters, managedFilter, filterText]);

  if (error) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-gray-50">
        <div className="bg-red-50 border border-red-200 rounded-lg p-6 max-w-md">
          <h2 className="text-red-800 font-semibold text-lg">Connection Error</h2>
          <p className="text-red-600 mt-2 text-sm">{error}</p>
          <p className="text-red-500 mt-2 text-xs">
            Make sure the backend is running: <code className="bg-red-100 px-1 rounded">cd UI/backend && npm run dev</code>
          </p>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-gray-50">
      {/* Header */}
      <header className="bg-white border-b border-gray-200 px-6 py-4">
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-xl font-semibold text-gray-900">FortigiGraph Role Mining</h1>
            <p className="text-sm text-gray-500 mt-0.5">
              Analyze permission assignments to discover role patterns
            </p>
          </div>
          <div className="flex items-center gap-3">
            {account && (
              <div className="flex items-center gap-2 text-sm text-gray-500">
                <span>{account.name || account.username}</span>
                <button
                  onClick={logout}
                  className="text-gray-400 hover:text-gray-600"
                  title="Sign out"
                >
                  Sign out
                </button>
              </div>
            )}
          </div>
        </div>

        {/* Tab navigation */}
        <nav className="flex items-center gap-1 mt-3 -mb-4 border-b-0">
          {NAV_TABS.map(tab => (
            <button
              key={tab.key}
              onClick={() => navigate(tab.key)}
              className={`px-4 py-2 text-sm font-medium rounded-t-lg border border-b-0 transition-colors ${
                page === tab.key
                  ? 'bg-gray-50 text-blue-600 border-gray-200'
                  : 'bg-transparent text-gray-500 border-transparent hover:text-gray-700 hover:bg-gray-50'
              }`}
            >
              {tab.label}
            </button>
          ))}
        </nav>
      </header>

      {/* Content */}
      <main className="p-6">
        {page === 'sync-log' ? (
          <SyncLogPage onBack={() => navigate('matrix')} />
        ) : page === 'users' ? (
          <UsersPage />
        ) : page === 'groups' ? (
          <GroupsPage />
        ) : loading ? (
          <div className="flex items-center justify-center h-64">
            <div className="text-gray-500">Loading permission data...</div>
          </div>
        ) : (
          <MatrixView
            data={data}
            accessPackageGroups={accessPackageGroups}
            managedByPackages={managedByPackages}
            totalUsers={totalUsers}
            userLimit={userLimit}
            setUserLimit={setUserLimit}
            activeFilters={activeFilters}
            setActiveFilters={setActiveFilters}
            managedFilter={managedFilter}
            setManagedFilter={setManagedFilter}
            filterText={filterText}
            setFilterText={setFilterText}
            userColumns={userColumns}
            refreshing={refreshing}
            shareUrl={shareUrl}
          />
        )}
      </main>
    </div>
  );
}
