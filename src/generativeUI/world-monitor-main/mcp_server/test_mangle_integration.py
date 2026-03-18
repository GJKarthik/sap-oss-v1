"""Focused tests for World Monitor Mangle remote integration and fallback."""

import importlib
import os
import sys
import unittest
from unittest.mock import patch


_here = os.path.dirname(os.path.abspath(__file__))
_root = os.path.dirname(_here)
for _path in (_here, _root):
    if _path not in sys.path:
        sys.path.insert(0, _path)


world_monitor_agent = importlib.import_module("agent.world_monitor_agent")
server_mod = importlib.import_module("server")
runtime_client = importlib.import_module("mangle.runtime_client")


class TestMangleEndpointValidation(unittest.TestCase):
    def test_grpc_endpoint_is_allowed(self):
        endpoint = runtime_client.validate_mangle_endpoint(
            "grpc://localhost:50051",
            "MANGLE_ENDPOINT",
            tuple(),
        )
        self.assertEqual(endpoint, "grpc://localhost:50051")


class TestWorldMonitorMangleEngine(unittest.TestCase):
    def test_engine_uses_remote_results_when_grpc_configured(self):
        with patch.object(world_monitor_agent, "_MANGLE_ENDPOINT", "grpc://localhost:50051"):
            engine = world_monitor_agent.MangleEngine()
            with patch.object(
                engine._remote_client,
                "_query_grpc",
                return_value=[{"result": True, "reason": "remote derivation"}],
            ) as mock_query:
                result = engine.query("route_to_vllm", "internal threat assessment")

        self.assertEqual(result, [{"result": True, "reason": "remote derivation"}])
        mock_query.assert_called_once_with("route_to_vllm", ["internal threat assessment"])

    def test_engine_opens_circuit_breaker_and_falls_back_locally(self):
        with patch.object(world_monitor_agent, "_MANGLE_ENDPOINT", "grpc://localhost:50051"):
            engine = world_monitor_agent.MangleEngine()
            with patch.object(
                engine._remote_client,
                "_query_grpc",
                side_effect=RuntimeError("grpc down"),
            ) as mock_query:
                for _ in range(4):
                    result = engine.query("route_to_vllm", "internal threat assessment")
                    self.assertTrue(result)
                    self.assertTrue(result[0]["result"])

        self.assertEqual(mock_query.call_count, 3)
        self.assertEqual(engine._remote_client.breaker.snapshot()["state"], "open")


class TestMCPMangleTool(unittest.TestCase):
    def test_mcp_tool_returns_remote_derivations(self):
        with patch.object(server_mod, "MANGLE_ENDPOINT", "grpc://localhost:50051"):
            srv = server_mod.MCPServer()
            with patch.object(
                srv._mangle_client,
                "_query_grpc",
                return_value=[{"service": "vllm", "result": "approved"}],
            ) as mock_query:
                result = srv._handle_mangle_query({
                    "predicate": "route_to_vllm",
                    "args": '["internal threat assessment"]',
                })

        self.assertTrue(result["wired"])
        self.assertEqual(result["results"], [{"service": "vllm", "result": "approved"}])
        mock_query.assert_called_once_with("route_to_vllm", ["internal threat assessment"])

    def test_mcp_tool_falls_back_to_local_derivation_shape(self):
        with patch.object(server_mod, "MANGLE_ENDPOINT", "grpc://localhost:50051"):
            srv = server_mod.MCPServer()
            with patch.object(
                srv._mangle_client,
                "_query_grpc",
                side_effect=RuntimeError("grpc down"),
            ):
                result = srv._handle_mangle_query({
                    "predicate": "route_to_vllm",
                    "args": '["internal threat assessment"]',
                })

        self.assertFalse(result["wired"])
        self.assertEqual(result["fallback_source"], "world_monitor_python_simulation")
        self.assertTrue(result["results"])
        self.assertIn("reason", result["results"][0])
        self.assertIn("result", result["results"][0])

    def test_mcp_tool_uses_hana_governance_facts_before_local_stub(self):
        with patch.object(server_mod, "MANGLE_ENDPOINT", "grpc://localhost:50051"):
            srv = server_mod.MCPServer()
            with patch.object(
                srv._mangle_client,
                "_query_grpc",
                side_effect=RuntimeError("grpc down"),
            ):
                result = srv._handle_mangle_query({
                    "predicate": "subject_to_review",
                    "args": '["impact_assessment"]',
                })

        self.assertEqual(result["fallback_source"], "hana_toolkit")
        self.assertEqual(len(result["results"]), 2)
        self.assertEqual(result["hana"]["service"], "hana-toolkit")

    def test_health_payload_reports_mangle_status(self):
        srv = server_mod.MCPServer()
        with patch.object(
            srv._mangle_client,
            "health",
            return_value={
                "configured": True,
                "endpoint": "grpc://localhost:50051",
                "transport": "grpc",
                "reachable": False,
                "status": "degraded",
                "error": "connection refused",
                "circuit_breaker": {"state": "open"},
            },
        ):
            payload = srv.get_health_payload()

        self.assertEqual(payload["status"], "degraded")
        self.assertEqual(payload["mangle"]["transport"], "grpc")
        self.assertEqual(payload["mangle"]["circuit_breaker"]["state"], "open")
        self.assertIn("hana_toolkit", payload)


if __name__ == "__main__":
    unittest.main()