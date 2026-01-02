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

    .PARAMETER UseDefaults
    Use the default set of attributes (16 common user properties). This is the default behavior.

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
    - Connect-FGSQLServerFromAzure or Connect-FGSQLServer to be called first
    - Valid Graph access token (Get-FGAccessToken)
    #>

    [CmdletBinding(DefaultParameterSetName = 'Default')]
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

    # Check SQL connection
    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServerFromAzure or Connect-FGSQLServer first."
    }

    # Check Graph access token
    if (-not $global:AccessToken) {
        throw "No Graph access token found. Please run Get-FGAccessToken first."
    }

    # Define default attributes
    $defaultAttributes = @(
        # Identity
        'id'
        'userPrincipalName'
        'onPremisesSamAccountName'
        'employeeId'
        'mail'

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

        # Manager & Sign-in (these need special handling)
        'managerId'  # We'll fetch this from manager/id
        'lastSignInDateTime'  # From signInActivity
    )

    # Determine which attributes to use
    if ($PSCmdlet.ParameterSetName -eq 'Custom') {
        # User provided custom attributes
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Using custom attributes: $($Attributes.Count) attributes" -ForegroundColor Cyan

        # Ensure 'id' is always included as it's the primary key
        if ($Attributes -notcontains 'id') {
            $Attributes = @('id') + $Attributes
            Write-Verbose "Added 'id' to attributes (required for primary key)"
        }
    }
    else {
        # Use defaults + any additional
        $Attributes = $defaultAttributes

        if ($AdditionalAttributes) {
            # Add additional attributes that aren't already in defaults
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
            # Default to NVARCHAR(MAX) for unknown attributes
            $sqlType = 'NVARCHAR(MAX)'
            Write-Warning "Unknown attribute '$attr', using NVARCHAR(MAX). Consider adding to type map."
        }
        $columns[$attr] = $sqlType
    }

    # Check if table exists
    try {
        Invoke-FGSQLCommand -ScriptBlock {
            param($connection)

            $checkTableCmd = $connection.CreateCommand()
            $checkTableCmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = '$TableName'"
            $tableExists = [int]$checkTableCmd.ExecuteScalar() -gt 0

            if ($tableExists -and -not $RecreateTable) {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Table '$TableName' already exists. Checking schema..." -ForegroundColor Cyan

                # Get existing columns from the table
                $getColumnsCmd = $connection.CreateCommand()
                $getColumnsCmd.CommandText = "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = '$TableName' AND TABLE_SCHEMA = 'dbo'"
                $reader = $getColumnsCmd.ExecuteReader()
                try {
                    $existingColumns = @()
                    while ($reader.Read()) {
                        $existingColumns += $reader.GetString(0)
                    }
                }
                finally {
                    $reader.Close()
                }

                # Find missing columns (exclude system columns ValidFrom, ValidTo)
                $missingColumns = @()
                foreach ($attr in $Attributes) {
                    if ($existingColumns -notcontains $attr) {
                        $missingColumns += $attr
                    }
                }

                if ($missingColumns.Count -gt 0) {
                    Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Found $($missingColumns.Count) new attribute(s) to add: $($missingColumns -join ', ')" -ForegroundColor Yellow
                    Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Adding columns to existing table..." -ForegroundColor Cyan

                    # Need to disable system versioning to alter the table
                    $disableVersioningCmd = $connection.CreateCommand()
                    $disableVersioningCmd.CommandText = "ALTER TABLE dbo.$TableName SET (SYSTEM_VERSIONING = OFF);"
                    $disableVersioningCmd.ExecuteNonQuery() | Out-Null

                    # Add each missing column
                    foreach ($attr in $missingColumns) {
                        $sqlType = $columns[$attr]
                        Write-Host "    [$(Get-Date -Format 'HH:mm:ss')] Adding column: $attr ($sqlType)" -ForegroundColor Gray

                        $addColumnCmd = $connection.CreateCommand()
                        $addColumnCmd.CommandText = "ALTER TABLE dbo.$TableName ADD $attr $sqlType NULL;"
                        $addColumnCmd.ExecuteNonQuery() | Out-Null

                        # Also add to history table
                        $addHistoryColumnCmd = $connection.CreateCommand()
                        $addHistoryColumnCmd.CommandText = "ALTER TABLE dbo.${TableName}History ADD $attr $sqlType NULL;"
                        $addHistoryColumnCmd.ExecuteNonQuery() | Out-Null
                    }

                    # Re-enable system versioning
                    $enableVersioningCmd = $connection.CreateCommand()
                    $enableVersioningCmd.CommandText = "ALTER TABLE dbo.$TableName SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.${TableName}History));"
                    $enableVersioningCmd.ExecuteNonQuery() | Out-Null

                    Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Schema updated successfully" -ForegroundColor Green
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
                    throw "Operation cancelled by user"
                }
            }
            else {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Table '$TableName' does not exist. Will be created..." -ForegroundColor Cyan
            }
        }

        # Create table if needed (outside the SQL command since Initialize-FGSQLTable manages its own connection)
        Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            $checkTableCmd = $connection.CreateCommand()
            $checkTableCmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = '$TableName'"
            $tableExists = [int]$checkTableCmd.ExecuteScalar() -gt 0
            return $tableExists
        } | Out-Null

        $tableStillExists = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            $checkTableCmd = $connection.CreateCommand()
            $checkTableCmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = '$TableName'"
            return ([int]$checkTableCmd.ExecuteScalar() -gt 0)
        }

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
        $uri += ",signInActivity"  # signInActivity is a property, not an expand
    }

    if ($expands.Count -gt 0) {
        $uri += "&`$expand=$($expands -join ',')"
    }

    if ($Filter) {
        $uri += "&`$filter=$Filter"
    }

    # Fetch all users
    $allUsers = @()
    $userCount = 0
    $graphStartTime = Get-Date

    do {
        try {
            $response = Invoke-RestMethod -Uri $uri -Headers @{Authorization = "Bearer $global:AccessToken"} -Method Get
            $allUsers += $response.value
            $userCount += $response.value.Count
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Fetched $userCount users..." -ForegroundColor Gray
            $uri = $response.'@odata.nextLink'
        }
        catch {
            throw "Failed to fetch users from Graph: $_"
        }
    } while ($uri)

    $graphElapsed = (Get-Date) - $graphStartTime
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Total users fetched: $($allUsers.Count) (took $([math]::Round($graphElapsed.TotalSeconds, 1))s)" -ForegroundColor Green

    if ($allUsers.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No users found to sync."
        return
    }

    # Sync to SQL
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing users to SQL Server..." -ForegroundColor Cyan

    # Build MERGE statement once (outside the loop for performance)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Preparing MERGE statement..." -ForegroundColor Gray
    $columnList = $Attributes -join ', '
    $sourceColumns = ($Attributes | ForEach-Object { "@$_ AS $_" }) -join ', '
    $updateSetStatements = ($Attributes | Where-Object { $_ -ne 'id' } | ForEach-Object { "$_ = source.$_" }) -join ', '
    $insertColumns = $Attributes -join ', '
    $insertValues = ($Attributes | ForEach-Object { "source.$_" }) -join ', '

    # Build condition to detect changes (skip update if nothing changed)
    # Use proper type-aware comparisons
    $changeConditions = ($Attributes | Where-Object { $_ -ne 'id' } | ForEach-Object {
        $attr = $_
        $sqlType = $graphToSqlTypeMap[$attr]

        if ($sqlType -eq 'UNIQUEIDENTIFIER') {
            # GUID comparison - use IS DISTINCT FROM (SQL Server doesn't have this, so we need NULL handling)
            "((target.$attr IS NULL AND source.$attr IS NOT NULL) OR (target.$attr IS NOT NULL AND source.$attr IS NULL) OR (target.$attr <> source.$attr))"
        }
        elseif ($sqlType -eq 'BIT') {
            # Boolean comparison
            "((target.$attr IS NULL AND source.$attr IS NOT NULL) OR (target.$attr IS NOT NULL AND source.$attr IS NULL) OR (target.$attr <> source.$attr))"
        }
        elseif ($sqlType -like 'DATETIME%') {
            # DateTime comparison
            "((target.$attr IS NULL AND source.$attr IS NOT NULL) OR (target.$attr IS NOT NULL AND source.$attr IS NULL) OR (target.$attr <> source.$attr))"
        }
        else {
            # String comparison with proper NULL handling
            "((target.$attr IS NULL AND source.$attr IS NOT NULL) OR (target.$attr IS NOT NULL AND source.$attr IS NULL) OR (target.$attr <> source.$attr))"
        }
    }) -join ' OR '

    $mergeSQL = @"
