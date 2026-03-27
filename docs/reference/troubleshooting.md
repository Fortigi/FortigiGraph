# Troubleshooting

This page covers debug mode, common error conditions, required permissions, and known operational constraints.

---

## Debug Mode

FortigiGraph's HTTP functions emit detailed request/response output when `$Global:DebugMode` is set. Set it to any combination of the letters below before running any command.

```powershell
$Global:DebugMode = 'G'   # GET requests — show URIs, page counts, item counts
$Global:DebugMode = 'P'   # POST and PATCH requests — show URIs and request bodies
$Global:DebugMode = 'D'   # DELETE requests
$Global:DebugMode = 'T'   # Token operations — show token acquisition and refresh events
$Global:DebugMode = 'GP'  # Multiple categories — combine any letters
$Global:DebugMode = 'GPT' # All HTTP + token operations

# Clear debug mode
$Global:DebugMode = $null
```

Debug output writes to the host (not the pipeline), so it does not interfere with function return values.

!!! tip "Troubleshooting a specific sync function"
    Set `$Global:DebugMode = 'G'` before calling a `Sync-FG*` function to see every Graph API URI being called, including paginated continuation URLs.

---

## Common Issues

| Issue | Solution |
|-------|---------|
| **SQL connection fails** | Run `Connect-FGSQLServer -ConfigFile config.json`. This re-establishes the connection and automatically updates the SQL Server firewall rule with your current public IP. |
| **"No Access Token found"** | Run `Get-FGAccessToken -ConfigFile config.json`. Tokens expire after approximately one hour in interactive sessions. |
| **Permission errors after changing the App Registration** | `Start-FGSync` always acquires a fresh token at the start of each run. For manual commands, run `Get-FGAccessToken -ConfigFile config.json` again to pick up new permissions. Allow up to 15 minutes for Graph API permission grants to propagate. |
| **"Temporal table schema error" / cannot ALTER table** | Do not modify temporal tables directly in SQL. Use the `Sync-FG*` functions, which detect schema changes and handle versioning safely. If a column must be added, use `Add-FGSQLTableColumn`. |
| **Cannot TRUNCATE a temporal table** | SQL Server forbids `TRUNCATE` on system-versioned tables. Use `DELETE FROM dbo.TableName` or `Clear-FGSQLTable -TableName dbo.TableName` instead. |
| **Sync skips expected data** | Check two things: (1) confirm the entity type is enabled in the config (`Sync.EntityType.Enabled = true`), and (2) verify the App Registration has the required Graph API permission (see [Required Permissions](#required-permissions) below). |
| **UI shows a blank or empty matrix** | Run `Sync-FGMaterializedViews -ConfigFile config.json` to refresh the materialized view tables that the matrix reads from. This is normally run automatically at the end of `Start-FGSync`. |
| **Risk scores not visible in the UI** | Run `Invoke-FGRiskScoring -ConfigFile config.json` to populate the `RiskScores` table. Risk scoring does not run as part of `Start-FGSync` — it is a separate step. |
| **"More than one object found"** in Confirm-FG* functions | A `Confirm-FG*` function found multiple objects matching the supplied name. Use a more specific identifier (object ID instead of display name). |
| **Azure Automation runbook fails immediately** | Check that the module version in the Automation Account matches or is older than the locally installed version. `New-FGAzureAutomationAccount` uploads the module only when the local version is newer. |
| **Parallel sync causes runspace errors** | Set `Sync.ParallelExecution = false` in the config and re-run. Runspace pool issues can occur when global state is not available inside the runspace. Report the error message for investigation. |

---

## Required Permissions

All permissions below are **Application** permissions (not Delegated). They are granted to the App Registration created by `New-FGConfig`.

| Permission | Purpose |
|-----------|---------|
| `User.Read.All` | Read all users and their profile attributes |
| `Group.Read.All` | Read all groups and group properties |
| `GroupMember.Read.All` | Read direct group memberships |
| `Directory.Read.All` | Read directory objects, directory roles, and role assignments |
| `EntitlementManagement.Read.All` | Read Entitlement Management catalogs, access packages, assignments, policies, and requests |
| `AccessReview.Read.All` | Read access review instances and decisions |
| `Application.Read.All` | Read service principals and application role assignments |
| `PrivilegedEligibilitySchedule.Read.AzureADGroup` | Read PIM-eligible group memberships |
| `AuditLog.Read.All` | Read sign-in logs and audit events (required for `PrincipalActivity` and `AppRoleActivity` sync) |

!!! warning "Admin consent required"
    All of these are Application permissions that require tenant-wide admin consent. `New-FGConfig` initiates the admin consent flow during setup. If permissions are added later, re-run the consent flow or grant consent manually in the Azure Portal under App Registrations → API Permissions.

---

## Azure Automation Memory Limits

Azure Automation sandboxes enforce a **400 MB memory limit**. Syncing very large tenants (100,000+ users or groups) in a single batch can exceed this limit and cause the runbook job to fail with an out-of-memory error.

**Diagnosis:** The Automation job log will show the process was terminated, often without a PowerShell exception.

**Solution:** Enable batching mode for the affected sync functions. Batching processes records in smaller chunks and calls `[System.GC]::Collect()` between iterations to release memory.

```powershell
# Example: sync users in batches of 5000
Sync-FGPrincipal -ConfigFile '.\Config\mycompany.json' -BatchSize 5000

# Check job memory usage in the Automation Account
Get-FGAutomationJob -ConfigFile '.\Config\mycompany.json' | Select-Object -Last 10
```

If batching is not available for a particular sync function, split the sync into multiple runbooks that each handle a subset of entity types, rather than calling `Start-FGSync` (which runs all types in one job).

---

## Config File Issues

### Missing keys after a module upgrade

New versions of FortigiGraph sometimes add new config sections or keys. If you see errors like `Cannot index into a null array` or `Property 'X' not found`, the config file is missing a key that the module now expects.

```powershell
# Add any missing keys from the current template without overwriting existing values
Update-FGConfig -Path .\Config\mycompany.json
```

### Decryption errors on a different machine

Config values ending in `_Encrypted` are encrypted with Windows DPAPI scoped to the user account that created them. They **cannot be decrypted on a different machine or user account**.

If you need to move a config file to another machine:

1. Copy the config file to the new machine.
2. Remove all `_Encrypted` keys from the JSON.
3. Run `Update-FGConfig` or `New-FGConfig` and re-enter credentials — they will be encrypted for the new machine.

For Azure Automation, credentials are stored as encrypted Automation Variables, not read from the `_Encrypted` fields. Re-running `New-FGAzureAutomationAccount` re-uploads all variables.

### Config file not found

All FortigiGraph cmdlets accept a `-ConfigFile` parameter. If you omit it, the module looks for a config file in the current working directory. Always supply the full path to avoid ambiguity:

```powershell
Start-FGSync -ConfigFile 'C:\Config\mycompany.json'
```
