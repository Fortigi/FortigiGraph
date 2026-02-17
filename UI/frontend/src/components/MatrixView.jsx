import { useMemo, useState, useCallback } from 'react';
import { DndContext, closestCenter, PointerSensor, useSensor, useSensors } from '@dnd-kit/core';
import { SortableContext, verticalListSortingStrategy, arrayMove } from '@dnd-kit/sortable';
import { restrictToVerticalAxis } from '@dnd-kit/modifiers';
import { useMatrixRowOrder } from '../hooks/useMatrixRowOrder';
import { exportToExcel } from '../utils/exportToExcel';
import MatrixToolbar from './matrix/MatrixToolbar';
import MatrixColumnHeaders from './matrix/MatrixColumnHeaders';
import MatrixGroupRow from './matrix/MatrixGroupRow';

// Fields to exclude from filter (IDs, display names used as labels, not useful for filtering)
const EXCLUDE_FIELDS = new Set(['groupId', 'memberId', 'memberDisplayName', 'memberUPN', 'memberType']);
// Friendly labels for known fields
const FIELD_LABELS = {
  department: 'Department',
  jobTitle: 'Job Title',
  membershipType: 'Membership Type',
  groupDisplayName: 'Group',
  companyName: 'Company',
  accountEnabled: 'Account Enabled',
  userType: 'User Type',
  employeeType: 'Employee Type',
};

