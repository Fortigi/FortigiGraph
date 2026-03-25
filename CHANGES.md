# FortigiGraph v3.0 — Universal Resource & Identity Model

**Branch:** `feature/universal-resource-model`
**Date:** 2026-03-21
**Base:** `dev`

## Summary

Major data model refactoring to support multi-system authorization data. The previous model was Entra-ID-centric (GraphGroups, GraphUsers). The new model introduces a universal hierarchy: **Systems > Resources/Principals > OrgUnits > Identities** — enabling import of permissions from any authorization source (Entra ID, SharePoint, Azure RBAC, SAP/Pathlock, DevOps, file shares, etc.).

## Data Model

```
                                    ┌──────────┐
                                    │ Systems  │
                                    │ (1)      │
                                    └────┬─────┘
                         ┌───────────────┼───────────────┐
                         │               │               │
                    ┌────▼────┐    ┌─────▼─────┐   ┌─────▼─────┐
                    │Resources│    │Principals │   │ OrgUnits  │
                    │  (105)  │    │   (34)    │   │   (8)     │
                    └────┬────┘    └─────┬─────┘   └───────────┘
                         │               │               ▲
                    ┌────▼────────┐      │          orgUnitId
                    │Resource     │      │               │
                    │Assignments  │◄─────┘         ┌─────┴─────┐
                    │  (936)      │    principalId  │Identities │
                    └─────────────┘                 │   (34)    │
                         │                          └─────┬─────┘
                    ┌────▼────────┐                       │
                    │Resource     │                 ┌─────▼──────┐
                    │Relationships│                 │Identity    │
                    └─────────────┘                 │Members     │
                                                    └────────────┘
```

## New SQL Tables (9 total)

| Table | PK | Temporal | Purpose |
|-------|-----|----------|---------|
| `Systems` | INT IDENTITY | Yes | Connected authorization sources |
| `SystemOwners` | systemId + userId | No | Team ownership of systems |
| `Resources` | UNIQUEIDENTIFIER | Yes | Groups, roles, sites, permissions |
| `ResourceAssignments` | resourceId + principalId + assignmentType | Yes | Who has access to what |
| `ResourceRelationships` | parentResourceId + childResourceId + relationshipType | Yes | Resource-to-resource links |
| `Principals` | UNIQUEIDENTIFIER | Yes | User accounts from any system |
| `Identities` | UNIQUEIDENTIFIER | Yes | Real persons across systems |
| `IdentityMembers` | identityId + principalId | Yes | Links identities to principals |
| `OrgUnits` | UNIQUEIDENTIFIER | Yes | Organizational units (departments, teams) |

## New PowerShell Functions (12)

### SQL Schema
| Function | File | Purpose |
|----------|------|---------|
| `Initialize-FGSystemTables` | Functions/SQL/ | Creates all 9 new tables |
| `Initialize-FGResourceViews` | Functions/SQL/ | Creates resource permission views |
| `Initialize-FGResourceIndexes` | Functions/SQL/ | Creates performance indexes |

### Sync Functions
| Function | File | Purpose |
|----------|------|---------|
| `Sync-FGSystem` | Functions/Sync/ | Ensures system records exist |
| `Sync-FGEntraDirectoryRole` | Functions/Sync/ | Syncs Entra directory roles + members |
| `Sync-FGEntraAppRoleAssignment` | Functions/Sync/ | Syncs app role assignments |
| `Sync-FGResourceRelationship` | Functions/Sync/ | Discovers resource-to-resource links |
| `Sync-FGPrincipal` | Functions/Sync/ | Syncs Entra users to Principals |
| `Sync-FGOrgUnit` | Functions/Sync/ | Calculates OrgUnits from departments |
| `Invoke-FGResourceModelMigration` | Functions/Sync/ | Migrates GraphGroups → Resources |
| `Invoke-FGPrincipalMigration` | Functions/Sync/ | Migrates GraphUsers → Principals |

## Modified PowerShell Functions (7)

| Function | Changes |
|----------|---------|
| `Start-FGSync` | Added 6 new sync types (Principals, DirectoryRoles, AppRoles, ResourceRelationships, OrgUnits, migration) |
| `Initialize-FGAccessPackageViews` | Views now join through Resources/ResourceAssignments with GraphGroups fallback |
| `New-FGAzureAutomationAccount` | Added 3 new runbooks + updated materialized views runbook |
| `Update-FGUI` | Fixed SecureString token handling for newer Az module |
| `Invoke-FGRiskScoring` | Resource-type-aware scoring with configurable multipliers; reads from Resources + Principals |
| `Invoke-FGAccountCorrelation` | Reads from Principals, writes to Identities/IdentityMembers |
| `New-FGRiskProfile` | LLM now determines resource type scoring multipliers per organization |

