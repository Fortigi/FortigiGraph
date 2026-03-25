function Sync-FGGroupMember {
    <#
    .SYNOPSIS
    Syncs Microsoft Graph group memberships to Azure SQL with temporal versioning.

    .DESCRIPTION
    This function syncs the many-to-many relationship between groups and their members
    to the universal ResourceAssignments table:
    - Creates a table with resourceId, principalId, principalType, and assignmentType columns
    - Uses composite primary key (resourceId, principalId, assignmentType)
    - assignmentType is set to 'Direct' for all rows
    - Automatically creates temporal table for change tracking
    - Iterates through all groups and fetches members for each
    - Handles all member types (users, groups, devices, service principals)
    - Does NOT sync member details - only the membership relationships

    IMPORTANT: This function must iterate through each group individually to get all members.
    Querying all groups and members in one call has limitations.

    .PARAMETER Filter
    Optional OData filter to limit which groups to process (e.g., "securityEnabled eq true")

    .PARAMETER GroupIds
    Optional array of specific group IDs to sync. If not specified, syncs all groups.

    .PARAMETER TableName
    Name of the SQL table to create/sync to. Default: "ResourceAssignments"

    .PARAMETER RecreateTable
    If specified, drops and recreates the table (WARNING: loses all history!)

    .PARAMETER IncludeTransitiveMembers
    If specified, includes transitive (nested) members. Default: false (direct members only)

    .PARAMETER UseBatching
    If specified, syncs each group's members to SQL immediately instead of collecting all in memory first.
    This uses much less memory (constant vs linear) at the cost of more SQL operations.
    Recommended for Azure Automation or other memory-constrained environments.

    .EXAMPLE
    Sync-FGGroupMember

    Syncs all group memberships for all groups (fast, high memory usage)

    .EXAMPLE
    Sync-FGGroupMember -UseBatching

    Syncs all group memberships using batched mode (slower, low memory usage)

    .EXAMPLE
    Sync-FGGroupMember -Filter "securityEnabled eq true"

    Syncs memberships only for security groups

    .EXAMPLE
    Sync-FGGroupMember -GroupIds @('group-id-1', 'group-id-2')

    Syncs memberships only for specific groups

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Valid Graph access token (Get-FGAccessToken)
    - This can be a long-running operation for tenants with many groups
    #>

    [CmdletBinding()]
    [Alias("Sync-GroupMember")]
    Param(
        [Parameter(Mandatory = $false)]
        [string]$Filter,

        [Parameter(Mandatory = $false)]
        [string[]]$GroupIds,

        [Parameter(Mandatory = $false)]
        [string]$TableName = "ResourceAssignments",

        [Parameter(Mandatory = $false)]
        [switch]$RecreateTable,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeTransitiveMembers,

        [Parameter(Mandatory = $false)]
        [switch]$UseBatching
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
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Starting group membership sync ($syncMode)..." -ForegroundColor Cyan

    # Define attributes for the membership table
    $attributes = @('resourceId', 'principalId', 'principalType', 'assignmentType')

    # Map to SQL types
    $graphToSqlTypeMap = @{
        'resourceId' = 'UNIQUEIDENTIFIER'
        'principalId' = 'UNIQUEIDENTIFIER'
        'principalType' = 'NVARCHAR(100)'  # e.g., #microsoft.graph.user
        'assignmentType' = 'NVARCHAR(50)'   # 'Direct'
    }

    # Add syncBatchId for batching mode to track which records were seen
    if ($UseBatching) {
        $attributes += 'syncBatchId'
        $graphToSqlTypeMap['syncBatchId'] = 'UNIQUEIDENTIFIER'
    }

    # Build column definitions
    $columns = @{}
    foreach ($attr in $attributes) {
        $columns[$attr] = $graphToSqlTypeMap[$attr]
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

        # Create table if needed (with composite primary key)
        $tableStillExists = Test-FGSQLTableExists -TableName $TableName

        if (-not $tableStillExists -or $RecreateTable) {
            Initialize-FGSQLTable -TableName $TableName -Columns $columns -PrimaryKey @('resourceId', 'principalId', 'assignmentType') -DropIfExists:$RecreateTable
        }
    }
    catch {
        throw "Failed to check/create table: $_"
    }

    # Fetch groups to process
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Fetching groups from Microsoft Graph..." -ForegroundColor Cyan

    $graphUri = 'https://graph.microsoft.com/v1.0'

    if ($GroupIds) {
        # Use specific group IDs
        $groups = @()
        foreach ($groupId in $GroupIds) {
            try {
                $uri = "$graphUri/groups/$groupId`?`$select=id,displayName"
                $group = Invoke-FGGetRequest -URI $uri
                $groups += $group
            }
            catch {
                Write-Warning "Failed to fetch group $groupId : $_"
            }
        }
    }
    else {
        # Fetch all groups (or filtered) using Invoke-FGGetRequest (handles token validation and pagination)
        $uri = "$graphUri/groups?`$select=id,displayName"
        if ($Filter) {
            $uri += "&`$filter=$Filter"
        }

        try {
            $groups = Invoke-FGGetRequest -URI $uri
            if (-not $groups) {
                $groups = @()
            }
        }
        catch {
            throw "Failed to fetch groups from Graph: $_"
        }
    }

    $totalGroups = $groups.Count
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Total groups to process: $totalGroups" -ForegroundColor Green

    if ($totalGroups -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No groups found to process."
        return
    }

    # Different sync strategies based on batching mode
    if ($UseBatching) {
        # ============================================
        # BATCHED MODE: Low memory, process per group
        # ============================================
        Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Using batched sync mode (low memory)..." -ForegroundColor Cyan
        Write-Host "  Each group's members will be synced to SQL immediately" -ForegroundColor Gray

        # Generate a unique batch ID for this sync run
        $syncBatchId = [guid]::NewGuid()
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Sync batch ID: $syncBatchId" -ForegroundColor Gray

        $processedGroups = 0
        $totalMemberships = 0
        $totalInserted = 0
        $totalUpdated = 0
        $errorCount = 0
        $membershipStartTime = Get-Date

        foreach ($group in $groups) {
            $processedGroups++
            $percentComplete = [math]::Round(($processedGroups / $totalGroups) * 100, 1)

            Write-Progress -Activity "Syncing Group Memberships (Batched)" `
                -Status "Group $processedGroups of $totalGroups ($percentComplete%) - $totalMemberships members synced" `
                -PercentComplete $percentComplete

            # Choose members or transitiveMembers endpoint
            if ($IncludeTransitiveMembers) {
                $memberUri = "$graphUri/groups/$($group.id)/transitiveMembers?`$select=id"
            }
            else {
                $memberUri = "$graphUri/groups/$($group.id)/members?`$select=id"
            }

            try {
                # Fetch members for this group
                $members = Invoke-FGGetRequest -URI $memberUri
                if (-not $members) {
                    $members = @()
                }

                if ($members.Count -eq 0) {
                    continue
                }

                # Build small DataTable for this group's members
                $dataTable = New-Object System.Data.DataTable
                $dataTable.Columns.Add("resourceId", [guid]) | Out-Null
                $dataTable.Columns.Add("principalId", [guid]) | Out-Null
                $dataTable.Columns.Add("principalType", [string]) | Out-Null
                $dataTable.Columns.Add("assignmentType", [string]) | Out-Null
                $dataTable.Columns.Add("syncBatchId", [guid]) | Out-Null

                foreach ($member in $members) {
                    $row = $dataTable.NewRow()
                    $row["resourceId"] = [guid]$group.id
                    $row["principalId"] = [guid]$member.id
                    $row["principalType"] = if ($member.'@odata.type') { $member.'@odata.type' } else { [DBNull]::Value }
                    $row["assignmentType"] = 'Direct'
                    $row["syncBatchId"] = $syncBatchId
                    $dataTable.Rows.Add($row)
                }

                $totalMemberships += $dataTable.Rows.Count

                # Sync this batch to SQL immediately
                $batchResult = Invoke-FGSQLCommand -ScriptBlock {
                    param($connection)

                    $transaction = $connection.BeginTransaction()

                    try {
                        # MERGE this group's members (updates syncBatchId for existing, inserts new)
                        $mergeResult = Invoke-FGSQLBulkMerge `
                            -Connection $connection `
                            -Transaction $transaction `
                            -TargetTableName $TableName `
                            -DataTable $dataTable `
                            -KeyColumns @('resourceId', 'principalId', 'assignmentType')

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

                # Clear the DataTable to free memory
                $dataTable.Clear()
                $dataTable.Dispose()
                $dataTable = $null
            }
            catch {
                $errorCount++
                Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] Failed to fetch members for group '$($group.displayName)' ($($group.id)): $_"
            }
        }

        Write-Progress -Activity "Syncing Group Memberships (Batched)" -Completed

        $membershipElapsed = (Get-Date) - $membershipStartTime
        $rate = if ($membershipElapsed.TotalSeconds -gt 0) { [math]::Round($totalMemberships / $membershipElapsed.TotalSeconds, 1) } else { 0 }
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Batch sync completed: $totalInserted inserted, $totalUpdated updated ($rate memberships/sec)" -ForegroundColor Green

        # Now delete records that weren't seen in this sync (stale memberships)
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking for deleted memberships..." -ForegroundColor Cyan

        $deleteResult = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)

            $transaction = $connection.BeginTransaction()

            try {
                # Delete records where syncBatchId doesn't match current batch (or is NULL for old records)
                $deleteCmd = $connection.CreateCommand()
                $deleteCmd.Transaction = $transaction
                $deleteCmd.CommandText = @"
                    DELETE FROM dbo.[$TableName]
                    WHERE syncBatchId IS NULL OR syncBatchId <> @syncBatchId
"@
                $deleteCmd.Parameters.AddWithValue("@syncBatchId", $syncBatchId) | Out-Null
                $deletedCount = $deleteCmd.ExecuteNonQuery()

                $transaction.Commit()
                $transaction.Dispose()

                return $deletedCount
            }
            catch {
                if ($transaction) {
                    $transaction.Rollback()
                    $transaction.Dispose()
                }
                throw
            }
        }

        if ($deleteResult -gt 0) {
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Deleted $deleteResult memberships that no longer exist in Graph" -ForegroundColor Yellow
        }
        else {
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] No deleted memberships found" -ForegroundColor Green
        }

        $syncedCount = $totalInserted + $totalUpdated
        $deletedCount = $deleteResult

        Write-Host "`n========================================" -ForegroundColor Green
        Write-Host "Sync Complete! (Batched Mode)" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "Table:           $TableName" -ForegroundColor White
        Write-Host "Groups:          $totalGroups" -ForegroundColor White
        Write-Host "Memberships:     $totalMemberships" -ForegroundColor White
        Write-Host "Inserted:        $totalInserted" -ForegroundColor White
        Write-Host "Updated:         $totalUpdated" -ForegroundColor White
        Write-Host "Deleted:         $deletedCount" -ForegroundColor White
        Write-Host "Errors:          $errorCount" -ForegroundColor White
        Write-Host "`nAll changes are automatically tracked in ${TableName}_History" -ForegroundColor Cyan
        Write-Host "========================================`n" -ForegroundColor Green

        # Set sync status for logging (batched mode)
        $syncRecordCount = $totalMemberships
        $syncStatus = if ($errorCount -gt 0) { "PartialSuccess" } else { "Success" }

        return @{
            TableName = $TableName
            TotalGroups = $totalGroups
            TotalMemberships = $totalMemberships
            SyncedCount = $syncedCount
            InsertedCount = $totalInserted
            UpdatedCount = $totalUpdated
            DeletedCount = $deletedCount
            ErrorCount = $errorCount
            Mode = "Batched"
        }
    }
    else {
        # ============================================
        # BULK MODE: High performance, high memory
        # ============================================

        # Fetch all group memberships (iterating through each group)
        Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Fetching group memberships..." -ForegroundColor Cyan
        Write-Host "  This may take a while for tenants with many groups and members..." -ForegroundColor Gray

        $allMemberships = @()
        $processedGroups = 0
        $membershipStartTime = Get-Date

        foreach ($group in $groups) {
            $processedGroups++
            $percentComplete = [math]::Round(($processedGroups / $totalGroups) * 100, 1)

            Write-Progress -Activity "Fetching Group Memberships" -Status "Processing group $processedGroups of $totalGroups ($percentComplete%)" -PercentComplete $percentComplete

            # Choose members or transitiveMembers endpoint
            if ($IncludeTransitiveMembers) {
                $memberUri = "$graphUri/groups/$($group.id)/transitiveMembers?`$select=id"
            }
            else {
                $memberUri = "$graphUri/groups/$($group.id)/members?`$select=id"
            }

            try {
                # Fetch all members for this group using Invoke-FGGetRequest (handles token validation and pagination)
                $members = Invoke-FGGetRequest -URI $memberUri
                if (-not $members) {
                    $members = @()
                }

                # Create membership records
                foreach ($member in $members) {
                    $membership = [PSCustomObject]@{
                        resourceId = $group.id
                        principalId = $member.id
                        principalType = $member.'@odata.type'
                        assignmentType = 'Direct'
                    }
                    $allMemberships += $membership
                }
            }
            catch {
                Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] Failed to fetch members for group '$($group.displayName)' ($($group.id)): $_"
            }
        }

        Write-Progress -Activity "Fetching Group Memberships" -Completed

        $membershipElapsed = (Get-Date) - $membershipStartTime
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Total memberships fetched: $($allMemberships.Count) from $totalGroups groups (took $([math]::Round($membershipElapsed.TotalSeconds, 1))s)" -ForegroundColor Green

        if ($allMemberships.Count -eq 0) {
            Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No memberships found to sync."
            return
        }

        # Sync to SQL using bulk operations (HIGH PERFORMANCE)
        Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing memberships to SQL Server..." -ForegroundColor Cyan

        # Build DataTable for bulk operations
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Preparing data for bulk sync..." -ForegroundColor Gray

        $dataTable = New-Object System.Data.DataTable
        $dataTable.Columns.Add("resourceId", [guid]) | Out-Null
        $dataTable.Columns.Add("principalId", [guid]) | Out-Null
        $dataTable.Columns.Add("principalType", [string]) | Out-Null
        $dataTable.Columns.Add("assignmentType", [string]) | Out-Null

        foreach ($membership in $allMemberships) {
            $row = $dataTable.NewRow()
            $row["resourceId"] = [guid]$membership.resourceId
            $row["principalId"] = [guid]$membership.principalId
            $row["principalType"] = if ($membership.principalType) { $membership.principalType } else { [DBNull]::Value }
            $row["assignmentType"] = $membership.assignmentType
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
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($dataTable.Rows.Count) memberships..." -ForegroundColor Cyan

                # Use bulk MERGE operation - much faster than row-by-row
                $mergeResult = Invoke-FGSQLBulkMerge `
                    -Connection $connection `
                    -Transaction $transaction `
                    -TargetTableName $TableName `
                    -DataTable $dataTable `
                    -KeyColumns @('resourceId', 'principalId', 'assignmentType')

                $syncedCount = $mergeResult.Inserted + $mergeResult.Updated

                $syncElapsed = (Get-Date) - $syncStartTime
                $rate = if ($syncElapsed.TotalSeconds -gt 0) { [math]::Round($syncedCount / $syncElapsed.TotalSeconds, 1) } else { 0 }
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merge completed: $($mergeResult.Inserted) inserted, $($mergeResult.Updated) updated ($rate memberships/sec)" -ForegroundColor Green

                # Handle deletions using bulk delete (avoids massive VALUES clause)
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking for deleted memberships..." -ForegroundColor Cyan

                $deletedCount = Invoke-FGSQLBulkDelete `
                    -Connection $connection `
                    -Transaction $transaction `
                    -TargetTableName $TableName `
                    -DataTable $dataTable `
                    -KeyColumns @('resourceId', 'principalId', 'assignmentType')

                if ($deletedCount -gt 0) {
                    Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedCount memberships that no longer exist in Graph" -ForegroundColor Yellow
                }
                else {
                    Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] No deleted memberships found" -ForegroundColor Green
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
        Write-Host "Table:           $TableName" -ForegroundColor White
        Write-Host "Groups:          $totalGroups" -ForegroundColor White
        Write-Host "Memberships:     $($allMemberships.Count)" -ForegroundColor White
        Write-Host "Synced:          $syncedCount" -ForegroundColor White
        Write-Host "Deleted:         $deletedCount" -ForegroundColor White
        Write-Host "Errors:          $errorCount" -ForegroundColor White
        Write-Host "`nAll changes are automatically tracked in ${TableName}_History" -ForegroundColor Cyan
        Write-Host "========================================`n" -ForegroundColor Green

        # Set sync status for logging
        $syncRecordCount = $allMemberships.Count
        $syncStatus = if ($errorCount -gt 0) { "PartialSuccess" } else { "Success" }

        return @{
            TableName = $TableName
            TotalGroups = $totalGroups
            TotalMemberships = $allMemberships.Count
            SyncedCount = $syncedCount
            DeletedCount = $deletedCount
            ErrorCount = $errorCount
            Mode = "Bulk"
        }
    }

    } # End try
    catch {
        $syncErrorMessage = $_.Exception.Message
        $syncStatus = "Failed"
        throw
    }
    finally {
        # Write sync log entry
        Write-FGSyncLog -SyncType "GroupMembers (Direct)" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName $TableName
    }
}
