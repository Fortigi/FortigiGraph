import { useState, useEffect, useRef, useCallback, useMemo } from 'react';
import { useAuth } from '../auth/AuthGate';

const API_BASE = '/api';

export function usePermissions(userLimit = 25, activeFilters = []) {
  const { authFetch } = useAuth();
  const [data, setData] = useState([]);
  const [totalUsers, setTotalUsers] = useState(0);
  const [accessPackageGroups, setAccessPackageGroups] = useState([]);
  const [managedByPackages, setManagedByPackages] = useState([]);
  const [userColumns, setUserColumns] = useState(null); // null = loading
  const [groupColumns, setGroupColumns] = useState(null); // null = loading
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false); // true during refetch (filter/limit change)
  const [error, setError] = useState(null);

  // Fetch user and group columns once on mount (for filter dropdowns + knowing which filters are server-side)
  useEffect(() => {
    let cancelled = false;
    authFetch(`${API_BASE}/user-columns`)
      .then(res => res.ok ? res.json() : [])
      .then(cols => { if (!cancelled) setUserColumns(cols); })
      .catch(() => { if (!cancelled) setUserColumns([]); });
    authFetch(`${API_BASE}/group-columns`)
      .then(res => res.ok ? res.json() : [])
      .then(cols => { if (!cancelled) setGroupColumns(cols); })
      .catch(() => { if (!cancelled) setGroupColumns([]); });
    return () => { cancelled = true; };
  }, [authFetch]);

  // Derive server-side filters: user and group attribute columns go to the backend.
  // Other filters (membershipType, etc.) stay client-side.
  const userColumnNames = useMemo(() => {
    if (!userColumns) return new Set();
    return new Set(userColumns.map(c => c.column));
  }, [userColumns]);

  const groupColumnNames = useMemo(() => {
    if (!groupColumns) return new Set();
    return new Set(groupColumns.map(c => c.column));
  }, [groupColumns]);

  const serverFilters = useMemo(() => {
    const result = {};
    for (const f of activeFilters) {
      if (userColumnNames.has(f.field) || groupColumnNames.has(f.field)) {
        result[f.field] = f.value;
      }
    }
    return result;
  }, [activeFilters, userColumnNames, groupColumnNames]);

  // Stable key for debounce comparison (avoids object reference changes)
  const serverFilterKey = useMemo(() => JSON.stringify(serverFilters), [serverFilters]);

  // Debounced server parameters: only triggers fetch after 400ms of no changes
  const [debouncedLimit, setDebouncedLimit] = useState(userLimit);
  const [debouncedFilterKey, setDebouncedFilterKey] = useState(serverFilterKey);
  const timerRef = useRef(null);

  useEffect(() => {
    if (timerRef.current) clearTimeout(timerRef.current);
    timerRef.current = setTimeout(() => {
      setDebouncedLimit(userLimit);
      setDebouncedFilterKey(serverFilterKey);
    }, 400);
    return () => clearTimeout(timerRef.current);
  }, [userLimit, serverFilterKey]);

  const fetchPermissions = useCallback(async (limit, filterJson, signal) => {
    const params = new URLSearchParams();
    if (limit > 0) params.set('userLimit', limit);
    const filters = JSON.parse(filterJson);
    if (Object.keys(filters).length > 0) params.set('filters', filterJson);
    const qs = params.toString();
    const url = `${API_BASE}/permissions${qs ? `?${qs}` : ''}`;
    const res = await authFetch(url, { signal });
    if (!res.ok) {
      const body = await res.json().catch(() => ({}));
      throw new Error(body.error || `HTTP ${res.status}`);
    }
    return res.json();
  }, [authFetch]);

  // Fetch data when debounced server parameters change
  useEffect(() => {
    const controller = new AbortController();
    let cancelled = false;

    async function fetchData() {
      try {
        // Full loading spinner on initial load; subtle refreshing indicator on subsequent fetches
        if (data.length === 0) setLoading(true);
        setRefreshing(true);

        const [permResult, apRes] = await Promise.all([
          fetchPermissions(debouncedLimit, debouncedFilterKey, controller.signal),
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
        if (!cancelled) {
          setLoading(false);
          setRefreshing(false);
        }
      }
    }
    fetchData();

    return () => {
      cancelled = true;
      controller.abort();
    };
  }, [debouncedLimit, debouncedFilterKey, fetchPermissions, authFetch]);

  return { data, totalUsers, accessPackageGroups, managedByPackages, userColumns, groupColumns, loading, refreshing, error };
}
