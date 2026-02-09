function Get-FGAutomationRunbook {
    <#
    .SYNOPSIS
    Lists Azure Automation runbooks for FortigiGraph sync operations.

    .DESCRIPTION
    Retrieves runbooks from an Azure Automation Account. By default, shows only
    FortigiGraph sync runbooks (Sync-FG*), but can optionally show all runbooks.

    .PARAMETER ConfigFile
    Path to a JSON config file containing Azure Automation Account details.
    Uses Azure.ResourceGroupName from the config and derives the Automation Account name.

    .PARAMETER AutomationAccountName
    Name of the Azure Automation Account. If not specified, uses the default naming
    convention based on the config file.

    .PARAMETER ResourceGroupName
    Name of the resource group containing the Automation Account.

    .PARAMETER SubscriptionId
    Azure subscription ID. If not specified, uses current context.

    .PARAMETER All
    If specified, shows all runbooks, not just FortigiGraph sync runbooks.

    .EXAMPLE
    Get-FGAutomationRunbook -ConfigFile ".\config.json"

    Lists all FortigiGraph sync runbooks from the Automation Account.

    .EXAMPLE
    Get-FGAutomationRunbook -ConfigFile ".\config.json" -All

    Lists all runbooks in the Automation Account.

    .EXAMPLE
    Get-FGAutomationRunbook -AutomationAccountName "my-automation" -ResourceGroupName "my-rg"

    Lists runbooks using explicit parameters.

    .NOTES
    Requires Az.Accounts module and appropriate Azure permissions.
    #>

    [CmdletBinding(DefaultParameterSetName = 'ConfigFile')]
    [Alias("Get-AutomationRunbook")]
    Param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ConfigFile')]
        [string]$ConfigFile,

        [Parameter(Mandatory = $true, ParameterSetName = 'Explicit')]
        [string]$AutomationAccountName,

        [Parameter(Mandatory = $true, ParameterSetName = 'Explicit')]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $false)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $false)]
        [switch]$All
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

    # Get runbooks
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Fetching runbooks from '$AutomationAccountName'..." -ForegroundColor Cyan

    $runbooks = Get-AzAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName

    if (-not $All) {
        # Filter to only FortigiGraph sync runbooks
        $runbooks = $runbooks | Where-Object { $_.Name -like "Sync-FG*" }
    }

    if (-not $runbooks -or $runbooks.Count -eq 0) {
        Write-Host "No runbooks found." -ForegroundColor Yellow
        return @()
    }

    # Format output
    $results = $runbooks | ForEach-Object {
        [PSCustomObject]@{
            Name = $_.Name
            State = $_.State
            LastModified = $_.LastModifiedTime.LocalDateTime.ToString("yyyy-MM-dd HH:mm")
            RunbookType = $_.RunbookType
        }
    } | Sort-Object Name

    # Display as table
    Write-Host ""
    $results | Format-Table -AutoSize

    Write-Host "Total: $($results.Count) runbook(s)" -ForegroundColor Gray
    Write-Host ""

    return $results
}
