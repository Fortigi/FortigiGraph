# RFC-001: Inbound Ingest API Layer

> **Status:** Draft
> **Author:** Wim van den Heijkant / Claude
> **Date:** 2026-03-30
> **Branch:** `feature/ingest-api`

---

## 1. Motivation

Today, FortigiGraph has two tightly-coupled sync paths:

1. **`Start-FGSync`** — runs inside the PowerShell module, calls Graph API directly, writes to SQL via `Invoke-FGSQLBulkMerge`.
2. **`Start-FGCSVSync`** — runs inside the PowerShell module, reads CSV files from disk, writes to SQL via the same bulk merge.

Both paths require the crawler logic to run **inside** the PowerShell module with direct SQL access. This creates several problems:

| Problem | Impact |
|---------|--------|
| Crawlers need SQL credentials | Security risk; credentials spread across environments |
| Can't write crawlers in Python, Go, etc. | Locked into PowerShell for all integrations |
| CSV files must be on the same machine | No remote ingestion; limits deployment flexibility |
| Adding a new source system requires a new `Sync-FG*` function in the module | High coupling; slow to extend |
| Azure Automation sandbox limits (400 MB) force batching workarounds | Complexity pushed into every crawler |
| No way for third parties to push data | Only pull-based; can't receive webhooks |

### Goal

Add an **inbound API layer** that:
- Accepts data conforming to the Universal Data Model via REST endpoints
- Handles all SQL complexity (bulk merge, delete detection, temporal versioning, schema evolution)
- Allows crawlers to be simple HTTP clients in any language
- Publishes an OpenAPI/Swagger spec so clients can be auto-generated
- Supports self-contained authentication (no external IdP dependency for crawlers)

---

## 2. Proposed Architecture

```
                    ┌─────────────────────────────────────┐
                    │        Crawler Scripts               │
                    │  (PowerShell, Python, Go, etc.)      │
                    │                                       │
                    │  EntraID    Omada     SailPoint  AD   │
                    │  Crawler    Crawler   Crawler    ...  │
                    └────┬──────────┬──────────┬───────────┘
                         │          │          │
                         │   HTTPS + Bearer Token (API Key)
                         │          │          │
                    ┌────▼──────────▼──────────▼───────────┐
                    │         Ingest API Layer              │
                    │     (Express.js routes)               │
                    │                                       │
                    │  POST /api/ingest/systems             │
                    │  POST /api/ingest/principals          │
                    │  POST /api/ingest/resources           │
                    │  POST /api/ingest/resource-assignments│
                    │  POST /api/ingest/resource-relationships│
                    │  POST /api/ingest/identities          │
                    │  POST /api/ingest/contexts            │
                    │  POST /api/ingest/governance/catalogs │
                    │  POST /api/ingest/governance/policies │
                    │  POST /api/ingest/governance/requests │
                    │  POST /api/ingest/governance/certifications│
                    │                                       │
                    │  Auth: /api/crawlers (register, rotate)│
                    │  Swagger: /api/docs                   │
                    ├───────────────────────────────────────┤
                    │  Ingest Engine                        │
                    │  - Validation & normalization         │
                    │  - Deterministic GUID generation      │
                    │  - Bulk MERGE (temp table pattern)    │
                    │  - Scoped delete detection            │
                    │  - Sync logging                       │
                    │  - View/index refresh                 │
                    ├───────────────────────────────────────┤
                    │  Azure SQL (temporal tables)          │
                    └───────────────────────────────────────┘
```

### 2.1 Where the API Lives

The ingest API is added to the **existing Express.js backend** (`UI/backend/`). It already has:
- SQL connection pooling (`db/connection.js`)
- Auth middleware infrastructure (`middleware/auth.js`)
- Helmet, CORS, rate limiting
- Performance metrics
- Graceful shutdown

Adding a new route module (`routes/ingest.js`) and a new auth scheme (`middleware/crawlerAuth.js`) is the simplest path. The UI backend becomes a **unified API server** serving both the frontend and crawlers.

### 2.2 Ingest API Design

#### Core Principle: Batch-Oriented Full Sync

Each ingest endpoint accepts a **batch of records** for a given entity type and system. The API then:

1. **Validates** all records against the schema
2. **Normalizes** data (type coercion, deterministic GUID generation for non-GUID IDs)
3. **Bulk MERGEs** into the target table (INSERT new, UPDATE changed)
4. **Scoped delete detection** — if the caller signals `fullSync: true`, records in this system+scope that are NOT in the batch are deleted
5. **Logs** the sync operation to `GraphSyncLog`
6. **Returns** a summary: `{ inserted, updated, deleted, errors }`

