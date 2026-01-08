function Sync-FGGroupOwner {
    <#
    .SYNOPSIS
    Syncs Microsoft Graph group ownership relationships to Azure SQL with temporal versioning.

    .DESCRIPTION
    This function syncs the many-to-many relationship between groups and their owners:
    - Creates a table with groupId and ownerId columns
    - Uses composite primary key (groupId, ownerId)
    - Automatically creates temporal table for change tracking
    - Iterates through all groups and fetches owners for each
    - Handles all owner types (typically users)
    - Does NOT sync owner details - only the ownership relationships

    .PARAMETER Filter
    Optional OData filter to limit which groups to process (e.g., "securityEnabled eq true")

    .PARAMETER GroupIds
    Optional array of specific group IDs to sync. If not specified, syncs all groups.

    .PARAMETER TableName
    Name of the SQL table to create/sync to. Default: "GraphGroupOwners"

    .PARAMETER RecreateTable
    If specified, drops and recreates the table (WARNING: loses all history!)

    .EXAMPLE
    Sync-FGGroupOwner

    Syncs all group ownership relationships for all groups

    .EXAMPLE
    Sync-FGGroupOwner -Filter "securityEnabled eq true"

    Syncs ownership relationships only for security groups

    .EXAMPLE
    Sync-FGGroupOwner -GroupIds @('group-id-1', 'group-id-2')

    Syncs ownership relationships only for specific groups

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Valid Graph access token (Get-FGAccessToken)
    - This can be a long-running operation for tenants with many groups
    #>

    [CmdletBinding()]
    [Alias("Sync-GroupOwner")]
    Param(
        [Parameter(Mandatory = $false)]
        [string]$Filter,

        [Parameter(Mandatory = $false)]
        [string[]]$GroupIds,

        [Parameter(Mandatory = $false)]
        [string]$TableName = "GraphGroupOwners",

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

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Starting group ownership sync..." -ForegroundColor Cyan

    # Define attributes for the ownership table
    $attributes = @('groupId', 'ownerId')

    # Map to SQL types
    $graphToSqlTypeMap = @{
        'groupId' = 'UNIQUEIDENTIFIER'
        'ownerId' = 'UNIQUEIDENTIFIER'
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
            Initialize-FGSQLTable -TableName $TableName -Columns $columns -PrimaryKey @('groupId', 'ownerId') -DropIfExists:$RecreateTable
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
        # Fetch all groups (or filtered groups) using Invoke-FGGetRequest (handles token validation and pagination)
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
            throw "Failed to fetch groups: $_"
        }
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Total groups to process: $($groups.Count)" -ForegroundColor Cyan

    # Now iterate through each group and fetch its owners
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Fetching ownership relationships..." -ForegroundColor Cyan

    $allOwnerships = @()
    $processedGroups = 0

    foreach ($group in $groups) {
        $processedGroups++

        if ($processedGroups % 10 -eq 0) {
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Processing group $processedGroups/$($groups.Count)..." -ForegroundColor Gray
        }

        try {
            # Fetch owners for this group using Invoke-FGGetRequest (handles token validation and pagination)
            $ownerUri = "$graphUri/groups/$($group.id)/owners?`$select=id"
            $owners = Invoke-FGGetRequest -URI $ownerUri
            if (-not $owners) {
                $owners = @()
            }

            # Add each owner to the collection
            foreach ($owner in $owners) {
                $ownership = [PSCustomObject]@{
                    groupId = $group.id
                    ownerId = $owner.id
                }
                $allOwnerships += $ownership
            }
        }
        catch {
            Write-Warning "Error processing group $($group.displayName): $_"
        }
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Total ownership relationships fetched: $($allOwnerships.Count)" -ForegroundColor Cyan

    if ($allOwnerships.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No ownership relationships found to sync."
        return
    }

    # Sync to SQL using bulk operations (HIGH PERFORMANCE)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing ownership relationships to SQL Server..." -ForegroundColor Cyan

    # Build DataTable for bulk operations
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Preparing data for bulk sync..." -ForegroundColor Gray

    $dataTable = New-Object System.Data.DataTable
    $dataTable.Columns.Add("groupId", [guid]) | Out-Null
    $dataTable.Columns.Add("ownerId", [guid]) | Out-Null

    foreach ($ownership in $allOwnerships) {
        $row = $dataTable.NewRow()
        $row["groupId"] = [guid]$ownership.groupId
        $row["ownerId"] = [guid]$ownership.ownerId
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
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($dataTable.Rows.Count) ownership relationships..." -ForegroundColor Cyan

            # Use bulk MERGE operation - much faster than row-by-row
            $mergeResult = Invoke-FGSQLBulkMerge `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName $TableName `
                -DataTable $dataTable `
                -KeyColumns @('groupId', 'ownerId')

            $syncedCount = $mergeResult.Inserted + $mergeResult.Updated

            $syncElapsed = (Get-Date) - $syncStartTime
            $rate = if ($syncElapsed.TotalSeconds -gt 0) { [math]::Round($syncedCount / $syncElapsed.TotalSeconds, 1) } else { 0 }
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merge completed: $($mergeResult.Inserted) inserted, $($mergeResult.Updated) updated ($rate ownerships/sec)" -ForegroundColor Green

            # Handle deletions using bulk delete (avoids massive VALUES clause)
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking for removed ownership relationships..." -ForegroundColor Cyan

            $deletedCount = Invoke-FGSQLBulkDelete `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName $TableName `
                -DataTable $dataTable `
                -KeyColumns @('groupId', 'ownerId')

            if ($deletedCount -gt 0) {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedCount ownership relationship(s) that no longer exist in Graph" -ForegroundColor Yellow
            }
            else {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] No removed ownership relationships found" -ForegroundColor Green
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
    Write-Host "Groups:                     $($groups.Count)" -ForegroundColor White
    Write-Host "Ownership Relationships:    $($allOwnerships.Count)" -ForegroundColor White
    Write-Host "Synced:                     $syncedCount" -ForegroundColor White
    Write-Host "Deleted:                    $deletedCount" -ForegroundColor White
    Write-Host "Errors:                     $errorCount" -ForegroundColor White
    Write-Host "`nAll changes are automatically tracked in ${TableName}History" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Green

    return @{
        TableName = $TableName
        TotalGroups = $groups.Count
        TotalOwnerships = $allOwnerships.Count
        SyncedCount = $syncedCount
        DeletedCount = $deletedCount
        ErrorCount = $errorCount
    }
}
