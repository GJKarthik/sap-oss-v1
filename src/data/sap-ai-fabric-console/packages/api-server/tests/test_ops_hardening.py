from src.config import Settings
from src.main import app
from src.routes import auth, mcp_proxy
from src.store import get_store


def _production_settings_kwargs(**overrides):
    values = {
        "environment": "production",
        "jwt_secret_key": "not-the-default-secret",
        "store_backend": "hana",
        "hana_host": "hana.example.test",
        "hana_user": "DBADMIN",
        "hana_password": "super-secret-password",
        "langchain_mcp_url": "https://langchain.example.test/mcp",
        "streaming_mcp_url": "https://streaming.example.test/mcp",
        "data_cleaning_mcp_url": "https://cleaning.example.test/mcp",
    }
    values.update(overrides)
    return values


def test_production_disables_api_docs_by_default() -> None:
    production_settings = Settings(**_production_settings_kwargs())

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
    monkeypatch.setattr(
        store,
        "health_snapshot",
        lambda: (_ for _ in ()).throw(RuntimeError("database offline")),
    )

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


def test_readiness_returns_503_when_required_mcp_dependency_is_unavailable(monkeypatch, client) -> None:
    async def fake_probe(service_name: str, target_url: str, timeout_seconds: float = 5.0) -> dict:
        if service_name == "langchain-hana-mcp":
            return {"status": "error", "service": service_name, "target": target_url, "error": "offline"}
        return {"status": "ok", "service": service_name, "target": target_url}

    monkeypatch.setattr("src.main.settings.require_mcp_dependencies", True)
    monkeypatch.setattr("src.main.mcp_proxy.probe_health", fake_probe)

    response = client.get("/ready")

    assert response.status_code == 503
    body = response.json()
    assert body["status"] == "not_ready"
    assert body["failed_dependencies"] == ["langchain_mcp"]
    assert body["checks"]["langchain_mcp"]["status"] == "error"


def test_operations_dashboard_reports_auth_and_alert_state(monkeypatch, client, admin_headers) -> None:
    monkeypatch.setattr("src.routes.metrics.settings.auth_failure_alert_threshold", 1)
    monkeypatch.setattr("src.routes.metrics.settings.mcp_failure_alert_threshold", 1)
    monkeypatch.setattr("src.routes.metrics.settings.require_mcp_dependencies", True)

    async def fake_probe(service_name: str, target_url: str, timeout_seconds: float = 5.0) -> dict:
        if service_name == "langchain-hana-mcp":
            return {"status": "error", "service": service_name, "target": target_url, "error": "offline"}
        return {"status": "healthy", "service": service_name, "target": target_url}

    monkeypatch.setattr("src.routes.metrics.probe_health", fake_probe)
    auth._record_auth_event("login", "failure")

    client.get("/health")
    response = client.get("/api/v1/metrics/operations", headers=admin_headers)

    assert response.status_code == 200
    body = response.json()
    assert body["api"]["requests_total"] >= 1
    assert body["auth"]["recent_failures"] >= 1
    assert body["store"]["store"] == "ok"
    alert_states = {alert["name"]: alert["active"] for alert in body["alerts"]}
    assert alert_states["auth_failure_spike"] is True
    assert alert_states["readiness_degradation"] is True


def test_root_omits_docs_link_when_docs_are_disabled(monkeypatch, client) -> None:
    monkeypatch.setattr(app, "docs_url", None)

    response = client.get("/")

    assert response.status_code == 200
    assert response.json()["docs"] is None