#### Endpoint Design

All ingest endpoints follow the same pattern:

```
POST /api/ingest/{entity-type}
Authorization: Bearer <crawler-api-key>
Content-Type: application/json

{
  "systemId": 3,                    // Required: which system this data belongs to
  "syncMode": "full" | "delta",    // full = delete detection; delta = upsert only
  "scope": {                        // Optional: narrow delete scope
    "resourceType": "Group",        //   e.g., only delete Groups, not AppRoles
    "assignmentType": "Direct"      //   e.g., only delete Direct, not Governed
  },
  "records": [
    { "id": "...", "displayName": "...", ... },
    { "id": "...", "displayName": "...", ... }
  ]
}
```

Response:

```json
{
  "syncId": "uuid",
  "table": "Resources",
  "inserted": 142,
  "updated": 38,
  "deleted": 7,
  "errors": [],
  "durationMs": 2340
}
```

#### Entity Endpoints

| Endpoint | Target Table | Key Column(s) | Scope Filters |
|----------|-------------|----------------|---------------|
| `POST /api/ingest/systems` | Systems | `id` (INT, auto-assigned) | — |
| `POST /api/ingest/principals` | Principals | `id` (GUID) | `principalType` |
| `POST /api/ingest/resources` | Resources | `id` (GUID) | `resourceType` |
| `POST /api/ingest/resource-assignments` | ResourceAssignments | `(resourceId, principalId, assignmentType)` | `assignmentType` |
| `POST /api/ingest/resource-relationships` | ResourceRelationships | `(parentResourceId, childResourceId, relationshipType)` | `relationshipType` |
| `POST /api/ingest/identities` | Identities | `id` (GUID) | — |
| `POST /api/ingest/identity-members` | IdentityMembers | `(identityId, principalId)` | — |
| `POST /api/ingest/contexts` | Contexts | `id` (GUID) | `contextType` |
| `POST /api/ingest/governance/catalogs` | GovernanceCatalogs | `id` (GUID) | — |
| `POST /api/ingest/governance/policies` | AssignmentPolicies | `id` (GUID) | — |
| `POST /api/ingest/governance/requests` | AssignmentRequests | `id` (GUID) | — |
| `POST /api/ingest/governance/certifications` | CertificationDecisions | `id` (GUID) | — |

#### System Registration

Before ingesting data, a crawler must have a system registered:

```
POST /api/ingest/systems
{
  "records": [{
    "systemType": "EntraID",
    "displayName": "Contoso Entra ID",
    "tenantId": "abc-123",
    "enabled": true,
    "syncEnabled": true
  }]
}

Response:
{
  "syncId": "...",
  "inserted": 1,
  "systemIds": [{ "systemType": "EntraID", "tenantId": "abc-123", "id": 5 }]
}
```

The returned `id` is used as `systemId` in all subsequent calls.

#### Deterministic GUID Generation

For source systems that don't use GUIDs (e.g., Omada uses integer IDs), the API generates deterministic GUIDs:

```
POST /api/ingest/resources
{
  "systemId": 3,
  "idGeneration": "deterministic",  // Options: "native" (default), "deterministic"
  "idPrefix": "omada-resource",      // Namespace for deterministic generation
  "records": [
    { "externalId": "12345", "displayName": "Admin Role", ... }
  ]
}
```

When `idGeneration: "deterministic"`, the API generates: `MD5(idPrefix + ":" + externalId)` as UUID v3, matching the current CSV sync pattern.

#### Sync Modes

| Mode | Behavior | Use Case |
|------|----------|----------|
| `full` | MERGE all records + DELETE records in scope not in batch | Scheduled full sync (replaces current pattern) |
| `delta` | MERGE only; no deletes | Real-time webhook, incremental changes |

#### Payload Size & Chunking

- **Default limit:** 10 MB per request (configurable via `INGEST_BODY_LIMIT`)
- **Record limit:** 50,000 records per batch
- For larger datasets, crawlers send multiple requests. The API handles this via **sync sessions**:

```
POST /api/ingest/resources
{ "systemId": 3, "syncMode": "full", "syncSession": "start", "records": [...] }

POST /api/ingest/resources
{ "systemId": 3, "syncMode": "full", "syncSession": "continue", "syncId": "uuid-from-first", "records": [...] }

POST /api/ingest/resources
{ "systemId": 3, "syncMode": "full", "syncSession": "end", "syncId": "uuid-from-first", "records": [...] }
```

