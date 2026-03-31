function Initialize-FGCrawlerTables {
    <#
    .SYNOPSIS
    Creates the Crawlers and CrawlerAuditLog tables for Ingest API authentication.

    .DESCRIPTION
    Creates two tables:
    - Crawlers: Registry of API crawler clients with hashed keys, system scoping, and rate limits
    - CrawlerAuditLog: Audit trail for crawler authentication and ingest operations

    The Crawlers table is NOT temporal (keys are rotated, not versioned).
    The CrawlerAuditLog table is append-only (no updates or deletes).

    Tables are only created if they do not already exist.

    .EXAMPLE
    Initialize-FGCrawlerTables

    Creates both tables if they don't exist

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    #>

    [CmdletBinding()]
    [Alias("Initialize-CrawlerTables")]
    Param()

    # Check SQL connection
    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Initializing crawler tables..." -ForegroundColor Cyan

    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        # 1. Crawlers table
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = @"
IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'Crawlers' AND TABLE_SCHEMA = 'dbo')
BEGIN
    CREATE TABLE dbo.Crawlers (
        id              INT IDENTITY(1,1) PRIMARY KEY,
        displayName     NVARCHAR(255) NOT NULL,
        description     NVARCHAR(MAX),
        apiKeyHash      VARBINARY(64) NOT NULL,
        apiKeySalt      VARBINARY(32) NOT NULL,
        apiKeyPrefix    NVARCHAR(8) NOT NULL,
        systemIds       NVARCHAR(MAX),
        permissions     NVARCHAR(MAX) NOT NULL DEFAULT '["ingest"]',
        enabled         BIT NOT NULL DEFAULT 1,
        createdAt       DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
        createdBy       NVARCHAR(255),
        lastUsedAt      DATETIME2,
        lastRotatedAt   DATETIME2,
        expiresAt       DATETIME2,
        rateLimit       INT NOT NULL DEFAULT 100
    );

    CREATE NONCLUSTERED INDEX IX_Crawlers_ApiKeyPrefix
    ON dbo.Crawlers (apiKeyPrefix)
    INCLUDE (apiKeyHash, apiKeySalt, enabled, expiresAt);

    PRINT 'Created table: Crawlers';
END
ELSE
    PRINT 'Table already exists: Crawlers';
"@
        $cmd.ExecuteNonQuery() | Out-Null

        # 2. CrawlerAuditLog table
        $cmd2 = $connection.CreateCommand()
        $cmd2.CommandText = @"
IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'CrawlerAuditLog' AND TABLE_SCHEMA = 'dbo')
BEGIN
    CREATE TABLE dbo.CrawlerAuditLog (
        id              INT IDENTITY(1,1) PRIMARY KEY,
        crawlerId       INT NOT NULL,
        action          NVARCHAR(50) NOT NULL,
        endpoint        NVARCHAR(255),
        recordCount     INT,
        statusCode      INT,
        ipAddress       NVARCHAR(45),
        timestamp       DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
    );

    CREATE NONCLUSTERED INDEX IX_CrawlerAuditLog_CrawlerId
    ON dbo.CrawlerAuditLog (crawlerId, timestamp DESC);

    CREATE NONCLUSTERED INDEX IX_CrawlerAuditLog_Timestamp
    ON dbo.CrawlerAuditLog (timestamp DESC);

    PRINT 'Created table: CrawlerAuditLog';
END
ELSE
    PRINT 'Table already exists: CrawlerAuditLog';
"@
        $cmd2.ExecuteNonQuery() | Out-Null
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Crawler tables initialized" -ForegroundColor Green
    Write-Host "  - Crawlers (non-temporal, INT PK)" -ForegroundColor Gray
    Write-Host "  - CrawlerAuditLog (append-only, INT PK)" -ForegroundColor Gray
}
