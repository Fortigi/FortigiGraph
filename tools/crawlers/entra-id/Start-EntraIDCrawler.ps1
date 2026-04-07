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
    [switch]$SyncPim = $false,
    [switch]$RefreshViews = $true,

    # Custom user attributes to include in the sync (added to $select)
    [string[]]$CustomUserAttributes = @(),

    # Custom group attributes to include in the sync (added to $select)
    [string[]]$CustomGroupAttributes = @(),

    # Identity filter: select which users are treated as identities
    # Format: @{ attribute='employeeId'; condition='isNotNull' }
    #     or: @{ attribute='employeeType'; condition='equals'; value='Employee' }
    #     or: @{ attribute='companyName'; condition='inValues'; values=@('Contoso','Fabrikam') }
    [hashtable]$IdentityFilter = @{}
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
        $statusCode = $null
        $responseBody = $null
        try {
            $statusCode = $_.Exception.Response.StatusCode.value__
            $stream = $_.Exception.Response.GetResponseStream()
            if ($stream) {
                $reader = [System.IO.StreamReader]::new($stream)
                $responseBody = $reader.ReadToEnd()
                $reader.Close()
            }
        } catch {}

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

# Read the actual system ID from the API response. The ingest/systems endpoint
# returns systemIds[] in the response after looking up the merged record(s).
$systemId = $null
if ($systemResult.systemIds -and $systemResult.systemIds.Count -gt 0) {
    $systemId = [int]$systemResult.systemIds[0]
}
if (-not $systemId) {
    Write-Host "  WARNING: ingest/systems did not return a systemId — falling back to 1" -ForegroundColor Yellow
    $systemId = 1
}

Write-Host "  System ID: $systemId" -ForegroundColor Green

$syncStart = Get-Date

# ─── Helper: get attribute value, handling extensionAttributeN ────
# extensionAttribute1-15 live under onPremisesExtensionAttributes
function Get-UserAttrValue {
    param($User, [string]$AttrName)
    if ($AttrName -match '^extensionAttribute\d+$') {
        if ($User.onPremisesExtensionAttributes) {
            return $User.onPremisesExtensionAttributes.$AttrName
        }
        return $null
    }
    return $User.$AttrName
}

