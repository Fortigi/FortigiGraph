function Start-FGSync {
    <#
.SYNOPSIS
    Syncs Microsoft Graph data to Azure SQL with comprehensive configuration options.

.DESCRIPTION
    This function provides production-ready synchronization that:
- Validates SQL Server exists (creates if needed on first run)
- Connects to Azure and Microsoft Graph
- Syncs all configured entity types (users, groups, memberships, access packages)
- Creates helpful analysis views
- Uses the same secure config file as integration tests
- Reads sync configuration from config file (Sync section)

.PARAMETER ConfigFile
Path to the configuration file (same format as test config)
Config file can include optional "Sync" section to configure what to sync

.PARAMETER SkipServerValidation
Skip validation of SQL Server existence (assumes it exists)

.PARAMETER SyncUsers
Sync users to SQL. Default: Read from config (Sync.Users.Enabled) or $true
Command-line parameter overrides config file setting

.PARAMETER SyncGroups
Sync groups to SQL. Default: Read from config (Sync.Groups.Enabled) or $true
Command-line parameter overrides config file setting

.PARAMETER SyncGroupMembers
Sync direct group memberships. Default: Read from config (Sync.GroupMembers.Enabled) or $true
Command-line parameter overrides config file setting

.PARAMETER SyncGroupTransitiveMembers
Sync transitive/nested group memberships. Default: Read from config (Sync.GroupTransitiveMembers.Enabled) or $true
Command-line parameter overrides config file setting

.PARAMETER SyncGroupEligibleMembers
Sync eligible/PIM group memberships. Default: Read from config (Sync.GroupEligibleMembers.Enabled) or $true
Command-line parameter overrides config file setting

.PARAMETER SyncGroupOwners
Sync group ownership relationships. Default: Read from config (Sync.GroupOwners.Enabled) or $true
Command-line parameter overrides config file setting

.PARAMETER CreateViews
Create/update analysis views after sync. Default: Read from config (Sync.Views.Enabled) or $true
Command-line parameter overrides config file setting

.PARAMETER ParallelExecution
Enable parallel execution of sync operations. Default: Read from config (Sync.ParallelExecution) or $true
Set to $false for sequential execution (useful for debugging or resource-constrained environments)
Command-line parameter overrides config file setting

.PARAMETER UserFilter
Optional OData filter for user sync (e.g., "accountEnabled eq true")
Command-line parameter overrides config file setting (Sync.Users.Filter)

.PARAMETER UserAdditionalAttributes
Additional user attributes to sync beyond defaults
Command-line parameter overrides config file setting (Sync.Users.AdditionalAttributes)

.PARAMETER GroupFilter
Optional OData filter for group sync
Command-line parameter overrides config file setting (Sync.Groups.Filter)

.PARAMETER GroupAdditionalAttributes
Additional group attributes to sync beyond defaults
Command-line parameter overrides config file setting (Sync.Groups.AdditionalAttributes)

.EXAMPLE
    Start-FGSync -ConfigFile "C:\Config\config.production.json"
    Runs full sync with all default options

.EXAMPLE
    Start-FGSync -ConfigFile ".\config.production.json" -UserFilter "accountEnabled eq true"
    Syncs only enabled users, all other entities use defaults

.EXAMPLE
    Start-FGSync -ConfigFile ".\config.production.json" -SyncGroupEligibleMembers:$false
    Runs sync but skips eligible members (useful if PIM is not configured)

.NOTES
    Prerequisites:
    - Az PowerShell module installed
    - FortigiGraph module installed
    - Configuration file with Azure/Graph credentials
    - Appropriate permissions in Azure and Microsoft Graph

    Author: Wim van den Heijkant
    Company: Fortigi
#>

    [alias("Daily-Sync")]
    [CmdletBinding()]
    param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,

    [Parameter(Mandatory = $false)]
    [switch]$SkipServerValidation,

    [Parameter(Mandatory = $false)]
    [bool]$SyncUsers = $true,

    [Parameter(Mandatory = $false)]
    [bool]$SyncGroups = $true,

    [Parameter(Mandatory = $false)]
    [bool]$SyncGroupMembers = $true,

    [Parameter(Mandatory = $false)]
    [bool]$SyncGroupTransitiveMembers = $false,  # DEPRECATED: Use vw_GraphGroupMembersRecursive instead

    [Parameter(Mandatory = $false)]
    [bool]$SyncGroupEligibleMembers = $true,

    [Parameter(Mandatory = $false)]
    [bool]$SyncGroupOwners = $true,

    [Parameter(Mandatory = $false)]
    [bool]$CreateViews = $true,

    [Parameter(Mandatory = $false)]
    [bool]$ParallelExecution = $true,

    [Parameter(Mandatory = $false)]
    [string]$UserFilter,

    [Parameter(Mandatory = $false)]
    [string[]]$UserAdditionalAttributes,

    [Parameter(Mandatory = $false)]
    [string]$GroupFilter,

    [Parameter(Mandatory = $false)]
    [string[]]$GroupAdditionalAttributes,

    [Parameter(Mandatory = $false)]
    [bool]$SyncCatalogs = $true,

    [Parameter(Mandatory = $false)]
    [bool]$SyncAccessPackages = $true,

    [Parameter(Mandatory = $false)]
    [bool]$SyncAccessPackageAssignments = $true,

    [Parameter(Mandatory = $false)]
    [bool]$SyncAccessPackageResourceRoleScopes = $true
)

    $ErrorActionPreference = "Stop"

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "FortigiGraph Daily Sync" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
    Write-Host "Config:  $ConfigFile`n" -ForegroundColor Cyan

    # Track sync statistics
    $script:SyncStats = @{
    StartTime = Get-Date
    Users = $null
    Groups = $null
    DirectMembers = $null
    TransitiveMembers = $null
    EligibleMembers = $null
    Owners = $null
    Catalogs = $null
    AccessPackages = $null
    AccessPackageAssignments = $null
    AccessPackageResourceRoleScopes = $null
    Errors = @()
}

#region Helper Functions
function Write-SyncHeader {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Yellow
}

function Write-SyncStep {
    param([string]$Message)
    Write-Host "  → $Message" -ForegroundColor Cyan
}

function Write-SyncSuccess {
    param([string]$Message)
    Write-Host "  ✓ $Message" -ForegroundColor Green
}

