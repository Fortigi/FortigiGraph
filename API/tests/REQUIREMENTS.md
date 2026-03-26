# Ingestion API – Test Requirements

## Scope

Tests cover three independent components:

1. **Node.js API** – the Express application in `API/src/`
2. **Python generator & client** – `API/generators/generate-python.py` and its output
3. **PowerShell generator & module** – `API/generators/generate-powershell.ps1` and its output

---

## Constraints

- **No real infrastructure required.** All tests run without an Azure AD tenant, SQL Server, or network access.
- **All external I/O is mocked** at the lowest sensible boundary (DB pool, `Invoke-RestMethod`, `httpx.AsyncClient`).
- **Tests are self-contained** per suite; no shared state between Node, Python, and PowerShell suites.
- **Generator tests use an embedded minimal spec** so they do not depend on the current state of `openapi.yaml`, but also include real-spec smoke tests (skipped when the file is absent).

---

## Node.js API Tests

**Framework:** Jest + supertest
**Location:** `API/tests/unit/`, `API/tests/integration/`

### Unit: Auth middleware (`auth.test.js`)

| # | Requirement |
|---|-------------|
| 1 | Returns `next()` and sets `req.user = { sub: 'anonymous', roles: [] }` when `AUTH_ENABLED=false` |
| 2 | Returns HTTP 401 when the `Authorization` header is absent |
| 3 | Returns HTTP 401 when the header is not a Bearer token |
| 4 | Returns HTTP 401 when `jwt.verify` produces an error (expired, malformed, etc.) |
| 5 | Returns HTTP 401 when the token `tid` claim does not match `AZURE_TENANT_ID` |
| 6 | Returns HTTP 403 when the token lacks a role listed in `AUTH_REQUIRED_ROLES` |
| 7 | Returns `next()` and populates `req.user` on a fully valid token |
| 8 | Returns `next()` when the required role is present in the token's `roles` claim |

### Unit: Route helpers (`helpers.test.js`)

| # | Requirement |
|---|-------------|
| 1 | `inferSqlType` maps `boolean` → `Bit` |
| 2 | `inferSqlType` maps integer `number` → `Int` |
| 3 | `inferSqlType` maps non-integer `number` → `Float` |
| 4 | `inferSqlType` maps UUID-formatted string → `UniqueIdentifier` |
| 5 | `inferSqlType` maps ISO 8601 date string → `DateTime2` |
| 6 | `inferSqlType` maps plain string → `NVarChar` |
| 7 | `inferSqlType` maps `null` / `undefined` → `NVarChar` |
| 8 | `sanitizeError` strips SQL bracket annotations (`[dbo]`, `[TableName]`, etc.) from error messages |
| 9 | `sanitizeError` truncates messages longer than 200 characters |
| 10 | `sanitizeError` returns a non-empty fallback for an empty error message |

### Integration: HTTP routes (`api.test.js`)

**Mocked:** `db/connection` pool and all `pool.request().query()` calls.

| Area | Requirement |
|------|-------------|
| Health | `GET /api/v1/ingestion/health` returns HTTP 200, `{ status: 'ok', version, timestamp }` without authentication |
| 404 | Unknown paths return HTTP 404 |
| List users | `GET /users` returns `{ data, total, page, limit }` |
| List users | `$page` and `$limit` query parameters are reflected in the response |
| Get user | `GET /users/:id` returns the user object when found |
| Get user | Returns HTTP 404 with `{ code: 'NOT_FOUND' }` when not found |
| Upsert user | `POST /users` with `{ id, ... }` returns HTTP 200 and echoes the record |
| Upsert user | Returns HTTP 400 with `{ code: 'BAD_REQUEST' }` when `id` is absent |
| Update user | `PUT /users/:id` returns HTTP 200 when the record exists |
| Update user | Returns HTTP 404 when the record does not exist |
| Delete user | `DELETE /users/:id` returns HTTP 204 when the record exists |
| Delete user | Returns HTTP 404 when the record does not exist |
| Batch upsert | `POST /users/batch` returns `{ inserted, updated }` counts |
| Batch upsert | Returns HTTP 400 when `records` is not an array |
| Batch upsert | Returns HTTP 400 when the batch exceeds 1 000 records |
| Composite key | `GET /group-members?groupId=...` returns paginated list |
| Composite key | `POST /group-members` with `{ groupId, memberId }` returns HTTP 200 |
| Composite key | `POST /group-members` without `memberId` returns HTTP 400 |
| Composite key | `DELETE /group-members/:groupId/:memberId` returns HTTP 204 when found |
| Composite key | `DELETE /group-members/:groupId/:memberId` returns HTTP 404 when not found |
| Auth enforce | With `AUTH_ENABLED=true`, requests without a token return HTTP 401 `{ code: 'UNAUTHORIZED' }` |
| Auth enforce | `/health` remains accessible without a token even when auth is enabled |

---

## Python Tests

**Framework:** pytest + pytest-asyncio
**Location:** `API/tests/python/`

### Generator (`test_generator.py`)