- `start`: Creates temp table, MERGEs first batch
- `continue`: MERGEs additional batches into same temp table
- `end`: MERGEs final batch, runs scoped delete, drops temp table, logs sync

This replaces the current `syncBatchId` pattern and avoids loading all data into memory.

### 2.3 Crawler Authentication

#### Design: Self-Contained API Keys

No external IdP dependency. The API manages its own crawler credentials.

#### Database Tables

```sql
CREATE TABLE dbo.Crawlers (
    id              INT IDENTITY(1,1) PRIMARY KEY,
    displayName     NVARCHAR(255) NOT NULL,
    description     NVARCHAR(MAX),
    apiKeyHash      VARBINARY(64) NOT NULL,        -- SHA-256 of the API key
    apiKeySalt      VARBINARY(32) NOT NULL,         -- Random salt per key
    apiKeyPrefix    NVARCHAR(8) NOT NULL,           -- First 8 chars for identification (fgc_xxxx)
    systemIds       NVARCHAR(MAX),                  -- JSON array of allowed system IDs (null = all)
    permissions     NVARCHAR(MAX) NOT NULL,          -- JSON array: ["ingest", "read", "admin"]
    enabled         BIT NOT NULL DEFAULT 1,
    createdAt       DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    createdBy       NVARCHAR(255),
    lastUsedAt      DATETIME2,
    lastRotatedAt   DATETIME2,
    expiresAt       DATETIME2,                       -- Optional expiry
    rateLimit       INT DEFAULT 100                  -- Requests per minute (per crawler)
);

CREATE TABLE dbo.CrawlerAuditLog (
    id              INT IDENTITY(1,1) PRIMARY KEY,
    crawlerId       INT NOT NULL,
    action          NVARCHAR(50) NOT NULL,           -- 'authenticate', 'ingest', 'rotate', 'disabled'
    endpoint        NVARCHAR(255),
    recordCount     INT,
    statusCode      INT,
    ipAddress       NVARCHAR(45),
    timestamp       DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
);
```

#### Key Format

```
fgc_<random-32-chars>
```

Example: `fgc_a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6`

- Prefix `fgc_` makes keys recognizable (FortigiGraph Crawler)
- Only the **hash** is stored; the plaintext key is shown once at creation time
- The `apiKeyPrefix` column stores the first 8 chars for key identification without exposing the full key

#### Admin Endpoints (Entra ID Auth Required)

These endpoints are used from the UI admin page. They require Entra ID authentication (existing auth middleware).

```
GET    /api/admin/crawlers              — List all crawlers (without keys)
POST   /api/admin/crawlers              — Register new crawler, returns plaintext key ONCE
PATCH  /api/admin/crawlers/:id          — Update name, description, enabled, systemIds, permissions
DELETE /api/admin/crawlers/:id          — Disable (soft-delete) crawler
GET    /api/admin/crawlers/:id/audit    — View audit log for a crawler
POST   /api/admin/crawlers/:id/reset    — Admin-initiated key reset, returns new key
```

#### Crawler Self-Service Endpoints (API Key Auth)

```
POST   /api/crawlers/rotate             — Rotate own key (provide current key, get new key)
GET    /api/crawlers/whoami             — Return crawler metadata (name, allowed systems, permissions)
```

#### Key Rotation Flow

```
POST /api/crawlers/rotate
Authorization: Bearer fgc_current_key_here

Response:
{
  "apiKey": "fgc_new_key_here",         // New key (shown once)
  "expiresAt": "2026-06-30T00:00:00Z",  // Optional
  "rotatedAt": "2026-03-30T14:00:00Z"
}
```

The old key is immediately invalidated. This enables automated secret rollover:

```python
# Example: Python crawler auto-rotation
new_key = requests.post("/api/crawlers/rotate",
    headers={"Authorization": f"Bearer {current_key}"}).json()["apiKey"]
save_to_vault(new_key)
```

#### Auth Middleware Chain

```
Request arrives
  │
  ├─ /api/ingest/*  → crawlerAuth middleware (API key)
  ├─ /api/crawlers/* → crawlerAuth middleware (API key, self-service only)
  ├─ /api/admin/crawlers/* → existing Entra ID auth middleware
  └─ /api/* (other) → existing Entra ID auth middleware
```

#### Rate Limiting

Per-crawler rate limits stored in the `Crawlers` table. Default: 100 requests/minute. The middleware tracks request counts in memory (no Redis dependency) with a sliding window.

