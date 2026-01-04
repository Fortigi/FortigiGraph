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
                $group = Invoke-RestMethod -Uri $uri -Headers @{Authorization = "Bearer $global:AccessToken"} -Method Get
                $groups += $group
            }
            catch {
                Write-Warning "Failed to fetch group $groupId : $_"
            }
        }
    }
    else {
        # Fetch all groups (or filtered groups)
        $uri = "$graphUri/groups?`$select=id,displayName"
        if ($Filter) {
            $uri += "&`$filter=$Filter"
        }

        $groups = @()
        do {
            try {
                $response = Invoke-RestMethod -Uri $uri -Headers @{Authorization = "Bearer $global:AccessToken"} -Method Get
                $groups += $response.value
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Fetched $($groups.Count) groups..." -ForegroundColor Gray
                $uri = $response.'@odata.nextLink'
            }
            catch {
                throw "Failed to fetch groups: $_"
            }
        } while ($uri)
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
            # Fetch owners for this group
            $ownerUri = "$graphUri/groups/$($group.id)/owners?`$select=id"

            do {
                try {
                    $ownerResponse = Invoke-RestMethod -Uri $ownerUri -Headers @{Authorization = "Bearer $global:AccessToken"} -Method Get

                    # Add each owner to the collection
                    foreach ($owner in $ownerResponse.value) {
                        $ownership = [PSCustomObject]@{
                            groupId = $group.id
                            ownerId = $owner.id
                        }
                        $allOwnerships += $ownership
                    }

                    $ownerUri = $ownerResponse.'@odata.nextLink'
                }
                catch {
                    Write-Warning "Failed to fetch owners for group $($group.displayName): $_"
                    break
                }
            } while ($ownerUri)
        }
        catch {
            Write-Warning "Error processing group $($group.displayName): $_"
        }
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Total ownership relationships fetched: $($allOwnerships.Count)" -ForegroundColor Cyan

    # Sync to SQL
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing ownership relationships to SQL Server..." -ForegroundColor Cyan

    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Database connection established" -ForegroundColor Gray
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Starting transaction..." -ForegroundColor Gray

        $transaction = $connection.BeginTransaction()

        try {
            # Prepare MERGE statement
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Preparing MERGE statement..." -ForegroundColor Gray

            $mergeSQL = New-FGSQLMergeStatement -TableName $TableName -Attributes $attributes -TypeMap $graphToSqlTypeMap -PrimaryKey @('groupId', 'ownerId')

            $cmd = $connection.CreateCommand()
            $cmd.Transaction = $transaction
            $cmd.CommandText = $mergeSQL

            # Add parameters (will be reused for each row)
            foreach ($attr in $attributes) {
                $cmd.Parameters.Add("@$attr", [System.Data.SqlDbType]::UniqueIdentifier) | Out-Null
            }

            # Execute for each ownership relationship
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Inserting/updating $($allOwnerships.Count) ownership relationships..." -ForegroundColor Gray
            $syncStartTime = Get-Date
            $syncedCount = 0
            $errorCount = 0

            foreach ($ownership in $allOwnerships) {
                try {
                    # Set parameter values
                    $cmd.Parameters["@groupId"].Value = [Guid]$ownership.groupId
                    $cmd.Parameters["@ownerId"].Value = [Guid]$ownership.ownerId

                    $cmd.ExecuteNonQuery() | Out-Null
                    $syncedCount++

                    if ($syncedCount % 100 -eq 0) {
                        $elapsed = (Get-Date) - $syncStartTime
                        $rate = [math]::Round($syncedCount / $elapsed.TotalSeconds, 1)
                        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Progress: $syncedCount/$($allOwnerships.Count) ownerships ($rate/sec)" -ForegroundColor Gray
                    }
                }
                catch {
                    Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] Failed to sync ownership (group: $($ownership.groupId), owner: $($ownership.ownerId)): $_"
                    $errorCount++
                }
            }

            # Commit transaction
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Committing transaction..." -ForegroundColor Gray
            $transaction.Commit()

            $syncElapsed = (Get-Date) - $syncStartTime
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Transaction committed successfully (took $($syncElapsed.TotalSeconds)s)" -ForegroundColor Green

            # Handle deletions (ownerships that no longer exist in Graph)
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking for removed ownership relationships..." -ForegroundColor Cyan

            $deleteCmd = $connection.CreateCommand()
            $deleteCmd.CommandText = @"
DELETE FROM dbo.$TableName
WHERE NOT EXISTS (
    SELECT 1 FROM (VALUES
        $( ($allOwnerships | ForEach-Object { "('$($_.groupId)', '$($_.ownerId)')" }) -join ',' )
    ) AS Source(groupId, ownerId)
    WHERE dbo.$TableName.groupId = CAST(Source.groupId AS UNIQUEIDENTIFIER)
    AND dbo.$TableName.ownerId = CAST(Source.ownerId AS UNIQUEIDENTIFIER)
)
"@

            if ($allOwnerships.Count -gt 0) {
                $deletedCount = $deleteCmd.ExecuteNonQuery()
                if ($deletedCount -gt 0) {
                    Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Removed $deletedCount ownership relationship(s) that no longer exist in Graph" -ForegroundColor Yellow
                }
                else {
                    Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] No removed ownership relationships found" -ForegroundColor Gray
                }
            }

            # Summary
            Write-Host "`n================================================================================" -ForegroundColor Cyan
            Write-Host "Sync Complete!" -ForegroundColor Green
            Write-Host "================================================================================" -ForegroundColor Cyan
            Write-Host "Table:                    $TableName" -ForegroundColor White
            Write-Host "Total Groups:             $($groups.Count)" -ForegroundColor White
            Write-Host "Total Ownerships:         $($allOwnerships.Count)" -ForegroundColor White
            Write-Host "Synced:                   $syncedCount" -ForegroundColor White
            Write-Host "Errors:                   $errorCount" -ForegroundColor $(if ($errorCount -eq 0) { "Green" } else { "Yellow" })
            Write-Host "`nAll changes are automatically tracked in ${TableName}_History" -ForegroundColor Gray
            Write-Host "================================================================================" -ForegroundColor Cyan
        }
        catch {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Error occurred, rolling back transaction..." -ForegroundColor Red
            $transaction.Rollback()
            throw "Sync failed: $_"
        }
    }
}
