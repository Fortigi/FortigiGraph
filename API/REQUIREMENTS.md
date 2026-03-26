# FortigiGraph Ingestion API – Functional Requirements

## Overview

The Ingestion API is a REST service that lets external callers write Microsoft Graph identity
and entitlement data directly into the Azure SQL database managed by FortigiGraph, without
running a full PowerShell sync.  It is the authoritative entry point for any system that wants
to push Graph data into the store (e.g. custom pipelines, third-party integrations, the
generated PowerShell and Python client modules).

**Base URL:** `/api/v1/ingestion`
**Spec:** `API/spec/openapi.yaml` (OpenAPI 3.0, single source of truth)

---

## Authentication

| Requirement | Detail |
|-------------|--------|
| All endpoints require a Bearer token | Except `GET /health` |
| Tokens must be Azure AD JWTs | Obtained via client credentials: `POST https://login.microsoftonline.com/{tenantId}/oauth2/v2.0/token` |
| Required scope | `api://{AZURE_CLIENT_ID}/.default` |
| Token `tid` claim must match `AZURE_TENANT_ID` | Mismatched tenant → HTTP 401 |
| Optional role enforcement | Set `AUTH_REQUIRED_ROLES` (comma-separated) to restrict access to callers holding specific app roles; absence of a required role → HTTP 403 |
| Auth can be disabled for local dev | `AUTH_ENABLED=false` injects an anonymous user and skips all token checks |

---

## Non-Functional Requirements

| Area | Requirement |
|------|-------------|
| **Rate limiting** | 200 requests per minute per IP (configurable via `RATE_LIMIT_MAX_REQUESTS` / `RATE_LIMIT_WINDOW_MS`); excess → HTTP 429 `RATE_LIMITED` |
| **Security headers** | `helmet` applied: CSP, HSTS (1 year), X-Frame-Options, Referrer-Policy |
| **CORS** | Whitelist via `ALLOWED_ORIGINS` (comma-separated); empty list blocks all cross-origin requests; server-to-server calls (no `Origin` header) are always allowed |
| **Body size** | Request body capped at 5 MB |
| **Error sanitisation** | SQL schema details (table names, column names) are stripped from all error responses |
| **Swagger UI** | Served at `/api-docs` when `SWAGGER_UI_ENABLED=true` (default) |
| **Health endpoint** | `GET /health` is unauthenticated and returns `{ status, version, timestamp }` |

---

## Data Model & Entities

The API covers 12 entity types, each mapping 1:1 to an Azure SQL temporal table.

### Single-key entities (primary key: `id`)

| Entity | Table | Key field |
|--------|-------|-----------|
| User | `GraphUsers` | `id` (Azure AD object ID) |
| Group | `GraphGroups` | `id` (Azure AD object ID) |
| Catalog | `GraphCatalogs` | `id` |
| Access Package | `GraphAccessPackages` | `id` |
| Access Package Assignment | `GraphAccessPackageAssignments` | `id` |
| Access Package Resource Role Scope | `GraphAccessPackageResourceRoleScopes` | `id` (composite string: `accessPackageId_roleId_scopeId`) |
| Access Package Assignment Policy | `GraphAccessPackageAssignmentPolicies` | `id` |
| Access Package Assignment Request | `GraphAccessPackageAssignmentRequests` | `id` |
| Access Package Access Review | `GraphAccessPackageAccessReviewDecisions` | `id` |

### Composite-key entities (no single `id`)

| Entity | Table | Key fields |
|--------|-------|------------|
| Group Member | `GraphGroupMembers` | `groupId` + `memberId` |
| Group Owner | `GraphGroupOwners` | `groupId` + `ownerId` |
| Group Eligible Member | `GraphGroupEligibleMembers` | `groupId` + `memberId` |

---

## Operations per Entity

Every entity exposes the same set of operations.  The URL patterns differ only by entity name.

### List — `GET /{entity}`

- Returns a paginated list of records from the corresponding SQL table.
- Response shape: `{ data: T[], total: int, page: int, limit: int, hasMore: bool }`
- Query parameters:

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `$page` | integer ≥ 1 | 1 | Page number |
| `$limit` | integer 1–1000 | 100 | Records per page |
| `$filter` | string | — | OData-style filter (e.g. `displayName eq 'Engineering'`) |
| `$select` | string | — | Comma-separated field names to return |
| `asOf` | ISO 8601 datetime | — | Point-in-time read from temporal table history |