### 2.4 OpenAPI / Swagger

The API serves an OpenAPI 3.0 spec and Swagger UI:

- `GET /api/docs` — Swagger UI (interactive documentation)
- `GET /api/docs/openapi.json` — OpenAPI 3.0 spec file

The spec is auto-generated from the route definitions using `swagger-jsdoc` (JSDoc annotations on routes) or maintained as a static YAML file.

From this spec, crawlers can auto-generate clients:

```bash
# Generate PowerShell client
npx @openapitools/openapi-generator-cli generate -i openapi.json -g powershell -o ./crawler-client-ps

# Generate Python client
npx @openapitools/openapi-generator-cli generate -i openapi.json -g python -o ./crawler-client-py
```

### 2.5 Ingest Engine (Server-Side Logic)

The ingest engine encapsulates all the complexity that currently lives in `Sync-FG*.ps1` and `Invoke-FGSQLBulk*.ps1`:

```
UI/backend/src/
├── ingest/
│   ├── engine.js              — Core MERGE + delete detection logic
│   ├── validation.js          — Schema validation per entity type
│   ├── normalization.js       — Type coercion, GUID generation, extendedAttributes packing
│   ├── schemas/               — JSON Schema definitions per entity type
│   │   ├── principal.schema.json
│   │   ├── resource.schema.json
│   │   ├── resourceAssignment.schema.json
│   │   └── ...
│   └── sessions.js            — Sync session management (start/continue/end)
├── routes/
│   ├── ingest.js              — Ingest endpoints
│   └── crawlers.js            — Crawler management endpoints
├── middleware/
│   ├── auth.js                — Existing Entra ID auth (unchanged)
│   └── crawlerAuth.js         — API key auth for crawlers
```

#### Engine Operations (engine.js)

The engine replicates the current `Invoke-FGSQLBulkMerge` + scoped delete pattern in JavaScript using the `mssql` npm package:

1. **Create temp table** with matching schema
2. **Bulk insert** records into temp table (using `mssql` Table/BulkLoad)
3. **MERGE** from temp table into target
4. **Scoped delete** (if `syncMode: "full"`) using the same patterns:
   - System-scoped: `WHERE systemId = @systemId`
   - Attribute-scoped: `WHERE resourceType = @scope` (if provided)
   - Temporal-scoped: `WHERE ValidTo = '9999-12-31 23:59:59.9999999'`
   - Batch-scoped: `AND NOT EXISTS (SELECT 1 FROM #temp WHERE ...)`
5. **Drop temp table**
6. **Write sync log** to `GraphSyncLog`

#### Validation Rules (validation.js)

Per-entity-type validation using JSON Schema:

| Field | Rule |
|-------|------|
| `id` (GUID) | Valid UUID v4 format, or `externalId` + `idGeneration: "deterministic"` |
| `systemId` | Must exist in Systems table AND be in crawler's allowed systems |
| `displayName` | Required, max 255 chars |
| `principalType` | Must be one of: `User`, `ServicePrincipal`, `ManagedIdentity`, `WorkloadIdentity`, `AIAgent`, `ExternalUser`, `SharedMailbox` |
| `resourceType` | Must be one of: `Group`, `DirectoryRole`, `AppRole`, `BusinessRole`, `Site`, `Team`, etc. |
| `assignmentType` | Must be one of: `Direct`, `Indirect`, `Eligible`, `Owner`, `Governed` |
| `relationshipType` | Must be one of: `Contains`, `GrantsAccessTo` |
| `extendedAttributes` | Valid JSON object, max 64 KB |

#### View Refresh

After ingest completes, the engine optionally triggers materialized view refresh:

```
POST /api/ingest/resources
{ ..., "refreshViews": true }
```

This calls the equivalent of `Sync-FGMaterializedViews` — refreshing `mat_UserPermissionAssignments` and other cached views.

---

## 3. Impact Analysis

### 3.1 Files That Change

#### UI Backend (Primary Changes)

