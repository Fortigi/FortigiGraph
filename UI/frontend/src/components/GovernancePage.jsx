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
function StatCard({ label, value, sub, color = 'gray' }) {
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
  return (
    <div className={`rounded-lg border p-4 ${colorMap[color] || colorMap.gray}`}>
      <div className="text-xs font-medium text-gray-500 uppercase tracking-wide">{label}</div>
      <div className={`text-2xl font-bold mt-1 ${textMap[color] || textMap.gray}`}>{value}</div>
      {sub && <div className="text-xs text-gray-500 mt-1">{sub}</div>}
    </div>
  );
}

// ─── Horizontal bar ────────────────────────────────────────
function Bar({ label, value, max, color = 'bg-blue-500' }) {
  const pct = max > 0 ? (value / max) * 100 : 0;
  return (
    <div className="flex items-center gap-3 text-sm">
      <span className="w-32 text-right text-gray-600 text-xs whitespace-nowrap">{label}</span>
      <div className="flex-1 bg-gray-100 rounded-full h-5 overflow-hidden">
        <div className={`h-full rounded-full ${color} transition-all`} style={{ width: `${Math.max(pct, 1)}%` }} />
      </div>
      <span className="w-10 text-right text-gray-700 font-medium text-xs">{formatNum(value)}</span>
    </div>
  );
}

// ─── Section wrapper ───────────────────────────────────────
function Section({ title, children }) {
  return (
    <div className="bg-white border border-gray-200 rounded-lg p-5 mt-6">
      <h3 className="text-sm font-semibold text-gray-700 mb-4">{title}</h3>
      {children}
    </div>
  );
}

// ─── Collapsible section ───────────────────────────────────
function CollapsibleSection({ title, count, children, defaultOpen = false }) {
  const [open, setOpen] = useState(defaultOpen);
  return (
    <div className="bg-white border border-gray-200 rounded-lg mt-6">
      <button
        onClick={() => setOpen(o => !o)}
        className="flex items-center gap-2 text-sm font-semibold text-gray-700 p-5 pb-4 w-full text-left hover:text-gray-900"
      >
        <span className="text-xs">{open ? '\u25BC' : '\u25B6'}</span>
        {title}
        {count != null && <span className="text-xs font-normal text-gray-400">({count})</span>}
      </button>
      {open && <div className="px-5 pb-5">{children}</div>}
    </div>
  );
}

