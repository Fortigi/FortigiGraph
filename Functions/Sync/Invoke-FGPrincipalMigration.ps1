function Invoke-FGPrincipalMigration {
    <#
    .SYNOPSIS
    Migrates data from legacy tables to the Principals, Identities, and IdentityMembers tables.

    .DESCRIPTION
    This function migrates data from the old tables to the new principal model:
    1. GraphUsers -> Principals (with principalType='User')
    2. GraphIdentities -> Identities (if old table exists)
    3. GraphIdentityMembers -> IdentityMembers (if old table exists)

    It is idempotent - running it multiple times will not create duplicate records
    (uses NOT EXISTS checks).

    .PARAMETER Force
    Skip confirmation prompts.

    .EXAMPLE
    Invoke-FGPrincipalMigration -Force

    Migrates all legacy data to the principal model tables without prompts.

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Legacy tables to exist with data
    #>

    [CmdletBinding()]
    [Alias("Invoke-PrincipalMigration")]
    Param(
        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    # Check SQL connection
    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Starting Principal Model Migration..." -ForegroundColor Cyan

    #region Ensure new tables exist
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Ensuring principal model tables exist..." -ForegroundColor Cyan
    try {
        Initialize-FGSystemTables
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Principal model tables ready" -ForegroundColor Green
    }
    catch {
        throw "Failed to create principal model tables: $($_.Exception.Message)"
    }
    #endregion

    #region Check old tables exist
    $oldTables = @{
        GraphUsers = $false
        GraphIdentities = $false
        GraphIdentityMembers = $false
    }

    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        foreach ($tableName in @('GraphUsers', 'GraphIdentities', 'GraphIdentityMembers')) {
            $cmd = $connection.CreateCommand()
            $cmd.CommandText = "SELECT CASE WHEN EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = @tableName) THEN 1 ELSE 0 END"
            $cmd.Parameters.AddWithValue("@tableName", $tableName) | Out-Null
            $exists = $cmd.ExecuteScalar()
            $oldTables[$tableName] = ($exists -eq 1)
        }
    }

    if (-not $oldTables['GraphUsers']) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] No legacy GraphUsers table found. Nothing to migrate." -ForegroundColor Yellow
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

    #region Migrate GraphUsers -> Principals
    if ($oldTables['GraphUsers']) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Migrating GraphUsers -> Principals..." -ForegroundColor Cyan

        $usersMigrated = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)

            $cmd = $connection.CreateCommand()
            $cmd.CommandTimeout = 300
            $cmd.CommandText = @"
INSERT INTO Principals (id, systemId, displayName, email, accountEnabled, principalType, externalId, givenName, surname, department, jobTitle, companyName, employeeId, managerId, createdDateTime, extendedAttributes)
SELECT
    u.id,
    @systemId,
    u.displayName,
    u.userPrincipalName,
    u.accountEnabled,
    'User',
    u.userPrincipalName,
    u.givenName,
    u.surname,
    u.department,
    u.jobTitle,
    u.companyName,
    u.employeeId,
    u.managerId,
    u.createdDateTime,
    (SELECT
        u.employeeType as employeeType,
        u.userType as userType,
        u.lastSignInDateTime as lastSignInDateTime,
        u.onPremisesSamAccountName as onPremisesSamAccountName,
        u.onPremisesSyncEnabled as onPremisesSyncEnabled,
        u.onPremisesDistinguishedName as onPremisesDistinguishedName,
        u.organizationalUnit as organizationalUnit,
        u.administrativeUnits as administrativeUnits,
        u.employeeHireDate as employeeHireDate,
        u.mail as mail
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
FROM GraphUsers u
WHERE u.ValidTo = '9999-12-31 23:59:59.9999999'
AND NOT EXISTS (SELECT 1 FROM Principals p WHERE p.id = u.id)
"@
            $cmd.Parameters.AddWithValue("@systemId", $systemId) | Out-Null
            $rowsAffected = $cmd.ExecuteNonQuery()
            return $rowsAffected
        }

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Users migrated to Principals: $usersMigrated" -ForegroundColor Green
    }
    #endregion

    #region Migrate GraphIdentities -> Identities
    if ($oldTables['GraphIdentities']) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Migrating GraphIdentities -> Identities..." -ForegroundColor Cyan

        $identitiesMigrated = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)

            # First check what columns exist in GraphIdentities to build a dynamic query
            $colCmd = $connection.CreateCommand()
            $colCmd.CommandText = "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = 'GraphIdentities'"
            $reader = $colCmd.ExecuteReader()
            $existingCols = @()
            while ($reader.Read()) {
                $existingCols += $reader.GetString(0)
            }
            $reader.Close()

            if ($existingCols.Count -eq 0) {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] GraphIdentities table has no columns or is empty" -ForegroundColor Yellow
                return 0
            }

            # Map source columns to target columns (only include columns that exist in both)
            $columnMap = @{
                'id' = 'id'
                'displayName' = 'displayName'
                'email' = 'email'
                'department' = 'department'
                'jobTitle' = 'jobTitle'
                'companyName' = 'companyName'
                'employeeId' = 'employeeId'
                'givenName' = 'givenName'
                'surname' = 'surname'
                'city' = 'city'
                'country' = 'country'
                'officeLocation' = 'officeLocation'
                'managerIdentityId' = 'managerIdentityId'
                'primaryPrincipalId' = 'primaryPrincipalId'
                'accountCount' = 'accountCount'
                'accountTypes' = 'accountTypes'
                'correlationConfidence' = 'correlationConfidence'
                'correlationSignals' = 'correlationSignals'
                'isHrAnchored' = 'isHrAnchored'
                'hrAccountId' = 'hrAccountId'
                'orphanStatus' = 'orphanStatus'
                'correlatedAt' = 'correlatedAt'
                'analystVerified' = 'analystVerified'
                'analystNotes' = 'analystNotes'
            }

            $targetCols = @()
            $sourceCols = @()
            foreach ($entry in $columnMap.GetEnumerator()) {
                if ($existingCols -contains $entry.Key) {
                    $targetCols += $entry.Value
                    $sourceCols += "gi.$($entry.Key)"
                }
            }

            if ($targetCols.Count -eq 0 -or $targetCols -notcontains 'id') {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] GraphIdentities table missing required columns" -ForegroundColor Yellow
                return 0
            }

            $cmd = $connection.CreateCommand()
            $cmd.CommandTimeout = 300
            $cmd.CommandText = @"