| File | Change | Effort |
|------|--------|--------|
| `UI/backend/package.json` | Add: `swagger-jsdoc`, `swagger-ui-express`, `uuid`, `ajv` (JSON Schema validation), `crypto` (built-in) | S |
| `UI/backend/src/index.js` | Register new routes: `/api/ingest`, `/api/crawlers`, `/api/admin/crawlers`, `/api/docs`; add body limit for ingest | S |
| **NEW** `UI/backend/src/routes/ingest.js` | All ingest endpoints (12 entity types) | XL |
| **NEW** `UI/backend/src/routes/crawlers.js` | Crawler management + self-service endpoints | L |
| **NEW** `UI/backend/src/middleware/crawlerAuth.js` | API key validation middleware | M |
| **NEW** `UI/backend/src/ingest/engine.js` | Core bulk merge + scoped delete in JS | XL |
| **NEW** `UI/backend/src/ingest/validation.js` | JSON Schema validation per entity type | L |
| **NEW** `UI/backend/src/ingest/normalization.js` | GUID generation, type coercion, extendedAttributes | M |
| **NEW** `UI/backend/src/ingest/sessions.js` | Sync session state management | M |
| **NEW** `UI/backend/src/ingest/schemas/*.json` | JSON Schema per entity type (12 files) | L |
| **NEW** `UI/backend/src/openapi.yaml` or JSDoc annotations | OpenAPI 3.0 spec | L |

#### SQL (Schema Additions)

| File | Change | Effort |
|------|--------|--------|
| **NEW** `Functions/SQL/Initialize-FGCrawlerTables.ps1` | Create `Crawlers` + `CrawlerAuditLog` tables | M |
| `Functions/SQL/Initialize-FGSystemTables.ps1` | Possibly no change — tables already support the universal model | — |

#### PowerShell Crawlers (Refactored from Current Sync)

| File | Change | Effort |
|------|--------|--------|
| **NEW** `Crawlers/EntraID/Sync-EntraIDPrincipals.ps1` | Fetch from Graph, POST to ingest API | L |
| **NEW** `Crawlers/EntraID/Sync-EntraIDResources.ps1` | Fetch groups/roles, POST to ingest API | L |
| **NEW** `Crawlers/EntraID/Sync-EntraIDAssignments.ps1` | Fetch memberships, POST to ingest API | L |
| **NEW** `Crawlers/EntraID/Sync-EntraIDGovernance.ps1` | Fetch APs/catalogs/reviews, POST to ingest API | XL |
| **NEW** `Crawlers/CSV/Sync-CSVData.ps1` | Read CSVs, POST to ingest API | L |
| **NEW** `Crawlers/Start-Crawler.ps1` | Orchestrator: auth, system reg, run crawlers | M |
| `Functions/Sync/Start-FGSync.ps1` | **Deprecate** or refactor to call ingest API instead of SQL directly | L |
| `Functions/Sync/Start-FGCSVSync.ps1` | **Deprecate** or refactor to call ingest API instead of SQL directly | L |

#### UI Frontend (Admin Page)

| File | Change | Effort |
|------|--------|--------|
| **NEW** `UI/frontend/src/components/CrawlersPage.jsx` | Admin page: list crawlers, register, rotate keys, view audit log | L |
| `UI/frontend/src/App.jsx` | Add Crawlers tab to admin section | S |

#### Module Manifest & Docs

| File | Change | Effort |
|------|--------|--------|
| `FortigiGraph.psd1` | Version bump | S |
| `CHANGES.md` | Document the change | S |
| `CLAUDE.md` | Update architecture docs | M |
| `README.md` | Update getting started to cover crawler setup | M |

### 3.2 Files That DON'T Change

These files remain untouched — they already follow the universal data model:

- All `Functions/SQL/Initialize-FG*Tables.ps1` — table schemas are correct as-is
- All `Functions/SQL/Initialize-FG*Views.ps1` — views query the same tables
- All `Functions/SQL/Initialize-FG*Indexes.ps1` — indexes remain valid
- All `Functions/Generic/*.ps1` — Graph API wrappers unchanged
- All `Functions/RiskScoring/*.ps1` — risk scoring reads from the same tables
- All UI frontend components except the new admin page — they read from the same SQL tables
- All UI backend read routes — they query the same tables

### 3.3 Breaking Changes

| Change | Who is Affected | Migration Path |
|--------|----------------|----------------|
| `Start-FGSync` deprecated | Users running scheduled syncs via Automation Account | Update runbooks to use crawler scripts |
| `Start-FGCSVSync` deprecated | Users doing CSV imports | Use CSV crawler script or call ingest API directly |
| New `Crawlers` table | DB admins | Auto-created on first API start |
| API server now requires crawler tables | Fresh deployments | `Initialize-FGCrawlerTables` called at startup |

### 3.4 What Stays Backward Compatible