### Get by ID — `GET /{entity}/{id}`

- Returns a single record by primary key.
- Supports `?asOf=` for point-in-time reads.
- Returns HTTP 404 `{ code: "NOT_FOUND" }` if no record exists.

### Upsert — `POST /{entity}`

- Creates the record if it does not exist; updates all columns if it does (SQL MERGE semantics).
- `id` (or composite key fields) must be present in the request body → HTTP 400 otherwise.
- Returns the upserted record with HTTP 200.

### Update — `PUT /{entity}/{id}`  *(single-key entities only)*

- Full replace of an existing record.
- Returns HTTP 404 if the record does not exist (does not create).
- Returns the updated record with HTTP 200.

### Delete — `DELETE /{entity}/{id}` or `DELETE /{entity}/{key1}/{key2}`

- Removes the record.
- Returns HTTP 204 (no body) on success.
- Returns HTTP 404 if the record does not exist.

### Batch upsert — `POST /{entity}/batch`

- Accepts `{ records: T[], mode?: "upsert" | "insert" | "replace" }`.
- Maximum **1 000 records** per request → HTTP 400 if exceeded.
- `records` must be an array → HTTP 400 otherwise.
- Modes:
  - `upsert` *(default)* — insert new, update existing
  - `insert` — skip records that already exist
  - `replace` — delete all existing records for the entity, then insert
- Response: `{ inserted: int, updated: int, deleted: int, skipped: int, errors: [] }`

---

## HTTP Status Codes

| Code | Meaning |
|------|---------|
| 200 | Success (list, get, upsert, update) |
| 204 | Success, no content (delete) |
| 400 | Bad request — missing required fields, invalid body shape, batch > 1000 |
| 401 | Unauthorized — missing token, expired token, wrong tenant |
| 403 | Forbidden — authenticated but missing required role |
| 404 | Record not found |
| 429 | Rate limit exceeded |
| 500 | Internal server error |

All error responses use the shape `{ code: string, message: string, details?: string }`.

---

## Temporal (Point-in-Time) Reads

All GET endpoints accept `?asOf=<ISO 8601 datetime>`.  When provided, the query targets the
temporal table history so the response reflects the state of the data at that exact moment.
This mirrors the same temporal versioning used by the FortigiGraph PowerShell sync functions.

---

## Configuration Reference

| Variable | Required | Default | Purpose |
|----------|----------|---------|---------|
| `PORT` | No | 3001 | HTTP listen port |
| `NODE_ENV` | No | — | Set to `production` to enable startup warnings |
| `SQL_CONNECTION_STRING` | Yes* | — | Full ADO.NET connection string |
| `SQL_SERVER` | Yes* | — | SQL Server hostname (alternative to connection string) |
| `SQL_DATABASE` | Yes* | — | Database name |
| `SQL_USER` / `SQL_PASSWORD` | Yes* | — | SQL credentials |
| `AZURE_TENANT_ID` | Yes | — | Azure AD tenant ID for token validation |
| `AZURE_CLIENT_ID` | Yes | — | App Registration client ID (expected `aud` in tokens) |
| `AUTH_ENABLED` | No | `true` | Set to `false` to disable auth (dev/demo only) |
| `AUTH_REQUIRED_ROLES` | No | — | Comma-separated list of required app roles |
| `ALLOWED_ORIGINS` | No | (deny all) | Comma-separated CORS whitelist |
| `RATE_LIMIT_WINDOW_MS` | No | 60000 | Rate limit window in milliseconds |
| `RATE_LIMIT_MAX_REQUESTS` | No | 200 | Max requests per window per IP |
| `SWAGGER_UI_ENABLED` | No | `true` | Serve Swagger UI at `/api-docs` |

\* Either `SQL_CONNECTION_STRING` or the individual `SQL_SERVER` / `SQL_DATABASE` / `SQL_USER` / `SQL_PASSWORD` variables must be set.

---

## Client Modules

The spec drives two auto-generated client modules (regenerated by CI on every spec change):

| Module | Location | Language | Auth helper |
|--------|----------|----------|-------------|
| `FortigiGraphIngestion` | `API/generated/powershell/` | PowerShell | `Get-FGIngestionToken` |
| `fortigigraph_ingestion` | `API/generated/python/` | Python (async) | `_get_token()` on client class |

Both modules version-lock to `API/package.json`, which is kept in sync with `FortigiGraph.psd1`.
