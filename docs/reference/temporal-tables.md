# Temporal Tables & Historical Queries

FortigiGraph uses SQL Server **system-versioned temporal tables** on all core tables. Every insert, update, and delete is automatically versioned, giving you a complete, tamper-evident history of every identity and permission change — with no extra code.

---

## What Are Temporal Tables

A SQL Server temporal table maintains two tables under the hood:

- The **current table** — contains only the current state of each row
- The **history table** (auto-created, named `<Table>History`) — contains every previous version of each row

Each row has two system-managed columns:

| Column | Type | Meaning |
|--------|------|---------|
| `ValidFrom` | `datetime2` | When this version became current |
| `ValidTo` | `datetime2` | When this version was superseded (`9999-12-31...` means still current) |

SQL Server manages these columns automatically. You never write to them directly.

### Tables with temporal versioning

| Table | Versioned |
|-------|-----------|
| `Resources` | Yes |
| `Principals` | Yes |
| `ResourceAssignments` | Yes |
| `ResourceRelationships` | Yes |
| `Contexts` | Yes |
| `Identities` | Yes |
| `IdentityMembers` | Yes |
| `RiskScores` | Yes |
| `GovernanceCatalogs` | Yes |
| `AssignmentPolicies` | Yes |
| `AssignmentRequests` | Yes |
| `CertificationDecisions` | Yes |
| `PrincipalActivity` | **No** — upsert-based; daily sign-in timestamps would generate excessive version noise |

---

## Query Patterns

### Current state (no change needed)

Standard queries work as usual on temporal tables — they always return the current state:

```sql
SELECT id, displayName, department, jobTitle
FROM Principals
WHERE department = 'Finance';
```

### Point-in-time query

Query what the data looked like at any specific moment in the past:

```sql
-- Who had access to this resource on January 15, 2025 at 10:00 UTC?
SELECT principalId, assignmentType, ValidFrom
FROM ResourceAssignments
FOR SYSTEM_TIME AS OF '2025-01-15 10:00:00'
WHERE resourceId = 'your-resource-guid';

-- What did a principal's profile look like six months ago?
SELECT displayName, email, department, jobTitle, ValidFrom
FROM Principals
FOR SYSTEM_TIME AS OF '2025-09-01 00:00:00'
WHERE id = 'principal-guid-here';
```

### Full version history for a row

```sql
-- All versions of a principal's record, newest first
SELECT email, department, jobTitle, ValidFrom, ValidTo
FROM Principals FOR SYSTEM_TIME ALL
WHERE email = 'john.doe@contoso.com'
ORDER BY ValidFrom DESC;

-- All assignment changes for a specific resource
SELECT principalId, assignmentType, ValidFrom, ValidTo
FROM ResourceAssignments FOR SYSTEM_TIME ALL
WHERE resourceId = 'your-resource-guid'
ORDER BY ValidFrom DESC;
```

### Changes within a time range

```sql
-- All assignment changes in the last 30 days
SELECT resourceId, principalId, assignmentType, ValidFrom, ValidTo
FROM ResourceAssignments FOR SYSTEM_TIME ALL
WHERE ValidFrom >= DATEADD(DAY, -30, GETDATE())
ORDER BY ValidFrom DESC;

-- Principals whose department changed this quarter
SELECT id, email, department, ValidFrom, ValidTo
FROM Principals FOR SYSTEM_TIME ALL
WHERE ValidFrom >= '2025-01-01'
  AND ValidTo   <= '2025-03-31'
ORDER BY ValidFrom DESC;
```

### Rows that existed in a range but may no longer exist

`FOR SYSTEM_TIME BETWEEN` returns rows that were active at any point during the range:

```sql
-- All access package assignments that were active during Q1 2025
SELECT resourceId, principalId, assignmentType, ValidFrom, ValidTo
FROM ResourceAssignments
FOR SYSTEM_TIME BETWEEN '2025-01-01' AND '2025-03-31'
WHERE assignmentType = 'Governed';
```

### Rows that have since been deleted

