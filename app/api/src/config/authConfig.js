// Dynamic auth configuration.
//
// The application's Entra ID SSO settings used to live in environment variables
// (AUTH_ENABLED, AUTH_TENANT_ID, AUTH_CLIENT_ID, AUTH_REQUIRED_ROLES). Those
// required a container restart to change, which made first-time configuration
// from the UI impossible. This module moves the settings into the WorkerConfig
// table so the Admin → Authentication page can update them at runtime.
//
// Resolution order at startup (first hit wins per key):
//   1. WorkerConfig row in SQL (the canonical source after first save)
//   2. Process environment variable (lets existing deployments keep working
//      until they explicitly save a different value via the UI)
//   3. Hardcoded default (auth disabled)
//
// After a successful PUT to /api/admin/auth-settings, reloadAuthConfig() is
// called to re-read state and (if needed) rebuild the JWKS client used by the
// JWT validation middleware. The next inbound request sees the new state.
//
// Why not env-only:
//   - Restarts are disruptive on a running stack
//   - Operators expect "save in UI = effective immediately"
//   - First-time setup is impossible if you have to edit env vars before you
//     can even reach the Admin page
//
// Why not full hot-swap of auth on every request:
//   - Reading SQL on every request would be slow
//   - JWKS clients cache signing keys for a day; rebuilding per request defeats
//     that cache and adds latency
//
// The compromise: read once into module-level state, expose a `reload()`
// function that the admin route calls after a successful save. Cheap and fast.

import jwksClient from 'jwks-rsa';
import * as db from '../db/connection.js';

const useSql = process.env.USE_SQL === 'true';

// Module-level state — a snapshot of the current auth configuration. Read by
// authMiddleware and the /api/auth-config route. Mutated only by load()/reload().
let _state = {
  enabled: false,
  tenantId: '',
  clientId: '',
  requiredRoles: null, // null = no role check; otherwise array of strings
  jwksClient: null,    // built when enabled === true && tenantId is set
  loaded: false,
};

function buildJwksClient(tenantId) {
  if (!tenantId) return null;
  return jwksClient({
    jwksUri: `https://login.microsoftonline.com/${tenantId}/discovery/v2.0/keys`,
    cache: true,
    cacheMaxAge: 86400000,  // 24h — same as the previous middleware
  });
}

function parseBoolean(v) {
  if (typeof v === 'boolean') return v;
  if (v == null) return false;
  return String(v).toLowerCase() === 'true';
}

function parseRoles(v) {
  if (!v) return null;
  const arr = String(v).split(',').map(r => r.trim()).filter(Boolean);
  return arr.length > 0 ? arr : null;
}

// Read all four auth keys out of WorkerConfig in one query. Missing rows are
// just absent from the result — caller falls back to env vars.
async function readFromDb() {
  if (!useSql) return {};
  try {
    const pool = await db.getPool();
    const result = await pool.request().query(
      `SELECT configKey, configValue FROM dbo.WorkerConfig
       WHERE configKey IN ('AUTH_ENABLED','AUTH_TENANT_ID','AUTH_CLIENT_ID','AUTH_REQUIRED_ROLES')`
    );
    const out = {};
    for (const row of result.recordset) out[row.configKey] = row.configValue;
    return out;
  } catch (err) {
    // Table might not exist yet on a fresh stack — fail silent and rely on env vars.
    console.warn('authConfig: failed to read WorkerConfig, falling back to env vars:', err.message);
    return {};
  }
}

// Resolve a single config value: DB → env → default.
function resolve(dbValue, envValue, defaultValue) {
  if (dbValue != null && dbValue !== '') return dbValue;
  if (envValue != null && envValue !== '') return envValue;
  return defaultValue;
}

export async function loadAuthConfig() {
  const dbVals = await readFromDb();
  const enabled  = parseBoolean(resolve(dbVals.AUTH_ENABLED,        process.env.AUTH_ENABLED,        'false'));
  const tenantId = resolve(dbVals.AUTH_TENANT_ID,        process.env.AUTH_TENANT_ID,        '');
  const clientId = resolve(dbVals.AUTH_CLIENT_ID,        process.env.AUTH_CLIENT_ID,        '');
  const roles    = parseRoles(resolve(dbVals.AUTH_REQUIRED_ROLES,   process.env.AUTH_REQUIRED_ROLES,   ''));

  _state = {
    enabled,
    tenantId,
    clientId,
    requiredRoles: roles,
    jwksClient: enabled && tenantId ? buildJwksClient(tenantId) : null,
    loaded: true,
  };

  if (enabled && (!tenantId || !clientId)) {
    console.warn('authConfig: AUTH_ENABLED is true but tenantId or clientId is missing — auth will reject all requests');
  }

  return _state;
}

// Re-read from DB and rebuild module state. Called by the admin save endpoint.
export async function reloadAuthConfig() {
  return loadAuthConfig();
}

// Persist a partial update to WorkerConfig. Caller passes only the fields they
// want to change. Empty string means "clear", null/undefined means "leave alone".
export async function saveAuthConfig({ enabled, tenantId, clientId, requiredRoles }) {
  if (!useSql) throw new Error('SQL not configured');
  const pool = await db.getPool();

  const updates = [];
  if (enabled !== undefined)       updates.push(['AUTH_ENABLED',        enabled ? 'true' : 'false']);
  if (tenantId !== undefined)      updates.push(['AUTH_TENANT_ID',      tenantId || '']);
  if (clientId !== undefined)      updates.push(['AUTH_CLIENT_ID',      clientId || '']);
  if (requiredRoles !== undefined) updates.push(['AUTH_REQUIRED_ROLES', Array.isArray(requiredRoles) ? requiredRoles.join(',') : (requiredRoles || '')]);

  for (const [k, v] of updates) {
    await pool.request()
      .input('k', k).input('v', v)
      .query(`MERGE dbo.WorkerConfig AS t
              USING (SELECT @k AS configKey) AS s ON t.configKey = s.configKey
              WHEN MATCHED THEN UPDATE SET configValue = @v, updatedAt = SYSUTCDATETIME()
              WHEN NOT MATCHED THEN INSERT (configKey, configValue) VALUES (@k, @v);`);
  }

  await reloadAuthConfig();
  return _state;
}

// Read-only accessors used by the middleware and the /api/auth-config route.
// Keeping these as functions (not exported state) avoids stale references.
export function getAuthState()   { return _state; }
export function isAuthEnabled()  { return _state.enabled; }
export function getJwksClient()  { return _state.jwksClient; }
export function getTenantId()    { return _state.tenantId; }
export function getClientId()    { return _state.clientId; }
export function getRequiredRoles() { return _state.requiredRoles; }
