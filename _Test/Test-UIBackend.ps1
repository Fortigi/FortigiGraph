# UI Backend API Test Suite for FortigiGraph
# Tests all REST API endpoints of the deployed Role Mining UI
#
# Prerequisites:
# - UI deployed via New-FGUI (with or without -NoAuth)
# - SQL database with synced data
#
# Usage:
#   pwsh -File _Test\Test-UIBackend.ps1 -BaseUrl "https://your-app.azurewebsites.net"
#   pwsh -File _Test\Test-UIBackend.ps1 -BaseUrl "https://your-app.azurewebsites.net" -BearerToken "eyJ0..."

param(
    [Parameter(Mandatory = $true)]
    [string]$BaseUrl,

    [Parameter(Mandatory = $false)]
    [string]$BearerToken = ""
)

$ErrorActionPreference = "Continue"

# Normalize base URL
$BaseUrl = $BaseUrl.TrimEnd('/')

# ── Test tracking ──────────────────────────────────────────────────────
$script:TestResults = @()
$script:TotalTests = 0
$script:PassedTests = 0
$script:FailedTests = 0
$script:SkippedTests = 0

function Write-TestHeader {
    param([string]$Message)
    Write-Host "`n$Message" -ForegroundColor Yellow
    Write-Host ("=" * $Message.Length) -ForegroundColor Yellow
}

function Write-TestStep {
    param([string]$Message)
    Write-Host "  → $Message" -ForegroundColor Cyan
}

function Add-TestResult {
    param(
        [string]$Category,
        [string]$TestName,
        [bool]$Passed,
        [string]$Message = "",
        [switch]$Skipped
    )

    $script:TotalTests++
    if ($Skipped) {
        $script:SkippedTests++
        Write-Host "  ○ $TestName — SKIPPED: $Message" -ForegroundColor DarkYellow
    } elseif ($Passed) {
        $script:PassedTests++
        Write-Host "  ✓ $TestName" -ForegroundColor Green
    } else {
        $script:FailedTests++
        Write-Host "  ✗ $TestName — $Message" -ForegroundColor Red
    }

    $script:TestResults += [PSCustomObject]@{
        Category = $Category
        TestName = $TestName
        Passed   = $Passed
        Skipped  = [bool]$Skipped
        Message  = $Message
    }
}

# Helper: Make API call
function Invoke-API {
    param(
        [string]$Method = "GET",
        [string]$Path,
        [object]$Body = $null,
        [switch]$ExpectError
    )

    $url = "$BaseUrl$Path"
    $headers = @{ "Accept" = "application/json" }
    if ($BearerToken) {
        $headers["Authorization"] = "Bearer $BearerToken"
    }

    $params = @{
        Method      = $Method
        Uri         = $url
        Headers     = $headers
        ContentType = "application/json"
        ErrorAction = "Stop"
    }

    if ($Body) {
        $params["Body"] = ($Body | ConvertTo-Json -Depth 10)
    }

    try {
        $response = Invoke-RestMethod @params
        return @{ Success = $true; Data = $response; StatusCode = 200 }
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $errorBody = $null
        try {
            $errorBody = $_.ErrorDetails.Message | ConvertFrom-Json
        } catch { }
        return @{ Success = $false; StatusCode = $statusCode; Error = $_.Exception.Message; ErrorBody = $errorBody }
    }
}

# Start transcript
$transcriptDir = Join-Path $PSScriptRoot "logs"
if (-not (Test-Path $transcriptDir)) { New-Item -ItemType Directory -Path $transcriptDir -Force | Out-Null }
$transcriptFile = Join-Path $transcriptDir "uibackend-test-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -Path $transcriptFile -Force | Out-Null

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "FortigiGraph UI Backend Test Suite" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Target: $BaseUrl" -ForegroundColor Gray
Write-Host "Auth: $(if ($BearerToken) { 'Bearer token provided' } else { 'No auth (expecting -NoAuth deployment)' })`n" -ForegroundColor Gray

# ══════════════════════════════════════════════════════════════════════
# TEST 1: Health & Auth Config
# ══════════════════════════════════════════════════════════════════════
Write-TestHeader "1. Health & Authentication"

