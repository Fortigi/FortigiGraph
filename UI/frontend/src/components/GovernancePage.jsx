import { useState, useEffect, useCallback } from 'react';
import { useAuth } from '../auth/AuthGate';

function formatDate(val) {
  if (!val) return '';
  const d = new Date(val);
  if (isNaN(d)) return String(val);
  return d.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
}

function formatNum(n) {
  if (n == null) return '0';
  return Number(n).toLocaleString();
}

// ─── Stat card ─────────────────────────────────────────────
function StatCard({ label, value, sub, color = 'gray', onClick }) {
  const colorMap = {
    gray: 'bg-gray-50 border-gray-200',
    blue: 'bg-blue-50 border-blue-200',
    green: 'bg-green-50 border-green-200',
    red: 'bg-red-50 border-red-200',
    yellow: 'bg-yellow-50 border-yellow-200',
    indigo: 'bg-indigo-50 border-indigo-200',
  };
  const textMap = {
    gray: 'text-gray-900',
    blue: 'text-blue-900',
    green: 'text-green-900',
    red: 'text-red-900',
    yellow: 'text-yellow-900',
    indigo: 'text-indigo-900',
  };
  const clickable = !!onClick;
  return (
    <div
      className={`rounded-lg border p-4 ${colorMap[color] || colorMap.gray} ${clickable ? 'cursor-pointer hover:ring-2 hover:ring-offset-1 hover:ring-blue-300 transition-shadow' : ''}`}
      onClick={onClick}
      role={clickable ? 'button' : undefined}
      tabIndex={clickable ? 0 : undefined}
      onKeyDown={clickable ? (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onClick(); } } : undefined}
    >
      <div className="text-xs font-medium text-gray-500 uppercase tracking-wide">{label}</div>
      <div className={`text-2xl font-bold mt-1 ${textMap[color] || textMap.gray}`}>{value}</div>
      {sub && <div className="text-xs text-gray-500 mt-1">{sub}</div>}
      {clickable && <div className="text-[10px] text-gray-400 mt-1">Click to view details</div>}
    </div>
  );
}

// ─── Collapsible section ───────────────────────────────────
function CollapsibleSection({ title, count, children, open: controlledOpen, onToggle }) {
  const [internalOpen, setInternalOpen] = useState(false);
  const isOpen = controlledOpen !== undefined ? controlledOpen : internalOpen;
  const handleToggle = onToggle || (() => setInternalOpen(o => !o));
  return (
    <div className="bg-white border border-gray-200 rounded-lg mt-6">
      <button
        onClick={handleToggle}
        className="flex items-center gap-2 text-sm font-semibold text-gray-700 p-5 pb-4 w-full text-left hover:text-gray-900"
      >
        <span className="text-xs">{isOpen ? '\u25BC' : '\u25B6'}</span>
        {title}
        {count != null && <span className="text-xs font-normal text-gray-400">({count})</span>}
      </button>
      {isOpen && <div className="px-5 pb-5">{children}</div>}
    </div>
  );
}

// ─── Category badge ────────────────────────────────────────
function CategoryBadge({ name, color }) {
  if (!name) return null;
  return (
    <span
      className="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-xs font-medium"
      style={{ backgroundColor: color ? `${color}20` : '#f3f4f6', color: color || '#6b7280', border: `1px solid ${color || '#d1d5db'}40` }}
    >
      {color && <span className="w-2 h-2 rounded-full inline-block flex-shrink-0" style={{ backgroundColor: color }} />}
      {name}
    </span>
  );
}

