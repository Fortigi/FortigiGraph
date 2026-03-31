function Get-FGCorrelationRuleset {
    <#
    .SYNOPSIS
        Reads an account correlation ruleset from Azure SQL.

    .DESCRIPTION
        Retrieves a previously saved correlation ruleset from the GraphCorrelationRulesets table.
        If no Id is specified, returns the most recently updated ruleset.

    .PARAMETER Id
        Optional identifier for a specific ruleset. If omitted, returns the most recent.

    .PARAMETER ConfigFile
        Optional path to FortigiGraph config file for SQL connection.

    .EXAMPLE
        $ruleset = Get-FGCorrelationRuleset
        $ruleset.accountTypeRules

    .EXAMPLE
        $ruleset = Get-FGCorrelationRuleset -Id "contoso-custom"
    #>
    [alias("Get-CorrelationRuleset")]
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory = $false)]
        [string]$Id,

        [Parameter(Mandatory = $false)]
        [string]$ConfigFile
    )

    # Ensure SQL connection
    if (-not $global:FGSQLConnectionString) {
        if ($ConfigFile) {
            Connect-FGSQLServer -ConfigFile $ConfigFile
        } else {
            throw "Not connected to SQL Server. Run Connect-FGSQLServer first or provide -ConfigFile."
        }
    }

    $result = $null
    try {
        $result = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            $cmd = $connection.CreateCommand()
            $cmd.CommandTimeout = 30

            if ($Id) {
                $cmd.CommandText = "SELECT TOP 1 rulesetJson FROM dbo.GraphCorrelationRulesets WHERE id = @id"
                $cmd.Parameters.AddWithValue("@id", $Id) | Out-Null
            } else {
                $cmd.CommandText = "SELECT TOP 1 rulesetJson FROM dbo.GraphCorrelationRulesets ORDER BY generatedAt DESC"
            }

            $reader = $cmd.ExecuteReader()
            try {
                if ($reader.Read()) {
                    return $reader.GetString(0)
                }
                return $null
            } finally {
                $reader.Close()
            }
        }
    } catch {
        # Table may not exist yet
        return $null
    }

    if ($result) {
        return $result | ConvertFrom-Json
    }

    return $null
}
