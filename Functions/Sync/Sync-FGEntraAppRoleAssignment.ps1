function Sync-FGEntraAppRoleAssignment {
    <#
    .SYNOPSIS
    Syncs Entra ID application role assignments to the universal resource model tables.

    .DESCRIPTION
    Fetches all service principals with app roles from Entra ID and syncs:
    - Resources table: Each unique (servicePrincipalId, appRoleId) as a resource with resourceType='EntraAppRole'
    - ResourceAssignments table: Who has each role, with assignmentType='Direct'

    Resource IDs are generated deterministically from MD5("{servicePrincipalId}_{appRoleId}")
    to ensure consistent IDs across syncs.

    .PARAMETER RecreateTable
    If specified, drops and recreates the Resources and ResourceAssignments tables (WARNING: loses all history!)

    .PARAMETER SystemId
    Optional system ID to use. If not provided, auto-detects from Systems table where systemType='EntraID'.

    .PARAMETER Filter
    Optional OData filter for service principals (e.g., "displayName eq 'SharePoint Online'")

    .EXAMPLE
    Sync-FGEntraAppRoleAssignment

    Syncs all app role assignments using auto-detected system ID

    .EXAMPLE
    Sync-FGEntraAppRoleAssignment -Filter "tags/any(t: t eq 'WindowsAzureActiveDirectoryIntegratedApp')"

    Syncs only enterprise applications (gallery + custom)

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Valid Graph access token (Get-FGAccessToken)
    - Initialize-FGSystemTables to have been run
    - Permission: Application.Read.All or Directory.Read.All
    #>

    [CmdletBinding()]
    [Alias("Sync-EntraAppRoleAssignment")]
    Param(
        [Parameter(Mandatory = $false)]
        [switch]$RecreateTable,

        [Parameter(Mandatory = $false)]
        [int]$SystemId,

        [Parameter(Mandatory = $false)]
        [string]$Filter
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

    # Helper function: Generate deterministic GUID from string
    function New-DeterministicGuid {
        param([string]$InputValue)
        $md5Provider = [System.Security.Cryptography.MD5]::Create()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputValue)
        $hash = $md5Provider.ComputeHash($bytes)
        $md5Provider.Dispose()
        $hex = ($hash | ForEach-Object { $_.ToString('x2') }) -join ''
        $guidStr = $hex.Substring(0,8) + '-' + $hex.Substring(8,4) + '-' + $hex.Substring(12,4) + '-' + $hex.Substring(16,4) + '-' + $hex.Substring(20,12)
        return [guid]$guidStr
    }

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

    # Fetch service principals with app roles
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Fetching service principals from Microsoft Graph..." -ForegroundColor Cyan

    $graphStartTime = Get-Date
    $spUri = "https://graph.microsoft.com/v1.0/servicePrincipals?`$select=id,displayName,appId,appRoles&`$top=999"

    if ($Filter) {
        $spUri += "&`$filter=$Filter"
    }

    try {
        $allServicePrincipals = Invoke-FGGetRequest -URI $spUri
        if (-not $allServicePrincipals) {
            $allServicePrincipals = @()
        }
    }
    catch {
        throw "Failed to fetch service principals from Graph: $_"
    }

    $graphElapsed = (Get-Date) - $graphStartTime
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Total service principals fetched: $($allServicePrincipals.Count) (took $([math]::Round($graphElapsed.TotalSeconds, 1))s)" -ForegroundColor Green

    # Filter to SPs that have appRoles defined
    $spsWithRoles = $allServicePrincipals | Where-Object { $_.appRoles -and $_.appRoles.Count -gt 0 }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Service principals with app roles: $($spsWithRoles.Count)" -ForegroundColor Cyan

    if ($spsWithRoles.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No service principals with app roles found."
        $syncStatus = "Success"
        $syncRecordCount = 0
        return
    }

    # Build a lookup of appRole definitions per SP
    $appRoleLookup = @{}
    foreach ($sp in $spsWithRoles) {
        foreach ($role in $sp.appRoles) {
            $compositeKey = "$($sp.id)_$($role.id)"
            $appRoleLookup[$compositeKey] = @{
                ServicePrincipalId = $sp.id
                AppDisplayName     = $sp.displayName
                AppId              = $sp.appId
                RoleId             = $role.id
                RoleDisplayName    = $role.displayName
                RoleValue          = $role.value
                RoleDescription    = $role.description
                DeterministicId    = New-DeterministicGuid -InputString $compositeKey
            }
        }
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Total unique app roles across all SPs: $($appRoleLookup.Count)" -ForegroundColor Cyan

    # Fetch app role assignments for each SP
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Fetching app role assignments..." -ForegroundColor Cyan

    $allResources = @()
    $allAssignments = @()
    $processedSPs = 0
    $assignmentStartTime = Get-Date
    $discoveredRoleKeys = @{}

    foreach ($sp in $spsWithRoles) {
        $processedSPs++
        $percentComplete = [math]::Round(($processedSPs / $spsWithRoles.Count) * 100, 1)

        Write-Progress -Activity "Fetching App Role Assignments" `
            -Status "SP $processedSPs of $($spsWithRoles.Count) ($percentComplete%) - $($sp.displayName)" `
            -PercentComplete $percentComplete

        $assignUri = "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.id)/appRoleAssignedTo?`$select=id,appRoleId,principalId,principalType,principalDisplayName,resourceId,resourceDisplayName,createdDateTime"

        try {
            $assignments = Invoke-FGGetRequest -URI $assignUri
            if (-not $assignments) {
                $assignments = @()
            }

            foreach ($assignment in $assignments) {
                $appRoleId = $assignment.appRoleId
                $compositeKey = "$($sp.id)_$appRoleId"

                # Track which roles actually have assignments
                if (-not $discoveredRoleKeys.ContainsKey($compositeKey)) {
                    $discoveredRoleKeys[$compositeKey] = $true

                    # Look up role definition
                    $roleDef = $appRoleLookup[$compositeKey]
                    if ($roleDef) {
                        $roleName = if ($roleDef.RoleDisplayName) { $roleDef.RoleDisplayName } elseif ($roleDef.RoleValue) { $roleDef.RoleValue } else { "Default Access" }
                        $allResources += [PSCustomObject]@{
                            id                 = $roleDef.DeterministicId
                            systemId           = $SystemId
                            displayName        = "$($roleDef.AppDisplayName) - $roleName"
                            description        = $roleDef.RoleDescription
                            resourceType       = 'EntraAppRole'
                            extendedAttributes = (@{
                                appId              = $roleDef.AppId
                                appDisplayName     = $roleDef.AppDisplayName
                                servicePrincipalId = $roleDef.ServicePrincipalId
                                roleValue          = $roleDef.RoleValue
                                roleDescription    = $roleDef.RoleDescription
                            } | ConvertTo-Json -Depth 10 -Compress)
                        }
                    }
                }

                # Map the assignment
                $roleDef = $appRoleLookup[$compositeKey]
                if ($roleDef) {
                    $allAssignments += [PSCustomObject]@{
                        resourceId     = $roleDef.DeterministicId
                        principalId    = $assignment.principalId
                        principalType  = $assignment.principalType
                        assignmentType = 'Direct'
                    }
                }
            }
        }
        catch {
            Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] Failed to fetch assignments for SP '$($sp.displayName)' ($($sp.id)): $_"
        }
    }

    Write-Progress -Activity "Fetching App Role Assignments" -Completed

    $assignmentElapsed = (Get-Date) - $assignmentStartTime
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Total app role resources: $($allResources.Count), assignments: $($allAssignments.Count) (took $([math]::Round($assignmentElapsed.TotalSeconds, 1))s)" -ForegroundColor Green

    if ($allResources.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No app role assignments found."
        $syncStatus = "Success"
        $syncRecordCount = 0
        return
    }

    # Build Resources DataTable
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Preparing resource data..." -ForegroundColor Gray

    $resourceAttributes = @('id', 'systemId', 'displayName', 'description', 'resourceType', 'extendedAttributes')
    $resourceResolvers = @{}

    $resourceDataTable = New-FGDataTableFromGraphObjects -GraphObjects $allResources -Columns $resourceColumns -Attributes $resourceAttributes -ValueResolvers $resourceResolvers

    # Build ResourceAssignments DataTable
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Preparing assignment data..." -ForegroundColor Gray

    $assignmentDataTable = New-Object System.Data.DataTable
    $assignmentDataTable.Columns.Add("resourceId", [guid]) | Out-Null
    $assignmentDataTable.Columns.Add("principalId", [guid]) | Out-Null
    $assignmentDataTable.Columns.Add("principalType", [string]) | Out-Null
    $assignmentDataTable.Columns.Add("assignmentType", [string]) | Out-Null

    foreach ($assignment in $allAssignments) {
        $row = $assignmentDataTable.NewRow()
        $row["resourceId"] = [guid]$assignment.resourceId
        $row["principalId"] = [guid]$assignment.principalId
        $row["principalType"] = if ($assignment.principalType) { $assignment.principalType } else { [DBNull]::Value }
        $row["assignmentType"] = $assignment.assignmentType
        $assignmentDataTable.Rows.Add($row)
    }

    # Deduplicate assignments (same principal can be assigned same role via multiple paths)
    $seenKeys = @{}
    $dedupedTable = $assignmentDataTable.Clone()
    foreach ($row in $assignmentDataTable.Rows) {
        $key = "$($row['resourceId'])_$($row['principalId'])_$($row['assignmentType'])"
        if (-not $seenKeys.ContainsKey($key)) {
            $seenKeys[$key] = $true
            $dedupedTable.ImportRow($row)
        }
    }
    $assignmentDataTable.Dispose()
    $assignmentDataTable = $dedupedTable

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Deduplicated assignments: $($assignmentDataTable.Rows.Count)" -ForegroundColor Gray

    # Sync to SQL
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing app roles to SQL Server..." -ForegroundColor Cyan

    $syncResult = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        $transaction = $connection.BeginTransaction()

        try {
            # Bulk merge resources
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($resourceDataTable.Rows.Count) app role resources to Resources..." -ForegroundColor Cyan

            $resourceMergeResult = Invoke-FGSQLBulkMerge `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName "Resources" `
                -DataTable $resourceDataTable `
                -KeyColumns @('id')

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Resources: $($resourceMergeResult.Inserted) inserted, $($resourceMergeResult.Updated) updated" -ForegroundColor Green

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

                # Delete stale assignments ONLY for EntraAppRole resources (scoped delete)
                $deleteCmd = $connection.CreateCommand()
                $deleteCmd.Transaction = $transaction
                $deleteCmd.CommandText = @"
DELETE ra FROM dbo.ResourceAssignments ra
INNER JOIN dbo.Resources r ON ra.resourceId = r.id
WHERE r.resourceType = 'EntraAppRole'
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
                    Write-Verbose "Scoped delete not available (temp table missing): $_"
                }
                $deleteCmd.Dispose()

                if ($deletedAssignments -gt 0) {
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedAssignments stale assignments" -ForegroundColor Yellow
                }
            }
            else {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] No assignments to sync" -ForegroundColor Gray
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

    $syncRecordCount = $allResources.Count + $allAssignments.Count

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "App Role Assignment Sync Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "System ID:         $SystemId" -ForegroundColor White
    Write-Host "SPs Processed:     $($spsWithRoles.Count)" -ForegroundColor White
    Write-Host "App Roles:         $($allResources.Count)" -ForegroundColor White
    Write-Host "  Inserted:        $($syncResult.ResourcesInserted)" -ForegroundColor White
    Write-Host "  Updated:         $($syncResult.ResourcesUpdated)" -ForegroundColor White
    Write-Host "Assignments:       $($assignmentDataTable.Rows.Count)" -ForegroundColor White
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
        ServicePrincipalsProcessed = $spsWithRoles.Count
        TotalAppRoles = $allResources.Count
        TotalAssignments = $assignmentDataTable.Rows.Count
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
        Write-FGSyncLog -SyncType "EntraAppRoleAssignments" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName "Resources"
    }
}
