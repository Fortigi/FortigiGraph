function Test-FGSQLConnection {
    <#
    .SYNOPSIS
    Tests the connection to SQL Server using stored connection details.

    .DESCRIPTION
    Verifies that the SQL Server connection established with Connect-FGSQLServer is still valid
    and can execute queries. Returns connection information.

    .EXAMPLE
    Test-FGSQLConnection

    Tests the current SQL connection and displays connection details

    .NOTES
    Requires Connect-FGSQLServer to be called first.
    #>

    [CmdletBinding()]
    Param()

    if (-not $global:FGSQLConnectionString) {
        Write-Warning "Not connected to SQL Server. Please run Connect-FGSQLServer first."
        return $false
    }

    try {
        $connection = New-Object System.Data.SqlClient.SqlConnection($global:FGSQLConnectionString)
        $connection.Open()

        # Get SQL Server version and database info
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = @"
SELECT
    SERVERPROPERTY('ProductVersion') AS Version,
    SERVERPROPERTY('Edition') AS Edition,
    DB_NAME() AS DatabaseName,
    GETDATE() AS CurrentTime
"@

        $reader = $cmd.ExecuteReader()
        if ($reader.Read()) {
            $info = @{
                Server = $global:FGSQLServerName
                Database = $reader["DatabaseName"]
                Version = $reader["Version"]
                Edition = $reader["Edition"]
                CurrentTime = $reader["CurrentTime"]
                ConnectionStatus = "Connected"
            }

            Write-Host "SQL Connection Test: SUCCESS" -ForegroundColor Green
            Write-Host "  Server: $($info.Server)" -ForegroundColor Cyan
            Write-Host "  Database: $($info.Database)" -ForegroundColor Cyan
            Write-Host "  Version: $($info.Version)" -ForegroundColor Cyan
            Write-Host "  Edition: $($info.Edition)" -ForegroundColor Cyan
            Write-Host "  Server Time: $($info.CurrentTime)" -ForegroundColor Cyan

            $reader.Close()
            $connection.Close()
            $connection.Dispose()

            return $info
        }
    }
    catch {
        Write-Error "SQL Connection Test: FAILED - $_"
        if ($connection.State -eq 'Open') {
            $connection.Close()
            $connection.Dispose()
        }
        return $false
    }
}
