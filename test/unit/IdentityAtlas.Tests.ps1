#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
<#
.SYNOPSIS
    Pester unit tests for the IdentityAtlas PowerShell module.
    No Azure connection required — tests module structure, naming, and code quality.

.USAGE
    # Install Pester first (once):
    Install-Module Pester -MinimumVersion 5.0.0 -Force -Scope CurrentUser

    # Run tests:
    Invoke-Pester -Path test/unit/IdentityAtlas.Tests.ps1 -Output Detailed
#>

$repoRoot    = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$modulePath  = Join-Path $repoRoot 'setup\IdentityAtlas.psd1'
$functionsRoot = Join-Path $repoRoot 'Functions'

BeforeAll {
    Import-Module $modulePath -Force -ErrorAction Stop
    $script:allPs1Files = Get-ChildItem -Path $using:functionsRoot -Include '*.ps1' -Recurse
}

# ── Module Import ────────────────────────────────────────────────────────────

Describe 'Module Import' {
    It 'imports without errors' {
        { Import-Module $modulePath -Force -ErrorAction Stop } | Should -Not -Throw
    }

    It 'manifest is valid' {
        { Test-ModuleManifest -Path $modulePath -ErrorAction Stop } | Should -Not -Throw
    }

    It 'version format matches Major.Minor.yyyyMMdd.HHmm' {
        $content = Get-Content $modulePath -Raw
        $content | Should -Match "ModuleVersion\s*=\s*'\d+\.\d+\.\d{8}\.\d{4}'"
    }
}

# ── Function Availability — Base ─────────────────────────────────────────────

