function New-FGCorrelationRuleset {
    <#
    .SYNOPSIS
        Generates an account correlation ruleset for identifying accounts belonging to the same person.

    .DESCRIPTION
        Creates a structured ruleset that defines account type detection patterns and correlation
        signals, then saves it to SQL for use by Invoke-FGAccountCorrelation.

        Two modes:
        - Interactive (default): Uses an LLM to discover org-specific naming conventions from
          anonymized database patterns, then allows interactive refinement via dialog.
          IMPORTANT: Only structural patterns are sent to the LLM (e.g., "adm-" prefix used by
          12 accounts). No user names, email addresses, or other identity data is ever shared.
        - NoLLM (-NoLLM): Generates universal defaults merged with database-discovered patterns.
          No LLM needed, no interaction. Good for environments without LLM access or where
          any external API call is not desired.

        LLM settings are read from the RiskScoring section of the config file (same as
        New-FGRiskProfile and New-FGRiskClassifiers). If no LLM config exists in the config
        file, you will be prompted to add it.

        Connects to SQL for pattern sampling and to Graph API for provisioning app discovery
        (both auto-connect via ConfigFile if not already connected).

    .PARAMETER ConfigFile
        FortigiGraph config file. Used to connect to SQL and Graph API for discovery.
        Reads LLM settings from the RiskScoring section.

    .PARAMETER LLMProvider
        LLM provider: "Anthropic" or "OpenAI". Read from config if not specified.

    .PARAMETER LLMApiKey
        API key. Read from config (supports encrypted) or environment variable if not specified.

    .PARAMETER LLMModel
        Optional model override.

    .PARAMETER NoLLM
        Skip LLM: generate universal defaults + database-discovered patterns without LLM or interaction.

    .PARAMETER Id
        Identifier for the ruleset in SQL. Defaults to "default".

    .EXAMPLE
        # Interactive mode with LLM (reads LLM settings from config)
        New-FGCorrelationRuleset -ConfigFile .\Config\fortigi.json

    .EXAMPLE
        # No LLM  -  just universal defaults + database patterns
        New-FGCorrelationRuleset -ConfigFile .\Config\fortigi.json -NoLLM

    .EXAMPLE
        # Explicit LLM parameters
        New-FGCorrelationRuleset -LLMProvider Anthropic -LLMApiKey $env:ANTHROPIC_API_KEY
    #>
    [alias("New-CorrelationRuleset")]
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory = $false)]
        [System.String]$ConfigFile,

        [Parameter(Mandatory = $false)]
        [ValidateSet("Anthropic", "OpenAI")]
        [System.String]$LLMProvider = "Anthropic",

        [Parameter(Mandatory = $false)]
        [System.String]$LLMApiKey,

        [Parameter(Mandatory = $false)]
        [System.String]$LLMModel,

        [Parameter(Mandatory = $false)]
        [switch]$NoLLM,

        [Parameter(Mandatory = $false)]
        [string]$Id = "default"
    )

    # ================================================================
    # Configuration  -  read LLM settings from config
    # ================================================================

    if ($ConfigFile) {
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

            if (-not $PSBoundParameters.ContainsKey('LLMProvider') -and $llmConfig.$providerProp) {
                $LLMProvider = $llmConfig.$providerProp
            }
            if (-not $PSBoundParameters.ContainsKey('LLMModel') -and $llmConfig.$modelProp) {
                $LLMModel = $llmConfig.$modelProp
            }
            if (-not $PSBoundParameters.ContainsKey('LLMApiKey')) {
                if ($llmConfig.$keyProp) {
                    $LLMApiKey = $llmConfig.$keyProp
                } elseif ($llmConfig.$keyEncProp) {
                    $keyPath = if ($llmConfigPath -eq 'LLM') { "LLM.ApiKey" } else { "RiskScoring.LLMApiKey" }
                    $LLMApiKey = Get-FGSecureConfigValue -ConfigPath $ConfigFile -PropertyPath $keyPath -AllowEmpty
                }
            }
        } elseif (-not $NoLLM) {
            # No LLM section in config  -  prompt to add it
            Write-Host ""
            Write-Host "  No LLM configuration found in config file." -ForegroundColor Yellow
            Write-Host "  LLM mode uses an AI to discover org-specific naming patterns." -ForegroundColor Gray
            Write-Host "  Only anonymized structural patterns are sent (e.g. prefix counts, suffix counts)." -ForegroundColor Gray
            Write-Host "  No user names, emails, or identity data is ever shared with the LLM." -ForegroundColor Gray
            Write-Host ""
            $addLLM = Read-Host "  Would you like to add LLM configuration to your config file? (Y/N, default: N)"
            if ($addLLM -match '^[Yy]') {
                Write-Host ""
                Write-Host "  Supported providers: Anthropic (Claude), OpenAI (GPT)" -ForegroundColor Gray
                $providerInput = Read-Host "  LLM Provider (Anthropic/OpenAI, default: Anthropic)"
                if ($providerInput -match '^[Oo]') {
                    $LLMProvider = "OpenAI"
                } else {
                    $LLMProvider = "Anthropic"
                }

                $apiKeyInput = Read-Host "  API Key (will be encrypted in config)"
                if ([string]::IsNullOrWhiteSpace($apiKeyInput)) {
                    Write-Host "  No API key provided. Continuing without LLM." -ForegroundColor Yellow
                    $NoLLM = $true
                } else {
                    $LLMApiKey = $apiKeyInput.Trim()

                    # Add LLM section to config file (encrypt API key with DPAPI)
                    try {
                        $llmSection = [PSCustomObject]@{
                            Provider = $LLMProvider
                            Model    = ""
                        }
                        try {
                            $secureKey = ConvertTo-SecureString -String $LLMApiKey -AsPlainText -Force
                            $encryptedKey = $secureKey | ConvertFrom-SecureString
                            $llmSection | Add-Member -NotePropertyName "ApiKey_Encrypted" -NotePropertyValue $encryptedKey
                        } catch {
                            Write-Host "  Could not encrypt API key (DPAPI). Storing in plain text." -ForegroundColor Yellow
                            $llmSection | Add-Member -NotePropertyName "ApiKey" -NotePropertyValue $LLMApiKey
                        }
                        $config | Add-Member -NotePropertyName "LLM" -NotePropertyValue $llmSection -Force
                        $config | ConvertTo-Json -Depth 100 | Set-Content -Path $ConfigFile -Encoding UTF8
                        Write-Host "  LLM section added to config file (API key encrypted)." -ForegroundColor Green
                    } catch {
                        Write-Host "  Could not update config file: $_" -ForegroundColor Yellow
                        Write-Host "  Continuing with the provided API key for this session." -ForegroundColor Gray
                    }
                }
            } else {
                Write-Host "  Continuing without LLM. Using -NoLLM mode." -ForegroundColor Gray
                $NoLLM = $true
            }
        }
    }

    # Resolve LLM availability
    $useLLM = -not $NoLLM
    if ($useLLM -and [string]::IsNullOrWhiteSpace($LLMApiKey)) {
        $envVar = switch ($LLMProvider) {
            "Anthropic" { "ANTHROPIC_API_KEY" }
            "OpenAI"    { "OPENAI_API_KEY" }
        }
        $LLMApiKey = [System.Environment]::GetEnvironmentVariable($envVar)
        if ([string]::IsNullOrWhiteSpace($LLMApiKey)) {
            Write-Host "  No LLM API key available. Falling back to -NoLLM mode." -ForegroundColor Yellow
            Write-Host "  To use LLM mode, set -LLMApiKey, $envVar, or configure in config file RiskScoring section." -ForegroundColor Gray
            $useLLM = $false
        }
    }

    # Ensure SQL connection (for pattern sampling and saving)
    if ($global:FGSQLConnectionString) {
        try {
            $testConn = New-Object System.Data.SqlClient.SqlConnection($global:FGSQLConnectionString)
            $testConn.Open(); $testConn.Close(); $testConn.Dispose()
        } catch {
            Write-Host "  Existing SQL connection is stale, reconnecting..." -ForegroundColor Yellow
            $global:FGSQLConnectionString = $null
        }
    }
    if (-not $global:FGSQLConnectionString -and $ConfigFile) {
        Connect-FGSQLServer -ConfigFile $ConfigFile
    }

    # Ensure Graph API connection (for provisioning app discovery)
    if (-not $global:AccessToken -and $ConfigFile) {
        try {
            Write-Host "  Connecting to Graph API via config file..." -ForegroundColor Gray
            Get-FGAccessToken -ConfigFile $ConfigFile
        } catch {
            Write-Host "  Could not connect to Graph API: $_" -ForegroundColor Yellow
            Write-Host "  Provisioning app discovery will be skipped." -ForegroundColor Gray
        }
    }

    # ================================================================
    # Start
    # ================================================================

    Write-Host ""
    Write-Host "=== Account Correlation Ruleset Generation ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Mode:     $(if ($useLLM) { "Interactive ($LLMProvider LLM)" } else { 'NoLLM (universal defaults + database patterns)' })" -ForegroundColor Gray
    if ($useLLM) {
        Write-Host "  Privacy:  Only anonymized structural patterns are sent to the LLM." -ForegroundColor Gray
        Write-Host "            No user names, email addresses, or identity data is shared." -ForegroundColor Gray
    }
    Write-Host ""

    # ================================================================
    # Universal Default Patterns (always included as baseline)
    # ================================================================

    $accountTypeRules = @(
        [ordered]@{
            type        = "Admin"
            description = "Privileged/administrative accounts"
            upnPrefixes = @('adm-', 'adm.', 'admin-', 'admin.', 'a-', 'a.', 'priv-', 'priv.', 'pam-', 'pam.', 'tier0-', 'tier1-', 'tier2-')
            upnSuffixes = @('-adm', '.adm', '-admin', '.admin', '-a', '.a', '-priv', '.priv', '-pam', '.pam', '-t0', '-t1', '-t2')
            samPrefixes = @('adm-', 'adm_', 'admin-', 'admin_', 'a-', 'a_', 'priv-', 'priv_', 'pam-', 'pam_')
            samSuffixes = @('-adm', '_adm', '-admin', '_admin', '-a', '_a', '-priv', '_priv', '-pam', '_pam')
            displayNamePatterns = @('\(Admin[^)]*\)', '\(Adm[^)]*\)', '\(ADM[^)]*\)', '\(Privileged\)', '\(PAM\)', '\(T0\)', '\(T1\)', '\(T2\)', '^ADM-', '^Admin-')
            priority    = 1
        }
        [ordered]@{
            type        = "Service"
            description = "Service accounts and application identities"
            upnPrefixes = @('svc-', 'svc.', 'service-', 'service.', 'sa-', 'sa.', 'app-', 'app.', 'sys-', 'sys.')
            upnSuffixes = @('-svc', '.svc', '-service', '.service', '-sa', '.sa')
            samPrefixes = @('svc-', 'svc_', 'service-', 'service_', 'sa-', 'sa_', 'app-', 'app_', 'sys-', 'sys_')
            samSuffixes = @('-svc', '_svc', '-service', '_service', '-sa', '_sa')
            displayNamePatterns = @('\(Service[^)]*\)', '\(Svc[^)]*\)', '\(SVC[^)]*\)', '\(Service Account\)', '\(SA\)', '^SVC-', '^Service-')
            priority    = 2
        }
        [ordered]@{
            type        = "Test"
            description = "Test and development accounts"
            upnPrefixes = @('test-', 'test.', 'tst-', 'tst.', 't-', 'dev-', 'dev.', 'demo-', 'demo.')
            upnSuffixes = @('-test', '.test', '-tst', '.tst', '-dev', '.dev', '-demo', '.demo')
            samPrefixes = @('test-', 'test_', 'tst-', 'tst_', 't-', 'dev-', 'dev_', 'demo-', 'demo_')
            samSuffixes = @('-test', '_test', '-tst', '_tst', '-dev', '_dev', '-demo', '_demo')
            displayNamePatterns = @('\(Test[^)]*\)', '\(Tst[^)]*\)', '\(Dev[^)]*\)', '\(Demo[^)]*\)', '\(Development\)', '^TEST-', '^Test-')
            priority    = 3
        }
        [ordered]@{
            type        = "Shared"
            description = "Shared mailboxes, room accounts, and equipment"
            upnPrefixes = @('shared-', 'shared.', 'room-', 'room.', 'conf-', 'conf.', 'equip-', 'equip.', 'noreply-', 'noreply.', 'info@', 'support@')
            upnSuffixes = @('-shared', '.shared', '-room', '.room', '-noreply', '.noreply')
            samPrefixes = @('shared-', 'shared_', 'room-', 'room_', 'conf-', 'conf_', 'equip-', 'equip_')
            samSuffixes = @('-shared', '_shared', '-room', '_room')
            displayNamePatterns = @('\(Shared\)', '\(Room\)', '\(Conference\)', '\(Equipment\)', '\(Mailbox\)')
            priority    = 4
        }
        [ordered]@{
            type        = "External"
            description = "Guest and external accounts"
            upnPrefixes = @()
            upnSuffixes = @()
            samPrefixes = @()
            samSuffixes = @()
            displayNamePatterns = @('#EXT#')
            upnPatterns = @('#EXT#@')
            priority    = 5
        }
    )

    # ================================================================
    # Step 1: Sample naming patterns from database
    # ================================================================

    $sampledPatterns = $null

    if ($global:FGSQLConnectionString) {
        Write-Host "--- Step 1: Sampling Account Naming Patterns from Database ---" -ForegroundColor Cyan
        Write-Host "  Extracting anonymized UPN/SAM structure patterns..." -ForegroundColor Gray

        try {
            $sampledPatterns = Invoke-FGSQLCommand -ScriptBlock {
                param($connection)

                $results = @{
                    upnPrefixPatterns   = @()
                    upnSuffixPatterns   = @()
                    samPrefixPatterns   = @()
                    displayNameSuffixes = @()
                    domainParts         = @()
                    totalUsers          = 0
                }

                $cmd = $connection.CreateCommand()
                $cmd.CommandTimeout = 30
                $cmd.CommandText = "SELECT COUNT(*) FROM dbo.GraphUsers"
                $results.totalUsers = [int]$cmd.ExecuteScalar()

                # UPN prefixes: extract the part before the first separator (-, .) up to 8 chars
                $cmd = $connection.CreateCommand()
                $cmd.CommandTimeout = 60
                $cmd.CommandText = @"
                    SELECT prefix, COUNT(*) AS cnt FROM (
                        SELECT
                            CASE
                                WHEN CHARINDEX('-', LEFT(userPrincipalName, CHARINDEX('@', userPrincipalName + '@') - 1)) > 0
                                    THEN LOWER(LEFT(LEFT(userPrincipalName, CHARINDEX('@', userPrincipalName + '@') - 1),
                                         CHARINDEX('-', LEFT(userPrincipalName, CHARINDEX('@', userPrincipalName + '@') - 1))))
                                WHEN CHARINDEX('.', LEFT(userPrincipalName, CHARINDEX('@', userPrincipalName + '@') - 1)) > 0
                                    AND LEN(LEFT(LEFT(userPrincipalName, CHARINDEX('@', userPrincipalName + '@') - 1),
                                        CHARINDEX('.', LEFT(userPrincipalName, CHARINDEX('@', userPrincipalName + '@') - 1)))) <= 8
                                    THEN LOWER(LEFT(LEFT(userPrincipalName, CHARINDEX('@', userPrincipalName + '@') - 1),
                                         CHARINDEX('.', LEFT(userPrincipalName, CHARINDEX('@', userPrincipalName + '@') - 1))))
                                ELSE NULL
                            END AS prefix
                        FROM dbo.GraphUsers
                        WHERE userPrincipalName IS NOT NULL
                    ) sub
                    WHERE prefix IS NOT NULL AND LEN(prefix) BETWEEN 2 AND 8
                    GROUP BY prefix
                    HAVING COUNT(*) >= 2
                    ORDER BY cnt DESC
"@
                $reader = $cmd.ExecuteReader()
                while ($reader.Read()) {
                    $results.upnPrefixPatterns += @{ pattern = $reader.GetString(0); count = $reader.GetInt32(1) }
                }
                $reader.Close()

                # UPN suffixes (after last separator before @)
                $cmd = $connection.CreateCommand()
                $cmd.CommandTimeout = 60
                $cmd.CommandText = @"
                    SELECT suffix, COUNT(*) AS cnt FROM (
                        SELECT
                            CASE
                                WHEN CHARINDEX('-', REVERSE(LEFT(userPrincipalName, CHARINDEX('@', userPrincipalName + '@') - 1))) > 0
                                    THEN LOWER(RIGHT(LEFT(userPrincipalName, CHARINDEX('@', userPrincipalName + '@') - 1),
                                         CHARINDEX('-', REVERSE(LEFT(userPrincipalName, CHARINDEX('@', userPrincipalName + '@') - 1)))))
                                ELSE NULL
                            END AS suffix
                        FROM dbo.GraphUsers
                        WHERE userPrincipalName IS NOT NULL
                    ) sub
                    WHERE suffix IS NOT NULL AND LEN(suffix) BETWEEN 2 AND 10
                    GROUP BY suffix
                    HAVING COUNT(*) >= 2
                    ORDER BY cnt DESC
"@
                $reader = $cmd.ExecuteReader()
                while ($reader.Read()) {
                    $results.upnSuffixPatterns += @{ pattern = $reader.GetString(0); count = $reader.GetInt32(1) }
                }
                $reader.Close()

                # SAM prefix patterns
                $cmd = $connection.CreateCommand()
                $cmd.CommandTimeout = 60
                $cmd.CommandText = @"
                    SELECT prefix, COUNT(*) AS cnt FROM (
                        SELECT
                            CASE
                                WHEN CHARINDEX('-', onPremisesSamAccountName) > 0 AND CHARINDEX('-', onPremisesSamAccountName) <= 8
                                    THEN LOWER(LEFT(onPremisesSamAccountName, CHARINDEX('-', onPremisesSamAccountName)))
                                WHEN CHARINDEX('_', onPremisesSamAccountName) > 0 AND CHARINDEX('_', onPremisesSamAccountName) <= 8
                                    THEN LOWER(LEFT(onPremisesSamAccountName, CHARINDEX('_', onPremisesSamAccountName)))
                                ELSE NULL
                            END AS prefix
                        FROM dbo.GraphUsers
                        WHERE onPremisesSamAccountName IS NOT NULL
                    ) sub
                    WHERE prefix IS NOT NULL AND LEN(prefix) BETWEEN 2 AND 8
                    GROUP BY prefix
                    HAVING COUNT(*) >= 2
                    ORDER BY cnt DESC
"@
                $reader = $cmd.ExecuteReader()
                while ($reader.Read()) {
                    $results.samPrefixPatterns += @{ pattern = $reader.GetString(0); count = $reader.GetInt32(1) }
                }
                $reader.Close()

                # Display name suffixes in parentheses
                $cmd = $connection.CreateCommand()
                $cmd.CommandTimeout = 60
                $cmd.CommandText = @"
                    SELECT suffix, COUNT(*) AS cnt FROM (
                        SELECT
                            CASE
                                WHEN displayName LIKE '%(%)'
                                    THEN SUBSTRING(displayName, LEN(displayName) - CHARINDEX('(', REVERSE(displayName)) + 1,
                                         CHARINDEX('(', REVERSE(displayName)))
                                ELSE NULL
                            END AS suffix
                        FROM dbo.GraphUsers
                        WHERE displayName IS NOT NULL
                    ) sub
                    WHERE suffix IS NOT NULL AND LEN(suffix) BETWEEN 3 AND 30
                    GROUP BY suffix
                    HAVING COUNT(*) >= 2
                    ORDER BY cnt DESC
"@
                $reader = $cmd.ExecuteReader()
                while ($reader.Read()) {
                    $results.displayNameSuffixes += @{ pattern = $reader.GetString(0); count = $reader.GetInt32(1) }
                }
                $reader.Close()

                # UPN domains
                $cmd = $connection.CreateCommand()
                $cmd.CommandTimeout = 30
                $cmd.CommandText = @"
                    SELECT domain, COUNT(*) AS cnt FROM (
                        SELECT LOWER(SUBSTRING(userPrincipalName, CHARINDEX('@', userPrincipalName) + 1, 200)) AS domain
                        FROM dbo.GraphUsers
                        WHERE userPrincipalName IS NOT NULL AND CHARINDEX('@', userPrincipalName) > 0
                    ) sub
                    GROUP BY domain ORDER BY cnt DESC
"@
                $reader = $cmd.ExecuteReader()
                while ($reader.Read()) {
                    $results.domainParts += @{ domain = $reader.GetString(0); count = $reader.GetInt32(1) }
                }
                $reader.Close()

                return $results
            }

            Write-Host "  Total users: $($sampledPatterns.totalUsers)" -ForegroundColor Gray
            if ($sampledPatterns.upnPrefixPatterns.Count -gt 0) {
                Write-Host "  UPN prefixes ($($sampledPatterns.upnPrefixPatterns.Count)):" -ForegroundColor Gray
                foreach ($p in $sampledPatterns.upnPrefixPatterns | Select-Object -First 10) {
                    Write-Host "    '$($p.pattern)' ($($p.count) accounts)" -ForegroundColor White
                }
            }
            if ($sampledPatterns.upnSuffixPatterns.Count -gt 0) {
                Write-Host "  UPN suffixes ($($sampledPatterns.upnSuffixPatterns.Count)):" -ForegroundColor Gray
                foreach ($p in $sampledPatterns.upnSuffixPatterns | Select-Object -First 10) {
                    Write-Host "    '$($p.pattern)' ($($p.count) accounts)" -ForegroundColor White
                }
            }
            if ($sampledPatterns.samPrefixPatterns.Count -gt 0) {
                Write-Host "  SAM prefixes ($($sampledPatterns.samPrefixPatterns.Count)):" -ForegroundColor Gray
                foreach ($p in $sampledPatterns.samPrefixPatterns | Select-Object -First 10) {
                    Write-Host "    '$($p.pattern)' ($($p.count) accounts)" -ForegroundColor White
                }
            }
            if ($sampledPatterns.displayNameSuffixes.Count -gt 0) {
                Write-Host "  Display name suffixes ($($sampledPatterns.displayNameSuffixes.Count)):" -ForegroundColor Gray
                foreach ($p in $sampledPatterns.displayNameSuffixes | Select-Object -First 10) {
                    Write-Host "    '$($p.pattern)' ($($p.count) accounts)" -ForegroundColor White
                }
            }
            Write-Host ""
        } catch {
            Write-Host "  Could not sample from database: $_" -ForegroundColor Yellow
            Write-Host ""
        }
    } else {
        Write-Host "  No SQL connection  -  skipping database pattern sampling." -ForegroundColor Gray
        Write-Host ""
    }

    # ================================================================
    # Step 1b: HR Source Configuration
    # ================================================================
    Write-Host ""
    Write-Host "--- Step 1b: HR Source Configuration ---" -ForegroundColor Cyan

    $hrDiscovery = $null
    $hrSourceConfig = $null
    $hrProvisioningApps = @()
    $skipHrDiscovery = $false

    # Ask the user first  -  most admins know their environment
    Write-Host ""
    Write-Host "  Account correlation works best when we can identify which accounts are" -ForegroundColor Gray
    Write-Host "  managed by HR (e.g., provisioned from Workday, SuccessFactors, or on-prem AD)." -ForegroundColor Gray
    Write-Host "  HR-managed accounts become identity anchors that other accounts correlate to." -ForegroundColor Gray
    Write-Host ""
    Write-Host "  [Y] Yes, we have HR sync and I know how to identify HR-managed accounts" -ForegroundColor White
    Write-Host "  [D] Not sure  -  run discovery to analyze user attributes automatically" -ForegroundColor White
    Write-Host "  [N] No HR sync  -  use symmetric matching (fuzzy name-based correlation only)" -ForegroundColor White
    Write-Host ""
    $hrChoice = Read-Host "  Do you have an HR sync to Entra ID? (Y/D/N, default: D)"

    if ($hrChoice -match '^[Yy]') {
        # ---- User knows their HR setup  -  guided attribute selection ----
        Write-Host ""
        Write-Host "  Let's identify HR-managed accounts step by step." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Is there a specific user attribute that reliably identifies HR-managed accounts?" -ForegroundColor Yellow
        Write-Host "  This could be:" -ForegroundColor Gray
        Write-Host "    - A boolean extension attribute (e.g., extension_abc123_sfFromHR = true)" -ForegroundColor Gray
        Write-Host "    - An employeeType value (e.g., 'Employee' or 'Intern')" -ForegroundColor Gray
        Write-Host "    - An employeeId being populated (HR-managed users always have one)" -ForegroundColor Gray
        Write-Host "    - Any other attribute/value combination" -ForegroundColor Gray
        Write-Host ""

        # Step 1: Get the attribute name
        Write-Host "  What is the attribute name?" -ForegroundColor Yellow
        Write-Host "    [1] employeeId (populated = HR-managed)" -ForegroundColor White
        Write-Host "    [2] employeeType" -ForegroundColor White
        Write-Host "    [3] companyName" -ForegroundColor White
        Write-Host "    [4] department" -ForegroundColor White
        Write-Host "    [5] onPremisesSyncEnabled" -ForegroundColor White
        Write-Host "    [6] Other (type the full attribute name)" -ForegroundColor White
        Write-Host ""
        $attrChoice = Read-Host "  Select (1-6)"

        $hrAttrName = $null
        $hrAttrCondition = $null
        $hrAttrValue = $null

        switch ($attrChoice) {
            "1" {
                $hrAttrName = "employeeId"
                $hrAttrCondition = "isNotNull"
                Write-Host "  Using: employeeId IS NOT NULL (populated = HR-managed)" -ForegroundColor Green
            }
            "2" { $hrAttrName = "employeeType" }
            "3" { $hrAttrName = "companyName" }
            "4" { $hrAttrName = "department" }
            "5" {
                $hrAttrName = "onPremisesSyncEnabled"
                $hrAttrCondition = "equals"
                $hrAttrValue = "True"
                Write-Host "  Using: onPremisesSyncEnabled = 'True'" -ForegroundColor Green
            }
            "6" {
                $customName = Read-Host "  Attribute name (e.g., extension_abc123_sfFromHR)"
                $hrAttrName = $customName.Trim()
            }
            default {
                $customName = Read-Host "  Attribute name (e.g., extension_abc123_sfFromHR)"
                $hrAttrName = $customName.Trim()
            }
        }

        # Step 2: Get the condition/value if not already set
        if ($hrAttrName -and -not $hrAttrCondition) {
            Write-Host ""
            Write-Host "  How should we match on '$hrAttrName'?" -ForegroundColor Yellow
            Write-Host "    [1] Equals a specific value (e.g., 'true', 'Employee')" -ForegroundColor White
            Write-Host "    [2] Is not null/empty (attribute is populated = HR-managed)" -ForegroundColor White
            Write-Host "    [3] Contains one of several values (e.g., 'Employee', 'Intern', 'Contractor')" -ForegroundColor White
            Write-Host ""
            $condChoice = Read-Host "  Select (1-3, default: 1)"

            switch ($condChoice) {
                "2" {
                    $hrAttrCondition = "isNotNull"
                    Write-Host "  Using: $hrAttrName IS NOT NULL" -ForegroundColor Green
                }
                "3" {
                    $hrAttrCondition = "inValues"
                    $valuesInput = Read-Host "  Enter values (comma-separated, e.g., Employee,Intern,Contractor)"
                    $hrAttrValue = @($valuesInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    Write-Host "  Using: $hrAttrName IN ($($hrAttrValue -join ', '))" -ForegroundColor Green
                }
                default {
                    $hrAttrCondition = "equals"
                    $valueInput = Read-Host "  What value identifies HR-managed accounts? (e.g., true, Employee)"
                    $hrAttrValue = $valueInput.Trim()
                    Write-Host "  Using: $hrAttrName = '$hrAttrValue'" -ForegroundColor Green
                }
            }
        }

        # Step 3: Ask confidence level
        if ($hrAttrName) {
            Write-Host ""
            Write-Host "  How confident are you that this attribute reliably identifies HR-managed accounts?" -ForegroundColor Yellow
            Write-Host "    [1] 100% certain - this is authoritative (e.g., HR provisioning sets a boolean)" -ForegroundColor White
            Write-Host "    [2] Very confident (90%) - some edge cases may exist" -ForegroundColor White
            Write-Host "    [3] Fairly confident (75%) - mostly reliable but not perfect" -ForegroundColor White
            Write-Host "    [4] Not very sure (50%) - let's also run discovery to find more signals" -ForegroundColor White
            Write-Host ""
            $confChoice = Read-Host "  Select (1-4, default: 2)"

            $hrConfidence = switch ($confChoice) {
                "1" { 100 }
                "3" { 75 }
                "4" { 50 }
                default { 90 }
            }

            # Validate the attribute exists in the database and check coverage
            $hrAttrCoverage = 0
            if ($global:FGSQLConnectionString) {
                try {
                    $validationResult = Invoke-FGSQLCommand -ScriptBlock {
                        param($connection)

                        # Check if column exists
                        $cmd = $connection.CreateCommand()
                        $cmd.CommandTimeout = 30
                        $cmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'GraphUsers' AND TABLE_SCHEMA = 'dbo' AND COLUMN_NAME = @ColName"
                        $cmd.Parameters.AddWithValue("@ColName", $hrAttrName) | Out-Null
                        $colExists = [int]$cmd.ExecuteScalar() -gt 0

                        if (-not $colExists) {
                            return @{ exists = $false; total = 0; matches = 0 }
                        }

                        # Count total users
                        $cmd = $connection.CreateCommand()
                        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.GraphUsers"
                        $totalUsers = [int]$cmd.ExecuteScalar()

                        # Count matching users
                        $cmd = $connection.CreateCommand()
                        if ($hrAttrCondition -eq 'isNotNull') {
                            $cmd.CommandText = "SELECT COUNT(*) FROM dbo.GraphUsers WHERE [$hrAttrName] IS NOT NULL AND CAST([$hrAttrName] AS NVARCHAR(MAX)) <> ''"
                        } elseif ($hrAttrCondition -eq 'equals') {
                            $cmd.CommandText = "SELECT COUNT(*) FROM dbo.GraphUsers WHERE CAST([$hrAttrName] AS NVARCHAR(MAX)) = @Val"
                            $cmd.Parameters.AddWithValue("@Val", $hrAttrValue) | Out-Null
                        } elseif ($hrAttrCondition -eq 'inValues') {
                            # Build parameterized IN clause
                            $inParams = @()
                            for ($i = 0; $i -lt $hrAttrValue.Count; $i++) {
                                $paramName = "@V$i"
                                $inParams += $paramName
                                $cmd.Parameters.AddWithValue($paramName, $hrAttrValue[$i]) | Out-Null
                            }
                            $cmd.CommandText = "SELECT COUNT(*) FROM dbo.GraphUsers WHERE CAST([$hrAttrName] AS NVARCHAR(MAX)) IN ($($inParams -join ','))"
                        }
                        $matchCount = [int]$cmd.ExecuteScalar()

                        return @{ exists = $true; total = $totalUsers; matches = $matchCount }
                    }

                    if (-not $validationResult.exists) {
                        Write-Host ""
                        Write-Host "  WARNING: Column '$hrAttrName' does not exist in GraphUsers table." -ForegroundColor Red
                        Write-Host "  Make sure this attribute is included in your user sync (AdditionalAttributes)." -ForegroundColor Yellow
                        Write-Host "  The attribute will still be saved in the ruleset for future use." -ForegroundColor Gray
                    } elseif ($validationResult.total -gt 0) {
                        $hrAttrCoverage = [math]::Round($validationResult.matches / $validationResult.total * 100, 1)
                        Write-Host ""
                        Write-Host "  Validation: $($validationResult.matches) of $($validationResult.total) users match ($hrAttrCoverage%)" -ForegroundColor $(if ($hrAttrCoverage -gt 20) { 'Green' } elseif ($hrAttrCoverage -gt 5) { 'Yellow' } else { 'Red' })

                        if ($hrAttrCoverage -lt 5) {
                            Write-Host "  Very low coverage  -  are you sure this is the right attribute?" -ForegroundColor Yellow
                        }
                    }
                } catch {
                    Write-Host "  Could not validate attribute: $_" -ForegroundColor Yellow
                }
            }

            # Build HR source config from user input
            $hrIndicator = [ordered]@{
                id          = "userDefinedHrAttribute"
                attribute   = $hrAttrName
                condition   = $hrAttrCondition
                weight      = if ($hrConfidence -ge 90) { 5 } elseif ($hrConfidence -ge 75) { 3 } else { 2 }
                confidence  = $hrConfidence
                coverage    = $hrAttrCoverage
            }
            if ($hrAttrValue -and $hrAttrCondition -eq 'equals') {
                $hrIndicator.value = $hrAttrValue
            } elseif ($hrAttrValue -and $hrAttrCondition -eq 'inValues') {
                $hrIndicator.values = $hrAttrValue
            }

            $hrSourceConfig = [ordered]@{
                enabled          = $true
                description      = "HR-authoritative account detection (user-defined: $hrAttrName)"
                indicators       = @($hrIndicator)
                minimumScore     = 1
                provisioningApps = @()
                orphanDetection  = [ordered]@{
                    enabled                = $true
                    stalenessThresholdDays = 90
                }
            }

            Write-Host ""
            Write-Host "  HR anchoring configured:" -ForegroundColor Green
            $attrValueDisplay = if ($hrAttrValue) { " = $hrAttrValue" } else { "" }
            Write-Host "    Attribute: $hrAttrName ($hrAttrCondition$attrValueDisplay)" -ForegroundColor White
            Write-Host "    Confidence: $hrConfidence%" -ForegroundColor White
            Write-Host "    Coverage: $hrAttrCoverage%" -ForegroundColor White

            # If confidence is low, also run discovery for additional signals
            if ($hrConfidence -le 50) {
                Write-Host ""
                Write-Host "  Since confidence is moderate, running additional discovery..." -ForegroundColor Yellow
                $skipHrDiscovery = $false
            } else {
                $skipHrDiscovery = $true

                # Ask about staleness threshold
                Write-Host ""
                $staleInput = Read-Host "  Orphan staleness threshold in days (default: 90)"
                if ($staleInput.Trim() -and $staleInput.Trim() -match '^\d+$') {
                    $hrSourceConfig.orphanDetection.stalenessThresholdDays = [int]$staleInput.Trim()
                }
            }
        }

    } elseif ($hrChoice -match '^[Nn]') {
        # ---- No HR sync  -  skip everything ----
        $skipHrDiscovery = $true
        Write-Host ""
        Write-Host "  No HR sync. Correlation will use symmetric matching (name-based only)." -ForegroundColor Gray
        Write-Host ""
    } else {
        # ---- Discovery mode (default)  -  auto-detect HR indicators ----
        $skipHrDiscovery = $false
    }

    # ---- Auto-discovery of HR indicators (if not skipped) ----
    if (-not $skipHrDiscovery -and $global:FGSQLConnectionString) {
        Write-Host ""
        Write-Host "  Running HR indicator discovery..." -ForegroundColor Cyan

        try {
            $hrDiscovery = Invoke-FGSQLCommand -ScriptBlock {
                param($connection)
                $results = [ordered]@{
                    totalUsers          = 0
                    employeeIdCount     = 0
                    employeeTypeValues  = @()
                    onPremSyncCount     = 0
                    onPremNotSyncCount  = 0
                    ouPatterns          = @()
                    managedByHrCombo    = 0
                    managerIdCount      = 0
                    companyNameCount    = 0
                    employeeHireDateCount = 0
                    hasColumns          = @{}
                }

                # Check which columns exist
                $cmd = $connection.CreateCommand()
                $cmd.CommandTimeout = 30
                $cmd.CommandText = "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'GraphUsers' AND TABLE_SCHEMA = 'dbo'"
                $reader = $cmd.ExecuteReader()
                $existingCols = @()
                while ($reader.Read()) { $existingCols += $reader.GetString(0) }
                $reader.Close()

                foreach ($col in @('employeeId', 'employeeType', 'onPremisesSyncEnabled', 'onPremisesDistinguishedName', 'managerId', 'companyName', 'employeeHireDate', 'department', 'jobTitle')) {
                    $results.hasColumns[$col] = $col -in $existingCols
                }

                $cmd = $connection.CreateCommand()
                $cmd.CommandText = "SELECT COUNT(*) FROM dbo.GraphUsers"
                $results.totalUsers = [int]$cmd.ExecuteScalar()

                if ($results.hasColumns['employeeId']) {
                    $cmd = $connection.CreateCommand()
                    $cmd.CommandText = "SELECT COUNT(*) FROM dbo.GraphUsers WHERE employeeId IS NOT NULL AND employeeId <> ''"
                    $results.employeeIdCount = [int]$cmd.ExecuteScalar()
                }

                if ($results.hasColumns['employeeType']) {
                    $cmd = $connection.CreateCommand()
                    $cmd.CommandText = "SELECT employeeType, COUNT(*) AS cnt FROM dbo.GraphUsers WHERE employeeType IS NOT NULL AND employeeType <> '' GROUP BY employeeType ORDER BY cnt DESC"
                    $reader = $cmd.ExecuteReader()
                    while ($reader.Read()) {
                        $results.employeeTypeValues += @{ value = $reader.GetString(0); count = $reader.GetInt32(1) }
                    }
                    $reader.Close()
                }

                if ($results.hasColumns['onPremisesSyncEnabled']) {
                    $cmd = $connection.CreateCommand()
                    $cmd.CommandText = "SELECT COUNT(*) FROM dbo.GraphUsers WHERE onPremisesSyncEnabled = 'True'"
                    $results.onPremSyncCount = [int]$cmd.ExecuteScalar()
                    $cmd = $connection.CreateCommand()
                    $cmd.CommandText = "SELECT COUNT(*) FROM dbo.GraphUsers WHERE onPremisesSyncEnabled IS NULL OR onPremisesSyncEnabled <> 'True'"
                    $results.onPremNotSyncCount = [int]$cmd.ExecuteScalar()
                }

                if ($results.hasColumns['onPremisesDistinguishedName']) {
                    $cmd = $connection.CreateCommand()
                    $cmd.CommandTimeout = 60
                    $cmd.CommandText = @"
                        SELECT ouPath, COUNT(*) AS cnt FROM (
                            SELECT
                                CASE
                                    WHEN onPremisesDistinguishedName IS NOT NULL AND CHARINDEX('OU=', onPremisesDistinguishedName) > 0
                                        THEN SUBSTRING(onPremisesDistinguishedName, CHARINDEX('OU=', onPremisesDistinguishedName), LEN(onPremisesDistinguishedName))
                                    ELSE NULL
                                END AS ouPath
                            FROM dbo.GraphUsers
                        ) sub
                        WHERE ouPath IS NOT NULL
                        GROUP BY ouPath
                        HAVING COUNT(*) >= 3
                        ORDER BY cnt DESC
"@
                    $reader = $cmd.ExecuteReader()
                    while ($reader.Read()) {
                        $results.ouPatterns += @{ path = $reader.GetString(0); count = $reader.GetInt32(1) }
                    }
                    $reader.Close()
                }

                if ($results.hasColumns['managerId']) {
                    $cmd = $connection.CreateCommand()
                    $cmd.CommandText = "SELECT COUNT(*) FROM dbo.GraphUsers WHERE managerId IS NOT NULL AND CAST(managerId AS NVARCHAR(36)) <> ''"
                    $results.managerIdCount = [int]$cmd.ExecuteScalar()
                }

                if ($results.hasColumns['companyName']) {
                    $cmd = $connection.CreateCommand()
                    $cmd.CommandText = "SELECT COUNT(*) FROM dbo.GraphUsers WHERE companyName IS NOT NULL AND companyName <> ''"
                    $results.companyNameCount = [int]$cmd.ExecuteScalar()
                }

                if ($results.hasColumns['employeeHireDate']) {
                    $cmd = $connection.CreateCommand()
                    $cmd.CommandText = "SELECT COUNT(*) FROM dbo.GraphUsers WHERE employeeHireDate IS NOT NULL"
                    $results.employeeHireDateCount = [int]$cmd.ExecuteScalar()
                }

                if ($results.hasColumns['employeeId'] -and $results.hasColumns['managerId']) {
                    $cmd = $connection.CreateCommand()
                    $cmd.CommandText = "SELECT COUNT(*) FROM dbo.GraphUsers WHERE employeeId IS NOT NULL AND employeeId <> '' AND managerId IS NOT NULL AND CAST(managerId AS NVARCHAR(36)) <> ''"
                    $results.managedByHrCombo = [int]$cmd.ExecuteScalar()
                }

                return $results
            }

            # Display HR indicator statistics
            $total = $hrDiscovery.totalUsers
            if ($total -gt 0) {
                Write-Host "  HR Indicator Statistics (out of $total users):" -ForegroundColor Gray
                if ($hrDiscovery.hasColumns['employeeId']) {
                    $pct = [math]::Round($hrDiscovery.employeeIdCount / $total * 100, 1)
                    $color = if ($pct -gt 30) { 'Green' } elseif ($pct -gt 10) { 'Yellow' } else { 'Gray' }
                    Write-Host "    employeeId populated:       $($hrDiscovery.employeeIdCount) ($pct%)" -ForegroundColor $color
                }
                if ($hrDiscovery.employeeTypeValues.Count -gt 0) {
                    Write-Host "    employeeType values:" -ForegroundColor Gray
                    foreach ($et in $hrDiscovery.employeeTypeValues | Select-Object -First 5) {
                        Write-Host "      '$($et.value)'  -  $($et.count) accounts" -ForegroundColor White
                    }
                }
                if ($hrDiscovery.hasColumns['onPremisesSyncEnabled']) {
                    $syncPct = [math]::Round($hrDiscovery.onPremSyncCount / $total * 100, 1)
                    Write-Host "    onPremisesSyncEnabled:      $($hrDiscovery.onPremSyncCount) synced ($syncPct%), $($hrDiscovery.onPremNotSyncCount) cloud-only" -ForegroundColor Gray
                }
                if ($hrDiscovery.ouPatterns.Count -gt 0) {
                    Write-Host "    OU patterns (top 5):" -ForegroundColor Gray
                    foreach ($ou in $hrDiscovery.ouPatterns | Select-Object -First 5) {
                        Write-Host "      $($ou.path)  -  $($ou.count) accounts" -ForegroundColor White
                    }
                }
                if ($hrDiscovery.hasColumns['managerId']) {
                    $mgrPct = [math]::Round($hrDiscovery.managerIdCount / $total * 100, 1)
                    Write-Host "    managerId populated:        $($hrDiscovery.managerIdCount) ($mgrPct%)" -ForegroundColor Gray
                }
                if ($hrDiscovery.hasColumns['companyName']) {
                    $coPct = [math]::Round($hrDiscovery.companyNameCount / $total * 100, 1)
                    Write-Host "    companyName populated:      $($hrDiscovery.companyNameCount) ($coPct%)" -ForegroundColor Gray
                }
                if ($hrDiscovery.hasColumns['employeeHireDate']) {
                    $hirePct = [math]::Round($hrDiscovery.employeeHireDateCount / $total * 100, 1)
                    Write-Host "    employeeHireDate populated: $($hrDiscovery.employeeHireDateCount) ($hirePct%)" -ForegroundColor Gray
                }
                if ($hrDiscovery.managedByHrCombo -gt 0) {
                    $comboPct = [math]::Round($hrDiscovery.managedByHrCombo / $total * 100, 1)
                    Write-Host "    employeeId + managerId:     $($hrDiscovery.managedByHrCombo) ($comboPct%)  -  strong HR signal" -ForegroundColor Green
                }
                Write-Host ""
            }
        } catch {
            Write-Host "  Could not sample HR indicators: $_" -ForegroundColor Yellow
            Write-Host ""
        }

        # Discover HR provisioning apps via Graph API
        if ($global:AccessToken) {
            try {
                Write-Host "  Checking for HR provisioning apps in Entra ID..." -ForegroundColor Gray
                $syncApps = Get-FGServicePrincipalWithSync -IncludeJobs -ErrorAction SilentlyContinue
                if ($syncApps) {
                    $hrProvisioningApps = @($syncApps | Where-Object { $_.AppType -like "HR Provisioning*" -or $_.AppType -eq "Cloud Sync / AD" -or $_.AppType -eq "Cloud Sync" })
                    if ($hrProvisioningApps.Count -gt 0) {
                        Write-Host "  Discovered provisioning apps:" -ForegroundColor Green
                        foreach ($app in $hrProvisioningApps) {
                            $jobStatus = if ($app.Jobs) { ($app.Jobs | ForEach-Object { $_.schedule.state }) -join ', ' } else { 'unknown' }
                            Write-Host "    $($app.DisplayName) ($($app.AppType))  -  $($app.JobCount) job(s), status: $jobStatus" -ForegroundColor White
                        }
                    } else {
                        Write-Host "  No HR provisioning or Cloud Sync apps found" -ForegroundColor Gray
                    }
                }
                Write-Host ""
            } catch {
                Write-Host "  Could not discover provisioning apps: $_" -ForegroundColor Yellow
                Write-Host ""
            }
        }

        # Build HR source config from discovered indicators (only if user didn't already define one)
        if (-not $hrSourceConfig -and $hrDiscovery -and $hrDiscovery.totalUsers -gt 0) {
            $total = $hrDiscovery.totalUsers
            $hrIndicators = @()

            if ($hrDiscovery.hasColumns['employeeId'] -and $hrDiscovery.employeeIdCount -gt 0) {
                $coverage = [math]::Round($hrDiscovery.employeeIdCount / $total * 100, 1)
                if ($coverage -ge 10) {
                    $hrIndicators += [ordered]@{ id = "employeeId"; attribute = "employeeId"; condition = "isNotNull"; weight = 3; confidence = 95; coverage = $coverage }
                }
            }

            if ($hrDiscovery.employeeTypeValues.Count -gt 0) {
                $hrTypeValues = @($hrDiscovery.employeeTypeValues | Where-Object { $_.count -ge 10 } | ForEach-Object { $_.value })
                if ($hrTypeValues.Count -gt 0) {
                    $typeCoverage = [math]::Round(($hrDiscovery.employeeTypeValues | Where-Object { $_.value -in $hrTypeValues } | Measure-Object -Property count -Sum).Sum / $total * 100, 1)
                    $hrIndicators += [ordered]@{ id = "employeeType"; attribute = "employeeType"; condition = "inValues"; values = $hrTypeValues; weight = 2; confidence = 85; coverage = $typeCoverage }
                }
            }

            if ($hrDiscovery.hasColumns['onPremisesSyncEnabled'] -and $hrDiscovery.onPremSyncCount -gt 0) {
                $syncCoverage = [math]::Round($hrDiscovery.onPremSyncCount / $total * 100, 1)
                if ($syncCoverage -ge 20) {
                    $hrIndicators += [ordered]@{ id = "onPremisesSync"; attribute = "onPremisesSyncEnabled"; condition = "equals"; value = "True"; weight = 1; confidence = 60; coverage = $syncCoverage }
                }
            }

            if ($hrDiscovery.hasColumns['managerId'] -and $hrDiscovery.managerIdCount -gt 0) {
                $mgrCoverage = [math]::Round($hrDiscovery.managerIdCount / $total * 100, 1)
                if ($mgrCoverage -ge 30) {
                    $hrIndicators += [ordered]@{ id = "hasManager"; attribute = "managerId"; condition = "isNotNull"; weight = 1; confidence = 40; coverage = $mgrCoverage }
                }
            }

            $totalWeight = ($hrIndicators | Measure-Object -Property weight -Sum).Sum

            if ($hrIndicators.Count -gt 0 -and $totalWeight -ge 3) {
                $hrSourceConfig = [ordered]@{
                    enabled          = $true
                    description      = "HR-authoritative account detection (auto-discovered)"
                    indicators       = $hrIndicators
                    minimumScore     = [math]::Min(3, $totalWeight)
                    provisioningApps = @($hrProvisioningApps | ForEach-Object { [ordered]@{ name = $_.DisplayName; type = $_.AppType; appId = $_.AppId } })
                    orphanDetection  = [ordered]@{ enabled = $true; stalenessThresholdDays = 90 }
                }

                Write-Host "  HR Source Configuration (auto-discovered):" -ForegroundColor Green
                Write-Host "    Indicators: $($hrIndicators.Count) (total weight: $totalWeight)" -ForegroundColor White
                foreach ($ind in $hrIndicators) {
                    Write-Host "    $($ind.id): weight=$($ind.weight), confidence=$($ind.confidence)%, coverage=$($ind.coverage)%" -ForegroundColor Gray
                }
            } else {
                Write-Host "  Insufficient HR indicators (weight: $totalWeight, need >= 3)" -ForegroundColor Yellow
                Write-Host "  Correlation will use symmetric matching (name-based only)." -ForegroundColor Gray
            }
            Write-Host ""

        } elseif ($hrSourceConfig -and $hrDiscovery -and $hrDiscovery.totalUsers -gt 0) {
            # User provided HR config with low confidence  -  add discovery signals
            $total = $hrDiscovery.totalUsers
            if ($hrDiscovery.hasColumns['employeeId'] -and $hrDiscovery.employeeIdCount -gt 0) {
                $coverage = [math]::Round($hrDiscovery.employeeIdCount / $total * 100, 1)
                if ($coverage -ge 10) {
                    $hrSourceConfig.indicators += [ordered]@{ id = "employeeId"; attribute = "employeeId"; condition = "isNotNull"; weight = 2; confidence = 95; coverage = $coverage }
                }
            }
            Write-Host "  Added discovery signals to support user-defined HR attribute." -ForegroundColor Green
            Write-Host ""
        }
    }

    # ================================================================
    # Step 2: Merge database patterns into universal defaults
    #         LLM mode adds LLM-discovered patterns + interactive refinement
    # ================================================================

    if ($useLLM) {
        # ---- Interactive mode: LLM discovery ----
        Write-Host "--- Step 2: LLM Pattern Discovery ---" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  The following ANONYMIZED data will be sent to ${LLMProvider}:" -ForegroundColor Yellow
        Write-Host "    - Prefix patterns (e.g. 'adm-' used by 12 accounts)" -ForegroundColor Gray
        Write-Host "    - Suffix patterns (e.g. '-admin' used by 5 accounts)" -ForegroundColor Gray
        Write-Host "    - Display name suffixes (e.g. '(Admin)' used by 8 accounts)" -ForegroundColor Gray
        Write-Host "    - UPN domain names (e.g. '@contoso.com')" -ForegroundColor Gray
        Write-Host "    - Account counts per pattern" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  NO user names, email addresses, or identity data is shared." -ForegroundColor Green
        Write-Host ""

        # Build anonymized context for the LLM
        $patternContext = ""
        if ($sampledPatterns) {
            $patternContext = "`n`nDATABASE PATTERN ANALYSIS (anonymized  -  only structural patterns, no actual names):`n"
            $patternContext += "Total accounts: $($sampledPatterns.totalUsers)`n"

            if ($sampledPatterns.upnPrefixPatterns.Count -gt 0) {
                $patternContext += "`nUPN prefix patterns (prefix + separator, before the person's name):`n"
                foreach ($p in $sampledPatterns.upnPrefixPatterns | Select-Object -First 15) {
                    $patternContext += "  '$($p.pattern)'  -  $($p.count) accounts`n"
                }
            }
            if ($sampledPatterns.upnSuffixPatterns.Count -gt 0) {
                $patternContext += "`nUPN suffix patterns (separator + suffix, after the person's name):`n"
                foreach ($p in $sampledPatterns.upnSuffixPatterns | Select-Object -First 15) {
                    $patternContext += "  '$($p.pattern)'  -  $($p.count) accounts`n"
                }
            }
            if ($sampledPatterns.samPrefixPatterns.Count -gt 0) {
                $patternContext += "`nSAM account prefix patterns:`n"
                foreach ($p in $sampledPatterns.samPrefixPatterns | Select-Object -First 15) {
                    $patternContext += "  '$($p.pattern)'  -  $($p.count) accounts`n"
                }
            }
            if ($sampledPatterns.displayNameSuffixes.Count -gt 0) {
                $patternContext += "`nDisplay name parenthetical suffixes:`n"
                foreach ($p in $sampledPatterns.displayNameSuffixes | Select-Object -First 15) {
                    $patternContext += "  '$($p.pattern)'  -  $($p.count) accounts`n"
                }
            }
            if ($sampledPatterns.domainParts.Count -gt 0) {
                $patternContext += "`nUPN domains in use:`n"
                foreach ($d in $sampledPatterns.domainParts) {
                    $patternContext += "  @$($d.domain) ($($d.count) accounts)`n"
                }
            }
        }

        $systemPrompt = @"
You are an identity governance consultant specializing in account naming conventions in Microsoft Entra ID (Azure AD) environments.

Your task is to analyze an organization's account naming patterns and generate correlation rules that identify which accounts likely belong to the same physical person.

IMPORTANT: No actual user names or identities are shared  -  only structural naming patterns (prefixes, suffixes, separators).

You must respond with ONLY a valid JSON object (no markdown fencing, no explanation). The JSON must follow this exact schema:

{
  "organization_context": {
    "domain": "domain.com",
    "naming_convention_summary": "Brief description of the observed naming patterns",
    "confidence_notes": "Observations about pattern quality or ambiguity"
  },
  "account_type_rules": [
    {
      "type": "Admin|Service|Test|Shared|Training|Break-Glass",
      "description": "What this account type is used for",
      "upnPrefixes": ["prefix-", "prefix."],
      "upnSuffixes": ["-suffix", ".suffix"],
      "samPrefixes": ["prefix-", "prefix_"],
      "samSuffixes": ["-suffix", "_suffix"],
      "displayNamePatterns": ["\\(Admin\\)", "\\(Adm\\)"],
      "priority": 1,
      "rationale": "Why these patterns indicate this account type"
    }
  ],
  "correlation_insights": {
    "recommended_signal_adjustments": [
      {
        "signal": "employeeId|managerAndName|upnBaseName|samBaseName|fullNameMatch|displayNameFuzzy|mailBaseName",
        "recommended_confidence": 0-100,
        "reason": "Why this confidence is appropriate"
      }
    ],
    "warnings": ["Potential false-positive risks or ambiguities"]
  }
}

RULES:
1. Prefixes MUST include the separator (e.g., "adm-" not "adm")
2. Suffixes MUST include the separator (e.g., "-admin" not "admin")
3. DisplayName patterns use PowerShell regex  -  escape special chars with \\
4. Short prefixes like "a-" or "t-" are risky  -  flag in warnings
5. Consider BOTH observed database patterns AND industry-standard conventions
6. Classify each discovered prefix/suffix into the most appropriate account type
7. If patterns don't fit standard types, propose a new type (e.g., "Training", "Break-Glass")
8. Flag ambiguous patterns (e.g., "dev-" could be developer name OR development account)
"@

        $userPrompt = "Analyze the account naming conventions for this organization and generate correlation rules.$patternContext"

        $llmDiscoveredRules = $null
        try {
            Write-Host "  Sending anonymized patterns to ${LLMProvider}..." -ForegroundColor Gray
            $rawResponse = Invoke-FGLLMRequest `
                -Provider $LLMProvider `
                -ApiKey $LLMApiKey `
                -SystemPrompt $systemPrompt `
                -UserPrompt $userPrompt `
                -Model $LLMModel `
                -MaxTokens 4096 `
                -Temperature 0.3

            $jsonText = $rawResponse -replace '(?s)^```json\s*', '' -replace '(?s)\s*```$', '' -replace '(?s)^```\s*', ''
            $llmDiscoveredRules = $jsonText | ConvertFrom-Json

            # Display findings
            if ($llmDiscoveredRules.organization_context) {
                $ctx = $llmDiscoveredRules.organization_context
                Write-Host "  Summary: $($ctx.naming_convention_summary)" -ForegroundColor White
                if ($ctx.confidence_notes) {
                    Write-Host "  Notes:   $($ctx.confidence_notes)" -ForegroundColor Yellow
                }
                Write-Host ""
            }

            if ($llmDiscoveredRules.account_type_rules) {
                Write-Host "  Discovered Account Type Rules:" -ForegroundColor Gray
                foreach ($rule in $llmDiscoveredRules.account_type_rules) {
                    $prefixes = @(@($rule.upnPrefixes) + @($rule.samPrefixes) | Select-Object -Unique) -join ", "
                    $suffixes = @(@($rule.upnSuffixes) + @($rule.samSuffixes) | Select-Object -Unique) -join ", "
                    Write-Host "    $($rule.type):" -ForegroundColor White
                    if ($prefixes) { Write-Host "      Prefixes: $prefixes" -ForegroundColor Gray }
                    if ($suffixes) { Write-Host "      Suffixes: $suffixes" -ForegroundColor Gray }
                    Write-Host "      $($rule.rationale)" -ForegroundColor DarkGray
                }
                Write-Host ""
            }

            if ($llmDiscoveredRules.correlation_insights.warnings) {
                Write-Host "  Warnings:" -ForegroundColor Yellow
                foreach ($w in $llmDiscoveredRules.correlation_insights.warnings) {
                    Write-Host "    ! $w" -ForegroundColor Yellow
                }
                Write-Host ""
            }
        } catch {
            Write-Host "  LLM discovery failed: $_" -ForegroundColor Red
            Write-Host "  Continuing with universal defaults." -ForegroundColor Yellow
            Write-Host ""
        }

        # ---- Merge LLM patterns into universal rules ----
        if ($llmDiscoveredRules -and $llmDiscoveredRules.account_type_rules) {
            Write-Host "--- Step 3: Merging LLM + Universal Patterns ---" -ForegroundColor Cyan

            foreach ($llmRule in $llmDiscoveredRules.account_type_rules) {
                $existingRule = $accountTypeRules | Where-Object { $_.type -eq $llmRule.type }

                if ($existingRule) {
                    $newPrefixes = @($llmRule.upnPrefixes) | Where-Object { $_ -and $_ -notin $existingRule.upnPrefixes }
                    $newSuffixes = @($llmRule.upnSuffixes) | Where-Object { $_ -and $_ -notin $existingRule.upnSuffixes }
                    $newSamPrefixes = @($llmRule.samPrefixes) | Where-Object { $_ -and $_ -notin $existingRule.samPrefixes }
                    $newSamSuffixes = @($llmRule.samSuffixes) | Where-Object { $_ -and $_ -notin $existingRule.samSuffixes }
                    $newDisplayPatterns = @($llmRule.displayNamePatterns) | Where-Object { $_ -and $_ -notin $existingRule.displayNamePatterns }

                    if ($newPrefixes.Count -gt 0) {
                        $existingRule.upnPrefixes = @($existingRule.upnPrefixes) + @($newPrefixes)
                        Write-Host "  $($llmRule.type): +$($newPrefixes.Count) UPN prefixes ($($newPrefixes -join ', '))" -ForegroundColor Gray
                    }
                    if ($newSuffixes.Count -gt 0) {
                        $existingRule.upnSuffixes = @($existingRule.upnSuffixes) + @($newSuffixes)
                        Write-Host "  $($llmRule.type): +$($newSuffixes.Count) UPN suffixes ($($newSuffixes -join ', '))" -ForegroundColor Gray
                    }
                    if ($newSamPrefixes.Count -gt 0) { $existingRule.samPrefixes = @($existingRule.samPrefixes) + @($newSamPrefixes) }
                    if ($newSamSuffixes.Count -gt 0) { $existingRule.samSuffixes = @($existingRule.samSuffixes) + @($newSamSuffixes) }
                    if ($newDisplayPatterns.Count -gt 0) {
                        $existingRule.displayNamePatterns = @($existingRule.displayNamePatterns) + @($newDisplayPatterns)
                        Write-Host "  $($llmRule.type): +$($newDisplayPatterns.Count) display patterns" -ForegroundColor Gray
                    }
                } else {
                    # New type discovered by LLM
                    $newRule = [ordered]@{
                        type        = $llmRule.type
                        description = if ($llmRule.description) { $llmRule.description } else { "LLM-discovered account type" }
                        upnPrefixes = @($llmRule.upnPrefixes | Where-Object { $_ })
                        upnSuffixes = @($llmRule.upnSuffixes | Where-Object { $_ })
                        samPrefixes = @($llmRule.samPrefixes | Where-Object { $_ })
                        samSuffixes = @($llmRule.samSuffixes | Where-Object { $_ })
                        displayNamePatterns = @($llmRule.displayNamePatterns | Where-Object { $_ })
                        priority    = if ($llmRule.priority) { $llmRule.priority } else { 6 }
                    }
                    $accountTypeRules += $newRule
                    Write-Host "  New type: $($llmRule.type)" -ForegroundColor Green
                }
            }
            Write-Host ""
        }
    } else {
        # ---- NoLLM mode: merge database-discovered patterns into universal rules ----
        Write-Host "--- Step 2: Merging Database Patterns ---" -ForegroundColor Cyan

        if ($sampledPatterns) {
            $autoAdded = 0

            # Check each discovered prefix/suffix against known account type patterns
            foreach ($p in $sampledPatterns.upnPrefixPatterns) {
                $pattern = $p.pattern
                $alreadyKnown = $false
                foreach ($rule in $accountTypeRules) {
                    if ($pattern -in $rule.upnPrefixes -or $pattern -in $rule.samPrefixes) {
                        $alreadyKnown = $true; break
                    }
                }
                if (-not $alreadyKnown -and $p.count -ge 3) {
                    Write-Host "  New prefix discovered: '$pattern' ($($p.count) accounts)  -  review manually" -ForegroundColor Yellow
                }
            }

            # Add discovered displayName suffixes that match account type indicators
            foreach ($p in $sampledPatterns.displayNameSuffixes) {
                $suffix = $p.pattern
                $alreadyKnown = $false
                foreach ($rule in $accountTypeRules) {
                    foreach ($dp in $rule.displayNamePatterns) {
                        $escaped = [regex]::Escape($suffix)
                        if ($suffix -match $dp -or $dp -match [regex]::Escape($suffix)) {
                            $alreadyKnown = $true; break
                        }
                    }
                    if ($alreadyKnown) { break }
                }
                if (-not $alreadyKnown -and $p.count -ge 2) {
                    $suffixLower = $suffix.ToLower()
                    $targetRule = $null
                    if ($suffixLower -match 'admin|adm|priv|pam') { $targetRule = $accountTypeRules | Where-Object { $_.type -eq 'Admin' } }
                    elseif ($suffixLower -match 'svc|service') { $targetRule = $accountTypeRules | Where-Object { $_.type -eq 'Service' } }
                    elseif ($suffixLower -match 'test|tst|dev|demo') { $targetRule = $accountTypeRules | Where-Object { $_.type -eq 'Test' } }
                    elseif ($suffixLower -match 'shared|room|conf|equip|mailbox') { $targetRule = $accountTypeRules | Where-Object { $_.type -eq 'Shared' } }

                    if ($targetRule) {
                        $escapedPattern = [regex]::Escape($suffix)
                        $targetRule.displayNamePatterns = @($targetRule.displayNamePatterns) + @($escapedPattern)
                        Write-Host "  Added displayName pattern '$escapedPattern' to $($targetRule.type) ($($p.count) accounts)" -ForegroundColor Gray
                        $autoAdded++
                    } else {
                        Write-Host "  Unclassified displayName suffix: '$suffix' ($($p.count) accounts)  -  review manually" -ForegroundColor Yellow
                    }
                }
            }

            if ($autoAdded -gt 0) {
                Write-Host "  Auto-added $autoAdded patterns from database" -ForegroundColor Green
            } else {
                Write-Host "  No new patterns to add (universal defaults cover all observed patterns)" -ForegroundColor Gray
            }
        } else {
            Write-Host "  No database patterns available  -  using universal defaults only" -ForegroundColor Gray
        }
        Write-Host ""
    }

    # ================================================================
    # Correlation Signals
    # ================================================================

    $correlationSignals = @(
        [ordered]@{
            id          = "employeeId"
            name        = "Employee ID Match"
            description = "Exact match on employeeId attribute  -  strongest possible signal"
            confidence  = 100
            boost       = 0
            enabled     = $true
            requiresBothPopulated = $true
        }
        [ordered]@{
            id          = "managerAndName"
            name        = "Same Manager + Similar Name"
            description = "Accounts share the same managerId and have similar given/surname"
            confidence  = 90
            boost       = 5
            enabled     = $true
            requiresBothPopulated = $false
        }
        [ordered]@{
            id          = "upnBaseName"
            name        = "UPN Base Name Match"
            description = "UPN prefix matches after stripping account type prefixes/suffixes"
            confidence  = 80
            boost       = 5
            enabled     = $true
            requiresBothPopulated = $false
        }
        [ordered]@{
            id          = "samBaseName"
            name        = "SAM Account Base Name Match"
            description = "onPremisesSamAccountName matches after stripping account type prefixes/suffixes"
            confidence  = 75
            boost       = 5
            enabled     = $true
            requiresBothPopulated = $true
        }
        [ordered]@{
            id          = "fullNameMatch"
            name        = "Full Name Match"
            description = "Exact match on givenName + surname (case-insensitive)"
            confidence  = 70
            boost       = 5
            enabled     = $true
            requiresBothPopulated = $true
        }
        [ordered]@{
            id          = "displayNameFuzzy"
            name        = "Display Name Fuzzy Match"
            description = "displayName matches after removing account type indicators like (Admin), (Test)"
            confidence  = 60
            boost       = 0
            enabled     = $true
            requiresBothPopulated = $true
        }
        [ordered]@{
            id          = "mailBaseName"
            name        = "Mail Base Name Match"
            description = "Mail address prefix matches after stripping account type prefixes/suffixes"
            confidence  = 75
            boost       = 5
            enabled     = $true
            requiresBothPopulated = $true
        }
    )

    # Apply LLM signal adjustments
    if ($useLLM -and $llmDiscoveredRules -and $llmDiscoveredRules.correlation_insights -and $llmDiscoveredRules.correlation_insights.recommended_signal_adjustments) {
        foreach ($adj in $llmDiscoveredRules.correlation_insights.recommended_signal_adjustments) {
            $signal = $correlationSignals | Where-Object { $_.id -eq $adj.signal }
            if ($signal -and $adj.recommended_confidence) {
                $old = $signal.confidence
                $signal.confidence = [int]$adj.recommended_confidence
                Write-Host "  Signal '$($adj.signal)': $old -> $($signal.confidence) ($($adj.reason))" -ForegroundColor Gray
            }
        }
    }

    $settings = [ordered]@{
        minimumConfidence        = 60
        primaryAccountPreference = @("Regular", "Admin", "Test", "Service", "Shared", "External")
        excludeDisabledAccounts  = $false
        excludeExternalAccounts  = $true
        excludeServiceAccounts   = $true
    }

    # ================================================================
    # Display complete ruleset
    # ================================================================

    Write-Host "--- Complete Ruleset ---" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Account Type Rules:" -ForegroundColor Gray
    foreach ($rule in $accountTypeRules) {
        $totalPatterns = @($rule.upnPrefixes).Count + @($rule.upnSuffixes).Count + @($rule.samPrefixes).Count + @($rule.samSuffixes).Count + @($rule.displayNamePatterns).Count
        Write-Host "    $($rule.type) (priority $($rule.priority), $totalPatterns patterns)" -ForegroundColor White
        if (@($rule.upnPrefixes).Count -gt 0) { Write-Host "      Prefixes: $(@($rule.upnPrefixes) -join ', ')" -ForegroundColor Gray }
        if (@($rule.upnSuffixes).Count -gt 0) { Write-Host "      Suffixes: $(@($rule.upnSuffixes) -join ', ')" -ForegroundColor Gray }
    }
    Write-Host ""
    Write-Host "  Correlation Signals:" -ForegroundColor Gray
    foreach ($signal in $correlationSignals) {
        Write-Host "    $($signal.id): $($signal.confidence)% ($(if ($signal.enabled) { 'enabled' } else { 'disabled' }))" -ForegroundColor White
    }
    Write-Host ""

    # ================================================================
    # Interactive refinement dialog (only in LLM mode)
    # ================================================================

    if ($useLLM) {
        Write-Host "--- Review & Refine ---" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Review the ruleset above. Enter instructions to refine, or press Enter to save." -ForegroundColor Gray
        Write-Host "  Refinement instructions are sent to the LLM along with the current ruleset structure." -ForegroundColor Gray
        Write-Host "  No identity data is included  -  only rule definitions (patterns, signals, settings)." -ForegroundColor Gray
        Write-Host ""
        Write-Host "  Examples:" -ForegroundColor Gray
        Write-Host "    - 'Add x- as an admin prefix, we use that for external admins'" -ForegroundColor White
        Write-Host "    - 'Remove a- and a. as admin prefixes, too many false positives'" -ForegroundColor White
        Write-Host "    - 'Add a Training type for accounts starting with trn-'" -ForegroundColor White
        Write-Host "    - 'Increase fullNameMatch confidence to 80'" -ForegroundColor White
        Write-Host "    - 'Disable the displayNameFuzzy signal'" -ForegroundColor White
        Write-Host ""
        Write-Host "  Commands: 'done' or Enter = save, 'show' = display JSON, 'cancel' = abort" -ForegroundColor Yellow
        Write-Host ""

        $currentRuleset = [ordered]@{
            accountTypeRules   = $accountTypeRules
            correlationSignals = $correlationSignals
            settings           = $settings
            hrSourceConfig     = $hrSourceConfig
        }

        $refinementSystemPrompt = @"
You are helping an identity governance administrator refine account correlation rules.

The current ruleset is provided below. The admin will give you instructions to modify it.
Apply their changes and return the COMPLETE updated ruleset as a valid JSON object.

IMPORTANT:
- Return ONLY the JSON object, no markdown fencing, no explanation
- Keep the same schema: accountTypeRules, correlationSignals, settings
- Apply changes precisely, preserve everything that wasn't changed
- Prefixes MUST include the separator (e.g., "adm-" not "adm")
- Suffixes MUST include the separator (e.g., "-admin" not "admin")
- DisplayName patterns use PowerShell regex  -  escape parentheses with \\

Current ruleset:
$(($currentRuleset | ConvertTo-Json -Depth 100))
"@

        while ($true) {
            $input = Read-Host "  Refine"

            if ($input -eq 'done' -or $input -eq '') {
                Write-Host ""
                Write-Host "  Finalizing ruleset..." -ForegroundColor Green
                break
            }

            if ($input -eq 'cancel') {
                Write-Host ""
                Write-Host "  Cancelled. No ruleset saved." -ForegroundColor Yellow
                return $null
            }

            if ($input -eq 'show') {
                Write-Host ""
                $currentRuleset = [ordered]@{
                    accountTypeRules   = $accountTypeRules
                    correlationSignals = $correlationSignals
                    settings           = $settings
                    hrSourceConfig     = $hrSourceConfig
                }
                Write-Host ($currentRuleset | ConvertTo-Json -Depth 100) -ForegroundColor Gray
                Write-Host ""
                continue
            }

            Write-Host "  Sending refinement to ${LLMProvider} (no identity data included)..." -ForegroundColor Gray
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
                $updatedRuleset = $jsonText | ConvertFrom-Json

                if ($updatedRuleset.accountTypeRules) {
                    $accountTypeRules = @()
                    foreach ($r in $updatedRuleset.accountTypeRules) {
                        $accountTypeRules += [ordered]@{
                            type        = $r.type
                            description = $r.description
                            upnPrefixes = @($r.upnPrefixes | Where-Object { $_ })
                            upnSuffixes = @($r.upnSuffixes | Where-Object { $_ })
                            samPrefixes = @($r.samPrefixes | Where-Object { $_ })
                            samSuffixes = @($r.samSuffixes | Where-Object { $_ })
                            displayNamePatterns = @($r.displayNamePatterns | Where-Object { $_ })
                            priority    = if ($r.priority) { [int]$r.priority } else { 99 }
                        }
                    }
                }
                if ($updatedRuleset.correlationSignals) {
                    $correlationSignals = @()
                    foreach ($s in $updatedRuleset.correlationSignals) {
                        $correlationSignals += [ordered]@{
                            id          = $s.id
                            name        = $s.name
                            description = $s.description
                            confidence  = [int]$s.confidence
                            boost       = [int]$s.boost
                            enabled     = [bool]$s.enabled
                            requiresBothPopulated = [bool]$s.requiresBothPopulated
                        }
                    }
                }
                if ($updatedRuleset.settings) {
                    $settings = [ordered]@{
                        minimumConfidence        = if ($updatedRuleset.settings.minimumConfidence) { [int]$updatedRuleset.settings.minimumConfidence } else { 60 }
                        primaryAccountPreference = @($updatedRuleset.settings.primaryAccountPreference | Where-Object { $_ })
                        excludeDisabledAccounts  = [bool]$updatedRuleset.settings.excludeDisabledAccounts
                        excludeExternalAccounts  = [bool]$updatedRuleset.settings.excludeExternalAccounts
                        excludeServiceAccounts   = [bool]$updatedRuleset.settings.excludeServiceAccounts
                    }
                }

                # Update refinement context
                $currentRuleset = [ordered]@{
                    accountTypeRules   = $accountTypeRules
                    correlationSignals = $correlationSignals
                    settings           = $settings
                    hrSourceConfig     = $hrSourceConfig
                }
                $refinementSystemPrompt = @"
You are helping an identity governance administrator refine account correlation rules.

The current ruleset is provided below. The admin will give you instructions to modify it.
Apply their changes and return the COMPLETE updated ruleset as a valid JSON object.

IMPORTANT:
- Return ONLY the JSON object, no markdown fencing, no explanation
- Keep the same schema: accountTypeRules, correlationSignals, settings
- Apply changes precisely, preserve everything that wasn't changed
- Prefixes MUST include the separator (e.g., "adm-" not "adm")
- Suffixes MUST include the separator (e.g., "-admin" not "admin")
- DisplayName patterns use PowerShell regex  -  escape parentheses with \\

Current ruleset:
$(($currentRuleset | ConvertTo-Json -Depth 100))
"@

                Write-Host "  Updated." -ForegroundColor Green
                Write-Host ""
            } catch {
                Write-Host "  Failed: $_" -ForegroundColor Red
                Write-Host "  Ruleset unchanged. Try again or type 'done'." -ForegroundColor Yellow
                Write-Host ""
            }
        }
    }

    # ================================================================
    # Build final ruleset and save to SQL
    # ================================================================

    $ruleset = [ordered]@{
        version            = "1.1"
        generated_at       = (Get-Date -Format "o")
        llm_provider       = if ($useLLM) { $LLMProvider } else { $null }
        description        = "Account correlation ruleset for identifying multiple accounts belonging to the same person"
        accountTypeRules   = $accountTypeRules
        correlationSignals = $correlationSignals
        settings           = $settings
        hrSourceConfig     = if ($hrSourceConfig) { $hrSourceConfig } else { [ordered]@{ enabled = $false; description = "No HR indicators detected"; indicators = @(); minimumScore = 3; orphanDetection = [ordered]@{ enabled = $false; stalenessThresholdDays = 90 } } }
    }

    # Save to SQL (primary storage)
    if ($global:FGSQLConnectionString) {
        try {
            Save-FGCorrelationRuleset -Ruleset $ruleset -Id $Id
        } catch {
            Write-Host "  WARNING: Could not save to SQL: $_" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  WARNING: Not connected to SQL. Ruleset not persisted." -ForegroundColor Yellow
        Write-Host "  Connect to SQL or provide -ConfigFile to save the ruleset." -ForegroundColor Yellow
    }

    # Summary
    $totalPatterns = ($accountTypeRules | ForEach-Object {
        @($_.upnPrefixes).Count + @($_.upnSuffixes).Count + @($_.samPrefixes).Count + @($_.samSuffixes).Count + @($_.displayNamePatterns).Count
    } | Measure-Object -Sum).Sum
    $signalCount = ($correlationSignals | Where-Object { $_.enabled }).Count

    Write-Host ""
    Write-Host "=== Ruleset Complete ===" -ForegroundColor Cyan
    Write-Host "  Account types:       $($accountTypeRules.Count)" -ForegroundColor Gray
    Write-Host "  Total patterns:      $totalPatterns" -ForegroundColor Gray
    Write-Host "  Correlation signals: $signalCount enabled" -ForegroundColor Gray
    Write-Host "  Min confidence:      $($settings.minimumConfidence)%" -ForegroundColor Gray
    if ($hrSourceConfig -and $hrSourceConfig.enabled) {
        Write-Host "  HR anchoring:        enabled ($($hrSourceConfig.indicators.Count) indicators)" -ForegroundColor Green
        Write-Host "  Orphan detection:    $(if ($hrSourceConfig.orphanDetection.enabled) { 'enabled' } else { 'disabled' })" -ForegroundColor Gray
    } else {
        Write-Host "  HR anchoring:        disabled (symmetric matching)" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "  Next step: Run correlation:" -ForegroundColor Gray
    Write-Host "    Invoke-FGAccountCorrelation$(if ($ConfigFile) { " -ConfigFile '$ConfigFile'" })" -ForegroundColor White
    Write-Host ""

    return $ruleset
}
