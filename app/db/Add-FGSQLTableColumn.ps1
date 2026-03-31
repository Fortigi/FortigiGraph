function Add-FGSQLTableColumn {
    <#
    .SYNOPSIS
    Adds new columns to an existing temporal table with proper version control handling.

    .DESCRIPTION
    This helper function adds columns to both the main table and history table, handling
    temporal table system versioning correctly. It temporarily disables versioning during
    the schema change and re-enables it afterward.

    .PARAMETER TableName
    Name of the table to modify (without schema prefix)

    .PARAMETER Columns
    Hashtable of column names and their SQL data types (e.g., @{'newCol' = 'NVARCHAR(255)'})

    .EXAMPLE
    Add-FGSQLTableColumn -TableName "GraphUsers" -Columns @{'city' = 'NVARCHAR(255)'; 'state' = 'NVARCHAR(255)'}

    Adds city and state columns to GraphUsers and GraphUsersHistory tables

    .NOTES
    Requires an active SQL connection via Connect-FGSQLServer
    #>

    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$TableName,

        [Parameter(Mandatory = $true)]
        [hashtable]$Columns
    )

    if ($Columns.Count -eq 0) {
        Write-Verbose "No columns to add"
        return
    }

    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Adding $($Columns.Count) column(s) to table '$TableName'..." -ForegroundColor Cyan

        # Disable system versioning
        $disableVersioningCmd = $connection.CreateCommand()
        $disableVersioningCmd.CommandTimeout = 120
        $disableVersioningCmd.CommandText = "ALTER TABLE dbo.$TableName SET (SYSTEM_VERSIONING = OFF);"
        $disableVersioningCmd.ExecuteNonQuery() | Out-Null

        # Add each column to main table and history table
        foreach ($colName in $Columns.Keys) {
            $sqlType = $Columns[$colName]
            Write-Host "    [$(Get-Date -Format 'HH:mm:ss')] Adding column: $colName ($sqlType)" -ForegroundColor Gray

            # Add to main table
            $addColumnCmd = $connection.CreateCommand()
            $addColumnCmd.CommandTimeout = 120
            $addColumnCmd.CommandText = "ALTER TABLE dbo.$TableName ADD [$colName] $sqlType NULL;"
            $addColumnCmd.ExecuteNonQuery() | Out-Null

            # Add to history table
            $addHistoryColumnCmd = $connection.CreateCommand()
            $addHistoryColumnCmd.CommandTimeout = 120
            $addHistoryColumnCmd.CommandText = "ALTER TABLE dbo.${TableName}History ADD [$colName] $sqlType NULL;"
            $addHistoryColumnCmd.ExecuteNonQuery() | Out-Null
        }

        # Re-enable system versioning
        $enableVersioningCmd = $connection.CreateCommand()
        $enableVersioningCmd.CommandTimeout = 120
        $enableVersioningCmd.CommandText = "ALTER TABLE dbo.$TableName SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.${TableName}History));"
        $enableVersioningCmd.ExecuteNonQuery() | Out-Null

        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Schema updated successfully" -ForegroundColor Green
    }
}
