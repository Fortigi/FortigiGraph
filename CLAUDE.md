# FortigiGraph - AI Assistant Development Guide

> **IMPORTANT: After making ANY code changes, you MUST update the module version!**
> 1. Update the `ModuleVersion` in `FortigiGraph.psd1` (format: `Major.Minor.yyyyMMdd.HHmm`)
> 2. If running locally, run `_Build/CreatePSD.ps1` to regenerate `FortigiGraph.psd1`
> This ensures changes are properly tracked and the module can be re-imported.

## Project Overview

FortigiGraph is a PowerShell module that simplifies working with Microsoft Graph API and syncing data to Azure SQL databases with temporal versioning. It provides a guided setup wizard (`New-FGConfig`), comprehensive cmdlets for managing Azure AD/Entra ID resources, and orchestrated sync to SQL with automatic change tracking.

**Key Information:**
- **Language:** PowerShell
- **Primary Purpose:** Microsoft Graph API wrapper with Azure SQL data persistence
- **Author:** Wim van den Heijkant
- **Company:** Fortigi
- **GitHub:** https://github.com/Fortigi/FortigiGraph
- **Distribution:** PowerShell Gallery
- **Current Version:** 2.1.yyyyMMdd.HHmm (run `_Build/CreatePSD.ps1` to update)

## Major Features

### 1. Guided Setup Wizard (`New-FGConfig`)
- Creates Azure resources (Resource Group, SQL Server, Database, Automation Account)
- Creates App Registration with correct Graph API permissions
- Configures sync settings interactively
- Saves everything to a config file that drives all operations
- Supports selecting existing resources or creating new ones

### 2. Microsoft Graph API Integration
- Easy authentication (service principal & interactive)
- Automatic token refresh and pagination handling
- CRUD operations for Azure AD/Entra ID resources
- Required permissions: `User.Read.All`, `Group.Read.All`, `GroupMember.Read.All`, `Directory.Read.All`, `EntitlementManagement.Read.All`, `AccessReview.Read.All`, `AuditLog.Read.All`

### 3. Azure SQL Integration
- **Temporal Tables**: Automatic version history tracking for all data changes
- **Point-in-Time Queries**: Query data as it existed at any time
- **High-Performance Sync**: SqlBulkCopy-based operations (20-50x faster than row-by-row)
- **Automatic Schema Evolution**: Add new columns without recreating tables
- **ConfigFile Support**: All SQL functions support config files

### 4. Identity Governance & Compliance Sync
- **Complete Access Package Sync**: Catalogs, packages, assignments, policies, requests, reviews
- **Group Membership Sync**: Direct, transitive, eligible (PIM), and owner relationships
- **Orchestrated Sync**: `Start-FGSync` orchestrates all operations from config file
- **Parallel Execution**: Up to 6 entity types concurrently via runspace pool
- **Analytical Views**: 12+ SQL views for IST vs SOLL analysis, approval metrics, access reviews

### 5. Azure Automation
- `New-FGAzureAutomationAccount` creates everything needed for scheduled syncs
- Encrypted variables, runbooks, daily schedules, SQL firewall rules
- Memory-safe batching mode for large datasets (400 MB Azure sandbox limit)

### 6. Role Mining UI
- **Web Application**: React + Vite + Tailwind + TanStack Table v8 deployed to Azure App Service (default P0v3 SKU)
- **Authentication**: Entra ID (MSAL) with support for both v1 and v2 token formats; `-NoAuth` option for demos
- **Tab Navigation**: Five pages — Matrix, Users, Groups, Access Packages, Sync Log — plus dynamic detail tabs
- **Matrix View**: User-group permission heatmap with drag-and-drop row reordering
- **Staircase Sort**: Default row order groups rows by their leftmost AP bucket, creating a visual staircase pattern; unmanaged groups at the bottom. Custom drag order persists via versioned localStorage (bump `ROW_ORDER_VERSION` in `useMatrixRowOrder.js` when changing default sort logic)
- **Multi-Type Badges**: Cells show individually colored badges per membership type (D, I, E); multi-type cells show all badges side by side
- **Owner Row Separation**: Owner (O) memberships are shown in separate rows suffixed with "(Owner)". D, I, E stay together; ownership is a fundamentally different relationship. Synthetic rows use `id: groupId__owner` with `realGroupId` pointing to the original group
- **Access Package Coloring**: Each AP gets a distinct color from a 15-color palette; managed cells are colored by their governing AP
- **Multi-AP Indicator**: Cells managed by multiple access packages show a count badge
- **Access Package Categories**: Categories are single-assignment labels for access packages (unlike tags, an AP can only have one category). Categories are managed on the Access Packages page. Stored in `GraphCategories` and `GraphCategoryAssignments` SQL tables (auto-created). Categories drive the AP column ordering in the Matrix view.
- **Access Package Columns**: SOLL columns sorted first by category name, then by total assignment count within each category; uncategorized APs appear at the end. Category boundaries are marked with thicker borders and a colored indicator stripe.
- **IST/SOLL Toggle**: Filter matrix to show managed (SOLL), unmanaged (IST), or all assignments
- **Column Header Filters**: Type and Tags columns have filter dropdowns; Tags includes a "(Blank)" option (sentinel `BLANK_TAG`) to show groups without tags
- **Server-Side User Limit**: Slider (default 25) limits data at the SQL level for large environments
- **Excel Export**: Full matrix export with AP columns next to users (matching on-screen layout), AP-colored cells, rich-text multi-type badges, and multi-AP notes
- **Entity Detail Pages**: Click any user or group name (in matrix, Users page, or Groups page) to open a detail tab. Shows all SQL attributes, group memberships/members with type badges, access package assignments, and version history diffs from temporal tables. Multiple detail tabs can be open simultaneously; each has a close button. Hash-based routing (`#user:id` / `#group:id`) supports bookmarking. Drill-through navigation between user and group details.
- **Deployment**: `New-FGUI` / `Update-FGUI` / `Remove-FGUI` PowerShell cmdlets

