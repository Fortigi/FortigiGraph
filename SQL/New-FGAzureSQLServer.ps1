function New-FGAzureSQLServer {
    <#
    .SYNOPSIS
    Creates a new Azure SQL Server and Database for storing Microsoft Graph data.

    .DESCRIPTION
    Provisions a new Azure SQL Server and Database in the specified subscription and resource group.
    Configures firewall rules and retrieves connection details for use with Connect-FGSQLServer.

    Can automatically configure Azure AD authentication and optionally set the current user as admin.

    .PARAMETER SubscriptionId
    The Azure Subscription ID where the SQL Server will be created.

    .PARAMETER ResourceGroupName
    The Resource Group name. Will be created if it doesn't exist.

    .PARAMETER Location
    Azure region (e.g., "eastus", "westeurope", "northeurope"). Default: "northeurope"

    .PARAMETER ServerName
    The SQL Server name (must be globally unique). Will be suffixed with .database.windows.net

    .PARAMETER DatabaseName
    The database name to create. Default: "GraphData"

    .PARAMETER AdminUsername
    SQL Server administrator username. Default: "sqladmin"

    .PARAMETER AdminPassword
    SQL Server administrator password (as SecureString). If not provided, will prompt.

    .PARAMETER SkuName
    Database SKU name. Options:
    - "Basic" (cheap, 2GB max, good for testing)
    - "S0" (Standard tier, 250GB max)
    - "S1" (Standard tier, better performance)
    - "GP_Gen5_2" (General Purpose, 2 vCores)
    Default: "Basic"

    .PARAMETER EnableAzureADAuth
    If specified, enables Azure AD authentication and sets current user as AD admin.

    .PARAMETER AllowAzureServices
    If specified, allows Azure services to access the server (needed for Azure Functions, etc.)

    .PARAMETER AllowCurrentIP
    If specified, adds your current public IP to the firewall rules.

    .PARAMETER AutoConnect
    If specified, automatically runs Connect-FGSQLServer after creation.

    .EXAMPLE
    New-FGAzureSQLServer -SubscriptionId "xxx" -ResourceGroupName "rg-graph" -ServerName "mygraphsql" -EnableAzureADAuth -AllowCurrentIP -AutoConnect

    Creates a SQL Server with Azure AD auth, adds your IP to firewall, and connects automatically

    .EXAMPLE
    $pwd = Read-Host "Enter SQL Admin Password" -AsSecureString
    New-FGAzureSQLServer -SubscriptionId "xxx" -ResourceGroupName "rg-graph" -ServerName "mygraphsql" -AdminPassword $pwd -SkuName "S0"

    Creates a SQL Server with SQL authentication using Standard S0 tier

    .NOTES
    Requires Az PowerShell module (Install-Module -Name Az)
    Must be logged in to Azure (Connect-AzAccount)
    #>

    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [System.String]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [System.String]$ResourceGroupName,

        [Parameter(Mandatory = $false)]
        [System.String]$Location = "northeurope",

        [Parameter(Mandatory = $true)]
        [System.String]$ServerName,

        [Parameter(Mandatory = $false)]
        [System.String]$DatabaseName = "GraphData",

        [Parameter(Mandatory = $false)]
        [System.String]$AdminUsername = "sqladmin",

        [Parameter(Mandatory = $false)]
        [SecureString]$AdminPassword,

        [Parameter(Mandatory = $false)]
        [ValidateSet("Basic", "S0", "S1", "S2", "S3", "GP_Gen5_2", "GP_Gen5_4")]
        [System.String]$SkuName = "Basic",

        [Parameter(Mandatory = $false)]
        [Switch]$EnableAzureADAuth,

        [Parameter(Mandatory = $false)]
        [Switch]$AllowAzureServices,

        [Parameter(Mandatory = $false)]
        [Switch]$AllowCurrentIP,

        [Parameter(Mandatory = $false)]
        [Switch]$AutoConnect
    )

    # Check if Az module is available
    if (-not (Get-Module -ListAvailable -Name Az.Sql)) {
        throw "Az.Sql module not found. Please install it with: Install-Module -Name Az"
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

    try {
        # Check if context was already confirmed this session
        if (-not $global:FGAzureContextConfirmed) {
            # Get current context and display it
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
                Write-Host "Operation cancelled. Please run Connect-AzAccount or Set-AzContext to change context." -ForegroundColor Yellow
                return
            }

            # Mark context as confirmed for this session
            $global:FGAzureContextConfirmed = $true
            Write-Host "Azure context confirmed for this session.`n" -ForegroundColor Green
        }

        # Set subscription context
        Write-Host "Setting Azure subscription context..." -ForegroundColor Cyan
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

        # Validate and normalize server name
        $originalServerName = $ServerName
        $ServerName = $ServerName.ToLower()

        # Validate server name format
        if ($ServerName -notmatch '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$') {
            throw "Invalid server name. Server name must contain only lowercase letters (a-z), numbers (0-9), and hyphens. It cannot start or end with a hyphen."
        }

        if ($ServerName -ne $originalServerName) {
            Write-Host "Server name normalized to lowercase: $ServerName" -ForegroundColor Yellow
        }

        # Check/Create Resource Group
        Write-Host "Checking resource group: $ResourceGroupName..." -ForegroundColor Cyan
        $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
        if (-not $rg) {
            Write-Host "  Creating resource group: $ResourceGroupName in $Location..." -ForegroundColor Yellow
            $rg = New-AzResourceGroup -Name $ResourceGroupName -Location $Location
            Write-Host "  Resource group created successfully" -ForegroundColor Green
        }
        else {
            Write-Host "  Resource group already exists" -ForegroundColor Green
        }

        # Prompt for password if not provided
        if (-not $AdminPassword) {
            $AdminPassword = Read-Host "Enter SQL Server admin password" -AsSecureString
        }

        $credential = New-Object System.Management.Automation.PSCredential ($AdminUsername, $AdminPassword)

        # Check if SQL Server exists
        Write-Host "Checking SQL Server: $ServerName..." -ForegroundColor Cyan
        $sqlServer = Get-AzSqlServer -ResourceGroupName $ResourceGroupName -ServerName $ServerName -ErrorAction SilentlyContinue

        if (-not $sqlServer) {
            Write-Host "  Creating SQL Server: $ServerName in $Location..." -ForegroundColor Yellow
            Write-Host "    This may take a few minutes..." -ForegroundColor Yellow

            $sqlServer = New-AzSqlServer `
                -ResourceGroupName $ResourceGroupName `
                -ServerName $ServerName `
                -Location $Location `
                -SqlAdministratorCredentials $credential

            Write-Host "  SQL Server created successfully" -ForegroundColor Green
        }
        else {
            Write-Host "  SQL Server already exists" -ForegroundColor Green
        }

        # Configure Azure AD Authentication if requested
        if ($EnableAzureADAuth) {
            Write-Host "Configuring Azure AD authentication..." -ForegroundColor Cyan
            try {
                $currentUser = Get-AzADUser -SignedIn
                Set-AzSqlServerActiveDirectoryAdministrator `
                    -ResourceGroupName $ResourceGroupName `
                    -ServerName $ServerName `
                    -DisplayName $currentUser.DisplayName `
                    -ObjectId $currentUser.Id | Out-Null

                Write-Host "  Azure AD admin set to: $($currentUser.DisplayName)" -ForegroundColor Green
            }
            catch {
                Write-Warning "Failed to set Azure AD admin: $_"
            }
        }

        # Configure firewall rules
        Write-Host "Configuring firewall rules..." -ForegroundColor Cyan

        if ($AllowAzureServices) {
            Write-Host "  Allowing Azure services..." -ForegroundColor Yellow
            New-AzSqlServerFirewallRule `
                -ResourceGroupName $ResourceGroupName `
                -ServerName $ServerName `
                -FirewallRuleName "AllowAzureServices" `
                -StartIpAddress "0.0.0.0" `
                -EndIpAddress "0.0.0.0" `
                -ErrorAction SilentlyContinue | Out-Null
            Write-Host "    Azure services allowed" -ForegroundColor Green
        }

        if ($AllowCurrentIP) {
            Write-Host "  Getting your current public IP..." -ForegroundColor Yellow
            try {
                $currentIP = (Invoke-WebRequest -Uri "https://api.ipify.org" -UseBasicParsing).Content.Trim()
                Write-Host "    Your IP: $currentIP" -ForegroundColor Cyan

                New-AzSqlServerFirewallRule `
                    -ResourceGroupName $ResourceGroupName `
                    -ServerName $ServerName `
                    -FirewallRuleName "AllowMyIP" `
                    -StartIpAddress $currentIP `
                    -EndIpAddress $currentIP `
                    -ErrorAction SilentlyContinue | Out-Null

                Write-Host "    Your IP added to firewall" -ForegroundColor Green
            }
            catch {
                Write-Warning "Failed to add your IP to firewall: $_"
            }
        }

        # Check if database exists
        Write-Host "Checking database: $DatabaseName..." -ForegroundColor Cyan
        $database = Get-AzSqlDatabase `
            -ResourceGroupName $ResourceGroupName `
            -ServerName $ServerName `
            -DatabaseName $DatabaseName `
            -ErrorAction SilentlyContinue

        if (-not $database) {
            Write-Host "  Creating database: $DatabaseName with SKU: $SkuName..." -ForegroundColor Yellow
            Write-Host "    This may take a few minutes..." -ForegroundColor Yellow

            $database = New-AzSqlDatabase `
                -ResourceGroupName $ResourceGroupName `
                -ServerName $ServerName `
                -DatabaseName $DatabaseName `
                -RequestedServiceObjectiveName $SkuName

            Write-Host "  Database created successfully" -ForegroundColor Green
        }
        else {
            Write-Host "  Database already exists" -ForegroundColor Green
        }

        # Build connection details
        $fullyQualifiedServerName = "$ServerName.database.windows.net"

        Write-Host "`n========================================" -ForegroundColor Cyan
        Write-Host "Azure SQL Server Deployment Complete!" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "Server Name:    $fullyQualifiedServerName" -ForegroundColor White
        Write-Host "Database Name:  $DatabaseName" -ForegroundColor White
        Write-Host "Admin Username: $AdminUsername" -ForegroundColor White
        Write-Host "Location:       $Location" -ForegroundColor White
        Write-Host "SKU:            $SkuName" -ForegroundColor White

        if ($EnableAzureADAuth) {
            Write-Host "Auth Method:    Azure AD Integrated + SQL Auth" -ForegroundColor White
        }
        else {
            Write-Host "Auth Method:    SQL Authentication" -ForegroundColor White
        }

        Write-Host "`nConnection String (SQL Auth):" -ForegroundColor Cyan
        Write-Host "Server=$fullyQualifiedServerName;Database=$DatabaseName;User Id=$AdminUsername;Password=<your-password>;Encrypt=True;" -ForegroundColor Yellow

        if ($EnableAzureADAuth) {
            Write-Host "`nConnection String (Azure AD):" -ForegroundColor Cyan
            Write-Host "Server=$fullyQualifiedServerName;Database=$DatabaseName;Authentication=Active Directory Integrated;Encrypt=True;" -ForegroundColor Yellow
        }

        Write-Host "`n========================================`n" -ForegroundColor Cyan

        # Store details globally
        $global:FGSQLServerName = $fullyQualifiedServerName
        $global:FGSQLDatabaseName = $DatabaseName
        $global:FGSQLAdminUsername = $AdminUsername

        # Auto-connect if requested
        if ($AutoConnect) {
            Write-Host "Auto-connecting to SQL Server..." -ForegroundColor Cyan
            Connect-FGSQLServer `
                -SubscriptionId $SubscriptionId `
                -ResourceGroupName $ResourceGroupName `
                -ServerName $ServerName `
                -DatabaseName $DatabaseName `
                -AdminUsername $AdminUsername `
                -AdminPassword $AdminPassword
        }

        # Return deployment info
        return @{
            ServerName = $fullyQualifiedServerName
            DatabaseName = $DatabaseName
            AdminUsername = $AdminUsername
            Location = $Location
            SkuName = $SkuName
            ResourceGroupName = $ResourceGroupName
            AzureADAuthEnabled = $EnableAzureADAuth.IsPresent
        }
    }
    catch {
        Write-Error "Failed to create Azure SQL Server: $_"
        throw
    }
}
