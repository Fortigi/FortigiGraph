import { useState, useEffect, useCallback } from 'react';
import { useAuth } from '../auth/AuthGate';
import RiskScoreSection, { RISK_FIELDS } from './RiskScoreSection';

const HEADER_FIELDS = ['userPrincipalName', 'department', 'jobTitle', 'companyName'];
const HIDDEN_FIELDS = new Set(['displayName', ...HEADER_FIELDS, ...RISK_FIELDS, 'ValidFrom', 'ValidTo']);

function formatDate(val) {
  if (!val) return '';
  const d = new Date(val);
  if (isNaN(d)) return String(val);
  return d.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
}

function formatValue(val) {
  if (val === null || val === undefined) return '\u2014';
  if (val === true) return 'Yes';
  if (val === false) return 'No';
  if (typeof val === 'string' && val.match(/^\d{4}-\d{2}-\d{2}T/)) return formatDate(val);
  return String(val);
}

function computeHistoryDiffs(history) {
  if (!history || history.length <= 1) return [];
  const diffs = [];
  for (let i = 0; i < history.length - 1; i++) {
    const newer = history[i];
    const older = history[i + 1];
    const changes = [];
    const allKeys = new Set([...Object.keys(newer), ...Object.keys(older)]);
    for (const key of allKeys) {
      if (key === 'ValidFrom' || key === 'ValidTo' || key === 'id') continue;
      const oldVal = formatValue(older[key]);
      const newVal = formatValue(newer[key]);
      if (oldVal !== newVal) {
        changes.push({ field: key, from: oldVal, to: newVal });
      }
    }
    if (changes.length > 0) {
      diffs.push({ date: newer.ValidFrom, changes });
    }
  }
  return diffs;
}

const TIER_COLORS = {
  Critical: 'bg-red-100 text-red-800',
  High: 'bg-orange-100 text-orange-800',
  Medium: 'bg-yellow-100 text-yellow-800',
  Low: 'bg-blue-100 text-blue-800',
  Minimal: 'bg-gray-100 text-gray-600',
};

