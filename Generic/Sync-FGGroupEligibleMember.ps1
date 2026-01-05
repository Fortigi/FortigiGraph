function Sync-FGGroupEligibleMember {
    <#
    .SYNOPSIS
    Syncs Microsoft Graph group eligible memberships (PIM) to Azure SQL with temporal versioning.

    .DESCRIPTION
    This function syncs eligible group memberships from Privileged Identity Management (PIM):
    - Only processes groups that are assignable to roles (PIM-enabled)
    - Excludes dynamic membership groups
    - Creates a table with groupId, memberId, and memberType columns
    - Uses composite primary key (groupId, memberId)
    - Automatically creates temporal table for change tracking
    - Iterates through each PIM group and fetches eligible members
    - Tracks PIM eligibility changes over time

    Use this to track who has ELIGIBLE access (can activate membership) vs active membership.
    For active members, use Sync-FGGroupMember or Sync-FGGroupTransitiveMember.

    .PARAMETER Filter
    Optional OData filter to limit which groups to process (applied before PIM filtering)

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
    - Only works with groups where isAssignableToRole = true
    - Excludes dynamic membership groups
    #>

    [CmdletBinding()]
    [Alias("Sync-GroupEligibleMember")]
    Param(
        [Parameter(Mandatory = $false)]
        [string]$Filter,

        [Parameter(Mandatory = $false)]
        [string[]]$GroupIds,

        [Parameter(Mandatory = $false)]
        [string]$TableName = "GraphGroupEligibleMembers",

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

    # Fetch PIM-enabled groups
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Fetching PIM-enabled groups from Microsoft Graph..." -ForegroundColor Cyan

    $graphUri = 'https://graph.microsoft.com/beta'

    if ($GroupIds) {
        # Use specific group IDs - fetch and filter for PIM eligibility
        $groups = @()
        foreach ($groupId in $GroupIds) {
            try {
                $uri = "$graphUri/groups/$groupId`?`$select=id,displayName,isAssignableToRole,groupTypes"
                $group = Invoke-FGGetRequest -URI $uri

                # Only include if PIM-eligible
                if ($group.isAssignableToRole -eq $true -and $group.groupTypes -notcontains "DynamicMembership") {
                    $groups += $group
                }
                else {
                    Write-Warning "Group $groupId is not PIM-enabled (requires isAssignableToRole = true and not dynamic)"
                }
            }
            catch {
                Write-Warning "Failed to fetch group $groupId : $_"
            }
        }
    }
    else {
        # Fetch all groups with PIM properties using Invoke-FGGetRequest (handles token validation and pagination)
        $uri = "$graphUri/groups?`$select=id,displayName,isAssignableToRole,groupTypes"
        if ($Filter) {
            $uri += "&`$filter=$Filter"
        }

        try {
            $allGroups = Invoke-FGGetRequest -URI $uri
            if (-not $allGroups) {
                $allGroups = @()
            }
        }
        catch {
            throw "Failed to fetch groups from Graph: $_"
        }

        # Filter for PIM-enabled groups only
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Filtering for PIM-enabled groups (isAssignableToRole = true, not dynamic)..." -ForegroundColor Cyan
        $groups = $allGroups | Where-Object { $_.isAssignableToRole -eq $true -and $_.groupTypes -notcontains "DynamicMembership" }
    }

    $totalGroups = $groups.Count
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Total PIM-enabled groups to process: $totalGroups" -ForegroundColor Green

    if ($totalGroups -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No PIM-enabled groups found to process."
        return
    }

    # Fetch all eligible group memberships (iterating through each PIM group)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Fetching eligible group memberships from PIM..." -ForegroundColor Cyan
    Write-Host "  This may take a while for tenants with many PIM groups..." -ForegroundColor Gray

    $allEligibleMembers = @()
    $processedGroups = 0
    $membershipStartTime = Get-Date

    foreach ($group in $groups) {
        $processedGroups++
        $percentComplete = [math]::Round(($processedGroups / $totalGroups) * 100, 1)

        Write-Progress -Activity "Fetching Eligible Group Memberships" -Status "Processing group $processedGroups of $totalGroups ($percentComplete%)" -PercentComplete $percentComplete

        # Use eligibilitySchedules endpoint for PIM
        $eligibilityUri = "$graphUri/identityGovernance/privilegedAccess/group/eligibilitySchedules?`$filter=groupId eq '$($group.id)'"

        try {
            # Fetch all eligible members for this group using Invoke-FGGetRequest (handles token validation and pagination)
            $eligibilities = Invoke-FGGetRequest -URI $eligibilityUri
            if (-not $eligibilities) {
                $eligibilities = @()
            }

            # For each eligibility, we need to get the principal details to determine type
            foreach ($eligibility in $eligibilities) {
                try {
                    # Get principal details to determine memberType using Invoke-FGGetRequest (handles token validation)
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

            # Show progress every 10 groups
            if ($processedGroups % 10 -eq 0) {
                $elapsed = (Get-Date) - $membershipStartTime
                $rate = [math]::Round($processedGroups / $elapsed.TotalSeconds, 1)
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Progress: $processedGroups/$totalGroups groups, $($allEligibleMembers.Count) eligible memberships ($rate groups/sec)" -ForegroundColor Gray
            }
        }
        catch {
            Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] Failed to fetch eligible members for group '$($group.displayName)' ($($group.id)): $_"
        }
    }

    Write-Progress -Activity "Fetching Eligible Group Memberships" -Completed

    $membershipElapsed = (Get-Date) - $membershipStartTime
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Total eligible memberships fetched: $($allEligibleMembers.Count) from $totalGroups PIM groups (took $([math]::Round($membershipElapsed.TotalSeconds, 1))s)" -ForegroundColor Green

    if ($allEligibleMembers.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No eligible memberships found to sync."
        return
    }

    # Sync to SQL
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing eligible memberships to SQL Server..." -ForegroundColor Cyan

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

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Inserting/updating $($allEligibleMembers.Count) eligible memberships..." -ForegroundColor Cyan

            foreach ($membership in $allEligibleMembers) {
                try {
                    $cmd.Parameters.Clear()

                    # Add parameters using helper
                    ConvertTo-FGSQLParameter -Value $membership.groupId -AttributeName 'groupId' -SqlCommand $cmd
                    ConvertTo-FGSQLParameter -Value $membership.memberId -AttributeName 'memberId' -SqlCommand $cmd

                    # memberType might be null
                    if ($membership.memberType) {
                        $cmd.Parameters.AddWithValue("@memberType", $membership.memberType) | Out-Null
                    }
                    else {
                        $cmd.Parameters.AddWithValue("@memberType", [DBNull]::Value) | Out-Null
                    }

                    $cmd.ExecuteNonQuery() | Out-Null
                    $syncedCount++

                    if ($syncedCount % 500 -eq 0) {
                        $elapsed = (Get-Date) - $syncStartTime
                        $rate = [math]::Round($syncedCount / $elapsed.TotalSeconds, 1)
                        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Progress: $syncedCount/$($allEligibleMembers.Count) memberships ($rate memberships/sec)" -ForegroundColor Gray
                    }
                }
                catch {
                    Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] Failed to sync eligible membership (groupId: $($membership.groupId), memberId: $($membership.memberId)): $_"
                    $errorCount++
                }
            }

            # Commit transaction
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Committing transaction..." -ForegroundColor Cyan
            $transaction.Commit()
            $syncElapsed = (Get-Date) - $syncStartTime
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Transaction committed successfully (took $([math]::Round($syncElapsed.TotalSeconds, 1))s)" -ForegroundColor Green

            # Handle deletions - remove eligibilities that no longer exist
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking for removed eligible memberships..." -ForegroundColor Cyan

            # Build list of current memberships
            $membershipPairs = ($allEligibleMembers | ForEach-Object { "('$($_.groupId)', '$($_.memberId)')" }) -join ','

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
                    Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedCount eligible memberships that no longer exist" -ForegroundColor Yellow
                }
                else {
                    Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] No deleted eligible memberships found" -ForegroundColor Green
                }
            }
            catch {
                Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] Failed to delete removed eligible memberships: $_"
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
    Write-Host "Table:                      $TableName" -ForegroundColor White
    Write-Host "PIM Groups:                 $totalGroups" -ForegroundColor White
    Write-Host "Eligible Memberships:       $($allEligibleMembers.Count)" -ForegroundColor White
    Write-Host "Synced:                     $syncedCount" -ForegroundColor White
    Write-Host "Deleted:                    $deletedCount" -ForegroundColor White
    Write-Host "Errors:                     $errorCount" -ForegroundColor White
    Write-Host "`nAll changes are automatically tracked in ${TableName}History" -ForegroundColor Cyan
    Write-Host "Note: Only PIM-enabled groups (isAssignableToRole = true) are processed" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Green

    return @{
        TableName = $TableName
        TotalGroups = $totalGroups
        TotalMemberships = $allEligibleMembers.Count
        SyncedCount = $syncedCount
        DeletedCount = $deletedCount
        ErrorCount = $errorCount
    }
}
