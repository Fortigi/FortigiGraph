# FortigiGraph Integration Tests

## Overview

The integration test suite validates the complete FortigiGraph workflow end-to-end:

- ✅ Azure and Graph connectivity
- ✅ SQL Server creation and connection
- ✅ Table creation with different property sets
- ✅ Data synchronization from Microsoft Graph
- ✅ Query execution and temporal table features
- ✅ Automatic cleanup

## Prerequisites

1. **Azure Subscription** - With permissions to create SQL Servers
2. **Microsoft Graph App Registration** - With User.Read.All permission
3. **PowerShell Modules:**
   ```powershell
   Install-Module Az -Scope CurrentUser
   ```

## Setup

### Step 1: Create Configuration File

Copy the template and fill in your test environment details:

```powershell
cd _Test
cp config.test.json.template config.test.json
```

**⚠️ SECURITY WARNING:**
- **NEVER commit config files to Git** - They contain sensitive credentials
- The `.gitignore` already excludes `_Test/*.json` to protect you
- Use unique, strong passwords for test SQL servers
- Consider using Azure Key Vault for production scenarios
- Rotate secrets regularly, especially after testing

Edit `config.test.json`:

```json
{
  "Azure": {
    "TenantId": "optional-azure-tenant-id",
    "SubscriptionId": "12345678-1234-1234-1234-123456789012",
    "ResourceGroupName": "rg-fortigraph-test",
    "Location": "northeurope",
    "SQLServerName": "fg-test-sql-abc123",
    "DatabaseName": "GraphDataTest",
    "AdminUsername": "sqladmin"
  },
  "Graph": {
    "TenantId": "your-tenant-id",
    "ClientId": "your-app-client-id",
    "ClientSecret": "your-secret-or-leave-empty"
  },
  "TestData": {
    "MaxUsersToSync": 10
  }
}
```

**Configuration Notes:**

- **Azure.TenantId** (Optional): Use this if your Azure resources are in a different tenant than your Graph API
  - If specified: Azure operations use this tenant, Graph API uses Graph.TenantId
  - If omitted: Both Azure and Graph operations use Graph.TenantId (backward compatible)
  - Common in multi-tenant environments or when using Azure Lighthouse

**Important:**
- Use a **unique SQL server name** (must be globally unique in Azure)
- **DO NOT use production credentials** - Create dedicated test credentials
- Store passwords securely - Consider environment variables instead of config files

### Step 2: Login to Azure

```powershell
Connect-AzAccount
```

## Running Tests

### Full Test Suite (with cleanup)

```powershell
pwsh -File Test-Integration.ps1
```

This will:
1. Remove any existing test SQL Server
2. Create new SQL Server and database
3. Test all sync scenarios
4. Clean up resources at the end

### Keep Resources After Testing

```powershell
pwsh -File Test-Integration.ps1 -SkipCleanup
```

Useful for:
- Inspecting the database after tests
- Debugging issues
- Manual verification

### Verbose Output

```powershell
pwsh -File Test-Integration.ps1 -Verbose
```

## What Gets Tested

### Test Categories

| Category | Tests | Description |
|----------|-------|-------------|
| **Setup** | 1 | Module import |
| **Azure** | 2 | Azure connection and subscription |
| **Graph** | 2 | Graph token and API access |
| **Cleanup** | 1-2 | Remove existing test resources |
| **SQL** | 3 | Server creation, connection, verification |
| **Tables** | 3 | Default, extended, custom property tables |
| **Sync** | 6 | Data sync for each table type |
| **Query** | 2 | Query execution and temporal features |

### Sync Scenarios

**Scenario 1: Default Properties**
- Table: `GraphUsers_DefaultTest`
- Properties: id, userPrincipalName, displayName, mail, accountEnabled

**Scenario 2: Extended Properties**
- Table: `GraphUsers_ExtendedTest`
- Properties: Default + jobTitle, department

**Scenario 3: Custom Properties**
- Table: `GraphUsers_CustomTest`
- Properties: id, userPrincipalName, displayName, givenName, surname, officeLocation, mobilePhone

## Test Output

### Console Output

