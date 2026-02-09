function Start-FGAutomationRunbook {
    <#
    .SYNOPSIS
    Starts an Azure Automation runbook for FortigiGraph sync operations.

    .DESCRIPTION
    Triggers an Azure Automation runbook to run immediately, independent of its schedule.
    Can optionally wait for the runbook to complete and return the output.

    .PARAMETER ConfigFile
    Path to a JSON config file containing Azure Automation Account details.

    .PARAMETER RunbookName
    Name of the runbook to start. Use Get-FGAutomationRunbook to list available runbooks.
    Supports tab completion for common sync runbooks.

    .PARAMETER AutomationAccountName
    Name of the Azure Automation Account. If not specified, uses the default naming
    convention based on the config file.

    .PARAMETER ResourceGroupName
    Name of the resource group containing the Automation Account.

    .PARAMETER SubscriptionId
    Azure subscription ID. If not specified, uses current context.

    .PARAMETER Wait
    If specified, waits for the runbook to complete and returns the output.

    .PARAMETER TimeoutMinutes
    Maximum time to wait for runbook completion when using -Wait. Default: 30 minutes.

    .EXAMPLE
    Start-FGAutomationRunbook -ConfigFile ".\config.json" -RunbookName "Sync-FGUsers"

    Starts the Sync-FGUsers runbook and returns immediately.

    .EXAMPLE
    Start-FGAutomationRunbook -ConfigFile ".\config.json" -RunbookName "Sync-FGUsers" -Wait

    Starts the Sync-FGUsers runbook and waits for it to complete.

    .EXAMPLE
    Start-FGAutomationRunbook -ConfigFile ".\config.json" -RunbookName "Sync-FGGroups" -Wait -TimeoutMinutes 60

    Starts the runbook and waits up to 60 minutes for completion.

    .NOTES
    Requires Az.Accounts and Az.Automation modules and appropriate Azure permissions.
    #>

    [CmdletBinding(DefaultParameterSetName = 'ConfigFile')]
    [Alias("Start-AutomationRunbook", "Invoke-FGAutomationRunbook")]
    Param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ConfigFile')]
        [string]$ConfigFile,

        [Parameter(Mandatory = $true)]
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

        [Parameter(Mandatory = $true, ParameterSetName = 'Explicit')]
        [string]$AutomationAccountName,

        [Parameter(Mandatory = $true, ParameterSetName = 'Explicit')]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $false)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $false)]
        [switch]$Wait,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutMinutes = 30
    )

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
        else {
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

    # Start the runbook
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Starting runbook '$RunbookName'..." -ForegroundColor Cyan

    try {
        $job = Start-AzAutomationRunbook `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $RunbookName

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Runbook started. Job ID: $($job.JobId)" -ForegroundColor Green
    }
    catch {
        throw "Failed to start runbook '$RunbookName': $_"
    }

    if (-not $Wait) {
        Write-Host ""
        Write-Host "Runbook is running in the background." -ForegroundColor Gray
        Write-Host "Use -Wait parameter to wait for completion, or check status in Azure Portal." -ForegroundColor Gray
        Write-Host ""

        return [PSCustomObject]@{
            RunbookName = $RunbookName
            JobId = $job.JobId
            Status = "Running"
            StartTime = Get-Date
        }
    }

    # Wait for completion
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Waiting for runbook to complete (timeout: $TimeoutMinutes minutes)..." -ForegroundColor Cyan

    $startTime = Get-Date
    $timeout = New-TimeSpan -Minutes $TimeoutMinutes
    $pollInterval = 10  # seconds

    $terminalStates = @("Completed", "Failed", "Stopped", "Suspended")

    while ((Get-Date) - $startTime -lt $timeout) {
        Start-Sleep -Seconds $pollInterval

        $jobStatus = Get-AzAutomationJob `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Id $job.JobId

        $elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds)
        Write-Host "  [$elapsed s] Status: $($jobStatus.Status)" -ForegroundColor Gray

        if ($jobStatus.Status -in $terminalStates) {
            break
        }
    }

    # Get final status
    $finalJob = Get-AzAutomationJob `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -Id $job.JobId

    $duration = if ($finalJob.EndTime -and $finalJob.StartTime) {
        [math]::Round(($finalJob.EndTime - $finalJob.StartTime).TotalSeconds)
    } else {
        [math]::Round(((Get-Date) - $startTime).TotalSeconds)
    }

    # Get output
    $output = $null
    if ($finalJob.Status -eq "Completed") {
        try {
            $output = Get-AzAutomationJobOutput `
                -ResourceGroupName $ResourceGroupName `
                -AutomationAccountName $AutomationAccountName `
                -Id $job.JobId `
                -Stream Output

            # Also get any errors/warnings
            $errors = Get-AzAutomationJobOutput `
                -ResourceGroupName $ResourceGroupName `
                -AutomationAccountName $AutomationAccountName `
                -Id $job.JobId `
                -Stream Error
        }
        catch {
            Write-Warning "Could not retrieve job output: $_"
        }
    }

    # Display result
    Write-Host ""
    if ($finalJob.Status -eq "Completed") {
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "Runbook Completed Successfully!" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
    }
    elseif ($finalJob.Status -eq "Failed") {
        Write-Host "========================================" -ForegroundColor Red
        Write-Host "Runbook Failed!" -ForegroundColor Red
        Write-Host "========================================" -ForegroundColor Red

        # Get error details
        try {
            $errorOutput = Get-AzAutomationJobOutput `
                -ResourceGroupName $ResourceGroupName `
                -AutomationAccountName $AutomationAccountName `
                -Id $job.JobId `
                -Stream Error

            if ($errorOutput) {
                Write-Host ""
                Write-Host "Error Details:" -ForegroundColor Red
                foreach ($err in $errorOutput) {
                    Write-Host "  $($err.Summary)" -ForegroundColor Red
                }
            }
        }
        catch {
            Write-Warning "Could not retrieve error details"
        }
    }
    else {
        Write-Host "========================================" -ForegroundColor Yellow
        Write-Host "Runbook Status: $($finalJob.Status)" -ForegroundColor Yellow
        Write-Host "========================================" -ForegroundColor Yellow
    }

    Write-Host "Runbook:    $RunbookName" -ForegroundColor White
    Write-Host "Job ID:     $($job.JobId)" -ForegroundColor White
    Write-Host "Duration:   $duration seconds" -ForegroundColor White
    Write-Host "Status:     $($finalJob.Status)" -ForegroundColor White
    Write-Host ""

    return [PSCustomObject]@{
        RunbookName = $RunbookName
        JobId = $job.JobId
        Status = $finalJob.Status
        StartTime = $finalJob.StartTime
        EndTime = $finalJob.EndTime
        DurationSeconds = $duration
        Output = $output
        Exception = $finalJob.Exception
    }
}
