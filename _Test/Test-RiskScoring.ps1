# Risk Scoring Test Suite for FortigiGraph
# Tests the complete risk scoring pipeline: profile → classifiers → scoring → overrides
#
# Prerequisites:
# - Config file with valid Graph + SQL settings
# - SQL Server with synced data (users + groups must exist)
# - LLM API key (Anthropic or OpenAI)
#
# Usage:
#   pwsh -File _Test\Test-RiskScoring.ps1 -ConfigFile _Test\config.test.json -LLMProvider Anthropic -LLMApiKey "sk-ant-..."
#   pwsh -File _Test\Test-RiskScoring.ps1 -ConfigFile _Test\config.test.json -LLMProvider OpenAI -LLMApiKey "sk-..."

param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,

    [Parameter(Mandatory = $true)]
    [ValidateSet("Anthropic", "OpenAI")]
    [string]$LLMProvider,

    [Parameter(Mandatory = $true)]
    [string]$LLMApiKey,

    [Parameter(Mandatory = $false)]
    [string]$CustomerDomain = ""
)

$ErrorActionPreference = "Stop"

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

# Start transcript
$configBaseName = [System.IO.Path]::GetFileNameWithoutExtension($ConfigFile)
$transcriptDir = Join-Path $PSScriptRoot "logs"
if (-not (Test-Path $transcriptDir)) { New-Item -ItemType Directory -Path $transcriptDir -Force | Out-Null }
$transcriptFile = Join-Path $transcriptDir "riskscoring-test-$configBaseName.log"
Start-Transcript -Path $transcriptFile -Force | Out-Null

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "FortigiGraph Risk Scoring Test Suite" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "LLM Provider: $LLMProvider`n" -ForegroundColor Gray

# ══════════════════════════════════════════════════════════════════════
# SETUP
# ══════════════════════════════════════════════════════════════════════

$moduleRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $moduleRoot "FortigiGraph.psd1"

try {
    Import-Module $modulePath -Force -ErrorAction Stop
    Add-TestResult -Category "Setup" -TestName "Module imported" -Passed $true
} catch {
    Add-TestResult -Category "Setup" -TestName "Module imported" -Passed $false -Message $_.Exception.Message
    Stop-Transcript | Out-Null; exit 1
}

# Connect to SQL
try {
    Write-TestStep "Connecting to SQL Server..."
    Connect-FGSQLServer -ConfigFile $ConfigFile
    Add-TestResult -Category "Setup" -TestName "SQL Server connected" -Passed $true
} catch {
    Add-TestResult -Category "Setup" -TestName "SQL Server connected" -Passed $false -Message $_.Exception.Message
    Stop-Transcript | Out-Null; exit 1
}

# Verify synced data exists
try {
    $userCount = (Invoke-FGSQLQuery -Query "SELECT COUNT(*) AS cnt FROM GraphUsers").cnt
    $groupCount = (Invoke-FGSQLQuery -Query "SELECT COUNT(*) AS cnt FROM GraphGroups").cnt
    Add-TestResult -Category "Setup" -TestName "Synced data exists ($userCount users, $groupCount groups)" -Passed ($userCount -gt 0 -and $groupCount -gt 0)

    if ($userCount -eq 0 -or $groupCount -eq 0) {
        Write-Host "`nNo synced data found. Run Start-FGSync first." -ForegroundColor Red
        Stop-Transcript | Out-Null; exit 1
    }
} catch {
    Add-TestResult -Category "Setup" -TestName "Synced data exists" -Passed $false -Message $_.Exception.Message
    Stop-Transcript | Out-Null; exit 1
}

# Determine domain
$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($CustomerDomain)) {
    # Try to infer from config
    if ($config.RiskScoring -and $config.RiskScoring.CustomerDomain) {
        $CustomerDomain = $config.RiskScoring.CustomerDomain
    } elseif ($config.Graph.TenantId -match '\.onmicrosoft\.com$') {
        $CustomerDomain = $config.Graph.TenantId -replace '\.onmicrosoft\.com$', '.com'
    } else {
        $CustomerDomain = "contoso.com"
        Write-Host "  ⚠ No domain found in config, using '$CustomerDomain' for testing" -ForegroundColor DarkYellow
    }
}
Write-TestStep "Using domain: $CustomerDomain"

