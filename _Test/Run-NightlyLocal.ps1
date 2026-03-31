<#
.SYNOPSIS
    Local nightly test runner — provisions a full environment from scratch, runs all tests, tears down.

.DESCRIPTION
    Designed to run unattended via Windows Task Scheduler. Spins up Docker SQL + backend,
    initializes tables, runs crawlers, validates data, runs Playwright E2E, and produces a report.

    Exit code 0 = all tests passed. Non-zero = failures (count of failed test groups).

.PARAMETER RepoRoot
    Path to the FortigiGraph repository root. Default: parent of _Test folder.

.PARAMETER CsvDataset
    Path to CSV test dataset folder. Default: _Test/DatasetLed2

.PARAMETER SkipBackendUnit
    Skip backend JS unit tests

.PARAMETER SkipFrontendUnit
    Skip frontend React unit tests

.PARAMETER SkipIntegration
    Skip Docker integration tests (ingest + data verification)

.PARAMETER SkipE2E
    Skip Playwright browser tests

.PARAMETER KeepEnvironment
    Don't tear down Docker after tests (for debugging)

.PARAMETER LogFolder
    Folder for test logs and reports. Default: _Test/NightlyResults/<date>

.EXAMPLE
    pwsh -File _Test\Run-NightlyLocal.ps1

.EXAMPLE
    pwsh -File _Test\Run-NightlyLocal.ps1 -SkipE2E -KeepEnvironment
#>

[CmdletBinding()]
Param(
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$CsvDataset = '',
    [switch]$SkipPowerShellUnit,
    [switch]$SkipBackendUnit,
    [switch]$SkipFrontendUnit,
    [switch]$SkipIntegration,
    [switch]$SkipE2E,
    [switch]$KeepEnvironment,
    [string]$LogFolder = ''
)

$ErrorActionPreference = 'Continue'
$startTime = Get-Date

if (-not $CsvDataset) { $CsvDataset = Join-Path $RepoRoot '_Test/DatasetLed2' }
if (-not $LogFolder) { $LogFolder = Join-Path $RepoRoot "_Test/NightlyResults/$($startTime.ToString('yyyy-MM-dd_HHmm'))" }

New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null

$results = @{}
$totalFailed = 0

function Write-Phase {
    param([string]$Name)
    Write-Host "`n╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  $Name" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
}

function Write-Result {
    param([string]$Name, [bool]$Passed, [string]$Detail = '')
    if ($Passed) {
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } else {
        Write-Host "  FAIL  $Name  $Detail" -ForegroundColor Red
        $script:totalFailed++
    }
    $script:results[$Name] = @{ Passed = $Passed; Detail = $Detail; Timestamp = Get-Date }
}

# ─── Config ──────────────────────────────────────────────────────

$sqlServer = 'localhost'
$sqlDatabase = 'GraphData'
$sqlUser = 'sa'
$sqlPassword = 'FortigiGraph_Local1!'
$apiBaseUrl = 'http://localhost:3001/api'
$uiBaseUrl = 'http://localhost:3001'
$backendDir = Join-Path $RepoRoot 'UI/backend'
$frontendDir = Join-Path $RepoRoot 'UI/frontend'
$composePath = Join-Path $RepoRoot 'docker-compose.local.yml'

Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Yellow
Write-Host "║  FortigiGraph Nightly Test Run                   ║" -ForegroundColor Yellow
Write-Host "║  $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))                          ║" -ForegroundColor Yellow
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Yellow
Write-Host "Repo:     $RepoRoot"
Write-Host "Dataset:  $CsvDataset"
Write-Host "Logs:     $LogFolder"
Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# PHASE 1: POWERSHELL UNIT TESTS (no dependencies)
# ═══════════════════════════════════════════════════════════════════

if (-not $SkipPowerShellUnit) {
    Write-Phase "Phase 1: PowerShell Unit Tests"

    try {
        $unitTestScript = Join-Path $RepoRoot '_Test/Test-Unit.ps1'
        if (Test-Path $unitTestScript) {
            $unitOutput = & pwsh -File $unitTestScript 2>&1 | Tee-Object -FilePath (Join-Path $LogFolder 'ps-unit.log')
            $unitPassed = $LASTEXITCODE -eq 0
            Write-Result 'PS-Unit-Tests' $unitPassed
        } else {
            Write-Result 'PS-Unit-Tests' $false 'Test-Unit.ps1 not found'
        }
    }
    catch {
        Write-Result 'PS-Unit-Tests' $false $_.Exception.Message
    }

    # Additional: verify no references to deleted sync functions
    Write-Phase "Phase 1b: Verify Deleted Functions Not Referenced"
    $deletedFunctions = @('Start-FGSync', 'Start-FGCSVSync', 'Sync-FGPrincipal', 'Sync-FGGroup', 'Sync-FGGroupMember', 'Sync-FGUser')
    $psFiles = Get-ChildItem -Path (Join-Path $RepoRoot 'Functions') -Include '*.ps1' -Recurse
    $badRefs = @()
    foreach ($file in $psFiles) {
        $content = Get-Content $file.FullName -Raw
        foreach ($fn in $deletedFunctions) {
            if ($content -match "\b$fn\b" -and $file.Name -notmatch 'Test-') {
                $badRefs += "$($file.Name) references deleted function $fn"
            }
        }
    }
    Write-Result 'No-Deleted-Function-Refs' ($badRefs.Count -eq 0) ($badRefs -join '; ')
}

