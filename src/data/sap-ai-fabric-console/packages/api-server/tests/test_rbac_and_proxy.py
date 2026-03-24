import pytest

from src.config import settings
from src.routes import mcp_proxy


def test_viewer_cannot_mutate_models(client, viewer_headers) -> None:
    response = client.post(
        "/api/v1/models/",
        headers=viewer_headers,
        json={
            "id": "viewer-blocked-model",
            "name": "Viewer Blocked Model",
            "provider": "sap-ai-core",
            "version": "1.0",
            "context_window": 4096,
            "capabilities": ["chat"],
        },
    )

    assert response.status_code == 403


def test_admin_can_update_deployment_status_via_request_body(client, admin_headers) -> None:
    create_response = client.post(
        "/api/v1/deployments/",
        headers=admin_headers,
        json={"scenario_id": "scenario-a", "configuration": {"replicas": 1}},
    )
    assert create_response.status_code == 201

    deployment_id = create_response.json()["id"]

    update_response = client.patch(
        f"/api/v1/deployments/{deployment_id}/status",
        headers=admin_headers,
        json={"target_status": "STOPPED"},
    )

    assert update_response.status_code == 200
    assert update_response.json() == {"id": deployment_id, "target_status": "STOPPED"}


def test_mcp_proxy_forwards_authenticated_requests(monkeypatch, client, admin_headers) -> None:
    forwarded: dict[str, object] = {}

    async def fake_forward(target_url: str, body: dict, correlation_id: str) -> dict:
        forwarded["target_url"] = target_url
        forwarded["body"] = body
        forwarded["correlation_id"] = correlation_id
        return {"jsonrpc": "2.0", "id": body["id"], "result": {"ok": True}}

    monkeypatch.setattr(mcp_proxy, "_forward", fake_forward)

    response = client.post(
        "/api/v1/mcp/langchain",
        headers={**admin_headers, "X-Correlation-ID": "corr-123"},
        json={"jsonrpc": "2.0", "id": 7, "method": "tools/list", "params": {}},
    )

    assert response.status_code == 200
    assert response.json()["result"] == {"ok": True}
    assert forwarded == {
        "target_url": settings.langchain_mcp_url,
        "body": {"jsonrpc": "2.0", "id": 7, "method": "tools/list", "params": {}},
        "correlation_id": "corr-123",
    }


@pytest.mark.asyncio
async def test_mcp_proxy_returns_jsonrpc_error_when_upstream_unreachable() -> None:
    request = {
        "jsonrpc": "2.0",
        "id": 11,
        "method": "tools/call",
        "params": {},
    }

    result = await mcp_proxy._forward(
        "http://127.0.0.1:9999/mcp",
        request,
        "corr-456",
    )

    assert result["jsonrpc"] == "2.0"
    assert result["id"] == 11
    assert result["error"]["code"] == -32001
    assert "Cannot reach MCP service at http://127.0.0.1:9999/mcp" in result["error"]["message"]
