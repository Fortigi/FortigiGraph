function Get-FGAutomationJob {
    <#
    .SYNOPSIS
    Gets the status of Azure Automation jobs for FortigiGraph runbooks.

    .DESCRIPTION
    Retrieves recent automation jobs, optionally filtered by runbook name or status.
    Shows job status, duration, and completion time. Useful for monitoring runbook
    execution after starting jobs with Start-FGAutomationRunbook.

    .PARAMETER ConfigFile
    Path to a JSON config file containing Azure Automation Account details.

    .PARAMETER RunbookName
    Filter to show only jobs for a specific runbook.

    .PARAMETER Status
    Filter by job status: Running, Completed, Failed, Stopped, Suspended.

    .PARAMETER Last
    Number of recent jobs to show. Default: 20.

    .PARAMETER AutomationAccountName
    Name of the Azure Automation Account. If not specified, derived from config.

    .PARAMETER ResourceGroupName
    Name of the resource group containing the Automation Account.

    .PARAMETER SubscriptionId
    Azure subscription ID. If not specified, uses current context.

    .PARAMETER Running
    Shortcut to show only running jobs (-Status Running).

    .EXAMPLE
    Get-FGAutomationJob -ConfigFile ".\config.json"

    Shows the last 20 automation jobs.

    .EXAMPLE
    Get-FGAutomationJob -ConfigFile ".\config.json" -Running

    Shows only currently running jobs.

    .EXAMPLE
    Get-FGAutomationJob -ConfigFile ".\config.json" -RunbookName "Sync-FGUsers" -Last 10

    Shows the last 10 jobs for the Sync-FGUsers runbook.

    .EXAMPLE
    Get-FGAutomationJob -ConfigFile ".\config.json" -Status Failed

    Shows failed jobs.

    .EXAMPLE
    $jobs = Get-FGAutomationJob -ConfigFile ".\config.json" -PassThru

    Returns job objects for pipeline processing instead of displaying a table.

    .NOTES
    Requires Az.Accounts and Az.Automation modules.
    #>

    [CmdletBinding(DefaultParameterSetName = 'ConfigFile')]
    [Alias("Get-AutomationJob")]
    Param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ConfigFile')]
        [Parameter(Mandatory = $false, ParameterSetName = 'Explicit')]
        [string]$ConfigFile,

        [Parameter(Mandatory = $false)]
        [ValidateSet(
            "Sync-FGUsers",
            "Sync-FGGroups",
            "Sync-FGGroupMembers",
            "Sync-FGGroupEligibleMembers",
            "Sync-FGGroupOwners",
            "Sync-FGCatalogs",
            "Sync-FGAccessPackages",
            "Sync-FGAccessPackageAssignments",
            "Sync-FGAccessPackageResourceRoleScopes",
            "Sync-FGAccessPackageAssignmentPolicies",
            "Sync-FGAccessPackageAssignmentRequests",
            "Sync-FGAccessPackageAccessReviews"
        )]
        [string]$RunbookName,

        [Parameter(Mandatory = $false)]
        [ValidateSet("Running", "Completed", "Failed", "Stopped", "Suspended", "Queued", "Starting")]
        [string]$Status,

        [Parameter(Mandatory = $false)]
        [int]$Last = 20,

        [Parameter(Mandatory = $true, ParameterSetName = 'Explicit')]
        [string]$AutomationAccountName,

        [Parameter(Mandatory = $true, ParameterSetName = 'Explicit')]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $false)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $false)]
        [switch]$Running,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    # Shortcut for running jobs
    if ($Running) {
        $Status = "Running"
    }

    # Load config if provided
    if ($ConfigFile) {
        if (-not (Test-Path $ConfigFile)) {
            throw "Config file not found: $ConfigFile"
        }

        $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json

        $ResourceGroupName = $config.Azure.ResourceGroupName
        if (-not $ResourceGroupName) {
            throw "Config file must contain Azure.ResourceGroupName"
        }

        # Try to get AutomationAccountName from config, or derive it
        if ($config.Azure.AutomationAccountName) {
            $AutomationAccountName = $config.Azure.AutomationAccountName
        }
        elseif (-not $AutomationAccountName) {
            # List automation accounts in the resource group
            $accounts = Get-AzAutomationAccount -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
            if ($accounts.Count -eq 0) {
                throw "No Automation Account found in resource group '$ResourceGroupName'"
            }
            elseif ($accounts.Count -eq 1) {
                $AutomationAccountName = $accounts[0].AutomationAccountName
            }
            else {
                throw "Multiple Automation Accounts found in resource group '$ResourceGroupName'. Please specify AutomationAccountName in config or use -AutomationAccountName parameter."
            }
        }

        if ($config.Azure.SubscriptionId -and -not $SubscriptionId) {
            $SubscriptionId = $config.Azure.SubscriptionId
        }
    }

    # Set subscription context if specified
    if ($SubscriptionId) {
        Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    }

    # Build filter parameters
    $jobParams = @{
        ResourceGroupName = $ResourceGroupName
        AutomationAccountName = $AutomationAccountName
    }

    if ($RunbookName) {
        $jobParams.RunbookName = $RunbookName
    }

    if ($Status) {
        $jobParams.Status = $Status
    }

    # Get jobs
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Fetching jobs from '$AutomationAccountName'..." -ForegroundColor Cyan

    try {
        $jobs = Get-AzAutomationJob @jobParams |
            Sort-Object CreationTime -Descending |
            Select-Object -First $Last
    }
    catch {
        throw "Failed to get automation jobs: $_"
    }

    if (-not $jobs -or $jobs.Count -eq 0) {
        $filterMsg = ""
        if ($RunbookName) { $filterMsg += " for '$RunbookName'" }
        if ($Status) { $filterMsg += " with status '$Status'" }
        Write-Host "No jobs found$filterMsg." -ForegroundColor Yellow
        return @()
    }

    # Format output
    $results = $jobs | ForEach-Object {
        # Calculate duration
        $duration = ""
        $durationSeconds = 0
        if ($_.EndTime -and $_.StartTime) {
            $durationSeconds = [int]($_.EndTime - $_.StartTime).TotalSeconds
            if ($durationSeconds -lt 60) {
                $duration = "${durationSeconds}s"
            }
            elseif ($durationSeconds -lt 3600) {
                $duration = "$([math]::Floor($durationSeconds / 60))m $($durationSeconds % 60)s"
            }
            else {
                $duration = "$([math]::Floor($durationSeconds / 3600))h $([math]::Floor(($durationSeconds % 3600) / 60))m"
            }
        }
        elseif ($_.StartTime) {
            # Still running
            $elapsed = [int]((Get-Date) - $_.StartTime.LocalDateTime).TotalSeconds
            if ($elapsed -lt 60) {
                $duration = "${elapsed}s (running)"
            }
            elseif ($elapsed -lt 3600) {
                $duration = "$([math]::Floor($elapsed / 60))m $($elapsed % 60)s (running)"
            }
            else {
                $duration = "$([math]::Floor($elapsed / 3600))h $([math]::Floor(($elapsed % 3600) / 60))m (running)"
            }
        }

        # Format time ago
        $timeAgo = ""
        $refTime = if ($_.EndTime) { $_.EndTime.LocalDateTime } else { $_.CreationTime.LocalDateTime }
        $elapsed = (Get-Date) - $refTime
        if ($elapsed.TotalMinutes -lt 60) {
            $timeAgo = "$([math]::Round($elapsed.TotalMinutes))m ago"
        }
        elseif ($elapsed.TotalHours -lt 24) {
            $timeAgo = "$([math]::Round($elapsed.TotalHours, 1))h ago"
        }
        else {
            $timeAgo = "$([math]::Round($elapsed.TotalDays, 1))d ago"
        }

        [PSCustomObject]@{
            RunbookName = $_.RunbookName
            Status = $_.Status
            StartTime = if ($_.StartTime) { $_.StartTime.LocalDateTime.ToString("HH:mm:ss") } else { "-" }
            Duration = $duration
            TimeAgo = $timeAgo
            JobId = $_.JobId.ToString().Substring(0, 8) + "..."
        }
    }

    # Display with color coding
    Write-Host ""

    # Count by status
    $runningCount = ($results | Where-Object { $_.Status -eq "Running" }).Count
    $completedCount = ($results | Where-Object { $_.Status -eq "Completed" }).Count
    $failedCount = ($results | Where-Object { $_.Status -eq "Failed" }).Count

    if ($runningCount -gt 0) {
        Write-Host "Running: $runningCount" -ForegroundColor Yellow -NoNewline
        Write-Host " | " -NoNewline
    }
    if ($completedCount -gt 0) {
        Write-Host "Completed: $completedCount" -ForegroundColor Green -NoNewline
        Write-Host " | " -NoNewline
    }
    if ($failedCount -gt 0) {
        Write-Host "Failed: $failedCount" -ForegroundColor Red -NoNewline
        Write-Host " | " -NoNewline
    }
    Write-Host "Total: $($results.Count)"
    Write-Host ""

    # Output based on PassThru switch
    if ($PassThru) {
        return $results
    }
    else {
        $results | Format-Table -AutoSize | Out-Host
    }
}
