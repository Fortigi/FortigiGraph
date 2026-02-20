import { useSortable } from '@dnd-kit/sortable';
import { CSS } from '@dnd-kit/utilities';
import MatrixCell from './MatrixCell';
import { getAccessPackageColor } from './MatrixColumnHeaders';

// Map AP resource role names to the same badge style used in user/group cells.
// roleDisplayName from Graph can be "Member", "Owner", "Eligible Member", etc.
const BADGE_DIRECT   = { letter: 'D', bg: '#166534', text: '#fff' };
const BADGE_OWNER    = { letter: 'O', bg: '#9d174d', text: '#fff' };
const BADGE_ELIGIBLE = { letter: 'E', bg: '#854d0e', text: '#fff' };

function getRoleBadge(roleName) {
  const lower = (roleName || '').toLowerCase();
  if (lower.includes('owner')) return BADGE_OWNER;
  if (lower.includes('eligible')) return BADGE_ELIGIBLE;
  return BADGE_DIRECT;
}

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
  onOpenDetail,
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
        style={{ left: '124px', minWidth: '275px', maxWidth: '275px', zIndex: 10 }}
        title={group.displayName}
      >
        <div className="truncate cursor-pointer hover:text-blue-600"
          onClick={() => onOpenDetail?.('group', group.realGroupId || group.id, group.displayName)}>
          {group.displayName}
        </div>
      </td>

      {/* Intersection cells */}
      {users.map(user => {
        const cellKey = `${group.id}|${user.id}`;
        const managed = managedMap?.has(cellKey);
        // Look up which access packages manage this cell (all keys/IDs normalized to lowercase)
        // For owner rows, use realGroupId since managedApMap uses real group IDs from backend
        const lookupGroupId = group.realGroupId || group.id;
        const cellKeyLower = `${lookupGroupId.toLowerCase()}|${user.id.toLowerCase()}`;
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
        // For owner rows, look up using realGroupId (AP data uses real group IDs)
        const lookupGid = (group.realGroupId || group.id).toUpperCase();
        const apKey = `${lookupGid}|${ap.id}`;
        const roleName = apGroupMap?.get(apKey);
        // Owner rows only show AP cells where the role is Owner;
        // regular rows only show non-Owner roles
        const isOwnerRow = !!group.realGroupId;
        const roleIsOwner = (roleName || '').toLowerCase().includes('owner');
        const hasMapping = !!roleName && (isOwnerRow ? roleIsOwner : !roleIsOwner);
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
              const badge = getRoleBadge(roleName);
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