// ═══════════════════════════════════════════════════════════
// Main component
// ═══════════════════════════════════════════════════════════
export default function GovernancePage() {
  const { authFetch } = useAuth();
  const [summary, setSummary] = useState(null);
  const [responseTimes, setResponseTimes] = useState(null);
  const [perPackage, setPerPackage] = useState(null);
  const [reviewStatus, setReviewStatus] = useState(null);
  const [pendingRequests, setPendingRequests] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  // Load summary (always) + lazy data
  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    authFetch('/api/governance/summary')
      .then(r => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json(); })
      .then(d => { if (!cancelled) setSummary(d); })
      .catch(e => { if (!cancelled) setError(e.message); })
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [authFetch]);

  // Lazy loaders
  const loadResponseTimes = useCallback(() => {
    if (responseTimes) return;
    authFetch('/api/governance/response-times')
      .then(r => r.json()).then(setResponseTimes).catch(() => setResponseTimes({ approved: [], denied: [] }));
  }, [authFetch, responseTimes]);

  const loadPerPackage = useCallback(() => {
    if (perPackage) return;
    authFetch('/api/governance/per-package')
      .then(r => r.json()).then(setPerPackage).catch(() => setPerPackage([]));
  }, [authFetch, perPackage]);

  const loadReviewStatus = useCallback(() => {
    if (reviewStatus) return;
    authFetch('/api/governance/review-status')
      .then(r => r.json()).then(setReviewStatus).catch(() => setReviewStatus([]));
  }, [authFetch, reviewStatus]);

  const loadPendingRequests = useCallback(() => {
    if (pendingRequests) return;
    authFetch('/api/governance/pending-requests')
      .then(r => r.json()).then(setPendingRequests).catch(() => setPendingRequests([]));
  }, [authFetch, pendingRequests]);

  if (loading) {
    return <div className="flex items-center justify-center h-64 text-gray-500">Loading governance data...</div>;
  }
  if (error) {
    return (
      <div className="bg-red-50 border border-red-200 rounded-lg p-6">
        <h2 className="text-red-800 font-semibold">Error loading governance data</h2>
        <p className="text-red-600 mt-1 text-sm">{error}</p>
      </div>
    );
  }
  if (!summary) return null;

  const { requests, reviews, assignmentMethods } = summary;
  const totalAssignments = summary.managedAssignments + summary.unmanagedAssignments;

  return (
    <div className="max-w-6xl mx-auto">
      <div className="mb-6">
        <h2 className="text-xl font-semibold text-gray-900">Governance Dashboard</h2>
        <p className="text-sm text-gray-500 mt-1">KPI overview of the roles model and access governance</p>
      </div>

      {/* ─── Top-level stats ───────────────────────────────── */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <StatCard label="Total Users" value={formatNum(summary.totalUsers)} color="gray" />
        <StatCard label="Total Groups" value={formatNum(summary.totalGroups)} color="gray" />
        <StatCard label="Access Packages" value={formatNum(summary.totalAccessPackages)} color="indigo" />
        <StatCard
          label="Managed (SOLL)"
          value={`${summary.managedPercent}%`}
          sub={`${formatNum(summary.managedAssignments)} of ${formatNum(totalAssignments)} assignments`}
          color={summary.managedPercent >= 70 ? 'green' : summary.managedPercent >= 40 ? 'yellow' : 'red'}
        />
      </div>

      {/* ─── IST vs SOLL breakdown ─────────────────────────── */}
      <Section title="IT-Role Assignments: Managed (SOLL) vs Unmanaged (IST)">
        <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
          <div>
            <div className="flex items-center justify-between mb-2">
              <span className="text-sm text-gray-600">Managed via Business Role (SOLL)</span>
              <span className="text-sm font-semibold text-green-700">{formatNum(summary.managedAssignments)}</span>
            </div>
            <div className="w-full bg-gray-100 rounded-full h-6 overflow-hidden">
              <div
                className="h-full bg-green-500 rounded-full transition-all flex items-center justify-center text-xs text-white font-medium"
                style={{ width: `${summary.managedPercent}%`, minWidth: summary.managedPercent > 0 ? '2rem' : 0 }}
              >
                {summary.managedPercent > 10 && `${summary.managedPercent}%`}
              </div>
            </div>
          </div>
          <div>
            <div className="flex items-center justify-between mb-2">
              <span className="text-sm text-gray-600">Direct / Unmanaged (IST)</span>
              <span className="text-sm font-semibold text-red-700">{formatNum(summary.unmanagedAssignments)}</span>
            </div>
            <div className="w-full bg-gray-100 rounded-full h-6 overflow-hidden">
              <div
                className="h-full bg-red-400 rounded-full transition-all flex items-center justify-center text-xs text-white font-medium"
                style={{ width: `${100 - summary.managedPercent}%`, minWidth: (100 - summary.managedPercent) > 0 ? '2rem' : 0 }}
              >
                {(100 - summary.managedPercent) > 10 && `${(100 - summary.managedPercent).toFixed(1)}%`}
              </div>
            </div>
          </div>
        </div>

        {/* Assignment method breakdown */}
        {Object.keys(assignmentMethods).length > 0 && (
          <div className="mt-6 pt-4 border-t border-gray-100">
            <h4 className="text-xs font-semibold text-gray-500 uppercase tracking-wide mb-3">Assignment Method Breakdown (SOLL)</h4>
            <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
              {[
                { key: 'Automatic (Policy Rule)', label: 'Automatic', color: 'green' },
                { key: 'User Requested', label: 'Requested', color: 'blue' },
                { key: 'Admin Assigned', label: 'Admin', color: 'yellow' },
              ].map(({ key, label, color }) => (
                <StatCard
                  key={key}
                  label={label}
                  value={formatNum(assignmentMethods[key] || 0)}
                  color={color}
                />
              ))}
            </div>
          </div>
        )}
      </Section>

      {/* ─── Request Metrics ───────────────────────────────── */}
      <Section title="Role Request Metrics">
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4 mb-4">
          <StatCard label="Total Requests" value={formatNum(requests.total)} color="gray" />
          <StatCard
            label="Approval Rate"
            value={`${requests.approvalRatePercent}%`}
            sub={`${formatNum(requests.approved)} approved, ${formatNum(requests.denied)} denied`}
            color={requests.approvalRatePercent >= 80 ? 'green' : requests.approvalRatePercent >= 50 ? 'yellow' : 'red'}
          />
          <StatCard
            label="Avg Response Time"
            value={requests.avgResponseDays < 1 ? `${requests.avgResponseHours}h` : `${requests.avgResponseDays}d`}
            sub={requests.avgResponseDays >= 1 ? `${requests.avgResponseHours} hours` : ''}
            color={requests.avgResponseDays <= 1 ? 'green' : requests.avgResponseDays <= 3 ? 'yellow' : 'red'}
          />
          <StatCard
            label="Pending Requests"
            value={formatNum(requests.pendingTotal)}
            sub={requests.pendingOverdue > 0 ? `${requests.pendingOverdue} overdue (>7 days)` : 'None overdue'}
            color={requests.pendingOverdue > 0 ? 'red' : requests.pendingTotal > 0 ? 'yellow' : 'green'}
          />
        </div>

        {/* Approved vs Denied visual */}
        {requests.total > 0 && (
          <div className="mt-2">
            <div className="flex rounded-full h-4 overflow-hidden bg-gray-100">
              <div
                className="bg-green-500 transition-all"
                style={{ width: `${requests.approvalRatePercent}%` }}
                title={`${requests.approved} approved`}
              />
              <div
                className="bg-red-400 transition-all"
                style={{ width: `${100 - requests.approvalRatePercent}%` }}
                title={`${requests.denied} denied`}
              />
            </div>
            <div className="flex justify-between text-xs text-gray-500 mt-1">
              <span>Approved ({requests.approvalRatePercent}%)</span>
              <span>Denied ({(100 - requests.approvalRatePercent).toFixed(1)}%)</span>
            </div>
          </div>
        )}
      </Section>

      {/* ─── Response Time Distribution ────────────────────── */}
      <CollapsibleSection title="Response Time Distribution" defaultOpen={false}>
        <ResponseTimesSection data={responseTimes} onLoad={loadResponseTimes} />
      </CollapsibleSection>

      {/* ─── Access Review Compliance ──────────────────────── */}
      <Section title="Periodic Access Review Compliance">
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4 mb-4">
          <StatCard label="Total Decisions" value={formatNum(reviews.totalDecisions)} color="gray" />
          <StatCard
            label="On Time"
            value={formatNum(reviews.onTime)}
            sub={`${reviews.onTimePercent}% of decisions`}
            color="green"
          />
          <StatCard
            label="Overdue"
            value={formatNum(reviews.overdue)}
            sub={reviews.totalDecisions > 0 ? `${((reviews.overdue / reviews.totalDecisions) * 100).toFixed(1)}%` : '0%'}
            color={reviews.overdue > 0 ? 'red' : 'green'}
          />
          <StatCard
            label="Not Reviewed"
            value={formatNum(reviews.notReviewed)}
            sub={reviews.totalDecisions > 0 ? `${((reviews.notReviewed / reviews.totalDecisions) * 100).toFixed(1)}%` : '0%'}
            color={reviews.notReviewed > 0 ? 'yellow' : 'green'}
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
      </Section>

      {/* ─── Per-Package Metrics ───────────────────────────── */}
      <CollapsibleSection title="Request Metrics per Access Package" count={perPackage?.length}>
        <PerPackageSection data={perPackage} onLoad={loadPerPackage} />
      </CollapsibleSection>

      {/* ─── Review Status per AP ──────────────────────────── */}
      <CollapsibleSection title="Last Review per Access Package" count={reviewStatus?.length}>
        <ReviewStatusSection data={reviewStatus} onLoad={loadReviewStatus} />
      </CollapsibleSection>

      {/* ─── Pending Requests Detail ──────────────────────── */}
      {requests.pendingTotal > 0 && (
        <CollapsibleSection title="Pending Requests" count={requests.pendingTotal}>
          <PendingRequestsSection data={pendingRequests} onLoad={loadPendingRequests} />
        </CollapsibleSection>
      )}
    </div>
  );
}

