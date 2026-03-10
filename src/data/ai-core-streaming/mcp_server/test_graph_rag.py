# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
Unit tests for KùzuDB Graph-RAG integration in ai-core-streaming.

Covers M1 (schema/availability), M2 (kuzu_index tool logic),
M3 (kuzu_query tool logic), and M4 (stream_status enrichment).

Run with:
    python -m pytest mcp_server/test_graph_rag.py -v
  or:
    python -m unittest mcp_server.test_graph_rag

All tests pass whether or not the `kuzu` package is installed —
when absent, the store gracefully degrades and the tests verify
the degradation behaviour.
"""

import sys
import os
import unittest
from unittest.mock import MagicMock

# Ensure the mcp_server package is importable when run from repo root
_here = os.path.dirname(os.path.abspath(__file__))
_root = os.path.dirname(_here)
for _p in (_here, _root):
    if _p not in sys.path:
        sys.path.insert(0, _p)

from graph.kuzu_store import KuzuStore, get_kuzu_store, _reset_kuzu_store


# ---------------------------------------------------------------------------
# Mock helpers
# ---------------------------------------------------------------------------

def _make_mock_result(rows: list[dict]):
    """Return a mock KùzuDB query result object."""
    cols = list(rows[0].keys()) if rows else []
    idx = [0]

    result = MagicMock()
    result.get_column_names.return_value = cols
    result.has_next.side_effect = lambda: idx[0] < len(rows)

    def _get_next():
        row = rows[idx[0]]
        idx[0] += 1
        return [row[c] for c in cols]

    result.get_next.side_effect = _get_next
    return result


def _make_mock_conn(rows: list[dict] | None = None):
    conn = MagicMock()
    conn.execute.return_value = _make_mock_result(rows or [])
    return conn


def _make_available_store(rows: list[dict] | None = None) -> KuzuStore:
    """Return a KuzuStore with a mock connection injected."""
    store = KuzuStore.__new__(KuzuStore)
    store.db_path = ":memory:"
    store._db = MagicMock()
    store._conn = _make_mock_conn(rows or [])
    store._available = True
    store._schema_ready = False
    return store


# ---------------------------------------------------------------------------
# M1 – KuzuStore availability and graceful degradation
# ---------------------------------------------------------------------------

class TestKuzuStoreAvailability(unittest.TestCase):

    def setUp(self):
        _reset_kuzu_store()

    def tearDown(self):
        _reset_kuzu_store()

    def test_available_returns_bool(self):
        store = KuzuStore(":memory:")
        self.assertIsInstance(store.available(), bool)

    def test_unavailable_ensure_schema_no_throw(self):
        store = KuzuStore(":memory:")
        store._available = False
        store.ensure_schema()

    def test_unavailable_run_query_returns_empty(self):
        store = KuzuStore(":memory:")
        store._available = False
        self.assertEqual(store.run_query("MATCH (d:Deployment) RETURN d"), [])

    def test_unavailable_get_stream_context_returns_empty(self):
        store = KuzuStore(":memory:")
        store._available = False
        self.assertEqual(store.get_stream_context("s1a2b3c4"), [])

    def test_unavailable_get_deployment_context_returns_empty(self):
        store = KuzuStore(":memory:")
        store._available = False
        self.assertEqual(store.get_deployment_context("dep-abc"), [])

    def test_unavailable_upsert_deployment_no_throw(self):
        store = KuzuStore(":memory:")
        store._available = False
        store.upsert_deployment("dep-abc", "gpt-4", "default", "running")

    def test_unavailable_upsert_stream_no_throw(self):
        store = KuzuStore(":memory:")
        store._available = False
        store.upsert_stream("s1a2b3c4", "dep-abc", "active", "public")

    def test_unavailable_upsert_routing_decision_no_throw(self):
        store = KuzuStore(":memory:")
        store._available = False
        store.upsert_routing_decision("rd-001", "public", "aicore")

    def test_unavailable_link_session_deployment_no_throw(self):
        store = KuzuStore(":memory:")
        store._available = False
        store.link_session_deployment("s1a2b3c4", "dep-abc")

    def test_unavailable_link_session_routing_no_throw(self):
        store = KuzuStore(":memory:")
        store._available = False
        store.link_session_routing("s1a2b3c4", "rd-001")

    def test_unavailable_link_deployment_routing_no_throw(self):
        store = KuzuStore(":memory:")
        store._available = False
        store.link_deployment_routing("dep-abc", "rd-001")

    def test_singleton_returns_same_instance(self):
        a = get_kuzu_store()
        b = get_kuzu_store()
        self.assertIs(a, b)

    def test_reset_creates_new_singleton(self):
        a = get_kuzu_store()
        _reset_kuzu_store()
        b = get_kuzu_store()
        self.assertIsNot(a, b)


# ---------------------------------------------------------------------------
# M1 – With mock connection (available store)
# ---------------------------------------------------------------------------

class TestKuzuStoreWithMock(unittest.TestCase):

    def test_available_true_with_mock(self):
        store = _make_available_store()
        self.assertTrue(store.available())

    def test_ensure_schema_executes_statements(self):
        store = _make_available_store()
        store.ensure_schema()
        self.assertGreater(store._conn.execute.call_count, 0)

    def test_ensure_schema_idempotent(self):
        store = _make_available_store()
        store.ensure_schema()
        count1 = store._conn.execute.call_count
        store.ensure_schema()
        self.assertEqual(store._conn.execute.call_count, count1)

    def test_upsert_deployment_calls_execute(self):
        store = _make_available_store()
        store.upsert_deployment("dep-abc", "gpt-4", "default", "running")
        store._conn.execute.assert_called()

    def test_upsert_stream_calls_execute(self):
        store = _make_available_store()
        store.upsert_stream("s1a2b3c4", "dep-abc", "active", "public")
        store._conn.execute.assert_called()

    def test_upsert_routing_decision_calls_execute(self):
        store = _make_available_store()
        store.upsert_routing_decision("rd-001", "public", "aicore")
        store._conn.execute.assert_called()

    def test_link_session_deployment_calls_execute(self):
        store = _make_available_store()
        store.link_session_deployment("s1a2b3c4", "dep-abc")
        store._conn.execute.assert_called()

    def test_link_session_routing_calls_execute(self):
        store = _make_available_store()
        store.link_session_routing("s1a2b3c4", "rd-001")
        store._conn.execute.assert_called()

    def test_link_deployment_routing_calls_execute(self):
        store = _make_available_store()
        store.link_deployment_routing("dep-abc", "rd-001")
        store._conn.execute.assert_called()

    def test_run_query_returns_rows(self):
        rows = [{"deployment_id": "dep-abc", "model_name": "gpt-4"}]
        store = _make_available_store(rows)
        result = store.run_query(
            "MATCH (d:Deployment) RETURN d.deployment_id AS deployment_id, d.model_name AS model_name"
        )
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["deployment_id"], "dep-abc")
        self.assertEqual(result[0]["model_name"], "gpt-4")

    def test_run_query_returns_empty_on_exception(self):
        store = _make_available_store()
        store._conn.execute.side_effect = RuntimeError("db gone")
        self.assertEqual(store.run_query("MATCH (d:Deployment) RETURN d"), [])

    def test_get_stream_context_returns_list(self):
        ctx_rows = [{"deployment_id": "dep-abc", "model_name": "gpt-4",
                     "status": "running", "relation": "served_by"}]
        store = _make_available_store(ctx_rows)
        ctx = store.get_stream_context("s1a2b3c4")
        self.assertIsInstance(ctx, list)

    def test_get_deployment_context_returns_list(self):
        ctx_rows = [{"stream_id": "s1a2b3c4", "status": "active",
                     "security_class": "public", "relation": "session"}]
        store = _make_available_store(ctx_rows)
        ctx = store.get_deployment_context("dep-abc")
        self.assertIsInstance(ctx, list)


# ---------------------------------------------------------------------------
# M2 – kuzu_index handler logic
# ---------------------------------------------------------------------------

class TestKuzuIndexHandler(unittest.TestCase):

    def _patch_store(self, store: KuzuStore):
        import importlib
        server_mod = importlib.import_module("server")
        original = server_mod._get_kuzu_store
        server_mod._get_kuzu_store = lambda: store
        srv = server_mod.MCPServer()
        return srv, server_mod, original

    def test_returns_error_when_store_unavailable(self):
        import importlib
        store = KuzuStore(":memory:")
        store._available = False
        srv, server_mod, original = self._patch_store(store)
        result = srv._handle_kuzu_index({})
        server_mod._get_kuzu_store = original
        self.assertIn("error", result)

    def test_indexes_routing_decisions(self):
        import importlib, json
        store = _make_available_store()
        srv, server_mod, original = self._patch_store(store)
        result = srv._handle_kuzu_index({
            "routing_decisions": json.dumps([
                {"decision_id": "rd-public", "security_class": "public", "route": "aicore"},
                {"decision_id": "rd-confidential", "security_class": "confidential", "route": "vllm"},
            ])
        })
        server_mod._get_kuzu_store = original
        self.assertEqual(result["decisions_indexed"], 2)
        self.assertEqual(result["deployments_indexed"], 0)
        self.assertEqual(result["streams_indexed"], 0)

    def test_indexes_deployments(self):
        import importlib, json
        store = _make_available_store()
        srv, server_mod, original = self._patch_store(store)
        result = srv._handle_kuzu_index({
            "deployments": json.dumps([
                {"deployment_id": "dep-abc", "model_name": "gpt-4", "resource_group": "default", "status": "running"},
                {"deployment_id": "dep-xyz", "model_name": "claude-3-sonnet", "resource_group": "prod", "status": "running"},
            ])
        })
        server_mod._get_kuzu_store = original
        self.assertEqual(result["deployments_indexed"], 2)

    def test_indexes_streams(self):
        import importlib, json
        store = _make_available_store()
        srv, server_mod, original = self._patch_store(store)
        result = srv._handle_kuzu_index({
            "streams": json.dumps([
                {"stream_id": "s1a2b3c4", "deployment_id": "dep-abc",
                 "status": "active", "security_class": "public"},
            ])
        })
        server_mod._get_kuzu_store = original
        self.assertEqual(result["streams_indexed"], 1)

    def test_skips_deployments_with_missing_id(self):
        import importlib, json
        store = _make_available_store()
        srv, server_mod, original = self._patch_store(store)
        result = srv._handle_kuzu_index({
            "deployments": json.dumps([
                {"deployment_id": "", "model_name": "gpt-4"},   # skip
                {"deployment_id": "dep-abc", "model_name": "gpt-4"},  # ok
            ])
        })
        server_mod._get_kuzu_store = original
        self.assertEqual(result["deployments_indexed"], 1)

    def test_skips_streams_with_missing_id(self):
        import importlib, json
        store = _make_available_store()
        srv, server_mod, original = self._patch_store(store)
        result = srv._handle_kuzu_index({
            "streams": json.dumps([
                {"stream_id": "", "deployment_id": "dep-abc"},   # skip
                {"stream_id": "s1a2b3c4", "deployment_id": "dep-abc"},  # ok
            ])
        })
        server_mod._get_kuzu_store = original
        self.assertEqual(result["streams_indexed"], 1)

    def test_skips_decisions_with_missing_id(self):
        import importlib, json
        store = _make_available_store()
        srv, server_mod, original = self._patch_store(store)
        result = srv._handle_kuzu_index({
            "routing_decisions": json.dumps([
                {"decision_id": "", "route": "aicore"},   # skip
                {"decision_id": "rd-001", "route": "aicore"},  # ok
            ])
        })
        server_mod._get_kuzu_store = original
        self.assertEqual(result["decisions_indexed"], 1)

    def test_indexes_all_entity_types_together(self):
        import importlib, json
        store = _make_available_store()
        srv, server_mod, original = self._patch_store(store)
        result = srv._handle_kuzu_index({
            "routing_decisions": json.dumps([
                {"decision_id": "rd-public", "security_class": "public", "route": "aicore"},
            ]),
            "deployments": json.dumps([
                {"deployment_id": "dep-abc", "model_name": "gpt-4",
                 "handles_decision": "rd-public"},
            ]),
            "streams": json.dumps([
                {"stream_id": "s1a2b3c4", "deployment_id": "dep-abc",
                 "security_class": "public", "routed_as": "rd-public"},
            ]),
        })
        server_mod._get_kuzu_store = original
        self.assertEqual(result["decisions_indexed"], 1)
        self.assertEqual(result["deployments_indexed"], 1)
        self.assertEqual(result["streams_indexed"], 1)


# ---------------------------------------------------------------------------
# M3 – kuzu_query handler logic
# ---------------------------------------------------------------------------

class TestKuzuQueryHandler(unittest.TestCase):

    DISALLOWED = ["CREATE ", "MERGE ", "DELETE ", "SET ", "REMOVE ", "DROP "]

    def _patch_store(self, store: KuzuStore):
        import importlib
        server_mod = importlib.import_module("server")
        original = server_mod._get_kuzu_store
        server_mod._get_kuzu_store = lambda: store
        srv = server_mod.MCPServer()
        return srv, server_mod, original

    def test_requires_cypher(self):
        store = KuzuStore(":memory:")
        store._available = False
        srv, server_mod, original = self._patch_store(store)
        result = srv._handle_kuzu_query({"cypher": ""})
        server_mod._get_kuzu_store = original
        self.assertIn("error", result)

    def test_blocks_write_statements(self):
        store = _make_available_store()
        srv, server_mod, original = self._patch_store(store)
        for kw in self.DISALLOWED:
            with self.subTest(keyword=kw.strip()):
                result = srv._handle_kuzu_query({"cypher": f"{kw}(d:Deployment {{deployment_id: 'x'}})"})
                self.assertIn("error", result, f"{kw.strip()} should be blocked")
        server_mod._get_kuzu_store = original

    def test_allows_match_statement(self):
        rows = [{"deployment_id": "dep-abc"}]
        store = _make_available_store(rows)
        srv, server_mod, original = self._patch_store(store)
        result = srv._handle_kuzu_query({
            "cypher": "MATCH (d:Deployment) RETURN d.deployment_id AS deployment_id LIMIT 10"
        })
        server_mod._get_kuzu_store = original
        self.assertNotIn("error", result)
        self.assertIn("rows", result)

    def test_returns_row_count(self):
        rows = [{"deployment_id": "dep-abc"}, {"deployment_id": "dep-xyz"}]
        store = _make_available_store(rows)
        srv, server_mod, original = self._patch_store(store)
        result = srv._handle_kuzu_query({
            "cypher": "MATCH (d:Deployment) RETURN d.deployment_id AS deployment_id"
        })
        server_mod._get_kuzu_store = original
        self.assertEqual(result["row_count"], 2)

    def test_returns_error_when_unavailable(self):
        store = KuzuStore(":memory:")
        store._available = False
        srv, server_mod, original = self._patch_store(store)
        result = srv._handle_kuzu_query({
            "cypher": "MATCH (d:Deployment) RETURN d"
        })
        server_mod._get_kuzu_store = original
        self.assertIn("error", result)

    def test_allows_match_with_where(self):
        rows = [{"stream_id": "s1a2b3c4", "security_class": "public"}]
        store = _make_available_store(rows)
        srv, server_mod, original = self._patch_store(store)
        result = srv._handle_kuzu_query({
            "cypher": "MATCH (s:StreamSession) WHERE s.security_class = 'public' "
                      "RETURN s.stream_id AS stream_id, s.security_class AS security_class"
        })
        server_mod._get_kuzu_store = original
        self.assertNotIn("error", result)
        self.assertEqual(result["row_count"], 1)


# ---------------------------------------------------------------------------
# M4 – stream_status graph context enrichment
# ---------------------------------------------------------------------------

class TestStreamStatusEnrichment(unittest.TestCase):

    def _patch_store(self, store: KuzuStore):
        import importlib
        server_mod = importlib.import_module("server")
        original = server_mod._get_kuzu_store
        server_mod._get_kuzu_store = lambda: store
        srv = server_mod.MCPServer()
        return srv, server_mod, original

    def test_no_enrichment_when_store_unavailable(self):
        store = KuzuStore(":memory:")
        store._available = False
        srv, server_mod, original = self._patch_store(store)
        # plant a stream
        srv.streams["s1a2b3c4"] = {"deployment_id": "dep-abc", "status": "active", "events": []}
        result = srv._handle_stream_status({"stream_id": "s1a2b3c4"})
        server_mod._get_kuzu_store = original
        self.assertNotIn("graph_context", result)

    def test_enrichment_attached_for_specific_stream(self):
        ctx_rows = [{"deployment_id": "dep-abc", "model_name": "gpt-4",
                     "status": "running", "relation": "served_by"}]
        store = _make_available_store(ctx_rows)
        srv, server_mod, original = self._patch_store(store)
        srv.streams["s1a2b3c4"] = {"deployment_id": "dep-abc", "status": "active", "events": []}
        result = srv._handle_stream_status({"stream_id": "s1a2b3c4"})
        server_mod._get_kuzu_store = original
        self.assertIn("graph_context", result)
        self.assertIsInstance(result["graph_context"], list)

    def test_no_enrichment_when_context_empty(self):
        store = _make_available_store([])  # returns no rows
        srv, server_mod, original = self._patch_store(store)
        srv.streams["s1a2b3c4"] = {"deployment_id": "dep-abc", "status": "active", "events": []}
        result = srv._handle_stream_status({"stream_id": "s1a2b3c4"})
        server_mod._get_kuzu_store = original
        self.assertNotIn("graph_context", result)

    def test_stream_not_found_returns_error(self):
        store = _make_available_store([])
        srv, server_mod, original = self._patch_store(store)
        result = srv._handle_stream_status({"stream_id": "nonexistent"})
        server_mod._get_kuzu_store = original
        self.assertIn("error", result)

    def test_list_all_streams_returns_count(self):
        store = _make_available_store([])
        srv, server_mod, original = self._patch_store(store)
        srv.streams["s1a2b3c4"] = {"deployment_id": "dep-abc", "status": "active", "events": []}
        srv.streams["s9z8y7x6"] = {"deployment_id": "dep-xyz", "status": "active", "events": []}
        result = srv._handle_stream_status({})
        server_mod._get_kuzu_store = original
        self.assertEqual(result["count"], 2)
        self.assertIn("active_streams", result)

    def test_list_all_streams_enrichment(self):
        ctx_rows = [{"deployment_id": "dep-abc", "model_name": "gpt-4",
                     "status": "running", "relation": "served_by"}]
        store = _make_available_store(ctx_rows)
        srv, server_mod, original = self._patch_store(store)
        srv.streams["s1a2b3c4"] = {"deployment_id": "dep-abc", "status": "active", "events": []}
        result = srv._handle_stream_status({})
        server_mod._get_kuzu_store = original
        streams = result["active_streams"]
        self.assertEqual(len(streams), 1)
        self.assertIn("graph_context", streams[0])

    def test_empty_streams_returns_zero(self):
        store = _make_available_store([])
        srv, server_mod, original = self._patch_store(store)
        result = srv._handle_stream_status({})
        server_mod._get_kuzu_store = original
        self.assertEqual(result["count"], 0)


# ---------------------------------------------------------------------------
# Structural tests
# ---------------------------------------------------------------------------

class TestStructural(unittest.TestCase):

    def test_kuzu_store_exports(self):
        from graph.kuzu_store import KuzuStore, get_kuzu_store, _reset_kuzu_store
        self.assertTrue(callable(get_kuzu_store))
        self.assertTrue(callable(_reset_kuzu_store))
        self.assertTrue(callable(KuzuStore))

    def test_kuzu_store_required_methods(self):
        store = KuzuStore(":memory:")
        for method in (
            "available", "ensure_schema",
            "upsert_deployment", "upsert_stream", "upsert_routing_decision",
            "link_session_deployment", "link_session_routing", "link_deployment_routing",
            "run_query", "get_stream_context", "get_deployment_context",
        ):
            self.assertTrue(callable(getattr(store, method, None)), f"Missing: {method}")

    def test_server_registers_kuzu_tools(self):
        import importlib
        server_mod = importlib.import_module("server")
        srv = server_mod.MCPServer()
        self.assertIn("kuzu_index", srv.tools)
        self.assertIn("kuzu_query", srv.tools)

    def test_kuzu_index_tool_schema(self):
        import importlib
        server_mod = importlib.import_module("server")
        srv = server_mod.MCPServer()
        schema = srv.tools["kuzu_index"]["inputSchema"]
        self.assertIn("deployments", schema["properties"])
        self.assertIn("streams", schema["properties"])
        self.assertIn("routing_decisions", schema["properties"])

    def test_kuzu_query_tool_schema(self):
        import importlib
        server_mod = importlib.import_module("server")
        srv = server_mod.MCPServer()
        schema = srv.tools["kuzu_query"]["inputSchema"]
        self.assertIn("cypher", schema["properties"])
        self.assertIn("cypher", schema["required"])

    def test_kuzu_index_tool_has_description(self):
        import importlib
        server_mod = importlib.import_module("server")
        srv = server_mod.MCPServer()
        self.assertIn("KùzuDB", srv.tools["kuzu_index"]["description"])

    def test_kuzu_query_tool_has_description(self):
        import importlib
        server_mod = importlib.import_module("server")
        srv = server_mod.MCPServer()
        self.assertIn("KùzuDB", srv.tools["kuzu_query"]["description"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
