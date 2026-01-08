# Daily Sync Runbook

## Overview

The `Daily-Sync.ps1` runbook provides an easy-to-use, production-ready script for synchronizing Microsoft Graph data to Azure SQL on a regular basis. It's designed to be simple yet flexible, with sensible defaults and comprehensive error handling.

## Features

✅ **Automatic Setup**: Creates SQL Server if it doesn't exist (perfect for first run)
✅ **Secure Credentials**: Uses the same encrypted credential system as integration tests
✅ **Flexible Sync**: Enable/disable individual entity types as needed
✅ **Smart Filtering**: Apply OData filters to sync only the data you need
✅ **Comprehensive Logging**: Automatic transcript logging for audit and troubleshooting
✅ **Summary Reports**: Clear sync statistics and error reporting
✅ **Analysis Views**: Automatically creates helpful SQL views for data analysis

## Quick Start

### 1. Create Configuration File

Use the same config file format as integration tests:

```bash
# Copy the template
cp config.test.json.template config.production.json

# Edit with your values
notepad config.production.json
```

**Example config.production.json:**
```json
{
  "Azure": {
    "TenantId": "",
    "SubscriptionId": "your-subscription-id",
    "ResourceGroupName": "rg-graph-sync",
    "Location": "northeurope",
    "SQLServerName": "graph-sync-sql",
    "DatabaseName": "GraphData",
    "AdminUsername": "sqladmin",
    "AdminUserPassword": ""
  },
  "Graph": {
    "TenantId": "your-tenant-id",
    "ClientId": "your-app-client-id",
    "ClientSecret": ""
  }
}
```

**Note:** Leave `AdminUserPassword` and `ClientSecret` empty. The script will prompt for them on first run and encrypt them securely.

### 2. Run First Sync

```powershell
# Navigate to the _Test folder
cd C:\Path\To\FortigiGraph\_Test

# Run the sync (will create SQL Server on first run)
.\Daily-Sync.ps1 -ConfigFile .\config.production.json
```

On the first run:
1. You'll be prompted for SQL Admin Password
2. You'll be prompted for Graph Client Secret (or press Enter for interactive auth)
3. The script will create the SQL Server if it doesn't exist
4. All data will be synced
5. Analysis views will be created

### 3. Subsequent Runs

After the initial setup, daily syncs are simple:

```powershell
.\Daily-Sync.ps1 -ConfigFile .\config.production.json
```

The script will:
- Validate SQL Server exists
- Connect to Azure and Graph
- Sync all enabled entity types
- Update analysis views
- Generate a summary report

## Configuration Options

### What Gets Synced

By default, the runbook syncs:

| Entity Type | Default | Parameter |
|------------|---------|-----------|
| Users | ✅ Enabled | `-SyncUsers $true/$false` |
| Groups | ✅ Enabled | `-SyncGroups $true/$false` |
| Direct Memberships | ✅ Enabled | `-SyncGroupMembers $true/$false` |
| Transitive Memberships | ✅ Enabled | `-SyncGroupTransitiveMembers $true/$false` |
| Eligible Memberships (PIM) | ✅ Enabled | `-SyncGroupEligibleMembers $true/$false` |
| Group Ownerships | ✅ Enabled | `-SyncGroupOwners $true/$false` |
| Analysis Views | ✅ Enabled | `-CreateViews $true/$false` |

### Selective Sync Examples

**Sync only users and groups (no memberships):**
```powershell
.\Daily-Sync.ps1 -ConfigFile .\config.production.json `
    -SyncGroupMembers $false `
    -SyncGroupTransitiveMembers $false `
    -SyncGroupEligibleMembers $false `
    -SyncGroupOwners $false
```

**Sync everything except PIM (if not configured):**
```powershell
.\Daily-Sync.ps1 -ConfigFile .\config.production.json `
    -SyncGroupEligibleMembers $false
```

**Skip view creation (if you have custom views):**
```powershell
.\Daily-Sync.ps1 -ConfigFile .\config.production.json `
    -CreateViews $false
```

### Filtering Data

Apply OData filters to sync only specific data:

