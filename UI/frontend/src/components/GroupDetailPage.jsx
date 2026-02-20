import { useState, useEffect, useCallback } from 'react';
import { useAuth } from '../auth/AuthGate';

const TYPE_BADGE = {
  Direct:   { letter: 'D', bg: '#166534', text: '#fff' },
  Indirect: { letter: 'I', bg: '#1e40af', text: '#fff' },
  Eligible: { letter: 'E', bg: '#854d0e', text: '#fff' },
  Owner:    { letter: 'O', bg: '#9d174d', text: '#fff' },
};

const HEADER_FIELDS = ['description', 'groupTypeCalculated'];
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

export default function GroupDetailPage({ groupId, cachedData, onCacheData, onClose, onOpenDetail }) {
  const { authFetch } = useAuth();

  // Core data (fast — attributes, tags, counts)
  const [data, setData] = useState(cachedData?.core || null);
  const [loading, setLoading] = useState(!cachedData?.core);
  const [error, setError] = useState(null);

  // Lazy-loaded sections
  const [membersOpen, setMembersOpen] = useState(false);
  const [members, setMembers] = useState(cachedData?.members || null);
  const [membersLoading, setMembersLoading] = useState(false);

  const [apOpen, setApOpen] = useState(false);
  const [accessPackages, setAccessPackages] = useState(cachedData?.accessPackages || null);
  const [apLoading, setApLoading] = useState(false);

  const [historyOpen, setHistoryOpen] = useState(false);
  const [history, setHistory] = useState(cachedData?.history || null);
  const [historyLoading, setHistoryLoading] = useState(false);

  // Fetch core data (attributes + tags + counts)
  useEffect(() => {
    if (cachedData?.core) return;
    let cancelled = false;
    setLoading(true);
    setError(null);
    authFetch(`/api/group/${encodeURIComponent(groupId)}`)
      .then(r => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json(); })
      .then(d => {
        if (!cancelled) {
          setData(d);
          onCacheData?.(groupId, 'group', { core: d });
        }
      })
      .catch(e => { if (!cancelled) setError(e.message); })
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [groupId, authFetch, cachedData?.core, onCacheData]);

  // Lazy-load members
  const loadMembers = useCallback(() => {
    if (members) return;
    setMembersLoading(true);
    authFetch(`/api/group/${encodeURIComponent(groupId)}/members`)
      .then(r => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json(); })
      .then(d => {
        setMembers(d);
        onCacheData?.(groupId, 'group', { members: d });
      })
      .catch(() => setMembers([]))
      .finally(() => setMembersLoading(false));
  }, [groupId, authFetch, members, onCacheData]);

  // Lazy-load access packages
  const loadAccessPackages = useCallback(() => {
    if (accessPackages) return;
    setApLoading(true);
    authFetch(`/api/group/${encodeURIComponent(groupId)}/access-packages`)
      .then(r => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json(); })
      .then(d => {
        setAccessPackages(d);
        onCacheData?.(groupId, 'group', { accessPackages: d });
      })
      .catch(() => setAccessPackages([]))
      .finally(() => setApLoading(false));
  }, [groupId, authFetch, accessPackages, onCacheData]);

  // Lazy-load history
  const loadHistory = useCallback(() => {
    if (history) return;
    setHistoryLoading(true);
    authFetch(`/api/group/${encodeURIComponent(groupId)}/history`)
      .then(r => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json(); })
      .then(d => {
        setHistory(d);
        onCacheData?.(groupId, 'group', { history: d });
      })
      .catch(() => setHistory([]))
      .finally(() => setHistoryLoading(false));
  }, [groupId, authFetch, history, onCacheData]);

  // Toggle handlers
  const toggleMembers = useCallback(() => {
    setMembersOpen(prev => {
      if (!prev) loadMembers();
      return !prev;
    });
  }, [loadMembers]);

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
    return <div className="flex items-center justify-center h-64 text-gray-500">Loading group details...</div>;
  }
  if (error) {
    return (
      <div className="bg-red-50 border border-red-200 rounded-lg p-6">
        <h2 className="text-red-800 font-semibold">Error loading group</h2>
        <p className="text-red-600 mt-1 text-sm">{error}</p>
      </div>
    );
  }
  if (!data) return null;

  const { attributes, tags, memberCount, accessPackageCount, historyCount } = data;
  const otherAttributes = Object.entries(attributes).filter(([k]) => !HIDDEN_FIELDS.has(k));

  // Group members by memberId to show combined membership types
  const groupedMembers = new Map();
  if (members) {
    for (const m of members) {
      if (!groupedMembers.has(m.memberId)) {
        groupedMembers.set(m.memberId, {
          memberId: m.memberId,
          memberDisplayName: m.memberDisplayName,
          memberUPN: m.memberUPN,
          types: [],
          managed: false,
        });
      }
      const g = groupedMembers.get(m.memberId);
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
            <div className="w-10 h-10 rounded-full bg-purple-100 text-purple-700 flex items-center justify-center text-lg font-bold">
              G
            </div>
            <div>
              <h2 className="text-xl font-semibold text-gray-900">{attributes.displayName}</h2>
              {attributes.groupTypeCalculated && (
                <p className="text-sm text-gray-500">{attributes.groupTypeCalculated}</p>
              )}
            </div>
          </div>
          {attributes.description && (
            <p className="text-sm text-gray-600 mt-2 max-w-2xl">{attributes.description}</p>
          )}
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

      {/* Members - collapsible, lazy-loaded */}
      <div className="mt-6">
        <CollapsibleSection
          title="Members"
          count={memberCount}
          open={membersOpen}
          onToggle={toggleMembers}
          loading={membersLoading}
        >
          {groupedMembers.size === 0 ? (
            <p className="text-sm text-gray-400 italic">No members found</p>
          ) : (
            <table className="w-full text-sm">
              <thead>
                <tr className="text-left text-gray-500 border-b border-gray-100">
                  <th className="pb-1 font-medium">Name</th>
                  <th className="pb-1 font-medium w-48">UPN</th>
                  <th className="pb-1 font-medium w-32">Membership</th>
                  <th className="pb-1 font-medium w-20">Managed</th>
                </tr>
              </thead>
              <tbody>
                {[...groupedMembers.values()].map(m => (
                  <tr key={m.memberId} className="border-b border-gray-50 hover:bg-gray-50 cursor-pointer"
                    onClick={() => onOpenDetail('user', m.memberId, m.memberDisplayName)}>
                    <td className="py-1.5 text-blue-600 hover:text-blue-800 font-medium">
                      {m.memberDisplayName || m.memberId}
                    </td>
                    <td className="py-1.5 text-gray-500 text-xs truncate">{m.memberUPN}</td>
                    <td className="py-1.5">
                      <div className="flex gap-1">
                        {m.types.map(type => {
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
                      {m.managed && <span className="text-green-600 text-xs font-medium">AP</span>}
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
            <p className="text-sm text-gray-400 italic">Not included in any access packages</p>
          ) : accessPackages ? (
            <table className="w-full text-sm">
              <thead>
                <tr className="text-left text-gray-500 border-b border-gray-100">
                  <th className="pb-1 font-medium">Package</th>
                  <th className="pb-1 font-medium w-20">Role</th>
                </tr>
              </thead>
              <tbody>
                {accessPackages.map((ap, i) => (
                  <tr key={i} className="border-b border-gray-50">
                    <td className="py-1 text-gray-900">{ap.accessPackageName || ap.accessPackageId}</td>
                    <td className="py-1 text-gray-500 text-xs">{ap.roleName || '—'}</td>
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
