<#
.SYNOPSIS
    Generates a PowerShell client module for the FortigiGraph Ingestion API from the OpenAPI spec.

.DESCRIPTION
    Reads API/spec/openapi.yaml, parses all entity endpoints, and generates a complete
    PowerShell module with:
      - One function per API operation (Get-*, New-*, Set-*, Remove-*)
      - Typed parameter validation matching OpenAPI schemas
      - OAuth2 client credentials token management
      - Module manifest (.psd1) with matching version number
      - Aliases without the 'FG' prefix following FortigiGraph conventions

.PARAMETER SpecPath
    Path to the OpenAPI YAML spec. Defaults to the spec in the same repo.

.PARAMETER OutputPath
    Directory where the generated module will be written.
    Defaults to: API/generated/powershell/FortigiGraphIngestion/

.PARAMETER ModuleVersion
    Version to stamp on the generated module.
    Defaults to the version read from API/package.json.

.EXAMPLE
    .\generate-powershell.ps1
    .\generate-powershell.ps1 -OutputPath C:\Modules\FortigiGraphIngestion
#>
[CmdletBinding()]
Param(
    [string]$SpecPath    = (Join-Path $PSScriptRoot '..\spec\openapi.yaml'),
    [string]$OutputPath  = (Join-Path $PSScriptRoot '..\generated\powershell\FortigiGraphIngestion'),
    [string]$ModuleVersion = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── Helpers ──────────────────────────────────────────────────────────────────

function Read-YamlFile {
    param([string]$Path)
    # Requires powershell-yaml module or yq in PATH
    if (Get-Module -ListAvailable -Name 'powershell-yaml' -ErrorAction SilentlyContinue) {
        Import-Module powershell-yaml -ErrorAction Stop
        return Get-Content -Raw $Path | ConvertFrom-Yaml
    }
    # Fallback: use yq if available
    if (Get-Command yq -ErrorAction SilentlyContinue) {
        $json = & yq -o=json $Path
        return $json | ConvertFrom-Json -Depth 50
    }
    throw "Install 'powershell-yaml' (Install-Module powershell-yaml) or 'yq' to parse YAML."
}

function Get-PSTypeFromOpenApi {
    param([object]$Schema)
    if ($null -eq $Schema) { return '[object]' }
    switch ($Schema.type) {
        'string'  {
            if ($Schema.format -eq 'date-time') { return '[datetime]' }
            if ($Schema.format -eq 'uuid')       { return '[string]' }
            return '[string]'
        }
        'integer' { return '[int]' }
        'number'  { return '[double]' }
        'boolean' { return '[bool]' }
        'array'   { return '[array]' }
        'object'  { return '[hashtable]' }
        default   { return '[object]' }
    }
}

function ConvertTo-PascalCase {
    param([string]$Name)
    ($Name -split '[-_]' | ForEach-Object { $_.Substring(0,1).ToUpper() + $_.Substring(1) }) -join ''
}

function Get-VerbNoun {
    param([string]$OperationId)
    # Map OpenAPI operationId to PowerShell verb-noun
    $map = @{
        'list'   = 'Get'
        'get'    = 'Get'
        'upsert' = 'New'
        'update' = 'Set'
        'delete' = 'Remove'
        'add'    = 'Add'
        'remove' = 'Remove'
        'batch'  = 'Invoke'
    }
    # Extract action prefix from camelCase operationId
    if ($OperationId -match '^(list|get|upsert|update|delete|add|remove|batch)(.+)$') {
        $action = $Matches[1].ToLower()
        $noun   = $Matches[2]
        $verb   = if ($map.ContainsKey($action)) { $map[$action] } else { 'Invoke' }
        # Apply FG prefix to noun
        $psNoun = "FGIngestion$(ConvertTo-PascalCase $noun)"
        return "$verb-$psNoun"
    }
    return "Invoke-FGIngestion$(ConvertTo-PascalCase $OperationId)"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

Write-Host "[generate-powershell] Reading spec: $SpecPath" -ForegroundColor Cyan
$spec = Read-YamlFile -Path $SpecPath

# Resolve version
if (-not $ModuleVersion) {
    $pkgJson = Join-Path $PSScriptRoot '..\package.json'
    if (Test-Path $pkgJson) {
        $ModuleVersion = (Get-Content $pkgJson | ConvertFrom-Json).version
    } else {
        $ModuleVersion = $spec.info.version
    }
}
Write-Host "[generate-powershell] Module version: $ModuleVersion" -ForegroundColor Cyan

# Prepare output directory
if (Test-Path $OutputPath) {
    Remove-Item $OutputPath -Recurse -Force
}
$null = New-Item -ItemType Directory -Path $OutputPath -Force
$functionsPath = Join-Path $OutputPath 'Functions'
$null = New-Item -ItemType Directory -Path $functionsPath -Force

Write-Host "[generate-powershell] Output: $OutputPath" -ForegroundColor Cyan

# Collect exported function names
$exportedFunctions = [System.Collections.Generic.List[string]]::new()

# ─── Generate auth helper ──────────────────────────────────────────────────────

$authContent = @'
function Get-FGIngestionToken {
    <#
    .SYNOPSIS
        Obtains an Azure AD access token for the FortigiGraph Ingestion API using client credentials.
    .EXAMPLE
        $token = Get-FGIngestionToken -TenantId $env:TENANT_ID -ClientId $env:CLIENT_ID -ClientSecret $env:CLIENT_SECRET -ApiClientId $env:API_CLIENT_ID
    #>
    [alias("Get-IngestionToken")]
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]  [string]$TenantId,
        [Parameter(Mandatory=$true)]  [string]$ClientId,
        [Parameter(Mandatory=$true)]  [string]$ClientSecret,
        [Parameter(Mandatory=$true)]  [string]$ApiClientId,
        [Parameter(Mandatory=$false)] [string]$BaseUrl = 'http://localhost:3001'
    )
    $body = @{
        grant_type    = 'client_credentials'
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = "api://$ApiClientId/.default"
    }
    $response = Invoke-RestMethod `
        -Uri     "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Method  POST `
        -Body    $body `
        -ContentType 'application/x-www-form-urlencoded'

    $Global:FGIngestionToken   = $response.access_token
    $Global:FGIngestionBaseUrl = $BaseUrl.TrimEnd('/')
    Write-Host "[FortigiGraphIngestion] Token acquired. Expires in $($response.expires_in)s." -ForegroundColor Green
    return $response
}

function Invoke-FGIngestionRequest {
    <#
    .SYNOPSIS
        Internal helper: makes an authenticated HTTP request to the ingestion API.
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]  [string]$Method,
        [Parameter(Mandatory=$true)]  [string]$Path,
        [Parameter(Mandatory=$false)] [object]$Body,
        [Parameter(Mandatory=$false)] [hashtable]$Query = @{}
    )
    if (-not $Global:FGIngestionToken) {
        throw "Not authenticated. Run Get-FGIngestionToken first."
    }
    $uri = "$Global:FGIngestionBaseUrl/api/v1/ingestion$Path"
    if ($Query.Count -gt 0) {
        $qs = ($Query.GetEnumerator() | ForEach-Object { "$([Uri]::EscapeDataString($_.Key))=$([Uri]::EscapeDataString($_.Value))" }) -join '&'
        $uri = "$uri?$qs"
    }
    $headers = @{ Authorization = "Bearer $Global:FGIngestionToken" }
    $params  = @{ Uri = $uri; Method = $Method; Headers = $headers; ErrorAction = 'Stop' }
    if ($Body) {
        $params.Body        = $Body | ConvertTo-Json -Depth 20 -Compress
        $params.ContentType = 'application/json'
    }
    try {
        return Invoke-RestMethod @params
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $msg        = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
        throw "[$statusCode] $($msg.message ?? $_.Exception.Message)"
    }
}
'@

$authContent | Set-Content (Join-Path $functionsPath 'Auth.ps1') -Encoding UTF8
$exportedFunctions.Add('Get-FGIngestionToken')
$exportedFunctions.Add('Invoke-FGIngestionRequest')

# ─── Generate entity functions from spec ──────────────────────────────────────

$paths = $spec.paths
if ($null -eq $paths) { throw "No paths found in OpenAPI spec." }

foreach ($pathKey in $paths.Keys) {
    $pathItem = $paths[$pathKey]
    foreach ($httpMethod in @('get','post','put','delete','patch')) {
        $operation = $pathItem.$httpMethod
        if ($null -eq $operation) { continue }

        $operationId = $operation.operationId
        if (-not $operationId) { continue }

        $funcName = Get-VerbNoun -OperationId $operationId
        $alias    = $funcName -replace '-FGIngestion', '-'

        # Collect parameters
        $allParams  = @()
        $pathParams = @()
        $queryParams = @()

        $combinedParams = @()
        if ($pathItem.parameters) { $combinedParams += $pathItem.parameters }
        if ($operation.parameters) { $combinedParams += $operation.parameters }

        foreach ($p in $combinedParams) {
            if ($p.'$ref') { continue } # skip refs for simplicity
            $psType = Get-PSTypeFromOpenApi -Schema $p.schema
            $mandatory = if ($p.required -eq $true) { 'Mandatory=$true' } else { 'Mandatory=$false' }
            $paramBlock = "        [Parameter($mandatory)]`n        $psType`$$($p.name)"
            $allParams += @{ Name = $p.name; In = $p.In; Block = $paramBlock }
            if ($p.In -eq 'path') { $pathParams += $p.name }
            if ($p.In -eq 'query') { $queryParams += $p.name }
        }

        # Body parameter (for POST/PUT)
        $hasBody = $httpMethod -in @('post', 'put', 'patch') -and $operation.requestBody
        if ($hasBody) {
            $allParams += @{ Name = 'Body'; In = 'body'; Block = "        [Parameter(Mandatory=`$true)]`n        [hashtable]`$Body" }
        }

        # Build path with PowerShell variable substitution
        $psPath = $pathKey -replace '\{(\w+)\}', '/$1'

        # Build param declaration section
        $paramLines = ($allParams | ForEach-Object { $_.Block }) -join ",`n"
        if ($paramLines) { $paramLines = "`n$paramLines`n    " }

        # Build query hashtable
        $queryBuild = ''
        if ($queryParams.Count -gt 0) {
            $qLines = $queryParams | ForEach-Object {
                "        if (`$PSBoundParameters.ContainsKey('$_')) { `$query['$_'] = `$$_ }"
            }
            $queryBuild = "    `$query = @{}`n" + ($qLines -join "`n") + "`n"
        }

        # Build path string
        $psPathExpr = '"' + ($pathKey -replace '\{(\w+)\}', '`$$1') + '"'

        # Build request call
        $requestArgs = "    `$result = Invoke-FGIngestionRequest -Method '$($httpMethod.ToUpper())' -Path $psPathExpr"
        if ($queryParams.Count -gt 0) { $requestArgs += ' -Query $query' }
        if ($hasBody)                  { $requestArgs += ' -Body $Body' }

        $summary = $operation.summary ?? $operationId

        $funcContent = @"
