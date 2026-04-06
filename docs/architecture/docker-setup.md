# Docker Setup

Running Identity Atlas locally with Docker — three containers providing the full stack.

---

## Quick Start (End Users — No Git Required)

The fastest way to try Identity Atlas — pulls pre-built images, no source code needed:

```bash
# Download the production compose file
curl -O https://raw.githubusercontent.com/Fortigi/FortigiGraph/main/docker-compose.prod.yml

# Start everything (first run: ~2 min to pull images)
docker compose -f docker-compose.prod.yml up -d

# Open the UI
open http://localhost:3001
```

On first visit, the UI auto-navigates to the **Crawlers** page with a getting-started card. Click **"Load Demo Data"** to populate the system with synthetic data (~30 seconds). After that, explore the Matrix, Users, Resources, and other pages.

To connect your own Entra ID tenant, click **"Connect Entra ID"** on the Crawlers page and enter your App Registration credentials (Tenant ID, Client ID, Client Secret).

---

## Developer Setup (From Source)

For contributors who want to build and modify the code locally.

## Architecture

```mermaid
graph TB
    subgraph Docker["docker-compose.yml"]
        SQL[(SQL Server 2022<br/>port 1433)]
        INIT[sql-init + sql-table-init<br/><i>one-shot: create DB + tables</i>]
        API[Backend + Frontend<br/>port 3001]
        WORKER[Worker<br/><i>PowerShell 7: crawlers,<br/>risk scoring, scheduling</i>]
    end

    INIT -->|creates DB + schema| SQL
    API -->|reads/writes| SQL
    WORKER -->|calls Ingest API| API
    WORKER -->|direct SQL for risk scoring| SQL

    User[Browser] -->|http://localhost:3001| API
    Dev[Developer] -->|docker exec| WORKER
```

## Services

| Service | Image | Ports | Purpose |
|---|---|---|---|
| `sql` | SQL Server 2022 | 1433 | Database with temporal tables |
| `sql-init` | SQL Server 2022 (one-shot) | — | Creates `GraphData` database |
| `sql-table-init` | PowerShell 7 (one-shot) | — | Creates all application tables, views, indexes |
| `backend` | Node.js 20 | 3001 | Ingest API + Read API + served React frontend |
| `worker` | PowerShell 7 | — | Crawlers, risk scoring, account correlation, scheduling |

After startup, 3 containers remain running: `sql`, `backend`, `worker`.

---

## Quick Start (Developer)

```powershell
cd c:\Source\GitHub\FortigiGraph

# Start the stack (first time takes ~3 min to build)
docker compose up -d --build

# Verify
docker compose ps
# Expected: sql (healthy), backend (up), worker (up)

# Open the UI — click "Load Demo Data" on the Crawlers page
Start-Process http://localhost:3001

# Open Swagger docs
Start-Process http://localhost:3001/api/docs
```

## Stopping

```powershell
# Stop (keep data)
docker compose -f docker-compose.yml down

# Stop and delete all data
docker compose -f docker-compose.yml down -v
```

---

## Auto-Bootstrap

On first startup, the backend automatically:

1. Creates a **WorkerConfig** table (key-value store for worker settings)
2. Creates a **CrawlerJobs** table (SQL-based job queue between UI and worker)
3. Creates a **Built-in Worker** crawler with a generated API key
4. Stores the API key in WorkerConfig for the worker to discover

The worker discovers the key on startup by polling WorkerConfig (retries for up to 2 minutes while the backend initializes). This means no manual crawler registration is needed — jobs submitted from the UI are automatically picked up and executed by the worker.

## Job Queue

The UI can submit crawler jobs (demo data, Entra ID sync, CSV import) via `POST /api/admin/crawler-jobs`. Jobs are stored in the `CrawlerJobs` SQL table and picked up by the worker every 30 seconds.

The `Invoke-CrawlerJob.ps1` dispatcher routes jobs to the appropriate crawler script:

| Job Type | Dispatcher target |
|---|---|
| `demo` | `Ingest-DemoDataset.ps1` (synthetic data, baked into image) |
| `entra-id` | `Start-EntraIDCrawler.ps1` (fetches from Microsoft Graph) |
| `csv` | `Start-CSVCrawler.ps1` (reads uploaded CSV files) |

Progress is updated in SQL during execution and displayed in the UI with a progress bar.

---

## Worker Container

The worker container runs PowerShell 7 with the Identity Atlas module pre-loaded. It has two responsibilities: executing scheduled cron jobs and polling the CrawlerJobs queue for UI-submitted jobs.

### Run Ad-Hoc Commands

```powershell
# Open an interactive PowerShell session in the worker
docker exec -it fortigigraph-worker-1 pwsh

# Run a one-off command
docker exec fortigigraph-worker-1 pwsh -Command "Import-Module /app/FortigiGraph.psd1; Get-Command *FG*"
```

### Configure Scheduled Jobs

Edit `setup/docker/crontab` and restart the worker:

```cron
# Risk scoring nightly at 03:00
0 3 * * * /usr/bin/pwsh -Command "Import-Module /app/FortigiGraph.psd1; Invoke-FGRiskScoring"

# CSV crawler nightly at 02:00
0 2 * * * /usr/bin/pwsh -File /app/tools/crawlers/csv/Start-CSVCrawler.ps1 -ApiBaseUrl http://backend:3001/api -ApiKey $CRAWLER_API_KEY -CsvFolder /data/csv
```

```powershell
docker compose -f docker-compose.yml restart worker
```

### Environment Variables

Create `.env` from the template for secrets:

```powershell
cp setup/config/.env.example .env
# Edit .env with your values
```

| Variable | Purpose |
|---|---|
| `SQL_PASSWORD` | SQL Server SA password |
| `CRAWLER_API_KEY` | API key for the worker's crawler |
| `GRAPH_TENANT_ID` / `CLIENT_ID` / `CLIENT_SECRET` | For EntraID crawler |
| `LLM_PROVIDER` / `LLM_API_KEY` | For risk scoring (Anthropic or OpenAI) |
| `CSV_DATA_PATH` | Host path to CSV files mounted into worker |

---

## Folder Mapping

| Host Path | Container Path | Used By |
|---|---|---|
| `app/api/src/` | `/app/backend/src/` | backend |
| `app/ui/` (built) | `/app/frontend/dist/` | backend (static) |
| `app/db/` | `/app/app/db/` | sql-table-init, worker |
| `tools/` | `/app/tools/` | worker |
| `setup/docker/crontab` | `/app/setup/docker/crontab` | worker |
| `test/datasets/DatasetLed2/` | `/data/csv/` | worker (mounted volume) |

---

## Rebuilding

After code changes:

```powershell
# Rebuild only the backend (API + UI changes)
docker compose -f docker-compose.yml up -d --build backend

# Rebuild the worker (PowerShell script changes)
docker compose -f docker-compose.yml up -d --build worker

# Rebuild everything from scratch
docker compose -f docker-compose.yml down -v
docker compose -f docker-compose.yml up -d --build
```
