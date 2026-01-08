function Invoke-FGSQLBulkCopy {
    <#
    .SYNOPSIS
    Performs a high-performance bulk copy operation to SQL Server using SqlBulkCopy.

    .DESCRIPTION
    This function provides a high-performance way to insert large amounts of data into SQL Server.
    It uses the SqlBulkCopy class which is optimized for bulk operations and can handle millions
    of rows efficiently without generating massive SQL statements.

    This is the recommended approach for syncing large datasets from Microsoft Graph to SQL,
    as it avoids timeout issues caused by massive VALUES clauses.

    .PARAMETER DataTable
    The DataTable containing the data to bulk copy. Must have columns matching the destination table schema.

    .PARAMETER DestinationTableName
    The name of the destination table in SQL Server. Can be a temp table (##TableName) or regular table.

    .PARAMETER Connection
    Optional SQL connection to use. If not provided, uses the global connection.

    .PARAMETER Transaction
    Optional SQL transaction to use for the bulk copy operation.

    .PARAMETER BatchSize
    Number of rows to copy in each batch. Default is 10000. Larger batches are faster but use more memory.

    .PARAMETER Timeout
    Timeout in seconds for the bulk copy operation. Default is 600 (10 minutes).

    .EXAMPLE
    # Create a DataTable and bulk copy
    $dataTable = New-Object System.Data.DataTable
    $dataTable.Columns.Add("id", [guid])
    $dataTable.Columns.Add("displayName", [string])

    foreach ($user in $users) {
        $row = $dataTable.NewRow()
        $row["id"] = $user.id
        $row["displayName"] = $user.displayName
        $dataTable.Rows.Add($row)
    }

    Invoke-FGSQLBulkCopy -DataTable $dataTable -DestinationTableName "GraphUsers" -Transaction $transaction

    .NOTES
    This function is designed to be used within Invoke-FGSQLCommand for automatic connection management.
    For optimal performance with temporal tables:
    1. Bulk copy to a temp table
    2. MERGE from temp table to target table
    3. This avoids generating massive SQL statements
    #>

    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [System.Data.DataTable]$DataTable,

        [Parameter(Mandatory = $true)]
        [string]$DestinationTableName,

        [Parameter(Mandatory = $false)]
        [System.Data.SqlClient.SqlConnection]$Connection,

        [Parameter(Mandatory = $false)]
        [System.Data.SqlClient.SqlTransaction]$Transaction,

        [Parameter(Mandatory = $false)]
        [int]$BatchSize = 10000,

        [Parameter(Mandatory = $false)]
        [int]$Timeout = 600
    )

    # Use provided connection or create new one from global connection string
    if (-not $Connection) {
        if (-not $global:FGSQLConnectionString) {
            throw "No SQL connection available. Please run Connect-FGSQLServer first."
        }
        $Connection = New-Object System.Data.SqlClient.SqlConnection($global:FGSQLConnectionString)
        $Connection.Open()
        $shouldCloseConnection = $true
    }

    try {
        # Create SqlBulkCopy with options
        $bulkCopyOptions = [System.Data.SqlClient.SqlBulkCopyOptions]::Default

        if ($Transaction) {
            $bulkCopy = New-Object System.Data.SqlClient.SqlBulkCopy($Connection, $bulkCopyOptions, $Transaction)
        }
        else {
            $bulkCopy = New-Object System.Data.SqlClient.SqlBulkCopy($Connection)
        }

        $bulkCopy.DestinationTableName = $DestinationTableName
        $bulkCopy.BatchSize = $BatchSize
        $bulkCopy.BulkCopyTimeout = $Timeout

        # Map columns automatically (assumes column names match)
        foreach ($column in $DataTable.Columns) {
            $bulkCopy.ColumnMappings.Add($column.ColumnName, $column.ColumnName) | Out-Null
        }

        # Perform the bulk copy
        Write-Verbose "Bulk copying $($DataTable.Rows.Count) rows to $DestinationTableName..."
        $bulkCopy.WriteToServer($DataTable)
        Write-Verbose "Bulk copy completed successfully"

        $bulkCopy.Close()
    }
    catch {
        throw "Bulk copy failed: $_"
    }
    finally {
        if ($shouldCloseConnection -and $Connection) {
            $Connection.Close()
            $Connection.Dispose()
        }
    }
}