- **All existing SQL tables** — unchanged schema
- **All UI read endpoints** — same response format
- **All views and indexes** — query the same underlying tables
- **Temporal versioning** — merge + delete pattern preserved
- **Sync log** — same `GraphSyncLog` table, same format
- **Tags, categories, risk scores** — completely unaffected
- **PowerShell module** — existing functions still work; new crawlers are additive

---

## 4. Plan of Approach

### Phase 0: Foundation (Prep)

> Branch: `feature/ingest-api`

- [ ] Create `Crawlers` and `CrawlerAuditLog` table initialization (`Initialize-FGCrawlerTables.ps1`)
- [ ] Create `crawlerAuth.js` middleware (API key validation, rate limiting)
- [ ] Create crawler admin routes (`/api/admin/crawlers`) for registration, key management
- [ ] Create crawler self-service routes (`/api/crawlers/rotate`, `/api/crawlers/whoami`)
- [ ] Add Crawlers admin page in frontend
- [ ] **Validate:** Register a crawler, get a key, authenticate with it, rotate the key

### Phase 1: Ingest Engine Core

- [ ] Port `Invoke-FGSQLBulkMerge` pattern to JavaScript (`ingest/engine.js`)
  - Temp table creation from column schema
  - `mssql` BulkLoad into temp table
  - MERGE statement generation
  - Scoped delete detection
  - Sync log writing
- [ ] Implement JSON Schema validation (`ingest/validation.js`)
- [ ] Implement normalization: type coercion, deterministic GUID generation (`ingest/normalization.js`)
- [ ] Implement sync sessions for chunked uploads (`ingest/sessions.js`)
- [ ] **Validate:** Unit test engine with mock data against real SQL database

### Phase 2: Ingest Endpoints

- [ ] `POST /api/ingest/systems` — with auto-ID return
- [ ] `POST /api/ingest/principals` — with principalType scoping
- [ ] `POST /api/ingest/resources` — with resourceType scoping
- [ ] `POST /api/ingest/resource-assignments` — with composite key + assignmentType scoping
- [ ] `POST /api/ingest/resource-relationships` — with composite key + relationshipType scoping
- [ ] `POST /api/ingest/identities` + `POST /api/ingest/identity-members`
- [ ] `POST /api/ingest/contexts`
- [ ] Governance endpoints: catalogs, policies, requests, certifications
- [ ] Optional: `POST /api/ingest/refresh-views` — trigger materialized view refresh
- [ ] **Validate:** Use curl/Postman to ingest a small dataset, verify data in SQL matches expectations

### Phase 3: OpenAPI Spec & Swagger

- [ ] Write OpenAPI 3.0 spec (or annotate routes with `swagger-jsdoc`)
- [ ] Serve Swagger UI at `/api/docs`
- [ ] Serve raw spec at `/api/docs/openapi.json`
- [ ] **Validate:** Generate a PowerShell client from the spec; verify it compiles

### Phase 4: EntraID Crawler

Refactor `Start-FGSync` into a standalone crawler that uses the ingest API:

- [ ] `Crawlers/EntraID/Sync-EntraIDPrincipals.ps1` — fetch users from Graph, POST to `/api/ingest/principals`
- [ ] `Crawlers/EntraID/Sync-EntraIDResources.ps1` — fetch groups/roles, POST to `/api/ingest/resources`
- [ ] `Crawlers/EntraID/Sync-EntraIDAssignments.ps1` — fetch memberships, POST to `/api/ingest/resource-assignments`
- [ ] `Crawlers/EntraID/Sync-EntraIDGovernance.ps1` — fetch APs, catalogs, reviews, POST to governance endpoints
- [ ] `Crawlers/EntraID/Sync-EntraIDRelationships.ps1` — discover resource relationships, POST to `/api/ingest/resource-relationships`
- [ ] `Crawlers/Start-EntraIDCrawler.ps1` — orchestrator (auth, register system, run all in order, refresh views)
- [ ] **Validate:** Run EntraID crawler against a test tenant, compare SQL results with old `Start-FGSync` output

### Phase 5: CSV Crawler

Refactor `Start-FGCSVSync` into a standalone crawler:

- [ ] `Crawlers/CSV/Sync-CSVData.ps1` — read all CSV types, POST to appropriate ingest endpoints
- [ ] `Crawlers/Start-CSVCrawler.ps1` — orchestrator
- [ ] **Validate:** Run CSV crawler against the Omada test dataset, compare SQL results with old `Start-FGCSVSync` output

### Phase 6: Deprecate Old Sync Path

- [ ] Mark `Start-FGSync` as deprecated (add warning, keep functional)
- [ ] Mark `Start-FGCSVSync` as deprecated
- [ ] Update `New-FGAzureAutomationAccount` to deploy crawler scripts instead of sync functions
- [ ] Update documentation

