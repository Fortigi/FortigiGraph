import { useMemo, useState, useCallback, useEffect, useRef } from 'react';
import { DndContext, closestCenter, PointerSensor, useSensor, useSensors } from '@dnd-kit/core';
import { SortableContext, verticalListSortingStrategy, arrayMove } from '@dnd-kit/sortable';
import { restrictToVerticalAxis } from '@dnd-kit/modifiers';
import { useMatrixRowOrder } from '../hooks/useMatrixRowOrder';
import { exportToExcel } from '../utils/exportToExcel';
import MatrixToolbar from './matrix/MatrixToolbar';
import MatrixColumnHeaders from './matrix/MatrixColumnHeaders';
import MatrixGroupRow from './matrix/MatrixGroupRow';

// Fields to exclude from filter (IDs, display names used as labels, not useful for filtering)
const EXCLUDE_FIELDS = new Set(['groupId', 'memberId', 'memberDisplayName', 'memberUPN', 'memberType', 'managedByAccessPackage']);
// Friendly labels for known fields
const FIELD_LABELS = {
  // User columns
  department: 'Department',
  jobTitle: 'Job Title',
  companyName: 'Company',
  accountEnabled: 'Account Enabled',
  userType: 'User Type',
  employeeType: 'Employee Type',
  officeLocation: 'Office Location',
  city: 'City',
  country: 'Country',
  state: 'State',
  usageLocation: 'Usage Location',
  mail: 'Mail',
  manager: 'Manager',
  onPremisesSamAccountName: 'SAM Account',
  onPremisesSyncEnabled: 'On-Prem Sync',
  __userTag: 'User Tag',
  // Relationship fields
  membershipType: 'Membership Type',
};