## UI Changes

### New Pages
- **Systems tab** — Card-based view of connected authorization sources
- **Resources tab** — Replaces Groups tab with resourceType filter
- **OrgUnit detail page** — Department details with members and sub-units

### New Backend Routes
- `/api/systems` — System CRUD + owner management
- `/api/resources` — Resource list with type/system filters
- `/api/org-units` — OrgUnit list and tree endpoints

### Modified Backend Routes
- `/api/permissions` — Uses Resources table + new permission views; dynamic user/resource table detection
- `/api/group/:id` → `/api/resources/:id` — Resource detail with extendedAttributes
- `/api/users` — Uses Principals table with GraphUsers fallback
- `/api/user/:id` — User detail with extendedAttributes JSON display
- All routes use Principals → GraphUsers fallback pattern

### Frontend Changes
- **MatrixView** — Columns show `resourceType`, backward-compat field names
- **UserDetailPage** — Shows principalType badge, systemId, extendedAttributes
- **OrgChartPage** — Uses OrgUnits table for server-side tree building
- **GroupsPage** → **ResourcesPage** — Renamed with resourceType filter

## Risk Scoring Enhancements

### Resource-Type-Aware Scoring
- **Type multipliers**: EntraDirectoryRole (1.5x), EntraAppRole (1.2x), EntraGroup (1.0x baseline)
- **Type-specific structural signals**: Directory role patterns (Global Admin +25), app role patterns (.ReadWrite +10)
- **Type-specific propagation**: DirectoryRole 40%, AppRole 35%, Group 30%
- **LLM-determined multipliers**: `New-FGRiskProfile` generates org-specific multipliers via LLM

### Scoring Priority Chain
1. Config file override (explicit user settings)
2. Risk profile from SQL (LLM-determined)
3. Hardcoded defaults

## Design Patterns

### Core + JSON
Resources and Principals use the same pattern: frequently-queried attributes as real SQL columns, system-specific attributes in `extendedAttributes` JSON. This keeps the schema clean while allowing flexible extension.

### Backward Compatibility
All queries use try/catch fallback: prefer new tables (Resources, Principals), fall back to old tables (GraphGroups, GraphUsers). Both old and new tables coexist during migration.

### Deterministic GUIDs
OrgUnits and AppRole resources use MD5-based deterministic GUIDs for idempotent syncs.

## Files Changed

### New Files (16)
```
Functions/SQL/Initialize-FGSystemTables.ps1
Functions/SQL/Initialize-FGResourceViews.ps1
Functions/SQL/Initialize-FGResourceIndexes.ps1
Functions/Sync/Sync-FGSystem.ps1
Functions/Sync/Sync-FGEntraDirectoryRole.ps1
Functions/Sync/Sync-FGEntraAppRoleAssignment.ps1
Functions/Sync/Sync-FGResourceRelationship.ps1
Functions/Sync/Sync-FGPrincipal.ps1
Functions/Sync/Sync-FGOrgUnit.ps1
Functions/Sync/Invoke-FGResourceModelMigration.ps1
Functions/Sync/Invoke-FGPrincipalMigration.ps1
UI/backend/src/routes/systems.js
UI/backend/src/routes/resources.js
UI/backend/src/routes/orgUnits.js
UI/frontend/src/components/SystemsPage.jsx
UI/frontend/src/components/ResourceDetailPage.jsx
UI/frontend/src/components/OrgUnitDetailPage.jsx
```

### Modified Files (30)
```
CLAUDE.md
FortigiGraph.psd1
README.md
Functions/Automation/New-FGAzureAutomationAccount.ps1
Functions/Automation/Update-FGUI.ps1
Functions/RiskScoring/Invoke-FGAccountCorrelation.ps1
Functions/RiskScoring/Invoke-FGRiskScoring.ps1
Functions/RiskScoring/New-FGRiskProfile.ps1
Functions/RiskScoring/Save-FGResourceClusters.ps1
Functions/SQL/Initialize-FGAccessPackageViews.ps1
Functions/Sync/Start-FGSync.ps1
UI/backend/src/db/columnCache.js
UI/backend/src/index.js
UI/backend/src/routes/details.js
UI/backend/src/routes/identities.js
UI/backend/src/routes/orgChart.js
UI/backend/src/routes/permissions.js
UI/backend/src/routes/riskScores.js
UI/backend/src/routes/tags.js
UI/frontend/src/App.jsx
UI/frontend/src/components/GroupsPage.jsx
UI/frontend/src/components/MatrixView.jsx
UI/frontend/src/components/OrgChartPage.jsx
UI/frontend/src/components/UserDetailPage.jsx
UI/frontend/src/components/matrix/MatrixColumnHeaders.jsx
UI/frontend/src/components/matrix/MatrixGroupRow.jsx
UI/frontend/src/components/matrix/MatrixToolbar.jsx
UI/frontend/src/hooks/useMatrixRowOrder.js
UI/frontend/src/hooks/usePermissions.js
UI/frontend/src/utils/exportToExcel.js
```
## Changes in this branch

