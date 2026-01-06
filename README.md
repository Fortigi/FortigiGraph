# FortigiGraph

A PowerShell module for working with Microsoft Graph API and syncing data to Azure SQL with temporal versioning.

## Features

- **Easy Authentication**: Get Graph API tokens with simple commands
- **Azure SQL Integration**: Provision and connect to Azure SQL databases
- **Temporal Tables**: Automatic version history tracking for all data changes
- **User Sync**: Sync Microsoft Graph users to SQL with automatic schema detection
- **Group Sync**: Sync groups, memberships, nested groups, and PIM eligible members
- **Membership Analysis**: SQL views for analyzing direct, indirect, and eligible memberships
- **Point-in-Time Queries**: Query data as it existed at any point in time
- **Performance Optimized**: Transaction-based syncing with progress tracking
- **SQL Management Tools**: Query, list, clear, and manage SQL tables and servers
- **Secure Credentials**: Encrypted credential storage using Windows DPAPI
- **Comprehensive Testing**: Integration tests with parallel execution support

## Installation

```powershell
Import-Module FortigiGraph
```

## Quick Start

### 1. Get a Graph API Token

```powershell
# Interactive authentication
Get-FGAccessToken -TenantId "your-tenant-id" -ClientId "your-client-id"
```

### 2. Create an Azure SQL Server

```powershell
New-FGAzureSQLServer `
    -SubscriptionId "your-subscription-id" `
    -ResourceGroupName "rg-graph" `
    -ServerName "mygraphsql" `
    -AllowCurrentIP `
    -AutoConnect
```

### 3. Sync Users from Graph to SQL

```powershell
# Sync with default attributes (16 common user properties)
Sync-FGUser

# Sync with additional attributes
Sync-FGUser -AdditionalAttributes @('officeLocation', 'city', 'employeeType')

# Sync only enabled users
Sync-FGUser -Filter "accountEnabled eq true"
```

### 4. Sync Groups and Memberships

```powershell
# Sync group details
Sync-FGGroup

# Sync direct group memberships
Sync-FGGroupMember

# Sync nested/transitive memberships (includes indirect access)
Sync-FGGroupTransitiveMember

# Sync PIM eligible memberships
Sync-FGGroupEligibleMember

# Create helpful views for membership analysis
Initialize-FGGroupMembershipViews
```

---

## Authentication Functions

### Get-FGAccessToken

Obtains an access token for Microsoft Graph API.

**Parameters:**
- `TenantId` - Your Azure AD tenant ID
- `ClientId` - Your application/client ID
- `Scopes` (optional) - Permission scopes (default: User.Read.All, Group.Read.All)

**Example:**
```powershell
Get-FGAccessToken -TenantId "contoso.onmicrosoft.com" -ClientId "abc-123-def"
```

**Note:** The token is stored in `$global:AccessToken` and automatically used by other functions.

---

## Azure SQL Server Functions

### New-FGAzureSQLServer

Creates a new Azure SQL Server and Database for storing Microsoft Graph data.

**Parameters:**
- `SubscriptionId` - Azure Subscription ID
- `ResourceGroupName` - Resource Group name (creates if doesn't exist)
- `ServerName` - SQL Server name (must be globally unique)
- `DatabaseName` (optional) - Database name (default: "GraphData")
- `Location` (optional) - Azure region (default: "northeurope")
- `AdminUsername` (optional) - SQL admin username (default: "sqladmin")
- `AdminPassword` (optional) - SQL admin password (prompts if not provided)
- `SkuName` (optional) - Database SKU (default: "Basic")
- `AllowCurrentIP` (switch) - Add your current IP to firewall
- `AutoConnect` (switch) - Automatically connect after creation

**Example:**
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

**Available SKUs:**
- `Basic` - Cheap, 2GB max, good for testing
- `S0`, `S1`, `S2`, `S3` - Standard tier with increasing performance
- `GP_Gen5_2`, `GP_Gen5_4` - General Purpose with vCores

---

### Connect-FGSQLServer

Connects to an Azure SQL Server with automatic firewall management and Azure integration.

**Parameters:**
- `SubscriptionId` - Azure Subscription ID
- `ResourceGroupName` - Resource Group name
- `ServerName` - SQL Server name
- `DatabaseName` (optional) - Database name (auto-detects if not specified)
- `UpdateFirewall` (switch) - Update firewall with your current IP
- `Force` (switch) - Force reconnection even if already connected

**Example:**
```powershell
Connect-FGSQLServer `
    -SubscriptionId "12345678-1234-1234-1234-123456789012" `
    -ResourceGroupName "rg-graph-data" `
    -ServerName "contosographsql" `
    -UpdateFirewall