// ─── Lazy sub-sections ─────────────────────────────────────

function ResponseTimesSection({ data, onLoad }) {
  useEffect(() => { onLoad(); }, [onLoad]);
  if (!data) return <div className="text-sm text-gray-400 animate-pulse">Loading...</div>;

  const maxApproved = Math.max(...data.approved.map(b => b.count), 1);
  const maxDenied = Math.max(...data.denied.map(b => b.count), 1);
  const maxAll = Math.max(maxApproved, maxDenied);

  return (
    <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
      <div>
        <h4 className="text-xs font-semibold text-gray-500 uppercase tracking-wide mb-3">Approved Requests</h4>
        <div className="space-y-2">
          {data.approved.map(b => (
            <Bar key={b.bucket} label={b.bucket} value={b.count} max={maxAll} color="bg-green-500" />
          ))}
        </div>
      </div>
      <div>
        <h4 className="text-xs font-semibold text-gray-500 uppercase tracking-wide mb-3">Denied Requests</h4>
        <div className="space-y-2">
          {data.denied.map(b => (
            <Bar key={b.bucket} label={b.bucket} value={b.count} max={maxAll} color="bg-red-400" />
          ))}
        </div>
      </div>
    </div>
  );
}

function PerPackageSection({ data, onLoad }) {
  useEffect(() => { onLoad(); }, [onLoad]);
  if (!data) return <div className="text-sm text-gray-400 animate-pulse">Loading...</div>;
  if (data.length === 0) return <p className="text-sm text-gray-400 italic">No request data available</p>;

  return (
    <div className="overflow-x-auto">
      <table className="w-full text-sm">
        <thead>
          <tr className="text-left text-gray-500 bg-gray-50 border-b border-gray-200">
            <th className="px-3 py-2 font-medium">Access Package</th>
            <th className="px-3 py-2 font-medium">Catalog</th>
            <th className="px-3 py-2 font-medium text-right">Requests</th>
            <th className="px-3 py-2 font-medium text-right">Approved</th>
            <th className="px-3 py-2 font-medium text-right">Denied</th>
            <th className="px-3 py-2 font-medium text-right">Rate</th>
            <th className="px-3 py-2 font-medium text-right">Avg Time</th>
          </tr>
        </thead>
        <tbody>
          {data.map(r => (
            <tr key={r.accessPackageId} className="border-b border-gray-50 hover:bg-gray-50">
              <td className="px-3 py-2 text-gray-900 font-medium">{r.accessPackageName}</td>
              <td className="px-3 py-2 text-gray-500 text-xs">{r.catalogName}</td>
              <td className="px-3 py-2 text-right text-gray-700">{r.totalRequests}</td>
              <td className="px-3 py-2 text-right text-green-700">{r.approvedCount}</td>
              <td className="px-3 py-2 text-right text-red-600">{r.deniedCount}</td>
              <td className="px-3 py-2 text-right">
                <span className={`inline-block px-1.5 py-0.5 rounded text-xs font-medium ${
                  r.approvalRatePercent >= 80 ? 'bg-green-100 text-green-800' :
                  r.approvalRatePercent >= 50 ? 'bg-yellow-100 text-yellow-800' :
                  'bg-red-100 text-red-800'
                }`}>{r.approvalRatePercent}%</span>
              </td>
              <td className="px-3 py-2 text-right text-gray-500 text-xs">{r.avgResponseCategory}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function ReviewStatusSection({ data, onLoad }) {
  useEffect(() => { onLoad(); }, [onLoad]);
  if (!data) return <div className="text-sm text-gray-400 animate-pulse">Loading...</div>;
  if (data.length === 0) return <p className="text-sm text-gray-400 italic">No review data available</p>;

  return (
    <div className="overflow-x-auto">
      <table className="w-full text-sm">
        <thead>
          <tr className="text-left text-gray-500 bg-gray-50 border-b border-gray-200">
            <th className="px-3 py-2 font-medium">Access Package</th>
            <th className="px-3 py-2 font-medium">Catalog</th>
            <th className="px-3 py-2 font-medium">Last Reviewed By</th>
            <th className="px-3 py-2 font-medium">Date</th>
            <th className="px-3 py-2 font-medium">Decision</th>
            <th className="px-3 py-2 font-medium text-right">Days Ago</th>
          </tr>
        </thead>
        <tbody>
          {data.map(r => (
            <tr key={r.accessPackageId} className="border-b border-gray-50 hover:bg-gray-50">
              <td className="px-3 py-2 text-gray-900 font-medium">{r.accessPackageName}</td>
              <td className="px-3 py-2 text-gray-500 text-xs">{r.catalogName}</td>
              <td className="px-3 py-2 text-gray-600">{r.lastReviewedByName || '\u2014'}</td>
              <td className="px-3 py-2 text-gray-500 text-xs whitespace-nowrap">{formatDate(r.lastReviewDateTime)}</td>
              <td className="px-3 py-2">
                <span className={`inline-block px-1.5 py-0.5 rounded text-xs font-medium ${
                  r.lastReviewDecision === 'Approve' ? 'bg-green-100 text-green-800' :
                  r.lastReviewDecision === 'Deny' ? 'bg-red-100 text-red-800' :
                  'bg-gray-100 text-gray-600'
                }`}>{r.lastReviewDecision}</span>
              </td>
              <td className="px-3 py-2 text-right">
                <span className={`text-xs font-medium ${
                  r.daysSinceLastReview > 90 ? 'text-red-600' :
                  r.daysSinceLastReview > 30 ? 'text-yellow-600' :
                  'text-green-600'
                }`}>{r.daysSinceLastReview}d</span>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function PendingRequestsSection({ data, onLoad }) {
  useEffect(() => { onLoad(); }, [onLoad]);
  if (!data) return <div className="text-sm text-gray-400 animate-pulse">Loading...</div>;
  if (data.length === 0) return <p className="text-sm text-gray-400 italic">No pending requests</p>;

  return (
    <div className="overflow-x-auto">
      <table className="w-full text-sm">
        <thead>
          <tr className="text-left text-gray-500 bg-gray-50 border-b border-gray-200">
            <th className="px-3 py-2 font-medium">User</th>
            <th className="px-3 py-2 font-medium">Access Package</th>
            <th className="px-3 py-2 font-medium">Catalog</th>
            <th className="px-3 py-2 font-medium">State</th>
            <th className="px-3 py-2 font-medium text-right">Days Pending</th>
            <th className="px-3 py-2 font-medium">Status</th>
          </tr>
        </thead>
        <tbody>
          {data.map(r => (
            <tr key={r.requestId} className={`border-b border-gray-50 ${r.isOverdue ? 'bg-red-50' : 'hover:bg-gray-50'}`}>
              <td className="px-3 py-2">
                <div className="text-gray-900 font-medium">{r.userDisplayName}</div>
                <div className="text-xs text-gray-400">{r.userPrincipalName}</div>
              </td>
              <td className="px-3 py-2 text-gray-600">{r.accessPackageName}</td>
              <td className="px-3 py-2 text-gray-500 text-xs">{r.catalogName}</td>
              <td className="px-3 py-2">
                <span className="inline-block px-1.5 py-0.5 rounded text-xs font-medium bg-yellow-100 text-yellow-800">
                  {r.requestState}
                </span>
              </td>
              <td className="px-3 py-2 text-right">
                <span className={`text-xs font-medium ${r.isOverdue ? 'text-red-600' : 'text-gray-600'}`}>
                  {r.daysPending}d
                  {r.isOverdue ? ' (overdue)' : ''}
                </span>
              </td>
              <td className="px-3 py-2 text-gray-500 text-xs">{r.pendingTimeBucket}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
