# Quick Start - Running Integration Tests

## TL;DR

```powershell
# Run the simple diagnostic
.\_Test\Test-Simple.ps1 -ConfigFile _Test\config.iidemo.json

# Run the full integration test
.\_Test\Test-Integration.ps1 -ConfigFile _Test\config.iidemo.json
```

Both commands will:
- ✅ Auto-connect to Azure if needed
- ✅ Check all prerequisites
- ✅ Show clear output

## Test Files

| File | Purpose | Run Time |
|------|---------|----------|
| `Test-Simple.ps1` | Quick diagnostic check | ~10 seconds |
| `Test-Integration.ps1` | Full end-to-end test | ~5-10 minutes |
| `Test-SQLFunctions.ps1` | Code structure validation | ~5 seconds |

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

## Need Help?

- Run diagnostic first: `Test-Simple.ps1`
- Check README-Integration-Tests.md for details
- Review your config file values