```

**Features:**
- Automatically retrieves server FQDN and database list
- Updates firewall rules with your current IP
- Caches credentials for subsequent connections
- Tests connection validity before claiming "already connected"

---

### Test-FGSQLConnection

Tests the current SQL connection and displays server information.

**Example:**
```powershell
Test-FGSQLConnection
```

---

### Initialize-FGSQLTable

Creates a temporal table in SQL Server with automatic version history.

**Parameters:**
- `TableName` - Name of the table to create
- `Columns` - Hashtable of column names and SQL data types
- `PrimaryKey` - Column name(s) for primary key (string or array)
- `DropIfExists` (switch) - Drop table if it already exists

**Example:**
```powershell
$columns = @{
    "UserPrincipalName" = "NVARCHAR(255)"
    "DisplayName" = "NVARCHAR(255)"
    "Department" = "NVARCHAR(255)"
    "AccountEnabled" = "BIT"
}

Initialize-FGSQLTable -TableName "CustomUsers" -Columns $columns -PrimaryKey "UserPrincipalName"
```

**Features:**
- Automatically creates history table (e.g., `CustomUsersHistory`)
- Adds `ValidFrom` and `ValidTo` system columns
- Creates helper view `vw_CustomUsers_AllHistory` for easy querying

---

## User Sync Function

### Sync-FGUser

Syncs Microsoft Graph users to Azure SQL with automatic schema detection and temporal versioning.

**This is the main function you'll use for syncing user data from Graph to SQL.**

#### Default Attributes (16 properties)

When called without parameters, syncs these attributes:

**Identity:**
- `id` - User's unique identifier (GUID)
- `userPrincipalName` - User's UPN (e.g., user@contoso.com)
- `onPremisesSamAccountName` - On-premises SAM account name
- `employeeId` - Employee ID

**Status:**
- `accountEnabled` - Whether account is enabled
- `userType` - User type (Member/Guest)
- `onPremisesSyncEnabled` - Whether synced from on-premises

**Basic Info:**
- `displayName` - Display name
- `givenName` - First name
- `surname` - Last name

**Organization:**
- `companyName` - Company name
- `department` - Department
- `jobTitle` - Job title

**Metadata:**
- `createdDateTime` - When account was created
- `managerId` - Manager's unique ID (GUID)
- `lastSignInDateTime` - Last sign-in date/time

#### Parameters

- `Attributes` - Custom array of attributes (overrides defaults)
- `AdditionalAttributes` - Attributes to add on top of defaults
- `Filter` - OData filter (e.g., "accountEnabled eq true")
- `TableName` (optional) - Table name (default: "GraphUsers")
- `RecreateTable` (switch) - Drop and recreate table (loses history!)
- `BatchSize` (optional) - Batch size for progress reporting (default: 100)

#### Examples

**Basic sync with defaults:**
```powershell
Sync-FGUser
```

**Add extra attributes:**
```powershell
Sync-FGUser -AdditionalAttributes @('officeLocation', 'city', 'state', 'employeeType')
```

**Custom attributes only:**
```powershell
Sync-FGUser -Attributes @('id', 'userPrincipalName', 'mail', 'displayName', 'department')
```

**Filter users:**
```powershell
# Only enabled users
Sync-FGUser -Filter "accountEnabled eq true"

# Only members (no guests)
Sync-FGUser -Filter "userType eq 'Member'"

