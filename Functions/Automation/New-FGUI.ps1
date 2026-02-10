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
        [ValidateSet('F1', 'B1', 'B2', 'B3', 'S1', 'S2', 'S3')]
        [string]$Sku = 'F1',

        [Parameter(Mandatory = $false)]
        [switch]$UseMockData
    )

    # ─── Helper: Azure REST API call ───────────────────────────────────────
    function Invoke-AzureRestApi {
        param(
            [string]$Method,
            [string]$Uri,
            [object]$Body,
            [string]$ApiVersion = "2023-01-01"
        )

        $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
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

    # ─── SKU mapping ───────────────────────────────────────────────────────
    $skuMap = @{
        'F1' = @{ name = 'F1';  tier = 'Free';     kind = 'linux'; reserved = $true }
        'B1' = @{ name = 'B1';  tier = 'Basic';    kind = 'linux'; reserved = $true }
        'B2' = @{ name = 'B2';  tier = 'Basic';    kind = 'linux'; reserved = $true }
        'B3' = @{ name = 'B3';  tier = 'Basic';    kind = 'linux'; reserved = $true }
        'S1' = @{ name = 'S1';  tier = 'Standard'; kind = 'linux'; reserved = $true }
        'S2' = @{ name = 'S2';  tier = 'Standard'; kind = 'linux'; reserved = $true }
        'S3' = @{ name = 'S3';  tier = 'Standard'; kind = 'linux'; reserved = $true }
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
            $WebAppName = "fg-ui-$suffix"
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

    # ─── Verify Resource Group ─────────────────────────────────────────────
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Verifying resource group: $resourceGroupName..." -ForegroundColor Cyan
    $rg = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
    if (-not $rg) {
        throw "Resource group '$resourceGroupName' not found. Run New-FGConfig first."
    }
    Write-Host "  Resource group exists" -ForegroundColor Green

    # ─── Deployment Summary ────────────────────────────────────────────────
    Write-Host ""
    Write-Host "Deployment plan:" -ForegroundColor Yellow
    Write-Host "  Resource Group:    $resourceGroupName" -ForegroundColor White
    Write-Host "  Location:          $Location" -ForegroundColor White
    Write-Host "  App Service Plan:  $AppServicePlanName ($Sku)" -ForegroundColor White
    Write-Host "  Web App:           $WebAppName" -ForegroundColor White
    Write-Host "  URL:               https://$WebAppName.azurewebsites.net" -ForegroundColor White
    Write-Host "  Data mode:         $(if ($UseMockData) { 'Mock data' } else { 'Azure SQL' })" -ForegroundColor White
    if ($Sku -eq 'F1') {
        Write-Host "  Cost:              Free" -ForegroundColor White
    }
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
        # Check if plan already exists
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

    # ─── Configure App Settings (REST API) ─────────────────────────────────
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Configuring app settings..." -ForegroundColor Cyan

    $settingsList = @(
        @{ name = "WEBSITES_PORT";                  value = "3001" }
        @{ name = "SCM_DO_BUILD_DURING_DEPLOYMENT"; value = "true" }
        @{ name = "WEBSITE_NODE_DEFAULT_VERSION";   value = "~20" }
    )

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

        $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token

        # Get publish credentials
        $credsUri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$resourceGroupName/providers/Microsoft.Web/sites/$WebAppName/config/publishingcredentials/list?api-version=2023-01-01"
        $creds = Invoke-RestMethod -Uri $credsUri -Method POST -Headers @{ Authorization = "Bearer $token" } -ContentType "application/json"

        $kuduUser = $creds.properties.publishingUserName
        $kuduPass = $creds.properties.publishingPassword
        $kuduBase64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${kuduUser}:${kuduPass}"))

        # Zip deploy via Kudu
        $zipDeployUri = "https://$WebAppName.scm.azurewebsites.net/api/zipdeploy?isAsync=false"

        Invoke-WebRequest -Uri $zipDeployUri -Method POST `
            -Headers @{ Authorization = "Basic $kuduBase64" } `
            -ContentType "application/octet-stream" `
            -InFile $tempZipPath `
            -TimeoutSec 600 | Out-Null

        Write-Host "  Deployment complete" -ForegroundColor Green
    } catch {
        Write-Host "  Deployment failed: $_" -ForegroundColor Red
        return
    } finally {
        # Cleanup
        if (Test-Path $tempZipPath) {
            Remove-Item $tempZipPath -Force -ErrorAction SilentlyContinue
        }
    }

    # ─── Save UI settings to config ────────────────────────────────────────
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Saving UI settings to config file..." -ForegroundColor Cyan
    try {
        $config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json

        # Add or update UI section
        if (-not $config.UI) {
            $config | Add-Member -MemberType NoteProperty -Name 'UI' -Value ([PSCustomObject]@{
                WebAppName         = $WebAppName
                AppServicePlanName = $AppServicePlanName
                Location           = $Location
                Sku                = $Sku
                URL                = "https://$WebAppName.azurewebsites.net"
            })
        } else {
            $config.UI.WebAppName = $WebAppName
            $config.UI.AppServicePlanName = $AppServicePlanName
            $config.UI.Location = $Location
            $config.UI.Sku = $Sku
            $config.UI.URL = "https://$WebAppName.azurewebsites.net"
        }

        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigFile -Force
        Write-Host "  Config file updated" -ForegroundColor Green
    } catch {
        Write-Host "  Warning: Could not update config file: $_" -ForegroundColor Yellow
    }

    # ─── Done ──────────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║           Deployment Complete!                   ║" -ForegroundColor Green
    Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    Write-Host "  URL: https://$WebAppName.azurewebsites.net" -ForegroundColor White
    Write-Host ""
    Write-Host "  Note: The first load may take 1-2 minutes while Azure" -ForegroundColor Gray
    Write-Host "  builds the application (npm install + build)." -ForegroundColor Gray
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

    return [PSCustomObject]@{
        WebAppName    = $WebAppName
        URL           = "https://$WebAppName.azurewebsites.net"
        ResourceGroup = $resourceGroupName
        Location      = $Location
        Sku           = $Sku
        DataMode      = if ($UseMockData) { 'Mock' } else { 'SQL' }
    }
}
