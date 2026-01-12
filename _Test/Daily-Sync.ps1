<#
.SYNOPSIS
Daily sync runbook for FortigiGraph - Syncs Microsoft Graph data to Azure SQL

.DESCRIPTION
This runbook provides an easy-to-use daily synchronization script that:
- Validates SQL Server exists (creates if needed on first run)
- Connects to Azure and Microsoft Graph
- Syncs all configured entity types (users, groups, memberships)
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

.EXAMPLE
.\Daily-Sync.ps1 -ConfigFile .\config.production.json

Runs full sync with all default options

.EXAMPLE
.\Daily-Sync.ps1 -ConfigFile .\config.production.json -UserFilter "accountEnabled eq true"

Syncs only enabled users, all other entities use defaults

.EXAMPLE
.\Daily-Sync.ps1 -ConfigFile .\config.production.json -SyncGroupEligibleMembers:$false

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
    [bool]$SyncGroupTransitiveMembers = $true,

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
    [string]$GroupFilter
)

$ErrorActionPreference = "Stop"

# Start transcript for logging
$configBaseName = [System.IO.Path]::GetFileNameWithoutExtension($ConfigFile)
$transcriptFile = Join-Path $PSScriptRoot "daily-sync-$configBaseName-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -Path $transcriptFile -Force | Out-Null

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "FortigiGraph Daily Sync Runbook" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "Config:  $ConfigFile" -ForegroundColor Cyan
Write-Host "Log:     $transcriptFile`n" -ForegroundColor Cyan

# Track sync statistics
$script:SyncStats = @{
    StartTime = Get-Date
    EndTime = $null
    Users = $null
    Groups = $null
    DirectMembers = $null
    TransitiveMembers = $null
    EligibleMembers = $null
    Owners = $null
    Errors = @()
    ConfigFile = $ConfigFile
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

    # Import module
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    $modulePath = Join-Path $moduleRoot "FortigiGraph.psd1"

    if (-not (Test-Path $modulePath)) {
        throw "FortigiGraph module not found at: $modulePath"
    }

    Import-Module $modulePath -Force
    Write-SyncSuccess "FortigiGraph module loaded"

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

    # Load secure credentials
    $secureConfigPath = Join-Path $PSScriptRoot "SecureConfig.ps1"
    if (-not (Test-Path $secureConfigPath)) {
        throw "SecureConfig.ps1 not found. Required for credential management."
    }
    . $secureConfigPath

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

    # Capture SQL connection details for runspaces
    $sqlConnectionString = $Global:FGSQLConnectionString
    $sqlServerName = $Global:FGSQLServerName
    $sqlDatabaseName = $Global:FGSQLDatabaseName

    # Create sync log table if it doesn't exist
    Write-SyncStep "Ensuring sync log table exists..."
    $syncLogTableSQL = @"
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'GraphSyncLog')
BEGIN
    CREATE TABLE dbo.GraphSyncLog (
        SyncRunId UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
        StartTime DATETIME2 NOT NULL,
        EndTime DATETIME2 NULL,
        DurationSeconds INT NULL,
        ConfigFile NVARCHAR(500) NULL,
        UsersCount INT NULL,
        GroupsCount INT NULL,
        DirectMembersCount INT NULL,
        TransitiveMembersCount INT NULL,
        EligibleMembersCount INT NULL,
        OwnersCount INT NULL,
        ErrorCount INT NULL,
        ErrorDetails NVARCHAR(MAX) NULL,
        Status NVARCHAR(50) NULL,
        CreatedDate DATETIME2 DEFAULT GETDATE()
    )
