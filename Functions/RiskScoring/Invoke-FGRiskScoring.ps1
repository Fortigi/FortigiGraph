function Invoke-FGRiskScoring {
    <#
    .SYNOPSIS
        Runs the identity risk scoring engine against synced data in SQL.

    .DESCRIPTION
        Phase 2 of the Identity Risk Scoring architecture. This is a batch process that:

        1. Reads users, groups, and memberships from SQL (Principals, Resources, etc.)
        2. Loads the classifier ruleset (universal + customer-specific)
        3. Runs the 4-layer scoring engine on Principals and Resources:
           - Layer 1: Direct classifier match (regex patterns against names/descriptions/titles)
           - Layer 2: Membership/relationship analysis (PIM, high-risk groups, outlier detection)
           - Layer 3: Structural/hygiene signals (no description, no owner, stale accounts)
           - Layer 4: Cross-entity risk propagation (group→user 30%, user→group 25%)
        4. Writes risk scores to the RiskScores table and denormalizes riskScore+riskTier to entity tables
        5. Scores additional entity types (BusinessRoles, OrgUnits, Identities) using
           pre-computed Principal/Resource scores for aggregate calculations

        Designed for batch execution after Start-FGSync. Handles 5,000+ users and 10,000+ groups.

    .PARAMETER ClassifierRulesetPath
        Path to the classifier ruleset JSON (output of New-FGRiskClassifiers).
        If not specified, uses the universal classifiers bundled with the module.

    .PARAMETER ConfigFile
        FortigiGraph config file. Reads SQL connection and classifier path from config.

    .EXAMPLE
        # After sync, run scoring with universal classifiers only
        Connect-FGSQLServer -ConfigFile .\Config\mycompany.json
        Invoke-FGRiskScoring

    .EXAMPLE
        # With customer-specific classifiers
        Invoke-FGRiskScoring -ClassifierRulesetPath .\RiskScoring\mycompany.com\classifier-ruleset.json

    .EXAMPLE
        # Using config file for everything
        Invoke-FGRiskScoring -ConfigFile .\Config\mycompany.json
    #>

    [alias("Invoke-RiskScoring")]
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory = $false)]
        [System.String]$ClassifierRulesetPath,

        [Parameter(Mandatory = $false)]
        [System.String]$ConfigFile
    )

    $startTime = Get-Date

    # ================================================================
    # Configuration
    # ================================================================

    if ($ConfigFile) {
        if (-not (Test-Path $ConfigFile)) {
            throw "Configuration file not found: $ConfigFile"
        }
        $config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json

        # Read classifier path from config if not specified
        if ([string]::IsNullOrWhiteSpace($ClassifierRulesetPath) -and $config.RiskScoring.ClassifierRulesetPath) {
            $ClassifierRulesetPath = $config.RiskScoring.ClassifierRulesetPath
        }
    }

    # ================================================================
    # Load Resource Type Scoring Multipliers
    # ================================================================
    # Priority: 1) Config file override, 2) Risk profile (LLM-determined), 3) Defaults

    # Defaults
    $resourceTypeMultipliers = @{
        'EntraGroup'          = 1.0
        'EntraDirectoryRole'  = 1.5
        'EntraAppRole'        = 1.2
        'AzureRBACRole'       = 1.4
        'SharePointSite'      = 0.8
        'DevOpsPermission'    = 1.1
        'FileShare'           = 0.7
    }
    $resourceTypePropagation = @{
        'EntraDirectoryRole'  = 0.40
        'EntraAppRole'        = 0.35
        'EntraGroup'          = 0.30
    }
    $defaultPropagation = 0.30
    $multipliersSource = "defaults"

    # Priority 2: Load from risk profile in SQL (LLM-determined during New-FGRiskProfile)
    if ($global:FGSQLConnectionString) {
        $profileId = if ($config -and $config.RiskScoring.CustomerDomain) { $config.RiskScoring.CustomerDomain } else { $null }
        $riskProfile = Get-FGRiskProfile -Id $profileId
        if ($riskProfile -and $riskProfile.customer_profile -and $riskProfile.customer_profile.resource_type_scoring) {
            $rts = $riskProfile.customer_profile.resource_type_scoring
            if ($rts.multipliers) {
                foreach ($prop in $rts.multipliers.PSObject.Properties) {
                    $resourceTypeMultipliers[$prop.Name] = [double]$prop.Value
                }
                $multipliersSource = "risk profile (LLM-determined)"
            }
            if ($rts.propagation_weights) {
                foreach ($prop in $rts.propagation_weights.PSObject.Properties) {
                    $resourceTypePropagation[$prop.Name] = [double]$prop.Value
                }
            }
        }
    }

    # Priority 1: Config file overrides (explicit user settings take precedence)
    if ($config -and $config.RiskScoring.ResourceTypeMultipliers) {
        foreach ($prop in $config.RiskScoring.ResourceTypeMultipliers.PSObject.Properties) {
            $resourceTypeMultipliers[$prop.Name] = [double]$prop.Value
        }
        $multipliersSource = "config file (user override)"
    }
    if ($config -and $config.RiskScoring.ResourceTypePropagation) {
        foreach ($prop in $config.RiskScoring.ResourceTypePropagation.PSObject.Properties) {
            $resourceTypePropagation[$prop.Name] = [double]$prop.Value
        }
    }

    Write-Host "  Resource type multipliers: $multipliersSource" -ForegroundColor Gray
    foreach ($t in ($resourceTypeMultipliers.Keys | Sort-Object)) {
        $m = $resourceTypeMultipliers[$t]
        $color = if ($m -ge 1.3) { 'Yellow' } elseif ($m -le 0.8) { 'DarkGray' } else { 'Gray' }
        Write-Host "    $($t.PadRight(25)) x$m" -ForegroundColor $color
    }

    # Validate SQL connection — reconnect if stale or missing
    $sqlReady = $false
    if ($global:FGSQLConnectionString) {
        try {
            $testConn = New-Object System.Data.SqlClient.SqlConnection($global:FGSQLConnectionString)
            $testConn.Open()
            $testConn.Close()
            $testConn.Dispose()
            $sqlReady = $true
        } catch {
            Write-Host "  Existing SQL connection is stale, reconnecting..." -ForegroundColor Yellow
            $global:FGSQLConnectionString = $null
        }
    }

    if (-not $sqlReady) {
        if ($ConfigFile) {
            Connect-FGSQLServer -ConfigFile $ConfigFile
        } else {
            throw "Not connected to SQL Server. Run Connect-FGSQLServer first or provide -ConfigFile."
        }
    }

    # ================================================================
    # Load Classifiers
    # ================================================================

    Write-Host ""
    Write-Host "=== Identity Risk Scoring Engine ===" -ForegroundColor Cyan
    Write-Host ""

    $classifiers = $null

    # Priority 1: Explicit file path parameter
    if ($ClassifierRulesetPath) {
        if (-not (Test-Path $ClassifierRulesetPath)) {
            throw "Classifier ruleset not found: $ClassifierRulesetPath`nVerify the path and try again."
        }
        Write-Host "  Loading classifiers: $ClassifierRulesetPath" -ForegroundColor Gray
        $classifiers = Get-Content -Path $ClassifierRulesetPath -Raw | ConvertFrom-Json
    }

    # Priority 2: SQL table (primary storage, saved by New-FGRiskClassifiers)
    if (-not $classifiers -and $global:FGSQLConnectionString) {
        $sqlId = if ($config -and $config.RiskScoring.CustomerDomain) { $config.RiskScoring.CustomerDomain } else { $null }
        $classifiers = Get-FGRiskClassifiers -Id $sqlId
        if ($classifiers) {
            $src = if ($sqlId) { "SQL (id=$sqlId)" } else { "SQL (latest)" }
            Write-Host "  Loading classifiers from $src" -ForegroundColor Gray
        }
    }

    # Priority 3: Config file path (legacy/fallback)
    if (-not $classifiers -and $config -and $config.RiskScoring.ClassifierRulesetPath) {
        $configPath = $config.RiskScoring.ClassifierRulesetPath
        if (Test-Path $configPath) {
            Write-Host "  Loading classifiers: $configPath (from config)" -ForegroundColor Gray
            $classifiers = Get-Content -Path $configPath -Raw | ConvertFrom-Json
        }
    }

    # Priority 4: Universal classifiers bundled with module
    if (-not $classifiers) {
        $modulePath = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $universalPath = Join-Path $modulePath "UI" "backend" "src" "risk" "classifiers" "universal.json"
        if (Test-Path $universalPath) {
            Write-Host "  Loading universal classifiers: $universalPath" -ForegroundColor Gray
            $classifiers = Get-Content -Path $universalPath -Raw | ConvertFrom-Json
        } else {
            throw "No classifier ruleset found. Run New-FGRiskClassifiers first."
        }
    }

    $groupClassifiers = @($classifiers.groups | Where-Object { $_ })
    $userClassifiers = @($classifiers.users | Where-Object { $_ })
    Write-Host "  Classifiers: $($groupClassifiers.Count) group, $($userClassifiers.Count) user rules" -ForegroundColor Gray

    # ================================================================
    # Ensure RiskScores table exists + denormalized columns on entity tables
    # ================================================================

    Write-Host ""
    Write-Host "--- Preparing SQL Schema ---" -ForegroundColor Cyan

    # Create or verify RiskScores table
    Initialize-FGRiskScoreTables

    # Ensure denormalized riskScore + riskTier columns exist on entity tables for fast filtering
    $denormColumns = @{ 'riskScore' = 'INT'; 'riskTier' = 'NVARCHAR(20)' }
    foreach ($entityTable in @('Principals', 'Resources')) {
        try {
            $existingCols = Get-FGSQLTableSchema -TableName $entityTable
            $missing = @{}
            foreach ($col in $denormColumns.Keys) {
                if ($existingCols -notcontains $col) { $missing[$col] = $denormColumns[$col] }
            }
            if ($missing.Count -gt 0) {
                Write-Host "  Adding denormalized risk columns to $entityTable..." -ForegroundColor Gray
                Add-FGSQLTableColumn -TableName $entityTable -Columns $missing
            } else {
                Write-Host "  $($entityTable): denormalized risk columns exist" -ForegroundColor Gray
            }
        } catch {
            Write-Host "  $($entityTable): table not present (optional)" -ForegroundColor Gray
        }
    }

    # ================================================================
    # Load Data from SQL
    # ================================================================
    # Direct connection avoids Invoke-FGSQLCommand's pipeline which
    # unrolls DataTables into DataRow arrays, breaking .Rows iteration.

    Write-Host ""
    Write-Host "--- Loading Data from SQL ---" -ForegroundColor Cyan

    $dataConnection = New-Object System.Data.SqlClient.SqlConnection($global:FGSQLConnectionString)
    $dataConnection.Open()

    try {
        # Detect if Principals table exists (preferred over GraphUsers)
        $usePrincipals = $false
        $cmd = $dataConnection.CreateCommand()
        $cmd.CommandText = "SELECT OBJECT_ID('dbo.Principals', 'U')"
        $princCheck = $cmd.ExecuteScalar()
        if ($null -ne $princCheck -and $princCheck -ne [DBNull]::Value) {
            $usePrincipals = $true
        }

        if ($usePrincipals) {
            # Load from Principals with JSON extraction for backward-compatible column names
            Write-Host "  Loading users from Principals table..." -ForegroundColor Gray

            # Discover NVARCHAR columns on Principals for dynamic pattern matching
            $cmd = $dataConnection.CreateCommand()
            $cmd.CommandText = "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'Principals' AND TABLE_SCHEMA = 'dbo' AND DATA_TYPE LIKE 'nvarchar%'"
            $reader = $cmd.ExecuteReader()
            $princTextColumns = @()
            while ($reader.Read()) { $princTextColumns += $reader.GetString(0) }
            $reader.Close()

            Write-Host "  Text columns: $($princTextColumns.Count) discovered (Principals)" -ForegroundColor Gray

            # Build SELECT: real columns + JSON-extracted fields aliased for compatibility
            $princRealCols = @('id', 'managerId', 'accountEnabled', 'createdDateTime', 'displayName', 'givenName', 'surname', 'department', 'jobTitle', 'companyName', 'employeeId')
            $princTextSelect = ($princTextColumns | Where-Object { $_ -notin $princRealCols -and $_ -notin @('email', 'extendedAttributes', 'externalId', 'systemId', 'principalType') } | ForEach-Object { "[$_]" }) -join ', '

            $jsonExtracts = @(
                "email AS userPrincipalName",
                "JSON_VALUE(extendedAttributes, '$.lastSignInDateTime') AS lastSignInDateTime",
                "JSON_VALUE(extendedAttributes, '$.userType') AS userType",
                "JSON_VALUE(extendedAttributes, '$.employeeType') AS employeeType",
                "JSON_VALUE(extendedAttributes, '$.onPremisesSamAccountName') AS onPremisesSamAccountName",
                "JSON_VALUE(extendedAttributes, '$.administrativeUnits') AS administrativeUnits",
                "JSON_VALUE(extendedAttributes, '$.mail') AS mail"
            )

            $selectParts = @()
            $selectParts += ($princRealCols | ForEach-Object { "[$_]" })
            $selectParts += $jsonExtracts
            if ($princTextSelect) { $selectParts += $princTextSelect }
            $userSelectSql = $selectParts -join ', '

            $cmd = $dataConnection.CreateCommand()
            $cmd.CommandTimeout = 300
            $cmd.CommandText = "SELECT $userSelectSql FROM dbo.Principals WHERE principalType = 'User' AND ValidTo = '9999-12-31 23:59:59.9999999'"
            $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
            $users = New-Object System.Data.DataTable
            $adapter.Fill($users) | Out-Null
            Write-Host "  Users:       $($users.Rows.Count) (from Principals table)" -ForegroundColor Gray
        } else {
            # Legacy mode: load from GraphUsers
            # Discover all NVARCHAR columns on GraphUsers for dynamic pattern matching
            $cmd = $dataConnection.CreateCommand()
            $cmd.CommandText = "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'GraphUsers' AND TABLE_SCHEMA = 'dbo' AND DATA_TYPE LIKE 'nvarchar%'"
            $reader = $cmd.ExecuteReader()
            $userTextColumns = @()
            while ($reader.Read()) { $userTextColumns += $reader.GetString(0) }
            $reader.Close()

            Write-Host "  Text columns: $($userTextColumns.Count) discovered (GraphUsers)" -ForegroundColor Gray

            # Build dynamic column list: core non-text columns + all text columns
            $coreNonTextCols = @('id', 'managerId', 'accountEnabled', 'lastSignInDateTime', 'createdDateTime')
            $allUserCols = @($coreNonTextCols) + @($userTextColumns) | Select-Object -Unique
            $userSelectSql = ($allUserCols | ForEach-Object { "[$_]" }) -join ', '

            $cmd = $dataConnection.CreateCommand()
            $cmd.CommandTimeout = 300
            $cmd.CommandText = "SELECT $userSelectSql FROM dbo.GraphUsers"
            $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
            $users = New-Object System.Data.DataTable
            $adapter.Fill($users) | Out-Null
            Write-Host "  Users:       $($users.Rows.Count) (from GraphUsers — legacy mode)" -ForegroundColor Gray
        }

        # Load resources (prefer Resources table, fall back to GraphGroups)
        $useResourceModel = $false
        $resources = New-Object System.Data.DataTable
        $cmd = $dataConnection.CreateCommand()
        $cmd.CommandText = "SELECT OBJECT_ID('dbo.Resources', 'U')"
        $resCheck = $cmd.ExecuteScalar()

        if ($null -ne $resCheck -and $resCheck -ne [DBNull]::Value) {
            $useResourceModel = $true
            $cmd = $dataConnection.CreateCommand()
            $cmd.CommandTimeout = 300
            $cmd.CommandText = "SELECT id, displayName, description, resourceType, systemId, extendedAttributes, createdDateTime FROM dbo.Resources WHERE ValidTo = '9999-12-31 23:59:59.9999999'"
            $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
            $adapter.Fill($resources) | Out-Null
            Write-Host "  Resources:   $($resources.Rows.Count) (from Resources table)" -ForegroundColor Gray

            # Also load into $groups for backward compatibility with existing scoring logic
            $groups = $resources
        } else {
            $cmd = $dataConnection.CreateCommand()
            $cmd.CommandTimeout = 300
            $cmd.CommandText = "SELECT id, displayName, description, mailEnabled, securityEnabled, isAssignableToRole, membershipRuleProcessingState, groupTypeCalculated, createdDateTime FROM dbo.GraphGroups"
            $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
            $adapter.Fill($resources) | Out-Null
            $groups = $resources
            Write-Host "  Groups:      $($resources.Rows.Count) (from GraphGroups - legacy mode)" -ForegroundColor Gray
        }

        # Build resource type lookup
        $resourceTypeMap = @{}
        if ($useResourceModel) {
            foreach ($row in $resources.Rows) {
                $rId = "$($row['id'])"
                $rType = if ($null -eq $row['resourceType'] -or $row['resourceType'] -is [DBNull]) { 'EntraGroup' } else { "$($row['resourceType'])" }
                $resourceTypeMap[$rId] = $rType
            }
            # Log type breakdown
            $typeBreakdown = @{}
            foreach ($t in $resourceTypeMap.Values) {
                if (-not $typeBreakdown.ContainsKey($t)) { $typeBreakdown[$t] = 0 }
                $typeBreakdown[$t]++
            }
            foreach ($t in ($typeBreakdown.Keys | Sort-Object)) {
                Write-Host "    $($t): $($typeBreakdown[$t])" -ForegroundColor Gray
            }
        }

        # Determine permission source: prefer resource model view, then materialized, then old view
        $permSource = "vw_UserPermissionAssignments"
        $permResCol = "groupId"
        $permPrincCol = "memberId"

        $cmd = $dataConnection.CreateCommand()
        $cmd.CommandText = @"
SELECT
    OBJECT_ID('dbo.mat_UserPermissionAssignments', 'U') AS matExists,
    OBJECT_ID('dbo.vw_ResourceUserPermissionAssignments', 'V') AS resViewExists
"@
        $reader = $cmd.ExecuteReader()
        $reader.Read()
        $matExists = ($null -ne $reader[0] -and $reader[0] -isnot [DBNull])
        $resViewExists = ($null -ne $reader[1] -and $reader[1] -isnot [DBNull])
        $reader.Close()

        if ($resViewExists -and -not $matExists) {
            $permSource = "vw_ResourceUserPermissionAssignments"
            $permResCol = "resourceId"
            $permPrincCol = "principalId"
        } elseif ($matExists) {
            $permSource = "mat_UserPermissionAssignments"
        }

        $cmd = $dataConnection.CreateCommand()
        $cmd.CommandTimeout = 600
        $cmd.CommandText = "SELECT $permResCol AS resourceId, $permPrincCol AS principalId, membershipType FROM dbo.$permSource WHERE $permResCol IS NOT NULL AND $permPrincCol IS NOT NULL"
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $assignments = New-Object System.Data.DataTable
        $adapter.Fill($assignments) | Out-Null
        Write-Host "  Assignments: $($assignments.Rows.Count) (from $permSource)" -ForegroundColor Gray

        # Load owners: prefer ResourceAssignments, fall back to GraphGroupOwners
        $owners = New-Object System.Data.DataTable
        if ($useResourceModel) {
            try {
                $cmd = $dataConnection.CreateCommand()
                $cmd.CommandTimeout = 300
                $cmd.CommandText = "SELECT resourceId AS groupId, principalId AS ownerId FROM dbo.ResourceAssignments WHERE assignmentType = 'Owner' AND ValidTo = '9999-12-31 23:59:59.9999999'"
                $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
                $adapter.Fill($owners) | Out-Null
                Write-Host "  Owners:      $($owners.Rows.Count) (from ResourceAssignments)" -ForegroundColor Gray
            } catch {
                Write-Host "  Owners:      (ResourceAssignments not available)" -ForegroundColor Yellow
            }
        } else {
            try {
                $cmd = $dataConnection.CreateCommand()
                $cmd.CommandTimeout = 300
                $cmd.CommandText = "SELECT groupId, ownerId FROM dbo.GraphGroupOwners"
                $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
                $adapter.Fill($owners) | Out-Null
                Write-Host "  Owners:      $($owners.Rows.Count) (from GraphGroupOwners)" -ForegroundColor Gray
            } catch {
                Write-Host "  Owners:      (table not available)" -ForegroundColor Yellow
            }
        }
    } finally {
        if ($dataConnection.State -eq 'Open') { $dataConnection.Close() }
        $dataConnection.Dispose()
    }

    Write-MemoryUsage "after data load"

    # ================================================================
    # Helpers
    # ================================================================

    function Test-DBNull($value) { $null -eq $value -or $value -is [DBNull] }

    function Write-MemoryUsage($label) {
        $memMB = [Math]::Round([System.GC]::GetTotalMemory($false) / 1MB, 1)
        $color = if ($memMB -gt 300) { 'Yellow' } elseif ($memMB -gt 200) { 'Gray' } else { 'DarkGray' }
        Write-Host "  Memory: $memMB MB ($label)" -ForegroundColor $color
    }

    # ================================================================
    # Build Manager Hierarchy
    # ================================================================

    Write-Host ""
    Write-Host "--- Building Manager Hierarchy ---" -ForegroundColor Cyan

    $directReportsMap = @{}   # managerId -> @(userId, userId, ...)
    $managerOfMap = @{}       # userId -> managerId

    foreach ($row in $users.Rows) {
        $uId = "$($row['id'])"
        if ([string]::IsNullOrEmpty($uId)) { continue }
        $mgrId = if ((Test-DBNull $row['managerId'])) { $null } else { "$($row['managerId'])" }
        if (-not [string]::IsNullOrEmpty($mgrId)) {
            $managerOfMap[$uId] = $mgrId
            if (-not $directReportsMap.ContainsKey($mgrId)) { $directReportsMap[$mgrId] = @() }
            $directReportsMap[$mgrId] += $uId
        }
    }

    # Compute total reports (recursive subtree size) with memoization + cycle detection
    $totalReportsMap = @{}

    function Get-TotalReportsCount([string]$userId, [int]$depth = 0) {
        if ($depth -gt 50) { return 0 }  # Max depth guard
        if ($totalReportsMap.ContainsKey($userId) -and $totalReportsMap[$userId] -ge 0) {
            return $totalReportsMap[$userId]
        }
        if (-not $directReportsMap.ContainsKey($userId)) {
            $totalReportsMap[$userId] = 0
            return 0
        }
        # Mark in-progress to detect cycles
        $totalReportsMap[$userId] = -1

        $total = 0
        foreach ($reportId in $directReportsMap[$userId]) {
            $total++
            $sub = Get-TotalReportsCount $reportId ($depth + 1)
            if ($sub -gt 0) { $total += $sub }
        }

        $totalReportsMap[$userId] = $total
        return $total
    }

    # Pre-compute for all managers
    foreach ($mgrId in @($directReportsMap.Keys)) {
        $null = Get-TotalReportsCount $mgrId
    }

    $managersWithReports = $directReportsMap.Count
    $usersWithManager = $managerOfMap.Count
    Write-Host "  Users with manager:    $usersWithManager" -ForegroundColor Gray
    Write-Host "  Managers with reports: $managersWithReports" -ForegroundColor Gray

    # ================================================================
    # Build Membership Index
    # ================================================================

    Write-Host ""
    Write-Host "--- Building Membership Index ---" -ForegroundColor Cyan

    # groupId -> [memberId], userId -> [groupId], etc.
    $groupMembers = @{}
    $groupEligible = @{}
    $userMemberships = @{}
    $userEligible = @{}
    $groupOwnerMap = @{}
    $userOwnershipMap = @{}

    foreach ($row in $assignments.Rows) {
        if ((Test-DBNull $row['resourceId']) -or (Test-DBNull $row['principalId'])) { continue }
        $gId = "$($row['resourceId'])"
        $mId = "$($row['principalId'])"
        $type = if ((Test-DBNull $row['membershipType'])) { 'Direct' } else { "$($row['membershipType'])" }

        if ($type -eq 'Owner') {
            if (-not $groupOwnerMap.ContainsKey($gId)) { $groupOwnerMap[$gId] = @() }
            $groupOwnerMap[$gId] += $mId
            if (-not $userOwnershipMap.ContainsKey($mId)) { $userOwnershipMap[$mId] = @() }
            $userOwnershipMap[$mId] += $gId
        } elseif ($type -eq 'Eligible') {
            if (-not $groupEligible.ContainsKey($gId)) { $groupEligible[$gId] = @() }
            $groupEligible[$gId] += $mId
            if (-not $userEligible.ContainsKey($mId)) { $userEligible[$mId] = @() }
            $userEligible[$mId] += $gId
        } else {
            if (-not $groupMembers.ContainsKey($gId)) { $groupMembers[$gId] = @() }
            $groupMembers[$gId] += $mId
            if (-not $userMemberships.ContainsKey($mId)) { $userMemberships[$mId] = @() }
            $userMemberships[$mId] += $gId
        }
    }

    # Also index from owners table
    if ($owners -is [System.Data.DataTable]) {
        foreach ($row in $owners.Rows) {
            if ((Test-DBNull $row['groupId']) -or (Test-DBNull $row['ownerId'])) { continue }
            $gId = "$($row['groupId'])"
            $oId = "$($row['ownerId'])"
            if (-not $groupOwnerMap.ContainsKey($gId)) { $groupOwnerMap[$gId] = @() }
            if ($oId -notin $groupOwnerMap[$gId]) { $groupOwnerMap[$gId] += $oId }
        }
    }

    Write-Host "  Groups with members:  $($groupMembers.Count)" -ForegroundColor Gray
    Write-Host "  Groups with eligible: $($groupEligible.Count)" -ForegroundColor Gray
    Write-Host "  Groups with owners:   $($groupOwnerMap.Count)" -ForegroundColor Gray

    # Free DataTables now that indexes are built — they are no longer needed
    $assignments.Dispose(); $assignments = $null
    if ($owners -is [System.Data.DataTable]) { $owners.Dispose(); $owners = $null }
    [System.GC]::Collect()
    Write-MemoryUsage "after index build"

    # ================================================================
    # Pattern Matching Helper
    # ================================================================

    function Test-PatternMatch {
        param([string]$Text, [array]$Patterns)
        if ([string]::IsNullOrWhiteSpace($Text) -or -not $Patterns -or $Patterns.Count -eq 0) { return $false }
        foreach ($pattern in $Patterns) {
            try {
                if ($Text -match $pattern) { return $true }
            } catch { }
        }
        return $false
    }

    # ================================================================
    # Layer 1 — Direct Classifier Match
    # ================================================================

    Write-Host ""
    Write-Host "--- Layer 1: Direct Classifier Match ---" -ForegroundColor Cyan

    # Non-production environment patterns (OTAP: Ontwikkeling/Test/Acceptatie/Productie)
    $nonProdPatterns = @(
        '[-_](ACC|TST|DEV|ONT|STG|SBX|UAT|QA)(?:[-_\s]|$)',   # Multi-letter codes: _ACC, _TST, _DEV, etc.
        '[-_][ATDO][-_]',                                       # Single OTAP letter between delimiters: _A_, _T_
        '[-_][ATDO]$',                                          # Single OTAP letter at end: VPN_A, APP_T
        '\b(acceptat|develop|ontwikkel|staging|sandbox|non.?prod|pre.?prod)'  # Keywords
    )
    $nonProdDiscount = 0.75  # 75% score reduction for non-production groups

    $groupScores = @{}
    $groupMatchCount = 0
    $nonProdCount = 0

    foreach ($row in $groups.Rows) {
        $gId = "$($row['id'])"
        if ([string]::IsNullOrEmpty($gId)) { continue }
        $name = if ((Test-DBNull $row['displayName'])) { "" } else { "$($row['displayName'])" }
        $desc = if ((Test-DBNull $row['description'])) { "" } else { "$($row['description'])" }

        $bestScore = 0
        $matches = @()
        $directReasons = @()

        foreach ($c in $groupClassifiers) {
            $nameMatch = Test-PatternMatch -Text $name -Patterns $c.name_patterns
            $descMatch = Test-PatternMatch -Text $desc -Patterns $c.description_patterns
            if ($nameMatch -or $descMatch) {
                $matches += @{ id = $c.id; category = $c.category; score = [int]$c.base_score; rationale = $c.rationale }
                $matchedOn = @()
                if ($nameMatch) { $matchedOn += "name" }
                if ($descMatch) { $matchedOn += "description" }
                $directReasons += "Matched '$($c.id)' on $($matchedOn -join ' and ') ($($c.rationale)) [+$($c.base_score)]"
                if ([int]$c.base_score -gt $bestScore) { $bestScore = [int]$c.base_score }
            }
        }

        # Non-production environment discount: reduce score for ACC/DEV/TST/etc. groups
        if ($bestScore -gt 0) {
            $isNonProd = $false
            $nonProdMatchedOn = ""
            foreach ($pattern in $nonProdPatterns) {
                if (Test-PatternMatch -Text $name -Patterns @($pattern)) {
                    $isNonProd = $true
                    $nonProdMatchedOn = "name"
                    break
                }
                if (Test-PatternMatch -Text $desc -Patterns @($pattern)) {
                    $isNonProd = $true
                    $nonProdMatchedOn = "description"
                    break
                }
            }
            if ($isNonProd) {
                $originalScore = $bestScore
                $bestScore = [Math]::Max(5, [Math]::Round($bestScore * (1 - $nonProdDiscount)))
                $directReasons += "Non-production environment detected in $nonProdMatchedOn — score reduced from $originalScore to $bestScore [-$([int]($nonProdDiscount * 100))%]"
                $nonProdCount++
            }
        }

        # Apply resource type multiplier
        if ($useResourceModel -and $bestScore -gt 0) {
            $rType = if ($resourceTypeMap.ContainsKey($gId)) { $resourceTypeMap[$gId] } else { 'EntraGroup' }
            $multiplier = if ($resourceTypeMultipliers.ContainsKey($rType)) { $resourceTypeMultipliers[$rType] } else { 1.0 }
            if ($multiplier -ne 1.0) {
                $originalScore = $bestScore
                $bestScore = [Math]::Min(100, [Math]::Round($bestScore * $multiplier))
                $directReasons += "Resource type multiplier ($rType x$multiplier): score adjusted from $originalScore to $bestScore"
            }
        }

        if ($matches.Count -gt 0) { $groupMatchCount++ }
        if ($directReasons.Count -eq 0) { $directReasons += "No classifier patterns matched" }

        $groupScores[$gId] = @{
            directScore = $bestScore
            classifierMatches = $matches
            membershipScore = 0
            structuralScore = 0
            propagatedScore = 0
            explanation = @{
                direct = @{ score = $bestScore; reasons = $directReasons }
                membership = @{ score = 0; reasons = @() }
                structural = @{ score = 0; reasons = @() }
                propagated = @{ score = 0; reasons = @() }
            }
        }
    }
    Write-Host "  Groups matched: $groupMatchCount / $($groups.Rows.Count)" -ForegroundColor Gray
    if ($nonProdCount -gt 0) {
        Write-Host "  Non-production discount applied: $nonProdCount groups (-$([int]($nonProdDiscount * 100))%)" -ForegroundColor Yellow
    }

    $userScores = @{}
    $userMatchCount = 0

    foreach ($row in $users.Rows) {
        $uId = "$($row['id'])"
        if ([string]::IsNullOrEmpty($uId)) { continue }
        $name = if ((Test-DBNull $row['displayName'])) { "" } else { "$($row['displayName'])" }
        $title = if ((Test-DBNull $row['jobTitle'])) { "" } else { "$($row['jobTitle'])" }
        $upn = if ((Test-DBNull $row['userPrincipalName'])) { "" } else { "$($row['userPrincipalName'])" }
        $dept = if ((Test-DBNull $row['department'])) { "" } else { "$($row['department'])" }

        $bestScore = 0
        $matches = @()
        $directReasons = @()

        foreach ($c in $userClassifiers) {
            $titleMatch = Test-PatternMatch -Text $title -Patterns $c.title_patterns
            $deptMatch = Test-PatternMatch -Text $dept -Patterns $c.title_patterns
            $nameMatch = Test-PatternMatch -Text $name -Patterns $c.name_patterns
            $upnMatch = Test-PatternMatch -Text $upn -Patterns $c.upn_patterns
            if ($titleMatch -or $deptMatch -or $nameMatch -or $upnMatch) {
                $matches += @{ id = $c.id; category = $c.category; score = [int]$c.base_score; rationale = $c.rationale }
                $matchedOn = @()
                if ($titleMatch) { $matchedOn += "job title" }
                if ($deptMatch) { $matchedOn += "department" }
                if ($nameMatch) { $matchedOn += "display name" }
                if ($upnMatch) { $matchedOn += "UPN" }
                $directReasons += "Matched '$($c.id)' on $($matchedOn -join ' and ') ($($c.rationale)) [+$($c.base_score)]"
                if ([int]$c.base_score -gt $bestScore) { $bestScore = [int]$c.base_score }
            }
        }

        if ($matches.Count -gt 0) { $userMatchCount++ }
        if ($directReasons.Count -eq 0) { $directReasons += "No classifier patterns matched" }

        $userScores[$uId] = @{
            directScore = $bestScore
            classifierMatches = $matches
            membershipScore = 0
            structuralScore = 0
            propagatedScore = 0
            explanation = @{
                direct = @{ score = $bestScore; reasons = $directReasons }
                membership = @{ score = 0; reasons = @() }
                structural = @{ score = 0; reasons = @() }
                propagated = @{ score = 0; reasons = @() }
            }
        }
    }
    Write-Host "  Users matched:  $userMatchCount / $($users.Rows.Count)" -ForegroundColor Gray

    # ================================================================
    # Layer 2 — Membership/Relationship Analysis
    # ================================================================

    Write-Host ""
    Write-Host "--- Layer 2: Membership Analysis ---" -ForegroundColor Cyan

    # Score groups based on membership characteristics
    foreach ($gId in $groupScores.Keys) {
        $score = 0
        $reasons = @()
        $members = if ($groupMembers.ContainsKey($gId)) { $groupMembers[$gId] } else { @() }
        $eligible = if ($groupEligible.ContainsKey($gId)) { $groupEligible[$gId] } else { @() }
        $owners = if ($groupOwnerMap.ContainsKey($gId)) { $groupOwnerMap[$gId] } else { @() }

        # Small group = concentrated risk
        if ($members.Count -gt 0 -and $members.Count -le 5) {
            $score += 5
            $reasons += "Small group with $($members.Count) member(s) — concentrated access risk [+5]"
        }
        # Has PIM-eligible members
        if ($eligible.Count -gt 0) {
            $score += 10
            $reasons += "$($eligible.Count) PIM-eligible member(s) — indicates privileged access [+10]"
        }
        # No owner but has members
        if ($owners.Count -eq 0 -and $members.Count -gt 0) {
            $score += 5
            $reasons += "No owner assigned while having $($members.Count) member(s) — ungoverned group [+5]"
        }

        if ($reasons.Count -eq 0) { $reasons += "No membership-based risk signals detected" }
        $groupScores[$gId].membershipScore = [Math]::Min($score, 40)
        $groupScores[$gId].explanation.membership = @{ score = [Math]::Min($score, 40); reasons = $reasons }
    }

    # Score users based on their memberships
    foreach ($uId in $userScores.Keys) {
        $score = 0
        $reasons = @()
        $memberships = if ($userMemberships.ContainsKey($uId)) { $userMemberships[$uId] } else { @() }
        $ownerships = if ($userOwnershipMap.ContainsKey($uId)) { $userOwnershipMap[$uId] } else { @() }
        $eligible = if ($userEligible.ContainsKey($uId)) { $userEligible[$uId] } else { @() }

        $totalGroups = $memberships.Count + $ownerships.Count + $eligible.Count

        # High membership count
        if ($totalGroups -gt 15) {
            $points = [Math]::Min(15, [Math]::Floor(($totalGroups - 15) / 3) * 3)
            if ($points -gt 0) {
                $score += $points
                $reasons += "Member of $totalGroups groups (above threshold of 15) — broad access footprint [+$points]"
            }
        }

        # Member of high-risk groups (direct score > 70)
        $highRiskCount = 0
        $highRiskNames = @()
        foreach ($gId in $memberships) {
            if ($groupScores.ContainsKey($gId) -and $groupScores[$gId].directScore -gt 70) {
                $highRiskCount++
                # Resolve group name for explanation
                $gRow = $groups.Select("id = '$gId'")
                if ($gRow.Count -gt 0) { $highRiskNames += "$($gRow[0]['displayName'])" }
            }
        }
        if ($highRiskCount -gt 0) {
            $score += 15
            $namesList = if ($highRiskNames.Count -le 3) { $highRiskNames -join ', ' } else { ($highRiskNames[0..2] -join ', ') + " +$($highRiskNames.Count - 3) more" }
            $reasons += "Member of $highRiskCount high-risk group(s): $namesList [+15]"
        }

        # PIM-eligible
        if ($eligible.Count -gt 0) {
            $pimPoints = [Math]::Min(20, $eligible.Count * 5)
            $score += $pimPoints
            $reasons += "PIM-eligible for $($eligible.Count) group(s) — can activate privileged access [+$pimPoints]"
        }

        # Many ownerships
        if ($ownerships.Count -gt 3) {
            $score += 5
            $reasons += "Owner of $($ownerships.Count) groups — high administrative responsibility [+5]"
        }

        # Hierarchy: span of control (direct reports)
        $directCount = if ($directReportsMap.ContainsKey($uId)) { $directReportsMap[$uId].Count } else { 0 }
        if ($directCount -ge 5) {
            $spanPoints = [Math]::Min(15, 3 + [Math]::Floor(($directCount - 5) / 3) * 3)
            $score += $spanPoints
            $reasons += "$directCount direct reports — wide span of control increases blast radius [+$spanPoints]"
        }

        # Hierarchy: total org size (recursive reports)
        $totalCount = if ($totalReportsMap.ContainsKey($uId)) { $totalReportsMap[$uId] } else { 0 }
        if ($totalCount -ge 10) {
            $orgPoints = if ($totalCount -ge 100) { 15 } elseif ($totalCount -ge 50) { 12 } elseif ($totalCount -ge 25) { 10 } else { 5 }
            $score += $orgPoints
            $reasons += "$totalCount total reports in org subtree — executive pattern, high-value target [+$orgPoints]"
        }

        # Hierarchy: manager of high-risk direct reports
        if ($directCount -gt 0) {
            $highRiskReportCount = 0
            foreach ($reportId in $directReportsMap[$uId]) {
                if ($userScores.ContainsKey($reportId) -and $userScores[$reportId].directScore -gt 70) {
                    $highRiskReportCount++
                }
            }
            if ($highRiskReportCount -gt 0) {
                $mgrRiskPoints = [Math]::Min(15, $highRiskReportCount * 5)
                $score += $mgrRiskPoints
                $reasons += "Manager of $highRiskReportCount high-risk direct report(s) — inherited risk from managing sensitive roles [+$mgrRiskPoints]"
            }
        }

        if ($reasons.Count -eq 0) { $reasons += "No membership-based risk signals detected" }
        $userScores[$uId].membershipScore = [Math]::Min($score, 40)
        $userScores[$uId].explanation.membership = @{ score = [Math]::Min($score, 40); reasons = $reasons }
    }

    Write-Host "  Membership analysis complete" -ForegroundColor Gray

    # ================================================================
    # Layer 3 — Structural/Hygiene Signals
    # ================================================================

    Write-Host ""
    Write-Host "--- Layer 3: Structural Signals ---" -ForegroundColor Cyan

    foreach ($row in $groups.Rows) {
        $gId = "$($row['id'])"
        if ([string]::IsNullOrEmpty($gId)) { continue }
        $score = 0
        $reasons = @()
        $rType = if ($resourceTypeMap.ContainsKey($gId)) { $resourceTypeMap[$gId] } else { 'EntraGroup' }

        # No description (applies to all resource types)
        $descVal = "$($row['description'])"
        if ([string]::IsNullOrWhiteSpace($descVal)) {
            $score += 3
            $reasons += "No description set — poor documentation hygiene [+3]"
        }

        if ($useResourceModel) {
            # Parse extended attributes from JSON
            $extAttrs = @{}
            $extJson = if ($null -ne $row['extendedAttributes'] -and $row['extendedAttributes'] -isnot [DBNull]) { "$($row['extendedAttributes'])" } else { "" }
            if ($extJson -and $extJson -ne '') {
                try { $extAttrs = $extJson | ConvertFrom-Json -AsHashtable -ErrorAction SilentlyContinue } catch { $extAttrs = @{} }
            }

            switch ($rType) {
                'EntraGroup' {
                    # Mail-enabled security group
                    $mailEnabled = if ($extAttrs.ContainsKey('mailEnabled')) { $extAttrs['mailEnabled'] } else { $false }
                    $secEnabled = if ($extAttrs.ContainsKey('securityEnabled')) { $extAttrs['securityEnabled'] } else { $false }
                    if ($mailEnabled -and $secEnabled) {
                        $score += 3
                        $reasons += "Mail-enabled security group — dual-purpose increases attack surface [+3]"
                    }
                    # Role-assignable
                    $roleAssignable = if ($extAttrs.ContainsKey('isAssignableToRole')) { $extAttrs['isAssignableToRole'] } else { $false }
                    if ($roleAssignable) {
                        $score += 15
                        $reasons += "Role-assignable group — can be assigned Entra ID directory roles [+15]"
                    }
                    # Dynamic membership
                    $membershipRule = if ($extAttrs.ContainsKey('membershipRuleProcessingState')) { $extAttrs['membershipRuleProcessingState'] } else { "" }
                    if ($membershipRule -eq 'On') {
                        $score += 3
                        $reasons += "Dynamic membership rule active — membership changes automatically [+3]"
                    }
                }
                'EntraDirectoryRole' {
                    # All directory roles are inherently privileged
                    $score += 10
                    $reasons += "Entra ID directory role — tenant-wide administrative privilege [+10]"

                    # Check for critical roles via name patterns
                    $name = if ($null -ne $row['displayName'] -and $row['displayName'] -isnot [DBNull]) { "$($row['displayName'])" } else { "" }
                    $criticalRolePatterns = @(
                        @{ Pattern = '(?i)global\s*admin'; Points = 25; Desc = 'Global Administrator — highest privilege in tenant' }
                        @{ Pattern = '(?i)privileged\s*(role|auth)'; Points = 20; Desc = 'Privileged role/auth management — can elevate others' }
                        @{ Pattern = '(?i)(exchange|sharepoint|teams)\s*admin'; Points = 15; Desc = 'Service administrator — broad service control' }
                        @{ Pattern = '(?i)(security|compliance)\s*admin'; Points = 15; Desc = 'Security/Compliance admin — security configuration access' }
                        @{ Pattern = '(?i)(user|license|helpdesk)\s*admin'; Points = 8; Desc = 'User management role — can modify user accounts' }
                        @{ Pattern = '(?i)(application|cloud\s*app)\s*admin'; Points = 15; Desc = 'Application admin — can manage app registrations and consent' }
                        @{ Pattern = '(?i)intune.*admin'; Points = 12; Desc = 'Intune admin — device management control' }
                        @{ Pattern = '(?i)conditional\s*access'; Points = 15; Desc = 'Conditional Access admin — controls authentication policies' }
                    )
                    foreach ($crp in $criticalRolePatterns) {
                        if ($name -match $crp.Pattern) {
                            $score += $crp.Points
                            $reasons += "$($crp.Desc) [+$($crp.Points)]"
                            break  # Only match the first (most specific) pattern
                        }
                    }
                }
                'EntraAppRole' {
                    # Check app role details from extended attributes
                    $score += 5
                    $reasons += "Application role assignment — API/service access [+5]"

                    $name = if ($null -ne $row['displayName'] -and $row['displayName'] -isnot [DBNull]) { "$($row['displayName'])" } else { "" }
                    $roleValue = if ($extAttrs.ContainsKey('roleValue')) { $extAttrs['roleValue'] } else { "" }
                    $appDisplayName = if ($extAttrs.ContainsKey('appDisplayName')) { $extAttrs['appDisplayName'] } else { "" }

                    # High-risk app role patterns
                    $highRiskRolePatterns = @(
                        @{ Pattern = '(?i)(\.ReadWrite\.|\.FullControl\.|\.Manage\.)'; Points = 10; Desc = 'Write/manage permission — can modify data' }
                        @{ Pattern = '(?i)(RoleManagement|AppRoleAssignment|Directory)\.ReadWrite'; Points = 15; Desc = 'Can manage roles or directory — privilege escalation risk' }
                        @{ Pattern = '(?i)(Mail|Files|Sites)\.(ReadWrite|Send)'; Points = 8; Desc = 'Can read/write mail, files, or sites — data access risk' }
                    )
                    foreach ($hrp in $highRiskRolePatterns) {
                        if ($roleValue -match $hrp.Pattern -or $name -match $hrp.Pattern) {
                            $score += $hrp.Points
                            $reasons += "$($hrp.Desc) [+$($hrp.Points)]"
                            break
                        }
                    }

                    # First-party Microsoft app bonus
                    $firstPartyPatterns = @('Microsoft Graph', 'Office 365', 'SharePoint', 'Exchange', 'Azure AD', 'Windows Azure')
                    foreach ($fpp in $firstPartyPatterns) {
                        if ($appDisplayName -like "*$fpp*") {
                            $score += 5
                            $reasons += "First-party Microsoft application ($appDisplayName) — broad tenant access [+5]"
                            break
                        }
                    }
                }
                default {
                    # Future resource types — basic structural scoring
                    $score += 2
                    $reasons += "Resource type '$rType' — default structural assessment [+2]"
                }
            }
        } else {
            # Legacy mode: use direct column access (GraphGroups table)
            $mailEnabled = if ((Test-DBNull $row['mailEnabled'])) { $false } else { [bool]$row['mailEnabled'] }
            $secEnabled = if ((Test-DBNull $row['securityEnabled'])) { $false } else { [bool]$row['securityEnabled'] }
            if ($mailEnabled -and $secEnabled) {
                $score += 3
                $reasons += "Mail-enabled security group — dual-purpose increases attack surface [+3]"
            }
            $roleAssignable = if ((Test-DBNull $row['isAssignableToRole'])) { $false } else { [bool]$row['isAssignableToRole'] }
            if ($roleAssignable) {
                $score += 15
                $reasons += "Role-assignable group — can be assigned Entra ID directory roles [+15]"
            }
            $membershipRule = if ((Test-DBNull $row['membershipRuleProcessingState'])) { "" } else { "$($row['membershipRuleProcessingState'])" }
            if ($membershipRule -eq 'On') {
                $score += 3
                $reasons += "Dynamic membership rule active — membership changes automatically [+3]"
            }
        }

        if ($reasons.Count -eq 0) { $reasons += "No structural risk signals detected" }
        $groupScores[$gId].structuralScore = [Math]::Min($score, 40)  # Raised cap from 25 to 40 for directory roles
        $groupScores[$gId].explanation.structural = @{ score = [Math]::Min($score, 40); reasons = $reasons }
    }

    foreach ($row in $users.Rows) {
        $uId = "$($row['id'])"
        if ([string]::IsNullOrEmpty($uId)) { continue }
        $score = 0
        $reasons = @()

        # Account disabled
        $enabled = if ((Test-DBNull $row['accountEnabled'])) { $true } else { [bool]$row['accountEnabled'] }
        if (-not $enabled) {
            $score += 5
            $reasons += "Account is disabled but still has group memberships [+5]"
        }

        # Stale sign-in (90+ days)
        if ($null -ne $row['lastSignInDateTime'] -and $row['lastSignInDateTime'] -isnot [DBNull]) {
            $lastSignIn = [DateTime]$row['lastSignInDateTime']
            $daysSince = ([DateTime]::UtcNow - $lastSignIn).Days
            if ($daysSince -gt 90) {
                $score += 10
                $reasons += "Last sign-in $daysSince days ago — stale account with active permissions [+10]"
            }
        }

        # Guest user
        $userType = if ((Test-DBNull $row['userType'])) { "" } else { "$($row['userType'])" }
        if ($userType -eq 'Guest') {
            $score += 5
            $reasons += "External guest account — higher risk for data exfiltration [+5]"
        }

        if ($reasons.Count -eq 0) { $reasons += "No structural risk signals detected" }
        $userScores[$uId].structuralScore = [Math]::Min($score, 25)
        $userScores[$uId].explanation.structural = @{ score = [Math]::Min($score, 25); reasons = $reasons }
    }

    Write-Host "  Structural analysis complete" -ForegroundColor Gray

    # ================================================================
    # Layer 4 — Cross-Entity Risk Propagation
    # ================================================================

    Write-Host ""
    Write-Host "--- Layer 4: Risk Propagation ---" -ForegroundColor Cyan

    # Propagation weights now vary by resource type (configured above)
    $propagationUserToGroup = 0.25

    # Pre-propagation scores (without propagation component)
    $groupPreProp = @{}
    foreach ($gId in $groupScores.Keys) {
        $gs = $groupScores[$gId]
        $groupPreProp[$gId] = [int](0.60 * $gs.directScore + 0.25 * $gs.membershipScore + 0.15 * $gs.structuralScore)
    }

    $userPreProp = @{}
    foreach ($uId in $userScores.Keys) {
        $us = $userScores[$uId]
        $userPreProp[$uId] = [int](0.60 * $us.directScore + 0.25 * $us.membershipScore + 0.15 * $us.structuralScore)
    }

    # Resource → User: user inherits risk from their riskiest resource (type-weighted)
    foreach ($uId in $userScores.Keys) {
        $memberships = if ($userMemberships.ContainsKey($uId)) { $userMemberships[$uId] } else { @() }
        $maxPropScore = 0
        $maxResourceId = $null
        $maxResourceType = 'EntraGroup'
        foreach ($gId in $memberships) {
            if ($groupPreProp.ContainsKey($gId)) {
                $rType = if ($resourceTypeMap.ContainsKey($gId)) { $resourceTypeMap[$gId] } else { 'EntraGroup' }
                $propWeight = if ($resourceTypePropagation.ContainsKey($rType)) { $resourceTypePropagation[$rType] } else { $defaultPropagation }
                $propCandidate = [int]($groupPreProp[$gId] * $propWeight)
                if ($propCandidate -gt $maxPropScore) {
                    $maxPropScore = $propCandidate
                    $maxResourceId = $gId
                    $maxResourceType = $rType
                }
            }
        }
        $userScores[$uId].propagatedScore = $maxPropScore
        $propReasons = @()
        if ($maxPropScore -gt 0 -and $maxResourceId) {
            $gRow = $groups.Select("id = '$maxResourceId'")
            $gName = if ($gRow.Count -gt 0) { "$($gRow[0]['displayName'])" } else { $maxResourceId }
            $propWeight = if ($resourceTypePropagation.ContainsKey($maxResourceType)) { $resourceTypePropagation[$maxResourceType] } else { $defaultPropagation }
            $propReasons += "Inherits $([int]($propWeight * 100))% of riskiest $maxResourceType '$gName' (score $($groupPreProp[$maxResourceId])) = $maxPropScore [+$maxPropScore]"
        }
        if ($propReasons.Count -eq 0) { $propReasons += "No risk propagated from resource memberships" }
        $userScores[$uId].explanation.propagated = @{ score = $maxPropScore; reasons = $propReasons }
    }

    # User → Group: group inherits 25% of riskiest member
    foreach ($gId in $groupScores.Keys) {
        $members = if ($groupMembers.ContainsKey($gId)) { $groupMembers[$gId] } else { @() }
        $maxUserScore = 0
        $maxUserId = $null
        foreach ($uId in $members) {
            if ($userPreProp.ContainsKey($uId) -and $userPreProp[$uId] -gt $maxUserScore) {
                $maxUserScore = $userPreProp[$uId]
                $maxUserId = $uId
            }
        }
        $propScore = [int]($maxUserScore * $propagationUserToGroup)
        $groupScores[$gId].propagatedScore = $propScore
        $propReasons = @()
        if ($propScore -gt 0 -and $maxUserId) {
            $uRow = $users.Select("id = '$maxUserId'")
            $uName = if ($uRow.Count -gt 0) { "$($uRow[0]['displayName'])" } else { $maxUserId }
            $propReasons += "Inherits 25% of riskiest member '$uName' (score $maxUserScore) = $propScore [+$propScore]"
        }
        if ($propReasons.Count -eq 0) { $propReasons += "No risk propagated from group members" }
        $groupScores[$gId].explanation.propagated = @{ score = $propScore; reasons = $propReasons }
    }

    Write-Host "  Propagation complete" -ForegroundColor Gray

    # ================================================================
    # Calculate Final Scores
    # ================================================================

    Write-Host ""
    Write-Host "--- Calculating Final Scores ---" -ForegroundColor Cyan

    # Weights
    $wDirect = 0.50
    $wMembership = 0.20
    $wStructural = 0.10
    $wPropagated = 0.20

    function Get-RiskTier([int]$Score) {
        if ($Score -ge 90) { return "Critical" }
        if ($Score -ge 70) { return "High" }
        if ($Score -ge 40) { return "Medium" }
        if ($Score -ge 20) { return "Low" }
        if ($Score -ge 1) { return "Minimal" }
        return "None"
    }

    $scoredAt = Get-Date -Format "o"

    # Build update data for groups
    $groupUpdates = @()
    foreach ($gId in $groupScores.Keys) {
        $gs = $groupScores[$gId]
        $final = [Math]::Min(100, [int]($wDirect * $gs.directScore + $wMembership * $gs.membershipScore + $wStructural * $gs.structuralScore + $wPropagated * $gs.propagatedScore))
        $tier = Get-RiskTier -Score $final
        $matchJson = ($gs.classifierMatches | ConvertTo-Json -Depth 100 -Compress)
        if ($gs.classifierMatches.Count -eq 0) { $matchJson = "[]" }
        $explainJson = ($gs.explanation | ConvertTo-Json -Depth 100 -Compress)

        $groupUpdates += @{
            id = $gId
            riskScore = $final
            riskTier = $tier
            riskDirectScore = $gs.directScore
            riskMembershipScore = $gs.membershipScore
            riskStructuralScore = $gs.structuralScore
            riskPropagatedScore = $gs.propagatedScore
            riskClassifierMatches = $matchJson
            riskExplanation = $explainJson
        }
    }

    # Build update data for users
    $userUpdates = @()
    foreach ($uId in $userScores.Keys) {
        $us = $userScores[$uId]
        $final = [Math]::Min(100, [int]($wDirect * $us.directScore + $wMembership * $us.membershipScore + $wStructural * $us.structuralScore + $wPropagated * $us.propagatedScore))
        $tier = Get-RiskTier -Score $final
        $matchJson = ($us.classifierMatches | ConvertTo-Json -Depth 100 -Compress)
        if ($us.classifierMatches.Count -eq 0) { $matchJson = "[]" }
        $explainJson = ($us.explanation | ConvertTo-Json -Depth 100 -Compress)

        $userUpdates += @{
            id = $uId
            riskScore = $final
            riskTier = $tier
            riskDirectScore = $us.directScore
            riskMembershipScore = $us.membershipScore
            riskStructuralScore = $us.structuralScore
            riskPropagatedScore = $us.propagatedScore
            riskClassifierMatches = $matchJson
            riskExplanation = $explainJson
            riskHierarchyDirectReports = if ($directReportsMap.ContainsKey($uId)) { $directReportsMap[$uId].Count } else { 0 }
            riskHierarchyTotalReports = if ($totalReportsMap.ContainsKey($uId)) { [Math]::Max(0, $totalReportsMap[$uId]) } else { 0 }
        }
    }

    # ================================================================
    # Write Scores to SQL
    # ================================================================

    Write-MemoryUsage "after scoring"

    Write-Host ""
    Write-Host "--- Writing Scores to RiskScores Table ---" -ForegroundColor Cyan

    $batchSize = 100
    $scoredAt = [DateTime]::UtcNow

    # Helper: write a batch of scores to the RiskScores table using MERGE
    function Write-RiskScoreBatch {
        param($batch, [string]$entityType)
        Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            foreach ($item in $batch) {
                $cmd = $connection.CreateCommand()
                $cmd.CommandTimeout = 120
                $cmd.CommandText = @"
MERGE dbo.RiskScores AS target
USING (SELECT @entityId AS entityId, @entityType AS entityType) AS source
ON target.entityId = source.entityId AND target.entityType = source.entityType
WHEN MATCHED THEN UPDATE SET
    riskScore = @riskScore, riskTier = @riskTier,
    riskDirectScore = @riskDirectScore, riskMembershipScore = @riskMembershipScore,
    riskStructuralScore = @riskStructuralScore, riskPropagatedScore = @riskPropagatedScore,
    riskClassifierMatches = @riskClassifierMatches, riskExplanation = @riskExplanation,
    riskScoredAt = @riskScoredAt
WHEN NOT MATCHED THEN INSERT
    (entityId, entityType, riskScore, riskTier, riskDirectScore, riskMembershipScore,
     riskStructuralScore, riskPropagatedScore, riskClassifierMatches, riskExplanation, riskScoredAt)
VALUES
    (@entityId, @entityType, @riskScore, @riskTier, @riskDirectScore, @riskMembershipScore,
     @riskStructuralScore, @riskPropagatedScore, @riskClassifierMatches, @riskExplanation, @riskScoredAt);
"@
                $cmd.Parameters.AddWithValue("@entityId", [Guid]$item.id) | Out-Null
                $cmd.Parameters.AddWithValue("@entityType", $entityType) | Out-Null
                $cmd.Parameters.AddWithValue("@riskScore", $item.riskScore) | Out-Null
                $cmd.Parameters.AddWithValue("@riskTier", $item.riskTier) | Out-Null
                $cmd.Parameters.AddWithValue("@riskDirectScore", $item.riskDirectScore) | Out-Null
                $cmd.Parameters.AddWithValue("@riskMembershipScore", $item.riskMembershipScore) | Out-Null
                $cmd.Parameters.AddWithValue("@riskStructuralScore", $item.riskStructuralScore) | Out-Null
                $cmd.Parameters.AddWithValue("@riskPropagatedScore", $item.riskPropagatedScore) | Out-Null
                $cmd.Parameters.AddWithValue("@riskClassifierMatches", $item.riskClassifierMatches) | Out-Null
                $cmd.Parameters.AddWithValue("@riskExplanation", $item.riskExplanation) | Out-Null
                $cmd.Parameters.AddWithValue("@riskScoredAt", $scoredAt) | Out-Null
                $cmd.ExecuteNonQuery() | Out-Null
            }
        }
    }

    # Write resource scores to RiskScores
    $updated = 0
    for ($i = 0; $i -lt $groupUpdates.Count; $i += $batchSize) {
        $batch = $groupUpdates[$i..[Math]::Min($i + $batchSize - 1, $groupUpdates.Count - 1)]
        Write-RiskScoreBatch -batch $batch -entityType 'Resource'
        $updated += $batch.Count
        if ($updated % 500 -eq 0 -or $updated -eq $groupUpdates.Count) {
            Write-Host "  Resources: $updated / $($groupUpdates.Count)" -ForegroundColor Gray
        }
    }

    # Write principal scores to RiskScores
    $updated = 0
    for ($i = 0; $i -lt $userUpdates.Count; $i += $batchSize) {
        $batch = $userUpdates[$i..[Math]::Min($i + $batchSize - 1, $userUpdates.Count - 1)]
        Write-RiskScoreBatch -batch $batch -entityType 'Principal'
        $updated += $batch.Count
        if ($updated % 500 -eq 0 -or $updated -eq $userUpdates.Count) {
            Write-Host "  Principals: $updated / $($userUpdates.Count)" -ForegroundColor Gray
        }
    }

    # Denormalize riskScore + riskTier to entity tables for fast filtering
    Write-Host "  Denormalizing scores to entity tables..." -ForegroundColor Gray
    try {
        Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            $cmd = $connection.CreateCommand()
            $cmd.CommandTimeout = 120
            $cmd.CommandText = @"
UPDATE p SET p.riskScore = r.riskScore, p.riskTier = r.riskTier
FROM dbo.Principals p
INNER JOIN dbo.RiskScores r ON r.entityId = p.id AND r.entityType = 'Principal'
WHERE r.riskScoredAt = @scoredAt;

UPDATE res SET res.riskScore = r.riskScore, res.riskTier = r.riskTier
FROM dbo.Resources res
INNER JOIN dbo.RiskScores r ON r.entityId = res.id AND r.entityType = 'Resource'
WHERE r.riskScoredAt = @scoredAt;
"@
            $cmd.Parameters.AddWithValue("@scoredAt", $scoredAt) | Out-Null
            $cmd.ExecuteNonQuery() | Out-Null
        }
        Write-Host "  Denormalization complete" -ForegroundColor Green
    } catch {
        Write-Host "  WARNING: Denormalization failed: $_" -ForegroundColor Yellow
    }

    # Collect memory
    [System.GC]::Collect()
    Write-MemoryUsage "after SQL write"

    # ================================================================
    # Scoring Additional Entity Types
    # ================================================================

    Write-Host ""
    Write-Host "--- Scoring Additional Entity Types ---" -ForegroundColor Cyan

    # Open a dedicated connection for additional entity scoring
    $entityScoringConnection = New-Object System.Data.SqlClient.SqlConnection($global:FGSQLConnectionString)
    $entityScoringConnection.Open()

    try {

    # Load pre-existing Principal and Resource scores (just written) for aggregate calculations
    $principalRiskScores = @{}
    $resourceRiskScores = @{}
    try {
        $cmd = $entityScoringConnection.CreateCommand()
        $cmd.CommandTimeout = 120
        $cmd.CommandText = "SELECT entityId, riskScore, riskTier FROM dbo.RiskScores WHERE entityType = 'Principal'"
        $reader = $cmd.ExecuteReader()
        while ($reader.Read()) {
            $eId = "$($reader['entityId'])"
            $principalRiskScores[$eId] = @{ riskScore = [int]$reader['riskScore']; riskTier = "$($reader['riskTier'])" }
        }
        $reader.Close()

        $cmd2 = $entityScoringConnection.CreateCommand()
        $cmd2.CommandTimeout = 120
        $cmd2.CommandText = "SELECT entityId, riskScore, riskTier FROM dbo.RiskScores WHERE entityType = 'Resource'"
        $reader2 = $cmd2.ExecuteReader()
        while ($reader2.Read()) {
            $eId = "$($reader2['entityId'])"
            $resourceRiskScores[$eId] = @{ riskScore = [int]$reader2['riskScore']; riskTier = "$($reader2['riskTier'])" }
        }
        $reader2.Close()
        Write-Host "  Loaded $($principalRiskScores.Count) principal scores, $($resourceRiskScores.Count) resource scores for aggregation" -ForegroundColor Gray
    } catch {
        Write-Host "  WARNING: Could not load existing scores for aggregation: $_" -ForegroundColor Yellow
    }

    # ------------------------------------------------------------------
    # 1. BusinessRole Scoring
    # ------------------------------------------------------------------

    $brUpdates = @()
    try {
        # Check if Resources table exists and has BusinessRole rows
        $brExists = $false
        $cmd = $entityScoringConnection.CreateCommand()
        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.Resources WHERE resourceType = 'BusinessRole' AND ValidTo = '9999-12-31 23:59:59.9999999'"
        try {
            $result = $cmd.ExecuteScalar()
            if ($null -ne $result -and $result -isnot [DBNull] -and [int]$result -gt 0) {
                $brExists = $true
            }
        } catch {
            # Resources table doesn't exist
            $brExists = $false
        }

        if ($brExists) {
            Write-Host ""
            Write-Host "  Scoring BusinessRoles..." -ForegroundColor Cyan

            # Load BusinessRoles
            $businessRoles = @()
            $brAssignmentCounts = @{}    # brId -> assignee count
            $brResourceCounts = @{}      # brId -> resource count
            $brPolicyCounts = @{}        # brId -> policy count
            $brHasCertification = @{}    # brId -> $true/$false
            $brAssigneeIds = @{}         # brId -> @(principalId, ...)
            $brResourceIds = @{}         # brId -> @(scopeOriginId, ...)

            # Load BusinessRoles from Resources table
            $cmd = $entityScoringConnection.CreateCommand()
            $cmd.CommandTimeout = 120
            $cmd.CommandText = "SELECT id, displayName, description, catalogId FROM dbo.Resources WHERE resourceType = 'BusinessRole' AND ValidTo = '9999-12-31 23:59:59.9999999'"
            $reader = $cmd.ExecuteReader()
            while ($reader.Read()) {
                $businessRoles += @{
                    id = "$($reader['id'])"
                    displayName = if ($reader['displayName'] -is [DBNull]) { "" } else { "$($reader['displayName'])" }
                    description = if ($reader['description'] -is [DBNull]) { "" } else { "$($reader['description'])" }
                    catalogId = if ($reader['catalogId'] -is [DBNull]) { "" } else { "$($reader['catalogId'])" }
                }
            }
            $reader.Close()

            # Load assignment counts and assignee IDs per BR
            $cmd2 = $entityScoringConnection.CreateCommand()
            $cmd2.CommandTimeout = 120
            $cmd2.CommandText = "SELECT resourceId AS businessRoleId, principalId FROM dbo.ResourceAssignments WHERE assignmentType = 'Governed' AND ValidTo = '9999-12-31 23:59:59.9999999'"
            $reader2 = $cmd2.ExecuteReader()
            while ($reader2.Read()) {
                $brId = "$($reader2['businessRoleId'])"
                $assigneePrincipalId = "$($reader2['principalId'])"
                if (-not $brAssignmentCounts.ContainsKey($brId)) { $brAssignmentCounts[$brId] = 0; $brAssigneeIds[$brId] = @() }
                $brAssignmentCounts[$brId]++
                $brAssigneeIds[$brId] += $assigneePrincipalId
            }
            $reader2.Close()

            # Load resource counts and resource IDs per BR
            $cmd3 = $entityScoringConnection.CreateCommand()
            $cmd3.CommandTimeout = 120
            $cmd3.CommandText = "SELECT parentResourceId AS businessRoleId, childResourceId AS scopeOriginId FROM dbo.ResourceRelationships WHERE relationshipType = 'Contains' AND ValidTo = '9999-12-31 23:59:59.9999999'"
            $reader3 = $cmd3.ExecuteReader()
            while ($reader3.Read()) {
                $brId = "$($reader3['businessRoleId'])"
                $resId = if ($reader3['scopeOriginId'] -is [DBNull]) { "" } else { "$($reader3['scopeOriginId'])" }
                if (-not $brResourceCounts.ContainsKey($brId)) { $brResourceCounts[$brId] = 0; $brResourceIds[$brId] = @() }
                $brResourceCounts[$brId]++
                if ($resId -ne "") { $brResourceIds[$brId] += $resId }
            }
            $reader3.Close()

            # Load policy counts per BR
            $cmd4 = $entityScoringConnection.CreateCommand()
            $cmd4.CommandTimeout = 120
            $cmd4.CommandText = "SELECT resourceId AS businessRoleId, COUNT(*) AS cnt FROM dbo.AssignmentPolicies WHERE ValidTo = '9999-12-31 23:59:59.9999999' GROUP BY resourceId"
            $reader4 = $cmd4.ExecuteReader()
            while ($reader4.Read()) {
                $brPolicyCounts["$($reader4['businessRoleId'])"] = [int]$reader4['cnt']
            }
            $reader4.Close()

            # Load which BRs have certification decisions
            $cmd5 = $entityScoringConnection.CreateCommand()
            $cmd5.CommandTimeout = 120
            $cmd5.CommandText = "SELECT DISTINCT resourceId AS businessRoleId FROM dbo.CertificationDecisions WHERE ValidTo = '9999-12-31 23:59:59.9999999'"
            $reader5 = $cmd5.ExecuteReader()
            while ($reader5.Read()) {
                $brHasCertification["$($reader5['businessRoleId'])"] = $true
            }
            $reader5.Close()

            Write-Host "    Loaded $($businessRoles.Count) business roles" -ForegroundColor Gray

            if ($businessRoles.Count -gt 0) {
                foreach ($br in $businessRoles) {
                    $brId = $br.id
                    $name = $br.displayName
                    $desc = $br.description

                    # --- Direct (50%): Classifier matches on displayName/description ---
                    $bestScore = 0
                    $classifierHits = @()
                    $directReasons = @()

                    foreach ($c in $groupClassifiers) {
                        $nameMatch = Test-PatternMatch -Text $name -Patterns $c.name_patterns
                        $descMatch = Test-PatternMatch -Text $desc -Patterns $c.description_patterns
                        if ($nameMatch -or $descMatch) {
                            $classifierHits += @{ id = $c.id; category = $c.category; score = [int]$c.base_score; rationale = $c.rationale }
                            $matchedOn = @()
                            if ($nameMatch) { $matchedOn += "name" }
                            if ($descMatch) { $matchedOn += "description" }
                            $directReasons += "Matched '$($c.id)' on $($matchedOn -join ' and ') [+$($c.base_score)]"
                            if ([int]$c.base_score -gt $bestScore) { $bestScore = [int]$c.base_score }
                        }
                    }
                    $directScore = $bestScore

                    # --- Membership (20%): High-risk assignee density + count ---
                    $membershipScore = 0
                    $membershipReasons = @()
                    $assigneeCount = if ($brAssignmentCounts.ContainsKey($brId)) { $brAssignmentCounts[$brId] } else { 0 }
                    if ($assigneeCount -gt 0 -and $brAssigneeIds.ContainsKey($brId)) {
                        $highRiskCount = 0
                        foreach ($assigneePrincipalId in $brAssigneeIds[$brId]) {
                            if ($principalRiskScores.ContainsKey($assigneePrincipalId)) {
                                $pTier = $principalRiskScores[$assigneePrincipalId].riskTier
                                if ($pTier -eq 'Critical' -or $pTier -eq 'High') { $highRiskCount++ }
                            }
                        }
                        $highRiskPct = [Math]::Round(($highRiskCount / $assigneeCount) * 100, 1)
                        if ($highRiskPct -ge 50) {
                            $membershipScore += 40
                            $membershipReasons += "High-risk assignee density: $highRiskPct% ($highRiskCount/$assigneeCount) [+40]"
                        } elseif ($highRiskPct -ge 25) {
                            $membershipScore += 25
                            $membershipReasons += "Moderate high-risk assignee density: $highRiskPct% ($highRiskCount/$assigneeCount) [+25]"
                        } elseif ($highRiskPct -ge 10) {
                            $membershipScore += 15
                            $membershipReasons += "Some high-risk assignees: $highRiskPct% ($highRiskCount/$assigneeCount) [+15]"
                        }

                        # Exposure from assignee count
                        if ($assigneeCount -ge 100) {
                            $membershipScore += 20
                            $membershipReasons += "Large assignment base: $assigneeCount assignees [+20]"
                        } elseif ($assigneeCount -ge 50) {
                            $membershipScore += 10
                            $membershipReasons += "Moderate assignment base: $assigneeCount assignees [+10]"
                        } elseif ($assigneeCount -ge 20) {
                            $membershipScore += 5
                            $membershipReasons += "Notable assignment base: $assigneeCount assignees [+5]"
                        }
                    }
                    $membershipScore = [Math]::Min(100, $membershipScore)

                    # --- Structural (10%): Governance hygiene ---
                    $structuralScore = 0
                    $structuralReasons = @()
                    $resCount = if ($brResourceCounts.ContainsKey($brId)) { $brResourceCounts[$brId] } else { 0 }

                    if (-not $brHasCertification.ContainsKey($brId)) {
                        $structuralScore += 15
                        $structuralReasons += "No certification/review configured [+15]"
                    }
                    if ($resCount -ge 20) {
                        $structuralScore += 15
                        $structuralReasons += "High resource count: $resCount resources granted [+15]"
                    } elseif ($resCount -ge 10) {
                        $structuralScore += 8
                        $structuralReasons += "Moderate resource count: $resCount resources granted [+8]"
                    }
                    $polCount = if ($brPolicyCounts.ContainsKey($brId)) { $brPolicyCounts[$brId] } else { 0 }
                    if ($polCount -eq 0) {
                        $structuralScore += 10
                        $structuralReasons += "No assignment policy defined [+10]"
                    }
                    $structuralScore = [Math]::Min(100, $structuralScore)

                    # --- Propagated (20%): Aggregate risk from granted resources ---
                    $propagatedScore = 0
                    $propagatedReasons = @()
                    if ($brResourceIds.ContainsKey($brId) -and $brResourceIds[$brId].Count -gt 0) {
                        $resScores = @()
                        foreach ($rId in $brResourceIds[$brId]) {
                            if ($resourceRiskScores.ContainsKey($rId)) {
                                $resScores += $resourceRiskScores[$rId].riskScore
                            }
                        }
                        if ($resScores.Count -gt 0) {
                            $maxResScore = ($resScores | Measure-Object -Maximum).Maximum
                            $avgResScore = [Math]::Round(($resScores | Measure-Object -Average).Average, 1)
                            $propagatedScore = [int]([Math]::Max($maxResScore * 0.5, $avgResScore * 0.7))
                            $propagatedReasons += "Resource risk propagation: max=$maxResScore, avg=$avgResScore from $($resScores.Count) resources [+$propagatedScore]"
                        }
                    }
                    $propagatedScore = [Math]::Min(100, $propagatedScore)

                    # --- Final score ---
                    $final = [Math]::Min(100, [int]($wDirect * $directScore + $wMembership * $membershipScore + $wStructural * $structuralScore + $wPropagated * $propagatedScore))
                    $tier = Get-RiskTier -Score $final
                    $matchJson = ($classifierHits | ConvertTo-Json -Depth 100 -Compress)
                    if ($classifierHits.Count -eq 0) { $matchJson = "[]" }
                    $explanation = @{
                        direct = $directReasons
                        membership = $membershipReasons
                        structural = $structuralReasons
                        propagated = $propagatedReasons
                    }
                    $explainJson = ($explanation | ConvertTo-Json -Depth 100 -Compress)

                    $brUpdates += @{
                        id = $brId
                        riskScore = $final
                        riskTier = $tier
                        riskDirectScore = $directScore
                        riskMembershipScore = $membershipScore
                        riskStructuralScore = $structuralScore
                        riskPropagatedScore = $propagatedScore
                        riskClassifierMatches = $matchJson
                        riskExplanation = $explainJson
                    }
                }

                # Write BusinessRole scores
                $updated = 0
                for ($i = 0; $i -lt $brUpdates.Count; $i += $batchSize) {
                    $batch = $brUpdates[$i..[Math]::Min($i + $batchSize - 1, $brUpdates.Count - 1)]
                    Write-RiskScoreBatch -batch $batch -entityType 'BusinessRole'
                    $updated += $batch.Count
                    if ($updated % 500 -eq 0 -or $updated -eq $brUpdates.Count) {
                        Write-Host "    BusinessRoles: $updated / $($brUpdates.Count)" -ForegroundColor Gray
                    }
                }
                Write-Host "    BusinessRoles scored: $($brUpdates.Count)" -ForegroundColor Green
            } else {
                Write-Host "    No business roles found — skipping" -ForegroundColor Gray
            }
        } else {
            Write-Host "  No BusinessRole resources found — skipping" -ForegroundColor Gray
        }
    } catch {
        Write-Host "  WARNING: BusinessRole scoring failed: $_" -ForegroundColor Yellow
    }

    # ------------------------------------------------------------------
    # 2. OrgUnit Scoring
    # ------------------------------------------------------------------

    $ouUpdates = @()
    try {
        $ouExists = $false
        $cmd = $entityScoringConnection.CreateCommand()
        $cmd.CommandText = "SELECT OBJECT_ID('dbo.OrgUnits', 'U')"
        $result = $cmd.ExecuteScalar()
        if ($null -ne $result -and $result -isnot [DBNull]) {
            $ouExists = $true
        }

        if ($ouExists) {
            Write-Host ""
            Write-Host "  Scoring OrgUnits..." -ForegroundColor Cyan

            $orgUnits = @()
            $ouMemberPrincipalScores = @{}  # ouId -> @(riskScore, ...)

            # Load OrgUnits
            $cmd = $entityScoringConnection.CreateCommand()
            $cmd.CommandTimeout = 120
            $cmd.CommandText = "SELECT id, displayName, department, managerId, memberCount, totalMemberCount, parentOrgUnitId, officeLocation FROM dbo.OrgUnits WHERE ValidTo = '9999-12-31 23:59:59.9999999'"
            $reader = $cmd.ExecuteReader()
            while ($reader.Read()) {
                $orgUnits += @{
                    id = "$($reader['id'])"
                    displayName = if ($reader['displayName'] -is [DBNull]) { "" } else { "$($reader['displayName'])" }
                    department = if ($reader['department'] -is [DBNull]) { "" } else { "$($reader['department'])" }
                    managerId = if ($reader['managerId'] -is [DBNull]) { "" } else { "$($reader['managerId'])" }
                    memberCount = if ($reader['memberCount'] -is [DBNull]) { 0 } else { [int]$reader['memberCount'] }
                    totalMemberCount = if ($reader['totalMemberCount'] -is [DBNull]) { 0 } else { [int]$reader['totalMemberCount'] }
                    parentOrgUnitId = if ($reader['parentOrgUnitId'] -is [DBNull]) { "" } else { "$($reader['parentOrgUnitId'])" }
                    officeLocation = if ($reader['officeLocation'] -is [DBNull]) { "" } else { "$($reader['officeLocation'])" }
                }
            }
            $reader.Close()

            # Load principal risk scores grouped by orgUnitId (batch query)
            $cmd2 = $entityScoringConnection.CreateCommand()
            $cmd2.CommandTimeout = 120
            $cmd2.CommandText = @"
SELECT p.orgUnitId, r.riskScore
FROM dbo.Principals p
INNER JOIN dbo.RiskScores r ON r.entityId = p.id AND r.entityType = 'Principal'
WHERE p.orgUnitId IS NOT NULL AND p.ValidTo = '9999-12-31 23:59:59.9999999'
"@
            $reader2 = $cmd2.ExecuteReader()
            while ($reader2.Read()) {
                $ouId = "$($reader2['orgUnitId'])"
                if (-not $ouMemberPrincipalScores.ContainsKey($ouId)) { $ouMemberPrincipalScores[$ouId] = @() }
                $ouMemberPrincipalScores[$ouId] += [int]$reader2['riskScore']
            }
            $reader2.Close()

            Write-Host "    Loaded $($orgUnits.Count) org units" -ForegroundColor Gray

            if ($orgUnits.Count -gt 0) {
                # Build parent score lookup for propagation (two-pass: score first, propagate second)
                $ouScoresById = @{}

                foreach ($ou in $orgUnits) {
                    $ouId = $ou.id
                    $name = $ou.displayName
                    $dept = $ou.department
                    $memberCount = $ou.memberCount

                    # --- Direct (50%): Classifier matches on displayName/department ---
                    $bestScore = 0
                    $classifierHits = @()
                    $directReasons = @()

                    foreach ($c in $userClassifiers) {
                        $nameMatch = Test-PatternMatch -Text $name -Patterns $c.name_patterns
                        $deptMatch = Test-PatternMatch -Text $dept -Patterns $c.name_patterns
                        if ($nameMatch -or $deptMatch) {
                            $classifierHits += @{ id = $c.id; category = $c.category; score = [int]$c.base_score; rationale = $c.rationale }
                            $matchedOn = @()
                            if ($nameMatch) { $matchedOn += "displayName" }
                            if ($deptMatch) { $matchedOn += "department" }
                            $directReasons += "Matched '$($c.id)' on $($matchedOn -join ' and ') [+$($c.base_score)]"
                            if ([int]$c.base_score -gt $bestScore) { $bestScore = [int]$c.base_score }
                        }
                    }
                    $directScore = $bestScore

                    # Root OrgUnit bonus
                    if ($ou.parentOrgUnitId -eq "") {
                        $directScore = [Math]::Min(100, $directScore + 10)
                        $directReasons += "Root OrgUnit (no parent) [+10]"
                    }

                    # --- Membership (20%): Aggregate principal risk ---
                    $membershipScore = 0
                    $membershipReasons = @()
                    if ($ouMemberPrincipalScores.ContainsKey($ouId) -and $ouMemberPrincipalScores[$ouId].Count -gt 0) {
                        $memberScores = $ouMemberPrincipalScores[$ouId]
                        $avgScore = [Math]::Round(($memberScores | Measure-Object -Average).Average, 1)
                        $membershipScore = [int]$avgScore
                        $membershipReasons += "Average principal risk: $avgScore from $($memberScores.Count) members [+$membershipScore]"
                    }
                    $membershipScore = [Math]::Min(100, $membershipScore)

                    # --- Structural (10%): Governance signals ---
                    $structuralScore = 0
                    $structuralReasons = @()
                    if ($memberCount -lt 3 -and $memberCount -gt 0) {
                        $structuralScore += 5
                        $structuralReasons += "Very small unit ($memberCount members) — concentrated power [+5]"
                    }
                    if ($memberCount -gt 50) {
                        $structuralScore += 3
                        $structuralReasons += "Large unit ($memberCount members) — harder to govern [+3]"
                    }
                    if ($ou.managerId -eq "") {
                        $structuralScore += 5
                        $structuralReasons += "No manager assigned [+5]"
                    }
                    $structuralScore = [Math]::Min(100, $structuralScore)

                    # --- Propagated (20%): Deferred until second pass ---
                    $propagatedScore = 0
                    $propagatedReasons = @()

                    # Store intermediate score for propagation lookup
                    $prePropagate = [int]($wDirect * $directScore + $wMembership * $membershipScore + $wStructural * $structuralScore)
                    $ouScoresById[$ouId] = @{
                        directScore = $directScore
                        membershipScore = $membershipScore
                        structuralScore = $structuralScore
                        propagatedScore = 0
                        propagatedReasons = @()
                        classifierHits = $classifierHits
                        directReasons = $directReasons
                        membershipReasons = $membershipReasons
                        structuralReasons = $structuralReasons
                        prePropagate = $prePropagate
                    }
                }

                # Second pass: propagate parent OrgUnit risk down
                foreach ($ou in $orgUnits) {
                    $ouId = $ou.id
                    $parentId = $ou.parentOrgUnitId
                    if ($parentId -ne "" -and $ouScoresById.ContainsKey($parentId)) {
                        $parentPre = $ouScoresById[$parentId].prePropagate
                        $inherited = [int]($parentPre * 0.20)
                        if ($inherited -gt 0) {
                            $ouScoresById[$ouId].propagatedScore = $inherited
                            $ouScoresById[$ouId].propagatedReasons += "Inherited 20% from parent OrgUnit (score $parentPre) [+$inherited]"
                        }
                    }
                }

                # Build final updates
                foreach ($ou in $orgUnits) {
                    $ouId = $ou.id
                    $s = $ouScoresById[$ouId]
                    $final = [Math]::Min(100, [int]($wDirect * $s.directScore + $wMembership * $s.membershipScore + $wStructural * $s.structuralScore + $wPropagated * $s.propagatedScore))
                    $tier = Get-RiskTier -Score $final
                    $matchJson = ($s.classifierHits | ConvertTo-Json -Depth 100 -Compress)
                    if ($s.classifierHits.Count -eq 0) { $matchJson = "[]" }
                    $explanation = @{
                        direct = $s.directReasons
                        membership = $s.membershipReasons
                        structural = $s.structuralReasons
                        propagated = $s.propagatedReasons
                    }
                    $explainJson = ($explanation | ConvertTo-Json -Depth 100 -Compress)

                    $ouUpdates += @{
                        id = $ouId
                        riskScore = $final
                        riskTier = $tier
                        riskDirectScore = $s.directScore
                        riskMembershipScore = $s.membershipScore
                        riskStructuralScore = $s.structuralScore
                        riskPropagatedScore = $s.propagatedScore
                        riskClassifierMatches = $matchJson
                        riskExplanation = $explainJson
                    }
                }

                # Write OrgUnit scores
                $updated = 0
                for ($i = 0; $i -lt $ouUpdates.Count; $i += $batchSize) {
                    $batch = $ouUpdates[$i..[Math]::Min($i + $batchSize - 1, $ouUpdates.Count - 1)]
                    Write-RiskScoreBatch -batch $batch -entityType 'OrgUnit'
                    $updated += $batch.Count
                    if ($updated % 500 -eq 0 -or $updated -eq $ouUpdates.Count) {
                        Write-Host "    OrgUnits: $updated / $($ouUpdates.Count)" -ForegroundColor Gray
                    }
                }
                Write-Host "    OrgUnits scored: $($ouUpdates.Count)" -ForegroundColor Green
            } else {
                Write-Host "    No org units found — skipping" -ForegroundColor Gray
            }
        } else {
            Write-Host "  OrgUnits table not found — skipping" -ForegroundColor Gray
        }
    } catch {
        Write-Host "  WARNING: OrgUnit scoring failed: $_" -ForegroundColor Yellow
    }

    # ------------------------------------------------------------------
    # 3. Identity Scoring
    # ------------------------------------------------------------------

    $idUpdates = @()
    try {
        $idExists = $false
        $cmd = $entityScoringConnection.CreateCommand()
        $cmd.CommandText = "SELECT OBJECT_ID('dbo.Identities', 'U')"
        $result = $cmd.ExecuteScalar()
        if ($null -ne $result -and $result -isnot [DBNull]) {
            $idExists = $true
        }

        if ($idExists) {
            Write-Host ""
            Write-Host "  Scoring Identities..." -ForegroundColor Cyan

            $identities = @()
            $identityPrincipalIds = @{}  # identityId -> @(principalId, ...)
            $identityPrincipalSystems = @{} # identityId -> @(systemId, ...)

            # Load Identities
            $cmd = $entityScoringConnection.CreateCommand()
            $cmd.CommandTimeout = 120
            $cmd.CommandText = "SELECT id, displayName, accountCount, correlationConfidence, analystVerified, orphanStatus, accountTypes FROM dbo.Identities WHERE ValidTo = '9999-12-31 23:59:59.9999999'"
            $reader = $cmd.ExecuteReader()
            while ($reader.Read()) {
                $identities += @{
                    id = "$($reader['id'])"
                    displayName = if ($reader['displayName'] -is [DBNull]) { "" } else { "$($reader['displayName'])" }
                    accountCount = if ($reader['accountCount'] -is [DBNull]) { 0 } else { [int]$reader['accountCount'] }
                    correlationConfidence = if ($reader['correlationConfidence'] -is [DBNull]) { 1.0 } else { [double]$reader['correlationConfidence'] }
                    analystVerified = if ($reader['analystVerified'] -is [DBNull]) { $false } else { [bool]$reader['analystVerified'] }
                    orphanStatus = if ($reader['orphanStatus'] -is [DBNull]) { "" } else { "$($reader['orphanStatus'])" }
                    accountTypes = if ($reader['accountTypes'] -is [DBNull]) { "" } else { "$($reader['accountTypes'])" }
                }
            }
            $reader.Close()

            # Load identity-to-principal links with systemId
            $cmd2 = $entityScoringConnection.CreateCommand()
            $cmd2.CommandTimeout = 120
            $cmd2.CommandText = @"
SELECT im.identityId, im.principalId, p.systemId
FROM dbo.IdentityMembers im
INNER JOIN dbo.Principals p ON p.id = im.principalId AND p.ValidTo = '9999-12-31 23:59:59.9999999'
WHERE im.ValidTo = '9999-12-31 23:59:59.9999999'
"@
            $reader2 = $cmd2.ExecuteReader()
            while ($reader2.Read()) {
                $iId = "$($reader2['identityId'])"
                $linkedPrincipalId = "$($reader2['principalId'])"
                $sId = if ($reader2['systemId'] -is [DBNull]) { "" } else { "$($reader2['systemId'])" }
                if (-not $identityPrincipalIds.ContainsKey($iId)) { $identityPrincipalIds[$iId] = @(); $identityPrincipalSystems[$iId] = @() }
                $identityPrincipalIds[$iId] += $linkedPrincipalId
                if ($sId -ne "" -and $sId -notin $identityPrincipalSystems[$iId]) { $identityPrincipalSystems[$iId] += $sId }
            }
            $reader2.Close()

            Write-Host "    Loaded $($identities.Count) identities" -ForegroundColor Gray

            if ($identities.Count -gt 0) {
                foreach ($identity in $identities) {
                    $iId = $identity.id
                    $acctCount = $identity.accountCount

                    # --- Direct (50%): Account multiplicity + multi-system ---
                    $directScore = 0
                    $classifierHits = @()
                    $directReasons = @()

                    if ($acctCount -eq 2) {
                        $directScore += 10
                        $directReasons += "2 linked accounts [+10]"
                    } elseif ($acctCount -eq 3) {
                        $directScore += 20
                        $directReasons += "3 linked accounts [+20]"
                    } elseif ($acctCount -ge 4) {
                        $directScore += 30
                        $directReasons += "$acctCount linked accounts [+30]"
                    }

                    # Multi-system bonus
                    $systemCount = if ($identityPrincipalSystems.ContainsKey($iId)) { $identityPrincipalSystems[$iId].Count } else { 0 }
                    if ($systemCount -gt 1) {
                        $extraSystems = $systemCount - 1
                        $multiSystemBonus = $extraSystems * 15
                        $directScore += $multiSystemBonus
                        $directReasons += "Multi-system identity: $systemCount systems (+$multiSystemBonus for $extraSystems additional)"
                    }
                    $directScore = [Math]::Min(100, $directScore)

                    # --- Membership (20%): Highest-risk principal drives identity risk ---
                    $membershipScore = 0
                    $membershipReasons = @()
                    if ($identityPrincipalIds.ContainsKey($iId) -and $identityPrincipalIds[$iId].Count -gt 0) {
                        $maxPrincipalScore = 0
                        foreach ($linkedPrincipalId in $identityPrincipalIds[$iId]) {
                            if ($principalRiskScores.ContainsKey($linkedPrincipalId)) {
                                $pScore = $principalRiskScores[$linkedPrincipalId].riskScore
                                if ($pScore -gt $maxPrincipalScore) { $maxPrincipalScore = $pScore }
                            }
                        }
                        $membershipScore = $maxPrincipalScore
                        if ($maxPrincipalScore -gt 0) {
                            $membershipReasons += "Highest-risk linked principal: score $maxPrincipalScore [+$maxPrincipalScore]"
                        }
                    }
                    $membershipScore = [Math]::Min(100, $membershipScore)

                    # --- Structural (10%): Identity hygiene ---
                    $structuralScore = 0
                    $structuralReasons = @()
                    if ($identity.orphanStatus -ne "") {
                        $structuralScore += 15
                        $structuralReasons += "Orphaned account (status: $($identity.orphanStatus)) [+15]"
                    }
                    if ($identity.correlationConfidence -lt 0.5) {
                        $structuralScore += 10
                        $structuralReasons += "Low correlation confidence: $($identity.correlationConfidence) [+10]"
                    }
                    if ($acctCount -gt 1 -and -not $identity.analystVerified) {
                        $structuralScore += 5
                        $structuralReasons += "Multi-account identity not analyst-verified [+5]"
                    }
                    $structuralScore = [Math]::Min(100, $structuralScore)

                    # --- Propagated (20%): Critical/High principal risk propagation ---
                    $propagatedScore = 0
                    $propagatedReasons = @()
                    if ($identityPrincipalIds.ContainsKey($iId)) {
                        $maxCritHighScore = 0
                        foreach ($linkedPrincipalId in $identityPrincipalIds[$iId]) {
                            if ($principalRiskScores.ContainsKey($linkedPrincipalId)) {
                                $pTier = $principalRiskScores[$linkedPrincipalId].riskTier
                                $pScore = $principalRiskScores[$linkedPrincipalId].riskScore
                                if (($pTier -eq 'Critical' -or $pTier -eq 'High') -and $pScore -gt $maxCritHighScore) {
                                    $maxCritHighScore = $pScore
                                }
                            }
                        }
                        if ($maxCritHighScore -gt 0) {
                            $propagatedScore = [int]($maxCritHighScore * 0.30)
                            $propagatedReasons += "Propagated 30% from Critical/High principal (score $maxCritHighScore) [+$propagatedScore]"
                        }
                    }
                    $propagatedScore = [Math]::Min(100, $propagatedScore)

                    # --- Final score ---
                    $final = [Math]::Min(100, [int]($wDirect * $directScore + $wMembership * $membershipScore + $wStructural * $structuralScore + $wPropagated * $propagatedScore))
                    $tier = Get-RiskTier -Score $final
                    $matchJson = ($classifierHits | ConvertTo-Json -Depth 100 -Compress)
                    if ($classifierHits.Count -eq 0) { $matchJson = "[]" }
                    $explanation = @{
                        direct = $directReasons
                        membership = $membershipReasons
                        structural = $structuralReasons
                        propagated = $propagatedReasons
                    }
                    $explainJson = ($explanation | ConvertTo-Json -Depth 100 -Compress)

                    $idUpdates += @{
                        id = $iId
                        riskScore = $final
                        riskTier = $tier
                        riskDirectScore = $directScore
                        riskMembershipScore = $membershipScore
                        riskStructuralScore = $structuralScore
                        riskPropagatedScore = $propagatedScore
                        riskClassifierMatches = $matchJson
                        riskExplanation = $explainJson
                    }
                }

                # Write Identity scores
                $updated = 0
                for ($i = 0; $i -lt $idUpdates.Count; $i += $batchSize) {
                    $batch = $idUpdates[$i..[Math]::Min($i + $batchSize - 1, $idUpdates.Count - 1)]
                    Write-RiskScoreBatch -batch $batch -entityType 'Identity'
                    $updated += $batch.Count
                    if ($updated % 500 -eq 0 -or $updated -eq $idUpdates.Count) {
                        Write-Host "    Identities: $updated / $($idUpdates.Count)" -ForegroundColor Gray
                    }
                }
                Write-Host "    Identities scored: $($idUpdates.Count)" -ForegroundColor Green
            } else {
                Write-Host "    No identities found — skipping" -ForegroundColor Gray
            }
        } else {
            Write-Host "  Identities table not found — skipping" -ForegroundColor Gray
        }
    } catch {
        Write-Host "  WARNING: Identity scoring failed: $_" -ForegroundColor Yellow
    }

    } finally {
        # Close the dedicated entity scoring connection
        if ($entityScoringConnection -and $entityScoringConnection.State -eq 'Open') {
            $entityScoringConnection.Close()
        }
        if ($entityScoringConnection) { $entityScoringConnection.Dispose() }
    }

    # Collect memory after additional entity scoring
    [System.GC]::Collect()
    Write-MemoryUsage "after additional entity scoring"

    # ================================================================
    # Build Resource Clusters
    # ================================================================

    Write-Host ""
    Write-Host "--- Building Resource Clusters ---" -ForegroundColor Cyan

    try {
        Save-FGResourceClusters `
            -Groups $groups `
            -GroupScores $groupScores `
            -GroupUpdates $groupUpdates `
            -GroupClassifiers $groupClassifiers `
            -NonProdPatterns $nonProdPatterns `
            -ResourceTypeMap $resourceTypeMap
    } catch {
        Write-Host "  WARNING: Resource clustering failed: $_" -ForegroundColor Yellow
        Write-Host "  Risk scores were saved successfully. Clustering can be retried." -ForegroundColor Yellow
    }

    # ================================================================
    # Summary
    # ================================================================

    $endTime = Get-Date
    $duration = $endTime - $startTime

    Write-Host ""
    Write-Host "=== Risk Scoring Complete ===" -ForegroundColor Green
    Write-Host ""

    # Tier distribution
    $groupTiers = @{}
    $userTiers = @{}
    foreach ($gu in $groupUpdates) { $t = $gu.riskTier; if (-not $groupTiers.ContainsKey($t)) { $groupTiers[$t] = 0 }; $groupTiers[$t]++ }
    foreach ($uu in $userUpdates) { $t = $uu.riskTier; if (-not $userTiers.ContainsKey($t)) { $userTiers[$t] = 0 }; $userTiers[$t]++ }

    Write-Host "  Group Distribution:" -ForegroundColor Gray
    foreach ($tier in @('Critical', 'High', 'Medium', 'Low', 'Minimal', 'None')) {
        $count = if ($groupTiers.ContainsKey($tier)) { $groupTiers[$tier] } else { 0 }
        if ($count -gt 0) {
            $tierColor = switch ($tier) { 'Critical' { 'Red' } 'High' { 'Yellow' } 'Medium' { 'Yellow' } 'Low' { 'Cyan' } default { 'Gray' } }
            Write-Host "    $($tier.PadRight(10)) $count" -ForegroundColor $tierColor
        }
    }

    # Per-type distribution (when using resource model)
    if ($useResourceModel) {
        Write-Host ""
        Write-Host "  Per Resource Type:" -ForegroundColor Gray
        $typeTiers = @{}
        foreach ($gu in $groupUpdates) {
            $rType = if ($resourceTypeMap.ContainsKey($gu.id)) { $resourceTypeMap[$gu.id] } else { 'EntraGroup' }
            if (-not $typeTiers.ContainsKey($rType)) { $typeTiers[$rType] = @{ Total = 0; Scores = @() } }
            $typeTiers[$rType].Total++
            $typeTiers[$rType].Scores += $gu.riskScore
        }
        foreach ($rType in ($typeTiers.Keys | Sort-Object)) {
            $tt = $typeTiers[$rType]
            $avgScore = if ($tt.Scores.Count -gt 0) { [Math]::Round(($tt.Scores | Measure-Object -Average).Average, 1) } else { 0 }
            $multiplier = if ($resourceTypeMultipliers.ContainsKey($rType)) { $resourceTypeMultipliers[$rType] } else { 1.0 }
            Write-Host "    $($rType.PadRight(25)) $($tt.Total) resources, avg score: $avgScore (multiplier: x$multiplier)" -ForegroundColor Gray
        }
    }

    Write-Host ""
    Write-Host "  User Distribution:" -ForegroundColor Gray
    foreach ($tier in @('Critical', 'High', 'Medium', 'Low', 'Minimal', 'None')) {
        $count = if ($userTiers.ContainsKey($tier)) { $userTiers[$tier] } else { 0 }
        if ($count -gt 0) {
            $tierColor = switch ($tier) { 'Critical' { 'Red' } 'High' { 'Yellow' } 'Medium' { 'Yellow' } 'Low' { 'Cyan' } default { 'Gray' } }
            Write-Host "    $($tier.PadRight(10)) $count" -ForegroundColor $tierColor
        }
    }

    Write-Host ""
    # Additional entity tier distributions
    if ($brUpdates.Count -gt 0) {
        $brTiers = @{}
        foreach ($bu in $brUpdates) { $t = $bu.riskTier; if (-not $brTiers.ContainsKey($t)) { $brTiers[$t] = 0 }; $brTiers[$t]++ }
        Write-Host ""
        Write-Host "  BusinessRole Distribution:" -ForegroundColor Gray
        foreach ($tier in @('Critical', 'High', 'Medium', 'Low', 'Minimal', 'None')) {
            $count = if ($brTiers.ContainsKey($tier)) { $brTiers[$tier] } else { 0 }
            if ($count -gt 0) {
                $tierColor = switch ($tier) { 'Critical' { 'Red' } 'High' { 'Yellow' } 'Medium' { 'Yellow' } 'Low' { 'Cyan' } default { 'Gray' } }
                Write-Host "    $($tier.PadRight(10)) $count" -ForegroundColor $tierColor
            }
        }
    }

    if ($ouUpdates.Count -gt 0) {
        $ouTiers = @{}
        foreach ($ou in $ouUpdates) { $t = $ou.riskTier; if (-not $ouTiers.ContainsKey($t)) { $ouTiers[$t] = 0 }; $ouTiers[$t]++ }
        Write-Host ""
        Write-Host "  OrgUnit Distribution:" -ForegroundColor Gray
        foreach ($tier in @('Critical', 'High', 'Medium', 'Low', 'Minimal', 'None')) {
            $count = if ($ouTiers.ContainsKey($tier)) { $ouTiers[$tier] } else { 0 }
            if ($count -gt 0) {
                $tierColor = switch ($tier) { 'Critical' { 'Red' } 'High' { 'Yellow' } 'Medium' { 'Yellow' } 'Low' { 'Cyan' } default { 'Gray' } }
                Write-Host "    $($tier.PadRight(10)) $count" -ForegroundColor $tierColor
            }
        }
    }

    if ($idUpdates.Count -gt 0) {
        $idTiers = @{}
        foreach ($iu in $idUpdates) { $t = $iu.riskTier; if (-not $idTiers.ContainsKey($t)) { $idTiers[$t] = 0 }; $idTiers[$t]++ }
        Write-Host ""
        Write-Host "  Identity Distribution:" -ForegroundColor Gray
        foreach ($tier in @('Critical', 'High', 'Medium', 'Low', 'Minimal', 'None')) {
            $count = if ($idTiers.ContainsKey($tier)) { $idTiers[$tier] } else { 0 }
            if ($count -gt 0) {
                $tierColor = switch ($tier) { 'Critical' { 'Red' } 'High' { 'Yellow' } 'Medium' { 'Yellow' } 'Low' { 'Cyan' } default { 'Gray' } }
                Write-Host "    $($tier.PadRight(10)) $count" -ForegroundColor $tierColor
            }
        }
    }

    Write-Host ""
    Write-Host "  Duration: $($duration.ToString('mm\:ss'))" -ForegroundColor Gray
    $scoredParts = @("$($groupUpdates.Count) groups", "$($userUpdates.Count) users")
    if ($brUpdates.Count -gt 0) { $scoredParts += "$($brUpdates.Count) business roles" }
    if ($ouUpdates.Count -gt 0) { $scoredParts += "$($ouUpdates.Count) org units" }
    if ($idUpdates.Count -gt 0) { $scoredParts += "$($idUpdates.Count) identities" }
    Write-Host "  Scored:   $($scoredParts -join ', ')" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Scores persisted to RiskScores table (temporal, with history)." -ForegroundColor Gray
    Write-Host "  Denormalized riskScore + riskTier on Principals and Resources for filtering." -ForegroundColor Gray
    Write-Host "  The UI Risk Scores tab reads from RiskScores table." -ForegroundColor Gray
    Write-Host ""

    # Write sync log entry
    $totalScored = $groupUpdates.Count + $userUpdates.Count + $brUpdates.Count + $ouUpdates.Count + $idUpdates.Count
    $scoredTablesList = @('RiskScores')
    if ($usePrincipals) { $scoredTablesList += 'Principals' }
    $scoredTables = $scoredTablesList -join ','
    Write-FGSyncLog -SyncType "RiskScoring" -StartTime $startTime -RecordCount $totalScored -Status "Success" -TableName $scoredTables
}
