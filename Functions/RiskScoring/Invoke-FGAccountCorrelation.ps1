function Invoke-FGAccountCorrelation {
    <#
    .SYNOPSIS
        Correlates user accounts to identify multiple accounts belonging to the same person (Identity).

    .DESCRIPTION
        Uses a configurable correlation ruleset to:
        1. Classify each account by type (Regular, Admin, Test, Service, Shared, External)
        2. Extract base names by stripping type-specific prefixes/suffixes
        3. Apply multi-signal correlation (employeeId, manager+name, UPN, SAM, name matching)
        4. Group correlated accounts into Identities and persist to SQL

        Results are stored in GraphIdentities (master) and GraphIdentityMembers (detail) temporal tables.
        All user attributes from the primary account are copied to the identity for easy querying.

    .PARAMETER RulesetId
        Id of a saved correlation ruleset to use. Defaults to the most recent ruleset.

    .PARAMETER ConfigFile
        Optional path to FortigiGraph config file for SQL connection.

    .EXAMPLE
        # Generate and save ruleset first, then correlate
        New-FGCorrelationRuleset | Save-FGCorrelationRuleset
        Invoke-FGAccountCorrelation

    .EXAMPLE
        Invoke-FGAccountCorrelation -ConfigFile .\Config\mycompany.json
    #>
    [alias("Invoke-AccountCorrelation")]
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory = $false)]
        [string]$RulesetId,

        [Parameter(Mandatory = $false)]
        [string]$ConfigFile
    )

    Write-Host "`n=== Account Correlation Engine ===" -ForegroundColor Cyan
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # ── 1. Validate SQL connection ──
    if ($global:FGSQLConnectionString) {
        try {
            $testConn = New-Object System.Data.SqlClient.SqlConnection($global:FGSQLConnectionString)
            $testConn.Open()
            $testConn.Close()
            $testConn.Dispose()
        } catch {
            Write-Host "  Existing SQL connection is stale, reconnecting..." -ForegroundColor Yellow
            $global:FGSQLConnectionString = $null
        }
    }

    if (-not $global:FGSQLConnectionString) {
        if ($ConfigFile) {
            Connect-FGSQLServer -ConfigFile $ConfigFile
        } else {
            throw "Not connected to SQL Server. Run Connect-FGSQLServer first or provide -ConfigFile."
        }
    }

    # ── 2. Load correlation ruleset ──
    Write-Host "`n--- Loading Correlation Ruleset ---" -ForegroundColor Cyan
    $ruleset = $null
    if ($RulesetId) {
        $ruleset = Get-FGCorrelationRuleset -Id $RulesetId
    } else {
        $ruleset = Get-FGCorrelationRuleset
    }

    if (-not $ruleset) {
        Write-Host "  No correlation ruleset found. Generating default..." -ForegroundColor Yellow
        $ruleset = New-FGCorrelationRuleset
        Save-FGCorrelationRuleset -Ruleset $ruleset
    }

    $settings = $ruleset.settings
    Write-Host "  Ruleset loaded (version $($ruleset.version), $($ruleset.correlationSignals.Count) signals)" -ForegroundColor Gray

    # ── 3. Load user data from SQL ──
    Write-Host "`n--- Loading User Data from SQL ---" -ForegroundColor Cyan

    $dataConnection = New-Object System.Data.SqlClient.SqlConnection($global:FGSQLConnectionString)
    $dataConnection.Open()

    $users = $null
    $usePrincipals = $false
    try {
        # Detect if Principals table exists (preferred over GraphUsers)
        $cmd = $dataConnection.CreateCommand()
        $cmd.CommandText = "SELECT OBJECT_ID('dbo.Principals', 'U')"
        $princCheck = $cmd.ExecuteScalar()
        if ($null -ne $princCheck -and $princCheck -ne [DBNull]::Value) {
            $usePrincipals = $true
        }

        if ($usePrincipals) {
            # Load from Principals with JSON extraction for backward-compatible column names
            Write-Host "  Loading users from Principals table..." -ForegroundColor Gray

            # Discover all NVARCHAR columns on Principals
            $cmd = $dataConnection.CreateCommand()
            $cmd.CommandText = "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'Principals' AND TABLE_SCHEMA = 'dbo' ORDER BY ORDINAL_POSITION"
            $reader = $cmd.ExecuteReader()
            $allColumns = @()
            while ($reader.Read()) { $allColumns += $reader.GetString(0) }
            $reader.Close()

            # Build SELECT: real columns + JSON-extracted fields aliased for compatibility
            $princRealCols = @('id', 'managerId', 'accountEnabled', 'createdDateTime', 'displayName', 'givenName', 'surname', 'department', 'jobTitle', 'companyName', 'employeeId')
            $jsonExtracts = @(
                "email AS userPrincipalName",
                "JSON_VALUE(extendedAttributes, '$.userType') AS userType",
                "JSON_VALUE(extendedAttributes, '$.employeeType') AS employeeType",
                "JSON_VALUE(extendedAttributes, '$.onPremisesSamAccountName') AS onPremisesSamAccountName",
                "JSON_VALUE(extendedAttributes, '$.mail') AS mail",
                "JSON_VALUE(extendedAttributes, '$.city') AS city",
                "JSON_VALUE(extendedAttributes, '$.country') AS country",
                "JSON_VALUE(extendedAttributes, '$.officeLocation') AS officeLocation",
                "JSON_VALUE(extendedAttributes, '$.lastSignInDateTime') AS lastSignInDateTime"
            )

            # Dynamically add JSON extracts for extension attributes referenced in HR indicators
            $hrExtAttrs = @()
            $hrCfgCheck = $ruleset.hrSourceConfig
            if ($hrCfgCheck -and $hrCfgCheck.enabled -eq $true -and $hrCfgCheck.indicators) {
                $hrExtAttrs = @($hrCfgCheck.indicators |
                    Where-Object { $_.attribute -match '^extensionAttribute\d+$' } |
                    ForEach-Object { $_.attribute } | Select-Object -Unique)
                foreach ($extAttr in $hrExtAttrs) {
                    $jsonExtracts += "JSON_VALUE(extendedAttributes, '$.$extAttr') AS $extAttr"
                }
            }

            # Include any extra NVARCHAR columns that aren't already covered
            $coveredCols = $princRealCols + @('email', 'extendedAttributes', 'externalId', 'systemId', 'principalType', 'SysStartTime', 'SysEndTime', 'ValidFrom', 'ValidTo') + $hrExtAttrs
            $extraCols = $allColumns | Where-Object { $_ -notin $coveredCols }
            $extraColsSql = if ($extraCols.Count -gt 0) { ($extraCols | ForEach-Object { "[$_]" }) -join ', ' } else { $null }

            $selectParts = @()
            $selectParts += ($princRealCols | ForEach-Object { "[$_]" })
            $selectParts += $jsonExtracts
            if ($extraColsSql) { $selectParts += $extraColsSql }
            $selectSql = $selectParts -join ', '

            $cmd = $dataConnection.CreateCommand()
            $cmd.CommandTimeout = 300
            $cmd.CommandText = "SELECT $selectSql FROM dbo.Principals WHERE principalType = 'User' AND ValidTo = '9999-12-31 23:59:59.9999999'"
            $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
            $users = New-Object System.Data.DataTable
            $adapter.Fill($users) | Out-Null
            Write-Host "  Users loaded: $($users.Rows.Count) (from Principals table)" -ForegroundColor Gray

            # Fallback: if HR extension attributes are referenced but not populated in extendedAttributes,
            # merge values from GraphUsers (which stores them as direct columns)
            if ($hrExtAttrs.Count -gt 0) {
                $needsFallback = $false
                if ($users.Rows.Count -gt 0) {
                    $sample = $users.Rows[0]
                    foreach ($extAttr in $hrExtAttrs) {
                        $val = try { $sample[$extAttr] } catch { $null }
                        if ($null -eq $val -or $val -is [DBNull] -or "$val".Trim() -eq '') {
                            $needsFallback = $true; break
                        }
                    }
                }
                if ($needsFallback) {
                    $cmd2 = $dataConnection.CreateCommand()
                    $cmd2.CommandText = "SELECT OBJECT_ID('dbo.GraphUsers', 'U')"
                    $guExists = $cmd2.ExecuteScalar()
                    if ($null -ne $guExists -and $guExists -ne [DBNull]::Value) {
                        Write-Host "  Extension attributes not in Principals.extendedAttributes — merging from GraphUsers..." -ForegroundColor Yellow
                        $attrSelect = ($hrExtAttrs | ForEach-Object { "[$_]" }) -join ', '
                        $cmd2 = $dataConnection.CreateCommand()
                        $cmd2.CommandText = "SELECT [id], $attrSelect FROM dbo.GraphUsers WHERE ValidTo = '9999-12-31 23:59:59.9999999'"
                        $guAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd2)
                        $guData = New-Object System.Data.DataTable
                        $guAdapter.Fill($guData) | Out-Null
                        $guById = @{}
                        foreach ($guRow in $guData.Rows) { $guById[$guRow['id'].ToString().ToLower()] = $guRow }
                        foreach ($attr in $hrExtAttrs) {
                            if (-not $users.Columns.Contains($attr)) {
                                $users.Columns.Add($attr, [string]) | Out-Null
                            }
                        }
                        foreach ($row in $users.Rows) {
                            $rid = $row['id'].ToString().ToLower()
                            if ($guById.ContainsKey($rid)) {
                                $guRow = $guById[$rid]
                                foreach ($attr in $hrExtAttrs) {
                                    $existing = try { $row[$attr] } catch { $null }
                                    if ($null -eq $existing -or $existing -is [DBNull] -or "$existing".Trim() -eq '') {
                                        $guVal = try { $guRow[$attr] } catch { $null }
                                        if ($null -ne $guVal -and $guVal -isnot [DBNull] -and "$guVal".Trim() -ne '') {
                                            $row[$attr] = $guVal
                                        }
                                    }
                                }
                            }
                        }
                        Write-Host "  Merged extension attributes from GraphUsers: $($hrExtAttrs -join ', ')" -ForegroundColor Gray
                    }
                }
            }
        } else {
            # Legacy mode: load from GraphUsers
            # Discover all columns dynamically
            $cmd = $dataConnection.CreateCommand()
            $cmd.CommandText = "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'GraphUsers' AND TABLE_SCHEMA = 'dbo' ORDER BY ORDINAL_POSITION"
            $reader = $cmd.ExecuteReader()
            $allColumns = @()
            while ($reader.Read()) { $allColumns += $reader.GetString(0) }
            $reader.Close()

            # Exclude system columns from temporal tables
            $excludeCols = @('SysStartTime', 'SysEndTime')
            $selectCols = $allColumns | Where-Object { $_ -notin $excludeCols }
            $selectSql = ($selectCols | ForEach-Object { "[$_]" }) -join ', '

            $cmd = $dataConnection.CreateCommand()
            $cmd.CommandTimeout = 300
            $cmd.CommandText = "SELECT $selectSql FROM dbo.GraphUsers"
            $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
            $users = New-Object System.Data.DataTable
            $adapter.Fill($users) | Out-Null
            Write-Host "  Users loaded: $($users.Rows.Count) (from GraphUsers — legacy mode)" -ForegroundColor Gray
        }
    } finally {
        if ($dataConnection.State -eq 'Open') { $dataConnection.Close() }
        $dataConnection.Dispose()
    }

    if ($users.Rows.Count -eq 0) {
        $sourceTable = if ($usePrincipals) { "Principals" } else { "GraphUsers" }
        Write-Host "  No users found in $sourceTable table. Run Sync-FGUser first." -ForegroundColor Red
        return
    }

    # ── 4. Build helper functions ──

    # Get column value safely (handles DBNull)
    function Get-Val {
        param($row, $col)
        try {
            $v = $row[$col]
            if ($null -eq $v -or $v -is [DBNull]) { return $null }
            return "$v".Trim()
        } catch {
            return $null
        }
    }

    # Extract UPN prefix (part before @)
    function Get-UpnPrefix {
        param($upn)
        if (-not $upn) { return $null }
        $atIdx = $upn.IndexOf('@')
        if ($atIdx -gt 0) { return $upn.Substring(0, $atIdx).ToLower() }
        return $upn.ToLower()
    }

    # Extract mail prefix (part before @)
    function Get-MailPrefix {
        param($mail)
        if (-not $mail) { return $null }
        $atIdx = $mail.IndexOf('@')
        if ($atIdx -gt 0) { return $mail.Substring(0, $atIdx).ToLower() }
        return $mail.ToLower()
    }

    # Detect account type using ruleset patterns
    function Get-AccountType {
        param($upnPrefix, $samName, $displayName, $upn)
        $samLower = if ($samName) { $samName.ToLower() } else { $null }
        $displayLower = if ($displayName) { $displayName } else { "" }

        foreach ($rule in $ruleset.accountTypeRules) {
            # Check UPN prefix matches
            foreach ($p in $rule.upnPrefixes) {
                if ($upnPrefix -and $upnPrefix.StartsWith($p.ToLower())) {
                    return @{ type = $rule.type; matchedPattern = "upnPrefix:$p"; priority = $rule.priority }
                }
            }
            foreach ($s in $rule.upnSuffixes) {
                if ($upnPrefix -and $upnPrefix.EndsWith($s.ToLower())) {
                    return @{ type = $rule.type; matchedPattern = "upnSuffix:$s"; priority = $rule.priority }
                }
            }

            # Check SAM name matches
            foreach ($p in $rule.samPrefixes) {
                if ($samLower -and $samLower.StartsWith($p.ToLower())) {
                    return @{ type = $rule.type; matchedPattern = "samPrefix:$p"; priority = $rule.priority }
                }
            }
            foreach ($s in $rule.samSuffixes) {
                if ($samLower -and $samLower.EndsWith($s.ToLower())) {
                    return @{ type = $rule.type; matchedPattern = "samSuffix:$s"; priority = $rule.priority }
                }
            }

            # Check displayName patterns
            foreach ($pattern in $rule.displayNamePatterns) {
                if ($displayLower -match $pattern) {
                    return @{ type = $rule.type; matchedPattern = "displayName:$pattern"; priority = $rule.priority }
                }
            }

            # Check UPN patterns (for External #EXT#)
            if ($rule.upnPatterns) {
                foreach ($pattern in $rule.upnPatterns) {
                    if ($upn -and $upn -match [regex]::Escape($pattern)) {
                        return @{ type = $rule.type; matchedPattern = "upn:$pattern"; priority = $rule.priority }
                    }
                }
            }
        }

        return @{ type = "Regular"; matchedPattern = $null; priority = 99 }
    }

    # Strip account type prefixes/suffixes to extract base name
    function Get-BaseName {
        param($name, $accountType)
        if (-not $name) { return $null }
        $base = $name.ToLower()

        foreach ($rule in $ruleset.accountTypeRules) {
            # Strip UPN/SAM prefixes
            $allPrefixes = @($rule.upnPrefixes) + @($rule.samPrefixes) | Sort-Object { $_.Length } -Descending
            foreach ($p in $allPrefixes) {
                if ($base.StartsWith($p.ToLower())) {
                    $base = $base.Substring($p.Length)
                    break
                }
            }
            # Strip UPN/SAM suffixes
            $allSuffixes = @($rule.upnSuffixes) + @($rule.samSuffixes) | Sort-Object { $_.Length } -Descending
            foreach ($s in $allSuffixes) {
                if ($base.EndsWith($s.ToLower())) {
                    $base = $base.Substring(0, $base.Length - $s.Length)
                    break
                }
            }
        }

        return $base
    }

    # Clean displayName for comparison (remove type indicators)
    function Get-CleanDisplayName {
        param($displayName)
        if (-not $displayName) { return $null }
        $clean = $displayName
        foreach ($rule in $ruleset.accountTypeRules) {
            foreach ($pattern in $rule.displayNamePatterns) {
                $clean = $clean -replace $pattern, ''
            }
        }
        return $clean.Trim().ToLower()
    }

    # ── 5. Classify all accounts ──
    Write-Host "`n--- Classifying Accounts ---" -ForegroundColor Cyan

    $accounts = @()
    $typeCounts = @{}

    foreach ($row in $users.Rows) {
        $upn = Get-Val $row 'userPrincipalName'
        $sam = Get-Val $row 'onPremisesSamAccountName'
        $displayName = Get-Val $row 'displayName'
        $upnPrefix = Get-UpnPrefix $upn
        $mailPrefix = Get-MailPrefix (Get-Val $row 'mail')

        $typeResult = Get-AccountType -upnPrefix $upnPrefix -samName $sam -displayName $displayName -upn $upn

        # Extract base names for correlation
        $upnBase = Get-BaseName -name $upnPrefix -accountType $typeResult.type
        $samBase = Get-BaseName -name $sam -accountType $typeResult.type
        $mailBase = Get-BaseName -name $mailPrefix -accountType $typeResult.type

        $account = @{
            row             = $row
            id              = Get-Val $row 'id'
            upn             = $upn
            upnPrefix       = $upnPrefix
            upnBase         = $upnBase
            samName         = $sam
            samBase         = $samBase
            mail            = Get-Val $row 'mail'
            mailPrefix      = $mailPrefix
            mailBase        = $mailBase
            displayName     = $displayName
            cleanDisplayName = Get-CleanDisplayName $displayName
            givenName       = Get-Val $row 'givenName'
            surname         = Get-Val $row 'surname'
            employeeId      = Get-Val $row 'employeeId'
            managerId       = Get-Val $row 'managerId'
            department      = Get-Val $row 'department'
            accountType     = $typeResult.type
            matchedPattern  = $typeResult.matchedPattern
            accountEnabled  = Get-Val $row 'accountEnabled'
            identityId      = $null  # Will be assigned during correlation
        }

        $accounts += $account
        $typeCounts[$typeResult.type] = ($typeCounts[$typeResult.type] ?? 0) + 1
    }

    foreach ($type in ($typeCounts.Keys | Sort-Object)) {
        Write-Host "  $type : $($typeCounts[$type])" -ForegroundColor Gray
    }

    # ── 5b. Evaluate HR-authoritative status ──
    $hrConfig = $ruleset.hrSourceConfig
    $hrEnabled = $hrConfig -and $hrConfig.enabled -eq $true -and $hrConfig.indicators.Count -gt 0
    $hrAccountCount = 0

    if ($hrEnabled) {
        Write-Host "`n--- Evaluating HR-Authoritative Status ---" -ForegroundColor Cyan

        foreach ($account in $accounts) {
            $hrScore = 0
            $matchedIndicators = @()

            foreach ($indicator in $hrConfig.indicators) {
                $matched = $false

                switch ($indicator.condition) {
                    "isNotNull" {
                        $val = try { $account.row[$indicator.attribute] } catch { $null }
                        if ($null -ne $val -and $val -isnot [DBNull] -and "$val".Trim() -ne '') {
                            $matched = $true
                        }
                    }
                    "equals" {
                        $val = try { $account.row[$indicator.attribute] } catch { $null }
                        if ($null -ne $val -and "$val" -eq "$($indicator.value)") {
                            $matched = $true
                        }
                    }
                    "inValues" {
                        $val = try { $account.row[$indicator.attribute] } catch { $null }
                        if ($null -ne $val -and "$val" -in $indicator.values) {
                            $matched = $true
                        }
                    }
                    "containsAny" {
                        $val = try { $account.row[$indicator.attribute] } catch { $null }
                        if ($null -ne $val -and $val -isnot [DBNull]) {
                            $valStr = "$val"
                            foreach ($pattern in $indicator.values) {
                                if ($valStr -like "*$pattern*") {
                                    $matched = $true; break
                                }
                            }
                        }
                    }
                }

                if ($matched) {
                    $hrScore += $indicator.weight
                    $matchedIndicators += $indicator.id
                }
            }

            $account.isHrAuthoritative = $hrScore -ge $hrConfig.minimumScore
            $account.hrScore = $hrScore
            $account.hrIndicators = $matchedIndicators -join ','

            if ($account.isHrAuthoritative) { $hrAccountCount++ }
        }

        Write-Host "  HR-authoritative accounts: $hrAccountCount / $($accounts.Count) ($(([math]::Round($hrAccountCount / $accounts.Count * 100, 1)))%)" -ForegroundColor Green
    } else {
        # No HR config — mark all as non-HR
        foreach ($account in $accounts) {
            $account.isHrAuthoritative = $false
            $account.hrScore = 0
            $account.hrIndicators = $null
        }
        if ($hrConfig -and $hrConfig.enabled -eq $true) {
            Write-Host "`n  HR-anchored correlation configured but no indicators found. Using symmetric matching." -ForegroundColor Yellow
        }
    }

    # ── 6. Apply exclusions ──
    $correlatable = $accounts
    if ($settings.excludeExternalAccounts) {
        $correlatable = $correlatable | Where-Object { $_.accountType -ne 'External' }
    }
    if ($settings.excludeServiceAccounts) {
        $correlatable = $correlatable | Where-Object { $_.accountType -ne 'Service' }
    }
    Write-Host "  Correlatable accounts: $($correlatable.Count) (after exclusions)" -ForegroundColor Gray

    # ── 7. Build lookup indexes for fast matching ──
    Write-Host "`n--- Building Correlation Indexes ---" -ForegroundColor Cyan

    # Index by employeeId
    $byEmployeeId = @{}
    foreach ($a in $correlatable) {
        if ($a.employeeId) {
            if (-not $byEmployeeId.ContainsKey($a.employeeId)) { $byEmployeeId[$a.employeeId] = @() }
            $byEmployeeId[$a.employeeId] += $a
        }
    }

    # Index by UPN base name
    $byUpnBase = @{}
    foreach ($a in $correlatable) {
        if ($a.upnBase) {
            if (-not $byUpnBase.ContainsKey($a.upnBase)) { $byUpnBase[$a.upnBase] = @() }
            $byUpnBase[$a.upnBase] += $a
        }
    }

    # Index by SAM base name
    $bySamBase = @{}
    foreach ($a in $correlatable) {
        if ($a.samBase) {
            if (-not $bySamBase.ContainsKey($a.samBase)) { $bySamBase[$a.samBase] = @() }
            $bySamBase[$a.samBase] += $a
        }
    }

    # Index by mail base name
    $byMailBase = @{}
    foreach ($a in $correlatable) {
        if ($a.mailBase) {
            if (-not $byMailBase.ContainsKey($a.mailBase)) { $byMailBase[$a.mailBase] = @() }
            $byMailBase[$a.mailBase] += $a
        }
    }

    # Index by givenName+surname (lowered)
    $byFullName = @{}
    foreach ($a in $correlatable) {
        if ($a.givenName -and $a.surname) {
            $key = "$($a.givenName.ToLower())|$($a.surname.ToLower())"
            if (-not $byFullName.ContainsKey($key)) { $byFullName[$key] = @() }
            $byFullName[$key] += $a
        }
    }

    # Index by cleaned displayName
    $byCleanDisplayName = @{}
    foreach ($a in $correlatable) {
        if ($a.cleanDisplayName) {
            if (-not $byCleanDisplayName.ContainsKey($a.cleanDisplayName)) { $byCleanDisplayName[$a.cleanDisplayName] = @() }
            $byCleanDisplayName[$a.cleanDisplayName] += $a
        }
    }

    # Index by managerId
    $byManager = @{}
    foreach ($a in $correlatable) {
        if ($a.managerId) {
            if (-not $byManager.ContainsKey($a.managerId)) { $byManager[$a.managerId] = @() }
            $byManager[$a.managerId] += $a
        }
    }

    Write-Host "  Indexes built: employeeId=$($byEmployeeId.Count), upnBase=$($byUpnBase.Count), samBase=$($bySamBase.Count), fullName=$($byFullName.Count)" -ForegroundColor Gray

    # ── 8. Run correlation ──
    Write-Host "`n--- Running Correlation ---" -ForegroundColor Cyan

    # Union-Find for grouping accounts into identities
    $parent = @{}
    $rank = @{}

    function Find-Root {
        param($id)
        if (-not $parent.ContainsKey($id)) {
            $parent[$id] = $id
            $rank[$id] = 0
        }
        if ($parent[$id] -ne $id) {
            $parent[$id] = Find-Root -id $parent[$id]
        }
        return $parent[$id]
    }

    # Track HR status per id for merge preference
    $hrStatusById = @{}
    foreach ($a in $accounts) { $hrStatusById[$a.id] = $a.isHrAuthoritative }

    function Merge-Sets {
        param($id1, $id2)
        $r1 = Find-Root -id $id1
        $r2 = Find-Root -id $id2
        if ($r1 -eq $r2) { return }
        # Prefer HR-authoritative accounts as root
        $hr1 = $hrStatusById[$r1] -eq $true
        $hr2 = $hrStatusById[$r2] -eq $true
        if ($hr1 -and -not $hr2) { $parent[$r2] = $r1 }
        elseif ($hr2 -and -not $hr1) { $parent[$r1] = $r2 }
        elseif ($rank[$r1] -lt $rank[$r2]) { $parent[$r1] = $r2 }
        elseif ($rank[$r1] -gt $rank[$r2]) { $parent[$r2] = $r1 }
        else { $parent[$r2] = $r1; $rank[$r1]++ }
    }

    # Track which signals linked each pair
    $correlationEvidence = @{}  # "id1|id2" -> @{ signal, confidence }

    function Add-Evidence {
        param($id1, $id2, $signal, $confidence, $detail)
        $key = @($id1, $id2) | Sort-Object
        $pairKey = "$($key[0])|$($key[1])"
        if (-not $correlationEvidence.ContainsKey($pairKey)) {
            $correlationEvidence[$pairKey] = @()
        }
        $correlationEvidence[$pairKey] += @{ signal = $signal; confidence = $confidence; detail = $detail }
    }

    # Initialize all accounts in union-find
    foreach ($a in $correlatable) { $null = Find-Root -id $a.id }

    $enabledSignals = @{}
    foreach ($s in $ruleset.correlationSignals) {
        $enabledSignals[$s.id] = $s
    }

    $matchCount = 0

    # Signal 1: employeeId exact match
    if ($enabledSignals['employeeId'].enabled) {
        $signal = $enabledSignals['employeeId']
        foreach ($eid in $byEmployeeId.Keys) {
            $group = $byEmployeeId[$eid]
            if ($group.Count -gt 1) {
                $first = $group[0]
                for ($i = 1; $i -lt $group.Count; $i++) {
                    Merge-Sets -id1 $first.id -id2 $group[$i].id
                    Add-Evidence -id1 $first.id -id2 $group[$i].id -signal 'employeeId' -confidence $signal.confidence -detail "employeeId=$eid"
                    $matchCount++
                }
            }
        }
        Write-Host "  employeeId matches: $matchCount" -ForegroundColor Gray
    }

    # Signal 2: managerAndName — same manager + similar given/surname
    if ($enabledSignals['managerAndName'].enabled) {
        $signal = $enabledSignals['managerAndName']
        $mgrMatches = 0
        foreach ($mgr in $byManager.Keys) {
            $group = $byManager[$mgr]
            if ($group.Count -le 1) { continue }

            # Within same manager group, check name similarity
            for ($i = 0; $i -lt $group.Count; $i++) {
                for ($j = $i + 1; $j -lt $group.Count; $j++) {
                    $a = $group[$i]; $b = $group[$j]
                    $nameMatch = $false
                    # Check givenName+surname
                    if ($a.givenName -and $b.givenName -and $a.surname -and $b.surname) {
                        if ($a.givenName.ToLower() -eq $b.givenName.ToLower() -and $a.surname.ToLower() -eq $b.surname.ToLower()) {
                            $nameMatch = $true
                        }
                    }
                    # Check UPN base name
                    if (-not $nameMatch -and $a.upnBase -and $b.upnBase -and $a.upnBase -eq $b.upnBase) {
                        $nameMatch = $true
                    }
                    if ($nameMatch) {
                        Merge-Sets -id1 $a.id -id2 $b.id
                        Add-Evidence -id1 $a.id -id2 $b.id -signal 'managerAndName' -confidence $signal.confidence -detail "manager=$mgr"
                        $mgrMatches++
                    }
                }
            }
        }
        Write-Host "  managerAndName matches: $mgrMatches" -ForegroundColor Gray
        $matchCount += $mgrMatches
    }

    # Signal 3: UPN base name match
    if ($enabledSignals['upnBaseName'].enabled) {
        $signal = $enabledSignals['upnBaseName']
        $upnMatches = 0
        foreach ($base in $byUpnBase.Keys) {
            $group = $byUpnBase[$base]
            if ($group.Count -gt 1) {
                # Only correlate if at least one Regular account is present, or all are non-Regular
                $first = $group[0]
                for ($i = 1; $i -lt $group.Count; $i++) {
                    Merge-Sets -id1 $first.id -id2 $group[$i].id
                    Add-Evidence -id1 $first.id -id2 $group[$i].id -signal 'upnBaseName' -confidence $signal.confidence -detail "upnBase=$base"
                    $upnMatches++
                }
            }
        }
        Write-Host "  upnBaseName matches: $upnMatches" -ForegroundColor Gray
        $matchCount += $upnMatches
    }

    # Signal 4: SAM base name match
    if ($enabledSignals['samBaseName'].enabled) {
        $signal = $enabledSignals['samBaseName']
        $samMatches = 0
        foreach ($base in $bySamBase.Keys) {
            $group = $bySamBase[$base]
            if ($group.Count -gt 1) {
                $first = $group[0]
                for ($i = 1; $i -lt $group.Count; $i++) {
                    Merge-Sets -id1 $first.id -id2 $group[$i].id
                    Add-Evidence -id1 $first.id -id2 $group[$i].id -signal 'samBaseName' -confidence $signal.confidence -detail "samBase=$base"
                    $samMatches++
                }
            }
        }
        Write-Host "  samBaseName matches: $samMatches" -ForegroundColor Gray
        $matchCount += $samMatches
    }

    # Signal 5: Full name match (givenName + surname)
    if ($enabledSignals['fullNameMatch'].enabled) {
        $signal = $enabledSignals['fullNameMatch']
        $nameMatches = 0
        foreach ($key in $byFullName.Keys) {
            $group = $byFullName[$key]
            if ($group.Count -gt 1) {
                $first = $group[0]
                for ($i = 1; $i -lt $group.Count; $i++) {
                    Merge-Sets -id1 $first.id -id2 $group[$i].id
                    Add-Evidence -id1 $first.id -id2 $group[$i].id -signal 'fullNameMatch' -confidence $signal.confidence -detail "name=$key"
                    $nameMatches++
                }
            }
        }
        Write-Host "  fullNameMatch matches: $nameMatches" -ForegroundColor Gray
        $matchCount += $nameMatches
    }

    # Signal 6: Display name fuzzy match
    if ($enabledSignals['displayNameFuzzy'].enabled) {
        $signal = $enabledSignals['displayNameFuzzy']
        $fuzzyMatches = 0
        foreach ($key in $byCleanDisplayName.Keys) {
            $group = $byCleanDisplayName[$key]
            if ($group.Count -gt 1) {
                $first = $group[0]
                for ($i = 1; $i -lt $group.Count; $i++) {
                    Merge-Sets -id1 $first.id -id2 $group[$i].id
                    Add-Evidence -id1 $first.id -id2 $group[$i].id -signal 'displayNameFuzzy' -confidence $signal.confidence -detail "cleanName=$key"
                    $fuzzyMatches++
                }
            }
        }
        Write-Host "  displayNameFuzzy matches: $fuzzyMatches" -ForegroundColor Gray
        $matchCount += $fuzzyMatches
    }

    # Signal 7: Mail base name match
    if ($enabledSignals['mailBaseName'].enabled) {
        $signal = $enabledSignals['mailBaseName']
        $mailMatches = 0
        foreach ($base in $byMailBase.Keys) {
            $group = $byMailBase[$base]
            if ($group.Count -gt 1) {
                $first = $group[0]
                for ($i = 1; $i -lt $group.Count; $i++) {
                    Merge-Sets -id1 $first.id -id2 $group[$i].id
                    Add-Evidence -id1 $first.id -id2 $group[$i].id -signal 'mailBaseName' -confidence $signal.confidence -detail "mailBase=$base"
                    $mailMatches++
                }
            }
        }
        Write-Host "  mailBaseName matches: $mailMatches" -ForegroundColor Gray
        $matchCount += $mailMatches
    }

    Write-Host "  Total correlation matches: $matchCount" -ForegroundColor Gray

    # ── 9. Group accounts into identities ──
    Write-Host "`n--- Building Identities ---" -ForegroundColor Cyan

    # Group by root
    $identityGroups = @{}
    foreach ($a in $correlatable) {
        $root = Find-Root -id $a.id
        if (-not $identityGroups.ContainsKey($root)) { $identityGroups[$root] = @() }
        $identityGroups[$root] += $a
    }

    # Also include excluded accounts as single-account identities
    $excludedAccounts = $accounts | Where-Object { $_.id -notin ($correlatable | ForEach-Object { $_.id }) }
    foreach ($a in $excludedAccounts) {
        $identityGroups[$a.id] = @($a)
    }

    $multiAccountIdentities = ($identityGroups.Values | Where-Object { $_.Count -gt 1 }).Count
    $singleAccountIdentities = ($identityGroups.Values | Where-Object { $_.Count -eq 1 }).Count
    Write-Host "  Identities with multiple accounts: $multiAccountIdentities" -ForegroundColor Gray
    Write-Host "  Single-account identities: $singleAccountIdentities" -ForegroundColor Gray
    Write-Host "  Total identities: $($identityGroups.Count)" -ForegroundColor Gray

    # ── 10. Determine primary account and build identity records ──
    Write-Host "`n--- Selecting Primary Accounts ---" -ForegroundColor Cyan

    $preferenceOrder = @{}
    $prefList = $settings.primaryAccountPreference
    for ($i = 0; $i -lt $prefList.Count; $i++) {
        $preferenceOrder[$prefList[$i]] = $i
    }

    $identities = @{}
    $identityMembers = @()
    # Truncate to seconds to avoid datetime vs datetime2 precision mismatch in SQL comparisons
    $now = [DateTime]::UtcNow
    $correlatedAt = [DateTime]::new($now.Year, $now.Month, $now.Day, $now.Hour, $now.Minute, $now.Second, [System.DateTimeKind]::Utc)

    foreach ($root in $identityGroups.Keys) {
        $group = $identityGroups[$root]

        # Select primary account: prefer HR-authoritative > Regular > enabled
        $sorted = @($group | Sort-Object {
            $hr = if ($_.isHrAuthoritative) { 0 } else { 1 }
            $pref = if ($preferenceOrder.ContainsKey($_.accountType)) { $preferenceOrder[$_.accountType] } else { 99 }
            $enabled = if ($_.accountEnabled -eq 'True') { 0 } else { 1 }
            $hr * 10000 + $pref * 100 + $enabled
        })
        $primary = $sorted[0]

        # Calculate overall confidence from evidence
        $maxConfidence = 0
        $allSignals = @()
        foreach ($a in $group) {
            foreach ($b in $group) {
                if ($a.id -ge $b.id) { continue }
                $pairKey = @($a.id, $b.id) | Sort-Object
                $eKey = "$($pairKey[0])|$($pairKey[1])"
                if ($correlationEvidence.ContainsKey($eKey)) {
                    foreach ($ev in $correlationEvidence[$eKey]) {
                        if ($ev.confidence -gt $maxConfidence) { $maxConfidence = $ev.confidence }
                        $allSignals += $ev.signal
                    }
                }
            }
        }

        # Boost confidence when multiple signals agree
        $uniqueSignals = $allSignals | Select-Object -Unique
        $boost = 0
        foreach ($sig in $uniqueSignals) {
            if ($enabledSignals.ContainsKey($sig)) {
                $boost += $enabledSignals[$sig].boost
            }
        }
        $confidence = [Math]::Min(100, $maxConfidence + $boost)
        if ($group.Count -eq 1) { $confidence = 100 }  # Single account = certain

        # Build identity ID (deterministic from primary account)
        $identityId = $primary.id
        if (-not $identityId) { continue }  # Skip if no valid ID

        # Collect account types in this identity
        $accountTypes = ($group | ForEach-Object { $_.accountType } | Select-Object -Unique | Sort-Object) -join ','

        # Determine HR anchoring and orphan status
        $hrAnchor = $group | Where-Object { $_.isHrAuthoritative } | Select-Object -First 1
        $isHrAnchored = $null -ne $hrAnchor
        $hrAccountId = if ($hrAnchor) { $hrAnchor.id } else { $null }

        # Orphan detection
        $orphanStatus = $null
        if ($hrEnabled -and -not $isHrAnchored) {
            $hasRegular = $group | Where-Object { $_.accountType -eq 'Regular' }
            $allDisabled = -not ($group | Where-Object { $_.accountEnabled -eq 'True' })

            if ($allDisabled) {
                $orphanStatus = "disabled-no-anchor"
            } elseif (-not $hasRegular) {
                $orphanStatus = "no-regular-account"
            } else {
                $orphanStatus = "no-hr-anchor"
            }
        }

        $identities[$identityId] = @{
            id                      = $identityId
            displayName             = $primary.displayName
            primaryAccountId        = $primary.id
            primaryAccountUpn       = $primary.upn
            accountCount            = $group.Count
            accountTypes            = $accountTypes
            correlationConfidence   = $confidence
            correlationSignals      = ($uniqueSignals | Select-Object -Unique | Sort-Object) -join ','
            department              = $primary.department
            jobTitle                = (Get-Val $primary.row 'jobTitle')
            managerId               = $primary.managerId
            mail                    = $primary.mail
            givenName               = $primary.givenName
            surname                 = $primary.surname
            employeeId              = $primary.employeeId
            companyName             = (Get-Val $primary.row 'companyName')
            employeeType            = (Get-Val $primary.row 'employeeType')
            city                    = (Get-Val $primary.row 'city')
            country                 = (Get-Val $primary.row 'country')
            officeLocation          = (Get-Val $primary.row 'officeLocation')
            accountEnabled          = $primary.accountEnabled
            isHrAnchored            = $isHrAnchored
            hrAccountId             = $hrAccountId
            orphanStatus            = $orphanStatus
            correlatedAt            = $correlatedAt
            analystVerified         = $false
        }

        # Build member records for ALL accounts in this identity
        foreach ($a in $group) {
            # Collect evidence for this specific account
            $memberSignals = @()
            $memberConfidence = if ($a.id -eq $primary.id) { 100 } else { 0 }

            foreach ($other in $group) {
                if ($a.id -eq $other.id) { continue }
                $pairKey = @($a.id, $other.id) | Sort-Object
                $eKey = "$($pairKey[0])|$($pairKey[1])"
                if ($correlationEvidence.ContainsKey($eKey)) {
                    foreach ($ev in $correlationEvidence[$eKey]) {
                        $memberSignals += "$($ev.signal):$($ev.detail)"
                        if ($ev.confidence -gt $memberConfidence) { $memberConfidence = $ev.confidence }
                    }
                }
            }

            $identityMembers += @{
                identityId          = $identityId
                userId              = $a.id
                userPrincipalName   = $a.upn
                displayName         = $a.displayName
                accountType         = $a.accountType
                accountTypePattern  = $a.matchedPattern
                isPrimary           = ($a.id -eq $primary.id)
                signalConfidence    = $memberConfidence
                correlationSignals  = ($memberSignals -join '; ')
                accountEnabled      = $a.accountEnabled
                isHrAuthoritative   = $a.isHrAuthoritative
                hrScore             = $a.hrScore
                hrIndicators        = $a.hrIndicators
            }
        }
    }

    # ── 11. Ensure SQL tables exist ──
    Write-Host "`n--- Persisting to SQL ---" -ForegroundColor Cyan

    # Check if new-model tables exist (Identities / IdentityMembers)
    $useNewIdentityTables = $false
    $newIdentityTablesExist = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = "SELECT OBJECT_ID('dbo.Identities', 'U') AS identitiesExists, OBJECT_ID('dbo.IdentityMembers', 'U') AS membersExists"
        $reader = $cmd.ExecuteReader()
        $reader.Read()
        $idExists = ($null -ne $reader[0] -and $reader[0] -isnot [DBNull])
        $memExists = ($null -ne $reader[1] -and $reader[1] -isnot [DBNull])
        $reader.Close()
        return @{ identities = $idExists; members = $memExists }
    }
    if ($newIdentityTablesExist.identities -and $newIdentityTablesExist.members) {
        $useNewIdentityTables = $true
        Write-Host "  Detected Identities + IdentityMembers tables (new model)" -ForegroundColor Gray
    }

    # Check if legacy identity tables exist
    $tablesExist = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'GraphIdentities' AND TABLE_SCHEMA = 'dbo'"
        return [int]$cmd.ExecuteScalar() -gt 0
    }

    if (-not $tablesExist) {
        Write-Host "  Creating GraphIdentities table..." -ForegroundColor Gray
        $identityColumns = [ordered]@{
            'id'                    = 'NVARCHAR(36) NOT NULL'
            'displayName'           = 'NVARCHAR(500) NULL'
            'primaryAccountId'      = 'NVARCHAR(36) NOT NULL'
            'primaryAccountUpn'     = 'NVARCHAR(500) NULL'
            'accountCount'          = 'INT NOT NULL'
            'accountTypes'          = 'NVARCHAR(200) NULL'
            'correlationConfidence' = 'INT NOT NULL'
            'correlationSignals'    = 'NVARCHAR(MAX) NULL'
            'department'            = 'NVARCHAR(255) NULL'
            'jobTitle'              = 'NVARCHAR(255) NULL'
            'managerId'             = 'NVARCHAR(36) NULL'
            'mail'                  = 'NVARCHAR(255) NULL'
            'givenName'             = 'NVARCHAR(255) NULL'
            'surname'               = 'NVARCHAR(255) NULL'
            'employeeId'            = 'NVARCHAR(255) NULL'
            'companyName'           = 'NVARCHAR(255) NULL'
            'employeeType'          = 'NVARCHAR(255) NULL'
            'city'                  = 'NVARCHAR(255) NULL'
            'country'               = 'NVARCHAR(255) NULL'
            'officeLocation'        = 'NVARCHAR(255) NULL'
            'accountEnabled'        = 'NVARCHAR(10) NULL'
            'isHrAnchored'          = 'BIT NOT NULL'
            'hrAccountId'           = 'NVARCHAR(36) NULL'
            'orphanStatus'          = 'NVARCHAR(50) NULL'
            'correlatedAt'          = 'DATETIME2 NOT NULL'
            'analystVerified'       = 'BIT NOT NULL'
            'analystNotes'          = 'NVARCHAR(MAX) NULL'
        }
        Initialize-FGSQLTable -TableName 'GraphIdentities' -Columns $identityColumns -PrimaryKey 'id'
    }

    # Add new HR columns to existing table if needed
    if ($tablesExist) {
        Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            $newCols = @(
                @{ name = 'isHrAnchored'; type = 'BIT NOT NULL DEFAULT 0' }
                @{ name = 'hrAccountId'; type = 'NVARCHAR(36) NULL' }
                @{ name = 'orphanStatus'; type = 'NVARCHAR(50) NULL' }
            )
            foreach ($col in $newCols) {
                $cmd = $connection.CreateCommand()
                $cmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'GraphIdentities' AND COLUMN_NAME = '$($col.name)'"
                if ([int]$cmd.ExecuteScalar() -eq 0) {
                    $cmd2 = $connection.CreateCommand()
                    $cmd2.CommandText = "ALTER TABLE dbo.GraphIdentities ADD [$($col.name)] $($col.type)"
                    $cmd2.ExecuteNonQuery() | Out-Null
                    Write-Host "  Added column $($col.name) to GraphIdentities" -ForegroundColor Gray
                }
            }
        }
    }

    $memberTableExists = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'GraphIdentityMembers' AND TABLE_SCHEMA = 'dbo'"
        return [int]$cmd.ExecuteScalar() -gt 0
    }

    if (-not $memberTableExists) {
        Write-Host "  Creating GraphIdentityMembers table..." -ForegroundColor Gray
        $memberColumns = [ordered]@{
            'identityId'          = 'NVARCHAR(36) NOT NULL'
            'userId'              = 'NVARCHAR(36) NOT NULL'
            'userPrincipalName'   = 'NVARCHAR(500) NULL'
            'displayName'         = 'NVARCHAR(500) NULL'
            'accountType'         = 'NVARCHAR(50) NOT NULL'
            'accountTypePattern'  = 'NVARCHAR(200) NULL'
            'isPrimary'           = 'BIT NOT NULL'
            'signalConfidence'    = 'INT NOT NULL'
            'correlationSignals'  = 'NVARCHAR(MAX) NULL'
            'accountEnabled'      = 'NVARCHAR(10) NULL'
            'isHrAuthoritative'   = 'BIT NOT NULL'
            'hrScore'             = 'INT NOT NULL'
            'hrIndicators'        = 'NVARCHAR(500) NULL'
            'analystOverride'     = 'NVARCHAR(20) NULL'
            'analystReason'       = 'NVARCHAR(MAX) NULL'
        }
        Initialize-FGSQLTable -TableName 'GraphIdentityMembers' -Columns $memberColumns -PrimaryKey @('identityId', 'userId')
    }

    # Add new HR columns to existing member table if needed
    if ($memberTableExists) {
        Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            $newCols = @(
                @{ name = 'isHrAuthoritative'; type = 'BIT NOT NULL DEFAULT 0' }
                @{ name = 'hrScore'; type = 'INT NOT NULL DEFAULT 0' }
                @{ name = 'hrIndicators'; type = 'NVARCHAR(500) NULL' }
            )
            foreach ($col in $newCols) {
                $cmd = $connection.CreateCommand()
                $cmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'GraphIdentityMembers' AND COLUMN_NAME = '$($col.name)'"
                if ([int]$cmd.ExecuteScalar() -eq 0) {
                    $cmd2 = $connection.CreateCommand()
                    $cmd2.CommandText = "ALTER TABLE dbo.GraphIdentityMembers ADD [$($col.name)] $($col.type)"
                    $cmd2.ExecuteNonQuery() | Out-Null
                    Write-Host "  Added column $($col.name) to GraphIdentityMembers" -ForegroundColor Gray
                }
            }
        }
    }

    # ── 12. Write identities in batches ──

    # Clear existing members for identities we're about to update
    Write-Host "  Clearing existing correlation data (preserving analyst overrides)..." -ForegroundColor Gray
    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandTimeout = 300
        # Preserve analyst overrides by saving them first
        $cmd.CommandText = "DELETE FROM dbo.GraphIdentityMembers WHERE analystOverride IS NULL OR analystOverride = ''"
        $cmd.ExecuteNonQuery() | Out-Null
    }

    # MERGE identities
    $batchSize = 50
    $idKeys = @($identities.Keys)
    $mergedCount = 0

    for ($i = 0; $i -lt $idKeys.Count; $i += $batchSize) {
        $batchKeys = $idKeys[$i..[Math]::Min($i + $batchSize - 1, $idKeys.Count - 1)]

        Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            foreach ($key in $batchKeys) {
                $identity = $identities[$key]
                $cmd = $connection.CreateCommand()
                $cmd.CommandTimeout = 120
                $cmd.CommandText = @"
MERGE dbo.GraphIdentities AS target
USING (SELECT @id AS id) AS source ON target.id = source.id
WHEN MATCHED THEN UPDATE SET
    displayName = @displayName,
    primaryAccountId = @primaryAccountId,
    primaryAccountUpn = @primaryAccountUpn,
    accountCount = @accountCount,
    accountTypes = @accountTypes,
    correlationConfidence = @correlationConfidence,
    correlationSignals = @correlationSignals,
    department = @department,
    jobTitle = @jobTitle,
    managerId = @managerId,
    mail = @mail,
    givenName = @givenName,
    surname = @surname,
    employeeId = @employeeId,
    companyName = @companyName,
    employeeType = @employeeType,
    city = @city,
    country = @country,
    officeLocation = @officeLocation,
    accountEnabled = @accountEnabled,
    isHrAnchored = @isHrAnchored,
    hrAccountId = @hrAccountId,
    orphanStatus = @orphanStatus,
    correlatedAt = @correlatedAt
WHEN NOT MATCHED THEN INSERT (
    id, displayName, primaryAccountId, primaryAccountUpn, accountCount, accountTypes,
    correlationConfidence, correlationSignals, department, jobTitle, managerId, mail,
    givenName, surname, employeeId, companyName, employeeType, city, country, officeLocation,
    accountEnabled, isHrAnchored, hrAccountId, orphanStatus, correlatedAt, analystVerified
) VALUES (
    @id, @displayName, @primaryAccountId, @primaryAccountUpn, @accountCount, @accountTypes,
    @correlationConfidence, @correlationSignals, @department, @jobTitle, @managerId, @mail,
    @givenName, @surname, @employeeId, @companyName, @employeeType, @city, @country, @officeLocation,
    @accountEnabled, @isHrAnchored, @hrAccountId, @orphanStatus, @correlatedAt, 0
);
"@
                $cmd.Parameters.AddWithValue("@id", $identity.id) | Out-Null
                $cmd.Parameters.AddWithValue("@displayName", $(if ($identity.displayName) { $identity.displayName } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@primaryAccountId", $identity.primaryAccountId) | Out-Null
                $cmd.Parameters.AddWithValue("@primaryAccountUpn", $(if ($identity.primaryAccountUpn) { $identity.primaryAccountUpn } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@accountCount", $identity.accountCount) | Out-Null
                $cmd.Parameters.AddWithValue("@accountTypes", $(if ($identity.accountTypes) { $identity.accountTypes } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@correlationConfidence", $identity.correlationConfidence) | Out-Null
                $cmd.Parameters.AddWithValue("@correlationSignals", $(if ($identity.correlationSignals) { $identity.correlationSignals } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@department", $(if ($identity.department) { $identity.department } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@jobTitle", $(if ($identity.jobTitle) { $identity.jobTitle } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@managerId", $(if ($identity.managerId) { $identity.managerId } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@mail", $(if ($identity.mail) { $identity.mail } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@givenName", $(if ($identity.givenName) { $identity.givenName } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@surname", $(if ($identity.surname) { $identity.surname } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@employeeId", $(if ($identity.employeeId) { $identity.employeeId } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@companyName", $(if ($identity.companyName) { $identity.companyName } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@employeeType", $(if ($identity.employeeType) { $identity.employeeType } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@city", $(if ($identity.city) { $identity.city } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@country", $(if ($identity.country) { $identity.country } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@officeLocation", $(if ($identity.officeLocation) { $identity.officeLocation } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@accountEnabled", $(if ($identity.accountEnabled) { $identity.accountEnabled } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@isHrAnchored", [int]$identity.isHrAnchored) | Out-Null
                $cmd.Parameters.AddWithValue("@hrAccountId", $(if ($identity.hrAccountId) { $identity.hrAccountId } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@orphanStatus", $(if ($identity.orphanStatus) { $identity.orphanStatus } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@correlatedAt", $identity.correlatedAt) | Out-Null
                $cmd.ExecuteNonQuery() | Out-Null
            }
        }
        $mergedCount += $batchKeys.Count
        if ($mergedCount % 500 -eq 0 -or $mergedCount -eq $idKeys.Count) {
            Write-Host "  Identities: $mergedCount / $($idKeys.Count)" -ForegroundColor Gray
        }
    }

    # ── 13. Write identity members in batches ──
    # Filter out members that have analyst overrides (those are preserved)
    $memberBatchSize = 100
    $insertedCount = 0

    for ($i = 0; $i -lt $identityMembers.Count; $i += $memberBatchSize) {
        $batch = $identityMembers[$i..[Math]::Min($i + $memberBatchSize - 1, $identityMembers.Count - 1)]

        Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            foreach ($m in $batch) {
                $cmd = $connection.CreateCommand()
                $cmd.CommandTimeout = 120
                $cmd.CommandText = @"
MERGE dbo.GraphIdentityMembers AS target
USING (SELECT @identityId AS identityId, @userId AS userId) AS source
    ON target.identityId = source.identityId AND target.userId = source.userId
WHEN MATCHED AND (target.analystOverride IS NULL OR target.analystOverride = '') THEN UPDATE SET
    userPrincipalName = @userPrincipalName,
    displayName = @displayName,
    accountType = @accountType,
    accountTypePattern = @accountTypePattern,
    isPrimary = @isPrimary,
    signalConfidence = @signalConfidence,
    correlationSignals = @correlationSignals,
    accountEnabled = @accountEnabled,
    isHrAuthoritative = @isHrAuthoritative,
    hrScore = @hrScore,
    hrIndicators = @hrIndicators
WHEN NOT MATCHED THEN INSERT (
    identityId, userId, userPrincipalName, displayName, accountType,
    accountTypePattern, isPrimary, signalConfidence, correlationSignals, accountEnabled,
    isHrAuthoritative, hrScore, hrIndicators
) VALUES (
    @identityId, @userId, @userPrincipalName, @displayName, @accountType,
    @accountTypePattern, @isPrimary, @signalConfidence, @correlationSignals, @accountEnabled,
    @isHrAuthoritative, @hrScore, @hrIndicators
);
"@
                $cmd.Parameters.AddWithValue("@identityId", $m.identityId) | Out-Null
                $cmd.Parameters.AddWithValue("@userId", $m.userId) | Out-Null
                $cmd.Parameters.AddWithValue("@userPrincipalName", $(if ($m.userPrincipalName) { $m.userPrincipalName } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@displayName", $(if ($m.displayName) { $m.displayName } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@accountType", $m.accountType) | Out-Null
                $cmd.Parameters.AddWithValue("@accountTypePattern", $(if ($m.accountTypePattern) { $m.accountTypePattern } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@isPrimary", [int]$m.isPrimary) | Out-Null
                $cmd.Parameters.AddWithValue("@signalConfidence", $m.signalConfidence) | Out-Null
                $cmd.Parameters.AddWithValue("@correlationSignals", $(if ($m.correlationSignals) { $m.correlationSignals } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@accountEnabled", $(if ($m.accountEnabled) { $m.accountEnabled } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@isHrAuthoritative", [int]$m.isHrAuthoritative) | Out-Null
                $cmd.Parameters.AddWithValue("@hrScore", $m.hrScore) | Out-Null
                $cmd.Parameters.AddWithValue("@hrIndicators", $(if ($m.hrIndicators) { $m.hrIndicators } else { [DBNull]::Value })) | Out-Null
                $cmd.ExecuteNonQuery() | Out-Null
            }
        }
        $insertedCount += $batch.Count
        if ($insertedCount % 500 -eq 0 -or $insertedCount -eq $identityMembers.Count) {
            Write-Host "  Members: $insertedCount / $($identityMembers.Count)" -ForegroundColor Gray
        }
    }

    # ── 14. Clean up stale identities (GraphIdentities/GraphIdentityMembers) ──
    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandTimeout = 120
        $cmd.CommandText = "DELETE FROM dbo.GraphIdentityMembers WHERE identityId NOT IN (SELECT id FROM dbo.GraphIdentities WHERE correlatedAt >= @correlatedAt) AND (analystOverride IS NULL OR analystOverride = '')"
        $cmd.Parameters.AddWithValue("@correlatedAt", $correlatedAt) | Out-Null
        $staleMembers = $cmd.ExecuteNonQuery()

        $cmd2 = $connection.CreateCommand()
        $cmd2.CommandTimeout = 120
        $cmd2.CommandText = "DELETE FROM dbo.GraphIdentities WHERE correlatedAt < @correlatedAt AND analystVerified = 0"
        $cmd2.Parameters.AddWithValue("@correlatedAt", $correlatedAt) | Out-Null
        $staleIdentities = $cmd2.ExecuteNonQuery()

        if ($staleMembers -gt 0 -or $staleIdentities -gt 0) {
            Write-Host "  Cleaned up $staleIdentities stale identities and $staleMembers stale members (GraphIdentities)" -ForegroundColor Gray
        }
    }

    # ── 14b. Write to new Identities/IdentityMembers tables (if they exist) ──
    if ($useNewIdentityTables) {
        Write-Host "`n  Writing to Identities + IdentityMembers tables..." -ForegroundColor Gray

        # Ensure columns exist on Identities table (add HR columns if missing)
        Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            $newCols = @(
                @{ name = 'isHrAnchored'; type = 'BIT NOT NULL DEFAULT 0' }
                @{ name = 'hrAccountId'; type = 'NVARCHAR(36) NULL' }
                @{ name = 'orphanStatus'; type = 'NVARCHAR(50) NULL' }
            )
            foreach ($col in $newCols) {
                $cmd = $connection.CreateCommand()
                $cmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'Identities' AND COLUMN_NAME = '$($col.name)'"
                if ([int]$cmd.ExecuteScalar() -eq 0) {
                    $cmd2 = $connection.CreateCommand()
                    $cmd2.CommandText = "ALTER TABLE dbo.Identities ADD [$($col.name)] $($col.type)"
                    try { $cmd2.ExecuteNonQuery() | Out-Null } catch { }
                }
            }
        }

        # Clear existing members (preserving analyst overrides)
        Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            $cmd = $connection.CreateCommand()
            $cmd.CommandTimeout = 300
            $cmd.CommandText = "DELETE FROM dbo.IdentityMembers WHERE analystOverride IS NULL OR analystOverride = ''"
            try { $cmd.ExecuteNonQuery() | Out-Null } catch { }
        }

        # MERGE identities into Identities table
        $newIdMerged = 0
        $idKeys = @($identities.Keys)
        for ($i = 0; $i -lt $idKeys.Count; $i += $batchSize) {
            $batchKeys = $idKeys[$i..[Math]::Min($i + $batchSize - 1, $idKeys.Count - 1)]

            Invoke-FGSQLCommand -ScriptBlock {
                param($connection)
                foreach ($key in $batchKeys) {
                    $identity = $identities[$key]
                    $cmd = $connection.CreateCommand()
                    $cmd.CommandTimeout = 120
                    $cmd.CommandText = @"
MERGE dbo.Identities AS target
USING (SELECT @id AS id) AS source ON target.id = source.id
WHEN MATCHED THEN UPDATE SET
    displayName = @displayName,
    email = @email,
    primaryPrincipalId = @primaryPrincipalId,
    accountCount = @accountCount,
    accountTypes = @accountTypes,
    correlationConfidence = @correlationConfidence,
    correlationSignals = @correlationSignals,
    department = @department,
    jobTitle = @jobTitle,
    givenName = @givenName,
    surname = @surname,
    employeeId = @employeeId,
    companyName = @companyName,
    city = @city,
    country = @country,
    officeLocation = @officeLocation,
    isHrAnchored = @isHrAnchored,
    hrAccountId = @hrAccountId,
    orphanStatus = @orphanStatus,
    correlatedAt = @correlatedAt
WHEN NOT MATCHED THEN INSERT (
    id, displayName, email, primaryPrincipalId, accountCount, accountTypes,
    correlationConfidence, correlationSignals, department, jobTitle,
    givenName, surname, employeeId, companyName, city, country, officeLocation,
    isHrAnchored, hrAccountId, orphanStatus, correlatedAt, analystVerified
) VALUES (
    @id, @displayName, @email, @primaryPrincipalId, @accountCount, @accountTypes,
    @correlationConfidence, @correlationSignals, @department, @jobTitle,
    @givenName, @surname, @employeeId, @companyName, @city, @country, @officeLocation,
    @isHrAnchored, @hrAccountId, @orphanStatus, @correlatedAt, 0
);
"@
                    $cmd.Parameters.AddWithValue("@id", $identity.id) | Out-Null
                    $cmd.Parameters.AddWithValue("@displayName", $(if ($identity.displayName) { $identity.displayName } else { [DBNull]::Value })) | Out-Null
                    $cmd.Parameters.AddWithValue("@email", $(if ($identity.primaryAccountUpn) { $identity.primaryAccountUpn } elseif ($identity.mail) { $identity.mail } else { [DBNull]::Value })) | Out-Null
                    $cmd.Parameters.AddWithValue("@primaryPrincipalId", $(if ($identity.primaryAccountId) { $identity.primaryAccountId } else { [DBNull]::Value })) | Out-Null
                    $cmd.Parameters.AddWithValue("@accountCount", $identity.accountCount) | Out-Null
                    $cmd.Parameters.AddWithValue("@accountTypes", $(if ($identity.accountTypes) { $identity.accountTypes } else { [DBNull]::Value })) | Out-Null
                    $cmd.Parameters.AddWithValue("@correlationConfidence", $identity.correlationConfidence) | Out-Null
                    $cmd.Parameters.AddWithValue("@correlationSignals", $(if ($identity.correlationSignals) { $identity.correlationSignals } else { [DBNull]::Value })) | Out-Null
                    $cmd.Parameters.AddWithValue("@department", $(if ($identity.department) { $identity.department } else { [DBNull]::Value })) | Out-Null
                    $cmd.Parameters.AddWithValue("@jobTitle", $(if ($identity.jobTitle) { $identity.jobTitle } else { [DBNull]::Value })) | Out-Null
                    $cmd.Parameters.AddWithValue("@givenName", $(if ($identity.givenName) { $identity.givenName } else { [DBNull]::Value })) | Out-Null
                    $cmd.Parameters.AddWithValue("@surname", $(if ($identity.surname) { $identity.surname } else { [DBNull]::Value })) | Out-Null
                    $cmd.Parameters.AddWithValue("@employeeId", $(if ($identity.employeeId) { $identity.employeeId } else { [DBNull]::Value })) | Out-Null
                    $cmd.Parameters.AddWithValue("@companyName", $(if ($identity.companyName) { $identity.companyName } else { [DBNull]::Value })) | Out-Null
                    $cmd.Parameters.AddWithValue("@city", $(if ($identity.city) { $identity.city } else { [DBNull]::Value })) | Out-Null
                    $cmd.Parameters.AddWithValue("@country", $(if ($identity.country) { $identity.country } else { [DBNull]::Value })) | Out-Null
                    $cmd.Parameters.AddWithValue("@officeLocation", $(if ($identity.officeLocation) { $identity.officeLocation } else { [DBNull]::Value })) | Out-Null
                    $cmd.Parameters.AddWithValue("@isHrAnchored", [int]$identity.isHrAnchored) | Out-Null
                    $cmd.Parameters.AddWithValue("@hrAccountId", $(if ($identity.hrAccountId) { $identity.hrAccountId } else { [DBNull]::Value })) | Out-Null
                    $cmd.Parameters.AddWithValue("@orphanStatus", $(if ($identity.orphanStatus) { $identity.orphanStatus } else { [DBNull]::Value })) | Out-Null
                    $cmd.Parameters.AddWithValue("@correlatedAt", $identity.correlatedAt) | Out-Null
                    $cmd.ExecuteNonQuery() | Out-Null
                }
            }
            $newIdMerged += $batchKeys.Count
        }
        Write-Host "  Identities: $newIdMerged / $($idKeys.Count)" -ForegroundColor Gray

        # MERGE identity members into IdentityMembers table (using principalId instead of userId)
        $newMemInserted = 0
        for ($i = 0; $i -lt $identityMembers.Count; $i += $memberBatchSize) {
            $batch = $identityMembers[$i..[Math]::Min($i + $memberBatchSize - 1, $identityMembers.Count - 1)]

            Invoke-FGSQLCommand -ScriptBlock {
                param($connection)
                foreach ($m in $batch) {
                    $cmd = $connection.CreateCommand()
                    $cmd.CommandTimeout = 120
                    $cmd.CommandText = @"
MERGE dbo.IdentityMembers AS target
USING (SELECT @identityId AS identityId, @principalId AS principalId) AS source
    ON target.identityId = source.identityId AND target.principalId = source.principalId
WHEN MATCHED AND (target.analystOverride IS NULL OR target.analystOverride = '') THEN UPDATE SET
    displayName = @displayName,
    accountType = @accountType,
    accountTypePattern = @accountTypePattern,
    isPrimary = @isPrimary,
    signalConfidence = @signalConfidence,
    correlationSignals = @correlationSignals,
    accountEnabled = @accountEnabled,
    isHrAuthoritative = @isHrAuthoritative,
    hrScore = @hrScore,
    hrIndicators = @hrIndicators
WHEN NOT MATCHED THEN INSERT (
    identityId, principalId, displayName, accountType,
    accountTypePattern, isPrimary, signalConfidence, correlationSignals, accountEnabled,
    isHrAuthoritative, hrScore, hrIndicators
) VALUES (
    @identityId, @principalId, @displayName, @accountType,
    @accountTypePattern, @isPrimary, @signalConfidence, @correlationSignals, @accountEnabled,
    @isHrAuthoritative, @hrScore, @hrIndicators
);
"@
                    $cmd.Parameters.AddWithValue("@identityId", $m.identityId) | Out-Null
                    $cmd.Parameters.AddWithValue("@principalId", $m.userId) | Out-Null
                    $cmd.Parameters.AddWithValue("@displayName", $(if ($m.displayName) { $m.displayName } else { [DBNull]::Value })) | Out-Null
                    $cmd.Parameters.AddWithValue("@accountType", $m.accountType) | Out-Null
                    $cmd.Parameters.AddWithValue("@accountTypePattern", $(if ($m.accountTypePattern) { $m.accountTypePattern } else { [DBNull]::Value })) | Out-Null
                    $cmd.Parameters.AddWithValue("@isPrimary", [int]$m.isPrimary) | Out-Null
                    $cmd.Parameters.AddWithValue("@signalConfidence", $m.signalConfidence) | Out-Null
                    $cmd.Parameters.AddWithValue("@correlationSignals", $(if ($m.correlationSignals) { $m.correlationSignals } else { [DBNull]::Value })) | Out-Null
                    $cmd.Parameters.AddWithValue("@accountEnabled", $(if ($m.accountEnabled) { $m.accountEnabled } else { [DBNull]::Value })) | Out-Null
                    $cmd.Parameters.AddWithValue("@isHrAuthoritative", [int]$m.isHrAuthoritative) | Out-Null
                    $cmd.Parameters.AddWithValue("@hrScore", $m.hrScore) | Out-Null
                    $cmd.Parameters.AddWithValue("@hrIndicators", $(if ($m.hrIndicators) { $m.hrIndicators } else { [DBNull]::Value })) | Out-Null
                    $cmd.ExecuteNonQuery() | Out-Null
                }
            }
            $newMemInserted += $batch.Count
        }
        Write-Host "  IdentityMembers: $newMemInserted / $($identityMembers.Count)" -ForegroundColor Gray

        # Clean up stale data from new tables
        Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            $cmd = $connection.CreateCommand()
            $cmd.CommandTimeout = 120
            $cmd.CommandText = "DELETE FROM dbo.IdentityMembers WHERE identityId NOT IN (SELECT id FROM dbo.Identities WHERE correlatedAt >= @correlatedAt) AND (analystOverride IS NULL OR analystOverride = '')"
            $cmd.Parameters.AddWithValue("@correlatedAt", $correlatedAt) | Out-Null
            $staleMembers = $cmd.ExecuteNonQuery()

            $cmd2 = $connection.CreateCommand()
            $cmd2.CommandTimeout = 120
            $cmd2.CommandText = "DELETE FROM dbo.Identities WHERE correlatedAt < @correlatedAt AND analystVerified = 0"
            $cmd2.Parameters.AddWithValue("@correlatedAt", $correlatedAt) | Out-Null
            $staleIdentities = $cmd2.ExecuteNonQuery()

            if ($staleMembers -gt 0 -or $staleIdentities -gt 0) {
                Write-Host "  Cleaned up $staleIdentities stale identities and $staleMembers stale members (Identities)" -ForegroundColor Gray
            }
        }
    }

    [System.GC]::Collect()

    # ── 15. Summary ──
    $stopwatch.Stop()

    $hrAnchoredCount = ($identities.Values | Where-Object { $_.isHrAnchored }).Count
    $orphanCount = ($identities.Values | Where-Object { $_.orphanStatus }).Count

    Write-Host "`n=== Correlation Complete ===" -ForegroundColor Cyan
    $outputTables = @('GraphIdentities', 'GraphIdentityMembers')
    if ($useNewIdentityTables) { $outputTables += @('Identities', 'IdentityMembers') }
    $sourceTable = if ($usePrincipals) { "Principals" } else { "GraphUsers" }
    Write-Host "  Source:                  $sourceTable" -ForegroundColor Gray
    Write-Host "  Output tables:           $($outputTables -join ', ')" -ForegroundColor Gray
    Write-Host "  Total identities:        $($identities.Count)" -ForegroundColor Gray
    Write-Host "  Multi-account identities: $multiAccountIdentities" -ForegroundColor Gray
    Write-Host "  Single-account:          $singleAccountIdentities" -ForegroundColor Gray
    Write-Host "  Total accounts linked:   $($identityMembers.Count)" -ForegroundColor Gray
    Write-Host "  Correlation matches:     $matchCount" -ForegroundColor Gray
    if ($hrEnabled) {
        Write-Host "  HR-anchored identities:  $hrAnchoredCount" -ForegroundColor Green
        Write-Host "  HR-authoritative accounts: $hrAccountCount" -ForegroundColor Green
        Write-Host "  Orphan identities:       $orphanCount" -ForegroundColor $(if ($orphanCount -gt 0) { 'Yellow' } else { 'Gray' })
    }
    Write-Host "  Duration:                $([Math]::Round($stopwatch.Elapsed.TotalSeconds, 1))s" -ForegroundColor Gray

    # Return summary
    return [ordered]@{
        totalIdentities         = $identities.Count
        multiAccountIdentities  = $multiAccountIdentities
        singleAccountIdentities = $singleAccountIdentities
        totalAccountsLinked     = $identityMembers.Count
        correlationMatches      = $matchCount
        accountTypeCounts       = $typeCounts
        hrAnchoredIdentities    = $hrAnchoredCount
        hrAuthoritativeAccounts = $hrAccountCount
        orphanIdentities        = $orphanCount
        durationSeconds         = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
    }
}
