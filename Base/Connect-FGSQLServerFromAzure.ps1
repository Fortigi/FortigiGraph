function Connect-FGSQLServerFromAzure {
    <#
    .SYNOPSIS
    Intelligently connects to an Azure SQL Server by managing firewall rules and retrieving connection details from Azure.

    .DESCRIPTION
    This is a smart wrapper around Connect-FGSQLServer that:
    1. Retrieves SQL Server details from Azure
    2. Checks and updates firewall rules with your current IP
    3. Automatically handles connection with stored credentials
    4. Makes the connection process user-friendly

    .PARAMETER SubscriptionId
    The Azure Subscription ID where the SQL Server exists.

    .PARAMETER ResourceGroupName
    The Resource Group name containing the SQL Server.

    .PARAMETER ServerName
    The SQL Server name (without .database.windows.net suffix).

    .PARAMETER DatabaseName
    The database name. If not specified, uses the first database found or prompts.

    .PARAMETER AdminUsername
    SQL Server admin username. Default: "sqladmin"

    .PARAMETER AdminPassword
    SQL Server admin password (as SecureString). If not provided and not stored, will prompt.

    .PARAMETER UpdateFirewall
    If specified, updates the firewall to allow your current IP address.

    .PARAMETER Force
    If specified, forces a new connection even if already connected.

    .EXAMPLE
    Connect-FGSQLServerFromAzure -SubscriptionId "xxx" -ResourceGroupName "rg-graph" -ServerName "iisqlserver" -UpdateFirewall

    Connects to the SQL Server and updates firewall with your current IP

    .EXAMPLE
    Connect-FGSQLServerFromAzure -SubscriptionId "xxx" -ResourceGroupName "rg-graph" -ServerName "iisqlserver" -DatabaseName "GraphData"

    Connects to a specific database

    .NOTES
    Requires Az PowerShell module and being logged into Azure (Connect-AzAccount)
    #>

    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [System.String]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [System.String]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [System.String]$ServerName,

        [Parameter(Mandatory = $false)]
        [System.String]$DatabaseName,

        [Parameter(Mandatory = $false)]
        [System.String]$AdminUsername = "sqladmin",

        [Parameter(Mandatory = $false)]
        [SecureString]$AdminPassword,

        [Parameter(Mandatory = $false)]
        [Switch]$UpdateFirewall,

        [Parameter(Mandatory = $false)]
        [Switch]$Force
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

        # Update firewall if requested
        if ($UpdateFirewall) {
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
        $result = Connect-FGSQLServer -ServerName $sqlServer.FullyQualifiedDomainName -DatabaseName $DatabaseName -Credential $credential

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
        Write-Host "  1. Check your firewall rules in Azure Portal" -ForegroundColor White
        Write-Host "  2. Try running with -UpdateFirewall switch" -ForegroundColor White
        Write-Host "  3. Verify the SQL admin password is correct" -ForegroundColor White
        Write-Host "  4. Check that the database exists" -ForegroundColor White

        return $false
    }
}
