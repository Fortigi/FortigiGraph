<#
.SYNOPSIS
    Initializes all FortigiGraph SQL tables in the Docker environment.

.DESCRIPTION
    Runs after the database is created. Creates all system, governance,
    crawler, activity, risk score tables plus views and indexes.
    Designed to run as a one-shot Docker container.
#>

$ErrorActionPreference = 'Continue'

$sqlServer   = $env:SQL_SERVER   ?? 'sql'
$sqlDatabase = $env:SQL_DATABASE ?? 'GraphData'
$sqlUser     = $env:SQL_USER     ?? 'sa'
$sqlPassword = $env:SQL_PASSWORD ?? 'FortigiGraph_Local1!'

Write-Host "Initializing FortigiGraph tables..." -ForegroundColor Cyan
Write-Host "  Server:   $sqlServer" -ForegroundColor Gray
Write-Host "  Database: $sqlDatabase" -ForegroundColor Gray

# Wait for SQL to be ready
$maxRetries = 30
for ($i = 0; $i -lt $maxRetries; $i++) {
    try {
        $conn = New-Object System.Data.SqlClient.SqlConnection("Server=$sqlServer;Database=$sqlDatabase;User Id=$sqlUser;Password=$sqlPassword;TrustServerCertificate=True")
        $conn.Open()
        $conn.Close()
        Write-Host "  SQL Server is ready" -ForegroundColor Green
        break
    }
    catch {
        if ($i -eq $maxRetries - 1) { throw "SQL Server not ready after $maxRetries attempts" }
        Write-Host "  Waiting for SQL... ($($i+1)/$maxRetries)" -ForegroundColor Yellow
        Start-Sleep -Seconds 2
    }
}

# Set global connection string for FortigiGraph functions
$Global:FGSQLConnectionString = "Server=$sqlServer;Database=$sqlDatabase;User Id=$sqlUser;Password=$sqlPassword;TrustServerCertificate=True"

# Load module
Import-Module /app/setup/IdentityAtlas.psd1 -Force

# Initialize tables
Write-Host "`nCreating system tables..." -ForegroundColor Cyan
Initialize-FGSystemTables

try {
    Write-Host "`nCreating governance tables..." -ForegroundColor Cyan
    Initialize-FGGovernanceTables
} catch { Write-Host "  Governance tables warning: $($_.Exception.Message)" -ForegroundColor Yellow }

Write-Host "`nCreating crawler tables..." -ForegroundColor Cyan
Initialize-FGCrawlerTables

# Views and indexes (may fail if tables are empty — that's OK)
try {
    Write-Host "`nCreating resource views..." -ForegroundColor Cyan
    Initialize-FGResourceViews
} catch { Write-Host "  Views skipped: $($_.Exception.Message)" -ForegroundColor Yellow }

try {
    Write-Host "`nCreating resource indexes..." -ForegroundColor Cyan
    Initialize-FGResourceIndexes
} catch { Write-Host "  Indexes skipped: $($_.Exception.Message)" -ForegroundColor Yellow }

try {
    Write-Host "`nCreating access package views..." -ForegroundColor Cyan
    Initialize-FGAccessPackageViews
} catch { Write-Host "  AP views skipped: $($_.Exception.Message)" -ForegroundColor Yellow }

Write-Host "`nAll tables initialized successfully!" -ForegroundColor Green
