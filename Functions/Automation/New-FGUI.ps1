function New-FGUI {
    [alias("New-UI")]
    [CmdletBinding(DefaultParameterSetName = 'ConfigFile')]
    Param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ConfigFile')]
        [string]$ConfigFile,

        [Parameter(Mandatory = $false)]
        [string]$WebAppName,

        [Parameter(Mandatory = $false)]
        [string]$AppServicePlanName,

        [Parameter(Mandatory = $false)]
        [string]$Location,

        [Parameter(Mandatory = $false)]
        [ValidateSet('B1', 'B2', 'B3', 'S1', 'S2', 'S3', 'P0v3', 'P1v3', 'P2v3', 'P3v3')]
        [string]$Sku = 'P0v3',

        [Parameter(Mandatory = $false)]
        [ValidateSet('Basic', 'Optimum', 'Fast')]
        [string]$Scaling = 'Optimum',

        [Parameter(Mandatory = $false)]
        [switch]$UseMockData,

        [Parameter(Mandatory = $false)]
        [switch]$NoAuth,

        [Parameter(Mandatory = $false)]
        [switch]$PerformanceMetrics,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    # Suppress Az module deprecation warnings (e.g., Get-AzAccessToken SecureString change)
    $WarningPreference = 'SilentlyContinue'

    # ─── Helper: Azure REST API call ───────────────────────────────────────
    function Invoke-AzureRestApi {
        param(
            [string]$Method,
            [string]$Uri,
            [object]$Body,
            [string]$ApiVersion = "2023-01-01"
        )

        $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com" -WarningAction SilentlyContinue -ErrorAction Stop).Token
        $headers = @{ Authorization = "Bearer $token" }
        $fullUri = if ($Uri -match '\?') { "$Uri&api-version=$ApiVersion" } else { "$Uri`?api-version=$ApiVersion" }

        $params = @{
            Method      = $Method
            Uri         = $fullUri
            Headers     = $headers
            ContentType = "application/json"
        }

        if ($Body) {
            $params.Body = ($Body | ConvertTo-Json -Depth 10)
        }

        return Invoke-RestMethod @params
    }

    # ─── Helper: Microsoft Graph API call ────────────────────────────────
    function Invoke-GraphApi {
        param(
            [string]$Method,
            [string]$Uri,
            [object]$Body
        )

        $graphToken = (Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com" -WarningAction SilentlyContinue -ErrorAction Stop).Token
        $headers = @{
            Authorization  = "Bearer $graphToken"
            "Content-Type" = "application/json"
        }

        $params = @{
            Method      = $Method
            Uri         = $Uri
            Headers     = $headers
            ContentType = "application/json"
        }

        if ($Body) {
            $params.Body = ($Body | ConvertTo-Json -Depth 10)
        }

        return Invoke-RestMethod @params
    }

    # ─── Helper: Save UI settings to config file ──────────────────────────
    function Save-UIConfig {
        param(
            [string]$ConfigFilePath,
            [string]$WebAppName,
            [string]$AppServicePlanName,
            [string]$Location,
            [string]$Sku,
            [hashtable]$Auth
        )
        try {
            $cfg = Get-Content -Path $ConfigFilePath -Raw | ConvertFrom-Json

            if (-not $cfg.UI) {
                $cfg | Add-Member -MemberType NoteProperty -Name 'UI' -Value ([PSCustomObject]@{
                    WebAppName         = $WebAppName
                    AppServicePlanName = $AppServicePlanName
                    Location           = $Location
                    Sku                = $Sku
                    URL                = "https://$WebAppName.azurewebsites.net"
                })
            } else {
                $cfg.UI.WebAppName = $WebAppName
                $cfg.UI.AppServicePlanName = $AppServicePlanName
                $cfg.UI.Location = $Location
                $cfg.UI.Sku = $Sku
                $cfg.UI.URL = "https://$WebAppName.azurewebsites.net"
            }

            if ($Auth) {
                $authObj = [PSCustomObject]@{
                    AppRegistrationName = $Auth.AppRegistrationName
                    ClientId            = $Auth.ClientId
                    TenantId            = $Auth.TenantId
                }

                if ($cfg.UI.PSObject.Properties['Auth']) {
                    $cfg.UI.Auth = $authObj
                } else {
                    $cfg.UI | Add-Member -MemberType NoteProperty -Name 'Auth' -Value $authObj
                }
            }

            $cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigFilePath -Force
            return $true
        } catch {
            return $false
        }
    }

    # ─── SKU mapping ───────────────────────────────────────────────────────
    $skuMap = @{
        'B1' = @{ name = 'B1';  tier = 'Basic';    kind = 'linux'; reserved = $true }
        'B2' = @{ name = 'B2';  tier = 'Basic';    kind = 'linux'; reserved = $true }
        'B3' = @{ name = 'B3';  tier = 'Basic';    kind = 'linux'; reserved = $true }
        'S1' = @{ name = 'S1';  tier = 'Standard'; kind = 'linux'; reserved = $true }
        'S2' = @{ name = 'S2';  tier = 'Standard'; kind = 'linux'; reserved = $true }
        'S3'   = @{ name = 'S3';   tier = 'Standard';  kind = 'linux'; reserved = $true }
        'P0v3' = @{ name = 'P0v3'; tier = 'PremiumV3'; kind = 'linux'; reserved = $true }
        'P1v3' = @{ name = 'P1v3'; tier = 'PremiumV3'; kind = 'linux'; reserved = $true }
        'P2v3' = @{ name = 'P2v3'; tier = 'PremiumV3'; kind = 'linux'; reserved = $true }
        'P3v3' = @{ name = 'P3v3'; tier = 'PremiumV3'; kind = 'linux'; reserved = $true }
    }

    # ─── Load Config ───────────────────────────────────────────────────────
    if (-not (Test-Path $ConfigFile)) {
        throw "Config file not found: $ConfigFile"
    }

    $config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json

    $resourceGroupName = $config.Azure.ResourceGroupName
    $sqlServerName = $config.Azure.SQLServerName
    $databaseName = $config.Azure.DatabaseName
    $subscriptionId = $config.Azure.SubscriptionId

    # Generate names if not provided - check config first, then generate
    if (-not $WebAppName) {
        if ($config.UI -and $config.UI.WebAppName) {
            $WebAppName = $config.UI.WebAppName
        } else {
            $suffix = (Get-Random -Minimum 10000 -Maximum 99999)
            $WebAppName = "ui-$suffix"
        }
    }
    if (-not $AppServicePlanName) {
        if ($config.UI -and $config.UI.AppServicePlanName) {
            $AppServicePlanName = $config.UI.AppServicePlanName
        } else {
            $AppServicePlanName = "$WebAppName-plan"
        }
    }
    if (-not $Location) {
        if ($config.UI -and $config.UI.Location) {
            $Location = $config.UI.Location
        } else {
            $Location = $config.Azure.Location
        }
    }

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║       FortigiGraph UI - Azure Deployment        ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    # ─── Azure Context ─────────────────────────────────────────────────────
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking Azure context..." -ForegroundColor Cyan
    try {
        $currentContext = Get-AzContext
        if (-not $currentContext) { throw "Not logged in" }
    } catch {
        throw "Not logged in to Azure. Please run Connect-AzAccount first."
    }

    if (-not $global:FGAzureContextConfirmed) {
        Write-Host "Current Azure Context:" -ForegroundColor Yellow
        Write-Host "  Account:      $($currentContext.Account.Id)" -ForegroundColor White
        Write-Host "  Subscription: $($currentContext.Subscription.Name) ($($currentContext.Subscription.Id))" -ForegroundColor White
        Write-Host "  Tenant:       $($currentContext.Tenant.Id)" -ForegroundColor White
        Write-Host ""
        $confirmation = Read-Host "Do you want to use this Azure context? (Y/N)"
        if ($confirmation -notmatch '^[Yy]') {
            Write-Host "Aborted. Use Connect-AzAccount or Set-AzContext to change context." -ForegroundColor Yellow
            return
        }
        $global:FGAzureContextConfirmed = $true
    }

    # Set subscription
    if ($subscriptionId -and $currentContext.Subscription.Id -ne $subscriptionId) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Setting subscription to $subscriptionId..." -ForegroundColor Cyan
        Set-AzContext -SubscriptionId $subscriptionId | Out-Null
    }

    $subId = (Get-AzContext).Subscription.Id
    $tenantId = (Get-AzContext).Tenant.Id

    # ─── Verify Resource Group ─────────────────────────────────────────────
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Verifying resource group: $resourceGroupName..." -ForegroundColor Cyan
    $rg = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
    if (-not $rg) {
        throw "Resource group '$resourceGroupName' not found. Run New-FGConfig first."
    }
    Write-Host "  Resource group exists" -ForegroundColor Green

    # ─── Entra ID App Registration for Authentication ─────────────────────
    $uiClientId = $null
    $uiAuthAppName = $null

    if (-not $NoAuth) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Setting up Entra ID authentication..." -ForegroundColor Cyan

        $uiAuthAppName = "FortigiGraph-UI-$WebAppName"
        $redirectUri = "https://$WebAppName.azurewebsites.net"

        # -Force: delete existing app registration so it gets recreated cleanly
        if ($Force) {
            $appsToDelete = @()

            # Check config for existing client ID
            if ($config.UI -and $config.UI.Auth -and $config.UI.Auth.ClientId) {
                try {
                    $existing = Invoke-GraphApi -Method GET -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=appId eq '$($config.UI.Auth.ClientId)'"
                    if ($existing.value.Count -gt 0) { $appsToDelete += $existing.value[0] }
                } catch {}
            }

            # Also check by display name (catches orphaned registrations)
            try {
                $byName = Invoke-GraphApi -Method GET -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$uiAuthAppName'"
                foreach ($app in $byName.value) {
                    if ($appsToDelete.id -notcontains $app.id) { $appsToDelete += $app }
                }
            } catch {}

            foreach ($app in $appsToDelete) {
                Write-Host "  Deleting app registration: $($app.displayName) ($($app.appId))..." -ForegroundColor Yellow
                try {
                    Invoke-GraphApi -Method DELETE -Uri "https://graph.microsoft.com/v1.0/applications/$($app.id)" | Out-Null
                    Write-Host "  Deleted" -ForegroundColor Yellow
                } catch {
                    Write-Host "  Warning: Could not delete app registration: $_" -ForegroundColor Yellow
                }
            }
        }

        # Check if app registration already exists (from config or by name)
        if (-not $Force -and $config.UI -and $config.UI.Auth -and $config.UI.Auth.ClientId) {
            $uiClientId = $config.UI.Auth.ClientId
            Write-Host "  Found existing app in config: $uiClientId" -ForegroundColor Green

            # Ensure redirect URI and token version are current
            try {
                $existingApps = Invoke-GraphApi -Method GET -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=appId eq '$uiClientId'"
                if ($existingApps.value.Count -gt 0) {
                    $appObjectId = $existingApps.value[0].id
                    $patchBody = @{}

                    $currentRedirects = @($existingApps.value[0].spa.redirectUris)
                    if ($redirectUri -notin $currentRedirects) {
                        $currentRedirects += $redirectUri
                        $patchBody.spa = @{ redirectUris = $currentRedirects }
                        Write-Host "  Updating redirect URI: $redirectUri" -ForegroundColor Cyan
                    }

                    # Ensure v2 access tokens (required for issuer validation)
                    if ($existingApps.value[0].api.requestedAccessTokenVersion -ne 2) {
                        $patchBody.api = @{ requestedAccessTokenVersion = 2 }
                        Write-Host "  Updating access token version to v2..." -ForegroundColor Cyan
                    }

                    if ($patchBody.Count -gt 0) {
                        Invoke-GraphApi -Method PATCH -Uri "https://graph.microsoft.com/v1.0/applications/$appObjectId" -Body $patchBody | Out-Null
                        Write-Host "  App registration updated" -ForegroundColor Green
                    }
                }
            } catch {
                Write-Host "  Warning: Could not verify app registration settings: $_" -ForegroundColor Yellow
            }
        }

        if (-not $uiClientId) {
            # Search by display name
            try {
                $searchResult = Invoke-GraphApi -Method GET -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$uiAuthAppName'"
                if ($searchResult.value.Count -gt 0) {
                    $uiClientId = $searchResult.value[0].appId
                    Write-Host "  Found existing app registration: $uiAuthAppName ($uiClientId)" -ForegroundColor Green
                }
            } catch {
                Write-Host "  Warning: Could not search for existing app: $_" -ForegroundColor Yellow
            }
        }

        if (-not $uiClientId) {
            # Create new app registration
            Write-Host "  Creating app registration: $uiAuthAppName..." -ForegroundColor Cyan

            try {
                $newApp = Invoke-GraphApi -Method POST -Uri "https://graph.microsoft.com/v1.0/applications" -Body @{
                    displayName    = $uiAuthAppName
                    signInAudience = "AzureADMyOrg"
                    spa            = @{
                        redirectUris = @($redirectUri)
                    }
                }

                $uiClientId = $newApp.appId
                $appObjectId = $newApp.id
                Write-Host "  App registration created: $uiClientId" -ForegroundColor Green

                # Step 1: Add identifier URI and API scope
                $scopeId = [guid]::NewGuid().ToString()
                Write-Host "  Configuring API scope..." -ForegroundColor Cyan

                Invoke-GraphApi -Method PATCH -Uri "https://graph.microsoft.com/v1.0/applications/$appObjectId" -Body @{
                    identifierUris = @("api://$uiClientId")
                    api = @{
                        requestedAccessTokenVersion = 2
                        oauth2PermissionScopes = @(
                            @{
                                id                      = $scopeId
                                adminConsentDisplayName  = "Access FortigiGraph UI"
                                adminConsentDescription  = "Allow access to FortigiGraph Role Mining UI"
                                userConsentDisplayName   = "Access FortigiGraph UI"
                                userConsentDescription   = "Allow access to FortigiGraph Role Mining UI"
                                value                    = "access"
                                type                     = "User"
                                isEnabled                = $true
                            }
                        )
                    }
                } | Out-Null
                Write-Host "  API scope configured" -ForegroundColor Green

                # Step 2: Pre-authorize the SPA for its own API scope (must be separate
                # PATCH because the scope needs to exist before it can be referenced)
                Write-Host "  Pre-authorizing SPA for API scope..." -ForegroundColor Cyan

                Invoke-GraphApi -Method PATCH -Uri "https://graph.microsoft.com/v1.0/applications/$appObjectId" -Body @{
                    api = @{
                        requestedAccessTokenVersion = 2
                        oauth2PermissionScopes = @(
                            @{
                                id                      = $scopeId
                                adminConsentDisplayName  = "Access FortigiGraph UI"
                                adminConsentDescription  = "Allow access to FortigiGraph Role Mining UI"
                                userConsentDisplayName   = "Access FortigiGraph UI"
                                userConsentDescription   = "Allow access to FortigiGraph Role Mining UI"
                                value                    = "access"
                                type                     = "User"
                                isEnabled                = $true
                            }
                        )
                        preAuthorizedApplications = @(
                            @{
                                appId                  = $uiClientId
                                delegatedPermissionIds = @($scopeId)
                            }
                        )
                    }
                } | Out-Null
                Write-Host "  Pre-authorization configured (no consent prompt)" -ForegroundColor Green

                # Create service principal
                Write-Host "  Creating service principal..." -ForegroundColor Cyan
                $spObjectId = $null
                try {
                    $sp = Invoke-GraphApi -Method POST -Uri "https://graph.microsoft.com/v1.0/servicePrincipals" -Body @{
                        appId = $uiClientId
                    }
                    $spObjectId = $sp.id
                    Write-Host "  Service principal created" -ForegroundColor Green
                } catch {
                    if ($_.Exception.Response.StatusCode -eq 409 -or $_.ErrorDetails.Message -like "*already exists*") {
                        Write-Host "  Service principal already exists" -ForegroundColor Green
                        # Look up existing service principal
                        $existingSp = Invoke-GraphApi -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$uiClientId'"
                        $spObjectId = $existingSp.value[0].id
                    } else {
                        Write-Host "  Warning: Could not create service principal: $_" -ForegroundColor Yellow
                    }
                }

                # Enable assignment required and assign the deploying user
                if ($spObjectId) {
                    Write-Host "  Enabling 'Assignment required'..." -ForegroundColor Cyan
                    Invoke-GraphApi -Method PATCH -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$spObjectId" -Body @{
                        appRoleAssignmentRequired = $true
                    } | Out-Null
                    Write-Host "  Assignment required enabled (only assigned users can access)" -ForegroundColor Green

                    # Get the current user and assign them
                    Write-Host "  Assigning current user..." -ForegroundColor Cyan
                    $me = Invoke-GraphApi -Method GET -Uri "https://graph.microsoft.com/v1.0/me"
                    Invoke-GraphApi -Method POST -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$spObjectId/appRoleAssignments" -Body @{
                        principalId = $me.id
                        resourceId  = $spObjectId
                        appRoleId   = "00000000-0000-0000-0000-000000000000"
                    } | Out-Null
                    Write-Host "  Assigned: $($me.displayName) ($($me.userPrincipalName))" -ForegroundColor Green
                }
            } catch {
                Write-Host "  Failed to create app registration: $_" -ForegroundColor Red

                # Clean up partially created app registration
                if ($appObjectId) {
                    Write-Host "  Cleaning up partial app registration..." -ForegroundColor Yellow
                    try {
                        Invoke-GraphApi -Method DELETE -Uri "https://graph.microsoft.com/v1.0/applications/$appObjectId" | Out-Null
                        Write-Host "  Partial app registration removed" -ForegroundColor Yellow
                    } catch {
                        Write-Host "  Warning: Could not clean up app '$uiAuthAppName'. Delete it manually in Azure Portal > App Registrations." -ForegroundColor Yellow
                    }
                }

                Write-Host "  The UI will be deployed without authentication." -ForegroundColor Yellow
                Write-Host "  You can set up auth manually later by creating an App Registration" -ForegroundColor Yellow
                Write-Host "  and configuring AUTH_ENABLED, AUTH_TENANT_ID, AUTH_CLIENT_ID env vars." -ForegroundColor Yellow
                $uiClientId = $null
            }
        }

        if ($uiClientId) {
            Write-Host ""
            Write-Host "  TIP: To grant others access, assign users or groups to the" -ForegroundColor Gray
            Write-Host "  Enterprise Application '$uiAuthAppName' in the Azure Portal." -ForegroundColor Gray
        }
    }

    # ─── Deployment Summary ────────────────────────────────────────────────
    Write-Host ""
    Write-Host "Deployment plan:" -ForegroundColor Yellow
    Write-Host "  Resource Group:    $resourceGroupName" -ForegroundColor White
    Write-Host "  Location:          $Location" -ForegroundColor White
    Write-Host "  App Service Plan:  $AppServicePlanName ($Sku)" -ForegroundColor White
    Write-Host "  Web App:           $WebAppName" -ForegroundColor White
    Write-Host "  URL:               https://$WebAppName.azurewebsites.net" -ForegroundColor White
    Write-Host "  Data mode:         $(if ($UseMockData) { 'Mock data' } else { 'Azure SQL' })" -ForegroundColor White
    Write-Host "  Scaling:           $Scaling (applied after deployment)" -ForegroundColor White
    Write-Host "  Authentication:    $(if ($uiClientId) { "Entra ID ($uiClientId)" } elseif ($NoAuth) { 'Disabled' } else { 'Disabled' })" -ForegroundColor White
    Write-Host ""
    $proceed = Read-Host "Proceed with deployment? (Y/N)"
    if ($proceed -notmatch '^[Yy]') {
        Write-Host "Aborted." -ForegroundColor Yellow
        return
    }

    # ─── Create App Service Plan (REST API) ────────────────────────────────
    Write-Host ""
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Creating App Service Plan: $AppServicePlanName..." -ForegroundColor Cyan

    $planUri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$resourceGroupName/providers/Microsoft.Web/serverfarms/$AppServicePlanName"
    $skuConfig = $skuMap[$Sku]

    try {
        $existingPlan = $null
        try {
            $existingPlan = Invoke-AzureRestApi -Method GET -Uri $planUri
        } catch {}

        if ($existingPlan) {
            Write-Host "  App Service Plan already exists" -ForegroundColor Green
        } else {
            $planBody = @{
                location   = $Location
                kind       = $skuConfig.kind
                properties = @{ reserved = $skuConfig.reserved }
                sku        = @{ name = $skuConfig.name; tier = $skuConfig.tier }
            }

            Invoke-AzureRestApi -Method PUT -Uri $planUri -Body $planBody | Out-Null
            Write-Host "  App Service Plan created" -ForegroundColor Green
        }
    } catch {
        $errorMessage = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($errorMessage) {
            Write-Host "  Failed to create App Service Plan: $($errorMessage.Message)" -ForegroundColor Red
            if ($errorMessage.Message -match 'quota') {
                Write-Host ""
                Write-Host "  Your subscription has no App Service quota in $Location." -ForegroundColor Yellow
                Write-Host "  Fix: Azure Portal > Quotas > App Service > $Location" -ForegroundColor Yellow
                Write-Host "  Request at least 1 for '$Sku VMs'." -ForegroundColor Yellow
                Write-Host ""
                Write-Host "  Or try a different region: New-FGUI -ConfigFile '$ConfigFile' -Location 'westeurope'" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  Failed to create App Service Plan: $_" -ForegroundColor Red
        }
        return
    }

    # ─── Create Web App (REST API) ────────────────────────────────────────
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Creating Web App: $WebAppName..." -ForegroundColor Cyan

    $webAppUri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$resourceGroupName/providers/Microsoft.Web/sites/$WebAppName"

    try {
        $existingApp = $null
        try {
            $existingApp = Invoke-AzureRestApi -Method GET -Uri $webAppUri
        } catch {}

        if ($existingApp) {
            Write-Host "  Web App already exists" -ForegroundColor Green
        } else {
            $webAppBody = @{
                location   = $Location
                kind       = "app,linux"
                properties = @{
                    serverFarmId = "/subscriptions/$subId/resourceGroups/$resourceGroupName/providers/Microsoft.Web/serverfarms/$AppServicePlanName"
                    siteConfig   = @{
                        linuxFxVersion = "NODE|20-lts"
                        appCommandLine = "cd backend && node src/index.js"
                        appSettings    = @()
                    }
                    reserved = $true
                }
            }

            Invoke-AzureRestApi -Method PUT -Uri $webAppUri -Body $webAppBody | Out-Null
            Write-Host "  Web App created" -ForegroundColor Green
        }
    } catch {
        $errorMessage = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($errorMessage) {
            Write-Host "  Failed to create Web App: $($errorMessage.Message)" -ForegroundColor Red
        } else {
            Write-Host "  Failed to create Web App: $_" -ForegroundColor Red
        }
        return
    }

    # ─── Save config early (resource names are now known) ──────────────────
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Saving UI settings to config file..." -ForegroundColor Cyan
    $authConfig = $null
    if ($uiClientId) {
        $authConfig = @{
            AppRegistrationName = $uiAuthAppName
            ClientId            = $uiClientId
            TenantId            = $tenantId
        }
    }
    if (Save-UIConfig -ConfigFilePath $ConfigFile -WebAppName $WebAppName -AppServicePlanName $AppServicePlanName -Location $Location -Sku $Sku -Auth $authConfig) {
        Write-Host "  Config file updated" -ForegroundColor Green
    } else {
        Write-Host "  Warning: Could not update config file" -ForegroundColor Yellow
    }

    # ─── Configure App Settings (REST API) ─────────────────────────────────
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Configuring app settings..." -ForegroundColor Cyan

    $settingsList = @(
        @{ name = "WEBSITES_PORT";                  value = "3001" }
        @{ name = "SCM_DO_BUILD_DURING_DEPLOYMENT"; value = "true" }
        @{ name = "WEBSITE_NODE_DEFAULT_VERSION";   value = "~20" }
    )

    # Auth settings
    if ($uiClientId) {
        $settingsList += @{ name = "AUTH_ENABLED";   value = "true" }
        $settingsList += @{ name = "AUTH_TENANT_ID"; value = $tenantId }
        $settingsList += @{ name = "AUTH_CLIENT_ID"; value = $uiClientId }
    } else {
        $settingsList += @{ name = "AUTH_ENABLED"; value = "false" }
    }

    if ($UseMockData) {
        $settingsList += @{ name = "USE_SQL"; value = "false" }
    } else {
        $sqlPassword = Get-FGSecureConfigValue -ConfigPath $ConfigFile `
            -PropertyPath "Azure.AdminUserPassword" `
            -PromptMessage "Enter SQL Admin Password"

        $sqlUser = $config.Azure.AdminUsername
        $fullServerName = if ($sqlServerName -match '\.database\.windows\.net$') {
            $sqlServerName
        } else {
            "$sqlServerName.database.windows.net"
        }

        $settingsList += @{ name = "USE_SQL";      value = "true" }
        $settingsList += @{ name = "SQL_SERVER";    value = $fullServerName }
        $settingsList += @{ name = "SQL_DATABASE";  value = $databaseName }
        $settingsList += @{ name = "SQL_USER";      value = $sqlUser }
        $settingsList += @{ name = "SQL_PASSWORD";  value = $sqlPassword }
    }

    # Performance metrics (opt-in, default off)
    $settingsList += @{ name = "PERF_METRICS_ENABLED"; value = if ($PerformanceMetrics) { "true" } else { "false" } }

    $settingsUri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$resourceGroupName/providers/Microsoft.Web/sites/$WebAppName/config/appsettings"

    try {
        $settingsBody = @{
            properties = @{}
        }
        foreach ($setting in $settingsList) {
            $settingsBody.properties[$setting.name] = $setting.value
        }

        Invoke-AzureRestApi -Method PUT -Uri $settingsUri -Body $settingsBody | Out-Null
        Write-Host "  App settings configured" -ForegroundColor Green
    } catch {
        Write-Host "  Failed to configure app settings: $_" -ForegroundColor Red
        return
    }

    # ─── Ensure App is Started ─────────────────────────────────────────────
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Ensuring web app is started..." -ForegroundColor Cyan
    try {
        $startUri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$resourceGroupName/providers/Microsoft.Web/sites/$WebAppName/start"
        Invoke-AzureRestApi -Method POST -Uri $startUri | Out-Null
        Write-Host "  Web app started" -ForegroundColor Green
        # Give the app a moment to fully start before deploying
        Start-Sleep -Seconds 10
    } catch {
        Write-Host "  Warning: Could not start web app: $_" -ForegroundColor Yellow
    }

    # ─── SQL Firewall Rule ─────────────────────────────────────────────────
    if (-not $UseMockData) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking SQL firewall for Azure services..." -ForegroundColor Cyan

        $sqlServer = Get-AzSqlServer | Where-Object { $_.ServerName -ieq $sqlServerName.Split('.')[0] } | Select-Object -First 1
        if ($sqlServer) {
            $sqlResourceGroup = $sqlServer.ResourceGroupName
            $sqlServerNameActual = $sqlServer.ServerName

            $azureServicesRule = Get-AzSqlServerFirewallRule -ResourceGroupName $sqlResourceGroup `
                -ServerName $sqlServerNameActual -ErrorAction SilentlyContinue | Where-Object {
                    $_.StartIpAddress -eq "0.0.0.0" -and $_.EndIpAddress -eq "0.0.0.0"
                }

            if ($azureServicesRule) {
                Write-Host "  SQL firewall already allows Azure services" -ForegroundColor Green
            } else {
                Write-Host "  Adding firewall rule to allow Azure services access to SQL..." -ForegroundColor Yellow
                try {
                    New-AzSqlServerFirewallRule -ResourceGroupName $sqlResourceGroup `
                        -ServerName $sqlServerNameActual `
                        -FirewallRuleName "AllowAzureServices" `
                        -StartIpAddress "0.0.0.0" -EndIpAddress "0.0.0.0" `
                        -ErrorAction Stop | Out-Null
                    Write-Host "  Firewall rule added" -ForegroundColor Green
                } catch {
                    Write-Host "  Failed to add firewall rule: $_" -ForegroundColor Yellow
                    Write-Host "  You may need to add it manually in Azure Portal" -ForegroundColor Yellow
                }
            }
        } else {
            Write-Host "  Could not find SQL server - verify firewall manually" -ForegroundColor Yellow
        }
    }

    # ─── Deploy Code ───────────────────────────────────────────────────────
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Packaging UI for deployment..." -ForegroundColor Cyan

    $uiSourcePath = Join-Path $PSScriptRoot "..\..\UI"
    $uiSourcePath = (Resolve-Path $uiSourcePath).Path

    if (-not (Test-Path $uiSourcePath)) {
        Write-Host "  UI source not found at: $uiSourcePath" -ForegroundColor Red
        Write-Host "  Expected the UI folder at the root of the FortigiGraph module." -ForegroundColor Red
        return
    }

    $tempZipPath = Join-Path ([System.IO.Path]::GetTempPath()) "fortigraph-ui-deploy.zip"

    try {
        # Remove old zip if exists
        if (Test-Path $tempZipPath) {
            Remove-Item $tempZipPath -Force
        }

        # Create zip excluding node_modules, dist, .env, .git
        Write-Host "  Creating deployment package..." -ForegroundColor Gray

        $filesToZip = Get-ChildItem -Path $uiSourcePath -Recurse -File | Where-Object {
            $relativePath = $_.FullName.Substring($uiSourcePath.Length + 1)
            $relativePath -notmatch '(^|[\\/])node_modules[\\/]' -and
            $relativePath -notmatch '(^|[\\/])dist[\\/]' -and
            $relativePath -notmatch '(^|[\\/])\.env$' -and
            $relativePath -notmatch '(^|[\\/])\.git[\\/]'
        }

        # Use .NET compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem

        $zip = [System.IO.Compression.ZipFile]::Open($tempZipPath, 'Create')
        foreach ($file in $filesToZip) {
            $entryName = $file.FullName.Substring($uiSourcePath.Length + 1).Replace('\', '/')
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip, $file.FullName, $entryName, [System.IO.Compression.CompressionLevel]::Optimal
            ) | Out-Null
        }
        $zip.Dispose()

        $zipSizeMB = [math]::Round((Get-Item $tempZipPath).Length / 1MB, 2)
        Write-Host "  Package created: $zipSizeMB MB" -ForegroundColor Gray

        # Deploy using Kudu zip deploy API
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Deploying to Azure App Service..." -ForegroundColor Cyan
        Write-Host "  This will take a few minutes (Azure builds the app on the server)..." -ForegroundColor Gray

        $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com" -WarningAction SilentlyContinue -ErrorAction Stop).Token

        # Get publish credentials
        $credsUri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$resourceGroupName/providers/Microsoft.Web/sites/$WebAppName/config/publishingcredentials/list?api-version=2023-01-01"
        $creds = Invoke-RestMethod -Uri $credsUri -Method POST -Headers @{ Authorization = "Bearer $token" } -ContentType "application/json"

        $kuduUser = $creds.properties.publishingUserName
        $kuduPass = $creds.properties.publishingPassword
        $kuduBase64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${kuduUser}:${kuduPass}"))

        # Zip deploy via Kudu (async to avoid 504 timeout during Oryx build)
        $zipDeployUri = "https://$WebAppName.scm.azurewebsites.net/api/zipdeploy?isAsync=true"

        $deployResponse = Invoke-WebRequest -Uri $zipDeployUri -Method POST `
            -Headers @{ Authorization = "Basic $kuduBase64" } `
            -ContentType "application/octet-stream" `
            -InFile $tempZipPath `
            -TimeoutSec 120

        # Poll deployment status
        $pollUrl = $deployResponse.Headers['Location']
        if (-not $pollUrl) {
            # Fallback: check latest deployment
            $pollUrl = "https://$WebAppName.scm.azurewebsites.net/api/deployments/latest"
        }
        # Ensure pollUrl is a string (not an array)
        if ($pollUrl -is [array]) { $pollUrl = $pollUrl[0] }

        $authHeaders = @{ Authorization = "Basic $kuduBase64" }
        $maxWaitMinutes = 10
        $elapsed = 0
        $pollInterval = 15

        Write-Host "  Waiting for build to complete (up to $maxWaitMinutes min)..." -ForegroundColor Gray

        while ($elapsed -lt ($maxWaitMinutes * 60)) {
            Start-Sleep -Seconds $pollInterval
            $elapsed += $pollInterval

            try {
                $status = Invoke-RestMethod -Uri $pollUrl -Headers $authHeaders -Method GET
                $buildStatus = $status.status
                $progress = $status.progress

                if ($progress) {
                    Write-Host "  [$([math]::Floor($elapsed/60))m $($elapsed%60)s] $progress" -ForegroundColor Gray
                }

                # Status codes: 0=Pending, 1=Building, 2=Deploying, 3=Failed, 4=Success
                if ($buildStatus -eq 4) {
                    Write-Host "  Deployment complete" -ForegroundColor Green
                    break
                } elseif ($buildStatus -eq 3) {
                    Write-Host "  Deployment failed on Azure. Check logs:" -ForegroundColor Red
                    Write-Host "  https://$WebAppName.scm.azurewebsites.net/api/deployments/latest/log" -ForegroundColor Yellow
                    return
                }
            } catch {
                Write-Host "  [$([math]::Floor($elapsed/60))m $($elapsed%60)s] Waiting..." -ForegroundColor Gray
            }
        }

        if ($elapsed -ge ($maxWaitMinutes * 60)) {
            Write-Host "  Build is still running. Check status at:" -ForegroundColor Yellow
            Write-Host "  https://$WebAppName.scm.azurewebsites.net/api/deployments/latest" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  Deployment failed: $_" -ForegroundColor Red
        return
    } finally {
        # Cleanup
        if (Test-Path $tempZipPath) {
            Remove-Item $tempZipPath -Force -ErrorAction SilentlyContinue
        }
    }

    # ─── Warmup Request ─────────────────────────────────────────────────────
    $appUrl = "https://$WebAppName.azurewebsites.net"
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Warming up the application..." -ForegroundColor Cyan
    $maxAttempts = 8
    $attempt = 0
    $ready = $false

    while ($attempt -lt $maxAttempts -and -not $ready) {
        $attempt++
        try {
            $response = Invoke-WebRequest -Uri $appUrl -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
            if ($response.StatusCode -eq 200) {
                Write-Host "  Application is ready (HTTP 200)" -ForegroundColor Green
                $ready = $true
            } else {
                Write-Host "  Attempt $attempt/$maxAttempts - HTTP $($response.StatusCode), retrying in 15s..." -ForegroundColor Gray
                Start-Sleep -Seconds 15
            }
        } catch {
            Write-Host "  Attempt $attempt/$maxAttempts - Not ready yet, retrying in 15s..." -ForegroundColor Gray
            Start-Sleep -Seconds 15
        }
    }

    if (-not $ready) {
        Write-Host "  App may still be starting. Try opening the URL in a minute." -ForegroundColor Yellow
    }

    # ─── Done ──────────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║           Deployment Complete!                   ║" -ForegroundColor Green
    Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    Write-Host "  URL: $appUrl" -ForegroundColor White
    Write-Host ""
    if ($UseMockData) {
        Write-Host "  Running with MOCK DATA. To switch to real SQL data:" -ForegroundColor Yellow
        Write-Host "  New-FGUI -ConfigFile '$ConfigFile'" -ForegroundColor Yellow
        Write-Host "  (without the -UseMockData flag)" -ForegroundColor Yellow
    } else {
        Write-Host "  Connected to: $sqlServerName / $databaseName" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  Make sure you have run Start-FGSync at least once" -ForegroundColor Gray
        Write-Host "  so the SQL views contain data." -ForegroundColor Gray
    }
    Write-Host ""

    if ($uiClientId) {
        Write-Host "  Authentication: Entra ID enabled (assignment required)" -ForegroundColor Green
        Write-Host "  App Registration: $uiAuthAppName" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  To grant others access:" -ForegroundColor White
        Write-Host "  Open Azure Portal > Enterprise Applications > $uiAuthAppName > Users and groups" -ForegroundColor Gray
    } else {
        Write-Host "  Authentication: Disabled" -ForegroundColor Yellow
        Write-Host "  Run New-FGUI again without -NoAuth to enable Entra ID auth." -ForegroundColor Yellow
    }
    Write-Host ""

    # ─── Apply Scaling ───────────────────────────────────────────────────
    if (-not $UseMockData) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Applying '$Scaling' scaling profile..." -ForegroundColor Cyan
        Write-Host "  This adjusts both the App Service and SQL Database to matched tiers" -ForegroundColor Gray
        Write-Host "  based on your environment size." -ForegroundColor Gray
        Write-Host ""

        try {
            Set-FGUI -ConfigFile $ConfigFile -Scaling $Scaling
        } catch {
            Write-Host "  Warning: Could not apply scaling: $_" -ForegroundColor Yellow
            Write-Host "  You can run Set-FGUI -ConfigFile '$ConfigFile' -Scaling '$Scaling' later." -ForegroundColor Yellow
        }
    }

    return [PSCustomObject]@{
        WebAppName    = $WebAppName
        URL           = $appUrl
        ResourceGroup = $resourceGroupName
        Location      = $Location
        Sku           = $Sku
        Scaling       = $Scaling
        DataMode      = if ($UseMockData) { 'Mock' } else { 'SQL' }
        Auth          = if ($uiClientId) { $uiClientId } else { 'Disabled' }
    }
}
