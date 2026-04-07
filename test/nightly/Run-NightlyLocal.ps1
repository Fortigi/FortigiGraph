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
    Optional path to a CSV test dataset folder. The CSV crawler step is skipped
    when this is empty or the folder doesn't exist (the bundled Omada export was
    removed from the repo in April 2026).

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
    Folder for test logs and reports. Default: test/nightly/results/<date>

.EXAMPLE
    pwsh -File test\nightly\Run-NightlyLocal.ps1

.EXAMPLE
    pwsh -File test\nightly\Run-NightlyLocal.ps1 -SkipE2E -KeepEnvironment
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

if (-not $LogFolder) { $LogFolder = Join-Path $RepoRoot "test/nightly/results/$($startTime.ToString('yyyy-MM-dd_HHmm'))" }

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
$backendDir = Join-Path $RepoRoot 'app/api'
$frontendDir = Join-Path $RepoRoot 'app/ui'
$composePath = Join-Path $RepoRoot 'docker-compose.yml'

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
        $unitTestScript = Join-Path $RepoRoot 'test/unit/Test-Unit.ps1'
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
            Import-Module (Join-Path $RepoRoot 'setup/IdentityAtlas.psd1') -Force

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

                # Generate and ingest demo dataset
                Write-Phase "Phase 4f: Demo Dataset — Generate"

                $demoDir = Join-Path $RepoRoot 'test/demo-dataset'
                try {
                    & (Join-Path $demoDir 'Generate-DemoDataset.ps1') 2>&1 |
                        Tee-Object -FilePath (Join-Path $LogFolder 'demo-generate.log')
                    $datasetExists = Test-Path (Join-Path $demoDir 'demo-company.json')
                    Write-Result 'Demo-Generate' $datasetExists
                }
                catch {
                    Write-Result 'Demo-Generate' $false $_.Exception.Message
                }

                Write-Phase "Phase 4g: Demo Dataset — Ingest"

                try {
                    & (Join-Path $demoDir 'Ingest-DemoDataset.ps1') -ApiKey $crawlerKey -ApiBaseUrl $apiBaseUrl 2>&1 |
                        Tee-Object -FilePath (Join-Path $LogFolder 'demo-ingest.log')
                    Write-Result 'Demo-Ingest' ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq $null)
                }
                catch {
                    Write-Result 'Demo-Ingest' $false $_.Exception.Message
                }

                Write-Phase "Phase 4h: Demo Dataset — Verify (Row Counts + Integrity + Business Logic)"

                try {
                    & (Join-Path $demoDir 'Verify-DemoDataset.ps1') -ApiBaseUrl $apiBaseUrl 2>&1 |
                        Tee-Object -FilePath (Join-Path $LogFolder 'demo-verify.log')
                    $verifyExitCode = $LASTEXITCODE
                    Write-Result 'Demo-Verify' ($verifyExitCode -eq 0) "Failed checks: $verifyExitCode"

                    # Copy detailed results
                    $verifyJson = Join-Path $demoDir 'verify-results.json'
                    if (Test-Path $verifyJson) {
                        Copy-Item $verifyJson (Join-Path $LogFolder 'demo-verify-results.json') -Force
                    }
                }
                catch {
                    Write-Result 'Demo-Verify' $false $_.Exception.Message
                }

                # Also run CSV crawler against legacy dataset (if exists)
                Write-Phase "Phase 4i: CSV Crawler (Legacy Dataset)"

                if (Test-Path $CsvDataset) {
                    try {
                        $crawlerScript = Join-Path $RepoRoot 'tools/crawlers/csv/Start-CSVCrawler.ps1'
                        & $crawlerScript -ApiBaseUrl $apiBaseUrl -ApiKey $crawlerKey -CsvFolder $CsvDataset `
                            -SystemName 'Nightly Test Omada' -SystemType 'Omada' 2>&1 |
                            Tee-Object -FilePath (Join-Path $LogFolder 'csv-crawler.log')
                        Write-Result 'CSV-Crawler-Run' ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq $null)
                    }
                    catch {
                        Write-Result 'CSV-Crawler-Run' $false $_.Exception.Message
                    }
                }
                else {
                    Write-Host "  Skipping (no CSV dataset at $CsvDataset)" -ForegroundColor Yellow
                }

                # ─── Phase 4j: Entra ID crawler scenarios ────────────────────
                # Exercises the real crawler against a test tenant. Credentials
                # come from test/test.secrets.json or env vars; if neither is set,
                # the step skips itself with a clear message (treated as PASS).
                Write-Phase "Phase 4j: Entra ID Crawler Scenarios"

                $entraTestScript = Join-Path $PSScriptRoot 'Test-EntraIdCrawler.ps1'
                if (Test-Path $entraTestScript) {
                    try {
                        # Hand the script our Write-Result so its assertions
                        # show up in the unified report alongside the rest.
                        & $entraTestScript `
                            -ApiBaseUrl $apiBaseUrl `
                            -ApiKey     $crawlerKey `
                            -LogFolder  $LogFolder `
                            -WriteResult ${function:Write-Result}
                    } catch {
                        Write-Result 'EntraID-Crawler-Tests' $false $_.Exception.Message
                    }
                } else {
                    Write-Host "  Skipping (Test-EntraIdCrawler.ps1 not found)" -ForegroundColor Yellow
                }
            }
        }

        # Backend integration tests (if vitest is set up)
        Write-Phase "Phase 4k: Backend Integration Tests"

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
Write-Host "║  Report:   $LogFolder\report.md" -ForegroundColor White
Write-Host "║  Latest:   test\nightly\results\latest.md" -ForegroundColor White
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

# ─── Markdown report (for morning review) ────────────────────────
# Designed to be skimmable: status badge at the top, big PASS/FAIL counts,
# all failures up front with their detail messages, then full results table
# at the bottom for completeness. Open it in any markdown viewer.
$mdLines = [System.Collections.Generic.List[string]]::new()
$badge = if ($failedTests -eq 0) { '🟢 ALL PASS' } else { "🔴 $failedTests FAILED" }

$mdLines.Add("# Nightly Test Run — $($startTime.ToString('yyyy-MM-dd HH:mm'))")
$mdLines.Add('')
$mdLines.Add("**Status:** $badge")
$mdLines.Add('')
$mdLines.Add('| Metric | Value |')
$mdLines.Add('|---|---|')
$mdLines.Add("| Total | $totalTests |")
$mdLines.Add("| Passed | $passedTests |")
$mdLines.Add("| Failed | $failedTests |")
$mdLines.Add("| Duration | $([Math]::Round($elapsed.TotalMinutes, 1)) min |")
$mdLines.Add("| Started | $($startTime.ToString('yyyy-MM-dd HH:mm:ss')) |")
$mdLines.Add("| Finished | $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) |")
$mdLines.Add("| Log folder | ``$LogFolder`` |")
$mdLines.Add('')

if ($failedTests -gt 0) {
    $mdLines.Add('## ❌ Failures')
    $mdLines.Add('')
    foreach ($name in ($results.Keys | Sort-Object)) {
        $r = $results[$name]
        if (-not $r.Passed) {
            $mdLines.Add("### $name")
            if ($r.Detail) {
                $mdLines.Add('')
                $mdLines.Add('```')
                $mdLines.Add($r.Detail)
                $mdLines.Add('```')
            }
            $mdLines.Add('')
        }
    }
} else {
    $mdLines.Add('## ✅ All checks passed')
    $mdLines.Add('')
}

