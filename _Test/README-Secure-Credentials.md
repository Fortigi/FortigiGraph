# Secure Credential Storage for FortigiGraph Tests

## Overview

The FortigiGraph test suite now uses **encrypted credential storage** to protect sensitive information like SQL passwords and Graph client secrets. Credentials are encrypted using Windows Data Protection API (DPAPI) and stored in your config file.

## How It Works

### Security Features

- **Encrypted at Rest**: Credentials are encrypted using Windows DPAPI
- **User-Specific**: Encrypted credentials can only be decrypted by the same Windows user on the same machine
- **Automatic Migration**: If you have plaintext passwords in your config, they'll be automatically encrypted on first run
- **No Code Changes Needed**: The test scripts handle encryption/decryption automatically

### First Run Experience

When you run a test script for the first time:

1. The script checks if credentials are already stored (encrypted)
2. If not found, it prompts you to enter them
3. Your credentials are encrypted using Windows DPAPI
4. The encrypted values are stored in the config file with `_Encrypted` suffix
5. On subsequent runs, credentials are automatically decrypted and used

## Usage

### Running Tests (Normal Workflow)

Just run your tests as usual:

```powershell
# Simple diagnostic
.\_Test\Test-Simple.ps1 -ConfigFile _Test\config.iidemo.json

# Full integration test
.\_Test\Test-Integration.ps1 -ConfigFile _Test\config.iidemo.json
```

**On first run**, you'll be prompted:

```
  → Enter SQL Server Admin Password: ********
  ✓ Credential encrypted and stored securely

  → Enter Graph Client Secret (or press Enter for interactive auth): ********
  ✓ Credential encrypted and stored securely
```

**On subsequent runs**, credentials are loaded automatically from encrypted storage.

### Managing Credentials

Use the `Manage-Credentials.ps1` script to view or clear stored credentials:

```powershell
# Check credential status
.\_Test\Manage-Credentials.ps1 -ConfigFile _Test\config.iidemo.json

# Clear credentials (interactive menu)
.\_Test\Manage-Credentials.ps1 -ConfigFile _Test\config.iidemo.json -Action Clear

# Clear all credentials at once
.\_Test\Manage-Credentials.ps1 -ConfigFile _Test\config.iidemo.json -Action ClearAll
```

**Example output:**

```
========================================
FortigiGraph Credential Manager
========================================

Checking credential status...

  ✓ SQL Admin Password: Stored securely
  ✓ Graph Client Secret: Stored securely
```

### Updating Credentials

To update a credential:

1. Clear it: `.\_Test\Manage-Credentials.ps1 -Action Clear`
2. Run your test script again - it will prompt for the new value

### Config File Format

After credentials are stored, your config file will look like this:

```json
{
  "Azure": {
    "SubscriptionId": "12345678-1234-1234-1234-123456789012",
    "AdminUsername": "sqladmin",
    "AdminUserPassword": "",
    "AdminUserPassword_Encrypted": "01000000d08c9ddf0115d1118c7a00c04fc297eb..."
  },
  "Graph": {
    "TenantId": "87654321-4321-4321-4321-210987654321",
    "ClientId": "11111111-1111-1111-1111-111111111111",
    "ClientSecret": "",
    "ClientSecret_Encrypted": "01000000d08c9ddf0115d1118c7a00c04fc297eb..."
  }
}
```

Notice:
- Original fields (`AdminUserPassword`, `ClientSecret`) are cleared (empty string)
- New encrypted fields (`*_Encrypted`) contain the encrypted data

## Security Considerations

### What's Protected

✅ **Protected by encryption:**
- SQL Server admin passwords
- Microsoft Graph client secrets
- Any future sensitive credentials

✅ **Protection level:**
- Encrypted using Windows DPAPI (same encryption used by Windows Credential Manager)
- Can only be decrypted by the same user on the same machine
- Much more secure than plaintext storage

### What's NOT Protected

⚠️ **Still visible in plaintext in config:**
- Azure Subscription IDs (not sensitive - needed for resource lookup)
- Tenant IDs (not sensitive - public directory identifier)
- Client IDs (not sensitive - public app identifier)
- SQL Server names, database names, usernames

These values are not sensitive and are safe to store in plaintext.

### Important Security Notes

1. **Config files still should NOT be committed to Git**
   - Even though passwords are encrypted, the config file still contains environment-specific information
   - The `.gitignore` already excludes `_Test/*.json`

2. **Encrypted credentials are machine and user-specific**
   - If you copy the config to another machine, the encrypted credentials won't work
   - If another user on the same machine tries to use your config, decryption will fail
   - This is a security feature!

3. **For team environments**
   - Each team member should have their own config file with their own credentials
   - Don't share config files between team members
   - Consider using a template config and having each person fill in their own values

4. **For CI/CD pipelines**
   - CI/CD environments should use environment variables or secure vault systems
   - See the main README for CI/CD integration examples

## Migration from Plaintext

If you already have a config file with plaintext passwords:

1. **Automatic Migration**: Just run your test script - it will detect plaintext passwords and automatically encrypt them
2. **Manual Migration**: Use the credential manager to check status

Example of automatic migration:

```
  → Migrating plaintext credential to encrypted storage...
  ✓ Credential encrypted and stored securely
```

After migration, your plaintext passwords are cleared from the config file and replaced with encrypted versions.

## Troubleshooting

### "Failed to decrypt stored credential"

This happens if:
- You copied the config from another machine
- Another user is trying to use your config
- The config was created by a different Windows user account

**Solution**: Clear the credential and re-enter it:
```powershell
.\_Test\Manage-Credentials.ps1 -Action Clear
```

### Interactive Auth Instead of Client Secret

If you prefer not to store the Graph client secret at all, just press Enter when prompted. The test will use interactive browser authentication instead:

```
  → Enter Graph Client Secret (or press Enter for interactive auth): [press Enter]
  → Using empty value (interactive auth will be used)
```

### Credential Prompts on Every Run

If you're prompted every time, check:
1. The config file is writable (not read-only)
2. You have permissions to modify the config file
3. The config file path is correct

### Sharing Configs Between Machines

Don't copy configs between machines. Instead:
1. Copy the template: `config.test.json.template`
2. Rename to `config.test.json` on the new machine
3. Fill in the non-sensitive values
4. Run the test - it will prompt for credentials

## Technical Details

### Encryption Method

- Uses PowerShell's `ConvertFrom-SecureString` / `ConvertTo-SecureString`
- Internally uses Windows DPAPI
- Encryption scope: CurrentUser (user-specific, not machine-specific)
- Same encryption used by Windows Credential Manager and PowerShell credential storage

### Where Credentials Are Stored

- Encrypted credentials are stored directly in the JSON config file
- Field naming: `{OriginalFieldName}_Encrypted`
- No separate credential store or vault

### Helper Functions

The `SecureConfig.ps1` module provides:

- `Get-SecureConfigValue`: Gets or prompts for a credential
- `Clear-SecureConfigValue`: Removes an encrypted credential
- `Test-SecureConfigAvailable`: Checks if a credential exists

## Best Practices

1. **Never commit config files to Git** (even with encrypted credentials)
2. **Use strong passwords** for SQL Server admin accounts
3. **Rotate credentials regularly**, especially test credentials
4. **Delete test resources** after use (SQL Servers, databases)
5. **Use dedicated test credentials**, never production credentials
6. **Consider interactive auth** for Graph (no stored secret at all)

## Support

For issues or questions:
- Check this README first
- Review the main `README-Integration-Tests.md`
- Open an issue on GitHub
