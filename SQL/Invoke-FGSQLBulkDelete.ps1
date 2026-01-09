function Invoke-FGSQLBulkDelete {
    <#
    .SYNOPSIS
    Deletes records from a table that don't exist in the provided data set using a temp table approach.

    .DESCRIPTION
    This function efficiently handles deletion of records that no longer exist in the source data.
    Instead of generating massive SQL VALUES clauses (which cause timeouts), it:
    1. Creates a temp table
    2. Bulk inserts current records into the temp table
    3. Deletes from target table where records don't exist in temp table
    4. Cleans up temp table

    This avoids timeout issues when dealing with hundreds of thousands of records.

    .PARAMETER Connection
    SQL connection to use for the operation.

    .PARAMETER Transaction
    Optional SQL transaction to use.

    .PARAMETER TargetTableName
    The table to delete records from.

    .PARAMETER CurrentData
    Array or DataTable of current records. Used to determine what should NOT be deleted.

    .PARAMETER KeyColumns
    Array of column names that form the primary key (e.g., @('groupId', 'memberId')).

    .PARAMETER DataTable
    Optional pre-built DataTable of current records. If not provided, will be built from CurrentData.

    .EXAMPLE
    # Delete memberships that no longer exist
    Invoke-FGSQLBulkDelete `
        -Connection $connection `
        -Transaction $transaction `
        -TargetTableName "GraphGroupMembers" `
        -CurrentData $allMemberships `
        -KeyColumns @('groupId', 'memberId')

    .NOTES
    This function is designed to work with large datasets (100K+ records) without timeout issues.
    #>

    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [System.Data.SqlClient.SqlConnection]$Connection,

        [Parameter(Mandatory = $false)]
        [System.Data.SqlClient.SqlTransaction]$Transaction,

        [Parameter(Mandatory = $true)]
        [string]$TargetTableName,

        [Parameter(Mandatory = $false)]
        $CurrentData,

        [Parameter(Mandatory = $true)]
        [string[]]$KeyColumns,

        [Parameter(Mandatory = $false)]
        [System.Data.DataTable]$DataTable
    )

    if ((-not $CurrentData -or $CurrentData.Count -eq 0) -and -not $DataTable) {
        Write-Verbose "No current data provided, skipping bulk delete"
        return 0
    }

    # Create temp table name
    $tempTableName = "##TempDelete_" + [guid]::NewGuid().ToString("N")

    Write-Verbose "Creating temp table $tempTableName for bulk delete operation..."

    try {
        # Build column list and CREATE TABLE statement
        # We only need the key columns in the temp table
        $columnDefs = @()

        foreach ($keyCol in $KeyColumns) {
            # Determine column type by looking at target table
            $columnDefs += "$keyCol UNIQUEIDENTIFIER"
        }

        $createTableSQL = @"
CREATE TABLE $tempTableName (
    $($columnDefs -join ",`n    ")
)
"@

        # Create temp table
        $cmd = $Connection.CreateCommand()
        if ($Transaction) {
            $cmd.Transaction = $Transaction
        }
        $cmd.CommandText = $createTableSQL
        $cmd.ExecuteNonQuery() | Out-Null

        # Build DataTable if not provided
        if (-not $DataTable) {
            $dt = New-Object System.Data.DataTable
            foreach ($keyCol in $KeyColumns) {
                $dt.Columns.Add($keyCol, [guid]) | Out-Null
            }

            foreach ($record in $CurrentData) {
                $row = $dt.NewRow()
                foreach ($keyCol in $KeyColumns) {
                    $row[$keyCol] = $record.$keyCol
                }
                $dt.Rows.Add($row)
            }
            $DataTable = $dt
        }

        # Bulk insert current keys into temp table
        Write-Verbose "Bulk inserting $($DataTable.Rows.Count) key records into temp table..."

        $bulkCopy = New-Object System.Data.SqlClient.SqlBulkCopy($Connection, [System.Data.SqlClient.SqlBulkCopyOptions]::Default, $Transaction)
        $bulkCopy.DestinationTableName = $tempTableName
        $bulkCopy.BatchSize = 10000
        $bulkCopy.BulkCopyTimeout = 300

        foreach ($keyCol in $KeyColumns) {
            $bulkCopy.ColumnMappings.Add($keyCol, $keyCol) | Out-Null
        }

        $bulkCopy.WriteToServer($DataTable)
        $bulkCopy.Close()

        # Build WHERE clause for matching keys
        $whereConditions = @()
        foreach ($keyCol in $KeyColumns) {
            $whereConditions += "dbo.$TargetTableName.$keyCol = t.$keyCol"
        }
        $whereClause = $whereConditions -join " AND "

        # Delete records that don't exist in temp table
        Write-Verbose "Deleting records from $TargetTableName that don't exist in current data..."

        $deleteSQL = @"
DELETE FROM dbo.$TargetTableName
WHERE NOT EXISTS (
    SELECT 1 FROM $tempTableName t
    WHERE $whereClause
)
"@

        $cmd.CommandText = $deleteSQL
        $cmd.CommandTimeout = 300
        $deletedCount = $cmd.ExecuteNonQuery()

        Write-Verbose "Deleted $deletedCount records"

        # Cleanup temp table
        $cmd.CommandText = "DROP TABLE $tempTableName"
        $cmd.ExecuteNonQuery() | Out-Null

        $cmd.Dispose()

        return $deletedCount
    }
    catch {
        # Try to cleanup temp table if it exists
        try {
            $cleanupCmd = $Connection.CreateCommand()
            if ($Transaction) {
                $cleanupCmd.Transaction = $Transaction
            }
            $cleanupCmd.CommandText = "IF OBJECT_ID('tempdb..$tempTableName') IS NOT NULL DROP TABLE $tempTableName"
            $cleanupCmd.ExecuteNonQuery() | Out-Null
            $cleanupCmd.Dispose()
        }
        catch {
            # Ignore cleanup errors
        }

        throw "Bulk delete failed: $_"
    }
}