export default function MatrixView({
  data, accessPackageGroups = [], managedByPackages = [], totalUsers: serverTotalUsers,
  userLimit, setUserLimit,
  activeFilters, setActiveFilters,
  managedFilter, setManagedFilter,
  filterText, setFilterText,
  userColumns,
  groupTagMap,
  refreshing,
  shareUrl,
}) {
  const [groupTypeFilter, setGroupTypeFilter] = useState(null); // null = all, Set = selected types
  const [groupTagFilter, setGroupTagFilter] = useState(null); // null = all, Set = selected tag names

  // Build a stable storage key from all active filters (sorted for consistency)
  const storageKey = useMemo(() => {
    if (activeFilters.length === 0) return '';
    return activeFilters
      .map(f => `${f.field}:${f.value}`)
      .sort()
      .join('|');
  }, [activeFilters]);

  const rowOrderHook = useMatrixRowOrder(storageKey);

  // Sets of column names (for knowing which filters are server-side)
  const userColumnNames = useMemo(() => {
    if (!userColumns) return new Set();
    return new Set(userColumns.map(c => c.column));
  }, [userColumns]);

  // Auto-discover filterable fields from data + merge server-provided user columns.
  // Data-derived fields appear even if not in server columns (e.g., membershipType).
  // Server-provided columns appear even if all values are null in the current page.
  const filterFields = useMemo(() => {
    const fieldMap = new Map(); // key -> { key, label, dataKey }

    // 1. Discover from data (current page)
    if (data && data.length > 0) {
      const sample = data[0];
      for (const key of Object.keys(sample)) {
        if (EXCLUDE_FIELDS.has(key)) continue;
        const values = new Set();
        for (const d of data) {
          const val = d[key];
          if (val != null && val !== '') values.add(String(val));
          if (values.size > 500) break;
        }
        if (values.size >= 1 && values.size <= 500) {
          fieldMap.set(key, {
            key,
            label: FIELD_LABELS[key] || key.replace(/([A-Z])/g, ' $1').replace(/^./, s => s.toUpperCase()).trim(),
            dataKey: key,
          });
        }
      }
    }

    // 2. Add server-provided user columns that aren't already discovered
    if (userColumns) {
      for (const col of userColumns) {
        if (EXCLUDE_FIELDS.has(col.column)) continue;
        if (!fieldMap.has(col.column) && col.values && col.values.length > 0) {
          fieldMap.set(col.column, {
            key: col.column,
            label: FIELD_LABELS[col.column] || col.column.replace(/([A-Z])/g, ' $1').replace(/^./, s => s.toUpperCase()).trim(),
            dataKey: col.column,
          });
        }
      }
    }

    return [...fieldMap.values()].sort((a, b) => a.label.localeCompare(b.label));
  }, [data, userColumns]);

  // User filter fields = columns known to the server from GraphUsers table + __userTag.
  const userFilterFields = useMemo(
    () => filterFields.filter(f => userColumnNames.has(f.key) || f.key === '__userTag'),
    [filterFields, userColumnNames],
  );

  // Get available values for a specific field.
  // Server-provided columns: use server values (full dataset, not just current page).
  // Other fields: derive from loaded data with cross-filter logic.
  const getOptionsForField = useCallback((fieldKey) => {
    // For user columns, return server-provided values (from full dataset)
    if (userColumns) {
      const serverCol = userColumns.find(c => c.column === fieldKey);
      if (serverCol && serverCol.values && serverCol.values.length > 0) {
        return serverCol.values;
      }
    }
    // For non-server columns (membershipType, etc.), derive from loaded data
    const field = filterFields.find(f => f.key === fieldKey);
    if (!field) return [];
    // Apply all OTHER active filters first to show contextual values
    let filtered = data;
    for (const af of activeFilters) {
      if (af.field === fieldKey) continue;
      const f = filterFields.find(ff => ff.key === af.field);
      if (f) {
        filtered = filtered.filter(d => String(d[f.dataKey] ?? '') === af.value);
      }
    }
    const values = new Set();
    filtered.forEach(d => {
      const val = d[field.dataKey];
      if (val != null && val !== '') values.add(String(val));
    });
    return [...values].sort();
  }, [data, activeFilters, filterFields, userColumns]);

  const addFilter = useCallback((field, value) => {
    setActiveFilters(prev => [...prev.filter(f => f.field !== field), { field, value }]);
  }, [setActiveFilters]);

  const removeFilter = useCallback((field) => {
    setActiveFilters(prev => prev.filter(f => f.field !== field));
  }, [setActiveFilters]);

  const clearAllFilters = useCallback(() => {
    setActiveFilters([]);
  }, [setActiveFilters]);

  // Apply CLIENT-SIDE filters only (server-side user & group attribute filters already applied by backend).
  // Client-side: text search, managed toggle, non-server-column structured filters (e.g., membershipType).
  const filteredData = useMemo(() => {
    let result = data;
    // Only apply non-server filters client-side
    for (const af of activeFilters) {
      if (userColumnNames.has(af.field)) continue; // already applied server-side
      const field = filterFields.find(f => f.key === af.field);
      if (field) {
        result = result.filter(d => String(d[field.dataKey] ?? '') === af.value);
      }
    }
    if (filterText) {
      const lower = filterText.toLowerCase();
      result = result.filter(d =>
        (d.memberDisplayName || '').toLowerCase().includes(lower) ||
        (d.groupDisplayName || '').toLowerCase().includes(lower) ||
        (d.memberUPN || '').toLowerCase().includes(lower)
      );
    }
    if (managedFilter === 'managed') {
      result = result.filter(d => !!d.managedByAccessPackage);
    } else if (managedFilter === 'unmanaged') {
      result = result.filter(d => !d.managedByAccessPackage);
    }
    return result;
  }, [data, activeFilters, filterFields, filterText, managedFilter, userColumnNames]);

  // Build matrix data structures
  const { users, groups, memberships, managedMap } = useMemo(() => {
    const userMap = new Map();
    const groupMap = new Map();
    const membershipMap = new Map();
    const managed = new Map();

    filteredData.forEach(d => {
      // Users
      if (d.memberId && !userMap.has(d.memberId)) {
        userMap.set(d.memberId, {
          id: d.memberId,
          displayName: d.memberDisplayName || d.memberId,
          jobTitle: d.jobTitle || '',
          department: d.department || '',
          upn: d.memberUPN || '',
        });
      }

      // Groups
      if (d.groupId && !groupMap.has(d.groupId)) {
        const name = d.groupDisplayName || d.groupId;
        const tags = groupTagMap?.get(d.groupId.toUpperCase()) || [];

        groupMap.set(d.groupId, {
          id: d.groupId,
          displayName: name,
          tags,
          description: d.groupDescription || '',
          groupType: d.groupTypeCalculated || '',
        });
      }

      // Memberships
      const key = `${d.groupId}|${d.memberId}`;
      if (!membershipMap.has(key)) {
        membershipMap.set(key, new Set());
      }
      membershipMap.get(key).add(d.membershipType);

      // Track managedByAccessPackage per cell (boolean from view, used for filtering)
      if (d.managedByAccessPackage) {
        managed.set(key, true);
      }
    });

    // Sort users by job title then name
    const users = [...userMap.values()].sort((a, b) => {
      const titleCmp = (a.jobTitle || '').localeCompare(b.jobTitle || '');
      if (titleCmp !== 0) return titleCmp;
      return (a.displayName || '').localeCompare(b.displayName || '');
    });

    // Compute member count per group (for default sort and % column)
    const userList = [...userMap.values()];
    for (const group of groupMap.values()) {
      group.memberCount = userList.filter(u => membershipMap.has(`${group.id}|${u.id}`)).length;
    }

    // Sort groups by member count descending (most common permissions first)
    const groups = [...groupMap.values()].sort((a, b) => b.memberCount - a.memberCount);

    return { users, groups, memberships: membershipMap, managedMap: managed };
  }, [filteredData, groupTagMap]);

  // Build managed-by-AP map: cellKey (lowercase) -> accessPackageId[] (lowercase)
  // All keys and values normalized to lowercase for case-insensitive matching
  const managedApMap = useMemo(() => {
    const map = new Map();
    if (!managedByPackages || managedByPackages.length === 0) return map;
    for (const r of managedByPackages) {
      const key = `${(r.groupId || '').toLowerCase()}|${(r.memberId || '').toLowerCase()}`;
      map.set(key, (r.accessPackageIds || []).map(id => id.toLowerCase()));
    }
    return map;
  }, [managedByPackages]);

  // Build access package data (SOLL matrix): which groups are in which access packages
  // Only include APs where at least one visible user actually has an assignment through that AP.
  const { accessPackages, apGroupMap } = useMemo(() => {
    if (!accessPackageGroups || accessPackageGroups.length === 0) {
      return { accessPackages: [], apGroupMap: new Map() };
    }
    const visibleGroupIds = new Set(groups.map(g => g.id));
    const visibleUserIds = new Set(users.map(u => u.id.toLowerCase()));
    const apMap = new Map();
    const mapping = new Map(); // "groupId|apId" -> roleName

    for (const row of accessPackageGroups) {
      const gid = row.groupId?.toUpperCase();
      if (!gid || !visibleGroupIds.has(gid)) continue;
      if (!apMap.has(row.accessPackageId)) {
        apMap.set(row.accessPackageId, {
          id: row.accessPackageId,
          displayName: row.accessPackageName,
          catalogName: row.catalogName,
          totalAssignments: row.totalAssignments || 0,
        });
      }
      mapping.set(`${gid}|${row.accessPackageId}`, row.roleName || 'Member');
    }

    // Filter to APs that have at least one visible user assignment
    const apIdsWithAssignments = new Set();
    for (const [cellKey, apIds] of managedApMap) {
      const [gid, uid] = cellKey.split('|');
      if (visibleGroupIds.has(gid.toUpperCase()) && visibleUserIds.has(uid)) {
        for (const apId of apIds) {
          apIdsWithAssignments.add(apId);
        }
      }
    }
    for (const apId of [...apMap.keys()]) {
      if (!apIdsWithAssignments.has(apId.toLowerCase())) {
        apMap.delete(apId);
      }
    }

    // Sort access packages by total assignments descending (broadest first)
    const accessPackages = [...apMap.values()].sort((a, b) =>
      b.totalAssignments - a.totalAssignments || a.displayName.localeCompare(b.displayName)
    );
    return { accessPackages, apGroupMap: mapping };
  }, [accessPackageGroups, groups, users, managedApMap]);

  // AP ID (lowercase) -> sorted index (for consistent color lookup)
  const apIdToIndex = useMemo(() => {
    const map = new Map();
    accessPackages.forEach((ap, idx) => map.set(ap.id.toLowerCase(), idx));
    return map;
  }, [accessPackages]);

  // Unique group types for filter dropdown
  const uniqueGroupTypes = useMemo(() => {
    const types = new Set();
    groups.forEach(g => { if (g.groupType) types.add(g.groupType); });
    return [...types].sort();
  }, [groups]);

  // Unique group tags for filter dropdown (derived from groups which already have tags attached)
  const uniqueGroupTags = useMemo(() => {
    const tagMap = new Map(); // name -> { name, color }
    groups.forEach(g => {
      (g.tags || []).forEach(t => {
        if (!tagMap.has(t.name)) tagMap.set(t.name, { name: t.name, color: t.color });
      });
    });
    return [...tagMap.values()].sort((a, b) => a.name.localeCompare(b.name));
  }, [groups]);

  // Default: exclude Distribution and Dynamic group types (user can change)
  const groupTypeDefaultsApplied = useRef(false);
  useEffect(() => {
    if (groupTypeDefaultsApplied.current || uniqueGroupTypes.length === 0) return;
    groupTypeDefaultsApplied.current = true;
    const excluded = /distribution|dynamic/i;
    const defaults = new Set(uniqueGroupTypes.filter(t => !excluded.test(t)));
    if (defaults.size > 0 && defaults.size < uniqueGroupTypes.length) {
      setGroupTypeFilter(defaults);
    }
  }, [uniqueGroupTypes]);

  // Default sort: AP staircase pattern.
  // All groups in the leftmost AP first, then next AP, etc. Unmanaged at the bottom.
  const apSortedGroups = useMemo(() => {
    if (accessPackages.length === 0) return groups; // no APs, keep member count sort

    // Assign each group to the AP bucket of its leftmost AP column
    const groupApBucket = new Map();
    for (const g of groups) {
      let bucket = accessPackages.length; // unmanaged = after all APs
      for (let i = 0; i < accessPackages.length; i++) {
        if (apGroupMap.has(`${g.id}|${accessPackages[i].id}`)) {
          bucket = i;
          break;
        }
      }
      groupApBucket.set(g.id, bucket);
    }

    return [...groups].sort((a, b) => {
      const aBucket = groupApBucket.get(a.id);
      const bBucket = groupApBucket.get(b.id);
      if (aBucket !== bBucket) return aBucket - bBucket;
      // Same bucket: sort by member count descending
      return b.memberCount - a.memberCount;
    });
  }, [groups, accessPackages, apGroupMap]);

  // Apply custom row order (drag), then filter by group type and tags
  const orderedGroups = useMemo(() => {
    let result = rowOrderHook.getOrderedGroups(apSortedGroups);
    if (groupTypeFilter && groupTypeFilter.size > 0) {
      result = result.filter(g => groupTypeFilter.has(g.groupType));
    }
    if (groupTagFilter && groupTagFilter.size > 0) {
      result = result.filter(g => (g.tags || []).some(t => groupTagFilter.has(t.name)));
    }
    return result;
  }, [apSortedGroups, rowOrderHook.getOrderedGroups, groupTypeFilter, groupTagFilter]);

  const groupIds = useMemo(() => orderedGroups.map(g => g.id), [orderedGroups]);

  // Row DnD setup
  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 5 } })
  );

  const handleRowDragEnd = useCallback((event) => {
    const { active, over } = event;
    if (!over || active.id === over.id) return;
    const oldIndex = groupIds.indexOf(active.id);
    const newIndex = groupIds.indexOf(over.id);
    const newOrder = arrayMove(groupIds, oldIndex, newIndex);
    rowOrderHook.updateOrder(newOrder);
  }, [groupIds, rowOrderHook]);

  // Sort rows by member count descending (clears any custom drag order)
  const handleSortByCount = useCallback(() => {
    const sorted = [...orderedGroups].sort((a, b) => b.memberCount - a.memberCount);
    rowOrderHook.updateOrder(sorted.map(g => g.id));
  }, [orderedGroups, rowOrderHook]);

  // Excel export handler
  const handleExportExcel = useCallback(() => {
    exportToExcel({
      users,
      orderedGroups,
      memberships,
      managedApMap,
      apIdToIndex,
      activeFilters,
      filterFields,
      accessPackages,
      apGroupMap,
      shareUrl,
    });
  }, [users, orderedGroups, memberships, managedApMap, apIdToIndex, activeFilters, filterFields, accessPackages, apGroupMap, shareUrl]);

  // Share: copy URL to clipboard
  const handleShare = useCallback(async () => {
    try {
      await navigator.clipboard.writeText(shareUrl);
      return true;
    } catch {
      return false;
    }
  }, [shareUrl]);

  const stats = {
    users: users.length,
    totalUsers: serverTotalUsers,
    groups: orderedGroups.length,
    memberships: memberships.size,
  };

  // Number of info columns (drag handle + category + group name)
  const infoColumnCount = 3;

  return (
    <div className="flex flex-col gap-3">
      <MatrixToolbar
        filterFields={filterFields}
        userFilterFields={userFilterFields}
        activeFilters={activeFilters}
        getOptionsForField={getOptionsForField}
        onAddFilter={addFilter}
        onRemoveFilter={removeFilter}
        filterText={filterText}
        setFilterText={setFilterText}
        managedFilter={managedFilter}
        setManagedFilter={setManagedFilter}
        userLimit={userLimit}
        setUserLimit={setUserLimit}
        onExportExcel={handleExportExcel}
        onShare={handleShare}
        onResetRowOrder={rowOrderHook.resetOrder}
        hasCustomRowOrder={rowOrderHook.hasCustomOrder}
        stats={stats}
      />

      {users.length === 0 || orderedGroups.length === 0 ? (
        <div className="text-center text-gray-500 py-12">
          {activeFilters.length > 0
            ? 'No data found for the current filters. Try removing some filters.'
            : 'No permission data available. Add a filter to narrow down the view.'}
        </div>
      ) : (
        <div className="relative border border-gray-200 rounded-lg overflow-auto max-h-[calc(100vh-280px)]">
          {refreshing && (
            <div className="absolute inset-0 bg-white/60 z-10 flex items-center justify-center">
              <div className="bg-white border border-gray-200 rounded-lg px-4 py-2 shadow-sm flex items-center gap-2">
                <svg className="animate-spin h-4 w-4 text-blue-500" viewBox="0 0 24 24" fill="none">
                  <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
                  <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
                </svg>
                <span className="text-sm text-gray-600">Updating...</span>
              </div>
            </div>
          )}
          <DndContext
            sensors={sensors}
            collisionDetection={closestCenter}
            onDragEnd={handleRowDragEnd}
            modifiers={[restrictToVerticalAxis]}
          >
            <table className="border-collapse" style={{ tableLayout: 'fixed' }}>
              <MatrixColumnHeaders
                users={users}
                infoColumnCount={infoColumnCount}
                onSortByCount={handleSortByCount}
                accessPackages={accessPackages}
                uniqueGroupTypes={uniqueGroupTypes}
                groupTypeFilter={groupTypeFilter}
                onGroupTypeFilterChange={setGroupTypeFilter}
                uniqueGroupTags={uniqueGroupTags}
                groupTagFilter={groupTagFilter}
                onGroupTagFilterChange={setGroupTagFilter}
              />
              <SortableContext items={groupIds} strategy={verticalListSortingStrategy}>
                <tbody>
                  {orderedGroups.map(group => (
                    <MatrixGroupRow
                      key={group.id}
                      group={group}
                      users={users}
                      totalUsers={users.length}
                      memberships={memberships}
                      managedMap={managedMap}
                      managedApMap={managedApMap}
                      apIdToIndex={apIdToIndex}
                      accessPackages={accessPackages}
                      apGroupMap={apGroupMap}
                    />
                  ))}
                </tbody>
              </SortableContext>
            </table>
          </DndContext>
        </div>
      )}
    </div>
  );
}
