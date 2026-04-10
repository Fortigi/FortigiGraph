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
| **Database connection fails** | Check that the `postgres` container is healthy (`docker compose ps`). Verify `DATABASE_URL` in the web container's environment. For direct access, connect to `localhost:5432` with the credentials from your `.env` file or `docker-compose.yml`. |
| **"No Access Token found"** | Run `Get-FGAccessToken -ConfigFile config.json`. Tokens expire after approximately one hour in interactive sessions. |
| **Permission errors after changing the App Registration** | `Start-FGSync` always acquires a fresh token at the start of each run. For manual commands, run `Get-FGAccessToken -ConfigFile config.json` again to pick up new permissions. Allow up to 15 minutes for Graph API permission grants to propagate. |
| **Migration errors on startup** | Check the web container logs (`docker compose logs web`). Migrations run automatically and are idempotent. If a migration fails, fix the underlying issue and restart the web container. |
| **Sync skips expected data** | Check two things: (1) confirm the entity type is enabled in the config (`Sync.EntityType.Enabled = true`), and (2) verify the App Registration has the required Graph API permission (see [Required Permissions](#required-permissions) below). |
| **UI shows a blank or empty matrix** | Run `Sync-FGMaterializedViews -ConfigFile config.json` to refresh the materialized view tables that the matrix reads from. This is normally run automatically at the end of `Start-FGSync`. |
| **Risk scores not visible in the UI** | Run `Invoke-FGRiskScoring -ConfigFile config.json` to populate the `RiskScores` table. Risk scoring does not run as part of `Start-FGSync` — it is a separate step. |
| **"More than one object found"** in Confirm-FG* functions | A `Confirm-FG*` function found multiple objects matching the supplied name. Use a more specific identifier (object ID instead of display name). |
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

### Config file not found

All FortigiGraph cmdlets accept a `-ConfigFile` parameter. If you omit it, the module looks for a config file in the current working directory. Always supply the full path to avoid ambiguity:

```powershell
Start-FGSync -ConfigFile 'C:\Config\mycompany.json'
```
