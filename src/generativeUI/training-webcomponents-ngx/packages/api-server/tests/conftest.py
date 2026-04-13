"""Shared pytest configuration for the api-server tests."""
import os
import tempfile
from pathlib import Path

import pytest

TEST_DATABASE_DIR = Path(tempfile.mkdtemp(prefix="api-server-tests-"))
os.environ.setdefault("DATABASE_URL", f"sqlite:///{TEST_DATABASE_DIR / 'enterprise_mlops.db'}")

from src.database import Base, engine


def pytest_configure(config):
    config.addinivalue_line("markers", "anyio: mark test as async (anyio backend)")


@pytest.fixture(autouse=True)
def ensure_database_schema():
    Base.metadata.create_all(bind=engine)
    yield


@pytest.fixture
def anyio_backend():
    return "asyncio"
