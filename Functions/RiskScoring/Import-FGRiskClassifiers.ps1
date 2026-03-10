function Import-FGRiskClassifiers {
    <#
    .SYNOPSIS
    Imports risk classifiers from a JSON file into SQL.

    .DESCRIPTION
    Reads a classifier ruleset JSON file and persists it to the GraphRiskClassifiers table.
    Use this to load classifiers shared by a colleague or from version control.

    Automatically connects to SQL if a ConfigFile is provided and not already connected.

    .PARAMETER Path
    Path to the classifier ruleset JSON file.

    .PARAMETER Id
    Override the ID used in SQL. Defaults to the customer domain from the file.

    .PARAMETER ConfigFile
    Optional FortigiGraph config file. Used to connect to SQL if not already connected.

    .EXAMPLE
    Import-FGRiskClassifiers -Path .\share\por-classifiers.json -ConfigFile .\Config\mycompany.json

    .EXAMPLE
    Import-FGRiskClassifiers -Path .\share\por-classifiers.json
    #>

    [alias("Import-RiskClassifiers")]
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
        throw "Classifier file not found: $Path"
    }

    # Connect to SQL if not already connected
    if (-not $global:FGSQLConnectionString) {
        if ($ConfigFile) {
            Connect-FGSQLServer -ConfigFile $ConfigFile
        } else {
            throw "Not connected to SQL. Provide -ConfigFile or run Connect-FGSQLServer first."
        }
    }

    $ruleset = Get-Content -Path $Path -Raw | ConvertFrom-Json

    $saveParams = @{ ClassifierRuleset = $ruleset }
    if ($Id) { $saveParams.Id = $Id }

    Save-FGRiskClassifiers @saveParams
}