# Specific department
Sync-FGUser -Filter "department eq 'Engineering'"
```

**Sync to custom table:**
```powershell
Sync-FGUser -TableName "ActiveUsers" -Filter "accountEnabled eq true"
```

#### How It Works

1. **Attribute Selection**: Determines which attributes to sync (defaults + additional or custom)
2. **Schema Check**:
    - Checks if table exists
    - Automatically adds missing columns if new attributes are specified
    - Creates table with temporal versioning on first run
3. **Graph API Fetch**:
    - Fetches all users from Microsoft Graph
    - Handles pagination automatically
    - Shows progress every batch
4. **SQL Sync**:
    - Opens transaction for performance
    - Uses MERGE statements (INSERT or UPDATE based on existence)
    - Only creates history entries when data actually changes
    - Shows progress every 100 users with rate (users/sec)
    - Commits transaction
5. **Deletion Handling**: Removes users from SQL that no longer exist in Graph

#### Performance

- **Transaction-based**: All operations in a single transaction for speed
- **Optimized MERGE**: Reuses prepared statement for each user
- **Progress tracking**: Shows real-time progress with timestamps and rate
- **Typical performance**: 40-50 users/sec depending on network and database tier

#### Output Example

```
[14:23:15] Using default attributes: 16 attributes
[14:23:15] Table 'GraphUsers' already exists. Checking schema...
[14:23:15]   Schema is up to date

[14:23:15] Fetching users from Microsoft Graph...
[14:23:15]   Fetched 100 users...
[14:23:16]   Fetched 234 users...
[14:23:17] Total users fetched: 234 (took 2.1s)

[14:23:17] Syncing users to SQL Server...
[14:23:17] Database connection established
[14:23:17] Starting transaction...
[14:23:17] Preparing MERGE statement...
[14:23:17] Inserting/updating 234 users...
[14:23:19]   Progress: 100/234 users (48.2 users/sec)
[14:23:21]   Progress: 200/234 users (47.1 users/sec)
[14:23:22] Committing transaction...
[14:23:22] Transaction committed successfully (took 5.1s)
[14:23:22] Checking for deleted users...
[14:23:22]   No deleted users found

================================================================================
Sync Complete!
================================================================================
Table:                  GraphUsers
Total Users:            234
Synced:                 234
Deleted:                0
Errors:                 0
Attributes:             16

All changes are automatically tracked in GraphUsersHistory
================================================================================
```

#### Automatic Schema Evolution

When you add new attributes via `-AdditionalAttributes`, the function automatically:
1. Detects missing columns
2. Disables system versioning
3. Adds columns to both main table and history table
4. Re-enables system versioning

**Example:**
```powershell
# First run - creates table with defaults
Sync-FGUser

# Later - add new attributes (no need to recreate table!)
Sync-FGUser -AdditionalAttributes @('employeeType', 'officeLocation')
```

Output:
```
[14:25:10] Found 2 new attribute(s) to add: employeeType, officeLocation
[14:25:10] Adding columns to existing table...
[14:25:10]   Adding column: employeeType (NVARCHAR(255))
[14:25:10]   Adding column: officeLocation (NVARCHAR(255))
[14:25:11] Schema updated successfully
```

---

## Group Sync Functions

FortigiGraph provides comprehensive group synchronization capabilities, including group details, memberships, nested memberships, and PIM eligible memberships.

### Sync-FGGroup

Syncs Microsoft Graph group details to Azure SQL with automatic schema detection and temporal versioning.

#### Default Attributes (20+ properties)

When called without parameters, syncs these attributes:

**Identity:**
- `id` - Group's unique identifier (GUID)
- `displayName` - Group display name
- `description` - Group description
- `mail` - Group email address
- `mailNickname` - Mail alias

**Type & Security:**
- `mailEnabled` - Whether mail is enabled
- `securityEnabled` - Whether it's a security group
- `groupTypes` - Array of group types (Unified, DynamicMembership, etc.)
- `visibility` - Public/Private visibility
- `isAssignableToRole` - Whether assignable to Azure AD roles (PIM)

**Organization:**
- `ownerId` - Owner's unique ID (first owner)
- `classification` - Data classification
- `membershipRule` - Dynamic membership rule (if dynamic)
- `membershipRuleProcessingState` - Dynamic membership state

**Metadata:**
- `createdDateTime` - When group was created
- `renewedDateTime` - Last renewal date
- `expirationDateTime` - Expiration date (if set)
- `onPremisesSyncEnabled` - Whether synced from on-premises
- `onPremisesLastSyncDateTime` - Last on-premises sync

#### Parameters

- `Attributes` - Custom array of attributes (overrides defaults)
- `AdditionalAttributes` - Attributes to add on top of defaults
- `Filter` - OData filter (e.g., "securityEnabled eq true")
- `TableName` (optional) - Table name (default: "GraphGroups")
- `RecreateTable` (switch) - Drop and recreate table (loses history!)

#### Examples

**Basic sync with defaults:**
```powershell
Sync-FGGroup
```

**Add extra attributes:**
```powershell
Sync-FGGroup -AdditionalAttributes @('theme', 'resourceProvisioningOptions')
```

**Filter groups:**
```powershell
# Only security groups
Sync-FGGroup -Filter "securityEnabled eq true"