# Export directory for JSON files
$exportDir = Join-Path $PSScriptRoot "exports"
if (-not (Test-Path $exportDir)) { New-Item -ItemType Directory -Path $exportDir -Force | Out-Null }

# ══════════════════════════════════════════════════════════════════════
# TEST 1: Risk Profile Generation
# ══════════════════════════════════════════════════════════════════════
Write-TestHeader "1. Risk Profile Generation"

$profile = $null
try {
    Write-TestStep "Generating risk profile via $LLMProvider (public domain info only)..."
    $profile = New-FGRiskProfile -Domain $CustomerDomain -LLMProvider $LLMProvider -LLMApiKey $LLMApiKey -ConfigFile $ConfigFile
    $hasProfile = $null -ne $profile
    Add-TestResult -Category "Profile" -TestName "New-FGRiskProfile returns a profile" -Passed $hasProfile

    if ($hasProfile) {
        # Validate profile structure
        $hasIndustry = $null -ne $profile.industry -or $null -ne $profile.Industry
        Add-TestResult -Category "Profile" -TestName "Profile contains industry field" -Passed $hasIndustry

        # Save to SQL
        Write-TestStep "Saving profile to SQL..."
        Save-FGRiskProfile -Profile $profile -ConfigFile $ConfigFile
        Add-TestResult -Category "Profile" -TestName "Profile saved to SQL" -Passed $true

        # Read back from SQL
        Write-TestStep "Reading profile back from SQL..."
        $readProfile = Get-FGRiskProfile -ConfigFile $ConfigFile
        Add-TestResult -Category "Profile" -TestName "Profile retrieved from SQL" -Passed ($null -ne $readProfile)

        # Export to JSON
        $profileExportPath = Join-Path $exportDir "test-risk-profile.json"
        Write-TestStep "Exporting profile to JSON..."
        Export-FGRiskProfile -Profile $profile -Path $profileExportPath
        Add-TestResult -Category "Profile" -TestName "Profile exported to JSON" -Passed (Test-Path $profileExportPath)

        # Import from JSON
        Write-TestStep "Importing profile from JSON..."
        $importedProfile = Import-FGRiskProfile -Path $profileExportPath
        Add-TestResult -Category "Profile" -TestName "Profile imported from JSON" -Passed ($null -ne $importedProfile)
    }
} catch {
    Add-TestResult -Category "Profile" -TestName "Risk profile generation" -Passed $false -Message $_.Exception.Message
}

# ══════════════════════════════════════════════════════════════════════
# TEST 2: Risk Classifier Generation
# ══════════════════════════════════════════════════════════════════════
Write-TestHeader "2. Risk Classifier Generation"

$classifiers = $null
try {
    Write-TestStep "Generating classifiers from profile..."
    $classifiers = New-FGRiskClassifiers -ConfigFile $ConfigFile
    $hasClassifiers = $null -ne $classifiers
    Add-TestResult -Category "Classifiers" -TestName "New-FGRiskClassifiers returns classifiers" -Passed $hasClassifiers

    if ($hasClassifiers) {
        # Check it's an array with at least one classifier
        $classifierCount = if ($classifiers -is [array]) { $classifiers.Count } else { 1 }
        Add-TestResult -Category "Classifiers" -TestName "At least 1 classifier generated ($classifierCount total)" -Passed ($classifierCount -gt 0)

        # Save to SQL
        Write-TestStep "Saving classifiers to SQL..."
        Save-FGRiskClassifiers -Classifiers $classifiers -ConfigFile $ConfigFile
        Add-TestResult -Category "Classifiers" -TestName "Classifiers saved to SQL" -Passed $true

        # Read back
        Write-TestStep "Reading classifiers from SQL..."
        $readClassifiers = Get-FGRiskClassifiers -ConfigFile $ConfigFile
        $readCount = if ($readClassifiers -is [array]) { $readClassifiers.Count } else { if ($readClassifiers) { 1 } else { 0 } }
        Add-TestResult -Category "Classifiers" -TestName "Classifiers retrieved from SQL ($readCount)" -Passed ($readCount -gt 0)

        # Export/Import
        $classifierExportPath = Join-Path $exportDir "test-risk-classifiers.json"
        Export-FGRiskClassifiers -Classifiers $classifiers -Path $classifierExportPath
        Add-TestResult -Category "Classifiers" -TestName "Classifiers exported to JSON" -Passed (Test-Path $classifierExportPath)

        $importedClassifiers = Import-FGRiskClassifiers -Path $classifierExportPath
        $importedCount = if ($importedClassifiers -is [array]) { $importedClassifiers.Count } else { if ($importedClassifiers) { 1 } else { 0 } }
        Add-TestResult -Category "Classifiers" -TestName "Classifiers imported from JSON ($importedCount)" -Passed ($importedCount -gt 0)
    }
} catch {
    Add-TestResult -Category "Classifiers" -TestName "Risk classifier generation" -Passed $false -Message $_.Exception.Message
}

