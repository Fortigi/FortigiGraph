<#
.SYNOPSIS
    Orchestrates a full Entra ID sync via the FortigiGraph Ingest API.

.DESCRIPTION
    Standalone crawler that fetches data from Microsoft Graph and POSTs it to the Ingest API.
    Replaces the old Start-FGSync direct-SQL approach with an API-driven architecture.

    Requires:
    - FortigiGraph module (for Graph API functions: Get-FGAccessToken, Invoke-FGGetRequest)
    - Ingest API running and accessible
    - Crawler API key (fgc_...)

.PARAMETER ApiBaseUrl
    Base URL of the Ingest API (e.g., https://myapp.azurewebsites.net/api)

.PARAMETER ApiKey
    Crawler API key (fgc_...)

.PARAMETER ConfigFile
    Path to FortigiGraph config file (for Graph API credentials)

.PARAMETER SyncPrincipals
    Sync user principals (default: true)

.PARAMETER SyncServicePrincipals
    Sync service principals (default: false)

.PARAMETER SyncResources
    Sync groups, directory roles, app roles (default: true)

.PARAMETER SyncAssignments
    Sync group memberships, owners, eligible members (default: true)

.PARAMETER SyncGovernance
    Sync catalogs, access packages, policies, reviews (default: true)

.PARAMETER SyncContexts
    Sync calculated department contexts (default: true)

.PARAMETER RefreshViews
    Refresh materialized SQL views after sync (default: true)

.EXAMPLE
    .\Start-EntraIDCrawler.ps1 -ApiBaseUrl "https://myapp.azurewebsites.net/api" -ApiKey "fgc_abc123..." -ConfigFile ".\Config\mycompany.json"
#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true)]
    [string]$ApiBaseUrl,

    [Parameter(Mandatory = $true)]
    [string]$ApiKey,

    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,

    [switch]$SyncPrincipals = $true,
    [switch]$SyncServicePrincipals = $false,
    [switch]$SyncResources = $true,
    [switch]$SyncAssignments = $true,
    [switch]$SyncGovernance = $true,
    [switch]$SyncContexts = $true,
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

    $headers = @{
        'Authorization' = "Bearer $ApiKey"
        'Content-Type'  = 'application/json'
    }

    $json = $Body | ConvertTo-Json -Depth 20 -Compress
    $uri = "$ApiBaseUrl/$Endpoint"

    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $json -TimeoutSec 300
        return $response
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        Write-Host "  ERROR: $Endpoint returned $statusCode - $($_.Exception.Message)" -ForegroundColor Red
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
        return @{ inserted = 0; updated = 0; deleted = 0 }
    }

    Write-Host "  Sending $($Records.Count) records to $Endpoint..." -ForegroundColor Cyan

    if ($Records.Count -le $BatchSize) {
        # Single batch
        $body = @{
            systemId = $SystemId
            syncMode = $SyncMode
            scope    = $Scope
            records  = $Records
        }
        $result = Invoke-IngestAPI -Endpoint $Endpoint -Body $body
        Write-Host "  Result: $($result.inserted) inserted, $($result.updated) updated, $($result.deleted) deleted" -ForegroundColor Green
        return $result
    }

    # Chunked session
    $totalInserted = 0
    $totalUpdated = 0
    $syncId = $null

    for ($i = 0; $i -lt $Records.Count; $i += $BatchSize) {
        $batch = $Records[$i..([Math]::Min($i + $BatchSize - 1, $Records.Count - 1))]
        $isFirst = ($i -eq 0)
        $isLast = ($i + $BatchSize -ge $Records.Count)

        $body = @{
            systemId    = $SystemId
            syncMode    = $SyncMode
            scope       = $Scope
            records     = $batch
            syncSession = if ($isFirst) { 'start' } elseif ($isLast) { 'end' } else { 'continue' }
        }
        if ($syncId) { $body.syncId = $syncId }

        $result = Invoke-IngestAPI -Endpoint $Endpoint -Body $body
        if ($isFirst) { $syncId = $result.syncId }

        $totalInserted += ($result.inserted ?? 0)
        $totalUpdated += ($result.updated ?? 0)

        $batchNum = [Math]::Floor($i / $BatchSize) + 1
        $totalBatches = [Math]::Ceiling($Records.Count / $BatchSize)
        Write-Host "  Batch $batchNum/$totalBatches done" -ForegroundColor Gray
    }

    $deleted = $result.deleted ?? 0
    Write-Host "  Total: $totalInserted inserted, $totalUpdated updated, $deleted deleted" -ForegroundColor Green
    return @{ inserted = $totalInserted; updated = $totalUpdated; deleted = $deleted }
}