# Only Microsoft 365 groups
Sync-FGGroup -Filter "groupTypes/any(c:c eq 'Unified')"

# Only role-assignable groups
Sync-FGGroup -Filter "isAssignableToRole eq true"
```

---

### Sync-FGGroupMember

Syncs **direct** group memberships to SQL with composite primary key (groupId + memberId).

**Table Structure:**
- `groupId` (UNIQUEIDENTIFIER) - Group's ID
- `memberId` (UNIQUEIDENTIFIER) - Member's ID
- `memberType` (NVARCHAR) - Type of member (#microsoft.graph.user, #microsoft.graph.group, etc.)
- Primary Key: **(groupId, memberId)** - Composite key for many-to-many relationship

#### Parameters

- `Filter` - OData filter to limit which groups to process
- `GroupIds` - Array of specific group IDs to sync
- `TableName` (optional) - Table name (default: "GraphGroupMembers")
- `RecreateTable` (switch) - Drop and recreate table (loses history!)

#### Examples

**Sync all direct memberships:**
```powershell
Sync-FGGroupMember
```

**Sync specific groups:**
```powershell
$groupIds = @('group-id-1', 'group-id-2', 'group-id-3')
Sync-FGGroupMember -GroupIds $groupIds
```

**Filter groups:**
```powershell
Sync-FGGroupMember -Filter "securityEnabled eq true"
```

#### How It Works

The function iterates through each group individually to fetch members because bulk queries have Graph API limitations:

1. Fetches all groups (or filtered subset)
2. For each group, calls `/groups/{id}/members` endpoint
3. Stores membership relationships in SQL
4. Uses composite key (groupId, memberId) for proper many-to-many handling
5. Tracks changes over time with temporal versioning

---

### Sync-FGGroupTransitiveMember

Syncs **transitive/nested** group memberships - includes all members through nested groups.

**Table Structure:** Same as `Sync-FGGroupMember`
- `groupId`, `memberId`, `memberType`
- Primary Key: **(groupId, memberId)**
- Default table: **GraphGroupTransitiveMembers**

#### Difference from Sync-FGGroupMember

- **Direct members**: Only users/groups explicitly added to the group
- **Transitive members**: All users including those from nested groups

**Example:**
- Group A contains User1 and Group B
- Group B contains User2
- Direct members of Group A: User1, Group B
- Transitive members of Group A: User1, Group B, User2

#### Parameters

Same as `Sync-FGGroupMember`:
- `Filter`, `GroupIds`, `TableName`, `RecreateTable`

#### Examples

**Sync all transitive memberships:**
```powershell
Sync-FGGroupTransitiveMember
```

**Sync specific groups:**
```powershell
Sync-FGGroupTransitiveMember -GroupIds @('group-id-1', 'group-id-2')
```

#### Use Case

Use this to answer: "Who has access to this group through any path (including nested groups)?"

---

### Sync-FGGroupEligibleMember

Syncs **PIM eligible** group memberships - members who can activate access but don't currently have it.

**Table Structure:** Same as other membership tables
- `groupId`, `memberId`, `memberType`
- Primary Key: **(groupId, memberId)**
- Default table: **GraphGroupEligibleMembers**

#### PIM Integration

Only processes **PIM-enabled groups**:
- `isAssignableToRole` must be `true`
- Group must not be a dynamic membership group
- Uses `/identityGovernance/privilegedAccess/group/eligibilitySchedules` endpoint

#### Parameters

- `Filter` - OData filter (applied before PIM filtering)
- `GroupIds` - Array of specific group IDs to sync
- `TableName` (optional) - Table name (default: "GraphGroupEligibleMembers")
- `RecreateTable` (switch) - Drop and recreate table

#### Examples

**Sync all eligible memberships:**
```powershell
Sync-FGGroupEligibleMember
```

**Sync specific PIM groups:**
```powershell
$pimGroupIds = @('pim-group-1', 'pim-group-2')
Sync-FGGroupEligibleMember -GroupIds $pimGroupIds
```

#### Use Case

Use this to answer:
- "Who is eligible to activate membership in this group?"
- "Which users have PIM eligibility but haven't activated?"
- "Track changes to PIM eligibility over time"

#### Notes

- If a group is not PIM-enabled, the function will skip it with a warning
- Eligible members may or may not be active members
- Use `Initialize-FGGroupMembershipViews` to combine eligible + active data

---

## Group Membership Analysis

### Initialize-FGGroupMembershipViews

Creates SQL views that simplify analyzing group membership relationships.

#### Prerequisites

- `GraphGroupMembers` table (run `Sync-FGGroupMember` first)
- `GraphGroupTransitiveMembers` table (run `Sync-FGGroupTransitiveMember` first)
- `GraphGroupEligibleMembers` table (optional - run `Sync-FGGroupEligibleMember` for PIM support)

#### Parameters

- `DirectMembersTable` (optional) - Direct members table name (default: "GraphGroupMembers")
- `TransitiveMembersTable` (optional) - Transitive members table name (default: "GraphGroupTransitiveMembers")
- `EligibleMembersTable` (optional) - Eligible members table name (default: "GraphGroupEligibleMembers")
- `DropIfExists` (switch) - Recreate views if they already exist

#### Views Created

**1. vw_GraphGroupNestedMembers**
Shows only members who have **indirect access** (not direct members):

```sql
SELECT * FROM vw_GraphGroupNestedMembers
WHERE groupId = 'group-guid-here';
```

**Use case:** "Show me users who have access only through nested groups"

**2. vw_GraphGroupEligibleMembers** (if PIM table exists)
Shows only **PIM eligible** members:

```sql
SELECT * FROM vw_GraphGroupEligibleMembers
WHERE groupId = 'group-guid-here';
```

**Use case:** "Show me who can activate membership"

**3. vw_GraphGroupMembershipType**
Shows **all members** with a `membershipType` indicator:
- `'Direct'` - Explicitly added to the group
- `'Indirect'` - Access through nested groups only
- `'Eligible'` - PIM eligible (can activate)

```sql
-- See all membership types for a group
SELECT groupId, memberId, memberType, membershipType
FROM vw_GraphGroupMembershipType
WHERE groupId = 'group-guid-here';

