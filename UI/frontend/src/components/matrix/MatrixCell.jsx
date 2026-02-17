import { memo } from 'react';

const TYPE_INDICATORS = {
  Direct:   { letter: 'D', bg: '#166534', text: '#fff' },
  Indirect: { letter: 'I', bg: '#1e40af', text: '#fff' },
  Eligible: { letter: 'E', bg: '#854d0e', text: '#fff' },
  Owner:    { letter: 'O', bg: '#9d174d', text: '#fff' },
};

function MatrixCell({ cellKey, membershipTypes, managed, annotation, activeBrush, palette, onClick, onShiftClick }) {
  const hasMembership = membershipTypes && membershipTypes.size > 0;
  const paletteEntry = annotation ? palette.find(p => p.key === annotation) : null;
  const annotationColor = paletteEntry?.hex || null;
  const marker = paletteEntry?.marker || null;

  const handleClick = (e) => {
    if (e.shiftKey) {
      onShiftClick(cellKey);
    } else {
      onClick(cellKey);
    }
  };

  return (
    <td
      className={`px-0 py-0 text-center border-r border-b border-gray-100 ${
        activeBrush ? 'cursor-crosshair' : ''
      }`}
      style={{
        backgroundColor: annotationColor || (hasMembership ? '#dcfce7' : undefined),
        minWidth: '24px',
        width: '24px',
        height: '24px',
        position: 'relative',
      }}
      onClick={handleClick}
      title={
        hasMembership
          ? [...membershipTypes].join(', ')
          : undefined
      }
    >
      {/* +/- marker from annotation */}
      {marker && (
        <span
          className="absolute font-black text-center"
          style={{
            fontSize: '16px',
            lineHeight: '24px',
            color: marker === '+' ? '#1e40af' : '#991b1b',
            inset: 0,
            zIndex: 1,
          }}
        >
          {marker}
        </span>
      )}
      {/* Membership type indicators */}
      {hasMembership && !marker && (
        <div className="flex items-center justify-center gap-px">
          {membershipTypes.size === 1 ? (
            (() => {
              const type = [...membershipTypes][0];
              const ind = TYPE_INDICATORS[type];
              return ind ? (
                <span
                  className="inline-block w-4 h-4 rounded-sm text-[9px] font-bold leading-4 text-center"
                  style={{ backgroundColor: ind.bg, color: managed ? '#dc2626' : ind.text }}
                >
                  {ind.letter}
                </span>
              ) : (
                <span className="text-[9px] font-bold text-green-800">1</span>
              );
            })()
          ) : (
            <span className="text-[9px] font-bold" style={{ color: managed ? '#dc2626' : '#166534' }}>
              {[...membershipTypes].map(t => TYPE_INDICATORS[t]?.letter || '?').join('')}
            </span>
          )}
        </div>
      )}
    </td>
  );
}

export default memo(MatrixCell, (prev, next) => {
  return (
    prev.annotation === next.annotation &&
    prev.activeBrush === next.activeBrush &&
    prev.membershipTypes === next.membershipTypes &&
    prev.managed === next.managed
  );
});
