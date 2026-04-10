# CSV Import

FortigiGraph can ingest authorization data from any system that can produce a CSV export — HR platforms, PAM tools, SIEMs, IGA platforms such as Omada or SailPoint, ticketing systems, or custom applications. CSV sync uses the same ingestion pipeline as the Entra ID sync, giving you consistent change tracking, audit history, and IST/SOLL analysis across all your identity sources.

---

## Overview

The CSV orchestrator dispatches a folder of CSV files to the correct sync function for each entity type:

```powershell
Start-FGCSVSync -ConfigFile '.\Config\mycompany.json' -CSVFolder '.\exports\acme-hr'
```

You can also run individual CSV sync functions directly for targeted imports or custom pipelines.

!!! tip
    Columns not explicitly mapped by the sync function are automatically collected into the `extendedAttributes` JSON column. You do not need to pre-process or strip your exports — just pass the file as-is.

---

## CSV Functions

### Sync-FGCSVSystem

Create or update system records that identify the source of the data.

```powershell
Sync-FGCSVSystem -FilePath ".\exports\systems.csv"
```

| Column | Required | Description |
|--------|----------|-------------|
| `id` | No | Stable system GUID; auto-generated if omitted |
| `displayName` | Yes | Human-readable system name |
| `systemType` | Yes | Type identifier (e.g. `HR`, `PAM`, `IGA`, `SIEM`) |
| `enabled` | No | `true` / `false`; defaults to `true` |

---

### Sync-FGCSVPrincipal

Import user and identity accounts from any system.

```powershell
Sync-FGCSVPrincipal -FilePath ".\exports\users.csv" -SystemId 2
```

| Column | Required | Description |
|--------|----------|-------------|
| `id` | Yes | Stable principal GUID in the source system |
| `displayName` | Yes | Full name |
| `email` | No | Primary email address |
| `principalType` | No | `User`, `ExternalUser`, `SharedMailbox`, etc. Defaults to `User` |
| `department` | No | Department name |
| `jobTitle` | No | Job title |
| *extra columns* | No | Stored in `extendedAttributes` JSON |

---

### Sync-FGCSVResource

Import permission-granting resources (roles, groups, application permissions, SharePoint sites, etc.).

```powershell
Sync-FGCSVResource -FilePath ".\exports\resources.csv" -SystemId 2
```

| Column | Required | Description |
|--------|----------|-------------|
| `id` | Yes | Stable resource GUID in the source system |
| `displayName` | Yes | Resource name |
| `resourceType` | No | Type label (e.g. `SharePointSite`, `AppRole`, `DevOpsGroup`) |
| `description` | No | Free-text description |
| *extra columns* | No | Stored in `extendedAttributes` JSON |

---

### Sync-FGCSVResourceAssignment

Import who has access to what.

```powershell
Sync-FGCSVResourceAssignment -FilePath ".\exports\assignments.csv"
```

| Column | Required | Description |
|--------|----------|-------------|
| `resourceId` | Yes | Matches `Resources.id` |
| `principalId` | Yes | Matches `Principals.id` |
| `assignmentType` | No | `Direct`, `Governed`, `Eligible`, etc. Defaults to `Direct` |

---

### Sync-FGCSVBusinessRole

Import business roles from IGA platforms such as Omada or SailPoint. Business roles are stored in the `Resources` table with `resourceType = 'BusinessRole'`, making them first-class participants in views, risk scoring, and clustering alongside Entra ID access packages.

```powershell
Sync-FGCSVBusinessRole -FilePath ".\exports\business-roles.csv"
```

| Column | Required | Description |
|--------|----------|-------------|
| `id` | Yes | Stable role GUID |
| `displayName` | Yes | Role name |
| `catalogId` | No | Links the role to a `GovernanceCatalogs` entry |
| `isHidden` | No | Exclude from UI listings |
| *extra columns* | No | Stored in `extendedAttributes` JSON |

---

### Sync-FGCSVIdentity

Import real-person identities that aggregate accounts from multiple systems (the result of account correlation).