-- Find all indirect members across all groups
SELECT * FROM vw_GraphGroupMembershipType
WHERE membershipType = 'Indirect';

-- Find eligible-but-not-active members
SELECT * FROM vw_GraphGroupMembershipType
WHERE membershipType = 'Eligible';
```

#### Examples

**Create views with defaults:**
```powershell
Initialize-FGGroupMembershipViews
```

**Recreate existing views:**
```powershell
Initialize-FGGroupMembershipViews -DropIfExists
```

**Custom table names:**
```powershell
Initialize-FGGroupMembershipViews `
    -DirectMembersTable "CustomDirectMembers" `
    -TransitiveMembersTable "CustomTransitiveMembers" `
    -EligibleMembersTable "CustomEligibleMembers"
```

#### Output Example

```
[14:45:10] Creating group membership analysis views...

[14:45:10] Creating view: vw_GraphGroupNestedMembers
  Purpose: Shows only members with indirect/nested access (not direct members)
  ✅ Created: vw_GraphGroupNestedMembers

[14:45:10] Creating view: vw_GraphGroupEligibleMembers
  Purpose: Shows only eligible members (PIM - can activate membership)
  ✅ Created: vw_GraphGroupEligibleMembers

[14:45:11] Creating view: vw_GraphGroupMembershipType
  Purpose: Shows all members with Direct/Indirect/Eligible indicator
  ✅ Created: vw_GraphGroupMembershipType

========================================
Views Created Successfully!
========================================
View 1: vw_GraphGroupNestedMembers
  - Shows only indirect/nested members
  - Excludes direct members

View 2: vw_GraphGroupEligibleMembers
  - Shows only eligible members (PIM)
  - Members who can activate access

View 3: vw_GraphGroupMembershipType
  - Shows all members (direct + indirect + eligible)
  - Includes membershipType column (Direct/Indirect/Eligible)
========================================
```

