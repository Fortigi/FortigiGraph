function Sync-FGCatalog {
    <#
    .SYNOPSIS
    Syncs Microsoft Graph access package catalogs to Azure SQL with automatic schema detection and temporal versioning.

    .DESCRIPTION
    This function makes syncing Graph access package catalogs to SQL incredibly easy:
    - Specify the catalog attributes you want to sync
    - Automatically creates the SQL table on first run
    - Auto-detects SQL data types from Graph schema
    - Uses temporal tables for automatic change tracking
    - Syncs all catalogs or filtered catalogs to SQL

    .PARAMETER Attributes
    Array of catalog attribute names to sync. If not specified, uses default set of common attributes.
    To add to defaults, use -AdditionalAttributes instead.

    .PARAMETER AdditionalAttributes
    Array of additional attributes to sync on top of the defaults.

    .PARAMETER Filter
    Optional OData filter to limit which catalogs to sync (e.g., "catalogType eq 'userManaged'")

    .PARAMETER RecreateTable
    If specified, drops and recreates the table (WARNING: loses all history!)

    .PARAMETER BatchSize
    Number of catalogs to process at once. Default: 100

    .EXAMPLE
    Sync-FGCatalog

    Syncs all catalogs with default attributes (id, displayName, description, etc.)

    .EXAMPLE
    Sync-FGCatalog -AdditionalAttributes @('isExternallyVisible')

    Syncs catalogs with default attributes PLUS the additional ones specified

    .EXAMPLE
    Sync-FGCatalog -Filter "catalogType eq 'userManaged'"

    Syncs only user-managed catalogs

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Valid Graph access token (Get-FGAccessToken)
    - Appropriate permissions: EntitlementManagement.Read.All
    #>

    [CmdletBinding(DefaultParameterSetName = 'Default')]
    [Alias("Sync-Catalog")]
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
    $TableName = "GovernanceCatalogs"

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

        # Type & State
        'catalogType'  # userManaged, serviceDefault, serviceManaged
        'isExternallyVisible'

        # Metadata
        'createdDateTime'
        'modifiedDateTime'

        # Advanced
        'catalogStatus'
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
        'catalogType' = 'NVARCHAR(50)'
        'isExternallyVisible' = 'BIT'
        'createdDateTime' = 'DATETIME2'
        'modifiedDateTime' = 'DATETIME2'
        'catalogStatus' = 'NVARCHAR(50)'
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
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Fetching catalogs from Microsoft Graph..." -ForegroundColor Cyan

    $selectProperties = $Attributes -join ','
    $uri = "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackageCatalogs?`$select=$selectProperties"

    if ($Filter) {
        $uri += "&`$filter=$Filter"
    }

    # Fetch all catalogs using Invoke-FGGetRequest (handles token validation and pagination)
    $graphStartTime = Get-Date

    try {
        $allCatalogs = Invoke-FGGetRequest -URI $uri
        if (-not $allCatalogs) {
            $allCatalogs = @()
        }
    }
    catch {
        throw "Failed to fetch catalogs from Graph: $_"
    }

    $graphElapsed = (Get-Date) - $graphStartTime
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Total catalogs fetched: $($allCatalogs.Count) (took $([math]::Round($graphElapsed.TotalSeconds, 1))s)" -ForegroundColor Green

    if ($allCatalogs.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No catalogs found to sync."
        return
    }

    # Sync to SQL using bulk operations (HIGH PERFORMANCE)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing catalogs to SQL Server..." -ForegroundColor Cyan

    # Build DataTable for bulk operations
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Preparing data for bulk sync..." -ForegroundColor Gray

    $dataTable = New-FGDataTableFromGraphObjects -GraphObjects $allCatalogs -Columns $columns -Attributes $Attributes

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
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($dataTable.Rows.Count) catalogs..." -ForegroundColor Cyan

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
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merge completed: $($mergeResult.Inserted) inserted, $($mergeResult.Updated) updated ($rate catalogs/sec)" -ForegroundColor Green

            # Handle deletions using bulk delete (avoids massive IN clause)
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking for deleted catalogs..." -ForegroundColor Cyan

            $deletedCount = Invoke-FGSQLBulkDelete `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName $TableName `
                -DataTable $dataTable `
                -KeyColumns @('id')

            if ($deletedCount -gt 0) {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedCount catalogs that no longer exist in Graph" -ForegroundColor Yellow
            }
            else {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] No deleted catalogs found" -ForegroundColor Green
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
    Write-Host "Table:           $TableName" -ForegroundColor White
    Write-Host "Total Catalogs:  $($allCatalogs.Count)" -ForegroundColor White
    Write-Host "Synced:          $syncedCount" -ForegroundColor White
    Write-Host "Deleted:         $deletedCount" -ForegroundColor White
    Write-Host "Errors:          $errorCount" -ForegroundColor White
    Write-Host "Attributes:      $($Attributes.Count)" -ForegroundColor White
    Write-Host "`nAll changes are automatically tracked in ${TableName}_History" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Green

    # Set sync status for logging
    $syncRecordCount = $allCatalogs.Count
    $syncStatus = if ($errorCount -gt 0) { "PartialSuccess" } else { "Success" }

    } # End try
    catch {
        $syncErrorMessage = $_.Exception.Message
        $syncStatus = "Failed"
        throw
    }
    finally {
        # Write sync log entry
        Write-FGSyncLog -SyncType "Catalogs" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName $TableName
    }

    return @{
        TableName = $TableName
        TotalCatalogs = $allCatalogs.Count
        SyncedCount = $syncedCount
        DeletedCount = $deletedCount
        ErrorCount = $errorCount
        Attributes = $Attributes
    }
}