// ═══════════════════════════════════════════════════════════
// Main component
// ═══════════════════════════════════════════════════════════
export default function GovernancePage() {
  const { authFetch } = useAuth();
  const [summary, setSummary] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  // Categories for filtering
  const [categories, setCategories] = useState(null);

  // Review compliance drill-down
  const [complianceDrilldown, setComplianceDrilldown] = useState(null); // { filter, category, data, loading }
  const [complianceDrilldownOpen, setComplianceDrilldownOpen] = useState(false);
  const [selectedCategory, setSelectedCategory] = useState(''); // '' = all

  // Load summary + categories in parallel
  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    Promise.all([
      authFetch('/api/governance/summary').then(r => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json(); }),
      authFetch('/api/governance/categories').then(r => r.ok ? r.json() : []).catch(() => []),
    ])
      .then(([summaryData, cats]) => {
        if (!cancelled) {
          setSummary(summaryData);
          setCategories(cats);
        }
      })
      .catch(e => { if (!cancelled) setError(e.message); })
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [authFetch]);

  // Review compliance drill-down loader
  const loadComplianceDrilldown = useCallback((filter, category) => {
    setComplianceDrilldown({ filter, category, data: null, loading: true });
    setComplianceDrilldownOpen(true);
    let url = `/api/governance/review-compliance?filter=${encodeURIComponent(filter)}`;
    if (category) url += `&category=${encodeURIComponent(category)}`;
    authFetch(url)
      .then(r => r.json())
      .then(data => setComplianceDrilldown(prev => ({ ...prev, data, loading: false })))
      .catch(() => setComplianceDrilldown(prev => ({ ...prev, data: [], loading: false })));
  }, [authFetch]);

  // Reload drilldown when category filter changes
  const handleCategoryChange = useCallback((newCategory) => {
    setSelectedCategory(newCategory);
    if (complianceDrilldown?.filter) {
      loadComplianceDrilldown(complianceDrilldown.filter, newCategory);
    }
  }, [complianceDrilldown?.filter, loadComplianceDrilldown]);

  // Tile click handler — uses current category filter
  const handleTileClick = useCallback((filter) => {
    loadComplianceDrilldown(filter, selectedCategory);
  }, [loadComplianceDrilldown, selectedCategory]);

  if (loading) {
    return <div className="flex items-center justify-center h-64 text-gray-500">Loading access review data...</div>;
  }
  if (error) {
    return (
      <div className="bg-red-50 border border-red-200 rounded-lg p-6">
        <h2 className="text-red-800 font-semibold">Error loading access review data</h2>
        <p className="text-red-600 mt-1 text-sm">{error}</p>
      </div>
    );
  }
  if (!summary) return null;

  const { reviews } = summary;

  const COMPLIANCE_FILTER_LABELS = {
    'overdue': 'Overdue Reviews',
    'not-reviewed': 'Not Reviewed',
    'on-time': 'On-Time Reviews',
  };

  return (
    <div className="max-w-6xl mx-auto">
      <div className="mb-6">
        <h2 className="text-xl font-semibold text-gray-900">Access Review Compliance</h2>
        <p className="text-sm text-gray-500 mt-1">Periodic access review compliance overview</p>
      </div>

      {/* ─── Category Filter ───────────────────────────────── */}
      {categories && categories.length > 0 && (
        <div className="mb-4 flex items-center gap-2">
          <label className="text-xs font-medium text-gray-500 uppercase tracking-wide">Category:</label>
          <select
            value={selectedCategory}
            onChange={e => handleCategoryChange(e.target.value)}
            className="text-sm border border-gray-300 rounded-md px-2 py-1 bg-white text-gray-700 focus:outline-none focus:ring-2 focus:ring-blue-300"
          >
            <option value="">All Categories</option>
            {categories.map(cat => (
              <option key={cat.id} value={cat.id}>{cat.name}</option>
            ))}
            <option value="uncategorized">Uncategorized</option>
          </select>
        </div>
      )}

      {/* ─── Compliance Stat Cards ──────────────────────────── */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4 mb-4">
        <StatCard label="Total Decisions" value={formatNum(reviews.totalDecisions)} color="gray" />
        <StatCard
          label="On Time"
          value={formatNum(reviews.onTime)}
          sub={`${reviews.onTimePercent}% of decisions`}
          color="green"
          onClick={() => handleTileClick('on-time')}
        />
        <StatCard
          label="Overdue"
          value={formatNum(reviews.overdue)}
          sub={reviews.totalDecisions > 0 ? `${((reviews.overdue / reviews.totalDecisions) * 100).toFixed(1)}%` : '0%'}
          color={reviews.overdue > 0 ? 'red' : 'green'}
          onClick={reviews.overdue > 0 ? () => handleTileClick('overdue') : undefined}
        />
        <StatCard
          label="Not Reviewed"
          value={formatNum(reviews.notReviewed)}
          sub={reviews.totalDecisions > 0 ? `${((reviews.notReviewed / reviews.totalDecisions) * 100).toFixed(1)}%` : '0%'}
          color={reviews.notReviewed > 0 ? 'yellow' : 'green'}
          onClick={reviews.notReviewed > 0 ? () => handleTileClick('not-reviewed') : undefined}
        />
      </div>

      {/* Compliance bar */}
      {reviews.totalDecisions > 0 && (
        <div>
          <div className="flex rounded-full h-4 overflow-hidden bg-gray-100">
            <div className="bg-green-500" style={{ width: `${reviews.onTimePercent}%` }} title={`${reviews.onTime} on time`} />
            <div className="bg-red-400" style={{ width: `${(reviews.overdue / reviews.totalDecisions * 100)}%` }} title={`${reviews.overdue} overdue`} />
            <div className="bg-gray-300" style={{ width: `${(reviews.notReviewed / reviews.totalDecisions * 100)}%` }} title={`${reviews.notReviewed} not reviewed`} />
          </div>
          <div className="flex gap-4 text-xs text-gray-500 mt-1">
            <span className="flex items-center gap-1"><span className="w-2 h-2 rounded-full bg-green-500 inline-block" />On Time</span>
            <span className="flex items-center gap-1"><span className="w-2 h-2 rounded-full bg-red-400 inline-block" />Overdue</span>
            <span className="flex items-center gap-1"><span className="w-2 h-2 rounded-full bg-gray-300 inline-block" />Not Reviewed</span>
          </div>
        </div>
      )}

      {/* ─── Review Compliance Drill-down ─────────────────── */}
      {complianceDrilldown && (
        <CollapsibleSection
          title={COMPLIANCE_FILTER_LABELS[complianceDrilldown.filter] || 'Review Compliance Details'}
          count={complianceDrilldown.data?.length}
          open={complianceDrilldownOpen}
          onToggle={() => setComplianceDrilldownOpen(o => !o)}
        >
          <ComplianceDrilldownSection data={complianceDrilldown} />
        </CollapsibleSection>
      )}
    </div>
  );
}