## Repository Structure

```
FortigiGraph/
├── Functions/                  # All PowerShell functions
│   ├── Base/                   # Core authentication and HTTP request functions (20)
│   │   ├── New-FGConfig.ps1              # Setup wizard
│   │   ├── Get-FGAccessToken*.ps1        # Token acquisition (3 variants)
│   │   ├── Invoke-FGGetRequest.ps1       # HTTP GET with auto-pagination
│   │   ├── Invoke-FGPostRequest.ps1      # HTTP POST wrapper
│   │   ├── Invoke-FGPatchRequest.ps1     # HTTP PATCH wrapper
│   │   ├── Invoke-FGPutRequest.ps1       # HTTP PUT wrapper
│   │   ├── Invoke-FGDeleteRequest.ps1    # HTTP DELETE wrapper
│   │   ├── Update-FGAccessTokenIfExpired.ps1 # Shared token refresh helper
│   │   └── ...                           # Token management, secure config helpers
│   │
│   ├── Generic/                # Microsoft Graph API operations (49)
│   │   ├── Get-FG*.ps1         # Retrieve operations
│   │   ├── New-FG*.ps1         # Create operations
│   │   ├── Set-FG*.ps1         # Update operations
│   │   ├── Add-FG*.ps1         # Add operations (members, resources)
│   │   └── Remove-FG*.ps1      # Delete/remove operations
│   │
│   ├── Sync/                   # High-performance data sync operations (14)
│   │   ├── Start-FGSync.ps1              # Orchestrates all sync operations
│   │   ├── Sync-FGUser.ps1               # Sync users to SQL
│   │   ├── Sync-FGGroup.ps1              # Sync groups to SQL
│   │   ├── Sync-FGGroupMember.ps1        # Sync direct group memberships
│   │   ├── Sync-FGGroupEligibleMember.ps1
│   │   ├── Sync-FGGroupOwner.ps1
│   │   ├── Sync-FGAccessPackage.ps1
│   │   ├── Sync-FGAccessPackageAssignment.ps1
│   │   ├── Sync-FGAccessPackageResourceRoleScope.ps1
│   │   ├── Sync-FGAccessPackageAssignmentPolicy.ps1
│   │   ├── Sync-FGAccessPackageAssignmentRequest.ps1
│   │   ├── Sync-FGAccessPackageAccessReview.ps1
│   │   ├── Sync-FGCatalog.ps1
│   │   ├── Initialize-FGSyncTable.ps1           # Shared table lifecycle helper
│   │   └── New-FGDataTableFromGraphObjects.ps1  # Shared DataTable builder
│   │
│   ├── SQL/                    # Azure SQL operations (24)
│   │   ├── Invoke-FGSQLCommand.ps1       # Helper for connection lifecycle
│   │   ├── Connect-FGSQLServer.ps1       # Connect with firewall & ConfigFile
│   │   ├── Initialize-FGSQLTable.ps1     # Create temporal tables
│   │   ├── Initialize-FGAccessPackageViews.ps1
│   │   ├── Initialize-FGGroupMembershipViews.ps1
│   │   ├── Initialize-FGGroupMembershipIndexes.ps1
│   │   └── ...                           # Query, bulk ops, server management
│   │
│   ├── Specific/               # Higher-level helper functions (9)
│   │   └── Confirm-FG*.ps1     # Idempotent confirmation/creation
│   │
│   └── Automation/             # Azure Automation Account management (4)
│       ├── New-FGAzureAutomationAccount.ps1
│       ├── Get-FGAutomationRunbook.ps1
│       ├── Start-FGAutomationRunbook.ps1
│       └── Get-FGAutomationJob.ps1
│
├── Config/                 # Configuration templates
│   └── tenantname.json.template
│
├── UI/                     # Role Mining Web Application
│   ├── backend/            # Node.js + Express API server
│   │   └── src/
│   │       ├── routes/permissions.js  # API endpoints (permissions, AP groups, sync log)
│   │       ├── routes/categories.js  # Category CRUD, AP list, category assignments
│   │       ├── routes/details.js     # User/group detail endpoints with version history
│   │       ├── middleware/auth.js     # Entra ID JWT validation (v1+v2 tokens)
│   │       ├── db/connection.js       # Azure SQL (mssql) connection pool + graceful shutdown
│   │       ├── db/columnCache.js      # Shared column discovery cache (5-min TTL)
│   │       └── mock/data.js           # Mock data for local dev
│   └── frontend/           # React + Vite + Tailwind
│       └── src/
│           ├── App.jsx                # Root component, tab navigation, userLimit state
│           ├── auth/AuthGate.jsx      # MSAL authentication gate
│           ├── hooks/
│           │   ├── usePermissions.js  # API hook with debounced refetch
│           │   ├── useMatrixRowOrder.js # Row order persistence (versioned localStorage)
│           │   └── useEntityPage.js   # Shared hook for Users/Groups pages (search, filter, tags, pagination)
│           ├── utils/exportToExcel.js # Excel export with AP colors & rich text
│           └── components/
│               ├── MatrixView.jsx     # Main matrix orchestrator (staircase sort, managedApMap, apIdToIndex)
│               ├── PermissionGrid.jsx # TanStack Table grid view
│               ├── SyncLogPage.jsx    # Sync log viewer
│               ├── UserDetailPage.jsx # User detail with attributes, memberships, history
│               ├── GroupDetailPage.jsx # Group detail with attributes, members, history
│               └── matrix/            # Matrix sub-components
│                   ├── MatrixToolbar.jsx    # Filters, IST/SOLL, slider
│                   ├── MatrixCell.jsx       # Individual cell (AP-colored bg, multi-type badges)
│                   ├── MatrixGroupRow.jsx   # DnD-agnostic row (sortable props injected by SortableRow)
│                   ├── SortableMatrixBody.jsx  # Lazy-loaded: DnD + virtual scrolling wrapper
│                   └── MatrixColumnHeaders.jsx  # AP color palette (15 colors), column filters
│
├── _Build/                 # Build and publishing scripts
│   └── CreatePSD.ps1       # Module manifest generation
│
├── _Test/                  # Testing scripts and documentation
│
├── FortigiGraph.psm1       # Module entry point (auto-loads all functions)
├── FortigiGraph.psd1       # Module manifest
├── README.md               # User documentation
└── CLAUDE.md               # This file - AI assistant development guide
```

