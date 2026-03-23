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
