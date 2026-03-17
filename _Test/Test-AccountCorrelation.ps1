# Account Correlation Tests for FortigiGraph
# Tests the 4 new correlation functions: Invoke-FGAccountCorrelation, New-FGCorrelationRuleset,
# Get-FGCorrelationRuleset, Save-FGCorrelationRuleset
#
# Requires a live SQL connection (via ConfigFile) — no Graph API or LLM needed for most tests.
# The -NoLLM flag in New-FGCorrelationRuleset allows ruleset generation without LLM.
#
# Usage:
#   pwsh -File _Test\Test-AccountCorrelation.ps1 -ConfigFile _Test\config.test.json
#   pwsh -File _Test\Test-AccountCorrelation.ps1 -ConfigFile _Test\config.test.json -LLMProvider Anthropic -LLMApiKey "sk-ant-..."

param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Anthropic", "OpenAI")]
    [string]$LLMProvider,

    [Parameter(Mandatory = $false)]
    [string]$LLMApiKey,

    [switch]$SkipLLM   # Skip tests that require an LLM API key
)

$ErrorActionPreference = "Continue"

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
$transcriptDir = Join-Path $PSScriptRoot "logs"
if (-not (Test-Path $transcriptDir)) { New-Item -ItemType Directory -Path $transcriptDir -Force | Out-Null }
$transcriptFile = Join-Path $transcriptDir "account-correlation-test-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -Path $transcriptFile -Force | Out-Null

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "FortigiGraph Account Correlation Tests" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Config: $ConfigFile" -ForegroundColor Gray
Write-Host "LLM:    $(if ($LLMProvider) { $LLMProvider } else { '(skipped)' })`n" -ForegroundColor Gray

$moduleRoot = Split-Path -Parent $PSScriptRoot
$hasLLM = $LLMProvider -and $LLMApiKey -and -not $SkipLLM

# ══════════════════════════════════════════════════════════════════════
# SECTION 1: Module & Function Availability
# ══════════════════════════════════════════════════════════════════════
Write-TestHeader "1. Module & Function Availability"

$modulePath = Join-Path $moduleRoot "FortigiGraph.psd1"
try {
    Import-Module $modulePath -Force -ErrorAction Stop
    Add-TestResult -Category "Module" -TestName "Module imports successfully" -Passed $true
} catch {
    Add-TestResult -Category "Module" -TestName "Module imports successfully" -Passed $false -Message $_.Exception.Message
    Write-Host "`nModule failed to load — cannot run remaining tests." -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}

$correlationFunctions = @(
    "Invoke-FGAccountCorrelation",
    "New-FGCorrelationRuleset",
    "Get-FGCorrelationRuleset",
    "Save-FGCorrelationRuleset"
)

foreach ($func in $correlationFunctions) {
    $exists = $null -ne (Get-Command $func -ErrorAction SilentlyContinue)
    Add-TestResult -Category "Functions" -TestName "$func is available" -Passed $exists -Message $(if (-not $exists) { "Function not found after module import" })
}

# Check aliases
$aliasPairs = @(
    @{ Alias = "Invoke-AccountCorrelation"; Function = "Invoke-FGAccountCorrelation" },
    @{ Alias = "New-CorrelationRuleset";    Function = "New-FGCorrelationRuleset" },
    @{ Alias = "Get-CorrelationRuleset";    Function = "Get-FGCorrelationRuleset" },
    @{ Alias = "Save-CorrelationRuleset";   Function = "Save-FGCorrelationRuleset" }
)

foreach ($pair in $aliasPairs) {
    $alias = Get-Alias $pair.Alias -ErrorAction SilentlyContinue
    $correct = $alias -and ($alias.Definition -eq $pair.Function)
    Add-TestResult -Category "Functions" -TestName "Alias $($pair.Alias) → $($pair.Function)" -Passed $correct -Message $(if (-not $correct) { "Alias missing or points to wrong function" })
}

# ══════════════════════════════════════════════════════════════════════
# SECTION 2: SQL Connection
# ══════════════════════════════════════════════════════════════════════
Write-TestHeader "2. SQL Connection"

