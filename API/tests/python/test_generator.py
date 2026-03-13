"""
Tests for API/generators/generate-python.py

Verifies that the generator:
  - Produces valid Python files for a minimal OpenAPI spec
  - Generates correct Pydantic models from schema definitions
  - Generates a client method for every operationId in the spec
  - Creates pyproject.toml with the correct version
  - Generates a working __init__.py that exports the client and models
"""

import importlib.util
import json
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

# ── Paths ─────────────────────────────────────────────────────────────────────

REPO_ROOT  = Path(__file__).parents[3]
GENERATOR  = REPO_ROOT / "API" / "generators" / "generate-python.py"
SPEC_PATH  = REPO_ROOT / "API" / "spec" / "openapi.yaml"
PKG_JSON   = REPO_ROOT / "API" / "package.json"


# ── Fixtures ──────────────────────────────────────────────────────────────────

MINIMAL_SPEC = textwrap.dedent("""\
    openapi: 3.0.3
    info:
      title: Test API
      version: "1.2.3"
    servers:
      - url: /api/v1/ingestion
    paths:
      /widgets:
        get:
          operationId: listWidgets
          summary: List widgets
          parameters:
            - name: $page
              in: query
              schema:
                type: integer
          responses:
            "200":
              description: ok
        post:
          operationId: upsertWidget
          summary: Upsert a widget
          requestBody:
            required: true
            content:
              application/json:
                schema:
                  $ref: "#/components/schemas/Widget"
          responses:
            "200":
              description: ok
      /widgets/{id}:
        get:
          operationId: getWidget
          summary: Get widget by id
          parameters:
            - name: id
              in: path
              required: true
              schema:
                type: string
                format: uuid
          responses:
            "200":
              description: ok
        delete:
          operationId: deleteWidget
          summary: Delete widget
          parameters:
            - name: id
              in: path
              required: true
              schema:
                type: string
          responses:
            "204":
              description: deleted
    components:
      schemas:
        Widget:
          type: object
          required: [id]
          properties:
            id:
              type: string
              format: uuid
            name:
              type: string
            count:
              type: integer
            active:
              type: boolean
            createdAt:
              type: string
              format: date-time
""")


