function Sync-FGAccessPackageResourceRoleScope {
    <#
    .SYNOPSIS
    Syncs Microsoft Graph access package resource role scopes to Azure SQL with automatic schema detection and temporal versioning.

    .DESCRIPTION
    This function syncs the resources (groups, apps, sites) and roles (member, owner) that are included in each access package.
    This is the critical mapping that shows what group memberships/ownerships users receive when assigned an access package.

    - Fetches all access packages and their resource role scopes
    - Expands resource and role information for complete details
    - Automatically creates the SQL table on first run
    - Uses temporal tables for automatic change tracking
    - Enables analysis: "Which groups does a user get from access package X?"

    .PARAMETER TableName
    Name of the SQL table to create/sync to. Default: "GraphAccessPackageResourceRoleScopes"

    .PARAMETER RecreateTable
    If specified, drops and recreates the table (WARNING: loses all history!)

    .PARAMETER BatchSize
    Number of items to process at once. Default: 100

    .EXAMPLE
    Sync-FGAccessPackageResourceRoleScope

    Syncs all access package resource role scopes

    .EXAMPLE
    Sync-FGAccessPackageResourceRoleScope -TableName "APResourceRoles"

    Syncs to a custom table name

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Valid Graph access token (Get-FGAccessToken)
    - Appropriate permissions: EntitlementManagement.Read.All
    - This function makes multiple API calls (one per access package) to get resource role scopes
    - Progress is shown for large numbers of access packages
    #>

    [CmdletBinding()]
    [Alias("Sync-AccessPackageResourceRoleScope")]
    Param(
        [Parameter(Mandatory = $false)]
        [string]$TableName = "GraphAccessPackageResourceRoleScopes",

        [Parameter(Mandatory = $false)]
        [switch]$RecreateTable,

        [Parameter(Mandatory = $false)]
        [int]$BatchSize = 100
    )

    # Check SQL connection
    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    # Check Graph access token
    if (-not $global:AccessToken) {
        throw "No Graph access token found. Please run Get-FGAccessToken first."
    }

    # Define fixed attributes for resource role scopes
    # These represent the flattened structure we'll store
    $Attributes = @(
        'id'                          # Composite ID (e.g., "guid1_guid2")
        'accessPackageId'             # Which access package this belongs to
        'roleId'                      # Role ID from accessPackageResourceRole.id
        'roleDisplayName'             # Role display name (Member, Owner)
        'roleDescription'             # Role description
        'roleOriginSystem'            # Role origin (AadGroup, AadApplication)
        'roleOriginId'                # Role origin ID (e.g., "Member_guid")
        'scopeId'                     # Scope ID from accessPackageResourceScope.id
        'scopeDisplayName'            # Scope display name
        'scopeOriginId'               # Scope origin ID - THE ACTUAL GROUP/RESOURCE ID
        'scopeOriginSystem'           # Scope origin system (AadGroup, AadApplication)
        'scopeIsRootScope'            # Whether this is root scope
        'createdBy'                   # Who created this scope
        'createdDateTime'             # When this was added to the access package
        'modifiedBy'                  # Who last modified
        'modifiedDateTime'            # When last modified
    )

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Using fixed attributes: $($Attributes.Count) attributes" -ForegroundColor Cyan

    # Map attributes to SQL types
    $graphToSqlTypeMap = @{
        'id' = 'NVARCHAR(255)'              # Composite ID, not a GUID
        'accessPackageId' = 'UNIQUEIDENTIFIER'
        'roleId' = 'NVARCHAR(100)'          # Can be GUID or other format
        'roleDisplayName' = 'NVARCHAR(255)'
        'roleDescription' = 'NVARCHAR(1024)'
        'roleOriginSystem' = 'NVARCHAR(100)'
        'roleOriginId' = 'NVARCHAR(255)'
        'scopeId' = 'NVARCHAR(100)'         # Can be GUID or other format
        'scopeDisplayName' = 'NVARCHAR(255)'
        'scopeOriginId' = 'NVARCHAR(255)'   # The actual group/resource GUID
        'scopeOriginSystem' = 'NVARCHAR(100)'
        'scopeIsRootScope' = 'BIT'
        'createdBy' = 'NVARCHAR(255)'
        'createdDateTime' = 'DATETIME2'
        'modifiedBy' = 'NVARCHAR(255)'
        'modifiedDateTime' = 'DATETIME2'
    }

    # Build column definitions
    $columns = @{}
    foreach ($attr in $Attributes) {
        $columns[$attr] = $graphToSqlTypeMap[$attr]
    }

    # Check if table exists and handle schema
    try {
        $tableExists = Test-FGSQLTableExists -TableName $TableName

        if ($tableExists -and -not $RecreateTable) {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Table '$TableName' already exists. Checking schema..." -ForegroundColor Cyan

            # Get existing columns
            $existingColumns = Get-FGSQLTableSchema -TableName $TableName

            # Find missing columns
            $missingColumns = @{}
            foreach ($attr in $Attributes) {
                if ($existingColumns -notcontains $attr) {
                    $missingColumns[$attr] = $columns[$attr]
                }
            }

            if ($missingColumns.Count -gt 0) {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Found $($missingColumns.Count) new attribute(s) to add: $($missingColumns.Keys -join ', ')" -ForegroundColor Yellow
                Add-FGSQLTableColumn -TableName $TableName -Columns $missingColumns
            }
            else {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Schema is up to date" -ForegroundColor Green
            }
        }
        elseif ($tableExists -and $RecreateTable) {
            Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] Recreating table '$TableName' - all history will be lost!"
            $confirm = Read-Host "Are you sure? (Y/N)"
            if ($confirm -notmatch '^[Yy]') {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Operation cancelled." -ForegroundColor Yellow
                return
            }
        }
        else {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Table '$TableName' does not exist. Will be created..." -ForegroundColor Cyan
        }

        # Create table if needed
        $tableStillExists = Test-FGSQLTableExists -TableName $TableName

        if (-not $tableStillExists -or $RecreateTable) {
            # Use composite primary key: same role-scope can appear in multiple access packages
            Initialize-FGSQLTable -TableName $TableName -Columns $columns -PrimaryKey 'accessPackageId, id' -DropIfExists:$RecreateTable
        }
    }
    catch {
        throw "Failed to check/create table: $_"
    }

    # Step 1: Get all access packages
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Fetching access packages from Microsoft Graph..." -ForegroundColor Cyan

    $packagesUri = "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackages?`$select=id,displayName"

    try {
        $allPackages = Invoke-FGGetRequest -URI $packagesUri
        if (-not $allPackages) {
            $allPackages = @()
        }
    }
    catch {
        throw "Failed to fetch access packages from Graph: $_"
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Found $($allPackages.Count) access packages" -ForegroundColor Green

    if ($allPackages.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No access packages found. Nothing to sync."
        return
    }

    # Step 2: For each access package, get its resource role scopes
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Fetching resource role scopes for each access package..." -ForegroundColor Cyan

    $allResourceRoleScopes = @()
    $processedCount = 0
    $graphStartTime = Get-Date

    foreach ($package in $allPackages) {
        $processedCount++

        # Show progress bar
        $percentComplete = [math]::Round(($processedCount / $allPackages.Count) * 100, 1)
        Write-Progress -Activity "Fetching Resource Role Scopes" -Status "Processing package $processedCount of $($allPackages.Count) ($percentComplete%)" -PercentComplete $percentComplete

        # Get resource role scopes for this access package with expansion
        # Using the correct endpoint pattern from Get-FGAccessPackagesResource
        $scopesUri = "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackages/$($package.id)?`$expand=accessPackageResourceRoleScopes(`$expand=accessPackageResourceRole,accessPackageResourceScope)"

        try {
            $packageWithScopes = Invoke-FGGetRequest -URI $scopesUri
            $scopes = $packageWithScopes.accessPackageResourceRoleScopes

            if ($scopes -and $scopes.Count -gt 0) {
                # Flatten the complex structure into our desired format
                foreach ($scope in $scopes) {
                    # Skip scopes with null/empty id
                    if (-not $scope.id -or [string]::IsNullOrWhiteSpace($scope.id)) {
                        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] WARNING: Skipping scope with NULL/empty id for package '$($package.displayName)'" -ForegroundColor Yellow
                        continue
                    }

                    # Note: The ID is a composite string like "guid1_guid2", not a single GUID
                    # This is expected and valid

                    $flatScope = [PSCustomObject]@{
                        id = $scope.id
                        accessPackageId = $package.id
                        roleId = $scope.accessPackageResourceRole.id
                        roleDisplayName = $scope.accessPackageResourceRole.displayName
                        roleDescription = $scope.accessPackageResourceRole.description
                        roleOriginSystem = $scope.accessPackageResourceRole.originSystem
                        roleOriginId = $scope.accessPackageResourceRole.originId
                        scopeId = $scope.accessPackageResourceScope.id
                        scopeDisplayName = $scope.accessPackageResourceScope.displayName
                        scopeOriginId = $scope.accessPackageResourceScope.originId
                        scopeOriginSystem = $scope.accessPackageResourceScope.originSystem
                        scopeIsRootScope = $scope.accessPackageResourceScope.isRootScope
                        createdBy = $scope.createdBy
                        createdDateTime = $scope.createdDateTime
                        modifiedBy = $scope.modifiedBy
                        modifiedDateTime = $scope.modifiedDateTime
                    }
                    $allResourceRoleScopes += $flatScope
                }
            }
        }
        catch {
            Write-Warning "  [$(Get-Date -Format 'HH:mm:ss')] Failed to get scopes for package '$($package.displayName)' (ID: $($package.id))"
            Write-Warning "    Error: $($_.Exception.Message)"
            if ($_.Exception.Response) {
                Write-Warning "    Status Code: $($_.Exception.Response.StatusCode.value__)"
            }
            # Continue with next package
        }
    }

    Write-Progress -Activity "Fetching Resource Role Scopes" -Completed

    $graphElapsed = (Get-Date) - $graphStartTime
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Total resource role scopes fetched: $($allResourceRoleScopes.Count) (took $([math]::Round($graphElapsed.TotalSeconds, 1))s)" -ForegroundColor Green

    if ($allResourceRoleScopes.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No resource role scopes found to sync."
        return
    }

    # Sync to SQL using bulk operations (HIGH PERFORMANCE)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing resource role scopes to SQL Server..." -ForegroundColor Cyan

    # Build DataTable for bulk operations
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Preparing data for bulk sync..." -ForegroundColor Gray

    $dataTable = New-Object System.Data.DataTable

    # Add columns based on attributes and their SQL types
    foreach ($attr in $Attributes) {
        $sqlType = $columns[$attr]
        $dotNetType = switch -Regex ($sqlType) {
            'UNIQUEIDENTIFIER' { [guid] }
            'BIT' { [bool] }
            'DATETIME2' { [datetime] }
            'INT' { [int] }
            'BIGINT' { [long] }
            default { [string] }
        }
        $dataTable.Columns.Add($attr, $dotNetType) | Out-Null
    }

    # Populate DataTable with resource role scope data
    foreach ($scope in $allResourceRoleScopes) {
        $row = $dataTable.NewRow()

        foreach ($attr in $Attributes) {
            $value = $scope.$attr

            # Convert value to appropriate type or DBNull
            if ($null -eq $value -or $value -eq '') {
                $row[$attr] = [DBNull]::Value
            }
            else {
                # Type conversion based on column type
                $sqlType = $columns[$attr]
                try {
                    switch -Regex ($sqlType) {
                        'UNIQUEIDENTIFIER' { $row[$attr] = [guid]$value }
                        'BIT' { $row[$attr] = [bool]$value }
                        'DATETIME2' { $row[$attr] = [datetime]$value }
                        'INT' { $row[$attr] = [int]$value }
                        'BIGINT' { $row[$attr] = [long]$value }
                        default {
                            $row[$attr] = [string]$value
                        }
                    }
                }
                catch {
                    # If conversion fails, use DBNull
                    $row[$attr] = [DBNull]::Value
                }
            }
        }

        $dataTable.Rows.Add($row)
    }

    $syncResult = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Database connection established" -ForegroundColor Gray

        # Start transaction
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Starting transaction..." -ForegroundColor Gray
        $transaction = $connection.BeginTransaction()

        $syncedCount = 0
        $errorCount = 0
        $deletedCount = 0
        $syncStartTime = Get-Date

        try {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($dataTable.Rows.Count) resource role scopes..." -ForegroundColor Cyan

            # Use bulk MERGE operation - much faster than row-by-row
            $mergeResult = Invoke-FGSQLBulkMerge `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName $TableName `
                -DataTable $dataTable `
                -KeyColumns @('id')

            $syncedCount = $mergeResult.Inserted + $mergeResult.Updated

            $syncElapsed = (Get-Date) - $syncStartTime
            $rate = if ($syncElapsed.TotalSeconds -gt 0) { [math]::Round($syncedCount / $syncElapsed.TotalSeconds, 1) } else { 0 }
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merge completed: $($mergeResult.Inserted) inserted, $($mergeResult.Updated) updated ($rate scopes/sec)" -ForegroundColor Green

            # Handle deletions using bulk delete (avoids massive IN clause)
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking for deleted resource role scopes..." -ForegroundColor Cyan

            $deletedCount = Invoke-FGSQLBulkDelete `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName $TableName `
                -DataTable $dataTable `
                -KeyColumns @('accessPackageId', 'id')

            if ($deletedCount -gt 0) {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedCount scopes that no longer exist in Graph" -ForegroundColor Yellow
            }
            else {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] No deleted scopes found" -ForegroundColor Green
            }

            # Commit transaction
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Committing transaction..." -ForegroundColor Cyan
            $transaction.Commit()

            $totalElapsed = (Get-Date) - $syncStartTime
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Transaction committed successfully (took $([math]::Round($totalElapsed.TotalSeconds, 1))s)" -ForegroundColor Green

            # Cleanup
            $transaction.Dispose()

            return @{
                SyncedCount = $syncedCount
                ErrorCount = $errorCount
                DeletedCount = $deletedCount
            }
        }
        catch {
            Write-Error "[$(Get-Date -Format 'HH:mm:ss')] Failed during sync: $_"
            if ($transaction) {
                $transaction.Rollback()
                $transaction.Dispose()
            }
            throw
        }
    }

    $syncedCount = $syncResult.SyncedCount
    $errorCount = $syncResult.ErrorCount
    $deletedCount = $syncResult.DeletedCount

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Sync Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Table:               $TableName" -ForegroundColor White
    Write-Host "Total Scopes:        $($allResourceRoleScopes.Count)" -ForegroundColor White
    Write-Host "Synced:              $syncedCount" -ForegroundColor White
    Write-Host "Deleted:             $deletedCount" -ForegroundColor White
    Write-Host "Errors:              $errorCount" -ForegroundColor White
    Write-Host "Access Packages:     $($allPackages.Count)" -ForegroundColor White
    Write-Host "`nAll changes are automatically tracked in ${TableName}_History" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Green

    return @{
        TableName = $TableName
        TotalScopes = $allResourceRoleScopes.Count
        SyncedCount = $syncedCount
        DeletedCount = $deletedCount
        ErrorCount = $errorCount
        AccessPackagesProcessed = $allPackages.Count
    }
}
