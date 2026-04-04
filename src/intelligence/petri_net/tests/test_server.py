"""Tests for the CPN FastAPI server."""

import asyncio
import pytest
from fastapi.testclient import TestClient

from petri_net.server import app, _instances


@pytest.fixture(autouse=True)
def clear_instances():
    """Clear all CPN instances between tests."""
    _instances.clear()
    yield
    _instances.clear()


client = TestClient(app)


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------


class TestHealth:
    def test_health(self):
        r = client.get("/health")
        assert r.status_code == 200
        assert r.json()["status"] == "ok"


# ---------------------------------------------------------------------------
# Templates
# ---------------------------------------------------------------------------


class TestTemplates:
    def test_list_templates(self):
        r = client.get("/api/cpn/templates")
        assert r.status_code == 200
        names = [t["name"] for t in r.json()["templates"]]
        assert "training_pipeline" in names
        assert "ocr_batch" in names
        assert "model_deploy" in names


# ---------------------------------------------------------------------------
# Net CRUD
# ---------------------------------------------------------------------------


class TestNetCRUD:
    def _create(self, template="model_deploy"):
        r = client.post("/api/cpn/nets", json={"template": template})
        assert r.status_code == 200
        return r.json()["net_id"]

    def test_create_from_template(self):
        r = client.post("/api/cpn/nets", json={"template": "model_deploy"})
        assert r.status_code == 200
        data = r.json()
        assert "net_id" in data
        assert data["name"] == "model_deploy"

    def test_create_bad_template(self):
        r = client.post("/api/cpn/nets", json={"template": "nonexistent"})
        assert r.status_code == 400

    def test_create_no_input(self):
        r = client.post("/api/cpn/nets", json={})
        assert r.status_code == 400

    def test_create_with_custom_name(self):
        r = client.post("/api/cpn/nets", json={"template": "model_deploy", "name": "my_net"})
        assert r.status_code == 200
        assert r.json()["name"] == "my_net"

    def test_list_nets(self):
        self._create()
        self._create("training_pipeline")
        r = client.get("/api/cpn/nets")
        assert r.status_code == 200
        assert len(r.json()["nets"]) == 2

    def test_get_net(self):
        net_id = self._create()
        r = client.get(f"/api/cpn/nets/{net_id}")
        assert r.status_code == 200
        data = r.json()
        assert "marking" in data
        assert "enabled_transitions" in data
        assert "structure" in data

    def test_get_nonexistent(self):
        r = client.get("/api/cpn/nets/nonexistent")
        assert r.status_code == 404

    def test_delete_net(self):
        net_id = self._create()
        r = client.delete(f"/api/cpn/nets/{net_id}")
        assert r.status_code == 200
        assert r.json()["deleted"] is True
        # Confirm gone
        r = client.get(f"/api/cpn/nets/{net_id}")
        assert r.status_code == 404

    def test_delete_nonexistent(self):
        r = client.delete("/api/cpn/nets/nonexistent")
        assert r.status_code == 404


# ---------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------


class TestExecution:
    def _create(self, template="model_deploy"):
        r = client.post("/api/cpn/nets", json={"template": template})
        return r.json()["net_id"]

    def test_step(self):
        net_id = self._create()
        r = client.post(f"/api/cpn/nets/{net_id}/step")
        assert r.status_code == 200
        data = r.json()
        assert "fired" in data
        assert data["step_count"] == 1

    def test_fire_specific(self):
        net_id = self._create()
        # model_deploy starts with "export" enabled
        r = client.post(
            f"/api/cpn/nets/{net_id}/fire",
            json={"transition": "export"},
        )
        assert r.status_code == 200
        assert r.json()["fired"] == "export"

    def test_fire_not_enabled(self):
        net_id = self._create()
        # "deploy" needs export to fire first
        r = client.post(
            f"/api/cpn/nets/{net_id}/fire",
            json={"transition": "deploy"},
        )
        assert r.status_code == 409


# ---------------------------------------------------------------------------
# Run / Pause / Reset
# ---------------------------------------------------------------------------


