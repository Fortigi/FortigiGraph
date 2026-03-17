function Update-FGUI {
    [alias("Update-UI")]
    [CmdletBinding(DefaultParameterSetName = 'ConfigFile')]
    Param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ConfigFile')]
        [string]$ConfigFile,

        [Parameter(Mandatory = $false)]
        [Nullable[bool]]$PerformanceMetrics
    )

    # Suppress Az module deprecation warnings
    $WarningPreference = 'SilentlyContinue'

    # ─── Load Config ───────────────────────────────────────────────────────
    if (-not (Test-Path $ConfigFile)) {
        throw "Config file not found: $ConfigFile"
    }

    $config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json

    if (-not $config.UI -or -not $config.UI.WebAppName) {
        throw "No UI deployment found in config file. Run New-FGUI first."
    }

    $resourceGroupName = $config.Azure.ResourceGroupName
    $subscriptionId    = $config.Azure.SubscriptionId
    $WebAppName        = $config.UI.WebAppName

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║       FortigiGraph UI - Code Update              ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Web App:  $WebAppName" -ForegroundColor White
    Write-Host "  URL:      https://$WebAppName.azurewebsites.net" -ForegroundColor White
    Write-Host ""

    # ─── Azure Context ─────────────────────────────────────────────────────
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking Azure context..." -ForegroundColor Cyan
    try {
        $currentContext = Get-AzContext
        if (-not $currentContext) { throw "Not logged in" }
    } catch {
        throw "Not logged in to Azure. Please run Connect-AzAccount first."
    }

    if ($subscriptionId -and $currentContext.Subscription.Id -ne $subscriptionId) {
        Set-AzContext -SubscriptionId $subscriptionId | Out-Null
    }

    $subId = (Get-AzContext).Subscription.Id

    # ─── Update App Settings (module version + optional perf metrics) ────
    # Always update MODULE_VERSION on redeploy; also update perf if specified
    $psdPath = Join-Path $PSScriptRoot "..\..\FortigiGraph.psd1"
    $moduleVersion = $null
    if (Test-Path $psdPath) {
        $manifest = Import-PowerShellDataFile -Path $psdPath
        $moduleVersion = $manifest.ModuleVersion
    }

    if ($moduleVersion -or $null -ne $PerformanceMetrics) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Updating app settings..." -ForegroundColor Cyan

        try {
            $rawToken = (Get-AzAccessToken -ResourceUrl "https://management.azure.com" -WarningAction SilentlyContinue -ErrorAction Stop).Token
            $token = if ($rawToken -is [System.Security.SecureString]) { [System.Net.NetworkCredential]::new('', $rawToken).Password } else { $rawToken }
        } catch {
            throw "Azure token expired or MFA required. Please run: Connect-AzAccount -AuthScope https://management.azure.com"
        }

        $settingsUri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$resourceGroupName/providers/Microsoft.Web/sites/$WebAppName/config/appsettings/list?api-version=2023-01-01"
        $currentSettings = Invoke-RestMethod -Uri $settingsUri -Method POST -Headers @{ Authorization = "Bearer $token" } -ContentType "application/json"

        $properties = @{}
        foreach ($prop in $currentSettings.properties.PSObject.Properties) {
            $properties[$prop.Name] = $prop.Value
        }

        if ($null -ne $PerformanceMetrics) {
            $properties["PERF_METRICS_ENABLED"] = if ($PerformanceMetrics) { "true" } else { "false" }
        }

        # Feature flags (read from config, default to enabled for backward compatibility)
        if ($config.RiskScoring -and $config.RiskScoring.PSObject.Properties['Enabled']) {
            $properties["FEATURE_RISK_SCORING"] = if ($config.RiskScoring.Enabled -eq $false) { "false" } else { "true" }
        }
        if ($config.AccountCorrelation -and $config.AccountCorrelation.PSObject.Properties['Enabled']) {
            $properties["FEATURE_ACCOUNT_CORRELATION"] = if ($config.AccountCorrelation.Enabled -eq $false) { "false" } else { "true" }
        }

        if ($moduleVersion) {
            $properties["MODULE_VERSION"] = $moduleVersion
            Write-Host "  Module version: $moduleVersion" -ForegroundColor Green
        }

        $putUri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$resourceGroupName/providers/Microsoft.Web/sites/$WebAppName/config/appsettings?api-version=2023-01-01"
        $body = @{ properties = $properties } | ConvertTo-Json -Depth 10
        Invoke-RestMethod -Uri $putUri -Method PUT -Headers @{ Authorization = "Bearer $token" } -ContentType "application/json" -Body $body | Out-Null

        if ($null -ne $PerformanceMetrics) {
            $perfState = if ($PerformanceMetrics) { "Enabled" } else { "Disabled" }
            Write-Host "  Performance metrics: $perfState" -ForegroundColor Green
        }
    }

    # ─── Package Code ─────────────────────────────────────────────────────
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Packaging UI for deployment..." -ForegroundColor Cyan

    $uiSourcePath = Join-Path $PSScriptRoot "..\..\UI"
    $uiSourcePath = (Resolve-Path $uiSourcePath).Path

    if (-not (Test-Path $uiSourcePath)) {
        throw "UI source not found at: $uiSourcePath"
    }

    $tempZipPath = Join-Path ([System.IO.Path]::GetTempPath()) "fortigraph-ui-deploy.zip"

    try {
        if (Test-Path $tempZipPath) {
            Remove-Item $tempZipPath -Force
        }

        Write-Host "  Creating deployment package..." -ForegroundColor Gray

        $filesToZip = Get-ChildItem -Path $uiSourcePath -Recurse -File | Where-Object {
            $relativePath = $_.FullName.Substring($uiSourcePath.Length + 1)
            $relativePath -notmatch '(^|[\\/])node_modules[\\/]' -and
            $relativePath -notmatch '(^|[\\/])dist[\\/]' -and
            $relativePath -notmatch '(^|[\\/])\.env$' -and
            $relativePath -notmatch '(^|[\\/])\.git[\\/]'
        }

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

        # ─── Deploy via Kudu ──────────────────────────────────────────────
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Deploying to $WebAppName..." -ForegroundColor Cyan
        Write-Host "  This will take a few minutes (Azure rebuilds the app)..." -ForegroundColor Gray

        try {
            $rawToken = (Get-AzAccessToken -ResourceUrl "https://management.azure.com" -WarningAction SilentlyContinue -ErrorAction Stop).Token
            $token = if ($rawToken -is [System.Security.SecureString]) { [System.Net.NetworkCredential]::new('', $rawToken).Password } else { $rawToken }
        } catch {
            throw "Azure token expired or MFA required. Please run: Connect-AzAccount -AuthScope https://management.azure.com"
        }
        if (-not $token) {
            throw "Failed to acquire Azure access token. Please run: Connect-AzAccount -AuthScope https://management.azure.com"
        }

        $credsUri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$resourceGroupName/providers/Microsoft.Web/sites/$WebAppName/config/publishingcredentials/list?api-version=2023-01-01"
        $creds = Invoke-RestMethod -Uri $credsUri -Method POST -Headers @{ Authorization = "Bearer $token" } -ContentType "application/json"

        $kuduUser = $creds.properties.publishingUserName
        $kuduPass = $creds.properties.publishingPassword
        $kuduBase64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${kuduUser}:${kuduPass}"))

        $zipDeployUri = "https://$WebAppName.scm.azurewebsites.net/api/zipdeploy?isAsync=true"

        $deployResponse = Invoke-WebRequest -Uri $zipDeployUri -Method POST `
            -Headers @{ Authorization = "Basic $kuduBase64" } `
            -ContentType "application/octet-stream" `
            -InFile $tempZipPath `
            -TimeoutSec 120

        # ─── Poll deployment status ───────────────────────────────────────
        $pollUrl = $deployResponse.Headers['Location']
        if (-not $pollUrl) {
            $pollUrl = "https://$WebAppName.scm.azurewebsites.net/api/deployments/latest"
        }
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
        if (Test-Path $tempZipPath) {
            Remove-Item $tempZipPath -Force -ErrorAction SilentlyContinue
        }
    }

    # ─── Warmup Request ───────────────────────────────────────────────────
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

    # ─── Done ─────────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║           Update Complete!                        ║" -ForegroundColor Green
    Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    Write-Host "  URL: $appUrl" -ForegroundColor White
    Write-Host ""

    return [PSCustomObject]@{
        WebAppName    = $WebAppName
        URL           = $appUrl
        ResourceGroup = $resourceGroupName
    }
}