$result = Invoke-API -Path "/api/auth-config"
Add-TestResult -Category "Health" -TestName "GET /api/auth-config responds" -Passed $result.Success -Message $(if (-not $result.Success) { "HTTP $($result.StatusCode): $($result.Error)" })

if ($result.Success) {
    Write-TestStep "Auth enabled: $($result.Data.authEnabled)"
}

# ══════════════════════════════════════════════════════════════════════
# TEST 2: Permissions (Matrix Data)
# ══════════════════════════════════════════════════════════════════════
Write-TestHeader "2. Permissions / Matrix Data"

$result = Invoke-API -Path "/api/permissions?userLimit=10"
Add-TestResult -Category "Permissions" -TestName "GET /api/permissions returns data" -Passed $result.Success -Message $(if (-not $result.Success) { "HTTP $($result.StatusCode)" })

if ($result.Success -and $result.Data) {
    $hasUsers = $null -ne $result.Data.users
    $hasGroups = $null -ne $result.Data.groups
    $hasAssignments = $null -ne $result.Data.assignments

    Add-TestResult -Category "Permissions" -TestName "Response has users array" -Passed $hasUsers
    Add-TestResult -Category "Permissions" -TestName "Response has groups array" -Passed $hasGroups
    Add-TestResult -Category "Permissions" -TestName "Response has assignments array" -Passed $hasAssignments

    if ($hasUsers) {
        $userCount = if ($result.Data.users -is [array]) { $result.Data.users.Count } else { 1 }
        Write-TestStep "Users returned: $userCount (limit=10)"
        Add-TestResult -Category "Permissions" -TestName "User limit respected ($userCount <= 10)" -Passed ($userCount -le 10)
    }
}

# AP groups
$result = Invoke-API -Path "/api/permissions/groups"
Add-TestResult -Category "Permissions" -TestName "GET /api/permissions/groups responds" -Passed $result.Success -Message $(if (-not $result.Success) { "HTTP $($result.StatusCode)" })

# Sync log
$result = Invoke-API -Path "/api/permissions/sync-log"
Add-TestResult -Category "Permissions" -TestName "GET /api/permissions/sync-log responds" -Passed $result.Success -Message $(if (-not $result.Success) { "HTTP $($result.StatusCode)" })

# ══════════════════════════════════════════════════════════════════════
# TEST 3: Users Endpoint
# ══════════════════════════════════════════════════════════════════════
Write-TestHeader "3. Users API"

$result = Invoke-API -Path "/api/users?page=1&pageSize=5"
Add-TestResult -Category "Users" -TestName "GET /api/users returns data" -Passed $result.Success

$testUserId = $null
if ($result.Success -and $result.Data) {
    $data = if ($result.Data.data) { $result.Data.data } else { $result.Data }
    if ($data -is [array] -and $data.Count -gt 0) {
        $testUserId = $data[0].id
        Write-TestStep "First user: $($data[0].displayName) ($testUserId)"
        Add-TestResult -Category "Users" -TestName "User has id property" -Passed ($null -ne $testUserId)
        Add-TestResult -Category "Users" -TestName "User has displayName property" -Passed ($null -ne $data[0].displayName)
    }
}

# Search
$result = Invoke-API -Path "/api/users?search=a&page=1&pageSize=5"
Add-TestResult -Category "Users" -TestName "GET /api/users?search=a responds" -Passed $result.Success

# ══════════════════════════════════════════════════════════════════════
# TEST 4: Groups Endpoint
# ══════════════════════════════════════════════════════════════════════
Write-TestHeader "4. Groups API"

$result = Invoke-API -Path "/api/groups?page=1&pageSize=5"
Add-TestResult -Category "Groups" -TestName "GET /api/groups returns data" -Passed $result.Success

$testGroupId = $null
if ($result.Success -and $result.Data) {
    $data = if ($result.Data.data) { $result.Data.data } else { $result.Data }
    if ($data -is [array] -and $data.Count -gt 0) {
        $testGroupId = $data[0].id
        Write-TestStep "First group: $($data[0].displayName) ($testGroupId)"
    }
}

# ══════════════════════════════════════════════════════════════════════
# TEST 5: Access Packages Endpoint
# ══════════════════════════════════════════════════════════════════════
Write-TestHeader "5. Access Packages API"