### Phase 7: Example Python Crawler (Optional, Demonstrates Extensibility)

- [ ] `Crawlers/Examples/python-entra-crawler/` — minimal Python crawler using `requests` + auto-generated client
- [ ] Demonstrates the value proposition: any language can now feed data into FortigiGraph

---

## 5. Validation Plan

### 5.1 Unit Tests

| Test | What It Validates |
|------|-------------------|
| **Engine: MERGE correctness** | Insert new records, update changed records, leave unchanged records alone |
| **Engine: Scoped delete** | Full sync removes records not in batch; delta sync does NOT delete |
| **Engine: Delete scope isolation** | Sync for system A does not delete system B's records |
| **Engine: Composite key delete** | ResourceAssignments delete matches on all 3 key columns |
| **Engine: Temporal preservation** | Deleted records appear in history table; `ValidTo` is set correctly |
| **Validation: Schema enforcement** | Missing required fields → 400; invalid types → 400; invalid enums → 400 |
| **Validation: GUID generation** | Deterministic GUIDs are stable across repeated syncs |
| **Auth: API key validation** | Valid key → 200; invalid key → 401; disabled crawler → 403; expired key → 401 |
| **Auth: System scoping** | Crawler scoped to system 3 cannot ingest to system 5 |
| **Auth: Rate limiting** | Exceeding rate limit → 429 |
| **Sessions: Chunked upload** | Start/continue/end produces correct merge + delete result |

### 5.2 Integration Tests (Against Real SQL)

| Test | Steps | Expected Result |
|------|-------|-----------------|
| **Full lifecycle** | Register crawler → create system → ingest principals → ingest resources → ingest assignments → query via UI API | All data visible in UI, correct counts, tags/categories still work |
| **Full sync delete detection** | Ingest 100 resources → ingest 90 resources (full sync) | 10 resources deleted, 90 remain, history shows deletions |
| **Delta sync no-delete** | Ingest 100 resources → ingest 10 resources (delta sync) | 10 updated, 90 untouched, 0 deleted |
| **Cross-system isolation** | Ingest resources for system A → full sync for system B | System A resources untouched |
| **View refresh** | Ingest data → trigger view refresh → query materialized views | Views contain fresh data |
| **Concurrent ingest** | Two crawlers ingest to different systems simultaneously | No data corruption, correct scoped deletes |

### 5.3 Regression Tests (Old vs New Comparison)

This is the most critical validation: **the new path must produce identical results to the old path.**

| Test | Procedure |
|------|-----------|
| **EntraID parity** | 1. Run old `Start-FGSync` against test tenant, snapshot all tables. 2. Clear tables. 3. Run new EntraID crawler against same tenant. 4. Compare all table row counts and checksums. |
| **CSV parity** | 1. Run old `Start-FGCSVSync` against Omada test dataset, snapshot all tables. 2. Clear tables. 3. Run new CSV crawler against same dataset. 4. Compare all table row counts and checksums. |
| **Delete parity** | 1. Old path: sync 100 resources, then sync 90 → verify 10 deleted. 2. New path: same operation. 3. Compare `GraphSyncLog` entries and table states. |

SQL comparison query:
```sql
-- Run after both old and new sync, compare:
SELECT 'Resources' AS [Table], COUNT(*) AS [Count],
       CHECKSUM_AGG(CHECKSUM(*)) AS [Checksum]
FROM dbo.Resources WHERE ValidTo = '9999-12-31 23:59:59.9999999'
UNION ALL
SELECT 'Principals', COUNT(*), CHECKSUM_AGG(CHECKSUM(*))
FROM dbo.Principals WHERE ValidTo = '9999-12-31 23:59:59.9999999'
-- ... etc for all tables
```

### 5.4 Performance Tests

| Test | Target |
|------|--------|
| Ingest 10,000 principals in single batch | < 10 seconds |
| Ingest 100,000 resources in 10 chunked batches | < 60 seconds |
| Ingest 500,000 resource assignments in 50 chunks | < 5 minutes |
| Full sync with delete detection (100K records) | < 2 minutes |
| Concurrent 3-crawler ingest | No deadlocks, < 2x single-crawler time |

### 5.5 Security Tests

