import { useState, useEffect, useCallback, useRef } from 'react';

const DEFAULT_PALETTE = [
  { key: 'green',  hex: '#bbf7d0', label: 'Confirmed' },
  { key: 'pink',   hex: '#fbcfe8', label: 'Role A' },
  { key: 'purple', hex: '#e9d5ff', label: 'Role B' },
  { key: 'orange', hex: '#fed7aa', label: 'Role C' },
  { key: 'red',    hex: '#fecaca', label: 'Remove' },
  { key: 'blue',   hex: '#bfdbfe', label: 'Add' },
];

function getStorageKey(department) {
  return `fgraph-annotations-${department || 'all'}`;
}

function loadAnnotations(department) {
  try {
    const raw = localStorage.getItem(getStorageKey(department));
    if (raw) return JSON.parse(raw);
  } catch {}
  return null;
}

function saveAnnotations(department, data) {
  try {
    localStorage.setItem(getStorageKey(department), JSON.stringify(data));
  } catch {}
}

export function useMatrixAnnotations(department) {
  const [cells, setCells] = useState({});
  const [palette, setPalette] = useState(DEFAULT_PALETTE);
  const [activeBrush, setActiveBrush] = useState(null);
  const [history, setHistory] = useState([]);
  const [historyIndex, setHistoryIndex] = useState(-1);
  const lastClickedCell = useRef(null);

  // Load from localStorage when department changes
  useEffect(() => {
    const saved = loadAnnotations(department);
    if (saved) {
      setCells(saved.cells || {});
      if (saved.palette) setPalette(saved.palette);
    } else {
      setCells({});
    }
    setHistory([]);
    setHistoryIndex(-1);
  }, [department]);

  // Debounced save to localStorage
  useEffect(() => {
    const timer = setTimeout(() => {
      saveAnnotations(department, {
        department,
        cells,
        palette,
        updatedAt: new Date().toISOString(),
      });
    }, 500);
    return () => clearTimeout(timer);
  }, [cells, palette, department]);

  const pushHistory = useCallback((prevCells) => {
    setHistory(h => {
      const newHistory = h.slice(0, historyIndex + 1);
      newHistory.push(prevCells);
      if (newHistory.length > 50) newHistory.shift();
      return newHistory;
    });
    setHistoryIndex(i => Math.min(i + 1, 49));
  }, [historyIndex]);

  const annotateCell = useCallback((cellKey) => {
    if (!activeBrush) return;
    setCells(prev => {
      pushHistory(prev);
      const next = { ...prev };
      if (activeBrush === 'clear') {
        delete next[cellKey];
      } else {
        next[cellKey] = activeBrush;
      }
      return next;
    });
    lastClickedCell.current = cellKey;
  }, [activeBrush, pushHistory]);

  const annotateRange = useCallback((startKey, endKey, groupIds, userIds) => {
    if (!activeBrush) return;

    const [startGroup, startUser] = startKey.split('|');
    const [endGroup, endUser] = endKey.split('|');

    const gi1 = groupIds.indexOf(startGroup);
    const gi2 = groupIds.indexOf(endGroup);
    const ui1 = userIds.indexOf(startUser);
    const ui2 = userIds.indexOf(endUser);

    const gMin = Math.min(gi1, gi2);
    const gMax = Math.max(gi1, gi2);
    const uMin = Math.min(ui1, ui2);
    const uMax = Math.max(ui1, ui2);

    setCells(prev => {
      pushHistory(prev);
      const next = { ...prev };
      for (let g = gMin; g <= gMax; g++) {
        for (let u = uMin; u <= uMax; u++) {
          const key = `${groupIds[g]}|${userIds[u]}`;
          if (activeBrush === 'clear') {
            delete next[key];
          } else {
            next[key] = activeBrush;
          }
        }
      }
      return next;
    });
  }, [activeBrush, pushHistory]);

  const undo = useCallback(() => {
    if (historyIndex < 0 || history.length === 0) return;
    const prev = history[historyIndex];
    setHistoryIndex(i => i - 1);
    setCells(prev);
  }, [history, historyIndex]);

  const clearAll = useCallback(() => {
    pushHistory(cells);
    setCells({});
  }, [cells, pushHistory]);

  const updatePaletteLabel = useCallback((key, label) => {
    setPalette(p => p.map(c => c.key === key ? { ...c, label } : c));
  }, []);

  const exportAnnotations = useCallback(() => {
    const data = { department, cells, palette, updatedAt: new Date().toISOString() };
    const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `role-mining-${department || 'all'}-${new Date().toISOString().slice(0, 10)}.json`;
    a.click();
    URL.revokeObjectURL(url);
  }, [department, cells, palette]);

  const importAnnotations = useCallback((jsonString) => {
    try {
      const data = JSON.parse(jsonString);
      if (data.cells) {
        pushHistory(cells);
        setCells(data.cells);
      }
      if (data.palette) setPalette(data.palette);
    } catch {}
  }, [cells, pushHistory]);

  return {
    cells,
    palette,
    activeBrush,
    setActiveBrush,
    annotateCell,
    annotateRange,
    lastClickedCell,
    undo,
    clearAll,
    updatePaletteLabel,
    exportAnnotations,
    importAnnotations,
  };
}
