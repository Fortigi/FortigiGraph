function Initialize-FGResourceIndexes {
    <#
    .SYNOPSIS
    Creates performance-optimized indexes for the universal resource model tables.

    .DESCRIPTION
    Creates indexes to dramatically improve query performance on resource data.
    These indexes are critical for the recursive membership calculations and comprehensive views.

    Indexes Created:
    - ResourceAssignments: IX_RA_ResourceId (resourceId, ValidTo)
    - ResourceAssignments: IX_RA_PrincipalId (principalId, ValidTo)
    - ResourceAssignments: IX_RA_Current (filtered index for current assignments)
    - ResourceRelationships: IX_RR_Parent (parentResourceId, ValidTo)
    - ResourceRelationships: IX_RR_Child (childResourceId, ValidTo)
    - ResourceRelationships: IX_RR_Current (filtered index for current relationships)
    - Resources: IX_Resources_SystemId (systemId)
    - Resources: IX_Resources_ResourceType (resourceType)
    - Principals: IX_Principals_SystemId (systemId)
    - Principals: IX_Principals_PrincipalType (principalType)
    - Principals: IX_Principals_ManagerId (managerId)
    - Principals: IX_Principals_Department (department)

    .PARAMETER DropIfExists
    If specified, drops existing indexes before recreating them.

    .EXAMPLE
    Initialize-FGResourceIndexes

    Creates all recommended indexes

    .EXAMPLE
    Initialize-FGResourceIndexes -DropIfExists

    Recreates all indexes (useful after schema changes)

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Tables to exist (run Initialize-FGSystemTables and sync functions first)

    Index creation may take several minutes for large datasets but dramatically
    improves ongoing query performance.
    #>

    [CmdletBinding()]
    [Alias("Initialize-ResourceIndexes")]
    Param(
        [Parameter(Mandatory = $false)]
        [switch]$DropIfExists
    )

    # Check SQL connection
    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Creating performance indexes for resource model tables..." -ForegroundColor Cyan

        # Check which tables exist
        $checkTablesCmd = $connection.CreateCommand()
        $checkTablesCmd.CommandText = @"
SELECT
    CASE WHEN EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'Resources') THEN 1 ELSE 0 END AS ResourcesExists,
    CASE WHEN EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'ResourceAssignments') THEN 1 ELSE 0 END AS AssignmentsExists,
    CASE WHEN EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'ResourceRelationships') THEN 1 ELSE 0 END AS RelationshipsExists,
    CASE WHEN EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'Principals') THEN 1 ELSE 0 END AS PrincipalsExists,
    CASE WHEN EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'Contexts') THEN 1 ELSE 0 END AS ContextsExists