```sql
-- Resources that existed at some point but no longer exist
SELECT id, displayName, resourceType, ValidFrom, ValidTo
FROM Resources FOR SYSTEM_TIME ALL
WHERE ValidTo < '9999-12-31'
ORDER BY ValidTo DESC;
```

### Comparing two points in time (access drift)

```sql
-- Permissions held on Jan 1 but NOT on Jul 1 (access that was removed)
SELECT r.principalId, r.resourceId, r.assignmentType
FROM ResourceAssignments FOR SYSTEM_TIME AS OF '2025-01-01' r
WHERE NOT EXISTS (
    SELECT 1 FROM ResourceAssignments FOR SYSTEM_TIME AS OF '2025-07-01' c
    WHERE c.principalId = r.principalId
      AND c.resourceId  = r.resourceId
      AND c.assignmentType = r.assignmentType
);

-- Permissions on Jul 1 that did NOT exist on Jan 1 (new access granted)
SELECT c.principalId, c.resourceId, c.assignmentType
FROM ResourceAssignments FOR SYSTEM_TIME AS OF '2025-07-01' c
WHERE NOT EXISTS (
    SELECT 1 FROM ResourceAssignments FOR SYSTEM_TIME AS OF '2025-01-01' r
    WHERE r.principalId = c.principalId
      AND r.resourceId  = c.resourceId
      AND r.assignmentType = c.assignmentType
);
```

---

## Important Constraints

### No TRUNCATE on temporal tables

SQL Server does not permit `TRUNCATE` on system-versioned temporal tables. Always use `DELETE` or the FortigiGraph helper:

```powershell
# Safe: uses DELETE internally, handles versioning state automatically
Clear-FGSQLTable -TableName "ResourceAssignments"
```

```sql
-- Safe: standard DELETE
DELETE FROM ResourceAssignments;

-- Not allowed on temporal tables:
-- TRUNCATE TABLE ResourceAssignments;  ← will error
```

### Schema changes require disabling versioning

SQL Server does not allow adding, altering, or dropping columns on a temporal table while versioning is active. FortigiGraph handles this automatically when you use `Sync-FGPrincipal -AdditionalAttributes` or any function that evolves the schema:

1. Versioning is disabled (history table detached)
2. Column is added
3. Versioning is re-enabled (history table re-attached)

You should never need to do this manually, but if you do:

```sql
-- Disable versioning
ALTER TABLE Principals SET (SYSTEM_VERSIONING = OFF);

-- Make schema changes
ALTER TABLE Principals ADD myNewColumn NVARCHAR(200);
ALTER TABLE PrincipalsHistory ADD myNewColumn NVARCHAR(200);

-- Re-enable versioning
ALTER TABLE Principals SET (
    SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.PrincipalsHistory)
);
```

!!! warning
    When you add a column to the main table, you **must** add the same column to the history table before re-enabling versioning. FortigiGraph does this automatically. If you are altering tables manually, always update both.

### History table is read-only

The `*History` tables (e.g. `PrincipalsHistory`, `ResourceAssignmentsHistory`) are managed exclusively by SQL Server. You cannot insert, update, or delete rows in them directly.

### PrincipalActivity is not temporal

`PrincipalActivity` uses an upsert (MERGE) pattern rather than temporal versioning. Sign-in timestamps change daily for active users; recording every change would bloat the history table with low-value versions. For historical queries about when a principal was last active, compare timestamps across `PrincipalActivity` snapshots taken at different sync dates.

---

## Retention

By default, history is retained indefinitely. SQL Server supports a `HISTORY_RETENTION_PERIOD` if you want to cap storage:

```sql
-- Keep 2 years of history on Principals
ALTER TABLE Principals SET (
    SYSTEM_VERSIONING = ON (
        HISTORY_TABLE = dbo.PrincipalsHistory,
        HISTORY_RETENTION_PERIOD = 2 YEARS
    )
);
```

!!! note
    Retention cleanup runs during a SQL Server background task, not immediately. Rows older than the retention period may persist for a short time after the threshold passes.
