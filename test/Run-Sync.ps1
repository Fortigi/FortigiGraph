# Simple wrapper script for running Start-FGSync with transcript logging
# This is useful for scheduled tasks or manual runs that need logging

param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile
)

# Ensure FortigiGraph module is loaded
if (-not (Get-Module -Name FortigiGraph)) {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    $modulePath = Join-Path $moduleRoot "FortigiGraph.psd1"
    Import-Module $modulePath -Force
}

# Setup transcript logging
$configBaseName = [System.IO.Path]::GetFileNameWithoutExtension($ConfigFile)
$logDir = Join-Path $PSScriptRoot "logs\"
if (-not (Test-Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}
$transcriptFile = Join-Path $logDir "sync-$configBaseName-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

Write-Host "Starting transcript logging to: $transcriptFile" -ForegroundColor Cyan
Start-Transcript -Path $transcriptFile -Force | Out-Null

try {
    # Run the sync
    Start-FGSync -ConfigFile $ConfigFile

    Write-Host "`nTranscript saved to: $transcriptFile" -ForegroundColor Green
}
catch {
    Write-Host "`nSync failed. See transcript for details: $transcriptFile" -ForegroundColor Red
    throw
}
finally {
    Stop-Transcript
}
