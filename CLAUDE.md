# FortigiGraph - AI Assistant Development Guide

## Project Overview

FortigiGraph is a PowerShell module that simplifies working with Microsoft Graph API and syncing data to Azure SQL databases with temporal versioning. It provides a comprehensive set of cmdlets for managing Azure AD/Entra ID resources (users, groups, devices, access packages, catalogs, access reviews) and persisting this data to SQL with automatic change tracking.

**Key Information:**
- **Language:** PowerShell
- **Primary Purpose:** Microsoft Graph API wrapper with Azure SQL data persistence
- **Author:** Wim van den Heijkant
- **Company:** Fortigi
- **GitHub:** https://github.com/Fortigi/FortigiGraph
- **Distribution:** PowerShell Gallery
- **Current Version:** 1.1.20250515.1420

## Major Features

### 1. Microsoft Graph API Integration
- Easy authentication (service principal & interactive)
- Automatic token refresh
- Pagination handling
- CRUD operations for Azure AD/Entra ID resources

### 2. Azure SQL Integration (NEW in dev)
- **Temporal Tables**: Automatic version history tracking for all data changes
- **Point-in-Time Queries**: Query data as it existed at any time
- **User Sync**: Sync Microsoft Graph users to SQL with automatic schema detection
- **Transaction-based**: Performance-optimized with batch operations
- **Automatic Schema Evolution**: Add new columns without recreating tables

### 3. Comprehensive Testing
- Integration tests with parallel execution support
- Secure credential storage using Windows DPAPI
- Automated cleanup
- Multiple environment support

## Repository Structure

```
FortigiGraph/
├── Base/                   # Core authentication and HTTP request functions
│   ├── Get-FGAccessToken*.ps1          # Token acquisition (3 variants)
│   ├── Invoke-FGGetRequest.ps1         # HTTP GET with auto-pagination
│   ├── Invoke-FGPostRequest.ps1        # HTTP POST wrapper
│   ├── Invoke-FGPatchRequest.ps1       # HTTP PATCH wrapper
│   ├── Invoke-FGPutRequest.ps1         # HTTP PUT wrapper
│   ├── Invoke-FGDeleteRequest.ps1      # HTTP DELETE wrapper
│   ├── Confirm-FGAccessTokenValidity.ps1
│   ├── Save-FGToken.ps1 / Read-FGToken.ps1
│   └── ...                             # ~17 base functions
│
├── Generic/                # Microsoft Graph API operations
│   ├── Get-FG*.ps1         # Retrieve operations (~45 functions)
│   ├── New-FG*.ps1         # Create operations
│   ├── Set-FG*.ps1         # Update operations
│   ├── Add-FG*.ps1         # Add operations (members, resources)
│   ├── Remove-FG*.ps1      # Delete/remove operations
│   └── Sync-FGUser.ps1     # ⭐ NEW: Sync users to SQL
│
├── SQL/                    # ⭐ NEW: Azure SQL operations
│   ├── Invoke-FGSQLCommand.ps1         # Helper for connection lifecycle
│   ├── New-FGAzureSQLServer.ps1        # Create SQL Server + Database
│   ├── Connect-FGSQLServer.ps1         # Connect with firewall mgmt
│   ├── New-FGSQLConnection.ps1         # Low-level connection
│   ├── Test-FGSQLConnection.ps1        # Validate connection
│   ├── Initialize-FGSQLTable.ps1       # Create temporal tables
│   ├── Invoke-FGSQLQuery.ps1           # Simple query execution
│   ├── Get-FGSQLTable.ps1              # List tables with details
│   ├── Clear-FGSQLTable.ps1            # Clear table data
│   └── Remove-FGAzureSQLServer.ps1     # Delete SQL Server
│
├── Specific/               # Higher-level helper functions
│   └── Confirm-FG*.ps1     # Idempotent confirmation/creation (~10 functions)
│
├── _Test/                  # ⭐ NEW: Testing infrastructure
│   ├── Test-Integration.ps1            # Full end-to-end test
│   ├── Test-Simple.ps1                 # Quick diagnostic
│   ├── SecureConfig.ps1                # Encrypted credential storage
│   ├── Manage-Credentials.ps1          # Credential management
│   ├── README-Integration-Tests.md     # Test documentation
│   ├── README-SQL-Management.md        # SQL functions guide
│   ├── README-Secure-Credentials.md    # Security documentation
│   └── QUICK-START.md                  # Quick reference
│
├── _Build/                 # Build and publishing scripts
│   └── CreatePSD.ps1       # Module manifest generation
│
├── FortigiGraph.psm1       # Module entry point (auto-loads all functions)
├── FortigiGraph.psd1       # Module manifest
├── README.md               # User documentation (comprehensive)
└── .gitignore              # ⭐ NEW: Protects test configs
```

