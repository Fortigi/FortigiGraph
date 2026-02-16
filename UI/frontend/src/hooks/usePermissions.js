import { useState, useEffect } from 'react';

const API_BASE = '/api';

export function usePermissions() {
  const [data, setData] = useState([]);
  const [accessPackageGroups, setAccessPackageGroups] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  useEffect(() => {
    async function fetchData() {
      try {
        const [permRes, apRes] = await Promise.all([
          fetch(`${API_BASE}/permissions`),
          fetch(`${API_BASE}/access-package-groups`),
        ]);
        if (!permRes.ok) throw new Error(`HTTP ${permRes.status}`);
        const permJson = await permRes.json();
        setData(permJson);

        if (apRes.ok) {
          setAccessPackageGroups(await apRes.json());
        }
      } catch (err) {
        setError(err.message);
      } finally {
        setLoading(false);
      }
    }
    fetchData();
  }, []);

  return { data, accessPackageGroups, loading, error };
}
