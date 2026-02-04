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

    .PARAMETER CreateRunbooks
    If specified, creates runbook scripts for each sync type.

    .PARAMETER CreateSchedules
    If specified, creates schedules for the runbooks.
    Requires -CreateRunbooks to also be specified.

    .PARAMETER SkipModuleImport
    If specified, skips importing Az modules. Useful if you want to import FortigiGraph manually.

    .EXAMPLE
    New-FGAzureAutomationAccount -ConfigFile ".\config.json" -SubscriptionId "xxx" -ResourceGroupName "rg-fortigraph" -AutomationAccountName "aa-fortigraph" -CreateRunbooks

    Creates Automation Account using credentials from config file and creates runbooks.

    .EXAMPLE
    New-FGAzureAutomationAccount -SubscriptionId "xxx" -ResourceGroupName "rg-fortigraph" -AutomationAccountName "aa-fortigraph" -GraphTenantId "xxx" -GraphClientId "xxx" -GraphClientSecret "xxx" -SQLServerName "sql-fortigraph" -SQLDatabaseName "GraphDB" -SQLAdminUsername "sqladmin" -SQLAdminPassword "xxx"

    Creates Automation Account with explicit credentials.

    .NOTES
    Requires Az PowerShell module (Install-Module -Name Az)
    Must be logged in to Azure (Connect-AzAccount)

    FortigiGraph module must be imported manually into the Automation Account
    (upload from PowerShell Gallery or as a zip file).
    #>

    [CmdletBinding(DefaultParameterSetName = 'ConfigFile')]
    [Alias("New-AutomationAccount")]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$AutomationAccountName,

        [Parameter(Mandatory = $false)]
        [string]$Location = "northeurope",

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
        [switch]$CreateRunbooks,

        [Parameter(Mandatory = $false)]
        [switch]$CreateSchedules,

        [Parameter(Mandatory = $false)]
        [switch]$SkipModuleImport
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

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Loading credentials from config file..." -ForegroundColor Cyan
        $config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json

        # Extract Graph credentials
        $GraphTenantId = $config.Graph.TenantId
        $GraphClientId = $config.Graph.ClientId
        $GraphClientSecret = $config.Graph.ClientSecret

        # Extract SQL credentials
        $SQLServerName = $config.Azure.SQLServerName
        $SQLDatabaseName = $config.Azure.DatabaseName
        $SQLAdminUsername = $config.Azure.AdminUsername
        $SQLAdminPassword = $config.Azure.AdminUserPassword

        # Validate required fields
        if (-not $GraphTenantId) { throw "Config file missing: Graph.TenantId" }
        if (-not $GraphClientId) { throw "Config file missing: Graph.ClientId" }
        if (-not $GraphClientSecret) { throw "Config file missing: Graph.ClientSecret" }
        if (-not $SQLServerName) { throw "Config file missing: Azure.SQLServerName" }
        if (-not $SQLDatabaseName) { throw "Config file missing: Azure.DatabaseName" }
        if (-not $SQLAdminUsername) { throw "Config file missing: Azure.AdminUsername" }
        if (-not $SQLAdminPassword) { throw "Config file missing: Azure.AdminUserPassword" }

        Write-Host "  Credentials loaded successfully" -ForegroundColor Green
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
            $automationAccount = New-AzAutomationAccount `
                -ResourceGroupName $ResourceGroupName `
                -Name $AutomationAccountName `
                -Location $Location

            Write-Host "  Automation Account created successfully" -ForegroundColor Green
        }
        else {
            Write-Host "  Automation Account already exists" -ForegroundColor Green
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

            Write-Host "`n  IMPORTANT: You need to manually import FortigiGraph module" -ForegroundColor Yellow
            Write-Host "  Go to: Azure Portal > Automation Account > Modules > Browse Gallery" -ForegroundColor Yellow
            Write-Host "  Search for 'FortigiGraph' and import it" -ForegroundColor Yellow
        }

        # Create Runbooks
        if ($CreateRunbooks) {
            Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Creating runbooks..." -ForegroundColor Cyan

            $runbooks = @(
                @{
                    Name = "Sync-FGUsers"
                    Description = "Syncs Microsoft Graph users to Azure SQL"
                    SyncFunction = "Sync-FGUser"
                }
                @{
                    Name = "Sync-FGGroups"
                    Description = "Syncs Microsoft Graph groups to Azure SQL"
                    SyncFunction = "Sync-FGGroup"
                }
                @{
                    Name = "Sync-FGGroupMembers"
                    Description = "Syncs Microsoft Graph group memberships to Azure SQL"
                    SyncFunction = "Sync-FGGroupMember"
                    ExtraParams = "-UseBatching"
                }
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
                }
            )

            foreach ($runbook in $runbooks) {
                Write-Host "  Creating runbook: $($runbook.Name)..." -ForegroundColor Cyan

                $extraParams = if ($runbook.ExtraParams) { " $($runbook.ExtraParams)" } else { "" }

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

# Run sync
Write-Output "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Running $($runbook.SyncFunction)..."
$($runbook.SyncFunction)$extraParams

Write-Output "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $($runbook.Name) completed successfully"
"@

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

                    # Import runbook
                    Import-AzAutomationRunbook `
                        -ResourceGroupName $ResourceGroupName `
                        -AutomationAccountName $AutomationAccountName `
                        -Name $runbook.Name `
                        -Path $tempFile `
                        -Type PowerShell `
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
        if ($CreateSchedules -and $CreateRunbooks) {
            Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Creating schedules..." -ForegroundColor Cyan
            Write-Host "  Note: Schedules start tomorrow at the specified times" -ForegroundColor Gray

            $schedules = @(
                @{ RunbookName = "Sync-FGUsers"; ScheduleName = "Daily-Users-6AM"; Hour = 6; Frequency = "Day" }
                @{ RunbookName = "Sync-FGGroups"; ScheduleName = "Daily-Groups-6AM"; Hour = 6; Frequency = "Day" }
                @{ RunbookName = "Sync-FGGroupMembers"; ScheduleName = "Daily-GroupMembers-7AM"; Hour = 7; Frequency = "Day" }
                @{ RunbookName = "Sync-FGCatalogs"; ScheduleName = "Daily-Catalogs-6AM"; Hour = 6; Frequency = "Day" }
                @{ RunbookName = "Sync-FGAccessPackages"; ScheduleName = "Daily-AccessPackages-6AM"; Hour = 6; Frequency = "Day" }
                @{ RunbookName = "Sync-FGAccessPackageAssignments"; ScheduleName = "Daily-Assignments-8AM"; Hour = 8; Frequency = "Day" }
            )

            $startDate = (Get-Date).AddDays(1).Date

            foreach ($schedule in $schedules) {
                Write-Host "  Creating schedule: $($schedule.ScheduleName)..." -ForegroundColor Cyan

                try {
                    $startTime = $startDate.AddHours($schedule.Hour)

                    # Create schedule
                    $existingSchedule = Get-AzAutomationSchedule `
                        -ResourceGroupName $ResourceGroupName `
                        -AutomationAccountName $AutomationAccountName `
                        -Name $schedule.ScheduleName `
                        -ErrorAction SilentlyContinue

                    if (-not $existingSchedule) {
                        New-AzAutomationSchedule `
                            -ResourceGroupName $ResourceGroupName `
                            -AutomationAccountName $AutomationAccountName `
                            -Name $schedule.ScheduleName `
                            -StartTime $startTime `
                            -DayInterval 1 `
                            -Description "Daily schedule for $($schedule.RunbookName)" | Out-Null
                    }

                    # Link schedule to runbook
                    Register-AzAutomationScheduledRunbook `
                        -ResourceGroupName $ResourceGroupName `
                        -AutomationAccountName $AutomationAccountName `
                        -RunbookName $schedule.RunbookName `
                        -ScheduleName $schedule.ScheduleName `
                        -ErrorAction SilentlyContinue | Out-Null

                    Write-Host "    Schedule created: $($schedule.Frequency) at $($schedule.Hour):00" -ForegroundColor Green
                }
                catch {
                    Write-Warning "    Failed to create schedule $($schedule.ScheduleName): $_"
                }
            }
        }
        elseif ($CreateSchedules -and -not $CreateRunbooks) {
            Write-Warning "Schedules require runbooks. Use -CreateRunbooks with -CreateSchedules."
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
        }

        if ($CreateRunbooks) {
            Write-Host ""
            Write-Host "Runbooks Created:" -ForegroundColor Cyan
            Write-Host "  - Sync-FGUsers, Sync-FGGroups, Sync-FGGroupMembers" -ForegroundColor White
            Write-Host "  - Sync-FGCatalogs, Sync-FGAccessPackages, Sync-FGAccessPackageAssignments" -ForegroundColor White
        }

        if ($CreateSchedules -and $CreateRunbooks) {
            Write-Host ""
            Write-Host "Schedules Created:" -ForegroundColor Cyan
            Write-Host "  - Daily schedules starting tomorrow (6AM-8AM)" -ForegroundColor White
        }

        Write-Host ""
        Write-Host "NEXT STEPS:" -ForegroundColor Yellow
        Write-Host "1. Import FortigiGraph module from PowerShell Gallery" -ForegroundColor White
        Write-Host "   (Azure Portal > Automation Account > Modules > Browse Gallery)" -ForegroundColor Gray
        Write-Host "2. Wait for module imports to complete (check Modules status)" -ForegroundColor White
        Write-Host "3. Test runbooks manually before enabling schedules" -ForegroundColor White
        Write-Host "========================================`n" -ForegroundColor Cyan

        return @{
            AutomationAccountName = $AutomationAccountName
            ResourceGroupName = $ResourceGroupName
            Location = $Location
            RunbooksCreated = $CreateRunbooks.IsPresent
            SchedulesCreated = ($CreateSchedules.IsPresent -and $CreateRunbooks.IsPresent)
        }
    }
    catch {
        Write-Error "Failed to create Azure Automation Account: $_"
        throw
    }
}
