import { DndContext, closestCenter, PointerSensor, useSensor, useSensors } from '@dnd-kit/core';
import { SortableContext, horizontalListSortingStrategy, arrayMove, useSortable } from '@dnd-kit/sortable';
import { restrictToHorizontalAxis } from '@dnd-kit/modifiers';
import { CSS } from '@dnd-kit/utilities';

const TEAM_COLORS = [
  '#fde68a', '#a7f3d0', '#bfdbfe', '#ddd6fe', '#fbcfe8',
  '#fed7aa', '#99f6e4', '#c7d2fe', '#fecdd3', '#d9f99d',
  '#fef08a', '#a5f3fc', '#c4b5fd', '#fda4af', '#bef264',
];

function hashString(str) {
  let hash = 0;
  for (let i = 0; i < (str || '').length; i++) {
    hash = ((hash << 5) - hash + str.charCodeAt(i)) | 0;
  }
  return Math.abs(hash);
}

export function getTeamColor(jobTitle) {
  return TEAM_COLORS[hashString(jobTitle) % TEAM_COLORS.length];
}

function SortableUserHeader({ user }) {
  const {
    attributes,
    listeners,
    setNodeRef,
    transform,
    transition,
    isDragging,
  } = useSortable({ id: user.id });

  const style = {
    transform: CSS.Transform.toString(transform),
    transition,
    opacity: isDragging ? 0.5 : 1,
    backgroundColor: getTeamColor(user.jobTitle),
    height: '100px',
    width: '24px',
    minWidth: '24px',
    cursor: 'grab',
  };

  return (
    <th
      ref={setNodeRef}
      className="border-b border-r border-gray-200 px-0 py-0 text-center"
      style={style}
      title={`${user.displayName}\n${user.jobTitle || ''}\n${user.department || ''}\n(drag to reorder)`}
      {...attributes}
      {...listeners}
    >
      <div
        className="text-[10px] text-gray-700 font-medium select-none"
        style={{
          writingMode: 'vertical-lr',
          textOrientation: 'mixed',
          transform: 'rotate(180deg)',
          maxHeight: '95px',
          overflow: 'hidden',
          whiteSpace: 'nowrap',
          margin: '0 auto',
        }}
      >
        {user.displayName}
      </div>
    </th>
  );
}

export default function MatrixColumnHeaders({ users, userIds, infoColumnCount, onColumnDragEnd, onSortByCount }) {
  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 5 } })
  );

  const handleDragEnd = (event) => {
    const { active, over } = event;
    if (!over || active.id === over.id) return;
    const oldIndex = userIds.indexOf(active.id);
    const newIndex = userIds.indexOf(over.id);
    const newOrder = arrayMove(userIds, oldIndex, newIndex);
    onColumnDragEnd(newOrder);
  };

  // Group consecutive users by job title for merged headers
  const jobTitleSpans = [];
  let i = 0;
  while (i < users.length) {
    const title = users[i].jobTitle || '';
    let span = 1;
    while (i + span < users.length && (users[i + span].jobTitle || '') === title) {
      span++;
    }
    jobTitleSpans.push({ title, span, startIndex: i });
    i += span;
  }

  return (
    <thead className="sticky top-0 z-20">
      {/* Row 1: Job titles (merged cells) */}
      <tr>
        {/* Corner cells spanning info columns */}
        <th
          colSpan={infoColumnCount}
          className="sticky left-0 z-30 bg-gray-100 border-b border-r border-gray-300 px-2 py-1"
          style={{ minHeight: '120px' }}
        >
          <div className="text-xs text-gray-500 font-normal">
            <div>Drag rows or columns to reorder</div>
            <div>Click cells with brush to annotate</div>
            <div className="text-gray-400">Shift+click for range</div>
          </div>
        </th>

        {jobTitleSpans.map((span, idx) => (
          <th
            key={idx}
            colSpan={span.span}
            className="border-b border-r border-gray-300 px-0 py-0 text-center"
            style={{
              backgroundColor: getTeamColor(span.title),
              height: '120px',
              minWidth: `${span.span * 24}px`,
            }}
          >
            <div
              className="text-[10px] font-semibold text-gray-700"
              style={{
                writingMode: 'vertical-lr',
                textOrientation: 'mixed',
                transform: 'rotate(180deg)',
                maxHeight: '110px',
                overflow: 'hidden',
                whiteSpace: 'nowrap',
                margin: '0 auto',
              }}
            >
              {span.title || '(no title)'}
            </div>
          </th>
        ))}

        {/* Right metadata column headers - clickable to sort */}
        <th className="border-b border-l-2 border-gray-300 bg-gray-100 px-1 py-1 text-[10px] text-gray-500 font-medium cursor-pointer hover:bg-gray-200 select-none"
            style={{ minWidth: '40px' }}
            onClick={onSortByCount}
            title="Sort by member count (descending)">
          <div style={{ writingMode: 'vertical-lr', transform: 'rotate(180deg)' }}># &#x25BC;</div>
        </th>
        <th className="border-b border-gray-300 bg-gray-100 px-1 py-1 text-[10px] text-gray-500 font-medium cursor-pointer hover:bg-gray-200 select-none"
            style={{ minWidth: '45px' }}
            onClick={onSortByCount}
            title="Sort by percentage (descending)">
          <div style={{ writingMode: 'vertical-lr', transform: 'rotate(180deg)' }}>% &#x25BC;</div>
        </th>
        <th className="border-b border-gray-300 bg-gray-100 px-1 py-1 text-[10px] text-gray-500 font-medium"
            style={{ minWidth: '60px' }}>
          <div style={{ writingMode: 'vertical-lr', transform: 'rotate(180deg)' }}>Type</div>
        </th>
        <th className="border-b border-gray-300 bg-gray-100 px-1 py-1 text-[10px] text-gray-500 font-medium"
            style={{ minWidth: '200px' }}>
          <div style={{ writingMode: 'vertical-lr', transform: 'rotate(180deg)' }}>Description</div>
        </th>
      </tr>

      {/* Row 2: User names (draggable) */}
      <DndContext
        sensors={sensors}
        collisionDetection={closestCenter}
        onDragEnd={handleDragEnd}
        modifiers={[restrictToHorizontalAxis]}
      >
        <SortableContext items={userIds} strategy={horizontalListSortingStrategy}>
          <tr>
            {/* Corner cells for row info headers */}
            <th className="sticky left-0 z-30 bg-gray-100 border-b border-r border-gray-300 px-1 py-1 text-[10px] text-gray-500"
                style={{ minWidth: '24px' }}>
            </th>
            <th className="sticky z-30 bg-gray-100 border-b border-r border-gray-300 px-2 py-1 text-xs text-gray-600 text-left font-medium"
                style={{ left: '24px', minWidth: '100px' }}>
              Category
            </th>
            <th className="sticky z-30 bg-gray-100 border-b border-r border-gray-300 px-2 py-1 text-xs text-gray-600 text-left font-medium"
                style={{ left: '124px', minWidth: '250px' }}>
              Group Name
            </th>

            {users.map(user => (
              <SortableUserHeader key={user.id} user={user} />
            ))}

            {/* Right metadata column headers row 2 */}
            <th className="border-b border-l-2 border-gray-300 bg-gray-100" />
            <th className="border-b border-gray-300 bg-gray-100" />
            <th className="border-b border-gray-300 bg-gray-100" />
            <th className="border-b border-gray-300 bg-gray-100" />
          </tr>
        </SortableContext>
      </DndContext>
    </thead>
  );
}
