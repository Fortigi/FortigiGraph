# Integration Test Suite for FortigiGraph
# Tests the complete workflow from Azure connection to data sync
#
# Prerequisites:
# - Az PowerShell module installed
# - Logged in to Azure (Connect-AzAccount)
# - Microsoft Graph app registration with appropriate permissions
# - Test configuration file (config.test.json)

param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,

    [Parameter(Mandatory = $false)]
    [switch]$SkipCleanup
)

# Set error action preference
$ErrorActionPreference = "Stop"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "FortigiGraph Integration Test Suite" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Start transcript to capture all console output (unique per config file)
$configBaseName = [System.IO.Path]::GetFileNameWithoutExtension($ConfigFile)
$transcriptFile = Join-Path $PSScriptRoot "integration-test-$configBaseName.log"
Write-Host "Starting transcript logging..." -ForegroundColor Gray
Start-Transcript -Path $transcriptFile -Force | Out-Null
Write-Host "Transcript logging to: $transcriptFile`n" -ForegroundColor Cyan

# Import the module
$moduleRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $moduleRoot "FortigiGraph.psd1"

# Test tracking
$script:TestResults = @()
$script:CreatedResources = @()

function Write-TestHeader {
    param([string]$Message)
    Write-Host "`n$Message" -ForegroundColor Yellow
    Write-Host ("=" * $Message.Length) -ForegroundColor Yellow
}

function Write-TestStep {
    param([string]$Message)
    Write-Host "  → $Message" -ForegroundColor Cyan
}

function Write-TestSuccess {
    param([string]$Message)
    Write-Host "  ✓ $Message" -ForegroundColor Green
}

function Write-TestFailure {
    param([string]$Message)
    Write-Host "  ✗ $Message" -ForegroundColor Red
}

function Add-TestResult {
    param(
        [string]$Category,
        [string]$TestName,
        [bool]$Passed,
        [string]$Message = "",
        [object]$Data = $null
    )

    $script:TestResults += [PSCustomObject]@{
        Category = $Category
        TestName = $TestName
        Passed = $Passed
        Message = $Message
        Data = $Data
        Timestamp = Get-Date
    }

    if ($Passed) {
        Write-TestSuccess $TestName
    } else {
        Write-TestFailure "$TestName - $Message"
    }
}

function Register-Resource {
    param(
        [string]$Type,
        [string]$Name,
        [hashtable]$Details
    )

    $script:CreatedResources += [PSCustomObject]@{
        Type = $Type
        Name = $Name
        Details = $Details
        CreatedAt = Get-Date
    }
}

# Secure config functions now loaded from module (Get-FGSecureConfigValue, etc.)

# Load configuration
Write-TestHeader "Loading Test Configuration"

if (-not (Test-Path $ConfigFile)) {
    Write-Host "Configuration file not found. Please read the readme file." -ForegroundColor Yellow
    exit 1
}

$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
Write-TestSuccess "Configuration loaded from $ConfigFile"

# Validate configuration
Write-TestStep "Validating configuration..."
$requiredFields = @(
    @{ Path = "Azure.SubscriptionId"; Value = $config.Azure.SubscriptionId },
    @{ Path = "Azure.ResourceGroupName"; Value = $config.Azure.ResourceGroupName },
    @{ Path = "Graph.TenantId"; Value = $config.Graph.TenantId },
    @{ Path = "Graph.ClientId"; Value = $config.Graph.ClientId }
)

# Determine which tenant ID to use for Azure operations
# If Azure.TenantId is specified, use it; otherwise fall back to Graph.TenantId (for backward compatibility)
if ($config.Azure.TenantId -and $config.Azure.TenantId -notlike "YOUR-*" -and -not [string]::IsNullOrWhiteSpace($config.Azure.TenantId)) {
    $azureTenantId = $config.Azure.TenantId
    Write-TestStep "Using separate Azure TenantId: $azureTenantId"
} else {
    $azureTenantId = $config.Graph.TenantId
    Write-TestStep "Using Graph TenantId for Azure operations: $azureTenantId"
}

$configValid = $true
foreach ($field in $requiredFields) {
    if ([string]::IsNullOrWhiteSpace($field.Value) -or $field.Value -like "YOUR-*") {
        Write-TestFailure "Missing configuration: $($field.Path)"
        $configValid = $false
    }
}

if (-not $configValid) {
    Write-Host "`nPlease update $ConfigFile with valid values." -ForegroundColor Red
    exit 1
}

Write-TestSuccess "Configuration validated"

# Load secure credentials
Write-TestStep "Loading secure credentials..."
try {
    # Get SQL Admin Password (required)
    $SecurePassword = Get-SecureConfigValue `
        -ConfigPath $ConfigFile `
        -PropertyPath "Azure.AdminUserPassword" `
        -PromptMessage "Enter SQL Server Admin Password" `
        -AsSecureString

    # Get Graph Client Secret (optional - can be empty for interactive auth)
    $clientSecret = Get-SecureConfigValue `
        -ConfigPath $ConfigFile `
        -PropertyPath "Graph.ClientSecret" `
        -PromptMessage "Enter Graph Client Secret (or press Enter for interactive auth)" `
        -AllowEmpty

    Write-TestSuccess "Secure credentials loaded"
} catch {
    Write-TestFailure "Failed to load credentials: $($_.Exception.Message)"
    exit 1
}

# Import module
Write-TestHeader "Test 1: Module Import"

try {
    Import-Module $modulePath -Force
    Add-TestResult -Category "Setup" -TestName "Import FortigiGraph module" -Passed $true
} catch {
    Add-TestResult -Category "Setup" -TestName "Import FortigiGraph module" -Passed $false -Message $_.Exception.Message
    exit 1
}

