# Config File Reference

FortigiGraph uses a single JSON config file that drives all operations — authentication, SQL connection, sync settings, UI deployment, risk scoring, and account correlation. The file is created interactively by `New-FGConfig` and updated by `Update-FGConfig`.

```powershell
# Create a new config file (interactive wizard)
New-FGConfig -Path .\Config\mycompany.json

# Add keys that are missing after a module upgrade
Update-FGConfig -Path .\Config\mycompany.json
```

!!! warning "Keep config files out of source control"
    Config files contain encrypted credentials. The module's `.gitignore` excludes `Config/*.json`. Never commit these files.

---

## Full Annotated Example

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
    "ParallelExecution": true,
    "Users": { "Enabled": true, "AdditionalAttributes": [] },
    "Groups": { "Enabled": true },
    "GroupMembers": { "Enabled": true },
    "GroupEligibleMembers": { "Enabled": true },
    "GroupOwners": { "Enabled": true },
    "Catalogs": { "Enabled": true },
    "AccessPackages": { "Enabled": true },
    "AccessPackageAssignments": { "Enabled": true },
    "AccessPackageResourceRoleScopes": { "Enabled": true },
    "AccessPackageAssignmentPolicies": { "Enabled": true },
    "AccessPackageAssignmentRequests": { "Enabled": true },
    "AccessPackageAccessReviews": { "Enabled": true },
    "Principals": { "Enabled": true },
    "ServicePrincipals": { "Enabled": false },
    "EntraDirectoryRoles": { "Enabled": true },
    "EntraAppRoleAssignments": { "Enabled": true },
    "ResourceRelationships": { "Enabled": true },
    "Contexts": { "Enabled": true },
    "PrincipalActivity": { "Enabled": false },
    "AppRoleActivity": { "Enabled": false },
    "Views": { "Enabled": true },
    "MaterializedViews": { "Enabled": true }
  },
  "UI": {
    "WebAppName": "ui-xxxxx",
    "AppServicePlanName": "ui-xxxxx-plan",
    "Location": "northeurope",
    "Sku": "B1",
    "URL": "https://ui-xxxxx.azurewebsites.net",
    "Auth": {
      "AppRegistrationName": "FortigiGraph-UI-ui-xxxxx",
      "ClientId": "...",
      "TenantId": "..."
    }
  },
  "RiskScoring": {
    "Enabled": true,
    "Schedule": { "Enabled": true, "Time": "10:30", "Frequency": "Daily" }
  },
  "AccountCorrelation": {
    "Enabled": true,
    "Schedule": { "Enabled": true, "Time": "11:00", "Frequency": "Daily" }
  }
}
```

---

## Section: Azure

Controls which Azure subscription and resources FortigiGraph uses for SQL and Automation.

| Key | Type | Description |
|-----|------|-------------|
| `TenantId` | string | Entra ID tenant ID or domain name (e.g. `contoso.onmicrosoft.com`). Used for `Connect-AzAccount` in automation scenarios. |
| `SubscriptionId` | string | Azure subscription ID where resources are deployed. |
| `ResourceGroupName` | string | Resource Group containing the SQL Server, Automation Account, and (optionally) the UI App Service. |
| `Location` | string | Azure region for all created resources (e.g. `northeurope`, `eastus`). |
| `SQLServerName` | string | Logical SQL Server name (without `.database.windows.net`). Generated with a random suffix by `New-FGConfig`. |
| `DatabaseName` | string | Database name on the SQL Server. Default: `GraphData`. |
| `AdminUsername` | string | SQL Server administrator username. |
| `AdminUserPassword_Encrypted` | string | SQL admin password, encrypted with Windows DPAPI. Decrypted at runtime on the same machine and user account that encrypted it. |
| `AutomationAccountName` | string | Azure Automation Account name. Populated by `New-FGAzureAutomationAccount`. |

!!! note "DPAPI encryption"
    Keys ending in `_Encrypted` are encrypted using Windows Data Protection API (DPAPI) with user-scoped protection. The encrypted value is only decryptable on the same Windows user account that created it. When deploying to Azure Automation, credentials are re-encrypted as Automation Variables — the `_Encrypted` values in the config file are not used directly by the runbook.

---

## Section: Graph

Authentication credentials for the Microsoft Graph API App Registration created by `New-FGConfig`.

| Key | Type | Description |
|-----|------|-------------|
| `TenantId` | string | Tenant where the App Registration lives. Usually the same as `Azure.TenantId`. |
| `ClientId` | string | Application (client) ID of the App Registration. |
| `ClientSecret_Encrypted` | string | Client secret, encrypted with Windows DPAPI. |

The App Registration requires these Graph API application permissions (assigned automatically by `New-FGConfig`):

| Permission | Purpose |
|-----------|---------|
| `User.Read.All` | Read all users |
| `Group.Read.All` | Read all groups |
| `GroupMember.Read.All` | Read group memberships |
| `Directory.Read.All` | Read directory data |
| `Application.Read.All` | Read service principals and app role assignments |
| `PrivilegedEligibilitySchedule.Read.AzureADGroup` | Read PIM group eligibility |
| `EntitlementManagement.Read.All` | Read catalogs, access packages, assignments, policies, requests |
| `AccessReview.Read.All` | Read access review decisions |
| `AuditLog.Read.All` | Read sign-in and audit events |

---

## Section: Sync

Controls which entity types are included in `Start-FGSync` and how the sync runs.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `ParallelExecution` | bool | `true` | Run up to 6 entity type syncs concurrently using a runspace pool. Set to `false` for sequential execution when troubleshooting. |

Each entity type has at minimum an `Enabled` flag:

### Entra ID Principals

| Key | Default | Description |
|-----|---------|-------------|
| `Users.Enabled` | `true` | Sync Entra ID users to `Principals` (and legacy `GraphUsers`). |
| `Users.AdditionalAttributes` | `[]` | Extra Graph API attributes to request and store in `extendedAttributes` JSON. Example: `["department", "jobTitle", "employeeId"]`. |
| `Principals.Enabled` | `true` | Sync to the new `Principals` table (universal model). Should always be `true` when `Users` is enabled. |
| `ServicePrincipals.Enabled` | `false` | Sync service principals, managed identities, workload identities, and AI agents. Disabled by default due to volume. Enable for non-human identity risk analysis. |

### Groups and Memberships

| Key | Default | Description |
|-----|---------|-------------|
| `Groups.Enabled` | `true` | Sync Entra ID groups to `Resources` (and legacy `GraphGroups`). |
| `GroupMembers.Enabled` | `true` | Sync direct group memberships to `ResourceAssignments` (and `GraphGroupMembers`). |
| `GroupEligibleMembers.Enabled` | `true` | Sync PIM-eligible group memberships (requires `PrivilegedEligibilitySchedule.Read.AzureADGroup`). |
| `GroupOwners.Enabled` | `true` | Sync group owner relationships. Owners appear as separate rows in the UI matrix. |

### Directory Roles and App Roles

| Key | Default | Description |
|-----|---------|-------------|
| `EntraDirectoryRoles.Enabled` | `true` | Sync Entra ID directory roles and their assignments to `Resources` and `ResourceAssignments`. |
| `EntraAppRoleAssignments.Enabled` | `true` | Sync application role assignments to `Resources` and `ResourceAssignments` (requires `Application.Read.All`). |
| `ResourceRelationships.Enabled` | `true` | Sync resource-to-resource links (e.g. group-to-app relationships) to `ResourceRelationships`. |

### Governance (Access Packages / Business Roles)

| Key | Default | Description |
|-----|---------|-------------|
| `Catalogs.Enabled` | `true` | Sync Entra ID Entitlement Management catalogs to `GovernanceCatalogs`. |
| `AccessPackages.Enabled` | `true` | Sync access packages to `Resources` with `resourceType='BusinessRole'`. |
| `AccessPackageAssignments.Enabled` | `true` | Sync active AP assignments to `ResourceAssignments` with `assignmentType='Governed'`. |
| `AccessPackageResourceRoleScopes.Enabled` | `true` | Sync AP resource scope links to `ResourceRelationships` with `relationshipType='Contains'`. |
| `AccessPackageAssignmentPolicies.Enabled` | `true` | Sync AP assignment policies to `AssignmentPolicies`. |
| `AccessPackageAssignmentRequests.Enabled` | `true` | Sync AP request history to `AssignmentRequests`. |
| `AccessPackageAccessReviews.Enabled` | `true` | Sync access review decisions to `CertificationDecisions` (requires `AccessReview.Read.All`). |

### Organizational and Activity Data

| Key | Default | Description |
|-----|---------|-------------|
| `Contexts.Enabled` | `true` | Calculate organizational contexts (departments, teams, etc.) from `Identities` data and populate `Contexts`. |
| `PrincipalActivity.Enabled` | `false` | Sync last sign-in timestamps for stale account detection (requires `AuditLog.Read.All`). Expensive for large tenants. |
| `AppRoleActivity.Enabled` | `false` | Sync app role usage activity. Requires `AuditLog.Read.All`. |

### Views

| Key | Default | Description |
|-----|---------|-------------|
| `Views.Enabled` | `true` | Recreate SQL views (`vw_*`) after each sync to reflect schema changes. |
| `MaterializedViews.Enabled` | `true` | Refresh materialized (physical) view tables used by the UI matrix for performance. Disable only during troubleshooting. |

---

## Section: UI

Populated by `New-FGUI`. Controls the deployed web application.

| Key | Type | Description |
|-----|------|-------------|
| `WebAppName` | string | Azure App Service name (also the subdomain of `azurewebsites.net`). |
| `AppServicePlanName` | string | App Service Plan name. |
| `Location` | string | Azure region for the App Service (can differ from SQL location). |
| `Sku` | string | App Service SKU tier. Set by `New-FGUI` or `Set-FGUI -Scaling`. Examples: `B1`, `P0v3`, `P1v3`. |
| `URL` | string | Full URL of the deployed application. |
| `Auth.AppRegistrationName` | string | Display name of the UI's own App Registration (separate from the sync App Registration). |
| `Auth.ClientId` | string | Client ID of the UI App Registration, used for MSAL authentication in the browser. |
| `Auth.TenantId` | string | Tenant ID for UI authentication. |

---

## Section: RiskScoring

| Key | Type | Description |
|-----|------|-------------|
| `Enabled` | bool | Whether risk scoring is active. When `false`, the Automation runbook skips risk scoring steps. |
| `Schedule.Enabled` | bool | Whether the Automation Account runs risk scoring on a schedule. |
| `Schedule.Time` | string | Time of day for the scheduled run (24-hour format, e.g. `"10:30"`). |
| `Schedule.Frequency` | string | Recurrence. Currently only `"Daily"` is supported. |

---

## Section: AccountCorrelation

Account correlation links principals across systems to a single real-person Identity record.

| Key | Type | Description |
|-----|------|-------------|
| `Enabled` | bool | Whether account correlation is active. |
| `Schedule.Enabled` | bool | Whether correlation runs on a schedule in Azure Automation. |
| `Schedule.Time` | string | Time of day for the scheduled run (e.g. `"11:00"`). |
| `Schedule.Frequency` | string | Recurrence. Currently only `"Daily"` is supported. |

---

## Adding Keys After a Module Upgrade

When a new version of FortigiGraph adds new config sections or keys, run:

```powershell
Update-FGConfig -Path .\Config\mycompany.json
```

This merges any missing keys from the current template into your existing config file without overwriting values you have already set.
