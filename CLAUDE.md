# FortigiGraph - AI Assistant Guide

## Project Overview

FortigiGraph is a PowerShell module designed to simplify scripting against the Microsoft Graph API. It provides a comprehensive set of cmdlets for managing Azure AD/Entra ID resources including users, groups, devices, access packages, catalogs, and access reviews.

**Key Information:**
- **Language:** PowerShell
- **Purpose:** Microsoft Graph API wrapper module
- **Author:** Wim van den Heijkant
- **Company:** Fortigi
- **GitHub:** https://github.com/Fortigi/FortigiGraph
- **Distribution:** PowerShell Gallery
- **Current Version:** 1.1.20250514.1135

## Repository Structure

```
FortigiGraph/
├── Base/                   # Core authentication and HTTP request functions
│   ├── Get-FGAccessToken*.ps1          # Token acquisition functions
│   ├── Invoke-FGGetRequest.ps1         # HTTP GET wrapper
│   ├── Invoke-FGPostRequest.ps1        # HTTP POST wrapper
│   ├── Invoke-FGPatchRequest.ps1       # HTTP PATCH wrapper
│   ├── Invoke-FGPutRequest.ps1         # HTTP PUT wrapper
│   ├── Invoke-FGDeleteRequest.ps1      # HTTP DELETE wrapper
│   ├── Confirm-FGAccessTokenValidity.ps1
│   └── ...                             # Other base utilities
│
├── Generic/                # Generic Microsoft Graph API operations
│   ├── Get-FG*.ps1         # Get/retrieve operations (45 functions)
│   ├── New-FG*.ps1         # Create operations
│   ├── Set-FG*.ps1         # Update operations
│   ├── Add-FG*.ps1         # Add operations (members, resources)
│   └── Remove-FG*.ps1      # Delete/remove operations
│
├── Specific/               # Higher-level helper functions
│   └── Confirm-FG*.ps1     # Idempotent confirmation/creation functions
│
├── _Build/                 # Build and publishing scripts
│   └── CreatePSD.ps1       # Module manifest generation and publishing
│
├── FortigiGraph.psm1       # Module entry point (auto-loads all functions)
├── FortigiGraph.psd1       # Module manifest
└── README.md               # User documentation
```

### Total Function Count
- **Base Functions:** ~17 functions (authentication, HTTP operations, token management)
- **Generic Functions:** ~45 functions (CRUD operations for Graph resources)
- **Specific Functions:** ~10 functions (high-level helpers)
- **Total:** ~71 PowerShell functions

## Architecture & Design Patterns

### 1. Module Loading Strategy

The module uses automatic function loading via dot-sourcing in `FortigiGraph.psm1`:

```powershell
$base    = @( Get-ChildItem -Path (Join-Path $PSScriptRoot 'base') -Include *.ps1 -Recurse )
$generic = @( Get-ChildItem -Path (Join-Path $PSScriptRoot 'generic') -Include *.ps1 -Recurse )
$specific = @( Get-ChildItem -Path (Join-Path $PSScriptRoot 'specific') -Include *.ps1 -Recurse )

foreach ($import in @($base + $generic + $specific)) {
    . $import.fullname
}
```

### 2. Global State Management

The module uses global variables for token management:
- `$Global:AccessToken` - Current OAuth access token
- `$Global:ClientId` - Azure AD application client ID
- `$Global:ClientSecret` - Application secret (for service principal auth)
- `$Global:TenantId` - Azure AD tenant ID
- `$Global:RefreshToken` - Refresh token (for interactive auth)
- `$Global:DebugMode` - Debug flag ('T', 'G', 'P', 'D' or combinations)

### 3. Function Naming Convention

All functions follow PowerShell best practices:
- **Prefix:** `FG` (FortigiGraph) for all exported functions
- **Aliases:** Each function has an alias without the `FG` prefix (e.g., `Get-FGGroup` → `Get-Group`)
- **Verbs:** Standard PowerShell verbs (Get, New, Set, Add, Remove, Confirm, Invoke)
- **Pattern:** `Verb-FGNoun`

### 4. Authentication Flow

1. Call `Get-FGAccessToken` (service principal) or `Get-FGAccessTokenInteractive` (delegated)
2. Token stored in `$Global:AccessToken`
3. All `Invoke-FGGetRequest`/Post/Patch/etc. automatically:
   - Check token validity via `Confirm-FGAccessTokenValidity`
   - Auto-refresh if expired
   - Include bearer token in Authorization header

### 5. Pagination Handling

All GET requests automatically handle Microsoft Graph pagination:

