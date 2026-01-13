<#
.SYNOPSIS
    Example script demonstrating attribute mapping documentation features.

.DESCRIPTION
    This script shows various ways to use the new FortigiGraph attribute mapping
    documentation features. Run this as a reference for your own scripts.

.NOTES
    Author: Wim van den Heijkant
    Company: Fortigi
    Version: 1.0
#>

# Ensure FortigiGraph is loaded
Import-Module FortigiGraph -Force

Write-Host "`n=== FortigiGraph Attribute Mapping Examples ===" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# Example 1: Quick Discovery
# ============================================================================

Write-Host "`n--- Example 1: Quick Discovery of Provisioning Apps ---" -ForegroundColor Yellow
Write-Host ""
Write-Host "This example finds all apps with provisioning configured." -ForegroundColor Gray
Write-Host ""

# Authenticate first (replace with your values)
# Get-FGAccessToken -TenantId "..." -ClientId "..." -ClientSecret "..."

# Quick discovery
Write-Host "Running: Get-FGServicePrincipalWithSync" -ForegroundColor Cyan
try {
    $Apps = Get-FGServicePrincipalWithSync

    if ($Apps) {
        Write-Host ""
        Write-Host "Found $($Apps.Count) app(s) with provisioning:" -ForegroundColor Green
        $Apps | Select-Object DisplayName, AppType, JobCount | Format-Table -AutoSize
    }
    else {
        Write-Host "No apps with provisioning found." -ForegroundColor Yellow
    }
}
catch {
    Write-Host "Error: $_" -ForegroundColor Red
    Write-Host "Make sure you authenticate first with Get-FGAccessToken" -ForegroundColor Yellow
}

# ============================================================================
# Example 2: Include Cloud Sync
# ============================================================================

Write-Host "`n--- Example 2: Include Azure AD Connect Cloud Sync ---" -ForegroundColor Yellow
Write-Host ""
Write-Host "This example includes Cloud Sync in the discovery." -ForegroundColor Gray
Write-Host ""

Write-Host "Running: Get-FGServicePrincipalWithSync -IncludeCloudSync" -ForegroundColor Cyan
try {
    $AppsWithCloudSync = Get-FGServicePrincipalWithSync -IncludeCloudSync

    if ($AppsWithCloudSync) {
        Write-Host ""
        Write-Host "Found $($AppsWithCloudSync.Count) app(s) including Cloud Sync:" -ForegroundColor Green

        # Group by type
        $AppsWithCloudSync | Group-Object AppType | ForEach-Object {
            Write-Host "  $($_.Name): $($_.Count) app(s)" -ForegroundColor Cyan
        }
    }
}
catch {
    Write-Host "Error: $_" -ForegroundColor Red
}

# ============================================================================
# Example 3: Get Detailed Job Information
# ============================================================================

Write-Host "`n--- Example 3: Get Synchronization Job Details ---" -ForegroundColor Yellow
Write-Host ""
Write-Host "This example retrieves detailed job information for each app." -ForegroundColor Gray
Write-Host ""

Write-Host "Running: Get-FGServicePrincipalWithSync -IncludeJobs" -ForegroundColor Cyan
try {
    $AppsWithJobs = Get-FGServicePrincipalWithSync -IncludeJobs

    if ($AppsWithJobs) {
        foreach ($app in $AppsWithJobs) {
            Write-Host ""
            Write-Host "App: $($app.DisplayName)" -ForegroundColor Green
            Write-Host "  Type: $($app.AppType)" -ForegroundColor Gray
            Write-Host "  Jobs:" -ForegroundColor Gray

            foreach ($job in $app.Jobs) {
                Write-Host "    - Job ID: $($job.id)" -ForegroundColor Cyan
                Write-Host "      Template: $($job.templateId)" -ForegroundColor Cyan
                Write-Host "      Status: $($job.status.code)" -ForegroundColor $(if ($job.status.code -eq "Active") { "Green" } else { "Yellow" })

                if ($job.schedule) {
                    Write-Host "      Schedule: $($job.schedule.state) (Interval: $($job.schedule.interval))" -ForegroundColor Cyan
                }
            }
        }
    }
}
catch {
    Write-Host "Error: $_" -ForegroundColor Red
}

# ============================================================================
# Example 4: Analyze Specific Attribute
# ============================================================================

Write-Host "`n--- Example 4: Find All Mappings for 'mail' Attribute ---" -ForegroundColor Yellow
Write-Host ""
Write-Host "This example finds all apps that map the 'mail' attribute." -ForegroundColor Gray
Write-Host ""

$TargetAttribute = "mail"
Write-Host "Searching for mappings of attribute: $TargetAttribute" -ForegroundColor Cyan
Write-Host ""

