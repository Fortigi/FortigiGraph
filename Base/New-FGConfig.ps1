function New-FGConfig {
    <#
    .SYNOPSIS
        Creates a new FortigiGraph configuration file interactively.

    .DESCRIPTION
        Walks you through setting up a FortigiGraph configuration file step by step.
        Asks for Azure, Graph API, and Sync settings with sensible defaults.
        Passwords and secrets are encrypted using Windows DPAPI automatically.

        The generated config file works with:
        - Get-FGAccessToken -ConfigFile
        - Connect-FGSQLServer -ConfigFile
        - Start-FGSync -ConfigFile

    .PARAMETER Path
        Path where the config file will be saved.
        Example: ".\Config\mycompany.json" or "C:\Config\production.json"

    .PARAMETER Quick
        Only ask for essential settings (Azure + Graph credentials).
        All sync settings use defaults (everything enabled).

    .EXAMPLE
        New-FGConfig -Path ".\Config\mycompany.json"
        Creates a new config file with full interactive setup.

    .EXAMPLE
        New-FGConfig -Path ".\Config\mycompany.json" -Quick
        Creates a config file asking only for essential credentials.

    .NOTES
        - Passwords are encrypted using Windows DPAPI (user-specific, machine-specific)
        - The config file can be further customized by editing the JSON directly
        - Use Get-FGSecureConfigValue to read encrypted values programmatically
    #>

    [alias("New-Config")]
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [switch]$Quick
    )

    # Check if file already exists
    if (Test-Path $Path) {
        Write-Host ""
        Write-Host "Config file already exists: $Path" -ForegroundColor Yellow
        $overwrite = Read-Host "Overwrite? (y/N)"
        if ($overwrite -ne 'y' -and $overwrite -ne 'Y') {
            Write-Host "Cancelled." -ForegroundColor Gray
            return
        }
    }

    # Ensure parent directory exists
    $parentDir = Split-Path -Path $Path -Parent
    if ($parentDir -and -not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    Write-Host ""
    Write-Host "=== FortigiGraph Configuration Setup ===" -ForegroundColor Cyan
    Write-Host "This wizard will help you create a config file." -ForegroundColor Gray
    Write-Host "Press Enter to accept [default values]." -ForegroundColor Gray
    Write-Host ""

    # ============================================================
    # Azure Settings
    # ============================================================
    Write-Host "--- Azure Settings ---" -ForegroundColor Cyan

    $tenantId = Read-Host "  TenantId (e.g. contoso.onmicrosoft.com)"
    if ([string]::IsNullOrWhiteSpace($tenantId)) {
        Write-Host "  TenantId is required." -ForegroundColor Red
        return
    }

    $subscriptionId = Read-Host "  SubscriptionId (Azure subscription GUID)"
    if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
        Write-Host "  SubscriptionId is required." -ForegroundColor Red
        return
    }

    $resourceGroupName = Read-Host "  ResourceGroupName"
    if ([string]::IsNullOrWhiteSpace($resourceGroupName)) {
        Write-Host "  ResourceGroupName is required." -ForegroundColor Red
        return
    }

    $locationInput = Read-Host "  Location [northeurope]"
    $location = if ([string]::IsNullOrWhiteSpace($locationInput)) { "northeurope" } else { $locationInput }

    $sqlServerName = Read-Host "  SQL Server Name (without .database.windows.net)"
    if ([string]::IsNullOrWhiteSpace($sqlServerName)) {
        Write-Host "  SQL Server Name is required." -ForegroundColor Red
        return
    }

    $databaseNameInput = Read-Host "  Database Name [GraphData]"
    $databaseName = if ([string]::IsNullOrWhiteSpace($databaseNameInput)) { "GraphData" } else { $databaseNameInput }

    $adminUsernameInput = Read-Host "  SQL Admin Username [sqladmin]"
    $adminUsername = if ([string]::IsNullOrWhiteSpace($adminUsernameInput)) { "sqladmin" } else { $adminUsernameInput }

    Write-Host "  SQL Admin Password: " -ForegroundColor Gray -NoNewline
    $adminPassword = Read-Host -AsSecureString

    # Encrypt the password
    $adminPasswordEncrypted = ""
    if ($adminPassword.Length -gt 0) {
        $adminPasswordEncrypted = $adminPassword | ConvertFrom-SecureString
    }

    Write-Host ""

    # ============================================================
    # Graph API Settings
    # ============================================================
    Write-Host "--- Graph API Settings ---" -ForegroundColor Cyan
    Write-Host "  (From your Azure AD App Registration)" -ForegroundColor Gray

    $graphTenantIdInput = Read-Host "  Graph TenantId [$tenantId]"
    $graphTenantId = if ([string]::IsNullOrWhiteSpace($graphTenantIdInput)) { $tenantId } else { $graphTenantIdInput }

    $clientId = Read-Host "  Client ID (Application ID)"
    if ([string]::IsNullOrWhiteSpace($clientId)) {
        Write-Host "  Client ID is required." -ForegroundColor Red
        return
    }

    Write-Host "  Client Secret: " -ForegroundColor Gray -NoNewline
    $clientSecret = Read-Host -AsSecureString

    # Encrypt the secret
    $clientSecretEncrypted = ""
    if ($clientSecret.Length -gt 0) {
        $clientSecretEncrypted = $clientSecret | ConvertFrom-SecureString
    }

    Write-Host ""

    # ============================================================
    # Sync Settings
    # ============================================================
    $syncConfig = @{
        Users = @{ Enabled = $true; TableName = "GraphUsers"; Filter = ""; AdditionalAttributes = @() }
        Groups = @{ Enabled = $true; TableName = "GraphGroups"; Filter = "" }
        GroupMembers = @{ Enabled = $true; TableName = "GraphGroupMembers" }
        GroupTransitiveMembers = @{ Enabled = $true; TableName = "GraphGroupTransitiveMembers" }
        GroupEligibleMembers = @{ Enabled = $false }
        GroupOwners = @{ Enabled = $true; TableName = "GraphGroupOwners" }
        Catalogs = @{ Enabled = $true; TableName = "GraphCatalogs" }
        AccessPackages = @{ Enabled = $true; TableName = "GraphAccessPackages" }
        AccessPackageAssignments = @{ Enabled = $true; TableName = "GraphAccessPackageAssignments" }
        AccessPackageResourceRoleScopes = @{ Enabled = $true; TableName = "GraphAccessPackageResourceRoleScopes" }
        AccessPackageAssignmentPolicies = @{ Enabled = $true; TableName = "GraphAccessPackageAssignmentPolicies" }
        AccessPackageAssignmentRequests = @{ Enabled = $true; TableName = "GraphAccessPackageAssignmentRequests" }
        AccessPackageAccessReviews = @{ Enabled = $true; TableName = "GraphAccessPackageAccessReviewDecisions" }
        Views = @{ Enabled = $true }
        ParallelExecution = $true
    }

    if (-not $Quick) {
        Write-Host "--- Sync Settings ---" -ForegroundColor Cyan
        Write-Host "  Which data would you like to sync? (Y/n for each)" -ForegroundColor Gray
        Write-Host ""

        # Core data
        $syncConfig.Users.Enabled = (Read-FGConfigYesNo -Prompt "  Sync Users" -Default $true)
        $syncConfig.Groups.Enabled = (Read-FGConfigYesNo -Prompt "  Sync Groups" -Default $true)
        $syncConfig.GroupMembers.Enabled = (Read-FGConfigYesNo -Prompt "  Sync Group Members (direct)" -Default $true)
        $syncConfig.GroupTransitiveMembers.Enabled = (Read-FGConfigYesNo -Prompt "  Sync Group Transitive Members (nested)" -Default $true)
        $syncConfig.GroupEligibleMembers.Enabled = (Read-FGConfigYesNo -Prompt "  Sync Group Eligible Members (PIM)" -Default $false)
        $syncConfig.GroupOwners.Enabled = (Read-FGConfigYesNo -Prompt "  Sync Group Owners" -Default $true)

        Write-Host ""

        # Access Packages
        $enableAccessPackages = (Read-FGConfigYesNo -Prompt "  Sync Access Packages (Identity Governance)" -Default $true)

        if ($enableAccessPackages) {
            $syncConfig.Catalogs.Enabled = $true
            $syncConfig.AccessPackages.Enabled = $true
            $syncConfig.AccessPackageAssignments.Enabled = $true
            $syncConfig.AccessPackageResourceRoleScopes.Enabled = $true
            $syncConfig.AccessPackageAssignmentPolicies.Enabled = $true
            $syncConfig.AccessPackageAssignmentRequests.Enabled = $true
            $syncConfig.AccessPackageAccessReviews.Enabled = $true
        } else {
            $syncConfig.Catalogs.Enabled = $false
            $syncConfig.AccessPackages.Enabled = $false
            $syncConfig.AccessPackageAssignments.Enabled = $false
            $syncConfig.AccessPackageResourceRoleScopes.Enabled = $false
            $syncConfig.AccessPackageAssignmentPolicies.Enabled = $false
            $syncConfig.AccessPackageAssignmentRequests.Enabled = $false
            $syncConfig.AccessPackageAccessReviews.Enabled = $false
        }

        Write-Host ""

        # Additional user attributes
        if ($syncConfig.Users.Enabled) {
            Write-Host "  Additional user attributes to sync (comma-separated, or Enter to skip)" -ForegroundColor Gray
            Write-Host "  Examples: officeLocation, city, country, employeeType" -ForegroundColor Gray
            $attrsInput = Read-Host "  Additional attributes"
            if (-not [string]::IsNullOrWhiteSpace($attrsInput)) {
                $syncConfig.Users.AdditionalAttributes = @($attrsInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
            }
        }

        Write-Host ""
    } else {
        Write-Host "Using default sync settings (all enabled)." -ForegroundColor Gray
        Write-Host ""
    }

    # ============================================================
    # Build the config object
    # ============================================================
    $config = [ordered]@{
        Azure = [ordered]@{
            TenantId                    = $tenantId
            SubscriptionId              = $subscriptionId
            ResourceGroupName           = $resourceGroupName
            Location                    = $location
            SQLServerName               = $sqlServerName
            DatabaseName                = $databaseName
            AdminUsername               = $adminUsername
            AdminUserPassword_Encrypted = $adminPasswordEncrypted
        }
        Graph = [ordered]@{
            TenantId               = $graphTenantId
            ClientId               = $clientId
            ClientSecret_Encrypted = $clientSecretEncrypted
        }
        Sync = [ordered]@{
            Users                            = [ordered]@{
                Enabled              = $syncConfig.Users.Enabled
                TableName            = $syncConfig.Users.TableName
                Filter               = $syncConfig.Users.Filter
                AdditionalAttributes = $syncConfig.Users.AdditionalAttributes
            }
            Groups                           = [ordered]@{
                Enabled   = $syncConfig.Groups.Enabled
                TableName = $syncConfig.Groups.TableName
                Filter    = $syncConfig.Groups.Filter
            }
            GroupMembers                     = [ordered]@{
                Enabled   = $syncConfig.GroupMembers.Enabled
                TableName = $syncConfig.GroupMembers.TableName
            }
            GroupTransitiveMembers           = [ordered]@{
                Enabled   = $syncConfig.GroupTransitiveMembers.Enabled
                TableName = $syncConfig.GroupTransitiveMembers.TableName
            }
            GroupEligibleMembers             = [ordered]@{
                Enabled = $syncConfig.GroupEligibleMembers.Enabled
            }
            GroupOwners                      = [ordered]@{
                Enabled   = $syncConfig.GroupOwners.Enabled
                TableName = $syncConfig.GroupOwners.TableName
            }
            Catalogs                         = [ordered]@{
                Enabled   = $syncConfig.Catalogs.Enabled
                TableName = $syncConfig.Catalogs.TableName
            }
            AccessPackages                   = [ordered]@{
                Enabled   = $syncConfig.AccessPackages.Enabled
                TableName = $syncConfig.AccessPackages.TableName
            }
            AccessPackageAssignments         = [ordered]@{
                Enabled   = $syncConfig.AccessPackageAssignments.Enabled
                TableName = $syncConfig.AccessPackageAssignments.TableName
            }
            AccessPackageResourceRoleScopes  = [ordered]@{
                Enabled   = $syncConfig.AccessPackageResourceRoleScopes.Enabled
                TableName = $syncConfig.AccessPackageResourceRoleScopes.TableName
            }
            AccessPackageAssignmentPolicies  = [ordered]@{
                Enabled   = $syncConfig.AccessPackageAssignmentPolicies.Enabled
                TableName = $syncConfig.AccessPackageAssignmentPolicies.TableName
            }
            AccessPackageAssignmentRequests  = [ordered]@{
                Enabled   = $syncConfig.AccessPackageAssignmentRequests.Enabled
                TableName = $syncConfig.AccessPackageAssignmentRequests.TableName
            }
            AccessPackageAccessReviews       = [ordered]@{
                Enabled   = $syncConfig.AccessPackageAccessReviews.Enabled
                TableName = $syncConfig.AccessPackageAccessReviews.TableName
            }
            Views                            = [ordered]@{
                Enabled = $syncConfig.Views.Enabled
            }
            ParallelExecution                = $syncConfig.ParallelExecution
        }
    }

    # ============================================================
    # Save the config file
    # ============================================================
    $config | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Force

    Write-Host "Config file saved to: $Path" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "  1. Get-FGAccessToken -ConfigFile '$Path'" -ForegroundColor White
    Write-Host "  2. Connect-FGSQLServer -ConfigFile '$Path'" -ForegroundColor White
    Write-Host "  3. Start-FGSync -ConfigFile '$Path'" -ForegroundColor White
    Write-Host ""

    return $Path
}

function Read-FGConfigYesNo {
    <#
    .SYNOPSIS
        Internal helper for New-FGConfig. Prompts for a yes/no answer with a default.
    #>

    [cmdletbinding()]
    Param(
        [string]$Prompt,
        [bool]$Default
    )

    $defaultText = if ($Default) { "Y/n" } else { "y/N" }
    $answer = Read-Host "$Prompt [$defaultText]"

    if ([string]::IsNullOrWhiteSpace($answer)) {
        return $Default
    }

    return ($answer -eq 'y' -or $answer -eq 'Y')
}
