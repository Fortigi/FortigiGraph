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
            Initialize-FGSQLTable -TableName $TableName -Columns $columns -PrimaryKey 'id' -DropIfExists:$RecreateTable
        }
    }
    catch {
        throw "Failed to check/create table: $_"
    }

    # Build Graph API request - expand requestor to get user ID
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Fetching access package assignment requests from Microsoft Graph..." -ForegroundColor Cyan

    $uri = "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/assignmentRequests?`$expand=requestor,accessPackage"

    if ($Filter) {
        $uri += "&`$filter=$Filter"
    }

    # Fetch all requests using Invoke-FGGetRequest (handles token validation, pagination, and progress reporting)
    $graphStartTime = Get-Date

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

    # DIAGNOSTIC: Check for NULL or duplicate IDs in source data
    $nullIds = $allRequests | Where-Object { -not $_.id -or [string]::IsNullOrWhiteSpace($_.id) }
    if ($nullIds) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] CRITICAL: Found $($nullIds.Count) requests with NULL/empty IDs!"
        Write-Warning "This will cause MERGE to fail. Removing NULL ID requests from sync."
        $allRequests = $allRequests | Where-Object { $_.id -and -not [string]::IsNullOrWhiteSpace($_.id) }
    }

    $groupedById = $allRequests | Group-Object -Property id
    $duplicates = $groupedById | Where-Object { $_.Count -gt 1 }

    if ($duplicates) {
        Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] DIAGNOSTIC: Found $($duplicates.Count) request IDs with duplicates:" -ForegroundColor Yellow
        foreach ($dup in $duplicates | Select-Object -First 3) {
            Write-Host "  ID: $($dup.Name) appears $($dup.Count) times" -ForegroundColor Yellow
            Write-Host "    Sample differences:" -ForegroundColor Gray

            $firstItem = $dup.Group[0]
            $secondItem = $dup.Group[1]

            # Check key differences
            Write-Host "      Item 1: requestType=$($firstItem.requestType), requestState=$($firstItem.requestState), accessPackageId=$($firstItem.accessPackage.id), requestorId=$($firstItem.requestor.id)" -ForegroundColor Gray
            Write-Host "      Item 2: requestType=$($secondItem.requestType), requestState=$($secondItem.requestState), accessPackageId=$($secondItem.accessPackage.id), requestorId=$($secondItem.requestor.id)" -ForegroundColor Gray

            # Check if accessPackage is null vs just the id
            if ($null -eq $firstItem.accessPackage) {
                Write-Host "      WARNING: accessPackage object is NULL (likely a removal request or deleted package)" -ForegroundColor Yellow
            } elseif ([string]::IsNullOrWhiteSpace($firstItem.accessPackage.id)) {
                Write-Host "      WARNING: accessPackage exists but .id is NULL/empty" -ForegroundColor Yellow
            }
        }

        Write-Warning "Source data contains duplicate request IDs!"
        Write-Warning "Total requests: $($allRequests.Count), Unique IDs: $($groupedById.Count), Duplicates: $($allRequests.Count - $groupedById.Count)"
        Write-Warning "These duplicates are likely a Graph API pagination bug - will deduplicate before sync."

        # Deduplicate by keeping only the first occurrence of each ID
        $allRequests = $groupedById | ForEach-Object { $_.Group[0] }
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] After deduplication: $($allRequests.Count) unique requests" -ForegroundColor Green
    }

    # Sync to SQL using bulk operations (HIGH PERFORMANCE)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing assignment requests to SQL Server..." -ForegroundColor Cyan

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

    # Populate DataTable with request data
    foreach ($request in $allRequests) {
        $row = $dataTable.NewRow()

        foreach ($attr in $Attributes) {
            # Special handling for requestorId - extract from expanded requestor object
            if ($attr -eq 'requestorId') {
                $value = $request.requestor.id
            }
            elseif ($attr -eq 'accessPackageId') {
                $value = $request.accessPackage.id
            }
            else {
                $value = $request.$attr
            }

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
                            # For complex objects like schedule, convert to JSON
                            if ($value -is [PSCustomObject] -or $value -is [Hashtable]) {
                                $row[$attr] = [string]($value | ConvertTo-Json -Compress -Depth 10)
                            }
                            # For arrays, convert to JSON
                            elseif ($value -is [Array]) {
                                $row[$attr] = [string]($value | ConvertTo-Json -Compress -Depth 10)
                            }
                            else {
                                $row[$attr] = [string]$value
                            }
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

    return @{
        TableName = $TableName
        TotalRequests = $allRequests.Count
        SyncedCount = $syncedCount
        DeletedCount = $deletedCount
        ErrorCount = $errorCount
        Attributes = $Attributes
    }
}