| Test | Expected |
|------|----------|
| No auth header → ingest endpoint | 401 |
| Invalid API key | 401 |
| Valid key, wrong system scope | 403 |
| SQL injection in `displayName` field | Parameterized; no injection |
| SQL injection in `extendedAttributes` JSON | Stored as NVARCHAR; no injection |
| Oversized payload (> 10 MB) | 413 |
| Rate limit exceeded | 429 |
| Expired API key | 401 |
| Rotated (old) API key | 401 |

### 5.6 End-to-End Validation Checklist

- [ ] Register a crawler from the admin UI
- [ ] Copy the API key
- [ ] Run the EntraID crawler with the key — verify data appears in the UI
- [ ] Run the CSV crawler with the key — verify data appears alongside EntraID data
- [ ] Verify IST/SOLL matrix still works correctly
- [ ] Verify risk scoring still works on ingested data
- [ ] Verify temporal history (click a resource, see version history)
- [ ] Verify sync log shows entries from API ingestion
- [ ] Rotate the crawler key — verify old key stops working, new key works
- [ ] Disable a crawler — verify it can no longer ingest
- [ ] Delete resources from source — verify they disappear after full sync
- [ ] Run two crawlers simultaneously — verify no data corruption

---

## 6. Open Questions

| # | Question | Options | Recommendation |
|---|----------|---------|----------------|
| 1 | Should the ingest API live in the same Express server or a separate microservice? | Same server / Separate | **Same server** — avoids operational complexity; single deployment; shared DB pool |
| 2 | Should we keep the old `Start-FGSync` / `Start-FGCSVSync` as a fallback? | Keep / Remove | **Keep as deprecated** — some users may have automation depending on it; remove in v4.0 |
| 3 | Where do crawlers live in the repo? | Inside `Functions/` / Separate `Crawlers/` folder | **Separate `Crawlers/` folder** — they're independent scripts, not module functions |
| 4 | Should the ingest API validate foreign keys (e.g., systemId exists)? | Strict / Lenient | **Strict for systemId** (must exist), **lenient for other FKs** (principalId in assignments may not exist yet if sync order varies) |
| 5 | Should we support streaming (NDJSON) in addition to JSON arrays? | Yes / No | **Not in v1** — JSON arrays are simpler; NDJSON can be added later if needed |
| 6 | How should we handle `extendedAttributes` schema validation? | Strict schema / Any JSON object | **Any JSON object** — the whole point is extensibility; schema-per-system can be added later |
| 7 | Should crawlers be able to trigger view refresh, or should that be admin-only? | Crawler / Admin | **Crawler with permission** — add `"refreshViews"` to crawler permissions |
| 8 | Should the OpenAPI spec be hand-written YAML or auto-generated from JSDoc? | YAML / JSDoc | **Hand-written YAML** — more control, serves as source of truth for client generation |

---

## 7. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| **Performance regression** — JS bulk merge slower than PowerShell | Medium | High | Benchmark early (Phase 1); `mssql` BulkLoad is native TDS, should match performance |
| **Data corruption during migration** — old and new paths writing simultaneously | Low | Critical | Never run both paths against the same system; migration guide clear about switchover |
| **Deadlocks** — concurrent crawlers hitting same tables | Medium | Medium | Each crawler scoped to its own system; MERGE uses row-level locks; test concurrent scenarios |
| **Secret leakage** — API keys exposed in logs or error messages | Low | High | Never log keys; only store hashes; mask in audit log; `apiKeyPrefix` for identification |
| **Breaking existing automation** — users on `Start-FGSync` | High | Medium | Deprecation period (keep old path working); clear migration docs; version bump signals change |
| **OpenAPI spec drift** — spec out of sync with implementation | Medium | Low | CI check: validate spec against actual routes; or generate spec from code |
| **Temp table leaks** — crashed sync session leaves temp tables | Low | Low | Session timeout (30 min); cleanup on server restart; named temp tables with timestamp |

---

## 8. Future Extensions (Out of Scope for v1)

These are enabled by the architecture but not built in the initial implementation:

- **Webhook receiver** — source systems push change events; API ingests deltas in real-time
- **NDJSON streaming** — for very large datasets, stream records line-by-line
- **Crawler SDK** — npm/PyPI/PSGallery package with pre-built auth, chunking, retry logic
- **Crawler templates** — "Create new crawler" wizard in admin UI that generates boilerplate code
- **Multi-tenant** — single API serving multiple customer databases
- **Async ingestion** — queue-based: API accepts payload, returns job ID, processes asynchronously
- **Schema registry** — per-system `extendedAttributes` schemas for validation
- **Data quality scoring** — API returns quality metrics (completeness, consistency) per sync
