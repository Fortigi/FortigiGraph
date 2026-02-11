function Remove-FGUI {
    [alias("Remove-UI")]
    [CmdletBinding(DefaultParameterSetName = 'ConfigFile')]
    Param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ConfigFile')]
        [string]$ConfigFile
    )

    # ─── Load Config ───────────────────────────────────────────────────────
    if (-not (Test-Path $ConfigFile)) {
        throw "Config file not found: $ConfigFile"
    }

    $config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json

    if (-not $config.UI -or -not $config.UI.WebAppName) {
        Write-Host "No UI deployment found in config file." -ForegroundColor Yellow
        Write-Host "Nothing to remove." -ForegroundColor Yellow
        return
    }

    $resourceGroupName  = $config.Azure.ResourceGroupName
    $subscriptionId     = $config.Azure.SubscriptionId
    $webAppName         = $config.UI.WebAppName
    $appServicePlanName = $config.UI.AppServicePlanName
    $location           = $config.UI.Location
    $url                = $config.UI.URL

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║       FortigiGraph UI - Remove Deployment        ║" -ForegroundColor Yellow
    Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  This will DELETE the following Azure resources:" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Resource Group:    $resourceGroupName" -ForegroundColor White
    Write-Host "  Web App:           $webAppName" -ForegroundColor White
    Write-Host "  App Service Plan:  $appServicePlanName" -ForegroundColor White
    Write-Host "  Location:          $location" -ForegroundColor White
    Write-Host "  URL:               $url" -ForegroundColor White
    Write-Host ""
    Write-Host "  After removal, the App Service Plan stops billing." -ForegroundColor Gray
    Write-Host "  You can redeploy anytime with: New-FGUI -ConfigFile '$ConfigFile'" -ForegroundColor Gray
    Write-Host ""

    $proceed = Read-Host "Are you sure you want to remove the UI deployment? (Y/N)"
    if ($proceed -notmatch '^[Yy]') {
        Write-Host "Aborted." -ForegroundColor Yellow
        return
    }

    # ─── Azure Context ─────────────────────────────────────────────────────
    Write-Host ""
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

    # ─── Helper: Azure REST API call ───────────────────────────────────────
    function Invoke-AzureRestApi {
        param(
            [string]$Method,
            [string]$Uri,
            [string]$ApiVersion = "2023-01-01"
        )

        $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
        $headers = @{ Authorization = "Bearer $token" }
        $fullUri = if ($Uri -match '\?') { "$Uri&api-version=$ApiVersion" } else { "$Uri`?api-version=$ApiVersion" }

        return Invoke-RestMethod -Method $Method -Uri $fullUri -Headers $headers -ContentType "application/json"
    }

    # ─── Delete Web App ───────────────────────────────────────────────────
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Deleting Web App: $webAppName..." -ForegroundColor Cyan
    try {
        $webAppUri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$resourceGroupName/providers/Microsoft.Web/sites/$webAppName"
        Invoke-AzureRestApi -Method DELETE -Uri $webAppUri | Out-Null
        Write-Host "  Web App deleted" -ForegroundColor Green
    } catch {
        if ($_.Exception.Response.StatusCode -eq 'NotFound') {
            Write-Host "  Web App not found (already deleted)" -ForegroundColor Gray
        } else {
            Write-Host "  Failed to delete Web App: $_" -ForegroundColor Red
        }
    }

    # ─── Delete App Service Plan ──────────────────────────────────────────
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Deleting App Service Plan: $appServicePlanName..." -ForegroundColor Cyan
    try {
        $planUri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$resourceGroupName/providers/Microsoft.Web/serverfarms/$appServicePlanName"
        Invoke-AzureRestApi -Method DELETE -Uri $planUri | Out-Null
        Write-Host "  App Service Plan deleted" -ForegroundColor Green
    } catch {
        if ($_.Exception.Response.StatusCode -eq 'NotFound') {
            Write-Host "  App Service Plan not found (already deleted)" -ForegroundColor Gray
        } else {
            Write-Host "  Failed to delete App Service Plan: $_" -ForegroundColor Red
        }
    }

    # ─── Clear UI section from config ─────────────────────────────────────
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Clearing UI settings from config file..." -ForegroundColor Cyan
    try {
        $cfg = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json

        # Remove the UI property
        $cfg.PSObject.Properties.Remove('UI')

        $cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigFile -Force
        Write-Host "  Config file updated" -ForegroundColor Green
    } catch {
        Write-Host "  Warning: Could not update config file: $_" -ForegroundColor Yellow
    }

    # ─── Done ─────────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║           UI Deployment Removed                  ║" -ForegroundColor Green
    Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Azure resources deleted - billing stopped." -ForegroundColor White
    Write-Host ""
    Write-Host "  To redeploy later:" -ForegroundColor Gray
    Write-Host "  New-FGUI -ConfigFile '$ConfigFile'" -ForegroundColor Gray
    Write-Host ""
}
