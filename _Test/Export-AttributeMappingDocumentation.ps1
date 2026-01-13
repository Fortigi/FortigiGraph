<#
.SYNOPSIS
    Exports comprehensive attribute mapping documentation from Entra ID.

.DESCRIPTION
    This script analyzes your Entra ID tenant and generates a Markdown documentation file
    showing all attribute mappings across:
    - HR Provisioning (Workday/SuccessFactors/Custom HR) to AD
    - Azure AD Connect Cloud Sync (AD to Entra ID)
    - SCIM provisioning (Entra ID to applications)

    The output provides a clear overview of how attributes flow from HR systems through
    your identity infrastructure to target applications.

.PARAMETER OutputPath
    Path to the output Markdown file.
    Default: ".\Attribute-Mapping-Documentation.md"

.PARAMETER IncludeCloudSync
    Include Azure AD Connect Cloud Sync mappings in the documentation.

.PARAMETER IncludeDisabled
    Include synchronization jobs that are currently disabled.

.PARAMETER TenantId
    Optional. Entra ID tenant ID. If not provided, uses current authenticated tenant.

.PARAMETER ClientId
    Optional. Client ID for authentication. If not provided, uses current token.

.PARAMETER ClientSecret
    Optional. Client secret for authentication.

.EXAMPLE
    .\Export-AttributeMappingDocumentation.ps1
    Generates documentation using current authentication.

.EXAMPLE
    .\Export-AttributeMappingDocumentation.ps1 -IncludeCloudSync -OutputPath ".\docs\attribute-mappings.md"
    Generates comprehensive documentation including Cloud Sync configuration.

.EXAMPLE
    .\Export-AttributeMappingDocumentation.ps1 -TenantId "..." -ClientId "..." -ClientSecret "..."
    Authenticates and generates documentation.

.NOTES
    Requires FortigiGraph module and the following Graph API permissions:
    - Application.Read.All
    - Synchronization.Read.All

    Author: Wim van den Heijkant
    Company: Fortigi
    Version: 1.0

.LINK
    https://github.com/Fortigi/FortigiGraph
#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\Attribute-Mapping-Documentation.md",

    [Parameter(Mandatory = $false)]
    [switch]$IncludeCloudSync,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeDisabled,

    [Parameter(Mandatory = $false)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [string]$ClientId,

    [Parameter(Mandatory = $false)]
    [string]$ClientSecret
)

#Requires -Modules FortigiGraph

# ============================================================================
# Authentication
# ============================================================================

Write-Host "`n=== Entra ID Attribute Mapping Documentation Generator ===" -ForegroundColor Cyan
Write-Host "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host ""

# Check if we need to authenticate
if (-not $Global:AccessToken -or $TenantId -or $ClientId) {
    if ($TenantId -and $ClientId -and $ClientSecret) {
        Write-Host "Authenticating to Entra ID..." -ForegroundColor Cyan
        Get-FGAccessToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret | Out-Null
        Write-Host "  Authentication successful" -ForegroundColor Green
    }
    elseif ($TenantId -and $ClientId) {
        Write-Host "Authenticating to Entra ID (interactive)..." -ForegroundColor Cyan
        Get-FGAccessTokenInteractive -TenantId $TenantId -ClientId $ClientId | Out-Null
        Write-Host "  Authentication successful" -ForegroundColor Green
    }
    else {
        Write-Host "No authentication parameters provided. Using existing token..." -ForegroundColor Yellow
        if (-not $Global:AccessToken) {
            Write-Host "ERROR: No access token found. Please authenticate first." -ForegroundColor Red
            Write-Host "Run: Get-FGAccessToken -TenantId '...' -ClientId '...' -ClientSecret '...'" -ForegroundColor Yellow
            exit 1
        }
    }
}

# ============================================================================
# Discovery
# ============================================================================

Write-Host "`n=== Phase 1: Discovery ===" -ForegroundColor Cyan
Write-Host ""

# Get all service principals with synchronization
$ServicePrincipals = Get-FGServicePrincipalWithSync -IncludeCloudSync:$IncludeCloudSync -IncludeJobs -IncludeSchema