# ─── Main ─────────────────────────────────────────────────────────

Write-Host "`n=== FortigiGraph EntraID Crawler ===" -ForegroundColor Cyan
Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Starting EntraID sync via Ingest API" -ForegroundColor Cyan

# Verify API connectivity
Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Verifying API connectivity..." -ForegroundColor Cyan
try {
    $headers = @{ 'Authorization' = "Bearer $ApiKey" }
    $whoami = Invoke-RestMethod -Uri "$ApiBaseUrl/crawlers/whoami" -Headers $headers
    Write-Host "  Connected as: $($whoami.displayName)" -ForegroundColor Green
}
catch {
    Write-Host "  FAILED to connect to API: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Get Graph access token
Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Authenticating to Microsoft Graph..." -ForegroundColor Cyan
Get-FGAccessToken -ConfigFile $ConfigFile

# Register/get system
Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Registering system..." -ForegroundColor Cyan
$systemResult = Invoke-IngestAPI -Endpoint 'ingest/systems' -Body @{
    syncMode = 'delta'
    records  = @(@{
        systemType   = 'EntraID'
        displayName  = "Entra ID ($Global:TenantId)"
        tenantId     = $Global:TenantId
        enabled      = $true
        syncEnabled  = $true
    })
}
# For systems, we need to look up the actual system ID
$headers = @{ 'Authorization' = "Bearer $ApiKey" }
# The system ID is auto-assigned; we need to query it
# For now, pass systemId from the crawler config or use a known ID
$systemId = 1  # TODO: resolve from API response or config

Write-Host "  System ID: $systemId" -ForegroundColor Green

$syncStart = Get-Date

# ─── Sync Principals ─────────────────────────────────────────────
if ($SyncPrincipals) {
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing principals (users)..." -ForegroundColor Cyan
    $users = Invoke-FGGetRequest -URI "https://graph.microsoft.com/beta/users?`$select=id,displayName,mail,userPrincipalName,accountEnabled,givenName,surname,department,jobTitle,companyName,employeeId,createdDateTime&`$top=999"

    $records = @($users | ForEach-Object {
        @{
            id               = $_.id
            displayName      = $_.displayName
            email            = $_.mail ?? $_.userPrincipalName
            accountEnabled   = [bool]$_.accountEnabled
            principalType    = 'User'
            givenName        = $_.givenName
            surname          = $_.surname
            department       = $_.department
            jobTitle         = $_.jobTitle
            companyName      = $_.companyName
            employeeId       = $_.employeeId
            createdDateTime  = $_.createdDateTime
        }
    })

    Send-IngestBatch -Endpoint 'ingest/principals' -SystemId $systemId -SyncMode 'full' `
        -Scope @{ principalType = 'User' } -Records $records
}

# ─── Sync Resources (Groups) ─────────────────────────────────────
if ($SyncResources) {
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing resources (groups)..." -ForegroundColor Cyan
    $groups = Invoke-FGGetRequest -URI "https://graph.microsoft.com/beta/groups?`$select=id,displayName,description,mail,visibility,createdDateTime,groupTypes,securityEnabled,mailEnabled&`$top=999"

    $records = @($groups | ForEach-Object {
        @{
            id              = $_.id
            displayName     = $_.displayName
            description     = $_.description
            resourceType    = 'EntraGroup'
            mail            = $_.mail
            visibility      = $_.visibility
            enabled         = $true
            createdDateTime = $_.createdDateTime
            extendedAttributes = @{
                groupTypes      = ($_.groupTypes -join ',')
                securityEnabled = $_.securityEnabled
                mailEnabled     = $_.mailEnabled
            }
        }
    })

    Send-IngestBatch -Endpoint 'ingest/resources' -SystemId $systemId -SyncMode 'full' `
        -Scope @{ resourceType = 'EntraGroup' } -Records $records
}

# ─── Sync Assignments (Group Members) ────────────────────────────
if ($SyncAssignments) {
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing assignments (group memberships)..." -ForegroundColor Cyan

    $allMembers = @()
    foreach ($group in $groups) {
        $members = Invoke-FGGetRequest -URI "https://graph.microsoft.com/beta/groups/$($group.id)/members?`$select=id,`@odata.type&`$top=999"
        foreach ($member in $members) {
            $allMembers += @{
                resourceId     = $group.id
                principalId    = $member.id
                assignmentType = 'Direct'
                principalType  = if ($member.'@odata.type' -eq '#microsoft.graph.group') { 'Group' } else { 'User' }
            }
        }
    }

    Send-IngestBatch -Endpoint 'ingest/resource-assignments' -SystemId $systemId -SyncMode 'full' `
        -Scope @{ assignmentType = 'Direct' } -Records $allMembers

    # Group Owners
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing assignments (group owners)..." -ForegroundColor Cyan
    $allOwners = @()
    foreach ($group in $groups) {
        $owners = Invoke-FGGetRequest -URI "https://graph.microsoft.com/beta/groups/$($group.id)/owners?`$select=id&`$top=999"
        foreach ($owner in $owners) {
            $allOwners += @{
                resourceId     = $group.id
                principalId    = $owner.id
                assignmentType = 'Owner'
            }
        }
    }

    Send-IngestBatch -Endpoint 'ingest/resource-assignments' -SystemId $systemId -SyncMode 'full' `
        -Scope @{ assignmentType = 'Owner' } -Records $allOwners
}

# ─── Sync Governance ─────────────────────────────────────────────
if ($SyncGovernance) {
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing governance (catalogs)..." -ForegroundColor Cyan
    $catalogs = Invoke-FGGetRequest -URI "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/catalogs?`$top=999"

    $catRecords = @($catalogs | ForEach-Object {
        @{
            id              = $_.id
            displayName     = $_.displayName
            description     = $_.description
            catalogType     = $_.catalogType
            enabled         = [bool]$_.isPublished
            createdDateTime = $_.createdDateTime
            modifiedDateTime = $_.modifiedDateTime
        }
    })
    Send-IngestBatch -Endpoint 'ingest/governance/catalogs' -SystemId $systemId -SyncMode 'full' -Records $catRecords

    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing governance (access packages -> business roles)..." -ForegroundColor Cyan
    $accessPackages = Invoke-FGGetRequest -URI "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackages?`$top=999"

    $apRecords = @($accessPackages | ForEach-Object {
        @{
            id              = $_.id
            displayName     = $_.displayName
            description     = $_.description
            resourceType    = 'BusinessRole'
            catalogId       = $_.catalogId
            isHidden        = [bool]$_.isHidden
            enabled         = $true
            createdDateTime = $_.createdDateTime
            modifiedDateTime = $_.modifiedDateTime
        }
    })
    Send-IngestBatch -Endpoint 'ingest/resources' -SystemId $systemId -SyncMode 'full' `
        -Scope @{ resourceType = 'BusinessRole' } -Records $apRecords
}

# ─── Refresh Views ───────────────────────────────────────────────
if ($RefreshViews) {
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Refreshing materialized views..." -ForegroundColor Cyan
    try {
        Invoke-IngestAPI -Endpoint 'ingest/refresh-views' -Body @{}
        Write-Host "  Views refreshed" -ForegroundColor Green
    }
    catch {
        Write-Host "  View refresh failed (non-critical): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ─── Summary ─────────────────────────────────────────────────────
$elapsed = (Get-Date) - $syncStart
Write-Host "`n=== Sync Complete ===" -ForegroundColor Green
Write-Host "Duration: $([Math]::Round($elapsed.TotalSeconds)) seconds" -ForegroundColor Gray
