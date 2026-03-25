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
    Name of the SQL table to create/sync to. Default: "BusinessRoleResources"

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
        [string]$TableName = "BusinessRoleResources",

        [Parameter(Mandatory = $false)]
        [switch]$RecreateTable,

        [Parameter(Mandatory = $false)]
        [int]$BatchSize = 100
    )

    # Track sync timing for logging
    $syncStartTime = Get-Date
    $syncStatus = "Failed"
    $syncErrorMessage = $null
    $syncRecordCount = 0

    # Check SQL connection
    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    # Check Graph access token
    if (-not $global:AccessToken) {
        throw "No Graph access token found. Please run Get-FGAccessToken first."
    }

    try {

    # Define fixed attributes for resource role scopes
    # These represent the flattened structure we'll store
    $Attributes = @(
        'id'                          # Composite ID (e.g., "guid1_guid2")
        'businessRoleId'             # Which access package this belongs to
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
        'businessRoleId' = 'UNIQUEIDENTIFIER'
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
        $tableReady = Initialize-FGSyncTable -TableName $TableName -Columns $columns -RecreateTable:$RecreateTable -CompositePrimaryKey @('businessRoleId', 'id')
        if ($tableReady -eq $false) { return }
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

        # Retry logic for transient errors (504 Gateway Timeout, 503 Service Unavailable, 429 Too Many Requests)
        $maxRetries = 3
        $retryCount = 0
        $retryDelays = @(5, 10, 20)  # Exponential backoff: 5s, 10s, 20s
        $success = $false

        while (-not $success -and $retryCount -le $maxRetries) {
            try {
                $packageWithScopes = Invoke-FGGetRequest -URI $scopesUri
                $scopes = $packageWithScopes.accessPackageResourceRoleScopes
                $success = $true

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

                        # Normalize GUID fields to uppercase - Microsoft Graph returns lowercase GUIDs
                        # for several fields in this endpoint, but all other endpoints use uppercase.
                        # Without this, JOINs between these fields and other tables will fail.
                        $normalizedScopeOriginId = if ($scope.accessPackageResourceScope.originId) {
                            $scope.accessPackageResourceScope.originId.ToUpper()
                        } else { $null }
                        $normalizedScopeId = if ($scope.accessPackageResourceScope.id) {
                            $scope.accessPackageResourceScope.id.ToUpper()
                        } else { $null }
                        $normalizedRoleId = if ($scope.accessPackageResourceRole.id) {
                            $scope.accessPackageResourceRole.id.ToUpper()
                        } else { $null }

                        $flatScope = [PSCustomObject]@{
                            id = $scope.id
                            businessRoleId = $package.id
                            roleId = $normalizedRoleId
                            roleDisplayName = $scope.accessPackageResourceRole.displayName
                            roleDescription = $scope.accessPackageResourceRole.description
                            roleOriginSystem = $scope.accessPackageResourceRole.originSystem
                            roleOriginId = $scope.accessPackageResourceRole.originId
                            scopeId = $normalizedScopeId
                            scopeDisplayName = $scope.accessPackageResourceScope.displayName
                            scopeOriginId = $normalizedScopeOriginId
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
                $statusCode = $null
                if ($_.Exception.Response) {
                    $statusCode = $_.Exception.Response.StatusCode.value__
                }

                # Check if this is a transient error that should be retried
                $isTransientError = $statusCode -in @(429, 503, 504)

                if ($isTransientError -and $retryCount -lt $maxRetries) {
                    $retryCount++
                    $waitTime = $retryDelays[$retryCount - 1]

                    Write-Warning "  [$(Get-Date -Format 'HH:mm:ss')] Transient error (Status $statusCode) for package '$($package.displayName)'"
                    Write-Warning "    Retry attempt $retryCount of $maxRetries after ${waitTime}s..."

                    Start-Sleep -Seconds $waitTime
                    # Loop will retry
                }
                else {
                    # Non-transient error or max retries reached
                    Write-Warning "  [$(Get-Date -Format 'HH:mm:ss')] Failed to get scopes for package '$($package.displayName)' (ID: $($package.id))"
                    Write-Warning "    Error: $($_.Exception.Message)"
                    if ($statusCode) {
                        Write-Warning "    Status Code: $statusCode"
                    }
                    if ($retryCount -gt 0) {
                        Write-Warning "    After $retryCount retry attempt(s)"
                    }
                    # Break out of retry loop
                    break
                }
            }
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

    $dataTable = New-FGDataTableFromGraphObjects -GraphObjects $allResourceRoleScopes -Columns $columns -Attributes $Attributes

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
            # CRITICAL: Must use composite PRIMARY KEY (accessPackageId, id) to match correctly
            $mergeResult = Invoke-FGSQLBulkMerge `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName $TableName `
                -DataTable $dataTable `
                -KeyColumns @('businessRoleId', 'id')

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
                -KeyColumns @('businessRoleId', 'id')

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

    # Set sync status for logging
    $syncRecordCount = $allResourceRoleScopes.Count
    $syncStatus = if ($errorCount -gt 0) { "PartialSuccess" } else { "Success" }

    } # End try
    catch {
        $syncErrorMessage = $_.Exception.Message
        $syncStatus = "Failed"
        throw
    }
    finally {
        # Write sync log entry
        Write-FGSyncLog -SyncType "AccessPackageResourceRoleScopes" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName $TableName
    }

    return @{
        TableName = $TableName
        TotalScopes = $allResourceRoleScopes.Count
        SyncedCount = $syncedCount
        DeletedCount = $deletedCount
        ErrorCount = $errorCount
        AccessPackagesProcessed = $allPackages.Count
    }
}