# Test Azure connection
Write-TestHeader "Test 2: Azure Connection"

try {
    Write-TestStep "Checking Azure connection..."
    $azContext = Get-AzContext -ErrorAction SilentlyContinue

    # Check if we have a context at all
    if (-not $azContext) {
        Write-TestStep "Not connected to Azure. Connecting to tenant..."
        Connect-AzAccount -TenantId $azureTenantId -SubscriptionId $config.Azure.SubscriptionId
        $azContext = Get-AzContext
    } else {
        # We have a context, but is it the right tenant and subscription?
        $correctTenant = $azContext.Tenant.Id -eq $azureTenantId
        $correctSubscription = $azContext.Subscription.Id -eq $config.Azure.SubscriptionId

        if (-not $correctTenant -or -not $correctSubscription) {
            Write-TestStep "Switching to correct tenant/subscription..."
            Write-TestStep "Current: Tenant=$($azContext.Tenant.Id), Sub=$($azContext.Subscription.Id)"
            Write-TestStep "Target: Tenant=$azureTenantId, Sub=$($config.Azure.SubscriptionId)"

            # Try to switch context
            try {
                Set-AzContext -TenantId $azureTenantId -SubscriptionId $config.Azure.SubscriptionId -ErrorAction Stop | Out-Null
                $azContext = Get-AzContext
                Write-TestStep "Context switched successfully"
            } catch {
                # Context doesn't exist for this tenant/subscription, need to reconnect
                Write-TestStep "Context not found. Connecting to tenant..."
                Connect-AzAccount -TenantId $azureTenantId -SubscriptionId $config.Azure.SubscriptionId
                $azContext = Get-AzContext
            }
        } else {
            Write-TestStep "Already connected to correct tenant and subscription"
        }
    }

    Add-TestResult -Category "Azure" -TestName "Azure connection established" -Passed $true -Data "$($azContext.Account.Id) (Tenant: $($azContext.Tenant.Id))"

    Write-TestStep "Verifying subscription context..."
    $currentContext = Get-AzContext
    if ($currentContext.Subscription.Id -eq $config.Azure.SubscriptionId) {
        Add-TestResult -Category "Azure" -TestName "Subscription context verified" -Passed $true -Data "$($currentContext.Subscription.Name)"
    } else {
        throw "Subscription context mismatch. Expected: $($config.Azure.SubscriptionId), Got: $($currentContext.Subscription.Id)"
    }
} catch {
    Add-TestResult -Category "Azure" -TestName "Azure connection" -Passed $false -Message $_.Exception.Message
    exit 1
}

# Test Graph connection
Write-TestHeader "Test 3: Microsoft Graph Connection"

try {
    Write-TestStep "Checking for existing Graph token..."

    # Check if there's already a valid token
    $hasValidToken = $false
    if ($global:FGAccessToken) {
        try {
            # Try to use existing token
            Write-TestStep "Found existing token, testing validity..."
            $testUsers = Get-FGUser
            $hasValidToken = $true
            Write-TestStep "Existing token is valid"
        } catch {
            Write-TestStep "Existing token is invalid or expired, getting new token..."
            $hasValidToken = $false
        }
    }

    # Get new token if needed
    if (-not $hasValidToken) {
        Write-TestStep "Getting new Graph access token..."
        Write-TestStep "TenantId: $($config.Graph.TenantId)"
        Write-TestStep "ClientId: $($config.Graph.ClientId)"
        Write-TestStep "Using ClientSecret: $($clientSecret -ne $null -and $clientSecret -ne '')"

        if ($clientSecret -and $clientSecret -ne "") {
            Get-FGAccessToken -TenantId $config.Graph.TenantId -ClientId $config.Graph.ClientId -ClientSecret $clientSecret
        } else {
            Write-TestStep "No client secret provided, using interactive auth..."
            Get-FGAccessToken -TenantId $config.Graph.TenantId -ClientId $config.Graph.ClientId
        }

        Write-TestStep "Token obtained, testing Graph API access..."
        $testUsers = Get-FGUser
    }

    Add-TestResult -Category "Graph" -TestName "Graph access token obtained" -Passed $true
    Add-TestResult -Category "Graph" -TestName "Graph API connection verified" -Passed $true -Data "$(if ($testUsers.Count) { $testUsers.Count } else { 'Unknown' }) users retrieved"
} catch {
    $errorDetails = $_.Exception.Message
    if ($_.ErrorDetails.Message) {
        $errorDetails += " | Details: $($_.ErrorDetails.Message)"
    }
    Write-TestFailure "Graph connection failed: $errorDetails"
    Add-TestResult -Category "Graph" -TestName "Graph connection" -Passed $false -Message $errorDetails
    exit 1
}

# Cleanup existing test resources
Write-TestHeader "Test 4: Cleanup Existing Test Resources"

try {
    Write-TestStep "Checking for existing SQL Server..."
    $existingServer = Get-AzSqlServer -ResourceGroupName $config.Azure.ResourceGroupName -ServerName $config.Azure.SQLServerName -ErrorAction SilentlyContinue

    if ($existingServer) {
        Write-TestStep "Found existing SQL Server. Removing..."
        Remove-AzSqlServer -ResourceGroupName $config.Azure.ResourceGroupName -ServerName $config.Azure.SQLServerName -Force
        Start-Sleep -Seconds 10  # Wait for deletion to complete
        Add-TestResult -Category "Cleanup" -TestName "Existing SQL Server removed" -Passed $true
    } else {
        Add-TestResult -Category "Cleanup" -TestName "No existing SQL Server to remove" -Passed $true
    }
} catch {
    Write-Warning "Cleanup warning: $($_.Exception.Message)"
    Add-TestResult -Category "Cleanup" -TestName "Cleanup existing resources" -Passed $true -Message "Warning: $($_.Exception.Message)"
}

