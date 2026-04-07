import { useEffect, useState } from 'react';
import { useAuth } from '../auth/AuthGate';

// Admin → Authentication sub-tab.
//
// Lets the operator turn Entra ID SSO on/off and configure the tenant + client
// IDs from the UI. The settings are persisted to dbo.WorkerConfig via the new
// /api/admin/auth-settings endpoints; the backend hot-reloads its in-memory
// state so the next request uses the new config without a container restart.
//
// Important UX considerations baked in:
//
//   1. Auto-detected redirect URI: we show the current `window.location.origin`
//      so the user knows exactly which URI to register in their Entra ID app.
//      Multi-domain support (localhost + identityatlas.customer.com) is handled
//      by simply registering all the URIs in Entra — no app config change.
//
//   2. Lockout warning: turning auth on with bad config will lock the operator
//      out. We surface a prominent warning AND a recovery SQL command they can
//      use to disable auth via direct DB access if they ever get stuck.
//
//   3. Step-by-step setup walkthrough: Entra ID app registration is fiddly. The
//      page bundles a clickable checklist of the exact steps with the values
//      they need to paste in.

export default function AuthSettingsPage() {
  const { authFetch } = useAuth();
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);
  const [savedAt, setSavedAt] = useState(null);
  const [confirmEnable, setConfirmEnable] = useState(false);

  // Form state
  const [enabled, setEnabled] = useState(false);
  const [tenantId, setTenantId] = useState('');
  const [clientId, setClientId] = useState('');
  const [requiredRolesText, setRequiredRolesText] = useState(''); // comma-separated

  // The current page origin — what the user must register as a redirect URI in
  // Entra. We compute it client-side instead of asking the backend so it works
  // even when the backend is on a different host (proxied deployments).
  const currentOrigin = typeof window !== 'undefined' ? window.location.origin : '';
  const apiScopeUri = clientId ? `api://${clientId}/access` : 'api://<your-client-id>/access';

  // Fetch current state on mount
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const r = await authFetch('/api/admin/auth-settings');
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        const j = await r.json();
        if (cancelled) return;
        setEnabled(!!j.enabled);
        setTenantId(j.tenantId || '');
        setClientId(j.clientId || '');
        setRequiredRolesText((j.requiredRoles || []).join(', '));
      } catch (err) {
        if (!cancelled) setError(err.message);
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, [authFetch]);

  const tenantIdValid = /^[0-9a-f-]{36}$/i.test(tenantId);
  const clientIdValid = /^[0-9a-f-]{36}$/i.test(clientId);
  const enableReady   = tenantIdValid && clientIdValid;

  const handleSave = async () => {
    setError(null);
    setSavedAt(null);
    setSaving(true);
    try {
      // Parse comma-separated role list, drop blanks
      const requiredRoles = requiredRolesText
        .split(',')
        .map(s => s.trim())
        .filter(Boolean);

      const r = await authFetch('/api/admin/auth-settings', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ enabled, tenantId, clientId, requiredRoles }),
      });
      if (!r.ok) {
        const err = await r.json().catch(() => ({}));
        throw new Error(err.error || `HTTP ${r.status}`);
      }
      setSavedAt(new Date());
      setConfirmEnable(false);
      // If we just turned auth on, the next page load will redirect to Entra.
      // We don't auto-reload here — let the user choose when to leave the page.
    } catch (err) {
      setError(err.message);
    } finally {
      setSaving(false);
    }
  };

  if (loading) {
    return <div className="text-sm text-gray-500 p-6">Loading authentication settings...</div>;
  }

  return (
    <div className="space-y-6">
      {/* ─── Current state card ─────────────────────────────── */}
      <div className={`rounded-lg border p-5 ${enabled ? 'bg-green-50 border-green-200' : 'bg-gray-50 border-gray-200'}`}>
        <div className="flex items-start justify-between">
          <div>
            <h3 className="text-base font-semibold text-gray-900">Authentication</h3>
            <p className="text-sm text-gray-600 mt-1">
              {enabled
                ? 'Entra ID SSO is enabled. Users must sign in with their Microsoft account to access the application.'
                : 'Authentication is disabled. Anyone with the URL can access this application.'}
            </p>
          </div>
          <span className={`px-3 py-1 rounded-full text-xs font-semibold ${enabled ? 'bg-green-200 text-green-900' : 'bg-amber-200 text-amber-900'}`}>
            {enabled ? 'ENABLED' : 'DISABLED'}
          </span>
        </div>
      </div>

      {/* ─── Setup walkthrough ──────────────────────────────── */}
      <div className="rounded-lg border border-gray-200 bg-white p-5">
        <h3 className="text-base font-semibold text-gray-900 mb-3">Setup walkthrough</h3>
        <p className="text-sm text-gray-600 mb-4">
          Before enabling authentication, you need to register Identity Atlas as an application in your Entra ID tenant.
          Follow these steps once per tenant.
        </p>

        <ol className="space-y-3 text-sm">
          <li className="flex gap-3">
            <span className="flex-shrink-0 w-6 h-6 rounded-full bg-indigo-100 text-indigo-700 font-semibold flex items-center justify-center text-xs">1</span>
            <div>
              <div className="font-medium text-gray-900">Create an App Registration</div>
              <div className="text-gray-600">
                Go to <a href="https://portal.azure.com/#blade/Microsoft_AAD_RegisteredApps/ApplicationsListBlade" target="_blank" rel="noreferrer" className="text-indigo-600 underline">Entra ID → App registrations → New registration</a>.
                Name it <code className="bg-gray-100 px-1 rounded">Identity Atlas</code> (or whatever you prefer).
                Account types: <strong>Accounts in this organizational directory only</strong>.
                Leave the redirect URI empty for now.
              </div>
            </div>
          </li>

          <li className="flex gap-3">
            <span className="flex-shrink-0 w-6 h-6 rounded-full bg-indigo-100 text-indigo-700 font-semibold flex items-center justify-center text-xs">2</span>
            <div>
              <div className="font-medium text-gray-900">Add a Single-Page Application redirect URI</div>
              <div className="text-gray-600">
                In the new app, go to <strong>Authentication → Add a platform → Single-page application</strong>.
                Add this URI:
              </div>
              <div className="mt-1 flex items-center gap-2">
                <code className="px-2 py-1 bg-gray-100 rounded text-xs font-mono">{currentOrigin}</code>
                <button
                  onClick={() => navigator.clipboard.writeText(currentOrigin)}
                  className="text-xs text-indigo-600 hover:text-indigo-800"
                >Copy</button>
              </div>
              <div className="text-gray-500 text-xs mt-1">
                If you also access Identity Atlas from another URL (production domain, reverse proxy, etc.),
                add each one as a separate redirect URI in the same Entra app.
              </div>
            </div>
          </li>

          <li className="flex gap-3">
            <span className="flex-shrink-0 w-6 h-6 rounded-full bg-indigo-100 text-indigo-700 font-semibold flex items-center justify-center text-xs">3</span>
            <div>
              <div className="font-medium text-gray-900">Expose an API scope</div>
              <div className="text-gray-600">
                Go to <strong>Expose an API → Add a scope</strong>. Accept the default Application ID URI
                (<code className="bg-gray-100 px-1 rounded text-xs">api://&lt;client-id&gt;</code>),
                then create a scope named <code className="bg-gray-100 px-1 rounded">access</code>.
                The full scope value will be:
              </div>
              <div className="mt-1 flex items-center gap-2">
                <code className="px-2 py-1 bg-gray-100 rounded text-xs font-mono">{apiScopeUri}</code>
                {clientId && (
                  <button onClick={() => navigator.clipboard.writeText(apiScopeUri)} className="text-xs text-indigo-600 hover:text-indigo-800">Copy</button>
                )}
              </div>
            </div>
          </li>

          <li className="flex gap-3">
            <span className="flex-shrink-0 w-6 h-6 rounded-full bg-indigo-100 text-indigo-700 font-semibold flex items-center justify-center text-xs">4</span>
            <div>
              <div className="font-medium text-gray-900">(Optional) Define App roles</div>
              <div className="text-gray-600">
                If you want to restrict access to specific groups of users, define App roles under <strong>App roles → Create app role</strong>
                {' '}(e.g. <code className="bg-gray-100 px-1 rounded">IdentityAtlas.Read</code>, <code className="bg-gray-100 px-1 rounded">IdentityAtlas.Admin</code>),
                then assign them to users via <strong>Enterprise applications → &lt;your app&gt; → Users and groups</strong>.
                Add the role names to the "Required roles" field below to enforce them.
              </div>
            </div>
          </li>

          <li className="flex gap-3">
            <span className="flex-shrink-0 w-6 h-6 rounded-full bg-indigo-100 text-indigo-700 font-semibold flex items-center justify-center text-xs">5</span>
            <div>
              <div className="font-medium text-gray-900">Paste the Tenant ID and Client ID below</div>
              <div className="text-gray-600">
                Both values are on the app's <strong>Overview</strong> page (<em>Directory (tenant) ID</em> and <em>Application (client) ID</em>).
                Then check "Enable authentication" and click Save. The next page reload will redirect you to Entra ID to sign in.
              </div>
            </div>
          </li>
        </ol>
      </div>

      {/* ─── Configuration form ─────────────────────────────── */}
      <div className="rounded-lg border border-gray-200 bg-white p-5">
        <h3 className="text-base font-semibold text-gray-900 mb-4">Configuration</h3>

        <div className="space-y-4">
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">Tenant ID</label>
            <input
              type="text"
              value={tenantId}
              onChange={e => setTenantId(e.target.value.trim())}
              placeholder="00000000-0000-0000-0000-000000000000"
              className={`w-full px-3 py-2 border rounded text-sm font-mono ${tenantId && !tenantIdValid ? 'border-red-300 bg-red-50' : 'border-gray-300'}`}
            />
            {tenantId && !tenantIdValid && (
              <p className="text-xs text-red-600 mt-1">Must be a valid GUID</p>
            )}
          </div>

          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">Client ID</label>
            <input
              type="text"
              value={clientId}
              onChange={e => setClientId(e.target.value.trim())}
              placeholder="00000000-0000-0000-0000-000000000000"
              className={`w-full px-3 py-2 border rounded text-sm font-mono ${clientId && !clientIdValid ? 'border-red-300 bg-red-50' : 'border-gray-300'}`}
            />
            {clientId && !clientIdValid && (
              <p className="text-xs text-red-600 mt-1">Must be a valid GUID</p>
            )}
          </div>

          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">Required roles (optional, comma-separated)</label>
            <input
              type="text"
              value={requiredRolesText}
              onChange={e => setRequiredRolesText(e.target.value)}
              placeholder="IdentityAtlas.Read, IdentityAtlas.Admin"
              className="w-full px-3 py-2 border border-gray-300 rounded text-sm"
            />
            <p className="text-xs text-gray-500 mt-1">
              When set, users without at least one of these app roles get a 403. Leave empty to allow any signed-in user from your tenant.
            </p>
          </div>

          <div className="flex items-center gap-3 pt-2">
            <label className="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                checked={enabled}
                disabled={!enableReady}
                onChange={e => {
                  if (e.target.checked && !enabled) {
                    setConfirmEnable(true);
                  } else {
                    setEnabled(e.target.checked);
                    setConfirmEnable(false);
                  }
                }}
                className="rounded"
              />
              <span className="text-sm font-medium text-gray-900">Enable authentication</span>
            </label>
            {!enableReady && (
              <span className="text-xs text-gray-500">(fill in valid Tenant ID and Client ID first)</span>
            )}
          </div>

          {/* ─── Lockout warning + confirmation ────────────────── */}
          {confirmEnable && (
            <div className="bg-amber-50 border border-amber-300 rounded-lg p-4">
              <div className="flex items-start gap-2 mb-2">
                <span className="text-amber-600 text-lg">⚠️</span>
                <div>
                  <h4 className="font-semibold text-amber-900">Lockout warning</h4>
                  <p className="text-sm text-amber-800 mt-1">
                    If the Tenant ID, Client ID, or redirect URI registration is wrong, you will be locked out of the application.
                    Make sure you've completed all the setup steps above before enabling.
                  </p>
                  <p className="text-sm text-amber-800 mt-2">
                    <strong>Recovery:</strong> if you do get locked out, run this SQL command to disable auth:
                  </p>
                  <pre className="mt-1 p-2 bg-amber-100 rounded text-xs font-mono overflow-x-auto">{`UPDATE dbo.WorkerConfig SET configValue = 'false'
WHERE configKey = 'AUTH_ENABLED';`}</pre>
                  <p className="text-xs text-amber-700 mt-1">
                    Then refresh the page — auth will be off again. (You can also exec into the sql container with{' '}
                    <code>docker compose exec sql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SQL_PASSWORD" -d GraphData -No -Q "..."</code>.)
                  </p>
                </div>
              </div>
              <div className="flex gap-2 mt-3">
                <button
                  onClick={() => { setEnabled(true); setConfirmEnable(false); }}
                  className="px-3 py-1.5 bg-amber-600 text-white rounded text-sm hover:bg-amber-700"
                >
                  I understand, enable auth
                </button>
                <button
                  onClick={() => setConfirmEnable(false)}
                  className="px-3 py-1.5 bg-gray-100 text-gray-700 rounded text-sm hover:bg-gray-200"
                >
                  Cancel
                </button>
              </div>
            </div>
          )}

          {error && (
            <div className="p-3 bg-red-50 border border-red-200 rounded text-sm text-red-700">
              {error}
            </div>
          )}

          {savedAt && (
            <div className="p-3 bg-green-50 border border-green-200 rounded text-sm text-green-800">
              Saved at {savedAt.toLocaleTimeString()}.
              {enabled
                ? ' Authentication is now active. Reload the page to sign in.'
                : ' Authentication is now disabled.'}
            </div>
          )}

          <div className="flex justify-end pt-2">
            <button
              onClick={handleSave}
              disabled={saving || (enabled && !enableReady)}
              className="px-4 py-2 bg-indigo-600 text-white rounded text-sm hover:bg-indigo-700 disabled:opacity-50"
            >
              {saving ? 'Saving...' : 'Save'}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
