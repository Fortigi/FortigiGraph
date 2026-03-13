"""
Unit tests for the generated Python client class behaviour.

We generate the client from the real spec into a temporary directory,
dynamically import it, and test:
  - Token acquisition and caching
  - Auto-renewal when token is near-expiry
  - HTTP method routing (GET / POST / PUT / DELETE)
  - Error propagation from non-2xx responses
  - 204 No Content returns None
  - Context manager lifecycle

httpx calls are intercepted with httpx.MockTransport so no network is used.
"""

import importlib
import json
import subprocess
import sys
import time
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

REPO_ROOT = Path(__file__).parents[3]
GENERATOR = REPO_ROOT / "API" / "generators" / "generate-python.py"
SPEC_PATH = REPO_ROOT / "API" / "spec" / "openapi.yaml"


# ── Fixtures ───────────────────────────────────────────────────────────────────

@pytest.fixture(scope="module")
def client_module(tmp_path_factory):
    """Generate the Python package from the real spec and return the imported module."""
    if not SPEC_PATH.exists():
        pytest.skip("openapi.yaml not found")

    out_dir = tmp_path_factory.mktemp("client") / "fortigigraph_ingestion"
    result  = subprocess.run(
        [sys.executable, str(GENERATOR), "--spec", str(SPEC_PATH), "--output", str(out_dir)],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, f"Generator failed:\n{result.stderr}"

    # Dynamically import the generated package
    spec = importlib.util.spec_from_file_location(
        "fortigigraph_ingestion",
        out_dir / "__init__.py",
        submodule_search_locations=[str(out_dir)],
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture
def client_class(client_module):
    return client_module.FortigiGraphIngestionClient


def make_client(client_class, **kwargs):
    defaults = dict(
        base_url="http://localhost:3001",
        tenant_id="test-tenant",
        client_id="test-client",
        client_secret="test-secret",
        api_client_id="test-api-client",
    )
    return client_class(**{**defaults, **kwargs})


# ── Token acquisition ──────────────────────────────────────────────────────────

class TestTokenAcquisition:
    @pytest.mark.asyncio
    async def test_get_token_calls_azure_ad(self, client_class):
        client = make_client(client_class)

        fake_response = MagicMock()
        fake_response.raise_for_status = MagicMock()
        fake_response.json.return_value = {"access_token": "tok123", "expires_in": 3600}

        mock_http = AsyncMock()
        mock_http.post.return_value = fake_response
        client._http = mock_http

        token = await client._get_token()
        assert token == "tok123"
        mock_http.post.assert_called_once()
        call_kwargs = mock_http.post.call_args
        assert "oauth2/v2.0/token" in call_kwargs[0][0]

    @pytest.mark.asyncio
    async def test_token_is_cached(self, client_class):
        client = make_client(client_class)
        client._token         = "cached-token"
        client._token_expires = time.time() + 3600  # valid for another hour

        mock_http = AsyncMock()
        client._http = mock_http

        token = await client._get_token()
        assert token == "cached-token"
        mock_http.post.assert_not_called()

    @pytest.mark.asyncio
    async def test_token_refreshed_when_near_expiry(self, client_class):
        client = make_client(client_class)
        client._token         = "old-token"
        client._token_expires = time.time() + 30   # expires in 30s → refresh

        fake_response = MagicMock()
        fake_response.raise_for_status = MagicMock()
        fake_response.json.return_value = {"access_token": "new-token", "expires_in": 3600}

        mock_http = AsyncMock()
        mock_http.post.return_value = fake_response
        client._http = mock_http

        token = await client._get_token()
        assert token == "new-token"
        mock_http.post.assert_called_once()


# ── HTTP request routing ───────────────────────────────────────────────────────

class TestRequestRouting:
    @pytest.mark.asyncio
    async def test_get_request_uses_correct_url(self, client_class):
        client = make_client(client_class)
        client._token         = "tok"
        client._token_expires = time.time() + 3600

        fake_response = MagicMock()
        fake_response.is_success = True
        fake_response.status_code = 200
        fake_response.json.return_value = {"data": [], "total": 0}

        mock_http = AsyncMock()
        mock_http.request.return_value = fake_response
        client._http = mock_http

        result = await client._request("GET", "/users")

        mock_http.request.assert_called_once()
        call_args = mock_http.request.call_args
        assert call_args[0][0] == "GET"
        assert "/api/v1/ingestion/users" in call_args[0][1]
        assert result == {"data": [], "total": 0}

    @pytest.mark.asyncio
    async def test_204_returns_none(self, client_class):
        client = make_client(client_class)
        client._token         = "tok"
        client._token_expires = time.time() + 3600

        fake_response = MagicMock()
        fake_response.is_success = True
        fake_response.status_code = 204

        mock_http = AsyncMock()
        mock_http.request.return_value = fake_response
        client._http = mock_http

        result = await client._request("DELETE", "/users/some-id")
        assert result is None

    @pytest.mark.asyncio
    async def test_error_response_raises_runtime_error(self, client_class):
        client = make_client(client_class)
        client._token         = "tok"
        client._token_expires = time.time() + 3600

        fake_response = MagicMock()
        fake_response.is_success = False
        fake_response.status_code = 404
        fake_response.json.return_value = {"code": "NOT_FOUND", "message": "Resource not found"}
        fake_response.text = '{"code": "NOT_FOUND", "message": "Resource not found"}'

        mock_http = AsyncMock()
        mock_http.request.return_value = fake_response
        client._http = mock_http

        with pytest.raises(RuntimeError, match="404"):
            await client._request("GET", "/users/missing-id")

    @pytest.mark.asyncio
    async def test_bearer_token_in_authorization_header(self, client_class):
        client = make_client(client_class)
        client._token         = "my-bearer-token"
        client._token_expires = time.time() + 3600

        fake_response = MagicMock()
        fake_response.is_success = True
        fake_response.status_code = 200
        fake_response.json.return_value = {}

        mock_http = AsyncMock()
        mock_http.request.return_value = fake_response
        client._http = mock_http

        await client._request("GET", "/test")

        call_kwargs = mock_http.request.call_args[1]
        assert call_kwargs["headers"]["Authorization"] == "Bearer my-bearer-token"


# ── Context manager ───────────────────────────────────────────────────────────

class TestContextManager:
    @pytest.mark.asyncio
    async def test_context_manager_enters_and_exits(self, client_class):
        client = make_client(client_class)

        async with client as c:
            assert c._http is not None

    @pytest.mark.asyncio
    async def test_context_manager_closes_http_client(self, client_class):
        client = make_client(client_class)

        mock_http = AsyncMock()
        async with client as c:
            c._http = mock_http

        mock_http.aclose.assert_called_once()


# ── Generated methods exist ───────────────────────────────────────────────────

class TestGeneratedMethodsExist:
    """Smoke-test that the generator produced methods for all expected entity operations."""

    EXPECTED_METHODS = [
        "list_users",
        "get_user",
        "upsert_user",
        "update_user",
        "delete_user",
        "batch_upsert_users",
        "list_groups",
        "get_group",
        "upsert_group",
        "list_group_members",
        "add_group_member",
        "batch_upsert_group_members",
        "remove_group_member",
        "list_catalogs",
        "get_catalog",
        "list_access_packages",
        "list_access_package_assignments",
        "list_access_package_access_reviews",
    ]

    def test_all_expected_methods_exist(self, client_class):
        missing = [m for m in self.EXPECTED_METHODS if not hasattr(client_class, m)]
        assert missing == [], f"Missing methods: {missing}"
