function Clear-FGDatabase {
    <#
    .SYNOPSIS
    Clears all data from the FortigiGraph database while preserving table structures.

    .DESCRIPTION
    Removes all data from every FortigiGraph table (including temporal history) so you
    can load a different dataset without redeploying. Tables are cleared in dependency
    order to avoid foreign key violations. Uses a single SQL transaction for speed.

    .PARAMETER KeepUIData
    If specified, preserves tags, categories, and user preferences.

    .PARAMETER KeepSyncLog
    If specified, preserves the sync log history.

    .PARAMETER ConfigFile
    Optional config file path. If provided, connects to SQL Server automatically.

    .PARAMETER Force
    Skip confirmation prompt.

    .EXAMPLE
    Clear-FGDatabase -Force
    Clears all data from all tables without prompting.

    .EXAMPLE
    Clear-FGDatabase -ConfigFile .\Config\iidemo.json -KeepUIData -Force
    Connects to SQL and clears all data except tags, categories, and preferences.

    .NOTES
    Requires an active SQL connection (use Connect-FGSQLServer first, or pass -ConfigFile).
    #>

    [alias("Clear-Database")]
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    Param(
        [Parameter(Mandatory = $false)]
        [switch]$KeepUIData,

        [Parameter(Mandatory = $false)]
        [switch]$KeepSyncLog,

        [Parameter(Mandatory = $false)]
        [string]$ConfigFile,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    # Connect if ConfigFile provided and not already connected
    if ($ConfigFile -and -not $global:FGSQLConnectionString) {
        Connect-FGSQLServer -ConfigFile $ConfigFile
    }

    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first or pass -ConfigFile."
    }

    # Confirmation
    if (-not $Force) {
        Write-Host ""
        Write-Host "  WARNING: This will delete ALL data from the FortigiGraph database!" -ForegroundColor Red
        Write-Host "  Database: $global:FGSQLDatabaseName on $global:FGSQLServerName" -ForegroundColor Yellow
        Write-Host "  All tables and their history will be cleared." -ForegroundColor Yellow
        if ($KeepUIData) { Write-Host "  Tags, categories, and preferences will be preserved." -ForegroundColor Cyan }
        if ($KeepSyncLog) { Write-Host "  Sync log will be preserved." -ForegroundColor Cyan }
        Write-Host ""

        if (-not $PSCmdlet.ShouldProcess("$global:FGSQLDatabaseName", "Clear ALL data from database")) {
            Write-Host "  Cancelled." -ForegroundColor Gray
            return
        }
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "  Clearing FortigiGraph Database" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "  Server:   $global:FGSQLServerName" -ForegroundColor White
    Write-Host "  Database: $global:FGSQLDatabaseName" -ForegroundColor White
    Write-Host ""

    $startTime = Get-Date

    # Tables in dependency order (children before parents)
    # Each entry: table name, whether it's temporal
    $allTables = @(
        # Phase 1: Materialized tables (non-temporal, no dependencies)
        @{ Name = 'mat_UserPermissionAssignments'; Temporal = $false; Phase = 'Materialized tables' }
        @{ Name = 'mat_UserPermissionAssignmentViaBusinessRole'; Temporal = $false; Phase = 'Materialized tables' }
        @{ Name = 'mat_UserCounts'; Temporal = $false; Phase = 'Materialized tables' }

        # Phase 2: Risk scores
        @{ Name = 'RiskScores'; Temporal = $true; Phase = 'Risk scores' }

        # Phase 3: Governance (children first)
        @{ Name = 'CertificationDecisions'; Temporal = $true; Phase = 'Governance tables' }
        @{ Name = 'AssignmentRequests'; Temporal = $true; Phase = 'Governance tables' }
        @{ Name = 'AssignmentPolicies'; Temporal = $true; Phase = 'Governance tables' }
        @{ Name = 'GovernanceCatalogs'; Temporal = $true; Phase = 'Governance tables' }

        # Phase 4: Resource model (children first)
        @{ Name = 'ResourceRelationships'; Temporal = $true; Phase = 'Resource model' }
        @{ Name = 'ResourceAssignments'; Temporal = $true; Phase = 'Resource model' }
        @{ Name = 'Resources'; Temporal = $true; Phase = 'Resource model' }
        @{ Name = 'IdentityMembers'; Temporal = $true; Phase = 'Resource model' }
        @{ Name = 'Identities'; Temporal = $true; Phase = 'Resource model' }
        @{ Name = 'Principals'; Temporal = $true; Phase = 'Resource model' }
        @{ Name = 'Contexts'; Temporal = $true; Phase = 'Resource model' }

        # Phase 5: Systems
        @{ Name = 'SystemOwners'; Temporal = $false; Phase = 'Systems' }
        @{ Name = 'Systems'; Temporal = $true; Phase = 'Systems' }

        # Phase 6: Activity
        @{ Name = 'PrincipalActivity'; Temporal = $false; Phase = 'Activity tables' }
    )

    # Conditionally add sync log and UI tables
    if (-not $KeepSyncLog) {
        $allTables += @{ Name = 'GraphSyncLog'; Temporal = $false; Phase = 'Sync log' }
    }

    if (-not $KeepUIData) {
        $allTables += @(
            @{ Name = 'GraphTagAssignments'; Temporal = $false; Phase = 'UI tables' }
            @{ Name = 'GraphTags'; Temporal = $false; Phase = 'UI tables' }
            @{ Name = 'GovernanceCategoryAssignments'; Temporal = $false; Phase = 'UI tables' }
            @{ Name = 'GovernanceCategories'; Temporal = $false; Phase = 'UI tables' }
            @{ Name = 'GraphUserPreferences'; Temporal = $false; Phase = 'UI tables' }
        )
    }

    # Execute everything in a single connection
    $result = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        $clearedCount = 0
        $currentPhase = ''

        foreach ($tableEntry in $allTables) {
            $tableName = $tableEntry.Name
            $isTemporal = $tableEntry.Temporal
            $phase = $tableEntry.Phase

            if ($phase -ne $currentPhase) {
                $currentPhase = $phase
                Write-Host "  $phase..." -ForegroundColor Cyan
            }

            # Check if table exists
            $checkCmd = $connection.CreateCommand()
            $checkCmd.CommandText = "SELECT COUNT(*) FROM sys.tables WHERE name = @name AND schema_id = SCHEMA_ID('dbo')"
            $checkCmd.Parameters.AddWithValue("@name", $tableName) | Out-Null
            $exists = $checkCmd.ExecuteScalar()
            $checkCmd.Dispose()

            if ($exists -eq 0) { continue }

            # Get row count
            $countCmd = $connection.CreateCommand()
            $countCmd.CommandText = "SELECT COUNT(*) FROM dbo.[$tableName]"
            $rowCount = $countCmd.ExecuteScalar()
            $countCmd.Dispose()

            $historyCount = 0

            try {
                if ($isTemporal) {
                    # Get history table name
                    $histCmd = $connection.CreateCommand()
                    $histCmd.CommandText = @"
SELECT OBJECT_NAME(t.history_table_id) AS HistoryTable, OBJECT_SCHEMA_NAME(t.history_table_id) AS HistorySchema
FROM sys.tables t WHERE t.name = @name AND t.temporal_type = 2
"@
                    $histCmd.Parameters.AddWithValue("@name", $tableName) | Out-Null
                    $histReader = $histCmd.ExecuteReader()
                    $historyTable = $null
                    $historySchema = $null
                    if ($histReader.Read()) {
                        $historyTable = $histReader['HistoryTable']
                        $historySchema = $histReader['HistorySchema']
                    }
                    $histReader.Close()
                    $histCmd.Dispose()

                    if ($historyTable) {
                        # Count history rows
                        $hcCmd = $connection.CreateCommand()
                        $hcCmd.CommandText = "SELECT COUNT(*) FROM [$historySchema].[$historyTable]"
                        $historyCount = $hcCmd.ExecuteScalar()
                        $hcCmd.Dispose()

                        # Disable versioning
                        $cmd = $connection.CreateCommand()
                        $cmd.CommandText = "ALTER TABLE dbo.[$tableName] SET (SYSTEM_VERSIONING = OFF)"
                        $cmd.ExecuteNonQuery() | Out-Null
                        $cmd.Dispose()

                        # Clear main table
                        $cmd = $connection.CreateCommand()
                        $cmd.CommandText = "DELETE FROM dbo.[$tableName]"
                        $cmd.ExecuteNonQuery() | Out-Null
                        $cmd.Dispose()

                        # Clear history table
                        $cmd = $connection.CreateCommand()
                        $cmd.CommandText = "DELETE FROM [$historySchema].[$historyTable]"
                        $cmd.ExecuteNonQuery() | Out-Null
                        $cmd.Dispose()

                        # Re-enable versioning
                        $cmd = $connection.CreateCommand()
                        $cmd.CommandText = "ALTER TABLE dbo.[$tableName] SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = [$historySchema].[$historyTable]))"
                        $cmd.ExecuteNonQuery() | Out-Null
                        $cmd.Dispose()
                    }
                } else {
                    # Non-temporal: simple delete
                    $cmd = $connection.CreateCommand()
                    try {
                        $cmd.CommandText = "TRUNCATE TABLE dbo.[$tableName]"
                        $cmd.ExecuteNonQuery() | Out-Null
                    } catch {
                        $cmd.CommandText = "DELETE FROM dbo.[$tableName]"
                        $cmd.ExecuteNonQuery() | Out-Null
                    }
                    $cmd.Dispose()
                }

                $totalRows = $rowCount + $historyCount
                if ($totalRows -gt 0) {
                    Write-Host "    $tableName : $rowCount rows + $historyCount history" -ForegroundColor Gray
                }
                $clearedCount++
            }
            catch {
                Write-Host "    ! $tableName : FAILED - $_" -ForegroundColor Red
                # Try to re-enable versioning if we broke it
                if ($isTemporal -and $historyTable) {
                    try {
                        $fixCmd = $connection.CreateCommand()
                        $fixCmd.CommandText = "ALTER TABLE dbo.[$tableName] SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = [$historySchema].[$historyTable]))"
                        $fixCmd.ExecuteNonQuery() | Out-Null
                        $fixCmd.Dispose()
                    } catch { }
                }
            }
        }

        return $clearedCount
    }

    $elapsed = (Get-Date) - $startTime

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  Database Cleared!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  Tables cleared: $result" -ForegroundColor White
    Write-Host "  Duration:       $([math]::Round($elapsed.TotalSeconds, 1))s" -ForegroundColor White
    if ($KeepUIData) { Write-Host "  Preserved:      tags, categories, preferences" -ForegroundColor Cyan }
    if ($KeepSyncLog) { Write-Host "  Preserved:      sync log" -ForegroundColor Cyan }
    Write-Host ""
    Write-Host "  Run Start-FGSync or Start-FGCSVSync to load new data." -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Green
}