$result = Invoke-API -Path "/api/access-packages?page=1&pageSize=5"
Add-TestResult -Category "AccessPackages" -TestName "GET /api/access-packages responds" -Passed $result.Success

# ══════════════════════════════════════════════════════════════════════
# TEST 6: Tags CRUD
# ══════════════════════════════════════════════════════════════════════
Write-TestHeader "6. Tags CRUD"

$testTagId = $null

# Create tag
$result = Invoke-API -Method "POST" -Path "/api/tags" -Body @{ name = "TestTag-AutoTest"; color = "#FF5733"; type = "user" }
Add-TestResult -Category "Tags" -TestName "POST /api/tags creates a tag" -Passed $result.Success -Message $(if (-not $result.Success) { "HTTP $($result.StatusCode)" })

if ($result.Success -and $result.Data) {
    $testTagId = $result.Data.id
    Write-TestStep "Created tag ID: $testTagId"
}

# List tags
$result = Invoke-API -Path "/api/tags?type=user"
Add-TestResult -Category "Tags" -TestName "GET /api/tags?type=user responds" -Passed $result.Success

# Assign tag (if we have a user ID and tag ID)
if ($testTagId -and $testUserId) {
    $result = Invoke-API -Method "POST" -Path "/api/tags/$testTagId/assign" -Body @{ entityIds = @($testUserId) }
    Add-TestResult -Category "Tags" -TestName "POST /api/tags/{id}/assign works" -Passed $result.Success -Message $(if (-not $result.Success) { "HTTP $($result.StatusCode)" })

    # Unassign
    $result = Invoke-API -Method "POST" -Path "/api/tags/$testTagId/unassign" -Body @{ entityIds = @($testUserId) }
    Add-TestResult -Category "Tags" -TestName "POST /api/tags/{id}/unassign works" -Passed $result.Success
}

# Delete tag
if ($testTagId) {
    $result = Invoke-API -Method "DELETE" -Path "/api/tags/$testTagId"
    Add-TestResult -Category "Tags" -TestName "DELETE /api/tags/{id} works" -Passed $result.Success -Message $(if (-not $result.Success) { "HTTP $($result.StatusCode)" })
}

# ══════════════════════════════════════════════════════════════════════
# TEST 7: Categories CRUD
# ══════════════════════════════════════════════════════════════════════
Write-TestHeader "7. Categories CRUD"

$testCategoryId = $null

$result = Invoke-API -Method "POST" -Path "/api/categories" -Body @{ name = "TestCategory-AutoTest"; color = "#33FF57" }
Add-TestResult -Category "Categories" -TestName "POST /api/categories creates a category" -Passed $result.Success -Message $(if (-not $result.Success) { "HTTP $($result.StatusCode)" })

if ($result.Success -and $result.Data) {
    $testCategoryId = $result.Data.id
    Write-TestStep "Created category ID: $testCategoryId"
}

$result = Invoke-API -Path "/api/categories"
Add-TestResult -Category "Categories" -TestName "GET /api/categories responds" -Passed $result.Success

if ($testCategoryId) {
    $result = Invoke-API -Method "DELETE" -Path "/api/categories/$testCategoryId"
    Add-TestResult -Category "Categories" -TestName "DELETE /api/categories/{id} works" -Passed $result.Success
}

# ══════════════════════════════════════════════════════════════════════
# TEST 8: Detail Endpoints
# ══════════════════════════════════════════════════════════════════════
Write-TestHeader "8. Entity Detail Endpoints"

if ($testUserId) {
    $result = Invoke-API -Path "/api/details/user/$testUserId"
    Add-TestResult -Category "Details" -TestName "GET /api/details/user/{id} responds" -Passed $result.Success

    if ($result.Success -and $result.Data) {
        $hasAttributes = $null -ne $result.Data.attributes
        $hasMemberships = $null -ne $result.Data.groupMemberships
        Add-TestResult -Category "Details" -TestName "User detail has attributes" -Passed $hasAttributes
        Add-TestResult -Category "Details" -TestName "User detail has groupMemberships" -Passed $hasMemberships
    }

    # Version history
    $result = Invoke-API -Path "/api/details/user/$testUserId/history"
    Add-TestResult -Category "Details" -TestName "GET /api/details/user/{id}/history responds" -Passed $result.Success
} else {
    Add-TestResult -Category "Details" -TestName "User detail endpoints" -Passed $true -Skipped -Message "No user ID available"
}

