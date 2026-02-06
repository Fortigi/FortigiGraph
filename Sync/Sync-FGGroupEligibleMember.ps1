function Sync-FGGroupEligibleMember {
    <#
    .SYNOPSIS
    Syncs Microsoft Graph group eligible memberships (PIM) to Azure SQL with temporal versioning.

    .DESCRIPTION
    This function syncs eligible group memberships from Privileged Identity Management (PIM):
    - Queries eligibility schedules directly to identify actual PIM-enabled groups
    - Note: Since January 2023, PIM-enabled and role-assignable are INDEPENDENT properties
    - Any group (except dynamic/on-prem synced) can be PIM-enabled, not just role-assignable
    - Creates a table with groupId, memberId, and memberType columns
    - Uses composite primary key (groupId, memberId)
    - Automatically creates temporal table for change tracking
    - Tracks PIM eligibility changes over time

    Use this to track who has ELIGIBLE access (can activate membership) vs active membership.
    For active members, use Sync-FGGroupMember or Sync-FGGroupTransitiveMember.

    Reference: https://learn.microsoft.com/en-us/entra/id-governance/privileged-identity-management/concept-pim-for-groups

    .PARAMETER GroupIds
    Optional array of specific group IDs to sync. If not specified, syncs all PIM groups.

    .PARAMETER TableName
    Name of the SQL table to create/sync to. Default: "GraphGroupEligibleMembers"

    .PARAMETER RecreateTable
    If specified, drops and recreates the table (WARNING: loses all history!)

    .EXAMPLE
    Sync-FGGroupEligibleMember

    Syncs all eligible group memberships for all PIM-enabled groups

    .EXAMPLE
    Sync-FGGroupEligibleMember -GroupIds @('group-id-1', 'group-id-2')

    Syncs eligible memberships only for specific groups

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Valid Graph access token (Get-FGAccessToken) with PrivilegedEligibilitySchedule.Read.AzureADGroup permission
    - Works with any PIM-enabled group (isAssignableToRole is not required since January 2023)
    #>

    [CmdletBinding()]
    [Alias("Sync-GroupEligibleMember")]
    Param(
        [Parameter(Mandatory = $false)]
        [string[]]$GroupIds,

        [Parameter(Mandatory = $false)]
        [string]$TableName = "GraphGroupEligibleMembers",

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

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Starting eligible group membership sync (PIM)..." -ForegroundColor Cyan

    # Define attributes for the membership table
    $attributes = @('groupId', 'memberId', 'memberType')

    # Map to SQL types
    $graphToSqlTypeMap = @{
        'groupId' = 'UNIQUEIDENTIFIER'
        'memberId' = 'UNIQUEIDENTIFIER'
        'memberType' = 'NVARCHAR(100)'
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

    # Fetch PIM-enabled groups by querying all groups and checking each for eligibility schedules
    # Note: Graph API requires $filter parameter for eligibilitySchedules endpoint - cannot query all at once
    # isAssignableToRole and PIM-enabled are INDEPENDENT properties (since January 2023)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Fetching groups to check for PIM eligibility..." -ForegroundColor Cyan

    $graphUri = 'https://graph.microsoft.com/beta'
    $membershipStartTime = Get-Date

    try {
        # Determine which groups to check
        if ($GroupIds) {
            # Use specific group IDs provided by user
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking $($GroupIds.Count) specified groups..." -ForegroundColor Gray
            $groupsToCheck = @()
            foreach ($groupId in $GroupIds) {
                try {
                    $uri = "$graphUri/groups/$groupId`?`$select=id,displayName,groupTypes"
                    $group = Invoke-FGGetRequest -URI $uri
                    $groupsToCheck += $group
                }
                catch {
                    Write-Warning "Failed to fetch group $groupId : $_"
                }
            }
        }
        else {
            # Fetch ALL groups - don't pre-filter by isAssignableToRole since PIM-enabled is independent
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Fetching all groups from Microsoft Graph..." -ForegroundColor Gray
            $uri = "$graphUri/groups?`$select=id,displayName,groupTypes"
            $allGroups = Invoke-FGGetRequest -URI $uri
            if (-not $allGroups) {
                $allGroups = @()
            }

            # Filter out groups that CANNOT be PIM-enabled (dynamic membership)
            $groupsToCheck = $allGroups | Where-Object { $_.groupTypes -notcontains "DynamicMembership" }
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Found $($groupsToCheck.Count) candidate groups (excluded dynamic groups)" -ForegroundColor Gray
        }

        if ($groupsToCheck.Count -eq 0) {
            Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No groups found to check for PIM eligibility."
            return
        }

        # Query each group for eligibility schedules (API requires groupId filter)
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking groups for PIM eligibility schedules..." -ForegroundColor Cyan
        $allEligibleMembers = @()
        $processedGroups = 0
        $pimGroupCount = 0
        $totalGroupsToCheck = $groupsToCheck.Count

        foreach ($group in $groupsToCheck) {
            $processedGroups++
            $percentComplete = [math]::Round(($processedGroups / $totalGroupsToCheck) * 100, 1)

            Write-Progress -Activity "Fetching Eligible Group Memberships" -Status "Checking group $processedGroups of $totalGroupsToCheck ($percentComplete%)" -PercentComplete $percentComplete

            # Query eligibility schedules for this specific group (API requires groupId filter)
            $eligibilityUri = "$graphUri/identityGovernance/privilegedAccess/group/eligibilitySchedules?`$filter=groupId eq '$($group.id)'"

            try {
                $eligibilities = Invoke-FGGetRequest -URI $eligibilityUri
                if (-not $eligibilities) {
                    $eligibilities = @()
                }

                # Only process if group has eligible members
                if ($eligibilities.Count -gt 0) {
                    $pimGroupCount++

                    # For each eligibility, get principal details to determine memberType
                    foreach ($eligibility in $eligibilities) {
                        try {
                            # Get principal details to determine memberType
                            $principalUri = "$graphUri/directoryObjects/$($eligibility.principalId)?`$select=id"
                            $principal = Invoke-FGGetRequest -URI $principalUri

                            $membership = [PSCustomObject]@{
                                groupId = $eligibility.groupId
                                memberId = $eligibility.principalId
                                memberType = $principal.'@odata.type'
                            }
                            $allEligibleMembers += $membership
                        }
                        catch {
                            # If we can't get principal details, add without type
                            $membership = [PSCustomObject]@{
                                groupId = $eligibility.groupId
                                memberId = $eligibility.principalId
                                memberType = $null
                            }
                            $allEligibleMembers += $membership
                        }
                    }
                }
            }
            catch {
                # Group has no PIM eligibilities or error occurred - skip it
                # This is expected for non-PIM groups
            }
        }

        Write-Progress -Activity "Fetching Eligible Group Memberships" -Completed

        $membershipElapsed = (Get-Date) - $membershipStartTime
        $totalGroups = $pimGroupCount
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Total eligible memberships fetched: $($allEligibleMembers.Count) from $totalGroups PIM-enabled groups (checked $processedGroups groups in $([math]::Round($membershipElapsed.TotalSeconds, 1))s)" -ForegroundColor Green
    }
    catch {
        throw "Failed to fetch eligible memberships: $_"
    }

    if ($allEligibleMembers.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No eligible memberships found to sync."
        return
    }

    # Sync to SQL using bulk operations (HIGH PERFORMANCE)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing eligible memberships to SQL Server..." -ForegroundColor Cyan

    # Build DataTable for bulk operations
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Preparing data for bulk sync..." -ForegroundColor Gray

    $dataTable = New-Object System.Data.DataTable
    $dataTable.Columns.Add("groupId", [guid]) | Out-Null
    $dataTable.Columns.Add("memberId", [guid]) | Out-Null
    $dataTable.Columns.Add("memberType", [string]) | Out-Null

    foreach ($membership in $allEligibleMembers) {
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
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($dataTable.Rows.Count) eligible memberships..." -ForegroundColor Cyan

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
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking for removed eligible memberships..." -ForegroundColor Cyan

            $deletedCount = Invoke-FGSQLBulkDelete `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName $TableName `
                -DataTable $dataTable `
                -KeyColumns @('groupId', 'memberId')

            if ($deletedCount -gt 0) {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedCount eligible memberships that no longer exist" -ForegroundColor Yellow
            }
            else {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] No deleted eligible memberships found" -ForegroundColor Green
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
    Write-Host "PIM Groups:                 $totalGroups" -ForegroundColor White
    Write-Host "Eligible Memberships:       $($allEligibleMembers.Count)" -ForegroundColor White
    Write-Host "Synced:                     $syncedCount" -ForegroundColor White
    Write-Host "Deleted:                    $deletedCount" -ForegroundColor White
    Write-Host "Errors:                     $errorCount" -ForegroundColor White
    Write-Host "`nAll changes are automatically tracked in ${TableName}History" -ForegroundColor Cyan
    Write-Host "Note: Only groups with eligible members (actual PIM-enabled groups) are processed" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Green

    # Set sync status for logging
    $syncRecordCount = $allEligibleMembers.Count
    $syncStatus = if ($errorCount -gt 0) { "PartialSuccess" } else { "Success" }

    } # End try
    catch {
        $syncErrorMessage = $_.Exception.Message
        $syncStatus = "Failed"
        throw
    }
    finally {
        # Write sync log entry
        Write-FGSyncLog -SyncType "GroupEligibleMembers" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName $TableName
    }

    return @{
        TableName = $TableName
        TotalGroups = $totalGroups
        TotalMemberships = $allEligibleMembers.Count
        SyncedCount = $syncedCount
        DeletedCount = $deletedCount
        ErrorCount = $errorCount
    }
}