### Function Count by Category

| Category | Count | Purpose |
|----------|-------|---------|
| **Base** | 21 | Authentication, HTTP operations, setup wizard, token management |
| **Generic** | 49 | Graph API CRUD operations |
| **Sync** | 15 | High-performance data sync (Start-FGSync + 12 entity syncs + 2 helpers) |
| **SQL** | 24 | Azure SQL database operations (tables, views, indexes, bulk ops) |
| **Automation** | 4 | Azure Automation Account management |
| **Specific** | 9 | High-level idempotent helpers |
| **Total** | **122 functions** | |

## Architecture & Design Patterns

### 1. Module Loading Strategy

The module loads functions from the `Functions/` directory via dot-sourcing in `FortigiGraph.psm1`:

```powershell
$base       = @( Get-ChildItem -Path (Join-Path $PSScriptRoot 'functions\base') -Include *.ps1 -Recurse )
$generic    = @( Get-ChildItem -Path (Join-Path $PSScriptRoot 'functions\generic') -Include *.ps1 -Recurse )
$specific   = @( Get-ChildItem -Path (Join-Path $PSScriptRoot 'functions\specific') -Include *.ps1 -Recurse )
$SQL        = @( Get-ChildItem -Path (Join-Path $PSScriptRoot 'functions\SQL') -Include *.ps1 -Recurse )
$sync       = @( Get-ChildItem -Path (Join-Path $PSScriptRoot 'functions\Sync') -Include *.ps1 -Recurse )
$automation = @( Get-ChildItem -Path (Join-Path $PSScriptRoot 'functions\Automation') -Include *.ps1 -Recurse )

foreach ($import in @($base + $generic + $specific + $SQL + $sync + $automation)) {
    . $import.fullname
}
```

### 2. Global State Management

#### Graph API State
- `$Global:AccessToken` - Current OAuth access token
- `$Global:ClientId` - Azure AD application client ID
- `$Global:ClientSecret` - Application secret (for service principal auth)
- `$Global:TenantId` - Azure AD tenant ID
- `$Global:RefreshToken` - Refresh token (for interactive auth)
- `$Global:DebugMode` - Debug flag ('T', 'G', 'P', 'D' or combinations)

#### SQL State
- `$Global:FGSQLConnectionString` - SQL Server connection string
- `$Global:FGSQLServerName` - Connected server name
- `$Global:FGSQLDatabaseName` - Connected database name

### 3. Function Naming Convention

- **Prefix:** `FG` (FortigiGraph) for all exported functions
- **Aliases:** Each function has an alias without the `FG` prefix (e.g., `Get-FGGroup` -> `Get-Group`)
- **Verbs:** Standard PowerShell verbs (Get, New, Set, Add, Remove, Confirm, Invoke, Connect, Test, Initialize, Sync, Clear, Start)
- **Pattern:** `Verb-FGNoun`

