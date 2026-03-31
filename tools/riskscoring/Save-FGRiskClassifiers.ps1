function Save-FGRiskClassifiers {
    <#
    .SYNOPSIS
    Persists a risk classifier ruleset to SQL for use in Azure Automation.

    .DESCRIPTION
    Saves the classifier ruleset JSON to the GraphRiskClassifiers temporal table.
    This allows Invoke-FGRiskScoring to load classifiers from SQL when running
    in Azure Automation (where local classifier files are not available).

    The table is created automatically if it does not exist.

    .PARAMETER ClassifierRuleset
    The classifier ruleset object (as returned by New-FGRiskClassifiers or loaded from JSON).

    .PARAMETER Id
    The identifier for this ruleset. Defaults to the customer domain from the ruleset,
    or "default" if no customer is specified.

    .EXAMPLE
    $ruleset = Get-Content .\classifier-ruleset.json | ConvertFrom-Json
    Save-FGRiskClassifiers -ClassifierRuleset $ruleset

    .EXAMPLE
    Save-FGRiskClassifiers -ClassifierRuleset $ruleset -Id "portofrotterdam.com"

    .NOTES
    Requires Connect-FGSQLServer to be called first.
    #>

    [alias("Save-RiskClassifiers")]
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [PSObject]$ClassifierRuleset,

        [Parameter(Mandatory = $false)]
        [System.String]$Id
    )

    # Determine ID
    if (-not $Id) {
        $Id = if ($ClassifierRuleset.customer) { $ClassifierRuleset.customer } else { "default" }
    }

    # Serialize to JSON
    $classifierJson = $ClassifierRuleset | ConvertTo-Json -Depth 100

    # Ensure table exists
    $tableExists = $false
    try {
        $tableExists = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            $cmd = $connection.CreateCommand()
            $cmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'GraphRiskClassifiers' AND TABLE_SCHEMA = 'dbo'"
            return [int]$cmd.ExecuteScalar() -gt 0
        }
    } catch { }

    if (-not $tableExists) {
        Write-Host "    Creating GraphRiskClassifiers table..." -ForegroundColor Gray
        $columns = [ordered]@{
            'id'              = 'NVARCHAR(200) NOT NULL'
            'version'         = 'NVARCHAR(20) NULL'
            'customer'        = 'NVARCHAR(200) NULL'
            'generatedAt'     = 'DATETIME2 NULL'
            'llmProvider'     = 'NVARCHAR(50) NULL'
            'classifierJson'  = 'NVARCHAR(MAX) NOT NULL'
        }
        Initialize-FGSQLTable -TableName 'GraphRiskClassifiers' -Columns $columns -PrimaryKey 'id'
    }

    # Parse metadata from ruleset
    $version = if ($ClassifierRuleset.version) { $ClassifierRuleset.version } else { [DBNull]::Value }
    $customer = if ($ClassifierRuleset.customer) { $ClassifierRuleset.customer } else { [DBNull]::Value }
    $generatedAt = if ($ClassifierRuleset.generated_at) {
        try { [datetime]::Parse($ClassifierRuleset.generated_at) } catch { [DBNull]::Value }
    } else { [DBNull]::Value }
    $llmProvider = if ($ClassifierRuleset.llm_provider) { $ClassifierRuleset.llm_provider } else { [DBNull]::Value }

    # MERGE upsert
    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandTimeout = 60
        $cmd.CommandText = @"
MERGE dbo.GraphRiskClassifiers AS target
USING (SELECT @id AS id) AS source ON target.id = source.id
WHEN MATCHED THEN UPDATE SET
    version = @version,
    customer = @customer,
    generatedAt = @generatedAt,
    llmProvider = @llmProvider,
    classifierJson = @classifierJson
WHEN NOT MATCHED THEN INSERT (id, version, customer, generatedAt, llmProvider, classifierJson)
VALUES (@id, @version, @customer, @generatedAt, @llmProvider, @classifierJson);
"@
        $cmd.Parameters.AddWithValue("@id", $Id) | Out-Null
        $cmd.Parameters.AddWithValue("@version", $version) | Out-Null
        $cmd.Parameters.AddWithValue("@customer", $customer) | Out-Null
        $cmd.Parameters.AddWithValue("@generatedAt", $generatedAt) | Out-Null
        $cmd.Parameters.AddWithValue("@llmProvider", $llmProvider) | Out-Null
        $cmd.Parameters.AddWithValue("@classifierJson", $classifierJson) | Out-Null
        $cmd.ExecuteNonQuery() | Out-Null
    }

    $groupCount = @($ClassifierRuleset.groups | Where-Object { $_ }).Count
    $userCount = @($ClassifierRuleset.users | Where-Object { $_ }).Count
    Write-Host "    Classifiers saved to SQL: id='$Id' ($groupCount group, $userCount user rules, $([Math]::Round($classifierJson.Length / 1KB, 1)) KB)" -ForegroundColor Green
}