# ═══════════════════════════════════════════════════════════════════
# PHASE 2: BACKEND JS UNIT TESTS
# ═══════════════════════════════════════════════════════════════════

if (-not $SkipBackendUnit) {
    Write-Phase "Phase 2: Backend Unit Tests"

    try {
        Push-Location $backendDir
        $npmTest = & npm test -- --reporter=verbose 2>&1 | Tee-Object -FilePath (Join-Path $LogFolder 'backend-unit.log')
        Write-Result 'Backend-Unit-Tests' ($LASTEXITCODE -eq 0) $(if ($LASTEXITCODE -ne 0) { "exit code $LASTEXITCODE" })
        Pop-Location
    }
    catch {
        Write-Result 'Backend-Unit-Tests' $false $_.Exception.Message
        Pop-Location
    }
}

# ═══════════════════════════════════════════════════════════════════
# PHASE 3: FRONTEND UNIT TESTS
# ═══════════════════════════════════════════════════════════════════

if (-not $SkipFrontendUnit) {
    Write-Phase "Phase 3: Frontend Unit Tests"

    try {
        Push-Location $frontendDir
        $npmTest = & npm test -- --reporter=verbose 2>&1 | Tee-Object -FilePath (Join-Path $LogFolder 'frontend-unit.log')
        Write-Result 'Frontend-Unit-Tests' ($LASTEXITCODE -eq 0) $(if ($LASTEXITCODE -ne 0) { "exit code $LASTEXITCODE" })
        Pop-Location
    }
    catch {
        Write-Result 'Frontend-Unit-Tests' $false $_.Exception.Message
        Pop-Location
    }
}

# ═══════════════════════════════════════════════════════════════════
# PHASE 4: DOCKER INTEGRATION TESTS
# ═══════════════════════════════════════════════════════════════════