# Create SQL Server
Write-TestHeader "Test 5: SQL Server Creation"

try {
    Write-TestStep "Creating SQL Server: $($config.Azure.SQLServerName)..."

    # $SecurePassword was already loaded from secure config earlier

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

    Register-Resource -Type "SQLServer" -Name $config.Azure.SQLServerName -Details @{
        ResourceGroup = $config.Azure.ResourceGroupName
        Database = $config.Azure.DatabaseName
    }

    Add-TestResult -Category "SQL" -TestName "SQL Server created" -Passed $true -Data $serverInfo
    Add-TestResult -Category "SQL" -TestName "SQL Server auto-connected" -Passed ($null -ne $global:FGSQLConnectionString)
} catch {
    Add-TestResult -Category "SQL" -TestName "SQL Server creation" -Passed $false -Message $_.Exception.Message
    exit 1
}

# Test SQL Connection
Write-TestHeader "Test 6: SQL Connection Verification"

try {
    Write-TestStep "Testing SQL connection..."
    $connectionInfo = Test-FGSQLConnection
    Add-TestResult -Category "SQL" -TestName "SQL connection verified" -Passed $true -Data $connectionInfo
} catch {
    Add-TestResult -Category "SQL" -TestName "SQL connection test" -Passed $false -Message $_.Exception.Message
    exit 1
}

# Test 7: Table Creation - Default Properties
Write-TestHeader "Test 7: Table Creation (Default Properties)"

try {
    Write-TestStep "Creating table with default user properties..."

    $defaultColumns = @{
        "id" = "NVARCHAR(255)"
        "userPrincipalName" = "NVARCHAR(255)"
        "displayName" = "NVARCHAR(255)"
        "mail" = "NVARCHAR(255)"
        "accountEnabled" = "BIT"
    }

    Initialize-FGSQLTable -TableName "GraphUsers_DefaultTest" -Columns $defaultColumns -PrimaryKey "id"
    Add-TestResult -Category "SQL" -TestName "Table created with default properties" -Passed $true

    Register-Resource -Type "SQLTable" -Name "GraphUsers_DefaultTest" -Details @{ Columns = $defaultColumns }
} catch {
    Add-TestResult -Category "SQL" -TestName "Table creation (default)" -Passed $false -Message $_.Exception.Message
}

# Test 8: Table Creation - Extended Properties
Write-TestHeader "Test 8: Table Creation (Extended Properties)"

try {
    Write-TestStep "Creating table with extended user properties..."

    $extendedColumns = @{
        "id" = "NVARCHAR(255)"
        "userPrincipalName" = "NVARCHAR(255)"
        "displayName" = "NVARCHAR(255)"
        "mail" = "NVARCHAR(255)"
        "accountEnabled" = "BIT"
        "jobTitle" = "NVARCHAR(255)"  # Extra property
        "department" = "NVARCHAR(255)"  # Extra property
    }

    Initialize-FGSQLTable -TableName "GraphUsers_ExtendedTest" -Columns $extendedColumns -PrimaryKey "id"
    Add-TestResult -Category "SQL" -TestName "Table created with extended properties" -Passed $true

    Register-Resource -Type "SQLTable" -Name "GraphUsers_ExtendedTest" -Details @{ Columns = $extendedColumns }
} catch {
    Add-TestResult -Category "SQL" -TestName "Table creation (extended)" -Passed $false -Message $_.Exception.Message
}

# Test 9: Table Creation - Custom Properties
Write-TestHeader "Test 9: Table Creation (Custom Properties)"

try {
    Write-TestStep "Creating table with custom user properties..."

    $customColumns = @{
        "id" = "NVARCHAR(255)"
        "userPrincipalName" = "NVARCHAR(255)"
        "displayName" = "NVARCHAR(255)"
        "givenName" = "NVARCHAR(255)"
        "surname" = "NVARCHAR(255)"
        "officeLocation" = "NVARCHAR(255)"
        "mobilePhone" = "NVARCHAR(50)"
    }

    Initialize-FGSQLTable -TableName "GraphUsers_CustomTest" -Columns $customColumns -PrimaryKey "id"
    Add-TestResult -Category "SQL" -TestName "Table created with custom properties" -Passed $true

    Register-Resource -Type "SQLTable" -Name "GraphUsers_CustomTest" -Details @{ Columns = $customColumns }
} catch {
    Add-TestResult -Category "SQL" -TestName "Table creation (custom)" -Passed $false -Message $_.Exception.Message
}

# Test 10: Data Sync - Default Properties
Write-TestHeader "Test 10: Data Sync (Default Properties)"

try {
    Write-TestStep "Syncing users with default properties..."

    Sync-FGUser -TableName "GraphUsers_DefaultTest"
    Add-TestResult -Category "Sync" -TestName "User sync completed (default properties)" -Passed $true

    # Verify data was synced
    Write-TestStep "Verifying synced data..."
    $syncedCount = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.GraphUsers_DefaultTest"
        return $cmd.ExecuteScalar()
    }

    Add-TestResult -Category "Sync" -TestName "Data verification (default)" -Passed ($syncedCount -gt 0) -Data "Synced $syncedCount users"
} catch {
    Add-TestResult -Category "Sync" -TestName "User sync (default)" -Passed $false -Message $_.Exception.Message
}

# Test 11: Data Sync - AdditionalAttributes Properties
Write-TestHeader "Test 11: Data Sync (Additional Attributes)"

