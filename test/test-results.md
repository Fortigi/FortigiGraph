# Identity Atlas — Docker Test Results

**Date:** 2026-04-03 14:41:46
**Duration:** 19 seconds
**Results:** 87 passed, 0 failed, 0 skipped (87 total)

---

## Infrastructure

| Test | Status | Detail |
|---|---|---|
| SQL Server container running | PASS |  |
| Backend container running | PASS |  |
| Worker container running | PASS |  |
| Table init completed (exit 0) | PASS | Exited (0) 15 seconds ago |

## API

| Test | Status | Detail |
|---|---|---|
| GET /api/health returns ok | PASS |  |
| GET /api/version responds | PASS |  |
| GET /api/features responds | PASS |  |
| GET /api/auth-config responds | PASS | enabled=False |
| Swagger UI loads (200) | PASS |  |
| OpenAPI spec valid | PASS | openapi=3.0.3 |
| OpenAPI title is Identity Atlas | PASS | Identity Atlas Ingest API |
| Frontend HTML loads (200) | PASS |  |
| Frontend title is Identity Atlas | PASS |  |
| GET /api/systems responds | PASS |  |
| GET /api/resources responds | PASS |  |

## CrawlerAuth

| Test | Status | Detail |
|---|---|---|
| Register crawler returns key | PASS | prefix=fgc_d8db |
| Whoami returns crawler name | PASS |  |
| Invalid key returns 401 | PASS | status=401 |
| No auth returns 401 | PASS | status=401 |
| Key rotation returns new key | PASS |  |
| Old key rejected after rotation | PASS |  |
| New key works after rotation | PASS |  |
| Admin list returns crawlers | PASS | count=1 |

## DemoDataset

| Test | Status | Detail |
|---|---|---|
| Generate dataset | PASS |  |
| Ingest dataset via API | PASS |  |

## Schema

| Test | Status | Detail |
|---|---|---|
| Table exists: Systems | PASS |  |
| Table exists: Resources | PASS |  |
| Table exists: Principals | PASS |  |
| Table exists: ResourceAssignments | PASS |  |
| Table exists: ResourceRelationships | PASS |  |
| Table exists: Identities | PASS |  |
| Table exists: IdentityMembers | PASS |  |
| Table exists: Contexts | PASS |  |
| Table exists: GovernanceCatalogs | PASS |  |
| Table exists: AssignmentPolicies | PASS |  |
| Table exists: AssignmentRequests | PASS |  |
| Table exists: CertificationDecisions | PASS |  |
| Table exists: Crawlers | PASS |  |
| Table exists: CrawlerAuditLog | PASS |  |

## DataCounts

| Test | Status | Detail |
|---|---|---|
| Contexts >= 3 rows | PASS | actual=8 |
| GovernanceCatalogs >= 1 rows | PASS | actual=2 |
| Identities >= 5 rows | PASS | actual=23 |
| Principals >= 5 rows | PASS | actual=28 |
| ResourceAssignments >= 10 rows | PASS | actual=73 |
| ResourceRelationships >= 5 rows | PASS | actual=9 |
| Resources >= 5 rows | PASS | actual=14 |
| Systems >= 1 rows | PASS | actual=3 |

## Integrity

| Test | Status | Detail |
|---|---|---|
| Assignments -> Resources (no orphans) | PASS | orphans=0 |
| Assignments -> Principals (no orphans) | PASS | orphans=0 |

## BusinessLogic

| Test | Status | Detail |
|---|---|---|
| Has User principals | PASS | count=24 |
| Has ServicePrincipal | PASS | count=1 |
| Has AIAgent | PASS | count=1 |
| Has BusinessRole resources | PASS | count=4 |
| Has EntraGroup resources | PASS | count=6 |
| Has Governed assignments | PASS | count=31 |
| Has Owner assignments | PASS | count=1 |
| Has root context (no parent) | PASS | count=2 |
| Has child contexts (with parent) | PASS | count=6 |
| Has governance catalogs | PASS | count=2 |
| Has assignment policies | PASS | count=3 |
| Crawler audit log has entries | PASS | count=14 |

## APIData

| Test | Status | Detail |
|---|---|---|
| Resources endpoint returns data | PASS | count=10 |
| Systems endpoint returns data | PASS | count=3 |

## MatrixAPI

| Test | Status | Detail |
|---|---|---|
| Matrix returns user rows | PASS | users=51 |
| Matrix rows have resource assignments | PASS |  |
| Create resource tag | PASS | tagId=1 |
| Assign tag to resource | PASS |  |
| Tag filter returns tagged resources | PASS | count=10 |
| Matrix group tag filter reduces results | PASS | users=51 |
| Delete tag cleanup | PASS |  |

## Worker

| Test | Status | Detail |
|---|---|---|
| Module loaded successfully | PASS |  |
| Shows Identity Atlas branding | PASS |  |

## Module

| Test | Status | Detail |
|---|---|---|
| Module loads without errors | PASS |  |
| Functions loaded (>50) | PASS | count=258 |
| Function exists: Initialize-FGSystemTables | PASS |  |
| Function exists: Initialize-FGGovernanceTables | PASS |  |
| Function exists: Initialize-FGCrawlerTables | PASS |  |
| Function exists: Invoke-FGGetRequest | PASS |  |
| Function exists: Get-FGAccessToken | PASS |  |
| Function exists: Invoke-FGSQLCommand | PASS |  |
| Function exists: Connect-FGSQLServer | PASS |  |
| Function exists: New-FGRiskProfile | PASS |  |
| Function exists: Invoke-FGRiskScoring | PASS |  |
| Deleted function removed: Start-FGSync | PASS |  |
| Deleted function removed: Start-FGCSVSync | PASS |  |
| Deleted function removed: Sync-FGPrincipal | PASS |  |
| Deleted function removed: Sync-FGGroup | PASS |  |

---

## Summary

| Metric | Value |
|---|---|
| Total tests | 87 |
| Passed | 87 |
| Failed | 0 |
| Skipped | 0 |
| Duration | 19s |
| Docker containers | 3 (sql, backend, worker) |
| Date | 2026-04-03 14:41 |
