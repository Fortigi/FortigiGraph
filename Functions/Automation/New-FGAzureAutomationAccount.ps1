function New-FGAzureAutomationAccount {
    <#
    .SYNOPSIS
    Creates an Azure Automation Account configured for FortigiGraph sync operations.

    .DESCRIPTION
    Provisions an Azure Automation Account with all necessary components for running
    FortigiGraph sync operations:
    - Creates Automation Account (if not exists)
    - Creates encrypted variables for Graph and SQL credentials
    - Imports required PowerShell modules (Az.Accounts, Az.Sql)
    - Creates runbooks for each sync type (Users, Groups, GroupMembers, etc.)
    - Optionally creates schedules for automated sync

    Can read credentials from a config file (same format as Start-FGSync).

    .PARAMETER SubscriptionId
    The Azure Subscription ID where the Automation Account will be created.

    .PARAMETER ResourceGroupName
    The Resource Group name. Will be created if it doesn't exist.

    .PARAMETER AutomationAccountName
    The name for the Automation Account.

    .PARAMETER Location
    Azure region (e.g., "westeurope", "northeurope"). Default: "northeurope"

    .PARAMETER ConfigFile
    Path to config file containing Graph and SQL credentials.
    If provided, credentials will be read from the config file.

    .PARAMETER GraphTenantId
    Microsoft Graph Tenant ID. Required if ConfigFile not provided.

    .PARAMETER GraphClientId
    Microsoft Graph Application (Client) ID. Required if ConfigFile not provided.

    .PARAMETER GraphClientSecret
    Microsoft Graph Client Secret. Required if ConfigFile not provided.

    .PARAMETER SQLServerName
    Azure SQL Server name (without .database.windows.net). Required if ConfigFile not provided.

    .PARAMETER SQLDatabaseName
    Azure SQL Database name. Required if ConfigFile not provided.

    .PARAMETER SQLAdminUsername
    SQL Server admin username. Required if ConfigFile not provided.

    .PARAMETER SQLAdminPassword
    SQL Server admin password. Required if ConfigFile not provided.

    .PARAMETER SkipRunbooks
    If specified, skips creating runbooks. By default, runbooks are created.

    .PARAMETER CreateSchedules
    If specified, creates schedules for the runbooks.
    When using ConfigFile, schedules are created automatically if Schedules.Enabled is true in the config.

    .PARAMETER SkipModuleImport
    If specified, skips importing Az modules. Useful if you want to import FortigiGraph manually.

    .PARAMETER SkipModuleUpload
    If specified, skips uploading the local FortigiGraph module. By default, the module is uploaded.
    Use this if you prefer to import from PowerShell Gallery manually.

    .PARAMETER ModulePath
    Path to the FortigiGraph module folder. If not specified, automatically detected from the loaded
    FortigiGraph module. Falls back to the parent folder of this script's location.

    .PARAMETER RunbookType
    The PowerShell runtime type for runbooks. Default: "PowerShell72" (PowerShell 7.2).
    Options: "PowerShell" (5.1), "PowerShell72" (7.2).

    .EXAMPLE
    New-FGAzureAutomationAccount -ConfigFile ".\config.json"

    Creates Automation Account using all settings from config file (SubscriptionId, ResourceGroupName,
    AutomationAccountName, credentials), creates variables, imports modules, and creates runbooks.

    .EXAMPLE
    New-FGAzureAutomationAccount -ConfigFile ".\config.json" -SkipRunbooks

    Creates Automation Account with variables and modules, but skips creating runbooks.

    .EXAMPLE
    New-FGAzureAutomationAccount -SubscriptionId "xxx" -ResourceGroupName "rg-fortigraph" -AutomationAccountName "aa-fortigraph" -GraphTenantId "xxx" -GraphClientId "xxx" -GraphClientSecret "xxx" -SQLServerName "sql-fortigraph" -SQLDatabaseName "GraphDB" -SQLAdminUsername "sqladmin" -SQLAdminPassword "xxx"

    Creates Automation Account with all explicit parameters (no config file).

    .NOTES
    Requires Az PowerShell module (Install-Module -Name Az)
    Must be logged in to Azure (Connect-AzAccount)

    FortigiGraph module must be imported manually into the Automation Account
    (upload from PowerShell Gallery or as a zip file).
    #>

    [CmdletBinding(DefaultParameterSetName = 'ConfigFile')]
    [Alias("New-AutomationAccount")]
    Param(
        [Parameter(Mandatory = $false)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $false)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $false)]
        [string]$AutomationAccountName,

        [Parameter(Mandatory = $false)]
        [string]$Location,

        [Parameter(Mandatory = $true, ParameterSetName = 'ConfigFile')]
        [string]$ConfigFile,

        [Parameter(Mandatory = $true, ParameterSetName = 'Explicit')]
        [string]$GraphTenantId,

        [Parameter(Mandatory = $true, ParameterSetName = 'Explicit')]
        [string]$GraphClientId,

        [Parameter(Mandatory = $true, ParameterSetName = 'Explicit')]
        [string]$GraphClientSecret,

        [Parameter(Mandatory = $true, ParameterSetName = 'Explicit')]
        [string]$SQLServerName,

        [Parameter(Mandatory = $true, ParameterSetName = 'Explicit')]
        [string]$SQLDatabaseName,

        [Parameter(Mandatory = $true, ParameterSetName = 'Explicit')]
        [string]$SQLAdminUsername,

        [Parameter(Mandatory = $true, ParameterSetName = 'Explicit')]
        [string]$SQLAdminPassword,

        [Parameter(Mandatory = $false)]
        [switch]$SkipRunbooks,

        [Parameter(Mandatory = $false)]
        [switch]$CreateSchedules,

        [Parameter(Mandatory = $false)]
        [switch]$SkipModuleImport,

        [Parameter(Mandatory = $false)]
        [switch]$SkipModuleUpload,

        [Parameter(Mandatory = $false)]
        [string]$ModulePath,

        [Parameter(Mandatory = $false)]
        [ValidateSet("PowerShell", "PowerShell72")]
        [string]$RunbookType = "PowerShell72"
    )

    # Check if Az.Automation module is available
    if (-not (Get-Module -ListAvailable -Name Az.Automation)) {
        throw "Az.Automation module not found. Please install it with: Install-Module -Name Az"
    }

    # Check if logged in to Azure
    try {
        $context = Get-AzContext
        if (-not $context) {
            throw "Not logged in to Azure"
        }
    }
    catch {
        throw "Not logged in to Azure. Please run Connect-AzAccount first."
    }

    # Load credentials from config file if provided
    if ($PSCmdlet.ParameterSetName -eq 'ConfigFile') {
        if (-not (Test-Path $ConfigFile)) {
            throw "Config file not found: $ConfigFile"
        }

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Loading configuration from config file..." -ForegroundColor Cyan
        $config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json

        # Extract Azure settings (only if not provided via command line)
        if (-not $SubscriptionId -and $config.Azure.SubscriptionId) {
            $SubscriptionId = $config.Azure.SubscriptionId
        }
        if (-not $ResourceGroupName -and $config.Azure.ResourceGroupName) {
            $ResourceGroupName = $config.Azure.ResourceGroupName
        }
        if (-not $AutomationAccountName -and $config.Azure.AutomationAccountName) {
            $AutomationAccountName = $config.Azure.AutomationAccountName
        }
        if (-not $Location -and $config.Azure.Location) {
            $Location = $config.Azure.Location
        }

        # Extract Graph credentials (use Get-FGSecureConfigValue for secrets)
        $GraphTenantId = $config.Graph.TenantId
        $GraphClientId = $config.Graph.ClientId
        $GraphClientSecret = Get-FGSecureConfigValue -ConfigPath $ConfigFile -PropertyPath "Graph.ClientSecret" -PromptMessage "Enter Graph Client Secret"

        # Extract SQL credentials (use Get-FGSecureConfigValue for password)
        $SQLServerName = $config.Azure.SQLServerName
        $SQLDatabaseName = $config.Azure.DatabaseName
        $SQLAdminUsername = $config.Azure.AdminUsername
        $SQLAdminPassword = Get-FGSecureConfigValue -ConfigPath $ConfigFile -PropertyPath "Azure.AdminUserPassword" -PromptMessage "Enter SQL Admin Password"

        # Extract sync configuration (optional)
        $syncConfig = @{
            UsersAdditionalAttributes = @()
            UsersFilter = ""
            GroupsAdditionalAttributes = @()
            GroupsFilter = ""
        }

        if ($config.Sync.Users.AdditionalAttributes) {
            $syncConfig.UsersAdditionalAttributes = @($config.Sync.Users.AdditionalAttributes)
        }
        if ($config.Sync.Users.Filter) {
            $syncConfig.UsersFilter = $config.Sync.Users.Filter
        }
        if ($config.Sync.Groups.AdditionalAttributes) {
            $syncConfig.GroupsAdditionalAttributes = @($config.Sync.Groups.AdditionalAttributes)
        }
        if ($config.Sync.Groups.Filter) {
            $syncConfig.GroupsFilter = $config.Sync.Groups.Filter
        }

        # Extract schedule configuration from within each Sync entity
        $scheduleConfig = @{
            Enabled = $false
            TimeZone = "UTC"
            Schedules = @()
        }

        # Get time zone from Sync section
        if ($config.Sync.ScheduleTimeZone) {
            $scheduleConfig.TimeZone = $config.Sync.ScheduleTimeZone
        }

        # Map runbook names to sync config keys
        $scheduleMapping = @{
            "Sync-FGUsers" = "Users"
            "Sync-FGGroups" = "Groups"
            "Sync-FGGroupMembers" = "GroupMembers"
            "Sync-FGGroupEligibleMembers" = "GroupEligibleMembers"
            "Sync-FGGroupOwners" = "GroupOwners"
            "Sync-FGCatalogs" = "Catalogs"
            "Sync-FGAccessPackages" = "AccessPackages"
            "Sync-FGAccessPackageAssignments" = "AccessPackageAssignments"
            "Sync-FGAccessPackageResourceRoleScopes" = "AccessPackageResourceRoleScopes"
            "Sync-FGAccessPackageAssignmentPolicies" = "AccessPackageAssignmentPolicies"
            "Sync-FGAccessPackageAssignmentRequests" = "AccessPackageAssignmentRequests"
            "Sync-FGAccessPackageAccessReviews" = "AccessPackageAccessReviews"
            "Sync-FGEntraDirectoryRoles" = "EntraDirectoryRoles"
            "Sync-FGEntraAppRoleAssignments" = "EntraAppRoleAssignments"
            "Sync-FGResourceRelationships" = "ResourceRelationships"
            "Sync-FGPrincipals" = "Principals"
            "Sync-FGOrgUnits" = "OrgUnits"
            "Sync-FGMaterializedViews" = "MaterializedViews"
        }

        $syncSchedulesFound = $false
        foreach ($runbookName in $scheduleMapping.Keys) {
            $configKey = $scheduleMapping[$runbookName]
            $syncEntry = $config.Sync.$configKey

            # Check if this sync entity has a Schedule sub-section
            if ($syncEntry -and $syncEntry.Schedule) {
                # Handle both single schedule object and array of schedules
                $scheduleEntries = @()
                if ($syncEntry.Schedule -is [Array]) {
                    $scheduleEntries = $syncEntry.Schedule
                }
                else {
                    $scheduleEntries = @($syncEntry.Schedule)
                }

                foreach ($scheduleEntry in $scheduleEntries) {
                    if ($scheduleEntry.Enabled -eq $true) {
                        $scheduleConfig.Enabled = $true  # At least one schedule is enabled
                        $syncSchedulesFound = $true
                        $time = if ($scheduleEntry.Time) { $scheduleEntry.Time } else { "06:00" }
                        $frequency = if ($scheduleEntry.Frequency) { $scheduleEntry.Frequency } else { "Daily" }

                        $scheduleConfig.Schedules += @{
                            RunbookName = $runbookName
                            ConfigKey = $configKey
                            Time = $time
                            Frequency = $frequency
                        }
                    }
                }
            }
        }

        # Check for risk scoring — respect Enabled flag
        $riskScoringEnabled = -not ($config.RiskScoring -and $config.RiskScoring.PSObject.Properties['Enabled'] -and $config.RiskScoring.Enabled -eq $false)
        if ($riskScoringEnabled) {
            if ($config.RiskScoring -and $config.RiskScoring.Schedule -and $config.RiskScoring.Schedule.Enabled -eq $true) {
                $scheduleConfig.Enabled = $true
                $rsTime = if ($config.RiskScoring.Schedule.Time) { $config.RiskScoring.Schedule.Time } else { "10:30" }
                $rsFreq = if ($config.RiskScoring.Schedule.Frequency) { $config.RiskScoring.Schedule.Frequency } else { "Daily" }
                $scheduleConfig.Schedules += @{
                    RunbookName = "Invoke-FGRiskScoring"
                    ConfigKey   = "RiskScoring"
                    Time        = $rsTime
                    Frequency   = $rsFreq
                }
            }
            elseif (-not $config.RiskScoring -or -not $config.RiskScoring.Schedule -or $config.RiskScoring.Schedule.Enabled -ne $true) {
                Write-Host ""
                Write-Host "  Risk Scoring schedule is not configured." -ForegroundColor Yellow
                Write-Host "  This runs daily identity risk scoring using classifiers stored in SQL." -ForegroundColor Gray
                $addRiskScoring = Read-Host "  Would you like to add a daily Risk Scoring schedule? (Y/N)"

                if ($addRiskScoring -match '^[Yy]') {
                    $rsTimeInput = Read-Host "  Enter time for Risk Scoring (default: 10:30)"
                    $rsTime = if ($rsTimeInput.Trim()) { $rsTimeInput.Trim() } else { "10:30" }

                    $scheduleConfig.Enabled = $true
                    $scheduleConfig.Schedules += @{
                        RunbookName = "Invoke-FGRiskScoring"
                        ConfigKey   = "RiskScoring"
                        Time        = $rsTime
                        Frequency   = "Daily"
                    }

                    # Add or update RiskScoring section in config
                    try {
                        $rsScheduleObj = [PSCustomObject]@{ Enabled = $true; Time = $rsTime; Frequency = "Daily" }
                        if (-not $config.RiskScoring) {
                            $config | Add-Member -NotePropertyName "RiskScoring" -NotePropertyValue ([PSCustomObject]@{
                                Enabled = $true
                                Schedule = $rsScheduleObj
                            }) -Force
                        } else {
                            $config.RiskScoring | Add-Member -NotePropertyName "Schedule" -NotePropertyValue $rsScheduleObj -Force
                        }
                        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigFile -Encoding UTF8
                        Write-Host "  Risk Scoring schedule added to config (daily at $rsTime)" -ForegroundColor Green
                    } catch {
                        Write-Warning "  Failed to update config file: $_"
                    }
                }
            }
        } else {
            Write-Host "  Risk Scoring is disabled in config — skipping schedule" -ForegroundColor Gray
        }

        # Check for account correlation — respect Enabled flag
        $accountCorrelationEnabled = -not ($config.AccountCorrelation -and $config.AccountCorrelation.PSObject.Properties['Enabled'] -and $config.AccountCorrelation.Enabled -eq $false)
        if ($accountCorrelationEnabled) {
            if ($config.AccountCorrelation -and $config.AccountCorrelation.Schedule -and $config.AccountCorrelation.Schedule.Enabled -eq $true) {
                $scheduleConfig.Enabled = $true
                $acTime = if ($config.AccountCorrelation.Schedule.Time) { $config.AccountCorrelation.Schedule.Time } else { "11:00" }
                $acFreq = if ($config.AccountCorrelation.Schedule.Frequency) { $config.AccountCorrelation.Schedule.Frequency } else { "Daily" }
                $scheduleConfig.Schedules += @{
                    RunbookName = "Invoke-FGAccountCorrelation"
                    ConfigKey   = "AccountCorrelation"
                    Time        = $acTime
                    Frequency   = $acFreq
                }
            }
            elseif (-not $config.AccountCorrelation -or -not $config.AccountCorrelation.Schedule -or $config.AccountCorrelation.Schedule.Enabled -ne $true) {
                Write-Host ""
                Write-Host "  Account Correlation schedule is not configured." -ForegroundColor Yellow
                Write-Host "  This runs daily account correlation to group accounts into identities." -ForegroundColor Gray
                $addCorrelation = Read-Host "  Would you like to add a daily Account Correlation schedule? (Y/N)"

                if ($addCorrelation -match '^[Yy]') {
                    $acTimeInput = Read-Host "  Enter time for Account Correlation (default: 11:00)"
                    $acTime = if ($acTimeInput.Trim()) { $acTimeInput.Trim() } else { "11:00" }

                    $scheduleConfig.Enabled = $true
                    $scheduleConfig.Schedules += @{
                        RunbookName = "Invoke-FGAccountCorrelation"
                        ConfigKey   = "AccountCorrelation"
                        Time        = $acTime
                        Frequency   = "Daily"
                    }

                    # Add AccountCorrelation section to config
                    try {
                        $acScheduleObj = [PSCustomObject]@{ Enabled = $true; Time = $acTime; Frequency = "Daily" }
                        if (-not $config.AccountCorrelation) {
                            $config | Add-Member -NotePropertyName "AccountCorrelation" -NotePropertyValue ([PSCustomObject]@{
                                Enabled = $true
                                Schedule = $acScheduleObj
                            }) -Force
                        } else {
                            $config.AccountCorrelation | Add-Member -NotePropertyName "Schedule" -NotePropertyValue $acScheduleObj -Force
                        }
                        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigFile -Encoding UTF8
                        Write-Host "  Account Correlation schedule added to config (daily at $acTime)" -ForegroundColor Green
                    } catch {
                        Write-Warning "  Failed to update config file: $_"
                    }
                }
            }
        } else {
            Write-Host "  Account Correlation is disabled in config — skipping schedule" -ForegroundColor Gray
        }

        if (-not $syncSchedulesFound) {
            # No sync runbook schedules in config — prompt to add them
            Write-Host ""
            Write-Host "  No sync schedules configured in config file." -ForegroundColor Yellow
            Write-Host "  This covers: Users, Groups, Group Members, Access Packages, Directory Roles, etc." -ForegroundColor Gray
            $addSchedules = Read-Host "  Would you like to add daily sync schedules and save to config? (Y/N)"

            if ($addSchedules -match '^[Yy]') {
                # Ask for time
                $defaultTime = "06:00"
                $timeInput = Read-Host "  Enter time for daily sync (default: $defaultTime, format HH:mm)"
                $selectedTime = if ($timeInput.Trim() -match '^\d{2}:\d{2}$') { $timeInput.Trim() } else { $defaultTime }

                # Ask for time zone
                $defaultTz = if ($config.Sync.ScheduleTimeZone) { $config.Sync.ScheduleTimeZone } else { "W. Europe Standard Time" }
                $tzInput = Read-Host "  Enter time zone (default: $defaultTz)"
                $selectedTz = if ($tzInput.Trim()) { $tzInput.Trim() } else { $defaultTz }

                # Build schedules for all sync runbooks
                $scheduleConfig.Enabled = $true
                $scheduleConfig.TimeZone = $selectedTz

                foreach ($runbookName in $scheduleMapping.Keys) {
                    $configKey = $scheduleMapping[$runbookName]
                    $scheduleConfig.Schedules += @{
                        RunbookName = $runbookName
                        ConfigKey   = $configKey
                        Time        = $selectedTime
                        Frequency   = "Daily"
                    }
                }

                # Update the config file with schedules
                try {
                    if (-not $config.Sync.ScheduleTimeZone) {
                        $config.Sync | Add-Member -NotePropertyName "ScheduleTimeZone" -NotePropertyValue $selectedTz -Force
                    }

                    foreach ($configKey in $scheduleMapping.Values) {
                        $syncSchedule = [PSCustomObject]@{
                            Enabled   = $true
                            Time      = $selectedTime
                            Frequency = "Daily"
                        }
                        if ($config.Sync.$configKey) {
                            # Entry exists — just add/update the Schedule property
                            $config.Sync.$configKey | Add-Member -NotePropertyName "Schedule" -NotePropertyValue $syncSchedule -Force
                        }
                        else {
                            # Entry missing (e.g. v3.0 sync types not yet in config) — create minimal entry
                            $newEntry = [PSCustomObject]@{ Enabled = $true; Schedule = $syncSchedule }
                            $config.Sync | Add-Member -NotePropertyName $configKey -NotePropertyValue $newEntry -Force
                        }
                    }

                    $config | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigFile -Encoding UTF8
                    Write-Host "  Config file updated with daily sync schedules at $selectedTime ($selectedTz)" -ForegroundColor Green
                }
                catch {
                    Write-Warning "  Failed to update config file: $_"
                    Write-Host "  Schedules will still be created, but config file was not updated" -ForegroundColor Yellow
                }
            }
        }

        if ($scheduleConfig.Schedules.Count -gt 0) {
            Write-Host "  Schedule configuration: $($scheduleConfig.Schedules.Count) schedules configured" -ForegroundColor Cyan
        }

        # Validate required fields
        if (-not $SubscriptionId) { throw "SubscriptionId not provided and not found in config (Azure.SubscriptionId)" }
        if (-not $ResourceGroupName) { throw "ResourceGroupName not provided and not found in config (Azure.ResourceGroupName)" }
        if (-not $AutomationAccountName) { throw "AutomationAccountName not provided and not found in config (Azure.AutomationAccountName)" }
        if (-not $GraphTenantId) { throw "Config file missing: Graph.TenantId" }
        if (-not $GraphClientId) { throw "Config file missing: Graph.ClientId" }
        if (-not $GraphClientSecret) { throw "Config file missing: Graph.ClientSecret (or Graph.ClientSecret_Encrypted)" }
        if (-not $SQLServerName) { throw "Config file missing: Azure.SQLServerName" }
        if (-not $SQLDatabaseName) { throw "Config file missing: Azure.DatabaseName" }
        if (-not $SQLAdminUsername) { throw "Config file missing: Azure.AdminUsername" }
        if (-not $SQLAdminPassword) { throw "Config file missing: Azure.AdminUserPassword (or Azure.AdminUserPassword_Encrypted)" }

        # Default location if not specified
        if (-not $Location) { $Location = "northeurope" }

        Write-Host "  Configuration loaded successfully" -ForegroundColor Green

        # Check for missing sections compared to the current template
        $configCheck = Update-FGConfig -ConfigFile $ConfigFile -Silent
        if ($configCheck.Missing.Count -gt 0) {
            $answer = Read-Host "  Would you like to review and add the missing sections now? (Y/N)"
            if ($answer -match '^[Yy]') {
                Update-FGConfig -ConfigFile $ConfigFile
                # Reload config after updates
                $config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
            }
        }
    }
    else {
        # Explicit parameter set - validate required parameters
        if (-not $SubscriptionId) { throw "SubscriptionId is required when not using ConfigFile" }
        if (-not $ResourceGroupName) { throw "ResourceGroupName is required when not using ConfigFile" }
        if (-not $AutomationAccountName) { throw "AutomationAccountName is required when not using ConfigFile" }
        if (-not $Location) { $Location = "northeurope" }
    }

    try {
        # Confirm Azure context
        if (-not $global:FGAzureContextConfirmed) {
            $currentContext = Get-AzContext
            Write-Host "`n========================================" -ForegroundColor Yellow
            Write-Host "Current Azure Context:" -ForegroundColor Yellow
            Write-Host "========================================" -ForegroundColor Yellow
            Write-Host "Account:      $($currentContext.Account.Id)" -ForegroundColor White
            Write-Host "Subscription: $($currentContext.Subscription.Name)" -ForegroundColor White
            Write-Host "Tenant:       $($currentContext.Tenant.Id)" -ForegroundColor White
            Write-Host "========================================`n" -ForegroundColor Yellow

            $confirmation = Read-Host "Do you want to use this Azure context? (Y/N)"
            if ($confirmation -notmatch '^[Yy]') {
                Write-Host "Operation cancelled." -ForegroundColor Yellow
                return
            }
            $global:FGAzureContextConfirmed = $true
        }

        # Set subscription context
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Setting Azure subscription context..." -ForegroundColor Cyan
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

        # Check/Create Resource Group
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking resource group: $ResourceGroupName..." -ForegroundColor Cyan
        $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
        if (-not $rg) {
            Write-Host "  Creating resource group: $ResourceGroupName in $Location..." -ForegroundColor Yellow
            $rg = New-AzResourceGroup -Name $ResourceGroupName -Location $Location
            Write-Host "  Resource group created successfully" -ForegroundColor Green
        }
        else {
            Write-Host "  Resource group already exists" -ForegroundColor Green
        }

        # Check/Create Automation Account
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking Automation Account: $AutomationAccountName..." -ForegroundColor Cyan
        $automationAccount = Get-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName -ErrorAction SilentlyContinue

        if (-not $automationAccount) {
            Write-Host "  Creating Automation Account: $AutomationAccountName..." -ForegroundColor Yellow
            try {
                $automationAccount = New-AzAutomationAccount `
                    -ResourceGroupName $ResourceGroupName `
                    -Name $AutomationAccountName `
                    -Location $Location `
                    -ErrorAction Stop

                Write-Host "  Automation Account created successfully" -ForegroundColor Green
            } catch {
                Write-Host "  Failed to create Automation Account: $_" -ForegroundColor Red
                Write-Host "  Please create the Automation Account manually in the Azure Portal and try again." -ForegroundColor Yellow
                return
            }
        }
        else {
            Write-Host "  Automation Account already exists" -ForegroundColor Green
        }

        # Check/Configure SQL Server firewall for Azure Services
        Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Checking SQL Server firewall configuration..." -ForegroundColor Cyan

        # Get the SQL Server's resource group (may be different from Automation Account's RG)
        # Use case-insensitive comparison since Azure normalizes server names to lowercase
        $sqlServer = Get-AzSqlServer | Where-Object { $_.ServerName -ieq $SQLServerName } | Select-Object -First 1

        if ($sqlServer) {
            $sqlResourceGroup = $sqlServer.ResourceGroupName
            $sqlServerNameActual = $sqlServer.ServerName  # Use the actual lowercase name from Azure

            # Check if AllowAzureServices rule exists
            $azureServicesRule = Get-AzSqlServerFirewallRule `
                -ResourceGroupName $sqlResourceGroup `
                -ServerName $sqlServerNameActual `
                -ErrorAction SilentlyContinue | Where-Object {
                    $_.StartIpAddress -eq "0.0.0.0" -and $_.EndIpAddress -eq "0.0.0.0"
                }

            if ($azureServicesRule) {
                Write-Host "  SQL firewall already allows Azure services" -ForegroundColor Green
            }
            else {
                Write-Host ""
                Write-Host "  ========================================" -ForegroundColor Yellow
                Write-Host "  SQL Server Firewall Configuration Required" -ForegroundColor Yellow
                Write-Host "  ========================================" -ForegroundColor Yellow
                Write-Host "  Azure Automation runbooks need to connect to your SQL Server." -ForegroundColor White
                Write-Host "  This requires enabling 'Allow Azure services' on the SQL firewall." -ForegroundColor White
                Write-Host ""
                Write-Host "  SQL Server: $sqlServerNameActual" -ForegroundColor White
                Write-Host "  Resource Group: $sqlResourceGroup" -ForegroundColor White
                Write-Host "  ========================================" -ForegroundColor Yellow

                $firewallConfirm = Read-Host "  Add firewall rule to allow Azure services? (Y/N)"
                if ($firewallConfirm -match '^[Yy]') {
                    try {
                        New-AzSqlServerFirewallRule `
                            -ResourceGroupName $sqlResourceGroup `
                            -ServerName $sqlServerNameActual `
                            -FirewallRuleName "AllowAzureServices" `
                            -StartIpAddress "0.0.0.0" `
                            -EndIpAddress "0.0.0.0" | Out-Null

                        Write-Host "  Firewall rule added successfully" -ForegroundColor Green
                    }
                    catch {
                        Write-Warning "  Failed to add firewall rule: $_"
                        Write-Warning "  You may need to add it manually in Azure Portal"
                    }
                }
                else {
                    Write-Host "  Skipping firewall configuration" -ForegroundColor Yellow
                    Write-Host "  NOTE: Runbooks will fail to connect to SQL until this is configured" -ForegroundColor Yellow
                }
            }
        }
        else {
            Write-Warning "  Could not find SQL Server '$SQLServerName' in current subscription"
            Write-Warning "  You may need to configure the firewall manually"
        }

        # Create Variables
        Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Creating Automation Variables..." -ForegroundColor Cyan

        $variables = @(
            @{ Name = "GraphTenantId"; Value = $GraphTenantId; Encrypted = $false; Description = "Microsoft Graph Tenant ID" }
            @{ Name = "GraphClientId"; Value = $GraphClientId; Encrypted = $false; Description = "Microsoft Graph Application (Client) ID" }
            @{ Name = "GraphClientSecret"; Value = $GraphClientSecret; Encrypted = $true; Description = "Microsoft Graph Client Secret" }
            @{ Name = "SQLServerName"; Value = $SQLServerName; Encrypted = $false; Description = "Azure SQL Server name (without .database.windows.net)" }
            @{ Name = "SQLDatabaseName"; Value = $SQLDatabaseName; Encrypted = $false; Description = "Azure SQL Database name" }
            @{ Name = "SQLAdminUsername"; Value = $SQLAdminUsername; Encrypted = $false; Description = "SQL Server admin username" }
            @{ Name = "SQLAdminPassword"; Value = $SQLAdminPassword; Encrypted = $true; Description = "SQL Server admin password" }
        )

        # Add sync configuration variables if config file was used
        if ($PSCmdlet.ParameterSetName -eq 'ConfigFile') {
            # Store additional attributes as comma-separated strings
            $usersAdditionalAttributesString = if ($syncConfig.UsersAdditionalAttributes.Count -gt 0) {
                $syncConfig.UsersAdditionalAttributes -join ","
            } else { "" }

            $groupsAdditionalAttributesString = if ($syncConfig.GroupsAdditionalAttributes.Count -gt 0) {
                $syncConfig.GroupsAdditionalAttributes -join ","
            } else { "" }

            $variables += @(
                @{ Name = "SyncUsersAdditionalAttributes"; Value = $usersAdditionalAttributesString; Encrypted = $false; Description = "Additional user attributes to sync (comma-separated)" }
                @{ Name = "SyncUsersFilter"; Value = $syncConfig.UsersFilter; Encrypted = $false; Description = "OData filter for user sync" }
                @{ Name = "SyncGroupsAdditionalAttributes"; Value = $groupsAdditionalAttributesString; Encrypted = $false; Description = "Additional group attributes to sync (comma-separated)" }
                @{ Name = "SyncGroupsFilter"; Value = $syncConfig.GroupsFilter; Encrypted = $false; Description = "OData filter for group sync" }
            )

        }

        foreach ($var in $variables) {
            $existingVar = Get-AzAutomationVariable -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $var.Name -ErrorAction SilentlyContinue

            if ($existingVar) {
                Write-Host "  Updating variable: $($var.Name)..." -ForegroundColor Yellow
                Set-AzAutomationVariable `
                    -ResourceGroupName $ResourceGroupName `
                    -AutomationAccountName $AutomationAccountName `
                    -Name $var.Name `
                    -Value $var.Value `
                    -Encrypted $var.Encrypted | Out-Null
            }
            else {
                Write-Host "  Creating variable: $($var.Name)..." -ForegroundColor Cyan
                New-AzAutomationVariable `
                    -ResourceGroupName $ResourceGroupName `
                    -AutomationAccountName $AutomationAccountName `
                    -Name $var.Name `
                    -Value $var.Value `
                    -Encrypted $var.Encrypted `
                    -Description $var.Description | Out-Null
            }

            $encryptedStatus = if ($var.Encrypted) { "(encrypted)" } else { "" }
            Write-Host "    $($var.Name) $encryptedStatus" -ForegroundColor Green
        }

        # Import Modules
        if (-not $SkipModuleImport) {
            Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Importing PowerShell modules..." -ForegroundColor Cyan
            Write-Host "  Note: Module imports can take several minutes to complete" -ForegroundColor Gray

            $modules = @(
                @{ Name = "Az.Accounts"; ContentLink = "https://www.powershellgallery.com/api/v2/package/Az.Accounts" }
                @{ Name = "Az.Sql"; ContentLink = "https://www.powershellgallery.com/api/v2/package/Az.Sql" }
            )

            foreach ($module in $modules) {
                $existingModule = Get-AzAutomationModule -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $module.Name -ErrorAction SilentlyContinue

                if ($existingModule -and $existingModule.ProvisioningState -eq "Succeeded") {
                    Write-Host "  Module already imported: $($module.Name)" -ForegroundColor Green
                }
                else {
                    Write-Host "  Importing module: $($module.Name)..." -ForegroundColor Yellow
                    try {
                        New-AzAutomationModule `
                            -ResourceGroupName $ResourceGroupName `
                            -AutomationAccountName $AutomationAccountName `
                            -Name $module.Name `
                            -ContentLink $module.ContentLink | Out-Null

                        Write-Host "    Module import started (may take a few minutes to complete)" -ForegroundColor Cyan
                    }
                    catch {
                        Write-Warning "    Failed to import module $($module.Name): $_"
                    }
                }
            }

            # Handle FortigiGraph module (upload by default unless -SkipModuleUpload)
            if (-not $SkipModuleUpload) {
                Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Checking FortigiGraph module..." -ForegroundColor Cyan

                # Determine module path - try auto-detection first
                if (-not $ModulePath) {
                    # Try to detect from loaded module
                    $loadedModule = Get-Module -Name FortigiGraph -ErrorAction SilentlyContinue
                    if ($loadedModule) {
                        $ModulePath = Split-Path -Parent $loadedModule.Path
                        Write-Host "  Auto-detected module path from loaded module" -ForegroundColor Gray
                    }
                    else {
                        # Fall back to parent folder of Automation folder (where this script is)
                        $scriptPath = $PSScriptRoot
                        if ($scriptPath) {
                            $ModulePath = Split-Path -Parent $scriptPath
                        }
                        else {
                            $ModulePath = Split-Path -Parent (Get-Location)
                        }
                        Write-Host "  Using script location for module path" -ForegroundColor Gray
                    }
                }

                # Verify module exists
                $psdPath = Join-Path $ModulePath "FortigiGraph.psd1"
                if (-not (Test-Path $psdPath)) {
                    Write-Warning "  FortigiGraph.psd1 not found at: $ModulePath"
                    Write-Warning "  Please specify -ModulePath or import the module manually"
                    Write-Host "  Use -SkipModuleUpload to skip module upload" -ForegroundColor Gray
                }
                else {
                    # Get local module version
                    $localManifest = Import-PowerShellDataFile -Path $psdPath
                    $localVersion = [Version]$localManifest.ModuleVersion
                    Write-Host "  Local module version: $localVersion" -ForegroundColor Cyan

                    # Check if FortigiGraph module already exists in Automation Account
                    $existingFGModule = Get-AzAutomationModule `
                        -ResourceGroupName $ResourceGroupName `
                        -AutomationAccountName $AutomationAccountName `
                        -Name "FortigiGraph" `
                        -RuntimeVersion "7.2" `
                        -ErrorAction SilentlyContinue

                    $shouldUpload = $true
                    if ($existingFGModule -and $existingFGModule.ProvisioningState -eq "Succeeded") {
                        $deployedVersion = [Version]$existingFGModule.Version
                        Write-Host "  Deployed module version: $deployedVersion" -ForegroundColor Cyan

                        if ($localVersion -le $deployedVersion) {
                            Write-Host "  Module is up to date (deployed: $deployedVersion >= local: $localVersion)" -ForegroundColor Green
                            $shouldUpload = $false
                        }
                        else {
                            Write-Host "  Newer version available (local: $localVersion > deployed: $deployedVersion)" -ForegroundColor Yellow
                        }
                    }
                    elseif ($existingFGModule) {
                        Write-Host "  Existing module state: $($existingFGModule.ProvisioningState)" -ForegroundColor Yellow
                    }
                    else {
                        Write-Host "  No existing FortigiGraph module found in Automation Account" -ForegroundColor Yellow
                    }

                    if ($shouldUpload) {
                        Write-Host "  Uploading FortigiGraph module..." -ForegroundColor Cyan

                        try {
                            # Create temp ZIP file
                            $tempZipPath = Join-Path ([System.IO.Path]::GetTempPath()) "FortigiGraph_$(Get-Date -Format 'yyyyMMddHHmmss').zip"

                            Write-Host "  Module path: $ModulePath" -ForegroundColor Gray
                            Write-Host "  Creating ZIP archive..." -ForegroundColor Gray

                            # Get all module files (exclude _Test, _Build, .git, etc.)
                            $filesToInclude = Get-ChildItem -Path $ModulePath -Recurse -File | Where-Object {
                                $_.FullName -notmatch '[\\/](_Test|_Build|\.git|\.vscode|Config)[\\/]' -and
                                $_.Name -notmatch '^\.' -and
                                $_.Extension -in @('.ps1', '.psm1', '.psd1', '.ps1xml', '.dll', '.txt', '.md')
                            }

                            # Create a temp folder with proper module structure
                            $tempModuleFolder = Join-Path ([System.IO.Path]::GetTempPath()) "FortigiGraph"
                            if (Test-Path $tempModuleFolder) {
                                Remove-Item -Path $tempModuleFolder -Recurse -Force
                            }
                            New-Item -Path $tempModuleFolder -ItemType Directory -Force | Out-Null

                            # Copy files maintaining relative structure
                            foreach ($file in $filesToInclude) {
                                $relativePath = $file.FullName.Substring($ModulePath.Length).TrimStart('\', '/')
                                $destPath = Join-Path $tempModuleFolder $relativePath
                                $destFolder = Split-Path -Parent $destPath
                                if (-not (Test-Path $destFolder)) {
                                    New-Item -Path $destFolder -ItemType Directory -Force | Out-Null
                                }
                                Copy-Item -Path $file.FullName -Destination $destPath -Force
                            }

                            # Create ZIP
                            if (Test-Path $tempZipPath) {
                                Remove-Item -Path $tempZipPath -Force
                            }
                            Compress-Archive -Path $tempModuleFolder -DestinationPath $tempZipPath -Force

                            Write-Host "  ZIP created: $([math]::Round((Get-Item $tempZipPath).Length / 1KB, 1)) KB" -ForegroundColor Gray

                            # For PowerShell 7.2 runtime, we need to upload via blob storage
                            if ($RunbookType -eq "PowerShell72") {
                                # Create a temporary storage account for module upload
                                $storageAccountName = "fgtemp$((Get-Date).Ticks % 10000000000)"
                                $storageAccountName = $storageAccountName.Substring(0, [Math]::Min(24, $storageAccountName.Length)).ToLower()

                                Write-Host "  Creating temporary storage account for upload..." -ForegroundColor Gray

                                try {
                                    # Create storage account
                                    $storageAccount = New-AzStorageAccount `
                                        -ResourceGroupName $ResourceGroupName `
                                        -Name $storageAccountName `
                                        -Location $Location `
                                        -SkuName Standard_LRS `
                                        -Kind StorageV2 `
                                        -AllowBlobPublicAccess $true `
                                        -ErrorAction Stop

                                    $storageContext = $storageAccount.Context

                                    # Create container
                                    $containerName = "modules"
                                    New-AzStorageContainer -Name $containerName -Context $storageContext -Permission Blob -ErrorAction SilentlyContinue | Out-Null

                                    # Upload ZIP
                                    $blobName = "FortigiGraph.zip"
                                    Set-AzStorageBlobContent -File $tempZipPath -Container $containerName -Blob $blobName -Context $storageContext -Force | Out-Null

                                    # Get blob URL
                                    $blobUrl = "https://$storageAccountName.blob.core.windows.net/$containerName/$blobName"

                                    Write-Host "  Blob URL: $blobUrl" -ForegroundColor Gray

                                    # Import new module (will replace existing if present)
                                    New-AzAutomationModule `
                                        -ResourceGroupName $ResourceGroupName `
                                        -AutomationAccountName $AutomationAccountName `
                                        -Name "FortigiGraph" `
                                        -ContentLinkUri $blobUrl `
                                        -RuntimeVersion "7.2" | Out-Null

                                    Write-Host "  FortigiGraph module v$localVersion import started (PowerShell 7.2)" -ForegroundColor Green

                                    # Wait for module import to complete before deleting storage
                                    Write-Host "  Waiting for module import to complete..." -ForegroundColor Gray
                                    $maxWaitSeconds = 180  # 3 minutes max
                                    $waitedSeconds = 0
                                    $importComplete = $false

                                    while (-not $importComplete -and $waitedSeconds -lt $maxWaitSeconds) {
                                        Start-Sleep -Seconds 10
                                        $waitedSeconds += 10

                                        $moduleStatus = Get-AzAutomationModule `
                                            -ResourceGroupName $ResourceGroupName `
                                            -AutomationAccountName $AutomationAccountName `
                                            -Name "FortigiGraph" `
                                            -RuntimeVersion "7.2" `
                                            -ErrorAction SilentlyContinue

                                        if ($moduleStatus) {
                                            $state = $moduleStatus.ProvisioningState
                                            Write-Host "    Module state: $state ($waitedSeconds s)" -ForegroundColor Gray

                                            if ($state -eq "Succeeded") {
                                                $importComplete = $true
                                                Write-Host "  Module import completed successfully!" -ForegroundColor Green
                                            }
                                            elseif ($state -eq "Failed") {
                                                Write-Warning "  Module import failed!"
                                                break
                                            }
                                            # Continue waiting for Creating/ContentValidated states
                                        }
                                    }

                                    if (-not $importComplete -and $waitedSeconds -ge $maxWaitSeconds) {
                                        Write-Host "  Module import still in progress after $maxWaitSeconds seconds" -ForegroundColor Yellow
                                        Write-Host "  Storage account will be kept - please delete manually after import completes:" -ForegroundColor Yellow
                                        Write-Host "    Storage Account: $storageAccountName" -ForegroundColor Gray
                                    }
                                    else {
                                        # Clean up storage account
                                        Write-Host "  Cleaning up temporary storage account..." -ForegroundColor Gray
                                        $null = Remove-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $storageAccountName -Force -ErrorAction SilentlyContinue *>&1
                                    }
                                }
                                catch {
                                    Write-Warning "  Failed to upload module via storage account: $_"
                                    Write-Host "  Falling back to PowerShell Gallery import..." -ForegroundColor Yellow

                                    # Try importing from gallery as fallback
                                    try {
                                        New-AzAutomationModule `
                                            -ResourceGroupName $ResourceGroupName `
                                            -AutomationAccountName $AutomationAccountName `
                                            -Name "FortigiGraph" `
                                            -ContentLinkUri "https://www.powershellgallery.com/api/v2/package/FortigiGraph" `
                                            -RuntimeVersion "7.2" -ErrorAction SilentlyContinue | Out-Null
                                        Write-Host "  FortigiGraph imported from PowerShell Gallery (may be older version)" -ForegroundColor Yellow
                                    }
                                    catch {
                                        Write-Warning "  Could not import from gallery either. Please import manually."
                                    }
                                }
                            }
                            else {
                                # PowerShell 5.1 - simpler approach
                                Write-Warning "  Local module upload not yet supported for PowerShell 5.1 runtime"
                                Write-Host "  Please import FortigiGraph manually from PowerShell Gallery" -ForegroundColor Yellow
                            }

                            # Cleanup temp files
                            Remove-Item -Path $tempZipPath -Force -ErrorAction SilentlyContinue
                            Remove-Item -Path $tempModuleFolder -Recurse -Force -ErrorAction SilentlyContinue
                        }
                        catch {
                            Write-Warning "  Failed to upload local module: $_"
                            Write-Host "  Please import FortigiGraph manually" -ForegroundColor Yellow
                        }
                    }
                }
            }
            else {
                Write-Host "`n  Skipping FortigiGraph module upload (-SkipModuleUpload)" -ForegroundColor Yellow
                Write-Host "  Import manually from PowerShell Gallery if needed" -ForegroundColor Gray
            }
        }

        # Create Runbooks (by default, unless -SkipRunbooks is specified)
        if (-not $SkipRunbooks) {
            Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Creating runbooks..." -ForegroundColor Cyan

            $runbooks = @(
                # User & Group sync
                @{
                    Name = "Sync-FGUsers"
                    Description = "Syncs Microsoft Graph users to Azure SQL"
                    SyncFunction = "Sync-FGUser"
                    HasSyncConfig = $true
                }
                @{
                    Name = "Sync-FGGroups"
                    Description = "Syncs Microsoft Graph groups to Azure SQL"
                    SyncFunction = "Sync-FGGroup"
                    HasGroupSyncConfig = $true
                }
                # Group membership sync
                @{
                    Name = "Sync-FGGroupMembers"
                    Description = "Syncs Microsoft Graph group memberships to Azure SQL"
                    SyncFunction = "Sync-FGGroupMember"
                    ExtraParams = "-UseBatching"
                }
                @{
                    Name = "Sync-FGGroupEligibleMembers"
                    Description = "Syncs Microsoft Graph PIM eligible group memberships to Azure SQL"
                    SyncFunction = "Sync-FGGroupEligibleMember"
                }
                @{
                    Name = "Sync-FGGroupOwners"
                    Description = "Syncs Microsoft Graph group owners to Azure SQL"
                    SyncFunction = "Sync-FGGroupOwner"
                }
                # Access package sync
                @{
                    Name = "Sync-FGCatalogs"
                    Description = "Syncs access package catalogs to Azure SQL"
                    SyncFunction = "Sync-FGCatalog"
                }
                @{
                    Name = "Sync-FGAccessPackages"
                    Description = "Syncs access packages to Azure SQL"
                    SyncFunction = "Sync-FGAccessPackage"
                }
                @{
                    Name = "Sync-FGAccessPackageAssignments"
                    Description = "Syncs access package assignments to Azure SQL"
                    SyncFunction = "Sync-FGAccessPackageAssignment"
                    ExtraParams = "-UseBatching"
                }
                @{
                    Name = "Sync-FGAccessPackageResourceRoleScopes"
                    Description = "Syncs access package resource role scopes to Azure SQL"
                    SyncFunction = "Sync-FGAccessPackageResourceRoleScope"
                }
                @{
                    Name = "Sync-FGAccessPackageAssignmentPolicies"
                    Description = "Syncs access package assignment policies to Azure SQL"
                    SyncFunction = "Sync-FGAccessPackageAssignmentPolicy"
                }
                @{
                    Name = "Sync-FGAccessPackageAssignmentRequests"
                    Description = "Syncs access package assignment requests to Azure SQL"
                    SyncFunction = "Sync-FGAccessPackageAssignmentRequest"
                    ExtraParams = "-UseBatching"
                }
                @{
                    Name = "Sync-FGAccessPackageAccessReviews"
                    Description = "Syncs access package access review decisions to Azure SQL"
                    SyncFunction = "Sync-FGAccessPackageAccessReview"
                }
                # Resource model sync
                @{
                    Name = "Sync-FGEntraDirectoryRoles"
                    Description = "Syncs Entra ID directory roles and members to Resources/ResourceAssignments tables"
                    SyncFunction = "Sync-FGEntraDirectoryRole"
                }
                @{
                    Name = "Sync-FGEntraAppRoleAssignments"
                    Description = "Syncs Entra ID application role assignments to Resources/ResourceAssignments tables"
                    SyncFunction = "Sync-FGEntraAppRoleAssignment"
                }
                @{
                    Name = "Sync-FGResourceRelationships"
                    Description = "Discovers and syncs resource-to-resource relationships"
                    SyncFunction = "Sync-FGResourceRelationship"
                }
                @{
                    Name = "Sync-FGPrincipals"
                    Description = "Syncs Microsoft Graph users to the Principals table"
                    SyncFunction = "Sync-FGPrincipal"
                    HasSyncConfig = $true
                }
                @{
                    Name = "Sync-FGOrgUnits"
                    Description = "Calculates and syncs organizational units from department data"
                    SyncFunction = "Sync-FGOrgUnit"
                }
                # Post-sync: Materialize views for UI performance
                @{
                    Name = "Sync-FGMaterializedViews"
                    Description = "Refreshes materialized views and indexes for UI performance"
                    SqlOnly = $true
                }
                # Post-sync: Risk scoring (after materialized views)
                @{
                    Name = "Invoke-FGRiskScoring"
                    Description = "Runs identity risk scoring engine against synced data"
                    RiskScoring = $true
                }
                # Post-scoring: Account correlation (after risk scoring)
                @{
                    Name = "Invoke-FGAccountCorrelation"
                    Description = "Correlates user accounts to identify multiple accounts belonging to the same person"
                    AccountCorrelation = $true
                }
            )

            foreach ($runbook in $runbooks) {
                Write-Host "  Creating runbook: $($runbook.Name)..." -ForegroundColor Cyan

                # Build the sync command based on runbook type
                if ($runbook.HasSyncConfig) {
                    # Users runbook - includes additional attributes and filter
                    $syncCommand = @'
# Get sync configuration
$additionalAttributesRaw = Get-AutomationVariable -Name 'SyncUsersAdditionalAttributes' -ErrorAction SilentlyContinue
$userFilter = Get-AutomationVariable -Name 'SyncUsersFilter' -ErrorAction SilentlyContinue

# Build sync parameters
$syncParams = @{}
if ($additionalAttributesRaw -and $additionalAttributesRaw.Trim() -ne "") {
    $additionalAttributes = $additionalAttributesRaw -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    if ($additionalAttributes.Count -gt 0) {
        $syncParams.AdditionalAttributes = $additionalAttributes
        Write-Output "  Additional attributes: $($additionalAttributes -join ', ')"
    }
}
if ($userFilter -and $userFilter.Trim() -ne "") {
    $syncParams.Filter = $userFilter
    Write-Output "  Filter: $userFilter"
}

# Run sync
Write-Output "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Running Sync-FGUser..."
Sync-FGUser @syncParams
'@
                }
                elseif ($runbook.HasGroupSyncConfig) {
                    # Groups runbook - includes additional attributes and filter
                    $syncCommand = @'
# Get sync configuration
$additionalAttributesRaw = Get-AutomationVariable -Name 'SyncGroupsAdditionalAttributes' -ErrorAction SilentlyContinue
$groupFilter = Get-AutomationVariable -Name 'SyncGroupsFilter' -ErrorAction SilentlyContinue

# Build sync parameters
$syncParams = @{}
if ($additionalAttributesRaw -and $additionalAttributesRaw.Trim() -ne "") {
    $additionalAttributes = $additionalAttributesRaw -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    if ($additionalAttributes.Count -gt 0) {
        $syncParams.AdditionalAttributes = $additionalAttributes
        Write-Output "  Additional attributes: $($additionalAttributes -join ', ')"
    }
}
if ($groupFilter -and $groupFilter.Trim() -ne "") {
    $syncParams.Filter = $groupFilter
    Write-Output "  Filter: $groupFilter"
}

# Run sync
Write-Output "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Running Sync-FGGroup..."
Sync-FGGroup @syncParams
'@
                }
                else {
                    # Standard runbook
                    $extraParams = if ($runbook.ExtraParams) { " $($runbook.ExtraParams)" } else { "" }
                    $syncCommand = @"
# Run sync
Write-Output "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Running $($runbook.SyncFunction)..."
$($runbook.SyncFunction)$extraParams
"@
                }

                if ($runbook.RiskScoring) {
                    # Risk scoring runbook (SQL-only, reads classifiers from variable or SQL)
                    $runbookContent = @"
<#
.SYNOPSIS
$($runbook.Description)

.DESCRIPTION
This runbook is automatically generated by New-FGAzureAutomationAccount.
It reads SQL credentials and classifier data from Automation Variables,
then runs the identity risk scoring engine against already-synced data.

Schedule this runbook AFTER Sync-FGMaterializedViews has completed.

.NOTES
Requires FortigiGraph module to be imported into the Automation Account.
No Graph API credentials needed - scoring reads from SQL only.
#>

# Get SQL credentials
Write-Output "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Starting $($runbook.Name)..."

`$sqlServerName = Get-AutomationVariable -Name 'SQLServerName'
`$sqlDatabaseName = Get-AutomationVariable -Name 'SQLDatabaseName'
`$sqlUsername = Get-AutomationVariable -Name 'SQLAdminUsername'
`$sqlPassword = Get-AutomationVariable -Name 'SQLAdminPassword'

Write-Output "  SQL Server: `$sqlServerName"

# Import FortigiGraph module
Write-Output "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Importing FortigiGraph module..."
Import-Module FortigiGraph -ErrorAction Stop

# Connect to SQL Server
Write-Output "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Connecting to Azure SQL..."
`$connectionString = "Server=tcp:`$sqlServerName.database.windows.net,1433;Initial Catalog=`$sqlDatabaseName;User ID=`$sqlUsername;Password=`$sqlPassword;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
`$Global:FGSQLConnectionString = `$connectionString
`$Global:FGSQLServerName = `$sqlServerName
`$Global:FGSQLDatabaseName = `$sqlDatabaseName

# Run risk scoring (classifiers loaded from SQL by Invoke-FGRiskScoring)
Write-Output "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Running Invoke-FGRiskScoring..."
Invoke-FGRiskScoring

Write-Output "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $($runbook.Name) completed successfully"
"@
                }
                elseif ($runbook.AccountCorrelation) {
                    # Account correlation runbook (SQL-only, reads ruleset from SQL)
                    $runbookContent = @"
<#
.SYNOPSIS
$($runbook.Description)

.DESCRIPTION
This runbook is automatically generated by New-FGAzureAutomationAccount.
It reads SQL credentials from Automation Variables, then runs the account
correlation engine against already-synced user data.

Schedule this runbook AFTER Invoke-FGRiskScoring has completed.

.NOTES
Requires FortigiGraph module to be imported into the Automation Account.
No Graph API credentials needed - correlation reads from SQL only.
#>

# Get SQL credentials
Write-Output "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Starting $($runbook.Name)..."

`$sqlServerName = Get-AutomationVariable -Name 'SQLServerName'
`$sqlDatabaseName = Get-AutomationVariable -Name 'SQLDatabaseName'
`$sqlUsername = Get-AutomationVariable -Name 'SQLAdminUsername'
`$sqlPassword = Get-AutomationVariable -Name 'SQLAdminPassword'

Write-Output "  SQL Server: `$sqlServerName"

# Import FortigiGraph module
Write-Output "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Importing FortigiGraph module..."
Import-Module FortigiGraph -ErrorAction Stop

# Connect to SQL Server
Write-Output "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Connecting to Azure SQL..."
`$connectionString = "Server=tcp:`$sqlServerName.database.windows.net,1433;Initial Catalog=`$sqlDatabaseName;User ID=`$sqlUsername;Password=`$sqlPassword;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
`$Global:FGSQLConnectionString = `$connectionString
`$Global:FGSQLServerName = `$sqlServerName
`$Global:FGSQLDatabaseName = `$sqlDatabaseName

# Run account correlation (ruleset loaded from SQL by Invoke-FGAccountCorrelation)
Write-Output "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Running Invoke-FGAccountCorrelation..."
Invoke-FGAccountCorrelation

Write-Output "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $($runbook.Name) completed successfully"
"@
                }
                elseif ($runbook.SqlOnly) {
                    # SQL-only runbook (no Graph API authentication needed)
                    $runbookContent = @"
<#
.SYNOPSIS
$($runbook.Description)

.DESCRIPTION
This runbook is automatically generated by New-FGAzureAutomationAccount.
It reads SQL credentials from Automation Variables, recreates analysis views,
and materializes them into indexed tables for fast UI queries.

Schedule this runbook AFTER all data sync runbooks have completed.

.NOTES
Requires FortigiGraph module to be imported into the Automation Account.
#>

# Get SQL credentials (no Graph API needed for this runbook)
Write-Output "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Starting $($runbook.Name)..."

`$sqlServerName = Get-AutomationVariable -Name 'SQLServerName'
`$sqlDatabaseName = Get-AutomationVariable -Name 'SQLDatabaseName'
`$sqlUsername = Get-AutomationVariable -Name 'SQLAdminUsername'
`$sqlPassword = Get-AutomationVariable -Name 'SQLAdminPassword'

Write-Output "  SQL Server: `$sqlServerName"

# Import FortigiGraph module
Write-Output "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Importing FortigiGraph module..."
Import-Module FortigiGraph -ErrorAction Stop

# Connect to SQL Server
Write-Output "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Connecting to Azure SQL..."
`$connectionString = "Server=tcp:`$sqlServerName.database.windows.net,1433;Initial Catalog=`$sqlDatabaseName;User ID=`$sqlUsername;Password=`$sqlPassword;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
`$Global:FGSQLConnectionString = `$connectionString
`$Global:FGSQLServerName = `$sqlServerName
`$Global:FGSQLDatabaseName = `$sqlDatabaseName

# Recreate analysis views (ensures they reflect latest schema)
Write-Output "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Recreating group membership views..."
Initialize-FGGroupMembershipViews -DropIfExists

Write-Output "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Recreating resource model views..."
Initialize-FGResourceViews

Write-Output "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Creating resource model indexes..."
Initialize-FGResourceIndexes

Write-Output "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Recreating access package views..."
Initialize-FGAccessPackageViews -DropIfExists

# Materialize views into indexed tables for UI performance
Write-Output "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Materializing views..."
Sync-FGMaterializedViews

Write-Output "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $($runbook.Name) completed successfully"
"@
                }
                else {
                    $runbookContent = @"
<#
.SYNOPSIS
$($runbook.Description)

.DESCRIPTION
This runbook is automatically generated by New-FGAzureAutomationAccount.
It reads credentials from Automation Variables and syncs data to Azure SQL.

.NOTES
Requires FortigiGraph module to be imported into the Automation Account.
#>

# Get credentials from Automation Variables
Write-Output "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Starting $($runbook.Name)..."

`$graphTenantId = Get-AutomationVariable -Name 'GraphTenantId'
`$graphClientId = Get-AutomationVariable -Name 'GraphClientId'
`$graphClientSecret = Get-AutomationVariable -Name 'GraphClientSecret'
`$sqlServerName = Get-AutomationVariable -Name 'SQLServerName'
`$sqlDatabaseName = Get-AutomationVariable -Name 'SQLDatabaseName'
`$sqlUsername = Get-AutomationVariable -Name 'SQLAdminUsername'
`$sqlPassword = Get-AutomationVariable -Name 'SQLAdminPassword'

Write-Output "  Graph Tenant: `$graphTenantId"
Write-Output "  SQL Server: `$sqlServerName"

# Import FortigiGraph module
Write-Output "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Importing FortigiGraph module..."
Import-Module FortigiGraph -ErrorAction Stop

# Authenticate to Microsoft Graph
Write-Output "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Authenticating to Microsoft Graph..."
Get-FGAccessToken -TenantId `$graphTenantId -ClientId `$graphClientId -ClientSecret `$graphClientSecret

# Connect to SQL Server
Write-Output "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Connecting to Azure SQL..."
`$connectionString = "Server=tcp:`$sqlServerName.database.windows.net,1433;Initial Catalog=`$sqlDatabaseName;User ID=`$sqlUsername;Password=`$sqlPassword;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
`$Global:FGSQLConnectionString = `$connectionString
`$Global:FGSQLServerName = `$sqlServerName
`$Global:FGSQLDatabaseName = `$sqlDatabaseName

$syncCommand

Write-Output "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $($runbook.Name) completed successfully"
"@
                }

                # Create a temp file for the runbook content
                $tempFile = [System.IO.Path]::GetTempFileName()
                $tempFile = [System.IO.Path]::ChangeExtension($tempFile, ".ps1")
                $runbookContent | Out-File -FilePath $tempFile -Encoding UTF8

                try {
                    # Check if runbook exists
                    $existingRunbook = Get-AzAutomationRunbook `
                        -ResourceGroupName $ResourceGroupName `
                        -AutomationAccountName $AutomationAccountName `
                        -Name $runbook.Name `
                        -ErrorAction SilentlyContinue

                    if ($existingRunbook) {
                        Write-Host "    Updating existing runbook..." -ForegroundColor Yellow
                    }

                    # Import runbook (PowerShell72 = PowerShell 7.2, PowerShell = 5.1)
                    Import-AzAutomationRunbook `
                        -ResourceGroupName $ResourceGroupName `
                        -AutomationAccountName $AutomationAccountName `
                        -Name $runbook.Name `
                        -Path $tempFile `
                        -Type $RunbookType `
                        -Description $runbook.Description `
                        -Force | Out-Null

                    # Publish runbook
                    Publish-AzAutomationRunbook `
                        -ResourceGroupName $ResourceGroupName `
                        -AutomationAccountName $AutomationAccountName `
                        -Name $runbook.Name | Out-Null

                    Write-Host "    Runbook created and published" -ForegroundColor Green
                }
                catch {
                    Write-Warning "    Failed to create runbook $($runbook.Name): $_"
                }
                finally {
                    # Cleanup temp file
                    Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
                }
            }
        }

        # Create Schedules
        # Schedules are created if: (1) -CreateSchedules switch is used, OR (2) config file has Schedules.Enabled = true
        $shouldCreateSchedules = $CreateSchedules -or ($PSCmdlet.ParameterSetName -eq 'ConfigFile' -and $scheduleConfig.Enabled)

        # Default feature flags to enabled when not using ConfigFile (no Enabled flag to check)
        if (-not (Get-Variable -Name riskScoringEnabled -Scope Local -ErrorAction SilentlyContinue)) { $riskScoringEnabled = $true }
        if (-not (Get-Variable -Name accountCorrelationEnabled -Scope Local -ErrorAction SilentlyContinue)) { $accountCorrelationEnabled = $true }

        if ($shouldCreateSchedules -and -not $SkipRunbooks) {
            Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Checking existing schedules..." -ForegroundColor Cyan

            # Get all existing schedules in the Automation Account
            $existingSchedules = Get-AzAutomationSchedule `
                -ResourceGroupName $ResourceGroupName `
                -AutomationAccountName $AutomationAccountName `
                -ErrorAction SilentlyContinue

            # Get all existing schedule-runbook links
            $existingLinks = @()
            foreach ($rb in $runbooks) {
                $links = Get-AzAutomationScheduledRunbook `
                    -ResourceGroupName $ResourceGroupName `
                    -AutomationAccountName $AutomationAccountName `
                    -RunbookName $rb.Name `
                    -ErrorAction SilentlyContinue
                if ($links) {
                    $existingLinks += $links
                }
            }

            if ($existingSchedules -and $existingSchedules.Count -gt 0) {
                Write-Host "  Found $($existingSchedules.Count) existing schedule(s) in Automation Account" -ForegroundColor Cyan
            }

            # Determine schedule source: config file or defaults
            if ($PSCmdlet.ParameterSetName -eq 'ConfigFile' -and $scheduleConfig.Schedules.Count -gt 0) {
                Write-Host "  Using schedule configuration from config file" -ForegroundColor Cyan
                Write-Host "  Time zone: $($scheduleConfig.TimeZone)" -ForegroundColor Gray

                $schedulesToCreate = @()
                foreach ($sched in $scheduleConfig.Schedules) {
                    # Parse time string (e.g., "06:00" or "06:15")
                    $timeParts = $sched.Time -split ':'
                    $hour = [int]$timeParts[0]
                    $minute = if ($timeParts.Count -gt 1) { [int]$timeParts[1] } else { 0 }

                    # Build schedule name based on frequency
                    $freqPrefix = if ($sched.Frequency -eq "Hourly") { "Hourly" } else { "Daily" }
                    $scheduleName = "$freqPrefix-$($sched.ConfigKey)-$($hour.ToString('00'))$($minute.ToString('00'))"

                    $schedulesToCreate += @{
                        RunbookName = $sched.RunbookName
                        ScheduleName = $scheduleName
                        Hour = $hour
                        Minute = $minute
                        Frequency = $sched.Frequency
                        TimeZone = $scheduleConfig.TimeZone
                    }
                }
            }
            else {
                Write-Host "  Using default schedule configuration" -ForegroundColor Cyan
                Write-Host "  Note: Schedules start tomorrow at the specified times (UTC)" -ForegroundColor Gray

                $schedulesToCreate = @(
                    # User & Group sync
                    @{ RunbookName = "Sync-FGUsers"; ScheduleName = "Daily-Users-0600"; Hour = 6; Minute = 0; Frequency = "Daily"; TimeZone = "UTC" }
                    @{ RunbookName = "Sync-FGGroups"; ScheduleName = "Daily-Groups-0600"; Hour = 6; Minute = 0; Frequency = "Daily"; TimeZone = "UTC" }
                    # Group membership sync
                    @{ RunbookName = "Sync-FGGroupMembers"; ScheduleName = "Daily-GroupMembers-0700"; Hour = 7; Minute = 0; Frequency = "Daily"; TimeZone = "UTC" }
                    @{ RunbookName = "Sync-FGGroupEligibleMembers"; ScheduleName = "Daily-GroupEligibleMembers-0800"; Hour = 8; Minute = 0; Frequency = "Daily"; TimeZone = "UTC" }
                    @{ RunbookName = "Sync-FGGroupOwners"; ScheduleName = "Daily-GroupOwners-0630"; Hour = 6; Minute = 30; Frequency = "Daily"; TimeZone = "UTC" }
                    # Access package sync
                    @{ RunbookName = "Sync-FGCatalogs"; ScheduleName = "Daily-Catalogs-0600"; Hour = 6; Minute = 0; Frequency = "Daily"; TimeZone = "UTC" }
                    @{ RunbookName = "Sync-FGAccessPackages"; ScheduleName = "Daily-AccessPackages-0615"; Hour = 6; Minute = 15; Frequency = "Daily"; TimeZone = "UTC" }
                    @{ RunbookName = "Sync-FGAccessPackageAssignments"; ScheduleName = "Daily-AccessPackageAssignments-0830"; Hour = 8; Minute = 30; Frequency = "Daily"; TimeZone = "UTC" }
                    @{ RunbookName = "Sync-FGAccessPackageResourceRoleScopes"; ScheduleName = "Daily-AccessPackageResourceRoleScopes-0630"; Hour = 6; Minute = 30; Frequency = "Daily"; TimeZone = "UTC" }
                    @{ RunbookName = "Sync-FGAccessPackageAssignmentPolicies"; ScheduleName = "Daily-AccessPackageAssignmentPolicies-0645"; Hour = 6; Minute = 45; Frequency = "Daily"; TimeZone = "UTC" }
                    @{ RunbookName = "Sync-FGAccessPackageAssignmentRequests"; ScheduleName = "Daily-AccessPackageAssignmentRequests-0900"; Hour = 9; Minute = 0; Frequency = "Daily"; TimeZone = "UTC" }
                    @{ RunbookName = "Sync-FGAccessPackageAccessReviews"; ScheduleName = "Daily-AccessPackageAccessReviews-0930"; Hour = 9; Minute = 30; Frequency = "Daily"; TimeZone = "UTC" }
                    # Resource model sync
                    @{ RunbookName = "Sync-FGEntraDirectoryRoles"; ScheduleName = "Daily-EntraDirectoryRoles-0715"; Hour = 7; Minute = 15; Frequency = "Daily"; TimeZone = "UTC" }
                    @{ RunbookName = "Sync-FGEntraAppRoleAssignments"; ScheduleName = "Daily-EntraAppRoleAssignments-0730"; Hour = 7; Minute = 30; Frequency = "Daily"; TimeZone = "UTC" }
                    @{ RunbookName = "Sync-FGResourceRelationships"; ScheduleName = "Daily-ResourceRelationships-0845"; Hour = 8; Minute = 45; Frequency = "Daily"; TimeZone = "UTC" }
                    # Post-sync: Materialize views for UI (after all syncs complete)
                    @{ RunbookName = "Sync-FGMaterializedViews"; ScheduleName = "Daily-MaterializedViews-1000"; Hour = 10; Minute = 0; Frequency = "Daily"; TimeZone = "UTC" }
                    # Post-sync: Risk scoring (after materialized views)
                    @{ RunbookName = "Invoke-FGRiskScoring"; ScheduleName = "Daily-RiskScoring-1030"; Hour = 10; Minute = 30; Frequency = "Daily"; TimeZone = "UTC" }
                    # Post-scoring: Account correlation (after risk scoring)
                    @{ RunbookName = "Invoke-FGAccountCorrelation"; ScheduleName = "Daily-AccountCorrelation-1100"; Hour = 11; Minute = 0; Frequency = "Daily"; TimeZone = "UTC" }
                )
            }

            # Check for existing schedules that are not in the current configuration
            # These could be from previous config changes or manually added schedules
            $newScheduleNames = $schedulesToCreate | ForEach-Object { $_.ScheduleName }

            # Find FortigiGraph-related schedules (Daily-* or Hourly-* patterns for our runbooks)
            $fgSchedulePattern = '^(Daily|Hourly)-(Users|Groups|GroupMembers|GroupEligibleMembers|GroupOwners|Catalogs|AccessPackages|AccessPackageAssignments|AccessPackageResourceRoleScopes|AccessPackageAssignmentPolicies|AccessPackageAssignmentRequests|AccessPackageAccessReviews|MaterializedViews|RiskScoring|AccountCorrelation)-'

            $orphanedSchedules = @()
            $additionalSchedules = @()

            if ($existingSchedules) {
                foreach ($existingSched in $existingSchedules) {
                    # Check if this is a FortigiGraph schedule
                    if ($existingSched.Name -match $fgSchedulePattern) {
                        if ($newScheduleNames -notcontains $existingSched.Name) {
                            $orphanedSchedules += $existingSched
                        }
                    }
                    # Check for schedules linked to our runbooks but with custom names
                    elseif ($existingLinks | Where-Object { $_.ScheduleName -eq $existingSched.Name }) {
                        $additionalSchedules += $existingSched
                    }
                }
            }

            # Auto-remove schedules for explicitly disabled features
            $disabledFeatureSchedules = @()
            $generalOrphanedSchedules = @()
            foreach ($orphan in $orphanedSchedules) {
                if ((-not $riskScoringEnabled -and $orphan.Name -match 'RiskScoring') -or
                    (-not $accountCorrelationEnabled -and $orphan.Name -match 'AccountCorrelation')) {
                    $disabledFeatureSchedules += $orphan
                } else {
                    $generalOrphanedSchedules += $orphan
                }
            }

            if ($disabledFeatureSchedules.Count -gt 0) {
                Write-Host ""
                Write-Host "  Removing $($disabledFeatureSchedules.Count) schedule(s) for disabled features..." -ForegroundColor Yellow
                foreach ($sched in $disabledFeatureSchedules) {
                    try {
                        Remove-AzAutomationSchedule `
                            -ResourceGroupName $ResourceGroupName `
                            -AutomationAccountName $AutomationAccountName `
                            -Name $sched.Name `
                            -Force -ErrorAction Stop
                        Write-Host "    Removed: $($sched.Name)" -ForegroundColor Green
                    } catch {
                        Write-Warning "    Failed to remove schedule $($sched.Name): $_"
                    }
                }
            }

            # Warn about remaining orphaned schedules (from previous config changes)
            if ($generalOrphanedSchedules.Count -gt 0) {
                Write-Host ""
                Write-Host "  ========================================" -ForegroundColor Yellow
                Write-Host "  WARNING: Found $($generalOrphanedSchedules.Count) orphaned schedule(s)" -ForegroundColor Yellow
                Write-Host "  ========================================" -ForegroundColor Yellow
                Write-Host "  These schedules appear to be from previous configurations" -ForegroundColor Yellow
                Write-Host "  and are NOT in your current config file:" -ForegroundColor Yellow
                Write-Host ""
                foreach ($orphan in $generalOrphanedSchedules) {
                    $status = if ($orphan.IsEnabled) { "Enabled" } else { "Disabled" }
                    Write-Host "    - $($orphan.Name) ($status)" -ForegroundColor Yellow
                }
                Write-Host ""
                Write-Host "  Consider removing these manually if no longer needed:" -ForegroundColor Gray
                Write-Host "  Azure Portal > Automation Account > Schedules" -ForegroundColor Gray
                Write-Host "  ========================================" -ForegroundColor Yellow
                Write-Host ""
            }

            # Warn about additional custom schedules linked to our runbooks
            if ($additionalSchedules.Count -gt 0) {
                Write-Host ""
                Write-Host "  ========================================" -ForegroundColor Cyan
                Write-Host "  INFO: Found $($additionalSchedules.Count) additional schedule(s)" -ForegroundColor Cyan
                Write-Host "  ========================================" -ForegroundColor Cyan
                Write-Host "  These custom schedules are linked to FortigiGraph runbooks:" -ForegroundColor Cyan
                Write-Host ""
                foreach ($additional in $additionalSchedules) {
                    $status = if ($additional.IsEnabled) { "Enabled" } else { "Disabled" }
                    $linkedRunbooks = ($existingLinks | Where-Object { $_.ScheduleName -eq $additional.Name } | ForEach-Object { $_.RunbookName }) -join ", "
                    Write-Host "    - $($additional.Name) ($status) -> $linkedRunbooks" -ForegroundColor Cyan
                }
                Write-Host ""
                Write-Host "  These will be kept as-is (not modified by this script)" -ForegroundColor Gray
                Write-Host "  ========================================" -ForegroundColor Cyan
                Write-Host ""
            }

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Creating $($schedulesToCreate.Count) schedule(s)..." -ForegroundColor Cyan

            $startDate = (Get-Date).AddDays(1).Date

            foreach ($schedule in $schedulesToCreate) {
                Write-Host "  Creating schedule: $($schedule.ScheduleName)..." -ForegroundColor Cyan

                try {
                    $startTime = $startDate.AddHours($schedule.Hour).AddMinutes($schedule.Minute)

                    # Check if schedule exists
                    $existingSchedule = Get-AzAutomationSchedule `
                        -ResourceGroupName $ResourceGroupName `
                        -AutomationAccountName $AutomationAccountName `
                        -Name $schedule.ScheduleName `
                        -ErrorAction SilentlyContinue

                    if (-not $existingSchedule) {
                        # Create schedule with time zone support
                        $scheduleParams = @{
                            ResourceGroupName = $ResourceGroupName
                            AutomationAccountName = $AutomationAccountName
                            Name = $schedule.ScheduleName
                            StartTime = $startTime
                        }

                        # Set interval based on frequency
                        if ($schedule.Frequency -eq "Hourly") {
                            $scheduleParams.HourInterval = 1
                            $scheduleParams.Description = "Hourly schedule for $($schedule.RunbookName)"
                        }
                        else {
                            $scheduleParams.DayInterval = 1
                            $scheduleParams.Description = "Daily schedule for $($schedule.RunbookName)"
                        }

                        # Add time zone if specified and not UTC
                        if ($schedule.TimeZone -and $schedule.TimeZone -ne "UTC") {
                            $scheduleParams.TimeZone = $schedule.TimeZone
                        }

                        New-AzAutomationSchedule @scheduleParams | Out-Null
                    }
                    else {
                        Write-Host "    Schedule already exists, updating link..." -ForegroundColor Yellow
                    }

                    # Link schedule to runbook
                    Register-AzAutomationScheduledRunbook `
                        -ResourceGroupName $ResourceGroupName `
                        -AutomationAccountName $AutomationAccountName `
                        -RunbookName $schedule.RunbookName `
                        -ScheduleName $schedule.ScheduleName `
                        -ErrorAction SilentlyContinue | Out-Null

                    $timeDisplay = "$($schedule.Hour.ToString('00')):$($schedule.Minute.ToString('00'))"
                    $tzDisplay = if ($schedule.TimeZone -and $schedule.TimeZone -ne "UTC") { " ($($schedule.TimeZone))" } else { " (UTC)" }
                    Write-Host "    Schedule created: $($schedule.Frequency) at $timeDisplay$tzDisplay" -ForegroundColor Green
                }
                catch {
                    Write-Warning "    Failed to create schedule $($schedule.ScheduleName): $_"
                }
            }
        }
        elseif ($shouldCreateSchedules -and $SkipRunbooks) {
            Write-Warning "Schedules require runbooks. Remove -SkipRunbooks to create schedules."
        }

        # Summary
        Write-Host "`n========================================" -ForegroundColor Cyan
        Write-Host "Azure Automation Account Setup Complete!" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "Automation Account: $AutomationAccountName" -ForegroundColor White
        Write-Host "Resource Group:     $ResourceGroupName" -ForegroundColor White
        Write-Host "Location:           $Location" -ForegroundColor White
        Write-Host ""
        Write-Host "Variables Created:" -ForegroundColor Cyan
        Write-Host "  - GraphTenantId, GraphClientId, GraphClientSecret (encrypted)" -ForegroundColor White
        Write-Host "  - SQLServerName, SQLDatabaseName, SQLAdminUsername, SQLAdminPassword (encrypted)" -ForegroundColor White

        if (-not $SkipModuleImport) {
            Write-Host ""
            Write-Host "Modules Importing:" -ForegroundColor Cyan
            Write-Host "  - Az.Accounts, Az.Sql (may take a few minutes)" -ForegroundColor White
            if (-not $SkipModuleUpload) {
                Write-Host "  - FortigiGraph (uploaded from local path)" -ForegroundColor White
            }
        }

        if (-not $SkipRunbooks) {
            Write-Host ""
            Write-Host "Runbooks Created ($($runbooks.Count) total):" -ForegroundColor Cyan
            Write-Host "  Users & Groups:    Sync-FGUsers, Sync-FGGroups" -ForegroundColor White
            Write-Host "  Group Membership:  Sync-FGGroupMembers, Sync-FGGroupEligibleMembers," -ForegroundColor White
            Write-Host "                     Sync-FGGroupOwners" -ForegroundColor White
            Write-Host "  Access Packages:   Sync-FGCatalogs, Sync-FGAccessPackages," -ForegroundColor White
            Write-Host "                     Sync-FGAccessPackageAssignments, Sync-FGAccessPackageResourceRoleScopes," -ForegroundColor White
            Write-Host "                     Sync-FGAccessPackageAssignmentPolicies, Sync-FGAccessPackageAssignmentRequests," -ForegroundColor White
            Write-Host "                     Sync-FGAccessPackageAccessReviews" -ForegroundColor White
            Write-Host "  Post-Sync:         Sync-FGMaterializedViews (views + indexes for UI)" -ForegroundColor White
            Write-Host "  Risk Scoring:      Invoke-FGRiskScoring (classifiers from SQL)" -ForegroundColor White
            Write-Host "  Correlation:       Invoke-FGAccountCorrelation (ruleset from SQL)" -ForegroundColor White
        }

        if ($shouldCreateSchedules -and -not $SkipRunbooks) {
            Write-Host ""
            Write-Host "Schedules Created:" -ForegroundColor Cyan
            if ($PSCmdlet.ParameterSetName -eq 'ConfigFile' -and $scheduleConfig.Schedules.Count -gt 0) {
                Write-Host "  - $($scheduleConfig.Schedules.Count) schedules from config file ($($scheduleConfig.TimeZone))" -ForegroundColor White
            }
            else {
                Write-Host "  - $($schedulesToCreate.Count) daily schedules starting tomorrow (6AM-9:30AM UTC)" -ForegroundColor White
            }
        }

        Write-Host ""
        Write-Host "NEXT STEPS:" -ForegroundColor Yellow
        if (-not $SkipModuleUpload) {
            Write-Host "1. Wait for module imports to complete (check Modules status)" -ForegroundColor White
            Write-Host "2. Test runbooks manually before enabling schedules" -ForegroundColor White
        }
        else {
            Write-Host "1. Import FortigiGraph module from PowerShell Gallery" -ForegroundColor White
            Write-Host "   (Azure Portal > Automation Account > Modules > Browse Gallery)" -ForegroundColor Gray
            Write-Host "2. Wait for module imports to complete (check Modules status)" -ForegroundColor White
            Write-Host "3. Test runbooks manually before enabling schedules" -ForegroundColor White
        }
        Write-Host "========================================`n" -ForegroundColor Cyan

        return @{
            AutomationAccountName = $AutomationAccountName
            ResourceGroupName = $ResourceGroupName
            Location = $Location
            RunbooksCreated = (-not $SkipRunbooks.IsPresent)
            SchedulesCreated = ($shouldCreateSchedules -and -not $SkipRunbooks.IsPresent)
            ScheduleCount = if ($shouldCreateSchedules -and -not $SkipRunbooks.IsPresent) { $schedulesToCreate.Count } else { 0 }
        }
    }
    catch {
        Write-Error "Failed to create Azure Automation Account: $_"
        throw
    }
}
