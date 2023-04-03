# USE THIS FILE FOR ADDITIONAL MODULE CODE
# THIS FILE WILL NOT BE OVERWRITTEN WHEN NEW CONTENT IS PUBLISHED TO THIS MODULE

# Get public and private function definition files.
$base    = @( Get-ChildItem -Path (Join-Path $PSScriptRoot 'base') -Include *.ps1 -Recurse -ErrorAction SilentlyContinue )
$generic = @( Get-ChildItem -Path (Join-Path $PSScriptRoot 'generic') -Include *.ps1 -Recurse -ErrorAction SilentlyContinue )
$specific = @( Get-ChildItem -Path (Join-Path $PSScriptRoot 'specific') -Include *.ps1 -Recurse -ErrorAction SilentlyContinue )

# Dot source base & generic function files
foreach ($import in @($base + $generic + $specific)) {
    try {
        . $import.fullname
    }
    catch {
        Write-Error -Message "Failed to import function $($import.fullname): $_"
    }
}