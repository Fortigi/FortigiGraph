function Invoke-FGResourceModelMigration {
    <#
    .SYNOPSIS
    Migrates data from legacy tables to the Universal Resource Model tables.

    .DESCRIPTION
    This function migrates data from the old tables (GraphGroups, GraphGroupMembers,
    GraphGroupOwners, GraphGroupEligibleMembers) to the new tables (Systems, Resources,
    ResourceAssignments). It is idempotent - running it multiple times will not create
    duplicate records.

    Steps:
    1. Ensures new tables exist (Systems, Resources, ResourceAssignments)
    2. Creates a System record for EntraID
    3. Migrates GraphGroups -> Resources
    4. Migrates GraphGroupMembers -> ResourceAssignments (Direct)
    5. Migrates GraphGroupOwners -> ResourceAssignments (Owner)
    6. Migrates GraphGroupEligibleMembers -> ResourceAssignments (Eligible)
    7. Creates resource model views and indexes
    8. Updates System metadata (resourceTypes, assignmentTypes)

    .PARAMETER Force
    Skip confirmation prompts.

    .EXAMPLE
    Invoke-FGResourceModelMigration -Force

    Migrates all legacy data to the universal resource model without prompts.

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Legacy tables to exist with data
    #>

    [CmdletBinding()]
    [Alias("Invoke-ResourceModelMigration")]
    Param(
        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    # Check SQL connection
    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Starting Resource Model Migration..." -ForegroundColor Cyan

    #region Ensure new tables exist
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Ensuring resource model tables exist..." -ForegroundColor Cyan
    try {
        Initialize-FGSystemTables
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Resource model tables ready" -ForegroundColor Green
    }
    catch {
        throw "Failed to create resource model tables: $($_.Exception.Message)"
    }
    #endregion

    #region Check old tables exist
    $oldTables = @{
        GraphGroups = $false
        GraphGroupMembers = $false
        GraphGroupOwners = $false
        GraphGroupEligibleMembers = $false
    }

    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        foreach ($tableName in @('GraphGroups', 'GraphGroupMembers', 'GraphGroupOwners', 'GraphGroupEligibleMembers')) {
            $cmd = $connection.CreateCommand()
            $cmd.CommandText = "SELECT CASE WHEN EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = @tableName) THEN 1 ELSE 0 END"
            $cmd.Parameters.AddWithValue("@tableName", $tableName) | Out-Null
            $exists = $cmd.ExecuteScalar()
            $oldTables[$tableName] = ($exists -eq 1)
        }
    }

    if (-not $oldTables['GraphGroups']) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] No legacy GraphGroups table found. Nothing to migrate." -ForegroundColor Yellow
        return
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Legacy tables found:" -ForegroundColor Cyan
    foreach ($table in $oldTables.GetEnumerator()) {
        $status = if ($table.Value) { "exists" } else { "not found" }
        Write-Host "  - $($table.Key): $status" -ForegroundColor $(if ($table.Value) { 'Green' } else { 'Yellow' })
    }
    #endregion

    #region Confirmation
    if (-not $Force) {
        $response = Read-Host "Proceed with migration? (Y/N)"
        if ($response -notmatch '^[Yy]') {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Migration cancelled." -ForegroundColor Yellow
            return
        }
    }
    #endregion

    #region Create System record for EntraID
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Ensuring EntraID system record exists..." -ForegroundColor Cyan
    $systemId = Sync-FGSystem -SystemType 'EntraID' -DisplayName 'Entra ID' -TenantId $Global:TenantId
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] EntraID system id: $systemId" -ForegroundColor Green
    #endregion

    #region Migrate GraphGroups -> Resources
    if ($oldTables['GraphGroups']) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Migrating GraphGroups -> Resources..." -ForegroundColor Cyan

        $groupsMigrated = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)

            $cmd = $connection.CreateCommand()
            $cmd.CommandTimeout = 300
            $cmd.CommandText = @"
INSERT INTO Resources (id, systemId, displayName, description, resourceType, createdDateTime, mail, visibility, enabled, externalId, extendedAttributes)
SELECT
    g.id,
    @systemId,
    g.displayName,
    g.description,
    'EntraGroup',
    g.createdDateTime,
    g.mail,
    g.visibility,
    1,
    NULL,
    (SELECT
        g.securityEnabled as securityEnabled,
        g.mailEnabled as mailEnabled,
        g.groupTypes as groupTypes,
        g.membershipRule as membershipRule,
        g.membershipRuleProcessingState as membershipRuleProcessingState,
        g.isAssignableToRole as isAssignableToRole,
        g.groupTypeCalculated as groupTypeCalculated,
        g.renewedDateTime as renewedDateTime,
        g.expirationDateTime as expirationDateTime,
        g.resourceProvisioningOptions as resourceProvisioningOptions,
        g.onPremisesSyncEnabled as onPremisesSyncEnabled,
        g.onPremisesSamAccountName as onPremisesSamAccountName,
        g.onPremisesSecurityIdentifier as onPremisesSecurityIdentifier,
        g.onPremisesNetBiosName as onPremisesNetBiosName,
        g.onPremisesDomainName as onPremisesDomainName,
        g.mailNickname as mailNickname,
        g.administrativeUnits as administrativeUnits
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
FROM GraphGroups g
WHERE g.ValidTo = '9999-12-31 23:59:59.9999999'
AND NOT EXISTS (SELECT 1 FROM Resources r WHERE r.id = g.id)
"@
            $cmd.Parameters.AddWithValue("@systemId", $systemId) | Out-Null
            $rowsAffected = $cmd.ExecuteNonQuery()
            return $rowsAffected
        }

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Groups migrated to Resources: $groupsMigrated" -ForegroundColor Green
    }
    #endregion

    #region Migrate GraphGroupMembers -> ResourceAssignments (Direct)
    if ($oldTables['GraphGroupMembers']) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Migrating GraphGroupMembers -> ResourceAssignments (Direct)..." -ForegroundColor Cyan

        $membersMigrated = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)

            $cmd = $connection.CreateCommand()
            $cmd.CommandTimeout = 300
            $cmd.CommandText = @"
