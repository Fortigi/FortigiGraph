<#
.SYNOPSIS
    Nightly test step: exercise the Entra ID crawler end-to-end against a real
    tenant. Designed to be called from Run-NightlyLocal.ps1 but also runnable
    standalone for ad-hoc verification.

.DESCRIPTION
    Runs a series of scenarios that hit different code paths through the crawler:

      1. Validate-Only       — POST /admin/validate-graph-credentials only.
                               Confirms creds + permission detection work.
      2. Identity-Only       — selectedObjects = { identity: true }.
                               Smallest possible sync (users + identities).
      3. Users-Groups        — selectedObjects = { usersGroupsMembers: true }.
                               Hits the parallel group-children fetcher.
      4. Full-Sync           — all object types enabled.
                               Hits governance, directory roles, app roles too.
      5. With-Identity-Filter — Full sync + identity filter on a real attribute.
                               Verifies the filter logic doesn't break the run.

    Each scenario:
      - Deletes any leftover config from a previous run (deterministic state).
      - POSTs the config via /api/admin/crawler-configs.
      - POSTs a job via /api/admin/crawler-jobs (with configId).
      - Polls /api/admin/crawler-jobs/:id every 3s until terminal state.
      - Asserts: status == 'completed' AND duration < timeout AND optional
        post-sync queries return non-zero counts where expected.
      - Records pass/fail back to the parent runner via the supplied
        WriteResult callback.

    Credentials are loaded in this order (first hit wins):
      1. Environment variables (TEST_GRAPH_TENANT_ID / CLIENT_ID / CLIENT_SECRET)
      2. test/test.secrets.json (gitignored)
    If neither is available, the entire phase is skipped with a clear message
    so CI runs without secrets just see a "skipped" entry instead of failing.

.PARAMETER ApiBaseUrl
    Base URL of the Identity Atlas API. Default: http://localhost:3001/api

.PARAMETER ApiKey
    Crawler API key for the built-in worker (issued by /api/admin/crawlers).
    The parent runner extracts this earlier in the pipeline.

.PARAMETER LogFolder
    Where to write per-scenario logs. Created if missing.

.PARAMETER WriteResult
    ScriptBlock signature: { param($Name, $Passed, $Detail) ... }
    Lets the parent runner record results into its central hashtable. When
    omitted (standalone use), results are printed and a final exit code is
    returned (count of failures).

.PARAMETER PerJobTimeoutSeconds
    How long to wait for an individual scenario job before declaring failure.
    Default: 600 (10 minutes). The iidemo tenant should complete in <60s
    even at full sync, so 600 is a generous safety net.

.PARAMETER Scenarios
    Optional array of scenario names to run. Default: all five.
    Useful for ad-hoc debugging: -Scenarios 'Validate-Only','Identity-Only'

.PARAMETER KeepConfigs
    Don't delete the test CrawlerConfigs at the end. Default: configs are
    cleaned up so the next run starts fresh and the Configured Crawlers UI
    doesn't fill up with test entries.

.EXAMPLE
    pwsh -File test\nightly\Test-EntraIdCrawler.ps1 `
        -ApiBaseUrl http://localhost:3001/api -ApiKey fgc_abc... `
        -LogFolder C:\tmp\entra-test
#>

[CmdletBinding()]
Param(
    [string]$ApiBaseUrl = 'http://localhost:3001/api',
    [Parameter(Mandatory)] [string]$ApiKey,
    [Parameter(Mandatory)] [string]$LogFolder,
    [scriptblock]$WriteResult,
    [int]$PerJobTimeoutSeconds = 600,
    [string[]]$Scenarios,
    [switch]$KeepConfigs
)

$ErrorActionPreference = 'Continue'
$ApiBaseUrl = $ApiBaseUrl.TrimEnd('/')

# A consistent display-name prefix so we can find and clean up our own configs
# without touching anything the user created manually.
$ConfigPrefix = 'NightlyTest — '

