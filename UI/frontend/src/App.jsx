import { useState, useEffect, useCallback } from 'react';
import { usePermissions } from './hooks/usePermissions';
import MatrixView from './components/MatrixView';
import SyncLogPage from './components/SyncLogPage';

function useHashRoute() {
  const [page, setPage] = useState(window.location.hash.replace('#', '') || 'matrix');
  useEffect(() => {
    const onHash = () => setPage(window.location.hash.replace('#', '') || 'matrix');
    window.addEventListener('hashchange', onHash);
    return () => window.removeEventListener('hashchange', onHash);
  }, []);
  const navigate = useCallback((p) => { window.location.hash = p; }, []);
  return [page, navigate];
}

export default function App() {
  const [userLimit, setUserLimit] = useState(25);
  const { data, totalUsers, accessPackageGroups, loading, error } = usePermissions(userLimit);
  const [page, navigate] = useHashRoute();

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
          <button
            onClick={() => navigate('sync-log')}
            className="px-3 py-1.5 rounded text-sm font-medium text-gray-600 hover:bg-gray-100 border border-gray-200"
          >
            Sync Log
          </button>
        </div>
      </header>

      {/* Content */}
      <main className="p-6">
        {page === 'sync-log' ? (
          <SyncLogPage onBack={() => navigate('matrix')} />
        ) : loading ? (
          <div className="flex items-center justify-center h-64">
            <div className="text-gray-500">Loading permission data...</div>
          </div>
        ) : (
          <MatrixView
            data={data}
            accessPackageGroups={accessPackageGroups}
            totalUsers={totalUsers}
            userLimit={userLimit}
            setUserLimit={setUserLimit}
          />
        )}
      </main>
    </div>
  );
}