class TestRunPauseReset:
    def _create(self, template="model_deploy"):
        r = client.post("/api/cpn/nets", json={"template": template})
        return r.json()["net_id"]

    def test_run(self):
        net_id = self._create()
        r = client.post(f"/api/cpn/nets/{net_id}/run", json={"max_steps": 100})
        assert r.status_code == 200
        assert r.json()["status"] == "running"
        # Give the background task time to complete
        import time
        time.sleep(0.5)
        r = client.get(f"/api/cpn/nets/{net_id}")
        assert r.json()["status"] in ("completed", "running")

    def test_run_already_running(self):
        net_id = self._create("training_pipeline")
        client.post(f"/api/cpn/nets/{net_id}/run", json={"max_steps": 1000})
        import time
        time.sleep(0.05)
        r = client.post(f"/api/cpn/nets/{net_id}/run", json={"max_steps": 10})
        # Could be 409 if still running or 200 if already completed
        assert r.status_code in (200, 409)

    def test_pause_not_running(self):
        net_id = self._create()
        r = client.post(f"/api/cpn/nets/{net_id}/pause")
        assert r.status_code == 409

    def test_reset(self):
        net_id = self._create()
        # Step once
        client.post(f"/api/cpn/nets/{net_id}/step")
        r = client.get(f"/api/cpn/nets/{net_id}")
        assert r.json()["step_count"] == 1
        # Reset
        r = client.post(f"/api/cpn/nets/{net_id}/reset")
        assert r.status_code == 200
        assert r.json()["status"] == "idle"
        # Check step count is reset
        r = client.get(f"/api/cpn/nets/{net_id}")
        assert r.json()["step_count"] == 0


# ---------------------------------------------------------------------------
# History
# ---------------------------------------------------------------------------


class TestHistory:
    def _create(self, template="model_deploy"):
        r = client.post("/api/cpn/nets", json={"template": template})
        return r.json()["net_id"]

    def test_history_empty(self):
        net_id = self._create()
        r = client.get(f"/api/cpn/nets/{net_id}/history")
        assert r.status_code == 200
        assert r.json()["history"] == []

    def test_history_after_fire(self):
        net_id = self._create()
        client.post(f"/api/cpn/nets/{net_id}/step")
        client.post(f"/api/cpn/nets/{net_id}/step")
        r = client.get(f"/api/cpn/nets/{net_id}/history")
        assert r.status_code == 200
        history = r.json()["history"]
        assert len(history) == 2
        assert history[0]["type"] == "fire"
        assert "timestamp" in history[0]


# ---------------------------------------------------------------------------
# WebSocket
# ---------------------------------------------------------------------------


class TestWebSocket:
    def _create(self, template="model_deploy"):
        r = client.post("/api/cpn/nets", json={"template": template})
        return r.json()["net_id"]

    def test_websocket_connect_and_initial_state(self):
        net_id = self._create()
        with client.websocket_connect(f"/api/cpn/nets/{net_id}/stream") as ws:
            data = ws.receive_json()
            assert data["type"] == "state"
            assert "marking" in data
            assert "timestamp" in data

    def test_websocket_receives_fire_event(self):
        net_id = self._create()
        with client.websocket_connect(f"/api/cpn/nets/{net_id}/stream") as ws:
            # Read initial state
            ws.receive_json()
            # Fire a transition from another "client"
            client.post(f"/api/cpn/nets/{net_id}/step")
            # Should receive fire event
            data = ws.receive_json()
            assert data["type"] == "fire"
            assert "transition" in data

    def test_websocket_nonexistent_net(self):
        with pytest.raises(Exception):
            with client.websocket_connect("/api/cpn/nets/bogus/stream") as ws:
                pass


# ---------------------------------------------------------------------------
# Custom definition
# ---------------------------------------------------------------------------


class TestCustomDefinition:
    def test_create_from_definition(self):
        defn = {
            "name": "simple",
            "places": [
                {"id": "p1", "name": "start", "capacity": None, "accepted_colours": None},
                {"id": "p2", "name": "end", "capacity": None, "accepted_colours": None},
            ],
            "transitions": [
                {"id": "t1", "name": "go", "priority": 0, "delay": None},
            ],
            "arcs": [
                {"place_name": "start", "transition_name": "go",
                 "direction": "input", "weight": 1, "variable": "start"},
                {"place_name": "end", "transition_name": "go",
                 "direction": "output", "weight": 1},
            ],
        }
        r = client.post("/api/cpn/nets", json={"definition": defn})
        assert r.status_code == 200
        assert r.json()["name"] == "simple"
