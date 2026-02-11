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

export default function MatrixColumnHeaders({ users, infoColumnCount }) {
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
            <div>Drag rows to reorder</div>
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

        {/* Right metadata column headers */}
        <th className="border-b border-l-2 border-gray-300 bg-gray-100 px-1 py-1 text-[10px] text-gray-500 font-medium"
            style={{ minWidth: '40px' }}>
          <div style={{ writingMode: 'vertical-lr', transform: 'rotate(180deg)' }}>#</div>
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

      {/* Row 2: User names */}
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
          <th
            key={user.id}
            className="border-b border-r border-gray-200 px-0 py-0 text-center"
            style={{
              backgroundColor: getTeamColor(user.jobTitle),
              height: '100px',
              width: '24px',
              minWidth: '24px',
            }}
            title={`${user.displayName}\n${user.jobTitle || ''}\n${user.department || ''}`}
          >
            <div
              className="text-[10px] text-gray-700 font-medium"
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
        ))}

        {/* Right metadata column headers row 2 */}
        <th className="border-b border-l-2 border-gray-300 bg-gray-100" />
        <th className="border-b border-gray-300 bg-gray-100" />
        <th className="border-b border-gray-300 bg-gray-100" />
      </tr>
    </thead>
  );
}
