function Import-FGRiskProfile {
    <#
    .SYNOPSIS
    Imports a risk profile from a JSON file into SQL.

    .DESCRIPTION
    Reads a risk profile JSON file and persists it to the GraphRiskProfiles table.
    Use this to load profiles shared by a colleague or from version control.

    Automatically connects to SQL if a ConfigFile is provided and not already connected.

    .PARAMETER Path
    Path to the risk profile JSON file.

    .PARAMETER Id
    Override the ID used in SQL. Defaults to the customer domain from the file.

    .PARAMETER ConfigFile
    Optional FortigiGraph config file. Used to connect to SQL if not already connected.

    .EXAMPLE
    Import-FGRiskProfile -Path .\share\por-profile.json -ConfigFile .\Config\mycompany.json

    .EXAMPLE
    Import-FGRiskProfile -Path .\share\por-profile.json
    #>

    [alias("Import-RiskProfile")]
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [System.String]$Path,

        [Parameter(Mandatory = $false)]
        [System.String]$Id,

        [Parameter(Mandatory = $false)]
        [System.String]$ConfigFile
    )

    if (-not (Test-Path $Path)) {
        throw "Risk profile file not found: $Path"
    }

    # Connect to SQL if not already connected
    if (-not $global:FGSQLConnectionString) {
        if ($ConfigFile) {
            Connect-FGSQLServer -ConfigFile $ConfigFile
        } else {
            throw "Not connected to SQL. Provide -ConfigFile or run Connect-FGSQLServer first."
        }
    }

    $profile = Get-Content -Path $Path -Raw | ConvertFrom-Json

    $saveParams = @{ RiskProfile = $profile }
    if ($Id) { $saveParams.Id = $Id }

    Save-FGRiskProfile @saveParams
}
