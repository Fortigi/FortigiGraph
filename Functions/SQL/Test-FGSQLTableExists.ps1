function Test-FGSQLTableExists {
    <#
    .SYNOPSIS
    Checks if a table exists in the connected SQL database.

    .DESCRIPTION
    Returns $true if the table exists, $false otherwise.

    .PARAMETER TableName
    Name of the table to check (without schema prefix)

    .PARAMETER Schema
    Database schema name. Default: 'dbo'

    .EXAMPLE
    if (Test-FGSQLTableExists -TableName "GraphUsers") {
        Write-Host "Table exists"
    }

    .NOTES
    Requires an active SQL connection via Connect-FGSQLServer
    #>

    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$TableName,

        [Parameter(Mandatory = $false)]
        [string]$Schema = 'dbo'
    )

    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        $checkTableCmd = $connection.CreateCommand()
        $checkTableCmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = @TableName AND TABLE_SCHEMA = @Schema"
        $checkTableCmd.Parameters.AddWithValue("@TableName", $TableName) | Out-Null
        $checkTableCmd.Parameters.AddWithValue("@Schema", $Schema) | Out-Null

        return ([int]$checkTableCmd.ExecuteScalar() -gt 0)
    }
}
