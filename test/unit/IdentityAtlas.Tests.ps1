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

BeforeAll {
    $script:repoRoot    = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:modulePath  = Join-Path $script:repoRoot 'setup\IdentityAtlas.psd1'

    # Actual function roots (repo was restructured from Functions/ subfolders)
    $script:graphRoot   = Join-Path $script:repoRoot 'tools\powershell-sdk\graph'
    $script:helpersRoot = Join-Path $script:repoRoot 'tools\powershell-sdk\helpers'
    $script:riskRoot    = Join-Path $script:repoRoot 'tools\riskscoring'
    $script:dbRoot      = Join-Path $script:repoRoot 'app\db'

    Import-Module $script:modulePath -Force -ErrorAction Stop

    # Collect all .ps1 files across every function root
    $script:allPs1Files = @(
        Get-ChildItem -Path $script:graphRoot   -Include '*.ps1' -Recurse -ErrorAction SilentlyContinue
        Get-ChildItem -Path $script:helpersRoot -Include '*.ps1' -Recurse -ErrorAction SilentlyContinue
        Get-ChildItem -Path $script:riskRoot    -Include '*.ps1' -Recurse -ErrorAction SilentlyContinue
        Get-ChildItem -Path $script:dbRoot      -Include '*.ps1' -Recurse -ErrorAction SilentlyContinue
    )
}

# ── Module Import ────────────────────────────────────────────────────────────

Describe 'Module Import' {
    It 'imports without errors' {
        { Import-Module $script:modulePath -Force -ErrorAction Stop } | Should -Not -Throw
    }

    It 'manifest is valid' {
        { Test-ModuleManifest -Path $script:modulePath -ErrorAction Stop } | Should -Not -Throw
    }

    It 'version format matches Major.Minor.yyyyMMdd.HHmm' {
        $content = Get-Content $script:modulePath -Raw
        $content | Should -Match "ModuleVersion\s*=\s*'\d+\.\d+\.\d{8}\.\d{4}'"
    }
}

# ── Function Availability — Graph / Base ─────────────────────────────────────

