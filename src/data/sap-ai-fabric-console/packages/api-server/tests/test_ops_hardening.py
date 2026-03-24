from src.config import Settings
from src.main import app
from src.routes import mcp_proxy
from src.store import get_store


def test_production_disables_api_docs_by_default() -> None:
    production_settings = Settings(
        environment="production",
        jwt_secret_key="not-the-default-secret",
    )

    assert production_settings.expose_api_docs is False


def test_security_headers_are_applied(client) -> None:
    response = client.get("/health")

    assert response.status_code == 200
    assert response.headers["x-content-type-options"] == "nosniff"
    assert response.headers["x-frame-options"] == "DENY"
    assert response.headers["referrer-policy"] == "no-referrer"
    assert response.headers["permissions-policy"] == "camera=(), microphone=(), geolocation=()"
    assert response.headers["cross-origin-resource-policy"] == "same-origin"


def test_readiness_reports_store_status(client) -> None:
    response = client.get("/ready")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ready"
    assert body["checks"]["store"] == "ok"
    assert body["checks"]["database_path"]
    assert body["checks"]["docs_exposed"] is True


def test_readiness_returns_503_when_store_is_unavailable(monkeypatch, client) -> None:
    store = get_store()
    original_count = store.count

    def broken_count(name: str) -> int:
        if name == "users":
            raise RuntimeError("database offline")
        return original_count(name)

    monkeypatch.setattr(store, "count", broken_count)

    response = client.get("/ready")

    assert response.status_code == 503
    assert response.json()["status"] == "not_ready"
    assert response.json()["checks"]["store"] == "error"
    assert "database offline" in response.json()["checks"]["error"]


def test_auth_endpoints_are_rate_limited(monkeypatch, client) -> None:
    monkeypatch.setattr("src.main.settings.auth_rate_limit_per_minute", 1)

    first_response = client.post(
        "/api/v1/auth/login",
        data={"username": "admin", "password": "changeme"},
    )
    second_response = client.post(
        "/api/v1/auth/login",
        data={"username": "admin", "password": "changeme"},
    )

    assert first_response.status_code == 200
    assert first_response.headers["x-ratelimit-limit"] == "1"
    assert second_response.status_code == 429
    assert second_response.json()["detail"] == "Too many authentication attempts"
    assert second_response.headers["retry-after"]


def test_mcp_proxy_requests_are_rate_limited(monkeypatch, client, admin_headers) -> None:
    monkeypatch.setattr("src.main.settings.mcp_rate_limit_per_minute", 1)

    async def fake_forward(target_url: str, body: dict, correlation_id: str) -> dict:
        return {"jsonrpc": "2.0", "id": body["id"], "result": {"ok": True}}

    monkeypatch.setattr(mcp_proxy, "_forward", fake_forward)

    first_response = client.post(
        "/api/v1/mcp/langchain",
        headers=admin_headers,
        json={"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}},
    )
    second_response = client.post(
        "/api/v1/mcp/langchain",
        headers=admin_headers,
        json={"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
    )

    assert first_response.status_code == 200
    assert first_response.headers["x-ratelimit-limit"] == "1"
    assert second_response.status_code == 429
    assert second_response.json()["detail"] == "Too many MCP proxy requests"


def test_root_omits_docs_link_when_docs_are_disabled(monkeypatch, client) -> None:
    monkeypatch.setattr(app, "docs_url", None)

    response = client.get("/")

    assert response.status_code == 200
    assert response.json()["docs"] is None
