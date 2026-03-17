function New-FGRiskProfile {
    <#
    .SYNOPSIS
        Discovers organizational context and generates a risk profile for identity risk scoring.

    .DESCRIPTION
        Phase 1, Steps 1.1 + 1.2 of the Identity Risk Scoring architecture.

        Uses an LLM (Anthropic Claude or OpenAI) to research a customer's organization based on
        their public domain name. The LLM discovers industry, regulations, critical systems,
        key roles, and risk domains. NO sensitive identity data is sent — only the public domain.

        After discovery, the profile is presented for interactive review. The admin can refine
        the profile through a dialog with the LLM before saving.

    .PARAMETER Domain
        Customer domain name (e.g., "portofrotterdam.com", "rabobank.nl").

    .PARAMETER OrganizationName
        Optional organization name if different from the domain (e.g., "Havenbedrijf Rotterdam N.V.").

    .PARAMETER OutputPath
        Path to save the risk profile JSON file. Defaults to "./RiskScoring/<domain>/risk-profile.json".

    .PARAMETER LLMProvider
        LLM provider to use: "Anthropic" or "OpenAI". Default: "Anthropic".

    .PARAMETER LLMApiKey
        API key for the chosen LLM provider.

    .PARAMETER LLMModel
        Optional model override. Defaults to provider's best available model.

    .PARAMETER ConfigFile
        Optional FortigiGraph config file. If provided, reads LLM settings from the RiskScoring section.

    .PARAMETER SkipReview
        Skip the interactive review dialog and save the profile directly.

    .EXAMPLE
        New-FGRiskProfile -Domain "portofrotterdam.com" -LLMProvider Anthropic -LLMApiKey $env:ANTHROPIC_API_KEY

    .EXAMPLE
        New-FGRiskProfile -Domain "rabobank.nl" -OrganizationName "Rabobank" -ConfigFile .\Config\rabobank.json

    .EXAMPLE
        New-FGRiskProfile -Domain "example.com" -LLMProvider OpenAI -LLMApiKey $env:OPENAI_API_KEY -SkipReview
    #>

    [alias("New-RiskProfile")]
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [System.String]$Domain,

        [Parameter(Mandatory = $false)]
        [System.String]$OrganizationName,

        [Parameter(Mandatory = $false)]
        [System.String]$OutputPath,

        [Parameter(Mandatory = $false, ParameterSetName = "Explicit")]
        [ValidateSet("Anthropic", "OpenAI")]
        [System.String]$LLMProvider = "Anthropic",

        [Parameter(Mandatory = $false, ParameterSetName = "Explicit")]
        [System.String]$LLMApiKey,

        [Parameter(Mandatory = $false, ParameterSetName = "Explicit")]
        [System.String]$LLMModel,

        [Parameter(Mandatory = $false, ParameterSetName = "ConfigFile")]
        [System.String]$ConfigFile,

        [Parameter(Mandatory = $false)]
        [switch]$SkipReview
    )

    # ================================================================
    # Configuration
    # ================================================================

    if ($PSCmdlet.ParameterSetName -eq "ConfigFile") {
        if (-not (Test-Path $ConfigFile)) {
            throw "Configuration file not found: $ConfigFile"
        }
        $config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json

        # Read LLM settings: prefer config.LLM section, fall back to config.RiskScoring for backward compatibility
        $llmConfig = $null
        if ($config.LLM) {
            $llmConfig = $config.LLM
            $llmConfigPath = "LLM"
        } elseif ($config.RiskScoring -and ($config.RiskScoring.LLMProvider -or $config.RiskScoring.LLMApiKey -or $config.RiskScoring.LLMApiKey_Encrypted)) {
            $llmConfig = $config.RiskScoring
            $llmConfigPath = "RiskScoring"
        }
        if ($llmConfig) {
            $providerProp = if ($llmConfig.PSObject.Properties['Provider']) { 'Provider' } else { 'LLMProvider' }
            $modelProp    = if ($llmConfig.PSObject.Properties['Model']) { 'Model' } else { 'LLMModel' }
            $keyProp      = if ($llmConfig.PSObject.Properties['ApiKey']) { 'ApiKey' } else { 'LLMApiKey' }
            $keyEncProp   = if ($llmConfig.PSObject.Properties['ApiKey_Encrypted']) { 'ApiKey_Encrypted' } else { 'LLMApiKey_Encrypted' }

            if ($llmConfig.$providerProp) { $LLMProvider = $llmConfig.$providerProp }
            if ($llmConfig.$modelProp) { $LLMModel = $llmConfig.$modelProp }
            if ($llmConfig.$keyProp) {
                $LLMApiKey = $llmConfig.$keyProp
            } elseif ($llmConfig.$keyEncProp) {
                $keyPath = if ($llmConfigPath -eq 'LLM') { "LLM.ApiKey" } else { "RiskScoring.LLMApiKey" }
                $LLMApiKey = Get-FGSecureConfigValue -ConfigPath $ConfigFile -PropertyPath $keyPath -AllowEmpty
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

    # Create output directory if file output was requested
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $outputDir = Split-Path $OutputPath -Parent
        if ($outputDir -and -not (Test-Path $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        }
    }

    # ================================================================
    # Step 1.1 — Customer Context Discovery
    # ================================================================

    Write-Host ""
    Write-Host "=== Identity Risk Profile Generation ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Domain:   $Domain" -ForegroundColor Gray
    if ($OrganizationName) {
        Write-Host "  Org name: $OrganizationName" -ForegroundColor Gray
    }
    Write-Host "  Provider: $LLMProvider" -ForegroundColor Gray
    Write-Host "  Output:   $OutputPath" -ForegroundColor Gray
    Write-Host ""
    Write-Host "--- Step 1: Organizational Context Discovery ---" -ForegroundColor Cyan
    Write-Host "Researching organization (no sensitive data is sent)..." -ForegroundColor Gray
    Write-Host ""

    $systemPrompt = @"
You are an identity security consultant specializing in organizational risk profiling for identity governance.

Your task is to research an organization based on its public domain name and generate a structured risk profile. This profile will be used to generate identity risk classifiers — regex patterns that detect high-risk groups, users, and applications in their Active Directory / Entra ID environment.

IMPORTANT: You are ONLY generating a profile of public organizational context. No actual identity data (user names, group names, etc.) will be shared with you.

You must respond with ONLY a valid JSON object (no markdown fencing, no explanation before or after). The JSON must follow this exact schema:

{
  "customer_profile": {
    "name": "Full legal name of organization",
    "domain": "domain.com",
    "industry": "industry-slug",
    "sub_industry": "sub-industry-slug",
    "country": "ISO country code",
    "description": "One paragraph description of what the organization does",
    "regulations": [
      {
        "id": "regulation-slug",
        "name": "Full regulation name",
        "relevance": "Why this regulation applies to this organization"
      }
    ],
    "critical_business_processes": [
      "Process description"
    ],
    "known_systems": [
      {
        "name": "System name",
        "type": "System type/description",
        "criticality": "critical|high|medium",
        "description": "What this system does and why it matters"
      }
    ],
    "critical_roles": [
      {
        "title_patterns": ["regex pattern1", "pattern2"],
        "rationale": "Why this role is critical"
      }
    ],
    "risk_domains": [
      {
        "domain": "domain-slug",
        "description": "What this risk domain covers",
        "weight": 0.0 to 1.0
      }
    ]
  }
}

Research targets:
- What does the organization do? (industry, sector, sub-sector)
- What regulations apply? (NIS2, DORA, SOX, HIPAA, Wbni, BIO, etc.)
- What are their critical business processes?
- What key systems/platforms are publicly known? (from job postings, press releases, vendor case studies)
- What security frameworks do they likely follow? (ISO 27001, NIST, BIO for government)
- What are typical critical roles/titles in this industry? Include BOTH English and local language variants in the regex patterns
- What are the main risk domains for this organization?

For title patterns, use regex that works case-insensitively. Include common variations and local language terms where applicable (e.g., for a Dutch company include both English and Dutch job titles).

Be specific to THIS organization, not generic. If it's a port authority, include port-specific systems, roles, and regulations. If it's a bank, include banking-specific ones.
"@

    $orgContext = if ($OrganizationName) { "$OrganizationName ($Domain)" } else { $Domain }
    $userPrompt = "Research the organization at domain '$Domain'" +
        $(if ($OrganizationName) { " (also known as '$OrganizationName')" } else { "" }) +
        " and generate their organizational risk profile as a JSON object."

    $rawResponse = Invoke-FGLLMRequest `
        -Provider $LLMProvider `
        -ApiKey $LLMApiKey `
        -SystemPrompt $systemPrompt `
        -UserPrompt $userPrompt `
        -Model $LLMModel `
        -MaxTokens 4096 `
        -Temperature 0.3

    # Parse the JSON response
    try {
        # Strip markdown code fences if present
        $jsonText = $rawResponse -replace '(?s)^```json\s*', '' -replace '(?s)\s*```$', '' -replace '(?s)^```\s*', ''
        $profile = $jsonText | ConvertFrom-Json
    }
    catch {
        Write-Host "Failed to parse LLM response as JSON. Raw response:" -ForegroundColor Red
        Write-Host $rawResponse -ForegroundColor Gray
        throw "LLM did not return valid JSON. Please try again."
    }

    # Ensure top-level structure
    if (-not $profile.customer_profile) {
        # Some models may return without the wrapper
        $profile = @{ customer_profile = $profile } | ConvertTo-Json -Depth 100 | ConvertFrom-Json
    }

    # ================================================================
    # Display the discovered profile
    # ================================================================

    Write-Host ""
    Write-Host "--- Discovered Risk Profile ---" -ForegroundColor Cyan
    Write-Host ""

    $p = $profile.customer_profile

    Write-Host "  Organization: " -NoNewline -ForegroundColor Gray
    Write-Host $p.name -ForegroundColor White
    Write-Host "  Industry:     " -NoNewline -ForegroundColor Gray
    Write-Host "$($p.industry) / $($p.sub_industry)" -ForegroundColor White
    Write-Host "  Country:      " -NoNewline -ForegroundColor Gray
    Write-Host $p.country -ForegroundColor White
    Write-Host ""

    if ($p.description) {
        Write-Host "  Description:" -ForegroundColor Gray
        Write-Host "  $($p.description)" -ForegroundColor White
        Write-Host ""
    }

    if ($p.regulations) {
        Write-Host "  Regulations:" -ForegroundColor Gray
        foreach ($reg in $p.regulations) {
            Write-Host "    - $($reg.name) ($($reg.id))" -ForegroundColor Yellow
            Write-Host "      $($reg.relevance)" -ForegroundColor Gray
        }
        Write-Host ""
    }

    if ($p.critical_business_processes) {
        Write-Host "  Critical Business Processes:" -ForegroundColor Gray
        foreach ($proc in $p.critical_business_processes) {
            Write-Host "    - $proc" -ForegroundColor White
        }
        Write-Host ""
    }

    if ($p.known_systems) {
        Write-Host "  Known Systems:" -ForegroundColor Gray
        foreach ($sys in $p.known_systems) {
            $critColor = switch ($sys.criticality) {
                "critical" { "Red" }
                "high"     { "Yellow" }
                default    { "White" }
            }
            Write-Host "    - $($sys.name) " -NoNewline -ForegroundColor White
            Write-Host "[$($sys.criticality)]" -ForegroundColor $critColor
            Write-Host "      $($sys.type): $($sys.description)" -ForegroundColor Gray
        }
        Write-Host ""
    }

    if ($p.critical_roles) {
        Write-Host "  Critical Roles:" -ForegroundColor Gray
        foreach ($role in $p.critical_roles) {
            $patterns = ($role.title_patterns -join ", ")
            Write-Host "    - Patterns: $patterns" -ForegroundColor White
            Write-Host "      $($role.rationale)" -ForegroundColor Gray
        }
        Write-Host ""
    }

    if ($p.risk_domains) {
        Write-Host "  Risk Domains:" -ForegroundColor Gray
        foreach ($rd in $p.risk_domains) {
            $bar = "=" * [Math]::Floor($rd.weight * 20)
            Write-Host "    - $($rd.domain) " -NoNewline -ForegroundColor White
            Write-Host "[$bar] $($rd.weight)" -ForegroundColor Cyan
            Write-Host "      $($rd.description)" -ForegroundColor Gray
        }
        Write-Host ""
    }

    # ================================================================
    # Step 1.2 — Interactive Admin Review Dialog
    # ================================================================

    if (-not $SkipReview) {
        Write-Host "--- Step 2: Review & Refine ---" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Review the profile above. You can refine it by entering instructions below." -ForegroundColor Gray
        Write-Host "  The LLM will update the profile based on your feedback." -ForegroundColor Gray
        Write-Host ""
        Write-Host "  Examples:" -ForegroundColor Gray
        Write-Host "    - 'Add SAP S/4HANA as a critical system'" -ForegroundColor White
        Write-Host "    - 'We also have OT/SCADA systems for container cranes'" -ForegroundColor White
        Write-Host "    - 'Remove the HIPAA regulation, that does not apply'" -ForegroundColor White
        Write-Host "    - 'Add DBA and database administrator to critical roles'" -ForegroundColor White
        Write-Host ""
        Write-Host "  Type 'done' to save, 'show' to display the current profile, or 'cancel' to abort." -ForegroundColor Yellow
        Write-Host ""

        $refinementSystemPrompt = @"
You are helping an identity security administrator refine an organizational risk profile.

The current profile is provided below. The admin will give you instructions to modify it.
Apply their changes and return the COMPLETE updated profile as a valid JSON object.

IMPORTANT:
- Return ONLY the JSON object, no markdown fencing, no explanation
- Keep the same schema structure
- Apply the requested changes precisely
- Preserve all existing data that wasn't explicitly changed
- For title_patterns, always use case-insensitive regex patterns
- Include both English and local language variants for roles

Current profile:
$(($profile | ConvertTo-Json -Depth 100))
"@

        while ($true) {
            $input = Read-Host "  Refine"

            if ($input -eq 'done' -or $input -eq '') {
                Write-Host ""
                Write-Host "  Finalizing profile..." -ForegroundColor Green
                break
            }

            if ($input -eq 'cancel') {
                Write-Host ""
                Write-Host "  Cancelled. No profile saved." -ForegroundColor Yellow
                return $null
            }

            if ($input -eq 'show') {
                Write-Host ""
                Write-Host ($profile | ConvertTo-Json -Depth 100) -ForegroundColor Gray
                Write-Host ""
                continue
            }

            # Send refinement to LLM
            Write-Host "  Updating profile..." -ForegroundColor Gray

            try {
                $refinedResponse = Invoke-FGLLMRequest `
                    -Provider $LLMProvider `
                    -ApiKey $LLMApiKey `
                    -SystemPrompt $refinementSystemPrompt `
                    -UserPrompt $input `
                    -Model $LLMModel `
                    -MaxTokens 4096 `
                    -Temperature 0.2

                $jsonText = $refinedResponse -replace '(?s)^```json\s*', '' -replace '(?s)\s*```$', '' -replace '(?s)^```\s*', ''
                $updatedProfile = $jsonText | ConvertFrom-Json

                if (-not $updatedProfile.customer_profile) {
                    $updatedProfile = @{ customer_profile = $updatedProfile } | ConvertTo-Json -Depth 100 | ConvertFrom-Json
                }

                $profile = $updatedProfile

                # Update refinement system prompt with new profile
                $refinementSystemPrompt = @"
You are helping an identity security administrator refine an organizational risk profile.

The current profile is provided below. The admin will give you instructions to modify it.
Apply their changes and return the COMPLETE updated profile as a valid JSON object.

IMPORTANT:
- Return ONLY the JSON object, no markdown fencing, no explanation
- Keep the same schema structure
- Apply the requested changes precisely
- Preserve all existing data that wasn't explicitly changed
- For title_patterns, always use case-insensitive regex patterns
- Include both English and local language variants for roles

Current profile:
$(($profile | ConvertTo-Json -Depth 100))
"@

                Write-Host "  Profile updated." -ForegroundColor Green
                Write-Host ""
            }
            catch {
                Write-Host "  Failed to update: $_" -ForegroundColor Red
                Write-Host "  Profile unchanged. Try again or type 'done' to save current version." -ForegroundColor Yellow
                Write-Host ""
            }
        }
    }

    # ================================================================
    # Save the profile
    # ================================================================

    # Add metadata
    $profile.customer_profile | Add-Member -NotePropertyName "generated_at" -NotePropertyValue (Get-Date -Format "o") -Force
    $profile.customer_profile | Add-Member -NotePropertyName "generated_by" -NotePropertyValue "New-FGRiskProfile" -Force
    $profile.customer_profile | Add-Member -NotePropertyName "llm_provider" -NotePropertyValue $LLMProvider -Force

    # Save to SQL (primary storage)
    if ($global:FGSQLConnectionString) {
        try {
            Save-FGRiskProfile -RiskProfile $profile
        } catch {
            Write-Host "  WARNING: Could not save to SQL: $_" -ForegroundColor Yellow
        }
    }

    # Save to file (if output path was explicitly provided)
    if ($OutputPath) {
        $profileJson = $profile | ConvertTo-Json -Depth 100
        $profileJson | Set-Content -Path $OutputPath -Encoding UTF8
        Write-Host "  Risk profile also saved to: $OutputPath" -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "  Next step: Generate classifiers from this profile:" -ForegroundColor Gray
    Write-Host "    New-FGRiskClassifiers -ConfigFile `$configFile" -ForegroundColor White
    Write-Host ""

    return $profile
}
