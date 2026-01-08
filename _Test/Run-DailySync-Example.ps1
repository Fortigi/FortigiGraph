<#
.SYNOPSIS
Example wrapper script for scheduling Daily-Sync.ps1

.DESCRIPTION
This is a simple wrapper that can be used with Windows Task Scheduler or Azure Automation.
Copy and customize this file for your environment.

.EXAMPLE
Run directly:
    .\Run-DailySync-Example.ps1

Schedule with Task Scheduler:
    $action = New-ScheduledTaskAction -Execute "pwsh.exe" -Argument "-File C:\Scripts\Run-DailySync-Example.ps1"
    $trigger = New-ScheduledTaskTrigger -Daily -At "02:00AM"
    Register-ScheduledTask -TaskName "Graph Daily Sync" -Action $action -Trigger $trigger
#>

# Change to the script directory
Set-Location $PSScriptRoot

# Set your configuration file name here
$ConfigFile = "config.production.json"

# Optional: Set filters or custom parameters
$syncParams = @{
    ConfigFile = $ConfigFile
}

# Example: Uncomment to sync only enabled users
# $syncParams.UserFilter = "accountEnabled eq true"

# Example: Uncomment to skip PIM sync if not configured
# $syncParams.SyncGroupEligibleMembers = $false

# Example: Uncomment to add custom user attributes
# $syncParams.UserAdditionalAttributes = @('city', 'country', 'officeLocation')

# Run the sync
try {
    Write-Host "Starting Graph Daily Sync..." -ForegroundColor Cyan
    Write-Host "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
    Write-Host ""

    .\Daily-Sync.ps1 @syncParams

    Write-Host ""
    Write-Host "Sync completed successfully!" -ForegroundColor Green
    exit 0
}
catch {
    Write-Host ""
    Write-Host "Sync failed with error:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""
    Write-Host "Check log file for details" -ForegroundColor Yellow
    exit 1
}
