function Initialize-FGRiskScoreTables {
    <#
    .SYNOPSIS
    Creates the RiskScores temporal table and ensures denormalized risk columns exist on Principals and Resources.

    .DESCRIPTION
    Creates the RiskScores table for centralized risk score storage:
    - RiskScores: Per-entity risk scores with sub-scores, explanations, and analyst overrides (composite PK: entityId + entityType)

    The table uses temporal versioning for full audit trail of score changes over time.

    Also ensures denormalized riskScore (INT) and riskTier (NVARCHAR(20)) columns exist on
    Principals and Resources tables for fast query access.

    If migrating from the previous model (where risk scores lived directly on Principals/Resources),
    existing scores are automatically migrated to the new RiskScores table.

    Tables are only created if they do not already exist, unless -DropIfExists is specified.

    .PARAMETER DropIfExists
    If specified, drops and recreates the RiskScores table (WARNING: loses all history!)

    .EXAMPLE
    Initialize-FGRiskScoreTables

    Creates the RiskScores table if it doesn't exist and migrates existing scores

    .EXAMPLE
    Initialize-FGRiskScoreTables -DropIfExists

    Drops and recreates the RiskScores table (loses all temporal history)

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    #>

    [CmdletBinding()]
    [Alias("Initialize-RiskScoreTables")]
    Param(
        [Parameter(Mandatory = $false)]
        [switch]$DropIfExists
    )

    # Check SQL connection
    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Initializing risk score tables..." -ForegroundColor Cyan

    # 1. RiskScores table (temporal, composite PK: entityId + entityType)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Processing table: RiskScores" -ForegroundColor Cyan

    $riskScoreColumns = @{
        'entityId'              = 'UNIQUEIDENTIFIER'
        'entityType'            = 'NVARCHAR(50)'
        'riskScore'             = 'INT'
        'riskTier'              = 'NVARCHAR(20)'
        'riskDirectScore'       = 'INT'
        'riskMembershipScore'   = 'INT'
        'riskStructuralScore'   = 'INT'
        'riskPropagatedScore'   = 'INT'
        'riskExplanation'       = 'NVARCHAR(MAX)'
        'riskClassifierMatches' = 'NVARCHAR(MAX)'
        'riskOverride'          = 'INT'
        'riskOverrideReason'    = 'NVARCHAR(500)'
        'riskScoredAt'          = 'DATETIME2'
    }

    $tableReady = Initialize-FGSyncTable -TableName "RiskScores" -Columns $riskScoreColumns -CompositePrimaryKey @('entityId', 'entityType') -RecreateTable:$DropIfExists
    if ($tableReady -eq $false) {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] RiskScores table creation cancelled" -ForegroundColor Yellow
    }

    # 2. Ensure denormalized risk columns on Principals and Resources
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Ensuring denormalized risk columns on Principals and Resources..." -ForegroundColor Cyan

    $denormalizedColumns = @{
        'riskScore' = 'INT'
        'riskTier'  = 'NVARCHAR(20)'
    }

    foreach ($tableName in @('Principals', 'Resources')) {
        Invoke-FGSQLCommand -ScriptBlock {
            param($connection)

            $checkCmd = $connection.CreateCommand()
            $checkCmd.CommandText = @"
SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = '$tableName'
"@
            $tableExists = $checkCmd.ExecuteScalar() -gt 0

            if ($tableExists) {
                $missingColumns = @{}

                foreach ($colName in $denormalizedColumns.Keys) {
                    $colCmd = $connection.CreateCommand()
                    $colCmd.CommandText = @"
SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = '$tableName' AND COLUMN_NAME = '$colName'
"@
                    $colExists = $colCmd.ExecuteScalar() -gt 0

                    if (-not $colExists) {
                        $missingColumns[$colName] = $denormalizedColumns[$colName]
                    }
                }

                if ($missingColumns.Count -gt 0) {
                    Add-FGSQLTableColumn -TableName $tableName -Columns $missingColumns
                    Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Added columns ($($missingColumns.Keys -join ', ')) to $tableName" -ForegroundColor Green
                } else {
                    Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Risk columns already exist on $tableName" -ForegroundColor Gray
                }
            } else {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] $tableName table not yet created (columns will be added when table is initialized)" -ForegroundColor Yellow
            }
        }
    }

    # 3. Migration: Copy existing risk scores from Principals and Resources into RiskScores table
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Checking for risk score migration..." -ForegroundColor Cyan

    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        # Check if RiskScores table exists and is empty
        $countCmd = $connection.CreateCommand()
        $countCmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = 'RiskScores'"
        $riskTableExists = $countCmd.ExecuteScalar() -gt 0

        if (-not $riskTableExists) {
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] RiskScores table does not exist yet, skipping migration" -ForegroundColor Yellow
            return
        }

        $countCmd2 = $connection.CreateCommand()
        $countCmd2.CommandText = "SELECT COUNT(*) FROM dbo.RiskScores"
        $riskRowCount = $countCmd2.ExecuteScalar()

        if ($riskRowCount -gt 0) {
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] RiskScores table already has $riskRowCount rows, skipping migration" -ForegroundColor Gray
            return
        }

        $totalMigrated = 0

        # Migrate from Principals
        $checkPrincipals = $connection.CreateCommand()
        $checkPrincipals.CommandText = @"
SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = 'Principals' AND COLUMN_NAME = 'riskScore'
"@
        $principalsHasRisk = $checkPrincipals.ExecuteScalar() -gt 0

        if ($principalsHasRisk) {
            $migrateCmd = $connection.CreateCommand()
            $migrateCmd.CommandText = @"
INSERT INTO dbo.RiskScores (entityId, entityType, riskScore, riskTier, riskScoredAt)
SELECT id, 'Principal', riskScore, riskTier, SYSUTCDATETIME()
FROM dbo.Principals
WHERE riskScore IS NOT NULL
"@
            $principalRows = $migrateCmd.ExecuteNonQuery()
            $totalMigrated += $principalRows
            if ($principalRows -gt 0) {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Migrated $principalRows risk scores from Principals" -ForegroundColor Green
            }
        }

        # Migrate from Resources
        $checkResources = $connection.CreateCommand()
        $checkResources.CommandText = @"
SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = 'Resources' AND COLUMN_NAME = 'riskScore'
"@
        $resourcesHasRisk = $checkResources.ExecuteScalar() -gt 0

        if ($resourcesHasRisk) {
            $migrateCmd2 = $connection.CreateCommand()
            $migrateCmd2.CommandText = @"
INSERT INTO dbo.RiskScores (entityId, entityType, riskScore, riskTier, riskScoredAt)
SELECT id, 'Resource', riskScore, riskTier, SYSUTCDATETIME()
FROM dbo.Resources
WHERE riskScore IS NOT NULL
"@
            $resourceRows = $migrateCmd2.ExecuteNonQuery()
            $totalMigrated += $resourceRows
            if ($resourceRows -gt 0) {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Migrated $resourceRows risk scores from Resources" -ForegroundColor Green
            }
        }

        if ($totalMigrated -eq 0) {
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] No existing risk scores to migrate" -ForegroundColor Gray
        } else {
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Total migrated: $totalMigrated risk scores" -ForegroundColor Green
        }
    }

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Risk Score Tables Ready!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Tables:" -ForegroundColor White
    Write-Host "  - RiskScores (temporal, composite PK: entityId + entityType)" -ForegroundColor Gray
    Write-Host "  - Principals.riskScore, Principals.riskTier (denormalized)" -ForegroundColor Gray
    Write-Host "  - Resources.riskScore, Resources.riskTier (denormalized)" -ForegroundColor Gray
    Write-Host "========================================`n" -ForegroundColor Green

    return $true
}
