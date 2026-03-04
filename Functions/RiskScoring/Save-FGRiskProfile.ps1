function Save-FGRiskProfile {
    <#
    .SYNOPSIS
    Persists a risk profile to SQL for use in Azure Automation and risk scoring.

    .DESCRIPTION
    Saves the risk profile JSON to the GraphRiskProfiles temporal table.
    This allows New-FGRiskClassifiers and Invoke-FGRiskScoring to load
    profiles from SQL without requiring local files.

    The table is created automatically if it does not exist.

    .PARAMETER RiskProfile
    The risk profile object (as returned by New-FGRiskProfile or loaded from JSON).

    .PARAMETER Id
    The identifier for this profile. Defaults to the customer domain from the profile,
    or "default" if no domain is specified.

    .EXAMPLE
    $profile = New-FGRiskProfile -Domain portofrotterdam.com -ConfigFile .\Config\por.json
    Save-FGRiskProfile -RiskProfile $profile

    .NOTES
    Requires Connect-FGSQLServer to be called first.
    #>

    [alias("Save-RiskProfile")]
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [PSObject]$RiskProfile,

        [Parameter(Mandatory = $false)]
        [System.String]$Id
    )

    # Extract customer_profile (handle both nested and flat formats)
    $cp = if ($RiskProfile.customer_profile) { $RiskProfile.customer_profile } else { $RiskProfile }

    # Determine ID
    if (-not $Id) {
        $Id = if ($cp.domain) { $cp.domain } else { "default" }
    }

    # Serialize to JSON
    $profileJson = $RiskProfile | ConvertTo-Json -Depth 100

    # Ensure table exists
    $tableExists = $false
    try {
        $tableExists = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            $cmd = $connection.CreateCommand()
            $cmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'GraphRiskProfiles' AND TABLE_SCHEMA = 'dbo'"
            return [int]$cmd.ExecuteScalar() -gt 0
        }
    } catch { }

    if (-not $tableExists) {
        Write-Host "    Creating GraphRiskProfiles table..." -ForegroundColor Gray
        $columns = [ordered]@{
            'id'            = 'NVARCHAR(200) NOT NULL'
            'domain'        = 'NVARCHAR(200) NULL'
            'industry'      = 'NVARCHAR(200) NULL'
            'country'       = 'NVARCHAR(100) NULL'
            'llmProvider'   = 'NVARCHAR(50) NULL'
            'generatedAt'   = 'DATETIME2 NULL'
            'profileJson'   = 'NVARCHAR(MAX) NOT NULL'
        }
        Initialize-FGSQLTable -TableName 'GraphRiskProfiles' -Columns $columns -PrimaryKey 'id'
    }

    # Parse metadata from profile
    $domain = if ($cp.domain) { $cp.domain } else { [DBNull]::Value }
    $industry = if ($cp.industry) { $cp.industry } else { [DBNull]::Value }
    $country = if ($cp.country) { $cp.country } else { [DBNull]::Value }
    $llmProvider = if ($cp.llm_provider) { $cp.llm_provider } else { [DBNull]::Value }
    $generatedAt = if ($cp.generated_at) {
        try { [datetime]::Parse($cp.generated_at) } catch { [DBNull]::Value }
    } else { [DBNull]::Value }

    # MERGE upsert
    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandTimeout = 60
        $cmd.CommandText = @"
MERGE dbo.GraphRiskProfiles AS target
USING (SELECT @id AS id) AS source ON target.id = source.id
WHEN MATCHED THEN UPDATE SET
    domain = @domain,
    industry = @industry,
    country = @country,
    llmProvider = @llmProvider,
    generatedAt = @generatedAt,
    profileJson = @profileJson
WHEN NOT MATCHED THEN INSERT (id, domain, industry, country, llmProvider, generatedAt, profileJson)
VALUES (@id, @domain, @industry, @country, @llmProvider, @generatedAt, @profileJson);
"@
        $cmd.Parameters.AddWithValue("@id", $Id) | Out-Null
        $cmd.Parameters.AddWithValue("@domain", $domain) | Out-Null
        $cmd.Parameters.AddWithValue("@industry", $industry) | Out-Null
        $cmd.Parameters.AddWithValue("@country", $country) | Out-Null
        $cmd.Parameters.AddWithValue("@llmProvider", $llmProvider) | Out-Null
        $cmd.Parameters.AddWithValue("@generatedAt", $generatedAt) | Out-Null
        $cmd.Parameters.AddWithValue("@profileJson", $profileJson) | Out-Null
        $cmd.ExecuteNonQuery() | Out-Null
    }

    $industryDisplay = if ($cp.industry) { $cp.industry } else { "unknown" }
    Write-Host "    Risk profile saved to SQL: id='$Id' (industry=$industryDisplay, $([Math]::Round($profileJson.Length / 1KB, 1)) KB)" -ForegroundColor Green
}
