import { useState, useEffect, useCallback } from 'react';

function getStorageKey(department) {
  return `fgraph-colorder-${department || 'all'}`;
}

export function useMatrixColumnOrder(department) {
  const [colOrder, setColOrder] = useState(null);

  // Load from localStorage when department changes
  useEffect(() => {
    try {
      const raw = localStorage.getItem(getStorageKey(department));
      if (raw) {
        const saved = JSON.parse(raw);
        if (saved.order) {
          setColOrder(saved.order);
          return;
        }
      }
    } catch {}
    setColOrder(null);
  }, [department]);

  // Save when order changes
  useEffect(() => {
    if (colOrder === null) return;
    try {
      localStorage.setItem(getStorageKey(department), JSON.stringify({
        department,
        order: colOrder,
        updatedAt: new Date().toISOString(),
      }));
    } catch {}
  }, [colOrder, department]);

  const getOrderedUsers = useCallback((users) => {
    if (!colOrder) return users;

    const userMap = new Map(users.map(u => [u.id, u]));
    const ordered = [];

    for (const id of colOrder) {
      if (userMap.has(id)) {
        ordered.push(userMap.get(id));
        userMap.delete(id);
      }
    }

    // Append any new users not in saved order
    for (const u of userMap.values()) {
      ordered.push(u);
    }

    return ordered;
  }, [colOrder]);

  const updateOrder = useCallback((newUserIds) => {
    setColOrder(newUserIds);
  }, []);

  const resetOrder = useCallback(() => {
    setColOrder(null);
    try {
      localStorage.removeItem(getStorageKey(department));
    } catch {}
  }, [department]);

  return {
    getOrderedUsers,
    updateOrder,
    resetOrder,
    hasCustomOrder: colOrder !== null,
  };
}