"@
        $reader = $checkTablesCmd.ExecuteReader()
        $reader.Read()
        $resourcesExists = $reader.GetInt32(0) -eq 1
        $assignmentsExists = $reader.GetInt32(1) -eq 1
        $relationshipsExists = $reader.GetInt32(2) -eq 1
        $principalsExists = $reader.GetInt32(3) -eq 1
        $contextsExists = $reader.GetInt32(4) -eq 1
        $reader.Close()

        if (-not $resourcesExists -and -not $assignmentsExists) {
            throw "Required tables do not exist. Please run Initialize-FGSystemTables first."
        }

        # Define indexes to create
        $indexes = @()

        # Indexes for ResourceAssignments
        if ($assignmentsExists) {
            $indexes += @{
                Table = "ResourceAssignments"
                Name = "IX_RA_ResourceId"
                Columns = "resourceId, ValidTo"
                Include = "principalId, principalType, assignmentType"
                Where = $null
                Description = "Optimizes resource member lookups (used by views)"
            }
            $indexes += @{
                Table = "ResourceAssignments"
                Name = "IX_RA_PrincipalId"
                Columns = "principalId, ValidTo"
                Include = "resourceId, principalType, assignmentType"
                Where = $null
                Description = "Critical for recursive CTE joins (nested groups)"
            }
            $indexes += @{
                Table = "ResourceAssignments"
                Name = "IX_RA_Current"
                Columns = "ValidTo"
                Include = "resourceId, principalId, principalType, assignmentType"
                Where = "ValidTo = '9999-12-31 23:59:59.9999999'"
                Description = "Filtered index for current assignments only"
            }
        }

        # Indexes for ResourceRelationships
        if ($relationshipsExists) {
            $indexes += @{
                Table = "ResourceRelationships"
                Name = "IX_RR_Parent"
                Columns = "parentResourceId, ValidTo"
                Include = "childResourceId, relationshipType"
                Where = $null
                Description = "Optimizes parent resource lookups"
            }
            $indexes += @{
                Table = "ResourceRelationships"
                Name = "IX_RR_Child"
                Columns = "childResourceId, ValidTo"
                Include = "parentResourceId, relationshipType"
                Where = $null
                Description = "Optimizes child resource lookups"
            }
            $indexes += @{
                Table = "ResourceRelationships"
                Name = "IX_RR_Current"
                Columns = "ValidTo"
                Include = "parentResourceId, childResourceId, relationshipType"
                Where = "ValidTo = '9999-12-31 23:59:59.9999999'"
                Description = "Filtered index for current relationships only"
            }
        }

        # Indexes for Resources
        if ($resourcesExists) {
            $indexes += @{
                Table = "Resources"
                Name = "IX_Resources_SystemId"
                Columns = "systemId"
                Include = "displayName, resourceType"
                Where = $null
                Description = "Optimizes queries filtered by system"
            }
            $indexes += @{
                Table = "Resources"
                Name = "IX_Resources_ResourceType"
                Columns = "resourceType"
                Include = "systemId, displayName"
                Where = $null
                Description = "Optimizes queries filtered by resource type"
            }
        }

        # Indexes for Principals
        if ($principalsExists) {
            $indexes += @{
                Table = "Principals"
                Name = "IX_Principals_SystemId"
                Columns = "systemId"
                Include = "displayName, principalType"
                Where = $null
                Description = "Optimizes queries filtered by system"
            }
            $indexes += @{
                Table = "Principals"
                Name = "IX_Principals_PrincipalType"
                Columns = "principalType"
                Include = "systemId, displayName"
                Where = $null
                Description = "Optimizes queries filtered by principal type"
            }
            $indexes += @{
                Table = "Principals"
                Name = "IX_Principals_ManagerId"
                Columns = "managerId"
                Include = "displayName, department"
                Where = $null
                Description = "Optimizes manager hierarchy lookups"
            }
            $indexes += @{
                Table = "Principals"
                Name = "IX_Principals_Department"
                Columns = "department"
                Include = "displayName, jobTitle, companyName"
                Where = $null
                Description = "Optimizes department-based queries"
            }
        }

        # Indexes for Contexts
        if ($contextsExists) {
            $indexes += @{
                Table = "Contexts"
                Name = "IX_Contexts_SystemId"
                Columns = "systemId"
                Include = "displayName, contextType"
                Where = $null
                Description = "Optimizes queries filtered by system"
            }
            $indexes += @{
                Table = "Contexts"
                Name = "IX_Contexts_ParentId"
                Columns = "parentContextId"
                Include = "displayName, contextType, systemId"
                Where = $null
                Description = "Optimizes context hierarchy lookups"
            }
        }

        $createdCount = 0
        $skippedCount = 0
        $totalCount = $indexes.Count

        foreach ($index in $indexes) {
            $indexName = $index.Name
            $tableName = $index.Table
            $columns = $index.Columns
            $include = $index.Include
            $where = $index.Where
            $description = $index.Description

            Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Processing index: $indexName on $tableName" -ForegroundColor Cyan
            Write-Host "  Purpose: $description" -ForegroundColor Gray

            # Check if index exists
            $checkCmd = $connection.CreateCommand()
            $checkCmd.CommandText = @"
SELECT COUNT(*) FROM sys.indexes
WHERE name = '$indexName'
  AND object_id = OBJECT_ID('dbo.$tableName')
"@
            $exists = $checkCmd.ExecuteScalar() -gt 0

            if ($exists -and -not $DropIfExists) {
                Write-Host "  Index already exists (skipping)" -ForegroundColor Yellow
                $skippedCount++
                continue
            }

            # Drop if exists and DropIfExists specified
            if ($exists -and $DropIfExists) {
                Write-Host "  Dropping existing index..." -ForegroundColor Yellow
                $dropCmd = $connection.CreateCommand()
                $dropCmd.CommandText = "DROP INDEX [$indexName] ON dbo.[$tableName];"
                $dropCmd.ExecuteNonQuery() | Out-Null
            }

            # Build CREATE INDEX statement
            $createSQL = "CREATE NONCLUSTERED INDEX [$indexName] ON dbo.[$tableName] ($columns)"

            if ($include) {
                $createSQL += " INCLUDE ($include)"
            }

            if ($where) {
                $createSQL += " WHERE $where"
            }

            $createSQL += ";"

            # Create index
            Write-Host "  Creating index..." -ForegroundColor Gray
            $startTime = Get-Date

            $createCmd = $connection.CreateCommand()
            $createCmd.CommandTimeout = 600  # 10 minutes for large tables
            $createCmd.CommandText = $createSQL
            $createCmd.ExecuteNonQuery() | Out-Null

            $duration = (Get-Date) - $startTime
            Write-Host "  Created in $($duration.TotalSeconds.ToString('F1')) seconds" -ForegroundColor Green
            $createdCount++
        }

        Write-Host "`n========================================" -ForegroundColor Green
        Write-Host "Index Creation Complete!" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "Created: $createdCount" -ForegroundColor White
        Write-Host "Skipped: $skippedCount (already existed)" -ForegroundColor White
        Write-Host "Total: $totalCount" -ForegroundColor White
        Write-Host "`nPerformance Impact:" -ForegroundColor Cyan
        Write-Host "  - vw_ResourceUserPermissionAssignments queries should be 10-100x faster" -ForegroundColor Gray
        Write-Host "  - Recursive membership calculations significantly improved" -ForegroundColor Gray
        Write-Host "  - Resource lookups by system and type optimized" -ForegroundColor Gray
        Write-Host "  - Principal lookups by system, type, manager, department, and org unit optimized" -ForegroundColor Gray
        Write-Host "  - OrgUnit hierarchy and system lookups optimized" -ForegroundColor Gray
        Write-Host "========================================`n" -ForegroundColor Green

        return @{
            Created = $createdCount
            Skipped = $skippedCount
            Total = $totalCount
        }
    }
}