**Sync only enabled users:**
```powershell
.\Daily-Sync.ps1 -ConfigFile .\config.production.json `
    -UserFilter "accountEnabled eq true"
```

**Sync only security groups:**
```powershell
.\Daily-Sync.ps1 -ConfigFile .\config.production.json `
    -GroupFilter "securityEnabled eq true"
```

**Combine multiple filters:**
```powershell
.\Daily-Sync.ps1 -ConfigFile .\config.production.json `
    -UserFilter "accountEnabled eq true and userType eq 'Member'" `
    -GroupFilter "securityEnabled eq true"
```

### Additional User Attributes

Sync extra user attributes beyond the defaults:

```powershell
.\Daily-Sync.ps1 -ConfigFile .\config.production.json `
    -UserAdditionalAttributes @('officeLocation', 'city', 'state', 'country')
```

**Default attributes synced:**
- id, userPrincipalName, displayName, mail
- accountEnabled, userType, onPremisesSyncEnabled
- givenName, surname, jobTitle, department
- companyName, manager, createdDateTime
- And more (see `Sync-FGUser` function for full list)

## Automation & Scheduling

### Windows Task Scheduler

**Create a scheduled task for daily sync:**

1. **Create a wrapper script** (`Run-DailySync.ps1`):
```powershell
# Run-DailySync.ps1
Set-Location "C:\Scripts\FortigiGraph\_Test"
.\Daily-Sync.ps1 -ConfigFile .\config.production.json
```

2. **Schedule with Task Scheduler:**
```powershell
# Create scheduled task
$action = New-ScheduledTaskAction -Execute "pwsh.exe" `
    -Argument "-File C:\Scripts\FortigiGraph\_Test\Run-DailySync.ps1"

$trigger = New-ScheduledTaskTrigger -Daily -At "02:00AM"

$principal = New-ScheduledTaskPrincipal -UserId "DOMAIN\ServiceAccount" `
    -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName "Graph Daily Sync" `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Description "Daily sync of Microsoft Graph data to Azure SQL"
```

### Azure Automation

**Run the sync in Azure Automation:**

1. **Upload FortigiGraph module** to Azure Automation
2. **Create a Runbook:**

```powershell
# Azure-DailySync-Runbook.ps1
param(
    [string]$TenantId,
    [string]$ClientId,
    [string]$SubscriptionId,
    [string]$ResourceGroupName,
    [string]$SQLServerName
)

# Authenticate using Managed Identity or Service Principal
Connect-AzAccount -Identity

# Import FortigiGraph
Import-Module FortigiGraph

# Connect to Graph (using stored credentials)
Get-FGAccessToken -TenantId $TenantId -ClientId $ClientId `
    -ClientSecret (Get-AutomationVariable -Name 'GraphClientSecret')

# Connect to SQL
Connect-FGSQLServer -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -ServerName $SQLServerName `
    -AdminPassword (Get-AutomationPSCredential -Name 'SQLAdminCred').Password

# Run syncs
Sync-FGUser
Sync-FGGroup
Sync-FGGroupMember
Sync-FGGroupTransitiveMember
Sync-FGGroupEligibleMember
Sync-FGGroupOwner

# Create views
Initialize-FGGroupMembershipViews -DropIfExists
```

3. **Schedule the runbook** to run daily

## Output & Logging

### Console Output

The runbook provides color-coded, structured output:

