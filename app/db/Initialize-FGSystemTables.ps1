function Initialize-FGSystemTables {
    <#
    .SYNOPSIS
    Creates all tables for the universal resource model (Systems, SystemOwners, Resources, ResourceAssignments, ResourceRelationships, Principals, Identities, IdentityMembers).

    .DESCRIPTION
    Creates the foundational tables for the universal resource model:
    - Systems: Registry of connected systems (Entra ID, etc.) with temporal versioning
    - SystemOwners: Non-temporal mapping of system owners
    - Resources: Universal resource table with temporal versioning
    - ResourceAssignments: Principal-to-resource assignments with temporal versioning
    - ResourceRelationships: Resource-to-resource relationships with temporal versioning
    - Principals: Universal principal table (users, service principals, etc.) with temporal versioning
    - Identities: Real-person identity records across systems with temporal versioning
    - IdentityMembers: Identity-to-principal mappings with temporal versioning
    - Contexts: Organizational and other contextual groupings (departments, teams, projects) with temporal versioning

    Tables are only created if they do not already exist, unless -DropIfExists is specified.

    .PARAMETER DropIfExists
    If specified, drops and recreates all tables (WARNING: loses all history!)

    .EXAMPLE
    Initialize-FGSystemTables

    Creates all tables if they don't exist

    .EXAMPLE
    Initialize-FGSystemTables -DropIfExists

    Drops and recreates all tables (loses all temporal history)

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    #>

    [CmdletBinding()]
    [Alias("Initialize-SystemTables")]
    Param(
        [Parameter(Mandatory = $false)]
        [switch]$DropIfExists
    )

    # Check SQL connection
    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Initializing universal resource model tables..." -ForegroundColor Cyan

    # 1. Systems table (INT IDENTITY PK - must be created with raw SQL, not Initialize-FGSQLTable)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Processing table: Systems" -ForegroundColor Cyan

    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        $tableExists = $false
        $checkCmd = $connection.CreateCommand()
        $checkCmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'Systems' AND TABLE_SCHEMA = 'dbo'"
        $tableExists = $checkCmd.ExecuteScalar() -gt 0

        if ($tableExists -and -not $DropIfExists) {
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Table 'Systems' already exists (skipping)" -ForegroundColor Yellow
            # Ensure extendedAttributes column exists (added in v3.4)
            $colCheck = $connection.CreateCommand()
            $colCheck.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'Systems' AND TABLE_SCHEMA = 'dbo' AND COLUMN_NAME = 'extendedAttributes'"
            if ($colCheck.ExecuteScalar() -eq 0) {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Adding 'extendedAttributes' column to Systems..." -ForegroundColor Yellow
                $alterCmd = $connection.CreateCommand()
                $alterCmd.CommandText = "ALTER TABLE dbo.Systems ADD extendedAttributes NVARCHAR(MAX) NULL"
                $alterCmd.ExecuteNonQuery() | Out-Null
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Column added" -ForegroundColor Green
            }
            return
        }

        if ($tableExists -and $DropIfExists) {
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Dropping existing table 'Systems'..." -ForegroundColor Yellow
            $dropCmd = $connection.CreateCommand()
            $dropCmd.CommandText = @"
IF EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'Systems' AND TABLE_SCHEMA = 'dbo')
BEGIN
    ALTER TABLE dbo.Systems SET (SYSTEM_VERSIONING = OFF);
    DROP TABLE IF EXISTS dbo.SystemsHistory;
    DROP TABLE IF EXISTS dbo.Systems;
END
"@
            $dropCmd.ExecuteNonQuery() | Out-Null
        }

        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Creating table 'Systems' with temporal versioning..." -ForegroundColor Gray
        $createCmd = $connection.CreateCommand()
        $createCmd.CommandText = @"
