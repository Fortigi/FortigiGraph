function Import-FGCuratedData {
    <#
    .SYNOPSIS
    Imports manually curated data from a file created by Export-FGCuratedData.

    .DESCRIPTION
    Restores the following curated data from a JSON export file:
    - Tags and their entity assignments
    - Categories and their access package assignments
    - Analyst overrides on identity correlation results

    Safe to run multiple times (idempotent). Existing data is not overwritten
    unless -Overwrite is specified. Assignments for entities that no longer exist
    in the database are skipped with a warning.

    .PARAMETER Path
    Path to the JSON file created by Export-FGCuratedData.

    .PARAMETER ConfigFile
    Path to a FortigiGraph config file for SQL connection.

    .PARAMETER Overwrite
    If specified, overwrites existing tag colors, category colors, and analyst
    overrides with values from the import file. Without this flag, only missing
    records are inserted (existing ones are left unchanged).

    .EXAMPLE
    Import-FGCuratedData -Path .\Backup\curated_2026.json -ConfigFile .\Config\mycompany.json

    .EXAMPLE
    Import-FGCuratedData -Path .\curated.json -ConfigFile .\Config\mycompany.json -Overwrite
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [string]$ConfigFile,

        [Parameter(Mandatory = $false)]
        [switch]$Overwrite
    )

    if (-not (Test-Path $Path)) {
        throw "Import file not found: $Path"
    }

    if ($ConfigFile -and -not $global:FGSQLConnectionString) {
        Connect-FGSQLServer -ConfigFile $ConfigFile
    }

    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Run Connect-FGSQLServer first or provide -ConfigFile."
    }

    $importData = Get-Content -Path $Path -Raw | ConvertFrom-Json
    if (-not $importData.version) {
        throw "Invalid export file format. Expected a file created by Export-FGCuratedData."
    }

    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Importing curated data from: $Path" -ForegroundColor Cyan
    Write-Host "  Exported at: $($importData.exportedAt)" -ForegroundColor Gray
    Write-Host "  Tags: $($importData.tags.Count)  |  Categories: $($importData.categories.Count)  |  Overrides: $($importData.analystOverrides.Count)" -ForegroundColor Gray

    $conn = New-Object System.Data.SqlClient.SqlConnection($global:FGSQLConnectionString)
    $conn.Open()

    try {
        # ── 1. Tags ────────────────────────────────────────────────────────
        if ($importData.tags.Count -gt 0) {
            Write-Host "`n  Importing tags..." -ForegroundColor Cyan

            $tagsInserted = 0; $tagsSkipped = 0
            $assignmentsInserted = 0; $assignmentsSkipped = 0

            foreach ($tag in $importData.tags) {
                # Check if tag exists
                $checkCmd = $conn.CreateCommand()
                $checkCmd.CommandText = "SELECT id FROM dbo.GraphTags WHERE name = @name AND entityType = @entityType"
                $checkCmd.Parameters.AddWithValue("@name", $tag.name) | Out-Null
                $checkCmd.Parameters.AddWithValue("@entityType", $tag.entityType) | Out-Null
                $tagId = $checkCmd.ExecuteScalar()

                if ($null -eq $tagId -or $tagId -is [DBNull]) {
                    $insertCmd = $conn.CreateCommand()
                    $insertCmd.CommandText = "INSERT INTO dbo.GraphTags (name, color, entityType, createdAt) OUTPUT INSERTED.id VALUES (@name, @color, @entityType, GETDATE())"
                    $insertCmd.Parameters.AddWithValue("@name", $tag.name) | Out-Null
                    $insertCmd.Parameters.AddWithValue("@color", $(if ($tag.color) { $tag.color } else { [DBNull]::Value })) | Out-Null
                    $insertCmd.Parameters.AddWithValue("@entityType", $tag.entityType) | Out-Null
                    $tagId = $insertCmd.ExecuteScalar()
                    $tagsInserted++
                } else {
                    if ($Overwrite -and $tag.color) {
                        $updateCmd = $conn.CreateCommand()
                        $updateCmd.CommandText = "UPDATE dbo.GraphTags SET color = @color WHERE id = @id"
                        $updateCmd.Parameters.AddWithValue("@color", $tag.color) | Out-Null
                        $updateCmd.Parameters.AddWithValue("@id", $tagId) | Out-Null
                        $updateCmd.ExecuteNonQuery() | Out-Null
                    }
                    $tagsSkipped++
                }

                foreach ($assignment in $tag.assignments) {
                    $checkCmd = $conn.CreateCommand()
                    $checkCmd.CommandText = "SELECT COUNT(*) FROM dbo.GraphTagAssignments WHERE tagId = @tagId AND entityId = @entityId"
                    $checkCmd.Parameters.AddWithValue("@tagId", $tagId) | Out-Null
                    $checkCmd.Parameters.AddWithValue("@entityId", $assignment.entityId) | Out-Null
                    $exists = [int]$checkCmd.ExecuteScalar()

                    if ($exists -eq 0) {
                        $insertCmd = $conn.CreateCommand()
                        $insertCmd.CommandText = "INSERT INTO dbo.GraphTagAssignments (tagId, entityId) VALUES (@tagId, @entityId)"
                        $insertCmd.Parameters.AddWithValue("@tagId", $tagId) | Out-Null
                        $insertCmd.Parameters.AddWithValue("@entityId", $assignment.entityId) | Out-Null
                        $insertCmd.ExecuteNonQuery() | Out-Null
                        $assignmentsInserted++
                    } else {
                        $assignmentsSkipped++
                    }
                }
            }
            Write-Host "    Tags: $tagsInserted inserted, $tagsSkipped already existed" -ForegroundColor Gray
            Write-Host "    Assignments: $assignmentsInserted inserted, $assignmentsSkipped already existed" -ForegroundColor Gray
        }

        # ── 2. Categories ──────────────────────────────────────────────────
        if ($importData.categories.Count -gt 0) {
            Write-Host "`n  Importing categories..." -ForegroundColor Cyan

            $catsInserted = 0; $catsSkipped = 0
            $catAssignInserted = 0; $catAssignSkipped = 0

            foreach ($cat in $importData.categories) {
                $checkCmd = $conn.CreateCommand()
                $checkCmd.CommandText = "SELECT id FROM dbo.GraphCategories WHERE name = @name"
                $checkCmd.Parameters.AddWithValue("@name", $cat.name) | Out-Null
                $catId = $checkCmd.ExecuteScalar()

                if ($null -eq $catId -or $catId -is [DBNull]) {
                    $insertCmd = $conn.CreateCommand()
                    $insertCmd.CommandText = "INSERT INTO dbo.GraphCategories (name, color, createdAt) OUTPUT INSERTED.id VALUES (@name, @color, GETDATE())"
                    $insertCmd.Parameters.AddWithValue("@name", $cat.name) | Out-Null
                    $insertCmd.Parameters.AddWithValue("@color", $(if ($cat.color) { $cat.color } else { [DBNull]::Value })) | Out-Null
                    $catId = $insertCmd.ExecuteScalar()
                    $catsInserted++
                } else {
                    if ($Overwrite -and $cat.color) {
                        $updateCmd = $conn.CreateCommand()
                        $updateCmd.CommandText = "UPDATE dbo.GraphCategories SET color = @color WHERE id = @id"
                        $updateCmd.Parameters.AddWithValue("@color", $cat.color) | Out-Null
                        $updateCmd.Parameters.AddWithValue("@id", $catId) | Out-Null
                        $updateCmd.ExecuteNonQuery() | Out-Null
                    }
                    $catsSkipped++
                }

                foreach ($apAssign in $cat.assignments) {
                    $checkCmd = $conn.CreateCommand()
                    $checkCmd.CommandText = "SELECT COUNT(*) FROM dbo.GraphCategoryAssignments WHERE categoryId = @catId AND accessPackageId = @apId"
                    $checkCmd.Parameters.AddWithValue("@catId", $catId) | Out-Null
                    $checkCmd.Parameters.AddWithValue("@apId", $apAssign.accessPackageId) | Out-Null
                    $exists = [int]$checkCmd.ExecuteScalar()

                    if ($exists -eq 0) {
                        $insertCmd = $conn.CreateCommand()
                        $insertCmd.CommandText = "INSERT INTO dbo.GraphCategoryAssignments (categoryId, accessPackageId) VALUES (@catId, @apId)"
                        $insertCmd.Parameters.AddWithValue("@catId", $catId) | Out-Null
                        $insertCmd.Parameters.AddWithValue("@apId", $apAssign.accessPackageId) | Out-Null
                        $insertCmd.ExecuteNonQuery() | Out-Null
                        $catAssignInserted++
                    } else {
                        $catAssignSkipped++
                    }
                }
            }
            Write-Host "    Categories: $catsInserted inserted, $catsSkipped already existed" -ForegroundColor Gray
            Write-Host "    AP assignments: $catAssignInserted inserted, $catAssignSkipped already existed" -ForegroundColor Gray
        }

        # ── 3. Analyst Overrides ───────────────────────────────────────────
        if ($importData.analystOverrides.Count -gt 0) {
            Write-Host "`n  Importing analyst overrides..." -ForegroundColor Cyan

            $overridesApplied = 0; $overridesSkipped = 0; $overridesNotFound = 0

            foreach ($override in $importData.analystOverrides) {
                $lookupKey = if ($override.userPrincipalName) { $override.userPrincipalName } else { $override.userId }

                # Look up the record
                $findCmd = $conn.CreateCommand()
                if ($override.userPrincipalName) {
                    $findCmd.CommandText = "SELECT analystOverride FROM dbo.GraphIdentityMembers WHERE userPrincipalName = @key AND ValidTo = '9999-12-31 23:59:59.9999999'"
                } else {
                    $findCmd.CommandText = "SELECT analystOverride FROM dbo.GraphIdentityMembers WHERE userId = @key AND ValidTo = '9999-12-31 23:59:59.9999999'"
                }
                $findCmd.Parameters.AddWithValue("@key", $lookupKey) | Out-Null
                $existing = $findCmd.ExecuteScalar()

                if ($null -eq $existing) {
                    # Record not found (DBNull means found but override is null — that's fine to update)
                    Write-Host "    Warning: No identity member found for '$lookupKey' — run Invoke-FGAccountCorrelation first" -ForegroundColor Yellow
                    $overridesNotFound++
                    continue
                }

                # Check if already set and -Overwrite not specified
                if ($existing -isnot [DBNull] -and $null -ne $existing -and -not $Overwrite) {
                    $overridesSkipped++
                    continue
                }

                $updateCmd = $conn.CreateCommand()
                if ($override.userPrincipalName) {
                    $updateCmd.CommandText = "UPDATE dbo.GraphIdentityMembers SET analystOverride = @override, analystReason = @reason WHERE userPrincipalName = @key AND ValidTo = '9999-12-31 23:59:59.9999999'"
                } else {
                    $updateCmd.CommandText = "UPDATE dbo.GraphIdentityMembers SET analystOverride = @override, analystReason = @reason WHERE userId = @key AND ValidTo = '9999-12-31 23:59:59.9999999'"
                }
                $updateCmd.Parameters.AddWithValue("@key", $lookupKey) | Out-Null
                $updateCmd.Parameters.AddWithValue("@override", $override.analystOverride) | Out-Null
                $updateCmd.Parameters.AddWithValue("@reason", $(if ($override.analystReason) { $override.analystReason } else { [DBNull]::Value })) | Out-Null
                $rows = $updateCmd.ExecuteNonQuery()

                if ($rows -gt 0) { $overridesApplied++ } else { $overridesNotFound++ }
            }

            Write-Host "    Overrides: $overridesApplied applied, $overridesSkipped already set (use -Overwrite to replace), $overridesNotFound not found" -ForegroundColor Gray
        }

    } finally {
        $conn.Close()
    }

    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Import complete" -ForegroundColor Green
}
