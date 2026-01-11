# Sync Configuration Guide

## Overview

The Daily Sync runbook now supports a **Sync section** in the configuration file, allowing you to specify all your sync preferences in one place. This makes it much easier to manage, especially in large environments with many custom attributes.

## Benefits

✅ **Centralized Configuration**: All sync settings in one config file
✅ **Easy Maintenance**: Update attributes once, not in every script call
✅ **Version Control Friendly**: Config file shows exactly what's being synced
✅ **Environment-Specific**: Different configs for dev/test/prod
✅ **Command-Line Override**: Can still override via parameters when needed

## Configuration Structure

Add a `Sync` section to your config file:

```json
{
  "Azure": { ... },
  "Graph": { ... },

  "Sync": {
    "ParallelExecution": true,

    "Users": {
      "Enabled": true,
      "TableName": "GraphUsers",
      "Filter": "accountEnabled eq true",
      "AdditionalAttributes": ["city", "country", "officeLocation"]
    },

    "Groups": {
      "Enabled": true,
      "TableName": "GraphGroups",
      "Filter": ""
    },

    "GroupMembers": {
      "Enabled": true,
      "TableName": "GraphGroupMembers"
    },

    "GroupTransitiveMembers": {
      "Enabled": true,
      "TableName": "GraphGroupTransitiveMembers"
    },

    "GroupEligibleMembers": {
      "Enabled": false,
      "_Comment": "PIM not configured"
    },

    "GroupOwners": {
      "Enabled": true,
      "TableName": "GraphGroupOwners"
    },

    "Views": {
      "Enabled": true
    }
  }
}
```

## Configuration Options

### ParallelExecution (Global Setting)

| Property | Type | Description | Default |
|----------|------|-------------|---------|
| `ParallelExecution` | Boolean | Run sync operations in parallel or sequential | `true` |

**Parallel Mode (Default - Faster):**
- All sync operations run simultaneously
- Up to 6 concurrent operations
- Significantly faster (often 3-6x improvement)
- Best for: Production, scheduled runs, normal operation

**Sequential Mode (Debugging/Lower Resources):**
- Operations run one at a time
- Lower CPU/memory usage
- Easier to debug and follow logs
- Best for: Troubleshooting, resource-constrained environments, SQL connection limits

**Example:**
```json
"Sync": {
  "ParallelExecution": false,  // Use sequential mode for debugging
  "Users": { ... }
}
```

**Command-line override:**
```powershell
# Force sequential execution
.\Daily-Sync.ps1 -ConfigFile .\config.json -ParallelExecution $false

# Force parallel execution
.\Daily-Sync.ps1 -ConfigFile .\config.json -ParallelExecution $true
```

### Users Section

| Property | Type | Description | Example |
|----------|------|-------------|---------|
| `Enabled` | Boolean | Whether to sync users | `true` |
| `TableName` | String | SQL table name | `"GraphUsers"` |
| `Filter` | String | OData filter | `"accountEnabled eq true"` |
| `AdditionalAttributes` | Array | Extra attributes beyond defaults | `["city", "country"]` |

**Example - Sync only enabled members with custom attributes:**
```json
"Users": {
  "Enabled": true,
  "TableName": "GraphUsers",
  "Filter": "accountEnabled eq true and userType eq 'Member'",
  "AdditionalAttributes": [
    "officeLocation",
    "city",
    "state",
    "country",
    "employeeType",
    "extension_9dbfd777ae31443d9f207cb9c0b7f7ee_sfEmploymentUserID"
  ]
}
```

### Groups Section

| Property | Type | Description | Example |
|----------|------|-------------|---------|
| `Enabled` | Boolean | Whether to sync groups | `true` |
| `TableName` | String | SQL table name | `"GraphGroups"` |
| `Filter` | String | OData filter | `"securityEnabled eq true"` |

**Example - Sync only security groups:**
```json
"Groups": {
  "Enabled": true,
  "TableName": "GraphGroups",
  "Filter": "securityEnabled eq true and mailEnabled eq false"
}
```

### Membership Sections

All membership sections have the same structure:

