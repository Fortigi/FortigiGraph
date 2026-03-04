import { useState, useEffect, useMemo, useCallback, useRef } from 'react';
import { useAuth } from '../auth/AuthGate';

// ─── Constants ───────────────────────────────────────────────────────────────

const TIER_STYLES = {
  Critical: { bg: 'bg-red-100',    text: 'text-red-800',    border: 'border-red-200',    dot: 'bg-red-500',    avatar: '#ef4444', box: '#fef2f2', boxBorder: '#fca5a5' },
  High:     { bg: 'bg-orange-100', text: 'text-orange-800', border: 'border-orange-200', dot: 'bg-orange-500', avatar: '#f97316', box: '#fff7ed', boxBorder: '#fdba74' },
  Medium:   { bg: 'bg-yellow-100', text: 'text-yellow-800', border: 'border-yellow-200', dot: 'bg-yellow-500', avatar: '#eab308', box: '#fefce8', boxBorder: '#fde047' },
  Low:      { bg: 'bg-blue-100',   text: 'text-blue-800',   border: 'border-blue-200',   dot: 'bg-blue-500',  avatar: '#3b82f6', box: '#eff6ff', boxBorder: '#93c5fd' },
  Minimal:  { bg: 'bg-gray-100',   text: 'text-gray-600',   border: 'border-gray-200',   dot: 'bg-gray-400',  avatar: '#9ca3af', box: '#f9fafb', boxBorder: '#d1d5db' },
  None:     { bg: 'bg-gray-50',    text: 'text-gray-400',   border: 'border-gray-100',   dot: 'bg-gray-300',  avatar: '#d1d5db', box: '#f3f4f6', boxBorder: '#e5e7eb' },
};

const TIER_ORDER = { Critical: 5, High: 4, Medium: 3, Low: 2, Minimal: 1, None: 0 };
const TIER_DISPLAY = ['Critical', 'High', 'Medium', 'Low', 'Minimal'];

// ─── Helpers ─────────────────────────────────────────────────────────────────

function computeDeptRisk(members) {
  const tierCounts = {};
  let scoreSum = 0;
  let scoreCount = 0;
  let maxSeverity = 0;
  let maxTier = 'None';

  for (const person of members) {
    const tier = person.riskTier || 'None';
    tierCounts[tier] = (tierCounts[tier] || 0) + 1;
    if (person.riskScore != null) {
      scoreSum += person.riskScore;
      scoreCount++;
    }
    const severity = TIER_ORDER[tier] || 0;
    if (severity > maxSeverity) {
      maxSeverity = severity;
      maxTier = tier;
    }
  }

  return {
    maxTier,
    avgScore: scoreCount > 0 ? Math.round(scoreSum / scoreCount) : 0,
    tierCounts,
    totalPeople: members.length,
  };
}

// ─── Small components ────────────────────────────────────────────────────────

