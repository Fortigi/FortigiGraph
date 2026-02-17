import { useState, useEffect, useRef, useCallback } from 'react';

const API_BASE = '/api';

export function usePermissions(userLimit = 25) {
  const [data, setData] = useState([]);
  const [totalUsers, setTotalUsers] = useState(0);
  const [accessPackageGroups, setAccessPackageGroups] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  // Debounced userLimit: only triggers fetch after 400ms of no changes
  const [debouncedLimit, setDebouncedLimit] = useState(userLimit);
  const timerRef = useRef(null);

  useEffect(() => {
    if (timerRef.current) clearTimeout(timerRef.current);
    timerRef.current = setTimeout(() => {
      setDebouncedLimit(userLimit);
    }, 400);
    return () => clearTimeout(timerRef.current);
  }, [userLimit]);

  const fetchPermissions = useCallback(async (limit, signal) => {
    const params = limit > 0 ? `?userLimit=${limit}` : '';
    const res = await fetch(`${API_BASE}/permissions${params}`, { signal });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.json();
  }, []);

  // Initial load: fetch permissions + access package groups
  useEffect(() => {
    const controller = new AbortController();
    let cancelled = false;

    async function fetchData() {
      try {
        // Only show full loading spinner on initial load (no data yet)
        if (data.length === 0) setLoading(true);

        const [permResult, apRes] = await Promise.all([
          fetchPermissions(debouncedLimit, controller.signal),
          fetch(`${API_BASE}/access-package-groups`, { signal: controller.signal }),
        ]);

        if (cancelled) return;
        setData(permResult.data);
        setTotalUsers(permResult.totalUsers);

        if (apRes.ok) {
          setAccessPackageGroups(await apRes.json());
        }
      } catch (err) {
        if (cancelled || err.name === 'AbortError') return;
        setError(err.message);
      } finally {
        if (!cancelled) setLoading(false);
      }
    }
    fetchData();

    return () => {
      cancelled = true;
      controller.abort();
    };
  }, [debouncedLimit, fetchPermissions]);

  return { data, totalUsers, accessPackageGroups, loading, error };
}
