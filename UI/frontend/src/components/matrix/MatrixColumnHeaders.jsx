import { useState, useRef, useEffect } from 'react';

const AP_COLORS = [
  '#fde68a', '#a7f3d0', '#bfdbfe', '#ddd6fe', '#fbcfe8',
  '#fed7aa', '#99f6e4', '#c7d2fe', '#fecdd3', '#d9f99d',
  '#fef08a', '#a5f3fc', '#c4b5fd', '#fda4af', '#bef264',
];

export function getAccessPackageColor(index) {
  return AP_COLORS[index % AP_COLORS.length];
}

export const BLANK_TAG = '__blank__';

export default function MatrixColumnHeaders({ users, infoColumnCount, onSortByCount, accessPackages = [], uniqueGroupTypes = [], groupTypeFilter, onGroupTypeFilterChange, uniqueGroupTags = [], groupTagFilter, onGroupTagFilterChange, hasGroupsWithoutTags = false }) {
  const [typeFilterOpen, setTypeFilterOpen] = useState(false);
  const [tagFilterOpen, setTagFilterOpen] = useState(false);
  const typeFilterRef = useRef(null);
  const tagFilterRef = useRef(null);

  // Close dropdowns when clicking outside
  useEffect(() => {
    if (!typeFilterOpen && !tagFilterOpen) return;
    const handler = (e) => {
      if (typeFilterOpen && typeFilterRef.current && !typeFilterRef.current.contains(e.target)) {
        setTypeFilterOpen(false);
      }
      if (tagFilterOpen && tagFilterRef.current && !tagFilterRef.current.contains(e.target)) {
        setTagFilterOpen(false);
      }
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, [typeFilterOpen, tagFilterOpen]);

  const isTypeFiltered = groupTypeFilter && groupTypeFilter.size > 0;

  const toggleTypeValue = (val) => {
    if (!groupTypeFilter) {
      // First selection: select only this one
      onGroupTypeFilterChange(new Set([val]));
    } else if (groupTypeFilter.has(val)) {
      const next = new Set(groupTypeFilter);
      next.delete(val);
      onGroupTypeFilterChange(next.size === 0 ? null : next);
    } else {
      onGroupTypeFilterChange(new Set([...groupTypeFilter, val]));
    }
  };

  const selectAllTypes = () => onGroupTypeFilterChange(null);

  const isTagFiltered = groupTagFilter && groupTagFilter.size > 0;

  const toggleTagValue = (val) => {
    if (!groupTagFilter) {
      onGroupTagFilterChange(new Set([val]));
    } else if (groupTagFilter.has(val)) {
      const next = new Set(groupTagFilter);
      next.delete(val);
      onGroupTagFilterChange(next.size === 0 ? null : next);
    } else {
      onGroupTagFilterChange(new Set([...groupTagFilter, val]));
    }
  };

  const selectAllTags = () => onGroupTagFilterChange(null);

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
          </div>
        </th>

        {jobTitleSpans.map((span, idx) => (
          <th
            key={idx}
            colSpan={span.span}
            className="border-b border-r border-gray-300 px-0 py-0 text-center bg-gray-100"
            style={{
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

        {/* Access Package columns (SOLL) */}
        {accessPackages.length > 0 && (
          <th className="border-b border-l-2 border-gray-300 bg-indigo-50 px-1 py-1 text-[10px] text-indigo-700 font-bold"
              colSpan={accessPackages.length}
              style={{ height: '120px' }}>
            <div
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
              Access Packages (SOLL)
            </div>
          </th>
        )}

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
        <th className={`border-b border-gray-300 px-1 py-1 text-[10px] font-medium cursor-pointer select-none relative ${isTypeFiltered ? 'bg-blue-100 text-blue-700' : 'bg-gray-100 text-gray-500 hover:bg-gray-200'}`}
            style={{ minWidth: '60px' }}
            ref={typeFilterRef}>
          <div
            style={{ writingMode: 'vertical-lr', transform: 'rotate(180deg)' }}
            onClick={() => setTypeFilterOpen(prev => !prev)}
          >
            Type {isTypeFiltered ? '\u25BC' : '\u25BD'}
          </div>
          {typeFilterOpen && (
            <div
              className="absolute bg-white border border-gray-300 rounded shadow-lg z-50 text-left"
              style={{ top: '100%', right: 0, minWidth: '200px', writingMode: 'horizontal-tb' }}
              onClick={e => e.stopPropagation()}
            >
              <div className="px-3 py-1.5 border-b border-gray-200">
                <label className="flex items-center gap-2 cursor-pointer text-xs font-medium text-gray-700">
                  <input
                    type="checkbox"
                    checked={!isTypeFiltered}
                    onChange={selectAllTypes}
                    className="rounded"
                  />
                  (Select All)
                </label>
              </div>
              <div className="max-h-48 overflow-auto py-1">
                {uniqueGroupTypes.map(t => (
                  <label key={t} className="flex items-center gap-2 px-3 py-1 cursor-pointer hover:bg-gray-50 text-xs text-gray-700">
                    <input
                      type="checkbox"
                      checked={!groupTypeFilter || groupTypeFilter.has(t)}
                      onChange={() => toggleTypeValue(t)}
                      className="rounded"
                    />
                    {t}
                  </label>
                ))}
              </div>
              {isTypeFiltered && (
                <div className="px-3 py-1.5 border-t border-gray-200">
                  <button
                    onClick={selectAllTypes}
                    className="text-xs text-blue-600 hover:text-blue-800"
                  >
                    Clear filter
                  </button>
                </div>
              )}
            </div>
          )}
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
        <th className={`sticky z-30 border-b border-r border-gray-300 px-2 py-1 text-xs text-left font-medium cursor-pointer select-none relative ${isTagFiltered ? 'bg-blue-100 text-blue-700' : 'bg-gray-100 text-gray-600 hover:bg-gray-200'}`}
            style={{ left: '24px', minWidth: '100px' }}
            ref={tagFilterRef}>
          <div onClick={() => setTagFilterOpen(prev => !prev)}>
            Tags {isTagFiltered ? '\u25BC' : '\u25BD'}
          </div>
          {tagFilterOpen && (
            <div
              className="absolute bg-white border border-gray-300 rounded shadow-lg z-50 text-left"
              style={{ top: '100%', left: 0, minWidth: '200px' }}
              onClick={e => e.stopPropagation()}
            >
              <div className="px-3 py-1.5 border-b border-gray-200">
                <label className="flex items-center gap-2 cursor-pointer text-xs font-medium text-gray-700">
                  <input
                    type="checkbox"
                    checked={!isTagFiltered}
                    onChange={selectAllTags}
                    className="rounded"
                  />
                  (Select All)
                </label>
              </div>
              <div className="max-h-48 overflow-auto py-1">
                {hasGroupsWithoutTags && (
                  <label className="flex items-center gap-2 px-3 py-1 cursor-pointer hover:bg-gray-50 text-xs text-gray-500 italic">
                    <input
                      type="checkbox"
                      checked={!groupTagFilter || groupTagFilter.has(BLANK_TAG)}
                      onChange={() => toggleTagValue(BLANK_TAG)}
                      className="rounded"
                    />
                    (Blank)
                  </label>
                )}
                {uniqueGroupTags.map(t => (
                  <label key={t.name} className="flex items-center gap-2 px-3 py-1 cursor-pointer hover:bg-gray-50 text-xs text-gray-700">
                    <input
                      type="checkbox"
                      checked={!groupTagFilter || groupTagFilter.has(t.name)}
                      onChange={() => toggleTagValue(t.name)}
                      className="rounded"
                    />
                    <span
                      className="inline-block w-2.5 h-2.5 rounded-full border"
                      style={{ backgroundColor: t.color + '20', borderColor: t.color }}
                    />
                    {t.name}
                  </label>
                ))}
              </div>
              {isTagFiltered && (
                <div className="px-3 py-1.5 border-t border-gray-200">
                  <button
                    onClick={selectAllTags}
                    className="text-xs text-blue-600 hover:text-blue-800"
                  >
                    Clear filter
                  </button>
                </div>
              )}
            </div>
          )}
        </th>
        <th className="sticky z-30 bg-gray-100 border-b border-r border-gray-300 px-2 py-1 text-xs text-gray-600 text-left font-medium"
            style={{ left: '124px', minWidth: '250px' }}>
          Group Name
        </th>

        {users.map(user => (
          <th
            key={user.id}
            className="border-b border-r border-gray-200 px-0 py-0 text-center bg-gray-100"
            style={{
              height: '100px',
              width: '24px',
              minWidth: '24px',
            }}
            title={`${user.displayName}\n${user.jobTitle || ''}\n${user.department || ''}`}
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
        ))}

        {/* Access Package name headers */}
        {accessPackages.map((ap, idx) => (
          <th
            key={ap.id}
            className={`border-b border-r border-gray-200 px-0 py-0 text-center ${idx === 0 ? 'border-l-2 border-l-indigo-300' : ''}`}
            style={{
              backgroundColor: getAccessPackageColor(idx),
              height: '100px',
              width: '24px',
              minWidth: '24px',
            }}
            title={`${ap.displayName}\nCatalog: ${ap.catalogName || ''}`}
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
              {ap.displayName}
            </div>
          </th>
        ))}

        {/* Right metadata column headers row 2 */}
        <th className="border-b border-l-2 border-gray-300 bg-gray-100" />
        <th className="border-b border-gray-300 bg-gray-100" />
        <th className="border-b border-gray-300 bg-gray-100" />
        <th className="border-b border-gray-300 bg-gray-100" />
      </tr>
    </thead>
  );
}
