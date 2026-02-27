function Sync-FGAccessPackageAssignmentPolicy {
    <#
    .SYNOPSIS
    Syncs Microsoft Graph access package assignment policies to Azure SQL with automatic schema detection and temporal versioning.

    .DESCRIPTION
    This function syncs access package assignment policies which define how users get access:
    - Automatic assignment based on rules (e.g., all users in a department)
    - Request-based assignment with approval workflows
    - Direct admin assignment

    Policies control who can request access, whether approval is needed, and automatic assignment rules.
    This enables analysis of which assignments are automatic vs manually requested.

    .PARAMETER Attributes
    Array of policy attribute names to sync. If not specified, uses default set of common attributes.
    To add to defaults, use -AdditionalAttributes instead.

    .PARAMETER AdditionalAttributes
    Array of additional attributes to sync on top of the defaults.

    .PARAMETER Filter
    Optional OData filter to limit which policies to sync

    .PARAMETER TableName
    Name of the SQL table to create/sync to. Default: "GraphAccessPackageAssignmentPolicies"

    .PARAMETER RecreateTable
    If specified, drops and recreates the table (WARNING: loses all history!)

    .PARAMETER BatchSize
    Number of policies to process at once. Default: 100

    .EXAMPLE
    Sync-FGAccessPackageAssignmentPolicy

    Syncs all access package assignment policies with default attributes

    .EXAMPLE
    Sync-FGAccessPackageAssignmentPolicy -TableName "APPolicies"

    Syncs to a custom table name

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Valid Graph access token (Get-FGAccessToken)
    - Appropriate permissions: EntitlementManagement.Read.All
    - Policies define automatic vs request-based assignment rules
    #>

    [CmdletBinding(DefaultParameterSetName = 'Default')]
    [Alias("Sync-AccessPackageAssignmentPolicy")]
    Param(
        [Parameter(Mandatory = $false, ParameterSetName = 'Custom')]
        [string[]]$Attributes,

        [Parameter(Mandatory = $false, ParameterSetName = 'Default')]
        [string[]]$AdditionalAttributes,

        [Parameter(Mandatory = $false)]
        [string]$Filter,

        [Parameter(Mandatory = $false)]
        [string]$TableName = "GraphAccessPackageAssignmentPolicies",

        [Parameter(Mandatory = $false)]
        [switch]$RecreateTable,

        [Parameter(Mandatory = $false)]
        [int]$BatchSize = 100
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

    # Define default attributes
    $defaultAttributes = @(
        # Identity
        'id'
        'displayName'
        'description'

        # Relationships
        'accessPackageId'

        # Request settings
        'canExtend'
        'durationInDays'

        # Auto-assignment settings (complex object from Graph, stored as JSON)
        'automaticRequestSettings'

        # Derived: true only when automaticRequestSettings.requestAccessForAllowedTargets = true
        # Auto-remove-only policies (requestAccessForAllowedTargets = false) do NOT count as auto-add
        'hasAutoAddRule'

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
        'accessPackageId' = 'UNIQUEIDENTIFIER'
        'canExtend' = 'BIT'
        'durationInDays' = 'INT'
        'automaticRequestSettings' = 'NVARCHAR(MAX)'
        'hasAutoAddRule' = 'BIT'
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
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Fetching access package assignment policies from Microsoft Graph..." -ForegroundColor Cyan

    # Exclude derived attributes from $select (they're computed client-side, not Graph properties)
    $derivedAttributes = @('hasAutoAddRule')
    $graphAttributes = $Attributes | Where-Object { $_ -notin $derivedAttributes }
    $selectProperties = $graphAttributes -join ','
    $uri = "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackageAssignmentPolicies?`$select=$selectProperties"

    if ($Filter) {
        $uri += "&`$filter=$Filter"
    }

    # Fetch all policies using Invoke-FGGetRequest (handles token validation and pagination)
    $graphStartTime = Get-Date

    try {
        $allPolicies = Invoke-FGGetRequest -URI $uri
        if (-not $allPolicies) {
            $allPolicies = @()
        }
    }
    catch {
        throw "Failed to fetch assignment policies from Graph: $_"
    }

    $graphElapsed = (Get-Date) - $graphStartTime
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Total policies fetched: $($allPolicies.Count) (took $([math]::Round($graphElapsed.TotalSeconds, 1))s)" -ForegroundColor Green

    if ($allPolicies.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No assignment policies found to sync."
        return
    }

    # Sync to SQL using bulk operations (HIGH PERFORMANCE)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing assignment policies to SQL Server..." -ForegroundColor Cyan

    # Build DataTable for bulk operations
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Preparing data for bulk sync..." -ForegroundColor Gray

    $valueResolvers = @{
        'automaticRequestSettings' = { param($obj) if ($obj.automaticRequestSettings) { $obj.automaticRequestSettings | ConvertTo-Json -Compress -Depth 10 } else { $null } }
        'hasAutoAddRule' = {
            param($obj)
            $autoSettings = $obj.automaticRequestSettings
            if (-not $autoSettings) { return $false }

            # Check requestAccessForAllowedTargets — handle boolean and string representations
            $val = $autoSettings.requestAccessForAllowedTargets
            if ($val -eq $true -or $val -eq 'true' -or $val -eq 'True') { return $true }

            # If automaticRequestSettings exists as a non-empty object but requestAccessForAllowedTargets
            # is missing/null, this is still an auto-assignment policy (IGA-created policies may
            # omit requestAccessForAllowedTargets entirely while having gracePeriodBeforeAccessRemoval etc.)
            # Check if the object has any properties beyond @odata annotations
            $props = $autoSettings.PSObject.Properties | Where-Object { $_.Name -notlike '@odata*' }
            if ($props -and -not $val -and $val -ne $false -and $val -ne 'false') {
                return $true
            }

            return $false
        }
    }

    $dataTable = New-FGDataTableFromGraphObjects -GraphObjects $allPolicies -Columns $columns -Attributes $Attributes -ValueResolvers $valueResolvers

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
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($dataTable.Rows.Count) assignment policies..." -ForegroundColor Cyan

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
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merge completed: $($mergeResult.Inserted) inserted, $($mergeResult.Updated) updated ($rate policies/sec)" -ForegroundColor Green

            # Handle deletions using bulk delete
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking for deleted policies..." -ForegroundColor Cyan

            $deletedCount = Invoke-FGSQLBulkDelete `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName $TableName `
                -DataTable $dataTable `
                -KeyColumns @('id')

            if ($deletedCount -gt 0) {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedCount policies that no longer exist in Graph" -ForegroundColor Yellow
            }
            else {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] No deleted policies found" -ForegroundColor Green
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
    Write-Host "Total Policies:      $($allPolicies.Count)" -ForegroundColor White
    Write-Host "Synced:              $syncedCount" -ForegroundColor White
    Write-Host "Deleted:             $deletedCount" -ForegroundColor White
    Write-Host "Errors:              $errorCount" -ForegroundColor White
    Write-Host "Attributes:          $($Attributes.Count)" -ForegroundColor White
    Write-Host "`nAll changes are automatically tracked in ${TableName}_History" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Green

    # Set sync status for logging
    $syncRecordCount = $allPolicies.Count
    $syncStatus = if ($errorCount -gt 0) { "PartialSuccess" } else { "Success" }

    } # End try
    catch {
        $syncErrorMessage = $_.Exception.Message
        $syncStatus = "Failed"
        throw
    }
    finally {
        # Write sync log entry
        Write-FGSyncLog -SyncType "AccessPackageAssignmentPolicies" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName $TableName
    }

    return @{
        TableName = $TableName
        TotalPolicies = $allPolicies.Count
        SyncedCount = $syncedCount
        DeletedCount = $deletedCount
        ErrorCount = $errorCount
        Attributes = $Attributes
    }
}
