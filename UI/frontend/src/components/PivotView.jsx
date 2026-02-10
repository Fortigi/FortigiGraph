import { useMemo } from 'react';
import PivotTableUI from 'react-pivottable/PivotTableUI';
import TableRenderers from 'react-pivottable/TableRenderers';
import 'react-pivottable/pivottable.css';
import { useState } from 'react';

export default function PivotView({ data }) {
  const [pivotState, setPivotState] = useState({
    rows: ['department'],
    cols: ['groupDisplayName'],
    vals: ['memberId'],
    aggregatorName: 'Count Unique Values',
    rendererName: 'Heatmap',
  });

  // PivotTable.js expects plain arrays of objects
  const pivotData = useMemo(() => {
    return data.map(row => ({
      User: row.memberDisplayName,
      UPN: row.memberUPN,
      Department: row.department,
      'Job Title': row.jobTitle,
      Group: row.groupDisplayName,
      'Membership Type': row.membershipType,
      // Hidden field used for counting
      memberId: row.memberId,
    }));
  }, [data]);

  return (
    <div className="overflow-auto max-h-[calc(100vh-220px)]">
      <PivotTableUI
        data={pivotData}
        onChange={s => setPivotState(s)}
        renderers={TableRenderers}
        {...pivotState}
        // Map to friendly field names for the pivot UI
        rows={pivotState.rows?.map(r => {
          const map = { department: 'Department', groupDisplayName: 'Group', membershipType: 'Membership Type', jobTitle: 'Job Title', memberDisplayName: 'User' };
          return map[r] || r;
        })}
        cols={pivotState.cols?.map(c => {
          const map = { department: 'Department', groupDisplayName: 'Group', membershipType: 'Membership Type', jobTitle: 'Job Title', memberDisplayName: 'User' };
          return map[c] || c;
        })}
        hiddenFromDragDrop={['memberId']}
      />
    </div>
  );
}
