function Initialize-FGActivityTables {
    <#
    .SYNOPSIS
    Creates the PrincipalActivity table for tracking when principals last accessed systems and resources.

    .DESCRIPTION
    Creates the PrincipalActivity table — a non-temporal, upsert-based table that stores
    activity signals per principal, optionally scoped to a specific resource.

    Unlike the Principals temporal table (which tracks structural changes like job title or
    department), PrincipalActivity tracks time-series signals such as "last sign-in" or
    "last access to an app". Separating these prevents high-frequency activity updates from
    polluting the structural version history.

    Schema:
    - principalId   — FK to Principals (the user or service principal)
    - resourceId    — FK to Resources; '00000000-0000-0000-0000-000000000000' (nil GUID) = general activity
    - systemId      — FK to Systems (source system)
    - activityType  — Discriminator: 'SignIn', 'AppSignIn', 'ResourceAccess', etc.
    - lastActivityDateTime — When activity last occurred
    - activityCount — Optional: how many events in the period
    - periodStart / periodEnd — Optional: aggregation window
    - extendedAttributes — JSON for additional context (e.g. appId, appDisplayName)
    - syncedAt      — When this row was last synced

    Primary key: (principalId, resourceId, systemId, activityType) — enables efficient MERGE.

    The nil GUID is used as the resourceId sentinel for general (non-resource-specific) activity
    such as an Entra ID sign-in. Resource-specific activity (e.g. sign-in to a specific enterprise
    app) uses the matching resourceId from the Resources table.

    .PARAMETER DropIfExists
    If specified, drops and recreates the table (WARNING: loses all activity history!)

    .EXAMPLE
    Initialize-FGActivityTables

    Creates the PrincipalActivity table if it does not already exist.

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    #>

    [CmdletBinding()]
    [Alias("Initialize-ActivityTables")]
    Param(
        [Parameter(Mandatory = $false)]
        [switch]$DropIfExists
    )

    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Initializing activity tables..." -ForegroundColor Cyan

    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        $tableExists = $false
        $checkCmd = $connection.CreateCommand()
        $checkCmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'PrincipalActivity' AND TABLE_SCHEMA = 'dbo'"
        $tableExists = $checkCmd.ExecuteScalar() -gt 0
        $checkCmd.Dispose()

        if ($tableExists -and -not $DropIfExists) {
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Table 'PrincipalActivity' already exists (skipping)" -ForegroundColor Yellow
            return
        }

        if ($tableExists -and $DropIfExists) {
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Dropping existing table 'PrincipalActivity'..." -ForegroundColor Yellow
            $dropCmd = $connection.CreateCommand()
            $dropCmd.CommandText = "DROP TABLE IF EXISTS dbo.PrincipalActivity;"
            $dropCmd.ExecuteNonQuery() | Out-Null
            $dropCmd.Dispose()
        }

        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Creating table 'PrincipalActivity'..." -ForegroundColor Gray
        $createCmd = $connection.CreateCommand()
        $createCmd.CommandText = @"
CREATE TABLE dbo.PrincipalActivity (
    -- Who performed the activity
    principalId             UNIQUEIDENTIFIER NOT NULL,

    -- Which resource was accessed; nil GUID = general activity (e.g. tenant sign-in)
    resourceId              UNIQUEIDENTIFIER NOT NULL
        CONSTRAINT DF_PrincipalActivity_ResourceId DEFAULT '00000000-0000-0000-0000-000000000000',

    -- Source system (FK to Systems.id)
    systemId                INT NOT NULL,

    -- Activity type discriminator: 'SignIn', 'AppSignIn', 'ResourceAccess', ...
    activityType            NVARCHAR(100) NOT NULL,

    -- Core activity fields
    lastActivityDateTime    DATETIME2 NULL,
    activityCount           BIGINT NULL,
    periodStart             DATETIME2 NULL,
    periodEnd               DATETIME2 NULL,

    -- JSON for additional context (e.g. appId, appDisplayName for AppSignIn rows)
    extendedAttributes      NVARCHAR(MAX) NULL,

    -- Housekeeping
    syncedAt                DATETIME2 NOT NULL
        CONSTRAINT DF_PrincipalActivity_SyncedAt DEFAULT GETUTCDATE(),

    CONSTRAINT PK_PrincipalActivity PRIMARY KEY CLUSTERED (
        principalId, resourceId, systemId, activityType
    )
);
"@
        $createCmd.ExecuteNonQuery() | Out-Null
        $createCmd.Dispose()

        # Index for fast lookups by resource (for role mining queries)
        $idxCmd = $connection.CreateCommand()
        $idxCmd.CommandText = @"
CREATE NONCLUSTERED INDEX IX_PrincipalActivity_Resource
ON dbo.PrincipalActivity (resourceId, activityType)
INCLUDE (principalId, lastActivityDateTime);
"@
        $idxCmd.ExecuteNonQuery() | Out-Null
        $idxCmd.Dispose()

        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Created table 'PrincipalActivity' with index" -ForegroundColor Green
    }

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Activity Tables Ready!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Tables:" -ForegroundColor White
    Write-Host "  - PrincipalActivity (non-temporal, composite PK)" -ForegroundColor Gray
    Write-Host "    principalId + resourceId + systemId + activityType" -ForegroundColor Gray
    Write-Host "    Nil GUID resourceId = general sign-in activity" -ForegroundColor Gray
    Write-Host "========================================`n" -ForegroundColor Green

    return $true
}
