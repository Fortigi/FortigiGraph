import { useState, useEffect, useRef, useCallback } from 'react';
import { useAuth } from '../auth/AuthGate';

const API_BASE = '/api';

export function usePermissions(userLimit = 25) {
  const { authFetch } = useAuth();
  const [data, setData] = useState([]);
  const [totalUsers, setTotalUsers] = useState(0);
  const [accessPackageGroups, setAccessPackageGroups] = useState([]);
  const [managedByPackages, setManagedByPackages] = useState([]);
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
    const res = await authFetch(`${API_BASE}/permissions${params}`, { signal });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.json();
  }, [authFetch]);

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
          authFetch(`${API_BASE}/access-package-groups`, { signal: controller.signal }),
        ]);

        if (cancelled) return;
        setData(permResult.data);
        setTotalUsers(permResult.totalUsers);
        setManagedByPackages(permResult.managedByPackages || []);

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
  }, [debouncedLimit, fetchPermissions, authFetch]);

  return { data, totalUsers, accessPackageGroups, managedByPackages, loading, error };
}
