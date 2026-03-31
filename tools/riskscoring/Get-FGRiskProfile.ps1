function Get-FGRiskProfile {
    <#
    .SYNOPSIS
    Reads a risk profile from SQL.

    .DESCRIPTION
    Retrieves the risk profile stored in the GraphRiskProfiles temporal table.
    Returns the parsed profile object, or $null if not found.

    .PARAMETER Id
    The identifier of the profile to retrieve. Defaults to the most recently generated profile.
    Typically the customer domain (e.g., "portofrotterdam.com").

    .EXAMPLE
    $profile = Get-FGRiskProfile -Id "portofrotterdam.com"

    .EXAMPLE
    # Get the most recent profile
    $profile = Get-FGRiskProfile

    .NOTES
    Requires Connect-FGSQLServer to be called first.
    Returns $null if the table doesn't exist or no matching profile is found.
    #>

    [alias("Get-RiskProfile")]
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $false)]
        [System.String]$Id
    )

    if (-not $global:FGSQLConnectionString) {
        return $null
    }

    try {
        $tableExists = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            $cmd = $connection.CreateCommand()
            $cmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'GraphRiskProfiles' AND TABLE_SCHEMA = 'dbo'"
            return [int]$cmd.ExecuteScalar() -gt 0
        }

        if (-not $tableExists) { return $null }

        $result = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            $cmd = $connection.CreateCommand()
            $cmd.CommandTimeout = 30

            if ($Id) {
                $cmd.CommandText = "SELECT TOP 1 profileJson FROM dbo.GraphRiskProfiles WHERE id = @id"
                $cmd.Parameters.AddWithValue("@id", $Id) | Out-Null
            } else {
                $cmd.CommandText = "SELECT TOP 1 profileJson FROM dbo.GraphRiskProfiles ORDER BY generatedAt DESC"
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
        return $null
    }
}
