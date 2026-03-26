# Data Model Consolidation Analysis: Merging BusinessRoles into Resources

**Date:** 2026-03-25
**Context:** Discussion with senior data analyst colleague about whether the separate BusinessRoles and Resources tables should be unified into a single resource hierarchy.

---

## The Proposal

**Current state:** Two separate table groups — `Resources` (IST/as-is) and `BusinessRoles` (SOLL/should-be) — with a bridge table (`BusinessRoleResources`) connecting them.

**Proposed change:** Eliminate the `BusinessRoles` table group entirely. Instead, model business roles as resources with `resourceType = 'BusinessRole'` and use `ResourceRelationships` (parent-child) to express which permissions a business role grants. Nesting becomes natural: permissions inside application roles inside business roles.

---

## Current Data Model (v3.0)

```
┌──────────┐
│ Systems  │
└────┬─────┘
     │
     ├──────────────────────────────────────────────────┐
     │                                                  │
     │  RESOURCE MODEL (IST)                            │  GOVERNANCE MODEL (SOLL)
     │                                                  │
     ├──► Resources                                     ├──► GovernanceCatalogs
     │    (groups, roles, apps, sites)                   │    (containers)
     │                                                  │
     ├──► ResourceAssignments                           ├──► BusinessRoles
     │    (principalId + resourceId + type)              │    (access packages, bundles)
     │                                                  │
     ├──► ResourceRelationships                         ├──► BusinessRoleResources
     │    (parent-child, GrantsAccessTo)                 │    (which Resources a role grants)
     │                                                  │
     ├──► Principals                                    ├──► BusinessRoleAssignments
     │    (users, service principals)                    │    (who holds a role)
     │                                                  │
     ├──► OrgUnits                                      ├──► BusinessRolePolicies
     │    (departments, teams)                           │    (assignment rules, auto-add)
     │                                                  │
     ├──► Identities                                    ├──► BusinessRoleRequests
     │    (real persons across accounts)                 │    (request/approval workflow)
     │                                                  │
     └──► IdentityMembers                               └──► CertificationDecisions
          (identity-to-principal links)                       (review/attestation results)

Bridge: BusinessRoleResources.resourceId ──► Resources.id
Bridge: BusinessRoleAssignments.principalId ──► Principals.id
```

**Table count:** 7 governance tables + 8 resource model tables = **15 tables**

---

## Proposed Unified Data Model

```
┌──────────┐
│ Systems  │
└────┬─────┘
     │
     ├──► Resources
     │    resourceType: Group | DirectoryRole | AppRole | Site | BusinessRole | ApplicationRole | ...
     │    catalogId: UNIQUEIDENTIFIER (nullable, for governance containers)
     │
     ├──► ResourceAssignments
     │    assignmentType: Direct | Owner | Eligible | Governed | ...
     │    policyId: UNIQUEIDENTIFIER (nullable, links to assignment policy)
     │    complianceState: NVARCHAR (nullable)
     │    state: NVARCHAR (nullable, e.g. 'Delivered', 'PendingApproval')
     │    expirationDateTime: DATETIME2 (nullable)
     │
     ├──► ResourceRelationships
     │    relationshipType: Contains | GrantsAccessTo | NestIn | ...
     │    (BusinessRole ──Contains──► Group means "this role grants that group")
     │
     ├──► Principals
     │
     ├──► OrgUnits
     │
     ├──► Identities / IdentityMembers
     │
     ├──► GovernanceCatalogs (kept — containers are not resources)
     │
     ├──► AssignmentPolicies (renamed from BusinessRolePolicies)
     │    resourceId instead of businessRoleId
     │
     ├──► AssignmentRequests (renamed from BusinessRoleRequests)
     │    resourceId instead of businessRoleId
     │
     └──► CertificationDecisions
          resourceId instead of businessRoleId (already has this + existing field)
```

**Example of nesting in ResourceRelationships:**

```
BusinessRole: "Developer Access"
    ├── Contains ──► AppRole: "Azure DevOps Contributor"
    │                   └── Contains ──► Group: "DevOps-Project-Alpha"
    ├── Contains ──► Group: "Developers-SharePoint"
    └── Contains ──► DirectoryRole: "Application Developer"
```

**A principal assigned to "Developer Access" implicitly gets all child resources — traversable via the existing recursive CTE in `vw_ResourceMembersRecursive`.**

**Table count:** 3 kept from governance (Catalogs, Policies, Requests, Certifications renamed/adjusted) + 8 resource model = **~12 tables** (down from 15; `BusinessRoles`, `BusinessRoleResources`, `BusinessRoleAssignments` eliminated)

---

## Arguments FOR Merging (Your Colleague's Position)

