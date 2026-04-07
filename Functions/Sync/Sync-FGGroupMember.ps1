function Sync-FGGroupMember {
    <#
    .SYNOPSIS
    Syncs Microsoft Graph group memberships to Azure SQL with temporal versioning.

    .DESCRIPTION
    This function syncs the many-to-many relationship between groups and their members:
    - Creates a table with groupId, memberId, and memberType columns
    - Uses composite primary key (groupId, memberId)
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
    Name of the SQL table to create/sync to. Default: "GraphGroupMembers"

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
        [string]$TableName = "GraphGroupMembers",

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
    $attributes = @('groupId', 'memberId', 'memberType')

    # Map to SQL types
    $graphToSqlTypeMap = @{
        'groupId' = 'UNIQUEIDENTIFIER'
        'memberId' = 'UNIQUEIDENTIFIER'
        'memberType' = 'NVARCHAR(100)'  # e.g., #microsoft.graph.user
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
            Initialize-FGSQLTable -TableName $TableName -Columns $columns -PrimaryKey @('groupId', 'memberId') -DropIfExists:$RecreateTable
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

    # DEBUG: Show initial table state
    try {
        $initialCount = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            $cmd = $connection.CreateCommand()
            $cmd.CommandText = "SELECT COUNT(*) FROM dbo.[$TableName] WHERE ValidTo = '9999-12-31 23:59:59.9999999'"
            $count = $cmd.ExecuteScalar()
            $cmd.Dispose()
            return $count
        }
        Write-Host "[DEBUG] Initial record count in $TableName : $initialCount" -ForegroundColor Magenta
    }
    catch {
        Write-Host "[DEBUG] Could not read initial count (table may not exist yet)" -ForegroundColor Magenta
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
                $dataTable.Columns.Add("groupId", [guid]) | Out-Null
                $dataTable.Columns.Add("memberId", [guid]) | Out-Null
                $dataTable.Columns.Add("memberType", [string]) | Out-Null
                $dataTable.Columns.Add("syncBatchId", [guid]) | Out-Null

                foreach ($member in $members) {
                    $row = $dataTable.NewRow()
                    $row["groupId"] = [guid]$group.id
                    $row["memberId"] = [guid]$member.id
                    $row["memberType"] = if ($member.'@odata.type') { $member.'@odata.type' } else { [DBNull]::Value }
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
                            -KeyColumns @('groupId', 'memberId')

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

        # DEBUG: Show table state before delete
        $preDeleteStats = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)

            $cmd = $connection.CreateCommand()
            $cmd.CommandText = @"
                SELECT
                    COUNT(*) AS totalRecords,
                    SUM(CASE WHEN syncBatchId = @syncBatchId THEN 1 ELSE 0 END) AS currentBatchRecords,
                    SUM(CASE WHEN syncBatchId IS NULL THEN 1 ELSE 0 END) AS nullBatchRecords,
                    SUM(CASE WHEN syncBatchId IS NOT NULL AND syncBatchId <> @syncBatchId THEN 1 ELSE 0 END) AS staleBatchRecords
                FROM dbo.[$TableName]
                WHERE ValidTo = '9999-12-31 23:59:59.9999999'
"@
            $cmd.Parameters.AddWithValue("@syncBatchId", $syncBatchId) | Out-Null
            $reader = $cmd.ExecuteReader()
            $reader.Read()
            $stats = @{
                Total = $reader.GetInt32(0)
                CurrentBatch = $reader.GetInt32(1)
                NullBatch = $reader.GetInt32(2)
                StaleBatch = $reader.GetInt32(3)
            }
            $reader.Close()
            $cmd.Dispose()
            return $stats
        }

        Write-Host "  [DEBUG] Table state BEFORE delete:" -ForegroundColor Magenta
        Write-Host "    Total current records:           $($preDeleteStats.Total)" -ForegroundColor Magenta
        Write-Host "    Records with current syncBatchId: $($preDeleteStats.CurrentBatch)" -ForegroundColor Magenta
        Write-Host "    Records with NULL syncBatchId:    $($preDeleteStats.NullBatch)" -ForegroundColor Magenta
        Write-Host "    Records with stale syncBatchId:   $($preDeleteStats.StaleBatch)" -ForegroundColor Magenta
        Write-Host "    Candidates for deletion:          $($preDeleteStats.NullBatch + $preDeleteStats.StaleBatch)" -ForegroundColor Magenta

        # DEBUG: Show sample records that will be deleted (up to 10)
        if (($preDeleteStats.NullBatch + $preDeleteStats.StaleBatch) -gt 0) {
            $samplesToDelete = Invoke-FGSQLCommand -ScriptBlock {
                param($connection)

                $cmd = $connection.CreateCommand()
                $cmd.CommandText = @"
                    SELECT TOP 10 groupId, memberId, memberType, syncBatchId
                    FROM dbo.[$TableName]
                    WHERE syncBatchId IS NULL OR syncBatchId <> @syncBatchId
"@
                $cmd.Parameters.AddWithValue("@syncBatchId", $syncBatchId) | Out-Null
                $reader = $cmd.ExecuteReader()
                $samples = @()
                while ($reader.Read()) {
                    $samples += "    groupId=$($reader['groupId']), memberId=$($reader['memberId']), syncBatchId=$($reader['syncBatchId'])"
                }
                $reader.Close()
                $cmd.Dispose()
                return $samples
            }
            Write-Host "  [DEBUG] Sample records to be deleted:" -ForegroundColor Magenta
            foreach ($sample in $samplesToDelete) {
                Write-Host $sample -ForegroundColor Magenta
            }
        }

        $deleteResult = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)

            # Delete in batches to avoid timeout on large temporal tables
            # Each DELETE also writes to the history table, so large deletes are expensive
            $batchSize = 50000
            $totalDeleted = 0

            while ($true) {
                $transaction = $connection.BeginTransaction()

                try {
                    $deleteCmd = $connection.CreateCommand()
                    $deleteCmd.Transaction = $transaction
                    $deleteCmd.CommandTimeout = 300
                    $deleteCmd.CommandText = @"
                        DELETE TOP ($batchSize) FROM dbo.[$TableName]
                        WHERE syncBatchId IS NULL OR syncBatchId <> @syncBatchId
"@
                    $deleteCmd.Parameters.AddWithValue("@syncBatchId", $syncBatchId) | Out-Null
                    $batchDeleted = $deleteCmd.ExecuteNonQuery()

                    $transaction.Commit()
                    $transaction.Dispose()

                    $totalDeleted += $batchDeleted
                    if ($batchDeleted -gt 0) {
                        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Deleted batch: $batchDeleted (total so far: $totalDeleted)" -ForegroundColor Gray
                    }

                    # If we deleted less than batchSize, we're done
                    if ($batchDeleted -lt $batchSize) {
                        break
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

            return $totalDeleted
        }

        if ($deleteResult -gt 0) {
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Deleted $deleteResult memberships that no longer exist in Graph" -ForegroundColor Yellow
        }
        else {
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] No deleted memberships found" -ForegroundColor Green
        }

        # DEBUG: Show table state after delete
        $postDeleteCount = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            $cmd = $connection.CreateCommand()
            $cmd.CommandText = "SELECT COUNT(*) FROM dbo.[$TableName] WHERE ValidTo = '9999-12-31 23:59:59.9999999'"
            $count = $cmd.ExecuteScalar()
            $cmd.Dispose()
            return $count
        }
        Write-Host "  [DEBUG] Table state AFTER delete: $postDeleteCount current records" -ForegroundColor Magenta

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
                        groupId = $group.id
                        memberId = $member.id
                        memberType = $member.'@odata.type'
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
        $dataTable.Columns.Add("groupId", [guid]) | Out-Null
        $dataTable.Columns.Add("memberId", [guid]) | Out-Null
        $dataTable.Columns.Add("memberType", [string]) | Out-Null

        foreach ($membership in $allMemberships) {
            $row = $dataTable.NewRow()
            $row["groupId"] = [guid]$membership.groupId
            $row["memberId"] = [guid]$membership.memberId
            $row["memberType"] = if ($membership.memberType) { $membership.memberType } else { [DBNull]::Value }
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
                    -KeyColumns @('groupId', 'memberId')

                $syncedCount = $mergeResult.Inserted + $mergeResult.Updated

                $syncElapsed = (Get-Date) - $syncStartTime
                $rate = if ($syncElapsed.TotalSeconds -gt 0) { [math]::Round($syncedCount / $syncElapsed.TotalSeconds, 1) } else { 0 }
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merge completed: $($mergeResult.Inserted) inserted, $($mergeResult.Updated) updated ($rate memberships/sec)" -ForegroundColor Green

                # Handle deletions using bulk delete (avoids massive VALUES clause)
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking for deleted memberships..." -ForegroundColor Cyan

                # DEBUG: Show pre-delete state
                $preDeleteCmd = $connection.CreateCommand()
                $preDeleteCmd.Transaction = $transaction
                $preDeleteCmd.CommandText = "SELECT COUNT(*) FROM dbo.$TableName"
                $preDeleteTotal = $preDeleteCmd.ExecuteScalar()
                $preDeleteCmd.Dispose()
                Write-Host "  [DEBUG] Records in table before delete: $preDeleteTotal" -ForegroundColor Magenta
                Write-Host "  [DEBUG] Records in current Graph data:  $($dataTable.Rows.Count)" -ForegroundColor Magenta
                Write-Host "  [DEBUG] Expected deletions:             $($preDeleteTotal - $dataTable.Rows.Count)" -ForegroundColor Magenta

                $deletedCount = Invoke-FGSQLBulkDelete `
                    -Connection $connection `
                    -Transaction $transaction `
                    -TargetTableName $TableName `
                    -DataTable $dataTable `
                    -KeyColumns @('groupId', 'memberId')

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
        Write-FGSyncLog -SyncType "GroupMembers" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName $TableName
    }
}