```
========================================
FortigiGraph Daily Sync Runbook
========================================
Started: 2025-01-06 14:30:00
Config:  .\config.production.json
Log:     daily-sync-production-20250106-143000.log

=== Loading Configuration ===
  ✓ FortigiGraph module loaded
  ✓ Configuration loaded
  ✓ Configuration validated
  ✓ Secure credentials loaded

=== Connecting to Azure ===
  ✓ Connected to Azure: Production Subscription (user@domain.com)

=== Validating SQL Server ===
  ✓ SQL Server exists: graphsync.database.windows.net
  ✓ Connected to SQL Server
  ✓ SQL connection verified: GraphData

=== Connecting to Microsoft Graph ===
  ✓ Existing token is valid

=== Starting Data Synchronization ===
  → Syncing users to SQL...
  ✓ Users synced: 1,245

  → Syncing groups to SQL...
  ✓ Groups synced: 387

  → Syncing direct group memberships...
  ✓ Direct memberships synced: 4,521

  → Syncing transitive/nested group memberships...
  ✓ Transitive memberships synced: 8,932

  → Syncing eligible/PIM group memberships...
  ⚠ Eligible membership sync skipped: No PIM groups

  → Syncing group ownership relationships...
  ✓ Group ownerships synced: 245

=== Creating Analysis Views ===
  ✓ Analysis views created

=== Sync Summary ===

  Sync Duration: 00:08:34

  Users:                   1,245
  Groups:                  387
  Direct Memberships:      4,521
  Transitive Memberships:  8,932
  Eligible Memberships:    0
  Group Ownerships:        245

========================================
Sync Complete!
========================================
Completed: 2025-01-06 14:38:34
Log File:  daily-sync-production-20250106-143000.log
```

### Log Files

Every sync creates a timestamped log file:

**File naming:** `daily-sync-{config-name}-{timestamp}.log`

**Example:** `daily-sync-production-20250106-143000.log`

**Location:** Same folder as the script (`_Test/`)

**Log contents:**
- Full PowerShell transcript
- All console output
- Error details and stack traces
- Timestamps for all operations

## Error Handling

### Graceful Degradation

The runbook continues even if individual syncs fail:

```
=== Starting Data Synchronization ===
  → Syncing users to SQL...
  ✓ Users synced: 1,245

  → Syncing groups to SQL...
  ✗ Group sync failed
    Insufficient permissions: Requires Group.Read.All

  → Syncing direct group memberships...
  ✓ Direct memberships synced: 4,521
  ...

=== Sync Summary ===
  Errors encountered: 1
    - Group sync failed
```

### Common Issues

#### 1. Insufficient Permissions

**Error:** `Insufficient privileges to complete the operation`

**Solution:**
- Ensure the Graph app has required permissions:
  - `User.Read.All`
  - `Group.Read.All`
  - `GroupMember.Read.All`
  - `PrivilegedAccess.Read.AzureADGroup` (for PIM)
- Grant admin consent in Azure portal

#### 2. SQL Connection Failed

**Error:** `Cannot open server 'xxx' requested by the login`

**Solution:**
- Ensure your IP is in SQL Server firewall rules
- Use `-UpdateFirewall` parameter (automatically handled)
- Check if server exists in correct resource group

#### 3. Token Expired

**Error:** `Access token has expired`

**Solution:**
- The script auto-refreshes tokens
- If using service principal, verify client secret hasn't expired
- If interactive, you'll be prompted to re-authenticate

## Advanced Scenarios

### Multi-Tenant Sync

Sync data from multiple tenants to separate databases:

```powershell
# Tenant 1
.\Daily-Sync.ps1 -ConfigFile .\config.tenant1.json

# Tenant 2
.\Daily-Sync.ps1 -ConfigFile .\config.tenant2.json
```

### Incremental Sync

The temporal tables automatically track changes, but if you want to verify:

```sql
-- See what changed today
SELECT *
FROM GraphUsers FOR SYSTEM_TIME
    BETWEEN DATEADD(DAY, -1, GETDATE()) AND GETDATE()
WHERE ValidFrom >= DATEADD(DAY, -1, GETDATE())
```

### Custom Post-Sync Processing

Add custom logic after sync completes:

```powershell
# Run sync
.\Daily-Sync.ps1 -ConfigFile .\config.production.json

# Custom processing
Invoke-FGSQLQuery -Query @"
-- Send email for new users
SELECT userPrincipalName, displayName
FROM GraphUsers
WHERE ValidFrom >= DATEADD(HOUR, -1, GETDATE())
"@ | ForEach-Object {
    Send-MailMessage -To "admin@company.com" `
        -Subject "New User Created" `
        -Body "User: $($_.displayName) ($($_.userPrincipalName))"
}
```

## Performance Tuning

### Optimize for Large Tenants

**For tenants with 10,000+ users:**

