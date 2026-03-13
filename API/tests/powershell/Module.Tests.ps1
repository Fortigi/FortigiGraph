#Requires -Modules Pester
<#
.SYNOPSIS
    Pester tests for the generated FortigiGraphIngestion PowerShell module.

.DESCRIPTION
    Generates the module from the real spec (or a temp spec if the repo spec is missing),
    imports it, and verifies the runtime behaviour of:
      - Get-FGIngestionToken (mocked HTTP via Invoke-RestMethod mock)
      - Invoke-FGIngestionRequest (headers, body, query string construction)
      - Representative generated CRUD functions

    No real Azure AD or SQL connections are made.

.EXAMPLE
    Invoke-Pester .\API\tests\powershell\Module.Tests.ps1 -Output Detailed
#>

BeforeAll {
    $RepoRoot      = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\')
    $GeneratorPath = Join-Path $RepoRoot 'API\generators\generate-powershell.ps1'
    $RealSpecPath  = Join-Path $RepoRoot 'API\spec\openapi.yaml'

    if (-not (Test-Path $RealSpecPath)) {
        Write-Warning "openapi.yaml not found at $RealSpecPath — tests will be skipped."
        $script:SkipAll = $true
        return
    }

    $script:SkipAll    = $false
    $script:ModulePath = Join-Path ([System.IO.Path]::GetTempPath()) "FGModule_$(New-Guid)"

    & $GeneratorPath -SpecPath $RealSpecPath -OutputPath $script:ModulePath
    Import-Module (Join-Path $script:ModulePath 'FortigiGraphIngestion.psd1') -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module FortigiGraphIngestion -Force -ErrorAction SilentlyContinue
    if ($script:ModulePath -and (Test-Path $script:ModulePath)) {
        Remove-Item $script:ModulePath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ─── Get-FGIngestionToken ─────────────────────────────────────────────────────

Describe 'Get-FGIngestionToken' -Skip:$script:SkipAll {
    BeforeAll {
        # Mock Invoke-RestMethod to simulate a token response
        Mock -ModuleName FortigiGraphIngestion Invoke-RestMethod {
            return [PSCustomObject]@{
                access_token = 'mock-access-token-abc123'
                expires_in   = 3600
                token_type   = 'Bearer'
            }
        }
    }

    AfterEach {
        # Clean global state between tests
        $Global:FGIngestionToken   = $null
        $Global:FGIngestionBaseUrl = $null
    }

    It 'calls the Azure AD token endpoint' {
        Get-FGIngestionToken `
            -TenantId    'my-tenant' `
            -ClientId    'my-client' `
            -ClientSecret 'my-secret' `
            -ApiClientId  'my-api-client' `
            -BaseUrl      'http://localhost:3001'

        Should -Invoke -ModuleName FortigiGraphIngestion Invoke-RestMethod -Times 1 -ParameterFilter {
            $Uri -match 'my-tenant' -and $Uri -match 'oauth2/v2.0/token'
        }
    }

    It 'sets Global:FGIngestionToken' {
        Get-FGIngestionToken `
            -TenantId    'my-tenant' `
            -ClientId    'my-client' `
            -ClientSecret 'my-secret' `
            -ApiClientId  'my-api-client'

        $Global:FGIngestionToken | Should -Be 'mock-access-token-abc123'
    }

    It 'sets Global:FGIngestionBaseUrl' {
        Get-FGIngestionToken `
            -TenantId    'my-tenant' `
            -ClientId    'my-client' `
            -ClientSecret 'my-secret' `
            -ApiClientId  'my-api-client' `
            -BaseUrl      'http://myhost:9000'

        $Global:FGIngestionBaseUrl | Should -Be 'http://myhost:9000'
    }

    It 'trims trailing slash from BaseUrl' {
        Get-FGIngestionToken `
            -TenantId    'my-tenant' `
            -ClientId    'my-client' `
            -ClientSecret 'my-secret' `
            -ApiClientId  'my-api-client' `
            -BaseUrl      'http://myhost:9000/'

        $Global:FGIngestionBaseUrl | Should -Be 'http://myhost:9000'
    }

    It 'returns the response object' {
        $result = Get-FGIngestionToken `
            -TenantId    'my-tenant' `
            -ClientId    'my-client' `
            -ClientSecret 'my-secret' `
            -ApiClientId  'my-api-client'

        $result.access_token | Should -Be 'mock-access-token-abc123'
        $result.expires_in   | Should -Be 3600
    }
}

# ─── Invoke-FGIngestionRequest ────────────────────────────────────────────────

Describe 'Invoke-FGIngestionRequest' -Skip:$script:SkipAll {
    BeforeAll {
        $Global:FGIngestionToken   = 'test-bearer-token'
        $Global:FGIngestionBaseUrl = 'http://localhost:3001'

        Mock -ModuleName FortigiGraphIngestion Invoke-RestMethod {
            return [PSCustomObject]@{ data = @(); total = 0 }
        }
    }

    AfterAll {
        $Global:FGIngestionToken   = $null
        $Global:FGIngestionBaseUrl = $null
    }

    It 'calls Invoke-RestMethod with correct URI' {
        Invoke-FGIngestionRequest -Method 'GET' -Path '/users'

        Should -Invoke -ModuleName FortigiGraphIngestion Invoke-RestMethod -Times 1 -ParameterFilter {
            $Uri -eq 'http://localhost:3001/api/v1/ingestion/users'
        }
    }

    It 'includes Bearer token in Authorization header' {
        Invoke-FGIngestionRequest -Method 'GET' -Path '/groups'

        Should -Invoke -ModuleName FortigiGraphIngestion Invoke-RestMethod -Times 1 -ParameterFilter {
            $Headers.Authorization -eq 'Bearer test-bearer-token'
        }
    }

    It 'passes body as JSON for POST' {
        $body = @{ id = 'some-guid'; displayName = 'Test Group' }
        Invoke-FGIngestionRequest -Method 'POST' -Path '/groups' -Body $body

        Should -Invoke -ModuleName FortigiGraphIngestion Invoke-RestMethod -Times 1 -ParameterFilter {
            $Method -eq 'POST' -and $Body -ne $null
        }
    }

    It 'throws when not authenticated' {
        $Global:FGIngestionToken = $null
        { Invoke-FGIngestionRequest -Method 'GET' -Path '/users' } | Should -Throw
        $Global:FGIngestionToken = 'test-bearer-token'
    }
}

# ─── Generated CRUD functions ─────────────────────────────────────────────────

Describe 'Generated GET functions' -Skip:$script:SkipAll {
    BeforeAll {
        $Global:FGIngestionToken   = 'test-token'
        $Global:FGIngestionBaseUrl = 'http://localhost:3001'

        Mock -ModuleName FortigiGraphIngestion Invoke-RestMethod {
            return [PSCustomObject]@{ data = @(); total = 0 }
        }
    }

    AfterAll {
        $Global:FGIngestionToken   = $null
        $Global:FGIngestionBaseUrl = $null
    }

    $ListFunctions = @(
        'Get-FGIngestionUsers',
        'Get-FGIngestionGroups',
        'Get-FGIngestionCatalogs',
        'Get-FGIngestionAccessPackages',
        'Get-FGIngestionAccessPackageAssignments',
        'Get-FGIngestionGroupMembers',
        'Get-FGIngestionGroupOwners'
    )

    foreach ($funcName in $ListFunctions) {
        # Capture for closure
        $capturedName = $funcName

        It "function '$capturedName' calls the API and returns data" {
            $cmd = Get-Command $capturedName -Module FortigiGraphIngestion -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty -Because "$capturedName should be exported"

            # Call the function; it should not throw and should invoke Invoke-RestMethod
            & $capturedName
            Should -Invoke -ModuleName FortigiGraphIngestion Invoke-RestMethod -Times 1
        }
    }
}

Describe 'Generated DELETE functions' -Skip:$script:SkipAll {
    BeforeAll {
        $Global:FGIngestionToken   = 'test-token'
        $Global:FGIngestionBaseUrl = 'http://localhost:3001'

        Mock -ModuleName FortigiGraphIngestion Invoke-RestMethod { return $null }
    }

    AfterAll {
        $Global:FGIngestionToken   = $null
        $Global:FGIngestionBaseUrl = $null
    }

    It 'Remove-FGIngestionUser calls DELETE /users/{id}' {
        $cmd = Get-Command 'Remove-FGIngestionUser' -Module FortigiGraphIngestion -ErrorAction SilentlyContinue
        $cmd | Should -Not -BeNullOrEmpty

        Remove-FGIngestionUser -id 'some-guid'

        Should -Invoke -ModuleName FortigiGraphIngestion Invoke-RestMethod -Times 1 -ParameterFilter {
            $Method -eq 'DELETE'
        }
    }
}
