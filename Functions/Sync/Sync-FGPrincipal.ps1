function Sync-FGPrincipal {
    <#
    .SYNOPSIS
    Syncs Entra ID users to the Principals table in the universal resource model.

    .DESCRIPTION
    Fetches all users from Entra ID via Microsoft Graph and syncs them to the Principals table.
    Core user attributes are mapped to dedicated columns, while remaining attributes are stored
    as JSON in the extendedAttributes column.

    The function:
    - Auto-detects SystemId via Sync-FGSystem
    - Fetches users from Graph API (same attributes as Sync-FGUser)
    - Maps to Principals schema with principalType='User'
    - Uses bulk merge/delete with scoped delete (only affects this systemId + principalType)
    - Logs sync status via Write-FGSyncLog

    .PARAMETER Filter
    Optional OData filter to limit which users to sync (e.g., "accountEnabled eq true")

    .PARAMETER AdditionalAttributes
    Array of additional Graph user attributes to include in extendedAttributes JSON.

    .PARAMETER SystemId
    Optional system ID to use. If not provided, auto-detects from Systems table where systemType='EntraID'.

    .PARAMETER RecreateTable
    If specified, drops and recreates the Principals table (WARNING: loses all history!)

    .EXAMPLE
    Sync-FGPrincipal

    Syncs all Entra ID users to the Principals table using auto-detected system ID

    .EXAMPLE
    Sync-FGPrincipal -Filter "accountEnabled eq true"

    Syncs only enabled users

    .EXAMPLE
    Sync-FGPrincipal -AdditionalAttributes @('officeLocation', 'city')

    Syncs users with additional attributes stored in extendedAttributes JSON

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Valid Graph access token (Get-FGAccessToken)
    - Initialize-FGSystemTables to have been run
    - Permission: User.Read.All
    #>

    [CmdletBinding()]
    [Alias("Sync-Principal")]
    Param(
        [Parameter(Mandatory = $false)]
        [string]$Filter,

        [Parameter(Mandatory = $false)]
        [string[]]$AdditionalAttributes,

        [Parameter(Mandatory = $false)]
        [int]$SystemId,

        [Parameter(Mandatory = $false)]
        [switch]$RecreateTable
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

    # Resolve SystemId
    if (-not $SystemId) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Auto-detecting system ID for EntraID..." -ForegroundColor Cyan
        $SystemId = Sync-FGSystem -SystemType 'EntraID' -TenantId $Global:TenantId -DisplayName 'Entra ID'
        if (-not $SystemId) {
            throw "Could not find or create a system record for EntraID. Please run Initialize-FGSystemTables first."
        }
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Using system ID: $SystemId" -ForegroundColor Green
    }

    # Ensure Principals table exists
    $principalColumns = @{
        'id'                 = 'UNIQUEIDENTIFIER'
        'systemId'           = 'INT'
        'displayName'        = 'NVARCHAR(500)'
        'email'              = 'NVARCHAR(500)'
        'accountEnabled'     = 'BIT'
        'principalType'      = 'NVARCHAR(50)'
        'externalId'         = 'NVARCHAR(500)'
        'givenName'          = 'NVARCHAR(255)'
        'surname'            = 'NVARCHAR(255)'
        'department'         = 'NVARCHAR(255)'
        'jobTitle'           = 'NVARCHAR(255)'
        'companyName'        = 'NVARCHAR(255)'
        'employeeId'         = 'NVARCHAR(255)'
        'managerId'          = 'UNIQUEIDENTIFIER'
        'createdDateTime'    = 'DATETIME2'
        'extendedAttributes' = 'NVARCHAR(MAX)'
    }

    $tableReady = Initialize-FGSyncTable -TableName "Principals" -Columns $principalColumns -PrimaryKey 'id' -RecreateTable:$RecreateTable
    if ($tableReady -eq $false) { return }

    # Define default attributes to fetch from Graph
    $defaultAttributes = @(
        'id'
        'userPrincipalName'
        'onPremisesSamAccountName'
        'employeeId'
        'mail'
        'onPremisesDistinguishedName'
        'organizationalUnit'
        'administrativeUnits'
        'accountEnabled'
        'userType'
        'onPremisesSyncEnabled'
        'displayName'
        'givenName'
        'surname'
        'companyName'
        'department'
        'jobTitle'
        'createdDateTime'
        'employeeHireDate'
        'employeeType'
        'managerId'
    )

    $allAttributes = $defaultAttributes
    if ($AdditionalAttributes) {
        foreach ($attr in $AdditionalAttributes) {
            if ($allAttributes -notcontains $attr) {
                $allAttributes += $attr
            }
        }
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Using default attributes + $($AdditionalAttributes.Count) additional: Total $($allAttributes.Count) attributes" -ForegroundColor Cyan
    }
    else {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Using default attributes: $($allAttributes.Count) attributes" -ForegroundColor Cyan
    }

    # Build Graph API request
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Fetching users from Microsoft Graph..." -ForegroundColor Cyan

    # Remove special attributes that need expand, separate handling, or are computed
    $regularAttributes = $allAttributes | Where-Object { $_ -notin @('managerId', 'organizationalUnit', 'administrativeUnits') }
    $needsManager = $allAttributes -contains 'managerId'
    $needsOU = $allAttributes -contains 'organizationalUnit'
    $needsAU = $allAttributes -contains 'administrativeUnits'

    # Handle extensionAttribute1-15: Graph returns these under onPremisesExtensionAttributes
    $extensionAttrs = @($regularAttributes | Where-Object { $_ -match '^extensionAttribute\d+$' })
    $regularAttributes = @($regularAttributes | Where-Object { $_ -notmatch '^extensionAttribute\d+$' })
    if ($extensionAttrs.Count -gt 0) {
        if ($regularAttributes -notcontains 'onPremisesExtensionAttributes') {
            $regularAttributes += 'onPremisesExtensionAttributes'
        }
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Extension attributes ($($extensionAttrs -join ', ')) will be read from onPremisesExtensionAttributes" -ForegroundColor Gray
    }

    # Ensure onPremisesDistinguishedName is fetched from Graph if organizationalUnit is requested
    if ($needsOU -and $regularAttributes -notcontains 'onPremisesDistinguishedName') {
        $regularAttributes += 'onPremisesDistinguishedName'
    }

    $selectProperties = $regularAttributes -join ','
    $uri = "https://graph.microsoft.com/v1.0/users?`$select=$selectProperties"

    # Add expands for special properties
    $expands = @()
    if ($needsManager) {
        $expands += 'manager($select=id)'
    }
    if ($expands.Count -gt 0) {
        $uri += "&`$expand=$($expands -join ',')"
    }

    if ($Filter) {
        $uri += "&`$filter=$Filter"
    }

    # Fetch all users
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
        $syncStatus = "Success"
        $syncRecordCount = 0
        return
    }

    # Fetch administrative unit memberships if needed
    $auMemberMap = @{}
    if ($needsAU) {
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
            Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] Failed to fetch administrative units: $_. The 'administrativeUnits' attribute will be empty."
        }
    }

    # Build Principals DataTable
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Preparing principal data..." -ForegroundColor Cyan

    # Core attributes that map to dedicated Principals columns
    $principalAttributes = @('id', 'systemId', 'displayName', 'email', 'accountEnabled', 'principalType', 'externalId', 'givenName', 'surname', 'department', 'jobTitle', 'companyName', 'employeeId', 'managerId', 'createdDateTime', 'extendedAttributes')

    # Attributes that go into extendedAttributes JSON (everything not a core column)
    $coreGraphAttributes = @('id', 'displayName', 'userPrincipalName', 'accountEnabled', 'givenName', 'surname', 'department', 'jobTitle', 'companyName', 'employeeId', 'managerId', 'createdDateTime')

    $principalResolvers = @{
        'systemId' = { param($obj) $SystemId }
        'email' = { param($obj) $obj.userPrincipalName }
        'principalType' = { param($obj) 'User' }
        'externalId' = { param($obj) $obj.userPrincipalName }
        'managerId' = { param($obj) if ($obj.manager -and $obj.manager.id) { [guid]$obj.manager.id } else { $null } }
        'extendedAttributes' = {
            param($obj)
            $extended = @{}

            # Add all non-core attributes to extended
            if ($obj.employeeType) { $extended['employeeType'] = $obj.employeeType }
            if ($obj.userType) { $extended['userType'] = $obj.userType }
            if ($obj.mail) { $extended['mail'] = $obj.mail }
            if ($obj.onPremisesSamAccountName) { $extended['onPremisesSamAccountName'] = $obj.onPremisesSamAccountName }
            if ($null -ne $obj.onPremisesSyncEnabled) { $extended['onPremisesSyncEnabled'] = $obj.onPremisesSyncEnabled }
            if ($obj.onPremisesDistinguishedName) { $extended['onPremisesDistinguishedName'] = $obj.onPremisesDistinguishedName }
            if ($obj.employeeHireDate) { $extended['employeeHireDate'] = $obj.employeeHireDate }

            # Computed: organizationalUnit from DN
            if ($obj.onPremisesDistinguishedName) {
                $dn = $obj.onPremisesDistinguishedName
                $parts = $dn -split '(?<!\\),'
                $ouParts = @($parts | Where-Object { $_ -match '^OU=' } | ForEach-Object { $_ -replace '^OU=', '' })
                if ($ouParts.Count -gt 0) {
                    [array]::Reverse($ouParts)
                    $extended['organizationalUnit'] = ($ouParts -join '/')
                }
            }

            # Computed: administrativeUnits
            if ($auMemberMap.ContainsKey($obj.id)) {
                $extended['administrativeUnits'] = ($auMemberMap[$obj.id] -join ', ')
            }

            # Extension attributes (from onPremisesExtensionAttributes nested object)
            if ($extensionAttrs.Count -gt 0 -and $obj.onPremisesExtensionAttributes) {
                foreach ($extAttr in $extensionAttrs) {
                    $val = $obj.onPremisesExtensionAttributes.$extAttr
                    if ($null -ne $val -and $val -ne '') {
                        $extended[$extAttr] = $val
                    }
                }
            }

            # Any additional attributes that aren't already handled
            if ($AdditionalAttributes) {
                foreach ($attr in $AdditionalAttributes) {
                    if (-not $extended.ContainsKey($attr) -and $attr -notin $coreGraphAttributes -and $attr -notmatch '^extensionAttribute\d+$' -and $null -ne $obj.$attr) {
                        $extended[$attr] = $obj.$attr
                    }
                }
            }

            if ($extended.Count -gt 0) {
                $extended | ConvertTo-Json -Depth 10 -Compress
            } else {
                $null
            }
        }
    }

    $dataTable = New-FGDataTableFromGraphObjects -GraphObjects $allUsers -Columns $principalColumns -Attributes $principalAttributes -ValueResolvers $principalResolvers

    # Sync to SQL
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing principals to SQL Server..." -ForegroundColor Cyan

    $syncResult = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        $transaction = $connection.BeginTransaction()

        try {
            # Bulk merge principals
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($dataTable.Rows.Count) principals..." -ForegroundColor Cyan

            $mergeResult = Invoke-FGSQLBulkMerge `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName "Principals" `
                -DataTable $dataTable `
                -KeyColumns @('id')

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Principals: $($mergeResult.Inserted) inserted, $($mergeResult.Updated) updated" -ForegroundColor Green

            # Scoped delete: only delete principals for this systemId AND principalType='User'
            $deleteCmd = $connection.CreateCommand()
            $deleteCmd.Transaction = $transaction
            $deleteCmd.CommandText = @"
DELETE p FROM dbo.Principals p
WHERE p.principalType = 'User'
  AND p.systemId = @systemId
  AND NOT EXISTS (
    SELECT 1 FROM #BulkMerge_Principals bt
    WHERE bt.id = p.id
  )
"@
            $deleteCmd.Parameters.AddWithValue("@systemId", $SystemId) | Out-Null
            $deletedCount = 0
            try {
                $deletedCount = $deleteCmd.ExecuteNonQuery()
            } catch {
                Write-Verbose "Scoped delete not available (temp table missing): $_"
            }
            $deleteCmd.Dispose()

            if ($deletedCount -gt 0) {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedCount stale principals" -ForegroundColor Yellow
            }

            # Commit transaction
            $transaction.Commit()
            $transaction.Dispose()

            return @{
                Inserted = $mergeResult.Inserted
                Updated = $mergeResult.Updated
                Deleted = $deletedCount
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

    $syncRecordCount = $allUsers.Count

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Principal Sync Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "System ID:         $SystemId" -ForegroundColor White
    Write-Host "Total Users:       $($allUsers.Count)" -ForegroundColor White
    Write-Host "  Inserted:        $($syncResult.Inserted)" -ForegroundColor White
    Write-Host "  Updated:         $($syncResult.Updated)" -ForegroundColor White
    Write-Host "  Deleted:         $($syncResult.Deleted)" -ForegroundColor White
    Write-Host "`nAll changes tracked in Principals temporal table" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Green

    $syncStatus = "Success"

    # Update system last sync time
    Sync-FGSystem -SystemType 'EntraID' -TenantId $Global:TenantId -UpdateLastSync

    return @{
        SystemId = $SystemId
        TotalPrincipals = $allUsers.Count
        Inserted = $syncResult.Inserted
        Updated = $syncResult.Updated
        Deleted = $syncResult.Deleted
    }

    } # End try
    catch {
        $syncErrorMessage = $_.Exception.Message
        $syncStatus = "Failed"
        throw
    }
    finally {
        # Write sync log entry
        Write-FGSyncLog -SyncType "Principals" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName "Principals"
    }
}