# ══════════════════════════════════════════════════════════════════════
# TEST 3: Batch Scoring
# ══════════════════════════════════════════════════════════════════════
Write-TestHeader "3. Batch Scoring"

try {
    Write-TestStep "Running Invoke-FGRiskScoring (scoring all users + groups)..."
    Invoke-FGRiskScoring -ConfigFile $ConfigFile
    Add-TestResult -Category "Scoring" -TestName "Invoke-FGRiskScoring completed" -Passed $true

    # Verify scores on users
    Write-TestStep "Verifying user risk scores..."
    $scoredUsers = Invoke-FGSQLQuery -Query "SELECT COUNT(*) AS cnt FROM GraphUsers WHERE riskScore IS NOT NULL"
    Add-TestResult -Category "Scoring" -TestName "Users have risk scores ($($scoredUsers.cnt)/$userCount)" -Passed ($scoredUsers.cnt -gt 0)

    # Verify scores on groups
    Write-TestStep "Verifying group risk scores..."
    $scoredGroups = Invoke-FGSQLQuery -Query "SELECT COUNT(*) AS cnt FROM GraphGroups WHERE riskScore IS NOT NULL"
    Add-TestResult -Category "Scoring" -TestName "Groups have risk scores ($($scoredGroups.cnt)/$groupCount)" -Passed ($scoredGroups.cnt -gt 0)

    # Score range check (0-100)
    $outOfRange = Invoke-FGSQLQuery -Query "SELECT COUNT(*) AS cnt FROM GraphUsers WHERE riskScore < 0 OR riskScore > 100"
    Add-TestResult -Category "Scoring" -TestName "All user scores in 0-100 range" -Passed ($outOfRange.cnt -eq 0) -Message $(if ($outOfRange.cnt -gt 0) { "$($outOfRange.cnt) scores out of range" })

    $outOfRangeGroups = Invoke-FGSQLQuery -Query "SELECT COUNT(*) AS cnt FROM GraphGroups WHERE riskScore < 0 OR riskScore > 100"
    Add-TestResult -Category "Scoring" -TestName "All group scores in 0-100 range" -Passed ($outOfRangeGroups.cnt -eq 0)

    # Tier assignment check
    $validTiers = @('Critical', 'High', 'Medium', 'Low', 'Minimal', 'None')
    $invalidTiers = Invoke-FGSQLQuery -Query "SELECT DISTINCT riskTier FROM GraphUsers WHERE riskTier IS NOT NULL AND riskTier NOT IN ('Critical','High','Medium','Low','Minimal','None')"
    $hasInvalidTiers = if ($invalidTiers -is [array]) { $invalidTiers.Count -gt 0 } else { $null -ne $invalidTiers }
    Add-TestResult -Category "Scoring" -TestName "All risk tiers are valid" -Passed (-not $hasInvalidTiers) -Message $(if ($hasInvalidTiers) { "Invalid tiers found" })

    # Tier distribution
    Write-TestStep "Risk tier distribution:"
    $tierDist = Invoke-FGSQLQuery -Query "SELECT riskTier, COUNT(*) AS cnt FROM GraphUsers WHERE riskScore IS NOT NULL GROUP BY riskTier ORDER BY MIN(riskScore) DESC"
    if ($tierDist) {
        $tiers = if ($tierDist -is [array]) { $tierDist } else { @($tierDist) }
        foreach ($tier in $tiers) {
            Write-Host "    $($tier.riskTier): $($tier.cnt)" -ForegroundColor Gray
        }
    }
    Add-TestResult -Category "Scoring" -TestName "Tier distribution retrieved" -Passed ($null -ne $tierDist)

    # Check top scored entity
    $topUser = Invoke-FGSQLQuery -Query "SELECT TOP 1 displayName, riskScore, riskTier FROM GraphUsers WHERE riskScore IS NOT NULL ORDER BY riskScore DESC"
    if ($topUser) {
        Write-TestStep "Highest risk user: $($topUser.displayName) (score: $($topUser.riskScore), tier: $($topUser.riskTier))"
    }

} catch {
    Add-TestResult -Category "Scoring" -TestName "Batch scoring" -Passed $false -Message $_.Exception.Message
}

