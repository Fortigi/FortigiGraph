# Daily Sync Runbook - Files Created

This document lists all files created for the Daily Sync feature.

## Core Files

### 1. Daily-Sync.ps1
**Purpose:** Main daily sync runbook script
**Location:** `_Test/Daily-Sync.ps1`
**Description:**
- Production-ready PowerShell script for scheduled Graph data synchronization
- Validates SQL Server exists (creates if needed)
- Syncs users, groups, memberships, and ownership relationships
- Creates analysis views
- Comprehensive error handling and logging
- Uses encrypted credentials from config file

**Key Features:**
- ✅ Automatic SQL Server creation on first run
- ✅ Secure credential management (DPAPI encryption)
- ✅ Selective sync (enable/disable individual entity types)
- ✅ OData filtering support
- ✅ Comprehensive logging with timestamps
- ✅ Summary statistics and error reporting
- ✅ Analysis view creation

**Usage:**
```powershell
.\Daily-Sync.ps1 -ConfigFile .\config.production.json
```

---

### 2. README-Daily-Sync.md
**Purpose:** Comprehensive documentation for the daily sync runbook
**Location:** `_Test/README-Daily-Sync.md`
**Description:**
- Complete guide to using the daily sync runbook
- Configuration options and examples
- Scheduling and automation instructions
- Troubleshooting guide
- Security best practices
- Performance tuning tips

**Sections:**
- Overview and features
- Quick start guide
- Configuration options
- Selective sync examples
- Filtering data
- Additional user attributes
- Automation & scheduling (Task Scheduler, Azure Automation)
- Output & logging
- Error handling
- Advanced scenarios
- Performance tuning
- Troubleshooting
- Security best practices
- Integration with BI tools

---

### 3. QUICK-START-Daily-Sync.md
**Purpose:** Fast-track guide to get started in 5 minutes
**Location:** `_Test/QUICK-START-Daily-Sync.md`
**Description:**
- Simplified quick start guide
- 4 steps to first sync
- Common customizations
- Scheduling example
- Troubleshooting essentials

**Perfect for:**
- New users who want to get started quickly
- Quick reference for common tasks
- Sharing with colleagues

---

### 4. config.dailysync.json.template
**Purpose:** Configuration template specifically for daily sync
**Location:** `_Test/config.dailysync.json.template`
**Description:**
- Comprehensive template with detailed annotations
- Example values and notes for each field
- Security reminders
- Permission requirements
- Example usage patterns
- Scheduling recommendations

**Usage:**
```powershell
cp config.dailysync.json.template config.production.json
# Edit config.production.json with your values
```

---

### 5. Run-DailySync-Example.ps1
**Purpose:** Example wrapper script for scheduling
**Location:** `_Test/Run-DailySync-Example.ps1`
**Description:**
- Simple wrapper for Task Scheduler or Azure Automation
- Customizable parameters
- Error handling
- Exit codes for monitoring

**Usage:**
```powershell
# Copy and customize
cp Run-DailySync-Example.ps1 Run-DailySync-Production.ps1
# Edit and schedule
```

---

## Updated Files

### README-Integration-Tests.md
**Changes:**
- Updated title to "Integration Tests & Daily Sync"
- Added overview section mentioning daily sync runbook
- Added "Related Documentation" section with links to all daily sync docs

**Location:** `_Test/README-Integration-Tests.md`

---

## File Summary Table

| File | Type | Size (approx) | Purpose |
|------|------|---------------|---------|
| `Daily-Sync.ps1` | Script | 21 KB | Main sync runbook |
| `README-Daily-Sync.md` | Documentation | 15 KB | Comprehensive guide |
| `QUICK-START-Daily-Sync.md` | Documentation | 3.5 KB | Quick start guide |
| `config.dailysync.json.template` | Template | 3 KB | Config template |
| `Run-DailySync-Example.ps1` | Script | 1.7 KB | Wrapper example |

---

## Integration with Existing Structure

The daily sync runbook integrates seamlessly with existing FortigiGraph infrastructure:

### Uses Existing Functions
- `Connect-FGSQLServer` - SQL connection management
- `Get-FGAccessToken` - Graph authentication
- `Sync-FGUser` - User synchronization
- `Sync-FGGroup` - Group synchronization
- `Sync-FGGroupMember` - Direct membership sync
- `Sync-FGGroupTransitiveMember` - Nested membership sync
- `Sync-FGGroupEligibleMember` - PIM membership sync
- `Sync-FGGroupOwner` - Ownership sync
- `Initialize-FGGroupMembershipViews` - View creation
- `SecureConfig.ps1` - Encrypted credential management

### Uses Same Config Format
- Compatible with test config format
- Same encryption mechanism (DPAPI)
- Same credential prompting
- Same Azure/Graph structure

### Follows FortigiGraph Patterns
- Color-coded console output (Green/Yellow/Cyan/Red)
- Comprehensive error handling
- Transcript logging
- Helper function pattern
- Parameter naming conventions

---

## Directory Structure

```
FortigiGraph/
├── _Test/
│   ├── Daily-Sync.ps1                      ← NEW: Main runbook
│   ├── README-Daily-Sync.md                ← NEW: Full documentation
│   ├── QUICK-START-Daily-Sync.md           ← NEW: Quick guide
│   ├── config.dailysync.json.template      ← NEW: Config template
│   ├── Run-DailySync-Example.ps1           ← NEW: Wrapper example
│   ├── DAILY-SYNC-FILES.md                 ← NEW: This file
│   ├── README-Integration-Tests.md         ← UPDATED: Added daily sync refs
│   ├── Test-Integration.ps1                ← Existing
│   ├── Test-Simple.ps1                     ← Existing
│   ├── SecureConfig.ps1                    ← Existing (used by daily sync)
│   ├── Manage-Credentials.ps1              ← Existing
│   ├── config.test.json.template           ← Existing
│   └── ...                                 ← Other test files
```

---

## Next Steps

1. **Review the Quick Start:** `QUICK-START-Daily-Sync.md`
2. **Create your config:** Copy `config.dailysync.json.template` to `config.production.json`
3. **Run first sync:** `.\Daily-Sync.ps1 -ConfigFile .\config.production.json`
4. **Review full docs:** `README-Daily-Sync.md` for advanced scenarios
5. **Schedule it:** Use `Run-DailySync-Example.ps1` as a template

---

## Testing the Daily Sync

Before scheduling, test with your config:

```powershell
# Navigate to _Test folder
cd C:\Source\Fortigi\GitHub\FortigiGraph\_Test

# Run sync manually
.\Daily-Sync.ps1 -ConfigFile .\config.test.json

# Check the log file (created automatically)
Get-Content .\daily-sync-test-*.log -Tail 50

# Verify data in SQL
Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM GraphUsers" -AsScalar
```

---

## Support

For questions or issues:
1. Check `README-Daily-Sync.md` for detailed docs
2. Review log files for error details
3. Check `README-Secure-Credentials.md` for credential issues
4. See `README-Integration-Tests.md` for testing guidance
5. Open an issue on GitHub

---

**Created:** 2025-01-06
**Author:** Claude (based on FortigiGraph architecture by Wim van den Heijkant)
**Version:** 1.0