### 4. Config File Pattern

The config file (`Config/tenantname.json.template`) drives all operations:

```powershell
# All major functions support -ConfigFile
New-FGConfig -Path .\Config\mycompany.json          # Create config interactively
Get-FGAccessToken -ConfigFile .\Config\mycompany.json
Connect-FGSQLServer -ConfigFile .\Config\mycompany.json
Start-FGSync -ConfigFile .\Config\mycompany.json
New-FGAzureAutomationAccount -ConfigFile .\Config\mycompany.json
```

### 5. The SQL Helper Pattern: `Invoke-FGSQLCommand`

**Critical design pattern.** All SQL functions delegate connection lifecycle to this helper:

```powershell
Invoke-FGSQLCommand -ScriptBlock {
    param($connection)
    $cmd = $connection.CreateCommand()
    $cmd.CommandText = "SELECT COUNT(*) FROM Users"
    return $cmd.ExecuteScalar()
}
```

### 6. Authentication in Start-FGSync

`Start-FGSync` always gets a fresh token at the start of every sync run. This prevents stale token issues when switching between app registrations or when permissions have been updated.

### 7. Pagination Handling (Graph API)

All GET requests automatically handle Microsoft Graph pagination via `Invoke-FGGetRequest`.

### 8. Debug Mode

Debug output controlled via `$Global:DebugMode`:
- `'T'` - Token operations
- `'G'` - GET requests
- `'P'` - POST/PATCH requests
- `'D'` - DELETE requests
- Combine: `'GP'`, `'TPD'`, etc.

## Key Conventions for AI Assistants

### 1. File Organization

**All function files live under `Functions/`:**

