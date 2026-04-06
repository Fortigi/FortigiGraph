import { useState, useEffect, useCallback, useRef } from 'react';
import { useAuth } from '../auth/AuthGate';

// ─── Getting Started Card ─────────────────────────────────────────────────────
function GettingStarted({ onLoadDemo, onShowEntraId, demoLoading }) {
  return (
    <div className="mb-8 p-6 bg-gradient-to-br from-emerald-50 to-teal-50 dark:from-emerald-900/20 dark:to-teal-900/20 border border-emerald-200 dark:border-emerald-800 rounded-xl">
      <h2 className="text-xl font-bold text-emerald-900 dark:text-emerald-100 mb-2">
        Welcome to Identity Atlas
      </h2>
      <p className="text-emerald-700 dark:text-emerald-300 mb-6">
        No identity data loaded yet. Choose how to get started:
      </p>
      <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
        <button
          onClick={onLoadDemo}
          disabled={demoLoading}
          className="flex flex-col items-start p-4 bg-white dark:bg-gray-800 rounded-lg border-2 border-emerald-300 dark:border-emerald-700 hover:border-emerald-500 hover:shadow-md transition-all text-left disabled:opacity-50"
        >
          <span className="text-lg font-semibold text-gray-900 dark:text-white mb-1">
            {demoLoading ? 'Loading...' : 'Load Demo Data'}
          </span>
          <span className="text-sm text-gray-500 dark:text-gray-400">
            Explore with synthetic data (~30 seconds)
          </span>
        </button>

        <button
          onClick={onShowEntraId}
          className="flex flex-col items-start p-4 bg-white dark:bg-gray-800 rounded-lg border border-gray-200 dark:border-gray-700 hover:border-indigo-400 hover:shadow-md transition-all text-left"
        >
          <span className="text-lg font-semibold text-gray-900 dark:text-white mb-1">Connect Entra ID</span>
          <span className="text-sm text-gray-500 dark:text-gray-400">
            Sync from your Azure AD / Entra ID tenant
          </span>
        </button>

        <button
          disabled
          className="flex flex-col items-start p-4 bg-white dark:bg-gray-800 rounded-lg border border-gray-200 dark:border-gray-700 opacity-60 text-left cursor-not-allowed"
        >
          <span className="text-lg font-semibold text-gray-900 dark:text-white mb-1">Import CSV</span>
          <span className="text-sm text-gray-500 dark:text-gray-400">
            Upload identity data from files (coming soon)
          </span>
        </button>

        <button
          disabled
          className="flex flex-col items-start p-4 bg-white dark:bg-gray-800 rounded-lg border border-gray-200 dark:border-gray-700 opacity-60 text-left cursor-not-allowed"
        >
          <span className="text-lg font-semibold text-gray-900 dark:text-white mb-1">Download Scripts</span>
          <span className="text-sm text-gray-500 dark:text-gray-400">
            Run crawlers from your own machine (coming soon)
          </span>
        </button>
      </div>
    </div>
  );
}

// ─── Entra ID Configuration Form ────────��─────────────────────────────────────
function EntraIdForm({ onSubmit, onCancel, loading }) {
  const [tenantId, setTenantId] = useState('');
  const [clientId, setClientId] = useState('');
  const [clientSecret, setClientSecret] = useState('');
  const [syncPrincipals, setSyncPrincipals] = useState(true);
  const [syncResources, setSyncResources] = useState(true);
  const [syncAssignments, setSyncAssignments] = useState(true);
  const [syncGovernance, setSyncGovernance] = useState(true);

  const handleSubmit = (e) => {
    e.preventDefault();
    if (!tenantId.trim() || !clientId.trim() || !clientSecret.trim()) return;
    onSubmit({
      tenantId: tenantId.trim(),
      clientId: clientId.trim(),
      clientSecret: clientSecret.trim(),
      syncPrincipals,
      syncResources,
      syncAssignments,
      syncGovernance,
    });
  };

  return (
    <div className="mb-6 p-5 bg-indigo-50 dark:bg-indigo-900/20 border border-indigo-200 dark:border-indigo-800 rounded-lg">
      <h3 className="text-lg font-semibold text-indigo-900 dark:text-indigo-100 mb-4">Connect Entra ID</h3>
      <p className="text-sm text-indigo-700 dark:text-indigo-300 mb-4">
        Enter your App Registration credentials. These are used once to sync data and are not stored permanently.
      </p>
      <form onSubmit={handleSubmit}>
        <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mb-4">
          <div>
            <label className="block text-sm font-medium mb-1">Tenant ID *</label>
            <input
              type="text" value={tenantId} onChange={e => setTenantId(e.target.value)}
              placeholder="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
              className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 font-mono text-sm"
              required
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-1">Client ID *</label>
            <input
              type="text" value={clientId} onChange={e => setClientId(e.target.value)}
              placeholder="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
              className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 font-mono text-sm"
              required
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-1">Client Secret *</label>
            <input
              type="password" value={clientSecret} onChange={e => setClientSecret(e.target.value)}
              placeholder="Enter client secret"
              className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 text-sm"
              required
            />
          </div>
        </div>
        <div className="flex flex-wrap gap-4 mb-4">
          {[
            ['Principals (Users)', syncPrincipals, setSyncPrincipals],
            ['Resources (Groups)', syncResources, setSyncResources],
            ['Assignments (Memberships)', syncAssignments, setSyncAssignments],
            ['Governance (Access Packages)', syncGovernance, setSyncGovernance],
          ].map(([label, val, setter]) => (
            <label key={label} className="flex items-center gap-2 text-sm">
              <input type="checkbox" checked={val} onChange={e => setter(e.target.checked)} className="rounded" />
              {label}
            </label>
          ))}
        </div>
        <div className="flex gap-2">
          <button
            type="submit"
            disabled={loading || !tenantId.trim() || !clientId.trim() || !clientSecret.trim()}
            className="px-4 py-2 bg-indigo-600 text-white rounded text-sm hover:bg-indigo-700 disabled:opacity-50"
          >
            {loading ? 'Starting...' : 'Start Sync'}
          </button>
          <button type="button" onClick={onCancel} className="px-4 py-2 bg-gray-200 dark:bg-gray-600 rounded text-sm">
            Cancel
          </button>
        </div>
      </form>
    </div>
  );
}

