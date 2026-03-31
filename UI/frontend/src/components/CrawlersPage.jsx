import { useState, useEffect, useCallback } from 'react';
import { useAuth } from '../auth/AuthGate';

export default function CrawlersPage() {
  const { authFetch } = useAuth();
  const [crawlers, setCrawlers] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [showRegister, setShowRegister] = useState(false);
  const [newKey, setNewKey] = useState(null);
  const [expandedAudit, setExpandedAudit] = useState(null);
  const [auditData, setAuditData] = useState({ data: [], total: 0 });

  // Register form state
  const [regName, setRegName] = useState('');
  const [regDesc, setRegDesc] = useState('');
  const [regPerms, setRegPerms] = useState(['ingest']);
  const [regRateLimit, setRegRateLimit] = useState(100);

  const fetchCrawlers = useCallback(async () => {
    try {
      setLoading(true);
      const res = await authFetch('/api/admin/crawlers');
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      setCrawlers(Array.isArray(data) ? data : []);
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }, [authFetch]);

  useEffect(() => { fetchCrawlers(); }, [fetchCrawlers]);

  const handleRegister = async () => {
    if (!regName.trim()) return;
    try {
      const res = await authFetch('/api/admin/crawlers', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          displayName: regName.trim(),
          description: regDesc.trim(),
          permissions: regPerms,
          rateLimit: regRateLimit,
        }),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      setNewKey(data.apiKey);
      setShowRegister(false);
      setRegName('');
      setRegDesc('');
      fetchCrawlers();
    } catch (err) {
      setError(err.message);
    }
  };

  const handleToggleEnabled = async (crawler) => {
    try {
      await authFetch(`/api/admin/crawlers/${crawler.id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ enabled: !crawler.enabled }),
      });
      fetchCrawlers();
    } catch (err) {
      setError(err.message);
    }
  };

  const handleResetKey = async (crawler) => {
    if (!confirm(`Reset API key for "${crawler.displayName}"? The current key will stop working immediately.`)) return;
    try {
      const res = await authFetch(`/api/admin/crawlers/${crawler.id}/reset`, { method: 'POST' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      setNewKey(data.apiKey);
    } catch (err) {
      setError(err.message);
    }
  };

  const handleDelete = async (crawler) => {
    if (!confirm(`Disable crawler "${crawler.displayName}"?`)) return;
    try {
      await authFetch(`/api/admin/crawlers/${crawler.id}`, { method: 'DELETE' });
      fetchCrawlers();
    } catch (err) {
      setError(err.message);
    }
  };

  const toggleAudit = async (crawlerId) => {
    if (expandedAudit === crawlerId) {
      setExpandedAudit(null);
      return;
    }
    try {
      const res = await authFetch(`/api/admin/crawlers/${crawlerId}/audit?limit=20`);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      setAuditData(data);
      setExpandedAudit(crawlerId);
    } catch (err) {
      setError(err.message);
    }
  };

  const copyToClipboard = (text) => {
    navigator.clipboard.writeText(text);
  };

  const formatDate = (d) => d ? new Date(d).toLocaleString() : '—';

  if (loading) return <div className="p-6 text-gray-500">Loading crawlers...</div>;
  if (error) return <div className="p-6 text-red-500">Error: {error}</div>;

  return (
    <div className="p-6 max-w-6xl mx-auto">
      <div className="flex items-center justify-between mb-6">
        <h1 className="text-2xl font-bold text-gray-900 dark:text-white">Crawlers</h1>
        <button
          onClick={() => setShowRegister(true)}
          className="px-4 py-2 bg-indigo-600 text-white rounded-lg hover:bg-indigo-700 text-sm font-medium"
        >
          Register Crawler
        </button>
      </div>

      {/* New key display */}
      {newKey && (
        <div className="mb-6 p-4 bg-green-50 dark:bg-green-900/30 border border-green-200 dark:border-green-800 rounded-lg">
          <div className="flex items-center justify-between mb-2">
            <span className="font-semibold text-green-800 dark:text-green-200">API Key Generated</span>
            <button onClick={() => setNewKey(null)} className="text-green-600 hover:text-green-800 text-sm">Dismiss</button>
          </div>
          <p className="text-sm text-green-700 dark:text-green-300 mb-2">Store this key securely. It will not be shown again.</p>
          <div className="flex items-center gap-2">
            <code className="flex-1 p-2 bg-white dark:bg-gray-800 border rounded font-mono text-sm break-all">{newKey}</code>
            <button
              onClick={() => copyToClipboard(newKey)}
              className="px-3 py-2 bg-green-600 text-white rounded text-sm hover:bg-green-700"
            >
              Copy
            </button>
          </div>
        </div>
      )}

      {/* Register dialog */}
      {showRegister && (
        <div className="mb-6 p-4 bg-gray-50 dark:bg-gray-800 border rounded-lg">
          <h3 className="font-semibold mb-3">Register New Crawler</h3>
          <div className="grid grid-cols-2 gap-4 mb-4">
            <div>
              <label className="block text-sm font-medium mb-1">Name *</label>
              <input
                type="text" value={regName} onChange={e => setRegName(e.target.value)}
                placeholder="e.g., EntraID Production Crawler"
                className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600"
              />
            </div>
            <div>
              <label className="block text-sm font-medium mb-1">Rate Limit (req/min)</label>
              <input
                type="number" value={regRateLimit} onChange={e => setRegRateLimit(parseInt(e.target.value, 10) || 100)}
                className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600"
              />
            </div>
          </div>
          <div className="mb-4">
            <label className="block text-sm font-medium mb-1">Description</label>
            <input
              type="text" value={regDesc} onChange={e => setRegDesc(e.target.value)}
              placeholder="Optional description"
              className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600"
            />
          </div>
          <div className="flex gap-2">
            <button onClick={handleRegister} className="px-4 py-2 bg-indigo-600 text-white rounded text-sm hover:bg-indigo-700">Create</button>
            <button onClick={() => setShowRegister(false)} className="px-4 py-2 bg-gray-200 dark:bg-gray-600 rounded text-sm">Cancel</button>
          </div>
        </div>
      )}

      {/* Crawler table */}
      {crawlers.length === 0 ? (
        <div className="text-center py-12 text-gray-500">
          <p className="text-lg mb-2">No crawlers registered</p>
          <p className="text-sm">Register a crawler to start ingesting data via the API.</p>
        </div>
      ) : (
        <div className="bg-white dark:bg-gray-800 rounded-lg border overflow-hidden">
          <table className="w-full text-sm">
            <thead className="bg-gray-50 dark:bg-gray-700">
              <tr>
                <th className="text-left p-3 font-medium">Name</th>
                <th className="text-left p-3 font-medium">Key Prefix</th>
                <th className="text-left p-3 font-medium">Status</th>
                <th className="text-left p-3 font-medium">Last Used</th>
                <th className="text-left p-3 font-medium">Rate Limit</th>
                <th className="text-left p-3 font-medium">Created</th>
                <th className="text-right p-3 font-medium">Actions</th>
              </tr>
            </thead>
            <tbody className="divide-y dark:divide-gray-700">
              {crawlers.map(c => (
                <>
                  <tr key={c.id} className="hover:bg-gray-50 dark:hover:bg-gray-750">
                    <td className="p-3">
                      <div className="font-medium">{c.displayName}</div>
                      {c.description && <div className="text-xs text-gray-500 mt-0.5">{c.description}</div>}
                    </td>
                    <td className="p-3 font-mono text-xs">{c.apiKeyPrefix}...</td>
                    <td className="p-3">
                      <button
                        onClick={() => handleToggleEnabled(c)}
                        className={`px-2 py-0.5 rounded-full text-xs font-medium ${
                          c.enabled
                            ? 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300'
                            : 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300'
                        }`}
                      >
                        {c.enabled ? 'Enabled' : 'Disabled'}
                      </button>
                    </td>
                    <td className="p-3 text-gray-500">{formatDate(c.lastUsedAt)}</td>
                    <td className="p-3">{c.rateLimit}/min</td>
                    <td className="p-3 text-gray-500">{formatDate(c.createdAt)}</td>
                    <td className="p-3 text-right">
                      <div className="flex gap-1 justify-end">
                        <button onClick={() => toggleAudit(c.id)} className="px-2 py-1 text-xs bg-gray-100 dark:bg-gray-700 rounded hover:bg-gray-200">
                          {expandedAudit === c.id ? 'Hide Log' : 'Audit Log'}
                        </button>
                        <button onClick={() => handleResetKey(c)} className="px-2 py-1 text-xs bg-amber-100 dark:bg-amber-900/30 text-amber-800 dark:text-amber-200 rounded hover:bg-amber-200">
                          Reset Key
                        </button>
                        <button onClick={() => handleDelete(c)} className="px-2 py-1 text-xs bg-red-100 dark:bg-red-900/30 text-red-800 dark:text-red-200 rounded hover:bg-red-200">
                          Disable
                        </button>
                      </div>
                    </td>
                  </tr>
                  {expandedAudit === c.id && (
                    <tr key={`${c.id}-audit`}>
                      <td colSpan="7" className="p-3 bg-gray-50 dark:bg-gray-900">
                        {auditData.data.length === 0 ? (
                          <p className="text-sm text-gray-500">No audit entries</p>
                        ) : (
                          <table className="w-full text-xs">
                            <thead>
                              <tr className="text-gray-500">
                                <th className="text-left p-1">Time</th>
                                <th className="text-left p-1">Action</th>
                                <th className="text-left p-1">Endpoint</th>
                                <th className="text-left p-1">Records</th>
                                <th className="text-left p-1">Status</th>
                                <th className="text-left p-1">IP</th>
                              </tr>
                            </thead>
                            <tbody>
                              {auditData.data.map((a, i) => (
                                <tr key={i} className="border-t dark:border-gray-700">
                                  <td className="p-1">{formatDate(a.timestamp)}</td>
                                  <td className="p-1 font-mono">{a.action}</td>
                                  <td className="p-1 font-mono truncate max-w-48">{a.endpoint || '—'}</td>
                                  <td className="p-1">{a.recordCount ?? '—'}</td>
                                  <td className="p-1">{a.statusCode || '—'}</td>
                                  <td className="p-1">{a.ipAddress || '—'}</td>
                                </tr>
                              ))}
                            </tbody>
                          </table>
                        )}
                        <div className="text-xs text-gray-400 mt-1">{auditData.total} total entries</div>
                      </td>
                    </tr>
                  )}
                </>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