| Folder | Purpose | Example |
|--------|---------|---------|
| **Functions/Base/** | Core HTTP operations, authentication, setup wizard | `Invoke-FGGetRequest.ps1`, `New-FGConfig.ps1` |
| **Functions/Generic/** | Direct Microsoft Graph API wrappers (1:1 mapping) | `Get-FGUser.ps1`, `Get-FGGroup.ps1` |
| **Functions/SQL/** | Azure SQL database operations | `Connect-FGSQLServer.ps1`, `Initialize-FGSQLTable.ps1` |
| **Functions/Sync/** | Data sync operations | `Sync-FGUser.ps1`, `Start-FGSync.ps1` |
| **Functions/Automation/** | Azure Automation management | `New-FGAzureAutomationAccount.ps1` |
| **Functions/Specific/** | Business logic combining multiple functions | `Confirm-FGGroup.ps1` |

**File naming:** `Verb-FGNoun.ps1` (e.g., `Get-FGGroupMember.ps1`)

### 2. Function Structure Templates

#### Graph API Function Template

```powershell
function Get-FGResource {
    [alias("Get-Resource")]
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory = $false)]
        [string]$Id,
        [Parameter(Mandatory = $false)]
        [string]$Filter
    )

    If ($Id) {
        $URI = "https://graph.microsoft.com/beta/resources/$Id"
    } ElseIf ($Filter) {
        $URI = "https://graph.microsoft.com/beta/resources?`$filter=$Filter"
    } Else {
        $URI = "https://graph.microsoft.com/beta/resources"
    }

    $ReturnValue = Invoke-FGGetRequest -URI $URI
    return $ReturnValue
}
```

#### SQL Function Template

```powershell
function Get-FGSQLResource {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $false)]
        [string]$Filter
    )

    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = "SELECT * FROM dbo.Resources WHERE Name = @Name"
        $cmd.Parameters.AddWithValue("@Name", $ResourceName)
        $reader = $cmd.ExecuteReader()
        # Process results...
        return $results
    }
}
```

### 3. Important Rules

**DO:**
- Follow existing naming conventions (`Verb-FGNoun`)
- Add aliases without `FG` prefix
- Use `Invoke-FG*Request` functions (never call `Invoke-RestMethod` directly for Graph)
- Use `Invoke-FGSQLCommand` helper for all SQL operations
- Use `/beta` endpoint unless told otherwise
- Place one function per file under `Functions/`
- Use `[cmdletbinding()]` for all functions
- Use color-coded Write-Host for user feedback (Green=success, Yellow=warning, Cyan=progress, Red=error)
- Use `-ErrorAction Stop` with try/catch for Azure operations that must succeed before continuing
- Return raw Graph objects (don't transform)
- Update module version after every change

**DON'T:**
- Don't call `Invoke-RestMethod` directly for Graph (use wrappers)
- Don't manage SQL connections manually (use `Invoke-FGSQLCommand`)
- Don't hardcode credentials or tokens
- Don't create multi-function files
- Don't use `Write-Output` (use `return` directly)
- Don't add comments in Dutch (use English only)
- Don't commit test configuration files (protected by .gitignore)
- Don't modify temporal tables without disabling versioning first
- Don't use `TRUNCATE` on temporal tables (use `DELETE` instead)

### 4. When Extending the Module

1. **Check if function already exists:** Search `Functions/` folders first
2. **Determine correct location:**
   - Direct Graph API call -> `Functions/Generic/`
   - Azure SQL operation -> `Functions/SQL/`
   - Azure Automation operation -> `Functions/Automation/`
   - Data sync operation -> `Functions/Sync/`
   - Combines multiple operations -> `Functions/Specific/`
   - Core HTTP/auth -> `Functions/Base/` (rarely needed)
3. **Follow the pattern:** Look at similar existing functions
4. **Update module version** after making changes

## Graph API Permissions

`New-FGConfig` automatically sets up these permissions when creating an App Registration:

| Permission | ID | Purpose |
|---|---|---|
| `User.Read.All` | `df021288-bdef-4463-88db-98f22de89214` | Read all users |
| `Group.Read.All` | `5b567255-7703-4780-807c-7be8301ae99b` | Read all groups |
| `GroupMember.Read.All` | `98830695-27a2-44f7-8c18-0c3ebc9698f6` | Read group memberships |
| `Directory.Read.All` | `7ab1d382-f21e-4acd-a863-ba3e13f7da61` | Read directory data |
| `EntitlementManagement.Read.All` | `c74fd47d-ed3c-45c3-9a9e-b8676de685d2` | Read access packages |
| `AccessReview.Read.All` | `d07a8cc0-3d51-4b77-b3b0-32704d1f69fa` | Read access reviews |
| `AuditLog.Read.All` | `b0afded3-3588-46d8-8b3d-9842eff778da` | Read audit/sign-in data |

## Analytical Views

### Group Membership Views (via `Initialize-FGGroupMembershipViews`)

- `vw_GraphGroupMembersRecursive` - Calculates ALL memberships (direct + indirect) with paths using recursive CTE
- `vw_UserPermissionAssignments` - All membership types as separate rows: Owner, Direct, Indirect, Eligible + `managedByAccessPackage` (BIT). A user can have multiple rows per group (e.g. Direct + Owner) — no deduplication, so the UI can show all types.

### Access Package Views (via `Initialize-FGAccessPackageViews`)

- `vw_UserPermissionAssignmentViaAccessPackage` - User permissions via access packages
- `vw_DirectGroupMemberships` - Direct group memberships
- `vw_DirectGroupOwnerships` - Direct group ownerships
- `vw_UnmanagedPermissions` - IST vs SOLL gaps
- `vw_AccessPackageAssignmentDetails` - Assignment details
- `vw_AccessPackageLastReview` - Last review per package
- `vw_ApprovedRequestTimeline` - Approval times with response buckets
- `vw_DeniedRequestTimeline` - Denied request analysis
- `vw_PendingRequestTimeline` - Aging pending requests
- `vw_RequestResponseMetrics` - Aggregate approval statistics

## Development Workflow

### Making Changes

1. **Create/Edit Functions** in `Functions/<category>/`
2. **Test locally**: `Import-Module .\FortigiGraph.psd1 -Force`
3. **Update version** in `FortigiGraph.psd1` (format: `Major.Minor.yyyyMMdd.HHmm`)
4. **Commit** with descriptive messages

### Version Updates

Version format: `Major.Minor.yyyyMMdd.HHmm` (e.g., `2.1.20260209.1935`)

This is critical because `New-FGAzureAutomationAccount` checks version numbers and only uploads the module if the local version is newer than the deployed version.

## User Workflow (Getting Started)

The recommended flow for new users:

```powershell
# 1. Setup wizard - creates all Azure resources and config
New-FGConfig -Path .\Config\mycompany.json

# 2. Authenticate to Graph
Get-FGAccessToken -ConfigFile '.\Config\mycompany.json'

# 3. Connect to SQL
Connect-FGSQLServer -ConfigFile '.\Config\mycompany.json'

# 4. Run first sync
Start-FGSync -ConfigFile '.\Config\mycompany.json'

# 5. (Optional) Set up Azure Automation for scheduled syncs
New-FGAzureAutomationAccount -ConfigFile '.\Config\mycompany.json'
```

## Codebase Maintenance Analysis (Feb 2026)

> **This section documents known technical debt, bugs, and improvement opportunities discovered during a comprehensive code review. Use this as a backlog for maintenance sprints.**

### Critical Bugs (Must Fix)

| # | File | Line(s) | Issue |
|---|------|---------|-------|
| 1 | `Functions/Specific/Confirm-FGUser.ps1` | 17 | Checks `$Group.count` instead of `$User.count` — wrong variable |
| 2 | `Functions/Specific/Confirm-FGAccessPackagePolicy.ps1` | 16 | Copy-paste bug: checks `$Policy.accessPackageId` instead of `$Policy.displayName` |
| 3 | `Functions/Specific/Confirm-FGAccessPackage.ps1` | 37 | Uses undefined `$AccessPackageName` — parameter is `$DisplayName` |
| 4 | `Functions/Generic/Get-FGAccessPackagesAssignments.ps1` | 16 | Uses undefined `$id` — parameter is `$AccessPackageID` |
| 5 | `Functions/Generic/Remove-FGAccessPackage.ps1` | 25 | Singular/plural mismatch in loop variable (`$ActiveAccessPackageAssignments.id` vs `$ActiveAccessPackageAssignment.id`) |
| 6 | `Functions/Generic/Get-FGUserMail.ps1` | 20 | Checks `$MailFolder` instead of `$MailFolderId` |
| 7 | `Functions/Generic/Get-FGApplicationExtensionProperty.ps1` | 1-2 | Naming convention reversed: function is `Get-ApplicationExtensionProperty` with alias `Get-FGApplicationExtensionProperty` (should be opposite) |
| ~~8~~ | ~~`Functions/Sync/Sync-FGGroupTransitiveMember.ps1`~~ | — | **RESOLVED:** Function removed (legacy, replaced by `vw_GraphGroupMembersRecursive` view) |
| 9 | `Functions/Base/Use-FGExistingMSALToken.ps1` | 15 | Calls `Get-AccessTokenDetail` instead of `Get-FGAccessTokenDetail` |

### ~~High-Priority Refactoring: DRY Violations in Base HTTP Functions~~ RESOLVED

**RESOLVED:** `Update-FGAccessTokenIfExpired` extracted to `Functions/Base/Update-FGAccessTokenIfExpired.ps1` and all 6 HTTP functions refactored to use it. Remaining opportunities:
- Debug output blocks (~8 lines each) → Extract to `Write-FGDebugMessage`
- Response value extraction (~6 lines each) → Extract to `Get-FGResponseValue`

### ~~High-Priority Refactoring: Sync Function Duplication~~ RESOLVED

**RESOLVED:** Two helpers extracted to `Functions/Sync/`:
- `Initialize-FGSyncTable.ps1` — handles table existence, schema evolution, recreation
- `New-FGDataTableFromGraphObjects.ps1` — builds DataTables with type conversion and custom value resolvers

All 9 sync functions refactored to use these helpers. Remaining opportunity:
- **Group fetching** duplicated across 4 group-based syncs (~40 lines × 4). Create `Get-FGGroupsForSync` helper.

### High-Priority: Massive Functions to Break Down

| Function | Lines | Suggested Split |
|----------|-------|----------------|
| `New-FGConfig.ps1` | 836 | Extract: `Select-FGAzureSubscription`, `Select-FGResourceGroup`, `Select-FGSqlServer`, `Select-FGAutomationAccount`, `Select-FGAppRegistration`, `Get-FGSyncSettings`. Move `New-FGRandomPassword`/`New-FGRandomSqlName`/`New-FGRandomAutomationAccountName` to `Functions/Specific/` |
| `New-FGAzureAutomationAccount.ps1` | 1,408 | Extract: `New-FGAutomationVariables`, `New-FGAutomationRunbooks`, `New-FGAutomationSchedules` |
| `New-FGUI.ps1` | 877 | Extract Kudu deployment logic shared with `Update-FGUI.ps1` (~115 lines) into `Deploy-FGUIToAppService` helper |

### High-Priority: Generic Functions Consolidation

**"All" and "AllToFile" function pairs** have 95%+ duplication:
- `Get-FGGroupMemberAll.ps1` / `Get-FGGroupMemberAllToFile.ps1`
- `Get-FGGroupTransitiveMemberAll.ps1` / `Get-FGGroupTransitiveMemberAllToFile.ps1`

**Action:** Merge each pair into one function with optional `-OutputFile` parameter. The 52-line JSON restructuring routine is identical in both "ToFile" functions — extract to a shared helper.

**URI filter building** is duplicated across 6+ Get functions (Get-FGUser, Get-FGGroup, Get-FGApplication, Get-FGServicePrincipal, Get-FGCatalog, Get-FGDevice). Consider a shared `Build-FGGraphUri` helper.

**Missing `[cmdletbinding()]`** on: `Get-FGGroupMemberAll`, `Get-FGGroupMemberAllToFile`, `Get-FGGroupTransitiveMemberAll`, `Get-FGGroupTransitiveMemberAllToFile`.

### Medium-Priority: SQL Function Improvements

~~**SQL injection risks** (parameterize these):~~ **RESOLVED**
- ~~`Get-FGSQLTable.ps1`: Schema/pattern in WHERE via string interpolation~~ → parameterized via `Invoke-FGSQLCommand`
- ~~`Get-FGSyncLog.ps1`: SyncType/Status in WHERE via string interpolation~~ → parameterized via `Invoke-FGSQLCommand`
- ~~`New-FGSQLReadOnlyUser.ps1`: Password embedded directly in SQL string~~ → username validated with `[a-zA-Z0-9_]` regex, password escaped

**Connection management inconsistency** — 2 functions bypass `Invoke-FGSQLCommand`:
- `Write-FGSyncLog.ps1` (lines 98-172): Manual connection management
- `New-FGSQLReadOnlyUser.ps1` (lines 103-141): Manual connection management

**Extract shared SQL helpers:**
- `Set-FGSQLTableVersioning -Enable/-Disable` (duplicated in `Add-FGSQLTableColumn` and `Clear-FGSQLTable`)
- `ConvertTo-FGSQLType` / `ConvertTo-FGDotNetType` (duplicated in `Invoke-FGSQLBulkDelete` and `Invoke-FGSQLBulkMerge`)
- Table name parsing with schema (duplicated in `Clear-FGSQLTable` and `Get-FGSQLTableSchema`)

### Medium-Priority: Sync Performance & Reliability

**Missing batching options** — these load all data into memory (risk `OutOfMemoryException` for large tenants):
- `Sync-FGGroupOwner` — no batching option
- `Sync-FGUser` / `Sync-FGGroup` — no batching for very large tenants

**Retry logic** only exists in `Sync-FGAccessPackageResourceRoleScope`. Move to `Invoke-FGGetRequest` or create `Invoke-FGGetRequestWithRetry` so all sync functions benefit from transient error handling (429, 503, 504).

**Deduplication** only in some sync functions (`Sync-FGAccessPackageAssignment`, `Sync-FGAccessPackageAssignmentRequest`). Add to `Sync-FGUser`, `Sync-FGGroup`, `Sync-FGGroupMember` to prevent MERGE failures.

**GC calls** only in 2 sync functions. Standardize `[System.GC]::Collect()` every 50 iterations in all batching loops.

**Token refresh during long syncs:** `Start-FGSync` gets a token once at start. For 2+ hour syncs, tokens expire (~1 hour). The token check in `Invoke-FGGetRequest` should handle this, but verify it works correctly within runspaces where global state is copied.

**No dependency enforcement in Start-FGSync:** GroupMembers can start before Groups completes. Consider adding sync phases (Phase 1: Users+Groups, Phase 2: memberships, Phase 3: access packages, Phase 4: materialized views).

### Medium-Priority: Deprecated Patterns

**OAuth2 v1 endpoints** used in 4 files (v1 being deprecated by Microsoft):
- `Get-FGAccessToken.ps1` line 117: `/oauth2/token`
- `Get-FGAccessTokenInteractive.ps1` lines 23, 32
- `Get-FGAccessTokenWithRefreshToken.ps1` line 21

**Action:** Migrate to `/oauth2/v2.0/token` endpoint.

### Medium-Priority: Specific/Automation Cleanup

**Typos** (appear throughout `Functions/Specific/`):
- "cataloge" → "catalog" (in `Confirm-FGAccessPackage`, `Confirm-FGCatalog`, `Confirm-FGGroupInCatalog`)
- "More then one" → "More than one" (in 6+ Confirm-FG* functions)

**Dutch comment** in `Confirm-FGGroup.ps1` line 57 — violates English-only rule.

**Duplicate `Invoke-AzureRestApi` / `Invoke-GraphApi`** helpers defined inline in both `New-FGUI.ps1` and `Remove-FGUI.ps1`. Extract to shared helper in `Functions/Base/`.

**Config loading** duplicated across 3 automation functions (`Get-FGAutomationJob`, `Get-FGAutomationRunbook`, `Start-FGAutomationRunbook`). Extract to `Get-FGConfigAzureContext`.

**Confirm-FGGroupMember / Confirm-FGNotGroupMember** share 40+ lines of identical member resolution logic. Extract to `Resolve-FGMemberObjectIds`.

### UI Backend Improvements

**Security (Critical):**
- ~~`index.js` line 14: `app.use(cors())` allows ALL origins~~ → **RESOLVED:** CORS now configured with `ALLOWED_ORIGINS` env var; production blocks cross-origin by default
- ~~No rate limiting on any endpoint~~ → **RESOLVED:** Added `express-rate-limit` on pre-auth endpoints (30 req/min per IP); `helmet` for security headers (CSP, HSTS, X-Frame-Options, Referrer-Policy); `express.json({ limit: '100kb' })` body size cap; startup warning when `AUTH_ENABLED` not set in production; `/api/auth-config` no longer confirms auth is disabled
- Error responses leak SQL schema info (table names, column names) — sanitize error messages
- No audit logging for mutations — log user identity + changes for compliance
- ~~Auth middleware (`auth.js`) doesn't validate token scopes/roles~~ → **RESOLVED:** Added tenant ID validation and optional role-based access control via `AUTH_REQUIRED_ROLES` env var
- ~~Bulk operations (`/tags/:id/assign-by-filter`) have no row limit~~ → **RESOLVED:** Added `TOP 50000` safety cap; hex color validation (`/^#[0-9a-fA-F]{6}$/`) on tag and category create/update endpoints

**~~Performance (Critical):~~** **RESOLVED**
- ~~`tags.js` lines 194-206: N+1 query in tag assignment loop — batch into single INSERT~~ → batched into single parameterized INSERT with NOT EXISTS
- ~~`tags.js` lines 226-231: Same N+1 pattern in unassign loop~~ → batched into single DELETE with IN clause
- ~~`tags.js` line 98: Subquery COUNT per row — use LEFT JOIN + GROUP BY instead~~ → replaced with LEFT JOIN + GROUP BY (also fixed same pattern in `categories.js` line 50)
- ~~Column discovery runs on every request — add TTL-based cache (5 min)~~ → extracted to `db/columnCache.js` with 5-minute TTL

**Code Quality:**
- ~~Column discovery logic duplicated between `permissions.js` and `tags.js`~~ → **RESOLVED:** extracted to shared `db/columnCache.js` with TTL cache
- `ensureTagTables` / `ensureCategoryTables` — extract to shared `ensureTable` utility
- Pagination parameter parsing duplicated across routes
- ~~`db/connection.js`: No pool error handling, no graceful shutdown, no reconnect logic~~ → **RESOLVED:** Added pool error listener with auto-reconnect, `closePool()` export, and graceful SIGTERM/SIGINT shutdown in `index.js`
- Inconsistent response formats across endpoints — standardize to `{ data, total, ... }`

### UI Frontend Improvements

**Performance:**
- ~~No code splitting — all 5 pages bundled eagerly~~ → **RESOLVED:** All 5 pages use `React.lazy()` + `<Suspense>` for route-based code splitting
- ~~ExcelJS (~200KB) loaded on every page~~ → **RESOLVED:** Dynamic `import()` in `handleExportExcel` — ExcelJS only loads when user clicks Export
- ~~@dnd-kit (~110KB) loaded even when drag not active — lazy-load~~ → **RESOLVED:** Extracted to `SortableMatrixBody.jsx` (separate chunk, ~60KB), dynamically imported. MatrixView renders static rows immediately, upgrades to sortable when chunk loads
- ~~No virtual scrolling in matrix — becomes slow with 100+ groups~~ → **RESOLVED:** `@tanstack/react-virtual` virtualizes table rows (overscan=20). During drag, virtualization is disabled so all rows are in the DOM for accurate drop positioning
- ~~`MatrixCell.jsx` memo comparison (line 80) missing `apNames` prop — stale renders possible~~ → **RESOLVED:** Added `apNames` to memo comparison

**Code Duplication:**
- ~~`UsersPage.jsx` / `GroupsPage.jsx`: 95% identical (565 lines each)~~ → **RESOLVED:** Extracted `useEntityPage` hook to `hooks/useEntityPage.js`; both pages reduced from ~565 to ~270 lines
- Tag operation handlers duplicated in AccessPackagesPage — could use `useEntityPage` hook too
- `TAG_COLORS` array defined 3 times — move to shared constants
- Search debounce pattern repeated in 4 places — extract `useDebouncedValue` hook
- Pagination UI duplicated in 3 pages — extract `PaginationControls` component
- `AP_COLORS` array duplicated in `MatrixColumnHeaders.jsx` and `exportToExcel.js`

**Architecture:**
- `MatrixView.jsx` (584 lines) handles data transformation + row reordering + Excel export + rendering — split into data hook + presentation
- App.jsx passes 16 props to MatrixView — consider Context or custom hook
- Prop drilling: MatrixView (36 props) → MatrixToolbar (21 props) → FilterBar (7 props)

**Accessibility:**
- Filter dropdowns use `<div onClick>` instead of `<button>` — not keyboard accessible
- Missing `<label>` elements on search inputs (placeholder is not a label)
- No visible focus indicators on custom inputs
- Color-only indicators (AP colors, type badges) need non-color alternatives for color-blind users

### Error Handling Consistency (Cross-Cutting)

**PowerShell functions:** ~40+ Generic functions have zero error handling. At minimum, Graph API calls should have try/catch with meaningful error messages. Consider a standard error pattern for all Generic functions.

**Frontend API calls:** Several places silently swallow errors (`catch { /* ignore */ }` in UsersPage line 81, GroupsPage line 79). Should at minimum log to console.

**`$ReturnValue += $Result`** in multiple Base HTTP functions uses `+=` on null, creating unexpected array types. Initialize `$ReturnValue = @()` or use explicit assignment.

### Minor Improvements

- **JSON depth:** Multiple files hardcode `-Depth 10` for `ConvertTo-Json`. Use `-Depth 100` to avoid silent truncation
- **Base64 padding:** Duplicated in `Get-FGAccessTokenDetail.ps1` for header and payload — extract helper
- **Config property navigation:** Duplicated across `Get-FGSecureConfigValue`, `Clear-FGSecureConfigValue`, `Test-FGSecureConfigValue` — extract helper
- **SecureString conversion:** 4 duplicates in `Get-FGSecureConfigValue.ps1` — extract `ConvertFrom-SecureStringToPlainText`
- **Parameter naming inconsistency** in Generic functions: `$id` vs `$Id`, `$DisplayName` vs `$displayName`, `$ObjectId` vs `$objectId`. Standardize to PascalCase
- **Invoke-FGPutRequest.ps1** debug output says "PatchRequest" instead of "PutRequest" (copy-paste error)
- **Device code timeout** hardcoded to 300s in `Get-FGAccessTokenInteractive.ps1` — make parameter with default