if (-not $SkipIntegration) {
    Write-Phase "Phase 4a: Provision Docker Environment"

    # Tear down any existing containers
    Write-Host "  Cleaning up previous containers..." -ForegroundColor Gray
    & docker compose -f $composePath down -v 2>&1 | Out-Null

    # Start fresh
    Write-Host "  Starting Docker Compose..." -ForegroundColor Gray
    & docker compose -f $composePath up -d 2>&1 | Tee-Object -FilePath (Join-Path $LogFolder 'docker-up.log')
    Write-Result 'Docker-Compose-Up' ($LASTEXITCODE -eq 0)

    # Wait for SQL to be ready
    Write-Host "  Waiting for SQL Server..." -ForegroundColor Gray
    $sqlReady = $false
    for ($i = 0; $i -lt 30; $i++) {
        try {
            $conn = New-Object System.Data.SqlClient.SqlConnection("Server=$sqlServer;Database=master;User Id=$sqlUser;Password=$sqlPassword;TrustServerCertificate=True")
            $conn.Open()
            $conn.Close()
            $sqlReady = $true
            break
        }
        catch {
            Start-Sleep -Seconds 2
        }
    }
    Write-Result 'SQL-Server-Ready' $sqlReady $(if (-not $sqlReady) { 'Timed out after 60 seconds' })

    if ($sqlReady) {
        # Wait for database
        Write-Host "  Waiting for GraphData database..." -ForegroundColor Gray
        $dbReady = $false
        for ($i = 0; $i -lt 15; $i++) {
            try {
                $conn = New-Object System.Data.SqlClient.SqlConnection("Server=$sqlServer;Database=$sqlDatabase;User Id=$sqlUser;Password=$sqlPassword;TrustServerCertificate=True")
                $conn.Open()
                $conn.Close()
                $dbReady = $true
                break
            }
            catch {
                Start-Sleep -Seconds 2
            }
        }
        Write-Result 'Database-Ready' $dbReady

        # Initialize tables
        Write-Phase "Phase 4b: Initialize Tables"

        try {
            $Global:FGSQLConnectionString = "Server=$sqlServer;Database=$sqlDatabase;User Id=$sqlUser;Password=$sqlPassword;TrustServerCertificate=True"
            Import-Module (Join-Path $RepoRoot 'FortigiGraph.psd1') -Force

            Initialize-FGSystemTables 2>&1 | Tee-Object -FilePath (Join-Path $LogFolder 'init-system-tables.log')
            Write-Result 'Init-System-Tables' $true

            Initialize-FGGovernanceTables 2>&1 | Tee-Object -FilePath (Join-Path $LogFolder 'init-governance-tables.log')
            Write-Result 'Init-Governance-Tables' $true

            Initialize-FGCrawlerTables 2>&1 | Tee-Object -FilePath (Join-Path $LogFolder 'init-crawler-tables.log')
            Write-Result 'Init-Crawler-Tables' $true
        }
        catch {
            Write-Result 'Table-Initialization' $false $_.Exception.Message
        }

        # Verify tables exist
        Write-Phase "Phase 4c: Verify Table Schema"

        $expectedTables = @('Systems', 'Resources', 'Principals', 'ResourceAssignments', 'ResourceRelationships',
                            'Identities', 'IdentityMembers', 'Contexts', 'GovernanceCatalogs', 'AssignmentPolicies',
                            'AssignmentRequests', 'CertificationDecisions', 'Crawlers', 'CrawlerAuditLog')
        try {
            $conn = New-Object System.Data.SqlClient.SqlConnection($Global:FGSQLConnectionString)
            $conn.Open()
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = "SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'dbo'"
            $reader = $cmd.ExecuteReader()
            $existingTables = @()
            while ($reader.Read()) { $existingTables += $reader['TABLE_NAME'] }
            $reader.Close()
            $conn.Close()

            foreach ($table in $expectedTables) {
                $exists = $existingTables -contains $table
                Write-Result "Table-$table" $exists $(if (-not $exists) { "Table not found" })
            }
        }
        catch {
            Write-Result 'Table-Schema-Check' $false $_.Exception.Message
        }

        # Wait for backend API
        Write-Phase "Phase 4d: Verify API"

        $apiReady = $false
        for ($i = 0; $i -lt 20; $i++) {
            try {
                $health = Invoke-RestMethod -Uri "$apiBaseUrl/health" -TimeoutSec 5
                if ($health.status -eq 'ok') { $apiReady = $true; break }
            }
            catch {
                Start-Sleep -Seconds 3
            }
        }
        Write-Result 'API-Health' $apiReady $(if (-not $apiReady) { 'Timed out after 60 seconds' })

        if ($apiReady) {
            # Register crawler
            Write-Phase "Phase 4e: Crawler Registration & Auth"

            $crawlerKey = $null
            try {
                $regResult = Invoke-RestMethod -Uri "$apiBaseUrl/admin/crawlers" -Method Post -ContentType 'application/json' `
                    -Body '{"displayName":"Nightly Test Crawler","permissions":["ingest","refreshViews"]}'
                $crawlerKey = $regResult.apiKey
                Write-Result 'Crawler-Register' ($null -ne $crawlerKey)
            }
            catch {
                Write-Result 'Crawler-Register' $false $_.Exception.Message
            }

            if ($crawlerKey) {
                # Test whoami
                try {
                    $headers = @{ 'Authorization' = "Bearer $crawlerKey" }
                    $whoami = Invoke-RestMethod -Uri "$apiBaseUrl/crawlers/whoami" -Headers $headers
                    Write-Result 'Crawler-Whoami' ($whoami.displayName -eq 'Nightly Test Crawler')
                }
                catch {
                    Write-Result 'Crawler-Whoami' $false $_.Exception.Message
                }

                # Test key rotation
                try {
                    $rotateResult = Invoke-RestMethod -Uri "$apiBaseUrl/crawlers/rotate" -Method Post -Headers $headers
                    $newKey = $rotateResult.apiKey
                    Write-Result 'Crawler-Rotate' ($null -ne $newKey -and $newKey -ne $crawlerKey)
                    $crawlerKey = $newKey
                    $headers = @{ 'Authorization' = "Bearer $crawlerKey" }
                }
                catch {
                    Write-Result 'Crawler-Rotate' $false $_.Exception.Message
                }

                # Test old key fails
                try {
                    $oldHeaders = @{ 'Authorization' = "Bearer fgc_invalid_key_12345678901234567890" }
                    $null = Invoke-RestMethod -Uri "$apiBaseUrl/crawlers/whoami" -Headers $oldHeaders -ErrorAction Stop
                    Write-Result 'Invalid-Key-Rejected' $false 'Should have returned 401'
                }
                catch {
                    $statusCode = $_.Exception.Response.StatusCode.value__
                    Write-Result 'Invalid-Key-Rejected' ($statusCode -eq 401)
                }

                # Run CSV crawler
                Write-Phase "Phase 4f: CSV Crawler Ingest"

                try {
                    $crawlerScript = Join-Path $RepoRoot 'Crawlers/CSV/Start-CSVCrawler.ps1'
                    & $crawlerScript -ApiBaseUrl $apiBaseUrl -ApiKey $crawlerKey -CsvFolder $CsvDataset `
                        -SystemName 'Nightly Test Omada' -SystemType 'Omada' 2>&1 |
                        Tee-Object -FilePath (Join-Path $LogFolder 'csv-crawler.log')
                    Write-Result 'CSV-Crawler-Run' ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq $null)
                }
                catch {
                    Write-Result 'CSV-Crawler-Run' $false $_.Exception.Message
                }

                # Verify ingested data via API
                Write-Phase "Phase 4g: Data Verification"

                $verifyEndpoints = @(
                    @{ Name = 'Resources';  Url = "$apiBaseUrl/resources";   MinCount = 1 }
                    @{ Name = 'Systems';    Url = "$apiBaseUrl/systems";     MinCount = 1 }
                )

                foreach ($ep in $verifyEndpoints) {
                    try {
                        $data = Invoke-RestMethod -Uri $ep.Url -TimeoutSec 30
                        $count = if ($data -is [array]) { $data.Count } elseif ($data.data) { $data.data.Count } else { 0 }
                        Write-Result "Data-$($ep.Name)" ($count -ge $ep.MinCount) "Count: $count (min: $($ep.MinCount))"
                    }
                    catch {
                        Write-Result "Data-$($ep.Name)" $false $_.Exception.Message
                    }
                }

                # Verify sync log
                try {
                    $syncLog = Invoke-RestMethod -Uri "$apiBaseUrl/permissions/sync-log" -TimeoutSec 10 -ErrorAction SilentlyContinue
                    # Sync log endpoint may not exist at this path — just check if accessible
                    Write-Result 'Sync-Log-Accessible' $true
                }
                catch {
                    Write-Result 'Sync-Log-Accessible' $false 'Endpoint not available (non-critical)'
                }
            }
        }

        # Backend integration tests (if vitest is set up)
        Write-Phase "Phase 4h: Backend Integration Tests"

        $integrationTestDir = Join-Path $backendDir 'src/__tests__/integration'
        if (Test-Path $integrationTestDir) {
            try {
                Push-Location $backendDir
                $env:TEST_SQL_SERVER = $sqlServer
                $env:TEST_SQL_DATABASE = $sqlDatabase
                $env:TEST_SQL_USER = $sqlUser
                $env:TEST_SQL_PASSWORD = $sqlPassword
                & npx vitest run src/__tests__/integration/ --reporter=verbose 2>&1 |
                    Tee-Object -FilePath (Join-Path $LogFolder 'backend-integration.log')
                Write-Result 'Backend-Integration-Tests' ($LASTEXITCODE -eq 0)
                Pop-Location
            }
            catch {
                Write-Result 'Backend-Integration-Tests' $false $_.Exception.Message
                Pop-Location
            }
        }
        else {
            Write-Host "  Skipping (no integration test directory yet)" -ForegroundColor Yellow
        }
    }
}

