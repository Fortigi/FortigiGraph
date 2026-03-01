function Set-FGUI {
    <#
    .SYNOPSIS
    Adjusts the scaling tier for both the FortigiGraph UI (App Service) and Azure SQL Database together.

    .DESCRIPTION
    Scales the App Service Plan and Azure SQL Database to matched tiers based on a named profile
    AND the actual size of your environment. The function queries your database to count rows in
    key tables, then selects the right SKUs for your data volume.

    "Fast" in a small environment (< 50K rows) is very different from "Fast" in a large environment
    (500K+ rows) — there's no need to overprovision.

    Profiles:
    - Tiny:    Cheapest possible. For very small setups (< 500 users). All features work.
    - Basic:   Minimum viable performance for the environment size. Cost-optimized.
    - Optimum: Good balance of performance and cost. Recommended for production.
    - Fast:    Maximum performance for the environment size. For demanding workloads.

    The actual SKUs selected depend on your data:

    Environment      Tiny                 Basic                Optimum              Fast
    ──────────────────────────────────────────────────────────────────────────────────────────
    Small (<50K)     Basic+B1  (~$18/mo)  Basic+B1  (~$18/mo)  S0+B1    (~$28/mo)  S1+B2    (~$56/mo)
    Medium (50-500K) Basic+B1  (~$18/mo)  S0+B1     (~$28/mo)  S1+B2    (~$56/mo)  S2+P0v3  (~$149/mo)
    Large (>500K)    S0+B1     (~$28/mo)  S1+B2     (~$56/mo)  S2+B2    (~$101/mo) S3+P1v3  (~$252/mo)

    .PARAMETER ConfigFile
    Path to the FortigiGraph config file (created by New-FGConfig).

    .PARAMETER Scaling
    The scaling profile to apply: Tiny, Basic, Optimum, or Fast.

    .EXAMPLE
    Set-FGUI -ConfigFile .\Config\mycompany.json -Scaling Optimum

    Queries the database, determines environment size, and scales both components accordingly.

    .EXAMPLE
    Set-FGUI -ConfigFile .\Config\mycompany.json -Scaling Fast

    Scales to the fastest tier appropriate for your environment size.

    .NOTES
    Requires Az PowerShell module (Az.Sql, Az.Websites)
    Must be logged in to Azure (Connect-AzAccount)
    UI must be deployed first (New-FGUI)
    For most accurate sizing, ensure a SQL connection exists (Connect-FGSQLServer)
    #>

    [alias("Set-UI")]
    [CmdletBinding(DefaultParameterSetName = 'ConfigFile')]
    Param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ConfigFile')]
        [string]$ConfigFile,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Tiny', 'Basic', 'Optimum', 'Fast')]
        [string]$Scaling
    )

    # Suppress Az module deprecation warnings
    $WarningPreference = 'SilentlyContinue'

    # ─── SKU definitions with estimated monthly costs (EUR/USD) ──────────
    # Costs based on West Europe / North Europe pricing (Feb 2026)
    $skuInfo = @{
        # SQL Database SKUs (DTU model)
        'Basic' = @{ DTU = 5;   SqlCost = 4.99;   SqlLabel = 'Basic (5 DTU)' }
        'S0'    = @{ DTU = 10;  SqlCost = 15.03;  SqlLabel = 'S0 (10 DTU)' }
        'S1'    = @{ DTU = 20;  SqlCost = 30.05;  SqlLabel = 'S1 (20 DTU)' }
        'S2'    = @{ DTU = 50;  SqlCost = 75.05;  SqlLabel = 'S2 (50 DTU)' }
        'S3'    = @{ DTU = 100; SqlCost = 150.17; SqlLabel = 'S3 (100 DTU)' }
        # App Service SKUs (Linux)
        'B1'    = @{ AppCost = 13.14; AppLabel = 'B1 (1 core, 1.75 GB)';  AppTier = 'Basic' }
        'B2'    = @{ AppCost = 26.28; AppLabel = 'B2 (2 cores, 3.5 GB)';  AppTier = 'Basic' }
        'P0v3'  = @{ AppCost = 74.46; AppLabel = 'P0v3 (1 core, 4 GB)';   AppTier = 'PremiumV3' }
        'P1v3'  = @{ AppCost = 126.29; AppLabel = 'P1v3 (2 cores, 8 GB)'; AppTier = 'PremiumV3' }
    }

    # ─── Context-Aware Scaling Matrix ────────────────────────────────────
    # Rows = environment size, Columns = scaling profile
    # Each entry: @(SqlSku, AppServiceSku)
    $scalingMatrix = @{
        'Small' = @{
            'Tiny'    = @('Basic', 'B1')
            'Basic'   = @('Basic', 'B1')
            'Optimum' = @('S0',    'B1')
            'Fast'    = @('S1',    'B2')
        }
        'Medium' = @{
            'Tiny'    = @('Basic', 'B1')
            'Basic'   = @('S0',    'B1')
            'Optimum' = @('S1',    'B2')
            'Fast'    = @('S2',    'P0v3')
        }
        'Large' = @{
            'Tiny'    = @('S0',    'B1')
            'Basic'   = @('S1',    'B2')
            'Optimum' = @('S2',    'B2')
            'Fast'    = @('S3',    'P1v3')
        }
    }

    # ─── Load Config ─────────────────────────────────────────────────────
    if (-not (Test-Path $ConfigFile)) {
        throw "Config file not found: $ConfigFile"
    }

    $config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json

    if (-not $config.UI -or -not $config.UI.WebAppName) {
        throw "No UI deployment found in config file. Run New-FGUI first."
    }

    $resourceGroupName  = $config.Azure.ResourceGroupName
    $subscriptionId     = $config.Azure.SubscriptionId
    $sqlServerName      = $config.Azure.SQLServerName
    $databaseName       = $config.Azure.DatabaseName
    $webAppName         = $config.UI.WebAppName
    $appServicePlanName = $config.UI.AppServicePlanName

    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "       FortigiGraph UI - Scaling Configuration      " -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host ""

    # ─── Azure Context ───────────────────────────────────────────────────
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

    if ($subscriptionId -and $currentContext.Subscription.Id -ne $subscriptionId) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Setting subscription to $subscriptionId..." -ForegroundColor Cyan
        Set-AzContext -SubscriptionId $subscriptionId | Out-Null
    }

    $subId = (Get-AzContext).Subscription.Id

    # ─── Determine Environment Size ──────────────────────────────────────
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Analyzing environment size..." -ForegroundColor Cyan

    $totalRows = 0
    $userCount = 0
    $groupCount = 0
    $membershipCount = 0
    $environmentSize = 'Unknown'
    $rowDetails = @{}

    # Try to query SQL for actual row counts
    $sqlConnected = $false
    if ($Global:FGSQLConnectionString) {
        try {
            $rowDetails = Invoke-FGSQLCommand -ScriptBlock {
                param($connection)

                $counts = @{}
                $tables = @(
                    'GraphUsers',
                    'GraphGroups',
                    'GraphGroupMembers',
                    'GraphGroupOwners',
                    'GraphAccessPackageAssignments',
                    'mat_UserPermissionAssignments'
                )

                foreach ($table in $tables) {
                    try {
                        $cmd = $connection.CreateCommand()
                        $cmd.CommandText = "SELECT COUNT(*) FROM [$table]"
                        $count = $cmd.ExecuteScalar()
                        $counts[$table] = [int]$count
                    } catch {
                        # Table may not exist
                        $counts[$table] = 0
                    }
                }

                return $counts
            }

            $sqlConnected = $true

            $userCount = if ($rowDetails['GraphUsers']) { $rowDetails['GraphUsers'] } else { 0 }
            $groupCount = if ($rowDetails['GraphGroups']) { $rowDetails['GraphGroups'] } else { 0 }
            $membershipCount = if ($rowDetails['GraphGroupMembers']) { $rowDetails['GraphGroupMembers'] } else { 0 }
            $matCount = if ($rowDetails['mat_UserPermissionAssignments']) { $rowDetails['mat_UserPermissionAssignments'] } else { 0 }

            # Use materialized table if available, otherwise sum key tables
            if ($matCount -gt 0) {
                $totalRows = $matCount
            } else {
                $totalRows = $membershipCount
            }

            Write-Host "  Database row counts:" -ForegroundColor White
            foreach ($table in $rowDetails.Keys | Sort-Object) {
                if ($rowDetails[$table] -gt 0) {
                    Write-Host "    $($table): $($rowDetails[$table].ToString('N0'))" -ForegroundColor Gray
                }
            }
        } catch {
            Write-Host "  Could not query SQL: $_" -ForegroundColor Yellow
        }
    }

    # Fallback: try to get database size from Azure if no SQL connection
    if (-not $sqlConnected) {
        Write-Host "  No SQL connection active. Using Azure database metrics as estimate..." -ForegroundColor Yellow
        $sqlServerShortFallback = $sqlServerName.Split('.')[0]
        try {
            $sqlDb = Get-AzSqlDatabase -ResourceGroupName $resourceGroupName `
                -ServerName $sqlServerShortFallback -DatabaseName $databaseName -ErrorAction Stop
            $dbSizeMB = [math]::Round($sqlDb.CurrentServiceObjectiveName -eq 'Basic' ? 2048 : ($sqlDb.MaxSizeBytes / 1MB), 0)
            $usedMB = [math]::Round(($sqlDb.CurrentServiceObjectiveName -eq 'Basic' ? $sqlDb.MaxSizeBytes : $sqlDb.MaxSizeBytes) / 1MB, 0)

            Write-Host "  Database tier: $($sqlDb.CurrentServiceObjectiveName), Size: ~${usedMB} MB" -ForegroundColor Gray
            Write-Host "  Tip: Run Connect-FGSQLServer first for precise row-based sizing" -ForegroundColor Gray

            # Rough estimate: ~1KB per row average for Graph data
            $totalRows = [math]::Max($usedMB * 1000, 10000)
        } catch {
            Write-Host "  Could not read database metrics. Using default (Medium) sizing." -ForegroundColor Yellow
            $totalRows = 100000
        }
    }

    # Determine environment size
    if ($totalRows -lt 50000) {
        $environmentSize = 'Small'
    } elseif ($totalRows -le 500000) {
        $environmentSize = 'Medium'
    } else {
        $environmentSize = 'Large'
    }

    Write-Host ""
    Write-Host "  Environment size: $environmentSize ($($totalRows.ToString('N0')) rows)" -ForegroundColor Cyan
    if ($userCount -gt 0) {
        Write-Host "  Users: $($userCount.ToString('N0'))  |  Groups: $($groupCount.ToString('N0'))  |  Memberships: $($membershipCount.ToString('N0'))" -ForegroundColor Gray
    }

    # ─── Resolve Target SKUs ─────────────────────────────────────────────
    $targetSkus = $scalingMatrix[$environmentSize][$Scaling]
    $targetSqlSku = $targetSkus[0]
    $targetAppSku = $targetSkus[1]

    $sqlInfo = $skuInfo[$targetSqlSku]
    $appInfo = $skuInfo[$targetAppSku]

    # ─── Get Current State ───────────────────────────────────────────────
    Write-Host ""
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Reading current configuration..." -ForegroundColor Cyan

    # Get current App Service Plan SKU
    $currentAppSku = "Unknown"
    $currentAppTier = "Unknown"
    try {
        $planUri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$resourceGroupName/providers/Microsoft.Web/serverfarms/${appServicePlanName}?api-version=2023-01-01"
        $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com" -WarningAction SilentlyContinue -ErrorAction Stop).Token
        $planResult = Invoke-RestMethod -Uri $planUri -Headers @{ Authorization = "Bearer $token" } -Method GET
        $currentAppSku = $planResult.sku.name
        $currentAppTier = $planResult.sku.tier
        Write-Host "  App Service Plan: $currentAppSku ($currentAppTier)" -ForegroundColor White
    } catch {
        Write-Host "  App Service Plan: Could not read current SKU" -ForegroundColor Yellow
    }

    # Get current SQL Database SKU
    $currentSqlSku = "Unknown"
    $currentSqlDTU = "Unknown"
    $sqlServerShort = $sqlServerName.Split('.')[0]
    try {
        $sqlDb = Get-AzSqlDatabase -ResourceGroupName $resourceGroupName -ServerName $sqlServerShort -DatabaseName $databaseName -ErrorAction Stop
        $currentSqlSku = $sqlDb.CurrentServiceObjectiveName
        $currentSqlDTU = $sqlDb.Capacity
        Write-Host "  SQL Database:     $currentSqlSku ($currentSqlDTU DTU)" -ForegroundColor White
    } catch {
        Write-Host "  SQL Database: Could not read current SKU" -ForegroundColor Yellow
    }

    # ─── Check if Already at Target ─────────────────────────────────────
    $appAlreadyAtTarget = ($currentAppSku -eq $targetAppSku)
    $sqlAlreadyAtTarget = ($currentSqlSku -eq $targetSqlSku)

    $totalCost = $appInfo.AppCost + $sqlInfo.SqlCost

    if ($appAlreadyAtTarget -and $sqlAlreadyAtTarget) {
        Write-Host ""
        Write-Host "  Both components are already at the '$Scaling' tier for a $environmentSize environment." -ForegroundColor Green
        Write-Host "  No changes needed." -ForegroundColor Green
        Write-Host ""
        Write-Host "  Estimated monthly cost:" -ForegroundColor White
        Write-Host "    App Service ($targetAppSku):   `$$([math]::Round($appInfo.AppCost, 2))/mo" -ForegroundColor Gray
        Write-Host "    SQL Database ($targetSqlSku):   `$$([math]::Round($sqlInfo.SqlCost, 2))/mo" -ForegroundColor Gray
        Write-Host "    ─────────────────────────────" -ForegroundColor Gray
        Write-Host "    Total:                    `$$([math]::Round($totalCost, 2))/mo" -ForegroundColor White
        Write-Host ""
        return
    }

    # ─── Show Scaling Plan ───────────────────────────────────────────────
    Write-Host ""
    Write-Host "  Scaling profile: $Scaling (for $environmentSize environment)" -ForegroundColor Yellow
    Write-Host ""

    # Show all profiles for context
    Write-Host "  Available profiles for $environmentSize environment:" -ForegroundColor White
    foreach ($profile in @('Tiny', 'Basic', 'Optimum', 'Fast')) {
        $pSkus = $scalingMatrix[$environmentSize][$profile]
        $pSqlInfo = $skuInfo[$pSkus[0]]
        $pAppInfo = $skuInfo[$pSkus[1]]
        $pTotal = $pSqlInfo.SqlCost + $pAppInfo.AppCost
        $marker = if ($profile -eq $Scaling) { " <--" } else { "" }
        $color = if ($profile -eq $Scaling) { "Yellow" } else { "Gray" }
        Write-Host "    $($profile.PadRight(8)) $($pSkus[1].PadRight(5)) + $($pSkus[0].PadRight(6)) = `$$([math]::Round($pTotal, 2))/mo$marker" -ForegroundColor $color
    }

    Write-Host ""
    Write-Host "  Component            Current              Target" -ForegroundColor White
    Write-Host "  ─────────────────────────────────────────────────────────" -ForegroundColor Gray

    if ($appAlreadyAtTarget) {
        Write-Host "  App Service Plan     $($currentAppSku.PadRight(20)) $targetAppSku (no change)" -ForegroundColor Gray
    } else {
        Write-Host "  App Service Plan     $($currentAppSku.PadRight(20)) $($appInfo.AppLabel)" -ForegroundColor Yellow
    }

    if ($sqlAlreadyAtTarget) {
        Write-Host "  SQL Database         $($currentSqlSku.PadRight(20)) $targetSqlSku (no change)" -ForegroundColor Gray
    } else {
        Write-Host "  SQL Database         $($currentSqlSku.PadRight(20)) $($sqlInfo.SqlLabel)" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "  Estimated monthly cost after scaling:" -ForegroundColor White
    Write-Host "    App Service ($targetAppSku):   `$$([math]::Round($appInfo.AppCost, 2))/mo" -ForegroundColor Gray
    Write-Host "    SQL Database ($targetSqlSku):   `$$([math]::Round($sqlInfo.SqlCost, 2))/mo" -ForegroundColor Gray
    Write-Host "    ─────────────────────────────" -ForegroundColor Gray
    Write-Host "    Total:                    `$$([math]::Round($totalCost, 2))/mo" -ForegroundColor White
    Write-Host ""

    $proceed = Read-Host "Apply scaling changes? (Y/N)"
    if ($proceed -notmatch '^[Yy]') {
        Write-Host "Aborted." -ForegroundColor Yellow
        return
    }

    # ─── Scale SQL Database ──────────────────────────────────────────────
    if (-not $sqlAlreadyAtTarget) {
        Write-Host ""
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Scaling SQL Database to $targetSqlSku..." -ForegroundColor Cyan
        Write-Host "  This may take a few minutes (Azure performs an online migration)..." -ForegroundColor Gray

        try {
            Set-AzSqlDatabase -ResourceGroupName $resourceGroupName `
                -ServerName $sqlServerShort `
                -DatabaseName $databaseName `
                -RequestedServiceObjectiveName $targetSqlSku `
                -ErrorAction Stop | Out-Null

            Write-Host "  SQL Database scaled to $($sqlInfo.SqlLabel)" -ForegroundColor Green
        } catch {
            Write-Host "  Failed to scale SQL Database: $_" -ForegroundColor Red
            Write-Host "  You can scale manually:" -ForegroundColor Yellow
            Write-Host "  Set-AzSqlDatabase -ResourceGroupName '$resourceGroupName' -ServerName '$sqlServerShort' -DatabaseName '$databaseName' -RequestedServiceObjectiveName '$targetSqlSku'" -ForegroundColor Yellow
        }
    }

    # ─── Scale App Service Plan ──────────────────────────────────────────
    if (-not $appAlreadyAtTarget) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Scaling App Service Plan to $targetAppSku..." -ForegroundColor Cyan

        try {
            $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com" -WarningAction SilentlyContinue -ErrorAction Stop).Token

            $planUri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$resourceGroupName/providers/Microsoft.Web/serverfarms/${appServicePlanName}?api-version=2023-01-01"
            $planBody = @{
                location   = if ($config.UI.Location) { $config.UI.Location } else { $config.Azure.Location }
                kind       = "linux"
                properties = @{ reserved = $true }
                sku        = @{ name = $targetAppSku; tier = $appInfo.AppTier }
            }

            Invoke-RestMethod -Uri $planUri -Method PUT `
                -Headers @{ Authorization = "Bearer $token" } `
                -ContentType "application/json" `
                -Body ($planBody | ConvertTo-Json -Depth 10) | Out-Null

            Write-Host "  App Service Plan scaled to $($appInfo.AppLabel)" -ForegroundColor Green
        } catch {
            $errorMessage = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($errorMessage -and $errorMessage.Message -match 'quota') {
                Write-Host "  Failed: No App Service quota for $targetAppSku in this region." -ForegroundColor Red
                Write-Host "  Request quota at: Azure Portal > Quotas > App Service" -ForegroundColor Yellow
            } else {
                Write-Host "  Failed to scale App Service Plan: $_" -ForegroundColor Red
            }
        }
    }

    # ─── Update Config File ──────────────────────────────────────────────
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Updating config file..." -ForegroundColor Cyan
    try {
        $cfg = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json

        $cfg.UI.Sku = $targetAppSku

        if ($cfg.UI.PSObject.Properties['Scaling']) {
            $cfg.UI.Scaling = $Scaling
        } else {
            $cfg.UI | Add-Member -MemberType NoteProperty -Name 'Scaling' -Value $Scaling
        }

        if ($cfg.UI.PSObject.Properties['SqlSku']) {
            $cfg.UI.SqlSku = $targetSqlSku
        } else {
            $cfg.UI | Add-Member -MemberType NoteProperty -Name 'SqlSku' -Value $targetSqlSku
        }

        if ($cfg.UI.PSObject.Properties['EnvironmentSize']) {
            $cfg.UI.EnvironmentSize = $environmentSize
        } else {
            $cfg.UI | Add-Member -MemberType NoteProperty -Name 'EnvironmentSize' -Value $environmentSize
        }

        $cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigFile -Force
        Write-Host "  Config file updated" -ForegroundColor Green
    } catch {
        Write-Host "  Warning: Could not update config file: $_" -ForegroundColor Yellow
    }

    # ─── Summary ─────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Green
    Write-Host "       Scaling Complete                             " -ForegroundColor Green
    Write-Host "==================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Profile:           $Scaling" -ForegroundColor White
    Write-Host "  Environment:       $environmentSize ($($totalRows.ToString('N0')) rows)" -ForegroundColor White
    Write-Host "  App Service Plan:  $($appInfo.AppLabel)" -ForegroundColor White
    Write-Host "  SQL Database:      $($sqlInfo.SqlLabel)" -ForegroundColor White
    Write-Host ""
    Write-Host "  ┌─────────────────────────────────────────────────┐" -ForegroundColor Gray
    Write-Host "  │  Estimated Monthly Cost                         │" -ForegroundColor White
    Write-Host "  ├─────────────────────────────────────────────────┤" -ForegroundColor Gray
    Write-Host "  │  App Service ($($targetAppSku.PadRight(4))):   `$$([string]::Format('{0,7:N2}', $appInfo.AppCost))/mo     │" -ForegroundColor Gray
    Write-Host "  │  SQL Database ($($targetSqlSku.PadRight(5))): `$$([string]::Format('{0,7:N2}', $sqlInfo.SqlCost))/mo     │" -ForegroundColor Gray
    Write-Host "  ├─────────────────────────────────────────────────┤" -ForegroundColor Gray
    Write-Host "  │  Total:              `$$([string]::Format('{0,7:N2}', $totalCost))/mo     │" -ForegroundColor White
    Write-Host "  └─────────────────────────────────────────────────┘" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Note: Costs are estimates based on West/North Europe pricing." -ForegroundColor Gray
    Write-Host "  Check Azure Portal > Cost Analysis for precise billing." -ForegroundColor Gray
    Write-Host ""

    return [PSCustomObject]@{
        Scaling          = $Scaling
        EnvironmentSize  = $environmentSize
        TotalRows        = $totalRows
        AppServiceSku    = $targetAppSku
        AppServiceTier   = $appInfo.AppTier
        SqlSku           = $targetSqlSku
        SqlDTU           = $sqlInfo.DTU
        EstMonthlyCost   = [math]::Round($totalCost, 2)
        AppServiceCost   = $appInfo.AppCost
        SqlCost          = $sqlInfo.SqlCost
    }
}
