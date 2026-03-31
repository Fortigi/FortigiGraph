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
        $info = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)

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
            try {
                if ($reader.Read()) {
                    return @{
                        Server = $global:FGSQLServerName
                        Database = $reader["DatabaseName"]
                        Version = $reader["Version"]
                        Edition = $reader["Edition"]
                        CurrentTime = $reader["CurrentTime"]
                        ConnectionStatus = "Connected"
                    }
                }
            }
            finally {
                $reader.Close()
            }
        }

        if ($info) {
            Write-Host "SQL Connection Test: SUCCESS" -ForegroundColor Green
            Write-Host "  Server: $($info.Server)" -ForegroundColor Cyan
            Write-Host "  Database: $($info.Database)" -ForegroundColor Cyan
            Write-Host "  Version: $($info.Version)" -ForegroundColor Cyan
            Write-Host "  Edition: $($info.Edition)" -ForegroundColor Cyan
            Write-Host "  Server Time: $($info.CurrentTime)" -ForegroundColor Cyan

            return $info
        }

        return $false
    }
    catch {
        Write-Error "SQL Connection Test: FAILED - $_"
        return $false
    }
}
