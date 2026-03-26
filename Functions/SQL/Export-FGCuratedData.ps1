function Export-FGCuratedData {
    <#
    .SYNOPSIS
    Exports manually curated data that cannot be re-synced from source systems.

    .DESCRIPTION
    Exports the following curated data to a JSON file:
    - Tags and their assignments (user tags, resource/group tags)
    - Categories and their access package assignments
    - Analyst overrides on identity correlation results

    This data represents work done manually in the UI and is not recoverable from
    Microsoft Graph or any other source system. Use Import-FGCuratedData to restore
    after recreating an environment or migrating to a new database.

    .PARAMETER Path
    Path to the output JSON file. Defaults to .\FGCuratedData_<timestamp>.json

    .PARAMETER ConfigFile
    Path to a FortigiGraph config file for SQL connection.

    .EXAMPLE
    Export-FGCuratedData -Path .\Backup\curated_2026.json -ConfigFile .\Config\mycompany.json
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $false)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [string]$ConfigFile
    )

    if (-not $Path) {
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $Path = ".\FGCuratedData_$timestamp.json"
    }

    if ($ConfigFile -and -not $global:FGSQLConnectionString) {
        Connect-FGSQLServer -ConfigFile $ConfigFile
    }

    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Run Connect-FGSQLServer first or provide -ConfigFile."
    }

    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Exporting curated data..." -ForegroundColor Cyan

    $conn = New-Object System.Data.SqlClient.SqlConnection($global:FGSQLConnectionString)
    $conn.Open()

    try {
        $tags      = @()
        $categories = @()
        $overrides  = @()

        # ── 1. Tags + Assignments ──────────────────────────────────────────
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
SELECT
    t.id, t.name, t.color, t.entityType,
    ta.entityId,
    COALESCE(gu.displayName, gg.displayName, r.displayName) AS entityDisplayName
FROM dbo.GraphTags t
LEFT JOIN dbo.GraphTagAssignments ta ON ta.tagId = t.id
LEFT JOIN dbo.GraphUsers gu
    ON t.entityType = 'user' AND gu.id = TRY_CAST(ta.entityId AS UNIQUEIDENTIFIER)
LEFT JOIN dbo.GraphGroups gg
    ON t.entityType = 'group' AND gg.id = TRY_CAST(ta.entityId AS UNIQUEIDENTIFIER)
LEFT JOIN dbo.Resources r
    ON t.entityType = 'resource' AND r.id = TRY_CAST(ta.entityId AS UNIQUEIDENTIFIER)
       AND r.ValidTo = '9999-12-31 23:59:59.9999999'
ORDER BY t.entityType, t.name, ta.entityId
"@
        $reader = $cmd.ExecuteReader()
        $tagById = @{}
        while ($reader.Read()) {
            $id = [string]$reader['id']
            if (-not $tagById.ContainsKey($id)) {
                $tagById[$id] = @{
                    name        = [string]$reader['name']
                    color       = if ($reader['color'] -is [DBNull]) { $null } else { [string]$reader['color'] }
                    entityType  = [string]$reader['entityType']
                    assignments = [System.Collections.Generic.List[object]]::new()
                }
            }
            if ($reader['entityId'] -isnot [DBNull]) {
                $tagById[$id].assignments.Add(@{
                    entityId    = [string]$reader['entityId']
                    displayName = if ($reader['entityDisplayName'] -is [DBNull]) { $null } else { [string]$reader['entityDisplayName'] }
                })
            }
        }
        $reader.Close()
        $tags = @($tagById.Values | ForEach-Object { [PSCustomObject]$_ })
        $totalAssignments = ($tags | Measure-Object -Property { $_.assignments.Count } -Sum).Sum
        Write-Host "  Tags: $($tags.Count) tags, $totalAssignments assignments" -ForegroundColor Gray

        # ── 2. Categories + AP Assignments ────────────────────────────────
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
SELECT
    c.id, c.name, c.color,
    ca.resourceId AS accessPackageId,
    ap.displayName AS accessPackageDisplayName
FROM dbo.GovernanceCategories c
LEFT JOIN dbo.GovernanceCategoryAssignments ca ON ca.categoryId = c.id
LEFT JOIN dbo.Resources ap
    ON ap.id = ca.resourceId AND ap.resourceType = 'BusinessRole' AND ap.ValidTo = '9999-12-31 23:59:59.9999999'
ORDER BY c.name, ca.resourceId
"@
        $reader = $cmd.ExecuteReader()
        $catById = @{}
        while ($reader.Read()) {
            $id = [string]$reader['id']
            if (-not $catById.ContainsKey($id)) {
                $catById[$id] = @{
                    name        = [string]$reader['name']
                    color       = if ($reader['color'] -is [DBNull]) { $null } else { [string]$reader['color'] }
                    assignments = [System.Collections.Generic.List[object]]::new()
                }
            }
            if ($reader['accessPackageId'] -isnot [DBNull]) {
                $catById[$id].assignments.Add(@{
                    accessPackageId          = [string]$reader['accessPackageId']
                    accessPackageDisplayName = if ($reader['accessPackageDisplayName'] -is [DBNull]) { $null } else { [string]$reader['accessPackageDisplayName'] }
                })
            }
        }
        $reader.Close()
        $categories = @($catById.Values | ForEach-Object { [PSCustomObject]$_ })
        $totalCatAssign = ($categories | Measure-Object -Property { $_.assignments.Count } -Sum).Sum
        Write-Host "  Categories: $($categories.Count) categories, $totalCatAssign AP assignments" -ForegroundColor Gray

        # ── 3. Analyst Overrides ──────────────────────────────────────────
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
SELECT im.userId, im.userPrincipalName, im.displayName, im.analystOverride, im.analystReason
FROM dbo.GraphIdentityMembers im
WHERE im.analystOverride IS NOT NULL
  AND im.ValidTo = '9999-12-31 23:59:59.9999999'
ORDER BY im.userPrincipalName
"@
        $reader = $cmd.ExecuteReader()
        while ($reader.Read()) {
            $overrides += [PSCustomObject]@{
                userId            = if ($reader['userId'] -is [DBNull]) { $null } else { [string]$reader['userId'] }
                userPrincipalName = if ($reader['userPrincipalName'] -is [DBNull]) { $null } else { [string]$reader['userPrincipalName'] }
                displayName       = if ($reader['displayName'] -is [DBNull]) { $null } else { [string]$reader['displayName'] }
                analystOverride   = [string]$reader['analystOverride']
                analystReason     = if ($reader['analystReason'] -is [DBNull]) { $null } else { [string]$reader['analystReason'] }
            }
        }
        $reader.Close()
        Write-Host "  Analyst overrides: $($overrides.Count)" -ForegroundColor Gray

    } finally {
        $conn.Close()
    }

    $export = [PSCustomObject]@{
        exportedAt       = (Get-Date -Format 'o')
        version          = '1.0'
        tags             = $tags
        categories       = $categories
        analystOverrides = $overrides
    }

    $json = $export | ConvertTo-Json -Depth 10
    Set-Content -Path $Path -Value $json -Encoding UTF8

    $fileSize = [math]::Round((Get-Item $Path).Length / 1KB, 1)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Export complete: $Path ($fileSize KB)" -ForegroundColor Green
    Write-Host "  $($tags.Count) tags  |  $($categories.Count) categories  |  $($overrides.Count) analyst overrides" -ForegroundColor Gray
}
