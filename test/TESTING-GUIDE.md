# Identity Atlas — Complete Testing Guide

> **For human testers** — this guide walks you through testing Identity Atlas end-to-end, from a fresh setup to validating every major feature. Automated test scripts are provided where possible.

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Environment Setup](#2-environment-setup)
3. [Phase 0: PR Checks (No Azure, No Docker)](#3-phase-0-pr-checks-no-azure-no-docker)
4. [Phase 1: Offline Tests (Docker Only)](#4-phase-1-offline-tests-docker-only)
5. [Phase 2: Azure + Graph Setup](#5-phase-2-azure--graph-setup)
6. [Phase 3: SQL + Sync Integration Tests](#6-phase-3-sql--sync-integration-tests)
7. [Phase 4: Risk Scoring Tests](#7-phase-4-risk-scoring-tests)
8. [Phase 5: UI Deployment + Frontend Tests](#8-phase-5-ui-deployment--frontend-tests)
9. [Phase 6: UI Feature Walkthrough (Manual)](#9-phase-6-ui-feature-walkthrough-manual)
10. [Phase 7: Azure Automation Tests](#10-phase-7-azure-automation-tests)
11. [Phase 8: Cleanup](#11-phase-8-cleanup)
12. [Test File Reference](#12-test-file-reference)
13. [CI/CD Pipelines](#13-cicd-pipelines)

---

## 1. Prerequisites

### Azure Requirements

| Requirement | Details |
|---|---|
| **Azure Subscription** | Active subscription with Contributor access |
| **Entra ID (Azure AD)** | At least Reader access; Global Admin to create App Registrations |
| **Entra ID Data** | At least 5 users, 5 groups with members, ideally some access packages |
| **Budget** | ~$5-10/day for test SQL Server + App Service (Basic tiers) |

### Software Requirements

| Software | Version | Install Command |
|---|---|---|
| **PowerShell** | 7.2+ | `winget install Microsoft.PowerShell` |
| **Az PowerShell module** | Latest | `Install-Module Az -Scope CurrentUser` |
| **Node.js** | 20+ | `winget install OpenJS.NodeJS.LTS` (for UI testing only) |
| **Git** | Any | `winget install Git.Git` |

### Optional (for Risk Scoring)

| Requirement | Details |
|---|---|
| **Anthropic API Key** | For LLM-assisted risk profile generation |
| **OR OpenAI API Key** | Alternative LLM provider |

### Entra ID Test Data Checklist

For thorough testing, your tenant should have:

- [ ] **Users** (5+ minimum): Regular users with varying departments, job titles, cities
- [ ] **Groups** (5+ minimum): Mix of security groups and Microsoft 365 groups
- [ ] **Group Members**: At least some groups with 3+ members
- [ ] **Group Owners**: At least 2 groups with assigned owners
- [ ] **Nested Groups** (optional): Group A member of Group B for transitive testing
- [ ] **PIM Eligible Members** (optional): Privileged Identity Management assignments
- [ ] **Access Packages** (optional but recommended): At least 1 catalog with 1 access package, 1 assignment
- [ ] **Access Reviews** (optional): At least 1 completed access review

---

## 2. Environment Setup

### Step 1: Clone and Import

```powershell
git clone https://github.com/Fortigi/FortigiGraph.git
cd FortigiGraph
Import-Module .\IdentityAtlas.psd1 -Force
```

### Step 2: Create Test Config

**Option A: Use the setup wizard (recommended for first-time setup)**

```powershell
New-FGConfig -Path .\_Test\config.test.json
```

This interactively walks you through creating all Azure resources and an App Registration.

**Option B: Copy and edit the template manually**

```powershell
Copy-Item .\Config\tenantname.json.template .\_Test\config.test.json
```

Edit `_Test/config.test.json` and fill in:

```json
{
  "Azure": {
    "TenantId": "YOUR-AZURE-TENANT-ID",
    "SubscriptionId": "YOUR-SUBSCRIPTION-ID",
    "ResourceGroupName": "rg-fortigraph-test",
    "Location": "westeurope",
    "SQLServerName": "sql-fgtest-UNIQUE",
    "DatabaseName": "FortigiGraphTest",
    "AdminUsername": "fgadmin",
    "AdminUserPassword": ""
  },
  "Graph": {
    "TenantId": "YOUR-GRAPH-TENANT-ID",
    "ClientId": "YOUR-APP-CLIENT-ID",
    "ClientSecret": ""
  },
  "Sync": {
    "Users": { "Enabled": true, "TableName": "GraphUsers" },
    "Groups": { "Enabled": true, "TableName": "GraphGroups" },
    "GroupMembers": { "Enabled": true, "TableName": "GraphGroupMembers" },
    "GroupEligibleMembers": { "Enabled": true, "TableName": "GraphGroupEligibleMembers" },
    "GroupOwners": { "Enabled": true, "TableName": "GraphGroupOwners" },
    "Catalogs": { "Enabled": true, "TableName": "GraphCatalogs" },
    "AccessPackages": { "Enabled": true, "TableName": "GraphAccessPackages" },
    "AccessPackageAssignments": { "Enabled": true, "TableName": "GraphAccessPackageAssignments" },
    "AccessPackageResourceRoleScopes": { "Enabled": true, "TableName": "GraphAccessPackageResourceRoleScopes" },
    "AccessPackageAssignmentPolicies": { "Enabled": true, "TableName": "GraphAccessPackageAssignmentPolicies" },
    "AccessPackageAssignmentRequests": { "Enabled": true, "TableName": "GraphAccessPackageAssignmentRequests" },
    "AccessPackageAccessReviews": { "Enabled": true, "TableName": "GraphAccessPackageAccessReviewDecisions" },
    "Views": true,
    "MaterializedViews": false,
    "ParallelExecution": true
  }
}
```

### Step 3: Create App Registration (if not using wizard)

The App Registration needs these **Application permissions** (not Delegated):

| Permission | Purpose |
|---|---|
| `User.Read.All` | Read all users |
| `Group.Read.All` | Read all groups |
| `GroupMember.Read.All` | Read group memberships |
| `Directory.Read.All` | Read directory data |
| `EntitlementManagement.Read.All` | Read access packages |
| `AccessReview.Read.All` | Read access reviews |
| `AuditLog.Read.All` | Read audit/sign-in data |

After creating the app registration, grant admin consent for all permissions.

### Step 4: Login to Azure

```powershell
Connect-AzAccount -TenantId "YOUR-TENANT-ID" -SubscriptionId "YOUR-SUBSCRIPTION-ID"
```

---

## 3. Phase 0: PR Checks (No Azure, No Docker)

These checks run on every pull request and take under 5 minutes. They require nothing beyond a local checkout.

### PSScriptAnalyzer — PowerShell Linting

```powershell
Install-Module PSScriptAnalyzer -Force -Scope CurrentUser
Invoke-ScriptAnalyzer -Path ./Functions -Recurse -Severity Warning,Error
```

### ESLint — JavaScript Linting

```bash
cd app/ui
npm ci
npm run lint
```

### Pester — PowerShell Unit Tests

```powershell
Install-Module Pester -MinimumVersion 5.0.0 -Force -Scope CurrentUser
Invoke-Pester -Path test/unit/IdentityAtlas.Tests.ps1 -Output Detailed
```

**What it tests:**
- Module imports without errors; manifest is valid; version format is `Major.Minor.yyyyMMdd.HHmm`
- All ~130 expected functions are exported (Base, Generic, SQL, Sync, Automation, RiskScoring)
- Removed functions are gone (e.g. `Sync-FGGroupTransitiveMember`)
- All function aliases point to the correct functions
- All `.ps1` files follow `Verb-FGNoun` naming convention
- `[CmdletBinding()]` present on all functions; no Dutch comments; no hardcoded secrets; no `Write-Output`
- Config template exists and is valid JSON with required sections
- Function counts per folder within expected ranges

**Expected result:** All tests pass with 0 failures.

### Vitest — API Unit Tests

```bash
cd app/api
npm ci
npm test
```

**What it tests** (`src/ingest/validation.test.js`, 53 test cases):
- `validateEnvelope`: required fields, array bounds (0–50 000), `syncMode`/`idGeneration` enums, `idPrefix` requirement, `systems` endpoint skips `systemId`
- `validateRecords` for `principals`: required `displayName`, UUID enforcement on `id`/`managerId`, all `principalType` enum values, `maxLength` on string fields, non-string rejection
- `validateRecords` for `resource-assignments`: required triad, all `assignmentType` values
- `validateRecords` for `resource-relationships`: required triad, all `relationshipType` values
- Unknown entity type → error; 10-error cap with "stopped after" message

### npm audit — Dependency Scan

```bash
cd app/ui  && npm audit --audit-level=high
cd app/api && npm audit --audit-level=high
```

### OpenAPI Lint — Spectral

```bash
npm install -g @stoplight/spectral-cli
spectral lint app/api/src/openapi.yaml --ruleset @stoplight/spectral-oas
```

---

## 4. Phase 1: Offline Tests (Docker Only)

These tests validate the full stack locally using Docker. No Azure account needed.

### Start the Docker stack

```bash
docker compose up -d --build
# Wait ~30 seconds for SQL to initialize
```

### Run the Docker integration test suite

```powershell
pwsh -File test/run-docker-tests.ps1
```

Results are written to `test/test-results.md`.

**What it tests (87 checks across 9 categories):**

| Category | Coverage |
|---|---|
| Infrastructure | SQL, backend, worker containers running; table-init exited 0 |
| API | Health, version, features, auth-config, Swagger UI, OpenAPI spec, frontend HTML |
| CrawlerAuth | Register, whoami, invalid key rejection, key rotation, admin list |
| DemoDataset | Generate + ingest via API |
| Schema | 14 expected tables exist |
| DataCounts | Row count minimums for all entity tables after ingest |
| Integrity | No orphan assignments (resourceId / principalId FK checks) |
| BusinessLogic | Principal types, resource types, assignment types, context hierarchy, governance |
| MatrixAPI | Matrix returns user rows; tag create → assign → filter → delete lifecycle |

**Expected result:** 87 passed, 0 failed.

**Teardown:**

```bash
docker compose down -v
```

---

## 5. Phase 2: Azure + Graph Setup

### Run the Simple Diagnostics

```powershell
pwsh -File test/unit/Test-Simple.ps1 -ConfigFile _Test\config.test.json
```

This validates your config file, Azure connection, and module readiness.

### Run Graph API Tests

```powershell
pwsh -File test/unit/Test-GraphAPI.ps1 -ConfigFile _Test\config.test.json
```

**What it tests:**
- Access token acquisition (service principal)
- Token structure validation (required claims present)
- Token expiry is in the future
- Basic Graph API call: `GET /users?$top=1`
- Pagination: fetch first 2 pages of users
- User query: `GET /users/{id}`
- Group query: `GET /groups?$top=5`
- Group members: `GET /groups/{id}/members`
- Access packages: `GET /identityGovernance/entitlementManagement/accessPackages`
- Error handling: invalid endpoint returns proper error

**Expected result:** All tests pass. If you don't have access packages, those tests will be skipped gracefully.

---

## 5. Phase 3: SQL + Sync Integration Tests

### Full Integration Test (First Time)

Creates Azure SQL Server, database, runs all syncs, validates data:

```powershell
pwsh -File _Test\Test-Integration.ps1 -ConfigFile _Test\config.test.json -SkipCleanup
```

**Duration:** 15-30 minutes (Azure resource creation takes ~5 minutes)

**What it tests:**
- SQL Server creation
- Database creation
- Table creation with temporal versioning
- Schema evolution (adding columns to existing tables)
- User sync (default + additional attributes)
- Group sync
- Group member sync (direct, eligible, owners)
- Access package sync (catalogs, packages, assignments, policies, requests, reviews)
- Parallel sync (`Start-FGSync`)
- Point-in-time temporal queries
- View creation and querying
- Data integrity checks

### Fast Regression Test (Subsequent Runs)

Reuses existing SQL Server, clears data, re-syncs:

```powershell
pwsh -File _Test\Test-Integration-Fast.ps1 -ConfigFile _Test\config.test.json
```

**Duration:** 5-10 minutes

### Manual Sync Verification

After the integration test completes, verify data manually:

```powershell
# Connect and query
Connect-FGSQLServer -ConfigFile _Test\config.test.json

# Check row counts
Invoke-FGSQLQuery -Query "SELECT 'Users' AS Entity, COUNT(*) AS Rows FROM GraphUsers
    UNION ALL SELECT 'Groups', COUNT(*) FROM GraphGroups
    UNION ALL SELECT 'Members', COUNT(*) FROM GraphGroupMembers
    UNION ALL SELECT 'Owners', COUNT(*) FROM GraphGroupOwners"

# Check temporal history
Invoke-FGSQLQuery -Query "SELECT TOP 5 displayName, SysStartTime, SysEndTime FROM GraphUsers FOR SYSTEM_TIME ALL ORDER BY SysStartTime DESC"

# Check views
Invoke-FGSQLQuery -Query "SELECT TOP 10 * FROM vw_UserPermissionAssignments"
```

---

## 6. Phase 4: Risk Scoring Tests

### Automated Risk Scoring Test

```powershell
pwsh -File _Test\Test-RiskScoring.ps1 -ConfigFile _Test\config.test.json -LLMProvider Anthropic -LLMApiKey "sk-ant-..."
```

Or with OpenAI:

```powershell
pwsh -File _Test\Test-RiskScoring.ps1 -ConfigFile _Test\config.test.json -LLMProvider OpenAI -LLMApiKey "sk-..."
```

**What it tests:**
- Risk profile generation (LLM-assisted, public domain only)
- Risk profile persistence to SQL
- Risk classifier generation from profile
- Risk classifier persistence to SQL
- Export/import of profiles and classifiers (JSON files)
- Batch scoring of all users and groups
- Score distribution validation (0-100 range, tier assignment)
- Analyst override: set, verify, remove
- Resource clustering

**Duration:** 5-10 minutes (LLM calls take a few seconds each)

### Manual Risk Scoring Verification

```powershell
# Check risk scores exist on users
Invoke-FGSQLQuery -Query "SELECT TOP 10 displayName, riskScore, riskTier FROM GraphUsers WHERE riskScore IS NOT NULL ORDER BY riskScore DESC"

# Check risk scores exist on groups
Invoke-FGSQLQuery -Query "SELECT TOP 10 displayName, riskScore, riskTier FROM GraphGroups WHERE riskScore IS NOT NULL ORDER BY riskScore DESC"

# Check tier distribution
Invoke-FGSQLQuery -Query "SELECT riskTier, COUNT(*) AS Count FROM GraphUsers WHERE riskScore IS NOT NULL GROUP BY riskTier ORDER BY MIN(riskScore) DESC"

# Check an analyst override
Invoke-FGSQLQuery -Query "SELECT displayName, riskScore, riskOverride, riskOverrideReason FROM GraphUsers WHERE riskOverride IS NOT NULL"
```

---

## 7. Phase 5: UI Deployment + Frontend Tests

### Deploy the UI

```powershell
# Deploy with authentication
New-FGUI -ConfigFile _Test\config.test.json

# OR deploy without auth for easier testing
New-FGUI -ConfigFile _Test\config.test.json -NoAuth
```

**Duration:** 10-15 minutes (creates App Service, deploys code via Kudu)

Note the URL printed at the end (e.g., `https://fg-test-ui.azurewebsites.net`).

### Run Backend API Tests

These test the Node.js backend API directly:

```powershell
pwsh -File _Test\Test-UIBackend.ps1 -BaseUrl "https://fg-test-ui.azurewebsites.net"
```

If deployed with authentication, you'll need to pass a token:

```powershell
pwsh -File _Test\Test-UIBackend.ps1 -BaseUrl "https://fg-test-ui.azurewebsites.net" -BearerToken "eyJ0..."
```

**What it tests:**
- `/api/auth-config` endpoint responds
- `/api/permissions` returns user-group matrix data
- `/api/permissions/groups` returns access package groups
- `/api/permissions/sync-log` returns sync history
- `/api/users` returns paginated users with correct attributes
- `/api/groups` returns paginated groups
- `/api/access-packages` returns access packages with catalogs
- `/api/tags` CRUD operations (create, list, assign, unassign, delete)
- `/api/categories` CRUD operations
- `/api/details/user/{id}` returns user details with history
- `/api/details/group/{id}` returns group details with members
- `/api/risk-scores` returns risk score summary (if scoring done)
- `/api/risk-scores/users` returns paginated scored users
- `/api/risk-scores/groups` returns paginated scored groups
- `/api/org-chart` returns manager hierarchy
- `/api/governance/summary` returns review compliance KPIs
- `/api/perf` returns performance metrics (if enabled)
- Error handling: invalid endpoints return 404

### Run UI E2E Tests (Browser Tests)

Playwright E2E tests validate that UI pages render correctly, navigation works, and interactive features function. These run against the **mock backend** — no Azure or SQL required.

**First-time setup:**

```bash
cd app/ui
npm install
npx playwright install chromium
```

**Run tests:**

```bash
cd app/ui

# Headless (CI-friendly)
npm run test:e2e

# See the browser while tests run
npm run test:e2e:headed

# Interactive test runner with time-travel debugging
npm run test:e2e:ui
```

Playwright automatically starts the mock backend (`USE_SQL=false`) and Vite dev server. No manual startup needed.

**What it tests (12 spec files):**

| Spec file | What it validates |
|-----------|-------------------|
| `navigation.spec.js` | Title is "Identity Atlas"; always-visible tabs present (Matrix, Users, Resources, Systems, Business Roles, Sync Log); tab switching; hash routing; no auth gate in no-auth mode |
| `matrix.spec.js` | Matrix table renders with rows; user limit slider; IST/SOLL/All toggle; D/I/E membership badges; share/export buttons; filter dropdowns |
| `tags.spec.js` | Full tag lifecycle via API: create → appears in list → assign to resource → filter resources by tag → matrix `__groupTag` filter → delete |
| `users-page.spec.js` | User table, search debounce, tag flow, pagination, click-to-detail |
| `groups-page.spec.js` | Resource table (formerly Groups), search, tag management, click-to-detail |
| `access-packages.spec.js` | Business Roles table, category creation, assignment type badges, pagination |
| `sync-log.spec.js` | Table or empty state, column headers, status badge colors |
| `risk-scoring.spec.js` | Page renders, tier badges, score bars, no unhandled errors |
| `org-chart.spec.js` | Page renders, search input, no crashes |
| `performance.spec.js` | Summary/Recent/Slow tabs, export button |
| `detail-pages.spec.js` | Hash-based detail routing, multiple tabs open, close button |
| `identities.spec.js` | Identities page renders without errors |

**Test reports** are saved to `app/ui/playwright-report/` (open `index.html` in a browser).

**Screenshots on failure** are saved to `app/ui/test-results/`.

### Run E2E Tests Against Deployed UI

To test against a live deployment instead of mock data:

```bash
cd app/ui
BASE_URL=https://your-app.azurewebsites.net npx playwright test
```

Note: Tag/category creation tests will create real data in SQL when running against a live deployment.

---

## 8. Phase 6: UI Feature Walkthrough (Manual)

Open the UI URL in a browser and test each page. Use this checklist:

### Matrix Page

- [ ] Matrix loads with users as columns and groups as rows
- [ ] Cells show colored badges: **D** (blue), **I** (green), **E** (amber)
- [ ] Owner rows appear separately suffixed with "(Owner)"
- [ ] **IST/SOLL toggle**: "All" shows everything, "IST" shows only unmanaged, "SOLL" shows only AP-managed
- [ ] **User limit slider**: Changing the slider reloads with fewer/more users
- [ ] **Staircase sort**: Rows with AP assignments cluster at the top with a diagonal pattern
- [ ] **Drag-and-drop**: Drag a row to reorder. Reload page — order persists
- [ ] **AP coloring**: Managed cells have colored backgrounds matching their access package
- [ ] **Multi-AP indicator**: If a cell is in multiple APs, a count badge appears
- [ ] **Category boundaries**: Thick borders and colored stripes between AP category groups
- [ ] **Excel export**: Click Export → opens an .xlsx file with AP-colored cells and badges
- [ ] **Share link**: Click Share → paste URL in new tab → same filters/limit/toggle are applied
- [ ] **Filter pills**: Click "+ Add filter" → select "Department" → select a value → matrix filters
- [ ] **Column header filter**: Click Type column header → filter by "Direct" only
- [ ] **Tags column filter**: Click Tags header → select "(Blank)" → shows only untagged groups
- [ ] **Provisioning gap indicator**: If an AP assigns a group but a user has no Direct membership, a "!" badge appears

### Users Page

- [ ] Users load with pagination (page size selector works)
- [ ] **Search**: Type a name → results filter in real-time (debounced)
- [ ] **Filter pills**: Add filter by department/city/etc → table filters
- [ ] **Tag management**: Click "Manage Tags" → create a tag with a color → close
- [ ] **Tag assignment**: Select users with checkboxes → assign the new tag
- [ ] **Bulk tag**: Click "Tag All Matching" → all users matching current filter get the tag
- [ ] **Click user name**: Opens a detail tab with all attributes, group memberships, history

### Groups Page

- [ ] Groups load with pagination
- [ ] **Search**: Type a group name → results filter
- [ ] **Tag management**: Same as Users page — create, assign, bulk-tag
- [ ] **Click group name**: Opens a detail tab with members, AP assignments, history

### Access Packages Page

- [ ] Access packages load with catalog name and assignment count
- [ ] **Assignment type**: Column shows "Admin", "Request", or "Auto" badges
- [ ] **Category management**: Click "Manage Categories" → create a category with color
- [ ] **Category assignment**: Select APs → assign category (or use inline dropdown)
- [ ] **Filter by category**: Click a category pill → table filters to that category
- [ ] **Uncategorized filter**: Click "Uncategorized" → shows only APs without a category
- [ ] **Click AP name**: Opens detail tab with assignments, policies, last review

### Sync Log Page

- [ ] Shows recent sync operations with timestamps
- [ ] Each row shows: entity type, row count, duration, status
- [ ] Most recent sync is at the top

### Risk Scoring Page (requires `Invoke-FGRiskScoring` to have been run)

- [ ] **Summary cards**: Shows total scored entities, average score, tier distribution
- [ ] **User scores table**: Paginated list with score bars and tier badges
- [ ] **Group scores table**: Same format for groups
- [ ] **Tier filter**: Click a tier badge → filters to that tier only
- [ ] **Score bar colors**: Critical=red, High=orange, Medium=yellow, Low=blue, Minimal=gray
- [ ] **Click a user/group**: Expands to show:
  - Per-layer score breakdown (Direct, Membership, Structural, Propagation)
  - Classifier matches with regex patterns
  - Explanation text
- [ ] **Analyst override**: Click "Override" on a user → enter adjustment (-50 to +50) and reason → Submit
- [ ] Override badge appears next to score
- [ ] Effective score = computed + override (clamped 0-100)
- [ ] **Remove override**: Click remove → override disappears

### Org Chart Page (requires user sync with manager data)

- [ ] Manager hierarchy loads as a tree
- [ ] Department boxes are color-coded by risk tier
- [ ] Report counts show direct and indirect reports
- [ ] **Search**: Filter by department name
- [ ] **Click department**: Opens department detail page with member list

### Performance Page (requires `-PerformanceMetrics` flag on deployment)

- [ ] **Endpoint summaries**: Table with P50/P95/P99 times per route
- [ ] **Recent requests**: Last 20 requests with timing breakdown
- [ ] **Slowest requests**: Top 10 slowest with SQL query details
- [ ] **Export**: Download JSON file with all metrics

### Entity Detail Pages

- [ ] **User detail**: Shows all attributes from SQL, risk score section, group memberships with type badges, AP assignments, version history diffs
- [ ] **Group detail**: Shows all attributes, member list with type badges, AP assignments, version history
- [ ] **Multiple tabs**: Open 2+ detail tabs → each has a close (×) button
- [ ] **Hash routing**: Copy URL with `#user:id` → paste in new tab → opens same detail
- [ ] **Drill-through**: In user detail, click a group name → opens group detail tab

---

## 9. Phase 7: Azure Automation Tests

### Deploy Automation Account

```powershell
New-FGAzureAutomationAccount -ConfigFile _Test\config.test.json
```

### Manual Verification

- [ ] Automation Account created in the resource group
- [ ] Encrypted variables exist for: ClientId, ClientSecret, TenantId, SQLConnectionString
- [ ] Runbooks are published (one per sync type)
- [ ] Schedules exist (if configured)
- [ ] SQL firewall rule allows Azure services

### Test a Runbook

```powershell
Start-FGAutomationRunbook -ConfigFile _Test\config.test.json -RunbookName "Sync-Users"
Get-FGAutomationJob -ConfigFile _Test\config.test.json -Last 1
```

---

## 10. Phase 8: Cleanup

### Remove UI Resources

```powershell
Remove-FGUI -ConfigFile _Test\config.test.json
```

### Remove SQL Server (deletes all data!)

```powershell
pwsh -File _Test\Test-Integration-Fast.ps1 -ConfigFile _Test\config.test.json -RemoveServer
```

### Remove All Azure Resources

```powershell
# This removes the entire resource group — DESTRUCTIVE
Remove-AzResourceGroup -Name "rg-fortigraph-test" -Force
```

### Clean Up Local Files

```powershell
Remove-Item _Test\config.test.json -ErrorAction SilentlyContinue
Remove-Item _Test\logs\* -ErrorAction SilentlyContinue
Remove-Item _Test\exports\* -ErrorAction SilentlyContinue
```

---

## 12. Test File Reference

### Test structure

```
test/
├── test.config.json              # Central config: API URLs, SQL credentials
├── run-docker-tests.ps1          # Docker integration suite (87 checks)
├── test-results.md               # Latest Docker test run results
├── TESTING-GUIDE.md              # This file
├── unit/
│   ├── IdentityAtlas.Tests.ps1   # Pester v5 unit tests (module structure, quality)
│   ├── Test-Simple.ps1           # Azure context + config validation
│   └── Test-GraphAPI.ps1         # Graph API connectivity tests
├── demo-dataset/
│   ├── Generate-DemoDataset.ps1  # Generates demo-company.json
│   ├── Ingest-DemoDataset.ps1    # Posts dataset to Ingest API
│   └── demo-company.json         # Generated fixture (gitignored)
├── datasets/
│   └── DatasetLed2/              # Omada CSV dataset (10 files, real-shape data)
├── nightly/
│   ├── Register-NightlySchedule.ps1
│   └── Run-NightlyLocal.ps1
└── automation/
    └── github-nightly-tests.yml  # Nightly GitHub Actions workflow

app/
├── api/
│   ├── package.json              # includes "test": "vitest run"
│   └── src/ingest/
│       ├── validation.js         # Validation logic
│       └── validation.test.js    # Vitest unit tests (53 test cases)
└── ui/
    ├── playwright.config.js      # Starts mock backend + Vite dev server
    ├── eslint.config.js          # ESLint 9 flat config
    └── e2e/                      # Playwright spec files (12 files)
        ├── navigation.spec.js
        ├── matrix.spec.js
        ├── tags.spec.js          # Tag lifecycle: create → assign → filter → delete
        ├── users-page.spec.js
        ├── groups-page.spec.js
        ├── access-packages.spec.js
        ├── sync-log.spec.js
        ├── risk-scoring.spec.js
        ├── org-chart.spec.js
        ├── performance.spec.js
        ├── detail-pages.spec.js
        └── identities.spec.js

.github/workflows/
├── pr.yml                        # PR checks (fast, no Docker/Azure)
└── docs.yml                      # MkDocs deploy on push to main
```

### Quick-reference command table

| What | Command | Azure? | Docker? | Duration |
|------|---------|--------|---------|----------|
| Pester unit tests | `Invoke-Pester -Path test/unit/IdentityAtlas.Tests.ps1` | No | No | ~15 s |
| Vitest API tests | `cd app/api && npm test` | No | No | ~5 s |
| ESLint | `cd app/ui && npm run lint` | No | No | ~5 s |
| PSScriptAnalyzer | `Invoke-ScriptAnalyzer -Path ./Functions -Recurse` | No | No | ~10 s |
| Docker suite | `pwsh -File test/run-docker-tests.ps1` | No | Yes | ~30 s |
| Playwright E2E | `cd app/ui && npm run test:e2e` | No | No | ~45 s |
| Azure diagnostics | `pwsh -File test/unit/Test-Simple.ps1 -ConfigFile ...` | Yes | No | ~5 s |
| Graph API tests | `pwsh -File test/unit/Test-GraphAPI.ps1 -ConfigFile ...` | Yes | No | ~30 s |

### Logs

Docker test output goes to `test/test-results.md`. Playwright reports go to `app/ui/playwright-report/`. Pester JUnit XML goes to `pester-results.xml` (CI) or console output (local).

### Troubleshooting

| Problem | Solution |
|---------|----------|
| Pester "module not found" | Run `Install-Module Pester -MinimumVersion 5.0.0 -Force -Scope CurrentUser` |
| ESLint "No files matched" | Check `eslint.config.js` exists in `app/ui/` |
| Docker tests fail on SQL connection | Wait longer after `docker compose up` — SQL takes ~20 s to init |
| "No Access Token found" | Run `Get-FGAccessToken -ConfigFile config.test.json` first |
| SQL firewall timeout | Verify your IP is allowed in the Azure SQL firewall |
| 403 on Graph API | Check app registration has correct permissions + admin consent |
| UI returns 500 errors | `az webapp log tail --name <app-name> -g <rg>` |

---

## 13. CI/CD Pipelines

### PR Pipeline (`.github/workflows/pr.yml`)

Runs on every pull request to `main` or `dev`. No Docker, no Azure credentials needed. All 6 jobs run in parallel:

| Job | Tool | What it checks |
|-----|------|----------------|
| `lint-ps` | PSScriptAnalyzer | PowerShell code quality (Warnings + Errors fail the build) |
| `lint-js` | ESLint | JavaScript/JSX code quality in `app/ui/` |
| `unit-tests` | Pester v5 | Module structure, function availability, code quality; JaCoCo coverage artifact |
| `unit-js` | Vitest | API validation logic (53 test cases in `validation.test.js`) |
| `openapi` | Spectral | `app/api/src/openapi.yaml` conforms to OAS3 ruleset |
| `audit` | npm audit | No high-severity vulnerabilities in `app/ui` or `app/api` |

**Typical duration:** 3–5 minutes.

### Nightly Pipeline (`.github/workflows/` → `test/automation/github-nightly-tests.yml`)

Runs at 02:00 UTC daily and on-demand. Requires Azure secrets.

**Pipeline structure:**

```
unit-tests (Pester) ──┬──→ integration-tests (Azure SQL + Graph)
                      ├──→ ui-backend-tests  (deployed UI, if URL set)
                      └──→ e2e-tests         (Playwright, app/ui/)
                                    └──→ summary
```

**Required secrets** (Settings → Secrets → Actions):

| Secret | Required | Value |
|--------|----------|-------|
| `AZURE_CREDENTIALS` | Yes | `az ad sp create-for-rbac --sdk-auth` output |
| `TEST_CONFIG` | Yes | Full `config.test.json` contents |
| `SQL_ADMIN_PASSWORD` | Yes | SQL Server admin password |
| `GRAPH_CLIENT_SECRET` | Yes | Graph API client secret |
| `LLM_API_KEY` | No | Anthropic or OpenAI key (for risk scoring tests) |
| `UI_BASE_URL` | No | Deployed UI URL |
| `UI_BEARER_TOKEN` | No | Bearer token for authenticated deployments |

**Manual trigger options:** skip integration, skip risk scoring, skip E2E, first run (creates SQL from scratch).

**Artifacts retained 30 days:** Pester JUnit XML, Playwright HTML report, failure screenshots.

### Cost Considerations

- **GitHub Actions (private repo):** 2 000 min/month free, then ~$0.008/min
- **Azure resources during nightly tests:** ~$0.10–0.50 per run
- **LLM API (risk scoring):** ~$0.05–0.20 per run (2–3 calls)
