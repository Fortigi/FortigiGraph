function New-FGSQLReadOnlyUser {
    <#
    .SYNOPSIS
    Creates a read-only SQL user for Power BI or other reporting tools.

    .DESCRIPTION
    Creates a new SQL user with db_datareader role, suitable for Power BI
    connections or other read-only access scenarios. Generates a secure
    random password and outputs the credentials.

    .PARAMETER Username
    The username to create. Default: "PowerBIReader"

    .PARAMETER ConfigFile
    Path to a JSON config file containing SQL connection details.
    If not provided, uses the existing SQL connection.

    .PARAMETER PasswordLength
    Length of the generated password. Default: 32

    .EXAMPLE
    New-FGSQLReadOnlyUser

    Creates a user named "PowerBIReader" with a random password.

    .EXAMPLE
    New-FGSQLReadOnlyUser -Username "ReportingUser"

    Creates a user with a custom name.

    .EXAMPLE
    New-FGSQLReadOnlyUser -ConfigFile ".\config.json" -Username "PowerBI_Prod"

    Connects using config file and creates the specified user.

    .NOTES
    Requires an active SQL connection with admin privileges.
    The password is displayed once - save it securely!
    #>

    [CmdletBinding()]
    [Alias("New-SQLReadOnlyUser")]
    Param(
        [Parameter(Mandatory = $false)]
        [string]$Username = "PowerBIReader",

        [Parameter(Mandatory = $false)]
        [string]$ConfigFile,

        [Parameter(Mandatory = $false)]
        [int]$PasswordLength = 32
    )

    # Handle connection
    $needsDisconnect = $false

    if ($ConfigFile) {
        if (-not (Test-Path $ConfigFile)) {
            throw "Config file not found: $ConfigFile"
        }

        $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json

        # Check if already connected to the same server
        $targetServer = $config.Azure.SQLServerName
        if ($global:FGSQLServerName -ne $targetServer) {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Connecting to SQL Server..." -ForegroundColor Cyan
            Connect-FGSQLServer -ConfigFile $ConfigFile -SkipFirewallUpdate | Out-Null
            $needsDisconnect = $true
        }
    }
    elseif (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first or provide -ConfigFile."
    }

    # Generate secure random password
    # Use a mix of uppercase, lowercase, numbers, and special characters
    $uppercase = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    $lowercase = 'abcdefghijklmnopqrstuvwxyz'
    $numbers = '0123456789'
    $special = '!@#$%^&*'
    $allChars = $uppercase + $lowercase + $numbers + $special

    # Ensure at least one of each type
    $password = @(
        $uppercase[(Get-Random -Maximum $uppercase.Length)]
        $lowercase[(Get-Random -Maximum $lowercase.Length)]
        $numbers[(Get-Random -Maximum $numbers.Length)]
        $special[(Get-Random -Maximum $special.Length)]
    )

    # Fill the rest randomly
    for ($i = 4; $i -lt $PasswordLength; $i++) {
        $password += $allChars[(Get-Random -Maximum $allChars.Length)]
    }

    # Shuffle the password
    $password = ($password | Get-Random -Count $password.Count) -join ''

    # Validate username to prevent SQL injection in DDL statements
    # DDL (CREATE USER, ALTER USER) cannot use parameterized queries
    if ($Username -notmatch '^[a-zA-Z0-9_]+$') {
        throw "Username must contain only letters, numbers, and underscores (got: '$Username')"
    }

    # Escape single quotes in password for safe embedding in DDL
    # Password is generated internally (not user-supplied) but defense-in-depth
    $escapedPassword = $password.Replace("'", "''")

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Creating read-only user '$Username'..." -ForegroundColor Cyan

    try {
        $connection = New-Object System.Data.SqlClient.SqlConnection($global:FGSQLConnectionString)
        $connection.Open()

        # Check if user already exists (parameterized - safe)
        $checkQuery = "SELECT COUNT(*) FROM sys.database_principals WHERE name = @Username"
        $checkCmd = $connection.CreateCommand()
        $checkCmd.CommandText = $checkQuery
        $checkCmd.Parameters.AddWithValue("@Username", $Username) | Out-Null
        $userExists = $checkCmd.ExecuteScalar() -gt 0

        if ($userExists) {
            Write-Warning "User '$Username' already exists. Resetting password..."

            # DDL cannot be parameterized; username validated above, password escaped
            $alterQuery = "ALTER USER [$Username] WITH PASSWORD = N'$escapedPassword'"
            $alterCmd = $connection.CreateCommand()
            $alterCmd.CommandText = $alterQuery
            $alterCmd.ExecuteNonQuery() | Out-Null

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Password reset for existing user '$Username'" -ForegroundColor Green
        }
        else {
            # DDL cannot be parameterized; username validated above, password escaped
            $createQuery = "CREATE USER [$Username] WITH PASSWORD = N'$escapedPassword'"
            $createCmd = $connection.CreateCommand()
            $createCmd.CommandText = $createQuery
            $createCmd.ExecuteNonQuery() | Out-Null

            # Add to db_datareader role (username validated above)
            $roleQuery = "ALTER ROLE db_datareader ADD MEMBER [$Username]"
            $roleCmd = $connection.CreateCommand()
            $roleCmd.CommandText = $roleQuery
            $roleCmd.ExecuteNonQuery() | Out-Null

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] User '$Username' created with db_datareader role" -ForegroundColor Green
        }

        $connection.Close()
        $connection.Dispose()

        # Build connection string for Power BI
        $serverName = $global:FGSQLServerName
        $databaseName = $global:FGSQLDatabaseName

        # Output credentials
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "Read-Only SQL User Created" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "Server:   $serverName.database.windows.net" -ForegroundColor White
        Write-Host "Database: $databaseName" -ForegroundColor White
        Write-Host "Username: $Username" -ForegroundColor White
        Write-Host "Password: $password" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Power BI Connection String:" -ForegroundColor Cyan
        Write-Host "Server=tcp:$serverName.database.windows.net,1433;Initial Catalog=$databaseName;User ID=$Username;Password=$password;Encrypt=True;TrustServerCertificate=False;" -ForegroundColor Gray
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "SAVE THIS PASSWORD - it won't be shown again!" -ForegroundColor Red
        Write-Host "========================================" -ForegroundColor Green
        Write-Host ""

        return [PSCustomObject]@{
            Server = "$serverName.database.windows.net"
            Database = $databaseName
            Username = $Username
            Password = $password
            ConnectionString = "Server=tcp:$serverName.database.windows.net,1433;Initial Catalog=$databaseName;User ID=$Username;Password=$password;Encrypt=True;TrustServerCertificate=False;"
        }
    }
    catch {
        throw "Failed to create read-only user: $_"
    }
}
