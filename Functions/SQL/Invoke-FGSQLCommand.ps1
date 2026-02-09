function Invoke-FGSQLCommand {
    <#
    .SYNOPSIS
    Internal helper function that manages SQL connection lifecycle for all FG SQL functions.

    .DESCRIPTION
    This function provides a centralized way to execute SQL operations with proper connection
    management, error handling, and cleanup. It eliminates code duplication across SQL functions.

    The ScriptBlock parameter receives a SqlConnection object that is already open and ready to use.
    The helper ensures proper cleanup even if errors occur.

    .PARAMETER ScriptBlock
    A script block that receives the SQL connection as a parameter and performs operations.
    The connection is already open when passed to the script block.

    .PARAMETER RequireConnection
    If specified, throws an error if not connected to SQL Server. Default: $true

    .EXAMPLE
    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = "SELECT COUNT(*) FROM Users"
        return $cmd.ExecuteScalar()
    }

    Executes a scalar query and returns the result

    .EXAMPLE
    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = "CREATE TABLE Test (Id INT)"
        $cmd.ExecuteNonQuery()
    }

    Executes a non-query command

    .NOTES
    This is an internal helper function used by other FG SQL functions.
    It handles connection open/close/dispose and error handling automatically.
    #>

    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [ScriptBlock]$ScriptBlock,

        [Parameter(Mandatory = $false)]
        [bool]$RequireConnection = $true
    )

    # Check if connected
    if ($RequireConnection -and -not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    $connection = $null
    try {
        # Create and open connection
        $connection = New-Object System.Data.SqlClient.SqlConnection($global:FGSQLConnectionString)
        $connection.Open()

        # Execute the provided script block with the connection
        $result = & $ScriptBlock $connection

        return $result
    }
    catch {
        # Re-throw with context
        throw "SQL command execution failed: $_"
    }
    finally {
        # Always clean up connection
        if ($connection -and $connection.State -eq 'Open') {
            $connection.Close()
        }
        if ($connection) {
            $connection.Dispose()
        }
    }
}
