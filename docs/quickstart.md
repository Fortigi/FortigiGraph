# Quick Start

This guide takes you from a fresh install to a running sync and deployed UI. Each step builds on the previous one, and every command is designed to be copy-paste friendly.

Estimated time: 30–60 minutes for a first-time setup.

---

## 1. Prerequisites

Before you begin, confirm the following:

- **PowerShell 7 or later** — FortigiGraph enforces this at runtime. Check with `$PSVersionTable.PSVersion`.
- **Azure subscription** — you need Contributor rights on at least one subscription to create resources.
- **Az PowerShell module** — used by the setup wizard for resource provisioning.

```powershell
# Install Az if not already present
Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -Force
```

!!! warning "PowerShell 5 is not supported"
    The module will raise a clear error if you run it under Windows PowerShell 5. Install [PowerShell 7](https://aka.ms/powershell) and run commands from the `pwsh` terminal, not `powershell`.

---

## 2. Install FortigiGraph

### Option A: PowerShell Gallery (recommended)

```powershell
Install-Module -Name FortigiGraph -Scope CurrentUser
```

### Option B: Clone from source

```powershell
git clone https://github.com/Fortigi/FortigiGraph.git
Import-Module .\FortigiGraph\FortigiGraph.psd1
```

Verify the install:

```powershell
Get-Command -Module FortigiGraph | Measure-Object
# Should report 168 commands
```

---

## 3. Run the Setup Wizard

The setup wizard is a guided, interactive session that creates every Azure resource FortigiGraph needs and writes the results to a config file.

```powershell
New-FGConfig -Path .\Config\mycompany.json
```

**What the wizard creates:**

| Resource | Purpose |
|----------|---------|
| Resource Group | Container for all FortigiGraph resources |
| Azure SQL Server | Hosts the authorization data database |
| Azure SQL Database | Temporal tables for all synced data |
| App Registration | Service principal with Graph API permissions |
| Config file | JSON file that drives all subsequent operations |

The wizard lets you select existing resources or create new ones at each step. When it finishes, `mycompany.json` contains everything needed to authenticate and connect — with passwords stored encrypted via Windows DPAPI.

!!! tip "Keep the config file out of source control"
    The file contains encrypted credentials. Add `Config/*.json` to your `.gitignore`. The module's `.gitignore` already excludes this pattern.

---

## 4. Authenticate

Two separate authentications are required: one to Microsoft Graph, and one to Azure SQL.

```powershell
# Authenticate to Microsoft Graph (uses the App Registration from your config)
Get-FGAccessToken -ConfigFile '.\Config\mycompany.json'

# Connect to Azure SQL (also updates the SQL Server firewall with your current IP)
Connect-FGSQLServer -ConfigFile '.\Config\mycompany.json'
```

Both commands store their state in module-level globals (`$Global:AccessToken`, `$Global:FGSQLConnectionString`) so you don't need to pass credentials to subsequent commands.

!!! note "Token lifetime"
    Access tokens expire after approximately one hour. `Start-FGSync` (next step) always acquires a fresh token at the start of each run. For interactive sessions, re-run `Get-FGAccessToken` if you see "No Access Token found" errors.

---

## 5. Run Your First Sync

`Start-FGSync` orchestrates all Entra ID sync operations in a single call. It initializes all required SQL tables on first run.

```powershell
Start-FGSync -ConfigFile '.\Config\mycompany.json'
```

**What gets synced (by default):**

| Data | Target table(s) |
|------|----------------|
| Users | `Principals`, `GraphUsers` (legacy) |
| Groups | `Resources`, `GraphGroups` (legacy) |
| Group memberships (direct, eligible, owner) | `ResourceAssignments`, `GraphGroupMembers` |
| Directory roles and app role assignments | `Resources`, `ResourceAssignments` |
| Catalogs | `GovernanceCatalogs` |
| Access packages (business roles) | `Resources` (`resourceType='BusinessRole'`) |
| Access package assignments | `ResourceAssignments` (`assignmentType='Governed'`) |
| Access package resource scopes | `ResourceRelationships` (`relationshipType='Contains'`) |
| Assignment policies and requests | `AssignmentPolicies`, `AssignmentRequests` |
| Access reviews | `CertificationDecisions` |
| Organizational contexts | `Contexts` |
| SQL views and materialized views | All `vw_*` views |

**Optional sync targets:**

```powershell
# Include service principals, managed identities, and AI agents
Start-FGSync -ConfigFile '.\Config\mycompany.json' -SyncServicePrincipals $true

# Include sign-in activity for stale account detection
Start-FGSync -ConfigFile '.\Config\mycompany.json' -SyncPrincipalActivity $true -SyncAppRoleActivity $true
```

!!! tip "Parallel execution"
    By default, `Start-FGSync` runs up to 6 entity types concurrently via a runspace pool. This significantly reduces total sync time in large tenants. Set `Sync.ParallelExecution = false` in the config to run sequentially if you are troubleshooting.

---

## 6. Deploy the Role Mining UI

The web UI is a React application deployed to Azure App Service. The `New-FGUI` cmdlet handles everything: App Service Plan, Web App, authentication app registration, and initial code deployment.

```powershell
New-FGUI -ConfigFile '.\Config\mycompany.json'
```

The cmdlet presents an interactive scaling menu with cost estimates. For most environments, **Basic** is a good starting point. You can rescale later with `Set-FGUI`.

After deployment, the URL is printed and saved to the config file. Open it in a browser — you will be prompted to sign in with your Entra ID account.

!!! note "Scaling options"
    `Set-FGUI -Scaling Tiny|Basic|Optimum|Fast` queries your database row counts to recommend the right App Service and SQL tier. Run it as your data grows.

---

## 7. Risk Scoring (Optional)

Identity risk scoring runs in three phases. Only the first phase contacts an LLM, and it sends only public organizational context — no identity data.

```powershell
$apiKey = Read-Host -AsSecureString "LLM API Key"

# Phase 1: discover organizational context (contacts LLM)
New-FGRiskProfile -Domain "yourcompany.com" `
    -LLMProvider Anthropic `
    -LLMApiKey $apiKey `
    -ConfigFile '.\Config\mycompany.json'

# Phase 2: generate industry-specific classifiers (contacts LLM)
New-FGRiskClassifiers -ConfigFile '.\Config\mycompany.json'

# Phase 3: score all principals locally (no LLM, runs on your data)
Invoke-FGRiskScoring -ConfigFile '.\Config\mycompany.json'
```

Results are written to the `RiskScores` temporal table and immediately available in the UI's **Risk Scoring** tab.

!!! tip "Supported LLM providers"
    `LLMProvider` accepts `Anthropic` (default model: `claude-sonnet-4-20250514`) or `OpenAI` (default model: `gpt-4o`). Bring your own API key.

---

## 8. Schedule Automated Syncs

`New-FGAzureAutomationAccount` creates an Azure Automation Account with a daily runbook that runs `Start-FGSync` on a schedule.

```powershell
New-FGAzureAutomationAccount -ConfigFile '.\Config\mycompany.json'
```

**What it provisions:**

- Automation Account with the FortigiGraph module uploaded
- Encrypted Automation Variables for all credentials (no plaintext secrets)
- A PowerShell runbook that calls `Start-FGSync`
- A daily schedule (configurable time)
- SQL Server firewall rule for the Automation Account's outbound IPs

!!! warning "Azure Automation memory limit"
    Azure Automation sandboxes have a 400 MB memory limit. For tenants with very large datasets, enable batching mode in the runbook to process data in chunks. See [Troubleshooting](reference/troubleshooting.md#azure-automation-memory-limits) for details.

---

## Verify Your Data

After the first sync completes, you can query the SQL database directly to confirm data arrived:

```powershell
# Quick counts across the main tables
Invoke-FGSQLCommand -ScriptBlock {
    param($connection)
    $cmd = $connection.CreateCommand()
    $cmd.CommandText = @"
        SELECT 'Principals'         AS TableName, COUNT(*) AS RowCount FROM dbo.Principals
        UNION ALL
        SELECT 'Resources',                        COUNT(*) FROM dbo.Resources
        UNION ALL
        SELECT 'ResourceAssignments',              COUNT(*) FROM dbo.ResourceAssignments
        UNION ALL
        SELECT 'GovernanceCatalogs',               COUNT(*) FROM dbo.GovernanceCatalogs
        UNION ALL
        SELECT 'AssignmentPolicies',               COUNT(*) FROM dbo.AssignmentPolicies
        UNION ALL
        SELECT 'CertificationDecisions',           COUNT(*) FROM dbo.CertificationDecisions
"@
    $reader = $cmd.ExecuteReader()
    $results = @()
    while ($reader.Read()) {
        $results += [PSCustomObject]@{ Table = $reader["TableName"]; Rows = $reader["RowCount"] }
    }
    $reader.Close()
    return $results
}
```

---

## What's Next

| Topic | Where to go |
|-------|------------|
| Understanding the data model | [Data Model](concepts/data-model.md) |
| UI features and navigation | [UI Overview](ui/overview.md) |
| Risk scoring deep dive | [Risk Scoring Overview](risk-scoring/overview.md) |
| Config file reference | [Config Reference](reference/config.md) |
| Troubleshooting | [Troubleshooting](reference/troubleshooting.md) |
| Importing from non-Entra systems | [CSV Sync](sync/csv-sync.md) |
