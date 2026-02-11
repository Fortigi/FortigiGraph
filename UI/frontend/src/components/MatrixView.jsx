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

export default function MatrixView({ data }) {
  const [filterDept, setFilterDept] = useState('');
  const [filterText, setFilterText] = useState('');

  const annotations = useMatrixAnnotations(filterDept);
  const rowOrderHook = useMatrixRowOrder(filterDept);
  const colOrderHook = useMatrixColumnOrder(filterDept);

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

  // Extract unique departments
  const departments = useMemo(() => {
    const depts = new Set();
    data.forEach(d => { if (d.department) depts.add(d.department); });
    return [...depts].sort();
  }, [data]);

  // Filter data by department and text search
  const filteredData = useMemo(() => {
    let result = data;
    if (filterDept) {
      result = result.filter(d => d.department === filterDept);
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
  }, [data, filterDept, filterText]);

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
        departments={departments}
        filterDept={filterDept}
        setFilterDept={setFilterDept}
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
          {filterDept
            ? `No data found for department "${filterDept}". Select a different department.`
            : 'No permission data available.'}
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
