import { useState, useEffect, useCallback, useMemo, useRef, lazy, Suspense } from 'react';
import { usePermissions } from './hooks/usePermissions';
import { useAuth } from './auth/AuthGate';

// Lazy-load page components (route-based code splitting)
const MatrixView = lazy(() => import('./components/MatrixView'));
const SyncLogPage = lazy(() => import('./components/SyncLogPage'));
const UsersPage = lazy(() => import('./components/UsersPage'));
const GroupsPage = lazy(() => import('./components/GroupsPage'));
const AccessPackagesPage = lazy(() => import('./components/AccessPackagesPage'));
const UserDetailPage = lazy(() => import('./components/UserDetailPage'));
const GroupDetailPage = lazy(() => import('./components/GroupDetailPage'));
const AccessPackageDetailPage = lazy(() => import('./components/AccessPackageDetailPage'));
const PerfPage = lazy(() => import('./components/PerfPage'));
const RiskScoringPage = lazy(() => import('./components/RiskScoringPage'));
const OrgChartPage = lazy(() => import('./components/OrgChartPage'));
// const GovernancePage = lazy(() => import('./components/GovernancePage')); // temporarily disabled

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
  { key: 'matrix',           label: 'Matrix' },
  { key: 'users',            label: 'Users' },
  { key: 'groups',           label: 'Groups' },
  { key: 'access-packages',  label: 'Access Packages' },
  { key: 'sync-log',         label: 'Sync Log' },
  { key: 'risk-scores',      label: 'Risk Scores' },
  { key: 'org-chart',        label: 'Org Chart' },
  { key: 'performance',      label: 'Performance' },
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

  const { data, totalUsers, accessPackageGroups, managedByPackages, userColumns, groupTagMap, loading, refreshing, error } = usePermissions(userLimit, activeFilters);
  const { account, logout } = useAuth();
  const [page, navigate] = useHashRoute();

  // ─── Dynamic detail tabs ──────────────────────────────────────
  // Each entry: { type: 'user'|'group', id, displayName }
  const [detailTabs, setDetailTabs] = useState(() => {
    // Restore detail tab from URL on load (e.g., bookmarked #user:abc)
    const { page: initPage } = parseHash();
    if (initPage.startsWith('user:') || initPage.startsWith('group:') || initPage.startsWith('access-package:')) {
      const sepIdx = initPage.indexOf(':');
      const type = initPage.substring(0, sepIdx);
      const id = initPage.substring(sepIdx + 1);
      return [{ type, id, displayName: id }];
    }
    return [];
  });

  // ─── Detail data cache ─────────────────────────────────────────
  // Keyed by "type:id", stores { core, memberships, accessPackages, history }
  const detailCacheRef = useRef({});

  const onCacheData = useCallback((id, type, partialData) => {
    const key = `${type}:${id}`;
    detailCacheRef.current[key] = { ...detailCacheRef.current[key], ...partialData };
  }, []);

  const openDetailTab = useCallback((type, id, displayName) => {
    const tabKey = `${type}:${id}`;
    setDetailTabs(prev => {
      if (prev.some(t => `${t.type}:${t.id}` === tabKey)) return prev;
      return [...prev, { type, id, displayName: displayName || id }];
    });
    navigate(tabKey);
  }, [navigate]);

  const closeDetailTab = useCallback((type, id) => {
    const tabKey = `${type}:${id}`;
    setDetailTabs(prev => prev.filter(t => `${t.type}:${t.id}` !== tabKey));
    delete detailCacheRef.current[tabKey];
    navigate('matrix');
  }, [navigate]);

  // When navigating to a detail tab via URL that isn't tracked yet, add it
  useEffect(() => {
    if (page.startsWith('user:') || page.startsWith('group:') || page.startsWith('access-package:')) {
      const sepIdx = page.indexOf(':');
      const type = page.substring(0, sepIdx);
      const id = page.substring(sepIdx + 1);
      setDetailTabs(prev => {
        if (prev.some(t => t.type === type && t.id === id)) return prev;
        return [...prev, { type, id, displayName: id }];
      });
    }
  }, [page]);

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

  // Check if current page is a detail tab
  const isDetailPage = page.startsWith('user:') || page.startsWith('group:') || page.startsWith('access-package:');

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

  // Render detail page content
  const renderDetailPage = () => {
    if (page.startsWith('user:')) {
      const id = page.substring(5);
      const cacheKey = `user:${id}`;
      return <UserDetailPage userId={id} cachedData={detailCacheRef.current[cacheKey]} onCacheData={onCacheData} onClose={() => closeDetailTab('user', id)} onOpenDetail={openDetailTab} />;
    }
    if (page.startsWith('group:')) {
      const id = page.substring(6);
      const cacheKey = `group:${id}`;
      return <GroupDetailPage groupId={id} cachedData={detailCacheRef.current[cacheKey]} onCacheData={onCacheData} onClose={() => closeDetailTab('group', id)} />;
    }
    if (page.startsWith('access-package:')) {
      const id = page.substring(15);
      const cacheKey = `access-package:${id}`;
      return <AccessPackageDetailPage accessPackageId={id} cachedData={detailCacheRef.current[cacheKey]} onCacheData={onCacheData} onClose={() => closeDetailTab('access-package', id)} />;
    }
    return null;
  };

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
        <nav className="flex items-center gap-1 mt-3 -mb-4 border-b-0 overflow-x-auto">
          {NAV_TABS.map(tab => (
            <button
              key={tab.key}
              onClick={() => navigate(tab.key)}
              className={`px-4 py-2 text-sm font-medium rounded-t-lg border border-b-0 transition-colors whitespace-nowrap ${
                page === tab.key
                  ? 'bg-gray-50 text-blue-600 border-gray-200'
                  : 'bg-transparent text-gray-500 border-transparent hover:text-gray-700 hover:bg-gray-50'
              }`}
            >
              {tab.label}
            </button>
          ))}

          {/* Dynamic detail tabs */}
          {detailTabs.map(tab => {
            const tabKey = `${tab.type}:${tab.id}`;
            const isActive = page === tabKey;
            const icon = tab.type === 'user' ? 'U' : tab.type === 'group' ? 'G' : 'AP';
            const iconBg = tab.type === 'user' ? 'bg-blue-100 text-blue-700' : tab.type === 'group' ? 'bg-purple-100 text-purple-700' : 'bg-indigo-100 text-indigo-700';
            return (
              <button
                key={tabKey}
                onClick={() => navigate(tabKey)}
                className={`group flex items-center gap-1.5 pl-2 pr-1 py-2 text-sm font-medium rounded-t-lg border border-b-0 transition-colors whitespace-nowrap max-w-[200px] ${
                  isActive
                    ? 'bg-gray-50 text-blue-600 border-gray-200'
                    : 'bg-transparent text-gray-500 border-transparent hover:text-gray-700 hover:bg-gray-50'
                }`}
              >
                <span className={`inline-flex items-center justify-center w-4 h-4 rounded-sm text-[9px] font-bold ${iconBg}`}>{icon}</span>
                <span className="truncate max-w-[140px]">{tab.displayName}</span>
                <span
                  onClick={(e) => { e.stopPropagation(); closeDetailTab(tab.type, tab.id); }}
                  className="ml-0.5 p-0.5 rounded hover:bg-gray-200 text-gray-400 hover:text-gray-600 opacity-0 group-hover:opacity-100 transition-opacity"
                  title="Close"
                >
                  <svg className="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
                  </svg>
                </span>
              </button>
            );
          })}
        </nav>
      </header>

      {/* Content */}
      <main className="p-6">
        <Suspense fallback={<div className="flex items-center justify-center h-64"><div className="text-gray-500">Loading...</div></div>}>
          {isDetailPage ? (
            renderDetailPage()
          ) : page === 'sync-log' ? (
            <SyncLogPage />
          ) : page === 'users' ? (
            <UsersPage onOpenDetail={openDetailTab} />
          ) : page === 'groups' ? (
            <GroupsPage onOpenDetail={openDetailTab} />
          ) : page === 'access-packages' ? (
            <AccessPackagesPage onOpenDetail={openDetailTab} />
          ) : page === 'risk-scores' ? (
            <RiskScoringPage onOpenDetail={openDetailTab} />
          ) : page === 'org-chart' ? (
            <OrgChartPage onOpenDetail={openDetailTab} />
          ) : page === 'performance' ? (
            <PerfPage />
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
              groupTagMap={groupTagMap}
              refreshing={refreshing}
              shareUrl={shareUrl}
              onOpenDetail={openDetailTab}
            />
          )}
        </Suspense>
      </main>
    </div>
  );
}
