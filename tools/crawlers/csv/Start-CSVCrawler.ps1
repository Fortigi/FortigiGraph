<#
.SYNOPSIS
    Orchestrates a full CSV data sync via the FortigiGraph Ingest API.

.DESCRIPTION
    Standalone crawler that reads CSV files (e.g., Omada Identity exports) and POSTs
    them to the Ingest API. Replaces the old Start-FGCSVSync direct-SQL approach.

    CSV files are expected to be semicolon-delimited, UTF-8 encoded.

    Requires:
    - Ingest API running and accessible
    - Crawler API key (fgc_...)
    - CSV export folder with expected file names

.PARAMETER ApiBaseUrl
    Base URL of the Ingest API (e.g., https://myapp.azurewebsites.net/api)

.PARAMETER ApiKey
    Crawler API key (fgc_...)

.PARAMETER CsvFolder
    Path to folder containing CSV export files

.PARAMETER SystemName
    Display name for this system (e.g., "Omada Identity")

.PARAMETER SystemType
    System type identifier (e.g., "Omada", "CSV")

.PARAMETER Delimiter
    CSV delimiter (default: ";")

.PARAMETER RefreshViews
    Refresh materialized SQL views after sync (default: true)

.EXAMPLE
    .\Start-CSVCrawler.ps1 -ApiBaseUrl "https://myapp.azurewebsites.net/api" -ApiKey "fgc_abc123..." -CsvFolder ".\Exports\Omada" -SystemName "Omada Identity" -SystemType "Omada"
#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true)]
    [string]$ApiBaseUrl,

    [Parameter(Mandatory = $true)]
    [string]$ApiKey,

    [Parameter(Mandatory = $true)]
    [string]$CsvFolder,

    [Parameter(Mandatory = $false)]
    [string]$SystemName = 'CSV Import',

    [Parameter(Mandatory = $false)]
    [string]$SystemType = 'CSV',

    [Parameter(Mandatory = $false)]
    [string]$Delimiter = ';',

    [switch]$RefreshViews = $true
)

$ErrorActionPreference = 'Stop'
$ApiBaseUrl = $ApiBaseUrl.TrimEnd('/')

# ─── Helper: POST to Ingest API ──────────────────────────────────

function Invoke-IngestAPI {
    param(
        [string]$Endpoint,
        [hashtable]$Body
    )
    $headers = @{ 'Authorization' = "Bearer $ApiKey"; 'Content-Type' = 'application/json' }
    $json = $Body | ConvertTo-Json -Depth 20 -Compress
    $uri = "$ApiBaseUrl/$Endpoint"
    try {
        return Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $json -TimeoutSec 300
    }
    catch {
        $responseBody = $null
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            if ($stream) {
                $reader = [System.IO.StreamReader]::new($stream)
                $responseBody = $reader.ReadToEnd()
                $reader.Close()
            }
        } catch {}
        $statusCode = try { $_.Exception.Response.StatusCode.value__ } catch { '?' }
        Write-Host "  ERROR: $Endpoint returned $statusCode" -ForegroundColor Red
        if ($responseBody) {
            Write-Host "  Response: $responseBody" -ForegroundColor Yellow
        } else {
            Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
        }
        throw
    }
}

function Send-IngestBatch {
    param(
        [string]$Endpoint,
        [int]$SystemId,
        [string]$SyncMode = 'full',
        [hashtable]$Scope = @{},
        [array]$Records,
        [int]$BatchSize = 10000
    )

    if (-not $Records -or $Records.Count -eq 0) {
        Write-Host "  No records to send" -ForegroundColor Yellow
        return
    }

    Write-Host "  Sending $($Records.Count) records to $Endpoint..." -ForegroundColor Cyan

    if ($Records.Count -le $BatchSize) {
        $body = @{ systemId = $SystemId; syncMode = $SyncMode; scope = $Scope; records = $Records;
                   idGeneration = 'deterministic'; idPrefix = "$SystemType-$($Endpoint.Split('/')[-1])" }
        $result = Invoke-IngestAPI -Endpoint $Endpoint -Body $body
        Write-Host "  Result: $($result.inserted) inserted, $($result.updated) updated, $($result.deleted) deleted" -ForegroundColor Green
        return
    }

    # Chunked
    $syncId = $null
    for ($i = 0; $i -lt $Records.Count; $i += $BatchSize) {
        $batch = $Records[$i..([Math]::Min($i + $BatchSize - 1, $Records.Count - 1))]
        $isFirst = ($i -eq 0)
        $isLast = ($i + $BatchSize -ge $Records.Count)

        $body = @{
            systemId     = $SystemId; syncMode = $SyncMode; scope = $Scope; records = $batch
            idGeneration = 'deterministic'; idPrefix = "$SystemType-$($Endpoint.Split('/')[-1])"
            syncSession  = if ($isFirst) { 'start' } elseif ($isLast) { 'end' } else { 'continue' }
        }
        if ($syncId) { $body.syncId = $syncId }

        $result = Invoke-IngestAPI -Endpoint $Endpoint -Body $body
        if ($isFirst) { $syncId = $result.syncId }
    }

    Write-Host "  Chunked sync complete" -ForegroundColor Green
}

function Read-CsvFile {
    param([string]$FileName)
    $path = Join-Path $CsvFolder $FileName
    if (-not (Test-Path $path)) {
        Write-Host "  File not found: $FileName — skipping" -ForegroundColor Yellow
        return $null
    }
    return Import-Csv -Path $path -Delimiter $Delimiter -Encoding UTF8
}

# ─── Main ─────────────────────────────────────────────────────────

Write-Host "`n=== FortigiGraph CSV Crawler ===" -ForegroundColor Cyan
Write-Host "[$(Get-Date -Format 'HH:mm:ss')] CSV folder: $CsvFolder" -ForegroundColor Gray

