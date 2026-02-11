import { useState, useEffect, useCallback } from 'react';

function getStorageKey(department) {
  return `fgraph-roworder-${department || 'all'}`;
}

export function useMatrixRowOrder(department, defaultGroupIds) {
  const [rowOrder, setRowOrder] = useState(null);

  // Load from localStorage when department changes
  useEffect(() => {
    try {
      const raw = localStorage.getItem(getStorageKey(department));
      if (raw) {
        const saved = JSON.parse(raw);
        if (saved.order) {
          setRowOrder(saved.order);
          return;
        }
      }
    } catch {}
    setRowOrder(null);
  }, [department]);

  // Save when order changes
  useEffect(() => {
    if (rowOrder === null) return;
    try {
      localStorage.setItem(getStorageKey(department), JSON.stringify({
        department,
        order: rowOrder,
        updatedAt: new Date().toISOString(),
      }));
    } catch {}
  }, [rowOrder, department]);

  // Apply order to group list: use saved order, append any new groups at the end
  const getOrderedGroups = useCallback((groups) => {
    if (!rowOrder) return groups;

    const groupMap = new Map(groups.map(g => [g.id, g]));
    const ordered = [];

    // Add groups in saved order
    for (const id of rowOrder) {
      if (groupMap.has(id)) {
        ordered.push(groupMap.get(id));
        groupMap.delete(id);
      }
    }

    // Append any new groups not in saved order
    for (const g of groupMap.values()) {
      ordered.push(g);
    }

    return ordered;
  }, [rowOrder]);

  const updateOrder = useCallback((newGroupIds) => {
    setRowOrder(newGroupIds);
  }, []);

  const resetOrder = useCallback(() => {
    setRowOrder(null);
    try {
      localStorage.removeItem(getStorageKey(department));
    } catch {}
  }, [department]);

  return {
    getOrderedGroups,
    updateOrder,
    resetOrder,
    hasCustomOrder: rowOrder !== null,
  };
}
