import { useState, useEffect, useCallback } from 'react';
import { useAuth } from '../auth/AuthGate';

const TYPE_BADGE = {
  Direct:   { letter: 'D', bg: '#166534', text: '#fff' },
  Indirect: { letter: 'I', bg: '#1e40af', text: '#fff' },
  Eligible: { letter: 'E', bg: '#854d0e', text: '#fff' },
  Owner:    { letter: 'O', bg: '#9d174d', text: '#fff' },
};

const HEADER_FIELDS = ['userPrincipalName', 'department', 'jobTitle', 'companyName'];
const HIDDEN_FIELDS = new Set(['id', 'displayName', ...HEADER_FIELDS, 'ValidFrom', 'ValidTo']);

function formatDate(val) {
  if (!val) return '';
  const d = new Date(val);
  if (isNaN(d)) return String(val);
  return d.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
}

function formatValue(val) {
  if (val === null || val === undefined) return '—';
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

export default function UserDetailPage({ userId, cachedData, onCacheData, onClose, onOpenDetail }) {
  const { authFetch } = useAuth();

  // Core data (fast — attributes, tags, counts)
  const [data, setData] = useState(cachedData?.core || null);
  const [loading, setLoading] = useState(!cachedData?.core);
  const [error, setError] = useState(null);

  // Lazy-loaded sections
  const [membershipsOpen, setMembershipsOpen] = useState(false);
  const [memberships, setMemberships] = useState(cachedData?.memberships || null);
  const [membershipsLoading, setMembershipsLoading] = useState(false);

  const [apOpen, setApOpen] = useState(false);
  const [accessPackages, setAccessPackages] = useState(cachedData?.accessPackages || null);
  const [apLoading, setApLoading] = useState(false);

  const [historyOpen, setHistoryOpen] = useState(false);
  const [history, setHistory] = useState(cachedData?.history || null);
  const [historyLoading, setHistoryLoading] = useState(false);

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

  // Lazy-load memberships
  const loadMemberships = useCallback(() => {
    if (memberships) return; // Already loaded
    setMembershipsLoading(true);
    authFetch(`/api/user/${encodeURIComponent(userId)}/memberships`)
      .then(r => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json(); })
      .then(d => {
        setMemberships(d);
        onCacheData?.(userId, 'user', { memberships: d });
      })
      .catch(() => setMemberships([]))
      .finally(() => setMembershipsLoading(false));
  }, [userId, authFetch, memberships, onCacheData]);

  // Lazy-load access packages
  const loadAccessPackages = useCallback(() => {
    if (accessPackages) return;
    setApLoading(true);
    authFetch(`/api/user/${encodeURIComponent(userId)}/access-packages`)
      .then(r => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json(); })
      .then(d => {
        setAccessPackages(d);
        onCacheData?.(userId, 'user', { accessPackages: d });
      })
      .catch(() => setAccessPackages([]))
      .finally(() => setApLoading(false));
  }, [userId, authFetch, accessPackages, onCacheData]);

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

  // Toggle handlers that also trigger loading
  const toggleMemberships = useCallback(() => {
    setMembershipsOpen(prev => {
      if (!prev) loadMemberships();
      return !prev;
    });
  }, [loadMemberships]);

  const toggleAp = useCallback(() => {
    setApOpen(prev => {
      if (!prev) loadAccessPackages();
      return !prev;
    });
  }, [loadAccessPackages]);

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

  const { attributes, tags, membershipCount, accessPackageCount, historyCount } = data;
  const otherAttributes = Object.entries(attributes).filter(([k]) => !HIDDEN_FIELDS.has(k));

  // Group memberships by groupId
  const groupedMemberships = new Map();
  if (memberships) {
    for (const m of memberships) {
      if (!groupedMemberships.has(m.groupId)) {
        groupedMemberships.set(m.groupId, {
          groupId: m.groupId,
          groupDisplayName: m.groupDisplayName,
          groupTypeCalculated: m.groupTypeCalculated,
          types: [],
          managed: false,
        });
      }
      const g = groupedMemberships.get(m.groupId);
      g.types.push(m.membershipType);
      if (m.managedByAccessPackage) g.managed = true;
    }
  }

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
        </div>
        <button onClick={onClose}
          className="text-gray-400 hover:text-gray-600 p-1 rounded hover:bg-gray-100"
          title="Close tab">
          <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
          </svg>
        </button>
      </div>

      {/* Attributes - full width */}
      <Section title="Attributes" count={otherAttributes.length}>
        <div className="grid grid-cols-2 lg:grid-cols-3 gap-x-6 gap-y-1.5">
          {otherAttributes.map(([key, val]) => (
            <div key={key} className="flex justify-between text-sm min-w-0">
              <span className="text-gray-500 truncate mr-2 shrink-0">{friendlyLabel(key)}</span>
              <span className="text-gray-900 font-medium text-right truncate">{formatValue(val)}</span>
            </div>
          ))}
        </div>
      </Section>

      {/* Group Memberships - collapsible, lazy-loaded */}
      <div className="mt-6">
        <CollapsibleSection
          title="Group Memberships"
          count={membershipCount}
          open={membershipsOpen}
          onToggle={toggleMemberships}
          loading={membershipsLoading}
        >
          {groupedMemberships.size === 0 ? (
            <p className="text-sm text-gray-400 italic">No group memberships found</p>
          ) : (
            <table className="w-full text-sm">
              <thead>
                <tr className="text-left text-gray-500 border-b border-gray-100">
                  <th className="pb-1 font-medium">Group</th>
                  <th className="pb-1 font-medium w-24">Type</th>
                  <th className="pb-1 font-medium w-32">Membership</th>
                  <th className="pb-1 font-medium w-20">Managed</th>
                </tr>
              </thead>
              <tbody>
                {[...groupedMemberships.values()].map(g => (
                  <tr key={g.groupId} className="border-b border-gray-50 hover:bg-gray-50 cursor-pointer"
                    onClick={() => onOpenDetail('group', g.groupId, g.groupDisplayName)}>
                    <td className="py-1.5 text-blue-600 hover:text-blue-800 font-medium">
                      {g.groupDisplayName || g.groupId}
                    </td>
                    <td className="py-1.5 text-gray-500 text-xs">{g.groupTypeCalculated}</td>
                    <td className="py-1.5">
                      <div className="flex gap-1">
                        {g.types.map(type => {
                          const b = TYPE_BADGE[type];
                          return b ? (
                            <span key={type}
                              className="inline-block w-5 h-5 rounded-sm text-center font-bold text-[10px] leading-5"
                              style={{ backgroundColor: b.bg, color: b.text }}>
                              {b.letter}
                            </span>
                          ) : <span key={type} className="text-xs text-gray-400">{type}</span>;
                        })}
                      </div>
                    </td>
                    <td className="py-1.5 text-center">
                      {g.managed && <span className="text-green-600 text-xs font-medium">AP</span>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </CollapsibleSection>
      </div>

      {/* Access Packages - collapsible, lazy-loaded */}
      <div className="mt-6">
        <CollapsibleSection
          title="Access Packages"
          count={accessPackageCount}
          open={apOpen}
          onToggle={toggleAp}
          loading={apLoading}
        >
          {accessPackages && accessPackages.length === 0 ? (
            <p className="text-sm text-gray-400 italic">No access package assignments</p>
          ) : accessPackages ? (
            <table className="w-full text-sm">
              <thead>
                <tr className="text-left text-gray-500 border-b border-gray-100">
                  <th className="pb-1 font-medium">Package</th>
                  <th className="pb-1 font-medium w-20">State</th>
                  <th className="pb-1 font-medium w-28">Assigned</th>
                </tr>
              </thead>
              <tbody>
                {accessPackages.map((ap, i) => (
                  <tr key={i} className="border-b border-gray-50">
                    <td className="py-1 text-gray-900">{ap.accessPackageName || ap.accessPackageId}</td>
                    <td className="py-1">
                      <span className={`inline-block px-1.5 py-0.5 rounded text-xs font-medium ${
                        ap.state === 'delivered' ? 'bg-green-100 text-green-700' :
                        ap.state === 'expired' ? 'bg-gray-100 text-gray-500' :
                        'bg-yellow-100 text-yellow-700'
                      }`}>{ap.state || '—'}</span>
                    </td>
                    <td className="py-1 text-gray-500 text-xs">{formatDate(ap.assignedDateTime)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : null}
        </CollapsibleSection>
      </div>

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
  return key.replace(/([A-Z])/g, ' $1').replace(/^./, s => s.toUpperCase()).trim();
}