# Default scenarios when -Scenarios isn't passed.
$AllScenarios = @(
    'Validate-Only',
    'Identity-Only',
    'Users-Groups',
    'Full-Sync',
    'With-Identity-Filter'
)
if (-not $Scenarios -or $Scenarios.Count -eq 0) { $Scenarios = $AllScenarios }

if (-not (Test-Path $LogFolder)) {
    New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null
}

# ─── Result reporting ────────────────────────────────────────────
# When called from Run-NightlyLocal.ps1, results flow back via $WriteResult.
# When run standalone, we keep our own counter so the script can return a
# meaningful exit code.
$standaloneFailures = 0
function Report-Result {
    param([string]$Name, [bool]$Passed, [string]$Detail = '')
    $color = if ($Passed) { 'Green' } else { 'Red' }
    $status = if ($Passed) { 'PASS' } else { 'FAIL' }
    Write-Host "  $status  $Name  $Detail" -ForegroundColor $color
    if ($WriteResult) {
        & $WriteResult $Name $Passed $Detail
    } elseif (-not $Passed) {
        $script:standaloneFailures++
    }
}

# ─── Credential loading ──────────────────────────────────────────
function Get-TestGraphCreds {
    # 1. Environment variables take precedence so CI can inject without writing files.
    $envTenant = $env:TEST_GRAPH_TENANT_ID
    $envClient = $env:TEST_GRAPH_CLIENT_ID
    $envSecret = $env:TEST_GRAPH_CLIENT_SECRET
    if ($envTenant -and $envClient -and $envSecret) {
        return @{ tenantId = $envTenant; clientId = $envClient; clientSecret = $envSecret; source = 'env vars' }
    }

    # 2. Fall back to the gitignored secrets file.
    $secretsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'test.secrets.json'
    if (Test-Path $secretsPath) {
        try {
            $j = Get-Content $secretsPath -Raw | ConvertFrom-Json
            if ($j.graph.tenantId -and $j.graph.clientId -and $j.graph.clientSecret) {
                # Reject the template placeholder so a forgotten copy doesn't show as a real cred
                if ($j.graph.tenantId -match '^0{8}-0{4}') {
                    Write-Host "  Note: test.secrets.json still contains placeholder values" -ForegroundColor Yellow
                    return $null
                }
                return @{
                    tenantId     = $j.graph.tenantId
                    clientId     = $j.graph.clientId
                    clientSecret = $j.graph.clientSecret
                    source       = 'test.secrets.json'
                }
            }
        } catch {
            Write-Host "  Note: failed to parse test.secrets.json — $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    return $null
}

$creds = Get-TestGraphCreds
if (-not $creds) {
    Write-Host "  SKIP  Entra ID crawler tests — no test credentials available" -ForegroundColor Yellow
    Write-Host "        Set TEST_GRAPH_TENANT_ID/CLIENT_ID/CLIENT_SECRET env vars" -ForegroundColor Gray
    Write-Host "        OR copy test/test.secrets.json.template to test/test.secrets.json and fill it in" -ForegroundColor Gray
    if ($WriteResult) {
        & $WriteResult 'EntraID-Crawler-Tests' $true 'skipped (no creds)'
    }
    return 0
}
Write-Host "  Credentials loaded from $($creds.source) — tenant $($creds.tenantId)" -ForegroundColor Gray

# ─── HTTP helpers ─────────────────────────────────────────────────
# These talk to the local Identity Atlas API directly. Auth is the user-facing
# layer (no auth in local Docker by default), so no bearer needed for /admin/*.
# The crawler API key is only required for /api/ingest/* and /api/crawlers/*.
function Invoke-LocalApi {
    param([string]$Path, [string]$Method = 'GET', $Body = $null)
    $uri = "$ApiBaseUrl$Path"
    $params = @{ Uri = $uri; Method = $Method; TimeoutSec = 30; ErrorAction = 'Stop' }
    if ($Body) {
        $params['ContentType'] = 'application/json'
        $params['Body']        = ($Body | ConvertTo-Json -Depth 10 -Compress)
    }
    return Invoke-RestMethod @params
}

# ─── Cleanup helpers ─────────────────────────────────────────────
function Remove-PreviousNightlyConfigs {
    # Wipe any test configs left behind by an earlier run so we start clean.
    try {
        $existing = Invoke-LocalApi -Path '/admin/crawler-configs'
        foreach ($c in $existing) {
            if ($c.displayName -and $c.displayName.StartsWith($ConfigPrefix)) {
                try {
                    Invoke-LocalApi -Path "/admin/crawler-configs/$($c.id)" -Method DELETE | Out-Null
                } catch {
                    Write-Host "    cleanup: failed to delete config $($c.id) — $($_.Exception.Message)" -ForegroundColor DarkGray
                }
            }
        }
    } catch {
        Write-Host "    cleanup: list configs failed — $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}

# ─── Wait-for-job poller ──────────────────────────────────────────
# Polls /admin/crawler-jobs/:id at 3s intervals, returns the final job object.
# Times out (returns $null + error message) at PerJobTimeoutSeconds.
function Wait-ForJob {
    param([int]$JobId, [string]$ScenarioName)
    $deadline = (Get-Date).AddSeconds($PerJobTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        try {
            $job = Invoke-LocalApi -Path "/admin/crawler-jobs/$JobId"
        } catch {
            return @{ ok = $false; reason = "polling failed: $($_.Exception.Message)" }
        }
        if ($job.status -in @('completed','failed','cancelled')) {
            return @{ ok = ($job.status -eq 'completed'); job = $job; reason = "ended in $($job.status)" }
        }
    }
    return @{ ok = $false; reason = "timeout after ${PerJobTimeoutSeconds}s" }
}

# ─── Scenario runner ──────────────────────────────────────────────
# Builds a CrawlerConfig, queues a job, waits, runs assertions. Each scenario
# is fully self-contained so a failure in one doesn't poison the others.
function Invoke-Scenario {
    param(
        [string]$Name,
        [hashtable]$SelectedObjects,
        [hashtable]$IdentityFilter = $null,
        [scriptblock]$ExtraAssertions = $null
    )

    $displayName = "$ConfigPrefix$Name"
    $scenarioStart = Get-Date

    # 1. Build the config payload (same shape the wizard sends)
    $configPayload = @{
        tenantId        = $creds.tenantId
        clientId        = $creds.clientId
        clientSecret    = $creds.clientSecret
        selectedObjects = $SelectedObjects
    }
    if ($IdentityFilter) { $configPayload['identityFilter'] = $IdentityFilter }

    try {
        $config = Invoke-LocalApi -Path '/admin/crawler-configs' -Method POST -Body @{
            crawlerType = 'entra-id'
            displayName = $displayName
            config      = $configPayload
        }
    } catch {
        Report-Result "EntraID/$Name/CreateConfig" $false $_.Exception.Message
        return
    }
    Report-Result "EntraID/$Name/CreateConfig" $true "id=$($config.id)"

    # 2. Queue the job
    try {
        $job = Invoke-LocalApi -Path '/admin/crawler-jobs' -Method POST -Body @{
            jobType  = 'entra-id'
            configId = $config.id
        }
    } catch {
        Report-Result "EntraID/$Name/QueueJob" $false $_.Exception.Message
        return
    }
    Report-Result "EntraID/$Name/QueueJob" $true "jobId=$($job.id)"

    # 3. Wait for the job to finish
    $waitResult = Wait-ForJob -JobId $job.id -ScenarioName $Name
    $duration = [Math]::Round(((Get-Date) - $scenarioStart).TotalSeconds, 1)
    if (-not $waitResult.ok) {
        $detail = "$($waitResult.reason) after ${duration}s"
        if ($waitResult.job -and $waitResult.job.errorMessage) {
            $detail += " | $($waitResult.job.errorMessage)"
        }
        Report-Result "EntraID/$Name/JobCompleted" $false $detail
        # Still drop a per-scenario log file with the final job state for debugging
        if ($waitResult.job) {
            $waitResult.job | ConvertTo-Json -Depth 10 |
                Out-File (Join-Path $LogFolder "entra-$Name.json") -Encoding UTF8
        }
        return
    }
    Report-Result "EntraID/$Name/JobCompleted" $true "${duration}s"

    # 4. Save the final job state for forensic review
    $waitResult.job | ConvertTo-Json -Depth 10 |
        Out-File (Join-Path $LogFolder "entra-$Name.json") -Encoding UTF8

    # 5. Optional extra assertions (e.g. row counts via the read API)
    if ($ExtraAssertions) {
        try {
            & $ExtraAssertions
        } catch {
            Report-Result "EntraID/$Name/Assertions" $false $_.Exception.Message
        }
    }
}

# ─── Pre-flight: validate creds before running any scenario ───────
# We do this once even though it's also implicitly tested below — fast feedback
# if the secrets file is wrong before we burn time on a job.
Write-Host "  Pre-flight: validating credentials..." -ForegroundColor Gray
try {
    $vr = Invoke-LocalApi -Path '/admin/validate-graph-credentials' -Method POST -Body @{
        tenantId     = $creds.tenantId
        clientId     = $creds.clientId
        clientSecret = $creds.clientSecret
    }
    if (-not $vr.valid) {
        Report-Result 'EntraID/Validate-Only' $false ($vr.error ?? 'validation returned valid=false')
        if ($WriteResult) { & $WriteResult 'EntraID-Crawler-Tests' $false 'pre-flight validation failed' }
        return
    }
    $grantedCount = ($vr.permissions.PSObject.Properties | Where-Object { $_.Value }).Count
    Report-Result 'EntraID/Validate-Only' $true "org=$($vr.organization) · $grantedCount permissions granted"
} catch {
    Report-Result 'EntraID/Validate-Only' $false $_.Exception.Message
    if ($WriteResult) { & $WriteResult 'EntraID-Crawler-Tests' $false 'pre-flight validation threw' }
    return
}

# ─── Clean previous test configs ──────────────────────────────────
Write-Host "  Cleaning up previous test configs..." -ForegroundColor Gray
Remove-PreviousNightlyConfigs

# ─── Helper: simple read-API count assertion ──────────────────────
function Assert-ApiCount {
    param([string]$Name, [string]$Path, [int]$MinExpected = 1)
    try {
        $r = Invoke-LocalApi -Path $Path
        # Try a few common shapes: { total }, { data: [...] }, [...]
        $count = $null
        if ($r.PSObject.Properties.Name -contains 'total') { $count = [int]$r.total }
        elseif ($r.PSObject.Properties.Name -contains 'data') { $count = $r.data.Count }
        elseif ($r -is [array]) { $count = $r.Count }
        if ($count -ge $MinExpected) {
            Report-Result $Name $true "count=$count"
        } else {
            Report-Result $Name $false "expected >=$MinExpected, got $count"
        }
    } catch {
        Report-Result $Name $false $_.Exception.Message
    }
}

# ─── Run requested scenarios ──────────────────────────────────────
foreach ($scenario in $Scenarios) {
    Write-Host "`n  ── Scenario: $scenario ──" -ForegroundColor Cyan
    switch ($scenario) {
        'Validate-Only' {
            # Already covered by pre-flight above. Recording as an explicit
            # entry too so it shows up under each run for traceability.
            Report-Result 'EntraID/Validate-Only/Scenario' $true 'covered by pre-flight'
        }

        'Identity-Only' {
            Invoke-Scenario -Name 'Identity-Only' `
                -SelectedObjects @{ identity = $true; context = $false; usersGroupsMembers = $false; identityGovernance = $false } `
                -ExtraAssertions {
                    Assert-ApiCount -Name 'EntraID/Identity-Only/UsersExist' -Path '/users?pageSize=1' -MinExpected 1
                }
        }

        'Users-Groups' {
            Invoke-Scenario -Name 'Users-Groups' `
                -SelectedObjects @{ identity = $false; usersGroupsMembers = $true; identityGovernance = $false } `
                -ExtraAssertions {
                    Assert-ApiCount -Name 'EntraID/Users-Groups/UsersExist'     -Path '/users?pageSize=1'     -MinExpected 1
                    Assert-ApiCount -Name 'EntraID/Users-Groups/ResourcesExist' -Path '/resources?pageSize=1' -MinExpected 1
                }
        }

        'Full-Sync' {
            Invoke-Scenario -Name 'Full-Sync' `
                -SelectedObjects @{
                    identity           = $true
                    context            = $true
                    usersGroupsMembers = $true
                    identityGovernance = $true
                    appsAppRoles       = $true
                    directoryRoles     = $true
                } `
                -ExtraAssertions {
                    Assert-ApiCount -Name 'EntraID/Full-Sync/UsersExist'         -Path '/users?pageSize=1'           -MinExpected 1
                    Assert-ApiCount -Name 'EntraID/Full-Sync/ResourcesExist'     -Path '/resources?pageSize=1'       -MinExpected 1
                    Assert-ApiCount -Name 'EntraID/Full-Sync/SystemsExist'       -Path '/systems'                    -MinExpected 1
                    # Regression checks for the three areas the UI exposes after a crawler run.
                    # These caught a real outage in April 2026 where the routes were silently
                    # returning empty results due to T-SQL leftovers / wrong column-name casing.
                    Assert-ApiCount -Name 'EntraID/Full-Sync/BusinessRolesPage'  -Path '/access-packages?limit=1'    -MinExpected 1
                    Assert-ApiCount -Name 'EntraID/Full-Sync/SyncLogPage'        -Path '/sync-log?limit=1'           -MinExpected 1
                    Assert-ApiCount -Name 'EntraID/Full-Sync/MatrixHasData'      -Path '/permissions?userLimit=5'    -MinExpected 1
                }
        }

        'With-Identity-Filter' {
            # Simple, broadly-applicable filter: identities are users that have
            # an employeeId set. Works on most tenants. If iidemo doesn't set
            # employeeId on anyone the count check will catch it cleanly.
            Invoke-Scenario -Name 'With-Identity-Filter' `
                -SelectedObjects @{
                    identity           = $true
                    usersGroupsMembers = $true
                    identityGovernance = $false
                } `
                -IdentityFilter @{ attribute = 'employeeId'; condition = 'isNotNull' } `
                -ExtraAssertions {
                    Assert-ApiCount -Name 'EntraID/With-Identity-Filter/UsersExist' -Path '/users?pageSize=1' -MinExpected 1
                    # Identities count check is best-effort: tenant may have zero
                    # users with employeeId. We just verify the endpoint responds.
                    try {
                        Invoke-LocalApi -Path '/identities?pageSize=1' | Out-Null
                        Report-Result 'EntraID/With-Identity-Filter/IdentitiesQueryable' $true ''
                    } catch {
                        Report-Result 'EntraID/With-Identity-Filter/IdentitiesQueryable' $false $_.Exception.Message
                    }
                }
        }

        default {
            Write-Host "    Unknown scenario: $scenario — skipping" -ForegroundColor Yellow
        }
    }
}

# ─── Final cleanup ────────────────────────────────────────────────
if (-not $KeepConfigs) {
    Write-Host "`n  Removing test configs..." -ForegroundColor Gray
    Remove-PreviousNightlyConfigs
}

# Standalone exit code
if (-not $WriteResult) {
    exit $standaloneFailures
}
