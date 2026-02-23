function Sync-FGAccessPackageAssignmentRequest {
    <#
    .SYNOPSIS
    Syncs Microsoft Graph access package assignment requests to Azure SQL with automatic schema detection and temporal versioning.

    .DESCRIPTION
    This function syncs access package assignment requests which track how users obtained access:
    - UserAdd: User requested access (may require approval)
    - AdminAdd: Admin directly assigned access
    - SystemAdd: System automatically assigned access (based on policy rules)

    Combined with assignment policies, this enables analysis of which assignments were:
    - Automatically assigned based on rules
    - Requested by users and approved
    - Directly assigned by administrators

    .PARAMETER Attributes
    Array of request attribute names to sync. If not specified, uses default set of common attributes.
    To add to defaults, use -AdditionalAttributes instead.

    .PARAMETER AdditionalAttributes
    Array of additional attributes to sync on top of the defaults.

    .PARAMETER Filter
    Optional OData filter to limit which requests to sync (e.g., "requestState eq 'Delivered'")

    .PARAMETER TableName
    Name of the SQL table to create/sync to. Default: "GraphAccessPackageAssignmentRequests"

    .PARAMETER RecreateTable
    If specified, drops and recreates the table (WARNING: loses all history!)

    .PARAMETER BatchSize
    Number of requests to process at once. Default: 100

    .PARAMETER UseBatching
    If specified, fetches and processes requests in batches by access package, syncing each batch
    to SQL immediately instead of collecting all in memory first.
    This uses much less memory (constant vs linear) and is required for Azure Automation runbooks
    or large environments that would otherwise hit OutOfMemoryException.

    .PARAMETER PageSize
    Number of records per Graph API page when using batching. Default: 500.
    Reduce this if you're hitting timeouts.

    .EXAMPLE
    Sync-FGAccessPackageAssignmentRequest

    Syncs all access package assignment requests with default attributes

    .EXAMPLE
    Sync-FGAccessPackageAssignmentRequest -UseBatching

    Syncs using batched mode (low memory, recommended for Azure Automation)

    .EXAMPLE
    Sync-FGAccessPackageAssignmentRequest -Filter "requestState eq 'Delivered'"

    Syncs only delivered/completed requests

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Valid Graph access token (Get-FGAccessToken)
    - Appropriate permissions: EntitlementManagement.Read.All
    - requestType shows how access was granted: UserAdd, AdminAdd, SystemAdd
    #>

    [CmdletBinding(DefaultParameterSetName = 'Default')]
    [Alias("Sync-AccessPackageAssignmentRequest")]
    Param(
        [Parameter(Mandatory = $false, ParameterSetName = 'Custom')]
        [string[]]$Attributes,

        [Parameter(Mandatory = $false, ParameterSetName = 'Default')]
        [string[]]$AdditionalAttributes,

        [Parameter(Mandatory = $false)]
        [string]$Filter,

        [Parameter(Mandatory = $false)]
        [string]$TableName = "GraphAccessPackageAssignmentRequests",

        [Parameter(Mandatory = $false)]
        [switch]$RecreateTable,

        [Parameter(Mandatory = $false)]
        [int]$BatchSize = 100,

        [Parameter(Mandatory = $false)]
        [switch]$UseBatching = $true,

        [Parameter(Mandatory = $false)]
        [int]$PageSize = 500
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

    $syncMode = if ($UseBatching) { "batched (low memory)" } else { "bulk (high performance)" }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Starting assignment request sync ($syncMode)..." -ForegroundColor Cyan

    # Define default attributes
    $defaultAttributes = @(
        # Identity
        'id'

        # Relationships
        'accessPackageId'
        'accessPackage'
        'requestor'
        'requestorId'  # We'll extract from expanded requestor object

        # Request details
        'requestType'   # UserAdd, AdminAdd, SystemAdd, UserRemove, etc.
        'requestState'  # Accepted, PendingApproval, Delivering, Delivered, Denied, etc.
        'requestStatus'

        # Approval
        'isValidationOnly'
        'justification'

        # Schedule
        'schedule'  # JSON object with start/end dates

        # Metadata
        'createdDateTime'
        'completedDateTime'
    )

    # Determine which attributes to use
    if ($PSCmdlet.ParameterSetName -eq 'Custom') {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Using custom attributes: $($Attributes.Count) attributes" -ForegroundColor Cyan

        # Ensure 'id' is always included
        if ($Attributes -notcontains 'id') {
            $Attributes = @('id') + $Attributes
            Write-Verbose "Added 'id' to attributes (required for primary key)"
        }
        if ($Attributes -notcontains 'requestorId') {
            $Attributes += 'requestorId'
            Write-Verbose "Added 'requestorId' to attributes (required for relationship)"
        }
    }
    else {
        $Attributes = $defaultAttributes

        if ($AdditionalAttributes) {
            foreach ($attr in $AdditionalAttributes) {
                if ($Attributes -notcontains $attr) {
                    $Attributes += $attr
                }
            }
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Using default attributes + $($AdditionalAttributes.Count) additional: Total $($Attributes.Count) attributes" -ForegroundColor Cyan
        }
        else {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Using default attributes: $($Attributes.Count) attributes" -ForegroundColor Cyan
        }
    }

    # Map Graph attribute types to SQL types
    $graphToSqlTypeMap = @{
        'id' = 'UNIQUEIDENTIFIER'
        'accessPackageId' = 'UNIQUEIDENTIFIER'
        'assignmentPolicyId' = 'UNIQUEIDENTIFIER'
        'requestorId' = 'UNIQUEIDENTIFIER'
        'requestType' = 'NVARCHAR(50)'
        'requestState' = 'NVARCHAR(50)'
        'requestStatus' = 'NVARCHAR(100)'
        'isValidationOnly' = 'BIT'
        'justification' = 'NVARCHAR(MAX)'
        'accessPackage' = 'NVARCHAR(MAX)'
        'requestor' = 'NVARCHAR(MAX)'
        'schedule' = 'NVARCHAR(MAX)'  # JSON object
        'createdDateTime' = 'DATETIME2'
        'completedDateTime' = 'DATETIME2'
        'syncBatchId' = 'UNIQUEIDENTIFIER'
    }

    # Build column definitions
    $columns = @{}
    $syncAttributes = $Attributes.Clone()

    # Add syncBatchId for batching mode
    if ($UseBatching) {
        if ($syncAttributes -notcontains 'syncBatchId') {
            $syncAttributes += 'syncBatchId'
        }
    }

    foreach ($attr in $syncAttributes) {
        $sqlType = $graphToSqlTypeMap[$attr]
        if (-not $sqlType) {
            $sqlType = 'NVARCHAR(MAX)'
            Write-Warning "Unknown attribute '$attr', using NVARCHAR(MAX). Consider adding to type map."
        }
        $columns[$attr] = $sqlType
    }

    # Value resolvers for special attributes
    $valueResolvers = @{
        'requestorId' = { param($obj) $obj.requestor.id }
        'accessPackageId' = { param($obj) $obj.accessPackage.id }
        'schedule' = { param($obj) if ($obj.schedule) { $obj.schedule | ConvertTo-Json -Compress -Depth 10 } else { $null } }
        'accessPackage' = { param($obj) if ($obj.accessPackage) { $obj.accessPackage | ConvertTo-Json -Compress -Depth 10 } else { $null } }
        'requestor' = { param($obj) if ($obj.requestor) { $obj.requestor | ConvertTo-Json -Compress -Depth 10 } else { $null } }
    }

    # Check if table exists and handle schema
    try {
        $tableExists = Test-FGSQLTableExists -TableName $TableName

        if ($tableExists -and $RecreateTable) {
            Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] Recreating table '$TableName' - all history will be lost!"
            $confirm = Read-Host "Are you sure? (Y/N)"
            if ($confirm -notmatch '^[Yy]') {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Operation cancelled." -ForegroundColor Yellow
                return
            }
        }
        elseif ($tableExists) {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Table '$TableName' already exists." -ForegroundColor Cyan

            # For batching mode, ensure syncBatchId column exists
            if ($UseBatching) {
                $existingColumns = Get-FGSQLTableSchema -TableName $TableName
                if ($existingColumns -notcontains 'syncBatchId') {
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Adding syncBatchId column for batching support..." -ForegroundColor Yellow
                    Add-FGSQLTableColumn -TableName $TableName -Columns @{ 'syncBatchId' = 'UNIQUEIDENTIFIER' }
                }
            }
        }
        else {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Table '$TableName' does not exist. Will be created..." -ForegroundColor Cyan
        }

        # Create table if needed
        $tableStillExists = Test-FGSQLTableExists -TableName $TableName

        if (-not $tableStillExists -or $RecreateTable) {
            Initialize-FGSQLTable -TableName $TableName -Columns $columns -PrimaryKey @('id') -DropIfExists:$RecreateTable
        }
    }
    catch {
        throw "Failed to check/create table: $_"
    }

    # Build Graph API request - expand requestor to get user ID
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Fetching access package assignment requests from Microsoft Graph..." -ForegroundColor Cyan

    $graphStartTime = Get-Date

    if ($UseBatching) {
        # ============================================
        # BATCHED MODE: Low memory, process per access package
        # Syncs each batch to SQL immediately instead of accumulating in memory
        # ============================================
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Using batched sync mode (low memory)..." -ForegroundColor Cyan
        Write-Host "  Each package's requests will be synced to SQL immediately" -ForegroundColor Gray

        # Generate a unique batch ID for this sync run
        $syncBatchId = [guid]::NewGuid()
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Sync batch ID: $syncBatchId" -ForegroundColor Gray

        # First, get all access packages
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Fetching access packages list..." -ForegroundColor Gray
        $accessPackagesUri = "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackages?`$select=id,displayName"
        $accessPackages = Invoke-FGGetRequest -URI $accessPackagesUri

        if (-not $accessPackages -or $accessPackages.Count -eq 0) {
            Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No access packages found."
            return
        }

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Found $($accessPackages.Count) access packages to process" -ForegroundColor Cyan

        $packageCount = 0
        $totalRequests = 0
        $totalInserted = 0
        $totalUpdated = 0
        $errorCount = 0

        foreach ($package in $accessPackages) {
            $packageCount++
            $percentComplete = [math]::Round(($packageCount / $accessPackages.Count) * 100, 1)
            $packageName = if ($package.displayName.Length -gt 30) { $package.displayName.Substring(0, 30) + "..." } else { $package.displayName }

            Write-Progress -Activity "Syncing Assignment Requests (Batched)" `
                -Status "Package $packageCount of $($accessPackages.Count) ($percentComplete%) - $totalRequests requests synced" `
                -PercentComplete $percentComplete

            # Build URI for this package's requests
            $uri = "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/assignmentRequests?`$expand=requestor,accessPackage&`$filter=accessPackage/id eq '$($package.id)'"
            if ($Filter) {
                $uri += " and ($Filter)"
            }
            $uri += "&`$top=$PageSize"

            try {
                $packageRequests = Invoke-FGGetRequest -URI $uri
                if (-not $packageRequests -or $packageRequests.Count -eq 0) {
                    continue
                }

                Write-Host "  [$packageCount/$($accessPackages.Count)] $packageName : $($packageRequests.Count) requests" -ForegroundColor Gray

                # Deduplicate within this batch
                $groupedById = $packageRequests | Group-Object -Property id
                $dupeCount = $packageRequests.Count - $groupedById.Count
                if ($dupeCount -gt 0) {
                    $packageRequests = $groupedById | ForEach-Object { $_.Group[0] }
                }

                # Build DataTable for this batch
                $dataTable = New-FGDataTableFromGraphObjects -GraphObjects $packageRequests -Columns $columns -Attributes $syncAttributes -ValueResolvers $valueResolvers

                # Set syncBatchId for all rows
                foreach ($row in $dataTable.Rows) {
                    $row["syncBatchId"] = $syncBatchId
                }

                $totalRequests += $dataTable.Rows.Count

                # Sync this batch to SQL immediately
                $batchResult = Invoke-FGSQLCommand -ScriptBlock {
                    param($connection)

                    $transaction = $connection.BeginTransaction()

                    try {
                        $mergeResult = Invoke-FGSQLBulkMerge `
                            -Connection $connection `
                            -Transaction $transaction `
                            -TargetTableName $TableName `
                            -DataTable $dataTable `
                            -KeyColumns @('id')

                        $transaction.Commit()
                        $transaction.Dispose()

                        return @{
                            Inserted = $mergeResult.Inserted
                            Updated = $mergeResult.Updated
                        }
                    }
                    catch {
                        if ($transaction) {
                            $transaction.Rollback()
                            $transaction.Dispose()
                        }
                        throw
                    }
                }

                $totalInserted += $batchResult.Inserted
                $totalUpdated += $batchResult.Updated

                # Free memory immediately
                $dataTable.Clear()
                $dataTable.Dispose()
                $dataTable = $null
                $packageRequests = $null
            }
            catch {
                $errorCount++
                Write-Warning "  [$packageCount/$($accessPackages.Count)] Failed for package $($package.id): $_"
            }

            # Trigger garbage collection periodically
            if ($packageCount % 50 -eq 0) {
                [System.GC]::Collect()
            }
        }

        Write-Progress -Activity "Syncing Assignment Requests (Batched)" -Completed

        # Also fetch removal requests (these may not have an accessPackage)
        Write-Host "  [Extra] Fetching removal requests..." -ForegroundColor Gray
        try {
            $removalUri = "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/assignmentRequests?`$expand=requestor&`$filter=requestType eq 'userRemove' or requestType eq 'adminRemove' or requestType eq 'systemRemove'"
            if ($Filter) {
                $removalUri += " and ($Filter)"
            }
            $removalUri += "&`$top=$PageSize"
            $removalRequests = Invoke-FGGetRequest -URI $removalUri
            if ($removalRequests -and $removalRequests.Count -gt 0) {
                Write-Host "    Found $($removalRequests.Count) removal requests" -ForegroundColor Gray

                # Deduplicate
                $groupedById = $removalRequests | Group-Object -Property id
                $removalRequests = $groupedById | ForEach-Object { $_.Group[0] }

                $dataTable = New-FGDataTableFromGraphObjects -GraphObjects $removalRequests -Columns $columns -Attributes $syncAttributes -ValueResolvers $valueResolvers
                foreach ($row in $dataTable.Rows) {
                    $row["syncBatchId"] = $syncBatchId
                }

                $totalRequests += $dataTable.Rows.Count

                $batchResult = Invoke-FGSQLCommand -ScriptBlock {
                    param($connection)
                    $transaction = $connection.BeginTransaction()
                    try {
                        $mergeResult = Invoke-FGSQLBulkMerge `
                            -Connection $connection `
                            -Transaction $transaction `
                            -TargetTableName $TableName `
                            -DataTable $dataTable `
                            -KeyColumns @('id')
                        $transaction.Commit()
                        $transaction.Dispose()
                        return @{ Inserted = $mergeResult.Inserted; Updated = $mergeResult.Updated }
                    }
                    catch {
                        if ($transaction) { $transaction.Rollback(); $transaction.Dispose() }
                        throw
                    }
                }

                $totalInserted += $batchResult.Inserted
                $totalUpdated += $batchResult.Updated

                $dataTable.Clear()
                $dataTable.Dispose()
                $dataTable = $null
                $removalRequests = $null
            }
        }
        catch {
            Write-Warning "    Failed to fetch removal requests: $_"
        }

        $graphElapsed = (Get-Date) - $graphStartTime
        $rate = if ($graphElapsed.TotalSeconds -gt 0) { [math]::Round($totalRequests / $graphElapsed.TotalSeconds, 1) } else { 0 }
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Batch sync completed: $totalInserted inserted, $totalUpdated updated ($rate requests/sec)" -ForegroundColor Green

        # Delete records that weren't seen in this sync (stale requests)
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking for deleted requests..." -ForegroundColor Cyan

        $deletedCount = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            $transaction = $connection.BeginTransaction()
            try {
                $deleteCmd = $connection.CreateCommand()
                $deleteCmd.Transaction = $transaction
                $deleteCmd.CommandTimeout = 120
                $deleteCmd.CommandText = @"
                    DELETE FROM dbo.[$TableName]
                    WHERE syncBatchId IS NULL OR syncBatchId <> @syncBatchId
"@
                $deleteCmd.Parameters.AddWithValue("@syncBatchId", $syncBatchId) | Out-Null
                $deleted = $deleteCmd.ExecuteNonQuery()
                $transaction.Commit()
                $transaction.Dispose()
                return $deleted
            }
            catch {
                if ($transaction) { $transaction.Rollback(); $transaction.Dispose() }
                throw
            }
        }

        if ($deletedCount -gt 0) {
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedCount requests that no longer exist in Graph" -ForegroundColor Yellow
        }
        else {
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] No deleted requests found" -ForegroundColor Green
        }

        $syncedCount = $totalInserted + $totalUpdated

        Write-Host "`n========================================" -ForegroundColor Green
        Write-Host "Sync Complete! (Batched Mode)" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "Table:               $TableName" -ForegroundColor White
        Write-Host "Access Packages:     $($accessPackages.Count)" -ForegroundColor White
        Write-Host "Total Requests:      $totalRequests" -ForegroundColor White
        Write-Host "Inserted:            $totalInserted" -ForegroundColor White
        Write-Host "Updated:             $totalUpdated" -ForegroundColor White
        Write-Host "Deleted:             $deletedCount" -ForegroundColor White
        Write-Host "Errors:              $errorCount" -ForegroundColor White
        Write-Host "`nAll changes are automatically tracked in ${TableName}_History" -ForegroundColor Cyan
        Write-Host "========================================`n" -ForegroundColor Green

        # Set sync status for logging
        $syncRecordCount = $totalRequests
        $syncStatus = if ($errorCount -gt 0) { "PartialSuccess" } else { "Success" }
    }
    else {
        # ============================================
        # BULK MODE: High performance, high memory
        # ============================================

        # STANDARD MODE: Fetch all requests at once (faster but uses more memory)
        $uri = "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/assignmentRequests?`$expand=requestor,accessPackage"

        if ($Filter) {
            $uri += "&`$filter=$Filter"
        }

        # Fetch all requests using Invoke-FGGetRequest (handles token validation, pagination, and progress reporting)
        $allRequests = @()
        try {
            $allRequests = Invoke-FGGetRequest -URI $uri
            if (-not $allRequests) {
                $allRequests = @()
            }
        }
        catch {
            throw "Failed to fetch assignment requests from Graph: $_"
        }

        $graphElapsed = (Get-Date) - $graphStartTime
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Total requests fetched: $($allRequests.Count) (took $([math]::Round($graphElapsed.TotalSeconds, 1))s)" -ForegroundColor Green

        if ($allRequests.Count -eq 0) {
            Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No assignment requests found to sync."
            return
        }

        # Analyze requests with null accessPackageId by requestType
        $nullAccessPackageRequests = $allRequests | Where-Object { $null -eq $_.accessPackage -or [string]::IsNullOrWhiteSpace($_.accessPackage.id) }
        if ($nullAccessPackageRequests.Count -gt 0) {
            Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Analysis: Found $($nullAccessPackageRequests.Count) requests with null/empty accessPackageId:" -ForegroundColor Cyan
            $byRequestType = $nullAccessPackageRequests | Group-Object -Property requestType | Sort-Object Count -Descending
            foreach ($group in $byRequestType) {
                $percentage = [math]::Round(($group.Count / $nullAccessPackageRequests.Count) * 100, 1)
                Write-Host "  $($group.Name): $($group.Count) requests ($percentage%)" -ForegroundColor Gray
            }
            Write-Host "  This is normal for removal requests (UserRemove/AdminRemove/SystemRemove)" -ForegroundColor Gray
            Write-Host "  These will sync with accessPackageId = NULL in SQL" -ForegroundColor Gray
        }

        # Check for NULL or duplicate IDs in source data
        $nullIds = $allRequests | Where-Object { -not $_.id -or [string]::IsNullOrWhiteSpace($_.id) }
        if ($nullIds) {
            Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] CRITICAL: Found $($nullIds.Count) requests with NULL/empty IDs!"
            Write-Warning "This will cause MERGE to fail. Removing NULL ID requests from sync."
            $allRequests = $allRequests | Where-Object { $_.id -and -not [string]::IsNullOrWhiteSpace($_.id) }
        }

        $groupedById = $allRequests | Group-Object -Property id
        $duplicates = $groupedById | Where-Object { $_.Count -gt 1 }

        if ($duplicates) {
            Write-Warning "Source data contains duplicate request IDs (Graph API pagination bug)"
            Write-Warning "Total requests: $($allRequests.Count), Unique IDs: $($groupedById.Count), Duplicates: $($allRequests.Count - $groupedById.Count)"

            # Deduplicate by keeping only the first occurrence of each ID
            $allRequests = $groupedById | ForEach-Object { $_.Group[0] }
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] After deduplication: $($allRequests.Count) unique requests" -ForegroundColor Green
        }

        # Sync to SQL using bulk operations (HIGH PERFORMANCE)
        Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing assignment requests to SQL Server..." -ForegroundColor Cyan

        # Build DataTable for bulk operations
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Preparing data for bulk sync..." -ForegroundColor Gray

        $dataTable = New-FGDataTableFromGraphObjects -GraphObjects $allRequests -Columns $columns -Attributes $syncAttributes -ValueResolvers $valueResolvers

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
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($dataTable.Rows.Count) assignment requests..." -ForegroundColor Cyan

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
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merge completed: $($mergeResult.Inserted) inserted, $($mergeResult.Updated) updated ($rate requests/sec)" -ForegroundColor Green

                # Handle deletions using bulk delete
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking for deleted requests..." -ForegroundColor Cyan

                $deletedCount = Invoke-FGSQLBulkDelete `
                    -Connection $connection `
                    -Transaction $transaction `
                    -TargetTableName $TableName `
                    -DataTable $dataTable `
                    -KeyColumns @('id')

                if ($deletedCount -gt 0) {
                    Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedCount requests that no longer exist in Graph" -ForegroundColor Yellow
                }
                else {
                    Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] No deleted requests found" -ForegroundColor Green
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
        Write-Host "Total Requests:      $($allRequests.Count)" -ForegroundColor White
        Write-Host "Synced:              $syncedCount" -ForegroundColor White
        Write-Host "Deleted:             $deletedCount" -ForegroundColor White
        Write-Host "Errors:              $errorCount" -ForegroundColor White
        Write-Host "Attributes:          $($Attributes.Count)" -ForegroundColor White
        Write-Host "`nAll changes are automatically tracked in ${TableName}_History" -ForegroundColor Cyan
        Write-Host "========================================`n" -ForegroundColor Green

        # Set sync status for logging
        $syncRecordCount = $allRequests.Count
        $syncStatus = if ($errorCount -gt 0) { "PartialSuccess" } else { "Success" }
    }

    } # End try
    catch {
        $syncErrorMessage = $_.Exception.Message
        $syncStatus = "Failed"
        throw
    }
    finally {
        # Write sync log entry
        Write-FGSyncLog -SyncType "AccessPackageAssignmentRequests" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName $TableName
    }
}