export default function MatrixView({ data, accessPackageGroups = [], managedByPackages = [], totalUsers: serverTotalUsers, userLimit, setUserLimit }) {
  // Multiple active filters: [{field: 'department', value: 'Sales'}, ...]
  const [activeFilters, setActiveFilters] = useState([]);
  const [filterText, setFilterText] = useState('');
  const [groupTypeFilter, setGroupTypeFilter] = useState(null); // null = all, Set = selected types
  const [managedFilter, setManagedFilter] = useState('all'); // 'all' | 'unmanaged' | 'managed'

  // Build a stable storage key from all active filters (sorted for consistency)
  const storageKey = useMemo(() => {
    if (activeFilters.length === 0) return '';
    return activeFilters
      .map(f => `${f.field}:${f.value}`)
      .sort()
      .join('|');
  }, [activeFilters]);

  const rowOrderHook = useMatrixRowOrder(storageKey);

  // Auto-discover filterable fields from data
  const filterFields = useMemo(() => {
    if (!data || data.length === 0) return [];
    const sample = data[0];
    return Object.keys(sample)
      .filter(key => !EXCLUDE_FIELDS.has(key))
      .filter(key => {
        // Include fields that have at least 1 distinct value and aren't all unique
        const values = new Set();
        for (const d of data) {
          const val = d[key];
          if (val != null && val !== '') values.add(String(val));
          if (values.size > 500) break; // Too many unique values, skip
        }
        return values.size >= 1 && values.size <= 500;
      })
      .map(key => ({
        key,
        label: FIELD_LABELS[key] || key.replace(/([A-Z])/g, ' $1').replace(/^./, s => s.toUpperCase()).trim(),
        dataKey: key,
      }))
      .sort((a, b) => a.label.localeCompare(b.label));
  }, [data]);

  // Get available values for a specific field (considering already-applied filters)
  const getOptionsForField = useCallback((fieldKey) => {
    const field = filterFields.find(f => f.key === fieldKey);
    if (!field) return [];
    // Apply all OTHER active filters first to show contextual values
    let filtered = data;
    for (const af of activeFilters) {
      if (af.field === fieldKey) continue; // skip the field we're getting options for
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
  }, [data, activeFilters, filterFields]);

  const addFilter = useCallback((field, value) => {
    setActiveFilters(prev => [...prev.filter(f => f.field !== field), { field, value }]);
  }, []);

  const removeFilter = useCallback((field) => {
    setActiveFilters(prev => prev.filter(f => f.field !== field));
  }, []);

  const clearAllFilters = useCallback(() => {
    setActiveFilters([]);
  }, []);

  // Filter data by all active filters, text search, and managed filter
  const filteredData = useMemo(() => {
    let result = data;
    for (const af of activeFilters) {
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
  }, [data, activeFilters, filterFields, filterText, managedFilter]);

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
        // Parse category from group name prefix
        const parts = name.split(/[-_]/);
        let category = '';
        const prefixMap = {
          AG: 'App Group', CG: 'Cloud Group', GG: 'Global Group',
          SG: 'Security', APP: 'Application', ROL: 'Role',
          ORG: 'Organization', UAW: 'Access', MGT: 'Management',
        };
        if (parts.length > 1) {
          category = prefixMap[parts[0].toUpperCase()] || parts[0];
        }

        groupMap.set(d.groupId, {
          id: d.groupId,
          displayName: name,
          category,
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
  }, [filteredData]);

  // Build managed-by-AP map: cellKey -> accessPackageId[]
  // Uses case-insensitive groupId matching (AP view uppercases, main view may not)
  const managedApMap = useMemo(() => {
    const map = new Map();
    if (!managedByPackages || managedByPackages.length === 0) return map;
    for (const r of managedByPackages) {
      // Try both original and uppercased groupId to handle SQL collation differences
      const key = `${r.groupId}|${r.memberId}`;
      const keyUpper = `${(r.groupId || '').toUpperCase()}|${r.memberId}`;
      map.set(key, r.accessPackageIds);
      if (key !== keyUpper) map.set(keyUpper, r.accessPackageIds);
    }
    return map;
  }, [managedByPackages]);

  // Build access package data (SOLL matrix): which groups are in which access packages
  const { accessPackages, apGroupMap } = useMemo(() => {
    if (!accessPackageGroups || accessPackageGroups.length === 0) {
      return { accessPackages: [], apGroupMap: new Map() };
    }
    // Only include access packages that reference groups in our current view
    const visibleGroupIds = new Set(groups.map(g => g.id));
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
        });
      }
      mapping.set(`${gid}|${row.accessPackageId}`, row.roleName || 'Member');
    }

    // Sort access packages alphabetically
    const accessPackages = [...apMap.values()].sort((a, b) =>
      a.displayName.localeCompare(b.displayName)
    );
    return { accessPackages, apGroupMap: mapping };
  }, [accessPackageGroups, groups]);

  // AP ID -> sorted index (for consistent color lookup)
  const apIdToIndex = useMemo(() => {
    const map = new Map();
    accessPackages.forEach((ap, idx) => map.set(ap.id, idx));
    return map;
  }, [accessPackages]);

  // Unique group types for filter dropdown
  const uniqueGroupTypes = useMemo(() => {
    const types = new Set();
    groups.forEach(g => { if (g.groupType) types.add(g.groupType); });
    return [...types].sort();
  }, [groups]);

  // Apply custom row order, then filter by group type
  const orderedGroups = useMemo(() => {
    let result = rowOrderHook.getOrderedGroups(groups);
    if (groupTypeFilter && groupTypeFilter.size > 0) {
      result = result.filter(g => groupTypeFilter.has(g.groupType));
    }
    return result;
  }, [groups, rowOrderHook.getOrderedGroups, groupTypeFilter]);

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
    });
  }, [users, orderedGroups, memberships, managedApMap, apIdToIndex, activeFilters, filterFields, accessPackages, apGroupMap]);

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
        activeFilters={activeFilters}
        getOptionsForField={getOptionsForField}
        onAddFilter={addFilter}
        onRemoveFilter={removeFilter}
        onClearAllFilters={clearAllFilters}
        filterText={filterText}
        setFilterText={setFilterText}
        managedFilter={managedFilter}
        setManagedFilter={setManagedFilter}
        userLimit={userLimit}
        setUserLimit={setUserLimit}
        onExportExcel={handleExportExcel}
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
        <div className="border border-gray-200 rounded-lg overflow-auto max-h-[calc(100vh-280px)]">
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