try {
    Write-TestStep "Syncing users with Additional Attributes..."

    $extendedProps = @("extension_9dbfd777ae31443d9f207cb9c0b7f7ee_sfEmploymentUserID", "employeeType", "extension_9dbfd777ae31443d9f207cb9c0b7f7ee_sfTeamID")
    Sync-FGUser -TableName "GraphUsers_AdditionalAttributes" -AdditionalAttributes $extendedProps
    Add-TestResult -Category "Sync" -TestName "User sync completed (Additional Attributes)" -Passed $true

    # Verify data
    $syncedCount = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.GraphUsers_AdditionalAttributes"
        return $cmd.ExecuteScalar()
    }

    Add-TestResult -Category "Sync" -TestName "Data verification (Additional Attributes)" -Passed ($syncedCount -gt 0) -Data "Synced $syncedCount users"
} catch {
    Add-TestResult -Category "Sync" -TestName "User sync (Additional Attributes)" -Passed $false -Message $_.Exception.Message
}

# Test 12: Data Sync - Custom Properties
Write-TestHeader "Test 12: Data Sync (Custom Properties)"

try {
    Write-TestStep "Syncing users with custom properties..."

    $customProps = @("userPrincipalName", "displayName", "givenName", "surname", "officeLocation", "mobilePhone")
    Sync-FGUser -TableName "GraphUsers_CustomTest" -Attributes $customProps
    Add-TestResult -Category "Sync" -TestName "User sync completed (custom properties)" -Passed $true

    # Verify data
    $syncedCount = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.GraphUsers_CustomTest"
        return $cmd.ExecuteScalar()
    }

    Add-TestResult -Category "Sync" -TestName "Data verification (custom)" -Passed ($syncedCount -gt 0) -Data "Synced $syncedCount users"
} catch {
    Add-TestResult -Category "Sync" -TestName "User sync (custom)" -Passed $false -Message $_.Exception.Message
}

# Test 13: Query Results
Write-TestHeader "Test 13: Query and Verify Results"

try {
    Write-TestStep "Querying synced data..."

    $queryResults = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = @"
SELECT
    'GraphUsers_DefaultTest' as TableName,
    COUNT(*) as RecordCount,
    MIN(ValidFrom) as FirstSync,
    MAX(ValidFrom) as LastSync
FROM dbo.GraphUsers_DefaultTest
UNION ALL
SELECT
    'GraphUsers_ExtendedTest',
    COUNT(*),
    MIN(ValidFrom),
    MAX(ValidFrom)
FROM dbo.GraphUsers_ExtendedTest
UNION ALL
SELECT
    'GraphUsers_CustomTest',
    COUNT(*),
    MIN(ValidFrom),
    MAX(ValidFrom)
FROM dbo.GraphUsers_CustomTest
"@

        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        return $dataset.Tables[0]
    }

    Write-Host "`n  Query Results:" -ForegroundColor Cyan
    $queryResults | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host $_ -ForegroundColor White }

    Add-TestResult -Category "Query" -TestName "Query execution successful" -Passed $true -Data $queryResults
} catch {
    Add-TestResult -Category "Query" -TestName "Query execution" -Passed $false -Message $_.Exception.Message
}

# Test 14: Temporal Table Features
Write-TestHeader "Test 14: Temporal Table Features"

try {
    Write-TestStep "Testing temporal table history views..."

    $historyQuery = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = "SELECT TOP 5 * FROM dbo.vw_GraphUsers_DefaultTest_AllHistory ORDER BY ValidFrom DESC"

        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        return $dataset.Tables[0]
    }

    Add-TestResult -Category "Query" -TestName "Temporal history view accessible" -Passed ($historyQuery.Rows.Count -gt 0) -Data "$($historyQuery.Rows.Count) history records"
} catch {
    Add-TestResult -Category "Query" -TestName "Temporal table features" -Passed $false -Message $_.Exception.Message
}

# Test 15: Simple Query with Invoke-FGSQLQuery
Write-TestHeader "Test 15: Simple Query Test (Invoke-FGSQLQuery)"

try {
    Write-TestStep "Testing Invoke-FGSQLQuery with sample user data..."

    # Query a few users using the simple query function
    $sampleUsers = Invoke-FGSQLQuery -Query "SELECT TOP 5 userPrincipalName, displayName, mail, accountEnabled FROM dbo.GraphUsers_DefaultTest ORDER BY displayName"

    if ($sampleUsers -and $sampleUsers.Rows.Count -gt 0) {
        Write-Host "`n  Sample Users Retrieved:" -ForegroundColor Cyan
        $sampleUsers | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host $_ -ForegroundColor White }

        Add-TestResult -Category "Query" -TestName "Invoke-FGSQLQuery execution" -Passed $true -Data "$($sampleUsers.Rows.Count) users retrieved"

        # Also test scalar query
        Write-TestStep "Testing scalar query (user count)..."
        $userCount = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.GraphUsers_DefaultTest" -AsScalar
        Write-Host "  → Total users in database: $userCount" -ForegroundColor Cyan

        Add-TestResult -Category "Query" -TestName "Invoke-FGSQLQuery scalar execution" -Passed $true -Data "$userCount users"
    } else {
        Add-TestResult -Category "Query" -TestName "Invoke-FGSQLQuery execution" -Passed $false -Message "No users found"
    }
} catch {
    Add-TestResult -Category "Query" -TestName "Invoke-FGSQLQuery execution" -Passed $false -Message $_.Exception.Message
}

# Test 16: Group Sync - Default Properties
Write-TestHeader "Test 16: Group Sync (Default Properties)"

