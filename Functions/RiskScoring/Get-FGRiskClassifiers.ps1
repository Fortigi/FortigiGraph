function Get-FGRiskClassifiers {
    <#
    .SYNOPSIS
    Reads a risk classifier ruleset from SQL.

    .DESCRIPTION
    Retrieves the classifier ruleset stored in the GraphRiskClassifiers temporal table.
    Returns the parsed classifier object, or $null if not found.

    Used by Invoke-FGRiskScoring as a fallback when no local classifier file is available
    (e.g., when running in Azure Automation).

    .PARAMETER Id
    The identifier of the ruleset to retrieve. Defaults to "default".
    Typically the customer domain (e.g., "portofrotterdam.com").

    .EXAMPLE
    $classifiers = Get-FGRiskClassifiers -Id "portofrotterdam.com"

    .EXAMPLE
    # Get any available ruleset (tries specific ID, then "default")
    $classifiers = Get-FGRiskClassifiers -Id "mycompany.com"
    if (-not $classifiers) { $classifiers = Get-FGRiskClassifiers }

    .NOTES
    Requires Connect-FGSQLServer to be called first.
    Returns $null if the table doesn't exist or no matching ruleset is found.
    #>

    [alias("Get-RiskClassifiers")]
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $false)]
        [System.String]$Id
    )

    if (-not $global:FGSQLConnectionString) {
        return $null
    }

    try {
        # Check if table exists
        $tableExists = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            $cmd = $connection.CreateCommand()
            $cmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'GraphRiskClassifiers' AND TABLE_SCHEMA = 'dbo'"
            return [int]$cmd.ExecuteScalar() -gt 0
        }

        if (-not $tableExists) { return $null }

        # Build query — if Id specified, look for exact match; otherwise get the most recent
        $result = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            $cmd = $connection.CreateCommand()
            $cmd.CommandTimeout = 30

            if ($Id) {
                $cmd.CommandText = "SELECT TOP 1 classifierJson FROM dbo.GraphRiskClassifiers WHERE id = @id"
                $cmd.Parameters.AddWithValue("@id", $Id) | Out-Null
            } else {
                # No ID specified — get the most recently updated ruleset
                $cmd.CommandText = "SELECT TOP 1 classifierJson FROM dbo.GraphRiskClassifiers ORDER BY generatedAt DESC"
            }

            $reader = $cmd.ExecuteReader()
            try {
                if ($reader.Read()) {
                    return $reader.GetString(0)
                }
                return $null
            }
            finally {
                $reader.Close()
            }
        }

        if ($result) {
            return $result | ConvertFrom-Json
        }

        return $null
    }
    catch {
        # Don't throw — this is a fallback source, caller will try other sources
        return $null
    }
}
