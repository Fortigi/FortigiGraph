# FortigiGraph

**Unlock the insights hidden in your identity governance that the Azure Portal doesn't show you.**

FortigiGraph syncs authorization data from multiple systems to Azure SQL with temporal versioning, enabling powerful governance insights, access analysis, and identity auditing. The universal resource model supports Entra ID groups, directory roles, application roles, and can be extended to SharePoint, Azure RBAC, SAP/Pathlock, DevOps, and more.

---

## Getting Started

FortigiGraph provides a guided setup wizard that creates everything you need: Azure resources, App Registration with the right permissions, SQL Server, and a config file that drives all operations.

### Prerequisites

- PowerShell 7+ (required)
- Azure subscription with Contributor access
- Az PowerShell module: `Install-Module Az -Scope CurrentUser`

### Step 1: Install the Module

```powershell
# From PowerShell Gallery
Install-Module -Name FortigiGraph -Scope CurrentUser

# Or clone and import locally
git clone https://github.com/Fortigi/FortigiGraph.git
cd FortigiGraph
Import-Module .\FortigiGraph.psd1
```

### Step 2: Run the Setup Wizard

```powershell
New-FGConfig -Path .\Config\mycompany.json
```

The wizard walks you through:
- **Azure Login** - Logs you in and selects your subscription
- **Resource Group** - Select an existing one or create a new one
- **SQL Server** - Creates an Azure SQL Server and database (or selects existing)
- **Automation Account** - Creates an Azure Automation Account for scheduled syncs
- **App Registration** - Creates the app with the right Graph API permissions:
  - `User.Read.All`, `Group.Read.All`, `GroupMember.Read.All`
  - `Directory.Read.All`, `EntitlementManagement.Read.All`
  - `AccessReview.Read.All`, `AuditLog.Read.All`
- **Sync Settings** - Choose which data to sync (users, groups, memberships, access packages, etc.)

At the end, it saves everything to a config file and shows you the next steps.

### Step 3: Authenticate and Connect

```powershell
# Authenticate to Microsoft Graph
Get-FGAccessToken -ConfigFile '.\Config\mycompany.json'

# Connect to Azure SQL Server (updates firewall automatically)
Connect-FGSQLServer -ConfigFile '.\Config\mycompany.json'
```

### Step 4: Run Your First Sync

```powershell
Start-FGSync -ConfigFile '.\Config\mycompany.json'
```

This syncs all enabled data types in parallel:
- Users (→ GraphUsers + Principals), Groups (→ GraphGroups + Resources)
- Group Memberships (direct, eligible, owners → ResourceAssignments)
- Entra Directory Roles and members, Application Role Assignments
- Access Package Catalogs, Packages, Assignments, Policies, Requests, Reviews
- OrgUnits (calculated from department data)
- Resource relationships (group nesting, app role grants)
- Creates performance indexes and analytical SQL views automatically

### Step 5: Set Up Scheduled Syncs (Optional)

```powershell
New-FGAzureAutomationAccount -ConfigFile '.\Config\mycompany.json'
```

This creates an Azure Automation Account with:
- Encrypted variables for all credentials
- Runbooks for each sync type
- Daily schedules (optional)
- SQL firewall rule for Azure services

### Step 6: Deploy the Role Mining UI

```powershell
New-FGUI -ConfigFile '.\Config\mycompany.json'
```

This deploys a web application to Azure App Service that visualizes your synced data as an interactive permission matrix. It is the recommended way to explore and analyze your Entra ID governance data.