| Property | Type | Description | Example |
|----------|------|-------------|---------|
| `Enabled` | Boolean | Whether to sync | `true` |
| `TableName` | String | SQL table name | `"GraphGroupMembers"` |

**Sections:**
- `GroupMembers` - Direct memberships
- `GroupTransitiveMembers` - Nested/indirect memberships
- `GroupEligibleMembers` - PIM eligible memberships
- `GroupOwners` - Group ownership

**Example - Skip PIM if not configured:**
```json
"GroupEligibleMembers": {
  "Enabled": false,
  "_Comment": "PIM not configured in this environment"
}
```

### Views Section

| Property | Type | Description | Example |
|----------|------|-------------|---------|
| `Enabled` | Boolean | Whether to create analysis views | `true` |

## Common Scenarios

### Scenario 1: Large Environment with Custom Attributes

**Challenge:** Your organization uses many extension attributes from SuccessFactors or Workday.

**Solution:**
```json
"Sync": {
  "Users": {
    "Enabled": true,
    "TableName": "GraphUsers",
    "Filter": "",
    "AdditionalAttributes": [
      "extension_9dbfd777ae31443d9f207cb9c0b7f7ee_sfEmploymentUserID",
      "extension_9dbfd777ae31443d9f207cb9c0b7f7ee_sfTeamID",
      "extension_9dbfd777ae31443d9f207cb9c0b7f7ee_sfDepartmentID",
      "extension_9dbfd777ae31443d9f207cb9c0b7f7ee_sfManagerID",
      "extension_9dbfd777ae31443d9f207cb9c0b7f7ee_sfCostCenter",
      "officeLocation",
      "city",
      "country",
      "companyName",
      "employeeType"
    ]
  }
}
```

**Usage:**
```powershell
# Just run - all attributes from config
.\Daily-Sync.ps1 -ConfigFile .\config.production.json
```

### Scenario 2: Multiple Environments (Dev/Test/Prod)

**Challenge:** Different settings for different environments.

**Solution:** Create environment-specific config files:

**config.dev.json:**
```json
"Sync": {
  "Users": {
    "Enabled": true,
    "Filter": "startswith(userPrincipalName, 'test')",
    "AdditionalAttributes": ["city", "country"]
  },
  "GroupEligibleMembers": {
    "Enabled": false
  }
}
```

**config.production.json:**
```json
"Sync": {
  "Users": {
    "Enabled": true,
    "Filter": "accountEnabled eq true",
    "AdditionalAttributes": [
      "city", "country", "officeLocation",
      "extension_*_sfEmploymentUserID"
    ]
  },
  "GroupEligibleMembers": {
    "Enabled": true
  }
}
```

**Usage:**
```powershell
# Dev environment
.\Daily-Sync.ps1 -ConfigFile .\config.dev.json

# Production
.\Daily-Sync.ps1 -ConfigFile .\config.production.json
```

### Scenario 3: Compliance - Active Users Only

**Challenge:** Compliance requires only active, employed users.

**Solution:**
```json
"Sync": {
  "Users": {
    "Enabled": true,
    "Filter": "accountEnabled eq true and userType eq 'Member'",
    "AdditionalAttributes": ["employeeType", "employeeId"]
  }
}
```

### Scenario 4: No PIM in Environment

**Challenge:** Your tenant doesn't have PIM configured.

**Solution:**
```json
"Sync": {
  "GroupEligibleMembers": {
    "Enabled": false
  }
}
```

### Scenario 5: Groups Only (No Users)

**Challenge:** You only need group membership data, not user details.

**Solution:**
```json
"Sync": {
  "Users": {
    "Enabled": false
  },
  "Groups": {
    "Enabled": true
  },
  "GroupMembers": {
    "Enabled": true
  },
  "GroupTransitiveMembers": {
    "Enabled": true
  }
}
```

## Command-Line Overrides

Config file settings can be overridden via command-line parameters:

**Example - Config says sync users, but skip for this run:**
```powershell
.\Daily-Sync.ps1 -ConfigFile .\config.production.json -SyncUsers $false
```

