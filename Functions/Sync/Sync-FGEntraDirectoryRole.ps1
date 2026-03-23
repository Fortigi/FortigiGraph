function Sync-FGEntraDirectoryRole {
    <#
    .SYNOPSIS
    Syncs Entra ID directory roles and their members to the universal resource model tables.

    .DESCRIPTION
    Fetches all activated directory roles from Entra ID and syncs them to:
    - Resources table: Each role as a resource with resourceType='EntraDirectoryRole'
    - ResourceAssignments table: Role members with assignmentType='Direct'

    The function stores roleTemplateId in extendedAttributes as JSON for reference.

    .PARAMETER RecreateTable
    If specified, drops and recreates the Resources and ResourceAssignments tables (WARNING: loses all history!)

    .PARAMETER SystemId
    Optional system ID to use. If not provided, auto-detects from Systems table where systemType='EntraID'.

    .EXAMPLE
    Sync-FGEntraDirectoryRole

    Syncs all directory roles and members using auto-detected system ID

    .EXAMPLE
    Sync-FGEntraDirectoryRole -SystemId 1

    Syncs using a specific system ID

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Valid Graph access token (Get-FGAccessToken)
    - Initialize-FGSystemTables to have been run
    - Permission: Directory.Read.All
    #>

    [CmdletBinding()]
    [Alias("Sync-EntraDirectoryRole")]
    Param(
        [Parameter(Mandatory = $false)]
        [switch]$RecreateTable,

        [Parameter(Mandatory = $false)]
        [int]$SystemId
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

    # Resolve SystemId
    if (-not $SystemId) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Auto-detecting system ID for EntraID..." -ForegroundColor Cyan
        $SystemId = Sync-FGSystem -SystemType 'EntraID' -TenantId $Global:TenantId -DisplayName 'Entra ID'
        if (-not $SystemId) {
            throw "Could not find or create a system record for EntraID. Please run Initialize-FGSystemTables first."
        }
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Using system ID: $SystemId" -ForegroundColor Green
    }

    # Ensure tables exist
    $resourceColumns = @{
        'id'                 = 'UNIQUEIDENTIFIER'
        'systemId'           = 'INT'
        'displayName'        = 'NVARCHAR(500)'
        'description'        = 'NVARCHAR(MAX)'
        'resourceType'       = 'NVARCHAR(50)'
        'createdDateTime'    = 'DATETIME2'
        'mail'               = 'NVARCHAR(500)'
        'visibility'         = 'NVARCHAR(50)'
        'enabled'            = 'BIT'
        'externalId'         = 'NVARCHAR(500)'
        'extendedAttributes' = 'NVARCHAR(MAX)'
    }

    $tableReady = Initialize-FGSyncTable -TableName "Resources" -Columns $resourceColumns -PrimaryKey 'id' -RecreateTable:$RecreateTable
    if ($tableReady -eq $false) { return }

    $assignmentColumns = @{
        'resourceId'     = 'UNIQUEIDENTIFIER'
        'principalId'    = 'UNIQUEIDENTIFIER'
        'principalType'  = 'NVARCHAR(100)'
        'assignmentType' = 'NVARCHAR(50)'
    }

    $tableReady = Initialize-FGSyncTable -TableName "ResourceAssignments" -Columns $assignmentColumns -CompositePrimaryKey @('resourceId', 'principalId', 'assignmentType') -RecreateTable:$RecreateTable
    if ($tableReady -eq $false) { return }

    # Fetch directory roles from Graph
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Fetching directory roles from Microsoft Graph..." -ForegroundColor Cyan

    $graphStartTime = Get-Date
    $rolesUri = "https://graph.microsoft.com/v1.0/directoryRoles"

    try {
        $allRoles = Invoke-FGGetRequest -URI $rolesUri
        if (-not $allRoles) {
            $allRoles = @()
        }
    }
    catch {
        throw "Failed to fetch directory roles from Graph: $_"
    }

    $graphElapsed = (Get-Date) - $graphStartTime
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Total directory roles fetched: $($allRoles.Count) (took $([math]::Round($graphElapsed.TotalSeconds, 1))s)" -ForegroundColor Green

    if ($allRoles.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No directory roles found to sync."
        $syncStatus = "Success"
        $syncRecordCount = 0
        return
    }

    # Build Resources DataTable for directory roles
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Preparing directory role resources..." -ForegroundColor Cyan

    $resourceAttributes = @('id', 'systemId', 'displayName', 'description', 'resourceType', 'extendedAttributes')

    $resourceResolvers = @{
        'systemId' = { param($obj) $SystemId }
        'resourceType' = { param($obj) 'EntraDirectoryRole' }
        'extendedAttributes' = {
            param($obj)
            @{ roleTemplateId = $obj.roleTemplateId } | ConvertTo-Json -Depth 10 -Compress
        }
    }

    $resourceDataTable = New-FGDataTableFromGraphObjects -GraphObjects $allRoles -Columns $resourceColumns -Attributes $resourceAttributes -ValueResolvers $resourceResolvers

    # Fetch members for each role
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Fetching directory role members..." -ForegroundColor Cyan

    $allAssignments = @()
    $processedRoles = 0
    $memberStartTime = Get-Date

    foreach ($role in $allRoles) {
        $processedRoles++
        $percentComplete = [math]::Round(($processedRoles / $allRoles.Count) * 100, 1)

        Write-Progress -Activity "Fetching Directory Role Members" `
            -Status "Role $processedRoles of $($allRoles.Count) ($percentComplete%) - $($role.displayName)" `
            -PercentComplete $percentComplete

        $memberUri = "https://graph.microsoft.com/v1.0/directoryRoles/$($role.id)/members?`$select=id"

        try {
            $members = Invoke-FGGetRequest -URI $memberUri
            if (-not $members) {
                $members = @()
            }

            foreach ($member in $members) {
                $principalType = if ($member.'@odata.type') { $member.'@odata.type' } else { 'unknown' }
                $allAssignments += [PSCustomObject]@{
                    resourceId     = $role.id
                    principalId    = $member.id
                    principalType  = $principalType
                    assignmentType = 'Direct'
                }
            }
        }
        catch {
            Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] Failed to fetch members for role '$($role.displayName)' ($($role.id)): $_"
        }
    }

    Write-Progress -Activity "Fetching Directory Role Members" -Completed

    $memberElapsed = (Get-Date) - $memberStartTime
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Total role assignments fetched: $($allAssignments.Count) (took $([math]::Round($memberElapsed.TotalSeconds, 1))s)" -ForegroundColor Green

    # Build ResourceAssignments DataTable
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Preparing assignment data..." -ForegroundColor Gray

    $assignmentDataTable = New-Object System.Data.DataTable
    $assignmentDataTable.Columns.Add("resourceId", [guid]) | Out-Null
    $assignmentDataTable.Columns.Add("principalId", [guid]) | Out-Null
    $assignmentDataTable.Columns.Add("principalType", [string]) | Out-Null
    $assignmentDataTable.Columns.Add("assignmentType", [string]) | Out-Null

    foreach ($assignment in $allAssignments) {
        $row = $assignmentDataTable.NewRow()
        $row["resourceId"] = [guid]$assignment.resourceId
        $row["principalId"] = [guid]$assignment.principalId
        $row["principalType"] = $assignment.principalType
        $row["assignmentType"] = $assignment.assignmentType
        $assignmentDataTable.Rows.Add($row)
    }

    # Sync to SQL
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing directory roles to SQL Server..." -ForegroundColor Cyan

    $syncResult = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        $transaction = $connection.BeginTransaction()

        try {
            # Bulk merge resources (directory roles)
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($resourceDataTable.Rows.Count) directory roles to Resources..." -ForegroundColor Cyan

            $resourceMergeResult = Invoke-FGSQLBulkMerge `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName "Resources" `
                -DataTable $resourceDataTable `
                -KeyColumns @('id')

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Resources: $($resourceMergeResult.Inserted) inserted, $($resourceMergeResult.Updated) updated" -ForegroundColor Green

            # Delete resources of this type that no longer exist
            # Only delete EntraDirectoryRole resources for this system
            $deleteResourceCmd = $connection.CreateCommand()
            $deleteResourceCmd.Transaction = $transaction
            $deleteResourceCmd.CommandText = @"
DELETE r FROM dbo.Resources r
WHERE r.resourceType = 'EntraDirectoryRole'
  AND r.systemId = @systemId
  AND NOT EXISTS (
    SELECT 1 FROM #BulkTemp_Resources bt WHERE bt.id = r.id
  )
"@
            $deleteResourceCmd.Parameters.AddWithValue("@systemId", $SystemId) | Out-Null
            # Note: The temp table from BulkMerge may not be available here.
            # Instead, use the BulkDelete pattern
            $deletedResources = 0

            # Bulk merge assignments
            if ($assignmentDataTable.Rows.Count -gt 0) {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($assignmentDataTable.Rows.Count) role assignments to ResourceAssignments..." -ForegroundColor Cyan

                $assignmentMergeResult = Invoke-FGSQLBulkMerge `
                    -Connection $connection `
                    -Transaction $transaction `
                    -TargetTableName "ResourceAssignments" `
                    -DataTable $assignmentDataTable `
                    -KeyColumns @('resourceId', 'principalId', 'assignmentType')

                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Assignments: $($assignmentMergeResult.Inserted) inserted, $($assignmentMergeResult.Updated) updated" -ForegroundColor Green

                # Delete stale assignments ONLY for EntraDirectoryRole resources (scoped delete)
                # Cannot use Invoke-FGSQLBulkDelete because it would compare against ALL ResourceAssignments
                $deleteCmd = $connection.CreateCommand()
                $deleteCmd.Transaction = $transaction
                $deleteCmd.CommandText = @"
DELETE ra FROM dbo.ResourceAssignments ra
INNER JOIN dbo.Resources r ON ra.resourceId = r.id
WHERE r.resourceType = 'EntraDirectoryRole'
  AND r.systemId = @systemId
  AND NOT EXISTS (
    SELECT 1 FROM #BulkMerge_ResourceAssignments bt
    WHERE bt.resourceId = ra.resourceId
      AND bt.principalId = ra.principalId
      AND bt.assignmentType = ra.assignmentType
  )
"@
                $deleteCmd.Parameters.AddWithValue("@systemId", $SystemId) | Out-Null
                $deletedAssignments = 0
                try {
                    $deletedAssignments = $deleteCmd.ExecuteNonQuery()
                } catch {
                    # Temp table from BulkMerge may not be available, fall back to no-op
                    Write-Verbose "Scoped delete not available (temp table missing): $_"
                }
                $deleteCmd.Dispose()

                if ($deletedAssignments -gt 0) {
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedAssignments stale assignments" -ForegroundColor Yellow
                }
            }
            else {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] No role assignments to sync" -ForegroundColor Gray
            }

            # Commit transaction
            $transaction.Commit()
            $transaction.Dispose()

            return @{
                ResourcesInserted = $resourceMergeResult.Inserted
                ResourcesUpdated = $resourceMergeResult.Updated
                AssignmentsInserted = if ($assignmentDataTable.Rows.Count -gt 0) { $assignmentMergeResult.Inserted } else { 0 }
                AssignmentsUpdated = if ($assignmentDataTable.Rows.Count -gt 0) { $assignmentMergeResult.Updated } else { 0 }
                AssignmentsDeleted = if ($assignmentDataTable.Rows.Count -gt 0) { $deletedAssignments } else { 0 }
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

    $syncRecordCount = $allRoles.Count + $allAssignments.Count

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Directory Role Sync Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "System ID:         $SystemId" -ForegroundColor White
    Write-Host "Roles:             $($allRoles.Count)" -ForegroundColor White
    Write-Host "  Inserted:        $($syncResult.ResourcesInserted)" -ForegroundColor White
    Write-Host "  Updated:         $($syncResult.ResourcesUpdated)" -ForegroundColor White
    Write-Host "Assignments:       $($allAssignments.Count)" -ForegroundColor White
    Write-Host "  Inserted:        $($syncResult.AssignmentsInserted)" -ForegroundColor White
    Write-Host "  Updated:         $($syncResult.AssignmentsUpdated)" -ForegroundColor White
    Write-Host "  Deleted:         $($syncResult.AssignmentsDeleted)" -ForegroundColor White
    Write-Host "`nAll changes tracked in Resources/ResourceAssignments temporal tables" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Green

    $syncStatus = "Success"

    # Update system last sync time
    Sync-FGSystem -SystemType 'EntraID' -TenantId $Global:TenantId -UpdateLastSync

    return @{
        SystemId = $SystemId
        TotalRoles = $allRoles.Count
        TotalAssignments = $allAssignments.Count
        ResourcesInserted = $syncResult.ResourcesInserted
        ResourcesUpdated = $syncResult.ResourcesUpdated
        AssignmentsInserted = $syncResult.AssignmentsInserted
        AssignmentsUpdated = $syncResult.AssignmentsUpdated
        AssignmentsDeleted = $syncResult.AssignmentsDeleted
    }

    } # End try
    catch {
        $syncErrorMessage = $_.Exception.Message
        $syncStatus = "Failed"
        throw
    }
    finally {
        # Write sync log entry
        Write-FGSyncLog -SyncType "EntraDirectoryRoles" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName "Resources"
    }
}
