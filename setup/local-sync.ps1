<#
.SYNOPSIS
    Runs FortigiGraph data ingestion against the local Docker stack.

.DESCRIPTION
    Initializes tables (if needed), registers a crawler, generates the demo
    dataset, and ingests it via the Ingest API running in Docker.

    For EntraID crawlers that need Graph API access, use the EntraID crawler
    script directly: Crawlers/EntraID/Start-EntraIDCrawler.ps1

    Prerequisites:
    - Docker stack running: docker compose -f docker-compose.yml up -d
    - FortigiGraph module available at repo root

.PARAMETER ApiBaseUrl
    Ingest API base URL. Default: http://localhost:3001/api

.PARAMETER IngestDemo
    Ingest the demo dataset (default: true)

.PARAMETER CsvFolder
    Optional: path to CSV dataset to ingest via the CSV crawler

.EXAMPLE
    .\scripts\local-sync.ps1
    Ingests the demo dataset into the local Docker stack.

.EXAMPLE
    .\scripts\local-sync.ps1 -CsvFolder .\_Test\DatasetLed2
    Ingests both the demo dataset and a CSV export.
#>
param(
    [string]$ApiBaseUrl = 'http://localhost:3001/api',
    [switch]$SkipDemo,
    [string]$CsvFolder = ''
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path $PSScriptRoot -Parent

Write-Host "FortigiGraph Local Sync" -ForegroundColor Cyan
Write-Host "=======================" -ForegroundColor Cyan

# Verify API is running
try {
    $health = Invoke-RestMethod -Uri "$ApiBaseUrl/health" -TimeoutSec 5
    Write-Host "API is running ($($health.status))" -ForegroundColor Green
}
catch {
    Write-Host "API not reachable at $ApiBaseUrl — is Docker running?" -ForegroundColor Red
    Write-Host "Start with: docker compose -f docker-compose.yml up -d" -ForegroundColor Yellow
    exit 1
}

# Initialize tables from host (in case sql-table-init didn't run)
Write-Host "`nInitializing tables (if needed)..." -ForegroundColor Cyan
Import-Module (Join-Path $repoRoot 'setup/IdentityAtlas.psd1') -Force
$Global:FGSQLConnectionString = "Server=localhost,1433;Initial Catalog=GraphData;User ID=sa;Password=FortigiGraph_Local1!;TrustServerCertificate=True;Encrypt=True"
Initialize-FGSystemTables
Initialize-FGGovernanceTables
Initialize-FGCrawlerTables

# Register crawler
Write-Host "`nRegistering crawler..." -ForegroundColor Cyan
$result = Invoke-RestMethod -Uri "$ApiBaseUrl/admin/crawlers" -Method Post `
    -ContentType 'application/json' -Body '{"displayName":"Local Sync","permissions":["ingest","refreshViews"]}'
$apiKey = $result.apiKey
Write-Host "Crawler registered (key: $($result.apiKeyPrefix)...)" -ForegroundColor Green

# Ingest demo dataset
if (-not $SkipDemo) {
    Write-Host "`nGenerating demo dataset..." -ForegroundColor Cyan
    & (Join-Path $repoRoot 'test/demo-dataset/Generate-DemoDataset.ps1')

    Write-Host "`nIngesting demo dataset..." -ForegroundColor Cyan
    & (Join-Path $repoRoot 'test/demo-dataset/Ingest-DemoDataset.ps1') -ApiKey $apiKey -ApiBaseUrl $ApiBaseUrl
}

# Optional: CSV crawler
if ($CsvFolder) {
    Write-Host "`nRunning CSV crawler..." -ForegroundColor Cyan
    & (Join-Path $repoRoot 'tools/crawlers/csv/Start-CSVCrawler.ps1') `
        -ApiBaseUrl $ApiBaseUrl -ApiKey $apiKey -CsvFolder $CsvFolder `
        -SystemName 'Local CSV Import' -SystemType 'CSV'
}

Write-Host "`nLocal sync complete! Open http://localhost:3001 to view the data." -ForegroundColor Green