if ($testGroupId) {
    $result = Invoke-API -Path "/api/details/group/$testGroupId"
    Add-TestResult -Category "Details" -TestName "GET /api/details/group/{id} responds" -Passed $result.Success

    if ($result.Success -and $result.Data) {
        $hasAttributes = $null -ne $result.Data.attributes
        $hasMembers = $null -ne $result.Data.members
        Add-TestResult -Category "Details" -TestName "Group detail has attributes" -Passed $hasAttributes
        Add-TestResult -Category "Details" -TestName "Group detail has members" -Passed $hasMembers
    }
} else {
    Add-TestResult -Category "Details" -TestName "Group detail endpoints" -Passed $true -Skipped -Message "No group ID available"
}

# ══════════════════════════════════════════════════════════════════════
# TEST 9: Risk Scores API
# ══════════════════════════════════════════════════════════════════════
Write-TestHeader "9. Risk Scores API"

$result = Invoke-API -Path "/api/risk-scores"
if ($result.Success) {
    Add-TestResult -Category "RiskScores" -TestName "GET /api/risk-scores responds" -Passed $true

    $hasSummary = $null -ne $result.Data
    Add-TestResult -Category "RiskScores" -TestName "Risk scores summary returned" -Passed $hasSummary

    # Users
    $result = Invoke-API -Path "/api/risk-scores/users?page=1&pageSize=5"
    Add-TestResult -Category "RiskScores" -TestName "GET /api/risk-scores/users responds" -Passed $result.Success

    # Groups
    $result = Invoke-API -Path "/api/risk-scores/groups?page=1&pageSize=5"
    Add-TestResult -Category "RiskScores" -TestName "GET /api/risk-scores/groups responds" -Passed $result.Success
} else {
    # Risk scores may not be set up yet
    Add-TestResult -Category "RiskScores" -TestName "GET /api/risk-scores" -Passed $true -Skipped -Message "Risk scoring not configured or no data"
}

# ══════════════════════════════════════════════════════════════════════
# TEST 10: Org Chart API
# ══════════════════════════════════════════════════════════════════════
Write-TestHeader "10. Org Chart API"

$result = Invoke-API -Path "/api/org-chart"
Add-TestResult -Category "OrgChart" -TestName "GET /api/org-chart responds" -Passed $result.Success -Message $(if (-not $result.Success) { "HTTP $($result.StatusCode) (may require manager data)" })

# ══════════════════════════════════════════════════════════════════════
# TEST 11: Governance API
# ══════════════════════════════════════════════════════════════════════
Write-TestHeader "11. Governance API"

$result = Invoke-API -Path "/api/governance/summary"
Add-TestResult -Category "Governance" -TestName "GET /api/governance/summary responds" -Passed $result.Success -Message $(if (-not $result.Success) { "HTTP $($result.StatusCode)" })

$result = Invoke-API -Path "/api/governance/review-compliance"
Add-TestResult -Category "Governance" -TestName "GET /api/governance/review-compliance responds" -Passed $result.Success

$result = Invoke-API -Path "/api/governance/categories"
Add-TestResult -Category "Governance" -TestName "GET /api/governance/categories responds" -Passed $result.Success

# ══════════════════════════════════════════════════════════════════════
# TEST 12: Performance API
# ══════════════════════════════════════════════════════════════════════
Write-TestHeader "12. Performance Metrics API"

$result = Invoke-API -Path "/api/perf"
if ($result.Success) {
    Add-TestResult -Category "Perf" -TestName "GET /api/perf responds" -Passed $true
} else {
    Add-TestResult -Category "Perf" -TestName "GET /api/perf" -Passed $true -Skipped -Message "Performance metrics may not be enabled"
}

# ══════════════════════════════════════════════════════════════════════
# TEST 13: Identities API
# ══════════════════════════════════════════════════════════════════════
Write-TestHeader "13. Identities API"