See the [Role Mining UI](#role-mining-ui) section below for full details on the UI features.

### Step 7: Run Identity Risk Scoring (Optional)

```powershell
# Generate an organizational risk profile (LLM-assisted, uses public domain info only)
New-FGRiskProfile -Domain "yourcompany.com" -LLMProvider Anthropic -LLMApiKey $apiKey -ConfigFile '.\Config\mycompany.json'

# Generate industry-specific risk classifiers from the profile
New-FGRiskClassifiers -ConfigFile '.\Config\mycompany.json'

# Score all users and groups (batch process, reads synced data)
Invoke-FGRiskScoring -ConfigFile '.\Config\mycompany.json'
```

This adds risk scores (0-100) and tier classifications (Critical/High/Medium/Low/Minimal/None) to all synced users and groups. Scores are visible in the UI's Risk Scoring page and Org Chart. See [Identity Risk Scoring](#identity-risk-scoring) for details.

### Verify Your Data

```powershell
# Check what tables were created
Get-FGSQLTable

# Query some data (v3.0 universal model)
Invoke-FGSQLQuery -Query "SELECT COUNT(*) AS PrincipalCount FROM Principals"
Invoke-FGSQLQuery -Query "SELECT resourceType, COUNT(*) FROM Resources GROUP BY resourceType"
Invoke-FGSQLQuery -Query "SELECT COUNT(*) AS OrgUnitCount FROM OrgUnits"

# Check sync log
Invoke-FGSQLQuery -Query "SELECT * FROM GraphSyncLog ORDER BY StartTime DESC"
```

### Create a Read-Only User for Power BI (Optional)

```powershell
New-FGSQLReadOnlyUser -ConfigFile '.\Config\mycompany.json'
```

---

## Role Mining UI

FortigiGraph includes a web-based Role Mining UI that visualizes your permission data as an interactive matrix, making it easy to discover role patterns and governance gaps. This is the primary way most users will interact with their synced data.

### Deployment

```powershell
# Deploy the UI (creates Azure App Service + App Registration + deploys code)
New-FGUI -ConfigFile '.\Config\mycompany.json'

# Deploy without authentication (for demos/development)
New-FGUI -ConfigFile '.\Config\mycompany.json' -NoAuth

# Redeploy after code changes (code-only, no resource creation)
Update-FGUI -ConfigFile '.\Config\mycompany.json'

# Remove the UI (stops billing)
Remove-FGUI -ConfigFile '.\Config\mycompany.json'
```

### Architecture

| Layer | Technology | Purpose |
|---|---|---|
| **Backend** | Node.js + Express | REST API querying FortigiGraph SQL views |
| **Frontend** | React + Vite + Tailwind CSS + TanStack Table v8 | Interactive SPA |
| **Authentication** | Entra ID (MSAL) | Supports v1 + v2 JWT token formats; `-NoAuth` for demos |
| **Deployment** | Azure App Service (Linux, Node 20, P0v3) | Oryx build-on-deploy |
| **Data Sources** | `Resources`, `Principals`, `ResourceAssignments`, `Systems`, `OrgUnits`, `Identities` + legacy `GraphUsers`/`GraphGroups` views | SQL tables created by `Start-FGSync` with automatic migration |

### Security Hardening

The UI backend includes multiple layers of security:

- **Helmet** — sets security headers (CSP, HSTS, X-Frame-Options, Referrer-Policy)
- **CORS** — configurable via `ALLOWED_ORIGINS` env var; production blocks cross-origin by default
- **Rate limiting** — pre-auth endpoints limited to 30 req/min per IP
- **Authentication** — Entra ID JWT validation with tenant ID enforcement and optional role-based access via `AUTH_REQUIRED_ROLES`
- **Parameterized queries** — all SQL queries use parameterized inputs (no string interpolation)
- **Input validation** — route params validated with `parseInt`/`isNaN`, UUIDs checked with regex, request body fields length-capped, array inputs capped at 500 items
- **Column name validation** — schema-derived column names validated against `[a-zA-Z0-9_]` regex before use in queries
- **Error sanitization** — error responses return generic messages; `console.error` logs only `err.message` (no stack traces or SQL schema details)
- **Body size limit** — `express.json({ limit: '100kb' })` prevents oversized payloads

### Pages

The UI has eleven pages accessible via tab navigation. The main tabs are Matrix, Users, Resources, Systems, Access Packages, and Sync Log. Five optional pages (Risk Scores, Identities, Org Chart, Performance) are hidden by default and can be enabled per-user via the settings dropdown:

#### Matrix View (default)

The core visualization — an interactive user-group permission matrix.

- **Rows** = resources (groups, roles, app permissions), **Columns** = users. Each cell shows the membership types (Direct, Indirect, Eligible, Owner) as colored badges
- **Staircase Sort**: Default row order groups rows by their leftmost access package, creating a visual staircase pattern. Unmanaged groups appear at the bottom
- **Access Package Coloring**: Managed cells are colored by their governing access package (15-color palette). Multi-AP cells show a count badge
- **Access Package Columns**: SOLL columns sorted first by category name, then by assignment count within each category; uncategorized access packages appear at the end. Category boundaries are marked with thicker borders and a colored indicator stripe.
- **IST/SOLL Toggle**: Filter to show all assignments, only unmanaged (IST), or only managed (SOLL)
- **Server-Side User Limit**: Slider (default 25) limits data at the SQL level for large environments
- **Drag-and-Drop**: Reorder rows to group related permissions together
- **Excel Export**: Full matrix export with AP-colored cells, rich-text badges, multi-AP notes, and AP columns next to users (matching the on-screen layout)
- **Share Link**: Copy a URL that preserves all active filters, user limit, and managed toggle

**Filtering** is split into two sections:

| Section | Fields | Applied |
|---|---|---|
| **User Filters** | All user attributes (department, job title, company, city, etc.) + User Tag | Server-side (full dataset) |
| **Group Filters** | Group name, membership type, Group Tag | Client-side (current page) |

Filters use a pill-based UI: click "+ Add filter" → select field → select value. Active filters appear as removable pills with inline value switching.

**Column header filters**: The Type and Tags columns have filter dropdowns in the column header. The Tags filter includes a "(Blank)" option to show only groups without any tags assigned.

#### Users Page

Browse and manage all synced users with pagination.

- **Tag Management**: Create colored tags, assign/remove tags from selected users, bulk-tag all matching a filter
- **Filtering**: Same pill-based FilterBar with all user attribute columns + User Tag
- **Text Search**: Search by display name or UPN
- **Selection**: Checkbox selection with bulk tag operations

#### Resources Page (formerly Groups)

Browse and manage all synced resources (groups, directory roles, app roles) with pagination.

- **Resource Type Filter**: Filter by EntraGroup, EntraDirectoryRole, EntraAppRole, etc.
- **System Filter**: Filter by connected system
- **Tag Management**: Create colored tags, assign/remove tags from selected resources, bulk-tag by filter
- **Filtering**: Pill-based FilterBar with all resource attribute columns + Resource Tag
- **Text Search**: Search by resource name or description
- **Selection**: Checkbox selection with bulk tag operations

#### Systems Page

View and manage connected authorization systems.

- **Card Layout**: Each system displayed as a card with name, type, enabled/disabled badge
- **Statistics**: Resource count and assignment count per system
- **Last Sync**: Shows when each system was last synced
- **Resource Types**: Lists the resource types and assignment types available in each system
- **Owner Management**: Assign/remove team owners for each system

#### Access Packages Page

Browse all synced access packages with their catalog, assignment count, and category.

- **Category Management**: Create colored categories, assign a category to selected access packages, or set it directly via an inline dropdown per row
- **Filtering**: Filter by category (click a category pill) or show only uncategorized packages
- **Text Search**: Search by access package name or catalog name
- **Selection**: Checkbox selection with bulk category operations

Unlike tags (which allow multiple per entity), each access package can have only **one** category assigned. Categories drive the column ordering in the Matrix view.

#### Sync Log

View the last 50 sync operations from `GraphSyncLog`, showing timestamps, entity types, row counts, and durations.

#### Identities (optional, hidden by default)

Account correlation and identity matching across systems.

#### Risk Scoring (optional, hidden by default)

Visualize identity risk scores across all users and groups (requires running `Invoke-FGRiskScoring` first).

- **Score Visualization**: 0-100 risk score bars with tier badges (Critical/High/Medium/Low/Minimal/None)
- **Per-Layer Breakdown**: Direct classifier match, membership analysis, structural hygiene, and cross-entity propagation scores
- **Analyst Overrides**: Manually adjust risk scores (-50 to +50) with required justification
- **Classifier Matches**: See exactly which risk patterns triggered for each entity
- **Filtering**: Filter by tier, search by name, view overrides only

#### Org Chart (optional, hidden by default)

Manager hierarchy visualization with risk propagation.

- **Tree Layout**: Hybrid layout — horizontal flowchart at root level, vertical indented tree for deeper levels
- **Risk Coloring**: Department boxes color-coded by maximum risk tier in the subtree
- **Report Counts**: Direct and indirect report counts per manager
- **Department Drill-Down**: Click a department to open a detail page showing all members with risk scores
- **Search**: Filter by department name

#### Performance (optional, hidden by default)

Opt-in backend performance monitoring (enable with `-PerformanceMetrics` on `New-FGUI` or `Update-FGUI`).

- **Endpoint Summaries**: P50/P95/P99 response times per API route
- **Recent & Slowest Requests**: Drill into individual requests with per-SQL-query breakdowns
- **Server-Timing Headers**: Appear in browser DevTools for real-time performance visibility
- **Export**: Download JSON for offline analysis

### Tagging System

Tags are user-defined labels (e.g. "VIP", "Contractors", "Finance Groups") that can be assigned to users or groups. They serve two purposes:

1. **Organization**: Visually label entities in the Users/Groups tables
2. **Filtering**: Use as filter criteria on any page (Users, Groups, or Matrix)

Tags are stored in the `GraphTags` and `GraphTagAssignments` SQL tables (auto-created on first use). Clicking a tag pill on the Users/Groups page adds it as a filter; it also appears as a "User Tag" or "Group Tag" option in the standard filter bar.

### Category System

Categories are user-defined labels for access packages (e.g. "Identity", "Office 365", "Security"). Unlike tags, each access package can only have **one** category — this enforces clean grouping. Categories serve two purposes:

1. **Organization**: Label access packages on the Access Packages page
2. **Matrix Column Ordering**: AP columns in the Matrix view are sorted by category name first, then by assignment count within each category. Uncategorized APs appear at the end.

Categories are stored in the `GraphCategories` and `GraphCategoryAssignments` SQL tables (auto-created on first use). The `GraphCategoryAssignments` table has a primary key on `accessPackageId`, enforcing the single-category constraint.

### User Preferences

Each user can customize which optional tabs are visible via the settings dropdown (click the user avatar in the top-right corner). This keeps the interface clean by default while allowing power users to enable advanced features.

**Optional tabs** (hidden by default):
- **Risk Scores** — Identity risk scoring visualization
- **Identities** — Account correlation and identity matching
- **Org Chart** — Manager hierarchy with risk propagation
- **Performance** — Backend performance monitoring

Preferences are stored per-user in the `GraphUserPreferences` SQL table (auto-created on first access). When authentication is enabled, each user is identified by their Entra ID Object ID; in no-auth mode, a shared `anonymous` profile is used.

### Access Package Details

Clicking an access package name opens a detail tab with lazy-loaded collapsible sections:

- **Assignments** — Active users assigned to this access package (with UPN and assigned date)
- **Resource Assignments** — Groups and resources included in the package, with Member/Owner role badges
- **Assignment Policies** — Policy type (Auto-assigned / Request-based / with auto-removal), scope, and creation date
- **Access Reviews** — Review decisions with auto-review detection (lightning bolt icon for system-completed reviews)
- **Pending Requests** — Outstanding assignment requests with requestor details
- **Version History** — Temporal table diffs showing what changed and when

The review status column on the Access Packages page distinguishes between "Not required" (no review configured on any policy) and "Pending first review" (review configured but no instance created yet).

### UI API Reference

All endpoints require `Authorization: Bearer <JWT>` unless auth is disabled (`-NoAuth`). The backend runs on port 3001 and serves the React SPA for non-API routes.

#### Unauthenticated Endpoints

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/health` | Health check. Returns `{ status: "ok", mode: "sql"\|"mock" }` |
| `GET` | `/api/auth-config` | Auth configuration for MSAL. Returns `{ enabled, clientId?, tenantId? }` |

#### Matrix / Permissions

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/user-columns` | Column discovery for Matrix filters. Returns filterable columns from `GraphUsers` with up to 500 distinct values per column. Includes virtual `__userTag` and `__groupTag` columns if tags exist. |
| `GET` | `/api/permissions` | Main matrix data. Returns permission assignments with all user attributes, access package mappings, and total user count. |
| `GET` | `/api/access-package-groups` | Access package → group mapping with role names and assignment counts. |
| `GET` | `/api/sync-log` | Recent sync log entries from `GraphSyncLog`. |

**GET /api/permissions** query parameters:

| Parameter | Type | Description |
|---|---|---|
| `userLimit` | int | Limit to top N users by assignment count. `0` = all users. |
| `filters` | JSON string | Server-side filters: `{"department":"HR","__userTag":"VIP"}` |

Response:
```json
{
  "data": [
    {
      "groupId": "uuid",
      "groupDisplayName": "SG-Finance-Base",
      "memberId": "uuid",
      "memberDisplayName": "Jane Doe",
      "membershipType": "Direct",
      "department": "Finance",
      "jobTitle": "Analyst",
      "managedByAccessPackage": true
    }
  ],
  "totalUsers": 156,
  "managedByPackages": [
    { "memberId": "uuid", "groupId": "uuid", "accessPackageIds": ["ap-001"] }
  ]
}
```

**GET /api/sync-log** query parameters:

| Parameter | Type | Default | Description |
|---|---|---|---|
| `limit` | int | 20 | Number of entries (max 100) |

#### Systems

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/systems` | List all systems with resource/assignment counts |
| `GET` | `/api/systems/:id` | Single system detail |
| `PUT` | `/api/systems/:id` | Update system (displayName, description, enabled) |
| `GET` | `/api/systems/:id/owners` | System owners |
| `POST` | `/api/systems/:id/owners` | Add system owner |
| `DELETE` | `/api/systems/:id/owners/:userId` | Remove system owner |

#### Resources

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/resources` | Paginated resource list with type/system/tag filters |
| `GET` | `/api/resources/:id` | Resource detail with extendedAttributes, tags, counts |
| `GET` | `/api/resources/:id/members` | Resource members with assignment types |
| `GET` | `/api/resources/:id/history` | Temporal version history |
| `GET` | `/api/resource-columns` | Column discovery for Resources table |

#### OrgUnits

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/org-units` | List all OrgUnits with hierarchy |
| `GET` | `/api/org-units/tree` | Pre-built tree for org chart |
| `GET` | `/api/org-units/:id` | OrgUnit detail with members and sub-units |
| `GET` | `/api/org-units/:id/members` | Paginated member list |

#### Users Page

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/user-columns-page` | Column discovery for Users page filters. Same format as `/api/user-columns` but scoped to the Users page. Includes `__userTag` virtual column. |
| `GET` | `/api/users` | Paginated user list with tags. |

**GET /api/users** query parameters:

| Parameter | Type | Default | Description |
|---|---|---|---|
| `search` | string | | Search displayName or UPN (LIKE) |
| `tagId` | int | | Filter by tag ID (legacy, still supported) |
| `limit` | int | 100 | Page size (max 500) |
| `offset` | int | 0 | Pagination offset |
| `filters` | JSON string | | Attribute filters: `{"department":"HR","__userTag":"VIP"}` |

Response:
```json
{
  "data": [
    {
      "id": "uuid",
      "displayName": "Jane Doe",
      "userPrincipalName": "jane@contoso.com",
      "department": "Finance",
      "jobTitle": "Analyst",
      "companyName": "Contoso",
      "accountEnabled": true,
      "tags": [{ "id": 1, "name": "VIP", "color": "#3b82f6" }]
    }
  ],
  "total": 1234
}
```

#### Groups Page

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/group-columns` | Column discovery for Groups page filters. Includes `__groupTag` virtual column. |
| `GET` | `/api/groups` | Paginated group list with tags. |

**GET /api/groups** query parameters:

| Parameter | Type | Default | Description |
|---|---|---|---|
| `search` | string | | Search displayName or description (LIKE) |
| `tagId` | int | | Filter by tag ID (legacy, still supported) |
| `limit` | int | 100 | Page size (max 500) |
| `offset` | int | 0 | Pagination offset |
| `filters` | JSON string | | Attribute filters: `{"groupTypeCalculated":"Security","__groupTag":"Critical"}` |

Response:
```json
{
  "data": [
    {
      "id": "uuid",
      "displayName": "SG-Finance-Base",
      "groupTypeCalculated": "Security",
      "description": "Base access for Finance",
      "tags": [{ "id": 2, "name": "Critical", "color": "#ef4444" }]
    }
  ],
  "total": 567
}
```

#### Tag Management

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/tags?entityType=user\|group` | List tags (optionally filtered by entity type). Returns name, color, assignment count. |
| `POST` | `/api/tags` | Create a tag. Body: `{ name, color?, entityType }`. Unique per (name, entityType). |
| `PATCH` | `/api/tags/:id` | Update tag name and/or color. Body: `{ name?, color? }` |
| `DELETE` | `/api/tags/:id` | Delete tag and all its assignments (cascade). |
| `POST` | `/api/tags/:id/assign` | Assign tag to specific entities. Body: `{ entityIds: ["uuid", ...] }` |
| `POST` | `/api/tags/:id/unassign` | Remove tag from specific entities. Body: `{ entityIds: ["uuid", ...] }` |
| `POST` | `/api/tags/:id/assign-by-filter` | Bulk-assign tag to all entities matching a search/filter. Body: `{ entityType, search?, filters? }` |

#### Category Management

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/categories` | List all categories with assignment count. |
| `POST` | `/api/categories` | Create a category. Body: `{ name, color? }`. Name must be unique. |
| `PATCH` | `/api/categories/:id` | Update category name and/or color. Body: `{ name?, color? }` |
| `DELETE` | `/api/categories/:id` | Delete category and all its assignments (cascade). |
| `POST` | `/api/categories/:id/assign` | Assign category to an access package (replaces any existing category). Body: `{ accessPackageId }` |
| `POST` | `/api/categories/unassign` | Remove the category from an access package. Body: `{ accessPackageId }` |
| `GET` | `/api/category-assignments` | All category assignments as flat list (used by Matrix for column ordering). |

#### User Preferences

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/preferences` | Get current user's tab visibility preferences. Returns `{ visibleTabs: ["risk-scores", ...] }` |
| `PUT` | `/api/preferences` | Update tab visibility. Body: `{ visibleTabs: ["risk-scores", "performance"] }`. Only accepts known optional tab keys. |

#### Access Package Detail

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/access-package/:id` | Core attributes, counts, assignment type, category, review info |
| `GET` | `/api/access-package/:id/assignments` | Active user assignments (state = Delivered) with user names |
| `GET` | `/api/access-package/:id/resource-roles` | Resource role scopes (groups/resources with Member/Owner roles) |
| `GET` | `/api/access-package/:id/policies` | Assignment policies with auto-assignment flags |
| `GET` | `/api/access-package/:id/reviews` | Access review decisions |
| `GET` | `/api/access-package/:id/requests` | Pending assignment requests |
| `GET` | `/api/access-package/:id/history` | Temporal version history |

#### Access Packages Page

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/access-packages` | Paginated access package list with category info. |

**GET /api/access-packages** query parameters:

| Parameter | Type | Default | Description |
|---|---|---|---|
| `search` | string | | Search displayName or catalog name (LIKE) |
| `categoryId` | int | | Filter by category ID |
| `uncategorized` | string | | Set to `true` to show only uncategorized packages |
| `limit` | int | 100 | Page size (max 500) |
| `offset` | int | 0 | Pagination offset |

### Filter Architecture

The UI uses a hybrid filtering approach for optimal performance:

```
┌─────────────────────────────────────────────────┐
│ Frontend (React)                                 │
│                                                  │
│  activeFilters: [{field, value}, ...]            │
│         │                                        │
│         ├── User attribute filters ──────────► Server-side (SQL WHERE)
│         │   (department, jobTitle, __userTag)     │
│         │                                        │
│         └── Relationship filters ──────────────► Client-side (JS filter)
│             (groupDisplayName, membershipType)   │
│                                                  │
│  Column discovery:                               │
│    /api/user-columns → full dataset values       │
│    Data rows → current page values               │
│                                                  │
│  Debounced fetch (400ms) on filter change        │
└─────────────────────────────────────────────────┘
```

**Server-side filters** (applied in SQL) are more efficient for large datasets — they reduce data before it reaches the browser. These include all columns from `GraphUsers` plus the virtual `__userTag` and `__groupTag` tag columns.

**Client-side filters** are applied in JavaScript after data is loaded. These include relationship-level fields like `membershipType` and `groupDisplayName` that come from the permission view rather than the users table.

All filters use parameterized SQL queries to prevent injection. Virtual tag columns (`__userTag`, `__groupTag`) are extracted from the filters object and translated to tag table subqueries before the main query runs.

---

## Why FortigiGraph?

### Identity Governance Insights You Can't Get from Entra ID

The Role Mining UI covers the most common analysis scenarios visually. For advanced or custom queries, FortigiGraph's SQL views give you full flexibility.

#### 1. IST vs SOLL Analysis (As-Is vs Should-Be State)

**The Problem**: In Entra ID, you can't easily see the gap between what users *should* have (access package assignments) and what they *actually* have (direct group memberships).

**What FortigiGraph Gives You**:

The Matrix View's IST/SOLL toggle shows this visually. For custom analysis:

```sql
-- Find users with DIRECT group memberships when they should only have access through packages
SELECT * FROM vw_UnmanagedPermissions;
```

**Use Cases**:
- Identify "backdoor" access that bypasses governance
- Clean up direct assignments that should be managed by access packages
- Audit compliance with access governance policies

#### 2. Access Package Assignment Analysis

**The Problem**: Entra ID doesn't show you aggregate views of who has what through access packages, which packages are most used, or how assignments have changed over time.

```sql
-- Complete view of user permissions via access packages
SELECT * FROM vw_UserPermissionAssignmentViaAccessPackage;

-- All permission assignments (direct, indirect, eligible, owner)
SELECT * FROM vw_UserPermissionAssignments;
```

#### 3. Approval Timeline Analysis

**The Problem**: Entra ID doesn't provide aggregate statistics on how long access requests take to approve.

```sql
-- Approval response times with buckets (< 1 hour, 1-4 hours, etc.)
SELECT * FROM vw_ApprovedRequestTimeline;

-- Find pending requests and how long they've been waiting
SELECT * FROM vw_PendingRequestTimeline WHERE hoursPending > 24;

-- Aggregate approval statistics
SELECT * FROM vw_RequestResponseMetrics;
```

#### 4. Access Review Insights

**The Problem**: Entra ID shows individual review results, but doesn't aggregate patterns or completion rates.

```sql
-- Access package last review details
SELECT * FROM vw_AccessPackageLastReview;

-- Denied request patterns
SELECT * FROM vw_DeniedRequestTimeline;
```

#### 5. Direct vs Governed Access

**The Problem**: You can't easily see which memberships are managed through governance vs direct assignment.

```sql
-- Complete membership analysis: Owner, Direct, Indirect, Eligible
SELECT * FROM vw_UserPermissionAssignments
WHERE memberId = 'user-guid-here';

-- Recursive group memberships with full paths
SELECT * FROM vw_GraphGroupMembersRecursive
WHERE groupId = 'group-guid-here'
ORDER BY depth;
```

#### 6. Temporal/Historical Analysis

**The Problem**: Entra ID only shows current state. You can't answer "who had access on this date?"

```sql
-- Who had access to a specific group on January 15th?
SELECT * FROM GraphGroupMembers
FOR SYSTEM_TIME AS OF '2025-01-15 10:00:00'
WHERE groupId = 'your-group-id';

-- Track all changes for a specific user
SELECT userPrincipalName, department, ValidFrom, ValidTo
FROM GraphUsers FOR SYSTEM_TIME ALL
WHERE userPrincipalName = 'john.doe@contoso.com'
ORDER BY ValidFrom DESC;
```

---

## Features

### Core Capabilities
- **Guided Setup**: `New-FGConfig` wizard creates all Azure resources and config in one go
- **Easy Authentication**: Service principal and interactive auth with automatic token refresh
- **Azure SQL Integration**: Temporal tables with automatic version history tracking
- **High-Performance Sync**: SqlBulkCopy-based operations (20-50x faster than row-by-row)
- **Parallel Execution**: Sync up to 6 entity types concurrently
- **Role Mining UI**: Interactive web application for visual permission analysis

### Data Sync
- **Users → Principals**: User accounts with core columns + extendedAttributes JSON
- **Groups → Resources**: Groups, directory roles, app roles — all as universal resources
- **Memberships → ResourceAssignments**: Direct, PIM eligible, and owner relationships
- **Access Packages**: Catalogs, packages, assignments, policies, requests, reviews
- **OrgUnits**: Organizational units calculated from department data
- **Identities**: Real persons aggregated from multiple accounts (account correlation)
- **Automatic Schema Evolution**: Add new columns without recreating tables
- **Multi-System Support**: Systems table enables importing from multiple authorization sources

### Analytical Views
FortigiGraph creates SQL views automatically for instant insights:

**Group Membership Views** (via `Initialize-FGGroupMembershipViews`):
- `vw_GraphGroupMembersRecursive` - All memberships (direct + indirect) with paths
- `vw_UserPermissionAssignments` - Comprehensive view with all types as separate rows: Owner, Direct, Indirect, Eligible (a user can have multiple types per group, e.g. Direct + Owner)

**Access Package Views** (via `Initialize-FGAccessPackageViews`):
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

**Resource Model Views** (via `Initialize-FGResourceViews`):
- `vw_ResourceMembersRecursive` - All resource memberships (direct + indirect) with paths
- `vw_ResourceUserPermissionAssignments` - Comprehensive view with all types across all resource types

### Identity Risk Scoring
- **LLM-Assisted Profiling**: `New-FGRiskProfile` discovers organizational context from public domain info (no sensitive data sent to LLM)
- **Industry-Specific Classifiers**: `New-FGRiskClassifiers` generates regex-based detection patterns for group/user names
- **4-Layer Scoring Engine**: Direct classifier match, membership analysis, structural hygiene, cross-entity propagation
- **Batch Processing**: `Invoke-FGRiskScoring` scores all users and groups, writing results back to SQL
- **Resource Clustering**: Automatically groups related resources into logical clusters with owner assignment
- **Analyst Overrides**: Human-in-the-loop score adjustments with required justification
- **Resource-Type-Aware Scoring**: Configurable multipliers per resource type (EntraDirectoryRole 1.5x, EntraAppRole 1.2x). Multipliers determined by LLM during risk profiling
- **Type-Specific Signals**: Directory roles scored with critical role patterns (Global Admin +25), app roles scored with permission patterns (.ReadWrite +10)

### Production Ready
- **Azure Automation**: One-command setup with `New-FGAzureAutomationAccount`
- **Config-Driven**: All settings in one JSON file
- **Secure Credentials**: Encrypted credential storage using Windows DPAPI
- **Comprehensive Logging**: Sync statistics logged to `GraphSyncLog` table

---

## Identity Risk Scoring

FortigiGraph includes an identity risk scoring engine that assigns risk scores (0-100) to all synced users and groups. Scores are computed entirely on your own infrastructure — no sensitive identity data is sent to external services.

### How It Works

The scoring system has three phases:

**Phase 1: Organizational Context** (one-time setup, LLM-assisted)
```powershell
# Discover organizational profile from public domain info
New-FGRiskProfile -Domain "yourcompany.com" -LLMProvider Anthropic -LLMApiKey $key -ConfigFile '.\Config\mycompany.json'

# Generate industry + organization-specific classifiers
New-FGRiskClassifiers -ConfigFile '.\Config\mycompany.json'
```

**Phase 2: Batch Scoring** (run after each sync)
```powershell
# Score all users and groups using 4-layer analysis
Invoke-FGRiskScoring -ConfigFile '.\Config\mycompany.json'
```

**Phase 3: Analysis** (via UI or SQL)
- View scores in the Risk Scoring and Org Chart UI pages
- Query risk data directly: `SELECT displayName, riskScore, riskTier FROM GraphUsers ORDER BY riskScore DESC`

### Scoring Layers

| Layer | Signal | Weight |
|-------|--------|--------|
| **1. Direct Match** | Regex classifiers against entity names/descriptions | Primary |
| **2. Membership** | PIM eligible, high-risk group membership, outlier detection | Secondary |
| **3. Structural** | Missing description, no owner, stale accounts, hygiene signals | Tertiary |
| **4. Propagation** | Cross-entity risk: group→user (30%), user→group (25%) | Derived |

### Risk Tiers

| Tier | Score Range | Meaning |
|------|-------------|---------|
| Critical | 80-100 | Requires immediate attention |
| High | 60-79 | Should be reviewed soon |
| Medium | 40-59 | Monitor regularly |
| Low | 20-39 | Low concern |
| Minimal | 1-19 | Negligible risk |
| None | 0 | No risk signals detected |

### Data Privacy

- **Phase 1 only** sends data to an LLM (Anthropic Claude or OpenAI) — and only public organizational context (domain, industry, known systems)
- **No identity data** (user names, group memberships, emails) is ever sent to external services
- All scoring happens locally against your SQL database
- Supports both Anthropic and OpenAI as LLM providers

---

## Config File

The config file drives all FortigiGraph operations. Create one with `New-FGConfig` or manually from the template in `Config/tenantname.json.template`.

### Structure

```json
{
  "Azure": {
    "TenantId": "yourtenant.onmicrosoft.com",
    "SubscriptionId": "your-subscription-id",
    "ResourceGroupName": "rg-fortigraph",
    "Location": "northeurope",
    "SQLServerName": "sql-fortigraph-xxxxx",
    "DatabaseName": "GraphData",
    "AdminUsername": "sqladmin",
    "AdminUserPassword_Encrypted": "...",
    "AutomationAccountName": "aa-fortigraph-xxxxx"
  },
  "Graph": {
    "TenantId": "yourtenant.onmicrosoft.com",
    "ClientId": "your-app-client-id",
    "ClientSecret_Encrypted": "..."
  },
  "Sync": {
    "Users": { "Enabled": true, "TableName": "GraphUsers", "AdditionalAttributes": [] },
    "Groups": { "Enabled": true, "TableName": "GraphGroups" },
    "GroupMembers": { "Enabled": true, "TableName": "GraphGroupMembers" },
    "GroupEligibleMembers": { "Enabled": true },
    "GroupOwners": { "Enabled": true, "TableName": "GraphGroupOwners" },
    "Catalogs": { "Enabled": true, "TableName": "GraphCatalogs" },
    "AccessPackages": { "Enabled": true },
    "AccessPackageAssignments": { "Enabled": true },
    "AccessPackageResourceRoleScopes": { "Enabled": true },
    "AccessPackageAssignmentPolicies": { "Enabled": true },
    "AccessPackageAssignmentRequests": { "Enabled": true },
    "AccessPackageAccessReviews": { "Enabled": true },
    "Views": { "Enabled": true },
    "ParallelExecution": true
  }
}
```

---

## Authentication

### Service Principal (Automated/Scheduled Tasks)

```powershell
# Using config file (recommended)
Get-FGAccessToken -ConfigFile '.\Config\mycompany.json'

# Or with explicit parameters
Get-FGAccessToken -TenantId "contoso.onmicrosoft.com" -ClientId "app-client-id" -ClientSecret "secret"
```

### Interactive (User Delegation)

```powershell
Get-FGAccessTokenInteractive -TenantId "contoso.onmicrosoft.com" -ClientId "app-client-id"
```

### Required Permissions

| Permission | Purpose |
|---|---|
| `User.Read.All` | Read all users |
| `Group.Read.All` | Read all groups |
| `GroupMember.Read.All` | Read group memberships |
| `Directory.Read.All` | Read directory data |
| `EntitlementManagement.Read.All` | Read access packages, catalogs, assignments |
| `AccessReview.Read.All` | Read access review decisions |
| `AuditLog.Read.All` | Read sign-in activity (used by user sync) |

`New-FGConfig` sets up all these permissions automatically when creating a new App Registration.

---

## Data Synchronization

### Orchestrated Sync

```powershell
# Sync everything based on config file settings
Start-FGSync -ConfigFile '.\Config\mycompany.json'
```

`Start-FGSync` handles:
- Authentication (always gets a fresh token)
- SQL connection with firewall management
- Parallel execution of all enabled sync types
- Performance index creation
- Analytical view creation
- Summary report with statistics

### Individual Sync Commands

```powershell
# Users (with extra attributes)
Sync-FGUser -AdditionalAttributes @('officeLocation', 'city', 'employeeType')

# Groups
Sync-FGGroup

# Memberships
Sync-FGGroupMember              # Direct memberships
Sync-FGGroupEligibleMember      # PIM eligible memberships
Sync-FGGroupOwner               # Group owners

# Access Packages
Sync-FGCatalog
Sync-FGAccessPackage
Sync-FGAccessPackageAssignment
Sync-FGAccessPackageResourceRoleScope
Sync-FGAccessPackageAssignmentPolicy
Sync-FGAccessPackageAssignmentRequest
Sync-FGAccessPackageAccessReview
```

### Automatic Schema Evolution

Add new attributes without recreating the table:

```powershell
# First run - default attributes
Sync-FGUser

# Later - add new attributes (columns added automatically)
Sync-FGUser -AdditionalAttributes @('employeeType', 'officeLocation')
```

---

## SQL Management

```powershell
# Connect using config file
Connect-FGSQLServer -ConfigFile '.\Config\mycompany.json'

# List tables
Get-FGSQLTable

# Query data
Invoke-FGSQLQuery -Query "SELECT * FROM GraphUsers WHERE department = 'IT'"
$count = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM GraphUsers" -AsScalar

# Clear table (preserves history)
Clear-FGSQLTable -TableName "GraphUsers_Test"

# Clear table and history
Clear-FGSQLTable -TableName "GraphUsers_Test" -DeleteHistory -Force
```

---

## Temporal Tables & Historical Queries

All synced data uses SQL Server temporal tables for automatic change tracking.

```sql
-- Current data
SELECT * FROM GraphUsers;

-- Point-in-time query
SELECT * FROM GraphUsers FOR SYSTEM_TIME AS OF '2025-06-15 10:00:00';

-- All history
SELECT * FROM GraphUsers FOR SYSTEM_TIME ALL
WHERE userPrincipalName = 'john@contoso.com'
ORDER BY ValidFrom DESC;

-- Changes in the last 30 days
SELECT * FROM GraphGroupMembers FOR SYSTEM_TIME ALL
WHERE ValidFrom >= DATEADD(DAY, -30, GETDATE())
ORDER BY ValidFrom DESC;
```

---

## Azure Automation

Set up automated scheduled syncs with a single command:

```powershell
New-FGAzureAutomationAccount -ConfigFile '.\Config\mycompany.json'
```

**What it creates:**
- Azure Automation Account
- Encrypted variables for Graph and SQL credentials
- Runbooks for each sync type (Users, Groups, Members, Catalogs, Access Packages, etc.)
- Daily schedules (optional, configurable time zone)
- SQL firewall rule for Azure services

**Memory considerations:** Azure Automation sandbox has a 400 MB limit. Group member sync uses `-UseBatching` mode for constant memory usage.

**Post-setup:**
1. Import FortigiGraph module via Azure Portal > Automation Account > Modules > Browse Gallery
2. Wait for module imports to complete
3. Test runbooks manually before enabling schedules

---

## Attribute Mapping Discovery

Discover and document attribute mappings across your identity infrastructure:

```powershell
# Get all apps with provisioning configured
$apps = Get-FGServicePrincipalWithSync -IncludeSchema

# Extract attribute mappings
$mappings = Get-FGAttributeMapping -ServicePrincipalWithSync $apps

# Export for analysis
$mappings | Export-Csv -Path "attribute-mappings.csv" -NoTypeInformation
```

Works with HR provisioning (Workday, SuccessFactors), Azure AD Connect Cloud Sync, and SCIM applications.

---

## Repository Structure

```
FortigiGraph/
├── Functions/              # All PowerShell functions
│   ├── Base/               # Authentication & HTTP operations (21 functions)
│   ├── Generic/            # Graph API wrappers (49 functions)
│   ├── Specific/           # Business logic helpers (9 functions)
│   ├── SQL/                # Azure SQL operations (24 functions)
│   ├── Sync/               # Data synchronization (16 functions)
│   ├── Automation/         # Azure Automation & UI management (8 functions)
│   └── RiskScoring/        # Identity risk scoring engine (13 functions)
├── UI/                     # Role Mining Web Application
│   ├── backend/            # Node.js + Express API server
│   └── frontend/           # React + Vite + Tailwind
├── Config/                 # Configuration templates
│   └── tenantname.json.template
├── _Build/                 # Build and publishing scripts
├── _Test/                  # Testing scripts and documentation
├── FortigiGraph.psm1       # Module entry point
├── FortigiGraph.psd1       # Module manifest
└── README.md
```

**Total: 140 functions**

---

## Troubleshooting

### Debug Mode

```powershell
$Global:DebugMode = 'G'     # GET requests
$Global:DebugMode = 'P'     # POST/PATCH requests
$Global:DebugMode = 'D'     # DELETE requests
$Global:DebugMode = 'T'     # Token operations
$Global:DebugMode = 'GP'    # Multiple categories
```

### Common Issues

| Issue | Solution |
|---|---|
| SQL connection fails | `Connect-FGSQLServer -ConfigFile config.json` (updates firewall automatically) |
| "No Access Token found" | Run `Get-FGAccessToken -ConfigFile config.json` |
| Permission errors after changing app | `Start-FGSync` always gets a fresh token; for manual use run `Get-FGAccessToken` again |
| Temporal table schema error | Don't modify tables directly; use `Sync-FG*` functions which handle schema changes |
| Can't truncate temporal table | Use `DELETE` or `Clear-FGSQLTable` instead of `TRUNCATE` |

---

## Requirements

- **PowerShell**: 7 or later (required)
- **Azure**: Subscription with Contributor access
- **Modules**: `Az` PowerShell module (`Install-Module Az -Scope CurrentUser`)
- **Permissions**: See [Required Permissions](#required-permissions) table

---

## Support

- **GitHub Issues**: [Report bugs or request features](https://github.com/Fortigi/FortigiGraph/issues)
- **Examples**: Check `_Test/` folder and `Config/tenantname.json.template`

---

## License

MIT License - see [LICENSE](LICENSE) for details.

---

**Author**: Wim van den Heijkant | **Company**: Fortigi
**GitHub**: [github.com/Fortigi/FortigiGraph](https://github.com/Fortigi/FortigiGraph) | **PowerShell Gallery**: [FortigiGraph](https://www.powershellgallery.com/packages/FortigiGraph)
