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
    assert data["service"] == "training-console-api"


@pytest.mark.anyio
async def test_health_includes_upstream(client: AsyncClient):
    """GET /health includes the upstream URL in the response."""
    response = await client.get("/health")
    data = response.json()
    assert "upstream" in data


@pytest.mark.anyio
async def test_proxy_returns_502_when_upstream_down(client: AsyncClient):
    """Proxy routes return 502 when the upstream is unreachable."""
    response = await client.get("/not-a-real-endpoint-xyz")
    # Upstream is not running in tests — expect 502 or a connection error mapped to 502
    assert response.status_code in (502, 503)


@pytest.mark.anyio
async def test_large_body_rejected(client: AsyncClient):
    """POST with body exceeding MAX_BODY_BYTES returns 413."""
    big_body = b"x" * (11 * 1024 * 1024)  # 11 MB > 10 MB limit
    response = await client.post("/jobs", content=big_body)
    assert response.status_code == 413
