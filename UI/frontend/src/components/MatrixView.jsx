import { useMemo, useState, useCallback, useEffect } from 'react';
import { DndContext, closestCenter, PointerSensor, useSensor, useSensors } from '@dnd-kit/core';
import { SortableContext, verticalListSortingStrategy, arrayMove } from '@dnd-kit/sortable';
import { restrictToVerticalAxis } from '@dnd-kit/modifiers';
import { useMatrixAnnotations } from '../hooks/useMatrixAnnotations';
import { useMatrixRowOrder } from '../hooks/useMatrixRowOrder';
import { useMatrixColumnOrder } from '../hooks/useMatrixColumnOrder';
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

export default function MatrixView({ data }) {
  const [filterField, setFilterField] = useState('department');
  const [filterValue, setFilterValue] = useState('');
  const [filterText, setFilterText] = useState('');

  // Storage key combines field + value for unique persistence
  const storageKey = filterValue ? `${filterField}:${filterValue}` : '';
  const annotations = useMatrixAnnotations(storageKey);
  const rowOrderHook = useMatrixRowOrder(storageKey);
  const colOrderHook = useMatrixColumnOrder(storageKey);

  // Auto-discover filterable fields from data
  const filterFields = useMemo(() => {
    if (!data || data.length === 0) return [];
    const sample = data[0];
    return Object.keys(sample)
      .filter(key => !EXCLUDE_FIELDS.has(key))
      .filter(key => {
        // Only include fields that have at least 2 distinct values and aren't all unique
        const values = new Set();
        for (const d of data) {
          if (d[key] != null && d[key] !== '') values.add(String(d[key]));
          if (values.size > 500) break; // Too many unique values, skip
        }
        return values.size >= 2 && values.size <= 500;
      })
      .map(key => ({
        key,
        label: FIELD_LABELS[key] || key.replace(/([A-Z])/g, ' $1').replace(/^./, s => s.toUpperCase()).trim(),
        dataKey: key,
      }))
      .sort((a, b) => a.label.localeCompare(b.label));
  }, [data]);

  // Reset filter value when field changes
  const handleFilterFieldChange = useCallback((newField) => {
    setFilterField(newField);
    setFilterValue('');
  }, []);

  // Keyboard shortcuts
  useEffect(() => {
    const handler = (e) => {
      if (e.ctrlKey && e.key === 'z') {
        e.preventDefault();
        annotations.undo();
      }
      if (e.key === 'Escape') {
        annotations.setActiveBrush(null);
      }
      // Number keys 1-6 for palette
      const num = parseInt(e.key);
      if (num >= 1 && num <= annotations.palette.length && !e.ctrlKey && !e.altKey) {
        const target = e.target;
        if (target.tagName === 'INPUT' || target.tagName === 'SELECT' || target.tagName === 'TEXTAREA') return;
        annotations.setActiveBrush(annotations.palette[num - 1].key);
      }
      if (e.key === '0') {
        const target = e.target;
        if (target.tagName === 'INPUT' || target.tagName === 'SELECT' || target.tagName === 'TEXTAREA') return;
        annotations.setActiveBrush('clear');
      }
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [annotations]);

  // Extract unique values for the selected filter field
  const filterOptions = useMemo(() => {
    const field = filterFields.find(f => f.key === filterField);
    if (!field) return [];
    const values = new Set();
    data.forEach(d => {
      const val = d[field.dataKey];
      if (val) values.add(val);
    });
    return [...values].sort();
  }, [data, filterField]);

  // Filter data by selected field/value and text search
  const filteredData = useMemo(() => {
    let result = data;
    if (filterValue) {
      const field = filterFields.find(f => f.key === filterField);
      if (field) {
        result = result.filter(d => d[field.dataKey] === filterValue);
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
    return result;
  }, [data, filterField, filterValue, filterText]);

  // Build matrix data structures
  const { rawUsers, groups, memberships } = useMemo(() => {
    const userMap = new Map();
    const groupMap = new Map();
    const membershipMap = new Map();

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
        });
      }

      // Memberships
      const key = `${d.groupId}|${d.memberId}`;
      if (!membershipMap.has(key)) {
        membershipMap.set(key, new Set());
      }
      membershipMap.get(key).add(d.membershipType);
    });

    // Sort users by job title then name for initial default order
    const rawUsers = [...userMap.values()].sort((a, b) => {
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

    return { rawUsers, groups, memberships: membershipMap };
  }, [filteredData]);

  // Apply custom column order
  const users = useMemo(
    () => colOrderHook.getOrderedUsers(rawUsers),
    [rawUsers, colOrderHook.getOrderedUsers]
  );

  // Apply custom row order
  const orderedGroups = useMemo(
    () => rowOrderHook.getOrderedGroups(groups),
    [groups, rowOrderHook.getOrderedGroups]
  );

  const groupIds = useMemo(() => orderedGroups.map(g => g.id), [orderedGroups]);
  const userIds = useMemo(() => users.map(u => u.id), [users]);

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

  // Column DnD callback
  const handleColumnDragEnd = useCallback((newUserIds) => {
    colOrderHook.updateOrder(newUserIds);
  }, [colOrderHook]);

  // Sort rows by member count descending (clears any custom drag order)
  const handleSortByCount = useCallback(() => {
    const sorted = [...orderedGroups].sort((a, b) => b.memberCount - a.memberCount);
    rowOrderHook.updateOrder(sorted.map(g => g.id));
  }, [orderedGroups, rowOrderHook]);

  // Cell click handlers
  const handleCellClick = useCallback((cellKey) => {
    annotations.annotateCell(cellKey);
  }, [annotations]);

  const handleCellShiftClick = useCallback((cellKey) => {
    const lastKey = annotations.lastClickedCell.current;
    if (lastKey) {
      annotations.annotateRange(lastKey, cellKey, groupIds, userIds);
    } else {
      annotations.annotateCell(cellKey);
    }
  }, [annotations, groupIds, userIds]);

  const stats = {
    users: users.length,
    groups: orderedGroups.length,
    memberships: memberships.size,
  };

  // Number of info columns (drag handle + category + group name)
  const infoColumnCount = 3;

  return (
    <div className="flex flex-col gap-3">
      <MatrixToolbar
        filterFields={filterFields}
        filterField={filterField}
        setFilterField={handleFilterFieldChange}
        filterOptions={filterOptions}
        filterValue={filterValue}
        setFilterValue={setFilterValue}
        filterText={filterText}
        setFilterText={setFilterText}
        palette={annotations.palette}
        activeBrush={annotations.activeBrush}
        setActiveBrush={annotations.setActiveBrush}
        onUpdatePaletteLabel={annotations.updatePaletteLabel}
        onUndo={annotations.undo}
        onClearAll={annotations.clearAll}
        onExport={annotations.exportAnnotations}
        onImport={annotations.importAnnotations}
        onResetRowOrder={rowOrderHook.resetOrder}
        onResetColumnOrder={colOrderHook.resetOrder}
        hasCustomRowOrder={rowOrderHook.hasCustomOrder}
        hasCustomColumnOrder={colOrderHook.hasCustomOrder}
        stats={stats}
      />

      {users.length === 0 || orderedGroups.length === 0 ? (
        <div className="text-center text-gray-500 py-12">
          {filterValue
            ? `No data found for "${filterValue}". Select a different filter value.`
            : 'No permission data available. Select a filter to narrow down the view.'}
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
                userIds={userIds}
                infoColumnCount={infoColumnCount}
                onColumnDragEnd={handleColumnDragEnd}
                onSortByCount={handleSortByCount}
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
                      annotations={annotations.cells}
                      activeBrush={annotations.activeBrush}
                      palette={annotations.palette}
                      onCellClick={handleCellClick}
                      onCellShiftClick={handleCellShiftClick}
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