#### Query Examples

**Find users with indirect access only:**
```sql
SELECT u.displayName, u.userPrincipalName, g.displayName AS GroupName
FROM vw_GraphGroupNestedMembers m
JOIN GraphUsers u ON m.memberId = u.id
JOIN GraphGroups g ON m.groupId = g.id
WHERE u.accountEnabled = 1;
```

**Audit all membership types for a specific user:**
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

**Find groups where users are eligible but not active:**
```sql
SELECT
    g.displayName AS GroupName,
    COUNT(*) AS EligibleButInactiveCount
FROM vw_GraphGroupMembershipType m
JOIN GraphGroups g ON m.groupId = g.id
WHERE m.membershipType = 'Eligible'
GROUP BY g.displayName
ORDER BY EligibleButInactiveCount DESC;
```

---

## SQL Management Functions

### Invoke-FGSQLQuery

Executes SQL queries with a simple, easy-to-use syntax.

**Parameters:**
- `Query` - The SQL query to execute
- `AsScalar` (switch) - Returns a single scalar value (for COUNT, SUM, etc.)
- `AsNonQuery` (switch) - Returns rows affected (for INSERT, UPDATE, DELETE)

**Examples:**
```powershell
# Get all users
Invoke-FGSQLQuery -Query "SELECT * FROM dbo.GraphUsers"

# Get user count
$count = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.GraphUsers" -AsScalar

# Update a user
Invoke-FGSQLQuery -Query "UPDATE dbo.GraphUsers SET department = 'IT' WHERE id = '123'" -AsNonQuery
```

---

### Get-FGSQLTable

Lists all tables in the database with details like row counts, temporal status, and creation dates.

**Parameters:**
- `Schema` (optional) - Filter by schema name
- `Pattern` (optional) - Filter table names with wildcard pattern
- `IncludeSystemTables` (switch) - Include system temporal history tables

**Examples:**
```powershell
# List all tables
Get-FGSQLTable

# Filter by pattern
Get-FGSQLTable -Pattern "GraphUsers*"

# Filter by schema
Get-FGSQLTable -Schema "dbo"
```

---

### Clear-FGSQLTable

Clears all data from a table while preserving the table structure.

**Parameters:**
- `TableName` - Name of the table to clear
- `DeleteHistory` (switch) - Also clear the history table for temporal tables
- `Force` (switch) - Skip confirmation prompts

**Examples:**
```powershell
# Clear table (preserves history)
Clear-FGSQLTable -TableName "GraphUsers_Test"

# Clear table and history
Clear-FGSQLTable -TableName "GraphUsers_Test" -DeleteHistory -Force
```

**Note:** For temporal tables, this function automatically disables versioning, clears the data, and re-enables versioning.

---

### Remove-FGAzureSQLServer

