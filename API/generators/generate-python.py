#!/usr/bin/env python3
"""
FortigiGraph Ingestion API - Python Client Generator

Reads API/spec/openapi.yaml and generates a complete Python package with:
  - Pydantic models for all entities (matching the OpenAPI schemas)
  - Async client class with all CRUD operations
  - OAuth2 client credentials authentication helper
  - pyproject.toml with matching version number
  - __init__.py with public exports

Usage:
    python generate-python.py
    python generate-python.py --spec ../spec/openapi.yaml --output ../generated/python
    python generate-python.py --version 2.2.20260302.1045
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path
from textwrap import dedent, indent

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is required. Install with: pip install pyyaml")
    sys.exit(1)

# ─── Helpers ──────────────────────────────────────────────────────────────────

def to_snake_case(name: str) -> str:
    """Convert camelCase or PascalCase to snake_case."""
    s1 = re.sub(r'(.)([A-Z][a-z]+)', r'\1_\2', name)
    return re.sub(r'([a-z0-9])([A-Z])', r'\1_\2', s1).lower()

def to_pascal_case(name: str) -> str:
    """Convert kebab-case, snake_case, or camelCase to PascalCase."""
    return re.sub(r'[-_](\w)', lambda m: m.group(1).upper(), name[0].upper() + name[1:])

def openapi_type_to_python(schema: dict) -> str:
    """Map OpenAPI schema type to Python type hint."""
    if not schema:
        return "Any"
    fmt = schema.get("format", "")
    t = schema.get("type", "")
    if t == "string":
        if fmt == "date-time":
            return "Optional[datetime]"
        if fmt == "uuid":
            return "Optional[str]"
        return "Optional[str]"
    if t == "integer":
        return "Optional[int]"
    if t == "number":
        return "Optional[float]"
    if t == "boolean":
        return "Optional[bool]"
    if t == "array":
        items = schema.get("items", {})
        return f"Optional[List[{openapi_type_to_python(items)}]]"
    if t == "object":
        return "Optional[Dict[str, Any]]"
    return "Optional[Any]"

def operation_id_to_method(op_id: str) -> str:
    """Convert camelCase operationId to snake_case method name."""
    return to_snake_case(op_id)

# ─── Code generators ──────────────────────────────────────────────────────────

def generate_models(schemas: dict) -> str:
    """Generate Pydantic model classes from OpenAPI schemas."""
    lines = [
        "# Auto-generated Pydantic models for FortigiGraph Ingestion API",
        "# DO NOT EDIT MANUALLY - regenerate from generate-python.py",
        "",
        "from __future__ import annotations",
        "from datetime import datetime",
        "from typing import Any, Dict, List, Optional",
        "from pydantic import BaseModel, Field",
        "",
    ]

    # Only generate models for the main entity schemas (not Batch/Paged wrappers)
    skip_patterns = ["BatchRequest", "BatchResponse", "PagedResponse", "Error"]

    for schema_name, schema in schemas.items():
        if any(p in schema_name for p in skip_patterns):
            continue
        if schema.get("type") != "object" and "properties" not in schema:
            continue

        props = schema.get("properties", {})
        required = set(schema.get("required", []))

        lines.append(f"class {schema_name}(BaseModel):")
        lines.append(f'    """Auto-generated model for {schema_name}."""')
        lines.append("")

        if not props:
            lines.append("    pass")
        else:
            for prop_name, prop_schema in props.items():
                py_type = openapi_type_to_python(prop_schema)
                field_alias = None
                description = prop_schema.get("description", "")
                default = "None"

                # Required fields have no None default
                if prop_name in required:
                    py_type = py_type.replace("Optional[", "").rstrip("]") if "Optional" in py_type else py_type
                    default_str = "..."
                else:
                    default_str = "None"

                if description:
                    field_def = f'Field({default_str}, description="{description[:80]}")'
                else:
                    field_def = f"Field({default_str})"

                lines.append(f"    {to_snake_case(prop_name)}: {py_type} = {field_def}")

            # Add model_config for alias generation if property names differ
            lines.append("")
            lines.append("    model_config = {")
            lines.append('        "populate_by_name": True,')
            lines.append('        "use_enum_values": True,')
            lines.append("    }")

        lines.append("")
        lines.append("")

    return "\n".join(lines)

def generate_client(spec: dict, version: str) -> str:
    """Generate the async API client class."""
    base_path = spec.get("servers", [{}])[0].get("url", "/api/v1/ingestion")

    methods = []
    paths = spec.get("paths", {})

    for path_key, path_item in paths.items():
        for http_method in ["get", "post", "put", "delete"]:
            operation = path_item.get(http_method)
            if not operation:
                continue

            op_id = operation.get("operationId", "")
            if not op_id:
                continue

            method_name = operation_id_to_method(op_id)
            summary = operation.get("summary", op_id)

            # Collect path and query parameters
            all_params = list(path_item.get("parameters", [])) + list(operation.get("parameters", []))
            path_params  = [p for p in all_params if p.get("in") == "path" and "$ref" not in p]
            query_params = [p for p in all_params if p.get("in") == "query" and "$ref" not in p]
            has_body = http_method in ("post", "put", "patch") and "requestBody" in operation

            # Build function signature
            sig_parts = ["self"]
            for p in path_params:
                sig_parts.append(f"{to_snake_case(p['name'])}: str")
            for p in query_params:
                py_t = openapi_type_to_python(p.get("schema", {})).replace("Optional[", "").rstrip("]")
                required_p = p.get("required", False)
                if required_p:
                    sig_parts.append(f"{to_snake_case(p['name'])}: {py_t}")
                else:
                    sig_parts.append(f"{to_snake_case(p['name'])}: Optional[{py_t}] = None")
            if has_body:
                sig_parts.append("body: Dict[str, Any]")

            sig = ", ".join(sig_parts)

            # Build path with Python f-string
            py_path = re.sub(r'\{(\w+)\}', lambda m: '{' + to_snake_case(m.group(1)) + '}', path_key)
            path_expr = f'f"{py_path}"' if "{" in py_path else f'"{py_path}"'

            # Build query dict
            query_lines = []
            if query_params:
                query_lines.append("        params = {}")
                for p in query_params:
                    snake = to_snake_case(p["name"])
                    query_lines.append(f'        if {snake} is not None: params["{p["name"]}"] = {snake}')
                query_lines.append('        kwargs["params"] = params')

            # Build request call
            req_parts = [f'"{http_method.upper()}"', path_expr]
            if has_body:
                req_parts.append("json=body")

            method_lines = [
                f"    async def {method_name}({sig}) -> Any:",
                f'        """{summary}',
                f"",
                f"        Operation: {op_id}",
                f"        {http_method.upper()} {path_key}",
                f'        """',
                f"        kwargs: Dict[str, Any] = {{}}",
            ]
            method_lines.extend(query_lines)
            method_lines.append(f"        return await self._request({', '.join(req_parts)}, **kwargs)")
            method_lines.append("")

            methods.append("\n".join(method_lines))

    client_code = dedent(f'''\
        # Auto-generated API client for FortigiGraph Ingestion API v{version}
        # DO NOT EDIT MANUALLY - regenerate from generate-python.py
        # Generated: {datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")}

        from __future__ import annotations

        import time
        from typing import Any, Dict, List, Optional

        import httpx

        BASE_PATH = "{base_path}"


        class FortigiGraphIngestionClient:
            """
            Async HTTP client for the FortigiGraph Ingestion API.

            Authentication uses Azure AD service principal (client credentials flow).

            Example::

                import asyncio
                from fortigigraph_ingestion import FortigiGraphIngestionClient

                async def main():
                    async with FortigiGraphIngestionClient(
                        base_url="https://your-api.azurewebsites.net",
                        tenant_id="your-tenant-id",
                        client_id="your-client-id",
                        client_secret="your-client-secret",
                        api_client_id="your-api-app-registration-client-id",
                    ) as client:
                        users = await client.list_users(limit=50)
                        print(users)

                asyncio.run(main())
            """

            def __init__(
                self,
                base_url: str,
                tenant_id: str,
                client_id: str,
                client_secret: str,
                api_client_id: str,
                timeout: float = 30.0,
            ):
                self.base_url = base_url.rstrip("/")
                self.tenant_id = tenant_id
                self.client_id = client_id
                self.client_secret = client_secret
                self.api_client_id = api_client_id
                self.timeout = timeout
                self._token: Optional[str] = None
                self._token_expires: float = 0.0
                self._http: Optional[httpx.AsyncClient] = None

            async def __aenter__(self) -> "FortigiGraphIngestionClient":
                self._http = httpx.AsyncClient(timeout=self.timeout)
                return self

            async def __aexit__(self, *args: Any) -> None:
                if self._http:
                    await self._http.aclose()

            async def _get_token(self) -> str:
                """Obtain or refresh the OAuth2 client credentials token."""
                if self._token and time.time() < self._token_expires - 60:
                    return self._token

                if not self._http:
                    self._http = httpx.AsyncClient(timeout=self.timeout)

                resp = await self._http.post(
                    f"https://login.microsoftonline.com/{{self.tenant_id}}/oauth2/v2.0/token",
                    data={{
                        "grant_type": "client_credentials",
                        "client_id": self.client_id,
                        "client_secret": self.client_secret,
                        "scope": f"api://{{self.api_client_id}}/.default",
                    }},
                )
                resp.raise_for_status()
                data = resp.json()
                self._token = data["access_token"]
                self._token_expires = time.time() + data.get("expires_in", 3600)
                return self._token

            async def _request(self, method: str, path: str, **kwargs: Any) -> Any:
                """Make an authenticated request to the ingestion API."""
                if not self._http:
                    self._http = httpx.AsyncClient(timeout=self.timeout)

                token = await self._get_token()
                url = f"{{self.base_url}}{base_path}{{path}}"
                headers = {{
                    "Authorization": f"Bearer {{token}}",
                    "Content-Type": "application/json",
                    **kwargs.pop("headers", {{}}),
                }}

                response = await self._http.request(method, url, headers=headers, **kwargs)

                if response.status_code == 204:
                    return None
                if not response.is_success:
                    try:
                        err = response.json()
                        raise RuntimeError(f"[{{response.status_code}}] {{err.get('message', response.text)}}")
                    except Exception:
                        raise RuntimeError(f"[{{response.status_code}}] {{response.text}}")

                return response.json()

        ''') + "\n".join(methods)

    return client_code

