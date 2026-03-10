function Connect-FGSQLServer {
    <#
    .SYNOPSIS
    Connects to an Azure SQL Server with automatic firewall management and Azure integration.

    .DESCRIPTION
    This is the main connection function that provides a user-friendly experience:
    1. Retrieves SQL Server details from Azure
    2. Checks and updates firewall rules with your current IP
    3. Automatically handles connection with stored credentials
    4. Provides helpful error messages and troubleshooting guidance

    This function calls New-FGSQLConnection internally to establish the actual connection.

    Supports either explicit parameters or reading from a JSON configuration file.

    When using -ConfigFile:
    - SubscriptionId is read from Azure.SubscriptionId
    - ResourceGroupName is read from Azure.ResourceGroupName
    - ServerName is read from Azure.SQLServerName
    - DatabaseName is read from Azure.DatabaseName (if present)
    - AdminUsername is read from Azure.AdminUsername (defaults to "sqladmin")
    - AdminPassword is read from Azure.AdminUserPassword (with DPAPI encryption support)

    .PARAMETER SubscriptionId
    The Azure Subscription ID where the SQL Server exists. Mandatory unless using -ConfigFile.

    .PARAMETER ResourceGroupName
    The Resource Group name containing the SQL Server. Mandatory unless using -ConfigFile.

    .PARAMETER ServerName
    The SQL Server name (without .database.windows.net suffix). Mandatory unless using -ConfigFile.

    .PARAMETER DatabaseName
    The database name. If not specified, uses the first database found or prompts.

    .PARAMETER AdminUsername
    SQL Server admin username. Default: "sqladmin"

    .PARAMETER AdminPassword
    SQL Server admin password (as SecureString). If not provided and not stored, will prompt.

    .PARAMETER ConfigFile
    Path to a JSON configuration file containing Azure and SQL connection details.
    If specified, SubscriptionId, ResourceGroupName, ServerName, etc. are read from the config file.

    .PARAMETER SkipFirewallUpdate
    If specified, skips automatic firewall rule updates. By default, the function automatically
    updates firewall rules to allow your current IP address for seamless connectivity.

    .PARAMETER Force
    If specified, forces a new connection even if already connected.

    .EXAMPLE
    Connect-FGSQLServer -SubscriptionId "xxx" -ResourceGroupName "rg-graph" -ServerName "iisqlserver"

    Connects to the SQL Server and automatically updates firewall with your current IP

    .EXAMPLE
    Connect-FGSQLServer -SubscriptionId "xxx" -ResourceGroupName "rg-graph" -ServerName "iisqlserver" -DatabaseName "GraphData"

    Connects to a specific database with automatic firewall update

    .EXAMPLE
    Connect-FGSQLServer -ConfigFile "config.json"

    Connects using credentials from config file with automatic firewall update

    .EXAMPLE
    Connect-FGSQLServer -ConfigFile "config.json" -SkipFirewallUpdate

    Connects using config file without updating firewall rules

    .NOTES
    Requires Az PowerShell module and being logged into Azure (Connect-AzAccount)
    #>

    [alias("Connect-SQLServer")]
    [CmdletBinding(DefaultParameterSetName = 'Explicit')]
    Param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Explicit')]
        [System.String]$SubscriptionId,

        [Parameter(Mandatory = $true, ParameterSetName = 'Explicit')]
        [System.String]$ResourceGroupName,

        [Parameter(Mandatory = $true, ParameterSetName = 'Explicit')]
        [System.String]$ServerName,

        [Parameter(Mandatory = $false)]
        [System.String]$DatabaseName,

        [Parameter(Mandatory = $false)]
        [System.String]$AdminUsername,

        [Parameter(Mandatory = $false)]
        [SecureString]$AdminPassword,

        [Parameter(Mandatory = $true, ParameterSetName = "ConfigFile")]
        [System.String]$ConfigFile,

        [Parameter(Mandatory = $false)]
        [Switch]$SkipFirewallUpdate,

        [Parameter(Mandatory = $false)]
        [Switch]$Force
    )

    # If ConfigFile is specified, read connection details from config
    if ($PSCmdlet.ParameterSetName -eq "ConfigFile") {
        if (-not (Test-Path $ConfigFile)) {
            throw "Configuration file not found: $ConfigFile"
        }

        # Load config
        $config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json

        # Read SubscriptionId
        if (-not $config.Azure.SubscriptionId) {
            throw "Azure.SubscriptionId not found in configuration file"
        }
        $SubscriptionId = $config.Azure.SubscriptionId

        # Read ResourceGroupName
        if (-not $config.Azure.ResourceGroupName) {
            throw "Azure.ResourceGroupName not found in configuration file"
        }
        $ResourceGroupName = $config.Azure.ResourceGroupName

        # Read ServerName
        if (-not $config.Azure.SQLServerName) {
            throw "Azure.SQLServerName not found in configuration file"
        }
        $ServerName = $config.Azure.SQLServerName

        # Read optional DatabaseName
        if ($config.Azure.DatabaseName) {
            $DatabaseName = $config.Azure.DatabaseName
        }

        # Read optional AdminUsername (default to sqladmin)
        if ($config.Azure.AdminUsername) {
            $AdminUsername = $config.Azure.AdminUsername
        } else {
            $AdminUsername = "sqladmin"
        }

        # Read AdminPassword (with encryption support)
        $passwordPlainText = Get-FGSecureConfigValue -ConfigPath $ConfigFile -PropertyPath "Azure.AdminUserPassword" -AllowEmpty
        if (-not [string]::IsNullOrWhiteSpace($passwordPlainText)) {
            $AdminPassword = ConvertTo-SecureString -String $passwordPlainText -AsPlainText -Force
        }
        # If no password in config, will prompt later
    }
    # Explicit parameter set - set default AdminUsername if not provided
    else {
        if (-not $AdminUsername) {
            $AdminUsername = "sqladmin"
        }
    }

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
        # Set subscription context
        Write-Host "Setting Azure subscription context..." -ForegroundColor Cyan
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

        # Normalize server name (remove .database.windows.net if present)
        $ServerName = $ServerName -replace '\.database\.windows\.net$', ''
        $ServerName = $ServerName.ToLower()

        # Get SQL Server details from Azure
        Write-Host "Retrieving SQL Server details from Azure..." -ForegroundColor Cyan
        $sqlServer = Get-AzSqlServer -ResourceGroupName $ResourceGroupName -ServerName $ServerName -ErrorAction SilentlyContinue

        if (-not $sqlServer) {
            Write-Host "`nSQL Server '$ServerName' not found in resource group '$ResourceGroupName'" -ForegroundColor Red
            Write-Host "`nTo create a new SQL Server, run:" -ForegroundColor Yellow
            Write-Host "  New-FGAzureSQLServer -SubscriptionId '$SubscriptionId' -ResourceGroupName '$ResourceGroupName' -ServerName '$ServerName' -AllowCurrentIP -AutoConnect" -ForegroundColor Cyan
            Write-Host "`nOr check if the server name and resource group are correct." -ForegroundColor Yellow
            return $false
        }

        Write-Host "  Found server: $($sqlServer.ServerName)" -ForegroundColor Green
        Write-Host "  Location: $($sqlServer.Location)" -ForegroundColor Cyan
        Write-Host "  FQDN: $($sqlServer.FullyQualifiedDomainName)" -ForegroundColor Cyan

        # Get database if not specified
        if (-not $DatabaseName) {
            Write-Host "Retrieving databases..." -ForegroundColor Cyan
            $databases = Get-AzSqlDatabase -ResourceGroupName $ResourceGroupName -ServerName $ServerName | Where-Object { $_.DatabaseName -ne 'master' }

            if ($databases.Count -eq 0) {
                throw "No user databases found on server $ServerName"
            }
            elseif ($databases.Count -eq 1) {
                $DatabaseName = $databases[0].DatabaseName
                Write-Host "  Using database: $DatabaseName" -ForegroundColor Green
            }
            else {
                Write-Host "  Available databases:" -ForegroundColor Yellow
                $databases | ForEach-Object { Write-Host "    - $($_.DatabaseName)" -ForegroundColor White }
                $DatabaseName = Read-Host "Enter database name"
            }
        }

        # Update firewall by default (unless explicitly skipped)
        if (-not $SkipFirewallUpdate) {
            Write-Host "Updating firewall rules..." -ForegroundColor Cyan
            try {
                # Get current public IP
                $currentIP = (Invoke-WebRequest -Uri "https://api.ipify.org" -UseBasicParsing).Content.Trim()
                Write-Host "  Your current IP: $currentIP" -ForegroundColor Cyan

                # Check if rule exists
                $existingRule = Get-AzSqlServerFirewallRule -ResourceGroupName $ResourceGroupName -ServerName $ServerName -FirewallRuleName "AllowMyIP" -ErrorAction SilentlyContinue

                if ($existingRule) {
                    # Update existing rule
                    Set-AzSqlServerFirewallRule -ResourceGroupName $ResourceGroupName -ServerName $ServerName -FirewallRuleName "AllowMyIP" -StartIpAddress $currentIP -EndIpAddress $currentIP | Out-Null
                    Write-Host "  Updated existing firewall rule" -ForegroundColor Green
                }
                else {
                    # Create new rule
                    New-AzSqlServerFirewallRule -ResourceGroupName $ResourceGroupName -ServerName $ServerName -FirewallRuleName "AllowMyIP" -StartIpAddress $currentIP -EndIpAddress $currentIP | Out-Null
                    Write-Host "  Created new firewall rule" -ForegroundColor Green
                }
            }
            catch {
                Write-Warning "Failed to update firewall rule: $_"
                Write-Host "You may need to manually add your IP address in the Azure Portal." -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "Skipping firewall update (use without -SkipFirewallUpdate to auto-update)" -ForegroundColor Yellow
        }

        # Check if already connected (verify connection actually works)
        if ($global:FGSQLServerName -eq $sqlServer.FullyQualifiedDomainName -and $global:FGSQLDatabaseName -eq $DatabaseName -and -not $Force) {
            # Test if connection actually works by calling Test-FGSQLConnection
            if ($global:FGSQLConnectionString) {
                try {
                    $testResult = Test-FGSQLConnection
                    if ($testResult) {
                        Write-Host "Already connected to $($sqlServer.FullyQualifiedDomainName) / $DatabaseName" -ForegroundColor Green
                        return $testResult
                    }
                }
                catch {
                    Write-Verbose "Existing connection is invalid, reconnecting..."
                }
            }
        }

        # Get password if not provided
        if (-not $AdminPassword) {
            # Check if password is stored in session
            if ($global:FGSQLAdminPassword -and $global:FGSQLAdminUsername -eq $AdminUsername) {
                Write-Host "Using stored credentials from session..." -ForegroundColor Cyan
                $AdminPassword = $global:FGSQLAdminPassword
            }
            else {
                $AdminPassword = Read-Host "Enter password for SQL admin '$AdminUsername'" -AsSecureString
                # Store in session for future use
                $global:FGSQLAdminPassword = $AdminPassword
                $global:FGSQLAdminUsername = $AdminUsername
            }
        }
        else {
            # Store provided password for session
            $global:FGSQLAdminPassword = $AdminPassword
            $global:FGSQLAdminUsername = $AdminUsername
        }

        # Create credential object
        $credential = New-Object System.Management.Automation.PSCredential ($AdminUsername, $AdminPassword)

        # Connect
        Write-Host "Connecting to SQL Server..." -ForegroundColor Cyan
        $result = New-FGSQLConnection -ServerName $sqlServer.FullyQualifiedDomainName -DatabaseName $DatabaseName -Credential $credential

        if ($result) {
            Write-Host "`nConnection successful!" -ForegroundColor Green
            Write-Host "You can now use Initialize-FGSQLTable and other SQL functions.`n" -ForegroundColor Cyan

            # Test connection to show details
            return Test-FGSQLConnection
        }
        else {
            throw "Failed to connect to SQL Server"
        }
    }
    catch {
        Write-Error "Failed to connect from Azure: $_"

        # Provide helpful guidance
        Write-Host "`nTroubleshooting:" -ForegroundColor Yellow
        Write-Host "  1. Firewall should have been updated automatically - check if it succeeded above" -ForegroundColor White
        Write-Host "  2. Check your firewall rules in Azure Portal" -ForegroundColor White
        Write-Host "  3. Verify the SQL admin password is correct" -ForegroundColor White
        Write-Host "  4. Check that the database exists" -ForegroundColor White

        return $false
    }
}
