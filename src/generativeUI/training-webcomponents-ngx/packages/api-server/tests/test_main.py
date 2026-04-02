"""
Tests for the Training Console API Server.
"""

import pytest
from httpx import AsyncClient, ASGITransport

# Import the app with lifespan management
from src.main import app


@pytest.fixture
async def client():
    """Async test client using the ASGI transport (no real HTTP)."""
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c


@pytest.mark.anyio
async def test_health_returns_200(client: AsyncClient):
    """GET /health returns 200 with the expected shape."""
    response = await client.get("/health")
    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "healthy"
    assert data["service"] == "training-webcomponents-ngx-api"


@pytest.mark.anyio
async def test_health_includes_mode(client: AsyncClient):
    """GET /health includes orchestration mode."""
    response = await client.get("/health")
    data = response.json()
    assert data["mode"] == "native-orchestrator"


@pytest.mark.anyio
async def test_unknown_endpoint_returns_404(client: AsyncClient):
    """Unknown routes return 404."""
    response = await client.get("/not-a-real-endpoint-xyz")
    assert response.status_code == 404


@pytest.mark.anyio
async def test_large_body_rejected(client: AsyncClient):
    """POST with body exceeding MAX_BODY_BYTES returns 413."""
    big_body = b"x" * (11 * 1024 * 1024)  # 11 MB > 10 MB limit
    response = await client.post("/jobs", content=big_body)
    assert response.status_code in (413, 422)


@pytest.mark.anyio
async def test_data_cleaning_health_native(client: AsyncClient):
    response = await client.get("/data-cleaning/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"
    assert response.json()["mode"] == "native"


@pytest.mark.anyio
async def test_data_cleaning_chat_native(client: AsyncClient):
    response = await client.post("/data-cleaning/chat", json={"message": "Find nulls"})
    assert response.status_code == 200
    assert "Generated" in response.json()["response"]


@pytest.mark.anyio
async def test_data_cleaning_workflow_native(client: AsyncClient):
    chat_response = await client.post("/data-cleaning/chat", json={"message": "Check duplicates and nulls"})
    assert chat_response.status_code == 200

    run_response = await client.post("/data-cleaning/workflow/run", json={"message": "Prepare training data"})
    assert run_response.status_code == 200
    run_id = run_response.json()["run_id"]

    for _ in range(20):
        status_response = await client.get(f"/data-cleaning/workflow/{run_id}")
        assert status_response.status_code == 200
        if status_response.json()["status"] in {"completed", "failed"}:
            break
    else:
        pytest.fail("Workflow did not reach terminal state in time")

    events_response = await client.get(f"/data-cleaning/workflow/{run_id}/events")
    assert events_response.status_code == 200
    assert len(events_response.json()["events"]) > 0
