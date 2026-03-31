function Save-FGResourceClusters {
    <#
    .SYNOPSIS
    Clusters scored groups into functional groupings and persists them to SQL.

    .DESCRIPTION
    Groups related resources into logical clusters using two passes:
    1. Classifier-based: groups matching the same classifier ID form a cluster
    2. Name-stem fallback: unclaimed groups clustered by normalized name stem (2+ members required)

    Clusters are stored in GraphResourceClusters and GraphResourceClusterMembers temporal tables.
    Owner assignments (set via the UI) are preserved across re-scoring runs.

    Called automatically at the end of Invoke-FGRiskScoring.

    .PARAMETER Groups
    The groups DataTable loaded during scoring (has displayName, description columns).

    .PARAMETER GroupScores
    Hashtable from Invoke-FGRiskScoring: groupId -> { directScore, classifierMatches, ... }

    .PARAMETER GroupUpdates
    Array of scored group hashtables: { id, riskScore, riskTier, ... }

    .PARAMETER GroupClassifiers
    Classifier rules from the ruleset (used for display names and categories).

    .PARAMETER NonProdPatterns
    The non-production regex patterns for environment detection.
    #>

    [alias("Save-ResourceClusters")]
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [System.Data.DataTable]$Groups,

        [Parameter(Mandatory = $true)]
        [hashtable]$GroupScores,

        [Parameter(Mandatory = $true)]
        [array]$GroupUpdates,

        [Parameter(Mandatory = $true)]
        [array]$GroupClassifiers,

        [Parameter(Mandatory = $false)]
        [array]$NonProdPatterns,

        [Parameter(Mandatory = $false)]
        [hashtable]$ResourceTypeMap = @{}
    )

    # Build quick lookup: groupId -> update data (riskScore, riskTier)
    $updateLookup = @{}
    foreach ($gu in $GroupUpdates) {
        $updateLookup[$gu.id] = $gu
    }

    # Build quick lookup: groupId -> displayName from DataTable
    $groupNameLookup = @{}
    foreach ($row in $Groups.Rows) {
        $gId = "$($row['id'])"
        if (-not [string]::IsNullOrEmpty($gId)) {
            $groupNameLookup[$gId] = if ($null -eq $row['displayName'] -or $row['displayName'] -is [DBNull]) { "" } else { "$($row['displayName'])" }
        }
    }

    # Build classifier lookup: classifierId -> classifier object
    $classifierLookup = @{}
    foreach ($c in $GroupClassifiers) {
        $classifierLookup[$c.id] = $c
    }

    # ================================================================
    # Pass 1: Classifier-based clusters
    # ================================================================

    Write-Host "  Pass 1: Classifier-based clustering" -ForegroundColor Gray

    # Collect: classifierId -> @(groupId, groupId, ...)
    $classifierGroups = @{}
    $claimedGroups = @{}  # groupId -> $true (claimed by at least one classifier)

    foreach ($gId in $GroupScores.Keys) {
        $gs = $GroupScores[$gId]
        if ($gs.classifierMatches.Count -eq 0) { continue }

        foreach ($match in $gs.classifierMatches) {
            $cId = $match.id
            if (-not $classifierGroups.ContainsKey($cId)) { $classifierGroups[$cId] = @() }
            if ($gId -notin $classifierGroups[$cId]) {
                $classifierGroups[$cId] += $gId
            }
            $claimedGroups[$gId] = $true
        }
    }

    $clusters = @{}      # clusterId -> cluster data
    $memberData = @()    # flat array of member records
    $classifierClusterCount = 0

    foreach ($cId in $classifierGroups.Keys) {
        $memberIds = $classifierGroups[$cId]
        if ($memberIds.Count -lt 1) { continue }

        $clusterId = "cls-$cId"
        $classifier = $classifierLookup[$cId]

        # Build display name from classifier ID (concrete system name)
        # e.g., "por-hamis-access" → "Hamis", "univ-domain-admins" → "Domain Admins"
        $displayName = $cId -replace '^(univ|por|cust)[-_]', ''   # strip tenant/scope prefix
        $displayName = $displayName -replace '[-_](access|administrator|admin|management|system|role|group|membership|users|members|resources|permissions|rights|security|service|services)$', ''  # strip purpose suffix
        $displayName = $displayName -replace '[-_]', ' '          # dashes/underscores to spaces
        $displayName = (Get-Culture).TextInfo.ToTitleCase($displayName)
        $description = if ($classifier) { $classifier.rationale } else { "" }
        $category = if ($classifier) { $classifier.category } else { "" }
        $patterns = if ($classifier -and $classifier.name_patterns) {
            ($classifier.name_patterns | ConvertTo-Json -Compress)
        } else { "[]" }

        # Collect member data and compute aggregates
        $maxScore = 0; $scoreSum = 0; $scoreCount = 0
        $tierCounts = @{}; $prodCount = 0; $nonProdCount = 0

        foreach ($gId in $memberIds) {
            $gu = $updateLookup[$gId]
            if (-not $gu) { continue }

            $score = [int]$gu.riskScore
            $tier = $gu.riskTier
            if ($score -gt $maxScore) { $maxScore = $score }
            $scoreSum += $score; $scoreCount++
            if (-not $tierCounts.ContainsKey($tier)) { $tierCounts[$tier] = 0 }
            $tierCounts[$tier]++

            # Check non-production
            $isNonProd = $false
            $gName = $groupNameLookup[$gId]
            if ($NonProdPatterns -and $gName) {
                foreach ($pattern in $NonProdPatterns) {
                    if ($gName -match $pattern) { $isNonProd = $true; break }
                }
            }
            if ($isNonProd) { $nonProdCount++ } else { $prodCount++ }

            $memberResourceType = if ($ResourceTypeMap.ContainsKey($gId)) { $ResourceTypeMap[$gId] } else { 'group' }
            $memberData += @{
                clusterId       = $clusterId
                resourceType    = $memberResourceType
                resourceId      = $gId
                resourceName    = $gName
                resourceRiskScore = $score
                resourceRiskTier  = $tier
                isNonProduction = $isNonProd
                matchedOn       = 'classifier'
                matchDetail     = $cId
            }
        }

        $avgScore = if ($scoreCount -gt 0) { [int]($scoreSum / $scoreCount) } else { 0 }
        $aggregateScore = [Math]::Min(100, [int](0.60 * $maxScore + 0.40 * $avgScore))

        # Risk tier from aggregate
        $aggTier = if ($aggregateScore -ge 90) { "Critical" }
                   elseif ($aggregateScore -ge 70) { "High" }
                   elseif ($aggregateScore -ge 40) { "Medium" }
                   elseif ($aggregateScore -ge 20) { "Low" }
                   elseif ($aggregateScore -ge 1) { "Minimal" }
                   else { "None" }

        $clusters[$clusterId] = @{
            id                       = $clusterId
            displayName              = $displayName
            description              = $description
            clusterType              = 'classifier'
            sourceClassifierId       = $cId
            sourceClassifierCategory = $category
            matchPatterns            = $patterns
            memberCount              = $memberIds.Count
            memberCountProd          = $prodCount
            memberCountNonProd       = $nonProdCount
            aggregateRiskScore       = $aggregateScore
            maxMemberRiskScore       = $maxScore
            avgMemberRiskScore       = $avgScore
            riskTier                 = $aggTier
            tierDistribution         = ($tierCounts | ConvertTo-Json -Compress)
        }

        $classifierClusterCount++
        if ($memberIds.Count -ge 3) {
            Write-Host "    $($clusterId): $($memberIds.Count) groups" -ForegroundColor Gray
        }
    }

    $classifierGroupCount = $claimedGroups.Count
    Write-Host "    $classifierClusterCount clusters from classifiers ($classifierGroupCount groups)" -ForegroundColor Gray

    # ================================================================
    # Pass 2: Name-stem fallback
    # ================================================================

    Write-Host "  Pass 2: Name-stem fallback" -ForegroundColor Gray

    # Patterns to strip
    $prefixPattern = '^(SG|DL|AG|SEC|M365|AAD|GRP)[-_]'
    $envSuffix = '[-_](P|A|T|D|ACC|TST|DEV|ONT|STG|SBX|UAT|QA|PRD|PROD)$'
    $roleSuffix = '[-_](Admin|Admins|Users|Members|Owners|ReadOnly|FullAccess|Beheer|Gebruikers|Viewers|Readers|Writers|Contributors)$'

    function Get-GroupStem([string]$Name) {
        if ([string]::IsNullOrWhiteSpace($Name)) { return "" }
        $stem = $Name
        # Strip prefix
        $stem = $stem -replace $prefixPattern, ''
        # Strip env suffix (repeat to handle _P_ACC etc.)
        $stem = $stem -replace $envSuffix, ''
        $stem = $stem -replace $envSuffix, ''
        # Strip role suffix
        $stem = $stem -replace $roleSuffix, ''
        $stem = $stem -replace $roleSuffix, ''
        # Normalize
        $stem = $stem -replace '[_\-\s]+', '-'
        $stem = $stem.Trim('-').ToLower()
        return $stem
    }

    $stemGroups = @{}  # stem -> @(groupId, ...)
    $stemNames = @{}   # stem -> @(originalName, ...)

    foreach ($gId in $GroupScores.Keys) {
        if ($claimedGroups.ContainsKey($gId)) { continue }  # Already in a classifier cluster
        $gu = $updateLookup[$gId]
        if (-not $gu -or [int]$gu.riskScore -eq 0) { continue }  # Skip unscored

        $gName = $groupNameLookup[$gId]
        $stem = Get-GroupStem -Name $gName
        if ([string]::IsNullOrWhiteSpace($stem) -or $stem.Length -lt 2) { continue }

        if (-not $stemGroups.ContainsKey($stem)) { $stemGroups[$stem] = @(); $stemNames[$stem] = @() }
        $stemGroups[$stem] += $gId
        $stemNames[$stem] += $gName
    }

    $stemClusterCount = 0
    $stemGroupCount = 0

    foreach ($stem in $stemGroups.Keys) {
        $memberIds = $stemGroups[$stem]
        if ($memberIds.Count -lt 2) { continue }  # Need 2+ members for a stem cluster

        $clusterId = "stem-$stem"

        # Display name: find the most common shortest name variant
        $names = $stemNames[$stem] | Sort-Object { $_.Length }
        $displayName = $names[0]

        # Collect member data and compute aggregates
        $maxScore = 0; $scoreSum = 0; $scoreCount = 0
        $tierCounts = @{}; $prodCount = 0; $nonProdCount = 0

        foreach ($gId in $memberIds) {
            $gu = $updateLookup[$gId]
            if (-not $gu) { continue }

            $score = [int]$gu.riskScore
            $tier = $gu.riskTier
            if ($score -gt $maxScore) { $maxScore = $score }
            $scoreSum += $score; $scoreCount++
            if (-not $tierCounts.ContainsKey($tier)) { $tierCounts[$tier] = 0 }
            $tierCounts[$tier]++

            $isNonProd = $false
            $gName = $groupNameLookup[$gId]
            if ($NonProdPatterns -and $gName) {
                foreach ($pattern in $NonProdPatterns) {
                    if ($gName -match $pattern) { $isNonProd = $true; break }
                }
            }
            if ($isNonProd) { $nonProdCount++ } else { $prodCount++ }

            $memberResourceType = if ($ResourceTypeMap.ContainsKey($gId)) { $ResourceTypeMap[$gId] } else { 'group' }
            $memberData += @{
                clusterId       = $clusterId
                resourceType    = $memberResourceType
                resourceId      = $gId
                resourceName    = $gName
                resourceRiskScore = $score
                resourceRiskTier  = $tier
                isNonProduction = $isNonProd
                matchedOn       = 'stem'
                matchDetail     = $stem
            }
        }

        $avgScore = if ($scoreCount -gt 0) { [int]($scoreSum / $scoreCount) } else { 0 }
        $aggregateScore = [Math]::Min(100, [int](0.60 * $maxScore + 0.40 * $avgScore))

        $aggTier = if ($aggregateScore -ge 90) { "Critical" }
                   elseif ($aggregateScore -ge 70) { "High" }
                   elseif ($aggregateScore -ge 40) { "Medium" }
                   elseif ($aggregateScore -ge 20) { "Low" }
                   elseif ($aggregateScore -ge 1) { "Minimal" }
                   else { "None" }

        $clusters[$clusterId] = @{
            id                       = $clusterId
            displayName              = $displayName
            description              = "Stem-based cluster for groups matching '$stem'"
            clusterType              = 'stem'
            sourceClassifierId       = ''
            sourceClassifierCategory = ''
            matchPatterns            = "[]"
            memberCount              = $memberIds.Count
            memberCountProd          = $prodCount
            memberCountNonProd       = $nonProdCount
            aggregateRiskScore       = $aggregateScore
            maxMemberRiskScore       = $maxScore
            avgMemberRiskScore       = $avgScore
            riskTier                 = $aggTier
            tierDistribution         = ($tierCounts | ConvertTo-Json -Compress)
        }

        $stemClusterCount++
        $stemGroupCount += $memberIds.Count
    }

    Write-Host "    $stemClusterCount clusters from stems ($stemGroupCount groups)" -ForegroundColor Gray

    $totalClusters = $clusters.Count
    $totalGroupsClustered = $classifierGroupCount + $stemGroupCount
    Write-Host "  Total: $totalClusters clusters, $totalGroupsClustered groups clustered" -ForegroundColor Green

    if ($totalClusters -eq 0) {
        Write-Host "  No clusters to save." -ForegroundColor Gray
        return
    }

    # ================================================================
    # Create SQL tables if needed
    # ================================================================

    Write-Host "  Writing to SQL..." -ForegroundColor Cyan

    $scoredAt = Get-Date -Format "o"

    # Check if GraphResourceClusters table exists
    $clusterTableExists = $false
    try {
        $clusterTableExists = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            $cmd = $connection.CreateCommand()
            $cmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'GraphResourceClusters' AND TABLE_SCHEMA = 'dbo'"
            return [int]$cmd.ExecuteScalar() -gt 0
        }
    } catch { }

    if (-not $clusterTableExists) {
        Write-Host "    Creating GraphResourceClusters table..." -ForegroundColor Gray
        $clusterColumns = [ordered]@{
            'id'                       = 'NVARCHAR(200) NOT NULL'
            'displayName'              = 'NVARCHAR(500) NOT NULL'
            'description'              = 'NVARCHAR(MAX) NULL'
            'clusterType'              = 'NVARCHAR(20) NOT NULL'
            'sourceClassifierId'       = 'NVARCHAR(200) NULL'
            'sourceClassifierCategory' = 'NVARCHAR(100) NULL'
            'matchPatterns'            = 'NVARCHAR(MAX) NULL'
            'memberCount'              = 'INT NOT NULL'
            'memberCountProd'          = 'INT NOT NULL'
            'memberCountNonProd'       = 'INT NOT NULL'
            'aggregateRiskScore'       = 'INT NOT NULL'
            'maxMemberRiskScore'       = 'INT NOT NULL'
            'avgMemberRiskScore'       = 'INT NOT NULL'
            'riskTier'                 = 'NVARCHAR(20) NOT NULL'
            'tierDistribution'         = 'NVARCHAR(MAX) NULL'
            'ownerUserId'              = 'NVARCHAR(36) NULL'
            'ownerDisplayName'         = 'NVARCHAR(500) NULL'
            'ownerAssignedAt'          = 'DATETIME2 NULL'
            'ownerAssignedBy'          = 'NVARCHAR(500) NULL'
            'scoredAt'                 = 'DATETIME2 NOT NULL'
        }
        Initialize-FGSQLTable -TableName 'GraphResourceClusters' -Columns $clusterColumns -PrimaryKey 'id'
    }

    # Check if GraphResourceClusterMembers table exists
    $memberTableExists = $false
    try {
        $memberTableExists = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            $cmd = $connection.CreateCommand()
            $cmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'GraphResourceClusterMembers' AND TABLE_SCHEMA = 'dbo'"
            return [int]$cmd.ExecuteScalar() -gt 0
        }
    } catch { }

    if (-not $memberTableExists) {
        Write-Host "    Creating GraphResourceClusterMembers table..." -ForegroundColor Gray
        $memberColumns = [ordered]@{
            'clusterId'         = 'NVARCHAR(200) NOT NULL'
            'resourceType'      = 'NVARCHAR(20) NOT NULL'
            'resourceId'        = 'NVARCHAR(36) NOT NULL'
            'resourceName'      = 'NVARCHAR(500) NULL'
            'resourceRiskScore' = 'INT NULL'
            'resourceRiskTier'  = 'NVARCHAR(20) NULL'
            'isNonProduction'   = 'BIT NOT NULL'
            'matchedOn'         = 'NVARCHAR(50) NULL'
            'matchDetail'       = 'NVARCHAR(500) NULL'
        }
        Initialize-FGSQLTable -TableName 'GraphResourceClusterMembers' -Columns $memberColumns -PrimaryKey @('clusterId', 'resourceType', 'resourceId')
    }

    # ================================================================
    # MERGE clusters (preserve owner columns)
    # ================================================================

    $clusterBatchSize = 50
    $clusterKeys = @($clusters.Keys)
    $mergedCount = 0

    for ($i = 0; $i -lt $clusterKeys.Count; $i += $clusterBatchSize) {
        $batchKeys = $clusterKeys[$i..[Math]::Min($i + $clusterBatchSize - 1, $clusterKeys.Count - 1)]

        Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            foreach ($key in $batchKeys) {
                $c = $clusters[$key]
                $cmd = $connection.CreateCommand()
                $cmd.CommandTimeout = 120
                $cmd.CommandText = @"
MERGE dbo.GraphResourceClusters AS target
USING (SELECT @id AS id) AS source ON target.id = source.id
WHEN MATCHED THEN UPDATE SET
    displayName = @displayName,
    description = @description,
    clusterType = @clusterType,
    sourceClassifierId = @sourceClassifierId,
    sourceClassifierCategory = @sourceClassifierCategory,
    matchPatterns = @matchPatterns,
    memberCount = @memberCount,
    memberCountProd = @memberCountProd,
    memberCountNonProd = @memberCountNonProd,
    aggregateRiskScore = @aggregateRiskScore,
    maxMemberRiskScore = @maxMemberRiskScore,
    avgMemberRiskScore = @avgMemberRiskScore,
    riskTier = @riskTier,
    tierDistribution = @tierDistribution,
    scoredAt = @scoredAt
WHEN NOT MATCHED THEN INSERT (
    id, displayName, description, clusterType, sourceClassifierId, sourceClassifierCategory,
    matchPatterns, memberCount, memberCountProd, memberCountNonProd,
    aggregateRiskScore, maxMemberRiskScore, avgMemberRiskScore, riskTier, tierDistribution, scoredAt
) VALUES (
    @id, @displayName, @description, @clusterType, @sourceClassifierId, @sourceClassifierCategory,
    @matchPatterns, @memberCount, @memberCountProd, @memberCountNonProd,
    @aggregateRiskScore, @maxMemberRiskScore, @avgMemberRiskScore, @riskTier, @tierDistribution, @scoredAt
);
"@
                $cmd.Parameters.AddWithValue("@id", $c.id) | Out-Null
                $cmd.Parameters.AddWithValue("@displayName", $c.displayName) | Out-Null
                $cmd.Parameters.AddWithValue("@description", $(if ($c.description) { $c.description } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@clusterType", $c.clusterType) | Out-Null
                $cmd.Parameters.AddWithValue("@sourceClassifierId", $(if ($c.sourceClassifierId) { $c.sourceClassifierId } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@sourceClassifierCategory", $(if ($c.sourceClassifierCategory) { $c.sourceClassifierCategory } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@matchPatterns", $(if ($c.matchPatterns) { $c.matchPatterns } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@memberCount", $c.memberCount) | Out-Null
                $cmd.Parameters.AddWithValue("@memberCountProd", $c.memberCountProd) | Out-Null
                $cmd.Parameters.AddWithValue("@memberCountNonProd", $c.memberCountNonProd) | Out-Null
                $cmd.Parameters.AddWithValue("@aggregateRiskScore", $c.aggregateRiskScore) | Out-Null
                $cmd.Parameters.AddWithValue("@maxMemberRiskScore", $c.maxMemberRiskScore) | Out-Null
                $cmd.Parameters.AddWithValue("@avgMemberRiskScore", $c.avgMemberRiskScore) | Out-Null
                $cmd.Parameters.AddWithValue("@riskTier", $c.riskTier) | Out-Null
                $cmd.Parameters.AddWithValue("@tierDistribution", $(if ($c.tierDistribution) { $c.tierDistribution } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@scoredAt", $scoredAt) | Out-Null
                $cmd.ExecuteNonQuery() | Out-Null
            }
        }
        $mergedCount += $batchKeys.Count
    }

    Write-Host "    Clusters: $mergedCount merged" -ForegroundColor Gray

    # Zero out stale clusters (clusters no longer computed)
    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandTimeout = 120
        $cmd.CommandText = "UPDATE dbo.GraphResourceClusters SET memberCount = 0, aggregateRiskScore = 0, maxMemberRiskScore = 0, avgMemberRiskScore = 0, riskTier = 'None', memberCountProd = 0, memberCountNonProd = 0, scoredAt = @scoredAt WHERE scoredAt < @scoredAt"
        $cmd.Parameters.AddWithValue("@scoredAt", $scoredAt) | Out-Null
        $staleCount = $cmd.ExecuteNonQuery()
        if ($staleCount -gt 0) {
            Write-Host "    Stale clusters zeroed: $staleCount" -ForegroundColor Yellow
        }
    }

    # ================================================================
    # Replace cluster members (delete + insert)
    # ================================================================

    # Delete all current members for clusters we're updating
    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandTimeout = 300
        $cmd.CommandText = "DELETE FROM dbo.GraphResourceClusterMembers WHERE clusterId IN (SELECT id FROM dbo.GraphResourceClusters WHERE scoredAt = @scoredAt)"
        $cmd.Parameters.AddWithValue("@scoredAt", $scoredAt) | Out-Null
        $cmd.ExecuteNonQuery() | Out-Null
    }

    # Insert members in batches
    $memberBatchSize = 100
    $insertedCount = 0

    for ($i = 0; $i -lt $memberData.Count; $i += $memberBatchSize) {
        $batch = $memberData[$i..[Math]::Min($i + $memberBatchSize - 1, $memberData.Count - 1)]

        Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            foreach ($m in $batch) {
                $cmd = $connection.CreateCommand()
                $cmd.CommandTimeout = 120
                $cmd.CommandText = @"
INSERT INTO dbo.GraphResourceClusterMembers (clusterId, resourceType, resourceId, resourceName, resourceRiskScore, resourceRiskTier, isNonProduction, matchedOn, matchDetail)
VALUES (@clusterId, @resourceType, @resourceId, @resourceName, @resourceRiskScore, @resourceRiskTier, @isNonProduction, @matchedOn, @matchDetail)
"@
                $cmd.Parameters.AddWithValue("@clusterId", $m.clusterId) | Out-Null
                $cmd.Parameters.AddWithValue("@resourceType", $m.resourceType) | Out-Null
                $cmd.Parameters.AddWithValue("@resourceId", $m.resourceId) | Out-Null
                $cmd.Parameters.AddWithValue("@resourceName", $(if ($m.resourceName) { $m.resourceName } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@resourceRiskScore", $(if ($null -ne $m.resourceRiskScore) { $m.resourceRiskScore } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@resourceRiskTier", $(if ($m.resourceRiskTier) { $m.resourceRiskTier } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@isNonProduction", [int]$m.isNonProduction) | Out-Null
                $cmd.Parameters.AddWithValue("@matchedOn", $(if ($m.matchedOn) { $m.matchedOn } else { [DBNull]::Value })) | Out-Null
                $cmd.Parameters.AddWithValue("@matchDetail", $(if ($m.matchDetail) { $m.matchDetail } else { [DBNull]::Value })) | Out-Null
                $cmd.ExecuteNonQuery() | Out-Null
            }
        }
        $insertedCount += $batch.Count
    }

    Write-Host "    Members: $insertedCount written" -ForegroundColor Gray

    # Collect memory
    [System.GC]::Collect()

    Write-Host "  Resource clusters saved" -ForegroundColor Green
}