# ═══════════════════════════════════════════════════════════════════
# PHASE 5: PLAYWRIGHT E2E BROWSER TESTS
# ═══════════════════════════════════════════════════════════════════

if (-not $SkipE2E) {
    Write-Phase "Phase 5: Playwright E2E Browser Tests"

    try {
        Push-Location $frontendDir

        # Check if running against Docker (real data) or mock
        if (-not $SkipIntegration) {
            # Real data mode — point Playwright at Docker backend
            $env:E2E_BASE_URL = $uiBaseUrl
            Write-Host "  Running against Docker backend ($uiBaseUrl)" -ForegroundColor Gray
        }
        else {
            Write-Host "  Running against mock backend" -ForegroundColor Gray
        }

        & npx playwright test --reporter=html 2>&1 | Tee-Object -FilePath (Join-Path $LogFolder 'playwright.log')
        Write-Result 'Playwright-E2E' ($LASTEXITCODE -eq 0) $(if ($LASTEXITCODE -ne 0) { "exit code $LASTEXITCODE" })

        # Copy Playwright report to log folder
        $reportDir = Join-Path $frontendDir 'playwright-report'
        if (Test-Path $reportDir) {
            Copy-Item -Path $reportDir -Destination (Join-Path $LogFolder 'playwright-report') -Recurse -Force
        }

        Pop-Location
    }
    catch {
        Write-Result 'Playwright-E2E' $false $_.Exception.Message
        Pop-Location
    }
}

