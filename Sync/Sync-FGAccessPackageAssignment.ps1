function Sync-FGAccessPackageAssignment {
    <#
    .SYNOPSIS
    Syncs Microsoft Graph access package assignments to Azure SQL with automatic schema detection and temporal versioning.

    .DESCRIPTION
    This function makes syncing Graph access package assignments (user-to-package relationships) to SQL incredibly easy:
    - Specify the assignment attributes you want to sync
    - Automatically creates the SQL table on first run
    - Auto-detects SQL data types from Graph schema
    - Uses temporal tables for automatic change tracking
    - Syncs all assignments or filtered assignments to SQL
    - Tracks which users have which access packages

    .PARAMETER Attributes
    Array of assignment attribute names to sync. If not specified, uses default set of common attributes.
    To add to defaults, use -AdditionalAttributes instead.

    .PARAMETER AdditionalAttributes
    Array of additional attributes to sync on top of the defaults.

    .PARAMETER Filter
    Optional OData filter to limit which assignments to sync (e.g., "state eq 'delivered'")

    .PARAMETER TableName
    Name of the SQL table to create/sync to. Default: "GraphAccessPackageAssignments"

    .PARAMETER RecreateTable
    If specified, drops and recreates the table (WARNING: loses all history!)

    .PARAMETER BatchSize
    Number of assignments to process at once. Default: 100

    .EXAMPLE
    Sync-FGAccessPackageAssignment

    Syncs all access package assignments with default attributes

    .EXAMPLE
    Sync-FGAccessPackageAssignment -Filter "state eq 'delivered'"

    Syncs only active/delivered assignments

    .EXAMPLE
    Sync-FGAccessPackageAssignment -AdditionalAttributes @('isExtended')

    Syncs assignments with default attributes PLUS the additional ones specified

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Valid Graph access token (Get-FGAccessToken)
    - Appropriate permissions: EntitlementManagement.Read.All
    - This function expands the 'target' navigation property to get targetId
    #>

    [CmdletBinding(DefaultParameterSetName = 'Default')]
    [Alias("Sync-AccessPackageAssignment")]
    Param(
        [Parameter(Mandatory = $false, ParameterSetName = 'Custom')]
        [string[]]$Attributes,

        [Parameter(Mandatory = $false, ParameterSetName = 'Default')]
        [string[]]$AdditionalAttributes,

        [Parameter(Mandatory = $false)]
        [string]$Filter,

        [Parameter(Mandatory = $false)]
        [string]$TableName = "GraphAccessPackageAssignments",

        [Parameter(Mandatory = $false)]
        [switch]$RecreateTable,

        [Parameter(Mandatory = $false)]
        [int]$BatchSize = 100
    )

    # Check SQL connection
    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    # Check Graph access token
    if (-not $global:AccessToken) {
        throw "No Graph access token found. Please run Get-FGAccessToken first."
    }

    # Define default attributes
    $defaultAttributes = @(
        # Identity
        'id'
        'accessPackageId'

        # Target - we'll extract targetId from the expanded target object
        'targetId'  # This is not a direct property, we'll extract it

        # State
        'assignmentStatus'
        'assignmentState'

        # Schedule
        'schedule'  # Complex object with startDateTime, expiration, recurrence

    )

    # Determine which attributes to use
    if ($PSCmdlet.ParameterSetName -eq 'Custom') {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Using custom attributes: $($Attributes.Count) attributes" -ForegroundColor Cyan

        # Ensure required keys are always included
        if ($Attributes -notcontains 'id') {
            $Attributes = @('id') + $Attributes
            Write-Verbose "Added 'id' to attributes (required for primary key)"
        }
        if ($Attributes -notcontains 'targetId') {
            $Attributes += 'targetId'
            Write-Verbose "Added 'targetId' to attributes (required for relationship)"
        }
    }
    else {
        $Attributes = $defaultAttributes

        if ($AdditionalAttributes) {
            foreach ($attr in $AdditionalAttributes) {
                if ($Attributes -notcontains $attr) {
                    $Attributes += $attr
                }
            }
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Using default attributes + $($AdditionalAttributes.Count) additional: Total $($Attributes.Count) attributes" -ForegroundColor Cyan
        }
        else {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Using default attributes: $($Attributes.Count) attributes" -ForegroundColor Cyan
        }
    }

    # Map Graph attribute types to SQL types
    $graphToSqlTypeMap = @{
        'id' = 'UNIQUEIDENTIFIER'
        'accessPackageId' = 'UNIQUEIDENTIFIER'
        'targetId' = 'UNIQUEIDENTIFIER'
        'assignmentState' = 'NVARCHAR(50)'
        'assignmentStatus' = 'NVARCHAR(50)'
        'schedule' = 'NVARCHAR(MAX)'  # JSON representation
        'createdDateTime' = 'DATETIME2'
        'isExtended' = 'BIT'
        'expiredDateTime' = 'DATETIME2'
    }

    # Build column definitions
    $columns = @{}
    foreach ($attr in $Attributes) {
        $sqlType = $graphToSqlTypeMap[$attr]
        if (-not $sqlType) {
            $sqlType = 'NVARCHAR(MAX)'
            Write-Warning "Unknown attribute '$attr', using NVARCHAR(MAX). Consider adding to type map."
        }
        $columns[$attr] = $sqlType
    }

    # Check if table exists and handle schema
    try {
        $tableExists = Test-FGSQLTableExists -TableName $TableName

        if ($tableExists -and -not $RecreateTable) {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Table '$TableName' already exists. Checking schema..." -ForegroundColor Cyan

            # Get existing columns
            $existingColumns = Get-FGSQLTableSchema -TableName $TableName

            # Find missing columns
            $missingColumns = @{}
            foreach ($attr in $Attributes) {
                if ($existingColumns -notcontains $attr) {
                    $missingColumns[$attr] = $columns[$attr]
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
                return
            }
        }
        else {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Table '$TableName' does not exist. Will be created..." -ForegroundColor Cyan
        }

        # Create table if needed
        $tableStillExists = Test-FGSQLTableExists -TableName $TableName

        if (-not $tableStillExists -or $RecreateTable) {
            Initialize-FGSQLTable -TableName $TableName -Columns $columns -PrimaryKey 'id' -DropIfExists:$RecreateTable
        }
    }
    catch {
        throw "Failed to check/create table: $_"
    }

    # Build Graph API request
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Fetching access package assignments from Microsoft Graph..." -ForegroundColor Cyan

    # We need to expand 'target' to get the targetId (user id)
    # Note: We can't use $select with $expand in this case, so we'll get all properties and filter client-side
    $uri = "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackageAssignments?`$expand=target"

    if ($Filter) {
        $uri += "&`$filter=$Filter"
    }

    # Fetch all assignments using Invoke-FGGetRequest (handles token validation and pagination)
    $graphStartTime = Get-Date

    try {
        $allAssignments = Invoke-FGGetRequest -URI $uri
        if (-not $allAssignments) {
            $allAssignments = @()
        }
    }
    catch {
        throw "Failed to fetch access package assignments from Graph: $_"
    }

    $graphElapsed = (Get-Date) - $graphStartTime
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Total assignments fetched: $($allAssignments.Count) (took $([math]::Round($graphElapsed.TotalSeconds, 1))s)" -ForegroundColor Green

    if ($allAssignments.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No access package assignments found to sync."
        return
    }

    # Check for NULL or duplicate IDs in source data (Graph API pagination bug)
    $nullIds = $allAssignments | Where-Object { -not $_.id -or [string]::IsNullOrWhiteSpace($_.id) }
    if ($nullIds) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] CRITICAL: Found $($nullIds.Count) assignments with NULL/empty IDs!"
        Write-Warning "This will cause MERGE to fail. Removing NULL ID assignments from sync."
        $allAssignments = $allAssignments | Where-Object { $_.id -and -not [string]::IsNullOrWhiteSpace($_.id) }
    }

    $groupedById = $allAssignments | Group-Object -Property id
    $duplicates = $groupedById | Where-Object { $_.Count -gt 1 }

    if ($duplicates) {
        Write-Warning "Source data contains duplicate assignment IDs (Graph API pagination bug)"
        Write-Warning "Total assignments: $($allAssignments.Count), Unique IDs: $($groupedById.Count), Duplicates: $($allAssignments.Count - $groupedById.Count)"

        # Deduplicate by keeping only the first occurrence of each ID
        $allAssignments = $groupedById | ForEach-Object { $_.Group[0] }
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] After deduplication: $($allAssignments.Count) unique assignments" -ForegroundColor Green
    }

    # Sync to SQL using bulk operations (HIGH PERFORMANCE)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing access package assignments to SQL Server..." -ForegroundColor Cyan

    # Build DataTable for bulk operations
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Preparing data for bulk sync..." -ForegroundColor Gray

    $dataTable = New-Object System.Data.DataTable

    # Add columns based on attributes and their SQL types
    foreach ($attr in $Attributes) {
        $sqlType = $columns[$attr]
        $dotNetType = switch -Regex ($sqlType) {
            'UNIQUEIDENTIFIER' { [guid] }
            'BIT' { [bool] }
            'DATETIME2' { [datetime] }
            'INT' { [int] }
            'BIGINT' { [long] }
            default { [string] }
        }
        $dataTable.Columns.Add($attr, $dotNetType) | Out-Null
    }

    # Populate DataTable with assignment data
    foreach ($assignment in $allAssignments) {
        $row = $dataTable.NewRow()

        foreach ($attr in $Attributes) {
            # Special handling for targetId - extract from expanded target object
            if ($attr -eq 'targetId') {
                $value = $assignment.target.id
            }
            else {
                $value = $assignment.$attr
            }

            # Convert value to appropriate type or DBNull
            if ($null -eq $value -or $value -eq '') {
                $row[$attr] = [DBNull]::Value
            }
            else {
                # Type conversion based on column type
                $sqlType = $columns[$attr]
                try {
                    switch -Regex ($sqlType) {
                        'UNIQUEIDENTIFIER' { $row[$attr] = [guid]$value }
                        'BIT' { $row[$attr] = [bool]$value }
                        'DATETIME2' { $row[$attr] = [datetime]$value }
                        'INT' { $row[$attr] = [int]$value }
                        'BIGINT' { $row[$attr] = [long]$value }
                        default {
                            # For complex objects like schedule, convert to JSON
                            if ($value -is [PSCustomObject] -or $value -is [Hashtable]) {
                                $row[$attr] = [string]($value | ConvertTo-Json -Compress -Depth 10)
                            }
                            # For arrays, join them
                            elseif ($value -is [Array]) {
                                $row[$attr] = [string]($value -join ',')
                            }
                            else {
                                $row[$attr] = [string]$value
                            }
                        }
                    }
                }
                catch {
                    # If conversion fails, use DBNull
                    $row[$attr] = [DBNull]::Value
                }
            }
        }

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
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($dataTable.Rows.Count) access package assignments..." -ForegroundColor Cyan

            # Use bulk MERGE operation - much faster than row-by-row
            $mergeResult = Invoke-FGSQLBulkMerge `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName $TableName `
                -DataTable $dataTable `
                -KeyColumns @('id')

            $syncedCount = $mergeResult.Inserted + $mergeResult.Updated

            $syncElapsed = (Get-Date) - $syncStartTime
            $rate = if ($syncElapsed.TotalSeconds -gt 0) { [math]::Round($syncedCount / $syncElapsed.TotalSeconds, 1) } else { 0 }
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merge completed: $($mergeResult.Inserted) inserted, $($mergeResult.Updated) updated ($rate assignments/sec)" -ForegroundColor Green

            # Handle deletions using bulk delete (avoids massive IN clause)
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking for deleted assignments..." -ForegroundColor Cyan

            $deletedCount = Invoke-FGSQLBulkDelete `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName $TableName `
                -DataTable $dataTable `
                -KeyColumns @('id')

            if ($deletedCount -gt 0) {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedCount assignments that no longer exist in Graph" -ForegroundColor Yellow
            }
            else {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] No deleted assignments found" -ForegroundColor Green
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
    Write-Host "Table:               $TableName" -ForegroundColor White
    Write-Host "Total Assignments:   $($allAssignments.Count)" -ForegroundColor White
    Write-Host "Synced:              $syncedCount" -ForegroundColor White
    Write-Host "Deleted:             $deletedCount" -ForegroundColor White
    Write-Host "Errors:              $errorCount" -ForegroundColor White
    Write-Host "Attributes:          $($Attributes.Count)" -ForegroundColor White
    Write-Host "`nAll changes are automatically tracked in ${TableName}_History" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Green

    return @{
        TableName = $TableName
        TotalAssignments = $allAssignments.Count
        SyncedCount = $syncedCount
        DeletedCount = $deletedCount
        ErrorCount = $errorCount
        Attributes = $Attributes
    }
}