# Verify API connectivity
$headers = @{ 'Authorization' = "Bearer $ApiKey" }
$whoami = Invoke-RestMethod -Uri "$ApiBaseUrl/crawlers/whoami" -Headers $headers
Write-Host "Connected as: $($whoami.displayName)" -ForegroundColor Green

# Register system
Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Registering system..." -ForegroundColor Cyan
Invoke-IngestAPI -Endpoint 'ingest/systems' -Body @{
    syncMode = 'delta'
    records  = @(@{ systemType = $SystemType; displayName = $SystemName; enabled = $true; syncEnabled = $true })
}
$systemId = 2  # TODO: resolve from API

$syncStart = Get-Date

# ─── OrgUnits / Contexts ─────────────────────────────────────────
Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing contexts (org units)..." -ForegroundColor Cyan
$orgUnits = Read-CsvFile 'Orgunits.csv'
if ($orgUnits) {
    $records = @($orgUnits | ForEach-Object {
        @{
            externalId       = $_.OU_KEY
            displayName      = $_.OU_Name
            contextType      = 'OrgUnit'
            department       = $_.OU_Description
            parentExternalId = $_.Parent_OU_Key
        }
    })
    Send-IngestBatch -Endpoint 'ingest/contexts' -SystemId $systemId -SyncMode 'full' `
        -Scope @{ contextType = 'OrgUnit' } -Records $records
}

# ─── Resources (Permissions) ─────────────────────────────────────
Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing resources (permissions)..." -ForegroundColor Cyan
$permissions = Read-CsvFile 'Permissions.csv'
if ($permissions) {
    $records = @($permissions | ForEach-Object {
        $type = $_.ResourceTypeName
        if ($type -eq 'Business Role') { $type = 'BusinessRole' }
        @{
            externalId   = $_._ID
            displayName  = $_.DisplayName
            resourceType = $type
            enabled      = ($_.Deleted -ne 'True')
        }
    })
    Send-IngestBatch -Endpoint 'ingest/resources' -SystemId $systemId -SyncMode 'full' -Records $records
}

# ─── Resource Relationships (Nesting) ────────────────────────────
Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing resource relationships (nesting)..." -ForegroundColor Cyan
$nesting = Read-CsvFile 'Permission-Nesting.csv'
if ($nesting) {
    $records = @($nesting | ForEach-Object {
        @{
            parentExternalId = $_.ParentPermissionID
            childExternalId  = $_.ChildPermissionID
            relationshipType = 'Contains'
        }
    })
    Send-IngestBatch -Endpoint 'ingest/resource-relationships' -SystemId $systemId -SyncMode 'full' `
        -Scope @{ relationshipType = 'Contains' } -Records $records
}

# ─── Principals (Users) ──────────────────────────────────────────
Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing principals (users)..." -ForegroundColor Cyan
$users = Read-CsvFile 'Users.csv'
if ($users) {
    $records = @($users | ForEach-Object {
        @{
            externalId     = $_._ID
            displayName    = $_.DisplayName
            email          = $_.EmailAddress
            principalType  = 'User'
            accountEnabled = ($_.Deleted -ne 'True')
        }
    })
    Send-IngestBatch -Endpoint 'ingest/principals' -SystemId $systemId -SyncMode 'full' `
        -Scope @{ principalType = 'User' } -Records $records
}

# ─── Resource Assignments ────────────────────────────────────────
Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing resource assignments..." -ForegroundColor Cyan
$assignments = Read-CsvFile 'Account-Permission.csv'
if ($assignments) {
    $records = @($assignments | ForEach-Object {
        @{
            resourceExternalId = $_.PermissionID
            principalExternalId = $_.AccountID
            assignmentType = 'Direct'
        }
    })
    Send-IngestBatch -Endpoint 'ingest/resource-assignments' -SystemId $systemId -SyncMode 'full' `
        -Scope @{ assignmentType = 'Direct' } -Records $records
}

# ─── Identities ──────────────────────────────────────────────────
Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing identities..." -ForegroundColor Cyan
$identities = Read-CsvFile 'Identities.csv'
if ($identities) {
    $records = @($identities | Where-Object { $_.IdentityType -eq 'Primary' } | ForEach-Object {
        @{
            externalId  = $_._ID
            displayName = $_.DisplayName
            email       = $_.EmailAddress
            employeeId  = $_.EMPLOYEEID
        }
    })
    Send-IngestBatch -Endpoint 'ingest/identities' -SystemId $systemId -SyncMode 'full' -Records $records
}

# ─── Certifications ──────────────────────────────────────────────
Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing certifications..." -ForegroundColor Cyan
$cras = Read-CsvFile 'CRAs.csv'
if ($cras) {
    $records = @($cras | ForEach-Object {
        @{
            externalId = $_._ID
            decision   = $_.Decision
            reviewedBy = $_.ReviewerDisplayName
        }
    })
    Send-IngestBatch -Endpoint 'ingest/governance/certifications' -SystemId $systemId -SyncMode 'full' -Records $records
}

# ─── Refresh Views ───────────────────────────────────────────────
if ($RefreshViews) {
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Refreshing materialized views..." -ForegroundColor Cyan
    try {
        Invoke-IngestAPI -Endpoint 'ingest/refresh-views' -Body @{}
        Write-Host "  Views refreshed" -ForegroundColor Green
    }
    catch {
        Write-Host "  View refresh failed (non-critical)" -ForegroundColor Yellow
    }
}

$elapsed = (Get-Date) - $syncStart
Write-Host "`n=== CSV Sync Complete ===" -ForegroundColor Green
Write-Host "Duration: $([Math]::Round($elapsed.TotalSeconds)) seconds" -ForegroundColor Gray
