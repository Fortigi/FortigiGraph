function Initialize-FGGovernanceTables {
    <#
    .SYNOPSIS
    Creates governance model tables (GovernanceCatalogs, AssignmentPolicies, AssignmentRequests, CertificationDecisions)
    and ensures governance columns exist on Resources, ResourceAssignments, and ResourceRelationships.

    .DESCRIPTION
    In the unified data model (v3.1), business roles are stored as Resources with resourceType='BusinessRole',
    their resource grants are stored as ResourceRelationships with relationshipType='Contains',
    and their assignments are stored as ResourceAssignments with assignmentType='Governed'.

    This function creates the remaining governance-specific tables:
    - GovernanceCatalogs: Containers for business roles (Entra: Catalogs, Omada: Policy groups)
    - AssignmentPolicies: Rules for how roles get assigned (auto-add, approval, reviews)
    - AssignmentRequests: Request/approval workflow history
    - CertificationDecisions: Periodic review/certification results

    It also ensures governance columns exist on the shared tables:
    - Resources: catalogId, isHidden
    - ResourceAssignments: policyId, state, assignmentStatus, expirationDateTime, extendedAttributes
    - ResourceRelationships: roleName, roleOriginSystem, extendedAttributes

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
    - Initialize-FGSystemTables should be called first (creates Resources, ResourceAssignments, ResourceRelationships)
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

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Initializing governance model tables (unified v3.1)..." -ForegroundColor Cyan

    # 1. GovernanceCatalogs table (temporal, UNIQUEIDENTIFIER PK) - unchanged
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

    # 2. AssignmentPolicies table (renamed from BusinessRolePolicies; FK: resourceId instead of businessRoleId)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Processing table: AssignmentPolicies" -ForegroundColor Cyan

    $policyColumns = @{
        'id'                   = 'UNIQUEIDENTIFIER'
        'systemId'             = 'INT'
        'resourceId'           = 'UNIQUEIDENTIFIER'
        'displayName'          = 'NVARCHAR(255)'
        'description'          = 'NVARCHAR(1024)'
        'allowedTargetScope'   = 'NVARCHAR(255)'
        'hasAutoAddRule'       = 'BIT'
        'hasAutoRemoveRule'    = 'BIT'
        'hasAccessReview'      = 'BIT'
        'automaticRequestSettings' = 'NVARCHAR(MAX)'
        'policyConditions'     = 'NVARCHAR(MAX)'
        'reviewSettings'       = 'NVARCHAR(MAX)'
        'createdDateTime'      = 'DATETIME2'
        'modifiedDateTime'     = 'DATETIME2'
        'extendedAttributes'   = 'NVARCHAR(MAX)'
    }

    $tableReady = Initialize-FGSyncTable -TableName "AssignmentPolicies" -Columns $policyColumns -PrimaryKey 'id' -RecreateTable:$DropIfExists
    if ($tableReady -eq $false) {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] AssignmentPolicies table creation cancelled" -ForegroundColor Yellow
    }

    # 3. AssignmentRequests table (renamed from BusinessRoleRequests; FK: resourceId instead of businessRoleId)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Processing table: AssignmentRequests" -ForegroundColor Cyan

    $requestColumns = @{
        'id'                 = 'UNIQUEIDENTIFIER'
        'systemId'           = 'INT'
        'resourceId'         = 'UNIQUEIDENTIFIER'
        'requestorId'        = 'UNIQUEIDENTIFIER'
        'requestType'        = 'NVARCHAR(50)'
        'requestState'       = 'NVARCHAR(50)'
        'requestStatus'      = 'NVARCHAR(100)'
        'isValidationOnly'   = 'BIT'
        'justification'      = 'NVARCHAR(MAX)'
        'accessPackage'      = 'NVARCHAR(MAX)'
        'requestor'          = 'NVARCHAR(MAX)'
        'schedule'           = 'NVARCHAR(MAX)'
        'createdDateTime'    = 'DATETIME2'
        'completedDateTime'  = 'DATETIME2'
        'syncBatchId'        = 'UNIQUEIDENTIFIER'
        'extendedAttributes' = 'NVARCHAR(MAX)'
    }

    $tableReady = Initialize-FGSyncTable -TableName "AssignmentRequests" -Columns $requestColumns -PrimaryKey 'id' -RecreateTable:$DropIfExists
    if ($tableReady -eq $false) {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] AssignmentRequests table creation cancelled" -ForegroundColor Yellow
    }

    # 4. CertificationDecisions table (temporal, UNIQUEIDENTIFIER PK)
    # Column renamed: businessRoleId -> resourceId
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Processing table: CertificationDecisions" -ForegroundColor Cyan

    $certColumns = @{
        'id'                           = 'UNIQUEIDENTIFIER'
        'systemId'                     = 'INT'
        'resourceId'                   = 'UNIQUEIDENTIFIER'
        'reviewInstanceId'             = 'UNIQUEIDENTIFIER'
        'reviewDefinitionId'           = 'UNIQUEIDENTIFIER'
        'principalId'                  = 'UNIQUEIDENTIFIER'
        'principalDisplayName'         = 'NVARCHAR(255)'
        'reviewedResourceId'           = 'UNIQUEIDENTIFIER'
        'reviewedResourceDisplayName'  = 'NVARCHAR(500)'
        'reviewedBy'                   = 'UNIQUEIDENTIFIER'
        'reviewedByDisplayName'        = 'NVARCHAR(255)'
        'reviewedDateTime'             = 'DATETIME2'
        'decision'                     = 'NVARCHAR(50)'
        'justification'                = 'NVARCHAR(MAX)'
        'recommendation'               = 'NVARCHAR(50)'
        'reviewInstanceStartDateTime'  = 'DATETIME2'
        'reviewInstanceEndDateTime'    = 'DATETIME2'
        'reviewInstanceStatus'         = 'NVARCHAR(50)'
        'extendedAttributes'           = 'NVARCHAR(MAX)'
    }

    $tableReady = Initialize-FGSyncTable -TableName "CertificationDecisions" -Columns $certColumns -PrimaryKey 'id' -RecreateTable:$DropIfExists
    if ($tableReady -eq $false) {
        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] CertificationDecisions table creation cancelled" -ForegroundColor Yellow
    }

    # 5. Ensure governance columns exist on shared tables (Resources, ResourceAssignments, ResourceRelationships)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Ensuring governance columns on shared tables..." -ForegroundColor Cyan

    $governanceColumnAdditions = @(
        @{ Table = 'Resources'; Columns = @{ 'catalogId' = 'UNIQUEIDENTIFIER'; 'isHidden' = 'BIT'; 'modifiedDateTime' = 'DATETIME2' } }
        @{ Table = 'ResourceAssignments'; Columns = @{ 'policyId' = 'UNIQUEIDENTIFIER'; 'state' = 'NVARCHAR(50)'; 'assignmentStatus' = 'NVARCHAR(50)'; 'expirationDateTime' = 'DATETIME2'; 'extendedAttributes' = 'NVARCHAR(MAX)'; 'complianceState' = 'NVARCHAR(100)' } }
        @{ Table = 'ResourceRelationships'; Columns = @{ 'roleName' = 'NVARCHAR(255)'; 'roleOriginSystem' = 'NVARCHAR(100)'; 'extendedAttributes' = 'NVARCHAR(MAX)' } }
    )

    foreach ($addition in $governanceColumnAdditions) {
        $tableName = $addition.Table
        $columnsToAdd = $addition.Columns

        Invoke-FGSQLCommand -ScriptBlock {
            param($connection)

            $checkCmd = $connection.CreateCommand()
            $checkCmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = '$tableName'"
            $tableExists = $checkCmd.ExecuteScalar() -gt 0
            $checkCmd.Dispose()

            if (-not $tableExists) {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] $tableName table not yet created (columns will be added when table is initialized)" -ForegroundColor Yellow
                return
            }

            # Check which columns are missing
            $missingColumns = @{}
            foreach ($colName in $columnsToAdd.Keys) {
                $colCheckCmd = $connection.CreateCommand()
                $colCheckCmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = '$tableName' AND COLUMN_NAME = '$colName'"
                $colExists = $colCheckCmd.ExecuteScalar() -gt 0
                $colCheckCmd.Dispose()

                if (-not $colExists) {
                    $missingColumns[$colName] = $columnsToAdd[$colName]
                }
            }

            if ($missingColumns.Count -gt 0) {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Adding $($missingColumns.Count) column(s) to $tableName : $($missingColumns.Keys -join ', ')" -ForegroundColor Cyan
                Add-FGSQLTableColumn -TableName $tableName -Columns $missingColumns
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Columns added to $tableName" -ForegroundColor Green
            }
            else {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] All governance columns already exist on $tableName" -ForegroundColor Yellow
            }
        }
    }

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Governance Model Tables Ready! (Unified v3.1)" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Governance tables:" -ForegroundColor White
    Write-Host "  - GovernanceCatalogs (temporal, UNIQUEIDENTIFIER PK)" -ForegroundColor Gray
    Write-Host "  - AssignmentPolicies (temporal, UNIQUEIDENTIFIER PK)" -ForegroundColor Gray
    Write-Host "  - AssignmentRequests (temporal, UNIQUEIDENTIFIER PK)" -ForegroundColor Gray
    Write-Host "  - CertificationDecisions (temporal, UNIQUEIDENTIFIER PK)" -ForegroundColor Gray
    Write-Host "Unified tables (with governance columns):" -ForegroundColor White
    Write-Host "  - Resources: +catalogId, +isHidden (BusinessRoles -> resourceType='BusinessRole')" -ForegroundColor Gray
    Write-Host "  - ResourceAssignments: +policyId, +state, +expirationDateTime (BusinessRoleAssignments -> assignmentType='Governed')" -ForegroundColor Gray
    Write-Host "  - ResourceRelationships: +roleName, +roleOriginSystem (BusinessRoleResources -> relationshipType='Contains')" -ForegroundColor Gray
    Write-Host "========================================`n" -ForegroundColor Green

    return $true
}