| # | Requirement |
|---|-------------|
| 1 | Generator creates `models.py`, `client.py`, `__init__.py` in the output directory |
| 2 | Generator creates `pyproject.toml` alongside the package directory |
| 3 | `pyproject.toml` contains the version passed to the generator |
| 4 | A schema named `Widget` produces `class Widget(BaseModel):` in `models.py` |
| 5 | Required properties are non-optional; optional properties use `Optional[T]` |
| 6 | `string` maps to `Optional[str]`, `integer` → `Optional[int]`, `boolean` → `Optional[bool]`, `date-time` → `Optional[datetime]` |
| 7 | One async method is generated per `operationId` (`list_widgets`, `upsert_widget`, `get_widget`, `delete_widget`) |
| 8 | All generated `.py` files pass Python `compile()` without `SyntaxError` |
| 9 | `__init__.py` exports the client class, all model classes, and a `__version__` string |
| 10 | Real-spec smoke test: generator exits 0, produces syntactically valid Python, and `__version__` matches `API/package.json` |

### Generated client (`test_client.py`)

| # | Requirement |
|---|-------------|
| 1 | `_get_token()` calls the `oauth2/v2.0/token` endpoint with the configured tenant |
| 2 | Cached token is returned without a network call when still valid |
| 3 | Token is refreshed when it expires within 60 seconds |
| 4 | `_request()` constructs the URL as `{base_url}/api/v1/ingestion{path}` |
| 5 | All requests include `Authorization: Bearer {token}` |
| 6 | HTTP 204 responses return `None` |
| 7 | Non-2xx responses raise `RuntimeError` containing the status code |
| 8 | `async with client as c:` enters and exits cleanly, calling `aclose()` on the HTTP client |
| 9 | All 18 expected entity methods are present on the generated client class |

---

## PowerShell Tests

**Framework:** Pester v5
**Location:** `API/tests/powershell/`
**Dependencies:** `Pester >= 5.5`, `powershell-yaml`

### Generator (`Generator.Tests.ps1`)

| # | Requirement |
|---|-------------|
| 1 | Output directory is created |
| 2 | `FortigiGraphIngestion.psm1` and `FortigiGraphIngestion.psd1` are created |
| 3 | `Functions/` subdirectory exists and contains at least one `.ps1` file |
| 4 | `Functions/Auth.ps1` is created |
| 5 | `.psd1` `ModuleVersion` matches the version argument |
| 6 | `.psd1` `RootModule` points to the `.psm1` file |
| 7 | `FunctionsToExport` contains `Get-FGIngestionToken` and `Invoke-FGIngestionRequest` |
| 8 | `FunctionsToExport` has more than 2 entries |
| 9 | Generated functions follow `Verb-FGIngestionNoun` naming (`Get-`, `New-`, `Set-`, `Remove-`) |
| 10 | Each function declares an alias (without the `FGIngestion` prefix) |
| 11 | Each function uses `[cmdletbinding()]` or `[CmdletBinding()]` |
| 12 | Module imports without errors via `Import-Module` |
| 13 | Real-spec smoke test: `ModuleVersion` matches `API/package.json`, all 12 entity types exported, module imports cleanly |

### Generated module (`Module.Tests.ps1`)

| # | Requirement |
|---|-------------|
| 1 | `Get-FGIngestionToken` calls `oauth2/v2.0/token` for the specified tenant |
| 2 | `Get-FGIngestionToken` sets `$Global:FGIngestionToken` to the returned `access_token` |
| 3 | `Get-FGIngestionToken` sets `$Global:FGIngestionBaseUrl` and trims trailing slashes |
| 4 | `Get-FGIngestionToken` returns the full response object |
| 5 | `Invoke-FGIngestionRequest` builds the correct full URI |
| 6 | `Invoke-FGIngestionRequest` sends `Authorization: Bearer {token}` |
| 7 | `Invoke-FGIngestionRequest -Method POST -Body` serializes and sends the body |
| 8 | `Invoke-FGIngestionRequest` throws when `$Global:FGIngestionToken` is null |
| 9 | Generated list functions (`Get-FGIngestion*`) call the API and return results |
| 10 | `Remove-FGIngestionUser -id <guid>` calls `Invoke-RestMethod` with `Method = 'DELETE'` |

---

## CI Pipeline

**File:** `.github/workflows/test-ingestion-api.yml`
**Trigger:** Any push or pull request touching `API/**`

| Job | Runner | What it does |
|-----|--------|--------------|
| `test-nodejs` | ubuntu-latest | `npm install` → Jest unit suite → Jest integration suite; uploads coverage artifact |
| `test-python` | ubuntu-latest | `pip install` pytest deps → `pytest API/tests/python/`; uploads coverage XML |
| `test-powershell` | ubuntu-latest | Installs Pester + powershell-yaml → runs Generator and Module suites; uploads JUnit XML |
| `test-docker` | ubuntu-latest | `docker build` → starts container → waits for `HEALTHCHECK` → `curl /health` returns `"status":"ok"` |

All four jobs run in parallel.