// ─── Compliance drill-down table ────────────────────────────

function ComplianceDrilldownSection({ data: drilldown }) {
  if (drilldown.loading) return <div className="text-sm text-gray-400 animate-pulse">Loading...</div>;
  if (!drilldown.data || drilldown.data.length === 0) return <p className="text-sm text-gray-400 italic">No data</p>;

  const rows = drilldown.data;

  return (
    <div className="overflow-x-auto">
      <table className="w-full text-sm">
        <thead>
          <tr className="text-left text-gray-500 bg-gray-50 border-b border-gray-200">
            <th className="px-3 py-2 font-medium">Access Package</th>
            <th className="px-3 py-2 font-medium">Catalog</th>
            <th className="px-3 py-2 font-medium">Category</th>
            <th className="px-3 py-2 font-medium text-right">Total</th>
            <th className="px-3 py-2 font-medium text-right">On Time</th>
            <th className="px-3 py-2 font-medium text-right">Overdue</th>
            <th className="px-3 py-2 font-medium text-right">Not Reviewed</th>
            <th className="px-3 py-2 font-medium">Last Review</th>
          </tr>
        </thead>
        <tbody>
          {rows.map(r => (
            <tr key={r.accessPackageId} className={`border-b border-gray-50 ${r.notReviewed > 0 || r.overdue > 0 ? 'hover:bg-yellow-50' : 'hover:bg-gray-50'}`}>
              <td className="px-3 py-2 text-gray-900 font-medium">{r.accessPackageName}</td>
              <td className="px-3 py-2 text-gray-500 text-xs">{r.catalogName || '\u2014'}</td>
              <td className="px-3 py-2">
                <CategoryBadge name={r.categoryName} color={r.categoryColor} />
                {!r.categoryName && <span className="text-gray-400 text-xs">{'\u2014'}</span>}
              </td>
              <td className="px-3 py-2 text-right text-gray-700">{r.totalDecisions}</td>
              <td className="px-3 py-2 text-right text-green-700">{r.onTime}</td>
              <td className="px-3 py-2 text-right">
                <span className={r.overdue > 0 ? 'text-red-600 font-medium' : 'text-gray-400'}>{r.overdue}</span>
              </td>
              <td className="px-3 py-2 text-right">
                <span className={r.notReviewed > 0 ? 'text-yellow-700 font-medium' : 'text-gray-400'}>{r.notReviewed}</span>
              </td>
              <td className="px-3 py-2 text-gray-500 text-xs whitespace-nowrap">{formatDate(r.lastReviewDate)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
