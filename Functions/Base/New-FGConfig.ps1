function New-FGConfig {
    <#
    .SYNOPSIS
        Creates a new FortigiGraph configuration file and provisions Azure resources.

    .DESCRIPTION
        Walks you through setting up a FortigiGraph environment step by step:
        1. Logs into Azure (or reuses existing session)
        2. Selects or creates a subscription, resource group
        3. Creates a SQL Server + database (or picks existing)
        4. Creates an Automation Account (or picks existing)
        5. Creates an App Registration with correct Graph API permissions
        6. Configures sync settings
        7. Saves everything to an encrypted config file

        All passwords and secrets are encrypted using Windows DPAPI.

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
        Creates a new config file with full interactive setup and provisions resources.

    .EXAMPLE
        New-FGConfig -Path ".\Config\mycompany.json" -Quick
        Creates a config file asking only for essential credentials.

    .NOTES
        - Requires Az modules: Az.Accounts, Az.Resources, Az.Sql, Az.Automation
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

    # Require PowerShell 7+ (cross-platform support, modern .NET APIs)
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "New-FGConfig requires PowerShell 7 or later. You are running PowerShell $($PSVersionTable.PSVersion). Please install PowerShell 7+ from https://aka.ms/powershell"
    }

    # Require Az sub-modules — install any that are missing
    $requiredModules = @('Az.Accounts', 'Az.Resources', 'Az.Sql', 'Az.Automation')
    $missingModules = $requiredModules | Where-Object { -not (Get-Module -ListAvailable -Name $_) }
    if ($missingModules.Count -gt 0) {
        Write-Host ""
        Write-Host "  The following required PowerShell modules are not installed:" -ForegroundColor Yellow
        $missingModules | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
        Write-Host ""
        $install = Read-Host "  Install them now? (Y/n)"
        if ($install -eq 'n' -or $install -eq 'N') {
            Write-Host "  Cancelled." -ForegroundColor Gray
            return
        }
        foreach ($mod in $missingModules) {
            Write-Host "  Installing $mod..." -ForegroundColor Cyan
            try {
                Install-Module -Name $mod -Repository PSGallery -Force -AllowClobber -Scope CurrentUser -ErrorAction Stop
                Write-Host "  $mod installed successfully." -ForegroundColor Green
            } catch {
                Write-Host "  Failed to install $mod`: $_" -ForegroundColor Red
                return
            }
        }
        Write-Host ""
    }

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
    Write-Host "This wizard will set up your FortigiGraph environment." -ForegroundColor Gray
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
            Write-Host "  Logging in via device code..." -ForegroundColor Cyan
            Write-Host "  (Open the URL shown below and enter the code to authenticate)" -ForegroundColor Gray
            Connect-AzAccount -UseDeviceAuthentication | Out-Null
            $azContext = Get-AzContext
        }
    } else {
        Write-Host "  Not logged in. Starting device code login..." -ForegroundColor Cyan
        Write-Host "  (Open the URL shown below and enter the code to authenticate)" -ForegroundColor Gray
        Connect-AzAccount -UseDeviceAuthentication | Out-Null
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
    # Select or Create Resource Group
    # ============================================================
    Write-Host "--- Resource Group ---" -ForegroundColor Cyan

    $resourceGroups = @(Get-AzResourceGroup -ErrorAction Stop | Sort-Object ResourceGroupName)
    $createNewRg = $false

    if ($resourceGroups.Count -eq 0) {
        Write-Host "  No resource groups found." -ForegroundColor Gray
        $createNewRg = $true
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
            $createNewRg = $true
        } else {
            $selectedRg = $resourceGroups[$rgIndex - 1]
            $resourceGroupName = $selectedRg.ResourceGroupName
            $location = $selectedRg.Location
            Write-Host "  Selected: $resourceGroupName ($location)" -ForegroundColor Green
        }
    }

    if ($createNewRg) {
        $defaultRgName = "rg-fortigraph"
        $rgInput = Read-Host "  Resource Group Name [$defaultRgName]"
        $resourceGroupName = if ([string]::IsNullOrWhiteSpace($rgInput)) { $defaultRgName } else { $rgInput }

        $locationInput = Read-Host "  Location [northeurope]"
        $location = if ([string]::IsNullOrWhiteSpace($locationInput)) { "northeurope" } else { $locationInput }

        Write-Host "  Creating resource group: $resourceGroupName ($location)..." -ForegroundColor Cyan
        try {
            New-AzResourceGroup -Name $resourceGroupName -Location $location -ErrorAction Stop | Out-Null
            Write-Host "  Resource group created" -ForegroundColor Green
        } catch {
            Write-Host "  Failed to create resource group: $_" -ForegroundColor Red
            return
        }
    }
    Write-Host ""

    # ============================================================
    # SQL Server + Database
    # ============================================================
    Write-Host "--- SQL Server ---" -ForegroundColor Cyan

    # First check for existing SQL servers before asking for credentials
    $sqlServers = @()
    try {
        $sqlServers = @(Get-AzSqlServer -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue | Sort-Object ServerName)
    } catch { }

    $createNewSql = $false

    if ($sqlServers.Count -gt 0) {
        Write-Host ""
        for ($i = 0; $i -lt $sqlServers.Count; $i++) {
            Write-Host "  [$($i + 1)] $($sqlServers[$i].ServerName) ($($sqlServers[$i].Location))" -ForegroundColor White
        }
        Write-Host "  [N] Create a new SQL Server" -ForegroundColor White
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
            $createNewSql = $true
        } else {
            $sqlServerName = $sqlServers[$sqlIndex - 1].ServerName
            Write-Host "  Selected: $sqlServerName" -ForegroundColor Green
        }
    } else {
        $createNewSql = $true
    }

    # Now ask for credentials - context depends on new vs existing server
    Write-Host ""
    $adminUsernameInput = Read-Host "  SQL Admin Username [sqladmin]"
    $adminUsername = if ([string]::IsNullOrWhiteSpace($adminUsernameInput)) { "sqladmin" } else { $adminUsernameInput }

    if ($createNewSql) {
        # New server: offer auto-generated password
        $generatedPassword = New-FGRandomPassword
        Write-Host "  SQL Admin Password (auto-generated): $generatedPassword" -ForegroundColor Green
        $useGenerated = Read-Host "  Use this password? (Y/n)"

        if ($useGenerated -eq 'n' -or $useGenerated -eq 'N') {
            Write-Host "  Enter your own password: " -ForegroundColor Gray -NoNewline
            $adminPassword = Read-Host -AsSecureString
        } else {
            $adminPassword = $generatedPassword | ConvertTo-SecureString -AsPlainText -Force
        }
    } else {
        # Existing server: ask for the current password
        Write-Host "  SQL Admin Password: " -ForegroundColor Gray -NoNewline
        $adminPassword = Read-Host -AsSecureString
    }

    $adminPasswordEncrypted = ""
    if ($adminPassword.Length -gt 0) {
        $adminPasswordEncrypted = $adminPassword | ConvertFrom-SecureString
    }

    Write-Host ""

    if ($createNewSql) {
        $defaultSqlName = New-FGRandomSqlName
        $sqlInput = Read-Host "  SQL Server Name [$defaultSqlName]"
        $sqlServerName = if ([string]::IsNullOrWhiteSpace($sqlInput)) { $defaultSqlName } else { $sqlInput }

        Write-Host "  Creating SQL Server: $sqlServerName..." -ForegroundColor Cyan
        try {
            $sqlCred = New-Object System.Management.Automation.PSCredential($adminUsername, $adminPassword)
            New-AzSqlServer -ResourceGroupName $resourceGroupName -ServerName $sqlServerName -Location $location -SqlAdministratorCredentials $sqlCred -ErrorAction Stop | Out-Null
            Write-Host "  SQL Server created: $sqlServerName.database.windows.net" -ForegroundColor Green
        } catch {
            Write-Host "  Failed to create SQL Server: $_" -ForegroundColor Red
            Write-Host "  The name will be saved in config - you can create it later." -ForegroundColor Yellow
        }
    }

    # Database
    $databaseName = "GraphData"
    $createNewDb = $false
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
            Write-Host "  [N] Create a new database" -ForegroundColor White
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
                $createNewDb = $true
            } else {
                $databaseName = $databases[$dbIndex - 1].DatabaseName
                Write-Host "  Selected: $databaseName" -ForegroundColor Green
            }
        } else {
            $createNewDb = $true
        }
    } else {
        $createNewDb = $true
    }

    if ($createNewDb) {
        $dbInput = Read-Host "  Database Name [GraphData]"
        if (-not [string]::IsNullOrWhiteSpace($dbInput)) { $databaseName = $dbInput }

        # Only create if the SQL server exists (was just created or already existed)
        try {
            $existingServer = Get-AzSqlServer -ResourceGroupName $resourceGroupName -ServerName $sqlServerName -ErrorAction SilentlyContinue
            if ($existingServer) {
                Write-Host "  Creating database: $databaseName..." -ForegroundColor Cyan
                New-AzSqlDatabase -ResourceGroupName $resourceGroupName -ServerName $sqlServerName -DatabaseName $databaseName -Edition "Basic" -ErrorAction Stop | Out-Null
                Write-Host "  Database created" -ForegroundColor Green
            }
        } catch {
            if ($_.Exception.Message -like "*already exists*") {
                Write-Host "  Database already exists" -ForegroundColor Green
            } else {
                Write-Host "  Could not create database: $_" -ForegroundColor Yellow
                Write-Host "  The name will be saved in config - it will be created on first sync." -ForegroundColor Gray
            }
        }
    }

    Write-Host ""

    # ============================================================
    # Automation Account
    # ============================================================
    Write-Host "--- Automation Account ---" -ForegroundColor Cyan

    $automationAccounts = @()
    try {
        $automationAccounts = @(Get-AzAutomationAccount -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue | Sort-Object AutomationAccountName)
    } catch { }

    $createNewAa = $false

    if ($automationAccounts.Count -gt 0) {
        Write-Host ""
        for ($i = 0; $i -lt $automationAccounts.Count; $i++) {
            Write-Host "  [$($i + 1)] $($automationAccounts[$i].AutomationAccountName)" -ForegroundColor White
        }
        Write-Host "  [N] Create a new Automation Account" -ForegroundColor White
        Write-Host ""

        do {
            $aaChoice = Read-Host "  Select Automation Account (1-$($automationAccounts.Count)) or N for new"
            if ($aaChoice -eq 'n' -or $aaChoice -eq 'N') {
                $validChoice = $true
                $aaIndex = -1
            } else {
                $aaIndex = 0
                $validChoice = [int]::TryParse($aaChoice, [ref]$aaIndex) -and $aaIndex -ge 1 -and $aaIndex -le $automationAccounts.Count
            }
            if (-not $validChoice) {
                Write-Host "  Please enter a number between 1 and $($automationAccounts.Count), or N" -ForegroundColor Yellow
            }
        } while (-not $validChoice)

        if ($aaIndex -eq -1) {
            $createNewAa = $true
        } else {
            $automationAccountName = $automationAccounts[$aaIndex - 1].AutomationAccountName
            Write-Host "  Selected: $automationAccountName" -ForegroundColor Green
        }
    } else {
        $createNewAa = $true
    }

    if ($createNewAa) {
        $defaultAaName = New-FGRandomAutomationAccountName
        $aaInput = Read-Host "  Automation Account Name [$defaultAaName]"
        $automationAccountName = if ([string]::IsNullOrWhiteSpace($aaInput)) { $defaultAaName } else { $aaInput }

        Write-Host "  Creating Automation Account: $automationAccountName..." -ForegroundColor Cyan
        try {
            New-AzAutomationAccount -ResourceGroupName $resourceGroupName -Name $automationAccountName -Location $location -ErrorAction Stop | Out-Null
            Write-Host "  Automation Account created" -ForegroundColor Green
        } catch {
            if ($_.Exception.Message -like "*already exists*") {
                Write-Host "  Automation Account already exists" -ForegroundColor Green
            } else {
                Write-Host "  Could not create Automation Account: $_" -ForegroundColor Yellow
                Write-Host "  The name will be saved in config - you can create it later." -ForegroundColor Gray
            }
        }
    }

    Write-Host ""

    # ============================================================
    # Graph API Settings
    # ============================================================
    Write-Host "--- Graph API Settings ---" -ForegroundColor Cyan

    $graphTenantId = $tenantId

    Write-Host ""
    Write-Host "  [1] Create a new App Registration (recommended for new setups)" -ForegroundColor White
    Write-Host "  [2] Use an existing App Registration" -ForegroundColor White
    Write-Host ""

    do {
        $appChoice = Read-Host "  Select option (1-2)"
        $validAppChoice = ($appChoice -eq '1' -or $appChoice -eq '2')
        if (-not $validAppChoice) {
            Write-Host "  Please enter 1 or 2" -ForegroundColor Yellow
        }
    } while (-not $validAppChoice)

    if ($appChoice -eq '1') {
        # Create new App Registration
        $appNameInput = Read-Host "  App Registration name [FortigiGraph]"
        $appName = if ([string]::IsNullOrWhiteSpace($appNameInput)) { "FortigiGraph" } else { $appNameInput }

        Write-Host ""
        Write-Host "  Creating App Registration: $appName..." -ForegroundColor Cyan

        try {
            $app = New-AzADApplication -DisplayName $appName -ErrorAction Stop
            $clientId = $app.AppId
            Write-Host "  App created: $clientId" -ForegroundColor Green
        } catch {
            Write-Host "  Failed to create App Registration: $_" -ForegroundColor Red
            Write-Host "  You may not have permission to create apps in this tenant." -ForegroundColor Yellow
            Write-Host "  Falling back to manual entry." -ForegroundColor Yellow
            Write-Host ""

            $clientId = Read-Host "  Client ID (Application ID)"
            if ([string]::IsNullOrWhiteSpace($clientId)) {
                Write-Host "  Client ID is required." -ForegroundColor Red
                return
            }

            Write-Host "  Client Secret: " -ForegroundColor Gray -NoNewline
            $clientSecretRaw = Read-Host -AsSecureString
            $clientSecretEncrypted = ""
            if ($clientSecretRaw.Length -gt 0) {
                $clientSecretEncrypted = $clientSecretRaw | ConvertFrom-SecureString
            }

            # Skip to after the app creation block
            $appCreated = $false
        }

        if (-not (Test-Path variable:appCreated) -or $appCreated -ne $false) {
            $appCreated = $true

            # Create Service Principal
            Write-Host "  Creating Service Principal..." -ForegroundColor Cyan
            try {
                New-AzADServicePrincipal -ApplicationId $clientId -ErrorAction Stop | Out-Null
                Write-Host "  Service Principal created" -ForegroundColor Green
            } catch {
                if ($_.Exception.Message -like "*already exists*") {
                    Write-Host "  Service Principal already exists" -ForegroundColor Green
                } else {
                    Write-Host "  Warning: Could not create Service Principal: $_" -ForegroundColor Yellow
                }
            }

            # Generate Client Secret (valid for 2 years)
            Write-Host "  Generating client secret (valid for 2 years)..." -ForegroundColor Cyan
            try {
                $endDate = (Get-Date).AddYears(2)
                $credential = New-AzADAppCredential -ApplicationId $clientId -EndDate $endDate -ErrorAction Stop
                $clientSecretPlain = $credential.SecretText
                $clientSecretEncrypted = ($clientSecretPlain | ConvertTo-SecureString -AsPlainText -Force) | ConvertFrom-SecureString
                Write-Host "  Client secret generated and stored encrypted" -ForegroundColor Green
            } catch {
                Write-Host "  Failed to generate client secret: $_" -ForegroundColor Red
                Write-Host "  You can add a secret manually in the Azure Portal." -ForegroundColor Yellow
                $clientSecretEncrypted = ""
            }

            # Add Graph API permissions
            Write-Host "  Adding Microsoft Graph API permissions..." -ForegroundColor Cyan

            $graphApiId = '00000003-0000-0000-c000-000000000000'
            $permissions = @(
                @{ Name = 'User.Read.All';                  Id = 'df021288-bdef-4463-88db-98f22de89214' }
                @{ Name = 'Group.Read.All';                 Id = '5b567255-7703-4780-807c-7be8301ae99b' }
                @{ Name = 'GroupMember.Read.All';           Id = '98830695-27a2-44f7-8c18-0c3ebc9698f6' }
                @{ Name = 'Directory.Read.All';             Id = '7ab1d382-f21e-4acd-a863-ba3e13f7da61' }
                @{ Name = 'EntitlementManagement.Read.All'; Id = 'c74fd47d-ed3c-45c3-9a9e-b8676de685d2' }
                @{ Name = 'AccessReview.Read.All';          Id = 'd07a8cc0-3d51-4b77-b3b0-32704d1f69fa' }
                @{ Name = 'AuditLog.Read.All';              Id = 'b0afded3-3588-46d8-8b3d-9842eff778da' }
            )

            foreach ($perm in $permissions) {
                try {
                    Add-AzADAppPermission -ApplicationId $clientId -ApiId $graphApiId -PermissionId $perm.Id -Type Role -ErrorAction Stop
                    Write-Host "    + $($perm.Name)" -ForegroundColor Green
                } catch {
                    if ($_.Exception.Message -like "*already been assigned*") {
                        Write-Host "    + $($perm.Name) (already assigned)" -ForegroundColor Green
                    } else {
                        Write-Host "    ! $($perm.Name) - failed: $_" -ForegroundColor Yellow
                    }
                }
            }

            Write-Host ""
            Write-Host "  IMPORTANT: An admin must grant consent for these permissions." -ForegroundColor Yellow
            Write-Host "  Open the Azure Portal to grant admin consent:" -ForegroundColor Yellow
            Write-Host "  https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/CallAnAPI/appId/$clientId" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "  Press Enter after granting admin consent (or grant it later)..." -ForegroundColor Gray
            Read-Host | Out-Null
        }
    } else {
        # Use existing App Registration
        $clientId = Read-Host "  Client ID (Application ID)"
        if ([string]::IsNullOrWhiteSpace($clientId)) {
            Write-Host "  Client ID is required." -ForegroundColor Red
            return
        }

        Write-Host "  Client Secret: " -ForegroundColor Gray -NoNewline
        $clientSecretRaw = Read-Host -AsSecureString

        $clientSecretEncrypted = ""
        if ($clientSecretRaw.Length -gt 0) {
            $clientSecretEncrypted = $clientSecretRaw | ConvertFrom-SecureString
        }
    }

    Write-Host ""

    # ============================================================
    # Sync Settings
    # ============================================================
    $syncConfig = @{
        Users = @{ Enabled = $true; TableName = "GraphUsers"; Filter = ""; AdditionalAttributes = @() }
        Groups = @{ Enabled = $true; TableName = "GraphGroups"; Filter = ""; AdditionalAttributes = @() }
        GroupMembers = @{ Enabled = $true; TableName = "GraphGroupMembers" }
        GroupEligibleMembers = @{ Enabled = $true }
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
        $syncConfig.GroupEligibleMembers.Enabled = (Read-FGConfigYesNo -Prompt "  Sync Group Eligible Members (PIM)" -Default $true)
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
    } else {
        Write-Host "Using default sync settings (all enabled)." -ForegroundColor Gray
        Write-Host ""
    }

    # ============================================================
    # Advanced Features: Risk Scoring & Account Correlation
    # ============================================================
    $enableRiskScoring = $false
    $enableAccountCorrelation = $false
    $llmProvider = ""
    $llmModel = ""
    $llmApiKey = ""
    $riskScoringDomain = ""

    if (-not $Quick) {
        Write-Host "--- Advanced Features ---" -ForegroundColor Cyan
        Write-Host "  FortigiGraph includes optional identity analytics features." -ForegroundColor Gray
        Write-Host "  These require an LLM (AI) for initial setup but all identity" -ForegroundColor Gray
        Write-Host "  scoring runs locally — no identity data is sent externally." -ForegroundColor Gray
        Write-Host ""

        $enableRiskScoring = (Read-FGConfigYesNo -Prompt "  Enable Risk Scoring (identity risk analysis)" -Default $false)

        if ($enableRiskScoring) {
            $domainInput = Read-Host "  Enter your organization's primary domain (e.g., contoso.com)"
            $riskScoringDomain = if ($domainInput.Trim()) { $domainInput.Trim() } else { $tenantId }
        }

        $enableAccountCorrelation = (Read-FGConfigYesNo -Prompt "  Enable Account Correlation (group accounts into identities)" -Default $false)

        # If either feature is enabled, prompt for LLM configuration
        if ($enableRiskScoring -or $enableAccountCorrelation) {
            Write-Host ""
            Write-Host "  Both Risk Scoring and Account Correlation use an LLM (AI model)" -ForegroundColor Cyan
            Write-Host "  for one-time setup tasks only:" -ForegroundColor Gray
            Write-Host "    - Risk Scoring: Discovers organizational context from public domain info" -ForegroundColor Gray
            Write-Host "    - Account Correlation: Analyzes naming patterns to build correlation rules" -ForegroundColor Gray
            Write-Host ""
            Write-Host "  No user names, emails, or identity data is sent to the LLM." -ForegroundColor Green
            Write-Host "  Only anonymized structural data (prefix counts, domain names) is shared." -ForegroundColor Green
            Write-Host ""
            Write-Host "  Supported providers: Anthropic (Claude) or OpenAI (GPT)" -ForegroundColor Gray
            Write-Host ""

            $providerInput = Read-Host "  LLM Provider (anthropic/openai, or press Enter to skip)"
            $llmProvider = $providerInput.Trim().ToLower()

            if ($llmProvider -eq 'anthropic' -or $llmProvider -eq 'openai') {
                if ($llmProvider -eq 'anthropic') {
                    $defaultModel = "claude-sonnet-4-20250514"
                } else {
                    $defaultModel = "gpt-4o"
                }
                $modelInput = Read-Host "  Model name (default: $defaultModel)"
                $llmModel = if ($modelInput.Trim()) { $modelInput.Trim() } else { $defaultModel }

                $apiKeyInput = Read-Host "  API Key (will be DPAPI-encrypted in config)"
                $llmApiKey = $apiKeyInput.Trim()

                if ($llmApiKey) {
                    Write-Host "  LLM configured: $llmProvider / $llmModel" -ForegroundColor Green
                } else {
                    Write-Host "  No API key provided. You can set it later in the config file" -ForegroundColor Yellow
                    Write-Host "  or via ANTHROPIC_API_KEY / OPENAI_API_KEY environment variable." -ForegroundColor Yellow
                }
            } elseif ($llmProvider) {
                Write-Host "  Unknown provider '$llmProvider'. Skipping LLM configuration." -ForegroundColor Yellow
                Write-Host "  You can configure it later in the config file under the LLM section." -ForegroundColor Yellow
                $llmProvider = ""
            } else {
                Write-Host "  LLM not configured. You can add it later in the config file." -ForegroundColor Yellow
                Write-Host "  Risk Scoring and Account Correlation will use -NoLLM mode until configured." -ForegroundColor Yellow
            }
        }

        Write-Host ""
    }

    # Encrypt LLM API key if provided
    $llmApiKeyEncrypted = ""
    if ($llmApiKey) {
        try {
            $secureApiKey = ConvertTo-SecureString -String $llmApiKey -AsPlainText -Force
            $llmApiKeyEncrypted = $secureApiKey | ConvertFrom-SecureString
        } catch {
            Write-Warning "Failed to encrypt LLM API key: $_"
        }
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
            AutomationAccountName       = $automationAccountName
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
                Enabled              = $syncConfig.Groups.Enabled
                TableName            = $syncConfig.Groups.TableName
                Filter               = $syncConfig.Groups.Filter
                AdditionalAttributes = $syncConfig.Groups.AdditionalAttributes
            }
            GroupMembers                     = [ordered]@{
                Enabled   = $syncConfig.GroupMembers.Enabled
                TableName = $syncConfig.GroupMembers.TableName
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

    # Add LLM section if provider was configured or if either feature is enabled
    if ($llmProvider -or $enableRiskScoring -or $enableAccountCorrelation) {
        $llmSection = [ordered]@{
            Provider = $llmProvider
            Model    = $llmModel
        }
        if ($llmApiKeyEncrypted) {
            $llmSection.ApiKey_Encrypted = $llmApiKeyEncrypted
        } else {
            $llmSection.ApiKey = ""
        }
        $config.LLM = $llmSection
    }

    # Add RiskScoring section
    if ($enableRiskScoring) {
        $config.RiskScoring = [ordered]@{
            Enabled        = $true
            CustomerDomain = $riskScoringDomain
        }
    }

    # Add AccountCorrelation section
    if ($enableAccountCorrelation) {
        $config.AccountCorrelation = [ordered]@{
            Enabled = $true
        }
    }

    # ============================================================
    # Save the config file
    # ============================================================
    $config | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Force

    Write-Host "Config file saved to: $Path" -ForegroundColor Green
    Write-Host ""
    Write-Host "=== Setup Complete ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Resources created:" -ForegroundColor White
    Write-Host "    Resource Group:     $resourceGroupName" -ForegroundColor Gray
    Write-Host "    SQL Server:         $sqlServerName.database.windows.net" -ForegroundColor Gray
    Write-Host "    Database:           $databaseName" -ForegroundColor Gray
    Write-Host "    Automation Account: $automationAccountName" -ForegroundColor Gray
    Write-Host "    Config file:        $Path" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Next steps:" -ForegroundColor White
    Write-Host "    1. Get-FGAccessToken -ConfigFile '$Path'" -ForegroundColor Cyan
    Write-Host "    2. Connect-FGSQLServer -ConfigFile '$Path'" -ForegroundColor Cyan
    Write-Host "    3. Start-FGSync -ConfigFile '$Path'" -ForegroundColor Cyan
    Write-Host "    4. New-FGAzureAutomationAccount -ConfigFile '$Path'" -ForegroundColor Cyan
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
        Requires PowerShell 7+ (cross-platform: Windows, Linux, macOS).
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

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        # Ensure at least one of each category
        $bytes = [byte[]]::new(4)
        $rng.GetBytes($bytes)
        $password = @(
            $upper[$bytes[0] % $upper.Length]
            $lower[$bytes[1] % $lower.Length]
            $digits[$bytes[2] % $digits.Length]
            $special[$bytes[3] % $special.Length]
        )

        # Fill the rest randomly
        $remaining = $Length - 4
        $bytes = [byte[]]::new($remaining)
        $rng.GetBytes($bytes)
        for ($i = 0; $i -lt $remaining; $i++) {
            $password += $all[$bytes[$i] % $all.Length]
        }

        # Fisher-Yates shuffle so the guaranteed chars aren't always at the start
        for ($i = $password.Count - 1; $i -gt 0; $i--) {
            $swapBytes = [byte[]]::new(4)
            $rng.GetBytes($swapBytes)
            $j = [Math]::Abs([BitConverter]::ToInt32($swapBytes, 0)) % ($i + 1)
            $temp = $password[$i]
            $password[$i] = $password[$j]
            $password[$j] = $temp
        }
        $password = $password -join ''
    }
    finally {
        $rng.Dispose()
    }

    return $password
}

function New-FGRandomSqlName {
    <#
    .SYNOPSIS
        Internal helper for New-FGConfig. Generates a unique SQL Server name suggestion.
        Requires PowerShell 7+ (cross-platform: Windows, Linux, macOS).
    #>

    [cmdletbinding()]
    Param()

    $chars = 'abcdefghijklmnopqrstuvwxyz0123456789'
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $bytes = [byte[]]::new(5)
        $rng.GetBytes($bytes)
        $suffix = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
    }
    finally {
        $rng.Dispose()
    }

    return "sql-fortigraph-$suffix"
}

function New-FGRandomAutomationAccountName {
    <#
    .SYNOPSIS
        Internal helper for New-FGConfig. Generates a unique Automation Account name suggestion.
        Requires PowerShell 7+ (cross-platform: Windows, Linux, macOS).
    #>

    [cmdletbinding()]
    Param()

    $chars = 'abcdefghijklmnopqrstuvwxyz0123456789'
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $bytes = [byte[]]::new(5)
        $rng.GetBytes($bytes)
        $suffix = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
    }
    finally {
        $rng.Dispose()
    }

    return "aa-fortigraph-$suffix"
}
