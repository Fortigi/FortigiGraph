"""
pytest configuration for FortigiGraph Ingestion API Python tests.
"""
import pytest


def pytest_configure(config):
    """Register asyncio mode so async tests work with pytest-asyncio."""
    config.addinivalue_line("markers", "asyncio: mark test as async")