```powershell
Sync-FGCSVIdentity -FilePath ".\exports\identities.csv"
```

| Column | Required | Description |
|--------|----------|-------------|
| `id` | Yes | Stable identity GUID |
| `displayName` | Yes | Person's name |
| `email` | No | Canonical email address |
| `principalIds` | No | Semicolon-separated list of `Principals.id` values to link |

---

### Sync-FGCSVCertification

Import certification or review decisions from external IGA platforms.

```powershell
Sync-FGCSVCertification -FilePath ".\exports\certifications.csv"
```

| Column | Required | Description |
|--------|----------|-------------|
| `id` | Yes | Decision GUID |
| `resourceId` | Yes | Business role or resource being reviewed |
| `principalId` | Yes | Subject of the review |
| `decision` | Yes | `Approved`, `Denied`, `NotReviewed` |
| `reviewedDateTime` | No | ISO 8601 timestamp |
| `reviewedBy` | No | Reviewer identity |

---

### Sync-FGCSVPrincipalActivity

Import sign-in or activity data from a SIEM, PAM tool, or any custom source.

```powershell
Sync-FGCSVPrincipalActivity -FilePath ".\exports\siem-logins.csv" -DefaultActivityType "SIEMSignIn"
```

| Column | Required | Description |
|--------|----------|-------------|
| `principalId` | Yes | Matches `Principals.id` |
| `lastActivityDateTime` | Yes | ISO 8601 last observed activity |
| `activityType` | No | Activity label; falls back to `-DefaultActivityType` |
| `activityCount` | No | Number of events in the period |
| `periodStart` | No | ISO 8601 start of aggregation window |
| `periodEnd` | No | ISO 8601 end of aggregation window |

---

### Sync-FGCSVAgentActivity

Import AI agent invocation data from Azure Monitor, APIM, Copilot Studio Analytics, or any custom telemetry pipeline.

```powershell
Sync-FGCSVAgentActivity -FilePath ".\exports\copilot-invocations.csv"
Sync-FGCSVAgentActivity -FilePath ".\exports\apim-calls.csv" -DefaultActivityType "ToolCall"
```

| Column | Required | Description |
|--------|----------|-------------|
| `principalId` | Yes | Agent GUID matching a `Principals.id` (`AIAgent` or `ManagedIdentity`) |
| `resourceId` | No | Resource the agent accessed; nil GUID for general invocation |
| `lastActivityDateTime` | Yes | ISO 8601 last invocation timestamp |
| `activityCount` | No | Total invocations in the period |
| `activityType` | No | See activity types below; falls back to `-DefaultActivityType` |
| `periodStart` | No | ISO 8601 start of aggregation window |
| `periodEnd` | No | ISO 8601 end of aggregation window |
| `extendedAttributes` | No | JSON string for agent context |

**Activity types for agents:**

| Type | Meaning |
|------|---------|
| `Invocation` | Agent was called (default) |
| `ToolCall` | Agent invoked a tool or plugin |
| `DataAccess` | Agent read from a data source |
| `ExternalCall` | Agent made an outbound API call |

---

## CSV Format

All CSV files use **semicolon delimiters** and expect an ISO 8601 format for all date/time values.

Example agent activity CSV:

```csv
principalId;resourceId;lastActivityDateTime;activityCount;activityType;extendedAttributes
3f2504e0-4f89-11d3-9a0c-0305e82c3301;00000000-0000-0000-0000-000000000000;2026-03-15T14:00:00Z;142;Invocation;{"modelVersion":"gpt-4o","orchestratorType":"Copilot Studio"}
6ba7b810-9dad-11d1-80b4-00c04fd430c8;8a1bd9e2-4712-4c9e-a0d1-c9e7f67f8b3a;2026-03-14T09:30:00Z;37;ToolCall;{"callerSystem":"APIM","gatewayRegion":"westeurope"}
```

!!! tip
    Include any additional columns your source system provides. They will be collected into the `extendedAttributes` JSON column automatically, preserving all context without requiring schema changes.
