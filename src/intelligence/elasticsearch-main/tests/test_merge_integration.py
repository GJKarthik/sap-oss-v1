"""
Merge integration tests for the unified SAP Elasticsearch + Mangle Query Service.

Validates:
1. All merged Python packages import without errors.
2. MangleGRPCClient is importable and its unavailability path is safe.
3. MCPServer._governance_check dispatches to gRPC then falls back correctly.
4. The unified cmd.server.main module loads without import errors.
5. Middleware merged modules are importable.
6. rules/es_domain.mg exists and contains expected facts.
"""

import importlib
import os
import sys
import types
import unittest
from unittest.mock import MagicMock, patch

# Ensure the repo root is on sys.path
_REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)


class TestMergedPackageImports(unittest.TestCase):
    """Verify that all merged packages import without errors in isolation."""

    def _assert_importable(self, module_name: str, stub_deps: dict | None = None):
        """Try to import *module_name*, stubbing out *stub_deps* as needed."""
        stub_deps = stub_deps or {}
        with patch.dict("sys.modules", stub_deps):
            try:
                if module_name in sys.modules:
                    importlib.reload(sys.modules[module_name])
                else:
                    importlib.import_module(module_name)
            except ImportError as exc:
                self.fail(f"ImportError importing {module_name}: {exc}")

    def test_middleware_validation_importable(self):
        self._assert_importable("middleware.validation")

    def test_middleware_retry_importable(self):
        self._assert_importable("middleware.retry")

    def test_middleware_health_monitor_importable(self):
        self._assert_importable("middleware.health_monitor")

    def test_middleware_mtls_importable(self):
        self._assert_importable("middleware.mtls")

    def test_middleware_hana_circuit_breaker_importable(self):
        _stubs = {
            "hdbcli": MagicMock(),
            "hdbcli.dbapi": MagicMock(),
        }
        self._assert_importable("middleware.hana_circuit_breaker", stub_deps=_stubs)

    def test_middleware_resilient_client_importable(self):
        self._assert_importable("middleware.resilient_client")

    def test_mcp_server_importable(self):
        """mcp_server.server must import cleanly (all dependencies stubbed)."""
        _stubs = {
            "kuzu": MagicMock(),
            "hdbcli": MagicMock(),
            "hdbcli.dbapi": MagicMock(),
        }
        self._assert_importable("mcp_server.server", stub_deps=_stubs)


class TestMangleGRPCClientImport(unittest.TestCase):
    """MangleGRPCClient must be importable and safe to instantiate."""

    def test_client_class_exists(self):
        from mcp_server.server import MangleGRPCClient
        client = MangleGRPCClient(port=19999)
        self.assertIsNotNone(client)

    def test_resolve_returns_none_when_unavailable(self):
        from mcp_server.server import MangleGRPCClient
        client = MangleGRPCClient(port=19997)
        result = client.resolve("test")
        self.assertIsNone(result)

    def test_global_client_singleton_exists(self):
        import mcp_server.server as srv
        self.assertTrue(hasattr(srv, "_mangle_grpc_client"))


class TestGovernanceCheckDispatch(unittest.TestCase):
    """_governance_check must prefer gRPC and fall back to Python."""

    def setUp(self):
        from mcp_server.server import MCPServer
        self.server = MCPServer()

    @patch("mcp_server.server._mangle_grpc_client")
    def test_grpc_vllm_blocks(self, mock_client):
        mock_client.resolve.return_value = {"path": "vllm", "confidence": 0.9, "answer": ""}
        result = self.server._governance_check("customers data", "es_search")
        self.assertIsNotNone(result)
        self.assertIn("Governance block", result["error"])

    @patch("mcp_server.server._mangle_grpc_client")
    def test_grpc_rag_allows(self, mock_client):
        mock_client.resolve.return_value = {"path": "rag", "confidence": 0.7, "answer": ""}
        result = self.server._governance_check("search products", "es_search")
        self.assertIsNone(result)

    @patch("mcp_server.server._mangle_grpc_client")
    def test_grpc_none_allows_when_no_python_fallback(self, mock_client):
        """When gRPC is None and Python fallback raises ImportError, request is allowed."""
        mock_client.resolve.return_value = None
        with patch.dict("sys.modules", {"agent.elasticsearch_agent": None}):
            result = self.server._governance_check("safe query", "es_search")
        self.assertIsNone(result)