### Function Count by Category

| Category | Count | Purpose |
|----------|-------|---------|
| **Base** | ~17 | Authentication, HTTP operations, token management |
| **Generic** | ~47 | Graph API CRUD operations (including Sync-FGUser) |
| **SQL** | 10 | Azure SQL database operations |
| **Specific** | ~10 | High-level idempotent helpers |
| **Test** | 4 | Integration testing & credential management |
| **Total** | **~88 functions** | **~4,753 lines of code** |

## Architecture & Design Patterns

### 1. Module Loading Strategy

The module uses automatic function loading via dot-sourcing in `FortigiGraph.psm1`:

```powershell
# Get public and private function definition files
$base    = @( Get-ChildItem -Path (Join-Path $PSScriptRoot 'base') -Include *.ps1 -Recurse )
$generic = @( Get-ChildItem -Path (Join-Path $PSScriptRoot 'generic') -Include *.ps1 -Recurse )
$specific = @( Get-ChildItem -Path (Join-Path $PSScriptRoot 'specific') -Include *.ps1 -Recurse )
$SQL = @( Get-ChildItem -Path (Join-Path $PSScriptRoot 'SQL') -Include *.ps1 -Recurse )

# Dot source all function files
foreach ($import in @($base + $generic + $specific + $SQL)) {
    . $import.fullname
}
```

### 2. Global State Management

#### Graph API State
- `$Global:AccessToken` - Current OAuth access token
- `$Global:ClientId` - Azure AD application client ID
- `$Global:ClientSecret` - Application secret (for service principal auth)
- `$Global:TenantId` - Azure AD tenant ID
- `$Global:RefreshToken` - Refresh token (for interactive auth)
- `$Global:DebugMode` - Debug flag ('T', 'G', 'P', 'D' or combinations)

#### SQL State (NEW)
- `$Global:FGSQLConnectionString` - SQL Server connection string
- `$Global:FGSQLServerName` - Connected server name
- `$Global:FGSQLDatabaseName` - Connected database name

### 3. Function Naming Convention

All functions follow PowerShell best practices:
- **Prefix:** `FG` (FortigiGraph) for all exported functions
- **Aliases:** Each function has an alias without the `FG` prefix (e.g., `Get-FGGroup` → `Get-Group`)
- **Verbs:** Standard PowerShell verbs (Get, New, Set, Add, Remove, Confirm, Invoke, Connect, Test, Initialize, Sync, Clear)
- **Pattern:** `Verb-FGNoun`

### 4. Authentication Flow (Graph API)

1. Call `Get-FGAccessToken` (service principal) or `Get-FGAccessTokenInteractive` (delegated)
2. Token stored in `$Global:AccessToken`
3. All `Invoke-FGGetRequest`/Post/Patch/etc. automatically:
   - Check token validity via `Confirm-FGAccessTokenValidity`
   - Auto-refresh if expired using stored credentials
   - Include bearer token in Authorization header

### 5. SQL Connection Management (NEW)

#### The Helper Pattern: `Invoke-FGSQLCommand`

**This is a critical design pattern that all SQL functions use.**

All SQL functions delegate connection lifecycle management to `Invoke-FGSQLCommand`:

