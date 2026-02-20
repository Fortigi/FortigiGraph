import { useSortable } from '@dnd-kit/sortable';
import { CSS } from '@dnd-kit/utilities';
import MatrixCell from './MatrixCell';
import { getAccessPackageColor } from './MatrixColumnHeaders';

// Map AP resource role names to the same badge style used in user/group cells
const ROLE_BADGE = {
  Member:          { letter: 'D', bg: '#166534', text: '#fff' },
  Owner:           { letter: 'O', bg: '#9d174d', text: '#fff' },
  EligibleMember:  { letter: 'E', bg: '#854d0e', text: '#fff' },
};

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

      {/* Tags column - sticky left */}
      <td
        className="sticky bg-white border-r border-b border-gray-200 px-1 py-0.5"
        style={{ left: '24px', minWidth: '100px', maxWidth: '100px', zIndex: 10 }}
      >
        <div className="flex flex-wrap gap-0.5">
          {(group.tags || []).map(t => (
            <span
              key={t.id}
              className="inline-block px-1 py-0 rounded-full text-[9px] font-medium border leading-tight"
              style={{ backgroundColor: t.color + '20', borderColor: t.color, color: t.color }}
              title={t.name}
            >
              {t.name}
            </span>
          ))}
        </div>
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
        const prevCat = idx > 0 ? (accessPackages[idx - 1].categoryName || null) : undefined;
        const curCat = ap.categoryName || null;
        const isCategoryBoundary = idx === 0 || prevCat !== curCat;
        return (
          <td
            key={ap.id}
            className={`px-0 py-0 text-center border-r border-b border-gray-100 ${idx === 0 ? 'border-l-2 border-l-indigo-300' : isCategoryBoundary ? 'border-l-2 border-l-gray-400' : ''}`}
            style={{
              backgroundColor: hasMapping ? getAccessPackageColor(idx) : undefined,
              minWidth: '24px',
              width: '24px',
              height: '24px',
            }}
            title={hasMapping ? `${ap.displayName} (${roleName})${ap.categoryName ? ' — Category: ' + ap.categoryName : ''}` : undefined}
          >
            {hasMapping && (() => {
              const badge = ROLE_BADGE[roleName] || ROLE_BADGE.Member;
              return (
                <span
                  className="inline-block w-4 h-4 rounded-sm text-center font-bold leading-4 text-[9px]"
                  style={{ backgroundColor: badge.bg, color: badge.text }}
                >
                  {badge.letter}
                </span>
              );
            })()}
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
      <td className="border-b border-gray-200 px-2 py-0.5 text-xs text-gray-400 max-w-[500px]"
          title={group.description}>
        <div className="truncate">{group.description}</div>
      </td>
    </tr>
  );
}