function Write-SyncError {
    param([string]$Message, [string]$Details = "")
    Write-Host "  ✗ $Message" -ForegroundColor Red
    if ($Details) {
        Write-Host "    $Details" -ForegroundColor Gray
    }
    $script:SyncStats.Errors += [PSCustomObject]@{
        Message = $Message
        Details = $Details
        Timestamp = Get-Date
    }
}
#endregion

    try {
        #region Load Configuration
        Write-SyncHeader "Loading Configuration"

        # Module is already loaded when this function is called
        # Load configuration file
    if (-not (Test-Path $ConfigFile)) {
        throw "Configuration file not found: $ConfigFile"
    }

    $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    Write-SyncSuccess "Configuration loaded"

    # Validate required fields
    $requiredFields = @(
        @{ Path = "Azure.SubscriptionId"; Value = $config.Azure.SubscriptionId },
        @{ Path = "Azure.ResourceGroupName"; Value = $config.Azure.ResourceGroupName },
        @{ Path = "Azure.SQLServerName"; Value = $config.Azure.SQLServerName },
        @{ Path = "Graph.TenantId"; Value = $config.Graph.TenantId },
        @{ Path = "Graph.ClientId"; Value = $config.Graph.ClientId }
    )

    $configValid = $true
    foreach ($field in $requiredFields) {
        if ([string]::IsNullOrWhiteSpace($field.Value) -or $field.Value -like "YOUR-*") {
            Write-SyncError "Missing configuration: $($field.Path)"
            $configValid = $false
        }
    }

    if (-not $configValid) {
        throw "Configuration validation failed. Please update $ConfigFile"
    }

    Write-SyncSuccess "Configuration validated"

    # Read Sync configuration from config file (if present)
    # Command-line parameters override config file settings
    if ($config.Sync) {
        Write-SyncStep "Reading sync configuration from config file..."

        # Override defaults with config file values (only if not explicitly set via command-line)
        if ($PSBoundParameters.ContainsKey('SyncUsers') -eq $false -and $null -ne $config.Sync.Users.Enabled) {
            $SyncUsers = $config.Sync.Users.Enabled
        }
        if ($PSBoundParameters.ContainsKey('SyncGroups') -eq $false -and $null -ne $config.Sync.Groups.Enabled) {
            $SyncGroups = $config.Sync.Groups.Enabled
        }
        if ($PSBoundParameters.ContainsKey('SyncGroupMembers') -eq $false -and $null -ne $config.Sync.GroupMembers.Enabled) {
            $SyncGroupMembers = $config.Sync.GroupMembers.Enabled
        }
        if ($PSBoundParameters.ContainsKey('SyncGroupTransitiveMembers') -eq $false -and $null -ne $config.Sync.GroupTransitiveMembers.Enabled) {
            $SyncGroupTransitiveMembers = $config.Sync.GroupTransitiveMembers.Enabled
        }
        if ($PSBoundParameters.ContainsKey('SyncGroupEligibleMembers') -eq $false -and $null -ne $config.Sync.GroupEligibleMembers.Enabled) {
            $SyncGroupEligibleMembers = $config.Sync.GroupEligibleMembers.Enabled
        }
        if ($PSBoundParameters.ContainsKey('SyncGroupOwners') -eq $false -and $null -ne $config.Sync.GroupOwners.Enabled) {
            $SyncGroupOwners = $config.Sync.GroupOwners.Enabled
        }
        if ($PSBoundParameters.ContainsKey('SyncCatalogs') -eq $false -and $null -ne $config.Sync.Catalogs.Enabled) {
            $SyncCatalogs = $config.Sync.Catalogs.Enabled
        }
        if ($PSBoundParameters.ContainsKey('SyncAccessPackages') -eq $false -and $null -ne $config.Sync.AccessPackages.Enabled) {
            $SyncAccessPackages = $config.Sync.AccessPackages.Enabled
        }
        if ($PSBoundParameters.ContainsKey('SyncAccessPackageAssignments') -eq $false -and $null -ne $config.Sync.AccessPackageAssignments.Enabled) {
            $SyncAccessPackageAssignments = $config.Sync.AccessPackageAssignments.Enabled
        }
        if ($PSBoundParameters.ContainsKey('SyncAccessPackageResourceRoleScopes') -eq $false -and $null -ne $config.Sync.AccessPackageResourceRoleScopes.Enabled) {
            $SyncAccessPackageResourceRoleScopes = $config.Sync.AccessPackageResourceRoleScopes.Enabled
        }
        if ($PSBoundParameters.ContainsKey('CreateViews') -eq $false -and $null -ne $config.Sync.Views.Enabled) {
            $CreateViews = $config.Sync.Views.Enabled
        }
        if ($PSBoundParameters.ContainsKey('ParallelExecution') -eq $false -and $null -ne $config.Sync.ParallelExecution) {
            $ParallelExecution = $config.Sync.ParallelExecution
        }

        # Read filters and attributes from config (if not provided via command-line)
        if ($PSBoundParameters.ContainsKey('UserFilter') -eq $false -and $config.Sync.Users.Filter) {
            $UserFilter = $config.Sync.Users.Filter
        }
        if ($PSBoundParameters.ContainsKey('GroupFilter') -eq $false -and $config.Sync.Groups.Filter) {
            $GroupFilter = $config.Sync.Groups.Filter
        }
        if ($PSBoundParameters.ContainsKey('UserAdditionalAttributes') -eq $false -and $config.Sync.Users.AdditionalAttributes) {
            $UserAdditionalAttributes = $config.Sync.Users.AdditionalAttributes
        }
        if ($PSBoundParameters.ContainsKey('GroupAdditionalAttributes') -eq $false -and $config.Sync.Groups.AdditionalAttributes) {
            $GroupAdditionalAttributes = $config.Sync.Groups.AdditionalAttributes
        }

        Write-SyncSuccess "Sync configuration read from config file"
    }

    # Determine Azure tenant ID (use separate Azure tenant if specified)
    if ($config.Azure.TenantId -and $config.Azure.TenantId -notlike "YOUR-*" -and -not [string]::IsNullOrWhiteSpace($config.Azure.TenantId)) {
        $azureTenantId = $config.Azure.TenantId
        Write-SyncStep "Using separate Azure TenantId: $azureTenantId"
    } else {
        $azureTenantId = $config.Graph.TenantId
        Write-SyncStep "Using Graph TenantId for Azure operations"
    }

    # Secure config functions now loaded from module (Get-FGSecureConfigValue, etc.)
    Write-SyncStep "Loading secure credentials..."

    # Get SQL Admin Password
    $SecurePassword = Get-SecureConfigValue `
        -ConfigPath $ConfigFile `
        -PropertyPath "Azure.AdminUserPassword" `
        -PromptMessage "Enter SQL Server Admin Password" `
        -AsSecureString

    # Get Graph Client Secret (optional for interactive auth)
    $clientSecret = Get-SecureConfigValue `
        -ConfigPath $ConfigFile `
        -PropertyPath "Graph.ClientSecret" `
        -PromptMessage "Enter Graph Client Secret (or press Enter for interactive auth)" `
        -AllowEmpty

    Write-SyncSuccess "Secure credentials loaded"
    #endregion

    #region Azure Connection
    Write-SyncHeader "Connecting to Azure"

    $azContext = Get-AzContext -ErrorAction SilentlyContinue

    if (-not $azContext) {
        Write-SyncStep "Connecting to Azure..."
        Connect-AzAccount -TenantId $azureTenantId -SubscriptionId $config.Azure.SubscriptionId | Out-Null
        $azContext = Get-AzContext
    } else {
        $correctTenant = $azContext.Tenant.Id -eq $azureTenantId
        $correctSubscription = $azContext.Subscription.Id -eq $config.Azure.SubscriptionId

        if (-not $correctTenant -or -not $correctSubscription) {
            Write-SyncStep "Switching Azure context..."
            try {
                Set-AzContext -TenantId $azureTenantId -SubscriptionId $config.Azure.SubscriptionId -ErrorAction Stop | Out-Null
            } catch {
                Connect-AzAccount -TenantId $azureTenantId -SubscriptionId $config.Azure.SubscriptionId | Out-Null
            }
            $azContext = Get-AzContext
        }
    }

    Write-SyncSuccess "Connected to Azure: $($azContext.Subscription.Name) ($($azContext.Account.Id))"
    #endregion

    #region SQL Server Validation
    Write-SyncHeader "Validating SQL Server"

    if (-not $SkipServerValidation) {
        Write-SyncStep "Checking SQL Server: $($config.Azure.SQLServerName)..."

        $existingServer = Get-AzSqlServer `
            -ResourceGroupName $config.Azure.ResourceGroupName `
            -ServerName $config.Azure.SQLServerName `
            -ErrorAction SilentlyContinue

        if (-not $existingServer) {
            Write-SyncStep "SQL Server not found. Creating..."

            $serverInfo = New-FGAzureSQLServer `
                -SubscriptionId $config.Azure.SubscriptionId `
                -ResourceGroupName $config.Azure.ResourceGroupName `
                -ServerName $config.Azure.SQLServerName `
                -DatabaseName $config.Azure.DatabaseName `
                -AdminUsername $config.Azure.AdminUsername `
                -AdminPassword $SecurePassword `
                -Location $config.Azure.Location `
                -AllowCurrentIP `
                -AutoConnect

            Write-SyncSuccess "SQL Server created and connected"
        } else {
            Write-SyncSuccess "SQL Server exists: $($existingServer.ServerName)"

            # Connect to existing server
            Write-SyncStep "Connecting to SQL Server..."
            Connect-FGSQLServer `
                -SubscriptionId $config.Azure.SubscriptionId `
                -ResourceGroupName $config.Azure.ResourceGroupName `
                -ServerName $config.Azure.SQLServerName `
                -DatabaseName $config.Azure.DatabaseName `
                -AdminUsername $config.Azure.AdminUsername `
                -AdminPassword $SecurePassword `
                -UpdateFirewall

            Write-SyncSuccess "Connected to SQL Server"
        }
    } else {
        Write-SyncStep "Skipping server validation (assuming server exists)"

        # Still need to connect
        Connect-FGSQLServer `
            -SubscriptionId $config.Azure.SubscriptionId `
            -ResourceGroupName $config.Azure.ResourceGroupName `
            -ServerName $config.Azure.SQLServerName `
            -DatabaseName $config.Azure.DatabaseName `
            -AdminUsername $config.Azure.AdminUsername `
            -AdminPassword $SecurePassword `
            -UpdateFirewall

        Write-SyncSuccess "Connected to SQL Server"
    }

    # Verify connection
    $connectionInfo = Test-FGSQLConnection
    Write-SyncSuccess "SQL connection verified: $($connectionInfo.Database)"
    #endregion

    #region Microsoft Graph Connection
    Write-SyncHeader "Connecting to Microsoft Graph"

    # Check for existing valid token
    $hasValidToken = $false
    if ($global:AccessToken) {
        try {
            Write-SyncStep "Testing existing Graph token..."
            $testUsers = Get-FGUser
            $hasValidToken = $true
            Write-SyncSuccess "Existing token is valid"
        } catch {
            Write-SyncStep "Existing token invalid, getting new token..."
        }
    }

    if (-not $hasValidToken) {
        Write-SyncStep "Getting Graph access token..."

        if ($clientSecret -and $clientSecret -ne "") {
            Get-FGAccessToken `
                -TenantId $config.Graph.TenantId `
                -ClientId $config.Graph.ClientId `
                -ClientSecret $clientSecret
        } else {
            Write-SyncStep "Using interactive authentication..."
            Get-FGAccessToken `
                -TenantId $config.Graph.TenantId `
                -ClientId $config.Graph.ClientId
        }

        Write-SyncSuccess "Graph access token obtained"
    }
    #endregion

    # Capture Graph API access token and credentials for runspaces (must happen AFTER authentication)
    # These are needed for automatic token refresh if token expires during long-running sync operations
    $graphAccessToken = $Global:AccessToken
    $graphTenantId = $config.Graph.TenantId
    $graphClientId = $config.Graph.ClientId
    $graphClientSecret = $Global:ClientSecret      # For service principal auth refresh
    $graphRefreshToken = $Global:RefreshToken      # For interactive auth refresh

    # Capture SQL connection details for runspaces
    $sqlConnectionString = $Global:FGSQLConnectionString
    $sqlServerName = $Global:FGSQLServerName
    $sqlDatabaseName = $Global:FGSQLDatabaseName

    # Get module root for runspace initialization
    $moduleInfo = Get-Module -Name FortigiGraph
    if ($moduleInfo) {
        $moduleRoot = Split-Path -Parent $moduleInfo.Path
    } else {
        # Fallback: assume we're in Sync folder, parent is module root
        $moduleRoot = Split-Path -Parent $PSScriptRoot
    }

    #region Data Synchronization
    $executionMode = if ($ParallelExecution) { "Parallel" } else { "Sequential" }
    Write-SyncHeader "Starting Data Synchronization ($executionMode)"

    # Determine table names (from config or defaults)
    $userTableName = if ($config.Sync.Users.TableName) { $config.Sync.Users.TableName } else { "GraphUsers" }
    $groupTableName = if ($config.Sync.Groups.TableName) { $config.Sync.Groups.TableName } else { "GraphGroups" }
    $groupMembersTableName = if ($config.Sync.GroupMembers.TableName) { $config.Sync.GroupMembers.TableName } else { "GraphGroupMembers" }
    $groupTransitiveMembersTableName = if ($config.Sync.GroupTransitiveMembers.TableName) { $config.Sync.GroupTransitiveMembers.TableName } else { "GraphGroupTransitiveMembers" }
    $groupEligibleMembersTableName = if ($config.Sync.GroupEligibleMembers.TableName) { $config.Sync.GroupEligibleMembers.TableName } else { "GraphGroupEligibleMembers" }
    $groupOwnersTableName = if ($config.Sync.GroupOwners.TableName) { $config.Sync.GroupOwners.TableName } else { "GraphGroupOwners" }
    $catalogsTableName = if ($config.Sync.Catalogs.TableName) { $config.Sync.Catalogs.TableName } else { "GraphCatalogs" }
    $accessPackagesTableName = if ($config.Sync.AccessPackages.TableName) { $config.Sync.AccessPackages.TableName } else { "GraphAccessPackages" }
    $accessPackageAssignmentsTableName = if ($config.Sync.AccessPackageAssignments.TableName) { $config.Sync.AccessPackageAssignments.TableName } else { "GraphAccessPackageAssignments" }
    $accessPackageResourceRoleScopesTableName = if ($config.Sync.AccessPackageResourceRoleScopes.TableName) { $config.Sync.AccessPackageResourceRoleScopes.TableName } else { "GraphAccessPackageResourceRoleScopes" }

    if ($ParallelExecution) {
        # Parallel execution using runspaces
        Write-SyncStep "Using parallel execution (up to 6 operations concurrently)"

        # Create runspace pool
        $runspacePool = [runspacefactory]::CreateRunspacePool(1, 6)
        $runspacePool.Open()

        # Collection to track jobs
        $jobs = @()

        # Define scriptblock for parallel execution
        $syncScriptBlock = {
            param(
                [string]$SyncType,
                [string]$TableName,
                [string]$ModuleRoot,
                [string]$SqlConnString,
                [string]$SqlServer,
                [string]$SqlDb,
                [string]$AccessToken,
                [string]$TenantId,
                [string]$ClientId,
                [string]$ClientSecret,
                [string]$RefreshToken,
                [hashtable]$SyncParams = @{}
            )

            try {
                # Import FortigiGraph module in this runspace
                $modulePath = Join-Path $ModuleRoot "FortigiGraph.psd1"
                Import-Module $modulePath -Force -ErrorAction Stop

                # Set global variables for Graph API authentication
                $Global:AccessToken = $AccessToken
                $Global:TenantId = $TenantId
                $Global:ClientId = $ClientId
                $Global:ClientSecret = $ClientSecret
                $Global:RefreshToken = $RefreshToken

                # Set global variables for SQL connection
                $Global:FGSQLConnectionString = $SqlConnString
                $Global:FGSQLServerName = $SqlServer
                $Global:FGSQLDatabaseName = $SqlDb

                # Execute sync based on type
                # Suppress all output and only return the result object
                $outputMode = $null
                switch ($SyncType) {
                    "Users" {
                        $null = Sync-FGUser @SyncParams
                        $count = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.$TableName" -AsScalar
                        $outputMode = [PSCustomObject]@{ Success = $true; Count = [int]$count; Type = $SyncType }
                    }
                    "Groups" {
                        $null = Sync-FGGroup @SyncParams
                        $count = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.$TableName" -AsScalar
                        $outputMode = [PSCustomObject]@{ Success = $true; Count = [int]$count; Type = $SyncType }
                    }
                    "GroupMembers" {
                        $null = Sync-FGGroupMember -TableName $TableName
                        $count = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.$TableName" -AsScalar
                        $outputMode = [PSCustomObject]@{ Success = $true; Count = [int]$count; Type = $SyncType }
                    }
                    "GroupTransitiveMembers" {
                        $null = Sync-FGGroupTransitiveMember -TableName $TableName
                        $count = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.$TableName" -AsScalar
                        $outputMode = [PSCustomObject]@{ Success = $true; Count = [int]$count; Type = $SyncType }
                    }
                    "GroupEligibleMembers" {
                        $null = Sync-FGGroupEligibleMember -TableName $TableName
                        $count = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.$TableName" -AsScalar
                        $outputMode = [PSCustomObject]@{ Success = $true; Count = [int]$count; Type = $SyncType }
                    }
                    "GroupOwners" {
                        $null = Sync-FGGroupOwner -TableName $TableName
                        $count = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.$TableName" -AsScalar
                        $outputMode = [PSCustomObject]@{ Success = $true; Count = [int]$count; Type = $SyncType }
                    }
                    "Catalogs" {
                        $null = Sync-FGCatalog -TableName $TableName
                        $count = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.$TableName" -AsScalar
                        $outputMode = [PSCustomObject]@{ Success = $true; Count = [int]$count; Type = $SyncType }
                    }
                    "AccessPackages" {
                        $null = Sync-FGAccessPackage -TableName $TableName
                        $count = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.$TableName" -AsScalar
                        $outputMode = [PSCustomObject]@{ Success = $true; Count = [int]$count; Type = $SyncType }
                    }
                    "AccessPackageAssignments" {
                        $null = Sync-FGAccessPackageAssignment -TableName $TableName
                        $count = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.$TableName" -AsScalar
                        $outputMode = [PSCustomObject]@{ Success = $true; Count = [int]$count; Type = $SyncType }
                    }
                    "AccessPackageResourceRoleScopes" {
                        $null = Sync-FGAccessPackageResourceRoleScope -TableName $TableName
                        $count = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.$TableName" -AsScalar
                        $outputMode = [PSCustomObject]@{ Success = $true; Count = [int]$count; Type = $SyncType }
                    }
                }

                # Return only the result object
                return $outputMode
            } catch {
                return @{
                    Success = $false
                    Type = $SyncType
                    Error = $_.Exception.Message
                    StackTrace = $_.ScriptStackTrace
                }
            }
        }

        # Create job for Users sync
        if ($SyncUsers) {
            Write-SyncStep "Starting user sync job..."
            $userSyncParams = @{ TableName = $userTableName }
            if ($UserFilter) { $userSyncParams.Filter = $UserFilter }
            if ($UserAdditionalAttributes) { $userSyncParams.AdditionalAttributes = $UserAdditionalAttributes }

            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $runspacePool
            [void]$ps.AddScript($syncScriptBlock)
            [void]$ps.AddParameter("SyncType", "Users")
            [void]$ps.AddParameter("TableName", $userTableName)
            [void]$ps.AddParameter("ModuleRoot", $moduleRoot)
            [void]$ps.AddParameter("SqlConnString", $sqlConnectionString)
            [void]$ps.AddParameter("SqlServer", $sqlServerName)
            [void]$ps.AddParameter("SqlDb", $sqlDatabaseName)
            [void]$ps.AddParameter("AccessToken", $graphAccessToken)
            [void]$ps.AddParameter("TenantId", $graphTenantId)
            [void]$ps.AddParameter("ClientId", $graphClientId)
            [void]$ps.AddParameter("ClientSecret", $graphClientSecret)
            [void]$ps.AddParameter("RefreshToken", $graphRefreshToken)
            [void]$ps.AddParameter("SyncParams", $userSyncParams)

            $jobs += @{
                Name = "Users"
                PowerShell = $ps
                Handle = $ps.BeginInvoke()
            }
        }

        # Create job for Groups sync
        if ($SyncGroups) {
            Write-SyncStep "Starting group sync job..."
            $groupSyncParams = @{ TableName = $groupTableName }
            if ($GroupFilter) { $groupSyncParams.Filter = $GroupFilter }
            if ($GroupAdditionalAttributes) { $groupSyncParams.AdditionalAttributes = $GroupAdditionalAttributes }

            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $runspacePool
            [void]$ps.AddScript($syncScriptBlock)
            [void]$ps.AddParameter("SyncType", "Groups")
            [void]$ps.AddParameter("TableName", $groupTableName)
            [void]$ps.AddParameter("ModuleRoot", $moduleRoot)
            [void]$ps.AddParameter("SqlConnString", $sqlConnectionString)
            [void]$ps.AddParameter("SqlServer", $sqlServerName)
            [void]$ps.AddParameter("SqlDb", $sqlDatabaseName)
            [void]$ps.AddParameter("AccessToken", $graphAccessToken)
            [void]$ps.AddParameter("TenantId", $graphTenantId)
            [void]$ps.AddParameter("ClientId", $graphClientId)
            [void]$ps.AddParameter("ClientSecret", $graphClientSecret)
            [void]$ps.AddParameter("RefreshToken", $graphRefreshToken)
            [void]$ps.AddParameter("SyncParams", $groupSyncParams)

            $jobs += @{
                Name = "Groups"
                PowerShell = $ps
                Handle = $ps.BeginInvoke()
            }
        }

        # Create job for GroupMembers sync
        if ($SyncGroupMembers) {
            Write-SyncStep "Starting direct membership sync job..."
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $runspacePool
            [void]$ps.AddScript($syncScriptBlock)
            [void]$ps.AddParameter("SyncType", "GroupMembers")
            [void]$ps.AddParameter("TableName", $groupMembersTableName)
            [void]$ps.AddParameter("ModuleRoot", $moduleRoot)
            [void]$ps.AddParameter("SqlConnString", $sqlConnectionString)
            [void]$ps.AddParameter("SqlServer", $sqlServerName)
            [void]$ps.AddParameter("SqlDb", $sqlDatabaseName)
            [void]$ps.AddParameter("AccessToken", $graphAccessToken)
            [void]$ps.AddParameter("TenantId", $graphTenantId)
            [void]$ps.AddParameter("ClientId", $graphClientId)
            [void]$ps.AddParameter("ClientSecret", $graphClientSecret)
            [void]$ps.AddParameter("RefreshToken", $graphRefreshToken)

            $jobs += @{
                Name = "GroupMembers"
                PowerShell = $ps
                Handle = $ps.BeginInvoke()
            }
        }

        # Create job for GroupTransitiveMembers sync
        if ($SyncGroupTransitiveMembers) {
            Write-SyncStep "Starting transitive membership sync job..."
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $runspacePool
            [void]$ps.AddScript($syncScriptBlock)
            [void]$ps.AddParameter("SyncType", "GroupTransitiveMembers")
            [void]$ps.AddParameter("TableName", $groupTransitiveMembersTableName)
            [void]$ps.AddParameter("ModuleRoot", $moduleRoot)
            [void]$ps.AddParameter("SqlConnString", $sqlConnectionString)
            [void]$ps.AddParameter("SqlServer", $sqlServerName)
            [void]$ps.AddParameter("SqlDb", $sqlDatabaseName)
            [void]$ps.AddParameter("AccessToken", $graphAccessToken)
            [void]$ps.AddParameter("TenantId", $graphTenantId)
            [void]$ps.AddParameter("ClientId", $graphClientId)
            [void]$ps.AddParameter("ClientSecret", $graphClientSecret)
            [void]$ps.AddParameter("RefreshToken", $graphRefreshToken)

            $jobs += @{
                Name = "GroupTransitiveMembers"
                PowerShell = $ps
                Handle = $ps.BeginInvoke()
            }
        }

        # Create job for GroupEligibleMembers sync
        if ($SyncGroupEligibleMembers) {
            Write-SyncStep "Starting eligible membership sync job..."
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $runspacePool
            [void]$ps.AddScript($syncScriptBlock)
            [void]$ps.AddParameter("SyncType", "GroupEligibleMembers")
            [void]$ps.AddParameter("TableName", $groupEligibleMembersTableName)
            [void]$ps.AddParameter("ModuleRoot", $moduleRoot)
            [void]$ps.AddParameter("SqlConnString", $sqlConnectionString)
            [void]$ps.AddParameter("SqlServer", $sqlServerName)
            [void]$ps.AddParameter("SqlDb", $sqlDatabaseName)
            [void]$ps.AddParameter("AccessToken", $graphAccessToken)
            [void]$ps.AddParameter("TenantId", $graphTenantId)
            [void]$ps.AddParameter("ClientId", $graphClientId)
            [void]$ps.AddParameter("ClientSecret", $graphClientSecret)
            [void]$ps.AddParameter("RefreshToken", $graphRefreshToken)

            $jobs += @{
                Name = "GroupEligibleMembers"
                PowerShell = $ps
                Handle = $ps.BeginInvoke()
            }
        }

        # Create job for GroupOwners sync
        if ($SyncGroupOwners) {
            Write-SyncStep "Starting group ownership sync job..."
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $runspacePool
            [void]$ps.AddScript($syncScriptBlock)
            [void]$ps.AddParameter("SyncType", "GroupOwners")
            [void]$ps.AddParameter("TableName", $groupOwnersTableName)
            [void]$ps.AddParameter("ModuleRoot", $moduleRoot)
            [void]$ps.AddParameter("SqlConnString", $sqlConnectionString)
            [void]$ps.AddParameter("SqlServer", $sqlServerName)
            [void]$ps.AddParameter("SqlDb", $sqlDatabaseName)
            [void]$ps.AddParameter("AccessToken", $graphAccessToken)
            [void]$ps.AddParameter("TenantId", $graphTenantId)
            [void]$ps.AddParameter("ClientId", $graphClientId)
            [void]$ps.AddParameter("ClientSecret", $graphClientSecret)
            [void]$ps.AddParameter("RefreshToken", $graphRefreshToken)

            $jobs += @{
                Name = "GroupOwners"
                PowerShell = $ps
                Handle = $ps.BeginInvoke()
            }
        }

        # Create job for Catalogs sync
        if ($SyncCatalogs) {
            Write-SyncStep "Starting catalogs sync job..."
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $runspacePool
            [void]$ps.AddScript($syncScriptBlock)
            [void]$ps.AddParameter("SyncType", "Catalogs")
            [void]$ps.AddParameter("TableName", $catalogsTableName)
            [void]$ps.AddParameter("ModuleRoot", $moduleRoot)
            [void]$ps.AddParameter("SqlConnString", $sqlConnectionString)
            [void]$ps.AddParameter("SqlServer", $sqlServerName)
            [void]$ps.AddParameter("SqlDb", $sqlDatabaseName)
            [void]$ps.AddParameter("AccessToken", $graphAccessToken)
            [void]$ps.AddParameter("TenantId", $graphTenantId)
            [void]$ps.AddParameter("ClientId", $graphClientId)
            [void]$ps.AddParameter("ClientSecret", $graphClientSecret)
            [void]$ps.AddParameter("RefreshToken", $graphRefreshToken)

            $jobs += @{
                Name = "Catalogs"
                PowerShell = $ps
                Handle = $ps.BeginInvoke()
            }
        }

        # Create job for AccessPackages sync
        if ($SyncAccessPackages) {
            Write-SyncStep "Starting access packages sync job..."
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $runspacePool
            [void]$ps.AddScript($syncScriptBlock)
            [void]$ps.AddParameter("SyncType", "AccessPackages")
            [void]$ps.AddParameter("TableName", $accessPackagesTableName)
            [void]$ps.AddParameter("ModuleRoot", $moduleRoot)
            [void]$ps.AddParameter("SqlConnString", $sqlConnectionString)
            [void]$ps.AddParameter("SqlServer", $sqlServerName)
            [void]$ps.AddParameter("SqlDb", $sqlDatabaseName)
            [void]$ps.AddParameter("AccessToken", $graphAccessToken)
            [void]$ps.AddParameter("TenantId", $graphTenantId)
            [void]$ps.AddParameter("ClientId", $graphClientId)
            [void]$ps.AddParameter("ClientSecret", $graphClientSecret)
            [void]$ps.AddParameter("RefreshToken", $graphRefreshToken)

            $jobs += @{
                Name = "AccessPackages"
                PowerShell = $ps
                Handle = $ps.BeginInvoke()
            }
        }

        # Create job for AccessPackageAssignments sync
        if ($SyncAccessPackageAssignments) {
            Write-SyncStep "Starting access package assignments sync job..."
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $runspacePool
            [void]$ps.AddScript($syncScriptBlock)
            [void]$ps.AddParameter("SyncType", "AccessPackageAssignments")
            [void]$ps.AddParameter("TableName", $accessPackageAssignmentsTableName)
            [void]$ps.AddParameter("ModuleRoot", $moduleRoot)
            [void]$ps.AddParameter("SqlConnString", $sqlConnectionString)
            [void]$ps.AddParameter("SqlServer", $sqlServerName)
            [void]$ps.AddParameter("SqlDb", $sqlDatabaseName)
            [void]$ps.AddParameter("AccessToken", $graphAccessToken)
            [void]$ps.AddParameter("TenantId", $graphTenantId)
            [void]$ps.AddParameter("ClientId", $graphClientId)
            [void]$ps.AddParameter("ClientSecret", $graphClientSecret)
            [void]$ps.AddParameter("RefreshToken", $graphRefreshToken)

            $jobs += @{
                Name = "AccessPackageAssignments"
                PowerShell = $ps
                Handle = $ps.BeginInvoke()
            }
        }

        # Create job for AccessPackageResourceRoleScopes sync
        if ($SyncAccessPackageResourceRoleScopes) {
            Write-SyncStep "Starting access package resource role scopes sync job..."
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $runspacePool
            [void]$ps.AddScript($syncScriptBlock)
            [void]$ps.AddParameter("SyncType", "AccessPackageResourceRoleScopes")
            [void]$ps.AddParameter("TableName", $accessPackageResourceRoleScopesTableName)
            [void]$ps.AddParameter("ModuleRoot", $moduleRoot)
            [void]$ps.AddParameter("SqlConnString", $sqlConnectionString)
            [void]$ps.AddParameter("SqlServer", $sqlServerName)
            [void]$ps.AddParameter("SqlDb", $sqlDatabaseName)
            [void]$ps.AddParameter("AccessToken", $graphAccessToken)
            [void]$ps.AddParameter("TenantId", $graphTenantId)
            [void]$ps.AddParameter("ClientId", $graphClientId)
            [void]$ps.AddParameter("ClientSecret", $graphClientSecret)
            [void]$ps.AddParameter("RefreshToken", $graphRefreshToken)

            $jobs += @{
                Name = "AccessPackageResourceRoleScopes"
                PowerShell = $ps
                Handle = $ps.BeginInvoke()
            }
        }

        # Wait for all jobs to complete and process results
        Write-SyncStep "Waiting for parallel jobs to complete..."
        foreach ($job in $jobs) {
            try {
                # Wait for job to complete and get result
                $resultCollection = $job.PowerShell.EndInvoke($job.Handle)

                # EndInvoke returns a collection, get the first (and should be only) item
                $result = $resultCollection | Select-Object -First 1

                # Process streams (Information, Warning, Error, Verbose)
                if ($job.PowerShell.Streams.Information.Count -gt 0) {
                    $job.PowerShell.Streams.Information | ForEach-Object {
                        Write-Information $_.MessageData
                    }
                }
                if ($job.PowerShell.Streams.Warning.Count -gt 0) {
                    $job.PowerShell.Streams.Warning | ForEach-Object {
                        Write-Warning $_
                    }
                }
                if ($job.PowerShell.Streams.Error.Count -gt 0) {
                    $job.PowerShell.Streams.Error | ForEach-Object {
                        Write-Host "  ⚠ $($job.Name): $($_.Exception.Message)" -ForegroundColor Yellow
                    }
                }

                # Process result
                if ($result -and $result.Success) {
                    switch ($result.Type) {
                        "Users" {
                            $script:SyncStats.Users = $result.Count
                            Write-SyncSuccess "Users synced: $($result.Count) (table: $userTableName)"
                        }
                        "Groups" {
                            $script:SyncStats.Groups = $result.Count
                            Write-SyncSuccess "Groups synced: $($result.Count) (table: $groupTableName)"
                        }
                        "GroupMembers" {
                            $script:SyncStats.DirectMembers = $result.Count
                            Write-SyncSuccess "Direct memberships synced: $($result.Count) (table: $groupMembersTableName)"
                        }
                        "GroupTransitiveMembers" {
                            $script:SyncStats.TransitiveMembers = $result.Count
                            Write-SyncSuccess "Transitive memberships synced: $($result.Count) (table: $groupTransitiveMembersTableName)"
                        }
                        "GroupEligibleMembers" {
                            $script:SyncStats.EligibleMembers = $result.Count
                            Write-SyncSuccess "Eligible memberships synced: $($result.Count) (table: $groupEligibleMembersTableName)"
                        }
                        "GroupOwners" {
                            $script:SyncStats.Owners = $result.Count
                            Write-SyncSuccess "Group ownerships synced: $($result.Count) (table: $groupOwnersTableName)"
                        }
                        "Catalogs" {
                            $script:SyncStats.Catalogs = $result.Count
                            Write-SyncSuccess "Catalogs synced: $($result.Count) (table: $catalogsTableName)"
                        }
                        "AccessPackages" {
                            $script:SyncStats.AccessPackages = $result.Count
                            Write-SyncSuccess "Access packages synced: $($result.Count) (table: $accessPackagesTableName)"
                        }
                        "AccessPackageAssignments" {
                            $script:SyncStats.AccessPackageAssignments = $result.Count
                            Write-SyncSuccess "Access package assignments synced: $($result.Count) (table: $accessPackageAssignmentsTableName)"
                        }
                        "AccessPackageResourceRoleScopes" {
                            $script:SyncStats.AccessPackageResourceRoleScopes = $result.Count
                            Write-SyncSuccess "Access package resource role scopes synced: $($result.Count) (table: $accessPackageResourceRoleScopesTableName)"
                        }
                    }
                } elseif ($result -and -not $result.Success) {
                    Write-SyncError "$($result.Type) sync failed" $result.Error
                }

            } catch {
                Write-SyncError "$($job.Name) job failed" $_.Exception.Message
            } finally {
                # Dispose of PowerShell instance
                $job.PowerShell.Dispose()
            }
        }

        # Close runspace pool
        $runspacePool.Close()
        $runspacePool.Dispose()

    } else {
        # Sequential execution (original code)
        Write-SyncStep "Using sequential execution"

        # Sync Users
        if ($SyncUsers) {
            Write-SyncStep "Syncing users to SQL..."
            try {
                $syncParams = @{
                    TableName = $userTableName
                }

                if ($UserFilter) {
                    $syncParams.Filter = $UserFilter
                    Write-SyncStep "Using user filter: $UserFilter"
                }

                if ($UserAdditionalAttributes) {
                    $syncParams.AdditionalAttributes = $UserAdditionalAttributes
                    Write-SyncStep "Additional attributes: $($UserAdditionalAttributes -join ', ')"
                }

                Sync-FGUser @syncParams

                # Get count
                $userCount = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.$userTableName" -AsScalar
                $script:SyncStats.Users = $userCount
                Write-SyncSuccess "Users synced: $userCount (table: $userTableName)"
            } catch {
                Write-SyncError "User sync failed" $_.Exception.Message
            }
        }

        # Sync Groups
        if ($SyncGroups) {
            Write-SyncStep "Syncing groups to SQL..."
            try {
                $syncParams = @{
                    TableName = $groupTableName
                }

                if ($GroupFilter) {
                    $syncParams.Filter = $GroupFilter
                    Write-SyncStep "Using group filter: $GroupFilter"
                }

                if ($GroupAdditionalAttributes) {
                    $syncParams.AdditionalAttributes = $GroupAdditionalAttributes
                    Write-SyncStep "Additional attributes: $($GroupAdditionalAttributes -join ', ')"
                }

                Sync-FGGroup @syncParams

                $groupCount = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.$groupTableName" -AsScalar
                $script:SyncStats.Groups = $groupCount
                Write-SyncSuccess "Groups synced: $groupCount (table: $groupTableName)"
            } catch {
                Write-SyncError "Group sync failed" $_.Exception.Message
            }
        }

        # Sync Group Members (Direct)
        if ($SyncGroupMembers) {
            Write-SyncStep "Syncing direct group memberships..."
            try {
                Sync-FGGroupMember -TableName $groupMembersTableName

                $memberCount = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.$groupMembersTableName" -AsScalar
                $script:SyncStats.DirectMembers = $memberCount
                Write-SyncSuccess "Direct memberships synced: $memberCount (table: $groupMembersTableName)"
            } catch {
                Write-SyncError "Direct membership sync failed" $_.Exception.Message
            }
        }

        # Sync Group Transitive Members (Nested)
        if ($SyncGroupTransitiveMembers) {
            Write-SyncStep "Syncing transitive/nested group memberships..."
            try {
                Sync-FGGroupTransitiveMember -TableName $groupTransitiveMembersTableName

                $transitiveCount = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.$groupTransitiveMembersTableName" -AsScalar
                $script:SyncStats.TransitiveMembers = $transitiveCount
                Write-SyncSuccess "Transitive memberships synced: $transitiveCount (table: $groupTransitiveMembersTableName)"
            } catch {
                Write-SyncError "Transitive membership sync failed" $_.Exception.Message
            }
        }

        # Sync Group Eligible Members (PIM)
        if ($SyncGroupEligibleMembers) {
            Write-SyncStep "Syncing eligible/PIM group memberships..."
            try {
                # Check if there are PIM-enabled groups first
                $pimGroupCount = 0
                if ($SyncGroups) {
                    try {
                        $pimGroupCount = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.$groupTableName WHERE isAssignableToRole = 1" -AsScalar
                    } catch {
                        Write-SyncStep "Unable to check for PIM groups, attempting sync anyway..."
                    }
                }

                if ($pimGroupCount -gt 0 -or -not $SyncGroups) {
                    Sync-FGGroupEligibleMember -TableName $groupEligibleMembersTableName

                    $eligibleCount = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.$groupEligibleMembersTableName" -AsScalar
                    $script:SyncStats.EligibleMembers = $eligibleCount
                    Write-SyncSuccess "Eligible memberships synced: $eligibleCount (table: $groupEligibleMembersTableName)"
                } else {
                    Write-SyncStep "No PIM-enabled groups found. Skipping eligible membership sync."
                    $script:SyncStats.EligibleMembers = 0
                }
            } catch {
                # PIM might not be available, so we just warn
                Write-Host "  ⚠ Eligible membership sync skipped: $($_.Exception.Message)" -ForegroundColor Yellow
                $script:SyncStats.EligibleMembers = 0
            }
        }

        # Sync Group Owners
        if ($SyncGroupOwners) {
            Write-SyncStep "Syncing group ownership relationships..."
            try {
                Sync-FGGroupOwner -TableName $groupOwnersTableName

                $ownerCount = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.$groupOwnersTableName" -AsScalar
                $script:SyncStats.Owners = $ownerCount
                Write-SyncSuccess "Group ownerships synced: $ownerCount (table: $groupOwnersTableName)"
            } catch {
                Write-SyncError "Group ownership sync failed" $_.Exception.Message
            }
        }

        # Sync Catalogs
        if ($SyncCatalogs) {
            Write-SyncStep "Syncing access package catalogs..."
            try {
                Sync-FGCatalog -TableName $catalogsTableName

                $catalogCount = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.$catalogsTableName" -AsScalar
                $script:SyncStats.Catalogs = $catalogCount
                Write-SyncSuccess "Catalogs synced: $catalogCount (table: $catalogsTableName)"
            } catch {
                Write-SyncError "Catalog sync failed" $_.Exception.Message
            }
        }

        # Sync Access Packages
        if ($SyncAccessPackages) {
            Write-SyncStep "Syncing access packages..."
            try {
                Sync-FGAccessPackage -TableName $accessPackagesTableName

                $packageCount = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.$accessPackagesTableName" -AsScalar
                $script:SyncStats.AccessPackages = $packageCount
                Write-SyncSuccess "Access packages synced: $packageCount (table: $accessPackagesTableName)"
            } catch {
                Write-SyncError "Access package sync failed" $_.Exception.Message
            }
        }

        # Sync Access Package Assignments
        if ($SyncAccessPackageAssignments) {
            Write-SyncStep "Syncing access package assignments..."
            try {
                Sync-FGAccessPackageAssignment -TableName $accessPackageAssignmentsTableName

                $assignmentCount = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.$accessPackageAssignmentsTableName" -AsScalar
                $script:SyncStats.AccessPackageAssignments = $assignmentCount
                Write-SyncSuccess "Access package assignments synced: $assignmentCount (table: $accessPackageAssignmentsTableName)"
            } catch {
                Write-SyncError "Access package assignment sync failed" $_.Exception.Message
            }
        }

        # Sync Access Package Resource Role Scopes
        if ($SyncAccessPackageResourceRoleScopes) {
            Write-SyncStep "Syncing access package resource role scopes..."
            try {
                Sync-FGAccessPackageResourceRoleScope -TableName $accessPackageResourceRoleScopesTableName

                $scopeCount = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.$accessPackageResourceRoleScopesTableName" -AsScalar
                $script:SyncStats.AccessPackageResourceRoleScopes = $scopeCount
                Write-SyncSuccess "Access package resource role scopes synced: $scopeCount (table: $accessPackageResourceRoleScopesTableName)"
            } catch {
                Write-SyncError "Access package resource role scope sync failed" $_.Exception.Message
            }
        }
    }
    #endregion

    #region Create Views
    if ($CreateViews) {
        Write-SyncHeader "Creating Analysis Views"

        try {
            Write-SyncStep "Creating group membership analysis views..."

            $viewParams = @{
                DropIfExists = $true
            }

            # Use configured table names
            if ($SyncGroupMembers) {
                $viewParams.DirectMembersTable = $groupMembersTableName
            }
            if ($SyncGroupTransitiveMembers) {
                $viewParams.TransitiveMembersTable = $groupTransitiveMembersTableName
            }
            if ($SyncGroupEligibleMembers) {
                $viewParams.EligibleMembersTable = $groupEligibleMembersTableName
            }
            if ($SyncGroupOwners) {
                $viewParams.OwnersTable = $groupOwnersTableName
            }

            Initialize-FGGroupMembershipViews @viewParams

            Write-SyncSuccess "Analysis views created"
        } catch {
            Write-SyncError "View creation failed" $_.Exception.Message
        }
    }
    #endregion

    #region Summary Report
    Write-SyncHeader "Sync Summary"

    $endTime = Get-Date
    $duration = $endTime - $script:SyncStats.StartTime

    Write-Host ""
    Write-Host "  Sync Duration: $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor Cyan
    Write-Host ""

    if ($SyncUsers -and $script:SyncStats.Users -ne $null) {
        Write-Host "  Users:                   $($script:SyncStats.Users)" -ForegroundColor White
    }
    if ($SyncGroups -and $script:SyncStats.Groups -ne $null) {
        Write-Host "  Groups:                  $($script:SyncStats.Groups)" -ForegroundColor White
    }
    if ($SyncGroupMembers -and $script:SyncStats.DirectMembers -ne $null) {
        Write-Host "  Direct Memberships:      $($script:SyncStats.DirectMembers)" -ForegroundColor White
    }
    if ($SyncGroupTransitiveMembers -and $script:SyncStats.TransitiveMembers -ne $null) {
        Write-Host "  Transitive Memberships:  $($script:SyncStats.TransitiveMembers)" -ForegroundColor White
    }
    if ($SyncGroupEligibleMembers -and $script:SyncStats.EligibleMembers -ne $null) {
        Write-Host "  Eligible Memberships:    $($script:SyncStats.EligibleMembers)" -ForegroundColor White
    }
    if ($SyncGroupOwners -and $script:SyncStats.Owners -ne $null) {
        Write-Host "  Group Ownerships:        $($script:SyncStats.Owners)" -ForegroundColor White
    }
    if ($SyncCatalogs -and $script:SyncStats.Catalogs -ne $null) {
        Write-Host "  Catalogs:                $($script:SyncStats.Catalogs)" -ForegroundColor White
    }
    if ($SyncAccessPackages -and $script:SyncStats.AccessPackages -ne $null) {
        Write-Host "  Access Packages:         $($script:SyncStats.AccessPackages)" -ForegroundColor White
    }
    if ($SyncAccessPackageAssignments -and $script:SyncStats.AccessPackageAssignments -ne $null) {
        Write-Host "  Package Assignments:     $($script:SyncStats.AccessPackageAssignments)" -ForegroundColor White
    }
    if ($SyncAccessPackageResourceRoleScopes -and $script:SyncStats.AccessPackageResourceRoleScopes -ne $null) {
        Write-Host "  Resource Role Scopes:    $($script:SyncStats.AccessPackageResourceRoleScopes)" -ForegroundColor White
    }

    if ($script:SyncStats.Errors.Count -gt 0) {
        Write-Host ""
        Write-Host "  Errors encountered: $($script:SyncStats.Errors.Count)" -ForegroundColor Red
        $script:SyncStats.Errors | ForEach-Object {
            Write-Host "    - $($_.Message)" -ForegroundColor Yellow
        }
    }
    #endregion

} catch {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
        Write-Host "Fatal Error" -ForegroundColor Red
        Write-Host "========================================" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        Write-Host ""
        Write-Host "Stack Trace:" -ForegroundColor Gray
        Write-Host $_.ScriptStackTrace -ForegroundColor Gray

        throw
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Sync Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Completed: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
}
