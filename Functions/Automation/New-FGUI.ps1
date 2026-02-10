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
        [ValidateSet('B1', 'B2', 'B3', 'S1', 'S2', 'S3', 'F1')]
        [string]$Sku = 'B1',

        [Parameter(Mandatory = $false)]
        [switch]$UseMockData
    )

    # ─── Load Config ───────────────────────────────────────────────────────
    if (-not (Test-Path $ConfigFile)) {
        throw "Config file not found: $ConfigFile"
    }

    $config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json

    $resourceGroupName = $config.Azure.ResourceGroupName
    $location = $config.Azure.Location
    $sqlServerName = $config.Azure.SQLServerName
    $databaseName = $config.Azure.DatabaseName
    $subscriptionId = $config.Azure.SubscriptionId

    # Generate names if not provided
    if (-not $WebAppName) {
        $suffix = (Get-Random -Minimum 10000 -Maximum 99999)
        $WebAppName = "fg-ui-$suffix"
    }
    if (-not $AppServicePlanName) {
        $AppServicePlanName = "$WebAppName-plan"
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
    Write-Host "  Location:          $location" -ForegroundColor White
    Write-Host "  App Service Plan:  $AppServicePlanName ($Sku)" -ForegroundColor White
    Write-Host "  Web App:           $WebAppName" -ForegroundColor White
    Write-Host "  URL:               https://$WebAppName.azurewebsites.net" -ForegroundColor White
    Write-Host "  Data mode:         $(if ($UseMockData) { 'Mock data' } else { 'Azure SQL' })" -ForegroundColor White
    Write-Host ""
    $proceed = Read-Host "Proceed with deployment? (Y/N)"
    if ($proceed -notmatch '^[Yy]') {
        Write-Host "Aborted." -ForegroundColor Yellow
        return
    }

    # ─── Create App Service Plan ───────────────────────────────────────────
    Write-Host ""
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Creating App Service Plan: $AppServicePlanName..." -ForegroundColor Cyan
    $plan = Get-AzAppServicePlan -ResourceGroupName $resourceGroupName -Name $AppServicePlanName -ErrorAction SilentlyContinue

    if (-not $plan) {
        try {
            $plan = New-AzAppServicePlan `
                -ResourceGroupName $resourceGroupName `
                -Name $AppServicePlanName `
                -Location $location `
                -Tier $(if ($Sku -eq 'F1') { 'Free' } elseif ($Sku -match '^B') { 'Basic' } else { 'Standard' }) `
                -WorkerSize $(if ($Sku -match '1$') { 'Small' } elseif ($Sku -match '2$') { 'Medium' } else { 'Large' }) `
                -Linux `
                -ErrorAction Stop
            Write-Host "  App Service Plan created" -ForegroundColor Green
        } catch {
            Write-Host "  Failed to create App Service Plan: $_" -ForegroundColor Red
            return
        }
    } else {
        Write-Host "  App Service Plan already exists" -ForegroundColor Green
    }

    # ─── Create Web App ────────────────────────────────────────────────────
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Creating Web App: $WebAppName..." -ForegroundColor Cyan
    $webApp = Get-AzWebApp -ResourceGroupName $resourceGroupName -Name $WebAppName -ErrorAction SilentlyContinue

    if (-not $webApp) {
        try {
            $webApp = New-AzWebApp `
                -ResourceGroupName $resourceGroupName `
                -Name $WebAppName `
                -AppServicePlan $AppServicePlanName `
                -Runtime "NODE:20-lts" `
                -ErrorAction Stop
            Write-Host "  Web App created" -ForegroundColor Green
        } catch {
            Write-Host "  Failed to create Web App: $_" -ForegroundColor Red
            return
        }
    } else {
        Write-Host "  Web App already exists" -ForegroundColor Green
    }

    # ─── Configure App Settings ────────────────────────────────────────────
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Configuring app settings..." -ForegroundColor Cyan

    $appSettings = @{
        "WEBSITES_PORT"                    = "3001"
        "SCM_DO_BUILD_DURING_DEPLOYMENT"   = "true"
        "WEBSITE_NODE_DEFAULT_VERSION"     = "~20"
    }

    if ($UseMockData) {
        $appSettings["USE_SQL"] = "false"
    } else {
        # Get SQL password from config
        $sqlPassword = Get-FGSecureConfigValue -ConfigPath $ConfigFile `
            -PropertyPath "Azure.AdminUserPassword" `
            -PromptMessage "Enter SQL Admin Password"

        $sqlUser = $config.Azure.AdminUsername
        $fullServerName = if ($sqlServerName -match '\.database\.windows\.net$') {
            $sqlServerName
        } else {
            "$sqlServerName.database.windows.net"
        }

        $appSettings["USE_SQL"] = "true"
        $appSettings["SQL_SERVER"] = $fullServerName
        $appSettings["SQL_DATABASE"] = $databaseName
        $appSettings["SQL_USER"] = $sqlUser
        $appSettings["SQL_PASSWORD"] = $sqlPassword
    }

    try {
        Set-AzWebApp `
            -ResourceGroupName $resourceGroupName `
            -Name $WebAppName `
            -AppSettings $appSettings `
            -ErrorAction Stop | Out-Null
        Write-Host "  App settings configured" -ForegroundColor Green
    } catch {
        Write-Host "  Failed to configure app settings: $_" -ForegroundColor Red
        return
    }

    # ─── Configure Startup Command ─────────────────────────────────────────
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Setting startup command..." -ForegroundColor Cyan
    try {
        $resource = Get-AzResource -ResourceGroupName $resourceGroupName `
            -ResourceType "Microsoft.Web/sites/config" `
            -ResourceName "$WebAppName/web" `
            -ApiVersion "2022-03-01"

        $resource.Properties.appCommandLine = "cd backend && node src/index.js"
        $resource | Set-AzResource -Force -ApiVersion "2022-03-01" | Out-Null
        Write-Host "  Startup command configured" -ForegroundColor Green
    } catch {
        Write-Host "  Failed to set startup command: $_" -ForegroundColor Red
        Write-Host "  You can set it manually in Azure Portal > Web App > Configuration > Startup Command" -ForegroundColor Yellow
        Write-Host "  Command: cd backend && node src/index.js" -ForegroundColor Yellow
    }

    # ─── SQL Firewall Rule ─────────────────────────────────────────────────
    if (-not $UseMockData) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking SQL firewall for Azure services..." -ForegroundColor Cyan

        # Find the SQL server's resource group (may differ from the web app's)
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

        # Deploy using zip deploy
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Deploying to Azure App Service..." -ForegroundColor Cyan
        Write-Host "  This will take a few minutes (Azure builds the app on the server)..." -ForegroundColor Gray

        Publish-AzWebApp `
            -ResourceGroupName $resourceGroupName `
            -Name $WebAppName `
            -ArchivePath $tempZipPath `
            -Force `
            -ErrorAction Stop | Out-Null

        Write-Host "  Deployment initiated" -ForegroundColor Green
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
                Sku                = $Sku
                URL                = "https://$WebAppName.azurewebsites.net"
            })
        } else {
            $config.UI.WebAppName = $WebAppName
            $config.UI.AppServicePlanName = $AppServicePlanName
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
        WebAppName = $WebAppName
        URL        = "https://$WebAppName.azurewebsites.net"
        ResourceGroup = $resourceGroupName
        Sku        = $Sku
        DataMode   = if ($UseMockData) { 'Mock' } else { 'SQL' }
    }
}
