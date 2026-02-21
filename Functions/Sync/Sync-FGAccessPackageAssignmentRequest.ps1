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
    If specified, fetches and processes requests in batches by access package.
    This uses less memory and is recommended for Azure Automation runbooks or large environments.
    Instead of loading all requests at once, it fetches requests per access package.

    .PARAMETER PageSize
    Number of records per Graph API page when using batching. Default: 500.
    Reduce this if you're hitting timeouts.

    .EXAMPLE
    Sync-FGAccessPackageAssignmentRequest

    Syncs all access package assignment requests with default attributes

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
        [switch]$UseBatching,

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
    }

    # Build column definitions
    $columns = @{}
    foreach ($attr in $Attributes) {
        $sqlType = $graphToSqlTypeMap[$attr]
        if (-not $sqlType) {
            $sqlType = 'NVARCHAR(MAX)'
            Write-Warning "Unknown attribute '$attr', using NVARCHAR(MAX). Consider adding to type map."
        }
        $columns[$attr] = $sqlType
    }

    # Check if table exists and handle schema
    try {
        $tableReady = Initialize-FGSyncTable -TableName $TableName -Columns $columns -RecreateTable:$RecreateTable
        if ($tableReady -eq $false) { return }
    }
    catch {
        throw "Failed to check/create table: $_"
    }

    # Build Graph API request - expand requestor to get user ID
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Fetching access package assignment requests from Microsoft Graph..." -ForegroundColor Cyan

    $graphStartTime = Get-Date
    $allRequests = @()

    if ($UseBatching) {
        # BATCHING MODE: Fetch requests per access package to reduce memory usage
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Using batching mode (per access package)..." -ForegroundColor Cyan

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
        foreach ($package in $accessPackages) {
            $packageCount++
            $packageName = if ($package.displayName.Length -gt 30) { $package.displayName.Substring(0, 30) + "..." } else { $package.displayName }
            Write-Host "  [$packageCount/$($accessPackages.Count)] Processing: $packageName" -ForegroundColor Gray

            # Build URI for this package's requests
            $uri = "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/assignmentRequests?`$expand=requestor,accessPackage&`$filter=accessPackage/id eq '$($package.id)'"
            if ($Filter) {
                $uri += " and ($Filter)"
            }
            $uri += "&`$top=$PageSize"

            try {
                $packageRequests = Invoke-FGGetRequest -URI $uri
                if ($packageRequests) {
                    $allRequests += $packageRequests
                    Write-Host "    Found $($packageRequests.Count) requests" -ForegroundColor Gray
                }
            }
            catch {
                Write-Warning "    Failed to fetch requests for package $($package.id): $_"
            }

            # Trigger garbage collection periodically to free memory
            if ($packageCount % 50 -eq 0) {
                [System.GC]::Collect()
            }
        }

        # Also fetch requests without access package (removal requests)
        Write-Host "  [Extra] Fetching requests without access package (removals)..." -ForegroundColor Gray
        try {
            $removalUri = "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/assignmentRequests?`$expand=requestor&`$filter=requestType eq 'userRemove' or requestType eq 'adminRemove' or requestType eq 'systemRemove'"
            if ($Filter) {
                $removalUri += " and ($Filter)"
            }
            $removalUri += "&`$top=$PageSize"
            $removalRequests = Invoke-FGGetRequest -URI $removalUri
            if ($removalRequests) {
                $allRequests += $removalRequests
                Write-Host "    Found $($removalRequests.Count) removal requests" -ForegroundColor Gray
            }
        }
        catch {
            Write-Warning "    Failed to fetch removal requests: $_"
        }

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Batching complete" -ForegroundColor Green
    }
    else {
        # STANDARD MODE: Fetch all requests at once (faster but uses more memory)
        $uri = "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/assignmentRequests?`$expand=requestor,accessPackage"

        if ($Filter) {
            $uri += "&`$filter=$Filter"
        }

        # Fetch all requests using Invoke-FGGetRequest (handles token validation, pagination, and progress reporting)
        try {
            $allRequests = Invoke-FGGetRequest -URI $uri
            if (-not $allRequests) {
                $allRequests = @()
            }
        }
        catch {
            throw "Failed to fetch assignment requests from Graph: $_"
        }
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

    $valueResolvers = @{
        'requestorId' = { param($obj) $obj.requestor.id }
        'accessPackageId' = { param($obj) $obj.accessPackage.id }
        'schedule' = { param($obj) if ($obj.schedule) { $obj.schedule | ConvertTo-Json -Compress -Depth 10 } else { $null } }
        'accessPackage' = { param($obj) if ($obj.accessPackage) { $obj.accessPackage | ConvertTo-Json -Compress -Depth 10 } else { $null } }
        'requestor' = { param($obj) if ($obj.requestor) { $obj.requestor | ConvertTo-Json -Compress -Depth 10 } else { $null } }
    }

    $dataTable = New-FGDataTableFromGraphObjects -GraphObjects $allRequests -Columns $columns -Attributes $Attributes -ValueResolvers $valueResolvers

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

    return @{
        TableName = $TableName
        TotalRequests = $allRequests.Count
        SyncedCount = $syncedCount
        DeletedCount = $deletedCount
        ErrorCount = $errorCount
        Attributes = $Attributes
    }
}
