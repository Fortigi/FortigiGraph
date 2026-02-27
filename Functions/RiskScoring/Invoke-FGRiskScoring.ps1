function Invoke-FGRiskScoring {
    <#
    .SYNOPSIS
        Runs the identity risk scoring engine against synced data in SQL.

    .DESCRIPTION
        Phase 2 of the Identity Risk Scoring architecture. This is a batch process that:

        1. Reads users, groups, and memberships from SQL (GraphUsers, GraphGroups, etc.)
        2. Loads the classifier ruleset (universal + customer-specific)
        3. Runs the 4-layer scoring engine:
           - Layer 1: Direct classifier match (regex patterns against names/descriptions/titles)
           - Layer 2: Membership/relationship analysis (PIM, high-risk groups, outlier detection)
           - Layer 3: Structural/hygiene signals (no description, no owner, stale accounts)
           - Layer 4: Cross-entity risk propagation (group→user 30%, user→group 25%)
        4. Writes risk scores back to SQL as columns on GraphUsers and GraphGroups

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

        # Connect to SQL if not already connected
        if (-not $global:FGSQLConnectionString) {
            Connect-FGSQLServer -ConfigFile $ConfigFile
        }

        # Read classifier path from config if not specified
        if ([string]::IsNullOrWhiteSpace($ClassifierRulesetPath) -and $config.RiskScoring.ClassifierRulesetPath) {
            $ClassifierRulesetPath = $config.RiskScoring.ClassifierRulesetPath
        }
    }

    # Verify SQL connection
    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Run Connect-FGSQLServer first or provide -ConfigFile."
    }

    # ================================================================
    # Load Classifiers
    # ================================================================

    Write-Host ""
    Write-Host "=== Identity Risk Scoring Engine ===" -ForegroundColor Cyan
    Write-Host ""

    $classifiers = $null

    if ($ClassifierRulesetPath -and (Test-Path $ClassifierRulesetPath)) {
        Write-Host "  Loading classifiers: $ClassifierRulesetPath" -ForegroundColor Gray
        $classifiers = Get-Content -Path $ClassifierRulesetPath -Raw | ConvertFrom-Json
    } else {
        # Fall back to universal classifiers bundled with module
        $modulePath = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $universalPath = Join-Path $modulePath "UI" "backend" "src" "risk" "classifiers" "universal.json"
        if (Test-Path $universalPath) {
            Write-Host "  Loading universal classifiers: $universalPath" -ForegroundColor Gray
            $classifiers = Get-Content -Path $universalPath -Raw | ConvertFrom-Json
        } else {
            throw "No classifier ruleset found. Run New-FGRiskClassifiers first or provide -ClassifierRulesetPath."
        }
    }

    $groupClassifiers = @($classifiers.groups | Where-Object { $_ })
    $userClassifiers = @($classifiers.users | Where-Object { $_ })
    Write-Host "  Classifiers: $($groupClassifiers.Count) group, $($userClassifiers.Count) user rules" -ForegroundColor Gray

    # ================================================================
    # Ensure risk score columns exist on GraphUsers and GraphGroups
    # ================================================================

    Write-Host ""
    Write-Host "--- Preparing SQL Schema ---" -ForegroundColor Cyan

    $riskColumns = @{
        'riskScore'               = 'INT'
        'riskTier'                = 'NVARCHAR(20)'
        'riskDirectScore'         = 'INT'
        'riskMembershipScore'     = 'INT'
        'riskStructuralScore'     = 'INT'
        'riskPropagatedScore'     = 'INT'
        'riskClassifierMatches'   = 'NVARCHAR(MAX)'
        'riskScoredAt'            = 'DATETIME2'
    }

    foreach ($tableName in @('GraphUsers', 'GraphGroups')) {
        # Check which columns already exist
        $existingCols = @()
        try {
            $existingCols = @(Invoke-FGSQLCommand -ScriptBlock {
                param($connection)
                $cmd = $connection.CreateCommand()
                $cmd.CommandText = "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = @tableName AND TABLE_SCHEMA = 'dbo'"
                $cmd.Parameters.AddWithValue("@tableName", $tableName) | Out-Null
                $reader = $cmd.ExecuteReader()
                $cols = @()
                while ($reader.Read()) { $cols += $reader.GetString(0) }
                $reader.Close()
                return $cols
            })
        } catch {
            Write-Host "  Table $tableName does not exist yet. Run Start-FGSync first." -ForegroundColor Yellow
            throw "Table $tableName not found. Sync your data before running risk scoring."
        }

        $missingCols = @{}
        foreach ($colName in $riskColumns.Keys) {
            if ($colName -notin $existingCols) {
                $missingCols[$colName] = $riskColumns[$colName]
            }
        }

        if ($missingCols.Count -gt 0) {
            Write-Host "  Adding $($missingCols.Count) risk score column(s) to $tableName..." -ForegroundColor Gray
            Add-FGSQLTableColumn -TableName $tableName -Columns $missingCols
        } else {
            Write-Host "  $tableName: risk score columns already exist" -ForegroundColor Gray
        }
    }

    # ================================================================
    # Load Data from SQL
    # ================================================================

    Write-Host ""
    Write-Host "--- Loading Data from SQL ---" -ForegroundColor Cyan

    $users = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandTimeout = 300
        $cmd.CommandText = "SELECT id, displayName, userPrincipalName, department, jobTitle, companyName, accountEnabled, userType, mail, lastSignInDateTime, createdDateTime FROM dbo.GraphUsers"
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dt = New-Object System.Data.DataTable
        $adapter.Fill($dt) | Out-Null
        return $dt
    }
    Write-Host "  Users:       $($users.Rows.Count)" -ForegroundColor Gray

    $groups = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandTimeout = 300
        $cmd.CommandText = "SELECT id, displayName, description, mailEnabled, securityEnabled, isAssignableToRole, membershipRuleProcessingState, groupTypeCalculated, createdDateTime FROM dbo.GraphGroups"
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dt = New-Object System.Data.DataTable
        $adapter.Fill($dt) | Out-Null
        return $dt
    }
    Write-Host "  Groups:      $($groups.Rows.Count)" -ForegroundColor Gray

    # Load memberships — try materialized table first, fall back to view
    $permSource = "vw_UserPermissionAssignments"
    try {
        $matCheck = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            $cmd = $connection.CreateCommand()
            $cmd.CommandText = "SELECT OBJECT_ID('dbo.mat_UserPermissionAssignments', 'U')"
            return $cmd.ExecuteScalar()
        }
        if ($matCheck -ne [DBNull]::Value -and $null -ne $matCheck) {
            $permSource = "mat_UserPermissionAssignments"
        }
    } catch { }

    $assignments = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandTimeout = 600
        $cmd.CommandText = "SELECT groupId, memberId, membershipType FROM dbo.$permSource"
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dt = New-Object System.Data.DataTable
        $adapter.Fill($dt) | Out-Null
        return $dt
    }
    Write-Host "  Assignments: $($assignments.Rows.Count) (from $permSource)" -ForegroundColor Gray

    # Load group owners
    $owners = @()
    try {
        $owners = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            $cmd = $connection.CreateCommand()
            $cmd.CommandTimeout = 300
            $cmd.CommandText = "SELECT groupId, ownerId FROM dbo.GraphGroupOwners"
            $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
            $dt = New-Object System.Data.DataTable
            $adapter.Fill($dt) | Out-Null
            return $dt
        }
        Write-Host "  Owners:      $($owners.Rows.Count)" -ForegroundColor Gray
    } catch {
        Write-Host "  Owners:      (table not available)" -ForegroundColor Yellow
    }

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
        $gId = $row.groupId.ToString()
        $mId = $row.memberId.ToString()
        $type = $row.membershipType.ToString()

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
            $gId = $row.groupId.ToString()
            $oId = $row.ownerId.ToString()
            if (-not $groupOwnerMap.ContainsKey($gId)) { $groupOwnerMap[$gId] = @() }
            if ($oId -notin $groupOwnerMap[$gId]) { $groupOwnerMap[$gId] += $oId }
        }
    }

    Write-Host "  Groups with members:  $($groupMembers.Count)" -ForegroundColor Gray
    Write-Host "  Groups with eligible: $($groupEligible.Count)" -ForegroundColor Gray
    Write-Host "  Groups with owners:   $($groupOwnerMap.Count)" -ForegroundColor Gray

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

    $groupScores = @{}
    $groupMatchCount = 0

    foreach ($row in $groups.Rows) {
        $gId = $row.id.ToString()
        $name = if ($row.displayName -is [DBNull]) { "" } else { $row.displayName.ToString() }
        $desc = if ($row.description -is [DBNull]) { "" } else { $row.description.ToString() }

        $bestScore = 0
        $matches = @()

        foreach ($c in $groupClassifiers) {
            $nameMatch = Test-PatternMatch -Text $name -Patterns $c.name_patterns
            $descMatch = Test-PatternMatch -Text $desc -Patterns $c.description_patterns
            if ($nameMatch -or $descMatch) {
                $matches += @{ id = $c.id; category = $c.category; score = [int]$c.base_score; rationale = $c.rationale }
                if ([int]$c.base_score -gt $bestScore) { $bestScore = [int]$c.base_score }
            }
        }

        if ($matches.Count -gt 0) { $groupMatchCount++ }

        $groupScores[$gId] = @{
            directScore = $bestScore
            classifierMatches = $matches
            membershipScore = 0
            structuralScore = 0
            propagatedScore = 0
        }
    }
    Write-Host "  Groups matched: $groupMatchCount / $($groups.Rows.Count)" -ForegroundColor Gray

    $userScores = @{}
    $userMatchCount = 0

    foreach ($row in $users.Rows) {
        $uId = $row.id.ToString()
        $name = if ($row.displayName -is [DBNull]) { "" } else { $row.displayName.ToString() }
        $title = if ($row.jobTitle -is [DBNull]) { "" } else { $row.jobTitle.ToString() }
        $upn = if ($row.userPrincipalName -is [DBNull]) { "" } else { $row.userPrincipalName.ToString() }

        $bestScore = 0
        $matches = @()

        foreach ($c in $userClassifiers) {
            $titleMatch = Test-PatternMatch -Text $title -Patterns $c.title_patterns
            $nameMatch = Test-PatternMatch -Text $name -Patterns $c.name_patterns
            $upnMatch = Test-PatternMatch -Text $upn -Patterns $c.upn_patterns
            if ($titleMatch -or $nameMatch -or $upnMatch) {
                $matches += @{ id = $c.id; category = $c.category; score = [int]$c.base_score; rationale = $c.rationale }
                if ([int]$c.base_score -gt $bestScore) { $bestScore = [int]$c.base_score }
            }
        }

        if ($matches.Count -gt 0) { $userMatchCount++ }

        $userScores[$uId] = @{
            directScore = $bestScore
            classifierMatches = $matches
            membershipScore = 0
            structuralScore = 0
            propagatedScore = 0
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
        $members = if ($groupMembers.ContainsKey($gId)) { $groupMembers[$gId] } else { @() }
        $eligible = if ($groupEligible.ContainsKey($gId)) { $groupEligible[$gId] } else { @() }
        $ownrs = if ($groupOwnerMap.ContainsKey($gId)) { $groupOwnerMap[$gId] } else { @() }

        # Small group = concentrated risk
        if ($members.Count -gt 0 -and $members.Count -le 5) { $score += 5 }
        # Has PIM-eligible members
        if ($eligible.Count -gt 0) { $score += 10 }
        # No owner but has members
        if ($ownrs.Count -eq 0 -and $members.Count -gt 0) { $score += 5 }

        $groupScores[$gId].membershipScore = [Math]::Min($score, 40)
    }

    # Score users based on their memberships
    foreach ($uId in $userScores.Keys) {
        $score = 0
        $memberships = if ($userMemberships.ContainsKey($uId)) { $userMemberships[$uId] } else { @() }
        $ownerships = if ($userOwnershipMap.ContainsKey($uId)) { $userOwnershipMap[$uId] } else { @() }
        $eligible = if ($userEligible.ContainsKey($uId)) { $userEligible[$uId] } else { @() }

        $totalGroups = $memberships.Count + $ownerships.Count + $eligible.Count

        # High membership count
        if ($totalGroups -gt 15) {
            $points = [Math]::Min(15, [Math]::Floor(($totalGroups - 15) / 3) * 3)
            if ($points -gt 0) { $score += $points }
        }

        # Member of high-risk groups (direct score > 70)
        $highRiskCount = 0
        foreach ($gId in $memberships) {
            if ($groupScores.ContainsKey($gId) -and $groupScores[$gId].directScore -gt 70) {
                $highRiskCount++
            }
        }
        if ($highRiskCount -gt 0) { $score += 15 }

        # PIM-eligible
        if ($eligible.Count -gt 0) {
            $score += [Math]::Min(20, $eligible.Count * 5)
        }

        # Many ownerships
        if ($ownerships.Count -gt 3) { $score += 5 }

        $userScores[$uId].membershipScore = [Math]::Min($score, 40)
    }

    Write-Host "  Membership analysis complete" -ForegroundColor Gray

    # ================================================================
    # Layer 3 — Structural/Hygiene Signals
    # ================================================================

    Write-Host ""
    Write-Host "--- Layer 3: Structural Signals ---" -ForegroundColor Cyan

    foreach ($row in $groups.Rows) {
        $gId = $row.id.ToString()
        $score = 0

        # No description
        if ($row.description -is [DBNull] -or [string]::IsNullOrWhiteSpace($row.description.ToString())) { $score += 3 }
        # Mail-enabled security group
        $mailEnabled = if ($row.mailEnabled -is [DBNull]) { $false } else { [bool]$row.mailEnabled }
        $secEnabled = if ($row.securityEnabled -is [DBNull]) { $false } else { [bool]$row.securityEnabled }
        if ($mailEnabled -and $secEnabled) { $score += 3 }
        # Role-assignable
        $roleAssignable = if ($row.isAssignableToRole -is [DBNull]) { $false } else { [bool]$row.isAssignableToRole }
        if ($roleAssignable) { $score += 15 }
        # Dynamic membership
        $membershipRule = if ($row.membershipRuleProcessingState -is [DBNull]) { "" } else { $row.membershipRuleProcessingState.ToString() }
        if ($membershipRule -eq 'On') { $score += 3 }

        $groupScores[$gId].structuralScore = [Math]::Min($score, 25)
    }

    foreach ($row in $users.Rows) {
        $uId = $row.id.ToString()
        $score = 0

        # Account disabled
        $enabled = if ($row.accountEnabled -is [DBNull]) { $true } else { [bool]$row.accountEnabled }
        if (-not $enabled) { $score += 5 }

        # Stale sign-in (90+ days)
        if (-not ($row.lastSignInDateTime -is [DBNull])) {
            $lastSignIn = [DateTime]$row.lastSignInDateTime
            $daysSince = ([DateTime]::UtcNow - $lastSignIn).Days
            if ($daysSince -gt 90) { $score += 10 }
        }

        # Guest user
        $userType = if ($row.userType -is [DBNull]) { "" } else { $row.userType.ToString() }
        if ($userType -eq 'Guest') { $score += 5 }

        $userScores[$uId].structuralScore = [Math]::Min($score, 25)
    }

    Write-Host "  Structural analysis complete" -ForegroundColor Gray

    # ================================================================
    # Layer 4 — Cross-Entity Risk Propagation
    # ================================================================

    Write-Host ""
    Write-Host "--- Layer 4: Risk Propagation ---" -ForegroundColor Cyan

    $propagationGroupToUser = 0.30
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

    # Group → User: user inherits 30% of riskiest group
    foreach ($uId in $userScores.Keys) {
        $memberships = if ($userMemberships.ContainsKey($uId)) { $userMemberships[$uId] } else { @() }
        $maxGroupScore = 0
        foreach ($gId in $memberships) {
            if ($groupPreProp.ContainsKey($gId) -and $groupPreProp[$gId] -gt $maxGroupScore) {
                $maxGroupScore = $groupPreProp[$gId]
            }
        }
        $userScores[$uId].propagatedScore = [int]($maxGroupScore * $propagationGroupToUser)
    }

    # User → Group: group inherits 25% of riskiest member
    foreach ($gId in $groupScores.Keys) {
        $members = if ($groupMembers.ContainsKey($gId)) { $groupMembers[$gId] } else { @() }
        $maxUserScore = 0
        foreach ($uId in $members) {
            if ($userPreProp.ContainsKey($uId) -and $userPreProp[$uId] -gt $maxUserScore) {
                $maxUserScore = $userPreProp[$uId]
            }
        }
        $groupScores[$gId].propagatedScore = [int]($maxUserScore * $propagationUserToGroup)
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
        $matchJson = ($gs.classifierMatches | ConvertTo-Json -Depth 10 -Compress)
        if ($gs.classifierMatches.Count -eq 0) { $matchJson = "[]" }

        $groupUpdates += @{
            id = $gId
            riskScore = $final
            riskTier = $tier
            riskDirectScore = $gs.directScore
            riskMembershipScore = $gs.membershipScore
            riskStructuralScore = $gs.structuralScore
            riskPropagatedScore = $gs.propagatedScore
            riskClassifierMatches = $matchJson
        }
    }

    # Build update data for users
    $userUpdates = @()
    foreach ($uId in $userScores.Keys) {
        $us = $userScores[$uId]
        $final = [Math]::Min(100, [int]($wDirect * $us.directScore + $wMembership * $us.membershipScore + $wStructural * $us.structuralScore + $wPropagated * $us.propagatedScore))
        $tier = Get-RiskTier -Score $final
        $matchJson = ($us.classifierMatches | ConvertTo-Json -Depth 10 -Compress)
        if ($us.classifierMatches.Count -eq 0) { $matchJson = "[]" }

        $userUpdates += @{
            id = $uId
            riskScore = $final
            riskTier = $tier
            riskDirectScore = $us.directScore
            riskMembershipScore = $us.membershipScore
            riskStructuralScore = $us.structuralScore
            riskPropagatedScore = $us.propagatedScore
            riskClassifierMatches = $matchJson
        }
    }

    # ================================================================
    # Write Scores to SQL
    # ================================================================

    Write-Host ""
    Write-Host "--- Writing Scores to SQL ---" -ForegroundColor Cyan

    # Batch update groups
    $batchSize = 100
    $updated = 0

    for ($i = 0; $i -lt $groupUpdates.Count; $i += $batchSize) {
        $batch = $groupUpdates[$i..[Math]::Min($i + $batchSize - 1, $groupUpdates.Count - 1)]

        Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            foreach ($item in $batch) {
                $cmd = $connection.CreateCommand()
                $cmd.CommandTimeout = 120
                $cmd.CommandText = @"
UPDATE dbo.GraphGroups SET
    riskScore = @riskScore,
    riskTier = @riskTier,
    riskDirectScore = @riskDirectScore,
    riskMembershipScore = @riskMembershipScore,
    riskStructuralScore = @riskStructuralScore,
    riskPropagatedScore = @riskPropagatedScore,
    riskClassifierMatches = @riskClassifierMatches,
    riskScoredAt = @riskScoredAt
WHERE id = @id
"@
                $cmd.Parameters.AddWithValue("@id", [Guid]$item.id) | Out-Null
                $cmd.Parameters.AddWithValue("@riskScore", $item.riskScore) | Out-Null
                $cmd.Parameters.AddWithValue("@riskTier", $item.riskTier) | Out-Null
                $cmd.Parameters.AddWithValue("@riskDirectScore", $item.riskDirectScore) | Out-Null
                $cmd.Parameters.AddWithValue("@riskMembershipScore", $item.riskMembershipScore) | Out-Null
                $cmd.Parameters.AddWithValue("@riskStructuralScore", $item.riskStructuralScore) | Out-Null
                $cmd.Parameters.AddWithValue("@riskPropagatedScore", $item.riskPropagatedScore) | Out-Null
                $cmd.Parameters.AddWithValue("@riskClassifierMatches", $item.riskClassifierMatches) | Out-Null
                $cmd.Parameters.AddWithValue("@riskScoredAt", [DateTime]::UtcNow) | Out-Null
                $cmd.ExecuteNonQuery() | Out-Null
            }
        }
        $updated += $batch.Count
        if ($updated % 500 -eq 0 -or $updated -eq $groupUpdates.Count) {
            Write-Host "  Groups: $updated / $($groupUpdates.Count)" -ForegroundColor Gray
        }
    }

    # Batch update users
    $updated = 0

    for ($i = 0; $i -lt $userUpdates.Count; $i += $batchSize) {
        $batch = $userUpdates[$i..[Math]::Min($i + $batchSize - 1, $userUpdates.Count - 1)]

        Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            foreach ($item in $batch) {
                $cmd = $connection.CreateCommand()
                $cmd.CommandTimeout = 120
                $cmd.CommandText = @"
UPDATE dbo.GraphUsers SET
    riskScore = @riskScore,
    riskTier = @riskTier,
    riskDirectScore = @riskDirectScore,
    riskMembershipScore = @riskMembershipScore,
    riskStructuralScore = @riskStructuralScore,
    riskPropagatedScore = @riskPropagatedScore,
    riskClassifierMatches = @riskClassifierMatches,
    riskScoredAt = @riskScoredAt
WHERE id = @id
"@
                $cmd.Parameters.AddWithValue("@id", [Guid]$item.id) | Out-Null
                $cmd.Parameters.AddWithValue("@riskScore", $item.riskScore) | Out-Null
                $cmd.Parameters.AddWithValue("@riskTier", $item.riskTier) | Out-Null
                $cmd.Parameters.AddWithValue("@riskDirectScore", $item.riskDirectScore) | Out-Null
                $cmd.Parameters.AddWithValue("@riskMembershipScore", $item.riskMembershipScore) | Out-Null
                $cmd.Parameters.AddWithValue("@riskStructuralScore", $item.riskStructuralScore) | Out-Null
                $cmd.Parameters.AddWithValue("@riskPropagatedScore", $item.riskPropagatedScore) | Out-Null
                $cmd.Parameters.AddWithValue("@riskClassifierMatches", $item.riskClassifierMatches) | Out-Null
                $cmd.Parameters.AddWithValue("@riskScoredAt", [DateTime]::UtcNow) | Out-Null
                $cmd.ExecuteNonQuery() | Out-Null
            }
        }
        $updated += $batch.Count
        if ($updated % 500 -eq 0 -or $updated -eq $userUpdates.Count) {
            Write-Host "  Users:  $updated / $($userUpdates.Count)" -ForegroundColor Gray
        }
    }

    # Collect memory
    [System.GC]::Collect()

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
    Write-Host "  Duration: $($duration.ToString('mm\:ss'))" -ForegroundColor Gray
    Write-Host "  Scored:   $($groupUpdates.Count) groups, $($userUpdates.Count) users" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Scores are persisted on GraphUsers and GraphGroups tables." -ForegroundColor Gray
    Write-Host "  The UI Risk Scores tab reads these directly from SQL." -ForegroundColor Gray
    Write-Host ""
}