class TestEsDomainRuleFile(unittest.TestCase):
    """Verify rules/es_domain.mg was created and contains expected facts."""

    def _rules_path(self) -> str:
        return os.path.join(_REPO_ROOT, "rules", "es_domain.mg")

    def test_file_exists(self):
        self.assertTrue(os.path.isfile(self._rules_path()),
                        "rules/es_domain.mg missing")

    def test_contains_confidential_index_facts(self):
        content = open(self._rules_path()).read()
        for index in ("customers", "orders", "transactions", "financial", "audit"):
            self.assertIn(f'confidential_index("{index}")', content,
                          f"Missing confidential_index fact for '{index}'")

    def test_contains_agent_config_facts(self):
        content = open(self._rules_path()).read()
        self.assertIn('agent_config("elasticsearch-agent"', content)

    def test_contains_data_security_class_facts(self):
        content = open(self._rules_path()).read()
        self.assertIn('data_security_class("customers", "confidential")', content)
        self.assertIn('data_security_class("products", "public")', content)


class TestAllRulesFilesPresent(unittest.TestCase):
    """All 9 expected rule files must exist in rules/."""

    _EXPECTED = [
        "routing.mg",
        "governance.mg",
        "analytics_routing.mg",
        "hana_vector.mg",
        "rag_enrichment.mg",
        "model_registry.mg",
        "agent_classification.mg",
        "graph_rag.mg",
        "es_domain.mg",
    ]

    def test_rule_files_present(self):
        rules_dir = os.path.join(_REPO_ROOT, "rules")
        missing = [f for f in self._EXPECTED
                   if not os.path.isfile(os.path.join(rules_dir, f))]
        self.assertFalse(missing, f"Missing rule files: {missing}")


class TestUnifiedEntrypointImport(unittest.TestCase):
    """cmd.server.main must import without errors (heavy deps stubbed)."""

    def _load_main_module(self, extra_stubs: dict | None = None):
        """Load cmd/server/main.py via file path to avoid stdlib 'cmd' collision."""
        import importlib.util
        main_path = os.path.join(_REPO_ROOT, "cmd", "server", "main.py")
        _stubs = {
            "uvicorn": MagicMock(),
            "kuzu": MagicMock(),
            "hdbcli": MagicMock(),
            "hdbcli.dbapi": MagicMock(),
            "langchain_community": MagicMock(),
            "langchain_community.vectorstores": MagicMock(),
            "langchain_community.vectorstores.hanavector": MagicMock(),
            "grpc": MagicMock(),
        }
        if extra_stubs:
            _stubs.update(extra_stubs)
        with patch.dict("sys.modules", _stubs):
            spec = importlib.util.spec_from_file_location("_merged_main", main_path)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
        return mod

    def test_main_module_importable(self):
        try:
            self._load_main_module()
        except ImportError as exc:
            self.fail(f"ImportError loading cmd/server/main.py: {exc}")

    def test_grpc_sidecar_skipped_when_binary_absent(self):
        """_start_grpc_sidecar silently skips when mangle-engine is not on PATH."""
        mod = self._load_main_module()
        state = mod.ApplicationState()
        with patch("shutil.which", return_value=None):
            import logging
            with self.assertLogs(level=logging.WARNING):
                state._start_grpc_sidecar()
        self.assertIsNone(state._grpc_proc)


class TestMiddlewareMergeInit(unittest.TestCase):
    """middleware/__init__.py must load without hard failures."""

    def test_middleware_init_importable(self):
        try:
            if "middleware" in sys.modules:
                importlib.reload(sys.modules["middleware"])
            else:
                importlib.import_module("middleware")
        except ImportError as exc:
            self.fail(f"middleware __init__ ImportError: {exc}")

    def test_core_symbols_present(self):
        import middleware
        for sym in ("RateLimiter", "CircuitBreaker", "HealthChecker"):
            self.assertTrue(hasattr(middleware, sym),
                            f"middleware.{sym} missing after merge")


if __name__ == "__main__":
    unittest.main()
