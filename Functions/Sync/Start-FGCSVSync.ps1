function Start-FGCSVSync {
    <#
    .SYNOPSIS
    Orchestrates CSV-based data sync from Omada Identity exports into the universal data model.

    .DESCRIPTION
    Loads all CSVs from a folder in dependency order and syncs them to the FortigiGraph
    universal data model tables (Systems, Contexts, Resources, Principals, Identities,
    ResourceAssignments, ResourceRelationships, AssignmentPolicies, CertificationDecisions).

    CSVs are expected to use semicolon (;) delimiter and UTF-8 encoding.

    The function:
    - Validates folder and detects which CSVs are present
    - Ensures system tables and governance tables exist
    - Creates/gets the parent system record
    - Loads CSVs in dependency order (systems -> org units -> resources -> details ->
      relationships -> principals -> identities -> assignments -> certifications)
    - Prints a summary of all sync operations

    .PARAMETER FolderPath
    Path to the folder containing Omada Identity CSV exports.

    .PARAMETER SystemType
    Type identifier for the parent system. Default: 'OmadaIdentity'

    .PARAMETER SystemDisplayName
    Display name for the parent system. Default: 'Omada Identity'

    .EXAMPLE
    Start-FGCSVSync -FolderPath "C:\Exports\OmadaIdentity"

    Loads all available CSVs from the folder using default system settings.

    .EXAMPLE
    Start-FGCSVSync -FolderPath ".\exports" -SystemType "OmadaIdentity" -SystemDisplayName "Omada Identity (Production)"

    Loads CSVs with a custom system display name.

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Initialize-FGSystemTables to create base tables
    - CSV files with semicolon delimiter and UTF-8 encoding
    #>

    [CmdletBinding()]
    [Alias("Start-CSVSync")]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$FolderPath,

        [Parameter(Mandatory = $false)]
        [string]$SystemType = "OmadaIdentity",

        [Parameter(Mandatory = $false)]
        [string]$SystemDisplayName = "Omada Identity"
    )

    $ErrorActionPreference = "Stop"

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "FortigiGraph CSV Sync" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
    Write-Host "Folder:  $FolderPath" -ForegroundColor Cyan
    Write-Host "System:  $SystemDisplayName ($SystemType)`n" -ForegroundColor Cyan

    # Track sync statistics
    $syncStats = @{
        StartTime = Get-Date
        Systems = $null
        OrgUnits = $null
        Resources = $null
        ResourceDetails = $null
        ResourceRelationships = $null
        Principals = $null
        Identities = $null
        ResourceAssignments = $null
        Certifications = $null
        Errors = @()
    }

    #region Validation
    # Validate folder exists
    if (-not (Test-Path $FolderPath -PathType Container)) {
        throw "Folder not found: $FolderPath"
    }

    # Check SQL connection
    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    # Detect which CSVs are present
    $csvFiles = @{
        Systems               = Join-Path $FolderPath "System.csv"
        OrgUnits              = Join-Path $FolderPath "Orgunits.csv"
        Resources             = Join-Path $FolderPath "ResourceSystem.csv"
        ResourceDetails       = Join-Path $FolderPath "Permission-full-details.csv"
        ResourceRelationships = Join-Path $FolderPath "Permission-Nesting.csv"
        Principals            = Join-Path $FolderPath "Users.csv"
        Identities            = Join-Path $FolderPath "Identities.csv"
        Employment            = Join-Path $FolderPath "Employment.csv"
        ResourceAssignments   = Join-Path $FolderPath "Account-Permission.csv"
        Certifications        = Join-Path $FolderPath "CRAs.csv"
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Scanning for CSV files..." -ForegroundColor Cyan
    $foundCount = 0
    foreach ($key in $csvFiles.Keys) {
        $exists = Test-Path $csvFiles[$key]
        $status = if ($exists) { $foundCount++; "Found" } else { "Not found" }
        $color = if ($exists) { "Green" } else { "Gray" }
        Write-Host "  $($key.PadRight(22)) $status  ($($csvFiles[$key] | Split-Path -Leaf))" -ForegroundColor $color
    }

    if ($foundCount -eq 0) {
        throw "No recognized CSV files found in $FolderPath. Expected: System.csv, Orgunits.csv, ResourceSystem.csv, Permission-full-details.csv, Permission-Nesting.csv, Users.csv, Identities.csv, Employment.csv, Account-Permission.csv, CRAs.csv"
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Found $foundCount CSV file(s)`n" -ForegroundColor Green
    #endregion

    try {
        #region Initialize Tables
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Ensuring system tables exist..." -ForegroundColor Cyan
        Initialize-FGSystemTables
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] System tables ready" -ForegroundColor Green

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Ensuring governance tables exist..." -ForegroundColor Cyan
        Initialize-FGGovernanceTables
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Governance tables ready`n" -ForegroundColor Green
        #endregion

        #region Create Parent System
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Creating/retrieving parent system record..." -ForegroundColor Cyan
        $parentSystemId = Sync-FGSystem -SystemType $SystemType -DisplayName $SystemDisplayName -UpdateLastSync
        if (-not $parentSystemId) {
            throw "Could not find or create a system record for '$SystemType'. Please run Initialize-FGSystemTables first."
        }
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Parent system ID: $parentSystemId`n" -ForegroundColor Green
        #endregion

        #region Sync in Dependency Order

        # 1. Systems (child systems under the parent)
        if (Test-Path $csvFiles.Systems) {
            Write-Host "`n=== Syncing Systems ===" -ForegroundColor Yellow
            try {
                $syncStats.Systems = Sync-FGCSVSystem -Path $csvFiles.Systems -ParentSystemId $parentSystemId
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Systems sync complete" -ForegroundColor Green
            }
            catch {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Systems sync failed: $_" -ForegroundColor Red
                $syncStats.Errors += [PSCustomObject]@{ Entity = "Systems"; Message = $_.Exception.Message; Timestamp = Get-Date }
            }
        }

        # 2. OrgUnits (populates $Global:FGCSVOrgUnitLookup for identity context resolution)
        if (Test-Path $csvFiles.OrgUnits) {
            Write-Host "`n=== Syncing OrgUnits ===" -ForegroundColor Yellow
            try {
                $syncStats.OrgUnits = Sync-FGCSVOrgUnit -Path $csvFiles.OrgUnits
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] OrgUnits sync complete" -ForegroundColor Green
            }
            catch {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] OrgUnits sync failed: $_" -ForegroundColor Red
                $syncStats.Errors += [PSCustomObject]@{ Entity = "OrgUnits"; Message = $_.Exception.Message; Timestamp = Get-Date }
            }
        }

        # 3. Resources (depends on system lookup)
        if (Test-Path $csvFiles.Resources) {
            Write-Host "`n=== Syncing Resources ===" -ForegroundColor Yellow
            try {
                $syncStats.Resources = Sync-FGCSVResource -Path $csvFiles.Resources
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Resources sync complete" -ForegroundColor Green
            }
            catch {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Resources sync failed: $_" -ForegroundColor Red
                $syncStats.Errors += [PSCustomObject]@{ Entity = "Resources"; Message = $_.Exception.Message; Timestamp = Get-Date }
            }
        }

        # 4. Resource Details (enriches Resources from Permission-full-details.csv)
        if (Test-Path $csvFiles.ResourceDetails) {
            Write-Host "`n=== Syncing Resource Details ===" -ForegroundColor Yellow
            try {
                $syncStats.ResourceDetails = Sync-FGCSVResourceDetail -Path $csvFiles.ResourceDetails
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Resource Details sync complete" -ForegroundColor Green
            }
            catch {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Resource Details sync failed: $_" -ForegroundColor Red
                $syncStats.Errors += [PSCustomObject]@{ Entity = "ResourceDetails"; Message = $_.Exception.Message; Timestamp = Get-Date }
            }
        }

        # 5. Resource Relationships (Permission-Nesting.csv, depends on Resources)
        if (Test-Path $csvFiles.ResourceRelationships) {
            Write-Host "`n=== Syncing Resource Relationships ===" -ForegroundColor Yellow
            try {
                $syncStats.ResourceRelationships = Sync-FGCSVResourceRelationship -Path $csvFiles.ResourceRelationships
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Resource Relationships sync complete" -ForegroundColor Green
            }
            catch {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Resource Relationships sync failed: $_" -ForegroundColor Red
                $syncStats.Errors += [PSCustomObject]@{ Entity = "ResourceRelationships"; Message = $_.Exception.Message; Timestamp = Get-Date }
            }
        }

        # 6. Business Roles — SKIPPED for CSV sync
        # Business roles are loaded from ResourceSystem.csv (resourceType='BusinessRole') by Sync-FGCSVResource.
        # Resource grants come from Permission-Nesting.csv by Sync-FGCSVResourceRelationship.
        # Governed assignments come from Account-Permission.csv by Sync-FGCSVResourceAssignment.
        # Sync-FGCSVBusinessRole is NOT called here because it creates duplicate resources with
        # deterministic GUIDs that conflict with the real UUIDs from ResourceSystem.csv, and its
        # delete step removes the correct relationships loaded by Sync-FGCSVResourceRelationship.

        # 7. Principals (users/accounts)
        if (Test-Path $csvFiles.Principals) {
            Write-Host "`n=== Syncing Principals ===" -ForegroundColor Yellow
            try {
                $syncStats.Principals = Sync-FGCSVPrincipal -Path $csvFiles.Principals
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Principals sync complete" -ForegroundColor Green
            }
            catch {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Principals sync failed: $_" -ForegroundColor Red
                $syncStats.Errors += [PSCustomObject]@{ Entity = "Principals"; Message = $_.Exception.Message; Timestamp = Get-Date }
            }
        }

        # 7. Identities (with optional Employment.csv for org unit context)
        if (Test-Path $csvFiles.Identities) {
            Write-Host "`n=== Syncing Identities ===" -ForegroundColor Yellow
            try {
                $identityParams = @{ Path = $csvFiles.Identities }
                if (Test-Path $csvFiles.Employment) {
                    $identityParams.EmploymentPath = $csvFiles.Employment
                }
                $syncStats.Identities = Sync-FGCSVIdentity @identityParams
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Identities sync complete" -ForegroundColor Green
            }
            catch {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Identities sync failed: $_" -ForegroundColor Red
                $syncStats.Errors += [PSCustomObject]@{ Entity = "Identities"; Message = $_.Exception.Message; Timestamp = Get-Date }
            }
        }

        # 8. Resource Assignments (depends on resources + principals)
        if (Test-Path $csvFiles.ResourceAssignments) {
            Write-Host "`n=== Syncing Resource Assignments ===" -ForegroundColor Yellow
            try {
                $syncStats.ResourceAssignments = Sync-FGCSVResourceAssignment -Path $csvFiles.ResourceAssignments
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Resource Assignments sync complete" -ForegroundColor Green
            }
            catch {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Resource Assignments sync failed: $_" -ForegroundColor Red
                $syncStats.Errors += [PSCustomObject]@{ Entity = "ResourceAssignments"; Message = $_.Exception.Message; Timestamp = Get-Date }
            }
        }

        # 9. Certifications (CRAs - depends on resources + principals)
        if (Test-Path $csvFiles.Certifications) {
            Write-Host "`n=== Syncing Certifications ===" -ForegroundColor Yellow
            try {
                $syncStats.Certifications = Sync-FGCSVCertification -Path $csvFiles.Certifications
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Certifications sync complete" -ForegroundColor Green
            }
            catch {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Certifications sync failed: $_" -ForegroundColor Red
                $syncStats.Errors += [PSCustomObject]@{ Entity = "Certifications"; Message = $_.Exception.Message; Timestamp = Get-Date }
            }
        }

        #endregion

        #region Post-Sync: Views and Materialized Data

        # Initialize views and indexes (required for UI matrix + detail pages)
        Write-Host "`n=== Initializing Views & Indexes ===" -ForegroundColor Yellow
        try {
            Initialize-FGResourceViews
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Resource views ready" -ForegroundColor Green
        }
        catch {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Resource views failed: $_" -ForegroundColor Red
            $syncStats.Errors += [PSCustomObject]@{ Entity = "ResourceViews"; Message = $_.Exception.Message; Timestamp = Get-Date }
        }

        try {
            Initialize-FGResourceIndexes
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Resource indexes ready" -ForegroundColor Green
        }
        catch {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Resource indexes failed: $_" -ForegroundColor Red
            $syncStats.Errors += [PSCustomObject]@{ Entity = "ResourceIndexes"; Message = $_.Exception.Message; Timestamp = Get-Date }
        }

        try {
            Initialize-FGAccessPackageViews
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Access package views ready" -ForegroundColor Green
        }
        catch {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Access package views failed: $_" -ForegroundColor Red
            $syncStats.Errors += [PSCustomObject]@{ Entity = "AccessPackageViews"; Message = $_.Exception.Message; Timestamp = Get-Date }
        }

        # Refresh materialized views (powers the matrix UI)
        try {
            Sync-FGMaterializedViews
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Materialized views refreshed" -ForegroundColor Green
        }
        catch {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Materialized views failed: $_" -ForegroundColor Red
            $syncStats.Errors += [PSCustomObject]@{ Entity = "MaterializedViews"; Message = $_.Exception.Message; Timestamp = Get-Date }
        }

        #endregion

        # Update parent system last sync time
        Sync-FGSystem -SystemType $SystemType -DisplayName $SystemDisplayName -UpdateLastSync

    }
    catch {
        Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] CSV Sync failed with error: $_" -ForegroundColor Red
        throw
    }

    #region Summary
    $elapsed = (Get-Date) - $syncStats.StartTime

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "CSV Sync Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Duration:  $([math]::Round($elapsed.TotalMinutes, 1)) minutes" -ForegroundColor White
    Write-Host "System:    $SystemDisplayName (ID: $parentSystemId)" -ForegroundColor White

    $entities = @('Systems', 'OrgUnits', 'Resources', 'ResourceDetails', 'ResourceRelationships', 'Principals', 'Identities', 'ResourceAssignments', 'Certifications')
    foreach ($entity in $entities) {
        $result = $syncStats[$entity]
        if ($null -ne $result) {
            $count = if ($result -is [hashtable] -and $result.ContainsKey('TotalRecords')) { $result.TotalRecords } elseif ($result -is [hashtable] -and $result.ContainsKey('Count')) { $result.Count } else { "done" }
            Write-Host "  $($entity.PadRight(22)) $count" -ForegroundColor White
        }
        else {
            $csvPath = $csvFiles[$entity]
            if (Test-Path $csvPath) {
                $hasError = $syncStats.Errors | Where-Object { $_.Entity -eq $entity }
                if ($hasError) {
                    Write-Host "  $($entity.PadRight(22)) FAILED" -ForegroundColor Red
                }
                else {
                    Write-Host "  $($entity.PadRight(22)) skipped" -ForegroundColor Gray
                }
            }
            else {
                Write-Host "  $($entity.PadRight(22)) no CSV" -ForegroundColor Gray
            }
        }
    }

    if ($syncStats.Errors.Count -gt 0) {
        Write-Host "`nErrors ($($syncStats.Errors.Count)):" -ForegroundColor Red
        foreach ($err in $syncStats.Errors) {
            Write-Host "  - $($err.Entity): $($err.Message)" -ForegroundColor Red
        }
    }

    Write-Host "========================================`n" -ForegroundColor Green

    # Validation: query actual database state
    Write-Host "Database Validation:" -ForegroundColor Cyan
    try {
        Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            $cmd = $connection.CreateCommand()
            $cmd.CommandTimeout = 30
            $cmd.CommandText = @"
SELECT 'Systems' AS entity, CAST(COUNT(*) AS NVARCHAR) AS cnt, '' AS detail FROM Systems WHERE ValidTo = '9999-12-31 23:59:59.9999999'
UNION ALL SELECT 'Contexts (OrgUnits)', CAST(COUNT(*) AS NVARCHAR), '' FROM Contexts WHERE ValidTo = '9999-12-31 23:59:59.9999999'
UNION ALL SELECT 'Resources', CAST(COUNT(*) AS NVARCHAR), '' FROM Resources WHERE ValidTo = '9999-12-31 23:59:59.9999999'
UNION ALL SELECT '  BusinessRole', CAST(COUNT(*) AS NVARCHAR), '' FROM Resources WHERE resourceType = 'BusinessRole' AND ValidTo = '9999-12-31 23:59:59.9999999'
UNION ALL SELECT 'ResourceRelationships', CAST(COUNT(*) AS NVARCHAR), '' FROM ResourceRelationships WHERE ValidTo = '9999-12-31 23:59:59.9999999'
UNION ALL SELECT '  BR Contains', CAST(COUNT(*) AS NVARCHAR), '' FROM ResourceRelationships rr INNER JOIN Resources r ON rr.parentResourceId = r.id AND r.resourceType = 'BusinessRole' WHERE rr.relationshipType = 'Contains' AND rr.ValidTo = '9999-12-31 23:59:59.9999999' AND r.ValidTo = '9999-12-31 23:59:59.9999999'
UNION ALL SELECT 'Principals', CAST(COUNT(*) AS NVARCHAR), principalType FROM Principals WHERE ValidTo = '9999-12-31 23:59:59.9999999' GROUP BY principalType
UNION ALL SELECT 'Identities', CAST(COUNT(*) AS NVARCHAR), '' FROM Identities WHERE ValidTo = '9999-12-31 23:59:59.9999999'
UNION ALL SELECT '  with contextId', CAST(COUNT(contextId) AS NVARCHAR), '' FROM Identities WHERE ValidTo = '9999-12-31 23:59:59.9999999'
UNION ALL SELECT 'IdentityMembers', CAST(COUNT(*) AS NVARCHAR), '' FROM IdentityMembers WHERE ValidTo = '9999-12-31 23:59:59.9999999'
UNION ALL SELECT 'ResourceAssignments', CAST(COUNT(*) AS NVARCHAR), assignmentType FROM ResourceAssignments WHERE ValidTo = '9999-12-31 23:59:59.9999999' GROUP BY assignmentType
UNION ALL SELECT 'Mat BR view', CAST(COUNT(*) AS NVARCHAR), '' FROM mat_UserPermissionAssignmentViaBusinessRole
UNION ALL SELECT 'Mat Perm (total)', CAST(COUNT(*) AS NVARCHAR), '' FROM mat_UserPermissionAssignments
UNION ALL SELECT 'Mat Perm (managed)', CAST(SUM(CAST(managedByAccessPackage AS INT)) AS NVARCHAR), '' FROM mat_UserPermissionAssignments
"@
            $reader = $cmd.ExecuteReader()
            while ($reader.Read()) {
                $entity = $reader.GetString(0)
                $cnt = $reader.GetString(1)
                $detail = if (-not $reader.IsDBNull(2)) { $reader.GetString(2) } else { '' }
                $label = if ($detail) { "$entity ($detail)" } else { $entity }
                Write-Host "  $($label.PadRight(35)) $cnt" -ForegroundColor White
            }
            $reader.Close()
            $cmd.Dispose()
        }
    }
    catch {
        Write-Host "  Validation query failed: $_" -ForegroundColor Yellow
    }

    Write-Host "========================================`n" -ForegroundColor Green
    #endregion

    return $syncStats
}