**Example - Add extra attributes for one-time analysis:**
```powershell
.\Daily-Sync.ps1 -ConfigFile .\config.production.json `
    -UserAdditionalAttributes @('mobilePhone', 'businessPhones')
```

**Example - Test with filtered users:**
```powershell
.\Daily-Sync.ps1 -ConfigFile .\config.production.json `
    -UserFilter "department eq 'IT'"
```

## Priority Order

Settings are applied in this order (later overrides earlier):

1. **Script defaults** (`$true` for all syncs)
2. **Config file Sync section** (if present)
3. **Command-line parameters** (highest priority)

## Migration from Command-Line to Config File

### Before (command-line only):
```powershell
.\Daily-Sync.ps1 -ConfigFile .\config.production.json `
    -UserFilter "accountEnabled eq true" `
    -UserAdditionalAttributes @('city', 'country', 'officeLocation', 'employeeType', 'extension_*_sfEmploymentUserID') `
    -SyncGroupEligibleMembers $false
```

### After (using config file):
**Add to config.production.json:**
```json
"Sync": {
  "Users": {
    "Filter": "accountEnabled eq true",
    "AdditionalAttributes": [
      "city", "country", "officeLocation",
      "employeeType",
      "extension_9dbfd777ae31443d9f207cb9c0b7f7ee_sfEmploymentUserID"
    ]
  },
  "GroupEligibleMembers": {
    "Enabled": false
  }
}
```

**Run:**
```powershell
.\Daily-Sync.ps1 -ConfigFile .\config.production.json
```

Much cleaner! 🎉

## Validating Your Configuration

Test your config before scheduling:

```powershell
# Dry run - check what would be synced
.\Daily-Sync.ps1 -ConfigFile .\config.production.json

# Check log file
Get-Content .\daily-sync-production-*.log | Select-String "synced"
```

Look for output like:
```
  ✓ Users synced: 1,245 (table: GraphUsers)
  ✓ Groups synced: 387 (table: GraphGroups)
  ...
```

## Troubleshooting

### "Reading sync configuration from config file..." not shown

**Issue:** Config file doesn't have a `Sync` section.

**Solution:** Add the `Sync` section to your config file (see examples above).

### Additional attributes not syncing

**Issue:** Typo in attribute name or missing Graph API permissions.

**Solution:**
1. Check attribute name spelling (case-sensitive!)
2. Verify Graph API schema: `https://graph.microsoft.com/beta/users?$select=attributeName`
3. Check permissions include `User.Read.All`

### Filter not working

**Issue:** OData filter syntax error.

**Solution:**
- Ensure proper quoting: `"accountEnabled eq true"`
- Test filter in Graph Explorer first
- Check OData v4 syntax: https://learn.microsoft.com/en-us/graph/query-parameters

## Best Practices

1. **Use Config File for Static Settings**
   - Attributes that rarely change
   - Environment-specific filters
   - Enabled/disabled syncs

2. **Use Command-Line for Overrides**
   - One-time testing
   - Emergency bypasses
   - Temporary changes

3. **Version Control Your Config**
   - Commit `config.*.json.template` files
   - **DO NOT** commit actual configs with credentials
   - Document changes in commit messages

4. **Test Before Scheduling**
   - Run manually first
   - Verify counts in summary
   - Check SQL tables have expected data

5. **Document Your Attributes**
   - Add comments in config file
   - Maintain a separate doc for extension attributes
   - Note which attributes are required for BI reports

## Examples Repository

See these example configs:

| File | Description |
|------|-------------|
| `config.dailysync.json.template` | Template with all options documented |
| `config.dailysync-example.json` | Working example with Sync section |
| Your `config.production.json` | Your customized production config |

## Summary

The Sync configuration section provides:

- ✅ **Easy Management**: All settings in one place
- ✅ **Maintainability**: Update once, use everywhere
- ✅ **Flexibility**: Override when needed via command-line
- ✅ **Clarity**: Config file documents what's being synced
- ✅ **Scalability**: Perfect for large environments with many attributes

Start with the template, customize for your environment, and enjoy simplified daily syncs! 🚀
