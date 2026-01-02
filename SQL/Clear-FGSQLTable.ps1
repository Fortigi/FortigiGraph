function Clear-FGSQLTable {
    <#
    .SYNOPSIS
    Clears all data from a SQL table while preserving the table structure.

    .DESCRIPTION
    Truncates or deletes all records from the specified table, including history tables
    if the table is a temporal table. This is useful for cleaning up test data or
    resetting tables between sync operations.

    .PARAMETER TableName
    The name of the table to clear. Can include schema prefix (e.g., "dbo.TableName")

    .PARAMETER DeleteHistory
    If specified, also clears the history table for temporal tables. By default,
    only the current table is cleared and history is preserved.

    .PARAMETER Force
    Skip confirmation prompts. Use with caution!

    .EXAMPLE
    Clear-FGSQLTable -TableName "GraphUsers_Test"
    Clears all data from the GraphUsers_Test table (preserves history)

    .EXAMPLE
    Clear-FGSQLTable -TableName "GraphUsers_Test" -DeleteHistory -Force
    Clears both current and history data without confirmation

    .NOTES
    - Requires an active SQL connection (use Connect-FGSQLServer first)
    - For temporal tables, you can preserve history or delete it
    - Uses TRUNCATE when possible (faster), DELETE when required
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$TableName,

        [Parameter(Mandatory = $false)]
        [switch]$DeleteHistory,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    # Check if connected
    if (-not $global:FGSQLConnectionString) {
        Write-Error "Not connected to SQL Server. Use Connect-FGSQLServer first."
        return
    }

    # Parse table name to get schema and table
    if ($TableName -match '^\[?(\w+)\]?\.\[?(\w+)\]?$') {
        $schema = $matches[1]
        $table = $matches[2]
    } elseif ($TableName -match '^\[?(\w+)\]?$') {
        $schema = "dbo"
        $table = $matches[1]
    } else {
        Write-Error "Invalid table name format: $TableName"
        return
    }

    $fullTableName = "[$schema].[$table]"

    Write-Host "Preparing to clear table: $fullTableName" -ForegroundColor Yellow

    # Check if table exists and if it's temporal
    $tableInfo = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = @"
SELECT
    t.name as TableName,
    s.name as SchemaName,
    t.temporal_type,
    t.temporal_type_desc,
    OBJECT_NAME(t.history_table_id) as HistoryTableName,
    OBJECT_SCHEMA_NAME(t.history_table_id) as HistorySchemaName
FROM sys.tables t
INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
WHERE s.name = @schema AND t.name = @table
"@
        $cmd.Parameters.AddWithValue("@schema", $schema) | Out-Null
        $cmd.Parameters.AddWithValue("@table", $table) | Out-Null

        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        return $dataset.Tables[0]
    }

    if ($tableInfo.Rows.Count -eq 0) {
        Write-Error "Table not found: $fullTableName"
        return
    }

    $isTemporal = $tableInfo.Rows[0].temporal_type -eq 2
    $historyTable = $null
    $historySchema = $null

    if ($isTemporal) {
        $historyTable = $tableInfo.Rows[0].HistoryTableName
        $historySchema = $tableInfo.Rows[0].HistorySchemaName
        Write-Host "  → Table is temporal (history table: [$historySchema].[$historyTable])" -ForegroundColor Cyan
    }

    # Get row counts
    $currentCount = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = "SELECT COUNT(*) FROM $fullTableName"
        return $cmd.ExecuteScalar()
    }

    Write-Host "  → Current records: $currentCount" -ForegroundColor Cyan

    if ($isTemporal -and $historyTable) {
        $historyCount = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            $cmd = $connection.CreateCommand()
            $cmd.CommandText = "SELECT COUNT(*) FROM [$historySchema].[$historyTable]"
            return $cmd.ExecuteScalar()
        }
        Write-Host "  → History records: $historyCount" -ForegroundColor Cyan
    }

    # Confirmation
    if (-not $Force) {
        if ($isTemporal -and $DeleteHistory) {
            $message = "Clear $currentCount records from $fullTableName AND $historyCount records from history?"
        } else {
            $message = "Clear $currentCount records from $fullTableName?"
        }

        if (-not $PSCmdlet.ShouldProcess($fullTableName, $message)) {
            Write-Host "Operation cancelled." -ForegroundColor Yellow
            return
        }
    }

    try {
        # For temporal tables, we need to disable versioning first
        if ($isTemporal) {
            Write-Host "  → Disabling temporal versioning..." -ForegroundColor Cyan

            Invoke-FGSQLCommand -ScriptBlock {
                param($connection)
                $cmd = $connection.CreateCommand()
                $cmd.CommandText = "ALTER TABLE $fullTableName SET (SYSTEM_VERSIONING = OFF)"
                $cmd.ExecuteNonQuery() | Out-Null
            }
        }

        # Clear the main table
        Write-Host "  → Clearing current table..." -ForegroundColor Cyan
        Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            $cmd = $connection.CreateCommand()
            # Use TRUNCATE if possible (faster), but some tables require DELETE
            try {
                $cmd.CommandText = "TRUNCATE TABLE $fullTableName"
                $cmd.ExecuteNonQuery() | Out-Null
            } catch {
                # If TRUNCATE fails (e.g., foreign keys), use DELETE
                $cmd.CommandText = "DELETE FROM $fullTableName"
                $cmd.ExecuteNonQuery() | Out-Null
            }
        }

        Write-Host "  ✓ Cleared $currentCount records from $fullTableName" -ForegroundColor Green

        # Clear history table if requested
        if ($isTemporal -and $DeleteHistory -and $historyTable) {
            Write-Host "  → Clearing history table..." -ForegroundColor Cyan

            Invoke-FGSQLCommand -ScriptBlock {
                param($connection)
                $cmd = $connection.CreateCommand()
                $cmd.CommandText = "DELETE FROM [$historySchema].[$historyTable]"
                $cmd.ExecuteNonQuery() | Out-Null
            }

            Write-Host "  ✓ Cleared $historyCount records from history table" -ForegroundColor Green
        }

        # Re-enable temporal versioning if it was a temporal table
        if ($isTemporal) {
            Write-Host "  → Re-enabling temporal versioning..." -ForegroundColor Cyan

            Invoke-FGSQLCommand -ScriptBlock {
                param($connection)
                $cmd = $connection.CreateCommand()
                $cmd.CommandText = "ALTER TABLE $fullTableName SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = [$historySchema].[$historyTable]))"
                $cmd.ExecuteNonQuery() | Out-Null
            }

            Write-Host "  ✓ Temporal versioning re-enabled" -ForegroundColor Green
        }

        Write-Host "`n✓ Table cleared successfully" -ForegroundColor Green

    } catch {
        Write-Error "Failed to clear table: $_"

        # Try to re-enable versioning if we failed
        if ($isTemporal) {
            try {
                Write-Host "  → Attempting to restore temporal versioning..." -ForegroundColor Yellow
                Invoke-FGSQLCommand -ScriptBlock {
                    param($connection)
                    $cmd = $connection.CreateCommand()
                    $cmd.CommandText = "ALTER TABLE $fullTableName SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = [$historySchema].[$historyTable]))"
                    $cmd.ExecuteNonQuery() | Out-Null
                }
            } catch {
                Write-Warning "Failed to restore temporal versioning. You may need to manually restore it."
            }
        }
    }
}
