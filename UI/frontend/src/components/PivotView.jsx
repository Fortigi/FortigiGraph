import { useMemo, useState } from 'react';
import PivotTableUI from 'react-pivottable/PivotTableUI';
import TableRenderers from 'react-pivottable/TableRenderers';
import 'react-pivottable/pivottable.css';

export default function PivotView({ data }) {
  // Use friendly field names throughout - no mapping needed
  const [pivotState, setPivotState] = useState({
    rows: ['Department'],
    cols: ['Group'],
    aggregatorName: 'Count',
    rendererName: 'Heatmap',
  });

  // Transform data to use friendly field names
  const pivotData = useMemo(() => {
    return data.map(row => ({
      User: row.memberDisplayName || '',
      UPN: row.memberUPN || '',
      Department: row.department || '',
      'Job Title': row.jobTitle || '',
      Group: row.groupDisplayName || '',
      'Membership Type': row.membershipType || '',
    }));
  }, [data]);

  return (
    <div className="overflow-auto max-h-[calc(100vh-220px)]">
      <PivotTableUI
        data={pivotData}
        onChange={s => {
          // PivotTableUI passes back the full state including `data` -
          // we must strip `data` to avoid passing stale data back in
          const { data: _ignored, ...rest } = s;
          setPivotState(rest);
        }}
        renderers={TableRenderers}
        {...pivotState}
      />
    </div>
  );
}
