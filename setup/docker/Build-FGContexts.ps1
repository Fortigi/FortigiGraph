<#
.SYNOPSIS
    Builds Contexts (org units) from Principal data and links each Principal to its Context.

.DESCRIPTION
    Post-sync step that runs after a crawler completes. Two-phase build:
    1. For each unique (systemId, department) in Principals, MERGE a Context row
    2. Update each Principal's contextId to point to its department's Context

    Uses DELETE+INSERT for the contextId update because the Principals table is temporal —
    UPDATE generates a new history row for every change. We use a single UPDATE statement
    that touches all rows in one transaction.

    Requires: $Global:FGSQLConnectionString set, IdentityAtlas module loaded.
#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory = $false)]
    [int]$SystemId
)

$ErrorActionPreference = 'Stop'

if (-not $Global:FGSQLConnectionString) {
    throw "Not connected to SQL — set `$Global:FGSQLConnectionString first."
}

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Building contexts from Principal data..." -ForegroundColor Cyan

# Phase 1: Discover unique departments per system and MERGE Context rows
$systemFilter = if ($SystemId) { "AND p.systemId = $SystemId" } else { "" }

$mergeQuery = @"
-- Disable temporal versioning briefly to avoid history bloat for context creation
ALTER TABLE dbo.Contexts SET (SYSTEM_VERSIONING = OFF);

MERGE dbo.Contexts AS target
USING (
    SELECT DISTINCT
        p.systemId,
        LTRIM(RTRIM(p.department)) AS department
    FROM dbo.Principals p
    WHERE p.department IS NOT NULL
      AND LTRIM(RTRIM(p.department)) <> ''
      $systemFilter
) AS source
ON target.systemId = source.systemId
   AND target.displayName = source.department
   AND target.contextType = 'Department'
WHEN NOT MATCHED THEN
    INSERT (id, systemId, displayName, contextType, sourceType, lastCalculatedAt)
    VALUES (NEWID(), source.systemId, source.department, 'Department', 'Calculated', SYSUTCDATETIME())
WHEN MATCHED THEN
    UPDATE SET lastCalculatedAt = SYSUTCDATETIME(), sourceType = 'Calculated';

ALTER TABLE dbo.Contexts SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.ContextsHistory));

SELECT @@ROWCOUNT AS rowsAffected;
"@

$mergeResult = Invoke-FGSQLQuery -Query $mergeQuery
Write-Host "  Created/updated contexts" -ForegroundColor Green

# Phase 2: Link Principals to their Context (single UPDATE per system)
$linkQuery = @"
UPDATE p
SET contextId = c.id
FROM dbo.Principals p
INNER JOIN dbo.Contexts c
    ON c.systemId = p.systemId
    AND c.displayName = LTRIM(RTRIM(p.department))
    AND c.contextType = 'Department'
WHERE p.department IS NOT NULL
  AND LTRIM(RTRIM(p.department)) <> ''
  AND (p.contextId IS NULL OR p.contextId <> c.id)
  $systemFilter;

SELECT @@ROWCOUNT AS rowsAffected;
"@

$linkResult = Invoke-FGSQLQuery -Query $linkQuery
Write-Host "  Linked principals to contexts" -ForegroundColor Green

# Phase 3: Update memberCount on contexts
$countQuery = @"
UPDATE c
SET memberCount = pCounts.cnt
FROM dbo.Contexts c
INNER JOIN (
    SELECT contextId, COUNT(*) AS cnt
    FROM dbo.Principals
    WHERE contextId IS NOT NULL
    GROUP BY contextId
) pCounts ON pCounts.contextId = c.id
WHERE c.contextType = 'Department';
"@

Invoke-FGSQLQuery -Query $countQuery | Out-Null
Write-Host "  Updated context member counts" -ForegroundColor Green

# Summary
$summaryQuery = @"
SELECT
    (SELECT COUNT(*) FROM dbo.Contexts WHERE contextType = 'Department') AS contextCount,
    (SELECT COUNT(*) FROM dbo.Principals WHERE contextId IS NOT NULL) AS linkedPrincipals;
"@
$summary = Invoke-FGSQLQuery -Query $summaryQuery
Write-Host "  Total: $($summary.contextCount) contexts, $($summary.linkedPrincipals) principals linked" -ForegroundColor Cyan
