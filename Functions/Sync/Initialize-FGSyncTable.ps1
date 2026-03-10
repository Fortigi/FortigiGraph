function Initialize-FGSyncTable {
    <#
    .SYNOPSIS
    Ensures a sync target table exists with the correct schema, creating or evolving it as needed.

    .DESCRIPTION
    Shared helper used by all Sync-FG* functions to handle table lifecycle:
    - Checks if table exists
    - If it exists: detects missing columns and adds them (schema evolution)
    - If it doesn't exist or RecreateTable is set: creates the table via Initialize-FGSQLTable
    - Handles user confirmation for table recreation

    .PARAMETER TableName
    Name of the SQL table to create/sync to.

    .PARAMETER Columns
    Hashtable mapping column names to SQL types (e.g., @{ 'id' = 'UNIQUEIDENTIFIER'; 'displayName' = 'NVARCHAR(255)' }).

    .PARAMETER PrimaryKey
    Name of the primary key column. Default: 'id'

    .PARAMETER CompositePrimaryKey
    Array of column names for composite primary key (overrides PrimaryKey).

    .PARAMETER RecreateTable
    If $true, drops and recreates the table (WARNING: loses all history!).

    .EXAMPLE
    Initialize-FGSyncTable -TableName "GraphUsers" -Columns $columns -RecreateTable:$false

    .EXAMPLE
    Initialize-FGSyncTable -TableName "GraphGroupMembers" -Columns $columns -CompositePrimaryKey @('groupId', 'memberId')
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$TableName,

        [Parameter(Mandatory = $true)]
        [hashtable]$Columns,

        [Parameter(Mandatory = $false)]
        [string]$PrimaryKey = 'id',

        [Parameter(Mandatory = $false)]
        [string[]]$CompositePrimaryKey,

        [Parameter(Mandatory = $false)]
        [bool]$RecreateTable = $false
    )

    $tableExists = Test-FGSQLTableExists -TableName $TableName

    if ($tableExists -and -not $RecreateTable) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Table '$TableName' already exists. Checking schema..." -ForegroundColor Cyan

        # Get existing columns
        $existingColumns = Get-FGSQLTableSchema -TableName $TableName

        # Find missing columns
        $missingColumns = @{}
        foreach ($colName in $Columns.Keys) {
            if ($existingColumns -notcontains $colName) {
                $missingColumns[$colName] = $Columns[$colName]
            }
        }

        if ($missingColumns.Count -gt 0) {
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Found $($missingColumns.Count) new attribute(s) to add: $($missingColumns.Keys -join ', ')" -ForegroundColor Yellow
            Add-FGSQLTableColumn -TableName $TableName -Columns $missingColumns
        }
        else {
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Schema is up to date" -ForegroundColor Green
        }
    }
    elseif ($tableExists -and $RecreateTable) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] Recreating table '$TableName' - all history will be lost!"
        $confirm = Read-Host "Are you sure? (Y/N)"
        if ($confirm -notmatch '^[Yy]') {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Operation cancelled." -ForegroundColor Yellow
            return $false
        }
    }
    else {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Table '$TableName' does not exist. Will be created..." -ForegroundColor Cyan
    }

    # Create table if needed
    $tableStillExists = Test-FGSQLTableExists -TableName $TableName

    if (-not $tableStillExists -or $RecreateTable) {
        $initParams = @{
            TableName = $TableName
            Columns = $Columns
            DropIfExists = $RecreateTable
        }

        if ($CompositePrimaryKey) {
            $initParams.PrimaryKey = $CompositePrimaryKey
        }
        else {
            $initParams.PrimaryKey = $PrimaryKey
        }

        Initialize-FGSQLTable @initParams
    }

    return $true
}