### 1. A business role IS a resource once deployed
Your colleague's strongest point: *"zodra je de eerste businessrol hebt gevalideerd en in gebruik hebt genomen, maakt deze deel uit van je IST."* Once a business role is in production, it IS part of the actual permission landscape. The IST/SOLL distinction is a **state**, not a **type**. A business role that over-provisions is part of IST whether you like it or not.

### 2. Nesting becomes first-class
Currently `BusinessRoleResources` is a flat bridge table. If a business role contains application roles that contain groups, you can't express that hierarchy. With `ResourceRelationships`, you get true multi-level nesting:
- Permission → Application Role → Business Role → Catalog
- The existing recursive CTE (`vw_ResourceMembersRecursive`) already handles 10 levels deep

### 3. Simpler data model = simpler queries
Instead of joining across two table families (Resources + BusinessRoles + bridge), every query works against one set of tables. The IST/SOLL distinction becomes a `WHERE resourceType = 'BusinessRole'` filter.

### 4. Single assignment table
Currently assignments live in two places:
- `ResourceAssignments` (direct group memberships)
- `BusinessRoleAssignments` (business role holdings)

Merging means one place to look for "who has access to what". The `assignmentType` column already supports multiple types.

### 5. Resource clustering and risk scoring already treat everything uniformly
`Save-FGResourceClusters` and `Invoke-FGRiskScoring` already operate on Resources. BusinessRoles would automatically participate in clustering, risk propagation, and analysis without special handling.

### 6. Cross-system modeling is cleaner
When importing from Omada, SailPoint, etc., their "roles" are just resources with children. The current model forces you to decide: is this a Resource or a BusinessRole? With the unified model, it's always a Resource with a `resourceType` that indicates its nature.

### 7. Fewer tables, less code
Eliminating 3 tables (`BusinessRoles`, `BusinessRoleResources`, `BusinessRoleAssignments`) and their associated sync functions, Initialize functions, and API routes reduces maintenance surface.

---

## Arguments AGAINST Merging (Current Design's Strengths)

### 1. Governance metadata doesn't fit on Resources
BusinessRoles carry governance-specific attributes:
- `catalogId` (organizational container)
- `isHidden` (catalog visibility)

BusinessRoleAssignments carry:
- `policyId`, `complianceState`, `state`, `assignmentStatus`, `expirationDateTime`

BusinessRolePolicies carry:
- `hasAutoAddRule`, `hasAutoRemoveRule`, `hasAccessReview`, `policyConditions`, `reviewSettings`

Merging means either: (a) adding all these columns to Resources/ResourceAssignments (bloating them for non-governance rows), or (b) putting them in `extendedAttributes` JSON (losing SQL indexability).

**Counter-argument:** The `extendedAttributes` JSON column was designed exactly for this. Governance-specific attributes go there. The few frequently-queried ones (`catalogId`) can be real columns. This is the same "core + JSON" pattern already used for Resources.

### 2. Semantic clarity for the UI
The UI has dedicated pages: "Access Packages" page, "Resources" page, "Matrix" page. The matrix specifically needs to distinguish between SOLL columns (business roles) and IST rows (resources/groups). If everything is a Resource, the UI must filter by `resourceType` everywhere.

**Counter-argument:** The UI already filters by `resourceType` for Groups vs DirectoryRoles vs AppRoles. Adding `BusinessRole` as another type is consistent, not harder.

### 3. IST vs SOLL is a fundamental conceptual boundary
The whole point of FortigiGraph is governance analysis: comparing what IS (IST) against what SHOULD BE (SOLL). Having separate tables makes this boundary explicit and hard to accidentally cross.

**Counter-argument:** The boundary can be expressed as a view or a column (`isGovernanceResource BIT`). The IST/SOLL distinction is better expressed as "assignments that come through a business role vs direct assignments" — which is already how `managedByAccessPackage` works in the views.

### 4. Breaking change for existing deployments
This would be the second schema overhaul (v2→v3 was the first). Existing users who just migrated to v3 would need another migration.

**Counter-argument:** The v3 model is brand new and not yet widely deployed. If we're going to break it, now is the time — before there's a large install base.

### 5. Query complexity for governance reporting
Governance-specific queries (request timelines, certification reviews, policy analysis) currently join against dedicated governance tables with clean column names. After merging, these queries would need to filter `WHERE resourceType = 'BusinessRole'` on every join, and governance-specific columns would be in JSON.

**Counter-argument:** The dedicated views already abstract this. `vw_BusinessRoleAssignmentDetails`, `vw_BusinessRoleLastReview`, etc. would simply be rewritten to filter on `resourceType`. End users and the UI never hit raw tables.

### 6. Assignment semantics are different
A `ResourceAssignment` says "this user is a member/owner/eligible of this group." A `BusinessRoleAssignment` says "this user holds this business role, which was requested on date X, approved by person Y, expires on date Z, with compliance state C." These are semantically different things being forced into one table.

