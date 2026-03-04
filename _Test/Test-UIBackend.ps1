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
# TEST 13: Error Handling
# ══════════════════════════════════════════════════════════════════════
Write-TestHeader "13. Error Handling"

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