```powershell
# Collect initial results
$ReturnValue = $Result.value

# Follow @odata.nextLink
While ($Result.'@odata.nextLink') {
    $Result = Invoke-RestMethod -Method Get -Uri $Result.'@odata.nextLink' -Headers @{"Authorization" = "Bearer $AccessToken" }
    $ReturnValue += $Result.value
}
```

### 6. Debug Mode

Debug output controlled via `$Global:DebugMode`:
- `'T'` - Token operations
- `'G'` - GET requests
- `'P'` - POST/PATCH requests
- `'D'` - DELETE requests
- Combine: `'GP'`, `'TPD'`, etc.

## Key Conventions for AI Assistants

### 1. File Organization

**When adding new functions:**
- **Base/** - Only for core HTTP operations and authentication
- **Generic/** - For direct Microsoft Graph API wrappers (one-to-one mapping)
- **Specific/** - For business logic that combines multiple Generic functions

**File naming:** `Verb-FGResourceAction.ps1` (e.g., `Get-FGGroupMember.ps1`)

### 2. Function Structure Template

```powershell
function Verb-FGResource {
    [alias("Verb-Resource")]
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$RequiredParam,

        [Parameter(Mandatory = $false)]
        [string]$OptionalParam
    )

    # Build URI
    $URI = 'https://graph.microsoft.com/beta/...'

    # Call appropriate Invoke-FG*Request function
    $ReturnValue = Invoke-FGGetRequest -URI $URI

    return $ReturnValue
}
```

### 3. Parameter Naming Conventions

- Use **Aliases** for common parameter names:
  - `[Alias("GroupName","Name")]` for `$DisplayName`
  - `[Alias("ObjectId")]` for `$Id`
- Prefer `DisplayName` over `Name` as primary parameter name
- Use `Id` (singular) not `Ids` for object identifiers

### 4. Graph API Version

- Default to `/beta` endpoint unless specific reason to use `/v1.0`
- Example: `https://graph.microsoft.com/beta/groups`

### 5. Error Handling

- Use `Throw` for critical errors
- Provide descriptive error messages
- Let `Invoke-FG*Request` functions handle HTTP errors

### 6. Return Values

- Return raw Graph API objects (don't transform)
- Let `Invoke-FGGetRequest` handle `.value` extraction
- Return `$null` if no results (don't return empty arrays)

### 7. Confirm-FG* Functions (Specific/)

These are idempotent functions that ensure a resource exists:

```powershell
function Confirm-FGGroup {
    # 1. Try to get existing resource
    $Group = Get-FGGroup -GroupName $GroupName

    # 2. If exists, optionally update
    if ($Group.count -eq 1) {
        Write-Host "Confirmed Group exists: $GroupName" -ForegroundColor Green
        # Update if needed
    }
    # 3. If doesn't exist, create it
    else {
        Write-Host "Creating Group: $GroupName" -ForegroundColor Yellow
        New-FGGroup @Parameters
    }

    return $Group
}
```

### 8. Write-Host Usage

- Green: Confirmation/success messages
- Yellow: Warning/action messages
- Blue: Debug messages (when `$Global:DebugMode` is set)

## Development Workflow

### Making Changes

1. **Create/Edit Functions:**
   - Add new `.ps1` files to appropriate folder (Base/Generic/Specific)
   - Follow naming conventions and structure templates
   - Include aliases for backward compatibility
   - Test locally by importing module: `Import-Module .\FortigiGraph.psd1 -Force`

2. **Testing:**
   - No automated test framework currently exists
   - Manual testing required:
     ```powershell
     Import-Module .\FortigiGraph.psd1 -Force
     Get-FGAccessToken -ClientId "..." -ClientSecret "..." -TenantId "..."
     # Test your function
     ```

3. **Version Updates:**
   - Version format: `Major.Minor.yyyyMMdd.HHmm`
   - Update in `_Build/CreatePSD.ps1`:
     ```powershell
     $VersionMajor = "1"
     $VersionMinor = "1"
     ```

4. **Building the Module:**
   - Run `_Build/CreatePSD.ps1` to regenerate `FortigiGraph.psd1`
   - This script also publishes to PowerShell Gallery (requires API key)

5. **Git Workflow:**
   - Create feature branches: `claude/feature-name-xxxxx`
   - Commit with descriptive messages: `git commit -m "Adding functionality X"`
   - Push to remote: `git push -u origin branch-name`

### Common Development Tasks

#### Adding a New GET Function

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

#### Adding a New POST/CREATE Function

1. Create file: `Generic/New-FGResource.ps1`
2. Use template:
   ```powershell
   function New-FGResource {
       [alias("New-Resource")]
       [cmdletbinding()]
       Param(
           [Parameter(Mandatory = $true)]
           [hashtable]$ResourceProperties
       )

       $URI = "https://graph.microsoft.com/beta/resources"
       $Body = $ResourceProperties | ConvertTo-Json -Depth 10

       $ReturnValue = Invoke-FGPostRequest -URI $URI -Body $Body
       return $ReturnValue
   }
   ```

#### Adding a PATCH/UPDATE Function

1. Create file: `Generic/Set-FGResource.ps1`
2. Use `Invoke-FGPatchRequest` with JSON body

#### Adding Helper/Confirm Function

1. Create file: `Specific/Confirm-FGResource.ps1`
2. Implement idempotent logic (check exists → create/update)
3. Use color-coded `Write-Host` for user feedback

## Microsoft Graph API Reference

### Common Graph Endpoints Used

- **Groups:** `/beta/groups`
- **Users:** `/beta/users`
- **Devices:** `/beta/devices`
- **Applications:** `/beta/applications`
- **Service Principals:** `/beta/servicePrincipals`
- **Access Packages:** `/beta/identityGovernance/entitlementManagement/accessPackages`
- **Catalogs:** `/beta/identityGovernance/entitlementManagement/catalogs`
- **Access Reviews:** `/beta/identityGovernance/accessReviews`

### Filter Syntax Examples

```powershell
# Display name filter
$URI = 'https://graph.microsoft.com/beta/groups?$filter=' + "displayName eq '$DisplayName'"

# ID filter
$URI = 'https://graph.microsoft.com/beta/groups?$filter=' + "id eq '$Id'"

# Multiple filters
$URI = 'https://graph.microsoft.com/beta/users?$filter=' + "userPrincipalName eq '$UPN' and accountEnabled eq true"
```

### Expanding Properties

```powershell
# Expand members
$URI = "https://graph.microsoft.com/beta/groups/$GroupId/members"

# Expand with select
$URI = "https://graph.microsoft.com/beta/groups/$GroupId?`$expand=members(`$select=id,displayName)"
```

## Important Notes for AI Assistants

### DO:
- ✅ Follow existing naming conventions (`Verb-FGNoun`)
- ✅ Add aliases without `FG` prefix
- ✅ Use `Invoke-FG*Request` functions (never call `Invoke-RestMethod` directly)
- ✅ Handle pagination automatically (already done in `Invoke-FGGetRequest`)
- ✅ Use `/beta` endpoint unless told otherwise
- ✅ Include parameter validation (`[ValidateNotNullOrEmpty()]`)
- ✅ Return raw Graph objects (don't transform)
- ✅ Use `[cmdletbinding()]` for all functions
- ✅ Place one function per file
- ✅ Test token validity (already handled in base functions)

### DON'T:
- ❌ Don't call `Invoke-RestMethod` directly (use `Invoke-FG*Request` wrappers)
- ❌ Don't transform/modify Graph API response objects
- ❌ Don't add complex error handling (base functions handle this)
- ❌ Don't hardcode credentials or tokens
- ❌ Don't create multi-function files
- ❌ Don't use `Write-Output` (use `return` directly)
- ❌ Don't add comments in Dutch (use English only)
- ❌ Don't add dependencies on external modules

### When Extending the Module:

1. **Check if function already exists:** Search Generic/ and Specific/ folders first
2. **Determine correct location:**
   - Direct Graph API call → Generic/
   - Combines multiple operations → Specific/
   - Core HTTP/auth → Base/ (rarely needed)
3. **Follow the pattern:** Look at similar existing functions
4. **Test thoroughly:** Import module and test with real Graph API
5. **Update version:** Modify `_Build/CreatePSD.ps1` if publishing

## Authentication Examples

### Service Principal (Automated Scripts)

```powershell
Get-FGAccessToken -ClientId "app-id" -ClientSecret "secret" -TenantId "tenant-id"
```

### Interactive (User Delegation)

```powershell
Get-FGAccessTokenInteractive -ClientId "app-id" -TenantId "tenant-id"
```

### Using Existing MSAL Token

```powershell
Use-FGExistingMSALToken -MSALToken $token
```

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

1. **"No Access Token found"** → Run `Get-FGAccessToken` first
2. **Token expired** → Automatic refresh should handle this
3. **Insufficient permissions** → Check Graph API permissions in Azure AD app registration
4. **Pagination not working** → Ensure using `Invoke-FGGetRequest` (handles automatically)

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

## Summary

FortigiGraph is a well-structured PowerShell module with clear separation of concerns:
- **Base** handles authentication and HTTP operations
- **Generic** provides direct Graph API wrappers
- **Specific** offers higher-level business logic

When working with this codebase, always follow the established patterns, use the existing `Invoke-FG*Request` functions, and maintain consistency with the naming conventions. The module is designed for simplicity and ease of use, so avoid over-engineering solutions.
