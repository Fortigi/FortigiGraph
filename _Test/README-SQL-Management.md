# SQL Server Management Functions

FortigiGraph includes several functions for managing SQL Server resources. These are useful for both testing and general database administration.

## Overview

| Function | Purpose | Use Case |
|----------|---------|----------|
| `Get-FGSQLTable` | List all tables with details | See what tables exist and their status |
| `Clear-FGSQLTable` | Clear data from a table | Reset tables between test runs |
| `Remove-FGAzureSQLServer` | Delete an entire SQL Server | Clean up test environments |

## Get-FGSQLTable

Lists all tables in the connected database with details like row counts, temporal status, and history tables.

### Basic Usage

```powershell
# Connect to SQL Server first
Connect-FGSQLServer -SubscriptionId "..." -ResourceGroupName "rg-test" -ServerName "fg-test-sql"

# List all tables
Get-FGSQLTable
```

**Example Output:**
```
Found 3 table(s):

Table                      Rows    Temporal HistoryTable                        Created
-----                      ----    -------- ------------                        -------
dbo.GraphUsers_Default     1,234   Yes      dbo.GraphUsers_Default_History      2025-01-15
dbo.GraphUsers_Extended    1,234   Yes      dbo.GraphUsers_Extended_History     2025-01-15
dbo.GraphUsers_Custom      987     Yes      dbo.GraphUsers_Custom_History       2025-01-16

Summary:
  Total Tables: 3
  Temporal Tables: 3
  Total Rows (approx): 3,455
```

### Filtering

```powershell
# Filter by pattern
Get-FGSQLTable -Pattern "GraphUsers*"

# Filter by schema
Get-FGSQLTable -Schema "dbo"

# Include system temporal history tables
Get-FGSQLTable -IncludeSystemTables
```

## Clear-FGSQLTable

Clears all data from a table while preserving the table structure. For temporal tables, you can optionally clear history as well.

### Basic Usage

```powershell
# Clear a table (preserves history)
Clear-FGSQLTable -TableName "GraphUsers_Test"

# Clear table and history
Clear-FGSQLTable -TableName "GraphUsers_Test" -DeleteHistory

# Skip confirmation prompt
Clear-FGSQLTable -TableName "GraphUsers_Test" -Force
```

**Example Output:**
```
Preparing to clear table: [dbo].[GraphUsers_Test]
  → Table is temporal (history table: [dbo].[GraphUsers_Test_History])
  → Current records: 1,234
  → History records: 5,678

Confirm
Clear 1,234 records from [dbo].[GraphUsers_Test]?
[Y] Yes  [N] No  [?] Help (default is "Y"): Y

  → Disabling temporal versioning...
  → Clearing current table...
  ✓ Cleared 1,234 records from [dbo].[GraphUsers_Test]
  → Re-enabling temporal versioning...
  ✓ Temporal versioning re-enabled

✓ Table cleared successfully
```

### Use Cases

**Reset test data between runs:**
```powershell
# Clear all test tables before re-running sync
Clear-FGSQLTable -TableName "GraphUsers_Test" -Force
Clear-FGSQLTable -TableName "GraphGroups_Test" -Force

# Run sync again
Sync-FGUser -TableName "GraphUsers_Test"
```

**Clean slate for testing:**
```powershell
# Clear both current and history data
Clear-FGSQLTable -TableName "GraphUsers_Test" -DeleteHistory -Force
```

## Remove-FGAzureSQLServer

**⚠️ DANGEROUS OPERATION** - Permanently deletes an Azure SQL Server and all its databases.

### Basic Usage

```powershell
# Remove a SQL Server (with confirmation)
Remove-FGAzureSQLServer `
    -SubscriptionId "12345..." `
    -ResourceGroupName "rg-test" `
    -ServerName "fg-test-sql-123"

# Remove without confirmation (use with EXTREME caution)
Remove-FGAzureSQLServer `
    -SubscriptionId "12345..." `
    -ResourceGroupName "rg-test" `
    -ServerName "fg-test-sql-123" `
    -Force
```

**Example Output:**
```
========================================
Remove Azure SQL Server
========================================

Checking if SQL Server exists...
  → Found SQL Server: fg-test-sql-123
    Location: northeurope
    FQDN: fg-test-sql-123.database.windows.net
    Resource Group: rg-test

  → Databases that will be deleted:
    • GraphDataTest (Standard, 250.00 GB max)
    • TestDB (Basic, 2.00 GB max)

⚠️  WARNING: This will PERMANENTLY delete:
   • SQL Server: fg-test-sql-123
   • All databases on this server
   • All firewall rules
   • All data (CANNOT BE RECOVERED)

Confirm
PERMANENTLY DELETE SQL Server and all databases
[Y] Yes  [N] No  [?] Help (default is "N"): Y

  → Removing SQL Server...
    This may take several minutes...

========================================
✓ SQL Server Removed Successfully
========================================

Removed:
  • Server: fg-test-sql-123
  • Resource Group: rg-test
  • Databases: 2
```

### Safety Features

1. **Confirmation Required** - Prompts for confirmation unless `-Force` is used
2. **Extra Confirmation for Production** - Servers not containing "test", "dev", or "demo" require typing the server name
3. **Detailed Preview** - Shows all databases that will be deleted before proceeding
4. **Connection Cleanup** - Automatically closes any active connections to the server

### Use Cases

**Clean up after integration tests:**
```powershell
# Run integration test
.\Test-Integration.ps1 -ConfigFile config.test.json