function TierBadge({ tier, showAll }) {
  if (!showAll && (!tier || tier === 'None' || tier === 'Minimal')) return null;
  const s = TIER_STYLES[tier] || TIER_STYLES.None;
  return (
    <span className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[11px] font-medium ${s.bg} ${s.text} ${s.border} border whitespace-nowrap`}>
      <span className={`w-1.5 h-1.5 rounded-full ${s.dot}`} />
      {tier}
    </span>
  );
}

function Avatar({ name, tier }) {
  const letter = (name || '?')[0].toUpperCase();
  const style = TIER_STYLES[tier] || TIER_STYLES.None;
  return (
    <div
      className="w-7 h-7 rounded-full flex items-center justify-center text-white text-xs font-semibold shrink-0"
      style={{ backgroundColor: style.avatar }}
    >
      {letter}
    </div>
  );
}

function StatCard({ label, value, detail }) {
  return (
    <div className="bg-white border border-gray-200 rounded-lg px-4 py-3">
      <div className="text-2xl font-semibold text-gray-900">{value}</div>
      <div className="text-xs text-gray-500 mt-0.5">{label}</div>
      {detail && <div className="text-[10px] text-gray-400 mt-0.5">{detail}</div>}
    </div>
  );
}

// ─── Department box (the clickable card in the flowchart) ────────────────────

function DeptBox({ node, isSelected, isMatch, onClick }) {
  const s = TIER_STYLES[node.risk.maxTier] || TIER_STYLES.None;

  return (
    <button
      onClick={onClick}
      className={`relative border-2 rounded-lg px-4 py-3 min-w-[150px] max-w-[220px] transition-all cursor-pointer text-center ${
        isSelected
          ? 'shadow-lg ring-2 ring-blue-500 border-blue-400'
          : isMatch
            ? 'ring-2 ring-blue-400'
            : ''
      }`}
      style={{
        backgroundColor: isSelected ? '#dbeafe' : s.box,
        borderColor: isSelected ? undefined : s.boxBorder,
      }}
    >
      <div className="font-semibold text-sm text-gray-900 leading-tight">
        {node.department}
      </div>
      <div className="text-[10px] text-gray-500 mt-1">
        {node.risk.totalPeople} member{node.risk.totalPeople !== 1 ? 's' : ''}
      </div>

      {/* Risk badge top-right */}
      {node.risk.maxTier && node.risk.maxTier !== 'None' && (
        <div className="absolute -top-2.5 -right-2">
          <TierBadge tier={node.risk.maxTier} showAll />
        </div>
      )}
    </button>
  );
}

// ─── Recursive org chart node with hybrid layout ─────────────────────────────
// Depth 0 (root): horizontal flowchart with connector lines
// Depth 1+: vertical indented tree (prevents horizontal overflow)

function OrgNode({ node, depth, selectedId, onSelect, expandedMap, toggleExpand, matchNodeIds }) {
  const isExpanded = expandedMap[node.id] ?? false;
  const hasChildren = node.children.length > 0;
  const useVertical = depth >= 1;

  // ── Vertical tree layout (depth >= 1) ───────────────────────
  if (useVertical) {
    return (
      <div>
        <DeptBox
          node={node}
          isSelected={selectedId === node.id}
          isMatch={matchNodeIds && matchNodeIds.has(node.id)}
          onClick={() => {
            onSelect(selectedId === node.id ? null : node.id);
            if (hasChildren) toggleExpand(node.id);
          }}
        />

        {hasChildren && !isExpanded && (
          <button
            onClick={() => toggleExpand(node.id)}
            className="mt-1 ml-4 text-[10px] text-blue-600 hover:text-blue-800 bg-blue-50 border border-blue-200 rounded px-1.5 py-0.5"
          >
            +{node.children.length} sub-dept{node.children.length !== 1 ? 's' : ''}
          </button>
        )}

        {hasChildren && isExpanded && (
          <div className="ml-8 border-l-2 border-gray-200 mt-2 space-y-2">
            {node.children.map(child => (
              <div key={child.id} className="relative pl-6">
                {/* Horizontal connector from vertical border to box */}
                <div className="absolute left-0 top-5 w-6 border-t-2 border-gray-200" />
                <OrgNode
                  node={child}
                  depth={depth + 1}
                  selectedId={selectedId}
                  onSelect={onSelect}
                  expandedMap={expandedMap}
                  toggleExpand={toggleExpand}
                  matchNodeIds={matchNodeIds}
                />
              </div>
            ))}
          </div>
        )}
      </div>
    );
  }

  // ── Horizontal flowchart layout (depth 0 — root) ───────────
  return (
    <div className="flex flex-col items-center">
      <DeptBox
        node={node}
        isSelected={selectedId === node.id}
        isMatch={matchNodeIds && matchNodeIds.has(node.id)}
        onClick={() => {
          onSelect(selectedId === node.id ? null : node.id);
          if (hasChildren) toggleExpand(node.id);
        }}
      />

      {hasChildren && !isExpanded && (
        <button
          onClick={() => toggleExpand(node.id)}
          className="mt-1 text-[10px] text-blue-600 hover:text-blue-800 bg-blue-50 border border-blue-200 rounded px-1.5 py-0.5"
        >
          +{node.children.length}
        </button>
      )}

      {hasChildren && isExpanded && (
        <>
          {/* Vertical stem down from parent */}
          <div className="w-0.5 h-6 bg-gray-300" />

          {/* Children row */}
          <div className="flex flex-wrap justify-center">
            {node.children.map((child, i) => {
              const isFirst = i === 0;
              const isLast = i === node.children.length - 1;
              const isSingle = node.children.length === 1;

              return (
                <div key={child.id} className="flex flex-col items-center px-3">
                  {/* Connector: horizontal bar segment + vertical stem */}
                  <div className="flex w-full h-5">
                    <div className={`flex-1 ${!isFirst && !isSingle ? 'border-t-2 border-gray-300' : ''}`} />
                    <div className="w-0.5 bg-gray-300" />
                    <div className={`flex-1 ${!isLast && !isSingle ? 'border-t-2 border-gray-300' : ''}`} />
                  </div>

                  {/* Recurse */}
                  <OrgNode
                    node={child}
                    depth={depth + 1}
                    selectedId={selectedId}
                    onSelect={onSelect}
                    expandedMap={expandedMap}
                    toggleExpand={toggleExpand}
                    matchNodeIds={matchNodeIds}
                  />
                </div>
              );
            })}
          </div>
        </>
      )}
    </div>
  );
}

// ─── Detail panel (shown when a department is selected) ──────────────────────

function DeptDetail({ node, onOpenDetail, onClose }) {
  return (
    <div className="bg-white border border-gray-200 rounded-lg shadow-sm overflow-hidden">
      {/* Header */}
      <div className="flex items-center justify-between px-5 py-3 border-b border-gray-100 bg-gray-50">
        <div>
          <h3 className="text-base font-semibold text-gray-900">{node.department}</h3>
          <div className="text-xs text-gray-500 mt-0.5">
            {node.risk.totalPeople} member{node.risk.totalPeople !== 1 ? 's' : ''}
            <span className="mx-1.5 text-gray-300">|</span>
            Avg. score: {node.risk.avgScore}
            {node.children.length > 0 && (
              <>
                <span className="mx-1.5 text-gray-300">|</span>
                {node.children.length} sub-department{node.children.length !== 1 ? 's' : ''}
              </>
            )}
          </div>
        </div>
        <div className="flex items-center gap-3">
          <TierBadge tier={node.risk.maxTier} showAll />
          <button
            onClick={onClose}
            className="text-gray-400 hover:text-gray-600 text-lg leading-none"
            title="Close"
          >
            &times;
          </button>
        </div>
      </div>

      {/* Risk distribution */}
      {TIER_DISPLAY.some(t => node.risk.tierCounts[t] > 0) && (
        <div className="flex gap-2 px-5 py-2 border-b border-gray-100">
          {TIER_DISPLAY.filter(t => node.risk.tierCounts[t] > 0).map(t => {
            const s = TIER_STYLES[t];
            return (
              <span key={t} className={`${s.bg} ${s.text} text-xs px-2.5 py-0.5 rounded-full border ${s.border}`}>
                {node.risk.tierCounts[t]} {t}
              </span>
            );
          })}
        </div>
      )}

      {/* Members */}
      <div className="px-5 py-3 max-h-[300px] overflow-y-auto">
        <div className="space-y-1">
          {node.members.map(user => (
            <div key={user.id} className="flex items-center gap-2 py-1.5 px-2 rounded-md hover:bg-gray-50">
              <Avatar name={user.displayName} tier={user.riskTier} />
              <div className="min-w-0 flex-1">
                <button
                  onClick={() => onOpenDetail('user', user.id, user.displayName)}
                  className="text-sm text-blue-700 hover:text-blue-900 hover:underline truncate text-left block"
                >
                  {user.displayName}
                </button>
                <div className="text-xs text-gray-400 truncate">{user.jobTitle || '\u2014'}</div>
              </div>
              <TierBadge tier={user.riskTier} />
              {user.riskScore != null && (
                <span className="text-xs font-mono text-gray-400 w-6 text-right shrink-0">{user.riskScore}</span>
              )}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

// ─── Main component ──────────────────────────────────────────────────────────

export default function OrgChartPage({ onOpenDetail }) {
  const { authFetch } = useAuth();
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [data, setData] = useState(null);
  const [search, setSearch] = useState('');
  const [debouncedSearch, setDebouncedSearch] = useState('');
  const [expandedMap, setExpandedMap] = useState({});
  const [selectedId, setSelectedId] = useState(null);
  const initialExpandDone = useRef(false);

  // ─── Fetch data ──────────────────────────────────────────────────
  const fetchData = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const res = await authFetch('/api/org-chart');
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const json = await res.json();
      if (json.available === false) {
        setData({ available: false, message: json.message || 'Org chart data not available.' });
      } else {
        setData(json);
      }
    } catch (err) {
      console.error('Failed to load org chart:', err);
      setError(err.message || 'Failed to load org chart data');
    } finally {
      setLoading(false);
    }
  }, [authFetch]);

  useEffect(() => { fetchData(); }, [fetchData]);

  // ─── Debounce search ────────────────────────────────────────────
  useEffect(() => {
    const timer = setTimeout(() => setDebouncedSearch(search.trim().toLowerCase()), 250);
    return () => clearTimeout(timer);
  }, [search]);

  // ─── Build department tree ──────────────────────────────────────
  const { rootNode, nodeMap, totalUsers, totalDepts } = useMemo(() => {
    if (!data || data.available === false) {
      return { rootNode: null, nodeMap: new Map(), totalUsers: 0, totalDepts: 0 };
    }

    const users = data.users || [];
    const userMap = new Map();
    const childrenMap = new Map(); // userId -> [direct report users]

    for (const u of users) userMap.set(u.id, u);

    for (const u of users) {
      if (u.managerId && userMap.has(u.managerId)) {
        if (!childrenMap.has(u.managerId)) childrenMap.set(u.managerId, []);
        childrenMap.get(u.managerId).push(u);
      }
    }

    // Find single root: user with no manager (or manager not in dataset) + most total reports
    let bestRoot = null;
    let bestCount = -1;
    for (const u of users) {
      const hasNoManager = !u.managerId || !userMap.has(u.managerId);
      const reports = childrenMap.get(u.id);
      if (!hasNoManager || !reports || reports.length === 0) continue;

      const totalReports = u.riskHierarchyTotalReports || reports.length;
      if (totalReports > bestCount) {
        bestCount = totalReports;
        bestRoot = u;
      }
    }

    if (!bestRoot) {
      return { rootNode: null, nodeMap: new Map(), totalUsers: 0, totalDepts: 0 };
    }

    // Build department tree with de-duplication by department name
    const visited = new Set();
    const nMap = new Map(); // nodeId -> node (for detail lookup)
    let nodeCounter = 0;
    let deptCount = 0;

    function buildChildren(parentMembers, parentDeptName) {
      // Collect all direct reports of all parent members
      const allReports = [];
      for (const member of parentMembers) {
        const reports = childrenMap.get(member.id) || [];
        for (const r of reports) {
          if (!visited.has(r.id)) {
            allReports.push(r);
            visited.add(r.id);
          }
        }
      }

      // Group by department name → de-duplicate
      const deptGroups = new Map();
      for (const report of allReports) {
        const dept = report.department || '(No department)';
        if (!deptGroups.has(dept)) deptGroups.set(dept, []);
        deptGroups.get(dept).push(report);
      }

      const children = [];
      const mergedMembers = []; // members from same-name child depts rolled into parent

      for (const [deptName, deptMembers] of deptGroups) {
        deptMembers.sort((a, b) => (a.displayName || '').localeCompare(b.displayName || ''));

        if (deptName === parentDeptName) {
          // Same department name as parent — roll up: merge members into parent, promote grandchildren
          mergedMembers.push(...deptMembers);
          const sub = buildChildren(deptMembers, parentDeptName);
          mergedMembers.push(...sub.mergedMembers);
          children.push(...sub.nodes);
          continue;
        }

        const sub = buildChildren(deptMembers, deptName);
        const allDeptMembers = [...deptMembers, ...sub.mergedMembers];
        const nodeId = `dept-${++nodeCounter}`;
        deptCount++;

        const node = {
          id: nodeId,
          department: deptName,
          members: allDeptMembers,
          children: sub.nodes,
          risk: computeDeptRisk(allDeptMembers),
        };
        nMap.set(nodeId, node);
        children.push(node);
      }

      // Sort: highest risk first, then by member count
      children.sort((a, b) => {
        const riskDiff = (TIER_ORDER[b.risk.maxTier] || 0) - (TIER_ORDER[a.risk.maxTier] || 0);
        if (riskDiff !== 0) return riskDiff;
        return b.risk.totalPeople - a.risk.totalPeople;
      });

      return { nodes: children, mergedMembers };
    }

    visited.add(bestRoot.id);
    const rootDeptName = bestRoot.department || '(No department)';
    const rootResult = buildChildren([bestRoot], rootDeptName);
    const rootMembers = [bestRoot, ...rootResult.mergedMembers];
    const rootId = `dept-root`;
    deptCount++;

    const root = {
      id: rootId,
      department: rootDeptName,
      members: rootMembers,
      children: rootResult.nodes,
      risk: computeDeptRisk(rootMembers),
    };
    nMap.set(rootId, root);

    return {
      rootNode: root,
      nodeMap: nMap,
      totalUsers: visited.size,
      totalDepts: deptCount,
    };
  }, [data]);

  // ─── Initial expand: first 4 levels ────────────────────────────
  useEffect(() => {
    if (rootNode && !initialExpandDone.current) {
      initialExpandDone.current = true;
      const initial = {};
      function walkExpand(node, depth) {
        if (depth < 4) {
          initial[node.id] = true;
          for (const child of node.children) walkExpand(child, depth + 1);
        }
      }
      walkExpand(rootNode, 0);
      setExpandedMap(initial);
    }
  }, [rootNode]);

  // ─── Search matching ───────────────────────────────────────────
  const { matchNodeIds, matchCount } = useMemo(() => {
    if (!debouncedSearch || !rootNode) {
      return { matchNodeIds: new Set(), matchCount: 0 };
    }

    const nodeMatches = new Set();
    let userMatchCount = 0;

    function walkNodes(node) {
      let matched = false;
      // Check department name
      if ((node.department || '').toLowerCase().includes(debouncedSearch)) {
        matched = true;
      }
      // Check members
      for (const member of node.members) {
        const hay = [member.displayName, member.jobTitle, member.department]
          .filter(Boolean).join(' ').toLowerCase();
        if (hay.includes(debouncedSearch)) {
          matched = true;
          userMatchCount++;
        }
      }
      if (matched) nodeMatches.add(node.id);

      for (const child of node.children) walkNodes(child);
    }
    walkNodes(rootNode);

    return { matchNodeIds: nodeMatches, matchCount: userMatchCount };
  }, [debouncedSearch, rootNode]);

  // ─── Expand / collapse ─────────────────────────────────────────
  const toggleExpand = useCallback((id) => {
    setExpandedMap(prev => ({ ...prev, [id]: !prev[id] }));
  }, []);

  const expandAll = useCallback(() => {
    if (!rootNode) return;
    const map = {};
    function walk(node) {
      map[node.id] = true;
      for (const child of node.children) walk(child);
    }
    walk(rootNode);
    setExpandedMap(map);
  }, [rootNode]);

  const collapseAll = useCallback(() => {
    if (!rootNode) return;
    setExpandedMap({ [rootNode.id]: true });
  }, [rootNode]);

  // ─── Selected node for detail panel ────────────────────────────
  const selectedNode = selectedId ? nodeMap.get(selectedId) : null;

  // ─── Overall risk stats ────────────────────────────────────────
  const overallTierCounts = useMemo(() => {
    if (!data || data.available === false) return null;
    const counts = {};
    for (const u of (data.users || [])) {
      const tier = u.riskTier || 'None';
      counts[tier] = (counts[tier] || 0) + 1;
    }
    return counts;
  }, [data]);

  // ─── Render ───────────────────────────────────────────────────

  if (loading) {
    return (
      <div className="flex items-center justify-center h-64">
        <div className="text-gray-500">Loading org chart data...</div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="bg-red-50 border border-red-200 rounded-lg p-6 max-w-md mx-auto mt-12">
        <h2 className="text-red-800 font-semibold text-lg">Failed to load org chart</h2>
        <p className="text-red-600 mt-2 text-sm">{error}</p>
        <button onClick={fetchData} className="mt-3 text-sm text-red-700 underline hover:text-red-900">Retry</button>
      </div>
    );
  }

  if (data && data.available === false) {
    return (
      <div className="bg-amber-50 border border-amber-200 rounded-lg p-6 max-w-lg mx-auto mt-12">
        <h2 className="text-amber-800 font-semibold text-lg">Org Chart Not Available</h2>
        <p className="text-amber-700 mt-2 text-sm">
          {data.message || 'User data with manager information is required.'}
        </p>
      </div>
    );
  }

  if (!rootNode) {
    return (
      <div className="bg-white border border-gray-200 rounded-lg p-8 text-center text-gray-400 text-sm">
        No users with manager data found. Run a sync that includes manager information first.
      </div>
    );
  }

  return (
    <div>
      {/* Stats */}
      <div className="grid grid-cols-4 gap-4 mb-4">
        <StatCard label="Users in org tree" value={totalUsers} />
        <StatCard label="Departments" value={totalDepts} />
        <StatCard
          label="Highest risk"
          value={
            overallTierCounts
              ? TIER_DISPLAY.find(t => overallTierCounts[t] > 0)
                ? `${overallTierCounts[TIER_DISPLAY.find(t => overallTierCounts[t] > 0)]} ${TIER_DISPLAY.find(t => overallTierCounts[t] > 0)}`
                : 'None'
              : '\u2014'
          }
        />
        <StatCard
          label="Risk overview"
          value={
            overallTierCounts
              ? TIER_DISPLAY.filter(t => overallTierCounts[t] > 0).map(t => `${overallTierCounts[t]} ${t[0]}`).join(', ') || 'No data'
              : '\u2014'
          }
          detail={overallTierCounts ? TIER_DISPLAY.filter(t => overallTierCounts[t] > 0).map(t => t).join(', ') : ''}
        />
      </div>

      {/* Toolbar */}
      <div className="bg-white border border-gray-200 rounded-lg px-4 py-3 mb-4 flex items-center gap-4 flex-wrap">
        <div className="flex-1 min-w-[200px] max-w-sm">
          <input
            type="text"
            value={search}
            onChange={e => setSearch(e.target.value)}
            placeholder="Search by name, title, or department..."
            className="w-full text-sm border border-gray-200 rounded-lg px-3 py-1.5 placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-400 focus:border-transparent"
            aria-label="Search org chart"
          />
        </div>
        <div className="flex items-center gap-1">
          <button onClick={expandAll} className="text-xs text-gray-500 hover:text-gray-700 border border-gray-200 rounded px-2 py-1 hover:bg-gray-50">
            Expand All
          </button>
          <button onClick={collapseAll} className="text-xs text-gray-500 hover:text-gray-700 border border-gray-200 rounded px-2 py-1 hover:bg-gray-50">
            Collapse All
          </button>
        </div>
        {debouncedSearch && (
          <div className="text-xs text-gray-400">
            {matchCount} match{matchCount !== 1 ? 'es' : ''} in {matchNodeIds.size} department{matchNodeIds.size !== 1 ? 's' : ''}
          </div>
        )}
      </div>

      {/* Org chart */}
      <div className="bg-white border border-gray-200 rounded-lg p-6 overflow-x-auto">
        <div className="flex justify-center py-4">
          <OrgNode
            node={rootNode}
            depth={0}
            selectedId={selectedId}
            onSelect={setSelectedId}
            expandedMap={expandedMap}
            toggleExpand={toggleExpand}
            matchNodeIds={matchNodeIds}
          />
        </div>
      </div>

      {/* Detail panel */}
      {selectedNode && (
        <div className="mt-4">
          <DeptDetail
            node={selectedNode}
            onOpenDetail={onOpenDetail}
            onClose={() => setSelectedId(null)}
          />
        </div>
      )}
    </div>
  );
}