CREATE TABLE dbo.Systems (
    id INT IDENTITY(1,1) NOT NULL,
    systemType NVARCHAR(50) NOT NULL,
    displayName NVARCHAR(500) NULL,
    description NVARCHAR(MAX) NULL,
    tenantId NVARCHAR(100) NULL,
    enabled BIT NULL DEFAULT 1,
    syncEnabled BIT NULL DEFAULT 1,
    lastSyncDateTime DATETIME2 NULL,
    resourceTypes NVARCHAR(MAX) NULL,
    assignmentTypes NVARCHAR(MAX) NULL,
    extendedAttributes NVARCHAR(MAX) NULL,
    ValidFrom DATETIME2 GENERATED ALWAYS AS ROW START NOT NULL DEFAULT SYSUTCDATETIME(),
    ValidTo DATETIME2 GENERATED ALWAYS AS ROW END NOT NULL DEFAULT CAST('9999-12-31 23:59:59.9999999' AS DATETIME2),
    PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo),
    CONSTRAINT PK_Systems PRIMARY KEY CLUSTERED (id)
) WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.SystemsHistory));
"@
        $createCmd.ExecuteNonQuery() | Out-Null
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Created table 'Systems' with temporal versioning" -ForegroundColor Green
    }

    # 2. SystemOwners table (non-temporal, simple mapping)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Processing table: SystemOwners" -ForegroundColor Cyan

    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        $tableExists = $false
        $checkCmd = $connection.CreateCommand()
        $checkCmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'SystemOwners' AND TABLE_SCHEMA = 'dbo'"
        $tableExists = $checkCmd.ExecuteScalar() -gt 0

        if ($tableExists -and -not $DropIfExists) {
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Table 'SystemOwners' already exists (skipping)" -ForegroundColor Yellow
            return
        }

        if ($tableExists -and $DropIfExists) {
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Dropping existing table 'SystemOwners'..." -ForegroundColor Yellow
            $dropCmd = $connection.CreateCommand()
            $dropCmd.CommandText = "DROP TABLE IF EXISTS dbo.SystemOwners;"
            $dropCmd.ExecuteNonQuery() | Out-Null
        }

        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Creating table 'SystemOwners'..." -ForegroundColor Gray
        $createCmd = $connection.CreateCommand()
        $createCmd.CommandText = @"
