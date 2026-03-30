function Sync-FGGroup {
    <#
    .SYNOPSIS
    Syncs Microsoft Graph groups to the Resources table in Azure SQL with temporal versioning.

    .DESCRIPTION
    This function syncs Entra ID groups to the universal resource model:
    - Writes to the Resources table with resourceType='EntraGroup'
    - Core group attributes map to fixed Resources columns
    - All remaining group-specific attributes go into extendedAttributes JSON
    - Automatically creates the SQL table on first run
    - Uses temporal tables for automatic change tracking
    - Syncs all groups or filtered groups to SQL
    - Does NOT sync members (use Sync-FGGroupMember for that)

    .PARAMETER Attributes
    Array of group attribute names to fetch from Graph. If not specified, uses default set of common attributes.
    To add to defaults, use -AdditionalAttributes instead.
    All fetched attributes beyond the core Resources columns are stored in extendedAttributes JSON.

    .PARAMETER AdditionalAttributes
    Array of additional attributes to fetch from Graph on top of the defaults.
    These are included in the extendedAttributes JSON column.

    .PARAMETER Filter
    Optional OData filter to limit which groups to sync (e.g., "securityEnabled eq true")

    .PARAMETER RecreateTable
    If specified, drops and recreates the table (WARNING: loses all history!)

    .PARAMETER BatchSize
    Number of groups to process at once. Default: 100

    .EXAMPLE
    Sync-FGGroup

    Syncs all groups with default attributes to the Resources table

    .EXAMPLE
    Sync-FGGroup -AdditionalAttributes @('classification', 'preferredLanguage')

    Syncs groups with default attributes PLUS additional ones (stored in extendedAttributes JSON)

    .EXAMPLE
    Sync-FGGroup -Filter "securityEnabled eq true"

    Syncs only security groups to the Resources table

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

    # Check Graph access token
    if (-not $global:AccessToken) {
        throw "No Graph access token found. Please run Get-FGAccessToken first."
    }

    try {

    # Resolve SystemId for EntraID
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Resolving system ID for EntraID..." -ForegroundColor Cyan
    $SystemId = Sync-FGSystem -SystemType 'EntraID' -DisplayName 'Entra ID' -TenantId $Global:TenantId
    if (-not $SystemId) {
        throw "Could not find or create a system record for EntraID. Please run Initialize-FGSystemTables first."
    }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Using system ID: $SystemId" -ForegroundColor Green

    # Define default Graph attributes to fetch
    $defaultAttributes = @(
        # Identity
        'id'
        'displayName'
        'description'
        'mail'
        'mailNickname'

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

    # Determine which Graph attributes to fetch
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

    # Fixed Resources table columns (not driven by Graph attributes)
    $columns = @{
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

    # Core columns that map directly from Graph attributes (not put into extendedAttributes)
    $coreColumnNames = @('id', 'displayName', 'description', 'createdDateTime', 'mail', 'visibility')

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

    # Fetch administrative unit memberships
    $auMemberMap = @{}
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Fetching administrative unit memberships..." -ForegroundColor Cyan
    try {
        $auUri = "https://graph.microsoft.com/v1.0/directory/administrativeUnits?`$select=id,displayName"
        $allAUs = Invoke-FGGetRequest -URI $auUri
        if ($allAUs) {
            foreach ($au in $allAUs) {
                $membersUri = "https://graph.microsoft.com/v1.0/directory/administrativeUnits/$($au.id)/members?`$select=id"
                $members = Invoke-FGGetRequest -URI $membersUri
                if ($members) {
                    foreach ($member in $members) {
                        if (-not $auMemberMap.ContainsKey($member.id)) {
                            $auMemberMap[$member.id] = @()
                        }
                        $auMemberMap[$member.id] += $au.displayName
                    }
                }
            }
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Found $($allAUs.Count) administrative unit(s) with $($auMemberMap.Count) member assignments" -ForegroundColor Green
        }
        else {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] No administrative units found" -ForegroundColor Gray
        }
    }
    catch {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] Failed to fetch administrative units: $_. The administrativeUnits extended attribute will be empty."
    }

    # Sync to SQL using bulk operations (HIGH PERFORMANCE)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing groups to SQL Server..." -ForegroundColor Cyan

    # Build DataTable for bulk operations
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Preparing data for bulk sync..." -ForegroundColor Gray

    # The DataTable attributes are the Resources column names
    $dataTableAttributes = @($columns.Keys)

    # Build the list of all Graph attributes that should go into extendedAttributes
    # (everything fetched from Graph that isn't a core Resources column)
    $extendedAttributeNames = @($graphAttributes | Where-Object { $_ -notin $coreColumnNames })

    # Define value resolvers for columns that don't map directly from Graph
    $valueResolvers = @{
        'systemId' = {
            param($obj)
            $SystemId
        }
        'resourceType' = {
            param($obj)
            'EntraGroup'
        }
        'enabled' = {
            param($obj)
            $true
        }
        'externalId' = {
            param($obj)
            $null
        }
        'extendedAttributes' = {
            param($obj)
            $extended = @{}

            # Add all non-core Graph attributes to extendedAttributes
            foreach ($attrName in $extendedAttributeNames) {
                $val = $obj.$attrName
                if ($null -ne $val -and $val -ne '') {
                    $extended[$attrName] = $val
                }
            }

            # Add administrative units
            if ($auMemberMap.ContainsKey($obj.id)) {
                $extended['administrativeUnits'] = ($auMemberMap[$obj.id] -join ', ')
            }

            # Compute groupTypeCalculated
            $groupTypesValue = $obj.groupTypes
            $isUnified = $groupTypesValue -is [Array] -and $groupTypesValue -contains 'Unified'
            $hasTeam = $obj.resourceProvisioningOptions -is [Array] -and $obj.resourceProvisioningOptions -contains 'Team'
            $isDynamic = -not [string]::IsNullOrWhiteSpace($obj.membershipRule)

            if ($isUnified -and $hasTeam) { $baseType = 'Unified Group with Team' }
            elseif ($isUnified) { $baseType = 'Unified Group without Team' }
            elseif (-not $obj.securityEnabled) { $baseType = 'Distribution Group' }
            elseif (-not $obj.mailEnabled) { $baseType = 'Security Group' }
            else { $baseType = 'Mail Enabled Security Group' }

            if ($isDynamic) { $groupType = "Dynamic $baseType" } else { $groupType = $baseType }
            $extended['groupTypeCalculated'] = $groupType

            if ($extended.Count -gt 0) { $extended | ConvertTo-Json -Compress -Depth 10 } else { $null }
        }
    }

    $dataTable = New-FGDataTableFromGraphObjects -GraphObjects $allGroups -Columns $columns -Attributes $dataTableAttributes -ValueResolvers $valueResolvers

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

            # Scoped delete: only remove EntraGroup resources that no longer exist in Graph
            # Cannot use Invoke-FGSQLBulkDelete because it would delete ALL non-matching Resources (BusinessRoles, DirectoryRoles, etc.)
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking for deleted groups..." -ForegroundColor Cyan

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
            # Delete resources of type EntraGroup that aren't in source
            $deleteCmd.CommandText = "DELETE FROM dbo.[$TableName] WHERE resourceType = 'EntraGroup' AND id NOT IN (SELECT id FROM #SyncSourceIds)"
            $deletedCount = $deleteCmd.ExecuteNonQuery()
            $deleteCmd.CommandText = "DROP TABLE #SyncSourceIds"
            $deleteCmd.ExecuteNonQuery() | Out-Null
            $deleteCmd.Dispose()
            $idTable.Dispose()

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
    Write-Host "Resource Type:   EntraGroup" -ForegroundColor White
    Write-Host "System ID:       $SystemId" -ForegroundColor White
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