try {
    $AppsWithSchema = Get-FGServicePrincipalWithSync -IncludeSchema

    $Found = $false

    foreach ($app in $AppsWithSchema) {
        if ($app.Schemas) {
            foreach ($schemaObj in $app.Schemas) {
                $schema = $schemaObj.Schema

                if ($schema -and $schema.synchronizationRules) {
                    foreach ($rule in $schema.synchronizationRules) {
                        foreach ($objMapping in $rule.objectMappings) {
                            $mailMappings = $objMapping.attributeMappings |
                                Where-Object { $_.targetAttributeName -eq $TargetAttribute }

                            if ($mailMappings) {
                                $Found = $true
                                Write-Host "Found in: $($app.DisplayName)" -ForegroundColor Green
                                Write-Host "  Direction: $($rule.sourceDirectoryName) → $($rule.targetDirectoryName)" -ForegroundColor Cyan

                                foreach ($mapping in $mailMappings) {
                                    Write-Host "  Source: $($mapping.source.expression)" -ForegroundColor Yellow
                                    Write-Host "  Flow Type: $($mapping.flowType)" -ForegroundColor Gray
                                }
                                Write-Host ""
                            }
                        }
                    }
                }
            }
        }
    }

    if (-not $Found) {
        Write-Host "No mappings found for attribute: $TargetAttribute" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "Error: $_" -ForegroundColor Red
}

# ============================================================================
# Example 5: Generate Complete Documentation
# ============================================================================

Write-Host "`n--- Example 5: Generate Complete Markdown Documentation ---" -ForegroundColor Yellow
Write-Host ""
Write-Host "This example generates a complete Markdown documentation file." -ForegroundColor Gray
Write-Host ""

$OutputPath = ".\Example-Attribute-Mappings-$(Get-Date -Format 'yyyy-MM-dd-HHmmss').md"

Write-Host "Generating documentation to: $OutputPath" -ForegroundColor Cyan
Write-Host ""

try {
    # Run the export script
    & "$PSScriptRoot\Export-AttributeMappingDocumentation.ps1" `
        -OutputPath $OutputPath `
        -IncludeCloudSync

    Write-Host ""
    Write-Host "Documentation generated successfully!" -ForegroundColor Green
    Write-Host "Open with: code $OutputPath" -ForegroundColor Cyan
}
catch {
    Write-Host "Error generating documentation: $_" -ForegroundColor Red
}

# ============================================================================
# Example 6: Filter by Application Type
# ============================================================================

Write-Host "`n--- Example 6: Find Only Workday Provisioning ---" -ForegroundColor Yellow
Write-Host ""
Write-Host "This example filters to find only Workday provisioning apps." -ForegroundColor Gray
Write-Host ""

Write-Host "Running: Get-FGServicePrincipalWithSync -Filter ""startswith(displayName,'Workday')""" -ForegroundColor Cyan
try {
    $WorkdayApps = Get-FGServicePrincipalWithSync -Filter "startswith(displayName,'Workday')" -IncludeJobs

    if ($WorkdayApps) {
        Write-Host ""
        Write-Host "Found Workday provisioning:" -ForegroundColor Green
        $WorkdayApps | Select-Object DisplayName, AppType, JobCount | Format-Table -AutoSize
    }
    else {
        Write-Host "No Workday provisioning found." -ForegroundColor Yellow
    }
}
catch {
    Write-Host "Error: $_" -ForegroundColor Red
}

# ============================================================================
# Example 7: Get Specific Job Schema
# ============================================================================

Write-Host "`n--- Example 7: Get Schema for Specific Job ---" -ForegroundColor Yellow
Write-Host ""
Write-Host "This example retrieves the schema for a specific synchronization job." -ForegroundColor Gray
Write-Host ""

try {
    # First, get any app with provisioning
    $SampleApp = Get-FGServicePrincipalWithSync -IncludeJobs | Select-Object -First 1

    if ($SampleApp -and $SampleApp.Jobs) {
        $SampleJob = $SampleApp.Jobs[0]

        Write-Host "Getting schema for:" -ForegroundColor Cyan
        Write-Host "  App: $($SampleApp.DisplayName)" -ForegroundColor Gray
        Write-Host "  Job ID: $($SampleJob.id)" -ForegroundColor Gray
        Write-Host ""

        $Schema = Get-FGSynchronizationSchema `
            -ServicePrincipalId $SampleApp.ServicePrincipalId `
            -JobId $SampleJob.id

        if ($Schema) {
            Write-Host "Schema retrieved successfully!" -ForegroundColor Green
            Write-Host ""
            Write-Host "Synchronization Rules:" -ForegroundColor Cyan

            foreach ($rule in $Schema.synchronizationRules) {
                Write-Host "  - $($rule.name)" -ForegroundColor Yellow
                Write-Host "    Source: $($rule.sourceDirectoryName)" -ForegroundColor Gray
                Write-Host "    Target: $($rule.targetDirectoryName)" -ForegroundColor Gray
                Write-Host "    Object Mappings: $($rule.objectMappings.Count)" -ForegroundColor Gray

                # Count total attribute mappings
                $TotalMappings = 0
                foreach ($objMapping in $rule.objectMappings) {
                    $TotalMappings += $objMapping.attributeMappings.Count
                }
                Write-Host "    Total Attribute Mappings: $TotalMappings" -ForegroundColor Gray
                Write-Host ""
            }
        }
    }
    else {
        Write-Host "No apps with provisioning found to demonstrate." -ForegroundColor Yellow
    }
}
catch {
    Write-Host "Error: $_" -ForegroundColor Red
}

# ============================================================================
# Summary
# ============================================================================

Write-Host "`n=== Examples Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Cyan
Write-Host "  1. Authenticate: Get-FGAccessToken -TenantId '...' -ClientId '...' -ClientSecret '...'" -ForegroundColor Gray
Write-Host "  2. Discover apps: Get-FGServicePrincipalWithSync" -ForegroundColor Gray
Write-Host "  3. Generate docs: .\Export-AttributeMappingDocumentation.ps1" -ForegroundColor Gray
Write-Host ""
Write-Host "For more information, see README-Attribute-Mapping.md" -ForegroundColor Gray
Write-Host ""