$sqlConnected = $false
try {
    Connect-FGSQLServer -ConfigFile $ConfigFile -ErrorAction Stop
    $sqlConnected = $true
    Add-TestResult -Category "SQL" -TestName "Connected to SQL via ConfigFile" -Passed $true
} catch {
    Add-TestResult -Category "SQL" -TestName "Connected to SQL via ConfigFile" -Passed $false -Message $_.Exception.Message
    Write-Host "`nSQL connection failed — skipping SQL-dependent tests." -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}

# ══════════════════════════════════════════════════════════════════════
# SECTION 3: New-FGCorrelationRuleset — NoLLM Mode
# ══════════════════════════════════════════════════════════════════════
Write-TestHeader "3. New-FGCorrelationRuleset (NoLLM mode)"

$ruleset = $null

try {
    $ruleset = New-FGCorrelationRuleset -NoLLM -ConfigFile $ConfigFile -ErrorAction Stop
    Add-TestResult -Category "NewRuleset" -TestName "New-FGCorrelationRuleset -NoLLM runs without error" -Passed $true
} catch {
    Add-TestResult -Category "NewRuleset" -TestName "New-FGCorrelationRuleset -NoLLM runs without error" -Passed $false -Message $_.Exception.Message
}

if ($ruleset) {
    # Validate ruleset structure
    Add-TestResult -Category "NewRuleset" -TestName "Ruleset has 'version' field" `
        -Passed ($null -ne $ruleset.version) -Message "version field missing"

    Add-TestResult -Category "NewRuleset" -TestName "Ruleset has 'accountTypePatterns' field" `
        -Passed ($null -ne $ruleset.accountTypePatterns) -Message "accountTypePatterns field missing"

    Add-TestResult -Category "NewRuleset" -TestName "Ruleset has 'correlationSignals' array" `
        -Passed ($null -ne $ruleset.correlationSignals -and $ruleset.correlationSignals -is [array]) `
        -Message "correlationSignals should be an array"

    Add-TestResult -Category "NewRuleset" -TestName "correlationSignals array is not empty" `
        -Passed ($ruleset.correlationSignals.Count -gt 0) -Message "correlationSignals is empty"

    # Check account type patterns cover standard types
    $expectedTypes = @("Admin", "Test", "Service", "Shared", "External")
    if ($ruleset.accountTypePatterns) {
        foreach ($type in $expectedTypes) {
            $hasType = $null -ne $ruleset.accountTypePatterns.$type -or
                       ($ruleset.accountTypePatterns -is [array] -and ($ruleset.accountTypePatterns | Where-Object { $_.type -eq $type }))
            Add-TestResult -Category "NewRuleset" -TestName "Ruleset covers account type: $type" `
                -Passed $hasType -Message "Pattern for '$type' not found in ruleset"
        }
    }

    # Check correlation signals cover expected signals
    $signalNames = if ($ruleset.correlationSignals[0] -is [string]) {
        $ruleset.correlationSignals
    } else {
        $ruleset.correlationSignals | ForEach-Object { $_.name -or $_.signal -or $_ }
    }

    $expectedSignals = @("employeeId", "baseName")
    foreach ($signal in $expectedSignals) {
        $found = $signalNames | Where-Object { $_ -match $signal }
        Add-TestResult -Category "NewRuleset" -TestName "Ruleset includes correlation signal: $signal" `
            -Passed ($null -ne $found) -Message "Signal '$signal' not found"
    }

    Write-TestStep "Ruleset version: $($ruleset.version)"
    Write-TestStep "Correlation signals: $(($signalNames | Select-Object -First 5) -join ', ')"
}

# ══════════════════════════════════════════════════════════════════════
# SECTION 4: Save-FGCorrelationRuleset
# ══════════════════════════════════════════════════════════════════════
Write-TestHeader "4. Save-FGCorrelationRuleset"

$savedRulesetId = $null

if ($ruleset) {
    try {
        $savedRulesetId = Save-FGCorrelationRuleset -Ruleset $ruleset -ConfigFile $ConfigFile -ErrorAction Stop
        Add-TestResult -Category "SaveRuleset" -TestName "Save-FGCorrelationRuleset saves without error" -Passed $true
    } catch {
        Add-TestResult -Category "SaveRuleset" -TestName "Save-FGCorrelationRuleset saves without error" -Passed $false -Message $_.Exception.Message
    }

    if ($savedRulesetId) {
        Add-TestResult -Category "SaveRuleset" -TestName "Save returns a non-empty ruleset ID" `
            -Passed (-not [string]::IsNullOrWhiteSpace($savedRulesetId)) -Message "Returned ID was null or empty"
        Write-TestStep "Saved ruleset ID: $savedRulesetId"

        # Verify the CorrelationRulesets table was created
        try {
            $tableExists = Invoke-FGSQLCommand -ScriptBlock {
                param($conn)
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'GraphCorrelationRulesets' AND TABLE_SCHEMA = 'dbo'"
                return $cmd.ExecuteScalar()
            }
            Add-TestResult -Category "SaveRuleset" -TestName "GraphCorrelationRulesets table exists after save" `
                -Passed ($tableExists -gt 0) -Message "Table was not created"
        } catch {
            Add-TestResult -Category "SaveRuleset" -TestName "GraphCorrelationRulesets table exists after save" `
                -Passed $false -Message $_.Exception.Message
        }
    }
} else {
    Add-TestResult -Category "SaveRuleset" -TestName "Save-FGCorrelationRuleset" -Passed $true -Skipped -Message "No ruleset to save (previous test failed)"
}

