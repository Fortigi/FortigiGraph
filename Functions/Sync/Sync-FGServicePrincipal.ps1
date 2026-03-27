function Sync-FGServicePrincipal {
    <#
    .SYNOPSIS
    Syncs Entra ID service principals to the Principals table in the universal resource model.

    .DESCRIPTION
    Fetches service principals (managed identities, workload identities, AI agents, app registrations)
    from Entra ID via Microsoft Graph and syncs them to the Principals table.
    Core attributes are mapped to dedicated columns, while remaining attributes are stored
    as JSON in the extendedAttributes column.

    The function:
    - Auto-detects SystemId via Sync-FGSystem
    - Fetches service principals from Graph API
    - Determines principalType from SP data: ManagedIdentity, AIAgent, or ServicePrincipal
    - Maps to Principals schema with principalType determined per record
    - Uses bulk merge/delete with scoped delete (only affects this systemId + SP principal types)
    - Logs sync status via Write-FGSyncLog

    .PARAMETER Filter
    Optional OData filter to limit which service principals to sync.
    Defaults to "accountEnabled eq true". Set to "" to include disabled service principals.

    .PARAMETER AINamePatterns
    Additional regex patterns (beyond the built-in set) to classify a service principal as AIAgent
    based on its displayName.

    .PARAMETER ExcludeFirstPartyMicrosoft
    If specified, skips service principals where appOwnerOrganizationId equals
    'f8cdef31-a31e-4b4a-93e4-5f571e91255a' (Microsoft's tenant ID). This filters out
    built-in Microsoft first-party service principals that are not owned by your organization.

    .PARAMETER SystemId
    Optional system ID to use. If not provided, auto-detects from Systems table where systemType='EntraID'.

    .PARAMETER RecreateTable
    If specified, drops and recreates the Principals table (WARNING: loses all history!)

    .EXAMPLE
    Sync-FGServicePrincipal

    Syncs all enabled Entra ID service principals to the Principals table using auto-detected system ID.

    .EXAMPLE
    Sync-FGServicePrincipal -Filter ""

    Syncs all service principals including disabled ones.

    .EXAMPLE
    Sync-FGServicePrincipal -ExcludeFirstPartyMicrosoft

    Syncs only service principals owned by your organization, excluding built-in Microsoft SPs.

    .EXAMPLE
    Sync-FGServicePrincipal -AINamePatterns @('(?i)my-custom-agent', '(?i)internal-bot')

    Syncs service principals with additional AI agent name pattern matching.

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Valid Graph access token (Get-FGAccessToken)
    - Initialize-FGSystemTables to have been run
    - Permission: Application.Read.All
    #>

    [CmdletBinding()]
    [Alias("Sync-ServicePrincipal")]
    Param(
        [Parameter(Mandatory = $false)]
        [string]$Filter = "accountEnabled eq true",

        [Parameter(Mandatory = $false)]
        [string[]]$AINamePatterns,

        [Parameter(Mandatory = $false)]
        [switch]$ExcludeFirstPartyMicrosoft,

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

    # Microsoft's tenant ID — used to identify first-party Microsoft service principals
    $MicrosoftTenantId = 'f8cdef31-a31e-4b4a-93e4-5f571e91255a'

    # Built-in AI agent tags (any SP tagged with these is classified as AIAgent)
    $aiTags = @('CopilotStudio', 'PowerVirtualAgents', 'AzureOpenAI', 'CognitiveServices')

    # Built-in AI agent name regex pattern
    $builtInAIPattern = '(?i)(copilot|openai|cognitive[\s-]service|azure[\s-]ai|language[\s-]model|chat\s*gpt|gpt-?\d|\bbot\b|virtual[\s-]agent|ai[\s-]hub|azure[\s-]ml)'

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

    # Build Graph API request
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Fetching service principals from Microsoft Graph..." -ForegroundColor Cyan

    $selectProperties = 'id,displayName,accountEnabled,createdDateTime,servicePrincipalType,appId,appOwnerOrganizationId,tags,description,notes,homepage'
    $uri = "https://graph.microsoft.com/v1.0/servicePrincipals?`$select=$selectProperties"

    if ($Filter) {
        $uri += "&`$filter=$Filter"
    }

    # Fetch all service principals
    $graphStartTime = Get-Date

    try {
        $allSPs = Invoke-FGGetRequest -URI $uri
        if (-not $allSPs) {
            $allSPs = @()
        }
    }
    catch {
        throw "Failed to fetch service principals from Graph: $_"
    }

    $graphElapsed = (Get-Date) - $graphStartTime
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Total service principals fetched: $($allSPs.Count) (took $([math]::Round($graphElapsed.TotalSeconds, 1))s)" -ForegroundColor Green

    # Optionally filter out first-party Microsoft service principals
    if ($ExcludeFirstPartyMicrosoft) {
        $beforeCount = $allSPs.Count
        $allSPs = @($allSPs | Where-Object { $_.appOwnerOrganizationId -ne $MicrosoftTenantId })
        $filteredCount = $beforeCount - $allSPs.Count
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Excluded $filteredCount first-party Microsoft service principal(s). Remaining: $($allSPs.Count)" -ForegroundColor Cyan
    }

    if ($allSPs.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No service principals found to sync."
        $syncStatus = "Success"
        $syncRecordCount = 0
        return
    }

    # Build Principals DataTable
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Preparing service principal data..." -ForegroundColor Cyan

    # Core attributes that map to dedicated Principals columns
    $principalAttributes = @('id', 'systemId', 'displayName', 'email', 'accountEnabled', 'principalType', 'externalId', 'givenName', 'surname', 'department', 'jobTitle', 'companyName', 'employeeId', 'managerId', 'createdDateTime', 'extendedAttributes')

    $principalResolvers = @{
        'systemId' = { param($obj) $SystemId }
        'email' = { param($obj) $obj.appId }
        'principalType' = {
            param($obj)
            if ($obj.servicePrincipalType -eq 'ManagedIdentity') {
                $pType = 'ManagedIdentity'
            }
            else {
                # Check AI agent tags
                $spTags = @()
                if ($obj.tags) { $spTags = @($obj.tags) }
                $isAIByTag = ($spTags | Where-Object { $aiTags -contains $_ }).Count -gt 0

                # Check AI agent name patterns (built-in + custom)
                $isAIByName = $obj.displayName -match $builtInAIPattern
                if (-not $isAIByName -and $AINamePatterns) {
                    foreach ($pattern in $AINamePatterns) {
                        if ($obj.displayName -match $pattern) {
                            $isAIByName = $true
                            break
                        }
                    }
                }

                if ($isAIByTag -or $isAIByName) {
                    $pType = 'AIAgent'
                }
                else {
                    $pType = 'ServicePrincipal'
                }
            }
            $pType
        }
        'externalId' = { param($obj) $obj.appId }
        'givenName' = { param($obj) $null }
        'surname' = { param($obj) $null }
        'department' = { param($obj) $null }
        'jobTitle' = { param($obj) $null }
        'companyName' = { param($obj) $null }
        'employeeId' = { param($obj) $null }
        'managerId' = { param($obj) $null }
        'extendedAttributes' = {
            param($obj)
            $extended = @{}

            if ($obj.appId) { $extended['appId'] = $obj.appId }
            if ($obj.servicePrincipalType) { $extended['servicePrincipalType'] = $obj.servicePrincipalType }
            if ($obj.appOwnerOrganizationId) { $extended['appOwnerOrganizationId'] = $obj.appOwnerOrganizationId }

            # Tags as JSON array
            $spTags = @()
            if ($obj.tags) { $spTags = @($obj.tags) }
            $extended['tags'] = $spTags

            if ($obj.description) { $extended['description'] = $obj.description }
            if ($obj.notes) { $extended['notes'] = $obj.notes }
            if ($obj.homepage) { $extended['homepage'] = $obj.homepage }

            if ($extended.Count -gt 0) {
                $extended | ConvertTo-Json -Depth 10 -Compress
            } else {
                $null
            }
        }
    }

    $dataTable = New-FGDataTableFromGraphObjects -GraphObjects $allSPs -Columns $principalColumns -Attributes $principalAttributes -ValueResolvers $principalResolvers

    # Sync to SQL
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing service principals to SQL Server..." -ForegroundColor Cyan

    $syncResult = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        $transaction = $connection.BeginTransaction()

        try {
            # Bulk merge service principals
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($dataTable.Rows.Count) service principals..." -ForegroundColor Cyan

            $mergeResult = Invoke-FGSQLBulkMerge `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName "Principals" `
                -DataTable $dataTable `
                -KeyColumns @('id')

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Service Principals: $($mergeResult.Inserted) inserted, $($mergeResult.Updated) updated" -ForegroundColor Green

            # Scoped delete: only delete SP-type principals for this systemId that are no longer present
            $deleteCmd = $connection.CreateCommand()
            $deleteCmd.Transaction = $transaction
            $deleteCmd.CommandText = @"
DELETE p FROM dbo.Principals p
WHERE p.principalType IN ('ServicePrincipal', 'ManagedIdentity', 'WorkloadIdentity', 'AIAgent')
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
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedCount stale service principals" -ForegroundColor Yellow
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

    $syncRecordCount = $allSPs.Count

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Service Principal Sync Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "System ID:                $SystemId" -ForegroundColor White
    Write-Host "Total Service Principals: $($allSPs.Count)" -ForegroundColor White
    Write-Host "  Inserted:               $($syncResult.Inserted)" -ForegroundColor White
    Write-Host "  Updated:                $($syncResult.Updated)" -ForegroundColor White
    Write-Host "  Deleted:                $($syncResult.Deleted)" -ForegroundColor White
    Write-Host "`nAll changes tracked in Principals temporal table" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Green

    $syncStatus = "Success"

    # Update system last sync time
    Sync-FGSystem -SystemType 'EntraID' -TenantId $Global:TenantId -UpdateLastSync

    return @{
        SystemId = $SystemId
        TotalPrincipals = $allSPs.Count
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
        Write-FGSyncLog -SyncType "ServicePrincipals" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName "Principals"
    }
}
