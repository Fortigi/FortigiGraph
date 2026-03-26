function Sync-FGAccessPackage {
    <#
    .SYNOPSIS
    Syncs Microsoft Graph access packages to Azure SQL with automatic schema detection and temporal versioning.

    .DESCRIPTION
    This function makes syncing Graph access packages to SQL incredibly easy:
    - Specify the access package attributes you want to sync
    - Automatically creates the SQL table on first run
    - Auto-detects SQL data types from Graph schema
    - Uses temporal tables for automatic change tracking
    - Syncs all access packages or filtered packages to SQL

    .PARAMETER Attributes
    Array of access package attribute names to sync. If not specified, uses default set of common attributes.
    To add to defaults, use -AdditionalAttributes instead.

    .PARAMETER AdditionalAttributes
    Array of additional attributes to sync on top of the defaults.

    .PARAMETER Filter
    Optional OData filter to limit which access packages to sync (e.g., "isHidden eq false")

    .PARAMETER RecreateTable
    If specified, drops and recreates the table (WARNING: loses all history!)

    .PARAMETER BatchSize
    Number of access packages to process at once. Default: 100

    .EXAMPLE
    Sync-FGAccessPackage

    Syncs all access packages with default attributes (id, displayName, description, catalogId, etc.)

    .EXAMPLE
    Sync-FGAccessPackage -AdditionalAttributes @('isRoleScopesVisible')

    Syncs access packages with default attributes PLUS the additional ones specified

    .EXAMPLE
    Sync-FGAccessPackage -Filter "isHidden eq false"

    Syncs only visible access packages

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Valid Graph access token (Get-FGAccessToken)
    - Appropriate permissions: EntitlementManagement.Read.All
    #>

    [CmdletBinding(DefaultParameterSetName = 'Default')]
    [Alias("Sync-AccessPackage")]
    Param(
        [Parameter(Mandatory = $false, ParameterSetName = 'Custom')]
        [string[]]$Attributes,

        [Parameter(Mandatory = $false, ParameterSetName = 'Default')]
        [string[]]$AdditionalAttributes,

        [Parameter(Mandatory = $false)]
        [string]$Filter,

        [Parameter(Mandatory = $false)]
        [switch]$RecreateTable,

        [Parameter(Mandatory = $false)]
        [int]$BatchSize = 100
    )

    # Hardcoded table name
    $TableName = "Resources"

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

    # Check Graph access token
    if (-not $global:AccessToken) {
        throw "No Graph access token found. Please run Get-FGAccessToken first."
    }

    # Define default attributes
    $defaultAttributes = @(
        # Identity
        'id'
        'displayName'
        'description'

        # Resource type (fixed value for access packages)
        'resourceType'

        # Relationships
        'catalogId'

        # State & Visibility
        'isHidden'
        'isRoleScopesVisible'

        # Metadata
        'createdDateTime'
        'modifiedDateTime'
    )

    # Determine which attributes to use
    if ($PSCmdlet.ParameterSetName -eq 'Custom') {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Using custom attributes: $($Attributes.Count) attributes" -ForegroundColor Cyan

        # Ensure 'id' is always included
        if ($Attributes -notcontains 'id') {
            $Attributes = @('id') + $Attributes
            Write-Verbose "Added 'id' to attributes (required for primary key)"
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
        'displayName' = 'NVARCHAR(255)'
        'description' = 'NVARCHAR(1024)'
        'resourceType' = 'NVARCHAR(50)'
        'catalogId' = 'UNIQUEIDENTIFIER'
        'isHidden' = 'BIT'
        'isRoleScopesVisible' = 'BIT'
        'createdDateTime' = 'DATETIME2'
        'modifiedDateTime' = 'DATETIME2'
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
        $tableReady = Initialize-FGSyncTable -TableName $TableName -Columns $columns -RecreateTable:$RecreateTable
        if ($tableReady -eq $false) { return }
    }
    catch {
        throw "Failed to check/create table: $_"
    }

    # Build Graph API request
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Fetching access packages from Microsoft Graph..." -ForegroundColor Cyan

    # Exclude local-only attributes from Graph API $select (resourceType is set locally, not a Graph property)
    $localOnlyAttributes = @('resourceType')
    $graphAttributes = $Attributes | Where-Object { $_ -notin $localOnlyAttributes }
    $selectProperties = $graphAttributes -join ','
    $uri = "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackages?`$select=$selectProperties"

    if ($Filter) {
        $uri += "&`$filter=$Filter"
    }

    # Fetch all access packages using Invoke-FGGetRequest (handles token validation and pagination)
    $graphStartTime = Get-Date

    try {
        $allPackages = Invoke-FGGetRequest -URI $uri
        if (-not $allPackages) {
            $allPackages = @()
        }
    }
    catch {
        throw "Failed to fetch access packages from Graph: $_"
    }

    $graphElapsed = (Get-Date) - $graphStartTime
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Total access packages fetched: $($allPackages.Count) (took $([math]::Round($graphElapsed.TotalSeconds, 1))s)" -ForegroundColor Green

    if ($allPackages.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No access packages found to sync."
        return
    }

    # Sync to SQL using bulk operations (HIGH PERFORMANCE)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing access packages to SQL Server..." -ForegroundColor Cyan

    # Build DataTable for bulk operations
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Preparing data for bulk sync..." -ForegroundColor Gray

    $valueResolvers = @{
        'resourceType' = { param($obj) 'BusinessRole' }
    }

    $dataTable = New-FGDataTableFromGraphObjects -GraphObjects $allPackages -Columns $columns -Attributes $Attributes -ValueResolvers $valueResolvers

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
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($dataTable.Rows.Count) access packages..." -ForegroundColor Cyan

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
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merge completed: $($mergeResult.Inserted) inserted, $($mergeResult.Updated) updated ($rate packages/sec)" -ForegroundColor Green

            # Scoped delete: only remove BusinessRole resources that no longer exist in Graph
            # Cannot use Invoke-FGSQLBulkDelete because it would delete ALL non-matching Resources (groups, roles, etc.)
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking for deleted access packages..." -ForegroundColor Cyan

            $deleteCmd = $connection.CreateCommand()
            $deleteCmd.Transaction = $transaction
            $deleteCmd.CommandTimeout = 120
            # Create temp table with source IDs
            $deleteCmd.CommandText = "CREATE TABLE #SyncSourceIds (id UNIQUEIDENTIFIER PRIMARY KEY)"
            $deleteCmd.ExecuteNonQuery() | Out-Null
            # Bulk copy source IDs to temp table
            $idTable = New-Object System.Data.DataTable
            [void]$idTable.Columns.Add("id", [System.Guid])
            foreach ($row in $dataTable.Rows) {
                [void]$idTable.Rows.Add($row["id"])
            }
            $bulkCopy = New-Object System.Data.SqlClient.SqlBulkCopy($connection, [System.Data.SqlClient.SqlBulkCopyOptions]::Default, $transaction)
            $bulkCopy.DestinationTableName = "#SyncSourceIds"
            $bulkCopy.WriteToServer($idTable)
            $bulkCopy.Close()
            # Delete resources of type BusinessRole that aren't in source
            $deleteCmd.CommandText = "DELETE FROM dbo.[$TableName] WHERE resourceType = 'BusinessRole' AND id NOT IN (SELECT id FROM #SyncSourceIds)"
            $deletedCount = $deleteCmd.ExecuteNonQuery()
            $deleteCmd.CommandText = "DROP TABLE #SyncSourceIds"
            $deleteCmd.ExecuteNonQuery() | Out-Null
            $deleteCmd.Dispose()
            $idTable.Dispose()

            if ($deletedCount -gt 0) {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedCount access packages that no longer exist in Graph" -ForegroundColor Yellow
            }
            else {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] No deleted access packages found" -ForegroundColor Green
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
    Write-Host "Total Packages:      $($allPackages.Count)" -ForegroundColor White
    Write-Host "Synced:              $syncedCount" -ForegroundColor White
    Write-Host "Deleted:             $deletedCount" -ForegroundColor White
    Write-Host "Errors:              $errorCount" -ForegroundColor White
    Write-Host "Attributes:          $($Attributes.Count)" -ForegroundColor White
    Write-Host "`nAll changes are automatically tracked in ${TableName}_History" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Green

    # Set sync status for logging
    $syncRecordCount = $allPackages.Count
    $syncStatus = if ($errorCount -gt 0) { "PartialSuccess" } else { "Success" }

    } # End try
    catch {
        $syncErrorMessage = $_.Exception.Message
        $syncStatus = "Failed"
        throw
    }
    finally {
        # Write sync log entry
        Write-FGSyncLog -SyncType "AccessPackages" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName $TableName
    }

    return @{
        TableName = $TableName
        TotalPackages = $allPackages.Count
        SyncedCount = $syncedCount
        DeletedCount = $deletedCount
        ErrorCount = $errorCount
        Attributes = $Attributes
    }
}