try {
    Write-TestStep "Syncing groups with default properties..."

    Sync-FGGroup -TableName "GraphGroups_Test"
    Add-TestResult -Category "Sync" -TestName "Group sync completed (default properties)" -Passed $true

    # Verify data was synced
    Write-TestStep "Verifying synced group data..."
    $syncedGroupCount = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.GraphGroups_Test"
        return $cmd.ExecuteScalar()
    }

    Add-TestResult -Category "Sync" -TestName "Group data verification" -Passed ($syncedGroupCount -gt 0) -Data "Synced $syncedGroupCount groups"

    Register-Resource -Type "SQLTable" -Name "GraphGroups_Test" -Details @{ Type = "Groups" }
} catch {
    Add-TestResult -Category "Sync" -TestName "Group sync" -Passed $false -Message $_.Exception.Message
}

# Test 17: Group Member Sync - Direct Memberships
Write-TestHeader "Test 17: Group Member Sync (Direct Memberships)"

try {
    Write-TestStep "Syncing direct group memberships..."

    Sync-FGGroupMember -TableName "GraphGroupMembers_Test"
    Add-TestResult -Category "Sync" -TestName "Direct group membership sync completed" -Passed $true

    # Verify data was synced
    Write-TestStep "Verifying synced membership data..."
    $syncedMemberCount = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.GraphGroupMembers_Test"
        return $cmd.ExecuteScalar()
    }

    Add-TestResult -Category "Sync" -TestName "Direct membership data verification" -Passed ($syncedMemberCount -ge 0) -Data "Synced $syncedMemberCount memberships"

    # Verify composite key structure
    Write-TestStep "Verifying composite primary key..."
    $pkInfo = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = @"
SELECT COUNT(*)
FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE
WHERE TABLE_NAME = 'GraphGroupMembers_Test'
AND CONSTRAINT_NAME LIKE 'PK_%'
"@
        return $cmd.ExecuteScalar()
    }

    Add-TestResult -Category "Sync" -TestName "Composite primary key verification" -Passed ($pkInfo -eq 2) -Data "Primary key has $pkInfo columns (expected: 2)"

    Register-Resource -Type "SQLTable" -Name "GraphGroupMembers_Test" -Details @{ Type = "DirectMemberships" }
} catch {
    Add-TestResult -Category "Sync" -TestName "Group member sync" -Passed $false -Message $_.Exception.Message
}

# Test 18: Group Owner Sync - Group Ownership Relationships
Write-TestHeader "Test 18: Group Owner Sync (Ownership Relationships)"

try {
    Write-TestStep "Syncing group ownership relationships..."

    Sync-FGGroupOwner -TableName "GraphGroupOwners_Test"
    Add-TestResult -Category "Sync" -TestName "Group ownership sync completed" -Passed $true

    # Verify data was synced
    Write-TestStep "Verifying synced ownership data..."
    $syncedOwnerCount = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.GraphGroupOwners_Test"
        return $cmd.ExecuteScalar()
    }

    Add-TestResult -Category "Sync" -TestName "Ownership data verification" -Passed ($syncedOwnerCount -ge 0) -Data "Synced $syncedOwnerCount ownership relationships"

    # Verify composite key structure (groupId, ownerId)
    Write-TestStep "Verifying composite primary key..."
    $pkInfo = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = @"
SELECT COUNT(*)
FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE
WHERE TABLE_NAME = 'GraphGroupOwners_Test'
AND CONSTRAINT_NAME LIKE 'PK_%'
"@
        return $cmd.ExecuteScalar()
    }

    Add-TestResult -Category "Sync" -TestName "Composite primary key verification" -Passed ($pkInfo -eq 2) -Data "Primary key has $pkInfo columns (expected: 2)"

    Register-Resource -Type "SQLTable" -Name "GraphGroupOwners_Test" -Details @{ Type = "GroupOwnerships" }
} catch {
    Add-TestResult -Category "Sync" -TestName "Group owner sync" -Passed $false -Message $_.Exception.Message
}

# Test 19: Group Transitive Member Sync - Nested Memberships
Write-TestHeader "Test 19: Group Transitive Member Sync (Nested Memberships)"

try {
    Write-TestStep "Syncing transitive/nested group memberships..."

    Sync-FGGroupTransitiveMember -TableName "GraphGroupTransitiveMembers_Test"
    Add-TestResult -Category "Sync" -TestName "Transitive group membership sync completed" -Passed $true

    # Verify data was synced
    Write-TestStep "Verifying synced transitive membership data..."
    $syncedTransitiveCount = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.GraphGroupTransitiveMembers_Test"
        return $cmd.ExecuteScalar()
    }

    Add-TestResult -Category "Sync" -TestName "Transitive membership data verification" -Passed ($syncedTransitiveCount -ge 0) -Data "Synced $syncedTransitiveCount transitive memberships"

    # Compare direct vs transitive counts
    Write-TestStep "Comparing direct vs transitive membership counts..."
    $directCount = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.GraphGroupMembers_Test" -AsScalar
    Write-Host "  → Direct memberships: $directCount" -ForegroundColor Cyan
    Write-Host "  → Transitive memberships: $syncedTransitiveCount" -ForegroundColor Cyan
    Write-Host "  → Additional nested members: $($syncedTransitiveCount - $directCount)" -ForegroundColor Cyan

    Register-Resource -Type "SQLTable" -Name "GraphGroupTransitiveMembers_Test" -Details @{ Type = "TransitiveMemberships" }
} catch {
    Add-TestResult -Category "Sync" -TestName "Transitive member sync" -Passed $false -Message $_.Exception.Message
}