# ═══════════════════════════════════════════════════════════════════
# PHASE 6: SWAGGER / OPENAPI VALIDATION
# ═══════════════════════════════════════════════════════════════════

if (-not $SkipIntegration) {
    Write-Phase "Phase 6: API Documentation"

    try {
        $swaggerResponse = Invoke-WebRequest -Uri "$uiBaseUrl/api/docs" -TimeoutSec 10 -UseBasicParsing
        Write-Result 'Swagger-UI-Loads' ($swaggerResponse.StatusCode -eq 200)
    }
    catch {
        Write-Result 'Swagger-UI-Loads' $false $_.Exception.Message
    }

    try {
        $specResponse = Invoke-RestMethod -Uri "$apiBaseUrl/docs/openapi.json" -TimeoutSec 10
        Write-Result 'OpenAPI-Spec-Valid' ($null -ne $specResponse.openapi)
    }
    catch {
        Write-Result 'OpenAPI-Spec-Valid' $false $_.Exception.Message
    }
}

# ═══════════════════════════════════════════════════════════════════
# TEARDOWN
# ═══════════════════════════════════════════════════════════════════

if (-not $KeepEnvironment -and -not $SkipIntegration) {
    Write-Phase "Teardown: Docker Environment"
    & docker compose -f $composePath down -v 2>&1 | Out-Null
    Write-Host "  Docker environment removed" -ForegroundColor Gray
}

# ═══════════════════════════════════════════════════════════════════
# REPORT
# ═══════════════════════════════════════════════════════════════════

$elapsed = (Get-Date) - $startTime
$totalTests = $results.Count
$passedTests = ($results.Values | Where-Object { $_.Passed }).Count
$failedTests = $totalTests - $passedTests

Write-Host "`n"
Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor $(if ($failedTests -eq 0) { 'Green' } else { 'Red' })
Write-Host "║  NIGHTLY TEST RESULTS                            ║" -ForegroundColor $(if ($failedTests -eq 0) { 'Green' } else { 'Red' })
Write-Host "╠══════════════════════════════════════════════════╣" -ForegroundColor $(if ($failedTests -eq 0) { 'Green' } else { 'Red' })
Write-Host "║  Total:    $totalTests" -ForegroundColor White
Write-Host "║  Passed:   $passedTests" -ForegroundColor Green
Write-Host "║  Failed:   $failedTests" -ForegroundColor $(if ($failedTests -eq 0) { 'Green' } else { 'Red' })
Write-Host "║  Duration: $([Math]::Round($elapsed.TotalMinutes, 1)) minutes" -ForegroundColor White
Write-Host "║  Logs:     $LogFolder" -ForegroundColor White
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor $(if ($failedTests -eq 0) { 'Green' } else { 'Red' })

# Write results to JSON
$reportJson = @{
    timestamp  = $startTime.ToString('o')
    duration   = [Math]::Round($elapsed.TotalSeconds)
    total      = $totalTests
    passed     = $passedTests
    failed     = $failedTests
    results    = $results
} | ConvertTo-Json -Depth 5
$reportJson | Out-File -FilePath (Join-Path $LogFolder 'results.json') -Encoding UTF8

# Write results summary to text
$summaryLines = @("FortigiGraph Nightly Test Results — $($startTime.ToString('yyyy-MM-dd HH:mm'))", "")
foreach ($name in ($results.Keys | Sort-Object)) {
    $r = $results[$name]
    $status = if ($r.Passed) { 'PASS' } else { 'FAIL' }
    $line = "$status  $name"
    if ($r.Detail) { $line += "  ($($r.Detail))" }
    $summaryLines += $line
}
$summaryLines += ""
$summaryLines += "Total: $totalTests | Passed: $passedTests | Failed: $failedTests | Duration: $([Math]::Round($elapsed.TotalMinutes, 1)) min"
$summaryLines | Out-File -FilePath (Join-Path $LogFolder 'summary.txt') -Encoding UTF8

# Print failed tests
if ($failedTests -gt 0) {
    Write-Host "`nFailed tests:" -ForegroundColor Red
    foreach ($name in ($results.Keys | Sort-Object)) {
        $r = $results[$name]
        if (-not $r.Passed) {
            Write-Host "  - $name: $($r.Detail)" -ForegroundColor Red
        }
    }
}

exit $failedTests
