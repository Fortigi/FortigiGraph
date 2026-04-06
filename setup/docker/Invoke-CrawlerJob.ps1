<#
.SYNOPSIS
    Dispatches a CrawlerJob to the appropriate crawler script.

.DESCRIPTION
    Called by the scheduler when a job is picked up from dbo.CrawlerJobs.
    Dispatches based on jobType: demo, entra-id, csv.
    Updates progress in SQL during execution.

.PARAMETER JobId
    The CrawlerJobs.id for progress reporting.

.PARAMETER JobType
    One of: demo, entra-id, csv

.PARAMETER Config
    Hashtable parsed from the job's config JSON column.

.PARAMETER ApiKey
    The built-in crawler API key.
#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory)]
    [int]$JobId,

    [Parameter(Mandatory)]
    [string]$JobType,

    [Parameter(Mandatory = $false)]
    [hashtable]$Config = @{},

    [Parameter(Mandatory)]
    [string]$ApiKey
)

$ErrorActionPreference = 'Stop'
$apiBaseUrl = 'http://backend:3001/api'

function Update-JobProgress {
    param([string]$Step, [int]$Pct = 0, [string]$Detail = '')
    $progressJson = (@{ step = $Step; pct = $Pct; detail = $Detail } | ConvertTo-Json -Compress) -replace "'", "''"
    try {
        Invoke-FGSQLQuery -Query "UPDATE dbo.CrawlerJobs SET progress = '$progressJson' WHERE id = $JobId"
    }
    catch {
        Write-Host "  Warning: failed to update progress — $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Set-JobResult {
    param([hashtable]$Result)
    $resultJson = ($Result | ConvertTo-Json -Compress) -replace "'", "''"
    try {
        Invoke-FGSQLQuery -Query "UPDATE dbo.CrawlerJobs SET result = '$resultJson' WHERE id = $JobId"
    }
    catch {
        Write-Host "  Warning: failed to update result — $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

switch ($JobType) {

    'demo' {
        Update-JobProgress -Step 'Loading demo dataset' -Pct 10
        $datasetPath = '/app/test/demo-dataset/demo-company.json'
        $ingestScript = '/app/test/demo-dataset/Ingest-DemoDataset.ps1'

        if (-not (Test-Path $datasetPath)) {
            # Generate it first
            Update-JobProgress -Step 'Generating demo dataset' -Pct 5
            $genScript = '/app/test/demo-dataset/Generate-DemoDataset.ps1'
            if (Test-Path $genScript) {
                & $genScript
            } else {
                throw "Demo dataset not found at $datasetPath and generator not available"
            }
        }

        Update-JobProgress -Step 'Ingesting demo data' -Pct 30

        & $ingestScript -ApiBaseUrl $apiBaseUrl -ApiKey $ApiKey -DatasetPath $datasetPath

        Update-JobProgress -Step 'Refreshing views' -Pct 90

        # Views are refreshed by the ingest script, but ensure it's done
        try {
            $headers = @{ 'Authorization' = "Bearer $ApiKey"; 'Content-Type' = 'application/json' }
            Invoke-RestMethod -Uri "$apiBaseUrl/ingest/refresh-views" -Method Post -Headers $headers -Body '{}' -ErrorAction SilentlyContinue
        } catch {}

        Update-JobProgress -Step 'Complete' -Pct 100
        Set-JobResult @{ status = 'Demo data loaded successfully' }
    }

    'entra-id' {
        Update-JobProgress -Step 'Preparing Entra ID sync' -Pct 5

        # Write a temporary config file for the crawler
        $tempConfig = "/tmp/entra-config-$JobId.json"
        $graphConfig = @{
            Graph = @{
                TenantId     = $Config['tenantId']
                ClientId     = $Config['clientId']
                ClientSecret = $Config['clientSecret']
            }
        }
        $graphConfig | ConvertTo-Json -Depth 5 | Set-Content $tempConfig -Encoding UTF8

        try {
            Update-JobProgress -Step 'Running Entra ID crawler' -Pct 10

            $crawlerParams = @{
                ApiBaseUrl = $apiBaseUrl
                ApiKey     = $ApiKey
                ConfigFile = $tempConfig
            }

            # Apply sync toggles from config
            if ($Config.ContainsKey('syncPrincipals'))         { $crawlerParams['SyncPrincipals']         = [bool]$Config['syncPrincipals'] }
            if ($Config.ContainsKey('syncServicePrincipals'))   { $crawlerParams['SyncServicePrincipals']   = [bool]$Config['syncServicePrincipals'] }
            if ($Config.ContainsKey('syncResources'))           { $crawlerParams['SyncResources']           = [bool]$Config['syncResources'] }
            if ($Config.ContainsKey('syncAssignments'))         { $crawlerParams['SyncAssignments']         = [bool]$Config['syncAssignments'] }
            if ($Config.ContainsKey('syncGovernance'))          { $crawlerParams['SyncGovernance']          = [bool]$Config['syncGovernance'] }
            if ($Config.ContainsKey('syncContexts'))            { $crawlerParams['SyncContexts']            = [bool]$Config['syncContexts'] }

            & /app/tools/crawlers/entra-id/Start-EntraIDCrawler.ps1 @crawlerParams

            Update-JobProgress -Step 'Complete' -Pct 100
            Set-JobResult @{ status = 'Entra ID sync completed successfully' }
        }
        finally {
            # Clean up temp config file (contains secrets)
            if (Test-Path $tempConfig) { Remove-Item $tempConfig -Force }
        }
    }

    'csv' {
        Update-JobProgress -Step 'Preparing CSV import' -Pct 5

        $csvFolder = $Config['csvFolder']
        if (-not $csvFolder) { $csvFolder = '/data/csv' }
        $systemName = $Config['systemName']
        if (-not $systemName) { $systemName = 'CSV Import' }
        $systemType = $Config['systemType']
        if (-not $systemType) { $systemType = 'CSV' }

        if (-not (Test-Path $csvFolder)) {
            throw "CSV folder not found: $csvFolder"
        }

        Update-JobProgress -Step 'Running CSV crawler' -Pct 10

        & /app/tools/crawlers/csv/Start-CSVCrawler.ps1 `
            -ApiBaseUrl $apiBaseUrl `
            -ApiKey $ApiKey `
            -CsvFolder $csvFolder `
            -SystemName $systemName `
            -SystemType $systemType

        Update-JobProgress -Step 'Complete' -Pct 100
        Set-JobResult @{ status = 'CSV import completed successfully' }
    }

    default {
        throw "Unknown job type: $JobType"
    }
}