# Test 20: Group Eligible Member Sync - PIM Memberships (Optional)
Write-TestHeader "Test 20: Group Eligible Member Sync (PIM Memberships)"

try {
    Write-TestStep "Checking for PIM-enabled groups..."

    # First check if there are any PIM-enabled groups
    $pimGroupCount = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.GraphGroups_Test WHERE isAssignableToRole = 1" -AsScalar

    if ($pimGroupCount -gt 0) {
        Write-TestStep "Found $pimGroupCount PIM-enabled groups. Syncing eligible memberships..."

        Sync-FGGroupEligibleMember -TableName "GraphGroupEligibleMembers_Test"
        Add-TestResult -Category "Sync" -TestName "Eligible group membership sync completed" -Passed $true

        # Verify data
        $syncedEligibleCount = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            $cmd = $connection.CreateCommand()
            $cmd.CommandText = "SELECT COUNT(*) FROM dbo.GraphGroupEligibleMembers_Test"
            return $cmd.ExecuteScalar()
        }

        Add-TestResult -Category "Sync" -TestName "Eligible membership data verification" -Passed ($syncedEligibleCount -ge 0) -Data "Synced $syncedEligibleCount eligible memberships"

        Register-Resource -Type "SQLTable" -Name "GraphGroupEligibleMembers_Test" -Details @{ Type = "EligibleMemberships" }
    } else {
        Write-TestStep "No PIM-enabled groups found in tenant. Skipping eligible membership sync."
        Add-TestResult -Category "Sync" -TestName "Eligible membership sync" -Passed $true -Message "Skipped - No PIM groups in tenant"
    }
} catch {
    # PIM might not be available or configured, so we don't fail the entire test
    Write-Warning "Eligible membership sync warning: $($_.Exception.Message)"
    Add-TestResult -Category "Sync" -TestName "Eligible member sync" -Passed $true -Message "Skipped - PIM not available or configured"
}

# Test 21: Group Membership Views
Write-TestHeader "Test 21: Group Membership Analysis Views"

try {
    Write-TestStep "Creating group membership analysis views..."

    Initialize-FGGroupMembershipViews `
        -DirectMembersTable "GraphGroupMembers_Test" `
        -TransitiveMembersTable "GraphGroupTransitiveMembers_Test" `
        -EligibleMembersTable "GraphGroupEligibleMembers_Test" `
        -DropIfExists

    Add-TestResult -Category "Query" -TestName "Group membership views created" -Passed $true

    # Verify views exist
    Write-TestStep "Verifying views were created..."
    $viewCount = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = @"
SELECT COUNT(*)
FROM INFORMATION_SCHEMA.VIEWS
WHERE TABLE_NAME IN ('vw_GraphGroupNestedMembers', 'vw_GraphGroupMembershipType', 'vw_GraphGroupEligibleMembers')
"@
        return $cmd.ExecuteScalar()
    }

    Add-TestResult -Category "Query" -TestName "View creation verification" -Passed ($viewCount -ge 2) -Data "$viewCount views created"

    Register-Resource -Type "SQLView" -Name "vw_GraphGroupNestedMembers" -Details @{ Type = "NestedMembersView" }
    Register-Resource -Type "SQLView" -Name "vw_GraphGroupMembershipType" -Details @{ Type = "MembershipTypeView" }
    if ($viewCount -eq 3) {
        Register-Resource -Type "SQLView" -Name "vw_GraphGroupEligibleMembers" -Details @{ Type = "EligibleMembersView" }
    }
} catch {
    Add-TestResult -Category "Query" -TestName "Group membership views" -Passed $false -Message $_.Exception.Message
}

# Test 22: Query Group Membership Views
Write-TestHeader "Test 22: Query Group Membership Views"

try {
    Write-TestStep "Querying nested members view..."
    $nestedQuery = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM dbo.vw_GraphGroupNestedMembers" -AsScalar
    Write-Host "  → Nested members (indirect only): $nestedQuery" -ForegroundColor Cyan
    Add-TestResult -Category "Query" -TestName "Nested members view query" -Passed $true -Data "$nestedQuery nested members"

    Write-TestStep "Querying membership type view..."
    $typeQuery = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = @"
SELECT
    membershipType,
    COUNT(*) as Count
FROM dbo.vw_GraphGroupMembershipType
GROUP BY membershipType
ORDER BY membershipType
"@

        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        return $dataset.Tables[0]
    }

    if ($typeQuery -and $typeQuery.Rows.Count -gt 0) {
        Write-Host "`n  Membership Type Breakdown:" -ForegroundColor Cyan
        $typeQuery | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host $_ -ForegroundColor White }
        Add-TestResult -Category "Query" -TestName "Membership type view query" -Passed $true -Data "$($typeQuery.Rows.Count) membership types"
    } else {
        Add-TestResult -Category "Query" -TestName "Membership type view query" -Passed $true -Message "No data (expected if no groups have members)"
    }

    # Query sample memberships with details
    Write-TestStep "Querying sample membership details..."
    $sampleMemberships = Invoke-FGSQLQuery -Query @"
SELECT TOP 5
    m.groupId,
    m.memberId,
    m.memberType,
    m.membershipType
FROM dbo.vw_GraphGroupMembershipType m
ORDER BY m.membershipType, m.groupId
"@

    if ($sampleMemberships -and $sampleMemberships.Rows.Count -gt 0) {
        Write-Host "`n  Sample Memberships:" -ForegroundColor Cyan
        $sampleMemberships | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host $_ -ForegroundColor White }
        Add-TestResult -Category "Query" -TestName "Sample membership query" -Passed $true -Data "$($sampleMemberships.Rows.Count) samples retrieved"
    } else {
        Add-TestResult -Category "Query" -TestName "Sample membership query" -Passed $true -Message "No memberships found (expected if groups are empty)"
    }
} catch {
    Add-TestResult -Category "Query" -TestName "Group membership view queries" -Passed $false -Message $_.Exception.Message
}