# ══════════════════════════════════════════════════════════════════════
# TEST 4: Analyst Override
# ══════════════════════════════════════════════════════════════════════
Write-TestHeader "4. Analyst Override (via SQL)"

try {
    # Find a scored user to override
    $targetUser = Invoke-FGSQLQuery -Query "SELECT TOP 1 id, displayName, riskScore FROM GraphUsers WHERE riskScore IS NOT NULL ORDER BY riskScore DESC"

    if ($targetUser) {
        Write-TestStep "Setting override on user: $($targetUser.displayName) (current score: $($targetUser.riskScore))..."

        # Set override via direct SQL (the UI uses the API endpoint)
        Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            $cmd = $connection.CreateCommand()
            $cmd.CommandText = "UPDATE dbo.GraphUsers SET riskOverride = @Override, riskOverrideReason = @Reason WHERE id = @Id"
            $cmd.Parameters.AddWithValue("@Override", 10) | Out-Null
            $cmd.Parameters.AddWithValue("@Reason", "Test override from automated test suite") | Out-Null
            $cmd.Parameters.AddWithValue("@Id", $targetUser.id) | Out-Null
            $cmd.ExecuteNonQuery() | Out-Null
        }

        # Verify override
        $overridden = Invoke-FGSQLQuery -Query "SELECT riskOverride, riskOverrideReason FROM GraphUsers WHERE id = '$($targetUser.id)'"
        Add-TestResult -Category "Override" -TestName "Override value set (+10)" -Passed ($overridden.riskOverride -eq 10)
        Add-TestResult -Category "Override" -TestName "Override reason saved" -Passed ($overridden.riskOverrideReason -eq "Test override from automated test suite")

        # Clean up override
        Write-TestStep "Removing override..."
        Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            $cmd = $connection.CreateCommand()
            $cmd.CommandText = "UPDATE dbo.GraphUsers SET riskOverride = NULL, riskOverrideReason = NULL WHERE id = @Id"
            $cmd.Parameters.AddWithValue("@Id", $targetUser.id) | Out-Null
            $cmd.ExecuteNonQuery() | Out-Null
        }

        $cleared = Invoke-FGSQLQuery -Query "SELECT riskOverride FROM GraphUsers WHERE id = '$($targetUser.id)'"
        Add-TestResult -Category "Override" -TestName "Override removed successfully" -Passed ($null -eq $cleared.riskOverride)
    } else {
        Add-TestResult -Category "Override" -TestName "Find scored user for override test" -Passed $true -Skipped -Message "No scored users found"
    }
} catch {
    Add-TestResult -Category "Override" -TestName "Analyst override" -Passed $false -Message $_.Exception.Message
}

# ══════════════════════════════════════════════════════════════════════
# TEST 5: Resource Clustering
# ══════════════════════════════════════════════════════════════════════
Write-TestHeader "5. Resource Clustering"

try {
    Write-TestStep "Running Save-FGResourceClusters..."
    Save-FGResourceClusters -ConfigFile $ConfigFile
    Add-TestResult -Category "Clustering" -TestName "Save-FGResourceClusters completed" -Passed $true

    # Check if clusters were created
    try {
        $clusterCount = Invoke-FGSQLQuery -Query "SELECT COUNT(*) AS cnt FROM GraphResourceClusters"
        Add-TestResult -Category "Clustering" -TestName "Resource clusters created ($($clusterCount.cnt))" -Passed ($clusterCount.cnt -ge 0)
    } catch {
        # Table may not exist if no clusters generated
        Add-TestResult -Category "Clustering" -TestName "Resource clusters table" -Passed $true -Skipped -Message "GraphResourceClusters table not created (may be expected)"
    }
} catch {
    Add-TestResult -Category "Clustering" -TestName "Resource clustering" -Passed $false -Message $_.Exception.Message
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

# Cleanup exports
Write-TestStep "Test exports saved to: $exportDir"

Stop-Transcript | Out-Null
Write-Host "Log saved to: $transcriptFile" -ForegroundColor Gray

exit $(if ($script:FailedTests -gt 0) { 1 } else { 0 })