END
"@
    Invoke-FGSQLQuery -Query $syncLogTableSQL | Out-Null
    Write-SyncSuccess "Sync log table ready"
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

    if ($ParallelExecution) {
        # === PARALLEL EXECUTION MODE ===
        Write-SyncStep "Using parallel execution (up to 6 concurrent operations)"

        # Create runspace pool for parallel execution
    $runspacePool = [runspacefactory]::CreateRunspacePool(1, 6)
    $runspacePool.Open()

    # Array to track all running sync jobs
    $syncJobs = @()

    Write-SyncStep "Starting parallel sync operations..."

    # Sync Users (Job 1)
    if ($SyncUsers) {
        Write-SyncStep "Queuing users sync..."
        $syncParams = @{
            TableName = $userTableName
        }
        if ($UserFilter) {
            $syncParams.Filter = $UserFilter
        }
        if ($UserAdditionalAttributes) {
            $syncParams.AdditionalAttributes = $UserAdditionalAttributes
        }

        $powershell = [powershell]::Create().AddScript({
            param($syncParams, $tableName, $moduleRoot, $sqlConnString, $sqlServer, $sqlDb, $accessToken, $tenantId, $clientId, $clientSecret, $refreshToken)
            try {
                Import-Module (Join-Path $moduleRoot "FortigiGraph.psd1") -Force -ErrorAction Stop

                # Set SQL connection globals in this runspace
                $Global:FGSQLConnectionString = $sqlConnString
                $Global:FGSQLServerName = $sqlServer
                $Global:FGSQLDatabaseName = $sqlDb

                # Set Graph API globals in this runspace (including credentials for token refresh)
                $Global:AccessToken = $accessToken
                $Global:TenantId = $tenantId
                $Global:ClientId = $clientId
                $Global:ClientSecret = $clientSecret
                $Global:RefreshToken = $refreshToken

                Sync-FGUser @syncParams | Out-Null
                $count = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.$tableName" -AsScalar
                return @{ Success = $true; Count = $count; Type = "Users" }
            } catch {
                return @{ Success = $false; Error = $_.Exception.Message; Type = "Users" }
            }
        }).AddArgument($syncParams).AddArgument($userTableName).AddArgument($moduleRoot).AddArgument($sqlConnectionString).AddArgument($sqlServerName).AddArgument($sqlDatabaseName).AddArgument($graphAccessToken).AddArgument($graphTenantId).AddArgument($graphClientId).AddArgument($graphClientSecret).AddArgument($graphRefreshToken)

        $powershell.RunspacePool = $runspacePool
        $syncJobs += @{
            PowerShell = $powershell
            Handle = $powershell.BeginInvoke()
            Type = "Users"
        }
    }

    # Sync Groups (Job 2)
    if ($SyncGroups) {
        Write-SyncStep "Queuing groups sync..."
        $syncParams = @{
            TableName = $groupTableName
        }
        if ($GroupFilter) {
            $syncParams.Filter = $GroupFilter
        }

        $powershell = [powershell]::Create().AddScript({
            param($syncParams, $tableName, $moduleRoot, $sqlConnString, $sqlServer, $sqlDb, $accessToken, $tenantId, $clientId, $clientSecret, $refreshToken)
            try {
                Import-Module (Join-Path $moduleRoot "FortigiGraph.psd1") -Force -ErrorAction Stop

                # Set SQL connection globals in this runspace
                $Global:FGSQLConnectionString = $sqlConnString
                $Global:FGSQLServerName = $sqlServer
                $Global:FGSQLDatabaseName = $sqlDb

                # Set Graph API globals in this runspace (including credentials for token refresh)
                $Global:AccessToken = $accessToken
                $Global:TenantId = $tenantId
                $Global:ClientId = $clientId
                $Global:ClientSecret = $clientSecret
                $Global:RefreshToken = $refreshToken

                Sync-FGGroup @syncParams | Out-Null
                $count = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.$tableName" -AsScalar
                return @{ Success = $true; Count = $count; Type = "Groups" }
            } catch {
                return @{ Success = $false; Error = $_.Exception.Message; Type = "Groups" }
            }
        }).AddArgument($syncParams).AddArgument($groupTableName).AddArgument($moduleRoot).AddArgument($sqlConnectionString).AddArgument($sqlServerName).AddArgument($sqlDatabaseName).AddArgument($graphAccessToken).AddArgument($graphTenantId).AddArgument($graphClientId).AddArgument($graphClientSecret).AddArgument($graphRefreshToken)

        $powershell.RunspacePool = $runspacePool
        $syncJobs += @{
            PowerShell = $powershell
            Handle = $powershell.BeginInvoke()
            Type = "Groups"
        }
    }

    # Sync Group Members (Job 3)
    if ($SyncGroupMembers) {
        Write-SyncStep "Queuing direct group memberships sync..."
        $powershell = [powershell]::Create().AddScript({
            param($tableName, $moduleRoot, $sqlConnString, $sqlServer, $sqlDb, $accessToken, $tenantId, $clientId, $clientSecret, $refreshToken)
            try {
                Import-Module (Join-Path $moduleRoot "FortigiGraph.psd1") -Force -ErrorAction Stop

                # Set SQL connection globals in this runspace
                $Global:FGSQLConnectionString = $sqlConnString
                $Global:FGSQLServerName = $sqlServer
                $Global:FGSQLDatabaseName = $sqlDb

                # Set Graph API globals in this runspace (including credentials for token refresh)
                $Global:AccessToken = $accessToken
                $Global:TenantId = $tenantId
                $Global:ClientId = $clientId
                $Global:ClientSecret = $clientSecret
                $Global:RefreshToken = $refreshToken

                Sync-FGGroupMember -TableName $tableName | Out-Null
                $count = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.$tableName" -AsScalar
                return @{ Success = $true; Count = $count; Type = "DirectMembers" }
            } catch {
                return @{ Success = $false; Error = $_.Exception.Message; Type = "DirectMembers" }
            }
        }).AddArgument($groupMembersTableName).AddArgument($moduleRoot).AddArgument($sqlConnectionString).AddArgument($sqlServerName).AddArgument($sqlDatabaseName).AddArgument($graphAccessToken).AddArgument($graphTenantId).AddArgument($graphClientId).AddArgument($graphClientSecret).AddArgument($graphRefreshToken)

        $powershell.RunspacePool = $runspacePool
        $syncJobs += @{
            PowerShell = $powershell
            Handle = $powershell.BeginInvoke()
            Type = "DirectMembers"
        }
    }

    # Sync Group Transitive Members (Job 4)
    if ($SyncGroupTransitiveMembers) {
        Write-SyncStep "Queuing transitive group memberships sync..."
        $powershell = [powershell]::Create().AddScript({
            param($tableName, $moduleRoot, $sqlConnString, $sqlServer, $sqlDb, $accessToken, $tenantId, $clientId, $clientSecret, $refreshToken)
            try {
                Import-Module (Join-Path $moduleRoot "FortigiGraph.psd1") -Force -ErrorAction Stop

                # Set SQL connection globals in this runspace
                $Global:FGSQLConnectionString = $sqlConnString
                $Global:FGSQLServerName = $sqlServer
                $Global:FGSQLDatabaseName = $sqlDb

                # Set Graph API globals in this runspace (including credentials for token refresh)
                $Global:AccessToken = $accessToken
                $Global:TenantId = $tenantId
                $Global:ClientId = $clientId
                $Global:ClientSecret = $clientSecret
                $Global:RefreshToken = $refreshToken

                Sync-FGGroupTransitiveMember -TableName $tableName | Out-Null
                $count = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.$tableName" -AsScalar
                return @{ Success = $true; Count = $count; Type = "TransitiveMembers" }
            } catch {
                return @{ Success = $false; Error = $_.Exception.Message; Type = "TransitiveMembers" }
            }
        }).AddArgument($groupTransitiveMembersTableName).AddArgument($moduleRoot).AddArgument($sqlConnectionString).AddArgument($sqlServerName).AddArgument($sqlDatabaseName).AddArgument($graphAccessToken).AddArgument($graphTenantId).AddArgument($graphClientId).AddArgument($graphClientSecret).AddArgument($graphRefreshToken)

        $powershell.RunspacePool = $runspacePool
        $syncJobs += @{
            PowerShell = $powershell
            Handle = $powershell.BeginInvoke()
            Type = "TransitiveMembers"
        }
    }

    # Sync Group Eligible Members (Job 5)
    if ($SyncGroupEligibleMembers) {
        Write-SyncStep "Queuing eligible/PIM group memberships sync..."
        $powershell = [powershell]::Create().AddScript({
            param($tableName, $moduleRoot, $groupTableName, $syncGroups, $sqlConnString, $sqlServer, $sqlDb, $accessToken, $tenantId, $clientId, $clientSecret, $refreshToken)
            try {
                Import-Module (Join-Path $moduleRoot "FortigiGraph.psd1") -Force -ErrorAction Stop

                # Set SQL connection globals in this runspace
                $Global:FGSQLConnectionString = $sqlConnString
                $Global:FGSQLServerName = $sqlServer
                $Global:FGSQLDatabaseName = $sqlDb

                # Set Graph API globals in this runspace (including credentials for token refresh)
                $Global:AccessToken = $accessToken
                $Global:TenantId = $tenantId
                $Global:ClientId = $clientId
                $Global:ClientSecret = $clientSecret
                $Global:RefreshToken = $refreshToken

                # Check if there are PIM-enabled groups first
                $pimGroupCount = 0
                if ($syncGroups) {
                    try {
                        $pimGroupCount = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.$groupTableName WHERE isAssignableToRole = 1" -AsScalar
                    } catch {
                        # Unable to check, attempt sync anyway
                    }
                }

                if ($pimGroupCount -gt 0 -or -not $syncGroups) {
                    Sync-FGGroupEligibleMember -TableName $tableName | Out-Null
                    $count = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.$tableName" -AsScalar
                    return @{ Success = $true; Count = $count; Type = "EligibleMembers" }
                } else {
                    return @{ Success = $true; Count = 0; Type = "EligibleMembers"; Skipped = $true }
                }
            } catch {
                # PIM might not be available
                return @{ Success = $true; Count = 0; Type = "EligibleMembers"; Warning = $_.Exception.Message }
            }
        }).AddArgument($groupEligibleMembersTableName).AddArgument($moduleRoot).AddArgument($groupTableName).AddArgument($SyncGroups).AddArgument($sqlConnectionString).AddArgument($sqlServerName).AddArgument($sqlDatabaseName).AddArgument($graphAccessToken).AddArgument($graphTenantId).AddArgument($graphClientId).AddArgument($graphClientSecret).AddArgument($graphRefreshToken)

        $powershell.RunspacePool = $runspacePool
        $syncJobs += @{
            PowerShell = $powershell
            Handle = $powershell.BeginInvoke()
            Type = "EligibleMembers"
        }
    }

    # Sync Group Owners (Job 6)
    if ($SyncGroupOwners) {
        Write-SyncStep "Queuing group ownership relationships sync..."
        $powershell = [powershell]::Create().AddScript({
            param($tableName, $moduleRoot, $sqlConnString, $sqlServer, $sqlDb, $accessToken, $tenantId, $clientId, $clientSecret, $refreshToken)
            try {
                Import-Module (Join-Path $moduleRoot "FortigiGraph.psd1") -Force -ErrorAction Stop

                # Set SQL connection globals in this runspace
                $Global:FGSQLConnectionString = $sqlConnString
                $Global:FGSQLServerName = $sqlServer
                $Global:FGSQLDatabaseName = $sqlDb

                # Set Graph API globals in this runspace (including credentials for token refresh)
                $Global:AccessToken = $accessToken
                $Global:TenantId = $tenantId
                $Global:ClientId = $clientId
                $Global:ClientSecret = $clientSecret
                $Global:RefreshToken = $refreshToken

                Sync-FGGroupOwner -TableName $tableName | Out-Null
                $count = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.$tableName" -AsScalar
                return @{ Success = $true; Count = $count; Type = "Owners" }
            } catch {
                return @{ Success = $false; Error = $_.Exception.Message; Type = "Owners" }
            }
        }).AddArgument($groupOwnersTableName).AddArgument($moduleRoot).AddArgument($sqlConnectionString).AddArgument($sqlServerName).AddArgument($sqlDatabaseName).AddArgument($graphAccessToken).AddArgument($graphTenantId).AddArgument($graphClientId).AddArgument($graphClientSecret).AddArgument($graphRefreshToken)

        $powershell.RunspacePool = $runspacePool
        $syncJobs += @{
            PowerShell = $powershell
            Handle = $powershell.BeginInvoke()
            Type = "Owners"
        }
    }

    # Wait for all jobs to complete and collect results
    Write-SyncStep "Waiting for all sync operations to complete..."
    foreach ($job in $syncJobs) {
        $resultCollection = $job.PowerShell.EndInvoke($job.Handle)

        # EndInvoke returns a collection - get the actual hashtable result
        # The scriptblock's return statement is the last item in the collection
        $result = if ($resultCollection -is [array] -and $resultCollection.Count -gt 0) {
            $resultCollection[-1]  # Get the last item (our return hashtable)
        } else {
            $resultCollection
        }

        # Capture and display stream output from the runspace
        $hasStreamOutput = $false

        # Display Information stream (Write-Host messages get redirected here in PS 5.0+)
        if ($job.PowerShell.Streams.Information.Count -gt 0) {
            $hasStreamOutput = $true
            $job.PowerShell.Streams.Information | ForEach-Object {
                Write-Host "  ℹ [$($job.Type)] $($_.MessageData)" -ForegroundColor Cyan
            }
        }

        # Display Warning stream
        if ($job.PowerShell.Streams.Warning.Count -gt 0) {
            $hasStreamOutput = $true
            $job.PowerShell.Streams.Warning | ForEach-Object {
                Write-Host "  ⚠ [$($job.Type)] $_" -ForegroundColor Yellow
            }
        }

        # Display Error stream (non-terminating errors)
        if ($job.PowerShell.Streams.Error.Count -gt 0) {
            $hasStreamOutput = $true
            $job.PowerShell.Streams.Error | ForEach-Object {
                Write-Host "  ✗ [$($job.Type)] $($_.Exception.Message)" -ForegroundColor Red
                if ($_.ErrorDetails) {
                    Write-Host "    Details: $($_.ErrorDetails)" -ForegroundColor Gray
                }
            }
        }

        # Display Verbose stream
        if ($job.PowerShell.Streams.Verbose.Count -gt 0) {
            $hasStreamOutput = $true
            $job.PowerShell.Streams.Verbose | ForEach-Object {
                Write-Host "  VERBOSE: [$($job.Type)] $_" -ForegroundColor Gray
            }
        }

        # Display Debug stream
        if ($job.PowerShell.Streams.Debug.Count -gt 0) {
            $hasStreamOutput = $true
            $job.PowerShell.Streams.Debug | ForEach-Object {
                Write-Host "  DEBUG: [$($job.Type)] $_" -ForegroundColor DarkGray
            }
        }

        # Add separator if there was stream output
        if ($hasStreamOutput) {
            Write-Host ""
        }

        # Dispose of the PowerShell instance
        $job.PowerShell.Dispose()

        # Process the result
        if ($result.Success) {
            switch ($result.Type) {
                "Users" {
                    $script:SyncStats.Users = $result.Count
                    Write-SyncSuccess "Users synced: $($result.Count) (table: $userTableName)"
                }
                "Groups" {
                    $script:SyncStats.Groups = $result.Count
                    Write-SyncSuccess "Groups synced: $($result.Count) (table: $groupTableName)"
                }
                "DirectMembers" {
                    $script:SyncStats.DirectMembers = $result.Count
                    Write-SyncSuccess "Direct memberships synced: $($result.Count) (table: $groupMembersTableName)"
                }
                "TransitiveMembers" {
                    $script:SyncStats.TransitiveMembers = $result.Count
                    Write-SyncSuccess "Transitive memberships synced: $($result.Count) (table: $groupTransitiveMembersTableName)"
                }
                "EligibleMembers" {
                    $script:SyncStats.EligibleMembers = $result.Count
                    if ($result.Skipped) {
                        Write-SyncStep "No PIM-enabled groups found. Skipping eligible membership sync."
                    } elseif ($result.Warning) {
                        Write-Host "  ⚠ Eligible membership sync skipped: $($result.Warning)" -ForegroundColor Yellow
                    } else {
                        Write-SyncSuccess "Eligible memberships synced: $($result.Count) (table: $groupEligibleMembersTableName)"
                    }
                }
                "Owners" {
                    $script:SyncStats.Owners = $result.Count
                    Write-SyncSuccess "Group ownerships synced: $($result.Count) (table: $groupOwnersTableName)"
                }
            }
        } else {
            Write-SyncError "$($result.Type) sync failed" $result.Error
        }
    }

        # Clean up runspace pool
        $runspacePool.Close()
        $runspacePool.Dispose()

        Write-SyncSuccess "All parallel sync operations completed"
    } else {
        # === SEQUENTIAL EXECUTION MODE ===
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

        Write-SyncSuccess "All sequential sync operations completed"
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

            # Add performance indexes for faster view queries
            Write-SyncStep "Adding performance indexes to tables..."
            try {
                $indexParams = @{}
                if ($SyncGroupMembers) {
                    $indexParams.DirectMembersTable = $groupMembersTableName
                }
                if ($SyncGroupTransitiveMembers) {
                    $indexParams.TransitiveMembersTable = $groupTransitiveMembersTableName
                }
                if ($SyncGroupEligibleMembers) {
                    $indexParams.EligibleMembersTable = $groupEligibleMembersTableName
                }
                if ($SyncGroupOwners) {
                    $indexParams.OwnersTable = $groupOwnersTableName
                }

                $indexResult = Add-FGGroupMembershipIndexes @indexParams

                if ($indexResult.Created -gt 0) {
                    Write-SyncSuccess "Created $($indexResult.Created) new index(es)"
                }
                if ($indexResult.Skipped -gt 0) {
                    Write-Host "  ℹ $($indexResult.Skipped) index(es) already existed" -ForegroundColor Gray
                }
            } catch {
                Write-SyncError "Index creation failed" $_.Exception.Message
            }
        } catch {
            Write-SyncError "View creation failed" $_.Exception.Message
        }
    }
    #endregion

    #region Summary Report
    Write-SyncHeader "Sync Summary"

    $script:SyncStats.EndTime = Get-Date
    $duration = $script:SyncStats.EndTime - $script:SyncStats.StartTime
    $durationSeconds = [int]$duration.TotalSeconds

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

    if ($script:SyncStats.Errors.Count -gt 0) {
        Write-Host ""
        Write-Host "  Errors encountered: $($script:SyncStats.Errors.Count)" -ForegroundColor Red
        $script:SyncStats.Errors | ForEach-Object {
            Write-Host "    - $($_.Message)" -ForegroundColor Yellow
        }
    }

    # Store sync summary in SQL table
    Write-Host ""
    Write-SyncStep "Storing sync summary in database..."
    try {
        $errorDetails = if ($script:SyncStats.Errors.Count -gt 0) {
            ($script:SyncStats.Errors | ForEach-Object { "$($_.Message): $($_.Details)" }) -join "; "
        } else {
            $null
        }

        $status = if ($script:SyncStats.Errors.Count -eq 0) { "Success" }
                  elseif ($script:SyncStats.Errors.Count -lt 3) { "PartialSuccess" }
                  else { "Failed" }

        # Capture values before scriptblock (to avoid scope issues)
        $startTime = $script:SyncStats.StartTime
        $endTime = $script:SyncStats.EndTime
        $configFileName = [System.IO.Path]::GetFileName($script:SyncStats.ConfigFile)
        $usersCount = $script:SyncStats.Users
        $groupsCount = $script:SyncStats.Groups
        $directMembersCount = $script:SyncStats.DirectMembers
        $transitiveMembersCount = $script:SyncStats.TransitiveMembers
        $eligibleMembersCount = $script:SyncStats.EligibleMembers
        $ownersCount = $script:SyncStats.Owners
        $errorCount = $script:SyncStats.Errors.Count

        # Use Invoke-FGSQLCommand for proper parameterized query support
        # Note: Variables from outer scope are automatically captured by the scriptblock
        Invoke-FGSQLCommand -ScriptBlock {
            param($connection)

            $insertQuery = @"
INSERT INTO dbo.GraphSyncLog (
    StartTime,
    EndTime,
    DurationSeconds,
    ConfigFile,
    UsersCount,
    GroupsCount,
    DirectMembersCount,
    TransitiveMembersCount,
    EligibleMembersCount,
    OwnersCount,
    ErrorCount,
    ErrorDetails,
    Status
) VALUES (
    @StartTime,
    @EndTime,
    @DurationSeconds,
    @ConfigFile,
    @UsersCount,
    @GroupsCount,
    @DirectMembersCount,
    @TransitiveMembersCount,
    @EligibleMembersCount,
    @OwnersCount,
    @ErrorCount,
    @ErrorDetails,
    @Status
)
"@

            $cmd = $connection.CreateCommand()
            $cmd.CommandText = $insertQuery

            # Add parameters with proper SQL types
            $cmd.Parameters.AddWithValue("@StartTime", $startTime) | Out-Null
            $cmd.Parameters.AddWithValue("@EndTime", $endTime) | Out-Null
            $cmd.Parameters.AddWithValue("@DurationSeconds", $durationSeconds) | Out-Null
            $cmd.Parameters.AddWithValue("@ConfigFile", $configFileName) | Out-Null

            # Handle nullable counts - use DBNull if null
            $cmd.Parameters.AddWithValue("@UsersCount", $(if ($null -eq $usersCount) { [DBNull]::Value } else { $usersCount })) | Out-Null
            $cmd.Parameters.AddWithValue("@GroupsCount", $(if ($null -eq $groupsCount) { [DBNull]::Value } else { $groupsCount })) | Out-Null
            $cmd.Parameters.AddWithValue("@DirectMembersCount", $(if ($null -eq $directMembersCount) { [DBNull]::Value } else { $directMembersCount })) | Out-Null
            $cmd.Parameters.AddWithValue("@TransitiveMembersCount", $(if ($null -eq $transitiveMembersCount) { [DBNull]::Value } else { $transitiveMembersCount })) | Out-Null
            $cmd.Parameters.AddWithValue("@EligibleMembersCount", $(if ($null -eq $eligibleMembersCount) { [DBNull]::Value } else { $eligibleMembersCount })) | Out-Null
            $cmd.Parameters.AddWithValue("@OwnersCount", $(if ($null -eq $ownersCount) { [DBNull]::Value } else { $ownersCount })) | Out-Null

            $cmd.Parameters.AddWithValue("@ErrorCount", $errorCount) | Out-Null
            $cmd.Parameters.AddWithValue("@ErrorDetails", $(if ($errorDetails) { $errorDetails } else { [DBNull]::Value })) | Out-Null
            $cmd.Parameters.AddWithValue("@Status", $status) | Out-Null

            # Execute the insert
            $rowsAffected = $cmd.ExecuteNonQuery()
            return $rowsAffected
        } | Out-Null

        Write-SyncSuccess "Sync summary stored in GraphSyncLog table"
    } catch {
        Write-SyncError "Failed to store sync summary in database" $_.Exception.Message
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

    Stop-Transcript
    exit 1
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Sync Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Completed: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "Log File:  $transcriptFile`n" -ForegroundColor Cyan

Stop-Transcript
exit 0
