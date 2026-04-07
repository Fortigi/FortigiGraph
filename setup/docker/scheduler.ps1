<#
.SYNOPSIS
    PowerShell-based scheduler and job runner for the Identity Atlas worker container.

.DESCRIPTION
    Two responsibilities:
    1. Crontab scheduler — reads docker/crontab and executes matching jobs on schedule
    2. Job queue poller  — picks up CrawlerJobs from SQL (created by the UI) and runs them

    The container stays alive for ad-hoc commands:
        docker exec -it fortigigraph-worker-1 pwsh

    Crontab format: minute hour day-of-month month day-of-week command
    Lines starting with # are ignored. Empty lines are ignored.
    Only supports exact numeric values and * (wildcards). No ranges or step values.
#>

$ErrorActionPreference = 'Continue'

Write-Host "Identity Atlas Worker Container" -ForegroundColor Cyan
Write-Host "===============================" -ForegroundColor Cyan
Write-Host "  SQL:    $($env:SQL_SERVER)/$($env:SQL_DATABASE)" -ForegroundColor Gray
Write-Host "  Time:   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')" -ForegroundColor Gray
Write-Host ""

# Pre-load the module so it's ready for any job
try {
    Import-Module /app/setup/IdentityAtlas.psd1 -Force
    Write-Host "  Module loaded successfully" -ForegroundColor Green
}
catch {
    Write-Host "  Module load failed: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Set up SQL connection for direct-SQL jobs (risk scoring, account correlation)
$Global:FGSQLConnectionString = "Server=$($env:SQL_SERVER);Database=$($env:SQL_DATABASE);User Id=$($env:SQL_USER);Password=$($env:SQL_PASSWORD);TrustServerCertificate=True"

# ── Discover built-in API key ─────────────────────────────────────────────────
# The backend auto-creates a Built-in Worker crawler and stores the plaintext key
# in dbo.WorkerConfig. Poll until available (backend may still be starting).

$Global:BuiltinApiKey = $null

if ($env:CRAWLER_API_KEY) {
    $Global:BuiltinApiKey = $env:CRAWLER_API_KEY
    Write-Host "  API key: from environment variable" -ForegroundColor Green
} else {
    Write-Host "  Discovering API key from WorkerConfig..." -ForegroundColor Gray
    for ($i = 0; $i -lt 24; $i++) {
        try {
            $result = Invoke-FGSQLQuery -Query "SELECT configValue FROM dbo.WorkerConfig WHERE configKey = 'BUILTIN_CRAWLER_API_KEY'"
            if ($result -and $result.configValue) {
                $Global:BuiltinApiKey = $result.configValue
                Write-Host "  API key: discovered from SQL (prefix: $($result.configValue.Substring(0, 8)))" -ForegroundColor Green
                break
            }
        }
        catch {
            # Table may not exist yet — backend hasn't bootstrapped
        }
        if ($i -lt 23) { Start-Sleep -Seconds 5 }
    }
    if (-not $Global:BuiltinApiKey) {
        Write-Host "  API key: not found (job queue will not work until backend bootstraps)" -ForegroundColor Yellow
    }
}

# ── Parse crontab ─────────────────────────────────────────────────────────────

$crontabPath = '/app/setup/docker/crontab'
$cronJobs = @()

if (Test-Path $crontabPath) {
    $lines = Get-Content $crontabPath | Where-Object { $_ -and $_ -notmatch '^\s*#' -and $_.Trim() -ne '' }
    foreach ($line in $lines) {
        $parts = $line.Trim() -split '\s+', 6
        if ($parts.Count -ge 6) {
            $cronJobs += @{
                Minute     = $parts[0]
                Hour       = $parts[1]
                DayOfMonth = $parts[2]
                Month      = $parts[3]
                DayOfWeek  = $parts[4]
                Command    = $parts[5]
            }
        }
    }
    Write-Host "  Loaded $($cronJobs.Count) scheduled job(s) from crontab" -ForegroundColor Green
}
else {
    Write-Host "  No crontab found at $crontabPath" -ForegroundColor Yellow
}

if ($cronJobs.Count -eq 0 -and -not $Global:BuiltinApiKey) {
    Write-Host ""
    Write-Host "  No cron jobs and no API key. Container stays running for ad-hoc commands." -ForegroundColor Yellow
    Write-Host "  Use: docker exec -it fortigigraph-worker-1 pwsh" -ForegroundColor Yellow
}

Write-Host ""

function Test-CronMatch {
    param([string]$CronValue, [int]$CurrentValue)
    if ($CronValue -eq '*') { return $true }
    return [int]$CronValue -eq $CurrentValue
}

# ── Job queue poller ──────────────────────────────────────────────────────────

function Invoke-PendingJob {
    <#
    .SYNOPSIS
        Atomically claims and executes the next queued CrawlerJob.
    #>
    if (-not $Global:BuiltinApiKey) { return }

    try {
        # Atomic claim: UPDATE...OUTPUT prevents double-pickup
        # Use subquery because UPDATE TOP does not support ORDER BY in T-SQL
        $job = Invoke-FGSQLQuery -Query "
            UPDATE dbo.CrawlerJobs
            SET status = 'running', startedAt = SYSUTCDATETIME()
            OUTPUT INSERTED.id, INSERTED.jobType, INSERTED.config
            WHERE id = (
                SELECT TOP(1) id FROM dbo.CrawlerJobs
                WHERE status = 'queued'
                ORDER BY createdAt ASC
            )"

        if (-not $job) { return }

        $jobId = $job.id
        $jobType = $job.jobType
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Job $jobId ($jobType): starting..." -ForegroundColor Cyan

        # Parse config JSON
        $config = @{}
        if ($job.config) {
            $config = $job.config | ConvertFrom-Json -AsHashtable
        }

        # Dispatch to the job runner script
        try {
            & /app/setup/docker/Invoke-CrawlerJob.ps1 `
                -JobId $jobId `
                -JobType $jobType `
                -Config $config `
                -ApiKey $Global:BuiltinApiKey

            # Mark completed
            Invoke-FGSQLQuery -Query "
                UPDATE dbo.CrawlerJobs
                SET status = 'completed', completedAt = SYSUTCDATETIME()
                WHERE id = $jobId"

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Job $jobId ($jobType): completed" -ForegroundColor Green
        }
        catch {
            # Capture the full error including any inner exceptions
            $errMsg = $_.Exception.Message
            if ($_.ErrorDetails.Message) {
                $errMsg = "$errMsg | $($_.ErrorDetails.Message)"
            }
            $errMsg = ($errMsg -replace "'", "''").Substring(0, [Math]::Min($errMsg.Length, 2000))
            Invoke-FGSQLQuery -Query "
                UPDATE dbo.CrawlerJobs
                SET status = 'failed', completedAt = SYSUTCDATETIME(),
                    errorMessage = '$errMsg'
                WHERE id = $jobId"

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Job $jobId ($jobType): FAILED — $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    catch {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Job queue poll error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ── Scheduled crawlers from CrawlerConfigs ────────────────────────────────────

function Invoke-ScheduledCrawlers {
    <#
    .SYNOPSIS
        Checks CrawlerConfigs for scheduled crawlers and queues jobs when they match.
        Schedule format in config JSON: { "schedule": { "enabled": true, "frequency": "daily", "hour": 2, "minute": 0 } }
        Supported frequencies: hourly, daily, weekly (day 0-6, 0=Sunday)
    #>
    if (-not $Global:BuiltinApiKey) { return }

    try {
        $configs = Invoke-FGSQLQuery -Query "
            SELECT id, crawlerType, config
            FROM dbo.CrawlerConfigs
            WHERE enabled = 1"

        if (-not $configs) { return }
        # Handle single row (not array)
        if ($configs -isnot [array]) { $configs = @($configs) }

        $now = Get-Date
        foreach ($cfg in $configs) {
            $parsed = $cfg.config | ConvertFrom-Json -AsHashtable

            # Build list of schedules — supports both `schedules` (array) and legacy `schedule` (single)
            $schedList = @()
            if ($parsed['schedules'] -and $parsed['schedules'] -is [array]) {
                $schedList = $parsed['schedules']
            } elseif ($parsed['schedule']) {
                $schedList = @($parsed['schedule'])
            }
            if ($schedList.Count -eq 0) { continue }

            $shouldRun = $false
            foreach ($sched in $schedList) {
                if (-not $sched['enabled']) { continue }

                $freq = $sched['frequency']
                $schedHour = [int]($sched['hour'] ?? 2)
                $schedMinute = [int]($sched['minute'] ?? 0)
                $schedDay = [int]($sched['day'] ?? 0)

                switch ($freq) {
                    'hourly' {
                        if ($now.Minute -eq $schedMinute) { $shouldRun = $true }
                    }
                    'daily' {
                        if ($now.Hour -eq $schedHour -and $now.Minute -eq $schedMinute) { $shouldRun = $true }
                    }
                    'weekly' {
                        if ([int]$now.DayOfWeek -eq $schedDay -and $now.Hour -eq $schedHour -and $now.Minute -eq $schedMinute) { $shouldRun = $true }
                    }
                }
                if ($shouldRun) { break }
            }

            if ($shouldRun) {
                # Check if a job for this config is already queued or running
                $existing = Invoke-FGSQLQuery -Query "
                    SELECT 1 FROM dbo.CrawlerJobs
                    WHERE jobType = '$($cfg.crawlerType)' AND status IN ('queued','running')
                    AND config LIKE '%""tenantId"":""$($parsed['tenantId'])%'"
                if (-not $existing) {
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Schedule: queuing $($cfg.crawlerType) job (config $($cfg.id))" -ForegroundColor Cyan
                    Invoke-FGSQLQuery -Query "
                        INSERT INTO dbo.CrawlerJobs (jobType, config, createdBy)
                        VALUES ('$($cfg.crawlerType)', '$($cfg.config -replace "'","''")', 'scheduler')"
                    # Update lastRunAt
                    Invoke-FGSQLQuery -Query "
                        UPDATE dbo.CrawlerConfigs SET lastRunAt = SYSUTCDATETIME() WHERE id = $($cfg.id)"
                }
            }
        }
    }
    catch {
        # Non-critical — don't crash the loop
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Schedule check error: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ── Main loop — check schedules every minute, poll jobs every 30 seconds ──────

$lastMinute = -1
while ($true) {
    $now = Get-Date
    $currentMinute = $now.Minute

    # Once per minute: check crontab + scheduled configs
    if ($currentMinute -ne $lastMinute) {
        $lastMinute = $currentMinute

        # Legacy crontab
        foreach ($cj in $cronJobs) {
            $match = (Test-CronMatch $cj.Minute $now.Minute) -and
                     (Test-CronMatch $cj.Hour $now.Hour) -and
                     (Test-CronMatch $cj.DayOfMonth $now.Day) -and
                     (Test-CronMatch $cj.Month $now.Month) -and
                     (Test-CronMatch $cj.DayOfWeek ([int]$now.DayOfWeek))

            if ($match) {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Cron: $($cj.Command)" -ForegroundColor Cyan
                try {
                    $cmd = [System.Environment]::ExpandEnvironmentVariables($cj.Command)
                    Invoke-Expression $cmd 2>&1 | ForEach-Object { Write-Host "  $_" }
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Cron job completed" -ForegroundColor Green
                }
                catch {
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Cron job failed: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }

        # Scheduled crawler configs
        Invoke-ScheduledCrawlers
    }

    # Job queue check (every iteration)
    Invoke-PendingJob

    Start-Sleep -Seconds 30
}
