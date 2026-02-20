import { memo } from 'react';

const TYPE_INDICATORS = {
  Direct:   { letter: 'D', bg: '#166534', text: '#fff' },
  Indirect: { letter: 'I', bg: '#1e40af', text: '#fff' },
  Eligible: { letter: 'E', bg: '#854d0e', text: '#fff' },
  Owner:    { letter: 'O', bg: '#9d174d', text: '#fff' },
};

function MatrixCell({ cellKey, membershipTypes, managed, apColor, apCount, apNames }) {
  const hasMembership = membershipTypes && membershipTypes.size > 0;

  // Background: AP color for managed cells (if known), fallback blue for managed, green for unmanaged
  let bgColor;
  if (hasMembership) {
    if (managed && apColor) {
      bgColor = apColor;
    } else if (managed) {
      bgColor = '#dbeafe';
    } else {
      bgColor = '#dcfce7';
    }
  }

  // Tooltip
  let title;
  if (hasMembership) {
    const types = [...membershipTypes].join(', ');
    if (apNames && apNames.length > 0) {
      title = `${types}\nManaged by: ${apNames.join(', ')}`;
    } else if (managed) {
      title = `${types} (managed by access package)`;
    } else {
      title = types;
    }
  }

  return (
    <td
      className="px-0 py-0 text-center border-r border-b border-gray-100"
      style={{
        backgroundColor: bgColor,
        minWidth: '24px',
        width: '24px',
        height: '24px',
        position: apCount > 1 ? 'relative' : undefined,
      }}
      title={title}
    >
      {hasMembership && (
        <>
          {[...membershipTypes].map(type => {
            const ind = TYPE_INDICATORS[type];
            return ind ? (
              <span
                key={type}
                className={`inline-block rounded-sm text-center font-bold ${membershipTypes.size === 1 ? 'w-4 h-4 text-[9px] leading-4' : 'w-[9px] h-[14px] text-[7px] leading-[14px]'}`}
                style={{ backgroundColor: ind.bg, color: ind.text }}
              >
                {ind.letter}
              </span>
            ) : (
              <span key={type} className="text-[7px] font-bold text-green-800">?</span>
            );
          })}
        </>
      )}
      {apCount > 1 && (
        <span
          className="absolute -top-1 -right-1 flex items-center justify-center w-3 h-3 rounded-full text-[7px] font-bold leading-none bg-white text-gray-700 border border-gray-300 shadow-sm"
          style={{ zIndex: 1 }}
        >
          {apCount}
        </span>
      )}
    </td>
  );
}

export default memo(MatrixCell, (prev, next) => {
  return (
    prev.membershipTypes === next.membershipTypes &&
    prev.managed === next.managed &&
    prev.apColor === next.apColor &&
    prev.apCount === next.apCount
  );
});
