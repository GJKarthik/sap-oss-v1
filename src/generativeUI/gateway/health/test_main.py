from __future__ import annotations

import asyncio

from fastapi.testclient import TestClient

import main


def test_run_checks_probes_dependencies_concurrently(monkeypatch) -> None:
    monkeypatch.setattr(
        main,
        "CHECKS",
        [
            ("aifabric_api", "http://aifabric-api/health", True),
            ("training_api", "http://training-api/health", True),
            ("ui5_web", "http://ui5-web/health", False),
        ],
    )

    concurrency = {"current": 0, "max": 0}

    async def fake_probe(_client, name: str, url: str, required: bool):
        concurrency["current"] += 1
        concurrency["max"] = max(concurrency["max"], concurrency["current"])
        await asyncio.sleep(0.01)
        concurrency["current"] -= 1
        return {
            "name": name,
            "url": url,
            "required": required,
            "ok": True,
            "status_code": 200,
            "details": {"status": "ok"},
        }

    monkeypatch.setattr(main, "probe", fake_probe)

    summary = asyncio.run(main.run_checks())

    assert summary["status"] == "ok"
    assert concurrency["max"] > 1


def test_health_is_pure_liveness(monkeypatch) -> None:
    async def fail_if_called():
        raise AssertionError("run_checks should not be called for liveness")

    monkeypatch.setattr(main, "run_checks", fail_if_called)
    client = TestClient(main.app)

    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"suite": "sap-ai-open-source-suite", "status": "healthy"}


def test_ready_returns_503_when_required_services_fail(monkeypatch) -> None:
    async def degraded_summary():
        return {
            "status": "degraded",
            "required_failures": 1,
            "checks": [
                {
                    "name": "aifabric_api",
                    "url": "http://aifabric-api/health",
                    "required": True,
                    "ok": False,
                    "status_code": 503,
                    "details": "offline",
                }
            ],
        }

    monkeypatch.setattr(main, "run_checks", degraded_summary)
    client = TestClient(main.app)

    response = client.get("/ready")

    assert response.status_code == 503
    assert response.json()["status"] == "degraded"
    assert response.json()["required_failures"] == 1


def test_ready_details_returns_full_summary(monkeypatch) -> None:
    async def ok_summary():
        return {
            "status": "ok",
            "required_failures": 0,
            "checks": [{"name": "training_api", "ok": True, "required": True, "status_code": 200, "details": {"status": "ok"}}],
        }

    monkeypatch.setattr(main, "run_checks", ok_summary)
    client = TestClient(main.app)

    response = client.get("/ready/details")

    assert response.status_code == 200
    assert response.json()["suite"] == "sap-ai-open-source-suite"
    assert response.json()["checks"][0]["name"] == "training_api"