# ─── Sync Principals ─────────────────────────────────────────────
if ($SyncPrincipals) {
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing principals (users)..." -ForegroundColor Cyan

    # Build $select dynamically — core attributes + custom
    $coreUserAttrs = @('id','displayName','mail','userPrincipalName','accountEnabled','givenName','surname','department','jobTitle','companyName','employeeId','createdDateTime')

    # If any custom attribute is extensionAttributeN, add onPremisesExtensionAttributes to the select
    $extraSelectAttrs = @()
    $hasExtensionAttrs = $false
    foreach ($attr in $CustomUserAttributes) {
        if ($attr -match '^extensionAttribute\d+$') {
            $hasExtensionAttrs = $true
        } else {
            $extraSelectAttrs += $attr
        }
    }
    # Also check identity filter — if it filters on extensionAttributeN we need the parent
    if ($IdentityFilter['attribute'] -match '^extensionAttribute\d+$') {
        $hasExtensionAttrs = $true
    }
    if ($hasExtensionAttrs) {
        $extraSelectAttrs += 'onPremisesExtensionAttributes'
    }
    $allUserAttrs = $coreUserAttrs + $extraSelectAttrs | Select-Object -Unique
    $userSelect = $allUserAttrs -join ','
    $users = Invoke-FGGetRequest -URI "https://graph.microsoft.com/beta/users?`$select=$userSelect&`$top=999"

    $records = @($users | ForEach-Object {
        $rec = @{
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
        # Add custom attributes to extendedAttributes (handles extensionAttribute* lookup)
        if ($CustomUserAttributes.Count -gt 0) {
            $ext = @{}
            foreach ($attr in $CustomUserAttributes) {
                $val = Get-UserAttrValue -User $_ -AttrName $attr
                if ($null -ne $val -and $val -ne '') { $ext[$attr] = $val }
            }
            if ($ext.Count -gt 0) { $rec['extendedAttributes'] = $ext }
        }
        $rec
    })

    Send-IngestBatch -Endpoint 'ingest/principals' -SystemId $systemId -SyncMode 'full' `
        -Scope @{ principalType = 'User' } -Records $records

    # ─── Identity sync (filtered subset of users) ────────────────
    if ($IdentityFilter.Count -gt 0 -and $IdentityFilter['attribute']) {
        Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing identities (filtered from users)..." -ForegroundColor Cyan
        $attr = $IdentityFilter['attribute']
        $condition = $IdentityFilter['condition']
        $filterValue = $IdentityFilter['value']
        $filterValues = $IdentityFilter['values']

        # Coerce filter value to match the attribute's runtime type — booleans
        # need a real $true/$false (PowerShell -eq is type-strict for booleans)
        function ConvertTo-FilterValue {
            param($Value, $Sample)
            if ($null -eq $Value -or $null -eq $Sample) { return $Value }
            if ($Sample -is [bool]) {
                if ($Value -is [bool]) { return $Value }
                $s = "$Value".Trim().ToLower()
                if ($s -in @('true','1','yes','on'))  { return $true }
                if ($s -in @('false','0','no','off')) { return $false }
            }
            if ($Sample -is [int] -or $Sample -is [long]) {
                $n = 0; if ([int]::TryParse("$Value", [ref]$n)) { return $n }
            }
            return $Value
        }

        $identityUsers = $users | Where-Object {
            $val = Get-UserAttrValue -User $_ -AttrName $attr
            $coercedValue = ConvertTo-FilterValue -Value $filterValue -Sample $val
            $coercedValues = if ($filterValues) { $filterValues | ForEach-Object { ConvertTo-FilterValue -Value $_ -Sample $val } } else { @() }
            switch ($condition) {
                'isNotNull'  { $null -ne $val -and $val -ne '' }
                'equals'     { $val -eq $coercedValue }
                'notEquals'  { $val -ne $coercedValue }
                'inValues'   { $coercedValues -contains $val }
                default      { $false }
            }
        }

        Write-Host "  Matched $($identityUsers.Count) of $($users.Count) users as identities (filter: $attr $condition $filterValue$($filterValues -join ','))" -ForegroundColor Cyan

        if ($identityUsers.Count -gt 0) {
            $idRecords = @($identityUsers | ForEach-Object {
                $idRec = @{
                    id            = $_.id
                    displayName   = $_.displayName
                    email         = $_.mail ?? $_.userPrincipalName
                    department    = $_.department
                    jobTitle      = $_.jobTitle
                    companyName   = $_.companyName
                    employeeId    = $_.employeeId
                }
                # Identities also get custom attributes in extendedAttributes
                if ($CustomUserAttributes.Count -gt 0) {
                    $ext = @{}
                    foreach ($a in $CustomUserAttributes) {
                        $v = Get-UserAttrValue -User $_ -AttrName $a
                        if ($null -ne $v -and $v -ne '') { $ext[$a] = $v }
                    }
                    if ($ext.Count -gt 0) { $idRec['extendedAttributes'] = $ext }
                }
                $idRec
            })

            Send-IngestBatch -Endpoint 'ingest/identities' -SystemId $systemId -SyncMode 'full' -Records $idRecords

            # Link identities to principals
            $idMembers = @($identityUsers | ForEach-Object {
                @{
                    identityId  = $_.id
                    principalId = $_.id
                }
            })
            Send-IngestBatch -Endpoint 'ingest/identity-members' -SystemId $systemId -SyncMode 'full' -Records $idMembers
        }
    }
}

# ─── Sync Resources (Groups) ─────────────────────────────────────
if ($SyncResources) {
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing resources (groups)..." -ForegroundColor Cyan
    $coreGroupAttrs = @('id','displayName','description','mail','visibility','createdDateTime','groupTypes','securityEnabled','mailEnabled')
    $allGroupAttrs = $coreGroupAttrs + $CustomGroupAttributes | Select-Object -Unique
    $groupSelect = $allGroupAttrs -join ','
    $groups = Invoke-FGGetRequest -URI "https://graph.microsoft.com/beta/groups?`$select=$groupSelect&`$top=999"

    $records = @($groups | ForEach-Object {
        $ext = @{
            groupTypes      = ($_.groupTypes -join ',')
            securityEnabled = $_.securityEnabled
            mailEnabled     = $_.mailEnabled
        }
        foreach ($attr in $CustomGroupAttributes) {
            if ($_.$attr -ne $null) { $ext[$attr] = $_.$attr }
        }
        @{
            id              = $_.id
            displayName     = $_.displayName
            description     = $_.description
            resourceType    = 'EntraGroup'
            mail            = $_.mail
            visibility      = $_.visibility
            enabled         = $true
            createdDateTime = $_.createdDateTime
            extendedAttributes = $ext
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
        $members = Invoke-FGGetRequest -URI "https://graph.microsoft.com/beta/groups/$($group.id)/members?`$select=id&`$top=999"
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

# ─── Sync PIM (Eligible group memberships) ───────────────────────
# Privileged Identity Management gives users "Eligible" (not active) membership
# in groups. Each group must be queried individually because the Graph API
# requires a groupId filter on /privilegedAccess/group/eligibilitySchedules.
if ($SyncPim) {
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing PIM eligible memberships..." -ForegroundColor Cyan
    try {
        # Filter out dynamic groups (cannot be PIM-enabled)
        $candidateGroups = $groups | Where-Object { $_.groupTypes -notcontains 'DynamicMembership' }
        $totalGroups = $candidateGroups.Count
        Write-Host "  Checking $totalGroups groups for PIM eligibility..." -ForegroundColor Gray

        $pimRecords = @()
        $pimGroupCount = 0
        $checked = 0
        foreach ($group in $candidateGroups) {
            $checked++
            try {
                $eligibles = Invoke-FGGetRequest -URI "https://graph.microsoft.com/beta/identityGovernance/privilegedAccess/group/eligibilitySchedules?`$filter=groupId eq '$($group.id)'"
                if ($eligibles -and $eligibles.Count -gt 0) {
                    $pimGroupCount++
                    foreach ($e in $eligibles) {
                        $pimRecords += @{
                            resourceId         = $e.groupId
                            principalId        = $e.principalId
                            principalType      = 'User'
                            assignmentType     = 'Eligible'
                            state              = $e.status
                            expirationDateTime = $e.scheduleInfo.expiration.endDateTime
                        }
                    }
                }
            } catch {
                # Most groups are not PIM-enabled — silently skip on error
            }
        }

        Write-Host "  Found $pimGroupCount PIM-enabled group(s) with $($pimRecords.Count) eligible memberships" -ForegroundColor Gray

        if ($pimRecords.Count -gt 0) {
            # Dedup by (resourceId, principalId)
            $seen = @{}
            $pimRecords = @($pimRecords | Where-Object {
                $k = "$($_.resourceId)|$($_.principalId)"
                if ($seen.ContainsKey($k)) { $false } else { $seen[$k] = $true; $true }
            })
            Send-IngestBatch -Endpoint 'ingest/resource-assignments' -SystemId $systemId -SyncMode 'full' `
                -Scope @{ assignmentType = 'Eligible' } -Records $pimRecords
        }
    } catch {
        Write-Host "  PIM sync failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ─── Sync Governance ─────────────────────────────────────────────
if ($SyncGovernance) {
    try {
        Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing governance (catalogs)..." -ForegroundColor Cyan
        $catalogs = Invoke-FGGetRequest -URI "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackageCatalogs?`$top=999"

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

        # ── Access Package Resource Role Scopes (which groups each AP grants) ─
        # Each AP has resourceRoleScopes that describe the groups/resources it
        # contains. Without these, the matrix view can't show the AP coloring on
        # user→group cells, because vw_UserPermissionAssignmentViaBusinessRole
        # joins via ResourceRelationships(relationshipType='Contains').
        Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing governance (access package resource scopes)..." -ForegroundColor Cyan
        try {
            $relRecords = @()
            foreach ($ap in $accessPackages) {
                try {
                    $apDetail = Invoke-FGGetRequest -URI "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackages/$($ap.id)?`$expand=accessPackageResourceRoleScopes(`$expand=accessPackageResourceRole,accessPackageResourceScope)"
                    foreach ($rrs in @($apDetail.accessPackageResourceRoleScopes)) {
                        $scope = $rrs.accessPackageResourceScope
                        $role = $rrs.accessPackageResourceRole
                        if (-not $scope -or -not $scope.originId) { continue }
                        $relRecords += @{
                            parentResourceId = $ap.id
                            childResourceId  = $scope.originId
                            relationshipType = 'Contains'
                            roleName         = if ($role) { $role.displayName } else { 'Member' }
                            roleOriginSystem = if ($role) { $role.originSystem } else { 'AadGroup' }
                        }
                    }
                } catch {
                    Write-Host "  Skipping AP $($ap.displayName): $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }

            if ($relRecords.Count -gt 0) {
                # Dedupe (parent + child) — Graph can return duplicates if AP has multiple roles on same group
                $seen = @{}
                $relRecords = @($relRecords | Where-Object {
                    $k = "$($_.parentResourceId)|$($_.childResourceId)"
                    if ($seen.ContainsKey($k)) { $false } else { $seen[$k] = $true; $true }
                })
                Send-IngestBatch -Endpoint 'ingest/resource-relationships' -SystemId $systemId -SyncMode 'full' `
                    -Scope @{ relationshipType = 'Contains' } -Records $relRecords
            } else {
                Write-Host "  No access package resource scopes found" -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "  Resource scope sync failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }

        # ── Access Package Assignments (Governed) ────────────────────
        # Each assignment links a user (target) to an access package
        Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing governance (access package assignments)..." -ForegroundColor Cyan
        try {
            $assignments = Invoke-FGGetRequest -URI "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackageAssignments?`$expand=target,accessPackage&`$top=999"

            # Deduplicate by (resourceId, principalId) — keep the most recent active assignment.
            # Graph can return multiple assignments per user/AP (delivered, expired, removed, etc.)
            $seenKeys = @{}
            $assignRecords = @()
            foreach ($a in $assignments) {
                $apId = if ($a.accessPackage) { $a.accessPackage.id } else { $null }
                $targetId = if ($a.target) { $a.target.objectId } else { $null }
                if (-not $apId -or -not $targetId) { continue }

                $state = $a.assignmentState
                # Skip non-active states (Expired, Removed, Denied)
                if ($state -and $state -notin @('Delivered','PendingApproval','Active')) { continue }

                $key = "$apId|$targetId"
                if ($seenKeys.ContainsKey($key)) { continue }
                $seenKeys[$key] = $true

                $assignRecords += @{
                    resourceId         = $apId
                    principalId        = $targetId
                    principalType      = 'User'
                    assignmentType     = 'Governed'
                    state              = $state
                    assignmentStatus   = $a.assignmentStatus
                    expirationDateTime = $a.expiredDateTime
                }
            }

            if ($assignRecords.Count -gt 0) {
                Send-IngestBatch -Endpoint 'ingest/resource-assignments' -SystemId $systemId -SyncMode 'full' `
                    -Scope @{ assignmentType = 'Governed' } -Records $assignRecords
            } else {
                Write-Host "  No active access package assignments found" -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "  Access Package assignments sync failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "  Governance sync skipped: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  This tenant may not have Entitlement Management (Access Packages) enabled." -ForegroundColor Yellow
    }
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
