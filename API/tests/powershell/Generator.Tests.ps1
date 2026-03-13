#Requires -Modules Pester
<#
.SYNOPSIS
    Pester tests for API/generators/generate-powershell.ps1

.DESCRIPTION
    Runs the generator against a minimal embedded YAML spec (no real Azure/SQL needed),
    then validates the generated module structure, manifest, and function contents.

    Prerequisites:
        Install-Module Pester      -MinimumVersion 5.5 -Scope CurrentUser -Force
        Install-Module powershell-yaml -Scope CurrentUser -Force

.EXAMPLE
    Invoke-Pester .\API\tests\powershell\Generator.Tests.ps1 -Output Detailed
#>

BeforeAll {
    # ── Paths ──────────────────────────────────────────────────────────────────
    $RepoRoot      = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\')
    $GeneratorPath = Join-Path $RepoRoot 'API\generators\generate-powershell.ps1'
    $RealSpecPath  = Join-Path $RepoRoot 'API\spec\openapi.yaml'
    $PkgJsonPath   = Join-Path $RepoRoot 'API\package.json'

    # ── Minimal embedded spec for isolated testing ────────────────────────────
    $script:MinimalSpec = @'
openapi: 3.0.3
info:
  title: Test API
  version: "9.8.7"
servers:
  - url: /api/v1/ingestion
paths:
  /widgets:
    get:
      operationId: listWidgets
      summary: List all widgets
      parameters:
        - name: $page
          in: query
          required: false
          schema:
            type: integer
      responses:
        "200":
          description: ok
    post:
      operationId: upsertWidget
      summary: Upsert a widget
      requestBody:
        required: true
        content:
          application/json:
            schema: {}
      responses:
        "200":
          description: ok
  /widgets/batch:
    post:
      operationId: batchUpsertWidgets
      summary: Batch upsert widgets
      requestBody:
        required: true
        content:
          application/json:
            schema: {}
      responses:
        "200":
          description: ok
  /widgets/{id}:
    get:
      operationId: getWidget
      summary: Get widget by id
      parameters:
        - name: id
          in: path
          required: true
          schema:
            type: string
            format: uuid
      responses:
        "200":
          description: ok
    put:
      operationId: updateWidget
      summary: Update widget
      parameters:
        - name: id
          in: path
          required: true
          schema:
            type: string
            format: uuid
      requestBody:
        required: true
        content:
          application/json:
            schema: {}
      responses:
        "200":
          description: ok
    delete:
      operationId: deleteWidget
      summary: Delete widget
      parameters:
        - name: id
          in: path
          required: true
          schema:
            type: string
            format: uuid
      responses:
        "204":
          description: deleted
components:
  schemas:
    Widget:
      type: object
      required: [id]
      properties:
        id:
          type: string
          format: uuid
        name:
          type: string
        active:
          type: boolean
'@

    # ── Write temp spec and run generator ─────────────────────────────────────
    $script:TempDir    = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) "FGTest_$(New-Guid)")
    $script:SpecFile   = Join-Path $script:TempDir 'openapi.yaml'
    $script:OutputPath = Join-Path $script:TempDir 'FortigiGraphIngestion'

    $script:MinimalSpec | Set-Content $script:SpecFile -Encoding UTF8

    & $GeneratorPath `
        -SpecPath       $script:SpecFile `
        -OutputPath     $script:OutputPath `
        -ModuleVersion  '9.8.7'
}

AfterAll {
    if ($script:TempDir -and (Test-Path $script:TempDir)) {
        Remove-Item $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ─── Output structure ─────────────────────────────────────────────────────────

Describe 'Generator output structure' {
    It 'creates the output directory' {
        Test-Path $script:OutputPath | Should -BeTrue
    }

    It 'creates FortigiGraphIngestion.psm1' {
        Test-Path (Join-Path $script:OutputPath 'FortigiGraphIngestion.psm1') | Should -BeTrue
    }

    It 'creates FortigiGraphIngestion.psd1' {
        Test-Path (Join-Path $script:OutputPath 'FortigiGraphIngestion.psd1') | Should -BeTrue
    }

    It 'creates the Functions subfolder' {
        Test-Path (Join-Path $script:OutputPath 'Functions') | Should -BeTrue
    }

    It 'creates at least one .ps1 function file' {
        $files = Get-ChildItem -Path (Join-Path $script:OutputPath 'Functions') -Filter *.ps1
        $files.Count | Should -BeGreaterThan 0
    }

    It 'creates Auth.ps1 helper' {
        Test-Path (Join-Path $script:OutputPath 'Functions\Auth.ps1') | Should -BeTrue
    }
}

# ─── Module manifest (.psd1) ──────────────────────────────────────────────────

Describe 'Module manifest (.psd1)' {
    BeforeAll {
        $script:Manifest = Import-PowerShellDataFile (Join-Path $script:OutputPath 'FortigiGraphIngestion.psd1')
    }

    It 'has correct ModuleVersion' {
        $script:Manifest.ModuleVersion | Should -Be '9.8.7'
    }

    It 'has RootModule pointing to .psm1' {
        $script:Manifest.RootModule | Should -BeLike '*.psm1'
    }

    It 'exports Get-FGIngestionToken' {
        $script:Manifest.FunctionsToExport | Should -Contain 'Get-FGIngestionToken'
    }

    It 'exports Invoke-FGIngestionRequest' {
        $script:Manifest.FunctionsToExport | Should -Contain 'Invoke-FGIngestionRequest'
    }

    It 'has non-empty FunctionsToExport' {
        $script:Manifest.FunctionsToExport.Count | Should -BeGreaterThan 2
    }
}

# ─── Generated function names ─────────────────────────────────────────────────

Describe 'Generated function naming' {
    BeforeAll {
        $script:FunctionFiles = Get-ChildItem -Path (Join-Path $script:OutputPath 'Functions') -Filter *.ps1 -Recurse
        $script:FunctionContent = $script:FunctionFiles | Get-Content -Raw
    }

    It 'generates Get-FGIngestionWidgets (list)' {
        # listWidgets → Get-FGIngestion*
        $script:FunctionContent | Should -Match 'function Get-FGIngestion\w+Widgets'
    }

    It 'generates New-FGIngestion* (upsert)' {
        # upsertWidget → New-FGIngestion*
        $script:FunctionContent | Should -Match 'function New-FGIngestion\w+Widget'
    }

    It 'generates Set-FGIngestion* (update)' {
        # updateWidget → Set-FGIngestion*
        $script:FunctionContent | Should -Match 'function Set-FGIngestion\w+Widget'
    }

    It 'generates Remove-FGIngestion* (delete)' {
        # deleteWidget → Remove-FGIngestion*
        $script:FunctionContent | Should -Match 'function Remove-FGIngestion\w+Widget'
    }

    It 'functions have an alias without FGIngestion prefix' {
        $script:FunctionContent | Should -Match '\[alias\('
    }

    It 'functions use [CmdletBinding()] or [cmdletbinding()]' {
        $script:FunctionContent | Should -Match '\[cmdletbinding\(\)\]|\[CmdletBinding\(\)\]'
    }
}

# ─── Auth helper ──────────────────────────────────────────────────────────────

Describe 'Auth helper (Auth.ps1)' {
    BeforeAll {
        $script:AuthContent = Get-Content (Join-Path $script:OutputPath 'Functions\Auth.ps1') -Raw
    }

    It 'defines Get-FGIngestionToken' {
        $script:AuthContent | Should -Match 'function Get-FGIngestionToken'
    }

    It 'defines Invoke-FGIngestionRequest' {
        $script:AuthContent | Should -Match 'function Invoke-FGIngestionRequest'
    }

    It 'uses client_credentials grant_type' {
        $script:AuthContent | Should -Match 'client_credentials'
    }

    It 'calls oauth2/v2.0/token endpoint' {
        $script:AuthContent | Should -Match 'oauth2/v2.0/token'
    }

    It 'sets Global:FGIngestionToken' {
        $script:AuthContent | Should -Match '\$Global:FGIngestionToken'
    }

    It 'sets Global:FGIngestionBaseUrl' {
        $script:AuthContent | Should -Match '\$Global:FGIngestionBaseUrl'
    }
}

# ─── Module can be imported ───────────────────────────────────────────────────

Describe 'Module import' {
    It 'imports without errors' {
        { Import-Module (Join-Path $script:OutputPath 'FortigiGraphIngestion.psd1') -Force -ErrorAction Stop } |
            Should -Not -Throw
    }

    It 'exports Get-FGIngestionToken after import' {
        Get-Command -Module FortigiGraphIngestion -Name 'Get-FGIngestionToken' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    AfterAll {
        Remove-Module FortigiGraphIngestion -Force -ErrorAction SilentlyContinue
    }
}

# ─── Against the real spec ─────────────────────────────────────────────────────

Describe 'Real spec smoke test' -Skip:(-not (Test-Path $RealSpecPath)) {
    BeforeAll {
        $script:RealOutputPath = Join-Path ([System.IO.Path]::GetTempPath()) "FGReal_$(New-Guid)"

        & $GeneratorPath `
            -SpecPath       $RealSpecPath `
            -OutputPath     $script:RealOutputPath

        $script:RealManifest = Import-PowerShellDataFile (
            Join-Path $script:RealOutputPath 'FortigiGraphIngestion.psd1'
        )
    }

    AfterAll {
        if (Test-Path $script:RealOutputPath) {
            Remove-Item $script:RealOutputPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-Module FortigiGraphIngestion -Force -ErrorAction SilentlyContinue
    }

    It 'generates manifest with version matching package.json' -Skip:(-not (Test-Path $PkgJsonPath)) {
        $expectedVersion = (Get-Content $PkgJsonPath | ConvertFrom-Json).version
        $script:RealManifest.ModuleVersion | Should -Be $expectedVersion
    }

    It 'exports functions for all 12 entity types' {
        $exports = $script:RealManifest.FunctionsToExport
        # Spot-check a few representative entity operation names
        $exports | Should -Contain 'Get-FGIngestionToken'
        ($exports | Where-Object { $_ -match 'User' }).Count   | Should -BeGreaterThan 0
        ($exports | Where-Object { $_ -match 'Group' }).Count  | Should -BeGreaterThan 0
        ($exports | Where-Object { $_ -match 'Catalog' }).Count | Should -BeGreaterThan 0
    }

    It 'imports without errors' {
        { Import-Module (Join-Path $script:RealOutputPath 'FortigiGraphIngestion.psd1') -Force -ErrorAction Stop } |
            Should -Not -Throw
    }
}