function $funcName {
    <#
    .SYNOPSIS
        $summary
    .DESCRIPTION
        Auto-generated function. Operation: $operationId
        HTTP: $($httpMethod.ToUpper()) $pathKey
    #>
    [alias("$alias")]
    [CmdletBinding()]
    Param($paramLines)
$(    if ($queryBuild) { $queryBuild })
$requestArgs
    return `$result
}
"@

        $safeName = $funcName -replace '[^a-zA-Z0-9_-]', '_'
        $funcContent | Set-Content (Join-Path $functionsPath "$safeName.ps1") -Encoding UTF8
        $exportedFunctions.Add($funcName)
    }
}

# ─── Generate .psm1 ────────────────────────────────────────────────────────────

$psm1Content = @"
#
# FortigiGraphIngestion PowerShell Module
# Auto-generated by generate-powershell.ps1
# Version: $ModuleVersion
# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')
# DO NOT EDIT MANUALLY - regenerate from the OpenAPI spec
#

`$functions = @( Get-ChildItem -Path (Join-Path `$PSScriptRoot 'Functions') -Include *.ps1 -Recurse )
foreach (`$import in `$functions) {
    . `$import.FullName
}
"@

$psm1Content | Set-Content (Join-Path $OutputPath 'FortigiGraphIngestion.psm1') -Encoding UTF8

# ─── Generate .psd1 ────────────────────────────────────────────────────────────

$exportList = ($exportedFunctions | Sort-Object -Unique | ForEach-Object { "        '$_'" }) -join ",`n"

$psd1Content = @"
@{
    RootModule        = 'FortigiGraphIngestion.psm1'
    ModuleVersion     = '$ModuleVersion'
    GUID              = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author            = 'Fortigi'
    CompanyName       = 'Fortigi'
    Description       = 'Auto-generated PowerShell client for the FortigiGraph Ingestion API'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
$exportList
    )
    PrivateData = @{
        PSData = @{
            Tags        = @('FortigiGraph', 'MicrosoftGraph', 'AzureAD', 'IngestionAPI')
            ProjectUri  = 'https://github.com/Fortigi/FortigiGraph'
        }
    }
}
"@

$psd1Content | Set-Content (Join-Path $OutputPath 'FortigiGraphIngestion.psd1') -Encoding UTF8

Write-Host "[generate-powershell] Generated $($exportedFunctions.Count) functions." -ForegroundColor Green
Write-Host "[generate-powershell] Module written to: $OutputPath" -ForegroundColor Green
Write-Host "[generate-powershell] Import with: Import-Module $OutputPath\FortigiGraphIngestion.psd1" -ForegroundColor Cyan