**Counter-argument:** `ResourceAssignments` already has `complianceState`. The additional columns (`policyId`, `expirationDateTime`, `state`) could be added as nullable columns — they'd simply be NULL for direct group memberships. Or use `extendedAttributes`.

---

## Impact Analysis

### If We Merge

| Area | Impact | Effort |
|------|--------|--------|
| **SQL Tables** | Drop 3 tables, modify Resources + ResourceAssignments + ResourceRelationships, keep AssignmentPolicies/Requests/CertificationDecisions with renamed FK | Medium |
| **Initialize-FGGovernanceTables.ps1** | Major rewrite — most logic moves into Initialize-FGSystemTables | Medium |
| **Sync functions (7)** | Sync-FGAccessPackage → writes to Resources with `resourceType='BusinessRole'`; Sync-FGAccessPackageResourceRoleScope → writes to ResourceRelationships; Sync-FGAccessPackageAssignment → writes to ResourceAssignments with extra columns | High |
| **CSV import (Sync-FGCSVBusinessRole)** | Rewrite to target Resources + ResourceRelationships | Medium |
| **SQL Views (10+)** | Rewrite all governance views to join Resources instead of BusinessRoles | Medium |
| **Backend API routes (6 files)** | permissions.js, categories.js, details.js, governance.js, riskScores.js, resources.js — update queries | High |
| **Frontend components (8 files)** | AccessPackagesPage, AccessPackageDetailPage, GovernancePage, MatrixCell, MatrixView, RiskScoringPage — update data models | High |
| **Risk scoring** | Simplifies — BusinessRoles automatically participate as Resources | Low (net reduction) |
| **Migration script** | Need Invoke-FGGovernanceMigration to move data from old tables to new structure | Medium |
| **CLAUDE.md + README** | Full documentation rewrite for data model sections | Medium |

**Total estimated effort:** Significant — touches ~30 files across all layers.

### If We Keep Separate

| Area | Impact |
|------|--------|
| No code changes needed | Zero effort |
| Model is already working and deployed to iidemos | Stable |
| Multi-level nesting not supported (flat bridge table only) | Limitation remains |
| Every new IGA connector must decide Resource vs BusinessRole | Ongoing friction |

---

## My Recommendation

**Your colleague is architecturally right.** A business role is a parent resource. The IST/SOLL distinction is a property of the assignment, not of the entity. The current separation creates:
- A bridge table (`BusinessRoleResources`) that is essentially a denormalized `ResourceRelationships`
- Two parallel assignment tables with overlapping semantics
- Double the query surface for "who has access to what"

**However, I'd suggest a pragmatic middle path:**

### Phase 1: Keep the current model, add a compatibility view (Now)
Create a `vw_UnifiedResources` view that UNION ALLs Resources and BusinessRoles. This lets new code start treating everything uniformly without breaking existing queries.

### Phase 2: Merge when building the next IGA connector (Later)
When you actually need to import from Omada/SailPoint — where the "is this a role or a resource?" question becomes painful — that's the natural moment to merge. You'll have real requirements to validate the unified model against.

### Phase 3: If you decide to do it now (Friday discussion)
If you and your colleague decide to merge now (valid — v3 is fresh, install base is tiny), the approach would be:

1. Add `catalogId`, `isHidden` to Resources table
2. Add `policyId`, `state`, `expirationDateTime` to ResourceAssignments table (nullable)
3. Write `BusinessRoleResources` data into `ResourceRelationships` with `relationshipType = 'Contains'`
4. Write `BusinessRoleAssignments` data into `ResourceAssignments` with `assignmentType = 'Governed'`
5. Rename `BusinessRolePolicies` → `AssignmentPolicies` (FK changes from `businessRoleId` to `resourceId`)
6. Rename `BusinessRoleRequests` → `AssignmentRequests` (same FK change)
7. `CertificationDecisions` already has `resourceId` — just make `businessRoleId` also point to Resources
8. Drop `BusinessRoles`, `BusinessRoleResources`, `BusinessRoleAssignments`
9. Rewrite all 10 governance views
10. Update all sync functions and API routes

---

## Summary Table

| Criterion | Keep Separate | Merge |
|-----------|:---:|:---:|
| Architectural purity | - | ++ |
| Multi-level nesting | - | ++ |
| Query simplicity | + | ++ |
| IST/SOLL clarity | ++ | + (via views/filters) |
| Governance metadata fit | ++ | + (via nullable cols + JSON) |
| Cross-system extensibility | - | ++ |
| Risk scoring integration | - | ++ |
| Implementation effort now | ++ | -- |
| Long-term maintenance | - | ++ |
| Breaking change risk | ++ | - |

**Bottom line:** The unified model is the better long-term architecture. The question is timing. If you're going to do it, do it before v3 gets widely adopted. Friday's discussion with your colleague is the right moment to decide.
