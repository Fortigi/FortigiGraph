function New-FGConfig {
    <#
    .SYNOPSIS
        Creates a new FortigiGraph configuration file interactively.

    .DESCRIPTION
        Walks you through setting up a FortigiGraph configuration file step by step.
        Uses Connect-AzAccount to authenticate and then lets you pick your subscription,
        resource group, and SQL server from lists - no manual GUID typing needed.
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
        - Requires Az PowerShell module (Install-Module Az)
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
    Write-Host ""

    # ============================================================
    # Azure Login
    # ============================================================
    Write-Host "--- Azure Login ---" -ForegroundColor Cyan

    # Check if already logged in
    $azContext = $null
    try {
        $azContext = Get-AzContext -ErrorAction Stop
    } catch { }

    if ($azContext -and $azContext.Account) {
        Write-Host "  Logged in as: $($azContext.Account.Id)" -ForegroundColor Green
        Write-Host "  Tenant:       $($azContext.Tenant.Id)" -ForegroundColor Green
        $relogin = Read-Host "  Use this account? (Y/n)"
        if ($relogin -eq 'n' -or $relogin -eq 'N') {
            Write-Host "  Opening Azure login..." -ForegroundColor Cyan
            Connect-AzAccount | Out-Null
            $azContext = Get-AzContext
        }
    } else {
        Write-Host "  Not logged in. Opening Azure login..." -ForegroundColor Cyan
        Connect-AzAccount | Out-Null
        $azContext = Get-AzContext
    }

    $tenantId = $azContext.Tenant.Id
    Write-Host ""

    # ============================================================
    # Select Subscription
    # ============================================================
    Write-Host "--- Select Subscription ---" -ForegroundColor Cyan

    $subscriptions = @(Get-AzSubscription -TenantId $tenantId -ErrorAction Stop | Sort-Object Name)

    if ($subscriptions.Count -eq 0) {
        Write-Host "  No subscriptions found for this tenant." -ForegroundColor Red
        return
    } elseif ($subscriptions.Count -eq 1) {
        $selectedSub = $subscriptions[0]
        Write-Host "  Found 1 subscription: $($selectedSub.Name)" -ForegroundColor Green
    } else {
        Write-Host ""
        for ($i = 0; $i -lt $subscriptions.Count; $i++) {
            Write-Host "  [$($i + 1)] $($subscriptions[$i].Name) ($($subscriptions[$i].Id))" -ForegroundColor White
        }
        Write-Host ""

        do {
            $subChoice = Read-Host "  Select subscription (1-$($subscriptions.Count))"
            $subIndex = 0
            $validChoice = [int]::TryParse($subChoice, [ref]$subIndex) -and $subIndex -ge 1 -and $subIndex -le $subscriptions.Count
            if (-not $validChoice) {
                Write-Host "  Please enter a number between 1 and $($subscriptions.Count)" -ForegroundColor Yellow
            }
        } while (-not $validChoice)

        $selectedSub = $subscriptions[$subIndex - 1]
    }

    $subscriptionId = $selectedSub.Id
    Set-AzContext -SubscriptionId $subscriptionId | Out-Null
    Write-Host "  Selected: $($selectedSub.Name)" -ForegroundColor Green
    Write-Host ""

    # ============================================================
    # Select Resource Group
    # ============================================================
    Write-Host "--- Select Resource Group ---" -ForegroundColor Cyan

    $resourceGroups = @(Get-AzResourceGroup -ErrorAction Stop | Sort-Object ResourceGroupName)

    if ($resourceGroups.Count -eq 0) {
        Write-Host "  No resource groups found. Enter a name for a new one:" -ForegroundColor Yellow
        $resourceGroupName = Read-Host "  Resource Group Name"
        $location = Read-Host "  Location [northeurope]"
        if ([string]::IsNullOrWhiteSpace($location)) { $location = "northeurope" }
    } else {
        Write-Host ""
        for ($i = 0; $i -lt $resourceGroups.Count; $i++) {
            Write-Host "  [$($i + 1)] $($resourceGroups[$i].ResourceGroupName) ($($resourceGroups[$i].Location))" -ForegroundColor White
        }
        Write-Host "  [N] Create new resource group" -ForegroundColor White
        Write-Host ""

        do {
            $rgChoice = Read-Host "  Select resource group (1-$($resourceGroups.Count)) or N for new"
            if ($rgChoice -eq 'n' -or $rgChoice -eq 'N') {
                $validChoice = $true
                $rgIndex = -1
            } else {
                $rgIndex = 0
                $validChoice = [int]::TryParse($rgChoice, [ref]$rgIndex) -and $rgIndex -ge 1 -and $rgIndex -le $resourceGroups.Count
            }
            if (-not $validChoice) {
                Write-Host "  Please enter a number between 1 and $($resourceGroups.Count), or N" -ForegroundColor Yellow
            }
        } while (-not $validChoice)

        if ($rgIndex -eq -1) {
            $resourceGroupName = Read-Host "  New Resource Group Name"
            $location = Read-Host "  Location [northeurope]"
            if ([string]::IsNullOrWhiteSpace($location)) { $location = "northeurope" }
        } else {
            $selectedRg = $resourceGroups[$rgIndex - 1]
            $resourceGroupName = $selectedRg.ResourceGroupName
            $location = $selectedRg.Location
            Write-Host "  Selected: $resourceGroupName ($location)" -ForegroundColor Green
        }
    }
    Write-Host ""

    # ============================================================
    # SQL Server
    # ============================================================
    Write-Host "--- SQL Server ---" -ForegroundColor Cyan

    # Try to find existing SQL servers in the selected resource group
    $sqlServers = @()
    try {
        $sqlServers = @(Get-AzSqlServer -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue | Sort-Object ServerName)
    } catch { }

    if ($sqlServers.Count -gt 0) {
        Write-Host ""
        for ($i = 0; $i -lt $sqlServers.Count; $i++) {
            Write-Host "  [$($i + 1)] $($sqlServers[$i].ServerName) ($($sqlServers[$i].Location))" -ForegroundColor White
        }
        Write-Host "  [N] Enter a new SQL Server name" -ForegroundColor White
        Write-Host ""

        do {
            $sqlChoice = Read-Host "  Select SQL Server (1-$($sqlServers.Count)) or N for new"
            if ($sqlChoice -eq 'n' -or $sqlChoice -eq 'N') {
                $validChoice = $true
                $sqlIndex = -1
            } else {
                $sqlIndex = 0
                $validChoice = [int]::TryParse($sqlChoice, [ref]$sqlIndex) -and $sqlIndex -ge 1 -and $sqlIndex -le $sqlServers.Count
            }
            if (-not $validChoice) {
                Write-Host "  Please enter a number between 1 and $($sqlServers.Count), or N" -ForegroundColor Yellow
            }
        } while (-not $validChoice)

        if ($sqlIndex -eq -1) {
            $defaultSqlName = New-FGRandomSqlName
            $sqlInput = Read-Host "  SQL Server Name [$defaultSqlName]"
            $sqlServerName = if ([string]::IsNullOrWhiteSpace($sqlInput)) { $defaultSqlName } else { $sqlInput }
        } else {
            $sqlServerName = $sqlServers[$sqlIndex - 1].ServerName
            Write-Host "  Selected: $sqlServerName" -ForegroundColor Green
        }
    } else {
        $defaultSqlName = New-FGRandomSqlName
        Write-Host "  No SQL Servers found in $resourceGroupName." -ForegroundColor Gray
        Write-Host "  A new one will be created automatically on first sync." -ForegroundColor Gray
        $sqlInput = Read-Host "  SQL Server Name [$defaultSqlName]"
        $sqlServerName = if ([string]::IsNullOrWhiteSpace($sqlInput)) { $defaultSqlName } else { $sqlInput }
    }

    Write-Host "  Server: $sqlServerName" -ForegroundColor Green

    # Database name
    $databaseName = "GraphData"
    $selectedSqlServer = $sqlServers | Where-Object { $_.ServerName -eq $sqlServerName }
    if ($selectedSqlServer) {
        $databases = @()
        try {
            $databases = @(Get-AzSqlDatabase -ResourceGroupName $resourceGroupName -ServerName $sqlServerName -ErrorAction SilentlyContinue |
                Where-Object { $_.DatabaseName -ne 'master' } | Sort-Object DatabaseName)
        } catch { }

        if ($databases.Count -gt 0) {
            Write-Host ""
            for ($i = 0; $i -lt $databases.Count; $i++) {
                Write-Host "  [$($i + 1)] $($databases[$i].DatabaseName)" -ForegroundColor White
            }
            Write-Host "  [N] Enter a new database name" -ForegroundColor White
            Write-Host ""

            do {
                $dbChoice = Read-Host "  Select database (1-$($databases.Count)) or N for new"
                if ($dbChoice -eq 'n' -or $dbChoice -eq 'N') {
                    $validChoice = $true
                    $dbIndex = -1
                } else {
                    $dbIndex = 0
                    $validChoice = [int]::TryParse($dbChoice, [ref]$dbIndex) -and $dbIndex -ge 1 -and $dbIndex -le $databases.Count
                }
                if (-not $validChoice) {
                    Write-Host "  Please enter a number between 1 and $($databases.Count), or N" -ForegroundColor Yellow
                }
            } while (-not $validChoice)

            if ($dbIndex -eq -1) {
                $dbInput = Read-Host "  Database Name [GraphData]"
                if (-not [string]::IsNullOrWhiteSpace($dbInput)) { $databaseName = $dbInput }
            } else {
                $databaseName = $databases[$dbIndex - 1].DatabaseName
                Write-Host "  Selected: $databaseName" -ForegroundColor Green
            }
        } else {
            $dbInput = Read-Host "  Database Name [GraphData]"
            if (-not [string]::IsNullOrWhiteSpace($dbInput)) { $databaseName = $dbInput }
        }
    } else {
        $dbInput = Read-Host "  Database Name [GraphData]"
        if (-not [string]::IsNullOrWhiteSpace($dbInput)) { $databaseName = $dbInput }
    }

    Write-Host ""

    # SQL credentials
    Write-Host "--- SQL Credentials ---" -ForegroundColor Cyan

    $adminUsernameInput = Read-Host "  SQL Admin Username [sqladmin]"
    $adminUsername = if ([string]::IsNullOrWhiteSpace($adminUsernameInput)) { "sqladmin" } else { $adminUsernameInput }

    # Auto-generate a complex password by default
    $generatedPassword = New-FGRandomPassword
    Write-Host "  SQL Admin Password (auto-generated): $generatedPassword" -ForegroundColor Green
    $useGenerated = Read-Host "  Use this password? (Y/n)"

    if ($useGenerated -eq 'n' -or $useGenerated -eq 'N') {
        Write-Host "  Enter your own password: " -ForegroundColor Gray -NoNewline
        $adminPassword = Read-Host -AsSecureString
    } else {
        $adminPassword = $generatedPassword | ConvertTo-SecureString -AsPlainText -Force
    }

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
    Write-Host "  Using Tenant: $tenantId" -ForegroundColor Green

    $graphTenantId = $tenantId

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

function New-FGRandomPassword {
    <#
    .SYNOPSIS
        Internal helper for New-FGConfig. Generates a cryptographically random complex password.
    #>

    [cmdletbinding()]
    Param(
        [int]$Length = 24
    )

    $upper   = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    $lower   = 'abcdefghijklmnopqrstuvwxyz'
    $digits  = '0123456789'
    $special = '!@#$%^&*'
    $all     = $upper + $lower + $digits + $special

    # Ensure at least one of each category
    $bytes = [byte[]]::new(4)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $password = @(
        $upper[$bytes[0] % $upper.Length]
        $lower[$bytes[1] % $lower.Length]
        $digits[$bytes[2] % $digits.Length]
        $special[$bytes[3] % $special.Length]
    )

    # Fill the rest randomly
    $remaining = $Length - 4
    $bytes = [byte[]]::new($remaining)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    for ($i = 0; $i -lt $remaining; $i++) {
        $password += $all[$bytes[$i] % $all.Length]
    }

    # Shuffle the password so the guaranteed chars aren't always at the start
    $shuffleBytes = [byte[]]::new($password.Count)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($shuffleBytes)
    $password = ($password | Sort-Object { [System.Security.Cryptography.RandomNumberGenerator]::GetInt32([int]::MaxValue) }) -join ''

    return $password
}

function New-FGRandomSqlName {
    <#
    .SYNOPSIS
        Internal helper for New-FGConfig. Generates a unique SQL Server name suggestion.
    #>

    [cmdletbinding()]
    Param()

    $chars = 'abcdefghijklmnopqrstuvwxyz0123456789'
    $bytes = [byte[]]::new(5)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $suffix = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })

    return "sql-fortigraph-$suffix"
}