@pytest.fixture(scope="module")
def generated_dir(tmp_path_factory):
    """Run the generator against a minimal spec and return the output dir."""
    tmp   = tmp_path_factory.mktemp("gen")
    spec  = tmp / "openapi.yaml"
    spec.write_text(MINIMAL_SPEC)

    pkg_json = tmp / "package.json"
    pkg_json.write_text(json.dumps({"version": "9.8.7"}))

    out_dir = tmp / "fortigigraph_ingestion"

    result = subprocess.run(
        [
            sys.executable,
            str(GENERATOR),
            "--spec",    str(spec),
            "--output",  str(out_dir),
            "--version", "9.8.7",
        ],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, f"Generator failed:\n{result.stderr}"
    return out_dir


# ── Generator output structure ────────────────────────────────────────────────

class TestGeneratorOutputStructure:
    def test_creates_models_py(self, generated_dir):
        assert (generated_dir / "models.py").exists()

    def test_creates_client_py(self, generated_dir):
        assert (generated_dir / "client.py").exists()

    def test_creates_init_py(self, generated_dir):
        assert (generated_dir / "__init__.py").exists()

    def test_creates_pyproject_toml(self, generated_dir):
        assert (generated_dir.parent / "pyproject.toml").exists()

    def test_pyproject_has_correct_version(self, generated_dir):
        content = (generated_dir.parent / "pyproject.toml").read_text()
        assert 'version = "9.8.7"' in content


# ── Generated models ──────────────────────────────────────────────────────────

class TestGeneratedModels:
    def test_widget_model_exists(self, generated_dir):
        content = (generated_dir / "models.py").read_text()
        assert "class Widget(BaseModel):" in content

    def test_widget_model_has_id_field(self, generated_dir):
        content = (generated_dir / "models.py").read_text()
        # id is required so no Optional wrapper
        assert "id" in content

    def test_widget_model_has_optional_name(self, generated_dir):
        content = (generated_dir / "models.py").read_text()
        assert "Optional[str]" in content   # name is optional

    def test_widget_model_has_optional_int_for_count(self, generated_dir):
        content = (generated_dir / "models.py").read_text()
        assert "Optional[int]" in content

    def test_widget_model_has_optional_bool_for_active(self, generated_dir):
        content = (generated_dir / "models.py").read_text()
        assert "Optional[bool]" in content

    def test_widget_model_has_datetime_for_created_at(self, generated_dir):
        content = (generated_dir / "models.py").read_text()
        assert "Optional[datetime]" in content

    def test_models_file_is_valid_python(self, generated_dir):
        code = (generated_dir / "models.py").read_text()
        compile(code, "models.py", "exec")   # raises SyntaxError if invalid


# ── Generated client ──────────────────────────────────────────────────────────

class TestGeneratedClient:
    def test_client_class_exists(self, generated_dir):
        content = (generated_dir / "client.py").read_text()
        assert "class FortigiGraphIngestionClient:" in content

    def test_list_widgets_method_exists(self, generated_dir):
        content = (generated_dir / "client.py").read_text()
        assert "async def list_widgets(" in content

    def test_upsert_widget_method_exists(self, generated_dir):
        content = (generated_dir / "client.py").read_text()
        assert "async def upsert_widget(" in content

    def test_get_widget_method_exists(self, generated_dir):
        content = (generated_dir / "client.py").read_text()
        assert "async def get_widget(" in content

    def test_delete_widget_method_exists(self, generated_dir):
        content = (generated_dir / "client.py").read_text()
        assert "async def delete_widget(" in content

    def test_client_file_is_valid_python(self, generated_dir):
        code = (generated_dir / "client.py").read_text()
        compile(code, "client.py", "exec")

    def test_client_has_token_refresh_logic(self, generated_dir):
        content = (generated_dir / "client.py").read_text()
        assert "_get_token" in content
        assert "oauth2/v2.0/token" in content

    def test_client_supports_context_manager(self, generated_dir):
        content = (generated_dir / "client.py").read_text()
        assert "__aenter__" in content
        assert "__aexit__" in content


# ── Generated __init__.py ─────────────────────────────────────────────────────

class TestGeneratedInit:
    def test_exports_client(self, generated_dir):
        content = (generated_dir / "__init__.py").read_text()
        assert "FortigiGraphIngestionClient" in content

    def test_exports_widget_model(self, generated_dir):
        content = (generated_dir / "__init__.py").read_text()
        assert "Widget" in content

    def test_has_version_variable(self, generated_dir):
        content = (generated_dir / "__init__.py").read_text()
        assert '__version__ = "9.8.7"' in content


# ── Against real spec ──────────────────────────────────────────────────────────

class TestAgainstRealSpec:
    """Smoke-tests the generator against the actual openapi.yaml in the repo."""

    @pytest.mark.skipif(not SPEC_PATH.exists(), reason="openapi.yaml not found")
    def test_generator_succeeds_on_real_spec(self, tmp_path):
        out_dir = tmp_path / "fortigigraph_ingestion"
        result  = subprocess.run(
            [sys.executable, str(GENERATOR), "--spec", str(SPEC_PATH), "--output", str(out_dir)],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, f"Generator failed:\n{result.stderr}"
        assert (out_dir / "client.py").exists()
        assert (out_dir / "models.py").exists()

    @pytest.mark.skipif(not SPEC_PATH.exists(), reason="openapi.yaml not found")
    def test_real_client_is_valid_python(self, tmp_path):
        out_dir = tmp_path / "fortigigraph_ingestion"
        subprocess.run(
            [sys.executable, str(GENERATOR), "--spec", str(SPEC_PATH), "--output", str(out_dir)],
            capture_output=True, check=True,
        )
        for py_file in out_dir.glob("*.py"):
            code = py_file.read_text()
            compile(code, str(py_file), "exec")

    @pytest.mark.skipif(not PKG_JSON.exists(), reason="package.json not found")
    def test_version_matches_package_json(self, tmp_path):
        expected_version = json.loads(PKG_JSON.read_text())["version"]
        out_dir = tmp_path / "fortigigraph_ingestion"
        subprocess.run(
            [sys.executable, str(GENERATOR), "--spec", str(SPEC_PATH), "--output", str(out_dir)],
            capture_output=True, check=True,
        )
        init_content = (out_dir / "__init__.py").read_text()
        assert f'__version__ = "{expected_version}"' in init_content