export default function UserDetailPage({ userId, cachedData, onCacheData, onClose, onOpenDetail }) {
  const { authFetch } = useAuth();

  // Core data (fast — attributes, tags, counts)
  const [data, setData] = useState(cachedData?.core || null);
  const [loading, setLoading] = useState(!cachedData?.core);
  const [error, setError] = useState(null);

  // Lazy-loaded history
  const [historyOpen, setHistoryOpen] = useState(false);
  const [history, setHistory] = useState(cachedData?.history || null);
  const [historyLoading, setHistoryLoading] = useState(false);

  // Manager and direct reports
  const [manager, setManager] = useState(null);
  const [managerLoaded, setManagerLoaded] = useState(false);
  const [reportsOpen, setReportsOpen] = useState(false);
  const [reports, setReports] = useState(null);
  const [reportsLoading, setReportsLoading] = useState(false);

  // Fetch core data (attributes + tags + counts)
  useEffect(() => {
    if (cachedData?.core) return; // Already cached
    let cancelled = false;
    setLoading(true);
    setError(null);
    authFetch(`/api/user/${encodeURIComponent(userId)}`)
      .then(r => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json(); })
      .then(d => {
        if (!cancelled) {
          setData(d);
          onCacheData?.(userId, 'user', { core: d });
        }
      })
      .catch(e => { if (!cancelled) setError(e.message); })
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [userId, authFetch, cachedData?.core, onCacheData]);

  // Fetch manager (lightweight — one record)
  useEffect(() => {
    let cancelled = false;
    authFetch(`/api/org-chart/user/${encodeURIComponent(userId)}/manager`)
      .then(r => r.ok ? r.json() : null)
      .then(d => { if (!cancelled && d?.manager) setManager(d.manager); })
      .catch(() => {})
      .finally(() => { if (!cancelled) setManagerLoaded(true); });
    return () => { cancelled = true; };
  }, [userId, authFetch]);

  // Lazy-load direct reports
  const loadReports = useCallback(() => {
    if (reports) return;
    setReportsLoading(true);
    authFetch(`/api/org-chart/user/${encodeURIComponent(userId)}/reports`)
      .then(r => r.ok ? r.json() : null)
      .then(d => setReports(d?.reports || []))
      .catch(() => setReports([]))
      .finally(() => setReportsLoading(false));
  }, [userId, authFetch, reports]);

  const toggleReports = useCallback(() => {
    setReportsOpen(prev => {
      if (!prev) loadReports();
      return !prev;
    });
  }, [loadReports]);

  // Lazy-load history
  const loadHistory = useCallback(() => {
    if (history) return;
    setHistoryLoading(true);
    authFetch(`/api/user/${encodeURIComponent(userId)}/history`)
      .then(r => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json(); })
      .then(d => {
        setHistory(d);
        onCacheData?.(userId, 'user', { history: d });
      })
      .catch(() => setHistory([]))
      .finally(() => setHistoryLoading(false));
  }, [userId, authFetch, history, onCacheData]);

  const toggleHistory = useCallback(() => {
    setHistoryOpen(prev => {
      if (!prev) loadHistory();
      return !prev;
    });
  }, [loadHistory]);

  if (loading) {
    return <div className="flex items-center justify-center h-64 text-gray-500">Loading user details...</div>;
  }
  if (error) {
    return (
      <div className="bg-red-50 border border-red-200 rounded-lg p-6">
        <h2 className="text-red-800 font-semibold">Error loading user</h2>
        <p className="text-red-600 mt-1 text-sm">{error}</p>
      </div>
    );
  }
  if (!data) return null;

  const { attributes, tags, hasHistory } = data;
  const historyCount = history ? history.length : (hasHistory ? null : 1);
  const otherAttributes = [['id', attributes.id], ...Object.entries(attributes).filter(([k]) => !HIDDEN_FIELDS.has(k) && k !== 'id')];
  const entraUrl = `https://entra.microsoft.com/#view/Microsoft_AAD_UsersAndTenants/UserProfileMenuBlade/~/overview/userId/${encodeURIComponent(userId)}`;

  const historyDiffs = history ? computeHistoryDiffs(history) : [];

  return (
    <div className="max-w-5xl mx-auto">
      {/* Header */}
      <div className="flex items-start justify-between mb-6">
        <div>
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-full bg-blue-100 text-blue-700 flex items-center justify-center text-lg font-bold">
              {(attributes.displayName || '?')[0]}
            </div>
            <div>
              <h2 className="text-xl font-semibold text-gray-900">{attributes.displayName}</h2>
              <p className="text-sm text-gray-500">{attributes.userPrincipalName}</p>
            </div>
          </div>
          <div className="flex items-center gap-4 mt-2 text-sm text-gray-600">
            {attributes.jobTitle && <span>{attributes.jobTitle}</span>}
            {attributes.department && <span className="text-gray-400">|</span>}
            {attributes.department && <span>{attributes.department}</span>}
            {attributes.companyName && <span className="text-gray-400">|</span>}
            {attributes.companyName && <span>{attributes.companyName}</span>}
          </div>
          {tags.length > 0 && (
            <div className="flex gap-1.5 mt-2">
              {tags.map(t => (
                <span key={t.id} className="inline-block px-2 py-0.5 rounded-full text-xs font-medium border"
                  style={{ backgroundColor: t.color + '20', borderColor: t.color, color: t.color }}>
                  {t.name}
                </span>
              ))}
            </div>
          )}
          <a href={entraUrl} target="_blank" rel="noopener noreferrer"
            className="inline-flex items-center gap-1 mt-2 text-xs text-blue-600 hover:text-blue-800 hover:underline">
            Open in Entra ID
            <svg className="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14" />
            </svg>
          </a>
        </div>
        <button onClick={onClose}
          className="text-gray-400 hover:text-gray-600 p-1 rounded hover:bg-gray-100"
          title="Close tab">
          <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
          </svg>
        </button>
      </div>

      {/* Risk Assessment */}
      <RiskScoreSection attributes={attributes} entityType="user" entityId={userId} authFetch={authFetch} />

      {/* Manager */}
      {managerLoaded && manager && (
        <div className="bg-white border border-gray-200 rounded-lg p-4 mt-4 mb-4">
          <h3 className="text-sm font-semibold text-gray-700 mb-2">Manager</h3>
          <div className="flex items-center gap-3">
            <div className="w-8 h-8 rounded-full bg-blue-100 text-blue-700 flex items-center justify-center text-sm font-bold shrink-0">
              {(manager.displayName || '?')[0]}
            </div>
            <div className="min-w-0 flex-1">
              <button
                onClick={() => onOpenDetail?.('user', manager.id, manager.displayName)}
                className="text-sm font-medium text-blue-700 hover:text-blue-900 hover:underline text-left"
              >
                {manager.displayName}
              </button>
              <div className="text-xs text-gray-400">
                {[manager.jobTitle, manager.department].filter(Boolean).join(' \u2022 ') || '\u2014'}
              </div>
            </div>
            {manager.riskTier && manager.riskTier !== 'None' && manager.riskTier !== 'Minimal' && (
              <span className={`text-xs px-2 py-0.5 rounded-full font-medium ${TIER_COLORS[manager.riskTier] || ''}`}>
                {manager.riskTier}
              </span>
            )}
          </div>
        </div>
      )}

      {/* Direct Reports */}
      {managerLoaded && (
        <div className="mb-4">
          <CollapsibleSection
            title="Direct Reports"
            count={attributes.riskHierarchyDirectReports || null}
            open={reportsOpen}
            onToggle={toggleReports}
            loading={reportsLoading}
          >
            {reports && reports.length === 0 ? (
              <p className="text-sm text-gray-400 italic p-4">No direct reports</p>
            ) : reports ? (
              <div className="divide-y divide-gray-50">
                {reports.map(r => (
                  <div key={r.id} className="flex items-center gap-3 px-4 py-2 hover:bg-gray-50">
                    <div className="w-7 h-7 rounded-full bg-blue-100 text-blue-700 flex items-center justify-center text-xs font-bold shrink-0">
                      {(r.displayName || '?')[0]}
                    </div>
                    <div className="min-w-0 flex-1">
                      <button
                        onClick={() => onOpenDetail?.('user', r.id, r.displayName)}
                        className="text-sm font-medium text-blue-700 hover:text-blue-900 hover:underline text-left"
                      >
                        {r.displayName}
                      </button>
                      <div className="text-xs text-gray-400">
                        {[r.jobTitle, r.department].filter(Boolean).join(' \u2022 ') || '\u2014'}
                      </div>
                    </div>
                    {r.riskTier && r.riskTier !== 'None' && r.riskTier !== 'Minimal' && (
                      <span className={`text-xs px-2 py-0.5 rounded-full font-medium ${TIER_COLORS[r.riskTier] || ''}`}>
                        {r.riskTier}
                      </span>
                    )}
                    {r.riskScore != null && (
                      <span className="text-xs font-mono text-gray-400 w-6 text-right">{r.riskScore}</span>
                    )}
                  </div>
                ))}
              </div>
            ) : null}
          </CollapsibleSection>
        </div>
      )}

      {/* Attributes - single column table */}
      <Section title="Attributes" count={otherAttributes.length}>
        <table className="w-full text-sm">
          <tbody>
            {otherAttributes.map(([key, val]) => (
              <tr key={key} className="border-b border-gray-50 last:border-b-0">
                <td className="py-1 pr-4 text-gray-500 whitespace-nowrap align-top">{friendlyLabel(key)}</td>
                <td className="py-1 text-gray-900 font-medium break-all">{formatValue(val)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </Section>

      {/* Version History - collapsible, lazy-loaded */}
      <div className="mt-6">
        <CollapsibleSection
          title="Version History"
          count={historyCount}
          countLabel={historyCount === 1 ? 'version' : 'versions'}
          open={historyOpen}
          onToggle={toggleHistory}
          loading={historyLoading}
        >
          {historyDiffs.length === 0 ? (
            <p className="text-sm text-gray-400 italic p-4">No changes recorded</p>
          ) : (
            <table className="w-full text-sm">
              <thead>
                <tr className="text-left text-gray-500 bg-gray-50 border-b border-gray-200">
                  <th className="px-4 py-2 font-medium w-44">Date</th>
                  <th className="px-4 py-2 font-medium">Changes</th>
                </tr>
              </thead>
              <tbody>
                {historyDiffs.map((diff, i) => (
                  <tr key={i} className="border-b border-gray-50">
                    <td className="px-4 py-2 text-gray-600 text-xs align-top whitespace-nowrap">
                      {formatDate(diff.date)}
                    </td>
                    <td className="px-4 py-2">
                      <div className="flex flex-col gap-1">
                        {diff.changes.map((c, j) => (
                          <div key={j} className="text-xs">
                            <span className="font-medium text-gray-700">{friendlyLabel(c.field)}</span>
                            <span className="text-gray-400 mx-1">:</span>
                            <span className="text-red-500 line-through mr-1">{c.from}</span>
                            <span className="text-gray-400 mr-1">&rarr;</span>
                            <span className="text-green-600">{c.to}</span>
                          </div>
                        ))}
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </CollapsibleSection>
      </div>
    </div>
  );
}

function Section({ title, count, children }) {
  return (
    <div className="bg-white border border-gray-200 rounded-lg p-4">
      <h3 className="text-sm font-semibold text-gray-700 mb-3 flex items-center gap-2">
        {title}
        {count != null && <span className="text-xs font-normal text-gray-400">({count})</span>}
      </h3>
      {children}
    </div>
  );
}

function CollapsibleSection({ title, count, countLabel, open, onToggle, loading, children }) {
  return (
    <div>
      <button
        onClick={onToggle}
        className="flex items-center gap-2 text-sm font-semibold text-gray-700 mb-2 hover:text-gray-900"
      >
        <span className="text-xs">{open ? '\u25BC' : '\u25B6'}</span>
        {title}
        {count != null && (
          <span className="text-xs font-normal text-gray-400">
            ({count}{countLabel ? ` ${countLabel}` : ''})
          </span>
        )}
        {loading && <span className="text-xs text-gray-400 animate-pulse">Loading...</span>}
      </button>
      {open && !loading && (
        <div className="bg-white border border-gray-200 rounded-lg overflow-hidden">
          {children}
        </div>
      )}
    </div>
  );
}

function friendlyLabel(key) {
  if (key === 'id') return 'GUID';
  return key.replace(/([A-Z])/g, ' $1').replace(/^./, s => s.toUpperCase()).trim();
}