def generate_pyproject(version: str) -> str:
    return dedent(f'''\
        [build-system]
        requires = ["setuptools>=68", "wheel"]
        build-backend = "setuptools.backends.legacy:build"

        [project]
        name = "fortigigraph-ingestion"
        version = "{version}"
        description = "Auto-generated Python client for the FortigiGraph Ingestion API"
        readme = "README.md"
        license = {{text = "MIT"}}
        authors = [{{name = "Fortigi"}}]
        requires-python = ">=3.10"
        keywords = ["fortigigraph", "microsoft-graph", "azure-ad", "ingestion-api"]
        dependencies = [
            "httpx>=0.27.0",
            "pydantic>=2.0.0",
        ]

        [project.urls]
        Homepage = "https://github.com/Fortigi/FortigiGraph"

        [tool.setuptools.packages.find]
        where = ["."]
        include = ["fortigigraph_ingestion*"]
    ''')

def generate_init(schemas: dict, version: str) -> str:
    model_names = [
        name for name, s in schemas.items()
        if s.get("type") == "object" or "properties" in s
        if not any(p in name for p in ["BatchRequest", "BatchResponse", "PagedResponse", "Error"])
    ]
    imports = "\n".join(f"from .models import {n}" for n in model_names)
    return dedent(f'''\
        """
        FortigiGraph Ingestion API Python Client
        Version: {version}
        Auto-generated - DO NOT EDIT MANUALLY
        """

        from .client import FortigiGraphIngestionClient
        {imports}

        __version__ = "{version}"
        __all__ = [
            "FortigiGraphIngestionClient",
            {", ".join(f'"{n}"' for n in model_names)}
        ]
    ''')

# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Generate Python client from FortigiGraph OpenAPI spec")
    parser.add_argument("--spec",    default=str(Path(__file__).parent.parent / "spec" / "openapi.yaml"))
    parser.add_argument("--output",  default=str(Path(__file__).parent.parent / "generated" / "python" / "fortigigraph_ingestion"))
    parser.add_argument("--version", default="")
    args = parser.parse_args()

    spec_path = Path(args.spec)
    if not spec_path.exists():
        print(f"ERROR: Spec file not found: {spec_path}")
        sys.exit(1)

    with open(spec_path, "r", encoding="utf-8") as f:
        spec = yaml.safe_load(f)

    # Resolve version
    version = args.version
    if not version:
        pkg_json = Path(__file__).parent.parent / "package.json"
        if pkg_json.exists():
            with open(pkg_json) as f:
                version = json.load(f)["version"]
        else:
            version = spec.get("info", {}).get("version", "0.0.1")

    print(f"[generate-python] Spec: {spec_path}")
    print(f"[generate-python] Version: {version}")

    output_dir = Path(args.output)
    pkg_dir    = output_dir
    parent_dir = output_dir.parent

    # Clean and recreate
    import shutil
    if output_dir.exists():
        shutil.rmtree(output_dir)
    pkg_dir.mkdir(parents=True, exist_ok=True)

    schemas = spec.get("components", {}).get("schemas", {})

    # models.py
    models_code = generate_models(schemas)
    (pkg_dir / "models.py").write_text(models_code, encoding="utf-8")

    # client.py
    client_code = generate_client(spec, version)
    (pkg_dir / "client.py").write_text(client_code, encoding="utf-8")

    # __init__.py
    init_code = generate_init(schemas, version)
    (pkg_dir / "__init__.py").write_text(init_code, encoding="utf-8")

    # pyproject.toml (goes in parent of package)
    pyproject = generate_pyproject(version)
    (parent_dir / "pyproject.toml").write_text(pyproject, encoding="utf-8")

    # README
    readme = dedent(f"""\
        # FortigiGraph Ingestion API - Python Client

        Auto-generated Python async client for the FortigiGraph Ingestion API.

        **Version:** {version}

        ## Installation

        ```bash
        pip install fortigigraph-ingestion
        # or from source:
        pip install -e .
        ```

        ## Usage

        ```python
        import asyncio
        from fortigigraph_ingestion import FortigiGraphIngestionClient

        async def main():
            async with FortigiGraphIngestionClient(
                base_url="https://your-api.azurewebsites.net",
                tenant_id="your-tenant-id",
                client_id="your-service-principal-client-id",
                client_secret="your-service-principal-secret",
                api_client_id="your-api-app-registration-client-id",
            ) as client:
                # List users (paginated)
                users = await client.list_users(limit=100)

                # Upsert a user
                await client.upsert_user(body={{
                    "id": "00000000-0000-0000-0000-000000000001",
                    "displayName": "John Doe",
                    "userPrincipalName": "john@example.com",
                }})

                # Batch upsert groups
                await client.batch_upsert_groups(body={{
                    "records": [...],
                    "mode": "upsert",
                }})

        asyncio.run(main())
        ```

        ## Authentication

        Uses Azure AD service principal (client credentials flow).
        The token is automatically obtained and refreshed.

        Required scope: `api://{{api_client_id}}/.default`
    """)
    (parent_dir / "README.md").write_text(readme, encoding="utf-8")

    count = len([p for p in pkg_dir.rglob("*.py")])
    print(f"[generate-python] Generated {count} Python files.")
    print(f"[generate-python] Package written to: {parent_dir}")
    print(f"[generate-python] Install with: pip install -e {parent_dir}")

if __name__ == "__main__":
    main()
