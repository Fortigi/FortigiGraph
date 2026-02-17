# FortigiGraph

**Unlock the insights hidden in your Entra ID Governance that the Azure Portal doesn't show you.**

FortigiGraph syncs Microsoft Graph data to Azure SQL with temporal versioning, enabling powerful governance insights, access analysis, and identity auditing that simply aren't possible through the Entra ID portal alone.

---

## Getting Started

FortigiGraph provides a guided setup wizard that creates everything you need: Azure resources, App Registration with the right permissions, SQL Server, and a config file that drives all operations.

### Prerequisites

- PowerShell 7+ (recommended) or PowerShell 5.1
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
- Users, Groups, Group Memberships (direct, eligible, owners)
- Access Package Catalogs, Packages, Assignments, Policies, Requests, Reviews
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

### Verify Your Data

```powershell
# Check what tables were created
Get-FGSQLTable

# Query some data
Invoke-FGSQLQuery -Query "SELECT COUNT(*) AS UserCount FROM GraphUsers"
Invoke-FGSQLQuery -Query "SELECT TOP 5 displayName, userPrincipalName FROM GraphUsers"

# Check sync log
Invoke-FGSQLQuery -Query "SELECT * FROM GraphSyncLog ORDER BY StartTime DESC"
```

### Create a Read-Only User for Power BI (Optional)

```powershell
New-FGSQLReadOnlyUser -ConfigFile '.\Config\mycompany.json'
```

---

## Why FortigiGraph?

### Identity Governance Insights You Can't Get from Entra ID

#### 1. IST vs SOLL Analysis (As-Is vs Should-Be State)

**The Problem**: In Entra ID, you can't easily see the gap between what users *should* have (access package assignments) and what they *actually* have (direct group memberships).

**What FortigiGraph Gives You**:

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

### Data Sync
- **Users**: All user properties including custom/extension attributes
- **Groups**: Group details with security, type, and organization info
- **Memberships**: Direct, transitive, PIM eligible, and owner relationships
- **Access Packages**: Catalogs, packages, assignments, policies, requests, reviews
- **Automatic Schema Evolution**: Add new columns without recreating tables

### Analytical Views
FortigiGraph creates SQL views automatically for instant insights:

**Group Membership Views** (via `Initialize-FGGroupMembershipViews`):
- `vw_GraphGroupMembersRecursive` - All memberships (direct + indirect) with paths
- `vw_UserPermissionAssignments` - Comprehensive view: Owner, Direct, Indirect, Eligible

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

### Production Ready
- **Azure Automation**: One-command setup with `New-FGAzureAutomationAccount`
- **Config-Driven**: All settings in one JSON file
- **Secure Credentials**: Encrypted credential storage using Windows DPAPI
- **Comprehensive Logging**: Sync statistics logged to `GraphSyncLog` table

---

## Role Mining UI (Beta)

> **Warning**: The Role Mining UI is currently in **beta**. It does **not include authentication or authorization**. Anyone with network access to the web application can view the permission data. Deploy it only in trusted environments or behind a VPN/reverse proxy with authentication. Do not expose it to the public internet.

FortigiGraph includes an optional web-based Role Mining UI that visualizes your permission data as an interactive matrix, making it easy to discover role patterns and governance gaps.

### Features

- **Permission Matrix**: Interactive heatmap showing user-group assignments with membership type indicators (Direct, Indirect, Eligible, Owner)
- **IST/SOLL/Both Toggle**: Switch between showing all assignments, only unmanaged (IST), or only managed-by-access-package (SOLL)
- **Server-Side User Limit**: Adjustable slider (default 25 users) that limits data at the SQL level, keeping the UI fast even with hundreds of thousands of assignments
- **Managed Indicator**: Cells where the membership is managed by an access package are visually distinguished (blue background vs green)
- **Annotation Brushes**: Color-code cells for role discovery, export annotations to Excel or JSON
- **Access Package Overlay**: SOLL columns showing which groups are governed by access packages
- **Drag-and-Drop**: Reorder rows and columns to group related permissions together
- **Multi-Filter**: Filter by department, job title, membership type, and more
- **Excel Export**: Export the matrix with colors and annotations to `.xlsx`

### Quick Start

```powershell
# Deploy the UI (creates Azure App Service + deploys code)
New-FGUI -ConfigFile '.\Config\mycompany.json'

# Redeploy after code changes (code-only, no resource creation)
Update-FGUI -ConfigFile '.\Config\mycompany.json'

# Remove the UI (stops billing)
Remove-FGUI -ConfigFile '.\Config\mycompany.json'
```

### Architecture

- **Backend**: Node.js + Express serving a REST API that queries the FortigiGraph SQL views
- **Frontend**: React + Vite + Tailwind CSS + TanStack Table v8
- **Deployment**: Azure App Service (Linux, Node 20) with Oryx build-on-deploy
- **Data**: Reads directly from `vw_UserPermissionAssignments` and related views

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
Sync-FGGroupTransitiveMember    # Transitive (includes nested)
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
│   ├── Base/               # Authentication & HTTP operations (20 functions)
│   ├── Generic/            # Graph API wrappers (49 functions)
│   ├── Specific/           # Business logic helpers (9 functions)
│   ├── SQL/                # Azure SQL operations (24 functions)
│   ├── Sync/               # Data synchronization (14 functions)
│   └── Automation/         # Azure Automation management (4 functions)
├── UI/                     # Role Mining Web Application (Beta)
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

**Total: 120 functions**

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

- **PowerShell**: 5.1 or later (7+ recommended)
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
