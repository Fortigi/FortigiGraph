function Invoke-FGSQLQuery {
    <#
    .SYNOPSIS
    Executes a SQL query and returns the results in a simple, easy-to-use format.

    .DESCRIPTION
    A simplified wrapper around Invoke-FGSQLCommand that makes running SQL queries easy.
    Just provide a query string and get back results - no need to write complex scriptblocks.

    This function automatically handles:
    - Connection management (uses stored connection)
    - Result set conversion to PowerShell objects
    - Scalar results (COUNT, SUM, etc.)
    - Non-query commands (INSERT, UPDATE, DELETE)

    .PARAMETER Query
    The SQL query to execute. Can be SELECT, INSERT, UPDATE, DELETE, or any valid T-SQL.

    .PARAMETER AsScalar
    If specified, returns a single scalar value (useful for COUNT, SUM, MAX, etc.)

    .PARAMETER AsNonQuery
    If specified, executes the command and returns the number of rows affected
    (useful for INSERT, UPDATE, DELETE)

    .EXAMPLE
    Invoke-FGSQLQuery -Query "SELECT * FROM dbo.GraphUsers"
    Gets all users and displays them as a table

    .EXAMPLE
    Invoke-FGSQLQuery -Query "SELECT TOP 10 * FROM dbo.GraphUsers ORDER BY displayName"
    Gets the first 10 users sorted by display name

    .EXAMPLE
    $count = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.GraphUsers" -AsScalar
    Gets the total number of users as a single number

    .EXAMPLE
    $users = Invoke-FGSQLQuery -Query "SELECT userPrincipalName, displayName FROM dbo.GraphUsers WHERE accountEnabled = 1"
    Gets enabled users with specific columns

    .EXAMPLE
    Invoke-FGSQLQuery -Query "UPDATE dbo.GraphUsers SET accountEnabled = 0 WHERE userPrincipalName = 'test@example.com'" -AsNonQuery
    Updates a user record

    .NOTES
    - Requires an active SQL connection (use Connect-FGSQLServer first)
    - Returns a DataTable for SELECT queries (default)
    - Returns scalar value for aggregates when -AsScalar is used
    - Returns rows affected when -AsNonQuery is used
    #>
    [CmdletBinding(DefaultParameterSetName = 'Table')]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Query,

        [Parameter(Mandatory = $false, ParameterSetName = 'Scalar')]
        [switch]$AsScalar,

        [Parameter(Mandatory = $false, ParameterSetName = 'NonQuery')]
        [switch]$AsNonQuery
    )

    # Check if connected
    if (-not $global:FGSQLConnectionString) {
        Write-Error "Not connected to SQL Server. Use Connect-FGSQLServer first."
        return
    }

    try {
        if ($AsScalar) {
            # Execute as scalar (returns single value)
            $result = Invoke-FGSQLCommand -ScriptBlock {
                param($connection)
                $cmd = $connection.CreateCommand()
                $cmd.CommandText = $Query
                return $cmd.ExecuteScalar()
            }
            return $result
        }
        elseif ($AsNonQuery) {
            # Execute as non-query (returns rows affected)
            $result = Invoke-FGSQLCommand -ScriptBlock {
                param($connection)
                $cmd = $connection.CreateCommand()
                $cmd.CommandText = $Query
                return $cmd.ExecuteNonQuery()
            }
            return $result
        }
        else {
            # Execute as table query (default)
            $result = Invoke-FGSQLCommand -ScriptBlock {
                param($connection)
                $cmd = $connection.CreateCommand()
                $cmd.CommandText = $Query

                $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
                $dataset = New-Object System.Data.DataSet
                $adapter.Fill($dataset) | Out-Null

                return $dataset.Tables[0]
            }
            return $result
        }
    }
    catch {
        Write-Error "Query execution failed: $_"
        Write-Host "`nQuery was:" -ForegroundColor Yellow
        Write-Host $Query -ForegroundColor Gray
        throw
    }
}
