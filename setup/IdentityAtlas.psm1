# FortigiGraph Module Loader
# Dot-sources all PowerShell functions from the repository structure.

$repoRoot = Split-Path $PSScriptRoot -Parent

# App layer — database schema and SQL operations
$db = @( Get-ChildItem -Path (Join-Path $repoRoot 'app\db') -Include *.ps1 -Recurse -ErrorAction SilentlyContinue )

# Tools — PowerShell SDK (Graph API wrappers, SQL helpers, idempotent helpers)
$graph   = @( Get-ChildItem -Path (Join-Path $repoRoot 'tools\powershell-sdk\graph') -Include *.ps1 -Recurse -ErrorAction SilentlyContinue )
$sql     = @( Get-ChildItem -Path (Join-Path $repoRoot 'tools\powershell-sdk\sql') -Include *.ps1 -Recurse -ErrorAction SilentlyContinue )
$helpers = @( Get-ChildItem -Path (Join-Path $repoRoot 'tools\powershell-sdk\helpers') -Include *.ps1 -Recurse -ErrorAction SilentlyContinue )

# Tools — Risk scoring and account correlation
$riskScoring = @( Get-ChildItem -Path (Join-Path $repoRoot 'tools\riskscoring') -Include *.ps1 -Recurse -ErrorAction SilentlyContinue )
$correlation = @( Get-ChildItem -Path (Join-Path $repoRoot 'tools\correlation') -Include *.ps1 -Recurse -ErrorAction SilentlyContinue )

# Setup — Azure deployment scripts
$azure = @( Get-ChildItem -Path (Join-Path $PSScriptRoot 'azure') -Include *.ps1 -Recurse -ErrorAction SilentlyContinue )

# Dot source all function files
foreach ($import in @($db + $graph + $sql + $helpers + $riskScoring + $correlation + $azure)) {
    try {
        . $import.fullname
    }
    catch {
        Write-Error -Message "Failed to import function $($import.fullname): $_"
    }
}
