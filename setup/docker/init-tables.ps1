<#
.SYNOPSIS
    DEPRECATED in v5. Schema is created by the postgres migrations runner.

.DESCRIPTION
    In v4 this script was invoked by the `sql-table-init` docker compose
    service to create all SQL Server tables. In v5 the schema lives in
    `app/api/src/db/migrations/*.sql` and is applied automatically by the
    web container at startup. The `sql-table-init` service was removed from
    docker-compose.yml. This file remains as a stub.
#>

Write-Host 'init-tables.ps1 is a no-op in v5 — postgres schema is applied by the migrations runner inside the web container.' -ForegroundColor Yellow
exit 0