**⚠️ DANGEROUS** - Permanently deletes an Azure SQL Server and all its databases.

**Parameters:**
- `SubscriptionId` - Azure Subscription ID
- `ResourceGroupName` - Resource Group name
- `ServerName` - SQL Server name to remove
- `Force` (switch) - Skip confirmation prompts (use with extreme caution!)

**Example:**
```powershell
Remove-FGAzureSQLServer `
    -SubscriptionId "12345..." `
    -ResourceGroupName "rg-test" `
    -ServerName "fg-test-sql-123"
```

**Safety Features:**
- Requires confirmation unless `-Force` is used
- Extra confirmation for production-sounding servers
- Shows all databases that will be deleted
- Automatically closes active connections

---

## Querying Temporal Data

After syncing, you can query your data in several ways:

### Running SQL Queries from PowerShell

You can query your data using SQL Server Management Studio, Azure Data Studio, or any SQL client.

Alternatively, use the `Invoke-FGSQLQuery` function for quick queries:

```powershell
# Simple query
Invoke-FGSQLQuery -Query "SELECT * FROM GraphUsers WHERE department = 'IT'"

# Get count
$userCount = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM GraphUsers" -AsScalar
```

### Current Data (Latest State)

```sql
-- Just query the table normally
SELECT * FROM GraphUsers;
```

### All History (Current + Historical)

```sql
-- Use the auto-created view
SELECT * FROM vw_GraphUsers_AllHistory
ORDER BY userPrincipalName, ValidFrom;
```

### Point-in-Time Query

```sql
-- See data as it existed on a specific date
SELECT *
FROM GraphUsers
FOR SYSTEM_TIME AS OF '2024-01-15 10:00:00';
```

### Changes Between Two Dates

```sql
-- See all changes between two dates
SELECT *
FROM GraphUsers
FOR SYSTEM_TIME BETWEEN '2024-01-01' AND '2024-01-31';
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

---

## Architecture & Design

### Code Reuse and Separation of Concerns

The FortigiGraph module follows a clean architecture with proper separation of concerns to ensure maintainability and code reuse.

#### Invoke-FGSQLCommand (Internal Helper)

All SQL functions use a centralized helper function `Invoke-FGSQLCommand` that manages the SQL connection lifecycle:

```powershell
# Internal pattern used by all SQL functions
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
- **Automatic Resource Management**: Connection open/close/dispose handled automatically
- **Consistent Error Handling**: All SQL operations have the same error handling pattern
- **No Code Duplication**: Connection lifecycle code written once, used everywhere
- **Focus on Business Logic**: Functions focus on what they do, not how to manage connections

#### Function Responsibilities

Each function has a single, clear responsibility:

**Connect-FGSQLServer**
- Retrieves Azure SQL Server details
- Manages firewall rules
- Prepares credentials
- **Delegates to** `New-FGSQLConnection` for actual connection
- **Delegates to** `Test-FGSQLConnection` for validation

**New-FGSQLConnection** (Low-level)
- Builds connection strings
- Validates credentials
- Stores connection details
- Uses helper to test connection

**Test-FGSQLConnection**
- Queries server information
- Formats and displays results
- Uses helper for connection management

**Initialize-FGSQLTable**
- Builds CREATE TABLE statements
- Creates temporal tables and history tables
- Creates helper views
- Uses helper for all SQL operations

**Sync-FGUser**
- Fetches data from Microsoft Graph
- Builds MERGE statements
- Manages sync transactions
- Uses helper for schema checks and sync operations

This architecture follows the **DRY (Don't Repeat Yourself)** principle and ensures that each function does one thing well while leveraging shared functionality.

---

## Supported Attributes

The module has built-in type mappings for common Graph user attributes:

### Identity Attributes
- `id`, `userPrincipalName`, `mail`, `mailNickname`
- `employeeId`, `employeeType`
- `onPremisesSamAccountName`, `onPremisesUserPrincipalName`
- `onPremisesDistinguishedName`, `onPremisesDomainName`

### Status Attributes
- `accountEnabled`, `onPremisesSyncEnabled`
- `userType`, `ageGroup`, `usageLocation`

### Personal Information
- `displayName`, `givenName`, `surname`
- `preferredLanguage`

### Organization
- `companyName`, `department`, `jobTitle`
- `officeLocation`, `city`, `state`, `country`, `postalCode`, `streetAddress`

### Contact
- `mobilePhone`, `businessPhones`

### Dates
- `createdDateTime`, `lastPasswordChangeDateTime`, `lastSignInDateTime`

### Relations
- `managerId` - Requires special handling (automatically fetched via `$expand`)

### Custom Attributes
Any attribute not in the list above will use `NVARCHAR(MAX)` as the SQL data type.

---

## Error Handling

### Connection Issues

If you can't connect to SQL Server:
```powershell
# Check firewall
Connect-FGSQLServer -SubscriptionId $sub -ResourceGroupName $rg -ServerName $server -UpdateFirewall

