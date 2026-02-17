import { useSortable } from '@dnd-kit/sortable';
import { CSS } from '@dnd-kit/utilities';
import MatrixCell from './MatrixCell';
import { getAccessPackageColor } from './MatrixColumnHeaders';

export default function MatrixGroupRow({
  group,
  users,
  totalUsers,
  memberships,
  managedMap,
  managedApMap,
  apIdToIndex,
  accessPackages = [],
  apGroupMap,
}) {
  const {
    attributes,
    listeners,
    setNodeRef,
    transform,
    transition,
    isDragging,
  } = useSortable({ id: group.id });

  const style = {
    transform: CSS.Transform.toString(transform),
    transition,
    opacity: isDragging ? 0.5 : 1,
  };

  const memberCount = group.memberCount;
  const pct = totalUsers > 0 ? Math.round((memberCount / totalUsers) * 100) : 0;

  return (
    <tr ref={setNodeRef} style={style} className="hover:bg-gray-50/30">
      {/* Drag handle */}
      <td
        className="sticky left-0 z-10 bg-white border-r border-b border-gray-200 px-1 py-0 text-center cursor-grab active:cursor-grabbing"
        style={{ minWidth: '24px' }}
        {...attributes}
        {...listeners}
      >
        <span className="text-gray-300 text-xs select-none">&#x2630;</span>
      </td>

      {/* Group info columns - sticky left */}
      <td
        className="sticky bg-white border-r border-b border-gray-200 px-2 py-0.5 text-xs text-gray-600 whitespace-nowrap"
        style={{ left: '24px', minWidth: '100px', maxWidth: '100px', zIndex: 10 }}
        title={group.category}
      >
        {group.category}
      </td>
      <td
        className="sticky bg-white border-r border-b border-gray-200 px-2 py-0.5 text-xs text-gray-900 font-medium"
        style={{ left: '124px', minWidth: '250px', maxWidth: '250px', zIndex: 10 }}
        title={group.displayName}
      >
        <div className="truncate">{group.displayName}</div>
      </td>

      {/* Intersection cells */}
      {users.map(user => {
        const cellKey = `${group.id}|${user.id}`;
        const managed = managedMap?.has(cellKey);
        // Look up which access packages manage this cell (all keys/IDs normalized to lowercase)
        const cellKeyLower = `${group.id.toLowerCase()}|${user.id.toLowerCase()}`;
        const apIds = managed ? managedApMap?.get(cellKeyLower) : null;
        let apColor = null;
        let apCount = 0;
        let apNames = null;
        if (apIds && apIds.length > 0) {
          apCount = apIds.length;
          const firstIdx = apIdToIndex?.get(apIds[0]);
          if (firstIdx != null) apColor = getAccessPackageColor(firstIdx);
          apNames = apIds.map(id => {
            const ap = accessPackages.find(a => a.id.toLowerCase() === id);
            return ap ? ap.displayName : id;
          });
        }
        return (
          <MatrixCell
            key={cellKey}
            cellKey={cellKey}
            membershipTypes={memberships.get(cellKey)}
            managed={managed}
            apColor={apColor}
            apCount={apCount}
            apNames={apNames}
          />
        );
      })}

      {/* Access Package cells (SOLL) */}
      {accessPackages.map((ap, idx) => {
        const apKey = `${group.id}|${ap.id}`;
        const roleName = apGroupMap?.get(apKey);
        const hasMapping = !!roleName;
        return (
          <td
            key={ap.id}
            className={`px-0 py-0 text-center border-r border-b border-gray-100 ${idx === 0 ? 'border-l-2 border-l-indigo-300' : ''}`}
            style={{
              backgroundColor: hasMapping ? getAccessPackageColor(idx) : undefined,
              minWidth: '24px',
              width: '24px',
              height: '24px',
            }}
            title={hasMapping ? `${ap.displayName} (${roleName})` : undefined}
          >
            {hasMapping && (
              <span className="text-[9px] font-bold text-gray-700">
                {roleName === 'Owner' ? 'O' : 'M'}
              </span>
            )}
          </td>
        );
      })}

      {/* Right-side metadata */}
      <td className="border-l-2 border-b border-gray-200 px-2 py-0.5 text-xs text-gray-600 text-center"
          style={{ minWidth: '40px' }}>
        {memberCount}
      </td>
      <td className="border-b border-gray-200 px-2 py-0.5 text-xs text-gray-500 text-center"
          style={{ minWidth: '45px' }}>
        <span style={{ color: pct === 100 ? '#166534' : pct >= 75 ? '#854d0e' : undefined }}>
          {pct}%
        </span>
      </td>
      <td className="border-b border-gray-200 px-2 py-0.5 text-xs text-gray-500"
          style={{ minWidth: '60px' }}
          title={group.groupType}>
        {group.groupType}
      </td>
      <td className="border-b border-gray-200 px-2 py-0.5 text-xs text-gray-400 max-w-[200px]"
          title={group.description}>
        <div className="truncate">{group.description}</div>
      </td>
    </tr>
  );
}
