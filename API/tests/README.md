# FortigiGraph Ingestion API – Tests

Three independent test suites, one per component.

## Running all tests

```bash
# Node.js (from API/)
npm install
npm test

# Python
pip install pytest pytest-asyncio pyyaml pydantic httpx
pytest API/tests/python/ -v

# PowerShell (requires PowerShell 7+)
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force
Install-Module powershell-yaml -Scope CurrentUser -Force
Invoke-Pester API/tests/powershell/ -Output Detailed
```

## Test layout

```
tests/
├── unit/
│   ├── auth.test.js        Node.js: auth middleware (JWT validation, roles)
│   └── helpers.test.js     Node.js: SQL type inference, error sanitization
├── integration/
│   └── api.test.js         Node.js: full HTTP routes via supertest (DB mocked)
├── python/
│   ├── test_generator.py   Python: generate-python.py output structure & syntax
│   └── test_client.py      Python: generated client token handling & HTTP routing
└── powershell/
    ├── Generator.Tests.ps1 Pester: generate-powershell.ps1 output structure & import
    └── Module.Tests.ps1    Pester: runtime behaviour of generated PS functions
```

## What is mocked

| Test suite | Mocked | Real |
|------------|--------|------|
| Node.js unit | `jsonwebtoken`, `jwks-rsa`, `db/connection` | Express middleware logic |
| Node.js integration | `db/connection` (pool + queries) | Full HTTP stack, routing |
| Python | `httpx.AsyncClient` (responses) | Token logic, method routing |
| PowerShell | `Invoke-RestMethod` | Module import, function signatures |
| Docker smoke | — | Container start, /health endpoint |

No tests require a real Azure AD tenant, SQL Server, or network access.
