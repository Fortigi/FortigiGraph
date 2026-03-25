function Initialize-FGGovernanceTables {
    <#
    .SYNOPSIS
    Creates all tables for the universal governance model (GovernanceCatalogs, BusinessRoles, BusinessRoleResources, BusinessRoleAssignments, BusinessRolePolicies, BusinessRoleRequests, CertificationDecisions).

    .DESCRIPTION
    Creates the governance tables for the universal data model:
    - GovernanceCatalogs: Containers for business roles (replaces GraphCatalogs)
    - BusinessRoles: Named entitlement bundles (replaces GraphAccessPackages)
    - BusinessRoleResources: Which resources a business role grants (replaces GraphAccessPackageResourceRoleScopes)
    - BusinessRoleAssignments: Who currently holds a business role (replaces GraphAccessPackageAssignments)
    - BusinessRolePolicies: Rules for how roles get assigned (replaces GraphAccessPackageAssignmentPolicies)
    - BusinessRoleRequests: Request/approval workflow history (replaces GraphAccessPackageAssignmentRequests)
    - CertificationDecisions: Periodic review/certification results (replaces GraphAccessPackageAccessReviewDecisions)

    All tables use temporal versioning, systemId FK to Systems, and extendedAttributes JSON
    for system-specific data.

    Tables are only created if they do not already exist, unless -DropIfExists is specified.

    .PARAMETER DropIfExists
    If specified, drops and recreates all tables (WARNING: loses all history!)

    .EXAMPLE
    Initialize-FGGovernanceTables

    Creates all governance tables if they don't exist

    .EXAMPLE
    Initialize-FGGovernanceTables -DropIfExists

    Drops and recreates all governance tables (loses all temporal history)

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    #>

    [CmdletBinding()]
    [Alias("Initialize-GovernanceTables")]
    Param(
        [Parameter(Mandatory = $false)]
        [switch]$DropIfExists
    )

    # Check SQL connection
    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Initializing universal governance model tables..." -ForegroundColor Cyan

    # 1. GovernanceCatalogs table (temporal, UNIQUEIDENTIFIER PK)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Processing table: GovernanceCatalogs" -ForegroundColor Cyan

    $catalogColumns = @{
        'id'                 = 'UNIQUEIDENTIFIER'
        'systemId'           = 'INT'
        'externalId'         = 'NVARCHAR(500)'
        'displayName'        = 'NVARCHAR(500)'
        'description'        = 'NVARCHAR(MAX)'
        'catalogType'        = 'NVARCHAR(50)'
        'isExternallyVisible' = 'BIT'
        'enabled'            = 'BIT'
        'createdDateTime'    = 'DATETIME2'
        'modifiedDateTime'   = 'DATETIME2'
        'extendedAttributes' = 'NVARCHAR(MAX)'
    }

    $tableReady = Initialize-FGSyncTable -TableName "GovernanceCatalogs" -Columns $catalogColumns -PrimaryKey 'id' -RecreateTable:$DropIfExists
    if ($tableReady -eq $false) {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] GovernanceCatalogs table creation cancelled" -ForegroundColor Yellow
    }

    # 2. BusinessRoles table (temporal, UNIQUEIDENTIFIER PK)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Processing table: BusinessRoles" -ForegroundColor Cyan

    $roleColumns = @{
        'id'                 = 'UNIQUEIDENTIFIER'
        'systemId'           = 'INT'
        'externalId'         = 'NVARCHAR(500)'
        'catalogId'          = 'UNIQUEIDENTIFIER'
        'displayName'        = 'NVARCHAR(500)'
        'description'        = 'NVARCHAR(MAX)'
        'isHidden'           = 'BIT'
        'createdDateTime'    = 'DATETIME2'
        'modifiedDateTime'   = 'DATETIME2'
        'extendedAttributes' = 'NVARCHAR(MAX)'
    }

    $tableReady = Initialize-FGSyncTable -TableName "BusinessRoles" -Columns $roleColumns -PrimaryKey 'id' -RecreateTable:$DropIfExists
    if ($tableReady -eq $false) {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] BusinessRoles table creation cancelled" -ForegroundColor Yellow
    }

    # 3. BusinessRoleResources table (temporal, composite PK)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Processing table: BusinessRoleResources" -ForegroundColor Cyan

    $roleResourceColumns = @{
        'id'                  = 'NVARCHAR(255)'
        'systemId'            = 'INT'
        'businessRoleId'      = 'UNIQUEIDENTIFIER'
        'resourceId'          = 'UNIQUEIDENTIFIER'
        'externalResourceId'  = 'NVARCHAR(500)'
        'roleName'            = 'NVARCHAR(255)'
        'roleDescription'     = 'NVARCHAR(1024)'
        'originSystem'        = 'NVARCHAR(100)'
        'createdDateTime'     = 'DATETIME2'
        'modifiedDateTime'    = 'DATETIME2'
        'extendedAttributes'  = 'NVARCHAR(MAX)'
    }

    $tableReady = Initialize-FGSyncTable -TableName "BusinessRoleResources" -Columns $roleResourceColumns -CompositePrimaryKey @('businessRoleId', 'id') -RecreateTable:$DropIfExists
    if ($tableReady -eq $false) {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] BusinessRoleResources table creation cancelled" -ForegroundColor Yellow
    }

    # 4. BusinessRoleAssignments table (temporal, UNIQUEIDENTIFIER PK)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Processing table: BusinessRoleAssignments" -ForegroundColor Cyan

    $assignmentColumns = @{
        'id'                 = 'UNIQUEIDENTIFIER'
        'systemId'           = 'INT'
        'businessRoleId'     = 'UNIQUEIDENTIFIER'
        'principalId'        = 'UNIQUEIDENTIFIER'
        'policyId'           = 'UNIQUEIDENTIFIER'
        'state'              = 'NVARCHAR(50)'
        'complianceState'    = 'NVARCHAR(100)'
        'assignmentStatus'   = 'NVARCHAR(50)'
        'expirationDateTime' = 'DATETIME2'
        'createdDateTime'    = 'DATETIME2'
        'extendedAttributes' = 'NVARCHAR(MAX)'
    }

    $tableReady = Initialize-FGSyncTable -TableName "BusinessRoleAssignments" -Columns $assignmentColumns -PrimaryKey 'id' -RecreateTable:$DropIfExists
    if ($tableReady -eq $false) {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] BusinessRoleAssignments table creation cancelled" -ForegroundColor Yellow
    }

    # 5. BusinessRolePolicies table (temporal, UNIQUEIDENTIFIER PK)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Processing table: BusinessRolePolicies" -ForegroundColor Cyan

    $policyColumns = @{
        'id'                   = 'UNIQUEIDENTIFIER'
        'systemId'             = 'INT'
        'businessRoleId'       = 'UNIQUEIDENTIFIER'
        'displayName'          = 'NVARCHAR(255)'
        'description'          = 'NVARCHAR(1024)'
        'allowedTargetScope'   = 'NVARCHAR(255)'
        'hasAutoAddRule'       = 'BIT'
        'hasAutoRemoveRule'    = 'BIT'
        'hasAccessReview'      = 'BIT'
        'policyConditions'     = 'NVARCHAR(MAX)'
        'reviewSettings'       = 'NVARCHAR(MAX)'
        'createdDateTime'      = 'DATETIME2'
        'modifiedDateTime'     = 'DATETIME2'
        'extendedAttributes'   = 'NVARCHAR(MAX)'
    }

    $tableReady = Initialize-FGSyncTable -TableName "BusinessRolePolicies" -Columns $policyColumns -PrimaryKey 'id' -RecreateTable:$DropIfExists
    if ($tableReady -eq $false) {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] BusinessRolePolicies table creation cancelled" -ForegroundColor Yellow
    }

    # 6. BusinessRoleRequests table (temporal, UNIQUEIDENTIFIER PK)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Processing table: BusinessRoleRequests" -ForegroundColor Cyan

    $requestColumns = @{
        'id'                 = 'UNIQUEIDENTIFIER'
        'systemId'           = 'INT'
        'businessRoleId'     = 'UNIQUEIDENTIFIER'
        'requestorId'        = 'UNIQUEIDENTIFIER'
        'requestType'        = 'NVARCHAR(50)'
        'requestState'       = 'NVARCHAR(50)'
        'requestStatus'      = 'NVARCHAR(100)'
        'justification'      = 'NVARCHAR(MAX)'
        'createdDateTime'    = 'DATETIME2'
        'completedDateTime'  = 'DATETIME2'
        'extendedAttributes' = 'NVARCHAR(MAX)'
    }

    $tableReady = Initialize-FGSyncTable -TableName "BusinessRoleRequests" -Columns $requestColumns -PrimaryKey 'id' -RecreateTable:$DropIfExists
    if ($tableReady -eq $false) {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] BusinessRoleRequests table creation cancelled" -ForegroundColor Yellow
    }

    # 7. CertificationDecisions table (temporal, UNIQUEIDENTIFIER PK)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Processing table: CertificationDecisions" -ForegroundColor Cyan

    $certColumns = @{
        'id'                      = 'UNIQUEIDENTIFIER'
        'systemId'                = 'INT'
        'businessRoleId'          = 'UNIQUEIDENTIFIER'
        'resourceId'              = 'UNIQUEIDENTIFIER'
        'certificationScopeType'  = 'NVARCHAR(50)'
        'principalId'             = 'UNIQUEIDENTIFIER'
        'principalDisplayName'    = 'NVARCHAR(255)'
        'reviewedById'            = 'UNIQUEIDENTIFIER'
        'reviewedByDisplayName'   = 'NVARCHAR(255)'
        'reviewedDateTime'        = 'DATETIME2'
        'decision'                = 'NVARCHAR(50)'
        'justification'           = 'NVARCHAR(MAX)'
        'recommendation'          = 'NVARCHAR(50)'
        'reviewInstanceId'        = 'UNIQUEIDENTIFIER'
        'reviewDefinitionId'      = 'UNIQUEIDENTIFIER'
        'instanceStartDateTime'   = 'DATETIME2'
        'instanceEndDateTime'     = 'DATETIME2'
        'instanceStatus'          = 'NVARCHAR(50)'
        'extendedAttributes'      = 'NVARCHAR(MAX)'
    }

    $tableReady = Initialize-FGSyncTable -TableName "CertificationDecisions" -Columns $certColumns -PrimaryKey 'id' -RecreateTable:$DropIfExists
    if ($tableReady -eq $false) {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] CertificationDecisions table creation cancelled" -ForegroundColor Yellow
    }

    # Add complianceState to ResourceAssignments if not present
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Ensuring complianceState column on ResourceAssignments..." -ForegroundColor Cyan

    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        $checkCmd = $connection.CreateCommand()
        $checkCmd.CommandText = @"
SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = 'ResourceAssignments'
"@
        $tableExists = $checkCmd.ExecuteScalar() -gt 0

        if ($tableExists) {
            $colCmd = $connection.CreateCommand()
            $colCmd.CommandText = @"
SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = 'ResourceAssignments' AND COLUMN_NAME = 'complianceState'
"@
            $colExists = $colCmd.ExecuteScalar() -gt 0

            if (-not $colExists) {
                Add-FGSQLTableColumn -TableName "ResourceAssignments" -Columns @{ 'complianceState' = 'NVARCHAR(100)' }
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Added complianceState column to ResourceAssignments" -ForegroundColor Green
            }
            else {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] complianceState column already exists on ResourceAssignments" -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] ResourceAssignments table not yet created (will be added when table is initialized)" -ForegroundColor Yellow
        }
    }

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Universal Governance Model Tables Ready!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Tables:" -ForegroundColor White
    Write-Host "  - GovernanceCatalogs (temporal, UNIQUEIDENTIFIER PK)" -ForegroundColor Gray
    Write-Host "  - BusinessRoles (temporal, UNIQUEIDENTIFIER PK)" -ForegroundColor Gray
    Write-Host "  - BusinessRoleResources (temporal, composite PK)" -ForegroundColor Gray
    Write-Host "  - BusinessRoleAssignments (temporal, UNIQUEIDENTIFIER PK)" -ForegroundColor Gray
    Write-Host "  - BusinessRolePolicies (temporal, UNIQUEIDENTIFIER PK)" -ForegroundColor Gray
    Write-Host "  - BusinessRoleRequests (temporal, UNIQUEIDENTIFIER PK)" -ForegroundColor Gray
    Write-Host "  - CertificationDecisions (temporal, UNIQUEIDENTIFIER PK)" -ForegroundColor Gray
    Write-Host "  - ResourceAssignments.complianceState (added column)" -ForegroundColor Gray
    Write-Host "========================================`n" -ForegroundColor Green

    return $true
}
