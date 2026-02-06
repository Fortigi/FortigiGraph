function Sync-FGUser {
    <#
    .SYNOPSIS
    Syncs Microsoft Graph users to Azure SQL with automatic schema detection and temporal versioning.

    .DESCRIPTION
    This function makes syncing Graph users to SQL incredibly easy:
    - Specify the user attributes you want to sync
    - Automatically creates the SQL table on first run
    - Auto-detects SQL data types from Graph schema
    - Uses temporal tables for automatic change tracking
    - Syncs all users or filtered users to SQL

    .PARAMETER Attributes
    Array of user attribute names to sync. If not specified, uses default set of common attributes.
    To add to defaults, use -AdditionalAttributes instead.

    .PARAMETER AdditionalAttributes
    Array of additional attributes to sync on top of the defaults.

    .PARAMETER Filter
    Optional OData filter to limit which users to sync (e.g., "accountEnabled eq true")

    .PARAMETER TableName
    Name of the SQL table to create/sync to. Default: "GraphUsers"

    .PARAMETER RecreateTable
    If specified, drops and recreates the table (WARNING: loses all history!)

    .PARAMETER BatchSize
    Number of users to process at once. Default: 100

    .EXAMPLE
    Sync-FGUser

    Syncs all users with default attributes (id, userPrincipalName, displayName, department, etc.)

    .EXAMPLE
    Sync-FGUser -AdditionalAttributes @('officeLocation', 'city', 'state')

    Syncs users with default attributes PLUS the additional ones specified

    .EXAMPLE
    Sync-FGUser -Attributes @('id', 'userPrincipalName', 'mail') -Filter "accountEnabled eq true"

    Syncs only enabled users with custom attributes (overrides defaults)

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Valid Graph access token (Get-FGAccessToken)
    #>

    [CmdletBinding(DefaultParameterSetName = 'Default')]
    [Alias("Sync-User")]
    Param(
        [Parameter(Mandatory = $false, ParameterSetName = 'Custom')]
        [string[]]$Attributes,

        [Parameter(Mandatory = $false, ParameterSetName = 'Default')]
        [string[]]$AdditionalAttributes,

        [Parameter(Mandatory = $false)]
        [string]$Filter,

        [Parameter(Mandatory = $false)]
        [string]$TableName = "GraphUsers",

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
        'userPrincipalName'
        'onPremisesSamAccountName'
        'employeeId'
        'mail'
        'onPremisesDistinguishedName'

        # Status
        'accountEnabled'
        'userType'
        'onPremisesSyncEnabled'

        # Basic Info
        'displayName'
        'givenName'
        'surname'

        # Organization
        'companyName'
        'department'
        'jobTitle'

        # Metadata
        'createdDateTime'
        'employeeHireDate'
        'employeeType'

        # Manager & Sign-in (these need special handling)
        'managerId'  # We'll fetch this from manager/id
        'lastSignInDateTime'  # From signInActivity
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
        'userPrincipalName' = 'NVARCHAR(255)'
        'displayName' = 'NVARCHAR(255)'
        'givenName' = 'NVARCHAR(255)'
        'surname' = 'NVARCHAR(255)'
        'mail' = 'NVARCHAR(255)'
        'mailNickname' = 'NVARCHAR(255)'
        'jobTitle' = 'NVARCHAR(255)'
        'department' = 'NVARCHAR(255)'
        'companyName' = 'NVARCHAR(255)'
        'officeLocation' = 'NVARCHAR(255)'
        'city' = 'NVARCHAR(255)'
        'state' = 'NVARCHAR(255)'
        'country' = 'NVARCHAR(255)'
        'postalCode' = 'NVARCHAR(50)'
        'streetAddress' = 'NVARCHAR(500)'
        'mobilePhone' = 'NVARCHAR(50)'
        'businessPhones' = 'NVARCHAR(500)'
        'employeeId' = 'NVARCHAR(255)'
        'employeeType' = 'NVARCHAR(255)'
        'onPremisesSamAccountName' = 'NVARCHAR(255)'
        'onPremisesDistinguishedName' = 'NVARCHAR(1000)'
        'onPremisesDomainName' = 'NVARCHAR(255)'
        'onPremisesUserPrincipalName' = 'NVARCHAR(255)'
        'onPremisesSyncEnabled' = 'BIT'
        'accountEnabled' = 'BIT'
        'createdDateTime' = 'DATETIME2'
        'lastPasswordChangeDateTime' = 'DATETIME2'
        'lastSignInDateTime' = 'DATETIME2'
        'employeeHireDate' = 'DATETIME2'
        'ageGroup' = 'NVARCHAR(50)'
        'usageLocation' = 'NVARCHAR(10)'
        'preferredLanguage' = 'NVARCHAR(50)'
        'userType' = 'NVARCHAR(50)'
        'managerId' = 'UNIQUEIDENTIFIER'
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
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Fetching users from Microsoft Graph..." -ForegroundColor Cyan

    # Remove special attributes that need expand or separate handling
    $regularAttributes = $Attributes | Where-Object { $_ -notin @('managerId', 'lastSignInDateTime') }
    $needsManager = $Attributes -contains 'managerId'
    $needsSignInActivity = $Attributes -contains 'lastSignInDateTime'

    $selectProperties = $regularAttributes -join ','
    $uri = "https://graph.microsoft.com/v1.0/users?`$select=$selectProperties"

    # Add expands for special properties
    $expands = @()
    if ($needsManager) {
        $expands += 'manager($select=id)'
    }
    if ($needsSignInActivity) {
        $uri += ",signInActivity"
    }

    if ($expands.Count -gt 0) {
        $uri += "&`$expand=$($expands -join ',')"
    }

    if ($Filter) {
        $uri += "&`$filter=$Filter"
    }

    # Fetch all users using Invoke-FGGetRequest (handles token validation and pagination)
    $graphStartTime = Get-Date

    try {
        $allUsers = Invoke-FGGetRequest -URI $uri
        if (-not $allUsers) {
            $allUsers = @()
        }
    }
    catch {
        throw "Failed to fetch users from Graph: $_"
    }

    $graphElapsed = (Get-Date) - $graphStartTime
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Total users fetched: $($allUsers.Count) (took $([math]::Round($graphElapsed.TotalSeconds, 1))s)" -ForegroundColor Green

    if ($allUsers.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No users found to sync."
        return
    }

    # Sync to SQL using bulk operations (HIGH PERFORMANCE)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing users to SQL Server..." -ForegroundColor Cyan

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

    # Populate DataTable with user data
    foreach ($user in $allUsers) {
        $row = $dataTable.NewRow()

        foreach ($attr in $Attributes) {
            $value = $null

            # Handle special attributes that come from different Graph properties
            if ($attr -eq 'managerId') {
                # Manager ID comes from expanded manager object
                if ($user.manager -and $user.manager.id) {
                    $value = [guid]$user.manager.id
                }
            }
            elseif ($attr -eq 'lastSignInDateTime') {
                # Last sign-in comes from signInActivity object
                if ($user.signInActivity -and $user.signInActivity.lastSignInDateTime) {
                    $value = [datetime]$user.signInActivity.lastSignInDateTime
                }
            }
            else {
                # Regular attribute
                $value = $user.$attr
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
                        default { $row[$attr] = [string]$value }
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
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($dataTable.Rows.Count) users..." -ForegroundColor Cyan

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
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merge completed: $($mergeResult.Inserted) inserted, $($mergeResult.Updated) updated ($rate users/sec)" -ForegroundColor Green

            # Handle deletions using bulk delete (avoids massive IN clause)
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking for deleted users..." -ForegroundColor Cyan

            $deletedCount = Invoke-FGSQLBulkDelete `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName $TableName `
                -DataTable $dataTable `
                -KeyColumns @('id')

            if ($deletedCount -gt 0) {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedCount users that no longer exist in Graph" -ForegroundColor Yellow
            }
            else {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] No deleted users found" -ForegroundColor Green
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
    Write-Host "Total Users:     $($allUsers.Count)" -ForegroundColor White
    Write-Host "Synced:          $syncedCount" -ForegroundColor White
    Write-Host "Deleted:         $deletedCount" -ForegroundColor White
    Write-Host "Errors:          $errorCount" -ForegroundColor White
    Write-Host "Attributes:      $($Attributes.Count)" -ForegroundColor White
    Write-Host "`nAll changes are automatically tracked in ${TableName}History" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Green

    # Set sync status for logging
    $syncRecordCount = $allUsers.Count
    $syncStatus = if ($errorCount -gt 0) { "PartialSuccess" } else { "Success" }

    } # End try
    catch {
        $syncErrorMessage = $_.Exception.Message
        $syncStatus = "Failed"
        throw
    }
    finally {
        # Write sync log entry
        Write-FGSyncLog -SyncType "Users" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName $TableName
    }

    return @{
        TableName = $TableName
        TotalUsers = $allUsers.Count
        SyncedCount = $syncedCount
        DeletedCount = $deletedCount
        ErrorCount = $errorCount
        Attributes = $Attributes
    }
}
