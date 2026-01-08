function Get-FGSQLTableSchema {
    <#
    .SYNOPSIS
    Gets the existing column schema for a SQL table.

    .DESCRIPTION
    Returns a list of column names for the specified table, useful for detecting
    schema differences before adding new columns.

    .PARAMETER TableName
    Name of the table to inspect (without schema prefix)

    .PARAMETER Schema
    Database schema name. Default: 'dbo'

    .EXAMPLE
    $columns = Get-FGSQLTableSchema -TableName "GraphUsers"

    Returns array of column names from the GraphUsers table

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

        $getColumnsCmd = $connection.CreateCommand()
        $getColumnsCmd.CommandText = "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = @TableName AND TABLE_SCHEMA = @Schema"
        $getColumnsCmd.Parameters.AddWithValue("@TableName", $TableName) | Out-Null
        $getColumnsCmd.Parameters.AddWithValue("@Schema", $Schema) | Out-Null

        $reader = $getColumnsCmd.ExecuteReader()
        try {
            $columns = @()
            while ($reader.Read()) {
                $columns += $reader.GetString(0)
            }
            return $columns
        }
        finally {
            $reader.Close()
        }
    }
}