// ─── Job Progress Card ─────────���──────────────────────────────────────────────
function JobProgress({ job, onNavigateToMatrix, onDismiss }) {
  if (!job) return null;

  const progress = job.progress ? (typeof job.progress === 'string' ? JSON.parse(job.progress) : job.progress) : {};
  const pct = progress.pct || 0;
  const step = progress.step || 'Waiting...';

  if (job.status === 'completed') {
    return (
      <div className="mb-6 p-4 bg-green-50 dark:bg-green-900/30 border border-green-200 dark:border-green-800 rounded-lg">
        <div className="flex items-center justify-between">
          <div>
            <span className="font-semibold text-green-800 dark:text-green-200">Data loaded successfully!</span>
            <p className="text-sm text-green-600 dark:text-green-400 mt-1">
              Your identity data is ready to explore.
            </p>
          </div>
          <div className="flex gap-2">
            {onNavigateToMatrix && (
              <button
                onClick={onNavigateToMatrix}
                className="px-4 py-2 bg-green-600 text-white rounded-lg text-sm hover:bg-green-700"
              >
                Open Matrix
              </button>
            )}
            {onDismiss && (
              <button onClick={onDismiss} className="text-green-600 hover:text-green-800 text-sm">Dismiss</button>
            )}
          </div>
        </div>
      </div>
    );
  }

  if (job.status === 'failed') {
    return (
      <div className="mb-6 p-4 bg-red-50 dark:bg-red-900/30 border border-red-200 dark:border-red-800 rounded-lg">
        <div className="flex items-center justify-between">
          <div>
            <span className="font-semibold text-red-800 dark:text-red-200">Job failed</span>
            <p className="text-sm text-red-600 dark:text-red-400 mt-1">{job.errorMessage || 'Unknown error'}</p>
          </div>
          {onDismiss && (
            <button onClick={onDismiss} className="text-red-500 hover:text-red-700 text-sm">Dismiss</button>
          )}
        </div>
      </div>
    );
  }

  // Running or queued
  return (
    <div className="mb-6 p-4 bg-blue-50 dark:bg-blue-900/30 border border-blue-200 dark:border-blue-800 rounded-lg">
      <div className="flex items-center justify-between mb-2">
        <span className="font-semibold text-blue-800 dark:text-blue-200">
          {job.status === 'queued' ? 'Waiting for worker...' : step}
        </span>
        <span className="text-sm text-blue-600 dark:text-blue-400">{pct}%</span>
      </div>
      <div className="w-full bg-blue-200 dark:bg-blue-800 rounded-full h-2.5">
        <div
          className="bg-blue-600 h-2.5 rounded-full transition-all duration-500"
          style={{ width: `${Math.max(pct, 2)}%` }}
        />
      </div>
      <p className="text-xs text-blue-500 mt-2">
        {job.jobType === 'demo' ? 'Loading demo data...' : `Running ${job.jobType} crawler...`}
      </p>
    </div>
  );
}

