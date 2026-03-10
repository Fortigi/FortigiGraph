# USE THIS FILE FOR ADDITIONAL MODULE CODE
# THIS FILE WILL NOT BE OVERWRITTEN WHEN NEW CONTENT IS PUBLISHED TO THIS MODULE

# Get public and private function definition files.
$base       = @( Get-ChildItem -Path (Join-Path $PSScriptRoot 'functions\base') -Include *.ps1 -Recurse -ErrorAction SilentlyContinue )
$generic    = @( Get-ChildItem -Path (Join-Path $PSScriptRoot 'functions\generic') -Include *.ps1 -Recurse -ErrorAction SilentlyContinue )
$specific   = @( Get-ChildItem -Path (Join-Path $PSScriptRoot 'functions\specific') -Include *.ps1 -Recurse -ErrorAction SilentlyContinue )
$SQL        = @( Get-ChildItem -Path (Join-Path $PSScriptRoot 'functions\SQL') -Include *.ps1 -Recurse -ErrorAction SilentlyContinue )
$sync       = @( Get-ChildItem -Path (Join-Path $PSScriptRoot 'functions\Sync') -Include *.ps1 -Recurse -ErrorAction SilentlyContinue )
$automation    = @( Get-ChildItem -Path (Join-Path $PSScriptRoot 'functions\Automation') -Include *.ps1 -Recurse -ErrorAction SilentlyContinue )
$riskScoring   = @( Get-ChildItem -Path (Join-Path $PSScriptRoot 'functions\RiskScoring') -Include *.ps1 -Recurse -ErrorAction SilentlyContinue )

# Dot source all function files
foreach ($import in @($base + $generic + $specific + $SQL + $sync + $automation + $riskScoring)) {
    try {
        . $import.fullname
    }
    catch {
        Write-Error -Message "Failed to import function $($import.fullname): $_"
    }
}