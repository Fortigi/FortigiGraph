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

    [switch]$RefreshViews = $true,

    # Optional CrawlerJobs.id — when set, the crawler reports fine-grained progress
    # back to the API. Zero / unset = no progress reporting (standalone use).
    [int]$JobId = 0
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

    # Retry policy: up to 5 attempts with exponential backoff (2s, 4s, 8s, 16s, 32s).
    # Retries on transient failures (network errors, 5xx, 429); 4xx fails immediately.
    $maxAttempts = 5
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $json -TimeoutSec 300
            if ($attempt -gt 1) { Write-Host "  Recovered on attempt $attempt" -ForegroundColor Green }
            return $response
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
            $statusCode = try { $_.Exception.Response.StatusCode.value__ } catch { $null }
            $isTransient = (-not $statusCode) -or ($statusCode -ge 500) -or ($statusCode -eq 429)

            if ($isTransient -and $attempt -lt $maxAttempts) {
                $delay = [Math]::Pow(2, $attempt)
                $reason = if ($statusCode) { "HTTP $statusCode" } else { $_.Exception.Message }
                Write-Host "  Transient failure on $Endpoint ($reason) — retry $attempt/$($maxAttempts - 1) in ${delay}s" -ForegroundColor Yellow
                Start-Sleep -Seconds $delay
                continue
            }

            Write-Host "  ERROR: $Endpoint returned $statusCode after $attempt attempt(s)" -ForegroundColor Red
            if ($responseBody) {
                Write-Host "  Response: $responseBody" -ForegroundColor Yellow
            } else {
                Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
            }
            throw
        }
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