# Manually remove the test server afterward
Remove-FGAzureSQLServer `
    -SubscriptionId $config.Azure.SubscriptionId `
    -ResourceGroupName $config.Azure.ResourceGroupName `
    -ServerName $config.Azure.SQLServerName
```

**Automated cleanup in CI/CD:**
```powershell
# In your cleanup script
Remove-FGAzureSQLServer `
    -SubscriptionId $env:AZURE_SUBSCRIPTION_ID `
    -ResourceGroupName "rg-ci-test-$env:BUILD_ID" `
    -ServerName "fg-ci-sql-$env:BUILD_ID" `
    -Force  # OK in CI/CD with disposable resources
```

## Common Workflows

### Daily Testing Workflow

```powershell
# 1. Connect to test SQL Server
Connect-FGSQLServer -SubscriptionId "..." -ResourceGroupName "rg-test" -ServerName "fg-test-sql"

# 2. Check what tables exist
Get-FGSQLTable

# 3. Clear tables before testing
Clear-FGSQLTable -TableName "GraphUsers_Test" -Force

# 4. Run your sync
Sync-FGUser -TableName "GraphUsers_Test"

# 5. Verify results
Get-FGSQLTable -Pattern "GraphUsers*"
```

### Weekly Cleanup Workflow

```powershell
# 1. List all test servers in resource group
Get-AzSqlServer -ResourceGroupName "rg-fortigraph-test"

# 2. Remove old test servers
Remove-FGAzureSQLServer `
    -SubscriptionId "..." `
    -ResourceGroupName "rg-fortigraph-test" `
    -ServerName "fg-test-sql-old"
```

### Fresh Start Workflow

```powershell
# 1. Remove entire test SQL Server
Remove-FGAzureSQLServer `
    -SubscriptionId "..." `
    -ResourceGroupName "rg-test" `
    -ServerName "fg-test-sql-123"

# 2. Create new SQL Server
New-FGAzureSQLServer `
    -SubscriptionId "..." `
    -ResourceGroupName "rg-test" `
    -ServerName "fg-test-sql-124" `
    -DatabaseName "GraphData" `
    -Location "northeurope" `
    -AutoConnect

# 3. Initialize tables
Initialize-FGSQLTable -TableName "GraphUsers" -PrimaryKey "id"

# 4. Sync data
Sync-FGUser -TableName "GraphUsers"
```

## Best Practices

### ✅ Do

- **Clear tables** between test runs to ensure clean data
- **Use `-Force`** in automated scripts where confirmation isn't possible
- **List tables** regularly to understand your database state
- **Remove test servers** when done to avoid costs
- **Name test servers** with "test", "dev", or "demo" for easier identification

### ❌ Don't

- **Don't use `-Force`** for production operations without extreme caution
- **Don't forget** to backup important data before clearing or removing
- **Don't leave** test SQL Servers running overnight (they cost money)
- **Don't remove** servers without checking what databases they contain
- **Don't assume** table clears are reversible (they're not, except via history tables)

## Security Considerations

### Clear-FGSQLTable

- **Data Deletion**: Clears are permanent for current data
- **History Preservation**: By default, history is preserved (temporal tables)
- **Recovery**: No recovery unless you have backups or history tables
- **Permissions**: Requires write access to the database

### Remove-FGAzureSQLServer

- **Complete Deletion**: ALL data is permanently deleted
- **No Recovery**: Cannot be undone - backups are your only option
- **Permissions**: Requires Contributor or Owner role on the resource group
- **Active Connections**: Terminates all active connections

## Troubleshooting

### "Not connected to SQL Server"

**Solution:**
```powershell
Connect-FGSQLServer `
    -SubscriptionId "..." `
    -ResourceGroupName "rg-test" `
    -ServerName "fg-test-sql"
```

### "Failed to clear table: Cannot TRUNCATE table..."

Some tables can't be truncated (e.g., with foreign keys). The function automatically falls back to DELETE.

**If this fails too:**
```powershell
# Manually delete with custom script
Invoke-FGSQLCommand -ScriptBlock {
    param($connection)
    $cmd = $connection.CreateCommand()
    $cmd.CommandText = "DELETE FROM YourTable WHERE <condition>"
    $cmd.ExecuteNonQuery()
}
```

### "ResourceNotFound" when removing server

The server doesn't exist. Check:
- Server name is correct (without `.database.windows.net`)
- Resource group name is correct
- You're in the right subscription

```powershell
# List all servers in resource group
Get-AzSqlServer -ResourceGroupName "rg-test"
```

### "Failed to restore temporal versioning"

If `Clear-FGSQLTable` fails partway through:

```powershell
# Manually restore versioning
Invoke-FGSQLCommand -ScriptBlock {
    param($connection)
    $cmd = $connection.CreateCommand()
    $cmd.CommandText = @"
ALTER TABLE [dbo].[YourTable]
SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = [dbo].[YourTable_History]))
"@
    $cmd.ExecuteNonQuery()
}
```

## See Also

- **Connection Management**: `Connect-FGSQLServer`, `Test-FGSQLConnection`
- **Table Creation**: `Initialize-FGSQLTable`
- **Data Sync**: `Sync-FGUser`, `Sync-FGGroup`
- **Server Creation**: `New-FGAzureSQLServer`
- **Integration Tests**: `Test-Integration.ps1`