- Fixed categories endpoint handling in UI backend
- Updated access package detail page components
- Updated access packages page with improved export functionality
- Improved Excel export for access packages
- Updated module configuration setup
- Fixed: Access packages with zero active assignments no longer show "Overdue" or "In Progress" review status — if there are no assigned users there is nothing for a reviewer to act on
- `New-FGConfig`: Wizard now offers to run `New-FGRiskProfile` + `New-FGRiskClassifiers` immediately after setup when Risk Scoring is enabled and an LLM API key was configured
- Access Packages page now shows how many past review cycles were completely skipped (no reviewer acted) — displayed as "N reviews not done" under the compliance status badge, making it visible when an owner is not taking their review responsibility seriously
- Renamed review status "Overdue" to "Missed" — the deadline has passed and cannot be corrected until the next cycle, so "Missed" more accurately reflects the situation
- Access review reviewer type "User's manager" (targetManager) now displays as readable text instead of the raw Graph API type name
- Access packages with zero active assignments now show "No assignments" in the Review Status column instead of "Pending first review" — there are no users to review, so no review action is possible
- Access package detail page: "Open in Entra ID" link now points to the correct Azure Portal ELM blade (includes catalog ID and names)
- Access package detail page: policy scope values (e.g. "specificDirectoryUsers") now display as human-readable labels (e.g. "Specific directory users")
- Access package detail page: auto-assignment policy scope now shows the filter rule expression (e.g. which department or attribute conditions determine who gets the package automatically)
- Added `Export-FGCuratedData` and `Import-FGCuratedData` PowerShell functions to back up and restore manually curated data (tags, categories, analyst overrides) — useful when recreating environments
- Added Admin tab (hidden by default, enable via Settings): shows the saved Risk Profile, Risk Classifiers, and Account Correlation Ruleset stored in SQL — read-only view with expandable raw JSON
- Admin tab: Export and Import buttons for tags and categories — export downloads a JSON file; import matches by GUID first, falls back to soft-match by displayName + resourceType (for groups/resources) or displayName alone (for users and access packages); import result shows counts per match strategy
- Admin tab: Risk Classifiers section now shows built-in universal classifiers (with blue info banner) when no custom LLM-generated classifiers have been saved — same fallback behavior as Invoke-FGRiskScoring
- Admin tab: Risk Profile section now shows hardcoded resource-type multiplier defaults (with amber warning banner) when no LLM-generated profile has been saved — so the values actually used by Invoke-FGRiskScoring are always visible
- `New-FGAzureAutomationAccount`: When no sync schedules are configured in the config file, the wizard now prompts to add them with a user-specified time (default 06:00) and time zone — previously this prompt only triggered when zero schedules existed at all, causing it to be silently skipped when RiskScoring/AccountCorrelation schedules were already present; v3.0 sync types (EntraAppRoleAssignments, EntraDirectoryRoles, Principals, OrgUnits, ResourceRelationships) are now added to the config file when missing rather than silently skipped
- Added `Update-FGConfig` function: compares an existing config file against the module template and interactively offers to add any missing sections (top-level and Sync sub-keys) with template defaults — useful after upgrading the module; also runs automatically (silent check) at the start of `New-FGAzureAutomationAccount`
- Fixed `Sync-FGEntraAppRoleAssignment`: parameter name mismatch in internal `New-DeterministicGuid` helper (`$InputValue` vs `-InputString`) caused PowerShell to silently ignore the argument, producing the MD5 of empty string as the GUID for every app role resource — resulting in a PRIMARY KEY violation on the first sync run; also added a guard to skip app roles with null/empty IDs
- `New-FGConfig`: Added two missing Graph API permissions to the app registration — `Application.Read.All` (required for Sync-FGEntraAppRoleAssignment: reads service principals and app role assignments) and `PrivilegedAccess.Read.All` (required for Sync-FGGroupEligibleMember: reads PIM group eligibility schedules)
- Config template updated with all v3.0 sync types (Principals, EntraDirectoryRoles, EntraAppRoleAssignments, ResourceRelationships, OrgUnits)
- **BREAKING CHANGE:** Replaced all EntraID-specific `GraphAccessPackage*` tables with universal governance model — existing deployments must re-sync to populate the new tables (tags/categories can be exported first and re-imported)
- Added universal governance model tables: `GovernanceCatalogs`, `BusinessRoles`, `BusinessRoleResources`, `BusinessRoleAssignments`, `BusinessRolePolicies`, `BusinessRoleRequests`, `CertificationDecisions` — supporting business roles from any IGA platform (Entra ID, Omada, SailPoint, Pathlock, etc.)
- Added `complianceState` column to `ResourceAssignments` for tracking approval/certification status per assignment
- Added `Initialize-FGGovernanceTables` function to create all 7 governance tables with temporal versioning
- `Start-FGSync` now automatically initializes governance tables when access package syncs are active
- `CertificationDecisions` supports both per-business-role certifications (Entra ID style) and per-resource-assignment certifications (Omada style) via `certificationScopeType` discriminator
- `BusinessRolePolicies` includes `policyConditions` JSON column for ABAC rules (attribute-based access control conditions like job title or OU membership)
- Config template: updated default table names from legacy `GraphAccessPackage*` naming to universal governance names (`GovernanceCatalogs`, `BusinessRoles`, `BusinessRoleResources`, `BusinessRoleAssignments`, `BusinessRolePolicies`, `BusinessRoleRequests`, `CertificationDecisions`)
- `Initialize-FGAccessPackageViews`: Replaced all legacy table references and column names with universal governance model names — tables (`GraphAccessPackages` -> `BusinessRoles`, `GraphCatalogs` -> `GovernanceCatalogs`, etc.), columns (`accessPackageId` -> `businessRoleId`, `targetId` -> `principalId`, `assignmentPolicyId` -> `policyId`), parameters, and view names (`vw_UserPermissionAssignmentViaAccessPackage` -> `vw_UserPermissionAssignmentViaBusinessRole`, `vw_AccessPackageAssignmentDetails` -> `vw_BusinessRoleAssignmentDetails`, `vw_AccessPackageLastReview` -> `vw_BusinessRoleLastReview`)
- UI backend routes (`details.js`, `categories.js`, `permissions.js`, `governance.js`): Replaced all legacy SQL table/column/view references with universal governance model names — `GraphAccessPackages` -> `BusinessRoles`, `GraphCatalogs` -> `GovernanceCatalogs`, `GraphAccessPackageAssignments` -> `BusinessRoleAssignments`, `GraphAccessPackageResourceRoleScopes` -> `BusinessRoleResources`, `GraphAccessPackageAssignmentPolicies` -> `BusinessRolePolicies`, `GraphAccessPackageAssignmentRequests` -> `BusinessRoleRequests`, `GraphAccessPackageAccessReviewDecisions` -> `CertificationDecisions`; column renames `accessPackageId` -> `businessRoleId`, `targetId` -> `principalId`; category tables `GraphCategories` -> `GovernanceCategories`, `GraphCategoryAssignments` -> `GovernanceCategoryAssignments` with `accessPackageId` column -> `businessRoleId`
- Systems page now dynamically computes resource types and assignment types from the actual Resources and ResourceAssignments tables instead of relying on the (often empty) stored `resourceTypes` column — all synced resource types (EntraGroup, EntraDirectoryRole, EntraAppRole, etc.) and assignment types now appear as badges
- **BREAKING CHANGE:** Completed clean cutover from legacy tables — `Sync-FGGroup` now writes directly to `Resources` (with `extendedAttributes` JSON for group-specific fields), `Sync-FGGroupMember`/`Sync-FGGroupOwner`/`Sync-FGGroupEligibleMember` now write to `ResourceAssignments` with `assignmentType` column (Direct/Owner/Eligible), `Sync-FGUser` replaced by `Sync-FGPrincipal` in `Start-FGSync`
- No legacy tables (`GraphUsers`, `GraphGroups`, `GraphGroupMembers`, `GraphGroupOwners`, `GraphGroupEligibleMembers`, `GraphAccessPackage*`) are created on a clean install
- Removed migration functions from `Start-FGSync` orchestration — `Invoke-FGResourceModelMigration` and `Invoke-FGPrincipalMigration` are no longer called
- Removed legacy `Initialize-FGGroupMembershipViews` and `Initialize-FGGroupMembershipIndexes` from sync — replaced by `Initialize-FGResourceViews` and `Initialize-FGResourceIndexes`
- Added CSV import sync functions for loading data from external IGA platforms (e.g., Omada Identity): `Start-FGCSVSync` (orchestrator), `Sync-FGCSVSystem`, `Sync-FGCSVResource`, `Sync-FGCSVPrincipal`, `Sync-FGCSVIdentity`, `Sync-FGCSVResourceAssignment`, `Sync-FGCSVBusinessRole`, `Sync-FGCSVCertification`
- CSV sync loads data from semicolon-delimited exports into the universal data model (Systems, Resources, Principals, Identities, ResourceAssignments, BusinessRoles, BusinessRolePolicies, BusinessRoleResources, CertificationDecisions) using the same bulk MERGE patterns as Graph sync