INSERT INTO Identities ($($targetCols -join ', '))
SELECT $($sourceCols -join ', ')
FROM GraphIdentities gi
WHERE gi.ValidTo = '9999-12-31 23:59:59.9999999'
AND NOT EXISTS (SELECT 1 FROM Identities i WHERE i.id = gi.id)
"@
            $rowsAffected = $cmd.ExecuteNonQuery()
            return $rowsAffected
        }

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Identities migrated: $identitiesMigrated" -ForegroundColor Green
    }
    #endregion

    #region Migrate GraphIdentityMembers -> IdentityMembers
    if ($oldTables['GraphIdentityMembers']) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Migrating GraphIdentityMembers -> IdentityMembers..." -ForegroundColor Cyan

        $membersMigrated = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)

            # Check what columns exist in GraphIdentityMembers
            $colCmd = $connection.CreateCommand()
            $colCmd.CommandText = "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = 'GraphIdentityMembers'"
            $reader = $colCmd.ExecuteReader()
            $existingCols = @()
            while ($reader.Read()) {
                $existingCols += $reader.GetString(0)
            }
            $reader.Close()

            if ($existingCols.Count -eq 0) {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] GraphIdentityMembers table has no columns or is empty" -ForegroundColor Yellow
                return 0
            }

            # Map source columns to target columns
            $columnMap = @{
                'identityId' = 'identityId'
                'principalId' = 'principalId'
                'displayName' = 'displayName'
                'accountType' = 'accountType'
                'accountTypePattern' = 'accountTypePattern'
                'isPrimary' = 'isPrimary'
                'signalConfidence' = 'signalConfidence'
                'correlationSignals' = 'correlationSignals'
                'accountEnabled' = 'accountEnabled'
                'isHrAuthoritative' = 'isHrAuthoritative'
                'hrScore' = 'hrScore'
                'hrIndicators' = 'hrIndicators'
                'analystOverride' = 'analystOverride'
            }

            $targetCols = @()
            $sourceCols = @()
            foreach ($entry in $columnMap.GetEnumerator()) {
                if ($existingCols -contains $entry.Key) {
                    $targetCols += $entry.Value
                    $sourceCols += "gim.$($entry.Key)"
                }
            }

            if ($targetCols.Count -eq 0 -or $targetCols -notcontains 'identityId' -or $targetCols -notcontains 'principalId') {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] GraphIdentityMembers table missing required columns" -ForegroundColor Yellow
                return 0
            }

            $cmd = $connection.CreateCommand()
            $cmd.CommandTimeout = 300
            $cmd.CommandText = @"
INSERT INTO IdentityMembers ($($targetCols -join ', '))
SELECT $($sourceCols -join ', ')
FROM GraphIdentityMembers gim
WHERE gim.ValidTo = '9999-12-31 23:59:59.9999999'
AND NOT EXISTS (
    SELECT 1 FROM IdentityMembers im
    WHERE im.identityId = gim.identityId AND im.principalId = gim.principalId
)
"@
            $rowsAffected = $cmd.ExecuteNonQuery()
            return $rowsAffected
        }

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Identity members migrated: $membersMigrated" -ForegroundColor Green
    }
    #endregion

    #region Summary
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Principal Migration Summary:" -ForegroundColor Cyan
    if ($oldTables['GraphUsers']) {
        Write-Host "  Principals (from GraphUsers):       $usersMigrated" -ForegroundColor White
    }
    if ($oldTables['GraphIdentities']) {
        Write-Host "  Identities (from GraphIdentities):  $identitiesMigrated" -ForegroundColor White
    }
    if ($oldTables['GraphIdentityMembers']) {
        Write-Host "  IdentityMembers (from GraphIdentityMembers): $membersMigrated" -ForegroundColor White
    }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Principal Model Migration complete." -ForegroundColor Green
    #endregion
}
