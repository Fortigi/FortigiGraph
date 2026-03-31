<#
.SYNOPSIS
    Simple PowerShell-based scheduler for the FortigiGraph worker container.

.DESCRIPTION
    Reads docker/crontab and executes matching jobs at the scheduled times.
    Also keeps the container alive so you can exec into it for ad-hoc commands:

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

# Parse crontab
$crontabPath = '/app/setup/docker/crontab'
$jobs = @()

if (Test-Path $crontabPath) {
    $lines = Get-Content $crontabPath | Where-Object { $_ -and $_ -notmatch '^\s*#' -and $_.Trim() -ne '' }
    foreach ($line in $lines) {
        $parts = $line.Trim() -split '\s+', 6
        if ($parts.Count -ge 6) {
            $jobs += @{
                Minute     = $parts[0]
                Hour       = $parts[1]
                DayOfMonth = $parts[2]
                Month      = $parts[3]
                DayOfWeek  = $parts[4]
                Command    = $parts[5]
            }
        }
    }
    Write-Host "  Loaded $($jobs.Count) scheduled job(s) from crontab" -ForegroundColor Green
}
else {
    Write-Host "  No crontab found at $crontabPath" -ForegroundColor Yellow
}

if ($jobs.Count -eq 0) {
    Write-Host ""
    Write-Host "  No jobs scheduled. Container stays running for ad-hoc commands." -ForegroundColor Yellow
    Write-Host "  Use: docker exec -it fortigigraph-worker-1 pwsh" -ForegroundColor Yellow
    Write-Host ""
}

function Test-CronMatch {
    param([string]$CronValue, [int]$CurrentValue)
    if ($CronValue -eq '*') { return $true }
    return [int]$CronValue -eq $CurrentValue
}

# Main loop — check every 60 seconds
$lastMinute = -1
while ($true) {
    $now = Get-Date
    $currentMinute = $now.Minute

    # Only check once per minute
    if ($currentMinute -ne $lastMinute -and $jobs.Count -gt 0) {
        $lastMinute = $currentMinute

        foreach ($job in $jobs) {
            $match = (Test-CronMatch $job.Minute $now.Minute) -and
                     (Test-CronMatch $job.Hour $now.Hour) -and
                     (Test-CronMatch $job.DayOfMonth $now.Day) -and
                     (Test-CronMatch $job.Month $now.Month) -and
                     (Test-CronMatch $job.DayOfWeek ([int]$now.DayOfWeek))

            if ($match) {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Running: $($job.Command)" -ForegroundColor Cyan
                try {
                    # Expand environment variables in command
                    $cmd = [System.Environment]::ExpandEnvironmentVariables($job.Command)
                    Invoke-Expression $cmd 2>&1 | ForEach-Object { Write-Host "  $_" }
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Job completed" -ForegroundColor Green
                }
                catch {
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Job failed: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
    }

    Start-Sleep -Seconds 30
}
