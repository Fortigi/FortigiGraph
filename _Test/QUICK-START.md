# Quick Start - Running Integration Tests

## 🔒 NEW: Secure Credential Storage

**Passwords are now encrypted automatically!**
- ✅ Credentials encrypted using Windows DPAPI
- ✅ Test scripts prompt for passwords on first run
- ✅ Encrypted credentials stored in config file
- ✅ Much safer than plaintext passwords
- 📖 See `README-Secure-Credentials.md` for details

**Still important:**
- **NEVER commit config files to Git**
- `.gitignore` already protects `_Test/*.json`
- Use dedicated test credentials only
- Delete test resources after use

## TL;DR

```powershell
# Run the simple diagnostic (will prompt for credentials on first run)
.\_Test\Test-Simple.ps1 -ConfigFile _Test\config.iidemo.json

# Run the full integration test
.\_Test\Test-Integration.ps1 -ConfigFile _Test\config.iidemo.json

# Manage stored credentials (view/clear)
.\_Test\Manage-Credentials.ps1 -ConfigFile _Test\config.iidemo.json
```

Both test commands will:
- ✅ Auto-connect to Azure if needed
- ✅ Prompt for credentials (first run only)
- ✅ Check all prerequisites
- ✅ Show clear output

## Test Files

| File | Purpose | Run Time |
|------|---------|----------|
| `Test-Simple.ps1` | Quick diagnostic check | ~10 seconds |
| `Test-Integration.ps1` | Full end-to-end test | ~5-10 minutes |
| `Test-SQLFunctions.ps1` | Code structure validation | ~5 seconds |
| `Manage-Credentials.ps1` | View/clear stored credentials | Instant |

## Management Functions

FortigiGraph includes SQL management functions for everyday use:

| Function | Purpose |
|----------|---------|
| `Get-FGSQLTable` | List all tables with row counts and status |
| `Clear-FGSQLTable` | Clear data from tables (useful for testing) |
| `Remove-FGAzureSQLServer` | Delete SQL Servers and cleanup resources |

📖 See `README-SQL-Management.md` for detailed usage examples.

## Usage

### 1. Quick Diagnostic (Run This First)

```powershell
.\_Test\Test-Simple.ps1 -ConfigFile _Test\config.iidemo.json
```

**What it checks:**
- Config file is valid
- Module loads correctly
- Azure connection works (auto-connects if needed)
- All SQL functions are available

### 2. Full Integration Test

```powershell
.\_Test\Test-Integration.ps1 -ConfigFile _Test\config.iidemo.json
```

**What it does:**
- Connects to Azure (auto-prompts if needed)
- Creates SQL Server
- Creates 3 test tables (default, extended, custom properties)
- Syncs users from Graph
- Runs queries to verify
- Cleans up resources

**Keep resources for inspection:**
```powershell
.\_Test\Test-Integration.ps1 -ConfigFile _Test\config.iidemo.json -SkipCleanup
```

### 3. Code Structure Test

```powershell
pwsh -File _Test\Test-SQLFunctions.ps1
```

Validates code organization (no Azure/Graph connection needed).

## Multiple Environments

Create different config files for each environment:

```powershell
# Demo environment
.\_Test\Test-Integration.ps1 -ConfigFile _Test\config.iidemo.json

# Production test
.\_Test\Test-Integration.ps1 -ConfigFile _Test\config.production.json

# Dev environment
.\_Test\Test-Integration.ps1 -ConfigFile _Test\config.dev.json
```

## Common Issues

### "Parameter 'Verbose' was defined multiple times"

Fixed! Update your Test-Integration.ps1 file. The `-Verbose` parameter conflict has been removed.

### "Not logged in to Azure"

Both test scripts now auto-prompt for Azure login. Just follow the browser prompt.

### "SQL Server already exists"

The integration test automatically removes existing test servers. If it fails, manually remove:

```powershell
Remove-AzSqlServer -ResourceGroupName "rg-fortigraph-test" -ServerName "your-server-name" -Force
```

## Next Steps

After tests pass:
1. Check the results: `_Test\integration-test-results.json`
2. Add more sync functions (Groups, Devices, etc.)
3. Extend the test suite with new scenarios

## Test Output

After running tests, check:
- **Console output** - Real-time progress and results
- **`integration-test-<configname>.log`** - Full test log with all details (unique per config file)
- **`simple-test-<configname>.log`** - Diagnostic test log

The transcript captures everything you see in the console, making it easy to review what happened.

**Example:** If you use `config.iidemo.json`, logs will be named:
- `integration-test-config.iidemo.log`
- `simple-test-config.iidemo.log`

This allows you to run multiple tests in parallel without conflicts!

## Need Help?

- Run diagnostic first: `Test-Simple.ps1`
- Check README-Integration-Tests.md for details
- Review your config file values
- Check the transcript log for detailed error messages