# Best-effort progress reporter — see Entra crawler for full notes.
function Update-CrawlerProgress {
    param([string]$Step, [int]$Pct = -1, [string]$Detail)
    if (-not $JobId -or $JobId -le 0) { return }
    $body = @{ jobId = $JobId }
    if ($PSBoundParameters.ContainsKey('Step'))   { $body['step']   = $Step }
    if ($Pct -ge 0)                                { $body['pct']    = $Pct }
    if ($PSBoundParameters.ContainsKey('Detail')) { $body['detail'] = $Detail }
    try {
        $headers = @{ 'Authorization' = "Bearer $ApiKey"; 'Content-Type' = 'application/json' }
        Invoke-RestMethod -Uri "$ApiBaseUrl/crawlers/job-progress" -Method Post `
            -Headers $headers -Body ($body | ConvertTo-Json -Compress) -TimeoutSec 10 | Out-Null
    } catch { }
}

# ─── Main ─────────────────────────────────────────────────────────

Write-Host "`n=== FortigiGraph CSV Crawler ===" -ForegroundColor Cyan
Write-Host "[$(Get-Date -Format 'HH:mm:ss')] CSV folder: $CsvFolder" -ForegroundColor Gray

# Verify API connectivity
$headers = @{ 'Authorization' = "Bearer $ApiKey" }
$whoami = Invoke-RestMethod -Uri "$ApiBaseUrl/crawlers/whoami" -Headers $headers
Write-Host "Connected as: $($whoami.displayName)" -ForegroundColor Green

# ─── Register the fallback system (from Step 1 of the wizard) ────
# This system always gets created. Resources/principals that don't specify
# a system in the CSV data get linked to this one.
Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Registering fallback system ($SystemName)..." -ForegroundColor Cyan
$systemResult = Invoke-IngestAPI -Endpoint 'ingest/systems' -Body @{
    syncMode = 'delta'
    records  = @(@{ systemType = $SystemType; displayName = $SystemName; enabled = $true; syncEnabled = $true })
}
$fallbackSystemId = $null
if ($systemResult -and $systemResult.systemIds -and $systemResult.systemIds.Count -gt 0) {
    $fallbackSystemId = [int]$systemResult.systemIds[0]
} elseif ($systemResult -and $systemResult.systemId) {
    $fallbackSystemId = [int]$systemResult.systemId
}
if (-not $fallbackSystemId) {
    Write-Host "  WARNING: ingest/systems did not return a systemId — falling back to 2" -ForegroundColor Yellow
    $fallbackSystemId = 2
}
Write-Host "  Fallback system ID: $fallbackSystemId" -ForegroundColor Gray

# Build a lookup table: systemName → systemId. The fallback system is always
# in here. If Systems.csv is provided, those systems get added too.
$systemLookup = @{}
$systemLookup[$SystemName] = $fallbackSystemId

$syncStart = Get-Date

# ─── Helper: resolve a column by checking multiple candidate names ─
# Returns the first non-empty value found, or $null if none match.
function Get-Col {
    param($Row, [string[]]$Names)
    foreach ($n in $Names) {
        if ($Row.PSObject.Properties.Name -contains $n) {
            $v = $Row.$n
            if ($null -ne $v -and "$v" -ne '') { return "$v" }
        }
    }
    return $null
}

# Helper: resolve a system name from a CSV row to a systemId. Falls back to the
# Step 1 system when the column is missing or the name doesn't match any known system.
function Resolve-SystemId {
    param($Row)
    $sName = $null
    if ($Row.PSObject.Properties.Name -contains 'SystemName') { $sName = $Row.SystemName }
    elseif ($Row.PSObject.Properties.Name -contains 'System') { $sName = $Row.System }
    elseif ($Row.PSObject.Properties.Name -contains 'SYSTEMREF_VALUE') { $sName = $Row.SYSTEMREF_VALUE }
    if ($sName -and $systemLookup.ContainsKey($sName)) { return $systemLookup[$sName] }
    return $fallbackSystemId
}

# ─── Helper: group records by systemId and send per-system batches ──
function Send-GroupedBySystem {
    param(
        [string]$Endpoint,
        [string]$SyncMode = 'full',
        [hashtable]$Scope = @{},
        [array]$Records,
        [int]$BatchSize = 10000
    )
    $grouped = @{}
    foreach ($rec in $Records) {
        $sid = $rec['_systemId']
        if (-not $sid) { $sid = $fallbackSystemId }
        $rec.Remove('_systemId')
        if (-not $grouped.ContainsKey($sid)) { $grouped[$sid] = @() }
        $grouped[$sid] += $rec
    }
    foreach ($sid in $grouped.Keys) {
        $batch = $grouped[$sid]
        $seen = @{}
        foreach ($r in $batch) {
            $key = $r['externalId']
            if (-not $key) {
                $key = "$($r['resourceExternalId'])|$($r['principalExternalId'])|$($r['parentExternalId'])|$($r['childExternalId'])"
            }
            $seen[$key] = $r
        }
        $deduped = @($seen.Values)
        if ($deduped.Count -ne $batch.Count) {
            Write-Host "    Deduped: $($batch.Count) → $($deduped.Count) records" -ForegroundColor DarkGray
        }
        if ($grouped.Count -gt 1) {
            Write-Host "    System $sid`: $($deduped.Count) records" -ForegroundColor DarkGray
        }
        Send-IngestBatch -Endpoint $Endpoint -SystemId $sid -SyncMode $SyncMode `
            -Scope $Scope -Records $deduped -BatchSize $BatchSize
    }
}

Update-CrawlerProgress -Step 'Reading CSV files' -Pct 8 -Detail "Folder: $CsvFolder"

# ─── Systems.csv (optional — additional systems) ─────────────────
# Expected columns: DisplayName, SystemType, Description (all optional except DisplayName)
# Each row becomes a System record. The systemId is returned by the ingest API.
# Resources/principals can reference a system by name (SystemName column);
# unmatched ones fall back to the Step 1 system.
Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Checking for Systems.csv / System.csv..." -ForegroundColor Cyan
Update-CrawlerProgress -Step 'Processing systems' -Pct 10 -Detail 'Reading Systems.csv'
# Try both filenames — the Omada export uses "System.csv", the generic format uses "Systems.csv"
$systemsCsv = Read-CsvFile 'Systems.csv'
if (-not $systemsCsv) { $systemsCsv = Read-CsvFile 'System.csv' }
if ($systemsCsv) {
    Write-Host "  Found $($systemsCsv.Count) system(s) in CSV" -ForegroundColor Gray

    # Build all system records first, then send as one batch to avoid rate limiting
    $sysRecords = @()
    $sysNames = @()
    foreach ($sysRow in $systemsCsv) {
        $sName = Get-Col $sysRow '_DISPLAYNAME','DisplayName','Name'
        $sType = Get-Col $sysRow 'SystemType','Type'
        if (-not $sType) { $sType = $SystemType }
        $sDesc = Get-Col $sysRow 'DESCRIPTION','Description'
        if (-not $sName) { continue }
        # Deduplicate by name
        if ($sysNames -contains $sName) { continue }
        $sysNames += $sName
        $sysRecords += @{
            systemType  = $sType
            displayName = $sName
            description = $sDesc
            enabled     = $true
            syncEnabled = $true
        }
    }

    if ($sysRecords.Count -gt 0) {
        # Send all systems in one batch call (avoids 429 rate limiting)
        $sResult = Invoke-IngestAPI -Endpoint 'ingest/systems' -Body @{
            syncMode = 'delta'
            records  = $sysRecords
        }
        # Map system names → IDs from the response
        if ($sResult -and $sResult.systemIds) {
            for ($i = 0; $i -lt [Math]::Min($sysNames.Count, $sResult.systemIds.Count); $i++) {
                $systemLookup[$sysNames[$i]] = [int]$sResult.systemIds[$i]
                Write-Host "  System '$($sysNames[$i])' → ID $($sResult.systemIds[$i])" -ForegroundColor DarkGray
            }
        }
        # For any systems that didn't get an ID back, look them up individually
        foreach ($sName in $sysNames) {
            if (-not $systemLookup.ContainsKey($sName)) {
                try {
                    $lookup = Invoke-RestMethod -Uri "$ApiBaseUrl/systems" -Headers @{ 'Authorization' = "Bearer $ApiKey" } -TimeoutSec 30
                    $found = $lookup | Where-Object { $_.displayName -eq $sName } | Select-Object -First 1
                    if ($found) {
                        $systemLookup[$sName] = [int]$found.id
                        Write-Host "  System '$sName' → ID $($found.id) (via lookup)" -ForegroundColor DarkGray
                    }
                } catch { }
            }
        }
    }
    Write-Host "  System lookup: $($systemLookup.Count) system(s) available" -ForegroundColor Gray
} else {
    Write-Host "  No Systems.csv / System.csv — all data scoped to fallback system ($SystemName)" -ForegroundColor Gray
}

# For backward compat, $systemId points to the fallback
$systemId = $fallbackSystemId

# ─── OrgUnits / Contexts ─────────────────────────────────────────
Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing contexts (org units)..." -ForegroundColor Cyan
Update-CrawlerProgress -Step 'Syncing org units' -Pct 18 -Detail 'Reading Orgunits.csv'
$orgUnits = Read-CsvFile 'Orgunits.csv'
if ($orgUnits) {
    $records = @($orgUnits | ForEach-Object {
        @{
            _systemId        = Resolve-SystemId $_
            externalId       = Get-Col $_ 'OU_KEY','_ID','Id','ExternalId'
            displayName      = Get-Col $_ 'OU_Name','_DISPLAYNAME','DisplayName','Name'
            contextType      = 'OrgUnit'
            department       = Get-Col $_ 'OU_Description','Description','Department'
            parentExternalId = Get-Col $_ 'Parent_OU_Key','ParentId','ParentExternalId'
        }
    })
    Send-GroupedBySystem -Endpoint 'ingest/contexts' -SyncMode 'full' `
        -Scope @{ contextType = 'OrgUnit' } -Records $records
}

# ─── Resources (Permissions) ─────────────────────────────────────
Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing resources (permissions)..." -ForegroundColor Cyan
Update-CrawlerProgress -Step 'Syncing resources' -Pct 28 -Detail 'Reading Permissions.csv'
$permissions = Read-CsvFile 'Permissions.csv'
if (-not $permissions) { $permissions = Read-CsvFile 'Permission-full-details.csv' }
if ($permissions) {
    $records = @($permissions | ForEach-Object {
        $type = Get-Col $_ 'ResourceTypeName','ROLETYPEREF_VALUE','ResourceType','Type'
        if ($type -eq 'Business Role') { $type = 'BusinessRole' }
        $deleted = Get-Col $_ 'Deleted','RESOURCESTATUS_ENGLISH'
        $isActive = -not ($deleted -eq 'True' -or $deleted -eq '1' -or $deleted -eq 'Deleted')
        @{
            _systemId    = Resolve-SystemId $_
            externalId   = Get-Col $_ '_ID','Id','ExternalId','_UID'
            displayName  = Get-Col $_ 'DisplayName','_DISPLAYNAME','NAME','Name'
            description  = Get-Col $_ 'Description','DESCRIPTION'
            resourceType = $type
            enabled      = $isActive
        }
    })
    Send-GroupedBySystem -Endpoint 'ingest/resources' -SyncMode 'full' -Records $records
}

# ─── Resource → System mapping (ResourceSystem.csv) ─────────────
# This file links resources to systems by name. Each row has an Id (the
# resource's external ID) and a SystemName. After resources have been imported
# above (all scoped to the fallback system), we re-ingest them grouped by
# their real system so the systemId FK gets set correctly.
Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Checking for ResourceSystem.csv..." -ForegroundColor Cyan
Update-CrawlerProgress -Step 'Linking resources to systems' -Pct 33 -Detail 'Reading ResourceSystem.csv'
$resourceSystem = Read-CsvFile 'ResourceSystem.csv'
if ($resourceSystem) {
    Write-Host "  Found $($resourceSystem.Count) resource-system mapping(s)" -ForegroundColor Gray

    # Group by SystemName and re-ingest each group under the correct systemId.
    # Records whose SystemName doesn't match any known system stay on the fallback.
    $reRecords = @($resourceSystem | Where-Object { $_.Deleted -ne '1' -and $_.Deleted -ne 'True' } | ForEach-Object {
        $cols = $_.PSObject.Properties.Name
        $extId = if ($cols -contains 'Id') { $_.Id }
                 elseif ($cols -contains '_ID') { $_._ID }
                 else { $null }
        $name  = if ($cols -contains 'DisplayName') { $_.DisplayName }
                 elseif ($cols -contains 'TechName')  { $_.TechName }
                 else { $null }
        $rType = if ($cols -contains 'ResourceType') { $_.ResourceType }
                 elseif ($cols -contains 'ResourceTypeName') { $_.ResourceTypeName }
                 else { $null }
        if ($rType -eq 'Business Role') { $rType = 'BusinessRole' }
        if (-not $extId) { return }

        $sysName = if ($cols -contains 'SystemName') { $_.SystemName } else { $null }
        $sid = if ($sysName -and $systemLookup.ContainsKey($sysName)) { $systemLookup[$sysName] } else { $fallbackSystemId }

        @{
            _systemId    = $sid
            externalId   = $extId
            displayName  = $name
            resourceType = $rType
            enabled      = $true
        }
    } | Where-Object { $_ })

    if ($reRecords.Count -gt 0) {
        # Use delta mode — we're updating existing resources, not replacing them.
        # This preserves any resources that aren't in ResourceSystem.csv.
        Send-GroupedBySystem -Endpoint 'ingest/resources' -SyncMode 'delta' -Records $reRecords
    }
    Write-Host "  Linked $($reRecords.Count) resources to their systems" -ForegroundColor Green
} else {
    Write-Host "  No ResourceSystem.csv — resources stay on fallback system" -ForegroundColor Gray
}

# ─── Resource Relationships (Nesting) ────────────────────────────
Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing resource relationships (nesting)..." -ForegroundColor Cyan
Update-CrawlerProgress -Step 'Syncing resource relationships' -Pct 38 -Detail 'Reading Permission-Nesting.csv'
$nesting = Read-CsvFile 'Permission-Nesting.csv'
if ($nesting) {
    $records = @($nesting | ForEach-Object {
        @{
            _systemId        = Resolve-SystemId $_
            parentExternalId = Get-Col $_ 'ParentPermissionID','ParentUID','ParentId'
            childExternalId  = Get-Col $_ 'ChildPermissionID','ChildUID','ChildId'
            relationshipType = 'Contains'
        }
    } | Where-Object { $_.parentExternalId -and $_.childExternalId })
    Send-GroupedBySystem -Endpoint 'ingest/resource-relationships' -SyncMode 'full' `
        -Scope @{ relationshipType = 'Contains' } -Records $records
}

# ─── Principals (Users) ──────────────────────────────────────────
Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing principals (users)..." -ForegroundColor Cyan
Update-CrawlerProgress -Step 'Syncing users' -Pct 48 -Detail 'Reading Users.csv'
$users = Read-CsvFile 'Users.csv'
if ($users) {
    $records = @($users | ForEach-Object {
        $empId = Get-Col $_ '_ID','EmployeeNumber','Employee_ID','Id','ExternalId'
        @{
            _systemId      = Resolve-SystemId $_
            externalId     = $empId
            displayName    = Get-Col $_ 'DisplayName','_DISPLAYNAME','Employee_fullname','Name'
            email          = Get-Col $_ 'EmailAddress','EMAIL','Email'
            jobTitle       = Get-Col $_ 'Job_Title','JobTitle','JOBTITLE'
            department     = Get-Col $_ 'Department','OU_KEY'
            principalType  = Get-Col $_ 'Employee_Type','PrincipalType','Type'
            accountEnabled = -not ((Get-Col $_ 'Deleted','Status') -in @('True','1','Deleted','Inactive'))
        }
    } | Where-Object { $_.externalId -and $_.displayName })
    # Normalise principalType — map Omada Employee_Type to our conventions
    foreach ($r in $records) {
        if (-not $r.principalType -or $r.principalType -notin @('User','ServicePrincipal','ManagedIdentity','WorkloadIdentity','AIAgent','ExternalUser','SharedMailbox')) {
            $r.principalType = 'User'
        }
    }
    Send-GroupedBySystem -Endpoint 'ingest/principals' -SyncMode 'full' `
        -Scope @{ principalType = 'User' } -Records $records
}

# ─── Resource Assignments ────────────────────────────────────────
Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing resource assignments..." -ForegroundColor Cyan
Update-CrawlerProgress -Step 'Syncing resource assignments' -Pct 58 -Detail 'Reading Account-Permission.csv'
$assignments = Read-CsvFile 'Account-Permission.csv'
if ($assignments) {
    $records = @($assignments | ForEach-Object {
        @{
            _systemId           = Resolve-SystemId $_
            resourceExternalId  = Get-Col $_ 'PermissionID','ResouceUID','ResourceUID','ResourceId','_ID'
            principalExternalId = Get-Col $_ 'AccountID','Employee_ID','Account','UserId','PrincipalId'
            assignmentType      = 'Direct'
        }
    } | Where-Object { $_.resourceExternalId -and $_.principalExternalId })
    Send-GroupedBySystem -Endpoint 'ingest/resource-assignments' -SyncMode 'full' `
        -Scope @{ assignmentType = 'Direct' } -Records $records
}

# ─── Identities ──────────────────────────────────────────────────
Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing identities..." -ForegroundColor Cyan
Update-CrawlerProgress -Step 'Syncing identities' -Pct 68 -Detail 'Reading Identities.csv'
$identities = Read-CsvFile 'Identities.csv'
if ($identities) {
    # Filter to primary identities only if the IdentityType column exists
    $filtered = $identities
    $hasTypeCol = $identities | Select-Object -First 1 | ForEach-Object { $_.PSObject.Properties.Name -contains 'IDENTITYTYPE_ENGLISH' -or $_.PSObject.Properties.Name -contains 'IdentityType' }
    if ($hasTypeCol) {
        $filtered = @($identities | Where-Object {
            $t = Get-Col $_ 'IdentityType','IDENTITYTYPE_ENGLISH'
            (-not $t) -or ($t -eq 'Primary') -or ($t -eq 'Person')
        })
    }
    $records = @($filtered | ForEach-Object {
        @{
            _systemId   = Resolve-SystemId $_
            externalId  = Get-Col $_ '_ID','Id','ExternalId','IDENTITYID'
            displayName = Get-Col $_ 'DisplayName','_DISPLAYNAME','Name'
            email       = Get-Col $_ 'EmailAddress','EMAIL','Email'
            employeeId  = Get-Col $_ 'EMPLOYEEID','EmployeeID','EmployeeId','Employee_ID'
        }
    } | Where-Object { $_.externalId })
    Send-GroupedBySystem -Endpoint 'ingest/identities' -SyncMode 'full' -Records $records
}

# ─── Certifications ──────────────────────────────────────────────
Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing certifications..." -ForegroundColor Cyan
Update-CrawlerProgress -Step 'Syncing certifications' -Pct 73 -Detail 'Reading CRAs.csv'
$cras = Read-CsvFile 'CRAs.csv'
if ($cras) {
    $records = @($cras | ForEach-Object {
        @{
            _systemId  = Resolve-SystemId $_
            externalId = $_._ID
            decision   = $_.Decision
            reviewedBy = $_.ReviewerDisplayName
        }
    })
    Send-GroupedBySystem -Endpoint 'ingest/governance/certifications' -SyncMode 'full' -Records $records
}

# ─── Refresh Views ───────────────────────────────────────────────
if ($RefreshViews) {
    Update-CrawlerProgress -Step 'Refreshing materialized views' -Pct 78 -Detail 'Rebuilding SQL views...'
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Refreshing materialized views..." -ForegroundColor Cyan
    try {
        Invoke-IngestAPI -Endpoint 'ingest/refresh-views' -Body @{}
        Write-Host "  Views refreshed" -ForegroundColor Green
    }
    catch {
        Write-Host "  View refresh failed (non-critical)" -ForegroundColor Yellow
    }
}

# ─── Refresh Contexts ────────────────────────────────────────────
Update-CrawlerProgress -Step 'Refreshing contexts' -Pct 82 -Detail 'Rebuilding derived OrgUnit contexts'
try {
    $ctxResult = Invoke-IngestAPI -Endpoint 'ingest/refresh-contexts' -Body @{}
    Write-Host "  Contexts refreshed: $($ctxResult.contextsCreated) row(s)" -ForegroundColor Green
} catch {
    Write-Host "  Context refresh failed (non-critical): $($_.Exception.Message)" -ForegroundColor Yellow
}

$elapsed = (Get-Date) - $syncStart
Write-Host "`n=== CSV Sync Complete ===" -ForegroundColor Green
Write-Host "Duration: $([Math]::Round($elapsed.TotalSeconds)) seconds" -ForegroundColor Gray

# Write a full-sync log entry for the Sync Log page
try {
    Invoke-IngestAPI -Endpoint 'ingest/sync-log' -Body @{
        syncType    = 'CSV-FullCrawl'
        tableName   = $null
        startTime   = $syncStart.ToString('o')
        endTime     = (Get-Date).ToString('o')
        recordCount = 0
        status      = 'Success'
    } | Out-Null
} catch {
    Write-Host "  (sync log write failed: $($_.Exception.Message))" -ForegroundColor DarkGray
}
