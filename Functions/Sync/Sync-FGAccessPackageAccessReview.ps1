function Sync-FGAccessPackageAccessReview {
    <#
    .SYNOPSIS
    Syncs Microsoft Graph access reviews for access packages to Azure SQL with automatic schema detection and temporal versioning.

    .DESCRIPTION
    This function syncs access review data for access packages, including:
    - Access review definitions (scheduled review configurations)
    - Access review instances (individual review occurrences)
    - Access review decisions (reviewer actions and timestamps)

    This enables analysis of:
    - When each access package was last reviewed
    - Who performed the reviews
    - Review decisions (approve, deny, no decision)
    - Review coverage and compliance

    .PARAMETER TableName
    Name of the SQL table to create/sync to. Default: "GraphAccessPackageAccessReviewDecisions"

    .PARAMETER RecreateTable
    If specified, drops and recreates the table (WARNING: loses all history!)

    .EXAMPLE
    Sync-FGAccessPackageAccessReview

    Syncs all access review data for access packages

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Valid Graph access token (Get-FGAccessToken)
    - Appropriate permissions: AccessReview.Read.All
    - This function fetches review instances with decisions to capture reviewer activity
    #>

    [CmdletBinding()]
    [Alias("Sync-AccessPackageAccessReview")]
    Param(
        [Parameter(Mandatory = $false)]
        [string]$TableName = "GraphAccessPackageAccessReviewDecisions",

        [Parameter(Mandatory = $false)]
        [switch]$RecreateTable
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

    # Define attributes for flattened review decision data
    $Attributes = @(
        'id'                           # Decision ID (unique)
        'reviewInstanceId'             # Which review instance this decision belongs to
        'reviewDefinitionId'           # Which review definition/schedule
        'accessPackageId'              # Which access package was reviewed
        'reviewedResourceId'           # Resource being reviewed (often the access package assignment)
        'reviewedResourceDisplayName'  # Display name of reviewed resource
        'reviewedBy'                   # User ID who performed the review
        'reviewedByDisplayName'        # Display name of reviewer
        'reviewedDateTime'             # When the review was performed
        'decision'                     # Approve, Deny, DontKnow, NotReviewed
        'justification'                # Reviewer's justification
        'recommendation'               # System recommendation
        'reviewInstanceStartDateTime'  # When this review instance started
        'reviewInstanceEndDateTime'    # When this review instance ended
        'reviewInstanceStatus'         # Status of the review instance
    )

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Using fixed attributes: $($Attributes.Count) attributes" -ForegroundColor Cyan

    # Map attributes to SQL types
    $graphToSqlTypeMap = @{
        'id' = 'UNIQUEIDENTIFIER'
        'reviewInstanceId' = 'UNIQUEIDENTIFIER'
        'reviewDefinitionId' = 'UNIQUEIDENTIFIER'
        'accessPackageId' = 'UNIQUEIDENTIFIER'
        'reviewedResourceId' = 'UNIQUEIDENTIFIER'
        'reviewedResourceDisplayName' = 'NVARCHAR(500)'
        'reviewedBy' = 'UNIQUEIDENTIFIER'
        'reviewedByDisplayName' = 'NVARCHAR(255)'
        'reviewedDateTime' = 'DATETIME2'
        'decision' = 'NVARCHAR(50)'
        'justification' = 'NVARCHAR(MAX)'
        'recommendation' = 'NVARCHAR(50)'
        'reviewInstanceStartDateTime' = 'DATETIME2'
        'reviewInstanceEndDateTime' = 'DATETIME2'
        'reviewInstanceStatus' = 'NVARCHAR(50)'
    }

    # Build column definitions
    $columns = @{}
    foreach ($attr in $Attributes) {
        $columns[$attr] = $graphToSqlTypeMap[$attr]
    }

    # Check if table exists and handle schema
    try {
        $tableReady = Initialize-FGSyncTable -TableName $TableName -Columns $columns -RecreateTable:$RecreateTable
        if ($tableReady -eq $false) { return }
    }
    catch {
        throw "Failed to check/create table: $_"
    }

    # Step 1: Get all access review definitions for access packages
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Fetching access review definitions from Microsoft Graph..." -ForegroundColor Cyan

    # Filter for access package reviews (scopeType contains accessPackage)
    $definitionsUri = "https://graph.microsoft.com/beta/identityGovernance/accessReviews/definitions?`$filter=contains(scope/microsoft.graph.principalResourceMembershipsScope/principalScopes/microsoft.graph.accessPackageSubject/accessPackageId,'00000000')"

    # Actually, let's just get all definitions and filter for access package ones
    $definitionsUri = "https://graph.microsoft.com/beta/identityGovernance/accessReviews/definitions"

    try {
        $allDefinitions = Invoke-FGGetRequest -URI $definitionsUri
        if (-not $allDefinitions) {
            $allDefinitions = @()
        }
    }
    catch {
        throw "Failed to fetch access review definitions from Graph: $_"
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Found $($allDefinitions.Count) review definitions" -ForegroundColor Green

    if ($allDefinitions.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No access review definitions found."
        return
    }

    # Step 2: For each definition, get instances with decisions
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Fetching review instances and decisions..." -ForegroundColor Cyan

    $allReviewDecisions = @()
    $processedCount = 0
    $graphStartTime = Get-Date

    foreach ($definition in $allDefinitions) {
        $processedCount++

        # Show progress
        if ($processedCount -eq 1 -or $processedCount -eq $allDefinitions.Count -or ($processedCount % 10) -eq 0) {
            $percentComplete = [math]::Round(($processedCount / $allDefinitions.Count) * 100, 1)
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Progress: $processedCount/$($allDefinitions.Count) definitions ($percentComplete%)" -ForegroundColor Gray
        }

        # Extract access package ID from the definition scope
        # Access package reviews have scope with resourceScopes containing the AP query path,
        # or principalScopes with accessPackageSubject containing accessPackageId
        $definitionAccessPackageId = $null
        if ($definition.scope) {
            # Strategy 1: Check resourceScopes for query path containing accessPackages/{id}
            # The GUID may be quoted with single quotes in the query string
            if ($definition.scope.resourceScopes) {
                foreach ($rs in $definition.scope.resourceScopes) {
                    if ($rs.query -match "accessPackage[s]?[/']+'?([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})") {
                        $definitionAccessPackageId = $Matches[1]
                        break
                    }
                }
            }
            # Strategy 2: Check principalScopes for accessPackageId property
            if (-not $definitionAccessPackageId -and $definition.scope.principalScopes) {
                foreach ($ps in $definition.scope.principalScopes) {
                    if ($ps.accessPackageId) {
                        $definitionAccessPackageId = $ps.accessPackageId
                        break
                    }
                }
            }
            # Strategy 3: Serialize entire scope to JSON and search for any access package GUID reference
            if (-not $definitionAccessPackageId) {
                try {
                    $scopeJson = $definition.scope | ConvertTo-Json -Depth 100 -Compress -ErrorAction SilentlyContinue
                    if ($scopeJson -match "accessPackage[^""]*?([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})") {
                        $definitionAccessPackageId = $Matches[1]
                    }
                } catch { }
            }
        }
        # Strategy 4: Serialize entire definition to JSON as last resort
        if (-not $definitionAccessPackageId) {
            try {
                $defJson = $definition | ConvertTo-Json -Depth 100 -Compress -ErrorAction SilentlyContinue
                if ($defJson -match "accessPackage[^""]*?([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})") {
                    $definitionAccessPackageId = $Matches[1]
                }
            } catch { }
        }

        # Log first definition's structure for diagnostics
        if ($processedCount -eq 1) {
            try {
                $debugJson = $definition | ConvertTo-Json -Depth 10 -ErrorAction SilentlyContinue
                Write-Host "  [DEBUG] First definition structure:" -ForegroundColor Yellow
                Write-Host $debugJson -ForegroundColor Gray
                Write-Host "  [DEBUG] Extracted accessPackageId: $definitionAccessPackageId" -ForegroundColor Yellow
            } catch {
                Write-Host "  [DEBUG] Could not serialize definition: $_" -ForegroundColor Yellow
            }
        }

        # Get instances for this definition
        $instancesUri = "https://graph.microsoft.com/beta/identityGovernance/accessReviews/definitions/$($definition.id)/instances"

        try {
            $instances = Invoke-FGGetRequest -URI $instancesUri

            if ($instances -and $instances.Count -gt 0) {
                # For each instance, get decisions
                foreach ($instance in $instances) {
                    # Note: reviewedBy is included by default as userIdentity object, no expansion needed
                    $decisionsUri = "https://graph.microsoft.com/beta/identityGovernance/accessReviews/definitions/$($definition.id)/instances/$($instance.id)/decisions"

                    try {
                        $decisions = Invoke-FGGetRequest -URI $decisionsUri

                        if ($decisions -and $decisions.Count -gt 0) {
                            # Flatten and store decisions
                            foreach ($decision in $decisions) {
                                $flatDecision = [PSCustomObject]@{
                                    id = $decision.id
                                    reviewInstanceId = $instance.id
                                    reviewDefinitionId = $definition.id
                                    accessPackageId = $definitionAccessPackageId
                                    reviewedResourceId = $decision.resource.id
                                    reviewedResourceDisplayName = $decision.resource.displayName
                                    reviewedBy = $decision.reviewedBy.id
                                    reviewedByDisplayName = $decision.reviewedBy.displayName
                                    reviewedDateTime = $decision.reviewedDateTime
                                    decision = $decision.decision
                                    justification = $decision.justification
                                    recommendation = $decision.recommendation
                                    reviewInstanceStartDateTime = $instance.startDateTime
                                    reviewInstanceEndDateTime = $instance.endDateTime
                                    reviewInstanceStatus = $instance.status
                                }
                                $allReviewDecisions += $flatDecision
                            }
                        }
                    }
                    catch {
                        Write-Warning "  [$(Get-Date -Format 'HH:mm:ss')] Failed to get decisions for instance $($instance.id): $_"
                    }
                }
            }
        }
        catch {
            Write-Warning "  [$(Get-Date -Format 'HH:mm:ss')] Failed to get instances for definition '$($definition.displayName)' (ID: $($definition.id)): $_"
        }
    }

    $graphElapsed = (Get-Date) - $graphStartTime
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Total review decisions fetched: $($allReviewDecisions.Count) (took $([math]::Round($graphElapsed.TotalSeconds, 1))s)" -ForegroundColor Green

    if ($allReviewDecisions.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No review decisions found to sync."
        return
    }

    # Sync to SQL using bulk operations
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing review decisions to SQL Server..." -ForegroundColor Cyan

    # Build DataTable for bulk operations
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Preparing data for bulk sync..." -ForegroundColor Gray

    $dataTable = New-FGDataTableFromGraphObjects -GraphObjects $allReviewDecisions -Columns $columns -Attributes $Attributes

    $syncResult = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Database connection established" -ForegroundColor Gray
        $transaction = $connection.BeginTransaction()

        $syncedCount = 0
        $errorCount = 0
        $deletedCount = 0
        $syncStartTime = Get-Date

        try {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($dataTable.Rows.Count) review decisions..." -ForegroundColor Cyan

            $mergeResult = Invoke-FGSQLBulkMerge `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName $TableName `
                -DataTable $dataTable `
                -KeyColumns @('id')

            $syncedCount = $mergeResult.Inserted + $mergeResult.Updated

            $syncElapsed = (Get-Date) - $syncStartTime
            $rate = if ($syncElapsed.TotalSeconds -gt 0) { [math]::Round($syncedCount / $syncElapsed.TotalSeconds, 1) } else { 0 }
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merge completed: $($mergeResult.Inserted) inserted, $($mergeResult.Updated) updated ($rate decisions/sec)" -ForegroundColor Green

            # Handle deletions
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking for deleted decisions..." -ForegroundColor Cyan

            $deletedCount = Invoke-FGSQLBulkDelete `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName $TableName `
                -DataTable $dataTable `
                -KeyColumns @('id')

            if ($deletedCount -gt 0) {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedCount decisions that no longer exist in Graph" -ForegroundColor Yellow
            }
            else {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] No deleted decisions found" -ForegroundColor Green
            }

            $transaction.Commit()

            $totalElapsed = (Get-Date) - $syncStartTime
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Transaction committed successfully (took $([math]::Round($totalElapsed.TotalSeconds, 1))s)" -ForegroundColor Green

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
    Write-Host "Total Decisions:     $($allReviewDecisions.Count)" -ForegroundColor White
    Write-Host "Synced:              $syncedCount" -ForegroundColor White
    Write-Host "Deleted:             $deletedCount" -ForegroundColor White
    Write-Host "Errors:              $errorCount" -ForegroundColor White
    Write-Host "`nAll changes are automatically tracked in ${TableName}_History" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Green

    # Set sync status for logging
    $syncRecordCount = $allReviewDecisions.Count
    $syncStatus = if ($errorCount -gt 0) { "PartialSuccess" } else { "Success" }

    } # End try
    catch {
        $syncErrorMessage = $_.Exception.Message
        $syncStatus = "Failed"
        throw
    }
    finally {
        # Write sync log entry
        Write-FGSyncLog -SyncType "AccessPackageAccessReviews" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName $TableName
    }

    return @{
        TableName = $TableName
        TotalDecisions = $allReviewDecisions.Count
        SyncedCount = $syncedCount
        DeletedCount = $deletedCount
        ErrorCount = $errorCount
    }
}