MERGE dbo.$TableName AS target
USING (SELECT $sourceColumns) AS source
ON target.id = source.id
WHEN MATCHED AND ($changeConditions) THEN
    UPDATE SET $updateSetStatements
WHEN NOT MATCHED THEN
    INSERT ($insertColumns)
    VALUES ($insertValues);
"@

    $syncResult = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Database connection established" -ForegroundColor Gray

        # Start a transaction for better performance
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Starting transaction..." -ForegroundColor Gray
        $transaction = $connection.BeginTransaction()

        $syncedCount = 0
        $errorCount = 0
        $syncStartTime = Get-Date

        try {
            # Create command once and reuse it
            $cmd = $connection.CreateCommand()
            $cmd.Transaction = $transaction
            $cmd.CommandText = $mergeSQL

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Inserting/updating $($allUsers.Count) users..." -ForegroundColor Cyan

            foreach ($user in $allUsers) {
                try {
                    # Clear parameters from previous iteration
                    $cmd.Parameters.Clear()

                    # Add parameters
                    foreach ($attr in $Attributes) {
                        # Handle special attributes that come from different Graph properties
                        if ($attr -eq 'managerId') {
                            # Manager ID comes from expanded manager object
                            if ($user.manager -and $user.manager.id) {
                                $cmd.Parameters.AddWithValue("@$attr", [Guid]$user.manager.id) | Out-Null
                            }
                            else {
                                $cmd.Parameters.AddWithValue("@$attr", [DBNull]::Value) | Out-Null
                            }
                            continue
                        }
                        elseif ($attr -eq 'lastSignInDateTime') {
                            # Last sign-in comes from signInActivity object
                            if ($user.signInActivity -and $user.signInActivity.lastSignInDateTime) {
                                $cmd.Parameters.AddWithValue("@$attr", [DateTime]$user.signInActivity.lastSignInDateTime) | Out-Null
                            }
                            else {
                                $cmd.Parameters.AddWithValue("@$attr", [DBNull]::Value) | Out-Null
                            }
                            continue
                        }

                        # Regular attributes
                        $value = $user.$attr

                        # Handle standard data type conversions
                        if ($null -eq $value) {
                            $cmd.Parameters.AddWithValue("@$attr", [DBNull]::Value) | Out-Null
                        }
                        elseif ($attr -eq 'id') {
                            # Only 'id' is a GUID (managerId is handled separately above)
                            $cmd.Parameters.AddWithValue("@$attr", [Guid]$value) | Out-Null
                        }
                        elseif ($attr -like '*Enabled' -or $attr -like '*Synced') {
                            # Convert boolean
                            if ($null -ne $value) {
                                $cmd.Parameters.AddWithValue("@$attr", [bool]$value) | Out-Null
                            }
                            else {
                                $cmd.Parameters.AddWithValue("@$attr", [DBNull]::Value) | Out-Null
                            }
                        }
                        elseif ($attr -like '*DateTime') {
                            # Convert datetime
                            if ($value) {
                                $cmd.Parameters.AddWithValue("@$attr", [DateTime]$value) | Out-Null
                            }
                            else {
                                $cmd.Parameters.AddWithValue("@$attr", [DBNull]::Value) | Out-Null
                            }
                        }
                        elseif ($attr -eq 'businessPhones' -and $value -is [array]) {
                            # Convert array to comma-separated string
                            $cmd.Parameters.AddWithValue("@$attr", ($value -join ', ')) | Out-Null
                        }
                        else {
                            $cmd.Parameters.AddWithValue("@$attr", $value.ToString()) | Out-Null
                        }
                    }

                    $cmd.ExecuteNonQuery() | Out-Null
                    $syncedCount++

                    if ($syncedCount % 100 -eq 0) {
                        $elapsed = (Get-Date) - $syncStartTime
                        $rate = [math]::Round($syncedCount / $elapsed.TotalSeconds, 1)
                        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Progress: $syncedCount/$($allUsers.Count) users ($rate users/sec)" -ForegroundColor Gray
                    }
                }
                catch {
                    Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] Failed to sync user $($user.userPrincipalName): $_"
                    $errorCount++
                }
            }

            # Commit the transaction
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Committing transaction..." -ForegroundColor Cyan
            $transaction.Commit()
            $syncElapsed = (Get-Date) - $syncStartTime
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Transaction committed successfully (took $([math]::Round($syncElapsed.TotalSeconds, 1))s)" -ForegroundColor Green

            # Handle deletions - remove users from SQL that no longer exist in Graph
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking for deleted users..." -ForegroundColor Cyan
            $graphUserIds = ($allUsers | ForEach-Object { "'$($_.id)'" }) -join ','

            $deleteSQL = @"
DELETE FROM dbo.$TableName
WHERE id NOT IN ($graphUserIds)
"@

            $deletedCount = 0
            try {
                $deleteCmd = $connection.CreateCommand()
                $deleteCmd.CommandText = $deleteSQL
                $deletedCount = $deleteCmd.ExecuteNonQuery()

                if ($deletedCount -gt 0) {
                    Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedCount users that no longer exist in Graph" -ForegroundColor Yellow
                }
                else {
                    Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] No deleted users found" -ForegroundColor Green
                }
            }
            catch {
                Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] Failed to delete removed users: $_"
            }

            # Cleanup
            $cmd.Dispose()
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
            if ($cmd) {
                $cmd.Dispose()
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

    return @{
        TableName = $TableName
        TotalUsers = $allUsers.Count
        SyncedCount = $syncedCount
        DeletedCount = $deletedCount
        ErrorCount = $errorCount
        Attributes = $Attributes
    }
}