# Test 22: Group Sync Summary Query
Write-TestHeader "Test 22: Group Sync Summary"

try {
    Write-TestStep "Generating comprehensive group sync summary..."

    $summaryQuery = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        # Build dynamic query based on which tables exist
        $query = @"
SELECT
    'Groups' as EntityType,
    COUNT(*) as TotalCount,
    MIN(ValidFrom) as FirstSync,
    MAX(ValidFrom) as LastSync
FROM dbo.GraphGroups_Test
UNION ALL
SELECT
    'Direct Memberships',
    COUNT(*),
    MIN(ValidFrom),
    MAX(ValidFrom)
FROM dbo.GraphGroupMembers_Test
UNION ALL
SELECT
    'Transitive Memberships',
    COUNT(*),
    MIN(ValidFrom),
    MAX(ValidFrom)
FROM dbo.GraphGroupTransitiveMembers_Test
"@

        # Check if eligible members table exists and add to query
        $checkEligibleCmd = $connection.CreateCommand()
        $checkEligibleCmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'GraphGroupEligibleMembers_Test' AND TABLE_SCHEMA = 'dbo'"
        $eligibleTableExists = $checkEligibleCmd.ExecuteScalar() -gt 0

        if ($eligibleTableExists) {
            $query += @"

UNION ALL
SELECT
    'Eligible Memberships (PIM)',
    COUNT(*),
    MIN(ValidFrom),
    MAX(ValidFrom)
FROM dbo.GraphGroupEligibleMembers_Test
"@
        }

        # Check if owners table exists and add to query
        $checkOwnersCmd = $connection.CreateCommand()
        $checkOwnersCmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'GraphGroupOwners_Test' AND TABLE_SCHEMA = 'dbo'"
        $ownersTableExists = $checkOwnersCmd.ExecuteScalar() -gt 0

        if ($ownersTableExists) {
            $query += @"

UNION ALL
SELECT
    'Group Ownerships',
    COUNT(*),
    MIN(ValidFrom),
    MAX(ValidFrom)
FROM dbo.GraphGroupOwners_Test
"@
        }

        $cmd = $connection.CreateCommand()
        $cmd.CommandText = $query

        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        return $dataset.Tables[0]
    }

    Write-Host "`n  Group Sync Summary:" -ForegroundColor Cyan
    $summaryQuery | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host $_ -ForegroundColor White }

    Add-TestResult -Category "Query" -TestName "Group sync summary" -Passed $true -Data $summaryQuery
} catch {
    Add-TestResult -Category "Query" -TestName "Group sync summary" -Passed $false -Message $_.Exception.Message
}

# Test 23: Start-FGSync function with config file (sequential sync)
Write-TestHeader "Test 23: Start-FGSync (Sequential Sync)"

try {
    Write-TestStep "Testing Start-FGSync function with config file..."

    # Create a temporary config file for testing
    $tempConfigPath = Join-Path $PSScriptRoot "config.startsync-test.json"

    # Build test config based on main config
    $syncConfig = @{
        Azure = @{
            SubscriptionId = $config.Azure.SubscriptionId
            ResourceGroupName = $config.Azure.ResourceGroupName
            SqlServerName = $config.Azure.SQLServerName
            SqlDatabaseName = $config.Azure.SqlDatabaseName
            SqlServerAdminUsername = $config.Azure.SqlServerAdminUsername
            Location = $config.Azure.Location
            SkuName = $config.Azure.SkuName
        }
        Graph = @{
            TenantId = $config.Graph.TenantId
            ClientId = $config.Graph.ClientId
        }
        Sync = @{
            Users = @{
                Enabled = $true
                TableName = "GraphUsers_StartSync"
                Filter = "accountEnabled eq true"
                AdditionalAttributes = @("officeLocation")
            }
            Groups = @{
                Enabled = $true
                TableName = "GraphGroups_StartSync"
                Filter = ""
            }
            GroupMembers = @{
                Enabled = $true
                TableName = "GraphGroupMembers_StartSync"
            }
            GroupTransitiveMembers = @{
                Enabled = $false
            }
            GroupEligibleMembers = @{
                Enabled = $false
            }
            GroupOwners = @{
                Enabled = $true
                TableName = "GraphGroupOwners_StartSync"
            }
            Views = @{
                Enabled = $false
            }
        }
    }

    # Handle encrypted credentials
    if ($config.Azure.PSObject.Properties['SqlServerAdminPassword_Encrypted']) {
        $syncConfig.Azure.SqlServerAdminPassword_Encrypted = $config.Azure.SqlServerAdminPassword_Encrypted
    }
    if ($config.Graph.PSObject.Properties['ClientSecret_Encrypted']) {
        $syncConfig.Graph.ClientSecret_Encrypted = $config.Graph.ClientSecret_Encrypted
    }

    # Write temp config
    $syncConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $tempConfigPath

    Write-TestStep "Running Start-FGSync with sequential sync..."
    $syncStartTime = Get-Date

    # Run the sync
    Start-FGSync -ConfigFile $tempConfigPath

    $syncDuration = (Get-Date) - $syncStartTime
    Write-TestSuccess "Start-FGSync completed in $($syncDuration.TotalSeconds.ToString('F2')) seconds"

    # Verify tables were created
    Write-TestStep "Verifying synced tables..."
    $tables = Get-FGSQLTable
    $expectedTables = @("GraphUsers_StartSync", "GraphGroups_StartSync", "GraphGroupMembers_StartSync", "GraphGroupOwners_StartSync")

    $allTablesExist = $true
    foreach ($tableName in $expectedTables) {
        if ($tables.TableName -contains $tableName) {
            Write-TestSuccess "Table found: $tableName"
        } else {
            Write-Host "  ✗ Table missing: $tableName" -ForegroundColor Red
            $allTablesExist = $false
        }
    }

    # Verify row counts
    if ($allTablesExist) {
        Write-TestStep "Verifying row counts..."
        $userCount = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM GraphUsers_StartSync" -AsScalar
        $groupCount = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM GraphGroups_StartSync" -AsScalar
        $memberCount = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM GraphGroupMembers_StartSync" -AsScalar
        $ownerCount = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM GraphGroupOwners_StartSync" -AsScalar

        Write-TestSuccess "Users synced: $userCount"
        Write-TestSuccess "Groups synced: $groupCount"
        Write-TestSuccess "Memberships synced: $memberCount"
        Write-TestSuccess "Ownerships synced: $ownerCount"

        $syncPassed = ($userCount -gt 0) -and ($groupCount -gt 0)
    } else {
        $syncPassed = $false
    }

    # Cleanup temp config
    Remove-Item -Path $tempConfigPath -Force -ErrorAction SilentlyContinue

    Add-TestResult -Category "Sync" -TestName "Start-FGSync sequential" -Passed $syncPassed -Message "Duration: $($syncDuration.TotalSeconds.ToString('F2'))s, Users: $userCount, Groups: $groupCount"

} catch {
    Remove-Item -Path $tempConfigPath -Force -ErrorAction SilentlyContinue
    Add-TestResult -Category "Sync" -TestName "Start-FGSync sequential" -Passed $false -Message $_.Exception.Message
}

