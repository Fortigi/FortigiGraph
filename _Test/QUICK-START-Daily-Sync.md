# Daily Sync - Quick Start Guide

**Get started with daily Graph data sync in 5 minutes!**

## Prerequisites

- Az PowerShell module installed: `Install-Module Az -Scope CurrentUser`
- FortigiGraph module installed/cloned
- Azure subscription
- Microsoft Graph app registration

## Step 1: Create Config File

```bash
cd FortigiGraph\_Test
cp config.test.json.template config.production.json
```

Edit `config.production.json`:

```json
{
  "Azure": {
    "SubscriptionId": "YOUR-SUBSCRIPTION-ID",
    "ResourceGroupName": "rg-graph-sync",
    "Location": "northeurope",
    "SQLServerName": "mygraphsql",
    "DatabaseName": "GraphData",
    "AdminUsername": "sqladmin",
    "AdminUserPassword": ""
  },
  "Graph": {
    "TenantId": "YOUR-TENANT-ID",
    "ClientId": "YOUR-APP-CLIENT-ID",
    "ClientSecret": ""
  }
}
```

**Note:** Leave passwords empty - you'll be prompted on first run.

## Step 2: First Run

```powershell
.\Daily-Sync.ps1 -ConfigFile .\config.production.json
```

This will:
1. Prompt for SQL admin password (stored encrypted)
2. Prompt for Graph client secret (or Enter for interactive)
3. Create SQL Server (if needed)
4. Sync all data
5. Create analysis views

## Step 3: Verify

Check the output:
```
=== Sync Summary ===
  Users:                   1,245
  Groups:                  387
  Direct Memberships:      4,521
  Transitive Memberships:  8,932
```

## Step 4: Query Your Data

```sql
-- See all users
SELECT * FROM GraphUsers

-- See group memberships
SELECT * FROM vw_GraphGroupMembershipType

-- See nested/indirect access
SELECT * FROM vw_GraphGroupNestedMembers
```

## Daily Runs

Just run the same command:

```powershell
.\Daily-Sync.ps1 -ConfigFile .\config.production.json
```

No prompts needed after first run!

## Common Customizations

**Sync only enabled users:**
```powershell
.\Daily-Sync.ps1 -ConfigFile .\config.production.json `
    -UserFilter "accountEnabled eq true"
```

**Skip PIM (if not configured):**
```powershell
.\Daily-Sync.ps1 -ConfigFile .\config.production.json `
    -SyncGroupEligibleMembers $false
```

**Add custom user attributes:**
```powershell
.\Daily-Sync.ps1 -ConfigFile .\config.production.json `
    -UserAdditionalAttributes @('city', 'country', 'officeLocation')
```

## Schedule It

**Windows Task Scheduler:**
```powershell
$action = New-ScheduledTaskAction -Execute "pwsh.exe" `
    -Argument "-File C:\Scripts\FortigiGraph\_Test\Daily-Sync.ps1 -ConfigFile C:\Scripts\FortigiGraph\_Test\config.production.json"

$trigger = New-ScheduledTaskTrigger -Daily -At "02:00AM"

Register-ScheduledTask -TaskName "Graph Daily Sync" `
    -Action $action -Trigger $trigger
```

## Troubleshooting

**Can't connect to SQL Server?**
- Check firewall rules
- The script auto-updates firewall, but verify your IP

**Permission errors?**
- Ensure Graph app has: `User.Read.All`, `Group.Read.All`, `GroupMember.Read.All`
- Grant admin consent in Azure portal

**Token expired?**
- Script auto-refreshes tokens
- If it fails, delete the config and re-enter credentials

## Next Steps

- Read full docs: `README-Daily-Sync.md`
- Explore views: `vw_GraphGroupMembershipType`, `vw_GraphGroupNestedMembers`
- Connect Power BI to your SQL database
- Set up alerts for sync failures

## Help

```powershell
# Get help on specific functions
Get-Help Sync-FGUser -Full
Get-Help Connect-FGSQLServer -Full

# Enable debug mode
$Global:DebugMode = 'G'
```

That's it! You're syncing Graph data to SQL. 🎉
