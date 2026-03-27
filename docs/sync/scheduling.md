# Automated Scheduling

FortigiGraph can run syncs on a daily schedule using Azure Automation. The setup wizard creates the full Automation Account infrastructure in a single command.

---

## Azure Automation Setup

```powershell
New-FGAzureAutomationAccount -ConfigFile '.\Config\mycompany.json'
```

This creates everything needed for scheduled syncs:

- **Azure Automation Account** in your configured resource group
- **Encrypted variables** for Graph API credentials (client ID, client secret, tenant ID) and SQL connection details
- **Runbooks** for each enabled sync type, generated from the config file
- **Daily schedules** with configurable start times and time zone
- **SQL firewall rule** to allow connections from Azure services

### Post-setup steps

After `New-FGAzureAutomationAccount` completes:

1. Open the Automation Account in the Azure portal
2. Go to **Modules** → **Browse Gallery** and import the `FortigiGraph` module
3. Wait for the import status to show **Available** (this can take several minutes)
4. Go to **Runbooks** and start a runbook manually to verify connectivity
5. Enable schedules once manual tests pass

!!! warning
    Do not enable schedules until you have verified at least one runbook run succeeds manually. A failed first run can mask config issues that are much easier to debug interactively.

---

## Memory Considerations

!!! warning
    Azure Automation sandboxes have a **400 MB memory limit**. Group member sync loads all membership data before writing to SQL, which can exceed this limit in large tenants. The `Sync-FGGroupMember` function uses `-UseBatching` automatically when called from a runbook, processing groups in chunks to keep memory usage constant.

    If you see `OutOfMemoryException` errors in runbook logs, check whether batching is enabled in the config and reduce the batch size if needed.

---

## Sync Schedule Reference

Sync times are configured in the `Sync` section of the config file. Each entity type can have its own schedule, allowing you to stagger heavy operations.

```json
{
  "Sync": {
    "Users": {
      "Enabled": true,
      "Schedule": { "Enabled": true, "Time": "05:00", "Frequency": "Daily" }
    },
    "Groups": {
      "Enabled": true,
      "Schedule": { "Enabled": true, "Time": "05:00", "Frequency": "Daily" }
    },
    "GroupMembers": {
      "Enabled": true,
      "Schedule": { "Enabled": true, "Time": "06:00", "Frequency": "Daily" }
    },
    "GroupEligibleMembers": {
      "Enabled": true,
      "Schedule": { "Enabled": true, "Time": "06:00", "Frequency": "Daily" }
    },
    "GroupOwners": {
      "Enabled": true,
      "Schedule": { "Enabled": true, "Time": "06:00", "Frequency": "Daily" }
    },
    "AccessPackages": {
      "Enabled": true,
      "Schedule": { "Enabled": true, "Time": "07:00", "Frequency": "Daily" }
    },
    "Views": {
      "Enabled": true
    },
    "ParallelExecution": true
  }
}
```

**Recommended staggering:**

| Time | Entities |
|------|----------|
| 05:00 | Users, Groups — fast reads, no dependencies |
| 06:00 | Group memberships and owners — depend on Groups being current |
| 07:00 | Access packages and governance — depend on Users and Groups |
| 08:00 | Activity data, risk scoring — depend on all other data |

---

## Updating Config After Module Upgrade

When you upgrade the FortigiGraph module, new config keys may be added. Use `Update-FGConfig` to merge in any missing keys without overwriting your existing settings:

```powershell
Update-FGConfig -Path '.\Config\mycompany.json'
```

After updating the config, re-run `New-FGAzureAutomationAccount` to push the updated runbooks and variables to Azure:

```powershell
New-FGAzureAutomationAccount -ConfigFile '.\Config\mycompany.json'
```

!!! note
    `New-FGAzureAutomationAccount` compares local and deployed module version numbers before uploading. It only uploads the module if the local version is newer, so re-running it is safe and fast on repeat invocations.