// ─── Recent Jobs Table ────────────────────────────────────────────────────────
function RecentJobs({ jobs }) {
  if (!jobs || jobs.length === 0) return null;

  const statusColors = {
    queued: 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-300',
    running: 'bg-blue-100 text-blue-800 dark:bg-blue-900/30 dark:text-blue-300',
    completed: 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300',
    failed: 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300',
    cancelled: 'bg-gray-100 text-gray-800 dark:bg-gray-700 dark:text-gray-300',
  };

  return (
    <div className="mb-6">
      <h3 className="text-lg font-semibold mb-3">Recent Jobs</h3>
      <div className="bg-white dark:bg-gray-800 rounded-lg border overflow-hidden">
        <table className="w-full text-sm">
          <thead className="bg-gray-50 dark:bg-gray-700">
            <tr>
              <th className="text-left p-3 font-medium">Type</th>
              <th className="text-left p-3 font-medium">Status</th>
              <th className="text-left p-3 font-medium">Created</th>
              <th className="text-left p-3 font-medium">Duration</th>
              <th className="text-left p-3 font-medium">Error</th>
            </tr>
          </thead>
          <tbody className="divide-y dark:divide-gray-700">
            {jobs.map(j => {
              const duration = j.startedAt && j.completedAt
                ? `${Math.round((new Date(j.completedAt) - new Date(j.startedAt)) / 1000)}s`
                : j.startedAt ? 'running...' : '—';
              return (
                <tr key={j.id} className="hover:bg-gray-50 dark:hover:bg-gray-750">
                  <td className="p-3 font-medium">{j.jobType}</td>
                  <td className="p-3">
                    <span className={`px-2 py-0.5 rounded-full text-xs font-medium ${statusColors[j.status] || ''}`}>
                      {j.status}
                    </span>
                  </td>
                  <td className="p-3 text-gray-500">{new Date(j.createdAt).toLocaleString()}</td>
                  <td className="p-3 text-gray-500">{duration}</td>
                  <td className="p-3 text-red-500 text-xs truncate max-w-64">{j.errorMessage || '—'}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}

// ─── Main CrawlersPage ───────────────────────────────────────────────────────

export default function CrawlersPage({ onNavigate }) {
  const { authFetch } = useAuth();
  const [crawlers, setCrawlers] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [showRegister, setShowRegister] = useState(false);
  const [showEntraId, setShowEntraId] = useState(false);
  const [newKey, setNewKey] = useState(null);
  const [expandedAudit, setExpandedAudit] = useState(null);
  const [auditData, setAuditData] = useState({ data: [], total: 0 });

  // System status
  const [status, setStatus] = useState(null);

  // Jobs
  const [jobs, setJobs] = useState([]);
  const [activeJob, setActiveJob] = useState(null);
  const pollRef = useRef(null);

  // Register form state
  const [regName, setRegName] = useState('');
  const [regDesc, setRegDesc] = useState('');
  const [regPerms, setRegPerms] = useState(['ingest']);
  const [regRateLimit, setRegRateLimit] = useState(100);

  // Fetch system status
  const fetchStatus = useCallback(async () => {
    try {
      const res = await authFetch('/api/admin/status');
      if (res.ok) setStatus(await res.json());
    } catch { /* ignore */ }
  }, [authFetch]);

  // Fetch jobs
  const fetchJobs = useCallback(async () => {
    try {
      const res = await authFetch('/api/admin/crawler-jobs?limit=10');
      if (res.ok) {
        const data = await res.json();
        setJobs(Array.isArray(data) ? data : []);

        // Track the most recent active job
        const active = data.find(j => j.status === 'queued' || j.status === 'running');
        if (active) {
          setActiveJob(active);
        } else if (activeJob && (activeJob.status === 'queued' || activeJob.status === 'running')) {
          // Job just finished — fetch its final state
          const finished = data.find(j => j.id === activeJob.id);
          if (finished) setActiveJob(finished);
          // Refresh status since data may have changed
          fetchStatus();
        }
      }
    } catch { /* ignore */ }
  }, [authFetch, activeJob, fetchStatus]);

  // Fetch crawlers
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

  // Initial load
  useEffect(() => {
    fetchCrawlers();
    fetchStatus();
    fetchJobs();
  }, [fetchCrawlers, fetchStatus, fetchJobs]);

  // Poll jobs when there's an active one
  useEffect(() => {
    if (activeJob && (activeJob.status === 'queued' || activeJob.status === 'running')) {
      pollRef.current = setInterval(fetchJobs, 3000);
      return () => clearInterval(pollRef.current);
    } else {
      if (pollRef.current) clearInterval(pollRef.current);
    }
  }, [activeJob, fetchJobs]);

  // ─── Job actions ──────────────────────────────────────────────

  const submitJob = async (jobType, config = null) => {
    try {
      const res = await authFetch('/api/admin/crawler-jobs', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ jobType, config }),
      });
      if (!res.ok) {
        const err = await res.json();
        throw new Error(err.error || `HTTP ${res.status}`);
      }
      const job = await res.json();
      setActiveJob(job);
      setShowEntraId(false);
      fetchJobs();
    } catch (err) {
      setError(err.message);
    }
  };

  // ─── Crawler management actions ───────────────────────────────

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

  const handleDisable = async (crawler) => {
    if (!confirm(`Disable crawler "${crawler.displayName}"?`)) return;
    try {
      await authFetch(`/api/admin/crawlers/${crawler.id}`, { method: 'DELETE' });
      fetchCrawlers();
    } catch (err) {
      setError(err.message);
    }
  };

  const handleRemove = async (crawler) => {
    if (!confirm(`Permanently remove crawler "${crawler.displayName}"? This cannot be undone.`)) return;
    try {
      const res = await authFetch(`/api/admin/crawlers/${crawler.id}`, {
        method: 'DELETE',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ permanent: true }),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
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

  const copyToClipboard = (text) => navigator.clipboard.writeText(text);
  const formatDate = (d) => d ? new Date(d).toLocaleString() : '—';

  const handleNavigateToMatrix = () => {
    if (onNavigate) onNavigate('matrix');
  };

  if (loading) return <div className="p-6 text-gray-500">Loading crawlers...</div>;

  const showGettingStarted = status && !status.hasData && !activeJob;
  const demoLoading = activeJob && activeJob.jobType === 'demo' && ['queued', 'running'].includes(activeJob.status);

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

      {/* Error banner */}
      {error && (
        <div className="mb-4 p-3 bg-red-50 dark:bg-red-900/30 border border-red-200 dark:border-red-800 rounded-lg flex items-center justify-between">
          <span className="text-red-700 dark:text-red-300 text-sm">{error}</span>
          <button onClick={() => setError(null)} className="text-red-500 hover:text-red-700 text-sm">Dismiss</button>
        </div>
      )}

      {/* Getting Started card (shown when no data) */}
      {showGettingStarted && (
        <GettingStarted
          onLoadDemo={() => submitJob('demo')}
          onShowEntraId={() => setShowEntraId(true)}
          demoLoading={demoLoading}
        />
      )}

      {/* Active job progress */}
      {activeJob && ['queued', 'running', 'completed', 'failed'].includes(activeJob.status) && (
        <JobProgress
          job={activeJob}
          onNavigateToMatrix={handleNavigateToMatrix}
          onDismiss={() => setActiveJob(null)}
        />
      )}

      {/* Run Sync section (always visible when data exists) */}
      {!showGettingStarted && !showEntraId && (
        <div className="mb-6">
          <h3 className="text-lg font-semibold mb-3">Run Sync</h3>
          <div className="flex flex-wrap gap-3">
            <button
              onClick={() => setShowEntraId(true)}
              className="px-4 py-2 bg-indigo-600 text-white rounded-lg hover:bg-indigo-700 text-sm font-medium"
            >
              Connect Entra ID
            </button>
            <button
              onClick={() => submitJob('demo')}
              disabled={demoLoading}
              className="px-4 py-2 bg-emerald-600 text-white rounded-lg hover:bg-emerald-700 text-sm font-medium disabled:opacity-50"
            >
              {demoLoading ? 'Loading...' : 'Load Demo Data'}
            </button>
          </div>
        </div>
      )}

      {/* Entra ID configuration form */}
      {showEntraId && (
        <EntraIdForm
          onSubmit={(config) => submitJob('entra-id', config)}
          onCancel={() => setShowEntraId(false)}
          loading={activeJob && activeJob.jobType === 'entra-id' && ['queued', 'running'].includes(activeJob.status)}
        />
      )}

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

      {/* Recent jobs */}
      <RecentJobs jobs={jobs} />

      {/* Crawler table */}
      <h3 className="text-lg font-semibold mb-3">Registered Crawlers</h3>
      {crawlers.length === 0 ? (
        <div className="text-center py-8 text-gray-500 bg-white dark:bg-gray-800 rounded-lg border">
          <p className="text-sm">No external crawlers registered. The built-in worker handles jobs automatically.</p>
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
                <tr key={c.id}>
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
                      {c.enabled && (
                        <button onClick={() => handleDisable(c)} className="px-2 py-1 text-xs bg-gray-100 dark:bg-gray-700 text-gray-800 dark:text-gray-200 rounded hover:bg-gray-200">
                          Disable
                        </button>
                      )}
                      <button onClick={() => handleRemove(c)} className="px-2 py-1 text-xs bg-red-100 dark:bg-red-900/30 text-red-800 dark:text-red-200 rounded hover:bg-red-200">
                        Remove
                      </button>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>

          {/* Audit log expansion */}
          {expandedAudit && (
            <div className="p-3 bg-gray-50 dark:bg-gray-900 border-t">
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
            </div>
          )}
        </div>
      )}
    </div>
  );
}
