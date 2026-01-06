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

    .EXAMPLE
    Sync-FGGroupMember

    Syncs all group memberships for all groups

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
        [switch]$IncludeTransitiveMembers
    )

    # Check SQL connection
    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    # Check Graph access token
    if (-not $global:AccessToken) {
        throw "No Graph access token found. Please run Get-FGAccessToken first."
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Starting group membership sync..." -ForegroundColor Cyan

    # Define attributes for the membership table
    $attributes = @('groupId', 'memberId', 'memberType')

    # Map to SQL types
    $graphToSqlTypeMap = @{
        'groupId' = 'UNIQUEIDENTIFIER'
        'memberId' = 'UNIQUEIDENTIFIER'
        'memberType' = 'NVARCHAR(100)'  # e.g., #microsoft.graph.user
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

            # Show progress every 10 groups
            if ($processedGroups % 10 -eq 0) {
                $elapsed = (Get-Date) - $membershipStartTime
                $rate = [math]::Round($processedGroups / $elapsed.TotalSeconds, 1)
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Progress: $processedGroups/$totalGroups groups, $($allMemberships.Count) memberships ($rate groups/sec)" -ForegroundColor Gray
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

    # Sync to SQL
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing memberships to SQL Server..." -ForegroundColor Cyan

    # Build MERGE statement with composite key
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Preparing MERGE statement..." -ForegroundColor Gray
    $mergeSQL = New-FGSQLMergeStatement -TableName $TableName -Attributes $attributes -TypeMap $graphToSqlTypeMap -PrimaryKey @('groupId', 'memberId')

    $syncResult = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Database connection established" -ForegroundColor Gray

        # Start transaction
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Starting transaction..." -ForegroundColor Gray
        $transaction = $connection.BeginTransaction()

        $syncedCount = 0
        $errorCount = 0
        $syncStartTime = Get-Date

        try {
            # Create command and reuse it
            $cmd = $connection.CreateCommand()
            $cmd.Transaction = $transaction
            $cmd.CommandText = $mergeSQL

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Inserting/updating $($allMemberships.Count) memberships..." -ForegroundColor Cyan

            foreach ($membership in $allMemberships) {
                try {
                    $cmd.Parameters.Clear()

                    # Add parameters using helper
                    ConvertTo-FGSQLParameter -Value $membership.groupId -AttributeName 'groupId' -SqlCommand $cmd
                    ConvertTo-FGSQLParameter -Value $membership.memberId -AttributeName 'memberId' -SqlCommand $cmd

                    # memberType might be null for some member types
                    if ($membership.memberType) {
                        $cmd.Parameters.AddWithValue("@memberType", $membership.memberType) | Out-Null
                    }
                    else {
                        $cmd.Parameters.AddWithValue("@memberType", [DBNull]::Value) | Out-Null
                    }

                    $cmd.ExecuteNonQuery() | Out-Null
                    $syncedCount++

                    if ($syncedCount % 1000 -eq 0) {
                        $elapsed = (Get-Date) - $syncStartTime
                        $rate = [math]::Round($syncedCount / $elapsed.TotalSeconds, 1)
                        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Progress: $syncedCount/$($allMemberships.Count) memberships ($rate memberships/sec)" -ForegroundColor Gray
                    }
                }
                catch {
                    Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] Failed to sync membership (groupId: $($membership.groupId), memberId: $($membership.memberId)): $_"
                    $errorCount++
                }
            }

            # Commit transaction
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Committing transaction..." -ForegroundColor Cyan
            $transaction.Commit()
            $syncElapsed = (Get-Date) - $syncStartTime
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Transaction committed successfully (took $([math]::Round($syncElapsed.TotalSeconds, 1))s)" -ForegroundColor Green

            # Handle deletions - remove memberships that no longer exist in Graph
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking for deleted memberships..." -ForegroundColor Cyan

            # Build list of current memberships
            $membershipPairs = ($allMemberships | ForEach-Object { "('$($_.groupId)', '$($_.memberId)')" }) -join ','

            $deleteSQL = @"
DELETE FROM dbo.$TableName
WHERE NOT EXISTS (
    SELECT 1 FROM (VALUES $membershipPairs) AS CurrentMembers(groupId, memberId)
    WHERE dbo.$TableName.groupId = CurrentMembers.groupId
    AND dbo.$TableName.memberId = CurrentMembers.memberId
)
"@

            $deletedCount = 0
            try {
                $deleteCmd = $connection.CreateCommand()
                $deleteCmd.CommandText = $deleteSQL
                $deletedCount = $deleteCmd.ExecuteNonQuery()

                if ($deletedCount -gt 0) {
                    Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedCount memberships that no longer exist in Graph" -ForegroundColor Yellow
                }
                else {
                    Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] No deleted memberships found" -ForegroundColor Green
                }
            }
            catch {
                Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] Failed to delete removed memberships: $_"
            }

            # Cleanup
            $cmd.Dispose()
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
            if ($cmd) {
                $cmd.Dispose()
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
    Write-Host "`nAll changes are automatically tracked in ${TableName}History" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Green

    return @{
        TableName = $TableName
        TotalGroups = $totalGroups
        TotalMemberships = $allMemberships.Count
        SyncedCount = $syncedCount
        DeletedCount = $deletedCount
        ErrorCount = $errorCount
    }
}
