# Credential Management Helper for FortigiGraph Tests
# Use this script to view, update, or clear stored credentials

param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile = (Join-Path $PSScriptRoot "config.iidemo.json"),

    [Parameter(Mandatory = $false)]
    [ValidateSet("Status", "Clear", "ClearAll")]
    [string]$Action = "Status"
)

# Load secure configuration helper
$secureConfigPath = Join-Path $PSScriptRoot "SecureConfig.ps1"
. $secureConfigPath

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "FortigiGraph Credential Manager" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

if (-not (Test-Path $ConfigFile)) {
    Write-Host "Configuration file not found: $ConfigFile" -ForegroundColor Red
    exit 1
}

Write-Host "Config file: $ConfigFile`n" -ForegroundColor Gray

switch ($Action) {
    "Status" {
        Write-Host "Checking credential status...`n" -ForegroundColor Yellow

        # Check SQL Admin Password
        $hasSqlPassword = Test-SecureConfigAvailable -ConfigPath $ConfigFile -PropertyPath "Azure.AdminUserPassword"
        if ($hasSqlPassword) {
            Write-Host "  ✓ SQL Admin Password: Stored securely" -ForegroundColor Green
        } else {
            Write-Host "  ✗ SQL Admin Password: Not configured" -ForegroundColor Yellow
        }

        # Check Graph Client Secret
        $hasClientSecret = Test-SecureConfigAvailable -ConfigPath $ConfigFile -PropertyPath "Graph.ClientSecret"
        if ($hasClientSecret) {
            Write-Host "  ✓ Graph Client Secret: Stored securely" -ForegroundColor Green
        } else {
            Write-Host "  ℹ Graph Client Secret: Not configured (will use interactive auth)" -ForegroundColor Cyan
        }

        Write-Host "`nTo update credentials, run the test script - it will prompt for any missing credentials." -ForegroundColor Gray
        Write-Host "To clear credentials, run: .\Manage-Credentials.ps1 -Action Clear" -ForegroundColor Gray
    }

    "Clear" {
        Write-Host "Select credential to clear:" -ForegroundColor Yellow
        Write-Host "  1. SQL Admin Password" -ForegroundColor Cyan
        Write-Host "  2. Graph Client Secret" -ForegroundColor Cyan
        Write-Host "  3. Both" -ForegroundColor Cyan
        Write-Host "  Q. Cancel" -ForegroundColor Gray

        $choice = Read-Host "`nEnter choice"

        switch ($choice) {
            "1" {
                Clear-SecureConfigValue -ConfigPath $ConfigFile -PropertyPath "Azure.AdminUserPassword"
                Write-Host "`nSQL Admin Password cleared. Next test run will prompt for it." -ForegroundColor Green
            }
            "2" {
                Clear-SecureConfigValue -ConfigPath $ConfigFile -PropertyPath "Graph.ClientSecret"
                Write-Host "`nGraph Client Secret cleared. Next test run will use interactive auth or prompt for it." -ForegroundColor Green
            }
            "3" {
                Clear-SecureConfigValue -ConfigPath $ConfigFile -PropertyPath "Azure.AdminUserPassword"
                Clear-SecureConfigValue -ConfigPath $ConfigFile -PropertyPath "Graph.ClientSecret"
                Write-Host "`nAll credentials cleared. Next test run will prompt for them." -ForegroundColor Green
            }
            "Q" {
                Write-Host "`nCancelled." -ForegroundColor Gray
            }
            default {
                Write-Host "`nInvalid choice." -ForegroundColor Red
            }
        }
    }

    "ClearAll" {
        Write-Host "Clearing all stored credentials...`n" -ForegroundColor Yellow
        Clear-SecureConfigValue -ConfigPath $ConfigFile -PropertyPath "Azure.AdminUserPassword"
        Clear-SecureConfigValue -ConfigPath $ConfigFile -PropertyPath "Graph.ClientSecret"
        Write-Host "`nAll credentials cleared. Next test run will prompt for them." -ForegroundColor Green
    }
}

Write-Host ""