$mdLines.Add('## All Results')
$mdLines.Add('')
$mdLines.Add('| Status | Test | Detail |')
$mdLines.Add('|---|---|---|')
foreach ($name in ($results.Keys | Sort-Object)) {
    $r = $results[$name]
    $icon = if ($r.Passed) { '✅' } else { '❌' }
    # Pipe-escape the detail so the markdown table doesn't get mangled
    $detail = if ($r.Detail) { $r.Detail -replace '\|','\|' -replace '\r?\n',' ' } else { '' }
    if ($detail.Length -gt 200) { $detail = $detail.Substring(0, 197) + '...' }
    $mdLines.Add("| $icon | $name | $detail |")
}
$mdLines.Add('')
$mdLines.Add('---')
$mdLines.Add('')
$mdLines.Add("Generated by ``test/nightly/Run-NightlyLocal.ps1``. Full per-test logs are alongside this file in ``$LogFolder``.")

$mdPath = Join-Path $LogFolder 'report.md'
$mdLines | Out-File -FilePath $mdPath -Encoding UTF8

# Also write/overwrite a "latest" pointer at a fixed location so you can always
# bookmark the same path in your editor / file explorer.
$latestPath = Join-Path (Split-Path $LogFolder -Parent) 'latest.md'
try {
    Copy-Item -Path $mdPath -Destination $latestPath -Force
} catch {
    # Non-fatal — the dated copy is the source of truth
}

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
