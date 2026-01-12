function Add-FGGroupMembershipIndexes {
    <#
    .SYNOPSIS
    Adds performance indexes to group membership tables for faster view queries.

    .DESCRIPTION
    Creates non-clustered indexes on group membership tables to optimize the performance
    of recursive membership views and queries. These indexes are critical for large
    environments with thousands of groups and members.

    The function:
    - Checks if tables exist before creating indexes
    - Skips indexes that already exist
    - Creates covering indexes for the most common query patterns
    - Optimizes the recursive membership calculation (vw_GraphGroupMembersRecursive)

    Indexes Created:

    GraphGroupMembers (Direct Members):
    - IX_GroupMembers_GroupId_ValidTo: For "get all members of group X" queries
    - IX_GroupMembers_MemberId_Type_ValidTo: For recursive traversal (is member a group?)

    GraphGroupOwners:
    - IX_GroupOwners_GroupId_ValidTo: For "get all owners of group X" queries
    - IX_GroupOwners_OwnerId_ValidTo: For "get all groups owned by user X" queries

    GraphGroupEligibleMembers:
    - IX_GroupEligible_GroupId_ValidTo: For "get all eligible members of group X" queries
    - IX_GroupEligible_MemberId_ValidTo: For "get all groups user X is eligible for" queries

    GraphGroupTransitiveMembers (if exists):
    - IX_GroupTransitive_GroupId_ValidTo: For "get all members of group X" queries
    - IX_GroupTransitive_MemberId_ValidTo: For "get all groups user X is member of" queries

    .PARAMETER DirectMembersTable
    Name of the direct members table. Default: "GraphGroupMembers"

    .PARAMETER OwnersTable
    Name of the owners table. Default: "GraphGroupOwners"

    .PARAMETER EligibleMembersTable
    Name of the eligible members table. Default: "GraphGroupEligibleMembers"

    .PARAMETER TransitiveMembersTable
    Name of the transitive members table. Default: "GraphGroupTransitiveMembers"

    .PARAMETER DropExisting
    If specified, drops existing indexes before creating new ones

    .EXAMPLE
    Add-FGGroupMembershipIndexes

    Adds indexes to all existing group membership tables using default names

    .EXAMPLE
    Add-FGGroupMembershipIndexes -DropExisting

    Recreates all indexes (drops existing ones first)

    .NOTES
    - Requires Connect-FGSQLServer to be called first
    - Only creates indexes on tables that exist
    - Indexes are created as NON-CLUSTERED (temporal tables already have clustered PK)
    - Creating indexes can take several minutes on large tables (>100k rows)
    - Indexes significantly improve query performance (3.5 min -> seconds)
    #>

    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $false)]
        [string]$DirectMembersTable = "GraphGroupMembers",

        [Parameter(Mandatory = $false)]
        [string]$OwnersTable = "GraphGroupOwners",

        [Parameter(Mandatory = $false)]
        [string]$EligibleMembersTable = "GraphGroupEligibleMembers",

        [Parameter(Mandatory = $false)]
        [string]$TransitiveMembersTable = "GraphGroupTransitiveMembers",

        [Parameter(Mandatory = $false)]
        [switch]$DropExisting
    )

    # Check SQL connection
    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        Write-Host "`n========================================" -ForegroundColor Cyan
        Write-Host "Adding Performance Indexes" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan

        # Check which tables exist
        $checkTablesSQL = @"
SELECT
    CASE WHEN EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = '$DirectMembersTable') THEN 1 ELSE 0 END AS DirectExists,
    CASE WHEN EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = '$OwnersTable') THEN 1 ELSE 0 END AS OwnersExists,
    CASE WHEN EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = '$EligibleMembersTable') THEN 1 ELSE 0 END AS EligibleExists,
    CASE WHEN EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = '$TransitiveMembersTable') THEN 1 ELSE 0 END AS TransitiveExists
