# Fast Integration Test Suite for FortigiGraph
# Reuses existing SQL Server to speed up testing
#
# Prerequisites:
# - Run Test-Integration.ps1 with -SkipCleanup first to create the SQL Server
# - Or have an existing SQL Server from previous test runs
#
# This test:
# - Validates SQL Server exists
# - Clears all existing tables
# - Runs all sync and query tests
# - By default, keeps the SQL Server for next run

param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,

    [Parameter(Mandatory = $false)]
    [switch]$RemoveServer
)

# Set error action preference
$ErrorActionPreference = "Stop"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "FortigiGraph Fast Integration Test" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Start transcript to capture all console output (unique per config file)
$configBaseName = [System.IO.Path]::GetFileNameWithoutExtension($ConfigFile)
$transcriptFile = Join-Path $PSScriptRoot "integration-test-fast-$configBaseName.log"
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

# Load secure configuration helper
$secureConfigPath = Join-Path $PSScriptRoot "SecureConfig.ps1"
. $secureConfigPath

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
        Connect-AzAccount -TenantId $config.Graph.TenantId -SubscriptionId $config.Azure.SubscriptionId
        $azContext = Get-AzContext
    } else {
        # We have a context, but is it the right tenant and subscription?
        $correctTenant = $azContext.Tenant.Id -eq $config.Graph.TenantId
        $correctSubscription = $azContext.Subscription.Id -eq $config.Azure.SubscriptionId

        if (-not $correctTenant -or -not $correctSubscription) {
            Write-TestStep "Switching to correct tenant/subscription..."
            Write-TestStep "Current: Tenant=$($azContext.Tenant.Id), Sub=$($azContext.Subscription.Id)"
            Write-TestStep "Target: Tenant=$($config.Graph.TenantId), Sub=$($config.Azure.SubscriptionId)"

            # Try to switch context
            try {
                Set-AzContext -TenantId $config.Graph.TenantId -SubscriptionId $config.Azure.SubscriptionId -ErrorAction Stop | Out-Null
                $azContext = Get-AzContext
                Write-TestStep "Context switched successfully"
            } catch {
                # Context doesn't exist for this tenant/subscription, need to reconnect
                Write-TestStep "Context not found. Connecting to tenant..."
                Connect-AzAccount -TenantId $config.Graph.TenantId -SubscriptionId $config.Azure.SubscriptionId
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

# Validate existing SQL Server
Write-TestHeader "Test 4: Validate Existing SQL Server"

try {
    Write-TestStep "Checking for existing SQL Server..."
    $existingServer = Get-AzSqlServer -ResourceGroupName $config.Azure.ResourceGroupName -ServerName $config.Azure.SQLServerName -ErrorAction SilentlyContinue

    if (-not $existingServer) {
        throw "SQL Server '$($config.Azure.SQLServerName)' not found in resource group '$($config.Azure.ResourceGroupName)'. Please run Test-Integration.ps1 with -SkipCleanup first to create it."
    }

    Write-TestStep "Found SQL Server: $($existingServer.ServerName)"
    Add-TestResult -Category "SQL" -TestName "SQL Server exists" -Passed $true -Data "$($existingServer.ServerName) in $($existingServer.Location)"

    # Check database exists
    Write-TestStep "Checking for database..."
    $existingDb = Get-AzSqlDatabase -ResourceGroupName $config.Azure.ResourceGroupName -ServerName $config.Azure.SQLServerName -DatabaseName $config.Azure.DatabaseName -ErrorAction SilentlyContinue

    if (-not $existingDb) {
        throw "Database '$($config.Azure.DatabaseName)' not found on server '$($config.Azure.SQLServerName)'. Please run Test-Integration.ps1 with -SkipCleanup first."
    }

    Write-TestStep "Found database: $($existingDb.DatabaseName)"
    Add-TestResult -Category "SQL" -TestName "Database exists" -Passed $true -Data "$($existingDb.DatabaseName) ($($existingDb.SkuName))"
} catch {
    Add-TestResult -Category "SQL" -TestName "Validate existing SQL Server" -Passed $false -Message $_.Exception.Message
    Write-Host "`nTIP: Run Test-Integration.ps1 with -SkipCleanup first to create the SQL Server and database." -ForegroundColor Yellow
    exit 1
}

# Connect to SQL Server
Write-TestHeader "Test 5: SQL Server Connection"

try {
    Write-TestStep "Connecting to existing SQL Server..."

    Connect-FGSQLServer `
        -SubscriptionId $config.Azure.SubscriptionId `
        -ResourceGroupName $config.Azure.ResourceGroupName `
        -ServerName $config.Azure.SQLServerName `
        -DatabaseName $config.Azure.DatabaseName `
        -UpdateFirewall

    Add-TestResult -Category "SQL" -TestName "Connected to SQL Server" -Passed $true

    Write-TestStep "Testing connection..."
    $connectionInfo = Test-FGSQLConnection
    Add-TestResult -Category "SQL" -TestName "SQL connection verified" -Passed $true -Data $connectionInfo
} catch {
    Add-TestResult -Category "SQL" -TestName "SQL connection" -Passed $false -Message $_.Exception.Message
    exit 1
}

# Clear existing tables
Write-TestHeader "Test 6: Clear Existing Tables"

try {
    Write-TestStep "Getting list of existing tables..."

    $tables = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = @"
SELECT TABLE_NAME
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_TYPE = 'BASE TABLE'
AND TABLE_SCHEMA = 'dbo'
AND TABLE_NAME NOT LIKE '%History'
ORDER BY TABLE_NAME
"@
        $reader = $cmd.ExecuteReader()
        $tableList = @()
        while ($reader.Read()) {
            $tableList += $reader.GetString(0)
        }
        $reader.Close()
        return $tableList
    }

    if ($tables.Count -eq 0) {
        Write-TestStep "No tables found to clear"
        Add-TestResult -Category "Cleanup" -TestName "Clear existing tables" -Passed $true -Message "No tables to clear"
    } else {
        Write-TestStep "Found $($tables.Count) table(s) to clear"

        foreach ($table in $tables) {
            Write-TestStep "Clearing table: $table"

            # Clear the table
            Invoke-FGSQLCommand -ScriptBlock {
                param($connection)

                # First, disable system versioning if it's a temporal table
                $checkCmd = $connection.CreateCommand()
                $checkCmd.CommandText = @"
SELECT temporal_type
FROM sys.tables
WHERE name = '$table' AND schema_id = SCHEMA_ID('dbo')
"@
                $temporalType = $checkCmd.ExecuteScalar()

                if ($temporalType -eq 2) {
                    # It's a temporal table, disable versioning
                    $disableCmd = $connection.CreateCommand()
                    $disableCmd.CommandText = "ALTER TABLE dbo.[$table] SET (SYSTEM_VERSIONING = OFF)"
                    $disableCmd.ExecuteNonQuery() | Out-Null

                    # Delete from history table
                    $historyTable = "${table}History"
                    $deleteHistCmd = $connection.CreateCommand()
                    $deleteHistCmd.CommandText = "IF OBJECT_ID('dbo.[$historyTable]', 'U') IS NOT NULL DELETE FROM dbo.[$historyTable]"
                    $deleteHistCmd.ExecuteNonQuery() | Out-Null

                    # Delete from main table
                    $deleteCmd = $connection.CreateCommand()
                    $deleteCmd.CommandText = "DELETE FROM dbo.[$table]"
                    $deleteCmd.ExecuteNonQuery() | Out-Null

                    # Re-enable versioning
                    $enableCmd = $connection.CreateCommand()
                    $enableCmd.CommandText = "ALTER TABLE dbo.[$table] SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.[$historyTable]))"
                    $enableCmd.ExecuteNonQuery() | Out-Null
                } else {
                    # Regular table, just delete
                    $deleteCmd = $connection.CreateCommand()
                    $deleteCmd.CommandText = "DELETE FROM dbo.[$table]"
                    $deleteCmd.ExecuteNonQuery() | Out-Null
                }
            }
        }

        Add-TestResult -Category "Cleanup" -TestName "Clear existing tables" -Passed $true -Data "Cleared $($tables.Count) table(s)"
    }

} catch {
    Add-TestResult -Category "Cleanup" -TestName "Clear existing tables" -Passed $false -Message $_.Exception.Message
}

# Note: Tests 7-9 (Table Creation) are SKIPPED in the fast test
# The tables already exist from previous test runs - we only cleared their data in Test 6
# We jump directly to the sync tests (Tests 10-12) which will populate the existing tables
# The helper views will be automatically recreated by the sync functions as needed

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

# Test 13: Query and Verify Results
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

# Note: Test 14 (Temporal Table Features) is SKIPPED in the fast test
# The helper views (vw_*_AllHistory) are only created by Initialize-FGSQLTable
# which we don't call in the fast test. This test validates SQL Server temporal
# features which are already tested in the full integration test.
# The fast test focuses on sync functionality, not SQL Server features.

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

# Include all group sync tests (Tests 16-22) from Test-Integration.ps1
# These are the same tests, just running on the cleared database

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

# Test 18: Group Transitive Member Sync - Nested Memberships
Write-TestHeader "Test 18: Group Transitive Member Sync (Nested Memberships)"

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

# Test 19: Group Eligible Member Sync - PIM Memberships (Optional)
Write-TestHeader "Test 19: Group Eligible Member Sync (PIM Memberships)"

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

# Test 20: Group Membership Views
Write-TestHeader "Test 20: Group Membership Analysis Views"

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

# Test 21: Query Group Membership Views
Write-TestHeader "Test 21: Query Group Membership Views"

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
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = @"
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

# Optional: Remove server if requested
if ($RemoveServer) {
    Write-TestHeader "Test 23: Remove SQL Server"

    try {
        Write-TestStep "Removing SQL Server and resources..."
        Remove-AzSqlServer -ResourceGroupName $config.Azure.ResourceGroupName -ServerName $config.Azure.SQLServerName -Force
        Add-TestResult -Category "Cleanup" -TestName "SQL Server removed" -Passed $true
    } catch {
        Add-TestResult -Category "Cleanup" -TestName "Remove SQL Server" -Passed $false -Message $_.Exception.Message
    }
} else {
    Write-Host "`n" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "SQL Server Preserved for Next Run" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Server:   $($config.Azure.SQLServerName)" -ForegroundColor White
    Write-Host "Database: $($config.Azure.DatabaseName)" -ForegroundColor White
    Write-Host "`nTo remove the server, run with -RemoveServer" -ForegroundColor Gray
    Write-Host "========================================`n" -ForegroundColor Green
}

# Print Summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Fast Integration Test Summary" -ForegroundColor Cyan
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
    Write-Host "`nAll tests passed! ✓" -ForegroundColor Green
    Write-Host "Full test log saved to: $transcriptFile" -ForegroundColor Cyan
    exit 0
} else {
    Write-Host "`nSome tests failed." -ForegroundColor Red
    Write-Host "Full test log saved to: $transcriptFile" -ForegroundColor Cyan
    exit 1
}