CREATE TABLE dbo.SystemOwners (
    systemId INT NOT NULL,
    userId UNIQUEIDENTIFIER NOT NULL,
    CONSTRAINT PK_SystemOwners PRIMARY KEY CLUSTERED (systemId, userId),
    CONSTRAINT FK_SystemOwners_Systems FOREIGN KEY (systemId) REFERENCES dbo.Systems(id)
);
"@
        $createCmd.ExecuteNonQuery() | Out-Null
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Created table 'SystemOwners'" -ForegroundColor Green
    }

    # 3. Resources table (temporal, UNIQUEIDENTIFIER PK)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Processing table: Resources" -ForegroundColor Cyan

    $resourceColumns = @{
        'id'                 = 'UNIQUEIDENTIFIER'
        'systemId'           = 'INT'
        'displayName'        = 'NVARCHAR(500)'
        'description'        = 'NVARCHAR(MAX)'
        'resourceType'       = 'NVARCHAR(255)'
        'createdDateTime'    = 'DATETIME2'
        'modifiedDateTime'   = 'DATETIME2'
        'mail'               = 'NVARCHAR(500)'
        'visibility'         = 'NVARCHAR(50)'
        'enabled'            = 'BIT'
        'externalId'         = 'NVARCHAR(500)'
        'contextId'          = 'UNIQUEIDENTIFIER'      # FK to Contexts (classification or grouping context)
        'catalogId'          = 'UNIQUEIDENTIFIER'
        'isHidden'           = 'BIT'
        'extendedAttributes' = 'NVARCHAR(MAX)'
    }

    $tableReady = Initialize-FGSyncTable -TableName "Resources" -Columns $resourceColumns -PrimaryKey 'id' -RecreateTable:$DropIfExists
    if ($tableReady -eq $false) {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Resources table creation cancelled" -ForegroundColor Yellow
    }

    # 4. ResourceAssignments table (temporal, composite PK)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Processing table: ResourceAssignments" -ForegroundColor Cyan

    $assignmentColumns = @{
        'resourceId'          = 'UNIQUEIDENTIFIER'
        'principalId'         = 'UNIQUEIDENTIFIER'
        'principalType'       = 'NVARCHAR(100)'
        'assignmentType'      = 'NVARCHAR(50)'
        'complianceState'     = 'NVARCHAR(100)'
        'policyId'            = 'UNIQUEIDENTIFIER'
        'state'               = 'NVARCHAR(50)'
        'assignmentStatus'    = 'NVARCHAR(50)'
        'expirationDateTime'  = 'DATETIME2'
        'extendedAttributes'  = 'NVARCHAR(MAX)'
    }

    $tableReady = Initialize-FGSyncTable -TableName "ResourceAssignments" -Columns $assignmentColumns -CompositePrimaryKey @('resourceId', 'principalId', 'assignmentType') -RecreateTable:$DropIfExists
    if ($tableReady -eq $false) {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] ResourceAssignments table creation cancelled" -ForegroundColor Yellow
    }

    # 5. ResourceRelationships table (temporal, composite PK)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Processing table: ResourceRelationships" -ForegroundColor Cyan

    $relationshipColumns = @{
        'parentResourceId'  = 'UNIQUEIDENTIFIER'
        'childResourceId'   = 'UNIQUEIDENTIFIER'
        'relationshipType'  = 'NVARCHAR(50)'
        'roleName'          = 'NVARCHAR(255)'
        'roleOriginSystem'  = 'NVARCHAR(100)'
        'extendedAttributes' = 'NVARCHAR(MAX)'
    }

    $tableReady = Initialize-FGSyncTable -TableName "ResourceRelationships" -Columns $relationshipColumns -CompositePrimaryKey @('parentResourceId', 'childResourceId', 'relationshipType') -RecreateTable:$DropIfExists
    if ($tableReady -eq $false) {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] ResourceRelationships table creation cancelled" -ForegroundColor Yellow
    }

    # 6. Principals table (temporal, UNIQUEIDENTIFIER PK)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Processing table: Principals" -ForegroundColor Cyan

    $principalColumns = @{
        'id'                 = 'UNIQUEIDENTIFIER'
        'systemId'           = 'INT'
        'displayName'        = 'NVARCHAR(500)'
        'email'              = 'NVARCHAR(500)'
        'accountEnabled'     = 'BIT'
        'principalType'      = 'NVARCHAR(50)'
        'externalId'         = 'NVARCHAR(500)'
        'givenName'          = 'NVARCHAR(255)'
        'surname'            = 'NVARCHAR(255)'
        'department'         = 'NVARCHAR(255)'
        'jobTitle'           = 'NVARCHAR(255)'
        'companyName'        = 'NVARCHAR(255)'
        'employeeId'         = 'NVARCHAR(255)'
        'managerId'          = 'UNIQUEIDENTIFIER'
        'contextId'          = 'UNIQUEIDENTIFIER'      # FK to Contexts (source system org structure, e.g. AD OU)
        'createdDateTime'    = 'DATETIME2'
        'extendedAttributes' = 'NVARCHAR(MAX)'
    }

    $tableReady = Initialize-FGSyncTable -TableName "Principals" -Columns $principalColumns -PrimaryKey 'id' -RecreateTable:$DropIfExists
    if ($tableReady -eq $false) {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Principals table creation cancelled" -ForegroundColor Yellow
    }

    # 7. Identities table (temporal, UNIQUEIDENTIFIER PK)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Processing table: Identities" -ForegroundColor Cyan

    $identityColumns = @{
        'id'                      = 'UNIQUEIDENTIFIER'
        'displayName'             = 'NVARCHAR(500)'
        'email'                   = 'NVARCHAR(500)'
        'department'              = 'NVARCHAR(255)'
        'jobTitle'                = 'NVARCHAR(255)'
        'companyName'             = 'NVARCHAR(255)'
        'employeeId'              = 'NVARCHAR(255)'
        'givenName'               = 'NVARCHAR(255)'
        'surname'                 = 'NVARCHAR(255)'
        'city'                    = 'NVARCHAR(255)'
        'country'                 = 'NVARCHAR(255)'
        'officeLocation'          = 'NVARCHAR(255)'
        'managerIdentityId'       = 'UNIQUEIDENTIFIER'
        'primaryPrincipalId'      = 'UNIQUEIDENTIFIER'
        'accountCount'            = 'INT'
        'accountTypes'            = 'NVARCHAR(500)'
        'correlationConfidence'   = 'INT'
        'correlationSignals'      = 'NVARCHAR(MAX)'
        'isHrAnchored'            = 'BIT'
        'hrAccountId'             = 'NVARCHAR(36)'
        'orphanStatus'            = 'NVARCHAR(50)'
        'correlatedAt'            = 'DATETIME2'
        'analystVerified'         = 'BIT'
        'analystNotes'            = 'NVARCHAR(MAX)'
        'contextId'               = 'UNIQUEIDENTIFIER'
    }

    $tableReady = Initialize-FGSyncTable -TableName "Identities" -Columns $identityColumns -PrimaryKey 'id' -RecreateTable:$DropIfExists
    if ($tableReady -eq $false) {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Identities table creation cancelled" -ForegroundColor Yellow
    }

    # 8. IdentityMembers table (temporal, composite PK)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Processing table: IdentityMembers" -ForegroundColor Cyan

    $identityMemberColumns = @{
        'identityId'          = 'UNIQUEIDENTIFIER'
        'principalId'         = 'UNIQUEIDENTIFIER'
        'displayName'         = 'NVARCHAR(500)'
        'accountType'         = 'NVARCHAR(50)'
        'accountTypePattern'  = 'NVARCHAR(200)'
        'isPrimary'           = 'BIT'
        'signalConfidence'    = 'INT'
        'correlationSignals'  = 'NVARCHAR(MAX)'
        'accountEnabled'      = 'BIT'
        'isHrAuthoritative'   = 'BIT'
        'hrScore'             = 'INT'
        'hrIndicators'        = 'NVARCHAR(MAX)'
        'analystOverride'     = 'NVARCHAR(50)'
    }

    $tableReady = Initialize-FGSyncTable -TableName "IdentityMembers" -Columns $identityMemberColumns -CompositePrimaryKey @('identityId', 'principalId') -RecreateTable:$DropIfExists
    if ($tableReady -eq $false) {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] IdentityMembers table creation cancelled" -ForegroundColor Yellow
    }

    # 9. Contexts table (temporal, UNIQUEIDENTIFIER PK)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Processing table: Contexts" -ForegroundColor Cyan

    $contextColumns = @{
        'id'                 = 'UNIQUEIDENTIFIER'
        'systemId'           = 'INT'
        'displayName'        = 'NVARCHAR(500)'
        'contextType'        = 'NVARCHAR(50)'          # Department, Division, CostCenter, Team, Office, Project, Location
        'parentContextId'    = 'UNIQUEIDENTIFIER'
        'managerId'          = 'UNIQUEIDENTIFIER'      # FK to Principals
        'managerIdentityId'  = 'UNIQUEIDENTIFIER'      # FK to Identities
        'department'         = 'NVARCHAR(255)'
        'division'           = 'NVARCHAR(255)'
        'costCenter'         = 'NVARCHAR(255)'
        'officeLocation'     = 'NVARCHAR(255)'
        'memberCount'        = 'INT'
        'totalMemberCount'   = 'INT'
        'sourceType'         = 'NVARCHAR(50)'          # Calculated, Synced
        'lastCalculatedAt'   = 'DATETIME2'
        'extendedAttributes' = 'NVARCHAR(MAX)'
    }

    $tableReady = Initialize-FGSyncTable -TableName "Contexts" -Columns $contextColumns -PrimaryKey 'id' -RecreateTable:$DropIfExists
    if ($tableReady -eq $false) {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Contexts table creation cancelled" -ForegroundColor Yellow
    }

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Universal Resource Model Tables Ready!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Tables:" -ForegroundColor White
    Write-Host "  - Systems (temporal, INT IDENTITY PK)" -ForegroundColor Gray
    Write-Host "  - SystemOwners (non-temporal, composite PK)" -ForegroundColor Gray
    Write-Host "  - Resources (temporal, UNIQUEIDENTIFIER PK)" -ForegroundColor Gray
    Write-Host "  - ResourceAssignments (temporal, composite PK)" -ForegroundColor Gray
    Write-Host "  - ResourceRelationships (temporal, composite PK)" -ForegroundColor Gray
    Write-Host "  - Principals (temporal, UNIQUEIDENTIFIER PK)" -ForegroundColor Gray
    Write-Host "  - Identities (temporal, UNIQUEIDENTIFIER PK)" -ForegroundColor Gray
    Write-Host "  - IdentityMembers (temporal, composite PK)" -ForegroundColor Gray
    Write-Host "  - Contexts (temporal, UNIQUEIDENTIFIER PK)" -ForegroundColor Gray
    Write-Host "========================================`n" -ForegroundColor Green

    return $true
}