```powershell
# Internal pattern used by all SQL functions
Invoke-FGSQLCommand -ScriptBlock {
    param($connection)

    # Your SQL operations here
    # Connection is already open and will be automatically closed
    $cmd = $connection.CreateCommand()
    $cmd.CommandText = "SELECT COUNT(*) FROM Users"
    return $cmd.ExecuteScalar()
}
```

**Benefits:**
- ✅ **Automatic Resource Management**: Connection open/close/dispose handled automatically
- ✅ **Consistent Error Handling**: All SQL operations have the same error handling pattern
- ✅ **No Code Duplication**: Connection lifecycle code written once, used everywhere
- ✅ **Focus on Business Logic**: Functions focus on what they do, not how to manage connections
- ✅ **Proper Cleanup**: Even if errors occur, connections are properly disposed

**Example from a real function:**

```powershell
function Get-FGSQLTable {
    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        $query = "SELECT name, create_date FROM sys.tables"
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = $query

        $reader = $cmd.ExecuteReader()
        # Process results...
        return $results
    }
}
```

### 6. Temporal Tables Architecture (NEW)

FortigiGraph uses SQL Server's temporal table feature for automatic change tracking:

**What happens when you create a table:**
1. Main table created (e.g., `GraphUsers`)
2. History table auto-created (e.g., `GraphUsers_History`)
3. System columns added: `ValidFrom`, `ValidTo`
4. Helper view created (e.g., `vw_GraphUsers_AllHistory`)

**Benefits:**
- Every change is automatically tracked (who, what, when)
- Point-in-time queries: "Show me data as of Jan 15, 2025"
- Audit trail included automatically
- Zero code changes needed for tracking

### 7. Pagination Handling (Graph API)

All GET requests automatically handle Microsoft Graph pagination:

```powershell
# In Invoke-FGGetRequest.ps1
$ReturnValue = $Result.value

# Follow @odata.nextLink automatically
While ($Result.'@odata.nextLink') {
    $Result = Invoke-RestMethod -Method Get -Uri $Result.'@odata.nextLink' -Headers @{"Authorization" = "Bearer $AccessToken"}
    $ReturnValue += $Result.value
}
```

### 8. Debug Mode

Debug output controlled via `$Global:DebugMode`:
- `'T'` - Token operations
- `'G'` - GET requests
- `'P'` - POST/PATCH requests
- `'D'` - DELETE requests
- Combine: `'GP'`, `'TPD'`, etc.

## Key Conventions for AI Assistants

### 1. File Organization

**When adding new functions:**

