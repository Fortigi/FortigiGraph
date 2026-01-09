function Invoke-FGSQLBulkMerge {
    <#
    .SYNOPSIS
    Performs a high-performance bulk MERGE operation using temp table pattern.

    .DESCRIPTION
    This function efficiently handles INSERT/UPDATE operations for large datasets by:
    1. Creating a temp table matching the target table schema
    2. Bulk copying data to the temp table (very fast)
    3. Executing a MERGE statement from temp table to target table
    4. Cleaning up the temp table

    This approach is 10-50x faster than row-by-row MERGE operations and avoids timeout
    issues caused by massive VALUES clauses.

    .PARAMETER Connection
    SQL connection to use for the operation.

    .PARAMETER Transaction
    SQL transaction to use for the operation.

    .PARAMETER TargetTableName
    The target table to MERGE into.

    .PARAMETER DataTable
    DataTable containing the data to MERGE. Column names must match target table.

    .PARAMETER KeyColumns
    Array of column names that form the primary key (e.g., @('id') or @('groupId', 'memberId')).

    .PARAMETER UpdateColumns
    Optional array of columns to update on MATCH. If not specified, all non-key columns are updated.

    .EXAMPLE
    # Bulk merge users
    Invoke-FGSQLBulkMerge `
        -Connection $connection `
        -Transaction $transaction `
        -TargetTableName "GraphUsers" `
        -DataTable $usersDataTable `
        -KeyColumns @('id')

    .EXAMPLE
    # Bulk merge group memberships
    Invoke-FGSQLBulkMerge `
        -Connection $connection `
        -Transaction $transaction `
        -TargetTableName "GraphGroupMembers" `
        -DataTable $membershipsDataTable `
        -KeyColumns @('groupId', 'memberId')

    .NOTES
    This function is the recommended approach for syncing large datasets (10K+ records).
    Performance improvement: 10-50x faster than row-by-row operations.
    #>

    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [System.Data.SqlClient.SqlConnection]$Connection,

        [Parameter(Mandatory = $true)]
        [System.Data.SqlClient.SqlTransaction]$Transaction,

        [Parameter(Mandatory = $true)]
        [string]$TargetTableName,

        [Parameter(Mandatory = $true)]
        [System.Data.DataTable]$DataTable,

        [Parameter(Mandatory = $true)]
        [string[]]$KeyColumns,

        [Parameter(Mandatory = $false)]
        [string[]]$UpdateColumns
    )

    if ($DataTable.Rows.Count -eq 0) {
        Write-Verbose "No rows to merge, skipping operation"
        return @{
            Inserted = 0
            Updated = 0
        }
    }

    # Create temp table name
    $tempTableName = "##TempMerge_" + [guid]::NewGuid().ToString("N")

    Write-Verbose "Creating temp table $tempTableName for bulk merge of $($DataTable.Rows.Count) records..."

    try {
        # Build CREATE TABLE statement based on DataTable columns
        $columnDefs = @()

        foreach ($column in $DataTable.Columns) {
            $sqlType = switch ($column.DataType.Name) {
                "Guid" { "UNIQUEIDENTIFIER" }
                "String" { "NVARCHAR(MAX)" }
                "Boolean" { "BIT" }
                "DateTime" { "DATETIME2" }
                "Int32" { "INT" }
                "Int64" { "BIGINT" }
                default { "NVARCHAR(MAX)" }
            }

            $columnDefs += "$($column.ColumnName) $sqlType"
        }

        $createTableSQL = @"
CREATE TABLE $tempTableName (
    $($columnDefs -join ",`n    ")
)
"@

        # Create temp table
        $cmd = $Connection.CreateCommand()
        $cmd.Transaction = $Transaction
        $cmd.CommandText = $createTableSQL
        $cmd.ExecuteNonQuery() | Out-Null

        # Bulk copy to temp table
        Write-Verbose "Bulk copying $($DataTable.Rows.Count) rows to temp table..."

        $bulkCopy = New-Object System.Data.SqlClient.SqlBulkCopy($Connection, [System.Data.SqlClient.SqlBulkCopyOptions]::Default, $Transaction)
        $bulkCopy.DestinationTableName = $tempTableName
        $bulkCopy.BatchSize = 10000
        $bulkCopy.BulkCopyTimeout = 300

        foreach ($column in $DataTable.Columns) {
            $bulkCopy.ColumnMappings.Add($column.ColumnName, $column.ColumnName) | Out-Null
        }

        $bulkCopy.WriteToServer($DataTable)
        $bulkCopy.Close()

        Write-Verbose "Bulk copy completed, executing MERGE statement..."

        # Determine which columns to update
        if (-not $UpdateColumns) {
            $UpdateColumns = $DataTable.Columns | Where-Object { $_.ColumnName -notin $KeyColumns } | ForEach-Object { $_.ColumnName }
        }

        # Build MERGE statement
        $keyConditions = ($KeyColumns | ForEach-Object { "target.$_ = source.$_" }) -join " AND "
        $insertColumns = ($DataTable.Columns | ForEach-Object { $_.ColumnName }) -join ", "
        $insertValues = ($DataTable.Columns | ForEach-Object { "source.$($_.ColumnName)" }) -join ", "

        # Build MERGE with or without UPDATE clause depending on whether there are non-key columns
        if ($UpdateColumns -and $UpdateColumns.Count -gt 0) {
            $updateAssignments = ($UpdateColumns | ForEach-Object { "$_ = source.$_" }) -join ", `n        "
            $mergeSQL = @"
MERGE dbo.$TargetTableName AS target
USING $tempTableName AS source
ON $keyConditions
WHEN MATCHED THEN
    UPDATE SET
        $updateAssignments
WHEN NOT MATCHED BY TARGET THEN
    INSERT ($insertColumns)
    VALUES ($insertValues)
OUTPUT `$action;
"@
        }
        else {
            # No non-key columns to update - skip UPDATE clause (table has only key columns)
            $mergeSQL = @"
MERGE dbo.$TargetTableName AS target
USING $tempTableName AS source
ON $keyConditions
WHEN NOT MATCHED BY TARGET THEN
    INSERT ($insertColumns)
    VALUES ($insertValues)
OUTPUT `$action;
"@
        }

        $cmd.CommandText = $mergeSQL
        $cmd.CommandTimeout = 300

        # Execute MERGE and count operations
        $reader = $cmd.ExecuteReader()

        $insertCount = 0
        $updateCount = 0

        while ($reader.Read()) {
            $action = $reader.GetString(0)
            if ($action -eq "INSERT") {
                $insertCount++
            }
            elseif ($action -eq "UPDATE") {
                $updateCount++
            }
        }

        $reader.Close()

        Write-Verbose "MERGE completed: $insertCount inserted, $updateCount updated"

        # Cleanup temp table
        $cmd.CommandText = "DROP TABLE $tempTableName"
        $cmd.ExecuteNonQuery() | Out-Null

        $cmd.Dispose()

        return @{
            Inserted = $insertCount
            Updated = $updateCount
        }
    }
    catch {
        # Try to cleanup temp table if it exists
        try {
            $cleanupCmd = $Connection.CreateCommand()
            $cleanupCmd.Transaction = $Transaction
            $cleanupCmd.CommandText = "IF OBJECT_ID('tempdb..$tempTableName') IS NOT NULL DROP TABLE $tempTableName"
            $cleanupCmd.ExecuteNonQuery() | Out-Null
            $cleanupCmd.Dispose()
        }
        catch {
            # Ignore cleanup errors
        }

        throw "Bulk merge failed: $_"
    }
}