if (-not $ServicePrincipals -or $ServicePrincipals.Count -eq 0) {
    Write-Host "WARNING: No service principals with synchronization found." -ForegroundColor Yellow
    Write-Host "This could mean:" -ForegroundColor Yellow
    Write-Host "  - No provisioning is configured in your tenant" -ForegroundColor Yellow
    Write-Host "  - Insufficient permissions (requires Synchronization.Read.All)" -ForegroundColor Yellow
    Write-Host "  - All provisioning jobs are inactive" -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "Summary of discovered configurations:" -ForegroundColor Cyan
$ServicePrincipals | Group-Object AppType | ForEach-Object {
    Write-Host "  $($_.Name): $($_.Count) app(s)" -ForegroundColor Cyan
}

# ============================================================================
# Helper Functions
# ============================================================================

function Format-AttributeExpression {
    param($Source)

    if (-not $Source) {
        return "N/A"
    }

    # Handle different source types
    switch ($Source.type) {
        "Attribute" {
            return "``$($Source.expression)``"
        }
        "Constant" {
            return "**Constant**: ``$($Source.expression)``"
        }
        "Function" {
            # Format function with parameters
            if ($Source.parameters) {
                $paramStr = ($Source.parameters | ForEach-Object {
                    if ($_.value.type -eq "Attribute") {
                        "``$($_.value.expression)``"
                    }
                    else {
                        "``$($_.value.expression)``"
                    }
                }) -join ", "
                return "**Function**: ``$($Source.name)($paramStr)``"
            }
            else {
                return "**Function**: ``$($Source.expression)``"
            }
        }
        default {
            return "``$($Source.expression)``"
        }
    }
}

function Get-FlowTypeDescription {
    param($FlowType)

    switch ($FlowType) {
        "Always" { return "Always" }
        "ObjectAddOnly" { return "Only when creating object" }
        "MultiValueAddOnly" { return "Only add values to multi-value attribute" }
        "ValueAddOnly" { return "Only add if attribute is empty" }
        "AttributeAddOnly" { return "Only if attribute doesn't exist" }
        default { return $FlowType }
    }
}

function Get-DirectionArrow {
    param($SourceDir, $TargetDir)

    # Determine arrow based on source and target
    if ($SourceDir -like "*HR*" -or $SourceDir -like "*Workday*" -or $SourceDir -like "*SuccessFactors*") {
        if ($TargetDir -like "*Active Directory*" -or $TargetDir -eq "Active Directory") {
            return "HR → AD"
        }
        elseif ($TargetDir -like "*Azure*" -or $TargetDir -like "*Entra*") {
            return "HR → Entra ID"
        }
    }
    elseif ($SourceDir -like "*Active Directory*" -or $SourceDir -eq "Active Directory") {
        if ($TargetDir -like "*Azure*" -or $TargetDir -like "*Entra*") {
            return "AD → Entra ID"
        }
    }
    elseif ($SourceDir -like "*Azure*" -or $SourceDir -like "*Entra*") {
        return "Entra ID → App"
    }

    # Default
    return "$SourceDir → $TargetDir"
}

# ============================================================================
# Generate Markdown Documentation
# ============================================================================

Write-Host "`n=== Phase 2: Generating Documentation ===" -ForegroundColor Cyan
Write-Host ""

$Markdown = @()

# Header
$Markdown += "# Entra ID Attribute Mapping Documentation"
$Markdown += ""
$Markdown += "**Generated**: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$Markdown += "**Tenant**: $($Global:TenantId)"
$Markdown += ""
$Markdown += "This document provides a comprehensive overview of all attribute mappings configured in your Entra ID tenant."
$Markdown += ""
$Markdown += "## Table of Contents"
$Markdown += ""
$Markdown += "1. [Overview](#overview)"
$Markdown += "2. [Attribute Flow Diagram](#attribute-flow-diagram)"
$Markdown += "3. [Detailed Mappings](#detailed-mappings)"

# Add TOC entries for each app
$TocIndex = 4
foreach ($sp in $ServicePrincipals) {
    $anchorName = ($sp.DisplayName -replace '[^a-zA-Z0-9\s]', '' -replace '\s+', '-').ToLower()
    $Markdown += "   - [$($sp.DisplayName)](#$anchorName)"
}

$Markdown += "4. [Attribute Reference](#attribute-reference)"
$Markdown += ""

# Overview Section
$Markdown += "## Overview"
$Markdown += ""
$Markdown += "This tenant has **$($ServicePrincipals.Count)** provisioning configuration(s):"
$Markdown += ""

$ServicePrincipals | Group-Object AppType | ForEach-Object {
    $Markdown += "- **$($_.Name)**: $($_.Count) app(s)"
}

$Markdown += ""

# Attribute Flow Diagram
$Markdown += "## Attribute Flow Diagram"
$Markdown += ""
$Markdown += "```mermaid"
$Markdown += "graph LR"
$Markdown += "    HR[HR System] --> AD[Active Directory]"

# Check if Cloud Sync is included
if ($ServicePrincipals | Where-Object { $_.AppType -eq "Cloud Sync" }) {
    $Markdown += "    AD --> EntraID[Entra ID]"
}
else {
    $Markdown += "    AD -.-> EntraID[Entra ID]"
}

# Add SCIM apps
$SCIMApps = $ServicePrincipals | Where-Object { $_.AppType -like "*SCIM*" -or $_.AppType -eq "Enterprise Application" }
foreach ($app in $SCIMApps) {
    $appName = $app.DisplayName -replace '[^a-zA-Z0-9]', ''
    $Markdown += "    EntraID --> $appName[$($app.DisplayName)]"
}

$Markdown += "```"
$Markdown += ""

# Detailed Mappings
$Markdown += "## Detailed Mappings"
$Markdown += ""

foreach ($sp in $ServicePrincipals) {
    Write-Host "  Processing: $($sp.DisplayName)" -ForegroundColor Cyan

    $Markdown += "### $($sp.DisplayName)"
    $Markdown += ""
    $Markdown += "- **Type**: $($sp.AppType)"
    $Markdown += "- **Service Principal ID**: ``$($sp.ServicePrincipalId)``"
    $Markdown += "- **App ID**: ``$($sp.AppId)``"
    $Markdown += "- **Active Jobs**: $($sp.JobCount)"
    $Markdown += ""

    # Process each schema
    if ($sp.Schemas) {
        foreach ($schemaObj in $sp.Schemas) {
            $schema = $schemaObj.Schema

            if (-not $schema -or -not $schema.synchronizationRules) {
                $Markdown += "> **Note**: No synchronization schema available for this job."
                $Markdown += ""
                continue
            }

            # Process each synchronization rule
            foreach ($rule in $schema.synchronizationRules) {
                $Markdown += "#### Synchronization Rule: $($rule.name)"
                $Markdown += ""

                # Process each object mapping
                foreach ($objMapping in $rule.objectMappings) {
                    # Skip if disabled and not including disabled
                    if (-not $objMapping.enabled -and -not $IncludeDisabled) {
                        continue
                    }

                    $direction = Get-DirectionArrow -SourceDir $rule.sourceDirectoryName -TargetDir $rule.targetDirectoryName
                    $status = if ($objMapping.enabled) { "✅ Enabled" } else { "⛔ Disabled" }

                    $Markdown += "##### Object Mapping: $($objMapping.sourceObjectName) → $($objMapping.targetObjectName)"
                    $Markdown += ""
                    $Markdown += "- **Direction**: $direction"
                    $Markdown += "- **Status**: $status"
                    $Markdown += "- **Flow Types**: $($objMapping.flowTypes)"
                    $Markdown += ""

                    # Check if there are attribute mappings
                    if (-not $objMapping.attributeMappings -or $objMapping.attributeMappings.Count -eq 0) {
                        $Markdown += "> No attribute mappings configured."
                        $Markdown += ""
                        continue
                    }

                    # Attribute mappings table
                    $Markdown += "| Target Attribute | Source Expression | Flow Type | Notes |"
                    $Markdown += "|-----------------|-------------------|-----------|-------|"

                    foreach ($attrMapping in $objMapping.attributeMappings) {
                        $targetAttr = $attrMapping.targetAttributeName
                        $sourceExpr = Format-AttributeExpression -Source $attrMapping.source
                        $flowType = Get-FlowTypeDescription -FlowType $attrMapping.flowType
                        $notes = ""

                        # Add notes for special cases
                        if ($attrMapping.defaultValue) {
                            $notes += "Default: ``$($attrMapping.defaultValue)`` "
                        }
                        if ($attrMapping.matchingPriority -gt 0) {
                            $notes += "Matching priority: $($attrMapping.matchingPriority) "
                        }

                        $Markdown += "| ``$targetAttr`` | $sourceExpr | $flowType | $notes |"
                    }

                    $Markdown += ""

                    # Add scope information if available
                    if ($objMapping.scope -and $objMapping.scope.groups) {
                        $Markdown += "**Scoping Filters:**"
                        $Markdown += ""
                        foreach ($group in $objMapping.scope.groups) {
                            if ($group.clauses) {
                                foreach ($clause in $group.clauses) {
                                    $Markdown += "- ``$($clause.sourceAttributeName)`` $($clause.operator) ``$($clause.targetAttributeValue)``"
                                }
                            }
                        }
                        $Markdown += ""
                    }
                }
            }
        }
    }
    else {
        $Markdown += "> **Note**: Schema details not available. Run with ``-IncludeSchema`` to retrieve mapping details."
        $Markdown += ""
    }

    $Markdown += "---"
    $Markdown += ""
}

# Attribute Reference Section
$Markdown += "## Attribute Reference"
$Markdown += ""
$Markdown += "This section provides a consolidated view of all attributes being synchronized across your environment."
$Markdown += ""

# Collect all unique attributes
$AllTargetAttributes = @{}
$AllSourceAttributes = @{}

foreach ($sp in $ServicePrincipals) {
    if ($sp.Schemas) {
        foreach ($schemaObj in $sp.Schemas) {
            $schema = $schemaObj.Schema
            if ($schema -and $schema.synchronizationRules) {
                foreach ($rule in $schema.synchronizationRules) {
                    foreach ($objMapping in $rule.objectMappings) {
                        if ($objMapping.attributeMappings) {
                            foreach ($attrMapping in $objMapping.attributeMappings) {
                                # Target attributes
                                $targetAttr = $attrMapping.targetAttributeName
                                if (-not $AllTargetAttributes.ContainsKey($targetAttr)) {
                                    $AllTargetAttributes[$targetAttr] = @()
                                }
                                $AllTargetAttributes[$targetAttr] += $sp.DisplayName

                                # Source attributes (if direct attribute mapping)
                                if ($attrMapping.source -and $attrMapping.source.type -eq "Attribute") {
                                    $sourceAttr = $attrMapping.source.name
                                    if ($sourceAttr -and -not $AllSourceAttributes.ContainsKey($sourceAttr)) {
                                        $AllSourceAttributes[$sourceAttr] = @()
                                    }
                                    if ($sourceAttr) {
                                        $AllSourceAttributes[$sourceAttr] += $sp.DisplayName
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

# Output target attributes
if ($AllTargetAttributes.Count -gt 0) {
    $Markdown += "### Target Attributes"
    $Markdown += ""
    $Markdown += "Attributes being written to target systems:"
    $Markdown += ""
    $Markdown += "| Attribute | Used By |"
    $Markdown += "|-----------|---------|"

    $AllTargetAttributes.GetEnumerator() | Sort-Object Name | ForEach-Object {
        $apps = ($_.Value | Select-Object -Unique) -join ", "
        $Markdown += "| ``$($_.Key)`` | $apps |"
    }

    $Markdown += ""
}

# Output source attributes
if ($AllSourceAttributes.Count -gt 0) {
    $Markdown += "### Source Attributes"
    $Markdown += ""
    $Markdown += "Attributes being read from source systems:"
    $Markdown += ""
    $Markdown += "| Attribute | Used By |"
    $Markdown += "|-----------|---------|"

    $AllSourceAttributes.GetEnumerator() | Sort-Object Name | ForEach-Object {
        $apps = ($_.Value | Select-Object -Unique) -join ", "
        $Markdown += "| ``$($_.Key)`` | $apps |"
    }

    $Markdown += ""
}

# Footer
$Markdown += "---"
$Markdown += ""
$Markdown += "**Generated by**: [FortigiGraph](https://github.com/Fortigi/FortigiGraph) PowerShell Module"
$Markdown += ""
$Markdown += "*This documentation was automatically generated using the Microsoft Graph API.*"

# ============================================================================
# Write Output
# ============================================================================

Write-Host "Writing documentation to: $OutputPath" -ForegroundColor Cyan

# Ensure output directory exists
$OutputDir = Split-Path -Path $OutputPath -Parent
if ($OutputDir -and -not (Test-Path -Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}

# Write markdown file
$Markdown | Out-File -FilePath $OutputPath -Encoding UTF8 -Force

Write-Host ""
Write-Host "=== Documentation Generation Complete ===" -ForegroundColor Green
Write-Host "Output: $OutputPath" -ForegroundColor Green
Write-Host ""
Write-Host "Statistics:" -ForegroundColor Cyan
Write-Host "  - Service Principals: $($ServicePrincipals.Count)" -ForegroundColor Cyan
Write-Host "  - Target Attributes: $($AllTargetAttributes.Count)" -ForegroundColor Cyan
Write-Host "  - Source Attributes: $($AllSourceAttributes.Count)" -ForegroundColor Cyan
Write-Host ""
