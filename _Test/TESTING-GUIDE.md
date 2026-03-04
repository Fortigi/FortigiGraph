# FortigiGraph Complete Testing Guide

> **For human testers** — this guide walks you through testing FortigiGraph end-to-end, from a fresh setup to validating every major feature. Automated test scripts are provided where possible.

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Environment Setup](#2-environment-setup)
3. [Phase 1: Offline Tests (No Azure Required)](#3-phase-1-offline-tests-no-azure-required)
4. [Phase 2: Azure + Graph Setup](#4-phase-2-azure--graph-setup)
5. [Phase 3: SQL + Sync Integration Tests](#5-phase-3-sql--sync-integration-tests)
6. [Phase 4: Risk Scoring Tests](#6-phase-4-risk-scoring-tests)
7. [Phase 5: UI Deployment + Frontend Tests](#7-phase-5-ui-deployment--frontend-tests)
8. [Phase 6: UI Feature Walkthrough (Manual)](#8-phase-6-ui-feature-walkthrough-manual)
9. [Phase 7: Azure Automation Tests](#9-phase-7-azure-automation-tests)
10. [Phase 8: Cleanup](#10-phase-8-cleanup)
11. [Test Script Reference](#11-test-script-reference)

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
Import-Module .\FortigiGraph.psd1 -Force
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

## 3. Phase 1: Offline Tests (No Azure Required)

These tests validate the module itself without needing any Azure resources.

### Run the Unit Tests

```powershell
pwsh -File _Test\Test-Unit.ps1
```

**What it tests:**
- Module import and all 140 functions are loaded
- Every function has the correct `FG` prefix and alias
- All function files follow naming conventions
- `[cmdletbinding()]` attribute is present on all functions
- No Dutch comments remain in the codebase
- Config template is valid JSON
- No hardcoded credentials or tokens in source files
- Module manifest version format is valid
- All sync function files exist for each enabled sync type
- Graph API helper functions are available (Get/Post/Patch/Put/Delete)

**Expected result:** All tests pass with 0 failures.

**If tests fail:** Fix any issues before proceeding to Phase 2. Common issues:
- Module import failure → Check PowerShell version (`$PSVersionTable`)
- Missing functions → Check that no `.ps1` files have syntax errors

---

## 4. Phase 2: Azure + Graph Setup

### Run the Simple Diagnostics

```powershell
pwsh -File _Test\Test-Simple.ps1 -ConfigFile _Test\config.test.json
```

This validates your config file, Azure connection, and module readiness.

### Run Graph API Tests

```powershell
pwsh -File _Test\Test-GraphAPI.ps1 -ConfigFile _Test\config.test.json
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
cd UI/frontend
npm install
npx playwright install chromium
```

**Run tests:**

```bash
# Headless (CI-friendly)
npm run test:e2e

# See the browser while tests run
npm run test:e2e:headed

# Interactive test runner with time-travel debugging
npm run test:e2e:ui
```

Playwright automatically starts the mock backend (`USE_SQL=false`) and Vite dev server. No manual startup needed.

**What it tests (8 test files, ~50 assertions):**

| Test File | What It Validates |
|-----------|-------------------|
| `navigation.spec.js` | App loads, all 8 tabs visible, tab switching, hash routing, no auth gate in NoAuth mode |
| `matrix.spec.js` | Matrix renders rows/columns, user limit slider, IST/SOLL toggle, D/I/E badges, share/export buttons, filter dropdowns |
| `users-page.spec.js` | User table, search debounce, tag creation flow, pagination, checkbox selection, click-to-detail |
| `groups-page.spec.js` | Group table, search filtering, tag management, click-to-detail |
| `access-packages.spec.js` | AP table, search, category creation flow, assignment type badges, pagination |
| `sync-log.spec.js` | Table or empty state, column headers, status badge colors |
| `risk-scoring.spec.js` | Page renders, tier badges, score bars, no unhandled errors |
| `org-chart.spec.js` | Page renders, search input, no crashes, can navigate away |
| `performance.spec.js` | View tabs (Summary/Recent/Slow), tab switching, export button |
| `detail-pages.spec.js` | Hash-based detail routing, detail tabs in nav, multiple tabs, close button |

**Test reports** are saved to `UI/frontend/playwright-report/` (open `index.html` in a browser).

**Screenshots on failure** are saved to `UI/frontend/test-results/`.

### Run E2E Tests Against Deployed UI

To test against a live deployment instead of mock data:

```bash
cd UI/frontend
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

## 11. Test Script Reference

| Script | Phase | Azure Required | Duration | Purpose |
|--------|-------|---------------|----------|---------|
| `Test-Unit.ps1` | 1 | No | ~10 sec | Module structure, naming, code quality |
| `Test-Simple.ps1` | 2 | Yes (login) | ~5 sec | Config + Azure context validation |
| `Test-GraphAPI.ps1` | 2 | Yes (token) | ~30 sec | Graph API connectivity + basic queries |
| `Test-Integration.ps1` | 3 | Yes (full) | 15-30 min | Full end-to-end: create, sync, query |
| `Test-Integration-Fast.ps1` | 3 | Yes (reuse) | 5-10 min | Regression: clear + re-sync |
| `Test-RiskScoring.ps1` | 4 | Yes + LLM key | 5-10 min | Risk profile, classifiers, scoring |
| `Test-UIBackend.ps1` | 5 | Yes (deployed) | ~30 sec | Backend API endpoint validation |
| `e2e/*.spec.js` (Playwright) | 5 | No (mock) | ~30 sec | Browser rendering, navigation, interactions |
| **`Run-AllTests.ps1`** | **All** | **Varies** | **20-45 min** | **Single-command runner for the entire suite** |

### Single-Command Full Suite

Use `Run-AllTests.ps1` to run everything with one command. It runs all phases sequentially, skips phases that lack required parameters, and prints a combined summary at the end.

```powershell
# ── First time (creates SQL Server + runs all tests) ──────────────
pwsh -File _Test\Run-AllTests.ps1 `
    -ConfigFile _Test\config.test.json `
    -FirstRun `
    -LLMProvider Anthropic -LLMApiKey "sk-ant-..." `
    -UIBaseUrl "https://fg-test.azurewebsites.net"

# ── Regression run (reuses SQL, skips risk scoring) ───────────────
pwsh -File _Test\Run-AllTests.ps1 `
    -ConfigFile _Test\config.test.json

# ── Offline only (no Azure, no config needed) ─────────────────────
pwsh -File _Test\Run-AllTests.ps1

# ── Full suite, abort on first failure ────────────────────────────
pwsh -File _Test\Run-AllTests.ps1 `
    -ConfigFile _Test\config.test.json `
    -StopOnFailure

# ── Skip specific phases ──────────────────────────────────────────
pwsh -File _Test\Run-AllTests.ps1 `
    -ConfigFile _Test\config.test.json `
    -SkipIntegration `
    -SkipE2E
```

**Phase execution logic:**

| Phase | Runs When | Skip Flag |
|-------|-----------|-----------|
| 1. Unit Tests | Always | — |
| 2a. Simple Diagnostics | `-ConfigFile` provided | — |
| 2b. Graph API | `-ConfigFile` provided | — |
| 3. Integration | `-ConfigFile` provided | `-SkipIntegration` |
| 4. Risk Scoring | `-ConfigFile` + `-LLMProvider` + `-LLMApiKey` | `-SkipRiskScoring` |
| 5a. UI Backend API | `-UIBaseUrl` provided | `-SkipUIBackend` |
| 5b. UI E2E (Playwright) | Node.js installed | `-SkipE2E` |

The runner produces a summary like:

```
╔══════════════════════════════════════════════════╗
║           FORTIGRAPH TEST SUITE RESULTS          ║
╠══════════════════════════════════════════════════╣
║   ✓ 1. Unit Tests                       8.2s    ║
║   ✓ 2a. Simple Diagnostics             3.1s    ║
║   ✓ 2b. Graph API                      12.4s   ║
║   ✓ 3. Integration (fast)              287.3s  ║
║   ✗ 4. Risk Scoring                    45.2s   ║
║   ✓ 5b. UI E2E Browser Tests           18.7s   ║
╠══════════════════════════════════════════════════╣
║   Passed: 5 / 6                Total: 375s     ║
╚══════════════════════════════════════════════════╝
```

### Running Individual Tests

```powershell
# Phase 1: Offline
pwsh -File _Test\Test-Unit.ps1

# Phase 2: Setup validation
pwsh -File _Test\Test-Simple.ps1 -ConfigFile _Test\config.test.json
pwsh -File _Test\Test-GraphAPI.ps1 -ConfigFile _Test\config.test.json

# Phase 3: Integration (first time)
pwsh -File _Test\Test-Integration.ps1 -ConfigFile _Test\config.test.json -SkipCleanup

# Phase 4: Risk scoring (optional)
pwsh -File _Test\Test-RiskScoring.ps1 -ConfigFile _Test\config.test.json -LLMProvider Anthropic -LLMApiKey "sk-ant-..."

# Phase 5: UI backend (after deploying)
pwsh -File _Test\Test-UIBackend.ps1 -BaseUrl "https://your-ui.azurewebsites.net" [-BearerToken "..."]

# Phase 5b: UI E2E browser tests (no Azure needed — uses mock backend)
cd UI/frontend && npx playwright install chromium && npm run test:e2e
```

### Logs

All test scripts write transcripts to `_Test/logs/`. Check these for detailed output if any test fails.

### Troubleshooting

| Problem | Solution |
|---------|----------|
| "No Access Token found" | Run `Get-FGAccessToken -ConfigFile config.test.json` first |
| SQL connection timeout | Check SQL Server firewall allows your IP |
| 403 on Graph API | Verify app registration has correct permissions + admin consent |
| "Module not found" | Run from the repo root: `Import-Module .\FortigiGraph.psd1 -Force` |
| Risk scoring returns 0 scores | Ensure sync has run first — scoring reads from SQL tables |
| UI returns 500 errors | Check App Service logs: `az webapp log tail --name <app-name> -g <rg>` |
