function Export-FGRiskProfile {
    <#
    .SYNOPSIS
    Exports a risk profile from SQL to a JSON file.

    .DESCRIPTION
    Reads the risk profile from the GraphRiskProfiles table and writes it
    to a JSON file for sharing or version control.

    Automatically connects to SQL if a ConfigFile is provided and not already connected.

    .PARAMETER Id
    The profile ID to export. Defaults to the most recently generated profile.

    .PARAMETER Path
    Output file path. Defaults to ./risk-profile.json in the current directory.

    .PARAMETER ConfigFile
    Optional FortigiGraph config file. Used to connect to SQL if not already connected.

    .EXAMPLE
    Export-FGRiskProfile -Path .\export\risk-profile.json -ConfigFile .\Config\mycompany.json

    .EXAMPLE
    Export-FGRiskProfile -Id "portofrotterdam.com" -Path .\share\por-profile.json

    .EXAMPLE
    Export-FGRiskProfile
    #>

    [alias("Export-RiskProfile")]
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $false)]
        [System.String]$Id,

        [Parameter(Mandatory = $false)]
        [System.String]$Path = ".\risk-profile.json",

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

    $profile = Get-FGRiskProfile -Id $Id
    if (-not $profile) {
        Write-Warning "No risk profile found in SQL. Run New-FGRiskProfile first."
        return
    }

    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $profile | ConvertTo-Json -Depth 100 | Set-Content -Path $Path -Encoding UTF8

    $cp = if ($profile.customer_profile) { $profile.customer_profile } else { $profile }
    Write-Host "  Exported risk profile to: $Path (domain=$($cp.domain), industry=$($cp.industry))" -ForegroundColor Green

    return $profile
}