# Force reconnect
Connect-FGSQLServer -SubscriptionId $sub -ResourceGroupName $rg -ServerName $server -Force
```

### Expired Token

If your Graph token expires:
```powershell
Get-FGAccessToken -TenantId "your-tenant-id" -ClientId "your-client-id"
```

### Schema Conflicts

If you need to completely rebuild the table:
```powershell
Sync-FGUser -RecreateTable
# WARNING: This loses all history!
```

---

## Best Practices

### 1. Regular Syncs

Set up a scheduled task to sync regularly:
```powershell
# Daily sync script
Get-FGAccessToken -TenantId $tenantId -ClientId $clientId
Connect-FGSQLServer -SubscriptionId $sub -ResourceGroupName $rg -ServerName $server
Sync-FGUser
```

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

### 3. Filtered Syncs

Use filters to reduce data volume:
```powershell
# Only active employees
Sync-FGUser -Filter "accountEnabled eq true and userType eq 'Member'"
```

### 4. Multiple Tables

Sync different user sets to different tables:
```powershell
# All users
Sync-FGUser -TableName "AllUsers"

# Active users only
Sync-FGUser -TableName "ActiveUsers" -Filter "accountEnabled eq true"

# Guests only
Sync-FGUser -TableName "GuestUsers" -Filter "userType eq 'Guest'"
```

---

## Debugging

For debugging Graph operations, set:

```powershell
$Global:DebugMode = 'T'   # Token operations
$Global:DebugMode = 'G'   # GET requests
$Global:DebugMode = 'P'   # PATCH and POST requests
$Global:DebugMode = 'D'   # DELETE requests
$Global:DebugMode = 'PD'  # Combination
```

---

## Testing and Security

### Integration Tests

The module includes comprehensive integration tests that validate all functionality end-to-end. See [_Test/README-Integration-Tests.md](_Test/README-Integration-Tests.md) for details on:
- Running integration tests
- Test configuration
- What each test validates
- Parallel testing

### Secure Credential Storage

The test scripts support encrypted credential storage using Windows DPAPI. See [_Test/README-Secure-Credentials.md](_Test/README-Secure-Credentials.md) for:
- How secure credentials work
- Setting up encrypted credentials
- Managing stored credentials
- Security considerations

### SQL Management

Additional SQL management utilities are available for testing and database administration. See [_Test/README-SQL-Management.md](_Test/README-SQL-Management.md) for detailed documentation on:
- `Get-FGSQLTable` - List all tables with details
- `Clear-FGSQLTable` - Clear table data for testing
- `Remove-FGAzureSQLServer` - Remove test SQL Servers
- `Invoke-FGSQLQuery` - Simple query execution
- Common workflows and best practices

### Quick Start Guide

For a quick overview of all features and getting started, see [_Test/QUICK-START.md](_Test/QUICK-START.md).

---

## Requirements

- PowerShell 5.1 or later
- Az PowerShell module (for Azure SQL operations)
- Microsoft Graph API permissions (User.Read.All minimum)
- Azure subscription (for SQL Server)

---

## License

(Your license information here)

## Support

For issues or questions, please open an issue on GitHub.
