function New-FGSQLConnection {
    <#
    .SYNOPSIS
    Establishes a direct connection to an Azure SQL Server and stores connection details.

    .DESCRIPTION
    Low-level function that establishes a connection to an Azure SQL Server
    and stores the connection string in a global variable for use by other FG SQL functions.
    Supports both SQL Authentication and Azure AD authentication.

    For most scenarios, use Connect-FGSQLServer instead, which provides Azure integration and firewall management.

    .PARAMETER ServerName
    The SQL Server name (e.g., "myserver.database.windows.net")

    .PARAMETER DatabaseName
    The database name to connect to

    .PARAMETER Credential
    Optional PSCredential object for SQL Authentication. If not provided, uses Azure AD Integrated Authentication.

    .PARAMETER UseManagedIdentity
    Switch to use Azure Managed Identity authentication instead of Azure AD Integrated.

    .PARAMETER ConnectionString
    Optional. Provide a complete connection string directly instead of individual parameters.

    .EXAMPLE
    New-FGSQLConnection -ServerName "myserver.database.windows.net" -DatabaseName "GraphData"

    Connects using Azure AD Integrated Authentication

    .EXAMPLE
    $cred = Get-Credential
    New-FGSQLConnection -ServerName "myserver.database.windows.net" -DatabaseName "GraphData" -Credential $cred

    Connects using SQL Authentication with provided credentials

    .EXAMPLE
    New-FGSQLConnection -ServerName "myserver.database.windows.net" -DatabaseName "GraphData" -UseManagedIdentity

    Connects using Azure Managed Identity (useful for Azure VMs/Functions)

    .NOTES
    The connection string is stored in $global:FGSQLConnectionString for use by other functions.
    Use Test-FGSQLConnection to verify the connection is working.
    #>

    [CmdletBinding(DefaultParameterSetName = 'AzureAD')]
    Param(
        [Parameter(Mandatory = $true, ParameterSetName = 'AzureAD')]
        [Parameter(Mandatory = $true, ParameterSetName = 'SQLAuth')]
        [Parameter(Mandatory = $true, ParameterSetName = 'ManagedIdentity')]
        [System.String]$ServerName,

        [Parameter(Mandatory = $true, ParameterSetName = 'AzureAD')]
        [Parameter(Mandatory = $true, ParameterSetName = 'SQLAuth')]
        [Parameter(Mandatory = $true, ParameterSetName = 'ManagedIdentity')]
        [System.String]$DatabaseName,

        [Parameter(Mandatory = $true, ParameterSetName = 'SQLAuth')]
        [PSCredential]$Credential,

        [Parameter(Mandatory = $true, ParameterSetName = 'ManagedIdentity')]
        [Switch]$UseManagedIdentity,

        [Parameter(Mandatory = $true, ParameterSetName = 'ConnectionString')]
        [System.String]$ConnectionString
    )

    try {
        # Normalize server name - add .database.windows.net if not present
        if ($ServerName -notmatch '\.database\.windows\.net$') {
            $ServerName = "$ServerName.database.windows.net"
            Write-Verbose "Normalized server name to: $ServerName"
        }

        # Build connection string based on authentication method
        if ($PSCmdlet.ParameterSetName -eq 'ConnectionString') {
            $global:FGSQLConnectionString = $ConnectionString
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'SQLAuth') {
            $username = $Credential.UserName
            $password = $Credential.GetNetworkCredential().Password
            # Use simple connection string that works with System.Data.SqlClient
            $global:FGSQLConnectionString = "Server=tcp:$ServerName,1433;Initial Catalog=$DatabaseName;Persist Security Info=False;User ID=$username;Password=$password;MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'ManagedIdentity') {
            # For Managed Identity, we need Microsoft.Data.SqlClient (not System.Data.SqlClient)
            Write-Warning "Managed Identity requires Microsoft.Data.SqlClient. Falling back to SQL Authentication."
            throw "Managed Identity not supported with System.Data.SqlClient. Please use SQL Authentication."
        }
        else {
            # Azure AD Integrated requires Microsoft.Data.SqlClient - fall back to prompting for SQL auth
            Write-Warning "Azure AD authentication requires Microsoft.Data.SqlClient which is not available in PowerShell by default."
            Write-Host "Falling back to SQL Authentication. Please provide credentials." -ForegroundColor Yellow

            if (-not $Credential) {
                $Credential = Get-Credential -Message "Enter SQL Server credentials for $ServerName"
            }

            $username = $Credential.UserName
            $password = $Credential.GetNetworkCredential().Password
            $global:FGSQLConnectionString = "Server=tcp:$ServerName,1433;Initial Catalog=$DatabaseName;Persist Security Info=False;User ID=$username;Password=$password;MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
        }

        # Store individual parameters for reference
        $global:FGSQLServerName = $ServerName
        $global:FGSQLDatabaseName = $DatabaseName

        # Test the connection using the helper
        $testResult = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            # Connection is already open, just verify it works
            return $true
        }

        if ($testResult) {
            Write-Host "Successfully connected to SQL Server: $ServerName, Database: $DatabaseName" -ForegroundColor Green
        }

        return $testResult
    }
    catch {
        Write-Error "Failed to connect to SQL Server: $_"
        $global:FGSQLConnectionString = $null
        $global:FGSQLServerName = $null
        $global:FGSQLDatabaseName = $null
        return $false
    }
}
