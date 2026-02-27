import { useState, useEffect, useCallback, useMemo } from 'react';
import { useAuth } from '../auth/AuthGate';

// ─── Tier badge colors ───────────────────────────────────────────────
const TIER_STYLES = {
  Critical: { bg: 'bg-red-100',    text: 'text-red-800',    border: 'border-red-200',    dot: 'bg-red-500' },
  High:     { bg: 'bg-orange-100', text: 'text-orange-800', border: 'border-orange-200', dot: 'bg-orange-500' },
  Medium:   { bg: 'bg-yellow-100', text: 'text-yellow-800', border: 'border-yellow-200', dot: 'bg-yellow-500' },
  Low:      { bg: 'bg-blue-100',   text: 'text-blue-800',   border: 'border-blue-200',   dot: 'bg-blue-500' },
  Minimal:  { bg: 'bg-gray-100',   text: 'text-gray-600',   border: 'border-gray-200',   dot: 'bg-gray-400' },
  None:     { bg: 'bg-gray-50',    text: 'text-gray-400',   border: 'border-gray-100',   dot: 'bg-gray-300' },
};

function TierBadge({ tier }) {
  const s = TIER_STYLES[tier?.label] || TIER_STYLES.None;
  return (
    <span className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium ${s.bg} ${s.text} ${s.border} border`}>
      <span className={`w-1.5 h-1.5 rounded-full ${s.dot}`} />
      {tier?.label || 'None'}
    </span>
  );
}

function ScoreBar({ score, maxScore = 100 }) {
  const pct = Math.min(100, Math.max(0, (score / maxScore) * 100));
  const color = score >= 90 ? 'bg-red-500' : score >= 70 ? 'bg-orange-500' : score >= 40 ? 'bg-yellow-500' : score >= 20 ? 'bg-blue-500' : 'bg-gray-300';
  return (
    <div className="flex items-center gap-2">
      <div className="w-24 h-2 bg-gray-100 rounded-full overflow-hidden">
        <div className={`h-full rounded-full ${color}`} style={{ width: `${pct}%` }} />
      </div>
      <span className="text-xs font-mono text-gray-600 w-6 text-right">{score}</span>
    </div>
  );
}

// ─── Score Breakdown Panel ───────────────────────────────────────────

function ScoreBreakdown({ entity, onClose }) {
  if (!entity) return null;
  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center pt-16 bg-black/30" onClick={onClose}>
      <div className="bg-white rounded-lg shadow-xl w-full max-w-2xl max-h-[80vh] overflow-y-auto" onClick={e => e.stopPropagation()}>
        <div className="sticky top-0 bg-white border-b border-gray-200 px-6 py-4 flex items-center justify-between">
          <div>
            <h3 className="text-lg font-semibold text-gray-900">{entity.displayName}</h3>
            <p className="text-sm text-gray-500 mt-0.5">
              {entity.entityType === 'user' ? (entity.userPrincipalName || entity.department || '') : (entity.description || '')}
            </p>
          </div>
          <div className="flex items-center gap-3">
            <div className="text-right">
              <div className="text-2xl font-bold" style={{ color: entity.riskTier?.color }}>{entity.finalScore}</div>
              <TierBadge tier={entity.riskTier} />
            </div>
            <button onClick={onClose} className="text-gray-400 hover:text-gray-600 p-1">
              <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" /></svg>
            </button>
          </div>
        </div>

        <div className="px-6 py-4 space-y-5">
          {/* Score Layers */}
          <div>
            <h4 className="text-sm font-semibold text-gray-700 mb-2">Score Layers</h4>
            <div className="grid grid-cols-2 gap-3">
              {[
                { label: 'Direct (Classifier Match)', score: entity.directScore, weight: '50%' },
                { label: 'Membership Analysis', score: entity.membershipScore, weight: '20%' },
                { label: 'Structural/Hygiene', score: entity.structuralScore, weight: '10%' },
                { label: 'Risk Propagation', score: entity.propagatedScore, weight: '20%' },
              ].map(layer => (
                <div key={layer.label} className="bg-gray-50 rounded-lg p-3">
                  <div className="flex items-center justify-between mb-1">
                    <span className="text-xs text-gray-500">{layer.label}</span>
                    <span className="text-[10px] text-gray-400">{layer.weight}</span>
                  </div>
                  <ScoreBar score={layer.score} />
                </div>
              ))}
            </div>
          </div>

          {/* Classifier Matches */}
          {entity.classifierMatches?.length > 0 && (
            <div>
              <h4 className="text-sm font-semibold text-gray-700 mb-2">Classifier Matches</h4>
              <div className="space-y-2">
                {entity.classifierMatches.map((m, i) => (
                  <div key={i} className="bg-blue-50 border border-blue-100 rounded-lg p-3">
                    <div className="flex items-center justify-between">
                      <span className="text-sm font-medium text-blue-900">{m.classifierId}</span>
                      <span className="text-xs font-mono text-blue-700">+{m.score} pts</span>
                    </div>
                    <p className="text-xs text-blue-700 mt-1">{m.rationale}</p>
                    <span className="text-[10px] text-blue-500 mt-1 inline-block">
                      Matched on: {m.matchedOn} | Category: {m.category}
                    </span>
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* Membership Signals */}
          {entity.membershipSignals?.length > 0 && (
            <div>
              <h4 className="text-sm font-semibold text-gray-700 mb-2">Membership Signals</h4>
              <div className="space-y-1">
                {entity.membershipSignals.map((s, i) => (
                  <div key={i} className="flex items-center justify-between py-1.5 px-3 bg-purple-50 rounded text-sm">
                    <span className="text-purple-800">{s.detail}</span>
                    <span className="text-xs font-mono text-purple-600">+{s.points} pts</span>
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* Structural Signals */}
          {entity.structuralSignals?.length > 0 && (
            <div>
              <h4 className="text-sm font-semibold text-gray-700 mb-2">Structural Signals</h4>
              <div className="space-y-1">
                {entity.structuralSignals.map((s, i) => (
                  <div key={i} className="flex items-center justify-between py-1.5 px-3 bg-amber-50 rounded text-sm">
                    <span className="text-amber-800">{s.detail}</span>
                    <span className="text-xs font-mono text-amber-600">+{s.points} pts</span>
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* Propagation Source */}
          {entity.propagationSource && (
            <div>
              <h4 className="text-sm font-semibold text-gray-700 mb-2">Risk Propagation</h4>
              <div className="bg-rose-50 border border-rose-100 rounded-lg p-3 text-sm">
                <span className="text-rose-800">
                  Inherited from {entity.propagationSource.type} with score {entity.propagationSource.score}
                </span>
                <span className="text-xs text-rose-600 block mt-0.5">
                  Propagated score: +{entity.propagatedScore} pts
                </span>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

// ─── Distribution Chart (simple bar chart) ───────────────────────────

function DistributionChart({ label, byTier, total }) {
  const tiers = ['Critical', 'High', 'Medium', 'Low', 'Minimal', 'None'];
  return (
    <div className="bg-white rounded-lg border border-gray-200 p-4">
      <h3 className="text-sm font-semibold text-gray-700 mb-1">{label}</h3>
      <p className="text-xs text-gray-400 mb-3">{total} total</p>
      <div className="space-y-2">
        {tiers.map(tier => {
          const count = byTier[tier] || 0;
          if (count === 0) return null;
          const pct = total > 0 ? (count / total) * 100 : 0;
          const s = TIER_STYLES[tier];
          return (
            <div key={tier} className="flex items-center gap-2">
              <span className={`w-16 text-xs font-medium ${s.text}`}>{tier}</span>
              <div className="flex-1 h-5 bg-gray-50 rounded overflow-hidden">
                <div className={`h-full ${s.dot} rounded`} style={{ width: `${pct}%` }} />
              </div>
              <span className="w-8 text-xs text-gray-500 text-right">{count}</span>
            </div>
          );
        })}
      </div>
    </div>
  );
}

// ─── Entity Table ────────────────────────────────────────────────────

function EntityTable({ entities, entityType, search, tierFilter, onSelect, onOpenDetail }) {
  const filtered = useMemo(() => {
    let list = entities || [];
    if (tierFilter) list = list.filter(e => e.riskTier?.label === tierFilter);
    if (search) {
      const q = search.toLowerCase();
      list = list.filter(e =>
        e.displayName?.toLowerCase().includes(q) ||
        e.userPrincipalName?.toLowerCase().includes(q) ||
        e.description?.toLowerCase().includes(q) ||
        e.department?.toLowerCase().includes(q)
      );
    }
    return list;
  }, [entities, tierFilter, search]);

  const [page, setPage] = useState(0);
  const PAGE_SIZE = 25;
  const totalPages = Math.ceil(filtered.length / PAGE_SIZE);
  const paged = filtered.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE);

  // Reset page when filters change
  useEffect(() => setPage(0), [tierFilter, search]);

  return (
    <div>
      <div className="overflow-x-auto">
        <table className="min-w-full text-sm">
          <thead>
            <tr className="border-b border-gray-200">
              <th className="text-left py-2 px-3 text-xs font-medium text-gray-500 uppercase">Name</th>
              {entityType === 'user' && <th className="text-left py-2 px-3 text-xs font-medium text-gray-500 uppercase">Department</th>}
              {entityType === 'user' && <th className="text-left py-2 px-3 text-xs font-medium text-gray-500 uppercase">Title</th>}
              <th className="text-left py-2 px-3 text-xs font-medium text-gray-500 uppercase w-20">Score</th>
              <th className="text-left py-2 px-3 text-xs font-medium text-gray-500 uppercase w-24">Tier</th>
              <th className="text-left py-2 px-3 text-xs font-medium text-gray-500 uppercase w-16">Direct</th>
              <th className="text-left py-2 px-3 text-xs font-medium text-gray-500 uppercase w-16">Memb.</th>
              <th className="text-left py-2 px-3 text-xs font-medium text-gray-500 uppercase w-16">Struct.</th>
              <th className="text-left py-2 px-3 text-xs font-medium text-gray-500 uppercase w-16">Prop.</th>
              <th className="text-left py-2 px-3 text-xs font-medium text-gray-500 uppercase w-20">Matches</th>
            </tr>
          </thead>
          <tbody>
            {paged.map(entity => (
              <tr
                key={entity.entityId}
                className="border-b border-gray-100 hover:bg-gray-50 cursor-pointer"
                onClick={() => onSelect(entity)}
              >
                <td className="py-2 px-3">
                  <button
                    className="text-blue-600 hover:underline text-left font-medium"
                    onClick={e => {
                      e.stopPropagation();
                      if (onOpenDetail) onOpenDetail(entityType, entity.entityId, entity.displayName);
                    }}
                  >
                    {entity.displayName}
                  </button>
                  {entityType === 'group' && entity.description && (
                    <p className="text-xs text-gray-400 truncate max-w-xs">{entity.description}</p>
                  )}
                </td>
                {entityType === 'user' && <td className="py-2 px-3 text-gray-600">{entity.department || '\u2014'}</td>}
                {entityType === 'user' && <td className="py-2 px-3 text-gray-600">{entity.jobTitle || '\u2014'}</td>}
                <td className="py-2 px-3"><ScoreBar score={entity.finalScore} /></td>
                <td className="py-2 px-3"><TierBadge tier={entity.riskTier} /></td>
                <td className="py-2 px-3 text-xs font-mono text-gray-500">{entity.directScore}</td>
                <td className="py-2 px-3 text-xs font-mono text-gray-500">{entity.membershipScore}</td>
                <td className="py-2 px-3 text-xs font-mono text-gray-500">{entity.structuralScore}</td>
                <td className="py-2 px-3 text-xs font-mono text-gray-500">{entity.propagatedScore}</td>
                <td className="py-2 px-3 text-xs text-gray-500">{entity.classifierMatches?.length || 0} match{entity.classifierMatches?.length !== 1 ? 'es' : ''}</td>
              </tr>
            ))}
            {paged.length === 0 && (
              <tr><td colSpan={entityType === 'user' ? 10 : 8} className="py-8 text-center text-gray-400">No entities match the current filters</td></tr>
            )}
          </tbody>
        </table>
      </div>

      {/* Pagination */}
      {totalPages > 1 && (
        <div className="flex items-center justify-between mt-3 px-3">
          <span className="text-xs text-gray-500">
            Showing {page * PAGE_SIZE + 1}–{Math.min((page + 1) * PAGE_SIZE, filtered.length)} of {filtered.length}
          </span>
          <div className="flex gap-1">
            <button
              onClick={() => setPage(p => Math.max(0, p - 1))}
              disabled={page === 0}
              className="px-2 py-1 text-xs rounded border border-gray-200 disabled:opacity-30 hover:bg-gray-50"
            >
              Prev
            </button>
            <button
              onClick={() => setPage(p => Math.min(totalPages - 1, p + 1))}
              disabled={page >= totalPages - 1}
              className="px-2 py-1 text-xs rounded border border-gray-200 disabled:opacity-30 hover:bg-gray-50"
            >
              Next
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

// ─── Main Risk Scoring Page ──────────────────────────────────────────

export default function RiskScoringPage({ onOpenDetail }) {
  const { authFetch } = useAuth();
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [view, setView] = useState('groups'); // 'groups' | 'users'
  const [tierFilter, setTierFilter] = useState('');
  const [search, setSearch] = useState('');
  const [selectedEntity, setSelectedEntity] = useState(null);

  const fetchScores = useCallback(async (force = false) => {
    try {
      setLoading(true);
      setError(null);
      const url = force ? '/api/risk-scores?force=true' : '/api/risk-scores';
      const res = await authFetch(url);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const json = await res.json();
      setData(json);
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }, [authFetch]);

  useEffect(() => { fetchScores(); }, [fetchScores]);

  if (loading && !data) {
    return (
      <div className="flex items-center justify-center h-64">
        <div className="text-gray-500">Running risk scoring engine...</div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="max-w-4xl mx-auto">
        <div className="bg-red-50 border border-red-200 rounded-lg p-4">
          <h3 className="text-red-800 font-semibold">Scoring Error</h3>
          <p className="text-red-600 text-sm mt-1">{error}</p>
          <button onClick={() => fetchScores(true)} className="mt-3 text-sm text-red-700 underline">Retry</button>
        </div>
      </div>
    );
  }

  const summary = data?.summary;
  const tiers = ['Critical', 'High', 'Medium', 'Low', 'Minimal', 'None'];

  return (
    <div className="max-w-7xl mx-auto space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-lg font-semibold text-gray-900">Identity Risk Scores</h2>
          <p className="text-sm text-gray-500 mt-0.5">
            Heuristic risk scoring based on classifier matching, membership analysis, and structural signals
          </p>
        </div>
        <div className="flex items-center gap-3">
          {data?.cachedAt && (
            <span className="text-xs text-gray-400">
              Scored: {new Date(data.cachedAt).toLocaleTimeString()}
            </span>
          )}
          <button
            onClick={() => fetchScores(true)}
            disabled={loading}
            className="px-3 py-1.5 text-sm font-medium text-blue-700 bg-blue-50 rounded-lg border border-blue-200 hover:bg-blue-100 disabled:opacity-50"
          >
            {loading ? 'Scoring...' : 'Re-score'}
          </button>
        </div>
      </div>

      {/* Summary Cards */}
      {summary && (
        <div className="grid grid-cols-2 gap-4">
          <DistributionChart label="Groups" byTier={summary.groupsByTier} total={summary.totalGroups} />
          <DistributionChart label="Users" byTier={summary.usersByTier} total={summary.totalUsers} />
        </div>
      )}

      {/* Top Risks Overview */}
      {summary && (
        <div className="grid grid-cols-2 gap-4">
          <div className="bg-white rounded-lg border border-gray-200 p-4">
            <h3 className="text-sm font-semibold text-gray-700 mb-3">Top Risk Groups</h3>
            <div className="space-y-2">
              {(summary.topGroups || []).slice(0, 5).map(g => (
                <div key={g.entityId} className="flex items-center justify-between">
                  <span className="text-sm text-gray-800 truncate max-w-[60%]">{g.displayName}</span>
                  <div className="flex items-center gap-2">
                    <ScoreBar score={g.finalScore} />
                    <TierBadge tier={g.riskTier} />
                  </div>
                </div>
              ))}
            </div>
          </div>
          <div className="bg-white rounded-lg border border-gray-200 p-4">
            <h3 className="text-sm font-semibold text-gray-700 mb-3">Top Risk Users</h3>
            <div className="space-y-2">
              {(summary.topUsers || []).slice(0, 5).map(u => (
                <div key={u.entityId} className="flex items-center justify-between">
                  <span className="text-sm text-gray-800 truncate max-w-[60%]">{u.displayName}</span>
                  <div className="flex items-center gap-2">
                    <ScoreBar score={u.finalScore} />
                    <TierBadge tier={u.riskTier} />
                  </div>
                </div>
              ))}
            </div>
          </div>
        </div>
      )}

      {/* Entity Tables */}
      <div className="bg-white rounded-lg border border-gray-200">
        {/* Toolbar */}
        <div className="border-b border-gray-200 px-4 py-3 flex items-center justify-between gap-4">
          <div className="flex items-center gap-2">
            <button
              onClick={() => setView('groups')}
              className={`px-3 py-1.5 text-sm font-medium rounded-lg transition-colors ${
                view === 'groups' ? 'bg-gray-900 text-white' : 'text-gray-600 hover:bg-gray-100'
              }`}
            >
              Groups ({data?.groups?.length || 0})
            </button>
            <button
              onClick={() => setView('users')}
              className={`px-3 py-1.5 text-sm font-medium rounded-lg transition-colors ${
                view === 'users' ? 'bg-gray-900 text-white' : 'text-gray-600 hover:bg-gray-100'
              }`}
            >
              Users ({data?.users?.length || 0})
            </button>
          </div>

          <div className="flex items-center gap-3">
            {/* Tier Filter */}
            <select
              value={tierFilter}
              onChange={e => setTierFilter(e.target.value)}
              className="text-sm border border-gray-200 rounded-lg px-2 py-1.5 text-gray-700"
            >
              <option value="">All tiers</option>
              {tiers.map(t => (
                <option key={t} value={t}>{t}</option>
              ))}
            </select>

            {/* Search */}
            <input
              type="text"
              placeholder={`Search ${view}...`}
              value={search}
              onChange={e => setSearch(e.target.value)}
              className="text-sm border border-gray-200 rounded-lg px-3 py-1.5 w-52 placeholder-gray-400"
            />
          </div>
        </div>

        {/* Table */}
        <EntityTable
          entities={view === 'groups' ? data?.groups : data?.users}
          entityType={view === 'groups' ? 'group' : 'user'}
          search={search}
          tierFilter={tierFilter}
          onSelect={setSelectedEntity}
          onOpenDetail={onOpenDetail}
        />
      </div>

      {/* Score Breakdown Modal */}
      {selectedEntity && (
        <ScoreBreakdown entity={selectedEntity} onClose={() => setSelectedEntity(null)} />
      )}
    </div>
  );
}
