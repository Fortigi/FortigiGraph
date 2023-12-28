$Author = "Wim van den Heijkant"
$Company = "Fortigi"
$Description = "PowerShell Module to assist with scripting against the Microsoft Graph. The sources for this module, including versioning can be found on GitHub: https://github.com/Fortigi/FortigiGraph"

$VersionMajor = "1"
$VersionMinor = "0"
$Version = $VersionMajor + "." + $VersionMinor + "." + (Get-Date -Format "yyyyMMdd")

$Path = "C:\Source\Fortigi\GitHub\FortigiGraph"

Set-Location $Path

New-ModuleManifest -Path .\FortigiGraph.psd1 -Author $Author -CompanyName $Company -ModuleVersion $Version -Description $Description -ModuleToProcess .\FortigiGraph.psm1

Write-Host "Please provide API Key"
$APIKey = Read-Host -MaskInput

Publish-Module -Path $Path -NuGetApiKey $APIKey