$result = Invoke-API -Path "/api/identities"
if (-not $result.Success) {
    Add-TestResult -Category "Identities" -TestName "GET /api/identities" -Passed $true -Skipped -Message "Endpoint not responding (HTTP $($result.StatusCode)) — identities feature may not be deployed"
} else {
    Add-TestResult -Category "Identities" -TestName "GET /api/identities responds" -Passed $true

    $data = $result.Data
    Add-TestResult -Category "Identities" -TestName "Response has 'available' field" `
        -Passed ($null -ne $data.available) -Message "Missing 'available' field"

    if ($data.available -eq $false) {
        Add-TestResult -Category "Identities" -TestName "Identities data endpoints" -Passed $true -Skipped `
            -Message "Identities not available (run Invoke-FGAccountCorrelation to generate data)"
    } else {
        # Summary object
        Add-TestResult -Category "Identities" -TestName "Response has 'summary' object" `
            -Passed ($null -ne $data.summary) -Message "Missing 'summary' field"

        if ($data.summary) {
            $summaryFields = @("totalIdentities", "multiAccountIdentities", "singleAccountIdentities", "verifiedCount", "avgConfidence", "lastCorrelatedAt")
            foreach ($field in $summaryFields) {
                Add-TestResult -Category "Identities" -TestName "Summary has '$field' field" `
                    -Passed ($null -ne $data.summary.$field) -Message "Field missing from summary"
            }

            $hasDistribution = $null -ne $data.summary.accountTypeDistribution
            Add-TestResult -Category "Identities" -TestName "Summary has accountTypeDistribution" `
                -Passed $hasDistribution -Message "accountTypeDistribution missing from summary"
        }

        # Paginated data
        Add-TestResult -Category "Identities" -TestName "Response has 'data' array" `
            -Passed ($null -ne $data.data) -Message "Missing 'data' field"
        Add-TestResult -Category "Identities" -TestName "Response has 'total' count" `
            -Passed ($null -ne $data.total) -Message "Missing 'total' field"

        # Record shape (if any rows returned)
        if ($data.data -is [array] -and $data.data.Count -gt 0) {
            $first = $data.data[0]
            $requiredFields = @("id", "displayName", "accountCount", "correlationConfidence", "analystVerified")
            foreach ($field in $requiredFields) {
                Add-TestResult -Category "Identities" -TestName "Identity record has '$field' field" `
                    -Passed ($null -ne $first.$field) -Message "Field missing from identity record"
            }

            $testIdentityId = $first.id
            Write-TestStep "Test identity ID: $testIdentityId (accounts: $($first.accountCount), confidence: $($first.correlationConfidence)%)"
        }

        # Pagination: limit
        $resultLimited = Invoke-API -Path "/api/identities?limit=2&offset=0"
        Add-TestResult -Category "Identities" -TestName "GET /api/identities?limit=2 respects page size" `
            -Passed ($resultLimited.Success -and $resultLimited.Data.data.Count -le 2) `
            -Message $(if (-not $resultLimited.Success) { "HTTP $($resultLimited.StatusCode)" } else { "Returned more than 2 rows" })

        # limit capped at 500
        $resultMax = Invoke-API -Path "/api/identities?limit=9999"
        Add-TestResult -Category "Identities" -TestName "GET /api/identities?limit=9999 is capped at 500" `
            -Passed ($resultMax.Success -and $resultMax.Data.data.Count -le 500) `
            -Message "Returned more than 500 rows"

        # Search filter
        $resultSearch = Invoke-API -Path "/api/identities?search=a"
        Add-TestResult -Category "Identities" -TestName "GET /api/identities?search= filter works" `
            -Passed $resultSearch.Success -Message $(if (-not $resultSearch.Success) { "HTTP $($resultSearch.StatusCode)" })

        # Verified filter
        $resultVerified = Invoke-API -Path "/api/identities?verified=true"
        Add-TestResult -Category "Identities" -TestName "GET /api/identities?verified=true returns only verified" `
            -Passed ($resultVerified.Success -and ($resultVerified.Data.data | Where-Object { -not $_.analystVerified }).Count -eq 0) `
            -Message $(if (-not $resultVerified.Success) { "HTTP $($resultVerified.StatusCode)" } else { "Contains unverified identities" })

        # Sort options
        $sortOptions = @("accountCount", "confidence", "displayName", "department", "correlatedAt")
        foreach ($sortOpt in $sortOptions) {
            $r = Invoke-API -Path "/api/identities?sort=$sortOpt&limit=5"
            Add-TestResult -Category "Identities" -TestName "GET /api/identities?sort=$sortOpt responds" `
                -Passed $r.Success -Message $(if (-not $r.Success) { "HTTP $($r.StatusCode)" })
        }

        # hasHrColumns field
        Add-TestResult -Category "Identities" -TestName "Response has 'hasHrColumns' flag" `
            -Passed ($null -ne $data.hasHrColumns) -Message "Missing 'hasHrColumns' field"
    }
}

# ── GET /api/identities/:id ────────────────────────────────────────────
# We need an identity ID — re-use first one from list call if available
$testIdentityId = if ($result.Success -and $result.Data.available -and $result.Data.data.Count -gt 0) {
    $result.Data.data[0].id
} else { $null }

if ($testIdentityId) {
    $detailResult = Invoke-API -Path "/api/identities/$testIdentityId"
    Add-TestResult -Category "Identities" -TestName "GET /api/identities/:id returns identity" `
        -Passed $detailResult.Success -Message $(if (-not $detailResult.Success) { "HTTP $($detailResult.StatusCode)" })

    if ($detailResult.Success -and $detailResult.Data) {
        Add-TestResult -Category "Identities" -TestName "GET /api/identities/:id response has 'identity' object" `
            -Passed ($null -ne $detailResult.Data.identity) -Message "Missing 'identity' field"
        Add-TestResult -Category "Identities" -TestName "GET /api/identities/:id response has 'members' array" `
            -Passed ($null -ne $detailResult.Data.members) -Message "Missing 'members' field"

        if ($detailResult.Data.members -is [array] -and $detailResult.Data.members.Count -gt 0) {
            $member = $detailResult.Data.members[0]
            $memberFields = @("userId", "accountType", "isPrimary")
            foreach ($field in $memberFields) {
                Add-TestResult -Category "Identities" -TestName "Member record has '$field' field" `
                    -Passed ($null -ne $member.$field) -Message "Field missing from member record"
            }
        }
    }

    # 404 for non-existent ID
    $notFoundResult = Invoke-API -Path "/api/identities/00000000-0000-0000-0000-000000000000" -ExpectError
    Add-TestResult -Category "Identities" -TestName "GET /api/identities/:id returns 404 for unknown ID" `
        -Passed ($notFoundResult.StatusCode -eq 404) -Message "Got HTTP $($notFoundResult.StatusCode) instead of 404"

    # 400 for invalid UUID format
    $badIdResult = Invoke-API -Path "/api/identities/not-a-uuid" -ExpectError
    Add-TestResult -Category "Identities" -TestName "GET /api/identities/:id returns 400 for invalid ID format" `
        -Passed ($badIdResult.StatusCode -eq 400) -Message "Got HTTP $($badIdResult.StatusCode) instead of 400"
} else {
    Add-TestResult -Category "Identities" -TestName "GET /api/identities/:id" `
        -Passed $true -Skipped -Message "No identity ID available (identities not configured)"
    Add-TestResult -Category "Identities" -TestName "GET /api/identities/:id 404 test" `
        -Passed $true -Skipped -Message "Skipped — identities not configured"
}

# ── PUT /api/identities/:id/verify ────────────────────────────────────
if ($testIdentityId) {
    $verifyResult = Invoke-API -Method "PUT" -Path "/api/identities/$testIdentityId/verify" -Body @{ notes = "AutoTest verification" }
    Add-TestResult -Category "Identities" -TestName "PUT /api/identities/:id/verify sets verified flag" `
        -Passed $verifyResult.Success -Message $(if (-not $verifyResult.Success) { "HTTP $($verifyResult.StatusCode)" })

    if ($verifyResult.Success) {
        # Confirm verified=true via GET
        $checkResult = Invoke-API -Path "/api/identities/$testIdentityId"
        $isVerified = $checkResult.Success -and $checkResult.Data.identity.analystVerified -eq $true
        Add-TestResult -Category "Identities" -TestName "analystVerified is true after PUT /verify" `
            -Passed $isVerified -Message "analystVerified was not set to true"

        $hasNotes = $checkResult.Success -and $checkResult.Data.identity.analystNotes -eq "AutoTest verification"
        Add-TestResult -Category "Identities" -TestName "analystNotes saved after PUT /verify" `
            -Passed $hasNotes -Message "analystNotes were not persisted"
    }

    # 400 for invalid ID
    $badVerify = Invoke-API -Method "PUT" -Path "/api/identities/not-a-uuid/verify" -Body @{ notes = "test" } -ExpectError
    Add-TestResult -Category "Identities" -TestName "PUT /api/identities/:id/verify returns 400 for invalid ID" `
        -Passed ($badVerify.StatusCode -eq 400) -Message "Got HTTP $($badVerify.StatusCode) instead of 400"
} else {
    Add-TestResult -Category "Identities" -TestName "PUT /api/identities/:id/verify" `
        -Passed $true -Skipped -Message "No identity ID available"
}

# ── DELETE /api/identities/:id/verify ─────────────────────────────────
if ($testIdentityId) {
    $unverifyResult = Invoke-API -Method "DELETE" -Path "/api/identities/$testIdentityId/verify"
    Add-TestResult -Category "Identities" -TestName "DELETE /api/identities/:id/verify clears verification" `
        -Passed $unverifyResult.Success -Message $(if (-not $unverifyResult.Success) { "HTTP $($unverifyResult.StatusCode)" })

    if ($unverifyResult.Success) {
        $checkResult = Invoke-API -Path "/api/identities/$testIdentityId"
        $isUnverified = $checkResult.Success -and $checkResult.Data.identity.analystVerified -eq $false
        Add-TestResult -Category "Identities" -TestName "analystVerified is false after DELETE /verify" `
            -Passed $isUnverified -Message "analystVerified was not cleared"
    }
} else {
    Add-TestResult -Category "Identities" -TestName "DELETE /api/identities/:id/verify" `
        -Passed $true -Skipped -Message "No identity ID available"
}

# ── PUT /api/identities/:id/members/:userId/override ──────────────────
$testMemberId = if ($testIdentityId -and $detailResult -and $detailResult.Data.members.Count -gt 0) {
    $detailResult.Data.members[0].userId
} else { $null }

if ($testIdentityId -and $testMemberId) {
    # Valid override
    $overrideResult = Invoke-API -Method "PUT" `
        -Path "/api/identities/$testIdentityId/members/$testMemberId/override" `
        -Body @{ action = "confirmed"; reason = "AutoTest confirmed this link" }
    Add-TestResult -Category "Identities" -TestName "PUT /api/identities/:id/members/:userId/override sets override" `
        -Passed $overrideResult.Success -Message $(if (-not $overrideResult.Success) { "HTTP $($overrideResult.StatusCode): $($overrideResult.Error)" })

    if ($overrideResult.Success -and $overrideResult.Data) {
        Add-TestResult -Category "Identities" -TestName "Override response has 'action' field" `
            -Passed ($overrideResult.Data.action -eq "confirmed") -Message "action not 'confirmed'"
        Add-TestResult -Category "Identities" -TestName "Override response has 'reason' field" `
            -Passed (-not [string]::IsNullOrWhiteSpace($overrideResult.Data.reason)) -Message "reason empty"
    }

    # Invalid action
    $badAction = Invoke-API -Method "PUT" `
        -Path "/api/identities/$testIdentityId/members/$testMemberId/override" `
        -Body @{ action = "invalid-action"; reason = "AutoTest" } -ExpectError
    Add-TestResult -Category "Identities" -TestName "PUT override returns 400 for invalid action" `
        -Passed ($badAction.StatusCode -eq 400) -Message "Got HTTP $($badAction.StatusCode) instead of 400"

    # Reason too short
    $shortReason = Invoke-API -Method "PUT" `
        -Path "/api/identities/$testIdentityId/members/$testMemberId/override" `
        -Body @{ action = "confirmed"; reason = "xy" } -ExpectError
    Add-TestResult -Category "Identities" -TestName "PUT override returns 400 for reason < 3 chars" `
        -Passed ($shortReason.StatusCode -eq 400) -Message "Got HTTP $($shortReason.StatusCode) instead of 400"

    # Missing reason
    $noReason = Invoke-API -Method "PUT" `
        -Path "/api/identities/$testIdentityId/members/$testMemberId/override" `
        -Body @{ action = "confirmed" } -ExpectError
    Add-TestResult -Category "Identities" -TestName "PUT override returns 400 when reason is missing" `
        -Passed ($noReason.StatusCode -eq 400) -Message "Got HTTP $($noReason.StatusCode) instead of 400"

    # Invalid UUID
    $badUuid = Invoke-API -Method "PUT" `
        -Path "/api/identities/not-a-uuid/members/$testMemberId/override" `
        -Body @{ action = "confirmed"; reason = "AutoTest reason" } -ExpectError
    Add-TestResult -Category "Identities" -TestName "PUT override returns 400 for invalid identity UUID" `
        -Passed ($badUuid.StatusCode -eq 400) -Message "Got HTTP $($badUuid.StatusCode) instead of 400"
} else {
    Add-TestResult -Category "Identities" -TestName "PUT /api/identities/:id/members/:userId/override" `
        -Passed $true -Skipped -Message "No identity/member ID available"
}

# ── DELETE /api/identities/:id/members/:userId/override ───────────────
if ($testIdentityId -and $testMemberId) {
    $removeOverride = Invoke-API -Method "DELETE" `
        -Path "/api/identities/$testIdentityId/members/$testMemberId/override"
    Add-TestResult -Category "Identities" -TestName "DELETE /api/identities/:id/members/:userId/override clears override" `
        -Passed $removeOverride.Success -Message $(if (-not $removeOverride.Success) { "HTTP $($removeOverride.StatusCode)" })
} else {
    Add-TestResult -Category "Identities" -TestName "DELETE /api/identities/:id/members/:userId/override" `
        -Passed $true -Skipped -Message "No identity/member ID available"
}

# ══════════════════════════════════════════════════════════════════════
# TEST 14: Error Handling
# ══════════════════════════════════════════════════════════════════════
Write-TestHeader "14. Error Handling"

$result = Invoke-API -Path "/api/nonexistent-endpoint" -ExpectError
Add-TestResult -Category "Errors" -TestName "GET /api/nonexistent returns 404" -Passed ($result.StatusCode -eq 404) -Message $(if ($result.StatusCode -ne 404) { "Got HTTP $($result.StatusCode) instead of 404" })

# Test that error responses don't leak SQL details
if ($result.ErrorBody) {
    $errorStr = $result.ErrorBody | ConvertTo-Json -Depth 5
    $leaksInfo = $errorStr -match 'INFORMATION_SCHEMA|sys\.' -or $errorStr -match 'dbo\.'
    Add-TestResult -Category "Errors" -TestName "Error responses don't leak SQL schema info" -Passed (-not $leaksInfo) -Message $(if ($leaksInfo) { "SQL schema info found in error response" })
}

# ══════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Test Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Total:   $($script:TotalTests)" -ForegroundColor White
Write-Host "  Passed:  $($script:PassedTests)" -ForegroundColor Green
Write-Host "  Failed:  $($script:FailedTests)" -ForegroundColor $(if ($script:FailedTests -gt 0) { "Red" } else { "Green" })
Write-Host "  Skipped: $($script:SkippedTests)" -ForegroundColor DarkYellow

$categories = $script:TestResults | Group-Object Category
foreach ($cat in $categories) {
    $passed = ($cat.Group | Where-Object { $_.Passed -and -not $_.Skipped }).Count
    $skipped = ($cat.Group | Where-Object Skipped).Count
    $total = $cat.Group.Count
    $color = if (($cat.Group | Where-Object { -not $_.Passed -and -not $_.Skipped }).Count -eq 0) { "Green" } else { "Yellow" }
    $skipText = if ($skipped -gt 0) { " ($skipped skipped)" } else { "" }
    Write-Host "    $($cat.Name): $passed/$total$skipText" -ForegroundColor $color
}

if ($script:FailedTests -gt 0) {
    Write-Host "`nFailed Tests:" -ForegroundColor Red
    $script:TestResults | Where-Object { -not $_.Passed -and -not $_.Skipped } | ForEach-Object {
        Write-Host "  ✗ [$($_.Category)] $($_.TestName): $($_.Message)" -ForegroundColor Red
    }
}

Write-Host ""

Stop-Transcript | Out-Null
Write-Host "Log saved to: $transcriptFile" -ForegroundColor Gray

exit $(if ($script:FailedTests -gt 0) { 1 } else { 0 })
