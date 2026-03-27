# FortigiGraph

**Permissions are scattered across dozens of systems. You can't see who really has access to what, who used it last, or which identities were never reviewed.**

Most organizations operate with authorization data siloed in Active Directory, Entra ID, SAP, SharePoint, DevOps, and a dozen more systems — each with its own data model, no shared history, and no way to answer the question _"what can this person actually do?"_

FortigiGraph solves this by pulling authorization data from every connected system into a unified, temporal SQL model. It then provides a role mining web UI for analysts, LLM-assisted risk scoring for security teams, and a PowerShell cmdlet surface for automation.

---

## Three Core Capabilities

### Unified Data Model

Every system's permissions land in the same schema: **Systems → Resources → ResourceAssignments → Principals**. Business roles, directory roles, app roles, SharePoint site permissions, and SAP authorizations all map to the same tables.

- Temporal tables capture the full change history — query any table as it existed at any point in time
- Data from Entra ID syncs via the Microsoft Graph API; any other system imports via CSV or direct connector
- Schema evolves automatically as new attributes appear; no manual migrations needed

### Role Mining UI

A React web application deployed to Azure App Service gives analysts an interactive permission matrix, entity detail pages, and governance dashboards.

- **Permission Matrix**: rows are users/principals, columns are business roles — colored by access package or governed assignment, with direct/indirect/eligible membership badges
- **Entity Detail Pages**: click any user, group, resource, or business role to see all attributes, current memberships, and a version history diff
- **Certifications and Reviews**: track access review decisions, approval timelines, and pending requests
- **IST vs SOLL**: filter the matrix to show unmanaged (IST) or governed (SOLL) assignments

### Identity Risk Scoring

A 4-layer scoring engine that classifies principals by risk without sending sensitive identity data to any external service.

- **Phase 1 (LLM-assisted)**: discovers organizational context from public domain information only — no identity data leaves your environment
- **Phase 2 (local)**: generates industry-specific regex classifiers tuned to your organization
- **Phase 3 (local)**: scores every principal via direct match → membership analysis → structural hygiene → cross-entity propagation
- **AI agent detection**: automatically identifies Copilot Studio agents, managed identities, workload identities, and other non-human principals
- **Analyst overrides**: humans-in-the-loop score adjustments (−50 to +50) with mandatory reasoning, stored in temporal tables for audit

---

## Supported Source Systems

| System | How it connects | What it syncs |
|--------|----------------|---------------|
| **Entra ID / Azure AD** | Microsoft Graph API (service principal) | Users, groups, directory roles, app roles, business roles (access packages), PIM eligibility, access reviews |
| **Omada Identity** | CSV export | Business roles, governed assignments, certifications |
| **SailPoint** | CSV export | Access profiles, entitlements, access requests, certifications |
| **SAP / Pathlock** | CSV export | Roles, authorizations, principals |
| **SharePoint** | CSV export | Site permissions, resource assignments |
| **Azure RBAC** | CSV export or Graph | Role assignments on subscriptions and resource groups |
| **Azure DevOps** | CSV export | Project groups, repository permissions |
| **Any system** | CSV import (`Start-FGCSVSync`) | Systems, principals, resources, assignments, identities, certifications |

!!! note "Entra ID is the reference implementation"
    The Graph API connector is the most feature-complete integration and is the primary path for Microsoft 365 environments. All other systems use the CSV import path, which supports the same unified data model.

---

## Quick Install

**Prerequisites:** PowerShell 7+, an Azure subscription, and the `Az` PowerShell module.

```powershell
# Install from the PowerShell Gallery
Install-Module -Name FortigiGraph -Scope CurrentUser

# Run the interactive setup wizard
# Creates: Resource Group, SQL Server, Database, App Registration, config file
New-FGConfig -Path .\Config\mycompany.json
```

The setup wizard walks you through selecting or creating every required Azure resource and saves everything to a JSON config file. All subsequent commands read from that file — no environment variables or hardcoded credentials.

---

## Next Steps

- [Quick Start Guide](quickstart.md) — authenticate, sync, and deploy the UI in under an hour
- [Data Model](concepts/data-model.md) — understand the unified schema and how systems map to it
- [GitHub Repository](https://github.com/Fortigi/FortigiGraph) — source code, issue tracker, and releases
