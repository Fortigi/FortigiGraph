function New-FGRiskClassifiers {
    <#
    .SYNOPSIS
        Generates identity risk classifiers from an organizational risk profile.

    .DESCRIPTION
        Phase 1, Step 1.3 of the Identity Risk Scoring architecture.

        Takes a finalized organizational risk profile (from New-FGRiskProfile) and uses an LLM
        to generate industry-specific and organization-specific classifiers. These are merged
        with the universal classifiers to create a complete classifier ruleset.

        The output is a JSON file that the scoring engine (Phase 2) reads to classify entities.

        NO sensitive identity data is involved — classifiers are detection rules (regex patterns,
        score weights) generated from organizational context only.

    .PARAMETER ProfilePath
        Path to the organizational risk profile JSON (output of New-FGRiskProfile).
        Optional — if not provided, loads the profile from SQL (saved by New-FGRiskProfile).

    .PARAMETER OutputPath
        Path to save the merged classifier ruleset as a file. Optional — by default
        classifiers are only saved to SQL. Use Export-FGRiskClassifiers for file export.

    .PARAMETER UniversalClassifiersPath
        Path to universal classifiers JSON. Defaults to the one bundled with FortigiGraph.

    .PARAMETER LLMProvider
        LLM provider: "Anthropic" or "OpenAI". Default: "Anthropic".

    .PARAMETER LLMApiKey
        API key for the chosen LLM provider.

    .PARAMETER LLMModel
        Optional model override.

    .PARAMETER ConfigFile
        Optional FortigiGraph config file. Reads LLM settings from RiskScoring section.

    .EXAMPLE
        New-FGRiskClassifiers -ConfigFile .\Config\mycompany.json

    .EXAMPLE
        New-FGRiskClassifiers -ProfilePath "./export/risk-profile.json" -LLMProvider Anthropic -LLMApiKey $key
    #>

    [alias("New-RiskClassifiers")]
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory = $false)]
        [System.String]$ProfilePath,

        [Parameter(Mandatory = $false)]
        [System.String]$OutputPath,

        [Parameter(Mandatory = $false)]
        [System.String]$UniversalClassifiersPath,

        [Parameter(Mandatory = $false, ParameterSetName = "Explicit")]
        [ValidateSet("Anthropic", "OpenAI")]
        [System.String]$LLMProvider = "Anthropic",

        [Parameter(Mandatory = $false, ParameterSetName = "Explicit")]
        [System.String]$LLMApiKey,

        [Parameter(Mandatory = $false, ParameterSetName = "Explicit")]
        [System.String]$LLMModel,

        [Parameter(Mandatory = $false, ParameterSetName = "ConfigFile")]
        [System.String]$ConfigFile
    )

    # ================================================================
    # Configuration
    # ================================================================

    if ($ProfilePath -and -not (Test-Path $ProfilePath)) {
        throw "Risk profile not found: $ProfilePath. Run New-FGRiskProfile first."
    }

    if ($PSCmdlet.ParameterSetName -eq "ConfigFile") {
        if (-not (Test-Path $ConfigFile)) {
            throw "Configuration file not found: $ConfigFile"
        }
        $config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json

        if ($config.RiskScoring) {
            if ($config.RiskScoring.LLMProvider) { $LLMProvider = $config.RiskScoring.LLMProvider }
            if ($config.RiskScoring.LLMModel) { $LLMModel = $config.RiskScoring.LLMModel }
            if ($config.RiskScoring.LLMApiKey) {
                $LLMApiKey = $config.RiskScoring.LLMApiKey
            } elseif ($config.RiskScoring.LLMApiKey_Encrypted) {
                $LLMApiKey = Get-FGSecureConfigValue -ConfigPath $ConfigFile -PropertyPath "RiskScoring.LLMApiKey" -AllowEmpty
            }
        }
    }

    # Check for API key in environment if not provided
    if ([string]::IsNullOrWhiteSpace($LLMApiKey)) {
        $envVar = switch ($LLMProvider) {
            "Anthropic" { "ANTHROPIC_API_KEY" }
            "OpenAI"    { "OPENAI_API_KEY" }
        }
        $LLMApiKey = [System.Environment]::GetEnvironmentVariable($envVar)
        if ([string]::IsNullOrWhiteSpace($LLMApiKey)) {
            throw "No API key provided. Set -LLMApiKey, configure it in the config file, or set the $envVar environment variable."
        }
    }

    # Set default universal classifiers path
    if ([string]::IsNullOrWhiteSpace($UniversalClassifiersPath)) {
        $modulePath = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $UniversalClassifiersPath = Join-Path $modulePath "UI" "backend" "src" "risk" "classifiers" "universal.json"
        if (-not (Test-Path $UniversalClassifiersPath)) {
            $UniversalClassifiersPath = Join-Path $modulePath "RiskScoring" "classifiers" "universal.json"
        }
    }

    # Load profile: file path → SQL → error
    $profileRaw = $null
    if ($ProfilePath -and (Test-Path $ProfilePath)) {
        Write-Host "  Loading risk profile from file: $ProfilePath" -ForegroundColor Gray
        $profileRaw = Get-Content -Path $ProfilePath -Raw | ConvertFrom-Json
    } else {
        # Try SQL
        $sqlId = if ($config -and $config.RiskScoring.CustomerDomain) { $config.RiskScoring.CustomerDomain } else { $null }
        $profileRaw = Get-FGRiskProfile -Id $sqlId
        if ($profileRaw) {
            $src = if ($sqlId) { "SQL (id=$sqlId)" } else { "SQL (latest)" }
            Write-Host "  Loading risk profile from $src" -ForegroundColor Gray
        } else {
            throw "No risk profile found. Run New-FGRiskProfile first, or provide -ProfilePath."
        }
    }
    $customerProfile = $profileRaw.customer_profile

    # Load universal classifiers
    $universalClassifiers = $null
    if (Test-Path $UniversalClassifiersPath) {
        $universalClassifiers = Get-Content -Path $UniversalClassifiersPath -Raw | ConvertFrom-Json
        Write-Host "  Loaded universal classifiers: $($universalClassifiers.groups.Count) group, $($universalClassifiers.users.Count) user rules" -ForegroundColor Gray
    } else {
        Write-Host "  Universal classifiers not found at: $UniversalClassifiersPath" -ForegroundColor Yellow
        Write-Host "  Generating classifiers without universal base." -ForegroundColor Yellow
    }

    # ================================================================
    # Step 1.3 — Classifier Generation
    # ================================================================

    Write-Host ""
    Write-Host "=== Classifier Generation ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Profile: $($customerProfile.name) ($($customerProfile.domain))" -ForegroundColor Gray
    Write-Host "  Industry: $($customerProfile.industry) / $($customerProfile.sub_industry)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Generating industry and organization-specific classifiers..." -ForegroundColor Gray
    Write-Host ""

    $systemPrompt = @"
