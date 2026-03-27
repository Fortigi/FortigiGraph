# FortigiGraph

> Universal authorization intelligence — sync, analyze, and govern permissions from any identity system.

Permissions are scattered across identity systems, directories, and SaaS platforms. FortigiGraph syncs them all into a unified Azure SQL model with full temporal history, surfaces access gaps and risks through a visual role mining UI, and adds LLM-assisted identity risk scoring — without sending sensitive identity data to any external service. Source systems include Entra ID, Omada, SailPoint, SAP/Pathlock, SharePoint, Azure RBAC, Azure DevOps, or any system that can produce a CSV export.

📚 **[Full documentation →](https://fortigi.github.io/FortigiGraph)**

> **Note:** The documentation site will be available at the link above once GitHub Pages is enabled. Until then, see the [`docs/`](docs/) folder in this repository.

---

## Quick Start

**Prerequisites:** PowerShell 7+, an Azure subscription with Contributor access, and the Az module.

```powershell
# Install the Az PowerShell module (if not already installed)
Install-Module Az -Scope CurrentUser
```

**Install FortigiGraph from the PowerShell Gallery:**

```powershell
Install-Module -Name FortigiGraph -Scope CurrentUser
```

**Run the guided setup wizard** — it creates the App Registration, SQL Server, database, and config file interactively:

```powershell
New-FGConfig -Path .\Config\myorg.json
```

**Authenticate and run your first sync:**

```powershell
Get-FGAccessToken -ConfigFile .\Config\myorg.json
Connect-FGSQLServer -ConfigFile .\Config\myorg.json
Start-FGSync -ConfigFile .\Config\myorg.json
```

---

## What FortigiGraph Does

### Unified Permission Model
- Stores permissions from any system in a single SQL schema: Systems, Resources, Principals, ResourceAssignments, ResourceRelationships
- Temporal tables track every change — query permissions as they existed at any point in time
- Business roles, governed assignments, and resource grants share the same tables as direct permissions

### Role Mining UI
- Visual permission matrix with IST/SOLL comparison (actual vs governed access)
- Access package management with category-based column grouping and multi-type membership badges
- Entity detail pages for users, groups, and access packages with full version history
- Excel export, drag-and-drop row reordering, and server-side scaling for large environments

### Identity Risk Scoring
- LLM-assisted organizational profiling and classifier generation (public context only — no identity data sent externally)
- Four-layer scoring: direct classifier match → membership analysis → structural hygiene → cross-entity propagation
- Risk tiers from Critical (80–100) to None (0), with analyst override controls and full audit trail
- Resource clustering groups related permissions for easier analysis

### Multi-System Governance
- Native sync for Entra ID (users, groups, PIM, access packages, app roles, directory roles)
- CSV-based import for any other system (Omada, SailPoint, SAP/Pathlock, SharePoint, Azure RBAC, DevOps)
- Orchestrated sync via `Start-FGSync` (Entra ID) or `Start-FGCSVSync` (CSV-based sources)

---

## Supported Source Systems

| System | Sync Method | What Gets Synced |
|--------|-------------|------------------|
| Entra ID / Azure AD | Built-in Graph API sync | Users, groups, PIM eligibility, app roles, directory roles, access packages, access reviews |
| Omada, SailPoint, SAP/Pathlock | CSV import | Business roles, role assignments, certifications, policies |
| SharePoint, Azure RBAC, DevOps | CSV import | Resources, resource assignments, resource relationships |
| Any system | CSV import | Principals, resources, assignments — any authorization data that can be exported |

---

## Documentation

> Full docs at **[https://fortigi.github.io/FortigiGraph](https://fortigi.github.io/FortigiGraph)** (available once GitHub Pages is enabled).
> Browse locally in the [`docs/`](docs/) folder.

| Section | Link |
|---------|------|
| Quick Start | [docs/quickstart.md](docs/quickstart.md) |
| Data Model | [docs/data-model.md](docs/data-model.md) |
| Sync Guide | [docs/sync-guide.md](docs/sync-guide.md) |
| Risk Scoring | [docs/risk-scoring.md](docs/risk-scoring.md) |
| Role Mining UI | [docs/ui.md](docs/ui.md) |
| API Reference | [docs/api-reference.md](docs/api-reference.md) |

---

## Contributing / License

FortigiGraph is open source under the [MIT License](LICENSE).
Contributions are welcome — see the [GitHub repository](https://github.com/Fortigi/FortigiGraph) to open issues or pull requests.
