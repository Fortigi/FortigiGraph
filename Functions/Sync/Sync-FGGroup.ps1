function Sync-FGGroup {
    <#
    .SYNOPSIS
    Syncs Microsoft Graph groups to Azure SQL with automatic schema detection and temporal versioning.

    .DESCRIPTION
    This function makes syncing Graph groups to SQL incredibly easy:
    - Specify the group attributes you want to sync
    - Automatically creates the SQL table on first run
    - Auto-detects SQL data types from Graph schema
    - Uses temporal tables for automatic change tracking
    - Syncs all groups or filtered groups to SQL
    - Does NOT sync members (use Sync-FGGroupMember for that)

    .PARAMETER Attributes
    Array of group attribute names to sync. If not specified, uses default set of common attributes.
    To add to defaults, use -AdditionalAttributes instead.

    .PARAMETER AdditionalAttributes
    Array of additional attributes to sync on top of the defaults.

    .PARAMETER Filter
    Optional OData filter to limit which groups to sync (e.g., "securityEnabled eq true")

    .PARAMETER TableName
    Name of the SQL table to create/sync to. Default: "GraphGroups"

    .PARAMETER RecreateTable
    If specified, drops and recreates the table (WARNING: loses all history!)

    .PARAMETER BatchSize
    Number of groups to process at once. Default: 100

    .EXAMPLE
    Sync-FGGroup

    Syncs all groups with default attributes (id, displayName, description, mail, etc.)

    .EXAMPLE
    Sync-FGGroup -AdditionalAttributes @('classification', 'visibility')

    Syncs groups with default attributes PLUS the additional ones specified

    .EXAMPLE
    Sync-FGGroup -Filter "securityEnabled eq true" -TableName "SecurityGroups"

    Syncs only security groups to a custom table name

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Valid Graph access token (Get-FGAccessToken)
    - Does NOT sync group members - those are in a separate many-to-many relationship
    #>

    [CmdletBinding(DefaultParameterSetName = 'Default')]
    [Alias("Sync-Group")]
    Param(
        [Parameter(Mandatory = $false, ParameterSetName = 'Custom')]
        [string[]]$Attributes,

        [Parameter(Mandatory = $false, ParameterSetName = 'Default')]
        [string[]]$AdditionalAttributes,

        [Parameter(Mandatory = $false)]
        [string]$Filter,

        [Parameter(Mandatory = $false)]
        [string]$TableName = "GraphGroups",

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
        'mail'
        'mailNickname'
        'onPremisesDistinguishedName'

        # Type & Security
        'mailEnabled'
        'securityEnabled'
        'groupTypes'  # Array - Unified for M365 groups
        'visibility'  # Public, Private, HiddenMembership

        # Metadata
        'createdDateTime'
        'renewedDateTime'
        'expirationDateTime'

        # Provisioning
        'resourceProvisioningOptions'  # Array - "Team" for Teams-connected groups

        # Advanced
        'isAssignableToRole'
        'membershipRule'
        'membershipRuleProcessingState'

        # On-Premises Sync
        'onPremisesSamAccountName'
        'onPremisesSyncEnabled'
        'onPremisesSecurityIdentifier'
        'onPremisesNetBiosName'
        'onPremisesDomainName'
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
        'mail' = 'NVARCHAR(255)'
        'mailNickname' = 'NVARCHAR(255)'
        'mailEnabled' = 'BIT'
        'securityEnabled' = 'BIT'
        'groupTypes' = 'NVARCHAR(500)'  # Array stored as comma-separated
        'visibility' = 'NVARCHAR(50)'
        'createdDateTime' = 'DATETIME2'
        'renewedDateTime' = 'DATETIME2'
        'expirationDateTime' = 'DATETIME2'
        'deletedDateTime' = 'DATETIME2'
        'isAssignableToRole' = 'BIT'
        'membershipRule' = 'NVARCHAR(MAX)'
        'membershipRuleProcessingState' = 'NVARCHAR(50)'
        'resourceProvisioningOptions' = 'NVARCHAR(500)'
        'classification' = 'NVARCHAR(255)'
        'preferredDataLocation' = 'NVARCHAR(50)'
        'preferredLanguage' = 'NVARCHAR(50)'
        'theme' = 'NVARCHAR(50)'
        'onPremisesSamAccountName' = 'NVARCHAR(255)'
        'onPremisesSyncEnabled' = 'BIT'
        'onPremisesSecurityIdentifier' = 'NVARCHAR(255)'
        'onPremisesNetBiosName' = 'NVARCHAR(255)'
        'onPremisesDomainName' = 'NVARCHAR(255)'
        'onPremisesProvisioningErrors' = 'NVARCHAR(MAX)'
        'proxyAddresses' = 'NVARCHAR(MAX)'
    }

    # Add calculated field (not a Graph attribute, computed during sync)
    $calculatedField = 'groupTypeCalculated'

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
    # Add calculated column
    $columns[$calculatedField] = 'NVARCHAR(100)'

    # Check if table exists and handle schema
    try {
        $tableReady = Initialize-FGSyncTable -TableName $TableName -Columns $columns -RecreateTable:$RecreateTable
        if ($tableReady -eq $false) { return }
    }
    catch {
        throw "Failed to check/create table: $_"
    }

    # Build Graph API request
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Fetching groups from Microsoft Graph..." -ForegroundColor Cyan

    # Ensure attributes needed for groupTypeCalculated are always fetched from Graph
    $graphAttributes = $Attributes
    foreach ($required in @('groupTypes', 'securityEnabled', 'mailEnabled', 'resourceProvisioningOptions', 'membershipRule')) {
        if ($graphAttributes -notcontains $required) {
            $graphAttributes += $required
        }
    }
    $selectProperties = $graphAttributes -join ','
    $uri = "https://graph.microsoft.com/v1.0/groups?`$select=$selectProperties"

    if ($Filter) {
        $uri += "&`$filter=$Filter"
    }

    # Fetch all groups using Invoke-FGGetRequest (handles token validation and pagination)
    $graphStartTime = Get-Date

    try {
        $allGroups = Invoke-FGGetRequest -URI $uri
        if (-not $allGroups) {
            $allGroups = @()
        }
    }
    catch {
        throw "Failed to fetch groups from Graph: $_"
    }

    $graphElapsed = (Get-Date) - $graphStartTime
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Total groups fetched: $($allGroups.Count) (took $([math]::Round($graphElapsed.TotalSeconds, 1))s)" -ForegroundColor Green

    if ($allGroups.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No groups found to sync."
        return
    }

    # Sync to SQL using bulk operations (HIGH PERFORMANCE)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing groups to SQL Server..." -ForegroundColor Cyan

    # Build DataTable for bulk operations
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Preparing data for bulk sync..." -ForegroundColor Gray

    # Include calculated field in the attribute list for DataTable creation
    $allColumns = $Attributes + @($calculatedField)

    # Define a resolver for the calculated groupTypeCalculated field
    $valueResolvers = @{
        $calculatedField = {
            param($obj)
            $groupTypesValue = $obj.groupTypes
            $isUnified = $groupTypesValue -is [Array] -and $groupTypesValue -contains 'Unified'
            $hasTeam = $obj.resourceProvisioningOptions -is [Array] -and $obj.resourceProvisioningOptions -contains 'Team'
            $isDynamic = -not [string]::IsNullOrWhiteSpace($obj.membershipRule)

            if ($isUnified -and $hasTeam) { $baseType = 'Unified Group with Team' }
            elseif ($isUnified) { $baseType = 'Unified Group without Team' }
            elseif (-not $obj.securityEnabled) { $baseType = 'Distribution Group' }
            elseif (-not $obj.mailEnabled) { $baseType = 'Security Group' }
            else { $baseType = 'Mail Enabled Security Group' }

            if ($isDynamic) { "Dynamic $baseType" } else { $baseType }
        }
    }

    $dataTable = New-FGDataTableFromGraphObjects -GraphObjects $allGroups -Columns $columns -Attributes $allColumns -ValueResolvers $valueResolvers

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
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($dataTable.Rows.Count) groups..." -ForegroundColor Cyan

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
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merge completed: $($mergeResult.Inserted) inserted, $($mergeResult.Updated) updated ($rate groups/sec)" -ForegroundColor Green

            # Handle deletions using bulk delete (avoids massive IN clause)
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking for deleted groups..." -ForegroundColor Cyan

            $deletedCount = Invoke-FGSQLBulkDelete `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName $TableName `
                -DataTable $dataTable `
                -KeyColumns @('id')

            if ($deletedCount -gt 0) {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedCount groups that no longer exist in Graph" -ForegroundColor Yellow
            }
            else {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] No deleted groups found" -ForegroundColor Green
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
    Write-Host "Total Groups:    $($allGroups.Count)" -ForegroundColor White
    Write-Host "Synced:          $syncedCount" -ForegroundColor White
    Write-Host "Deleted:         $deletedCount" -ForegroundColor White
    Write-Host "Errors:          $errorCount" -ForegroundColor White
    Write-Host "Attributes:      $($Attributes.Count)" -ForegroundColor White
    Write-Host "`nAll changes are automatically tracked in ${TableName}History" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Green

    # Set sync status for logging
    $syncRecordCount = $allGroups.Count
    $syncStatus = if ($errorCount -gt 0) { "PartialSuccess" } else { "Success" }

    } # End try
    catch {
        $syncErrorMessage = $_.Exception.Message
        $syncStatus = "Failed"
        throw
    }
    finally {
        # Write sync log entry
        Write-FGSyncLog -SyncType "Groups" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName $TableName
    }

    return @{
        TableName = $TableName
        TotalGroups = $allGroups.Count
        SyncedCount = $syncedCount
        DeletedCount = $deletedCount
        ErrorCount = $errorCount
        Attributes = $Attributes
    }
}