You are an identity security expert generating risk classifiers for Active Directory and Entra ID environments.

Based on the organizational risk profile provided, generate classifiers that detect high-risk groups, users, and applications. These classifiers use regex patterns to match entity names, descriptions, and properties.

IMPORTANT RULES:
1. Return ONLY a valid JSON object — no markdown fencing, no explanation
2. Generate classifiers SPECIFIC to this organization's industry and context
3. DO NOT duplicate universal classifiers (domain admins, global admins, VPN, etc. are already covered)
4. Include BOTH English and local language variants in patterns (for country: $($customerProfile.country))
5. Use case-insensitive regex patterns
6. Each classifier needs: id, category, name_patterns (array), base_score (0-100), rationale
7. Optionally include: description_patterns, title_patterns (for users), upn_patterns (for users)
8. IDs should be prefixed with the industry slug (e.g., "bank-swift-ops", "port-vts-access")

Generate classifiers in these categories:

FOR GROUPS:
- Groups that manage access to industry-critical systems (from known_systems in profile)
- Groups related to regulatory compliance roles
- Groups for operational technology / physical safety systems
- Groups for industry-specific applications
- Groups for critical business process access

FOR USERS:
- Industry-critical roles (from critical_roles in profile)
- Regulatory-mandated positions
- Roles with safety/security authority
- Roles with financial authority specific to this industry

