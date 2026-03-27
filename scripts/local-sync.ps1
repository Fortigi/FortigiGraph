<#
.SYNOPSIS
    Runs FortigiGraph sync against the local Docker SQL Server.

.DESCRIPTION
    Bypasses the normal Connect-FGSQLServer (which requires Azure context and
    appends .database.windows.net) by pre-establishing the connection directly
    to the Docker SQL container on localhost:1433.

    Prerequisites:
    - Docker stack running: docker compose -f docker-compose.local.yml up -d
    - FortigiGraph module available at repo root
    - Config file with valid Graph credentials (Azure fields can be dummy values)

.PARAMETER ConfigFile
    Path to a FortigiGraph config JSON file.
    Graph.TenantId, Graph.ClientId, and Graph.ClientSecret must be real values.
    Azure fields (SubscriptionId, ResourceGroupName, etc.) are not used for local sync.

.PARAMETER SQLPassword
    SA password for the local Docker SQL Server.
    Defaults to the password set in docker-compose.local.yml.

.PARAMETER SQLDatabase
    Database name. Defaults to GraphData (matches docker-compose.local.yml).

.EXAMPLE
    .\scripts\local-sync.ps1 -ConfigFile .\Config\yourtenant.json
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,

    [Parameter(Mandatory = $false)]
    [string]$SQLPassword = "FortigiGraph_Local1!",

    [Parameter(Mandatory = $false)]
    [string]$SQLDatabase = "GraphData"
)

$ErrorActionPreference = "Stop"

Write-Host "FortigiGraph Local Sync" -ForegroundColor Cyan
Write-Host "=======================" -ForegroundColor Cyan

# Load module from repo root
$modulePath = Join-Path $PSScriptRoot "..\FortigiGraph.psd1"
Write-Host "Loading module from: $modulePath" -ForegroundColor Cyan
Import-Module $modulePath -Force

# Connect directly to the Docker SQL Server on localhost:1433.
# Using -ConnectionString bypasses the .database.windows.net suffix normalization
# in New-FGSQLConnection and avoids requiring Azure context.
Write-Host "Connecting to local Docker SQL Server (localhost:1433)..." -ForegroundColor Cyan
$connectionString = "Server=localhost,1433;Initial Catalog=$SQLDatabase;User ID=sa;Password=$SQLPassword;TrustServerCertificate=True;Encrypt=True;"
New-FGSQLConnection -ConnectionString $connectionString

# Authenticate to Microsoft Graph using the config file credentials.
Write-Host "Authenticating to Microsoft Graph..." -ForegroundColor Cyan
Get-FGAccessToken -ConfigFile $ConfigFile

# Run sync. -SkipServerValidation combined with the pre-established
# $Global:FGSQLConnectionString causes Start-FGSync to skip the Azure
# connection step and the Connect-FGSQLServer call entirely.
Write-Host "Starting sync..." -ForegroundColor Cyan
Start-FGSync -ConfigFile $ConfigFile -SkipServerValidation

Write-Host "Local sync complete." -ForegroundColor Green
