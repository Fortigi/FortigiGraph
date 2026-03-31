function Export-FGRiskClassifiers {
    <#
    .SYNOPSIS
    Exports risk classifiers from SQL to a JSON file.

    .DESCRIPTION
    Reads the classifier ruleset from the GraphRiskClassifiers table and writes it
    to a JSON file for sharing or version control.

    Automatically connects to SQL if a ConfigFile is provided and not already connected.

    .PARAMETER Id
    The classifier ruleset ID to export. Defaults to the most recently generated ruleset.

    .PARAMETER Path
    Output file path. Defaults to ./classifier-ruleset.json in the current directory.

    .PARAMETER ConfigFile
    Optional FortigiGraph config file. Used to connect to SQL if not already connected.

    .EXAMPLE
    Export-FGRiskClassifiers -Path .\export\classifiers.json -ConfigFile .\Config\mycompany.json

    .EXAMPLE
    Export-FGRiskClassifiers -Id "portofrotterdam.com" -Path .\share\por-classifiers.json

    .EXAMPLE
    Export-FGRiskClassifiers
    #>

    [alias("Export-RiskClassifiers")]
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $false)]
        [System.String]$Id,

        [Parameter(Mandatory = $false)]
        [System.String]$Path = ".\classifier-ruleset.json",

        [Parameter(Mandatory = $false)]
        [System.String]$ConfigFile
    )

    # Connect to SQL if not already connected
    if (-not $global:FGSQLConnectionString) {
        if ($ConfigFile) {
            Connect-FGSQLServer -ConfigFile $ConfigFile
        } else {
            throw "Not connected to SQL. Provide -ConfigFile or run Connect-FGSQLServer first."
        }
    }

    $classifiers = Get-FGRiskClassifiers -Id $Id
    if (-not $classifiers) {
        Write-Warning "No classifier ruleset found in SQL. Run New-FGRiskClassifiers first."
        return
    }

    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $classifiers | ConvertTo-Json -Depth 100 | Set-Content -Path $Path -Encoding UTF8

    $groupCount = @($classifiers.groups | Where-Object { $_ }).Count
    $userCount = @($classifiers.users | Where-Object { $_ }).Count
    Write-Host "  Exported classifiers to: $Path ($groupCount group, $userCount user rules)" -ForegroundColor Green

    return $classifiers
}