Return this JSON structure:
{
  "industry_classifiers": {
    "industry": "$($customerProfile.industry)",
    "sub_industry": "$($customerProfile.sub_industry)",
    "groups": [ ... ],
    "users": [ ... ]
  },
  "organization_classifiers": {
    "customer": "$($customerProfile.domain)",
    "groups": [ ... ],
    "users": [ ... ]
  }
}

The industry_classifiers should be reusable for ANY organization in this industry.
The organization_classifiers should be specific to THIS organization's known systems and context.
"@

    $userPrompt = @"
Generate identity risk classifiers for this organization:

$(($customerProfile | ConvertTo-Json -Depth 100))

Create industry-specific classifiers for the "$($customerProfile.industry) / $($customerProfile.sub_industry)" sector,
plus organization-specific classifiers based on their known systems and critical roles.
"@

    $rawResponse = Invoke-FGLLMRequest `
        -Provider $LLMProvider `
        -ApiKey $LLMApiKey `
        -SystemPrompt $systemPrompt `
        -UserPrompt $userPrompt `
        -Model $LLMModel `
        -MaxTokens 4096 `
        -Temperature 0.3

    # Parse response
    try {
        $jsonText = $rawResponse -replace '(?s)^```json\s*', '' -replace '(?s)\s*```$', '' -replace '(?s)^```\s*', ''
        $generated = $jsonText | ConvertFrom-Json
    }
    catch {
        Write-Host "Failed to parse LLM response as JSON. Raw response:" -ForegroundColor Red
        Write-Host $rawResponse -ForegroundColor Gray
        throw "LLM did not return valid JSON. Please try again."
    }

    # ================================================================
    # Merge classifiers: universal + industry + organization
    # ================================================================

    Write-Host "--- Merging Classifiers ---" -ForegroundColor Cyan
    Write-Host ""

    $mergedGroups = @()
    $mergedUsers = @()

    # Universal
    if ($universalClassifiers) {
        $mergedGroups += $universalClassifiers.groups
        $mergedUsers += $universalClassifiers.users
        Write-Host "  Universal:     $($universalClassifiers.groups.Count) group, $($universalClassifiers.users.Count) user classifiers" -ForegroundColor Gray
    }

    # Industry
    if ($generated.industry_classifiers) {
        $indGroups = @($generated.industry_classifiers.groups | Where-Object { $_ })
        $indUsers = @($generated.industry_classifiers.users | Where-Object { $_ })
        $mergedGroups += $indGroups
        $mergedUsers += $indUsers
        Write-Host "  Industry:      $($indGroups.Count) group, $($indUsers.Count) user classifiers" -ForegroundColor Gray
    }

    # Organization-specific
    if ($generated.organization_classifiers) {
        $orgGroups = @($generated.organization_classifiers.groups | Where-Object { $_ })
        $orgUsers = @($generated.organization_classifiers.users | Where-Object { $_ })
        $mergedGroups += $orgGroups
        $mergedUsers += $orgUsers
        Write-Host "  Organization:  $($orgGroups.Count) group, $($orgUsers.Count) user classifiers" -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "  Total:         $($mergedGroups.Count) group, $($mergedUsers.Count) user classifiers" -ForegroundColor Green

    # Deduplicate by ID (later entries win)
    $seenGroupIds = @{}
    $dedupedGroups = @()
    foreach ($g in $mergedGroups) {
        if ($g.id -and -not $seenGroupIds.ContainsKey($g.id)) {
            $seenGroupIds[$g.id] = $true
            $dedupedGroups += $g
        }
    }

    $seenUserIds = @{}
    $dedupedUsers = @()
    foreach ($u in $mergedUsers) {
        if ($u.id -and -not $seenUserIds.ContainsKey($u.id)) {
            $seenUserIds[$u.id] = $true
            $dedupedUsers += $u
        }
    }

    if ($dedupedGroups.Count -ne $mergedGroups.Count -or $dedupedUsers.Count -ne $mergedUsers.Count) {
        $removedGroups = $mergedGroups.Count - $dedupedGroups.Count
        $removedUsers = $mergedUsers.Count - $dedupedUsers.Count
        Write-Host "  Deduplication: removed $removedGroups group, $removedUsers user duplicates" -ForegroundColor Yellow
    }

    # ================================================================
    # Build and save the classifier ruleset
    # ================================================================

    $ruleset = [ordered]@{
        version       = "1.0"
        customer      = $customerProfile.domain
        generated_at  = (Get-Date -Format "o")
        profile_ref   = if ($ProfilePath) { $ProfilePath } else { "sql" }
        llm_provider  = $LLMProvider
        groups        = $dedupedGroups
        users         = $dedupedUsers
    }

    # Save to SQL (primary storage)
    if ($global:FGSQLConnectionString) {
        try {
            Save-FGRiskClassifiers -ClassifierRuleset ([PSCustomObject]$ruleset)
        } catch {
            Write-Host "  WARNING: Could not save to SQL: $_" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  WARNING: Not connected to SQL. Classifiers not persisted." -ForegroundColor Yellow
        Write-Host "  Connect to SQL first or use -OutputPath to save to file." -ForegroundColor Yellow
    }

    # Save to file (only if explicitly requested)
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $outputDir = Split-Path $OutputPath -Parent
        if ($outputDir -and -not (Test-Path $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        }
        $rulesetJson = $ruleset | ConvertTo-Json -Depth 100
        $rulesetJson | Set-Content -Path $OutputPath -Encoding UTF8
        Write-Host "  Classifier ruleset also saved to: $OutputPath" -ForegroundColor Gray
    }

    Write-Host ""

    # ================================================================
    # Display generated classifiers summary
    # ================================================================

    Write-Host "--- Generated Classifiers ---" -ForegroundColor Cyan
    Write-Host ""

    if ($generated.industry_classifiers.groups) {
        Write-Host "  Industry Group Classifiers ($($customerProfile.industry)):" -ForegroundColor Gray
        foreach ($c in $generated.industry_classifiers.groups) {
            Write-Host "    - $($c.id) " -NoNewline -ForegroundColor White
            Write-Host "(score: $($c.base_score))" -ForegroundColor Cyan
            Write-Host "      $($c.rationale)" -ForegroundColor Gray
            $patterns = ($c.name_patterns -join ", ")
            Write-Host "      Patterns: $patterns" -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    if ($generated.industry_classifiers.users) {
        Write-Host "  Industry User Classifiers ($($customerProfile.industry)):" -ForegroundColor Gray
        foreach ($c in $generated.industry_classifiers.users) {
            Write-Host "    - $($c.id) " -NoNewline -ForegroundColor White
            Write-Host "(score: $($c.base_score))" -ForegroundColor Cyan
            Write-Host "      $($c.rationale)" -ForegroundColor Gray
        }
        Write-Host ""
    }

    if ($generated.organization_classifiers.groups) {
        Write-Host "  Organization-Specific Group Classifiers ($($customerProfile.domain)):" -ForegroundColor Gray
        foreach ($c in $generated.organization_classifiers.groups) {
            Write-Host "    - $($c.id) " -NoNewline -ForegroundColor White
            Write-Host "(score: $($c.base_score))" -ForegroundColor Cyan
            Write-Host "      $($c.rationale)" -ForegroundColor Gray
        }
        Write-Host ""
    }

    if ($generated.organization_classifiers.users) {
        Write-Host "  Organization-Specific User Classifiers ($($customerProfile.domain)):" -ForegroundColor Gray
        foreach ($c in $generated.organization_classifiers.users) {
            Write-Host "    - $($c.id) " -NoNewline -ForegroundColor White
            Write-Host "(score: $($c.base_score))" -ForegroundColor Cyan
            Write-Host "      $($c.rationale)" -ForegroundColor Gray
        }
        Write-Host ""
    }

    Write-Host "  The scoring engine will use this ruleset to classify your Entra ID entities." -ForegroundColor Gray
    Write-Host "  To use with the UI, copy the ruleset to: UI/backend/src/risk/classifiers/" -ForegroundColor Gray
    Write-Host ""

    return $ruleset
}