```
========================================
FortigiGraph Integration Test Suite
========================================

Test 1: Module Import
====================
  ✓ Import FortigiGraph module

Test 2: Azure Connection
========================
  → Checking Azure connection...
  ✓ Azure connection established
  ✓ Subscription context set

[... more tests ...]

========================================
Integration Test Summary
========================================

Total Tests:  28
Passed:       28
Failed:       0

Results by Category:
  ✓ Setup: 1/1 passed
  ✓ Azure: 2/2 passed
  ✓ Graph: 2/2 passed
  ✓ SQL: 3/3 passed
  ✓ Sync: 6/6 passed
  ✓ Query: 2/2 passed

All integration tests passed! ✓
```

### Results File

Detailed test results are saved to `integration-test-results.json` with:
- Test name and category
- Pass/fail status
- Timestamps
- Data captured during test

## Extending Tests

### Adding New Sync Functions

When you add new sync functions (e.g., Groups, Devices), add new test sections:

```powershell
# Test: Group Sync
Write-TestHeader "Test X: Group Sync"

try {
    Write-TestStep "Creating groups table..."
    Initialize-FGSQLTable -TableName "GraphGroups_Test" -Columns $groupColumns -PrimaryKey "id"

    Write-TestStep "Syncing groups..."
    Sync-FGGroup -TableName "GraphGroups_Test" -Top 10

    Add-TestResult -Category "Sync" -TestName "Group sync completed" -Passed $true
} catch {
    Add-TestResult -Category "Sync" -TestName "Group sync" -Passed $false -Message $_.Exception.Message
}
```

### Custom Test Scenarios

Create a custom test script based on `Test-Integration.ps1`:

```powershell
# Test-MyScenario.ps1
# Copy relevant sections from Test-Integration.ps1
# Customize for your specific testing needs
```

## Troubleshooting

### "SQL Server name already exists"

Change the `SQLServerName` in config to a unique value.

### "Graph API permission denied"

Ensure your app registration has `User.Read.All` permission granted.

### "Firewall blocking connection"

The test automatically adds your IP with `-AllowCurrentIP`, but verify in Azure Portal.

### Tests fail partway through

Use `-SkipCleanup` to keep resources and investigate:

```powershell
# Connect to the test database
Connect-FGSQLServer -SubscriptionId "..." -ResourceGroupName "rg-fortigraph-test" -ServerName "fg-test-sql-abc123"

# Query the tables
Invoke-FGSQLCommand -ScriptBlock { ... }
```

## Clean Manual Cleanup

If resources weren't cleaned up automatically:

```powershell
Remove-AzSqlServer -ResourceGroupName "rg-fortigraph-test" -ServerName "fg-test-sql-abc123" -Force
```

## CI/CD Integration

Run tests in your pipeline:

```yaml
# Azure DevOps example
- task: PowerShell@2
  inputs:
    filePath: '_Test/Test-Integration.ps1'
    arguments: '-ConfigFile $(Build.SourcesDirectory)/_Test/config.test.json'
  env:
    AZURE_SUBSCRIPTION_ID: $(AzureSubscriptionId)
    GRAPH_CLIENT_SECRET: $(GraphClientSecret)
```

## Security Best Practices

### Credential Management

**⚠️ CRITICAL SECURITY WARNINGS:**

1. **Config Files Contain Plaintext Secrets**
   - SQL admin passwords stored in plaintext
   - Graph client secrets stored in plaintext
   - **NEVER commit config files to version control**
   - The `.gitignore` protects `_Test/*.json` but verify before committing

2. **Alternative: Use Environment Variables**
   ```powershell
   # Instead of storing in config, use environment variables:
   $env:SQL_ADMIN_PASSWORD = "YourPassword"

   # Then modify the test to read from env vars instead of config
   ```

3. **Alternative: Leave ClientSecret Empty**
   - Set `"ClientSecret": ""` in config
   - Test will prompt for interactive browser login
   - No secrets stored on disk

4. **Test Environment Isolation**
   - Use dedicated test tenant/subscription
   - Never use production credentials
   - Create service principals specifically for testing
   - Delete test resources after use

5. **Secret Rotation**
   - Rotate all test secrets after sharing or exposure
   - Use short-lived secrets (30-90 days)
   - Delete SQL servers immediately after testing

### Azure Best Practices

1. **Use a dedicated test subscription** - Avoid production environments
2. **Enable Azure Defender** - Monitor for security issues
3. **Run before commits** - Catch breaking changes early
4. **Monitor costs** - Basic SQL tier is cheap but verify after tests
5. **Review transcript logs** - Full console output saved to `integration-test-<configname>.log` (unique per config file for parallel testing)

## Support

Issues or questions? Open an issue on GitHub or check the main README.md.