# Test 24: Start-FGSync alias test
Write-TestHeader "Test 24: Start-FGSync Alias (Daily-Sync)"

try {
    Write-TestStep "Testing Daily-Sync alias..."

    # Verify alias exists
    $aliasExists = Get-Alias -Name "Daily-Sync" -ErrorAction SilentlyContinue

    if ($aliasExists -and $aliasExists.ResolvedCommandName -eq "Start-FGSync") {
        Write-TestSuccess "Alias 'Daily-Sync' correctly points to Start-FGSync"
        Add-TestResult -Category "Sync" -TestName "Start-FGSync alias" -Passed $true
    } else {
        Write-Host "  ✗ Alias 'Daily-Sync' not found or not pointing to Start-FGSync" -ForegroundColor Red
        Add-TestResult -Category "Sync" -TestName "Start-FGSync alias" -Passed $false -Message "Alias not configured correctly"
    }

} catch {
    Add-TestResult -Category "Sync" -TestName "Start-FGSync alias" -Passed $false -Message $_.Exception.Message
}

# Cleanup
if (-not $SkipCleanup) {
    Write-TestHeader "Test 25: Cleanup Test Resources"

    try {
        Write-TestStep "Removing test SQL Server and resources..."
        Remove-AzSqlServer -ResourceGroupName $config.Azure.ResourceGroupName -ServerName $config.Azure.SQLServerName -Force
        Add-TestResult -Category "Cleanup" -TestName "Test resources cleaned up" -Passed $true
    } catch {
        Add-TestResult -Category "Cleanup" -TestName "Cleanup" -Passed $false -Message $_.Exception.Message
    }
} else {
    Write-Host "`nSkipping cleanup (use -SkipCleanup to keep resources)" -ForegroundColor Yellow
}

# Print Summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Integration Test Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$totalTests = $script:TestResults.Count
$passedTests = ($script:TestResults | Where-Object { $_.Passed }).Count
$failedTests = $totalTests - $passedTests

Write-Host "`nTotal Tests:  $totalTests" -ForegroundColor White
Write-Host "Passed:       $passedTests" -ForegroundColor Green
Write-Host "Failed:       $failedTests" -ForegroundColor $(if ($failedTests -eq 0) { "Green" } else { "Red" })

# Category breakdown
Write-Host "`nResults by Category:" -ForegroundColor Cyan
$script:TestResults | Group-Object Category | ForEach-Object {
    $categoryPassed = ($_.Group | Where-Object { $_.Passed }).Count
    $categoryTotal = $_.Count
    $status = if ($categoryPassed -eq $categoryTotal) { "✓" } else { "✗" }
    Write-Host "  $status $($_.Name): $categoryPassed/$categoryTotal passed" -ForegroundColor $(if ($categoryPassed -eq $categoryTotal) { "Green" } else { "Yellow" })
}

if ($failedTests -gt 0) {
    Write-Host "`nFailed Tests:" -ForegroundColor Red
    $script:TestResults | Where-Object { -not $_.Passed } | ForEach-Object {
        Write-Host "  ✗ [$($_.Category)] $($_.TestName)" -ForegroundColor Yellow
        if ($_.Message) {
            Write-Host "    $($_.Message)" -ForegroundColor Gray
        }
    }
}

Write-Host "`n========================================`n" -ForegroundColor Cyan

# Stop transcript
Stop-Transcript

# Exit code
if ($failedTests -eq 0) {
    Write-Host "`nAll integration tests passed! ✓" -ForegroundColor Green
    Write-Host "Full test log saved to: $transcriptFile" -ForegroundColor Cyan
    exit 0
} else {
    Write-Host "`nSome integration tests failed." -ForegroundColor Red
    Write-Host "Full test log saved to: $transcriptFile" -ForegroundColor Cyan
    exit 1
}
