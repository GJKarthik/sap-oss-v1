import os
import sys
import tempfile
from pathlib import Path

import bcrypt
import pytest
from fastapi.testclient import TestClient

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

os.environ.setdefault("JWT_SECRET_KEY", "unit-test-secret")
os.environ.setdefault("ENVIRONMENT", "test")
os.environ.setdefault(
    "STORE_DATABASE_PATH",
    str(Path(tempfile.gettempdir()) / "aifabric-webcomponents-ngx-test.sqlite3"),
)

from src.main import app
from src.models import User
from src.seed import seed_store
from src.store import AppStore, StoreBackend, get_store


@pytest.fixture()
def store() -> StoreBackend:
    backing_store = get_store()
    backing_store.clear()
    seed_store()
    yield backing_store
    backing_store.clear()


@pytest.fixture()
def client(store: StoreBackend) -> TestClient:
    with TestClient(app) as test_client:
        yield test_client


@pytest.fixture()
def admin_headers(client: TestClient) -> dict[str, str]:
    response = client.post(
        "/api/v1/auth/login",
        data={"username": "admin", "password": "changeme"},
    )
    assert response.status_code == 200
    token = response.json()["access_token"]
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture()
def viewer_headers(client: TestClient, store: StoreBackend) -> dict[str, str]:
    password = "viewer-pass"
    user = User(
        username="viewer",
        email="viewer@example.com",
        hashed_password=bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode(),
        role="viewer",
    )
    store.set_record(
        "users",
        user.username,
        {
            "id": user.id,
            "username": user.username,
            "hashed_password": user.hashed_password,
            "email": user.email,
            "role": user.role,
            "is_active": user.is_active,
            "created_at": user.created_at,
        },
    )

    response = client.post(
        "/api/v1/auth/login",
        data={"username": user.username, "password": password},
    )
    assert response.status_code == 200
    token = response.json()["access_token"]
    return {"Authorization": f"Bearer {token}"}