| Folder | Purpose | Example |
|--------|---------|---------|
| **Base/** | Core HTTP operations and authentication | `Invoke-FGGetRequest.ps1` |
| **Generic/** | Direct Microsoft Graph API wrappers (1:1 mapping) | `Get-FGUser.ps1`, `Sync-FGUser.ps1` |
| **SQL/** | Azure SQL database operations | `Connect-FGSQLServer.ps1`, `Initialize-FGSQLTable.ps1` |
| **Specific/** | Business logic combining multiple Generic functions | `Confirm-FGGroup.ps1` |
| **_Test/** | Testing scripts and documentation | `Test-Integration.ps1` |

**File naming:** `Verb-FGResourceAction.ps1` (e.g., `Get-FGGroupMember.ps1`)

### 2. Function Structure Templates

#### Graph API Function Template

```powershell
function Get-FGResource {
    [alias("Get-Resource")]
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter(Mandatory = $false)]
        [string]$Filter
    )

    # Build URI
    If ($Id) {
        $URI = "https://graph.microsoft.com/beta/resources/$Id"
    }
    ElseIf ($Filter) {
        $URI = "https://graph.microsoft.com/beta/resources?`$filter=$Filter"
    }
    Else {
        $URI = "https://graph.microsoft.com/beta/resources"
    }

    # Call base function (handles pagination, token refresh, etc.)
    $ReturnValue = Invoke-FGGetRequest -URI $URI
    return $ReturnValue
}
```

#### SQL Function Template

```powershell
function Get-FGSQLResource {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $false)]
        [string]$Filter
    )

    # Use the helper pattern - it handles connection lifecycle
    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        # Build and execute query
        $query = "SELECT * FROM dbo.Resources"
        if ($Filter) {
            $query += " WHERE $Filter"
        }

        $cmd = $connection.CreateCommand()
        $cmd.CommandText = $query

        # Execute and return results
        $reader = $cmd.ExecuteReader()
        # ... process results ...

        return $results
    }
}
```

### 3. Parameter Naming Conventions

- Use **Aliases** for common parameter names:
  - `[Alias("GroupName","Name")]` for `$DisplayName`
  - `[Alias("ObjectId")]` for `$Id`
- Prefer `DisplayName` over `Name` as primary parameter name
- Use `Id` (singular) not `Ids` for object identifiers
- Use `TableName` for SQL table parameters
- Use `SubscriptionId`, `ResourceGroupName`, `ServerName` for Azure resources

### 4. Graph API Endpoint Selection

- **Default to `/beta`** endpoint unless specific reason to use `/v1.0`
- Example: `https://graph.microsoft.com/beta/groups`
- Beta endpoint has more features and newer properties

### 5. Error Handling

#### Graph API Functions
- Use `Throw` for critical errors
- Provide descriptive error messages
- Let `Invoke-FG*Request` functions handle HTTP errors (already implemented)

#### SQL Functions
- `Invoke-FGSQLCommand` automatically handles connection errors
- Use `try/catch` only for business logic errors
- Throw meaningful errors with context

### 6. Return Values

#### Graph API Functions
- Return raw Graph API objects (don't transform)
- Let `Invoke-FGGetRequest` handle `.value` extraction
- Return `$null` if no results (don't return empty arrays)

#### SQL Functions
- Return objects with properties (use `PSCustomObject`)
- Format data for PowerShell consumption
- Include metadata when useful (row counts, status, etc.)

### 7. Confirm-FG* Functions (Specific/)

These are idempotent functions that ensure a resource exists:

```powershell
function Confirm-FGGroup {
    Param([string]$GroupName, [string]$GroupDescription)

    # 1. Try to get existing resource
    $Group = Get-FGGroup -GroupName $GroupName

    # 2. If exists, optionally update
    if ($Group.count -eq 1) {
        Write-Host "Confirmed Group exists: $GroupName" -ForegroundColor Green
        # Update if needed
        if ($GroupDescription -and $Group.Description -ne $GroupDescription) {
            Set-FGGroup -ObjectId $Group.id -Description $GroupDescription
        }
    }
    # 3. If doesn't exist, create it
    else {
        Write-Host "Creating Group: $GroupName" -ForegroundColor Yellow
        New-FGGroup -DisplayName $GroupName -Description $GroupDescription

        # Wait for propagation and fetch with retry
        $Count = 0
        while (($Group -eq $null) -and ($Count -lt 6)) {
            Start-Sleep -Seconds 5
            $Group = Get-FGGroup -GroupName $GroupName
            $Count++
        }
    }

    return $Group
}
```

### 8. Write-Host Usage (User Feedback)

Use color-coded output for user feedback:

- **Green** (`-ForegroundColor Green`): Confirmation/success messages
- **Yellow** (`-ForegroundColor Yellow`): Warning/action messages
- **Blue** (`-ForegroundColor Blue`): Debug messages (when `$Global:DebugMode` is set)
- **Cyan** (`-ForegroundColor Cyan`): Progress/informational messages
- **Red** (default for errors): Error messages

**Example:**
```powershell
Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Syncing users to SQL Server..." -ForegroundColor Cyan
Write-Host "  Progress: 100/234 users (48.2 users/sec)" -ForegroundColor Cyan
Write-Host "Sync Complete!" -ForegroundColor Green
```

## Development Workflow

### Making Changes

1. **Create/Edit Functions:**
   - Add new `.ps1` files to appropriate folder (Base/Generic/SQL/Specific)
   - Follow naming conventions and structure templates
   - Include aliases for backward compatibility
   - Add proper parameter documentation with `[Parameter()]` attributes
   - Test locally: `Import-Module .\FortigiGraph.psd1 -Force`

2. **Testing:**
   - Use the integration test suite: `_Test/Test-Integration.ps1`
   - Add tests for new functionality
   - Run quick diagnostic: `_Test/Test-Simple.ps1`
   - Manual testing:
     ```powershell
     Import-Module .\FortigiGraph.psd1 -Force
     Get-FGAccessToken -TenantId "..." -ClientId "..."
     Connect-FGSQLServer -SubscriptionId "..." -ResourceGroupName "..." -ServerName "..."
     # Test your function
     ```

3. **Version Updates:**
   - Version format: `Major.Minor.yyyyMMdd.HHmm`
   - Update in `_Build/CreatePSD.ps1`:
     ```powershell
     $VersionMajor = "1"
     $VersionMinor = "1"
     ```
   - Script auto-generates timestamp

4. **Building the Module:**
   - Run `_Build/CreatePSD.ps1` to regenerate `FortigiGraph.psd1`
   - This script also publishes to PowerShell Gallery (requires API key)

5. **Git Workflow:**
   - Work on `dev` branch for new features
   - Create feature branches: `feature/feature-name`
   - Commit with descriptive messages: `git commit -m "Add SQL temporal table support"`
   - Push to remote: `git push -u origin branch-name`
   - Merge to main after testing

### Common Development Tasks

#### Adding a New Graph GET Function

1. Create file: `Generic/Get-FGNewResource.ps1`
2. Use template:
   ```powershell
   function Get-FGNewResource {
       [alias("Get-NewResource")]
       [cmdletbinding()]
       Param(
           [Parameter(Mandatory = $false)]
           [string]$Id
       )

       If ($Id) {
           $URI = "https://graph.microsoft.com/beta/resources/$Id"
       } Else {
           $URI = "https://graph.microsoft.com/beta/resources"
       }

       $ReturnValue = Invoke-FGGetRequest -URI $URI
       return $ReturnValue
   }
   ```

#### Adding a New SQL Function

1. Create file: `SQL/Verb-FGSQLResource.ps1`
2. **Always use `Invoke-FGSQLCommand` helper:**
   ```powershell
   function Get-FGSQLResource {
       [CmdletBinding()]
       Param(
           [Parameter(Mandatory = $false)]
           [string]$ResourceName
       )

       Invoke-FGSQLCommand -ScriptBlock {
           param($connection)

           $cmd = $connection.CreateCommand()
           $cmd.CommandText = "SELECT * FROM Resources WHERE Name = @Name"
           $cmd.Parameters.AddWithValue("@Name", $ResourceName)

           $reader = $cmd.ExecuteReader()
           # Process results...

           return $results
       }
   }
   ```

#### Adding Helper/Confirm Function

1. Create file: `Specific/Confirm-FGResource.ps1`
2. Implement idempotent logic (check exists → create/update)
3. Use color-coded `Write-Host` for user feedback
4. Include retry logic for propagation delays

#### Adding Integration Tests

1. Edit: `_Test/Test-Integration.ps1`
2. Add test section:
   ```powershell
   Write-Host "`n=== Testing New Feature ===" -ForegroundColor Cyan
   try {
       # Your test code here
       Write-Host "  ✅ Test passed" -ForegroundColor Green
   }
   catch {
       Write-Host "  ❌ Test failed: $_" -ForegroundColor Red
       throw
   }
   ```

## Microsoft Graph API Reference

### Common Graph Endpoints Used

```powershell
# Groups
/beta/groups
/beta/groups/{id}/members

# Users
/beta/users
/beta/users/{id}/manager

# Devices
/beta/devices

# Applications
/beta/applications
/beta/servicePrincipals

# Access Packages (Identity Governance)
/beta/identityGovernance/entitlementManagement/accessPackages
/beta/identityGovernance/entitlementManagement/catalogs
/beta/identityGovernance/entitlementManagement/accessPackageAssignments

# Access Reviews
/beta/identityGovernance/accessReviews/definitions
/beta/identityGovernance/accessReviews/definitions/{id}/instances
```

### Filter Syntax Examples

```powershell
# Display name filter
$URI = 'https://graph.microsoft.com/beta/groups?$filter=' + "displayName eq '$DisplayName'"

# ID filter
$URI = 'https://graph.microsoft.com/beta/groups?$filter=' + "id eq '$Id'"

# Multiple filters
$URI = 'https://graph.microsoft.com/beta/users?$filter=' + "userPrincipalName eq '$UPN' and accountEnabled eq true"

# Starts with
$URI = 'https://graph.microsoft.com/beta/users?$filter=' + "startswith(displayName,'John')"
```

### Expanding Properties

```powershell
# Expand members
$URI = "https://graph.microsoft.com/beta/groups/$GroupId/members"

# Expand with select
$URI = "https://graph.microsoft.com/beta/groups/$GroupId?`$expand=members(`$select=id,displayName)"

# Expand manager (used in Sync-FGUser)
$URI = "https://graph.microsoft.com/beta/users?`$expand=manager(`$select=id)"
```

### Select Specific Properties

```powershell
# Select only needed properties (performance optimization)
$URI = "https://graph.microsoft.com/beta/users?`$select=id,userPrincipalName,displayName,department"
```

## SQL Server Temporal Tables

### Understanding Temporal Tables

Temporal tables automatically track the full history of data changes:

**Structure:**
- Main table: Current data (e.g., `GraphUsers`)
- History table: All previous versions (e.g., `GraphUsers_History`)
- System columns: `ValidFrom`, `ValidTo` (managed automatically)

**When you update/delete a row:**
1. Old version moved to history table
2. Current table updated with new data
3. Timestamps recorded automatically

### Querying Temporal Data

```sql
-- Current data (normal query)
SELECT * FROM GraphUsers;

-- All history (current + historical)
SELECT * FROM GraphUsers FOR SYSTEM_TIME ALL;

-- Point-in-time query
SELECT * FROM GraphUsers FOR SYSTEM_TIME AS OF '2025-01-15 10:00:00';

-- Changes between dates
SELECT * FROM GraphUsers FOR SYSTEM_TIME BETWEEN '2025-01-01' AND '2025-01-31';

-- User change history
SELECT userPrincipalName, department, ValidFrom, ValidTo
FROM GraphUsers FOR SYSTEM_TIME ALL
WHERE userPrincipalName = 'john.doe@contoso.com'
ORDER BY ValidFrom DESC;
```

### Schema Evolution

Adding columns to temporal tables requires special handling:

```powershell
# The module handles this automatically in Sync-FGUser:
1. Disable system versioning
2. Add column to main table
3. Add column to history table
4. Re-enable system versioning
```

**Example from `Sync-FGUser`:**
```powershell
# User adds new attribute
Sync-FGUser -AdditionalAttributes @('employeeType')

# Output:
# [14:25:10] Found 1 new attribute(s) to add: employeeType
# [14:25:10] Adding columns to existing table...
# [14:25:10]   Adding column: employeeType (NVARCHAR(255))
# [14:25:11] Schema updated successfully
```

## Important Notes for AI Assistants

### DO:
- ✅ Follow existing naming conventions (`Verb-FGNoun`)
- ✅ Add aliases without `FG` prefix
- ✅ Use `Invoke-FG*Request` functions (never call `Invoke-RestMethod` directly for Graph)
- ✅ Use `Invoke-FGSQLCommand` helper for all SQL operations
- ✅ Handle pagination automatically (already done in `Invoke-FGGetRequest`)
- ✅ Use `/beta` endpoint unless told otherwise
- ✅ Include parameter validation (`[ValidateNotNullOrEmpty()]`)
- ✅ Return raw Graph objects (don't transform)
- ✅ Use `[cmdletbinding()]` for all functions
- ✅ Place one function per file
- ✅ Test with integration tests
- ✅ Include comprehensive comment-based help
- ✅ Use color-coded Write-Host for user feedback
- ✅ Handle temporal table schema changes properly
- ✅ Use transactions for batch SQL operations
- ✅ Provide progress feedback for long operations

### DON'T:
- ❌ Don't call `Invoke-RestMethod` directly for Graph (use `Invoke-FG*Request` wrappers)
- ❌ Don't manage SQL connections manually (use `Invoke-FGSQLCommand` helper)
- ❌ Don't transform/modify Graph API response objects
- ❌ Don't add complex error handling (base functions handle this)
- ❌ Don't hardcode credentials or tokens
- ❌ Don't create multi-function files
- ❌ Don't use `Write-Output` (use `return` directly)
- ❌ Don't add comments in Dutch (use English only)
- ❌ Don't add dependencies on external modules (except Az)
- ❌ Don't commit test configuration files (protected by .gitignore)
- ❌ Don't modify temporal tables without disabling versioning first
- ❌ Don't forget to re-enable versioning after schema changes
- ❌ Don't use `TRUNCATE` on temporal tables (use `DELETE` instead)

### When Extending the Module:

1. **Check if function already exists:** Search all folders first
2. **Determine correct location:**
   - Direct Graph API call → `Generic/`
   - Azure SQL operation → `SQL/`
   - Combines multiple operations → `Specific/`
   - Core HTTP/auth → `Base/` (rarely needed)
3. **Follow the pattern:** Look at similar existing functions
4. **Use the helpers:**
   - Graph API → `Invoke-FGGetRequest`, `Invoke-FGPostRequest`, etc.
   - SQL → `Invoke-FGSQLCommand`
5. **Test thoroughly:**
   - Add to integration tests
   - Test with real Graph API and SQL Server
6. **Update version:** Modify `_Build/CreatePSD.ps1` if publishing

## Key Functions Reference

### Authentication

```powershell
# Service Principal (Automated)
Get-FGAccessToken -ClientId "..." -ClientSecret "..." -TenantId "..."

# Interactive (User Delegation)
Get-FGAccessTokenInteractive -ClientId "..." -TenantId "..."

# Using Existing MSAL Token
Use-FGExistingMSALToken -MSALToken $token
```

### SQL Server Setup

```powershell
# Create SQL Server
New-FGAzureSQLServer `
    -SubscriptionId "..." `
    -ResourceGroupName "rg-graph" `
    -ServerName "mygraphsql" `
    -AllowCurrentIP `
    -AutoConnect

# Connect to Existing Server
Connect-FGSQLServer `
    -SubscriptionId "..." `
    -ResourceGroupName "rg-graph" `
    -ServerName "mygraphsql" `
    -UpdateFirewall

# Test Connection
Test-FGSQLConnection
```

### User Sync (Main Feature)

```powershell
# Sync with defaults (16 attributes)
Sync-FGUser

# Add extra attributes
Sync-FGUser -AdditionalAttributes @('officeLocation', 'city', 'employeeType')

# Custom attributes only
Sync-FGUser -Attributes @('id', 'userPrincipalName', 'mail', 'displayName')

# Filter users
Sync-FGUser -Filter "accountEnabled eq true"

# Custom table name
Sync-FGUser -TableName "ActiveUsers" -Filter "accountEnabled eq true"
```

### SQL Management

```powershell
# List all tables
Get-FGSQLTable

# Query data
Invoke-FGSQLQuery -Query "SELECT * FROM GraphUsers WHERE department = 'IT'"

# Get count
$count = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM GraphUsers" -AsScalar

# Clear table (preserves history)
Clear-FGSQLTable -TableName "GraphUsers_Test"

# Clear table and history
Clear-FGSQLTable -TableName "GraphUsers_Test" -DeleteHistory -Force

# Remove SQL Server
Remove-FGAzureSQLServer -SubscriptionId "..." -ResourceGroupName "..." -ServerName "..."
```

## Testing Infrastructure

### Test Files

| File | Purpose | Runtime |
|------|---------|---------|
| `Test-Simple.ps1` | Quick diagnostic | ~10 seconds |
| `Test-Integration.ps1` | Full end-to-end test | ~5-10 minutes |
| `Manage-Credentials.ps1` | Credential management | Instant |

### Running Tests

```powershell
# Quick diagnostic
.\_Test\Test-Simple.ps1 -ConfigFile _Test\config.test.json

# Full integration test
.\_Test\Test-Integration.ps1 -ConfigFile _Test\config.test.json

# Keep resources for inspection
.\_Test\Test-Integration.ps1 -ConfigFile _Test\config.test.json -SkipCleanup

# Manage stored credentials
.\_Test\Manage-Credentials.ps1 -ConfigFile _Test\config.test.json
```

### Secure Credentials

- Passwords encrypted using Windows DPAPI
- Test scripts prompt for passwords on first run
- Encrypted credentials stored in config file
- **Never commit config files** (protected by .gitignore)

## Troubleshooting

### Debug Mode

Enable debug output to see API calls:

```powershell
$Global:DebugMode = 'G'     # GET requests
$Global:DebugMode = 'P'     # POST/PATCH requests
$Global:DebugMode = 'D'     # DELETE requests
$Global:DebugMode = 'T'     # Token operations
$Global:DebugMode = 'GP'    # Multiple categories
```

### Common Issues

**Graph API:**
1. **"No Access Token found"** → Run `Get-FGAccessToken` first
2. **Token expired** → Automatic refresh should handle this
3. **Insufficient permissions** → Check Graph API permissions in Azure AD app
4. **Pagination not working** → Ensure using `Invoke-FGGetRequest`

**SQL:**
1. **Connection fails** → Use `Connect-FGSQLServer -UpdateFirewall`
2. **Table already exists** → Use `-RecreateTable` switch (loses history!)
3. **Temporal table error** → Don't modify schema without disabling versioning
4. **Can't truncate** → Use `DELETE` instead of `TRUNCATE` on temporal tables

## Publishing Workflow

**Note:** Only the module maintainer should publish to PowerShell Gallery.

1. Update version in `_Build/CreatePSD.ps1`
2. Run `_Build/CreatePSD.ps1`
3. Provide PowerShell Gallery API key when prompted
4. Module is automatically published

## Related Resources

- **Microsoft Graph API Docs:** https://learn.microsoft.com/en-us/graph/api/overview
- **PowerShell Module Best Practices:** https://learn.microsoft.com/en-us/powershell/scripting/developer/module/writing-a-windows-powershell-module
- **Graph API Permissions:** https://learn.microsoft.com/en-us/graph/permissions-reference
- **SQL Temporal Tables:** https://learn.microsoft.com/en-us/sql/relational-databases/tables/temporal-tables
- **Azure SQL Documentation:** https://learn.microsoft.com/en-us/azure/azure-sql/

## Summary

FortigiGraph is a well-architected PowerShell module with clear separation of concerns:

- **Base** - Authentication and HTTP operations
- **Generic** - Direct Graph API wrappers + user sync
- **SQL** - Azure SQL operations with temporal tables
- **Specific** - Higher-level business logic

**Key Architectural Decisions:**

1. **Helper Pattern**: `Invoke-FGSQLCommand` manages all SQL connections
2. **Temporal Tables**: Automatic change tracking with zero code overhead
3. **Automatic Pagination**: Graph API pagination handled transparently
4. **Token Refresh**: Automatic token renewal
5. **Schema Evolution**: Add columns without recreating tables
6. **Secure Testing**: Encrypted credentials with DPAPI
7. **Comprehensive Documentation**: Multiple README files for different aspects

**When working with this codebase:**
- Always follow the established patterns
- Use the existing helper functions
- Maintain consistency with naming conventions
- Test with the integration test suite
- Keep it simple - avoid over-engineering

The module is designed for ease of use, maintainability, and production reliability.