INSERT INTO ResourceAssignments (resourceId, principalId, principalType, assignmentType)
SELECT
    gm.groupId,
    gm.memberId,
    gm.memberType,
    'Direct'
FROM GraphGroupMembers gm
WHERE gm.ValidTo = '9999-12-31 23:59:59.9999999'
AND NOT EXISTS (
    SELECT 1 FROM ResourceAssignments ra
    WHERE ra.resourceId = gm.groupId AND ra.principalId = gm.memberId AND ra.assignmentType = 'Direct'
)
"@
            $rowsAffected = $cmd.ExecuteNonQuery()
            return $rowsAffected
        }

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Direct memberships migrated: $membersMigrated" -ForegroundColor Green
    }
    #endregion

    #region Migrate GraphGroupOwners -> ResourceAssignments (Owner)
    if ($oldTables['GraphGroupOwners']) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Migrating GraphGroupOwners -> ResourceAssignments (Owner)..." -ForegroundColor Cyan

        $ownersMigrated = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)

            $cmd = $connection.CreateCommand()
            $cmd.CommandTimeout = 300
            $cmd.CommandText = @"
INSERT INTO ResourceAssignments (resourceId, principalId, principalType, assignmentType)
SELECT
    go2.groupId,
    go2.ownerId,
    'user',
    'Owner'
FROM GraphGroupOwners go2
WHERE go2.ValidTo = '9999-12-31 23:59:59.9999999'
AND NOT EXISTS (
    SELECT 1 FROM ResourceAssignments ra
    WHERE ra.resourceId = go2.groupId AND ra.principalId = go2.ownerId AND ra.assignmentType = 'Owner'
)
"@
            $rowsAffected = $cmd.ExecuteNonQuery()
            return $rowsAffected
        }

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Owner memberships migrated: $ownersMigrated" -ForegroundColor Green
    }
    #endregion

    #region Migrate GraphGroupEligibleMembers -> ResourceAssignments (Eligible)
    if ($oldTables['GraphGroupEligibleMembers']) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Migrating GraphGroupEligibleMembers -> ResourceAssignments (Eligible)..." -ForegroundColor Cyan

        $eligibleMigrated = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)

            $cmd = $connection.CreateCommand()
            $cmd.CommandTimeout = 300
            $cmd.CommandText = @"
INSERT INTO ResourceAssignments (resourceId, principalId, principalType, assignmentType)
SELECT
    ge.groupId,
    ge.memberId,
    ge.memberType,
    'Eligible'
FROM GraphGroupEligibleMembers ge
WHERE ge.ValidTo = '9999-12-31 23:59:59.9999999'
AND NOT EXISTS (
    SELECT 1 FROM ResourceAssignments ra
    WHERE ra.resourceId = ge.groupId AND ra.principalId = ge.memberId AND ra.assignmentType = 'Eligible'
)
"@
            $rowsAffected = $cmd.ExecuteNonQuery()
            return $rowsAffected
        }

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Eligible memberships migrated: $eligibleMigrated" -ForegroundColor Green
    }
    #endregion

    #region Create views and indexes
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Creating resource model views..." -ForegroundColor Cyan
    try {
        Initialize-FGResourceViews
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Resource model views created" -ForegroundColor Green
    }
    catch {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Failed to create resource views: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Creating resource model indexes..." -ForegroundColor Cyan
    try {
        Initialize-FGResourceIndexes
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Resource model indexes created" -ForegroundColor Green
    }
    catch {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Failed to create resource indexes: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    #endregion

    #region Update System metadata
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Updating system metadata..." -ForegroundColor Cyan

    $resourceTypes = '["EntraGroup"]'
    $assignmentTypes = '["Direct","Owner","Eligible"]'

    Sync-FGSystem -SystemType 'EntraID' -TenantId $Global:TenantId `
        -UpdateResourceTypes $resourceTypes `
        -UpdateAssignmentTypes $assignmentTypes `
        -UpdateLastSync

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] System metadata updated" -ForegroundColor Green
    #endregion

    #region Summary
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Migration Summary:" -ForegroundColor Cyan
    if ($oldTables['GraphGroups']) {
        Write-Host "  Resources (from Groups):           $groupsMigrated" -ForegroundColor White
    }
    if ($oldTables['GraphGroupMembers']) {
        Write-Host "  Direct Assignments (from Members): $membersMigrated" -ForegroundColor White
    }
    if ($oldTables['GraphGroupOwners']) {
        Write-Host "  Owner Assignments (from Owners):   $ownersMigrated" -ForegroundColor White
    }
    if ($oldTables['GraphGroupEligibleMembers']) {
        Write-Host "  Eligible Assignments (from PIM):   $eligibleMigrated" -ForegroundColor White
    }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Resource Model Migration complete." -ForegroundColor Green
    #endregion
}
