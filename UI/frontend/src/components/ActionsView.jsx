import { useMemo, useState } from 'react';

function getStorageKey(department) {
  return `fgraph-annotations-${department || 'all'}`;
}

function loadAllAnnotations() {
  const results = [];
  try {
    for (let i = 0; i < localStorage.length; i++) {
      const key = localStorage.key(i);
      if (key && key.startsWith('fgraph-annotations-')) {
        const raw = JSON.parse(localStorage.getItem(key));
        if (raw && raw.cells) {
          results.push(raw);
        }
      }
    }
  } catch {}
  return results;
}

export default function ActionsView({ data }) {
  const [filterAction, setFilterAction] = useState('all');
  const [filterDept, setFilterDept] = useState('');

  // Build lookup maps from API data
  const { userMap, groupMap, membershipSet, departments } = useMemo(() => {
    const userMap = new Map();
    const groupMap = new Map();
    const membershipSet = new Set();
    const depts = new Set();

    data.forEach(d => {
      if (d.memberId) {
        userMap.set(d.memberId, {
          displayName: d.memberDisplayName || d.memberId,
          upn: d.memberUPN || '',
          department: d.department || '',
          jobTitle: d.jobTitle || '',
        });
        if (d.department) depts.add(d.department);
      }
      if (d.groupId) {
        groupMap.set(d.groupId, {
          displayName: d.groupDisplayName || d.groupId,
        });
      }
      if (d.groupId && d.memberId) {
        membershipSet.add(`${d.groupId}|${d.memberId}`);
      }
    });

    return { userMap, groupMap, membershipSet, departments: [...depts].sort() };
  }, [data]);

  // Build actions list from all annotations
  const actions = useMemo(() => {
    const allAnnotations = loadAllAnnotations();
    const actionList = [];

    for (const annotationData of allAnnotations) {
      const palette = annotationData.palette || [];
      const dept = annotationData.department || '';

      for (const [cellKey, brushKey] of Object.entries(annotationData.cells)) {
        const paletteEntry = palette.find(p => p.key === brushKey);
        if (!paletteEntry || !paletteEntry.marker) continue; // Only + and - actions

        const [groupId, userId] = cellKey.split('|');
        const user = userMap.get(userId);
        const group = groupMap.get(groupId);
        const hasMembership = membershipSet.has(cellKey);

        actionList.push({
          cellKey,
          action: paletteEntry.marker === '+' ? 'Add' : 'Remove',
          brushLabel: paletteEntry.label,
          brushColor: paletteEntry.hex,
          groupId,
          userId,
          groupName: group?.displayName || groupId,
          userName: user?.displayName || userId,
          userUPN: user?.upn || '',
          userDepartment: user?.department || dept,
          userJobTitle: user?.jobTitle || '',
          currentlyAssigned: hasMembership,
          department: dept,
        });
      }
    }

    // Sort: Adds first, then Removes, then by user, then by group
    actionList.sort((a, b) => {
      if (a.action !== b.action) return a.action === 'Add' ? -1 : 1;
      const userCmp = a.userName.localeCompare(b.userName);
      if (userCmp !== 0) return userCmp;
      return a.groupName.localeCompare(b.groupName);
    });

    return actionList;
  }, [userMap, groupMap, membershipSet]);

  // Filter actions
  const filteredActions = useMemo(() => {
    let result = actions;
    if (filterAction !== 'all') {
      result = result.filter(a => a.action === filterAction);
    }
    if (filterDept) {
      result = result.filter(a => a.userDepartment === filterDept || a.department === filterDept);
    }
    return result;
  }, [actions, filterAction, filterDept]);

  // Summary stats
  const addCount = filteredActions.filter(a => a.action === 'Add').length;
  const removeCount = filteredActions.filter(a => a.action === 'Remove').length;
  const alreadyCorrect = filteredActions.filter(a =>
    (a.action === 'Add' && a.currentlyAssigned) ||
    (a.action === 'Remove' && !a.currentlyAssigned)
  ).length;

  return (
    <div className="flex flex-col gap-4">
      {/* Toolbar */}
      <div className="flex flex-wrap items-center gap-4 text-sm">
        <div className="flex items-center gap-2">
          <label className="font-medium text-gray-700">Action:</label>
          <select
            value={filterAction}
            onChange={e => setFilterAction(e.target.value)}
            className="px-2 py-1 border border-gray-300 rounded text-sm"
          >
            <option value="all">All actions</option>
            <option value="Add">Add only</option>
            <option value="Remove">Remove only</option>
          </select>
        </div>
        <div className="flex items-center gap-2">
          <label className="font-medium text-gray-700">Department:</label>
          <select
            value={filterDept}
            onChange={e => setFilterDept(e.target.value)}
            className="px-2 py-1 border border-gray-300 rounded text-sm"
          >
            <option value="">All departments</option>
            {departments.map(d => (
              <option key={d} value={d}>{d}</option>
            ))}
          </select>
        </div>
        <div className="flex items-center gap-3 text-xs text-gray-500">
          <span className="px-2 py-0.5 bg-blue-50 text-blue-700 rounded font-medium">
            +{addCount} to add
          </span>
          <span className="px-2 py-0.5 bg-red-50 text-red-700 rounded font-medium">
            -{removeCount} to remove
          </span>
          {alreadyCorrect > 0 && (
            <span className="text-amber-600" title="Actions where the current state already matches the desired state">
              {alreadyCorrect} already in desired state
            </span>
          )}
        </div>
      </div>

      {/* Table */}
      {filteredActions.length === 0 ? (
        <div className="text-center text-gray-500 py-12">
          <div className="text-lg font-medium mb-2">No pending actions</div>
          <div className="text-sm">
            Use the <span className="font-medium text-blue-600">+ Add</span> and{' '}
            <span className="font-medium text-red-600">- Remove</span> brushes in the Matrix View
            to mark permissions that need to be changed.
          </div>
        </div>
      ) : (
        <div className="border border-gray-200 rounded-lg overflow-auto max-h-[calc(100vh-250px)]">
          <table className="min-w-full divide-y divide-gray-200">
            <thead className="bg-gray-50 sticky top-0">
              <tr>
                <th className="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider w-20">
                  Action
                </th>
                <th className="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  User
                </th>
                <th className="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  UPN
                </th>
                <th className="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Department
                </th>
                <th className="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Group
                </th>
                <th className="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider w-28">
                  Current State
                </th>
              </tr>
            </thead>
            <tbody className="bg-white divide-y divide-gray-200">
              {filteredActions.map((action) => {
                const isRedundant =
                  (action.action === 'Add' && action.currentlyAssigned) ||
                  (action.action === 'Remove' && !action.currentlyAssigned);

                return (
                  <tr
                    key={action.cellKey}
                    className={isRedundant ? 'opacity-50' : 'hover:bg-gray-50'}
                  >
                    <td className="px-4 py-2 whitespace-nowrap">
                      <span
                        className={`inline-flex items-center px-2 py-0.5 rounded text-xs font-bold ${
                          action.action === 'Add'
                            ? 'bg-blue-100 text-blue-800'
                            : 'bg-red-100 text-red-800'
                        }`}
                      >
                        {action.action === 'Add' ? '+' : '-'} {action.action}
                      </span>
                    </td>
                    <td className="px-4 py-2 text-sm text-gray-900 whitespace-nowrap">
                      {action.userName}
                    </td>
                    <td className="px-4 py-2 text-sm text-gray-500 whitespace-nowrap">
                      {action.userUPN}
                    </td>
                    <td className="px-4 py-2 text-sm text-gray-500 whitespace-nowrap">
                      {action.userDepartment}
                    </td>
                    <td className="px-4 py-2 text-sm text-gray-900">
                      {action.groupName}
                    </td>
                    <td className="px-4 py-2 whitespace-nowrap">
                      {isRedundant ? (
                        <span className="text-xs text-amber-600 font-medium">
                          Already {action.action === 'Add' ? 'assigned' : 'not assigned'}
                        </span>
                      ) : (
                        <span className={`text-xs font-medium ${
                          action.currentlyAssigned ? 'text-green-700' : 'text-gray-400'
                        }`}>
                          {action.currentlyAssigned ? 'Assigned' : 'Not assigned'}
                        </span>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