"@
        $checkTablesCmd = $connection.CreateCommand()
        $checkTablesCmd.CommandText = $checkTablesSQL
        $reader = $checkTablesCmd.ExecuteReader()
        $reader.Read()
        $directExists = $reader.GetInt32(0) -eq 1
        $ownersExists = $reader.GetInt32(1) -eq 1
        $eligibleExists = $reader.GetInt32(2) -eq 1
        $transitiveExists = $reader.GetInt32(3) -eq 1
        $reader.Close()

        if (-not $directExists) {
            throw "Table '$DirectMembersTable' does not exist. Run Sync-FGGroupMember first."
        }

        $indexesCreated = 0
        $indexesSkipped = 0

        # Helper function to create index
        $createIndex = {
            param($tableName, $indexName, $columns, $description)

            try {
                # Check if index exists
                $checkIndexSQL = "SELECT COUNT(*) FROM sys.indexes WHERE name = '$indexName' AND object_id = OBJECT_ID('dbo.$tableName')"
                $checkCmd = $connection.CreateCommand()
                $checkCmd.CommandText = $checkIndexSQL
                $indexExists = $checkCmd.ExecuteScalar() -gt 0

                if ($indexExists -and $DropExisting) {
                    Write-Host "  Dropping existing index: $indexName" -ForegroundColor Yellow
                    $dropCmd = $connection.CreateCommand()
                    $dropCmd.CommandText = "DROP INDEX $indexName ON dbo.$tableName"
                    $dropCmd.ExecuteNonQuery() | Out-Null
                    $indexExists = $false
                }

                if ($indexExists) {
                    Write-Host "  ⏭  Skipped (exists): $indexName" -ForegroundColor Gray
                    $script:indexesSkipped++
                } else {
                    Write-Host "  Creating: $indexName" -ForegroundColor White
                    Write-Host "    Purpose: $description" -ForegroundColor Gray
                    Write-Host "    Columns: $columns" -ForegroundColor Gray

                    $createIndexSQL = "CREATE NONCLUSTERED INDEX $indexName ON dbo.$tableName ($columns)"
                    $createCmd = $connection.CreateCommand()
                    $createCmd.CommandText = $createIndexSQL
                    $createCmd.ExecuteNonQuery() | Out-Null

                    Write-Host "  ✅ Created: $indexName" -ForegroundColor Green
                    $script:indexesCreated++
                }
            } catch {
                Write-Host "  ❌ Failed to create $indexName`: $_" -ForegroundColor Red
                throw
            }
        }

        # GraphGroupMembers indexes (CRITICAL for recursive view performance)
        Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Table: $DirectMembersTable" -ForegroundColor Cyan
        Write-Host "  This table is used heavily in recursive membership calculations" -ForegroundColor Gray

        & $createIndex $DirectMembersTable "IX_GroupMembers_GroupId_ValidTo" "groupId, ValidTo" `
            "Optimize: Get all members of a specific group (used in anchor query)"

        & $createIndex $DirectMembersTable "IX_GroupMembers_MemberId_Type_ValidTo" "memberId, memberType, ValidTo" `
            "Optimize: Check if member is a group and get its members (used in recursive part)"

        # GraphGroupOwners indexes
        if ($ownersExists) {
            Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Table: $OwnersTable" -ForegroundColor Cyan

            & $createIndex $OwnersTable "IX_GroupOwners_GroupId_ValidTo" "groupId, ValidTo" `
                "Optimize: Get all owners of a specific group"

            & $createIndex $OwnersTable "IX_GroupOwners_OwnerId_ValidTo" "ownerId, ValidTo" `
                "Optimize: Get all groups owned by a specific user"
        } else {
            Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Skipping $OwnersTable (table doesn't exist)" -ForegroundColor Yellow
        }

        # GraphGroupEligibleMembers indexes
        if ($eligibleExists) {
            Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Table: $EligibleMembersTable" -ForegroundColor Cyan

            & $createIndex $EligibleMembersTable "IX_GroupEligible_GroupId_ValidTo" "groupId, ValidTo" `
                "Optimize: Get all eligible members of a specific group"

            & $createIndex $EligibleMembersTable "IX_GroupEligible_MemberId_ValidTo" "memberId, ValidTo" `
                "Optimize: Get all groups a user is eligible for"
        } else {
            Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Skipping $EligibleMembersTable (table doesn't exist)" -ForegroundColor Yellow
        }

        # GraphGroupTransitiveMembers indexes (optional - we're moving away from this table)
        if ($transitiveExists) {
            Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Table: $TransitiveMembersTable" -ForegroundColor Cyan
            Write-Host "  Note: This table is deprecated - consider using vw_GraphGroupMembersRecursive instead" -ForegroundColor Yellow

            & $createIndex $TransitiveMembersTable "IX_GroupTransitive_GroupId_ValidTo" "groupId, ValidTo" `
                "Optimize: Get all members (direct + indirect) of a specific group"

            & $createIndex $TransitiveMembersTable "IX_GroupTransitive_MemberId_ValidTo" "memberId, ValidTo" `
                "Optimize: Get all groups (direct + indirect) a user is member of"
        } else {
            Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Skipping $TransitiveMembersTable (table doesn't exist - recommended!)" -ForegroundColor Green
        }

        Write-Host "`n========================================" -ForegroundColor Green
        Write-Host "Index Creation Complete!" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "  Indexes Created: $indexesCreated" -ForegroundColor White
        Write-Host "  Indexes Skipped: $indexesSkipped (already existed)" -ForegroundColor Gray
        Write-Host "`nExpected Performance Improvement:" -ForegroundColor Cyan
        Write-Host "  - Recursive view queries: 3+ minutes -> seconds" -ForegroundColor Green
        Write-Host "  - Membership lookups: Much faster" -ForegroundColor Green
        Write-Host "  - View creation: Significantly faster" -ForegroundColor Green
        Write-Host "========================================`n" -ForegroundColor Green

        return @{
            Created = $indexesCreated
            Skipped = $indexesSkipped
        }
    }
}