Describe 'Function Availability — Base' {
    It 'exports <_>' -ForEach @(
        'New-FGConfig',
        'Get-FGAccessToken', 'Get-FGAccessTokenInteractive', 'Get-FGAccessTokenWithRefreshToken',
        'Get-FGAccessTokenDetail', 'Confirm-FGAccessTokenValidity',
        'Update-FGAccessTokenIfExpired',
        'Invoke-FGGetRequest', 'Invoke-FGGetRequestToFile',
        'Invoke-FGPostRequest', 'Invoke-FGPatchRequest', 'Invoke-FGPutRequest', 'Invoke-FGDeleteRequest',
        'Use-FGExistingAccessTokenString', 'Use-FGExistingMSALToken',
        'Read-FGToken', 'Save-FGToken',
        'Test-FGConnection',
        'Get-FGSecureConfigValue', 'Clear-FGSecureConfigValue', 'Test-FGSecureConfigValue'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

# ── Function Availability — Generic ─────────────────────────────────────────

Describe 'Function Availability — Generic (sample)' {
    It 'exports <_>' -ForEach @(
        'Get-FGUser', 'Get-FGGroup', 'Get-FGDevice', 'Get-FGApplication', 'Get-FGServicePrincipal',
        'Get-FGCatalog', 'Get-FGAccessPackage', 'Get-FGAccessPackagesAssignments', 'Get-FGAccessPackagesPolicy',
        'Get-FGGroupMember', 'Get-FGGroupMemberAll', 'Get-FGGroupMemberAllToFile',
        'Get-FGGroupTransitiveMemberAll', 'Get-FGGroupEligibleMemberAll',
        'Get-FGUserMail', 'Get-FGUserMailFolder', 'Get-FGUserManager', 'Get-FGUserMemberOf',
        'New-FGGroup', 'New-FGAccessPackage', 'New-FGCatalog', 'New-FGAccessPackagePolicy',
        'Set-FGAccessPackage', 'Set-FGAccessPackagePolicy',
        'Add-FGGroupMember', 'Add-FGGroupToAccessPackage', 'Add-FGGroupToCatalog',
        'Remove-FGAccessPackage', 'Remove-FGDevice', 'Remove-FGGroupMember'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

# ── Function Availability — SQL ──────────────────────────────────────────────

Describe 'Function Availability — SQL' {
    It 'exports <_>' -ForEach @(
        'Connect-FGSQLServer', 'New-FGSQLConnection', 'Test-FGSQLConnection',
        'Initialize-FGSQLTable', 'Invoke-FGSQLCommand', 'Invoke-FGSQLQuery',
        'Invoke-FGSQLBulkMerge', 'Invoke-FGSQLBulkDelete',
        'New-FGAzureSQLServer', 'Remove-FGAzureSQLServer',
        'Get-FGSQLTable', 'Get-FGSQLTableSchema', 'Clear-FGSQLTable',
        'Add-FGSQLTableColumn', 'New-FGSQLReadOnlyUser',
        'Write-FGSyncLog', 'Get-FGSyncLog',
        'Initialize-FGAccessPackageViews', 'Initialize-FGGroupMembershipViews',
        'Initialize-FGGroupMembershipIndexes'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

# ── Function Availability — Sync ─────────────────────────────────────────────

Describe 'Function Availability — Sync' {
    It 'exports <_>' -ForEach @(
        'Start-FGSync',
        'Sync-FGUser', 'Sync-FGGroup',
        'Sync-FGGroupMember', 'Sync-FGGroupEligibleMember', 'Sync-FGGroupOwner',
        'Sync-FGCatalog', 'Sync-FGAccessPackage',
        'Sync-FGAccessPackageAssignment', 'Sync-FGAccessPackageResourceRoleScope',
        'Sync-FGAccessPackageAssignmentPolicy', 'Sync-FGAccessPackageAssignmentRequest',
        'Sync-FGAccessPackageAccessReview',
        'Initialize-FGSyncTable', 'New-FGDataTableFromGraphObjects'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

# ── Function Availability — Automation ──────────────────────────────────────

Describe 'Function Availability — Automation' {
    It 'exports <_>' -ForEach @(
        'New-FGAzureAutomationAccount',
        'Get-FGAutomationRunbook', 'Start-FGAutomationRunbook', 'Get-FGAutomationJob',
        'New-FGUI', 'Update-FGUI', 'Remove-FGUI', 'Set-FGUI'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

# ── Function Availability — RiskScoring ─────────────────────────────────────

Describe 'Function Availability — RiskScoring' {
    It 'exports <_>' -ForEach @(
        'New-FGRiskProfile', 'New-FGRiskClassifiers',
        'Invoke-FGRiskScoring', 'Invoke-FGLLMRequest',
        'Save-FGRiskProfile', 'Save-FGRiskClassifiers', 'Save-FGResourceClusters',
        'Get-FGRiskProfile', 'Get-FGRiskClassifiers',
        'Export-FGRiskProfile', 'Export-FGRiskClassifiers',
        'Import-FGRiskProfile', 'Import-FGRiskClassifiers'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

# ── Removed Functions ────────────────────────────────────────────────────────

Describe 'Removed Functions (must NOT exist)' {
    It '<_> is gone' -ForEach @(
        'Sync-FGGroupTransitiveMember'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}

# ── Alias Verification ───────────────────────────────────────────────────────

Describe 'Alias Verification' {
    It '<Alias> maps to <Function>' -ForEach @(
        @{ Function = 'Get-FGUser';           Alias = 'Get-User' },
        @{ Function = 'Get-FGGroup';          Alias = 'Get-Group' },
        @{ Function = 'Get-FGAccessToken';    Alias = 'Get-AccessToken' },
        @{ Function = 'New-FGConfig';         Alias = 'New-Config' },
        @{ Function = 'Connect-FGSQLServer';  Alias = 'Connect-SQLServer' },
        @{ Function = 'Start-FGSync';         Alias = 'Start-Sync' },
        @{ Function = 'Invoke-FGGetRequest';  Alias = 'Invoke-GetRequest' },
        @{ Function = 'Invoke-FGPostRequest'; Alias = 'Invoke-PostRequest' }
    ) {
        $a = Get-Alias $Alias -ErrorAction SilentlyContinue
        $a | Should -Not -BeNullOrEmpty
        $a.Definition | Should -Be $Function
    }
}

# ── File Structure ───────────────────────────────────────────────────────────

Describe 'File Structure' {
    It 'Functions/<_> folder exists' -ForEach @('Base','Generic','Specific','SQL','Sync','Automation','RiskScoring') {
        Join-Path $functionsRoot $_ | Should -Exist
    }

    It 'all .ps1 files follow Verb-FGNoun naming' {
        $bad = $script:allPs1Files | Where-Object { $_.BaseName -notmatch '^[A-Z][a-z]+-FG[A-Z]' }
        $bad | Should -BeNullOrEmpty -Because "bad names: $($bad.BaseName -join ', ')"
    }

    It 'IdentityAtlas.psm1 dot-sources <_>' -ForEach @(
        'functions\base', 'functions\generic', 'functions\specific',
        'functions\SQL', 'functions\sync', 'functions\automation'
    ) {
        $psm1 = Get-Content (Join-Path $repoRoot 'setup\IdentityAtlas.psm1') -Raw
        $psm1 | Should -Match [regex]::Escape($_)
    }
}

# ── Code Quality ─────────────────────────────────────────────────────────────

Describe 'Code Quality' {
    It 'all functions have [CmdletBinding()]' {
        $missing = $script:allPs1Files | Where-Object {
            $c = Get-Content $_.FullName -Raw
            $c -match '(?m)^function\s+' -and $c -notmatch '(?i)\[cmdletbinding\('
        }
        $missing | Should -BeNullOrEmpty -Because "missing in: $($missing.Name -join ', ')"
    }

    It 'no Dutch comments' {
        $dutch = @('# Controleer','# Verwijder','# Maak','# Als er','# Haal','# Sla op','# Voeg toe')
        $found = $script:allPs1Files | Where-Object {
            $c = Get-Content $_.FullName -Raw
            $dutch | Where-Object { $c -match [regex]::Escape($_) }
        }
        $found | Should -BeNullOrEmpty -Because "found in: $($found.Name -join ', ')"
    }

    It 'no hardcoded secrets' {
        $patterns = @('password\s*=\s*"[^"$]', 'secret\s*=\s*"[^"$]', 'Bearer\s+ey[A-Za-z0-9]')
        $found = $script:allPs1Files | Where-Object {
            $c = Get-Content $_.FullName -Raw
            $patterns | Where-Object { $c -match $_ }
        }
        $found | Should -BeNullOrEmpty -Because "secrets found in: $($found.Name -join ', ')"
    }

    It 'no Write-Output usage (use return instead)' {
        $found = $script:allPs1Files | Where-Object {
            $_.Name -ne 'New-FGAzureAutomationAccount.ps1' -and
            (Get-Content $_.FullName -Raw) -match 'Write-Output\s'
        }
        $found | Should -BeNullOrEmpty -Because "found in: $($found.Name -join ', ')"
    }

    It 'no "More then one" typo' {
        $found = $script:allPs1Files | Where-Object { (Get-Content $_.FullName -Raw) -match 'More then one' }
        $found | Should -BeNullOrEmpty -Because "found in: $($found.Name -join ', ')"
    }

    It 'no "cataloge" typo' {
        $found = $script:allPs1Files | Where-Object { (Get-Content $_.FullName -Raw) -match 'cataloge' }
        $found | Should -BeNullOrEmpty -Because "found in: $($found.Name -join ', ')"
    }

    It 'base HTTP functions use = not += for first $ReturnValue assignment' {
        $httpFiles = @('Invoke-FGPostRequest.ps1','Invoke-FGPatchRequest.ps1','Invoke-FGPutRequest.ps1','Invoke-FGDeleteRequest.ps1')
        $bad = $httpFiles | Where-Object {
            $path = Join-Path $functionsRoot "Base\$_"
            if (-not (Test-Path $path)) { return $false }
            $lines = Get-Content $path
            foreach ($line in $lines) {
                if ($line -match '\$ReturnValue\s*=\s*\$Result') { return $false }
                if ($line -match '\$ReturnValue\s*\+=\s*\$Result') { return $true }
            }
            return $false
        }
        $bad | Should -BeNullOrEmpty -Because "+=  used in: $($bad -join ', ')"
    }
}

# ── Config Template ──────────────────────────────────────────────────────────

Describe 'Config Template' {
    BeforeAll {
        $script:templatePath = Join-Path $repoRoot 'Config\tenantname.json.template'
    }

    It 'template file exists' {
        $script:templatePath | Should -Exist
    }

    It 'template is valid JSON' {
        { Get-Content $script:templatePath -Raw | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'template has <_> section' -ForEach @('Azure','Graph','Sync') {
        $t = Get-Content $script:templatePath -Raw | ConvertFrom-Json
        $t.$_ | Should -Not -BeNullOrEmpty
    }
}

# ── Function Counts ──────────────────────────────────────────────────────────

Describe 'Function Counts' {
    It 'Base has exactly 21 files' {
        (Get-ChildItem (Join-Path $functionsRoot 'Base') -Filter '*.ps1').Count | Should -Be 21
    }
    It 'Generic has 45-55 files' {
        $n = (Get-ChildItem (Join-Path $functionsRoot 'Generic') -Filter '*.ps1').Count
        $n | Should -BeGreaterOrEqual 45
        $n | Should -BeLessOrEqual 55
    }
    It 'Specific has exactly 9 files' {
        (Get-ChildItem (Join-Path $functionsRoot 'Specific') -Filter '*.ps1').Count | Should -Be 9
    }
    It 'SQL has 20-28 files' {
        $n = (Get-ChildItem (Join-Path $functionsRoot 'SQL') -Filter '*.ps1').Count
        $n | Should -BeGreaterOrEqual 20
        $n | Should -BeLessOrEqual 28
    }
    It 'Sync has 14-18 files' {
        $n = (Get-ChildItem (Join-Path $functionsRoot 'Sync') -Filter '*.ps1').Count
        $n | Should -BeGreaterOrEqual 14
        $n | Should -BeLessOrEqual 18
    }
    It 'Automation has exactly 8 files' {
        (Get-ChildItem (Join-Path $functionsRoot 'Automation') -Filter '*.ps1').Count | Should -Be 8
    }
    It 'RiskScoring has exactly 13 files' {
        (Get-ChildItem (Join-Path $functionsRoot 'RiskScoring') -Filter '*.ps1').Count | Should -Be 13
    }
    It 'total function count is 135-170' {
        $n = (Get-ChildItem $functionsRoot -Include '*.ps1' -Recurse).Count
        $n | Should -BeGreaterOrEqual 135
        $n | Should -BeLessOrEqual 170
    }
}
