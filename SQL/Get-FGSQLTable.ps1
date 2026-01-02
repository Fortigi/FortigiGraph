function Get-FGSQLTable {
    <#
    .SYNOPSIS
    Lists all tables in the connected SQL database with details.

    .DESCRIPTION
    Retrieves information about tables in the current database, including:
    - Table name and schema
    - Row counts
    - Temporal table status
    - History table information
    - Create date

    This is useful for understanding what tables exist and their current state.

    .PARAMETER Schema
    Optional: Filter by schema name (default: all schemas)

    .PARAMETER Pattern
    Optional: Filter table names using wildcard pattern (e.g., "GraphUsers*")

    .PARAMETER IncludeSystemTables
    If specified, includes system temporal history tables in the output

    .EXAMPLE
    Get-FGSQLTable
    Lists all user tables in the database

    .EXAMPLE
    Get-FGSQLTable -Pattern "GraphUsers*"
    Lists only tables starting with "GraphUsers"

    .EXAMPLE
    Get-FGSQLTable -Schema "dbo"
    Lists only tables in the dbo schema

    .NOTES
    - Requires an active SQL connection (use Connect-FGSQLServer first)
    - Row counts are approximate for large tables
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Schema,

        [Parameter(Mandatory = $false)]
        [string]$Pattern,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeSystemTables
    )

    # Check if connected
    if (-not $global:FGSQLConnectionString) {
        Write-Error "Not connected to SQL Server. Use Connect-FGSQLServer first."
        return
    }

    Write-Host "Retrieving table information from database: $($global:FGSQLDatabaseName)" -ForegroundColor Cyan

    # Build the query with optional filters
    $whereClause = "WHERE t.is_ms_shipped = 0"

    if ($Schema) {
        $whereClause += " AND s.name = '$Schema'"
    }

    if ($Pattern) {
        $sqlPattern = $Pattern.Replace("*", "%").Replace("?", "_")
        $whereClause += " AND t.name LIKE '$sqlPattern'"
    }

    if (-not $IncludeSystemTables) {
        $whereClause += " AND t.temporal_type_desc != 'HISTORY_TABLE'"
    }

    $query = @"
SELECT
    s.name as SchemaName,
    t.name as TableName,
    t.create_date as CreateDate,
    CASE t.temporal_type
        WHEN 2 THEN 'Yes'
        ELSE 'No'
    END as IsTemporal,
    OBJECT_SCHEMA_NAME(t.history_table_id) as HistorySchema,
    OBJECT_NAME(t.history_table_id) as HistoryTable,
    p.rows as ApproxRowCount
FROM sys.tables t
INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
LEFT JOIN sys.partitions p ON t.object_id = p.object_id AND p.index_id IN (0, 1)
$whereClause
ORDER BY s.name, t.name
"@

    try {
        # Execute query using Invoke-FGSQLQuery
        $results = Invoke-FGSQLQuery -Query $query

        # Check if we got results
        if (-not $results -or $results.Rows.Count -eq 0) {
            Write-Host "  → No tables found in the database" -ForegroundColor Yellow
            return
        }

        Write-Host "`nFound $($results.Rows.Count) table(s):`n" -ForegroundColor Green

        # Display the results
        $results | Format-Table -AutoSize

        # Calculate summary statistics
        $temporalCount = ($results | Where-Object { $_.IsTemporal -eq 'Yes' }).Count
        $totalRows = ($results | Measure-Object -Property ApproxRowCount -Sum).Sum

        Write-Host "Summary:" -ForegroundColor Cyan
        Write-Host "  Total Tables: $($results.Rows.Count)" -ForegroundColor White
        Write-Host "  Temporal Tables: $temporalCount" -ForegroundColor White
        Write-Host "  Total Rows (approx): $("{0:N0}" -f $totalRows)" -ForegroundColor White

        return $results

    } catch {
        Write-Error "Failed to retrieve table information: $_"
    }
}
