# FortigiGraph

A PowerShell module for working with Microsoft Graph API, syncing data to Azure SQL with temporal versioning, and documenting identity attribute mappings across your environment.

## Table of Contents

- [Features](#features)
- [Installation](#installation)
- [Quick Start](#quick-start)
  - [5-Minute Quickstart](#5-minute-quickstart)
  - [Production Quickstart (Daily Sync)](#production-quickstart-daily-sync)
- [Authentication](#authentication)
- [Azure SQL Server](#azure-sql-server)
  - [Creating SQL Server](#creating-sql-server)
  - [Connecting to SQL Server](#connecting-to-sql-server)
  - [SQL Management](#sql-management)
- [Data Synchronization](#data-synchronization)
  - [User Sync](#user-sync)
  - [Group Sync](#group-sync)
  - [Membership Analysis](#membership-analysis)
- [Attribute Mapping Discovery](#attribute-mapping-discovery)
- [Production Deployment (Daily Sync)](#production-deployment-daily-sync)
- [Temporal Tables & Historical Queries](#temporal-tables--historical-queries)
- [Testing](#testing)
- [Security & Credentials](#security--credentials)
- [Troubleshooting](#troubleshooting)
- [Best Practices](#best-practices)
- [Architecture & Design](#architecture--design)
- [Requirements](#requirements)
- [Support](#support)

---

## Features

### Core Capabilities
- **Easy Authentication**: Get Graph API tokens with simple commands (service principal & interactive)
- **Azure SQL Integration**: Provision and connect to Azure SQL databases
- **Temporal Tables**: Automatic version history tracking for all data changes
- **Point-in-Time Queries**: Query data as it existed at any point in time
- **High-Performance Bulk Operations**: Optimized sync with SqlBulkCopy (20-50x faster)

### Data Sync
- **User Sync**: Sync Microsoft Graph users to SQL with automatic schema detection
- **Group Sync**: Sync groups, memberships, nested groups, and PIM eligible members
- **Membership Analysis**: SQL views for analyzing direct, indirect, and eligible memberships
- **Flexible Filtering**: Filter by user type, account status, department, or any attribute

### Identity Governance
- **Attribute Mapping Discovery**: Discover and document all attribute mappings across HR, AD, Entra ID, and SCIM apps
- **Synchronization Analysis**: Analyze provisioning jobs, schemas, and transformation functions
- **Complete Visibility**: Track attribute flow from HR systems to target applications

### Production Ready
- **Daily Sync Runbook**: Production-ready scheduled sync with config file support
- **Secure Credentials**: Encrypted credential storage using Windows DPAPI
- **Comprehensive Logging**: Timestamped logs for auditing
- **Error Handling**: Graceful error handling with detailed reporting

### SQL Management Tools
- **Query Execution**: Simple SQL query execution from PowerShell
- **Table Management**: List, clear, and manage SQL tables
- **Server Management**: Create and remove Azure SQL Servers

### Testing
- **Integration Tests**: Comprehensive tests with parallel execution support
- **Secure Test Credentials**: DPAPI-encrypted test credentials
- **Multi-Environment**: Support for multiple test environments

---

## Installation

```powershell
# From PowerShell Gallery (when published)
Install-Module -Name FortigiGraph

# Or import locally
Import-Module .\FortigiGraph.psd1
```

---

## Quick Start

### 5-Minute Quickstart

Get up and running in 5 minutes:

```powershell
# 1. Import the module
Import-Module FortigiGraph

# 2. Get a Graph API token
Get-FGAccessToken -TenantId "contoso.onmicrosoft.com" -ClientId "your-client-id"

# 3. Create an Azure SQL Server
New-FGAzureSQLServer `
    -SubscriptionId "your-subscription-id" `
    -ResourceGroupName "rg-graph" `
    -ServerName "contosographsql" `
    -AllowCurrentIP `
    -AutoConnect

# 4. Sync users to SQL
Sync-FGUser

# 5. Query your data
Invoke-FGSQLQuery -Query "SELECT TOP 10 * FROM GraphUsers"
```

That's it! You now have all your Microsoft Graph users in SQL with automatic history tracking.

### Production Quickstart (Daily Sync)

For production environments with automated daily syncs:

```powershell
# 1. Create a config file
cd _Test
cp config.dailysync.json.template config.production.json

# 2. Edit the config file
# Fill in your Azure subscription, SQL server, and Graph settings

# 3. Run the sync
.\Daily-Sync.ps1 -ConfigFile .\config.production.json

# 4. Schedule it with Task Scheduler
$action = New-ScheduledTaskAction -Execute "pwsh.exe" `
    -Argument "-File C:\Path\_Test\Daily-Sync.ps1 -ConfigFile C:\Path\config.production.json"
$trigger = New-ScheduledTaskTrigger -Daily -At "02:00AM"
Register-ScheduledTask -TaskName "Graph Daily Sync" -Action $action -Trigger $trigger
```

See [Production Deployment](#production-deployment-daily-sync) for full details.

---

## Authentication

### Service Principal (Automated/Scheduled Tasks)

```powershell
Get-FGAccessToken `
    -TenantId "contoso.onmicrosoft.com" `
    -ClientId "app-client-id" `
    -ClientSecret "app-client-secret"
```

### Interactive (User Delegation)

```powershell
Get-FGAccessTokenInteractive `
    -TenantId "contoso.onmicrosoft.com" `
    -ClientId "app-client-id"
```

### Using Existing MSAL Token

```powershell
# If you already have a token from MSAL
Use-FGExistingMSALToken -MSALToken $token
```

### Required Permissions

For data synchronization:
- `User.Read.All` - Read all users
- `Group.Read.All` - Read all groups
- `GroupMember.Read.All` - Read group memberships

For attribute mapping discovery:
- `Application.Read.All` - Read application configurations
- `Synchronization.Read.All` or `Directory.Read.All` - Read synchronization schemas

### Token Storage

The access token is automatically stored in `$Global:AccessToken` and used by all functions.

---

## Azure SQL Server

### Creating SQL Server

Create a new Azure SQL Server with automatic connection:

```powershell
New-FGAzureSQLServer `
    -SubscriptionId "12345678-1234-1234-1234-123456789012" `
    -ResourceGroupName "rg-graph-data" `
    -ServerName "contosographsql" `
    -DatabaseName "GraphData" `
    -SkuName "S0" `
    -AllowCurrentIP `
    -AutoConnect
```

**Parameters:**
- `SubscriptionId` - Your Azure subscription ID
- `ResourceGroupName` - Resource group (creates if doesn't exist)
- `ServerName` - SQL Server name (must be globally unique)
- `DatabaseName` - Database name (default: "GraphData")
- `Location` - Azure region (default: "northeurope")
- `SkuName` - Database SKU (default: "Basic")
- `AllowCurrentIP` - Add your IP to firewall
- `AutoConnect` - Automatically connect after creation

**Available SKUs:**
- `Basic` - $5/month, 2GB max, good for testing
- `S0`, `S1`, `S2`, `S3` - Standard tier ($15-$300/month)
- `GP_Gen5_2`, `GP_Gen5_4` - General Purpose with vCores

### Connecting to SQL Server

Connect to an existing Azure SQL Server:

```powershell
Connect-FGSQLServer `
    -SubscriptionId "your-subscription-id" `
    -ResourceGroupName "rg-graph-data" `
    -ServerName "contosographsql" `
    -UpdateFirewall
```

**Features:**
- Automatically retrieves server FQDN and databases
- Updates firewall rules with your current IP
- Caches credentials for subsequent connections
- Tests connection validity

### SQL Management

#### List Tables

```powershell
# List all tables
Get-FGSQLTable

# Filter by pattern
Get-FGSQLTable -Pattern "GraphUsers*"
```

#### Run Queries

```powershell
# Get data
$users = Invoke-FGSQLQuery -Query "SELECT * FROM GraphUsers WHERE department = 'IT'"

# Get count
$count = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM GraphUsers" -AsScalar

# Update data
Invoke-FGSQLQuery -Query "UPDATE GraphUsers SET department = 'Engineering' WHERE id = '...'" -AsNonQuery
```

#### Clear Table Data

```powershell
# Clear table (preserves history)
Clear-FGSQLTable -TableName "GraphUsers_Test"

# Clear table and history
Clear-FGSQLTable -TableName "GraphUsers_Test" -DeleteHistory -Force
```

#### Remove SQL Server

**⚠️ WARNING: This permanently deletes the server and all databases!**

```powershell
Remove-FGAzureSQLServer `
    -SubscriptionId "..." `
    -ResourceGroupName "rg-test" `
    -ServerName "test-sql-server"
```

---

## Data Synchronization

### User Sync

Sync Microsoft Graph users to SQL with automatic schema detection and temporal versioning.

#### Default Attributes (16 properties)

By default, `Sync-FGUser` syncs these attributes:

**Identity**: `id`, `userPrincipalName`, `onPremisesSamAccountName`, `employeeId`
**Status**: `accountEnabled`, `userType`, `onPremisesSyncEnabled`
**Basic Info**: `displayName`, `givenName`, `surname`
**Organization**: `companyName`, `department`, `jobTitle`
**Metadata**: `createdDateTime`, `managerId`, `lastSignInDateTime`

#### Basic Usage

```powershell
# Sync with defaults
Sync-FGUser

# Add extra attributes
Sync-FGUser -AdditionalAttributes @('officeLocation', 'city', 'mobilePhone', 'employeeType')

# Custom attributes only
Sync-FGUser -Attributes @('id', 'userPrincipalName', 'mail', 'displayName', 'department')

# Filter users
Sync-FGUser -Filter "accountEnabled eq true"
Sync-FGUser -Filter "department eq 'Engineering'"
Sync-FGUser -Filter "userType eq 'Member'"

# Sync to custom table
Sync-FGUser -TableName "ActiveUsers" -Filter "accountEnabled eq true"
```

#### How It Works

1. **Attribute Selection**: Determines which attributes to sync
2. **Schema Check**: Automatically adds missing columns if needed
3. **Graph API Fetch**: Fetches all users with pagination
4. **SQL Sync**: Uses high-performance MERGE operations
5. **Deletion Handling**: Removes users no longer in Graph

#### Performance

**High-Performance Bulk Operations:**
- SqlBulkCopy to temp table (binary protocol)
- Bulk MERGE from temp to target (10-50x faster than row-by-row)
- Single transaction for atomicity
- Real-time progress tracking

**Benchmarks:**
- **100-200 users/sec** (previously ~3 users/sec)
- Expected for 4,300 users: **~25 seconds** (previously ~25 minutes)

#### Automatic Schema Evolution

Add new attributes without recreating the table:

```powershell
# First run
Sync-FGUser

# Later - add new attributes (no need to recreate!)
Sync-FGUser -AdditionalAttributes @('employeeType', 'officeLocation')
```

The function automatically:
1. Detects missing columns
2. Disables system versioning
3. Adds columns to both main and history tables
4. Re-enables system versioning

### Group Sync

#### Sync Group Details

```powershell
# Sync all groups with default attributes
Sync-FGGroup

# Add extra attributes
Sync-FGGroup -AdditionalAttributes @('theme', 'resourceProvisioningOptions')

# Filter groups
Sync-FGGroup -Filter "securityEnabled eq true"
Sync-FGGroup -Filter "mailEnabled eq true"
```

**Default Attributes (20+ properties):**
Identity, type, security, organization info, and metadata

#### Sync Direct Memberships

```powershell
# Sync all direct memberships
Sync-FGGroupMember

# Sync specific groups
Sync-FGGroupMember -GroupIds @('group-id-1', 'group-id-2')

# Filter groups
Sync-FGGroupMember -Filter "securityEnabled eq true"
```

**Table Structure**: `groupId`, `memberId`, `memberType`, composite PK `(groupId, memberId)`

#### Sync Nested/Transitive Memberships

```powershell
# Sync transitive memberships (includes indirect access through nested groups)
Sync-FGGroupTransitiveMember
```

**Difference:**
- **Direct**: Only explicit members
- **Transitive**: All members including through nested groups

**Example:**
- Group A contains User1 and Group B
- Group B contains User2
- Direct members of A: User1, Group B
- Transitive members of A: User1, Group B, User2

#### Sync PIM Eligible Memberships

```powershell
# Sync eligible memberships (users who can activate access)
Sync-FGGroupEligibleMember
```

**Requirements:**
- Only processes PIM-enabled groups (`isAssignableToRole = true`)
- Uses `/identityGovernance/privilegedAccess/group/eligibilitySchedules`

#### Sync Group Owners

```powershell
# Sync group owners
Sync-FGGroupOwner
```

### Membership Analysis

Create SQL views for easy membership analysis:

```powershell
Initialize-FGGroupMembershipViews
```

**Views Created:**

1. **vw_GraphGroupNestedMembers** - Only indirect members (not direct)
2. **vw_GraphGroupEligibleMembers** - Only PIM eligible members
3. **vw_GraphGroupMembershipType** - All members with type indicator (Direct/Indirect/Eligible)
4. **vw_GraphGroupMembersRecursive** ⭐ **NEW!** - Calculates ALL memberships recursively with paths

#### Recursive View (Performance Optimization)

The recursive view eliminates the need for `Sync-FGGroupTransitiveMember` (~75% faster):

```sql
-- Get all memberships with paths
SELECT * FROM vw_GraphGroupMembersRecursive
WHERE groupId = 'group-guid-here'
ORDER BY membershipType, depth;

-- Find users with both direct and indirect membership
SELECT groupId, memberId, COUNT(*) as PathCount
FROM vw_GraphGroupMembersRecursive
WHERE memberType = '#microsoft.graph.user'
GROUP BY groupId, memberId
HAVING COUNT(DISTINCT membershipType) > 1;

-- Find deeply nested memberships (4+ levels)
SELECT * FROM vw_GraphGroupMembersRecursive
WHERE depth >= 4
ORDER BY depth DESC;
```

**Features:**
- Calculates indirect memberships on-demand
- Shows complete path for each membership
- Preserves all paths for members with multiple routes
- Much faster than syncing transitive members

#### Query Examples

**Find users with indirect access only:**
```sql
SELECT u.displayName, u.userPrincipalName, g.displayName AS GroupName
FROM vw_GraphGroupNestedMembers m
JOIN GraphUsers u ON m.memberId = u.id
JOIN GraphGroups g ON m.groupId = g.id
WHERE u.accountEnabled = 1;
```

**Audit all membership types for a user:**
```sql
SELECT
    g.displayName AS GroupName,
    m.membershipType,
    m.ValidFrom,
    m.ValidTo
FROM vw_GraphGroupMembershipType m
JOIN GraphGroups g ON m.groupId = g.id
WHERE m.memberId = 'user-guid-here'
ORDER BY g.displayName, m.membershipType;
```

---

## Attribute Mapping Discovery

**NEW**: Discover and document all attribute mappings across your identity infrastructure.

### Overview

FortigiGraph can automatically discover all provisioning configurations in your Entra ID tenant and extract attribute mappings from:

- HR provisioning (Workday, SuccessFactors, custom HR) to AD
- Azure AD Connect Cloud Sync (AD to Entra ID)
- SCIM applications (Entra ID to applications)

### Discover Apps with Provisioning

```powershell
# Get all apps with provisioning configured
$apps = Get-FGServicePrincipalWithSync -IncludeSchema

# View summary
$apps | Select-Object DisplayName, AppType, JobCount | Format-Table

# Include Cloud Sync configurations
$apps = Get-FGServicePrincipalWithSync -IncludeCloudSync -IncludeSchema
```

### Extract Attribute Mappings

```powershell
# Get all attribute mappings
$mappings = Get-FGAttributeMapping -ServicePrincipalWithSync $apps

# View mappings
$mappings | Select-Object AppDisplayName, TargetAttributeName, SourceExpression, SourceAttributes | Format-Table
```

**Output includes:**
- `AppDisplayName` - Application name
- `TargetAttributeName` - Attribute being written to
- `SourceExpression` - Complete source expression
- `SourceAttributes` - List of source attributes (extracted from expression)
- `FlowType` - When attribute is synced (Always, ObjectAddOnly, etc.)
- `MatchingPriority` - Matching priority (for object matching)
- `SyncDirection` - Direction of sync (e.g., "HR -> AD")

### Query Mappings

```powershell
# Find all mappings for a specific target attribute
$mappings | Where-Object { $_.TargetAttributeName -eq "mail" } |
    Select-Object AppDisplayName, SourceExpression, SourceAttributes

# Find mappings that use a specific source attribute
$mappings | Where-Object { $_.SourceAttributes -contains "employeeId" } |
    Select-Object AppDisplayName, TargetAttributeName, SourceExpression

# Find matching priority mappings (used for object correlation)
$mappings | Where-Object { $_.MatchingPriority -gt 0 } |
    Sort-Object MatchingPriority -Descending |
    Select-Object AppDisplayName, TargetAttributeName, MatchingPriority

# Find transformation functions (not direct mappings)
$mappings | Where-Object { $_.SourceType -eq "Function" } |
    Select-Object AppDisplayName, TargetAttributeName, SourceExpression

# Group by target attribute to see which apps write to each
$mappings | Group-Object TargetAttributeName |
    Select-Object Name, Count, @{N="Apps";E={($_.Group.AppDisplayName | Select-Object -Unique) -join ", "}}
```

### Filter by Object Type

```powershell
# Get only User mappings
$userMappings = Get-FGAttributeMapping -ServicePrincipalWithSync $apps -ObjectType "User"

# Get only Group mappings
$groupMappings = Get-FGAttributeMapping -ServicePrincipalWithSync $apps -ObjectType "Group"
```

### Export for Analysis

```powershell
# Export all mappings to CSV
$mappings | Export-Csv -Path "attribute-mappings.csv" -NoTypeInformation

# Open in Excel or analyze with PowerShell
```

### Use Cases

- **Documentation**: Understand how attributes flow through your identity infrastructure
- **Troubleshooting**: Identify which system is responsible for populating an attribute
- **Compliance**: Document attribute mappings for audits
- **Migration Planning**: Understand current state before making changes
- **Onboarding**: Help new team members understand your identity architecture

---

## Production Deployment (Daily Sync)

For production environments, use the **Daily Sync** runbook to automate Graph data synchronization.

### Configuration File

Create a config file with all your settings:

```json
{
  "Azure": {
    "SubscriptionId": "your-subscription-id",
    "ResourceGroupName": "rg-graph-prod",
    "SqlServerName": "prodgraphsql",
    "SqlDatabaseName": "GraphData",
    "SqlServerAdminUsername": "sqladmin",
    "SqlServerAdminPassword_Encrypted": "...",
    "Location": "northeurope",
    "SkuName": "S1"
  },
  "Graph": {
    "TenantId": "contoso.onmicrosoft.com",
    "ClientId": "your-client-id",
    "ClientSecret_Encrypted": "..."
  },
  "Sync": {
    "Users": {
      "Enabled": true,
      "TableName": "GraphUsers",
      "Filter": "accountEnabled eq true",
      "AdditionalAttributes": [
        "officeLocation",
        "city",
        "employeeType",
        "extension_abc123_sfEmployeeId"
      ]
    },
    "Groups": {
      "Enabled": true,
      "Filter": ""
    },
    "GroupMembers": {
      "Enabled": true
    },
    "GroupTransitiveMembers": {
      "Enabled": true
    },
    "GroupEligibleMembers": {
      "Enabled": false
    },
    "GroupOwners": {
      "Enabled": true
    },
    "Views": {
      "Enabled": true
    }
  }
}
```

### Running Daily Sync

```powershell
# Run once
.\Daily-Sync.ps1 -ConfigFile .\config.production.json

# On first run, you'll be prompted for passwords
# They will be encrypted and stored in the config file
```

### Scheduling

**Windows Task Scheduler:**

```powershell
$action = New-ScheduledTaskAction -Execute "pwsh.exe" `
    -Argument "-File C:\Scripts\_Test\Daily-Sync.ps1 -ConfigFile C:\Scripts\config.production.json"

$trigger = New-ScheduledTaskTrigger -Daily -At "02:00AM"

$principal = New-ScheduledTaskPrincipal -UserId "DOMAIN\ServiceAccount" -LogonType Password -RunLevel Highest

Register-ScheduledTask `
    -TaskName "Graph Daily Sync - Production" `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Description "Daily sync of Graph data to SQL"
```

**Azure Automation:**

1. Upload the Daily-Sync.ps1 script as a runbook
2. Upload the config file as an automation variable
3. Schedule the runbook to run daily
4. Configure managed identity for Azure SQL access

### Features

- **Automatic Setup**: Creates SQL Server on first run if needed
- **Config-Driven**: All settings in one JSON file
- **Secure Credentials**: DPAPI encryption for passwords
- **Selective Sync**: Enable/disable individual entity types
- **Comprehensive Logging**: Timestamped logs for auditing
- **Error Handling**: Continues on errors, reports at end
- **Summary Reports**: Clear statistics after each sync

### Monitoring

The script creates detailed logs:

```
_Test/daily-sync-config.production-YYYYMMDD-HHMMSS.log
```

**Log Contents:**
- Start/end timestamps
- Configuration used
- Progress for each entity type
- Errors and warnings
- Summary statistics

---

## Temporal Tables & Historical Queries

All synced data uses SQL Server temporal tables for automatic change tracking.

### Understanding Temporal Tables

**Structure:**
- Main table: Current data (e.g., `GraphUsers`)
- History table: Previous versions (e.g., `GraphUsersHistory`)
- System columns: `ValidFrom`, `ValidTo` (managed automatically)

**How it works:**
1. When you update or delete a row, the old version is moved to history
2. Current table always has the latest data
3. History table has all previous versions with timestamps

### Querying Current Data

```sql
-- Just query normally
SELECT * FROM GraphUsers;
```

### Querying All History

```sql
-- Use the auto-created view
SELECT * FROM vw_GraphUsers_AllHistory
ORDER BY userPrincipalName, ValidFrom;
```

### Point-in-Time Queries

```sql
-- See data as it existed on January 15, 2025
SELECT * FROM GraphUsers
FOR SYSTEM_TIME AS OF '2025-01-15 10:00:00';
```

### Changes Between Dates

```sql
-- See all changes between two dates
SELECT * FROM GraphUsers
FOR SYSTEM_TIME BETWEEN '2025-01-01' AND '2025-01-31';
```

### User Change History

```sql
-- Track all changes for a specific user
SELECT
    userPrincipalName,
    displayName,
    department,
    ValidFrom,
    ValidTo,
    CASE
        WHEN ValidTo = '9999-12-31 23:59:59.9999999' THEN 'Current'
        ELSE 'Historical'
    END AS Status
FROM GraphUsers FOR SYSTEM_TIME ALL
WHERE userPrincipalName = 'john.doe@contoso.com'
ORDER BY ValidFrom DESC;
```

### Use Cases

- **Compliance Audits**: "Who had access on this date?"
- **Incident Investigation**: "When did this change occur?"
- **Trend Analysis**: "How has our department structure evolved?"
- **Data Recovery**: "What was the value before it changed?"

---

## Testing

### Quick Diagnostic

Fast diagnostic to verify everything works:

```powershell
.\_Test\Test-Simple.ps1 -ConfigFile _Test\config.test.json
```

**Checks:**
- Graph API connectivity
- SQL Server connectivity
- Token validity
- Basic sync operations

### Integration Tests

Comprehensive end-to-end tests:

```powershell
# Full test with cleanup
.\_Test\Test-Integration.ps1 -ConfigFile _Test\config.test.json

# Keep resources for inspection
.\_Test\Test-Integration.ps1 -ConfigFile _Test\config.test.json -SkipCleanup

# Parallel execution (faster)
.\_Test\Test-Integration.ps1 -ConfigFile _Test\config.test.json -Parallel
```

**Tests Include:**
- SQL Server creation
- Database provisioning
- User sync with various filters
- Group sync
- Membership sync (direct, transitive, eligible)
- View creation
- Temporal table operations
- Query validation
- Cleanup

### Test Configuration

Create a test config file:

```powershell
cd _Test
cp config.test.json.template config.mytest.json
# Edit config.mytest.json
```

**On first run**, you'll be prompted for passwords. They're encrypted and stored automatically.

---

## Security & Credentials

### Secure Credential Storage

Test scripts and Daily Sync use **Windows DPAPI** for credential encryption.

**Features:**
- Credentials encrypted at rest
- User-specific (can only be decrypted by same Windows user on same machine)
- Automatic migration from plaintext
- No code changes needed

**First Run:**
```
→ Enter SQL Server Admin Password: ********
✓ Credential encrypted and stored securely

→ Enter Graph Client Secret: ********
✓ Credential encrypted and stored securely
```

**Subsequent runs:** Credentials loaded automatically from encrypted storage.

### Managing Credentials

```powershell
# Check credential status
.\_Test\Manage-Credentials.ps1 -ConfigFile config.production.json

# Clear stored credentials
.\_Test\Manage-Credentials.ps1 -ConfigFile config.production.json
# Choose option 2 to clear
```

### Security Best Practices

1. **Never commit config files with credentials to git**
   - `.gitignore` already protects `config.*.json` files
   - Still, double-check before committing

2. **Use service principals for automation**
   - Create dedicated service principal for sync operations
   - Grant minimum required permissions

3. **Rotate secrets regularly**
   - Update secrets in Azure AD
   - Re-run scripts to re-encrypt with new values

4. **Separate dev/test/prod configs**
   - Use different config files per environment
   - Never use production credentials in test environments

5. **Restrict SQL Server access**
   - Use firewall rules
   - Enable Azure AD authentication
   - Use managed identities when possible

---

## Troubleshooting

### Connection Issues

**SQL Server connection fails:**

```powershell
# Update firewall with your current IP
Connect-FGSQLServer -SubscriptionId $sub -ResourceGroupName $rg -ServerName $server -UpdateFirewall

# Force reconnect
Connect-FGSQLServer -SubscriptionId $sub -ResourceGroupName $rg -ServerName $server -Force

# Test connection
Test-FGSQLConnection
```

**Graph API connection fails:**

```powershell
# Check token validity
Confirm-FGAccessTokenValidity

# Get new token
Get-FGAccessToken -TenantId $tid -ClientId $cid -ClientSecret $secret
```

### Permission Issues

**Error: "Insufficient privileges"**

Required Graph API permissions:
- `User.Read.All` - Read users
- `Group.Read.All` - Read groups
- `GroupMember.Read.All` - Read memberships
- `Synchronization.Read.All` or `Directory.Read.All` - Read sync schemas

Verify permissions in Azure Portal → App registrations → API permissions

**Don't forget to grant admin consent!**

### Schema Issues

**Column doesn't exist:**

The schema automatically evolves, but if you need to rebuild:

```powershell
# Add missing columns (recommended)
Sync-FGUser -AdditionalAttributes @('newAttribute')

# Or recreate table (loses history!)
Sync-FGUser -RecreateTable
```

**Temporal table errors:**

Don't modify temporal tables directly! Use the functions:

```powershell
# ❌ Wrong
Invoke-FGSQLQuery -Query "ALTER TABLE GraphUsers ADD newColumn NVARCHAR(255)"

# ✅ Correct
Sync-FGUser -AdditionalAttributes @('newColumn')
```

### Performance Issues

**Sync is slow:**

- Check network connectivity
- Consider filtering users: `Sync-FGUser -Filter "accountEnabled eq true"`
- Increase SQL SKU if database is bottleneck
- Check for locks: `sp_who2` in SQL

**Queries are slow:**

- Add indexes on commonly queried columns
- Use appropriate SQL SKU for workload
- Consider archiving old history if table is huge

### Debug Mode

Enable debug output:

```powershell
$Global:DebugMode = 'T'   # Token operations
$Global:DebugMode = 'G'   # GET requests
$Global:DebugMode = 'P'   # POST/PATCH requests
$Global:DebugMode = 'D'   # DELETE requests
$Global:DebugMode = 'GP'  # Multiple categories
```

---

## Best Practices

### 1. Regular Syncs

Schedule daily syncs to keep data current:

```powershell
# Production pattern
Get-FGAccessToken -TenantId $tid -ClientId $cid -ClientSecret $secret
Connect-FGSQLServer -SubscriptionId $sub -ResourceGroupName $rg -ServerName $server
Sync-FGUser
Sync-FGGroup
Sync-FGGroupMember
```

Or use the Daily Sync runbook for full automation.

### 2. Incremental Attributes

Start with defaults, add attributes as needed:

```powershell
# Week 1
Sync-FGUser

# Week 2 - add location data
Sync-FGUser -AdditionalAttributes @('officeLocation', 'city')

# Week 3 - add more
Sync-FGUser -AdditionalAttributes @('officeLocation', 'city', 'employeeType', 'mobilePhone')
```

The table schema evolves automatically!

### 3. Filtered Syncs

Reduce data volume with filters:

```powershell
# Only active employees
Sync-FGUser -Filter "accountEnabled eq true and userType eq 'Member'"

# Only security groups
Sync-FGGroup -Filter "securityEnabled eq true"
```

### 4. Multiple Tables

Sync different subsets to different tables:

```powershell
# All users
Sync-FGUser -TableName "AllUsers"

# Active users only
Sync-FGUser -TableName "ActiveUsers" -Filter "accountEnabled eq true"

# Guests only
Sync-FGUser -TableName "GuestUsers" -Filter "userType eq 'Guest'"
```

### 5. Leverage Temporal History

Use temporal tables for auditing and analysis:

```sql
-- Monthly activity report
SELECT
    YEAR(ValidFrom) AS Year,
    MONTH(ValidFrom) AS Month,
    COUNT(DISTINCT id) AS UsersModified
FROM GraphUsers FOR SYSTEM_TIME ALL
WHERE ValidFrom >= DATEADD(MONTH, -6, GETDATE())
GROUP BY YEAR(ValidFrom), MONTH(ValidFrom)
ORDER BY Year, Month;
```

### 6. Monitor and Alert

Set up monitoring:

- Alert on sync failures
- Track sync duration trends
- Monitor SQL Server DTU usage
- Watch for Graph API throttling

### 7. Test Before Production

Always test changes in a non-production environment:

```powershell
# Test environment
.\_Test\Test-Integration.ps1 -ConfigFile config.test.json

# If successful, deploy to production
.\Daily-Sync.ps1 -ConfigFile config.production.json
```

---

## Architecture & Design

### Code Reuse Pattern

All SQL functions use a centralized helper `Invoke-FGSQLCommand` that manages connection lifecycle:

```powershell
# Internal pattern
Invoke-FGSQLCommand -ScriptBlock {
    param($connection)

    # Your SQL operations here
    # Connection is already open and will be automatically closed
    $cmd = $connection.CreateCommand()
    $cmd.CommandText = "SELECT ..."
    return $cmd.ExecuteScalar()
}
```

**Benefits:**
- Automatic resource management
- Consistent error handling
- No code duplication
- Focus on business logic

### Function Responsibilities

Each function has a single, clear responsibility:

**Connect-FGSQLServer**: Manages Azure integration and firewall
**New-FGSQLConnection**: Low-level connection management
**Test-FGSQLConnection**: Connection validation
**Initialize-FGSQLTable**: Creates temporal tables
**Sync-FGUser**: Fetches from Graph, syncs to SQL

This follows the **DRY (Don't Repeat Yourself)** principle.

### Module Structure

```
FortigiGraph/
├── Base/          # Authentication & HTTP operations (~17 functions)
├── Generic/       # Graph API wrappers (~50 functions)
├── SQL/           # Azure SQL operations (10 functions)
├── Specific/      # Business logic helpers (~10 functions)
└── _Test/         # Testing & production runbooks (5 scripts)
```

Total: **~90 functions, ~5,500 lines of code**

---

## Requirements

### PowerShell
- PowerShell 5.1 or later
- PowerShell 7+ recommended for cross-platform support

### Azure
- Azure subscription (for SQL Server)
- Az PowerShell module (`Install-Module Az`)

### Permissions

**Microsoft Graph API:**
- `User.Read.All` (minimum for user sync)
- `Group.Read.All` (for group sync)
- `GroupMember.Read.All` (for membership sync)
- `Synchronization.Read.All` or `Directory.Read.All` (for attribute mapping discovery)

**Azure:**
- Contributor role on subscription or resource group (for creating SQL Server)

**Entra ID Roles (for attribute mapping discovery):**
- Application Administrator, Cloud Application Administrator, or Hybrid Identity Administrator

---

## Support

### Getting Help

- **GitHub Issues**: [Report bugs or request features](https://github.com/Fortigi/FortigiGraph/issues)
- **Documentation**: Check this README and `CLAUDE.md` for development guide
- **Examples**: Look in `_Test/` folder for working examples

### Contributing

Contributions are welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Make your changes following the development guide
4. Submit a pull request

---

## License

(Your license information here)

---

**Author**: Wim van den Heijkant
**Company**: Fortigi
**GitHub**: [https://github.com/Fortigi/FortigiGraph](https://github.com/Fortigi/FortigiGraph)
**PowerShell Gallery**: [https://www.powershellgallery.com/packages/FortigiGraph](https://www.powershellgallery.com/packages/FortigiGraph)
