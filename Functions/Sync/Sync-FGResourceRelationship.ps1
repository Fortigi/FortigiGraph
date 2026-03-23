function Sync-FGResourceRelationship {
    <#
    .SYNOPSIS
    Discovers and syncs resource-to-resource relationships to the ResourceRelationships table.

    .DESCRIPTION
    Analyzes existing Resources and ResourceAssignments data to discover relationships:
    1. Group nesting (Contains): When a group (principalId in ResourceAssignments) is also a Resource,
       the parent resource Contains the child group resource.
    2. App Role to Group (GrantsAccessTo): When a Group is assigned an app role, the group
       GrantsAccessTo the app role resource.

    This function works entirely from data already in SQL - it does NOT call the Graph API.

    .PARAMETER SystemId
    Optional system ID to scope relationship discovery to a specific system.

    .EXAMPLE
    Sync-FGResourceRelationship

    Discovers all resource relationships across all systems

    .EXAMPLE
    Sync-FGResourceRelationship -SystemId 1

    Discovers relationships only for resources in system 1

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Resources and ResourceAssignments tables to be populated
    - Run after Sync-FGEntraDirectoryRole, Sync-FGEntraAppRoleAssignment, etc.
    #>

    [CmdletBinding()]
    [Alias("Sync-ResourceRelationship")]
    Param(
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

    try {

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Discovering resource relationships..." -ForegroundColor Cyan

    # Ensure ResourceRelationships table exists
    $relationshipColumns = @{
        'parentResourceId' = 'UNIQUEIDENTIFIER'
        'childResourceId'  = 'UNIQUEIDENTIFIER'
        'relationshipType' = 'NVARCHAR(50)'
    }

    $tableReady = Initialize-FGSyncTable -TableName "ResourceRelationships" -Columns $relationshipColumns -CompositePrimaryKey @('parentResourceId', 'childResourceId', 'relationshipType')
    if ($tableReady -eq $false) { return }

    # Discover relationships from SQL data
    $syncResult = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        $allRelationships = @()

        # 1. Group nesting (Contains): Find ResourceAssignments where principalId is also a Resource
        Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Discovering group nesting relationships (Contains)..." -ForegroundColor Cyan

        $nestingCmd = $connection.CreateCommand()
        $nestingQuery = @"
SELECT DISTINCT
    ra.resourceId AS parentResourceId,
    r_child.id AS childResourceId,
    'Contains' AS relationshipType
FROM dbo.ResourceAssignments ra
INNER JOIN dbo.Resources r_child
    ON ra.principalId = r_child.id
    AND r_child.ValidTo = '9999-12-31 23:59:59.9999999'
WHERE ra.ValidTo = '9999-12-31 23:59:59.9999999'
  AND ra.assignmentType = 'Direct'
  AND ra.principalType LIKE '%group%'
"@

        if ($SystemId) {
            $nestingQuery += "`n  AND r_child.systemId = @systemId"
        }

        $nestingCmd.CommandText = $nestingQuery
        if ($SystemId) {
            $nestingCmd.Parameters.AddWithValue("@systemId", $SystemId) | Out-Null
        }

        $reader = $nestingCmd.ExecuteReader()
        $nestingCount = 0
        while ($reader.Read()) {
            $allRelationships += [PSCustomObject]@{
                parentResourceId = $reader.GetGuid(0)
                childResourceId  = $reader.GetGuid(1)
                relationshipType = $reader.GetString(2)
            }
            $nestingCount++
        }
        $reader.Close()

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Found $nestingCount group nesting relationships" -ForegroundColor Green

        # 2. App Role to Group (GrantsAccessTo): If a Group is assigned an app role,
        #    the group GrantsAccessTo the app role resource
        Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Discovering app role grant relationships (GrantsAccessTo)..." -ForegroundColor Cyan

        $grantCmd = $connection.CreateCommand()
        $grantQuery = @"
SELECT DISTINCT
    r_group.id AS parentResourceId,
    ra.resourceId AS childResourceId,
    'GrantsAccessTo' AS relationshipType
FROM dbo.ResourceAssignments ra
INNER JOIN dbo.Resources r_role
    ON ra.resourceId = r_role.id
    AND r_role.ValidTo = '9999-12-31 23:59:59.9999999'
    AND r_role.resourceType = 'EntraAppRole'
INNER JOIN dbo.Resources r_group
    ON ra.principalId = r_group.id
    AND r_group.ValidTo = '9999-12-31 23:59:59.9999999'
WHERE ra.ValidTo = '9999-12-31 23:59:59.9999999'
  AND ra.assignmentType = 'Direct'
  AND ra.principalType LIKE '%group%'
"@

        if ($SystemId) {
            $grantQuery += "`n  AND r_group.systemId = @systemId"
        }

        $grantCmd.CommandText = $grantQuery
        if ($SystemId) {
            $grantCmd.Parameters.AddWithValue("@systemId", $SystemId) | Out-Null
        }

        $reader = $grantCmd.ExecuteReader()
        $grantCount = 0
        while ($reader.Read()) {
            $allRelationships += [PSCustomObject]@{
                parentResourceId = $reader.GetGuid(0)
                childResourceId  = $reader.GetGuid(1)
                relationshipType = $reader.GetString(2)
            }
            $grantCount++
        }
        $reader.Close()

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Found $grantCount app role grant relationships" -ForegroundColor Green

        $totalRelationships = $allRelationships.Count
        Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Total relationships discovered: $totalRelationships" -ForegroundColor Cyan

        if ($totalRelationships -eq 0) {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] No relationships to sync" -ForegroundColor Gray
            return @{
                NestingCount = $nestingCount
                GrantCount = $grantCount
                TotalCount = 0
                Inserted = 0
                Updated = 0
                Deleted = 0
            }
        }

        # Build DataTable for bulk operations
        $dataTable = New-Object System.Data.DataTable
        $dataTable.Columns.Add("parentResourceId", [guid]) | Out-Null
        $dataTable.Columns.Add("childResourceId", [guid]) | Out-Null
        $dataTable.Columns.Add("relationshipType", [string]) | Out-Null

        foreach ($rel in $allRelationships) {
            $row = $dataTable.NewRow()
            $row["parentResourceId"] = [guid]$rel.parentResourceId
            $row["childResourceId"] = [guid]$rel.childResourceId
            $row["relationshipType"] = $rel.relationshipType
            $dataTable.Rows.Add($row)
        }

        # Sync to SQL
        $transaction = $connection.BeginTransaction()

        try {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($dataTable.Rows.Count) relationships..." -ForegroundColor Cyan

            $mergeResult = Invoke-FGSQLBulkMerge `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName "ResourceRelationships" `
                -DataTable $dataTable `
                -KeyColumns @('parentResourceId', 'childResourceId', 'relationshipType')

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Merge: $($mergeResult.Inserted) inserted, $($mergeResult.Updated) updated" -ForegroundColor Green

            # Delete stale relationships
            $deletedCount = Invoke-FGSQLBulkDelete `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName "ResourceRelationships" `
                -DataTable $dataTable `
                -KeyColumns @('parentResourceId', 'childResourceId', 'relationshipType')

            if ($deletedCount -gt 0) {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedCount stale relationships" -ForegroundColor Yellow
            }

            $transaction.Commit()
            $transaction.Dispose()

            $dataTable.Dispose()

            return @{
                NestingCount = $nestingCount
                GrantCount = $grantCount
                TotalCount = $totalRelationships
                Inserted = $mergeResult.Inserted
                Updated = $mergeResult.Updated
                Deleted = $deletedCount
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

    $syncRecordCount = $syncResult.TotalCount

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Resource Relationship Sync Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Nesting (Contains):       $($syncResult.NestingCount)" -ForegroundColor White
    Write-Host "Grants (GrantsAccessTo):  $($syncResult.GrantCount)" -ForegroundColor White
    Write-Host "Total Relationships:      $($syncResult.TotalCount)" -ForegroundColor White
    Write-Host "  Inserted:               $($syncResult.Inserted)" -ForegroundColor White
    Write-Host "  Updated:                $($syncResult.Updated)" -ForegroundColor White
    Write-Host "  Deleted:                $($syncResult.Deleted)" -ForegroundColor White
    Write-Host "`nAll changes tracked in ResourceRelationships temporal table" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Green

    $syncStatus = "Success"

    return @{
        NestingCount = $syncResult.NestingCount
        GrantCount = $syncResult.GrantCount
        TotalRelationships = $syncResult.TotalCount
        Inserted = $syncResult.Inserted
        Updated = $syncResult.Updated
        Deleted = $syncResult.Deleted
    }

    } # End try
    catch {
        $syncErrorMessage = $_.Exception.Message
        $syncStatus = "Failed"
        throw
    }
    finally {
        # Write sync log entry
        Write-FGSyncLog -SyncType "ResourceRelationships" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName "ResourceRelationships"
    }
}