1. **Use filters to reduce data:**
```powershell
.\Daily-Sync.ps1 -ConfigFile .\config.production.json `
    -UserFilter "accountEnabled eq true and userType eq 'Member'"
```

2. **Increase SQL Server tier:**
   - Upgrade from Basic to Standard S3+ for better performance
   - Consider Premium tier for very large datasets

3. **Run during off-hours:**
   - Schedule sync during low-usage periods
   - Reduces impact on SQL Server

4. **Monitor sync duration:**
   - Check log files for bottlenecks
   - Consider parallel processing for multiple entity types

### Sync Statistics

Track sync performance over time:

```sql
-- Create a sync stats table
CREATE TABLE SyncStatistics (
    SyncDate DATETIME2 DEFAULT GETDATE(),
    EntityType NVARCHAR(50),
    RecordCount INT,
    DurationSeconds INT
)

-- Log stats after each sync
INSERT INTO SyncStatistics (EntityType, RecordCount, DurationSeconds)
VALUES ('Users', (SELECT COUNT(*) FROM GraphUsers), 125)
```

## Troubleshooting

### Enable Debug Mode

Add debug output to troubleshoot issues:

```powershell
# Enable Graph API debug
$Global:DebugMode = 'G'  # GET requests

# Run sync
.\Daily-Sync.ps1 -ConfigFile .\config.production.json
```

### Check Last Sync

Verify when data was last updated:

```sql
-- Check last sync time for each entity
SELECT
    'Users' as Entity,
    MAX(ValidFrom) as LastSync,
    COUNT(*) as RecordCount
FROM GraphUsers

UNION ALL

SELECT
    'Groups',
    MAX(ValidFrom),
    COUNT(*)
FROM GraphGroups
```

### Validate Data Integrity

```sql
-- Check for orphaned memberships
SELECT COUNT(*)
FROM GraphGroupMembers gm
LEFT JOIN GraphGroups g ON gm.groupId = g.id
WHERE g.id IS NULL

-- Should return 0 if data is consistent
```

## Security Best Practices

### 1. Credential Management

✅ **DO:**
- Use Windows DPAPI encryption (automatic in this script)
- Store config files in secure locations with restricted permissions
- Use service principal with least privilege permissions
- Rotate client secrets regularly

❌ **DON'T:**
- Commit config files to source control (already in `.gitignore`)
- Share config files between users/machines
- Store plaintext passwords in scripts
- Use overly permissive Graph API permissions

### 2. SQL Server Security

✅ **DO:**
- Use firewall rules to restrict access
- Enable SQL Server auditing
- Use complex SQL admin passwords
- Consider using Azure AD authentication instead of SQL auth

### 3. Monitoring

Set up alerts for:
- Failed syncs (check log files)
- Permission errors
- Unusual data volumes
- Token expiration warnings

## Integration with BI Tools

### Power BI

Connect to your synced data:

1. Get Data → Azure SQL Database
2. Server: `your-server.database.windows.net`
3. Database: `GraphData`
4. Use views for analysis:
   - `vw_GraphGroupMembershipType`
   - `vw_GraphGroupNestedMembers`
   - `vw_GraphGroupEligibleMembers`

### Excel

Use Power Query to connect:

```m
let
    Source = Sql.Database("your-server.database.windows.net", "GraphData"),
    Users = Source{[Schema="dbo",Item="GraphUsers"]}[Data]
in
    Users
```

### Azure Synapse / Data Factory

Create pipelines that:
1. Trigger the Daily Sync runbook
2. Process synced data
3. Load into data warehouse
4. Generate reports

## Summary

The Daily Sync runbook provides:

- **Simple setup**: One config file, one command
- **Production-ready**: Comprehensive error handling and logging
- **Flexible**: Extensive configuration options
- **Secure**: Encrypted credentials using DPAPI
- **Auditable**: Full transcript logging
- **Maintainable**: Clear code structure following FortigiGraph patterns

For additional help:
- See integration test examples: `Test-Integration.ps1`
- Review function documentation: `Get-Help Sync-FGUser -Full`
- Check secure credential docs: `README-Secure-Credentials.md`
- SQL management guide: `README-SQL-Management.md`