Describe 'Function Availability — Graph / Base' {
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

# ── Function Availability — Generic Graph API ────────────────────────────────

Describe 'Function Availability — Generic Graph API (sample)' {
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

# ── Function Availability — SQL / DB ─────────────────────────────────────────

Describe 'Function Availability — SQL / DB' {
    It 'exports <_>' -ForEach @(
        'Connect-FGSQLServer', 'New-FGSQLConnection', 'Test-FGSQLConnection',
        'Initialize-FGSQLTable', 'Invoke-FGSQLCommand', 'Invoke-FGSQLQuery',
        'Invoke-FGSQLBulkMerge', 'Invoke-FGSQLBulkDelete',
        'New-FGAzureSQLServer', 'Remove-FGAzureSQLServer',
        'Get-FGSQLTable', 'Get-FGSQLTableSchema', 'Clear-FGSQLTable',
        'Add-FGSQLTableColumn', 'New-FGSQLReadOnlyUser',
        'Write-FGSyncLog', 'Get-FGSyncLog',
        'Initialize-FGAccessPackageViews', 'Initialize-FGGroupMembershipViews',
        'Initialize-FGGroupMembershipIndexes',
        'Initialize-FGSystemTables', 'Initialize-FGGovernanceTables',
        'Initialize-FGResourceViews', 'Initialize-FGResourceIndexes',
        'Initialize-FGCrawlerTables'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

# ── Function Availability — Helpers (idempotent) ─────────────────────────────

Describe 'Function Availability — Helpers' {
    It 'exports <_>' -ForEach @(
        'Confirm-FGUser', 'Confirm-FGGroup', 'Confirm-FGGroupMember', 'Confirm-FGNotGroupMember',
        'Confirm-FGAccessPackage', 'Confirm-FGAccessPackagePolicy', 'Confirm-FGAccessPackageResource',
        'Confirm-FGCatalog', 'Confirm-FGGroupInCatalog'
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
        'Sync-FGGroupTransitiveMember',
        'Sync-FGUser',
        'Sync-FGGroup',
        'Start-FGSync',
        'Start-FGCSVSync',
        # Azure deployment functions removed when project went Docker-only
        'New-FGUI', 'Update-FGUI', 'Remove-FGUI', 'Set-FGUI',
        'New-FGAzureAutomationAccount',
        'Get-FGAutomationRunbook', 'Start-FGAutomationRunbook', 'Get-FGAutomationJob'
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
    It 'tools/powershell-sdk/graph folder exists' {
        $script:graphRoot | Should -Exist
    }
    It 'tools/powershell-sdk/helpers folder exists' {
        $script:helpersRoot | Should -Exist
    }
    It 'tools/riskscoring folder exists' {
        $script:riskRoot | Should -Exist
    }
    It 'app/db folder exists' {
        $script:dbRoot | Should -Exist
    }

    It 'all .ps1 files follow Verb-FGNoun naming' {
        $bad = $script:allPs1Files | Where-Object { $_.BaseName -notmatch '^[A-Z][a-z]+-FG[A-Z]' }
        $bad | Should -BeNullOrEmpty -Because "bad names: $($bad.BaseName -join ', ')"
    }

    It 'IdentityAtlas.psm1 dot-sources <_>' -ForEach @(
        "tools\powershell-sdk\graph",
        "tools\powershell-sdk\helpers",
        "tools\riskscoring",
        "app\db"
    ) {
        $psm1 = Get-Content (Join-Path $script:repoRoot 'setup\IdentityAtlas.psm1') -Raw
        $psm1 | Should -Match ([regex]::Escape($_))
    }

    It 'setup/azure folder is gone (Docker-only)' {
        Join-Path $script:repoRoot 'setup\azure' | Should -Not -Exist
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
            $path = Join-Path $script:graphRoot $_
            if (-not (Test-Path $path)) { return $false }
            $lines = Get-Content $path
            foreach ($line in $lines) {
                if ($line -match '\$ReturnValue\s*=\s*\$Result') { return $false }
                if ($line -match '\$ReturnValue\s*\+=\s*\$Result') { return $true }
            }
            return $false
        }
        $bad | Should -BeNullOrEmpty -Because "+= used in: $($bad -join ', ')"
    }
}

# ── Config Template ──────────────────────────────────────────────────────────

Describe 'Config Template' {
    BeforeAll {
        $script:templatePath = Join-Path $script:repoRoot 'setup\config\tenantname.json.template'
    }

    It 'template file exists' {
        $script:templatePath | Should -Exist
    }

    It 'template is valid JSON' {
        { Get-Content $script:templatePath -Raw | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'template has <_> section' -ForEach @('Graph','RiskScoring','AccountCorrelation') {
        $t = Get-Content $script:templatePath -Raw | ConvertFrom-Json
        $t.$_ | Should -Not -BeNullOrEmpty
    }
}

# ── Function Counts ──────────────────────────────────────────────────────────

Describe 'Function Counts' {
    It 'tools/powershell-sdk/graph has 65-80 files' {
        $n = (Get-ChildItem $script:graphRoot -Filter '*.ps1').Count
        $n | Should -BeGreaterOrEqual 65
        $n | Should -BeLessOrEqual 80
    }
    It 'tools/powershell-sdk/helpers has exactly 9 files' {
        (Get-ChildItem $script:helpersRoot -Filter '*.ps1').Count | Should -Be 9
    }
    It 'tools/riskscoring has 15-20 files' {
        $n = (Get-ChildItem $script:riskRoot -Filter '*.ps1').Count
        $n | Should -BeGreaterOrEqual 15
        $n | Should -BeLessOrEqual 20
    }
    It 'app/db has 30-45 files' {
        $n = (Get-ChildItem $script:dbRoot -Filter '*.ps1').Count
        $n | Should -BeGreaterOrEqual 30
        $n | Should -BeLessOrEqual 45
    }
    It 'total function count is 120-170' {
        $n = $script:allPs1Files.Count
        $n | Should -BeGreaterOrEqual 120
        $n | Should -BeLessOrEqual 170
    }
}
