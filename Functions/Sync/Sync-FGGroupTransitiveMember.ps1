function Sync-FGGroupTransitiveMember {
    <#
    .SYNOPSIS
    Syncs Microsoft Graph group transitive memberships to Azure SQL with temporal versioning.

    .DESCRIPTION
    This function syncs the many-to-many relationship between groups and their TRANSITIVE members:
    - Transitive members include all nested group memberships (members of members)
    - Creates a table with groupId, memberId, and memberType columns
    - Uses composite primary key (groupId, memberId)
    - Automatically creates temporal table for change tracking
    - Iterates through all groups and fetches transitive members for each
    - Handles all member types (users, groups, devices, service principals)
    - Does NOT sync member details - only the membership relationships

    Use this to track ALL users who have access through nested groups.
    For direct members only, use Sync-FGGroupMember instead.

    IMPORTANT: This function must iterate through each group individually to get all members.
    Querying all groups and members in one call has limitations.

    .PARAMETER Filter
    Optional OData filter to limit which groups to process (e.g., "securityEnabled eq true")

    .PARAMETER GroupIds
    Optional array of specific group IDs to sync. If not specified, syncs all groups.

    .PARAMETER TableName
    Name of the SQL table to create/sync to. Default: "GraphGroupTransitiveMembers"

    .PARAMETER RecreateTable
    If specified, drops and recreates the table (WARNING: loses all history!)

    .EXAMPLE
    Sync-FGGroupTransitiveMember

    Syncs all transitive group memberships for all groups

    .EXAMPLE
    Sync-FGGroupTransitiveMember -Filter "securityEnabled eq true"

    Syncs transitive memberships only for security groups

    .EXAMPLE
    Sync-FGGroupTransitiveMember -GroupIds @('group-id-1', 'group-id-2')

    Syncs transitive memberships only for specific groups

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Valid Graph access token (Get-FGAccessToken)
    - This can be a long-running operation for tenants with many groups and nested structures
    #>

    [CmdletBinding()]
    [Alias("Sync-GroupTransitiveMember")]
    Param(
        [Parameter(Mandatory = $false)]
        [string]$Filter,

        [Parameter(Mandatory = $false)]
        [string[]]$GroupIds,

        [Parameter(Mandatory = $false)]
        [string]$TableName = "GraphGroupTransitiveMembers",

        [Parameter(Mandatory = $false)]
        [switch]$RecreateTable
    )

    # Check SQL connection
    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    # Check Graph access token
    if (-not $global:AccessToken) {
        throw "No Graph access token found. Please run Get-FGAccessToken first."
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Starting transitive group membership sync..." -ForegroundColor Cyan

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

    # Fetch all transitive group memberships (iterating through each group)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Fetching transitive group memberships..." -ForegroundColor Cyan
    Write-Host "  This may take a while for tenants with many groups and nested structures..." -ForegroundColor Gray

    $allMemberships = @()
    $processedGroups = 0
    $membershipStartTime = Get-Date

    foreach ($group in $groups) {
        $processedGroups++
        $percentComplete = [math]::Round(($processedGroups / $totalGroups) * 100, 1)

        Write-Progress -Activity "Fetching Transitive Group Memberships" -Status "Processing group $processedGroups of $totalGroups ($percentComplete%)" -PercentComplete $percentComplete

        # Use transitiveMembers endpoint
        $memberUri = "$graphUri/groups/$($group.id)/transitiveMembers?`$select=id"

        try {
            # Fetch all transitive members for this group using Invoke-FGGetRequest (handles token validation and pagination)
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
            Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] Failed to fetch transitive members for group '$($group.displayName)' ($($group.id)): $_"
        }
    }

    Write-Progress -Activity "Fetching Transitive Group Memberships" -Completed

    $membershipElapsed = (Get-Date) - $membershipStartTime
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Total transitive memberships fetched: $($allMemberships.Count) from $totalGroups groups (took $([math]::Round($membershipElapsed.TotalSeconds, 1))s)" -ForegroundColor Green

    if ($allMemberships.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No memberships found to sync."
        return
    }

    # Sync to SQL using bulk operations (HIGH PERFORMANCE)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing transitive memberships to SQL Server..." -ForegroundColor Cyan

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
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($dataTable.Rows.Count) transitive memberships..." -ForegroundColor Cyan

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
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking for deleted transitive memberships..." -ForegroundColor Cyan

            $deletedCount = Invoke-FGSQLBulkDelete `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName $TableName `
                -DataTable $dataTable `
                -KeyColumns @('groupId', 'memberId')

            if ($deletedCount -gt 0) {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedCount transitive memberships that no longer exist in Graph" -ForegroundColor Yellow
            }
            else {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] No deleted transitive memberships found" -ForegroundColor Green
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
    Write-Host "Table:                      $TableName" -ForegroundColor White
    Write-Host "Groups:                     $totalGroups" -ForegroundColor White
    Write-Host "Transitive Memberships:     $($allMemberships.Count)" -ForegroundColor White
    Write-Host "Synced:                     $syncedCount" -ForegroundColor White
    Write-Host "Deleted:                    $deletedCount" -ForegroundColor White
    Write-Host "Errors:                     $errorCount" -ForegroundColor White
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