# ══════════════════════════════════════════════════════════════════════
# SECTION 5: Get-FGCorrelationRuleset
# ══════════════════════════════════════════════════════════════════════
Write-TestHeader "5. Get-FGCorrelationRuleset"

# Get the most recent ruleset (no ID)
try {
    $retrieved = Get-FGCorrelationRuleset -ConfigFile $ConfigFile -ErrorAction Stop
    if ($retrieved) {
        Add-TestResult -Category "GetRuleset" -TestName "Get-FGCorrelationRuleset retrieves most recent ruleset" -Passed $true
        Add-TestResult -Category "GetRuleset" -TestName "Retrieved ruleset has version field" `
            -Passed ($null -ne $retrieved.version) -Message "version field missing"
        Add-TestResult -Category "GetRuleset" -TestName "Retrieved ruleset has accountTypePatterns" `
            -Passed ($null -ne $retrieved.accountTypePatterns) -Message "accountTypePatterns missing"
    } else {
        Add-TestResult -Category "GetRuleset" -TestName "Get-FGCorrelationRuleset retrieves most recent ruleset" `
            -Passed $false -Message "Returned null — no rulesets exist or retrieval failed"
    }
} catch {
    Add-TestResult -Category "GetRuleset" -TestName "Get-FGCorrelationRuleset retrieves most recent ruleset" `
        -Passed $false -Message $_.Exception.Message
}

# Get by specific ID (if we have one)
if ($savedRulesetId) {
    try {
        $byId = Get-FGCorrelationRuleset -Id $savedRulesetId -ConfigFile $ConfigFile -ErrorAction Stop
        Add-TestResult -Category "GetRuleset" -TestName "Get-FGCorrelationRuleset retrieves ruleset by ID" `
            -Passed ($null -ne $byId) -Message "Returned null for known ID"
    } catch {
        Add-TestResult -Category "GetRuleset" -TestName "Get-FGCorrelationRuleset retrieves ruleset by ID" `
            -Passed $false -Message $_.Exception.Message
    }
}

# Test retrieval with non-existent ID (should return null, not throw)
try {
    $notFound = Get-FGCorrelationRuleset -Id "00000000-0000-0000-0000-000000000000" -ConfigFile $ConfigFile -ErrorAction Stop
    Add-TestResult -Category "GetRuleset" -TestName "Get-FGCorrelationRuleset returns null for unknown ID (no exception)" `
        -Passed ($null -eq $notFound) -Message "Should return null, not throw"
} catch {
    Add-TestResult -Category "GetRuleset" -TestName "Get-FGCorrelationRuleset returns null for unknown ID (no exception)" `
        -Passed $false -Message "Threw exception for unknown ID: $($_.Exception.Message)"
}

# ══════════════════════════════════════════════════════════════════════
# SECTION 6: Invoke-FGAccountCorrelation
# ══════════════════════════════════════════════════════════════════════
Write-TestHeader "6. Invoke-FGAccountCorrelation"

# Check whether GraphUsers table exists (required for correlation)
$usersExist = $false
try {
    $userCount = Invoke-FGSQLCommand -ScriptBlock {
        param($conn)
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'GraphUsers' AND TABLE_SCHEMA = 'dbo'"
        return $cmd.ExecuteScalar()
    }
    $usersExist = $userCount -gt 0
} catch { }

if (-not $usersExist) {
    Add-TestResult -Category "Correlation" -TestName "Invoke-FGAccountCorrelation" `
        -Passed $true -Skipped -Message "GraphUsers table does not exist — run Sync-FGUser first"
} else {
    # Check user row count
    $syncedUserCount = Invoke-FGSQLCommand -ScriptBlock {
        param($conn)
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.GraphUsers"
        return $cmd.ExecuteScalar()
    }
    Write-TestStep "GraphUsers row count: $syncedUserCount"

    if ($syncedUserCount -eq 0) {
        Add-TestResult -Category "Correlation" -TestName "Invoke-FGAccountCorrelation" `
            -Passed $true -Skipped -Message "GraphUsers is empty — no data to correlate"
    } else {
        try {
            $result = Invoke-FGAccountCorrelation -ConfigFile $ConfigFile -ErrorAction Stop
            Add-TestResult -Category "Correlation" -TestName "Invoke-FGAccountCorrelation completes without error" -Passed $true
        } catch {
            Add-TestResult -Category "Correlation" -TestName "Invoke-FGAccountCorrelation completes without error" `
                -Passed $false -Message $_.Exception.Message
        }

        # Verify GraphIdentities table was created
        try {
            $identitiesTableExists = Invoke-FGSQLCommand -ScriptBlock {
                param($conn)
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'GraphIdentities' AND TABLE_SCHEMA = 'dbo'"
                return $cmd.ExecuteScalar()
            }
            Add-TestResult -Category "Correlation" -TestName "GraphIdentities table created after correlation" `
                -Passed ($identitiesTableExists -gt 0) -Message "Table not found after Invoke-FGAccountCorrelation"
        } catch {
            Add-TestResult -Category "Correlation" -TestName "GraphIdentities table created after correlation" `
                -Passed $false -Message $_.Exception.Message
        }

        # Verify GraphIdentityMembers table was created
        try {
            $membersTableExists = Invoke-FGSQLCommand -ScriptBlock {
                param($conn)
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'GraphIdentityMembers' AND TABLE_SCHEMA = 'dbo'"
                return $cmd.ExecuteScalar()
            }
            Add-TestResult -Category "Correlation" -TestName "GraphIdentityMembers table created after correlation" `
                -Passed ($membersTableExists -gt 0) -Message "Table not found after Invoke-FGAccountCorrelation"
        } catch {
            Add-TestResult -Category "Correlation" -TestName "GraphIdentityMembers table created after correlation" `
                -Passed $false -Message $_.Exception.Message
        }

        # Verify data consistency: every identity member points to a valid identity
        try {
            $orphanMembers = Invoke-FGSQLCommand -ScriptBlock {
                param($conn)
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = @"
                    SELECT COUNT(*) FROM dbo.GraphIdentityMembers m
                    WHERE NOT EXISTS (SELECT 1 FROM dbo.GraphIdentities i WHERE i.id = m.identityId)
"@
                return $cmd.ExecuteScalar()
            }
            Add-TestResult -Category "Correlation" -TestName "No orphaned identity members (referential integrity)" `
                -Passed ($orphanMembers -eq 0) -Message "$orphanMembers member rows have no matching identity"
        } catch {
            Add-TestResult -Category "Correlation" -TestName "No orphaned identity members (referential integrity)" `
                -Passed $false -Message $_.Exception.Message
        }

        # Verify accountCount on GraphIdentities matches actual member count
        try {
            $mismatchCount = Invoke-FGSQLCommand -ScriptBlock {
                param($conn)
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = @"
                    SELECT COUNT(*) FROM dbo.GraphIdentities i
                    WHERE i.accountCount <> (
                        SELECT COUNT(*) FROM dbo.GraphIdentityMembers m WHERE m.identityId = i.id
                    )
"@
                return $cmd.ExecuteScalar()
            }
            Add-TestResult -Category "Correlation" -TestName "accountCount matches actual member count" `
                -Passed ($mismatchCount -eq 0) -Message "$mismatchCount identities have wrong accountCount"
        } catch {
            Add-TestResult -Category "Correlation" -TestName "accountCount matches actual member count" `
                -Passed $false -Message $_.Exception.Message
        }

        # Verify each identity has exactly one primary member
        try {
            $wrongPrimary = Invoke-FGSQLCommand -ScriptBlock {
                param($conn)
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = @"
                    SELECT COUNT(*) FROM (
                        SELECT identityId, SUM(CASE WHEN isPrimary = 1 THEN 1 ELSE 0 END) AS primaryCount
                        FROM dbo.GraphIdentityMembers
                        GROUP BY identityId
                        HAVING SUM(CASE WHEN isPrimary = 1 THEN 1 ELSE 0 END) <> 1
                    ) AS t
"@
                return $cmd.ExecuteScalar()
            }
            Add-TestResult -Category "Correlation" -TestName "Every identity has exactly one primary account" `
                -Passed ($wrongPrimary -eq 0) -Message "$wrongPrimary identities have wrong number of primary accounts"
        } catch {
            Add-TestResult -Category "Correlation" -TestName "Every identity has exactly one primary account" `
                -Passed $false -Message $_.Exception.Message
        }

        # Verify correlationConfidence is in range 0-100
        try {
            $outOfRange = Invoke-FGSQLCommand -ScriptBlock {
                param($conn)
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = "SELECT COUNT(*) FROM dbo.GraphIdentities WHERE correlationConfidence < 0 OR correlationConfidence > 100"
                return $cmd.ExecuteScalar()
            }
            Add-TestResult -Category "Correlation" -TestName "correlationConfidence is in range 0-100" `
                -Passed ($outOfRange -eq 0) -Message "$outOfRange identities have out-of-range confidence"
        } catch {
            Add-TestResult -Category "Correlation" -TestName "correlationConfidence is in range 0-100" `
                -Passed $false -Message $_.Exception.Message
        }

        # Verify accountType values are from the known set
        try {
            $knownTypes = "'Regular', 'Admin', 'Test', 'Service', 'Shared', 'External'"
            $unknownTypes = Invoke-FGSQLCommand -ScriptBlock {
                param($conn)
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = "SELECT COUNT(*) FROM dbo.GraphIdentityMembers WHERE accountType NOT IN ('Regular', 'Admin', 'Test', 'Service', 'Shared', 'External')"
                return $cmd.ExecuteScalar()
            }
            Add-TestResult -Category "Correlation" -TestName "All accountType values are from the known set" `
                -Passed ($unknownTypes -eq 0) -Message "$unknownTypes rows have unrecognised accountType"
        } catch {
            Add-TestResult -Category "Correlation" -TestName "All accountType values are from the known set" `
                -Passed $false -Message $_.Exception.Message
        }

        # Report identity counts
        try {
            $stats = Invoke-FGSQLCommand -ScriptBlock {
                param($conn)
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = @"
                    SELECT
                        COUNT(*) AS totalIdentities,
                        SUM(CASE WHEN accountCount > 1 THEN 1 ELSE 0 END) AS multiAccount,
                        SUM(accountCount) AS totalAccounts
                    FROM dbo.GraphIdentities
"@
                $reader = $cmd.ExecuteReader()
                if ($reader.Read()) {
                    $result = [PSCustomObject]@{
                        TotalIdentities = $reader["totalIdentities"]
                        MultiAccount    = $reader["multiAccount"]
                        TotalAccounts   = $reader["totalAccounts"]
                    }
                }
                $reader.Close()
                return $result
            }

            if ($stats) {
                Write-TestStep "Identities created: $($stats.TotalIdentities) (multi-account: $($stats.MultiAccount), total accounts: $($stats.TotalAccounts))"
                Add-TestResult -Category "Correlation" -TestName "At least one identity was created" `
                    -Passed ($stats.TotalIdentities -gt 0) -Message "No identities were created"
                Add-TestResult -Category "Correlation" -TestName "Total accounts in identities equals user count (no users lost)" `
                    -Passed ($stats.TotalAccounts -eq $syncedUserCount) `
                    -Message "Expected $syncedUserCount accounts in identities, got $($stats.TotalAccounts)"
            }
        } catch {
            Add-TestResult -Category "Correlation" -TestName "Post-correlation stats query" `
                -Passed $false -Message $_.Exception.Message
        }
    }
}

# ══════════════════════════════════════════════════════════════════════
# SECTION 7: Correlation with specific RulesetId
# ══════════════════════════════════════════════════════════════════════
Write-TestHeader "7. Correlation with specific RulesetId"

if ($savedRulesetId -and $usersExist) {
    try {
        Invoke-FGAccountCorrelation -RulesetId $savedRulesetId -ConfigFile $ConfigFile -ErrorAction Stop
        Add-TestResult -Category "CorrelationById" -TestName "Invoke-FGAccountCorrelation with specific RulesetId works" -Passed $true
    } catch {
        Add-TestResult -Category "CorrelationById" -TestName "Invoke-FGAccountCorrelation with specific RulesetId works" `
            -Passed $false -Message $_.Exception.Message
    }

    # Non-existent RulesetId should fail gracefully
    try {
        Invoke-FGAccountCorrelation -RulesetId "00000000-0000-0000-0000-000000000000" -ConfigFile $ConfigFile -ErrorAction Stop
        Add-TestResult -Category "CorrelationById" -TestName "Non-existent RulesetId causes error" `
            -Passed $false -Message "Should have thrown an error for unknown RulesetId"
    } catch {
        Add-TestResult -Category "CorrelationById" -TestName "Non-existent RulesetId causes error" -Passed $true
    }
} else {
    $reason = if (-not $savedRulesetId) { "no saved ruleset ID" } else { "GraphUsers table unavailable" }
    Add-TestResult -Category "CorrelationById" -TestName "Correlation with specific RulesetId" `
        -Passed $true -Skipped -Message $reason
}

# ══════════════════════════════════════════════════════════════════════
# SECTION 8: Temporal Table Verification
# ══════════════════════════════════════════════════════════════════════
Write-TestHeader "8. Temporal Table Verification"

$tablesToCheck = @("GraphIdentities", "GraphIdentityMembers", "GraphCorrelationRulesets")

foreach ($tableName in $tablesToCheck) {
    try {
        $hasVersioning = Invoke-FGSQLCommand -ScriptBlock {
            param($conn)
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = @"
                SELECT COUNT(*) FROM sys.tables t
                INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
                WHERE t.name = @tableName AND s.name = 'dbo' AND t.temporal_type IN (1, 2)
"@
            $cmd.Parameters.AddWithValue("@tableName", $using:tableName) | Out-Null
            return $cmd.ExecuteScalar()
        }

        # Table might not exist if previous tests were skipped
        $tableExists = Invoke-FGSQLCommand -ScriptBlock {
            param($conn)
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = @name AND TABLE_SCHEMA = 'dbo'"
            $cmd.Parameters.AddWithValue("@name", $using:tableName) | Out-Null
            return $cmd.ExecuteScalar()
        }

        if ($tableExists -gt 0) {
            Add-TestResult -Category "Temporal" -TestName "$tableName is a temporal table" `
                -Passed ($hasVersioning -gt 0) -Message "Table exists but is not versioned (temporal)"
        } else {
            Add-TestResult -Category "Temporal" -TestName "$tableName temporal check" `
                -Passed $true -Skipped -Message "Table does not exist (previous tests may have been skipped)"
        }
    } catch {
        Add-TestResult -Category "Temporal" -TestName "$tableName temporal table check" `
            -Passed $false -Message $_.Exception.Message
    }
}

# ══════════════════════════════════════════════════════════════════════
# SECTION 9: New-FGCorrelationRuleset with LLM (optional)
# ══════════════════════════════════════════════════════════════════════
Write-TestHeader "9. New-FGCorrelationRuleset with LLM (optional)"

if (-not $hasLLM) {
    Add-TestResult -Category "LLMRuleset" -TestName "LLM-assisted ruleset generation" `
        -Passed $true -Skipped -Message "No -LLMProvider/-LLMApiKey provided. Use -LLMProvider Anthropic -LLMApiKey sk-ant-... to test"
} else {
    try {
        $llmRuleset = New-FGCorrelationRuleset `
            -LLMProvider $LLMProvider `
            -LLMApiKey $LLMApiKey `
            -NoInteractive `
            -ConfigFile $ConfigFile `
            -ErrorAction Stop

        Add-TestResult -Category "LLMRuleset" -TestName "New-FGCorrelationRuleset with LLM completes without error" -Passed $true

        if ($llmRuleset) {
            Add-TestResult -Category "LLMRuleset" -TestName "LLM ruleset has version field" `
                -Passed ($null -ne $llmRuleset.version) -Message "version missing"
            Add-TestResult -Category "LLMRuleset" -TestName "LLM ruleset has accountTypePatterns" `
                -Passed ($null -ne $llmRuleset.accountTypePatterns) -Message "accountTypePatterns missing"
            Add-TestResult -Category "LLMRuleset" -TestName "LLM ruleset has correlationSignals" `
                -Passed ($null -ne $llmRuleset.correlationSignals) -Message "correlationSignals missing"

            Write-TestStep "LLM ruleset version: $($llmRuleset.version)"
        }
    } catch {
        Add-TestResult -Category "LLMRuleset" -TestName "New-FGCorrelationRuleset with LLM completes without error" `
            -Passed $false -Message $_.Exception.Message
    }
}

# ══════════════════════════════════════════════════════════════════════
# SECTION 10: File Structure & Code Quality
# ══════════════════════════════════════════════════════════════════════
Write-TestHeader "10. File Structure & Code Quality"

$correlationFiles = @(
    "Invoke-FGAccountCorrelation.ps1",
    "New-FGCorrelationRuleset.ps1",
    "Get-FGCorrelationRuleset.ps1",
    "Save-FGCorrelationRuleset.ps1"
)

$riskScoringDir = Join-Path $moduleRoot "Functions\RiskScoring"

foreach ($fileName in $correlationFiles) {
    $filePath = Join-Path $riskScoringDir $fileName
    $exists = Test-Path $filePath
    Add-TestResult -Category "FileStructure" -TestName "$fileName exists in Functions/RiskScoring/" `
        -Passed $exists -Message "File not found at $filePath"

    if ($exists) {
        $content = Get-Content $filePath -Raw

        Add-TestResult -Category "FileStructure" -TestName "$fileName has [cmdletbinding()]" `
            -Passed ($content -match '(?i)\[cmdletbinding\(') -Message "Missing [cmdletbinding()]"

        Add-TestResult -Category "FileStructure" -TestName "$fileName has no Dutch comments" `
            -Passed (-not ($content -match '# Controleer|# Verwijder|# Maak|# Als er|# Haal|# Sla op|# Voeg toe')) `
            -Message "Dutch comments found"

        Add-TestResult -Category "FileStructure" -TestName "$fileName has [alias()] defined" `
            -Passed ($content -match '\[alias\(') -Message "No alias found"
    }
}

# Verify FortigiGraph.psm1 loads RiskScoring folder (which contains correlation functions)
$psm1 = Get-Content (Join-Path $moduleRoot "FortigiGraph.psm1") -Raw
Add-TestResult -Category "FileStructure" -TestName "FortigiGraph.psm1 loads RiskScoring folder" `
    -Passed ($psm1 -match 'functions\\RiskScoring' -or $psm1 -match 'functions/RiskScoring') `
    -Message "RiskScoring not dot-sourced in FortigiGraph.psm1"

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
    $passed  = ($cat.Group | Where-Object { $_.Passed -and -not $_.Skipped }).Count
    $skipped = ($cat.Group | Where-Object Skipped).Count
    $total   = $cat.Group.Count
    $hasFail = ($cat.Group | Where-Object { -not $_.Passed -and -not $_.Skipped }).Count -gt 0
    $color   = if ($hasFail) { "Yellow" } else { "Green" }
    $skipStr = if ($skipped -gt 0) { " ($skipped skipped)" } else { "" }
    Write-Host "    $($cat.Name): $passed/$total$skipStr" -ForegroundColor $color
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
