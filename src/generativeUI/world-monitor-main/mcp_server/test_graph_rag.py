# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2024 SAP SE
"""
Unit tests for KùzuDB Graph-RAG integration in world-monitor-main.

Covers M1 (schema/availability), M2 (kuzu_index tool logic),
M3 (kuzu_query tool logic), and M4 (get_alerts enrichment).

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
from unittest.mock import MagicMock, patch
from types import SimpleNamespace

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
        store.ensure_schema()  # must not raise

    def test_unavailable_run_query_returns_empty(self):
        store = KuzuStore(":memory:")
        store._available = False
        rows = store.run_query("MATCH (e:GeoEvent) RETURN e")
        self.assertEqual(rows, [])

    def test_unavailable_get_event_context_returns_empty(self):
        store = KuzuStore(":memory:")
        store._available = False
        ctx = store.get_event_context("evt-001")
        self.assertEqual(ctx, [])

    def test_unavailable_get_alert_context_returns_empty(self):
        store = KuzuStore(":memory:")
        store._available = False
        ctx = store.get_alert_context("alt-001")
        self.assertEqual(ctx, [])

    def test_unavailable_upsert_event_no_throw(self):
        store = KuzuStore(":memory:")
        store._available = False
        store.upsert_event("evt-001", "conflict", "Ukraine", "Eastern Europe")

    def test_unavailable_upsert_service_no_throw(self):
        store = KuzuStore(":memory:")
        store._available = False
        store.upsert_service("world-monitor-mcp", "http://localhost:9170/mcp", "monitoring")

    def test_unavailable_upsert_alert_no_throw(self):
        store = KuzuStore(":memory:")
        store._available = False
        store.upsert_alert("alt-001", "High Activity", "critical", "world-monitor-mcp")

    def test_unavailable_link_event_alert_no_throw(self):
        store = KuzuStore(":memory:")
        store._available = False
        store.link_event_alert("evt-001", "alt-001")

    def test_unavailable_link_event_service_no_throw(self):
        store = KuzuStore(":memory:")
        store._available = False
        store.link_event_service("evt-001", "world-monitor-mcp")

    def test_unavailable_link_alert_service_no_throw(self):
        store = KuzuStore(":memory:")
        store._available = False
        store.link_alert_service("alt-001", "world-monitor-mcp")

    def test_singleton_get_kuzu_store(self):
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
        # second call is no-op (schema_ready=True)
        self.assertEqual(store._conn.execute.call_count, count1)

    def test_upsert_event_calls_execute(self):
        store = _make_available_store()
        store.upsert_event("evt-001", "conflict", "Ukraine", "Eastern Europe")
        store._conn.execute.assert_called()

    def test_upsert_service_calls_execute(self):
        store = _make_available_store()
        store.upsert_service("world-monitor-mcp", "http://localhost:9170/mcp", "monitoring")
        store._conn.execute.assert_called()

    def test_upsert_alert_calls_execute(self):
        store = _make_available_store()
        store.upsert_alert("alt-001", "High Activity", "critical", "world-monitor-mcp")
        store._conn.execute.assert_called()

    def test_link_event_alert_calls_execute(self):
        store = _make_available_store()
        store.link_event_alert("evt-001", "alt-001")
        store._conn.execute.assert_called()

    def test_run_query_returns_rows(self):
        rows = [{"event_id": "evt-001", "country": "Ukraine"}]
        store = _make_available_store(rows)
        result = store.run_query("MATCH (e:GeoEvent) RETURN e.event_id AS event_id, e.country AS country")
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["event_id"], "evt-001")
        self.assertEqual(result[0]["country"], "Ukraine")

    def test_run_query_returns_empty_on_exception(self):
        store = _make_available_store()
        store._conn.execute.side_effect = RuntimeError("db gone")
        result = store.run_query("MATCH (e:GeoEvent) RETURN e")
        self.assertEqual(result, [])

    def test_get_event_context_returns_list(self):
        ctx_rows = [{"alert_id": "alt-001", "name": "High Activity",
                     "severity": "critical", "relation": "triggered_alert"}]
        store = _make_available_store(ctx_rows)
        ctx = store.get_event_context("evt-001")
        self.assertIsInstance(ctx, list)

    def test_get_alert_context_returns_list(self):
        ctx_rows = [{"event_id": "evt-001", "event_type": "conflict",
                     "country": "Ukraine", "relation": "correlated_event"}]
        store = _make_available_store(ctx_rows)
        ctx = store.get_alert_context("alt-001")
        self.assertIsInstance(ctx, list)


# ---------------------------------------------------------------------------
# M2 – kuzu_index handler logic
# ---------------------------------------------------------------------------

class TestKuzuIndexHandler(unittest.TestCase):
    """Test the _handle_kuzu_index logic extracted from MCPServer."""

    def _make_server(self, store: KuzuStore):
        """Return a minimal MCPServer-like object with a controlled store."""
        import importlib
        import json as _json
        server_mod = importlib.import_module("server")

        # Patch _get_kuzu_store at the module level
        original = server_mod._get_kuzu_store
        server_mod._get_kuzu_store = lambda: store
        srv = server_mod.MCPServer()
        server_mod._get_kuzu_store = original
        return srv, server_mod

    def test_requires_kuzu_available(self):
        store = KuzuStore(":memory:")
        store._available = False
        import importlib
        server_mod = importlib.import_module("server")
        original = server_mod._get_kuzu_store
        server_mod._get_kuzu_store = lambda: store
        srv = server_mod.MCPServer()
        result = srv._handle_kuzu_index({})
        server_mod._get_kuzu_store = original
        self.assertIn("error", result)

    def test_indexes_services(self):
        import importlib, json
        store = _make_available_store()
        server_mod = importlib.import_module("server")
        original = server_mod._get_kuzu_store
        server_mod._get_kuzu_store = lambda: store
        srv = server_mod.MCPServer()
        result = srv._handle_kuzu_index({
            "services": json.dumps([
                {"name": "world-monitor-mcp", "endpoint": "http://localhost:9170/mcp", "category": "monitoring"},
                {"name": "ai-sdk-mcp", "endpoint": "http://localhost:9090/mcp", "category": "ai-core"},
            ])
        })
        server_mod._get_kuzu_store = original
        self.assertEqual(result["services_indexed"], 2)
        self.assertEqual(result["events_indexed"], 0)

    def test_indexes_events(self):
        import importlib, json
        store = _make_available_store()
        server_mod = importlib.import_module("server")
        original = server_mod._get_kuzu_store
        server_mod._get_kuzu_store = lambda: store
        srv = server_mod.MCPServer()
        result = srv._handle_kuzu_index({
            "events": json.dumps([
                {"event_id": "evt-001", "event_type": "conflict", "country": "Ukraine", "region": "Eastern Europe"},
                {"event_id": "evt-002", "event_type": "cyber", "country": "US", "region": "North America"},
            ])
        })
        server_mod._get_kuzu_store = original
        self.assertEqual(result["events_indexed"], 2)

    def test_indexes_alerts(self):
        import importlib, json
        store = _make_available_store()
        server_mod = importlib.import_module("server")
        original = server_mod._get_kuzu_store
        server_mod._get_kuzu_store = lambda: store
        srv = server_mod.MCPServer()
        result = srv._handle_kuzu_index({
            "alerts": json.dumps([
                {"alert_id": "alt-001", "name": "High Conflict", "severity": "critical", "service": "world-monitor-mcp"},
            ])
        })
        server_mod._get_kuzu_store = original
        self.assertEqual(result["alerts_indexed"], 1)

    def test_skips_events_with_missing_event_id(self):
        import importlib, json
        store = _make_available_store()
        server_mod = importlib.import_module("server")
        original = server_mod._get_kuzu_store
        server_mod._get_kuzu_store = lambda: store
        srv = server_mod.MCPServer()
        result = srv._handle_kuzu_index({
            "events": json.dumps([
                {"event_id": "", "event_type": "conflict"},   # skip: no id
                {"event_id": "evt-003", "event_type": "cyber"}, # ok
            ])
        })
        server_mod._get_kuzu_store = original
        self.assertEqual(result["events_indexed"], 1)

    def test_skips_services_with_missing_name(self):
        import importlib, json
        store = _make_available_store()
        server_mod = importlib.import_module("server")
        original = server_mod._get_kuzu_store
        server_mod._get_kuzu_store = lambda: store
        srv = server_mod.MCPServer()
        result = srv._handle_kuzu_index({
            "services": json.dumps([
                {"name": "", "endpoint": "http://localhost:9999/mcp"},  # skip
                {"name": "valid-svc", "endpoint": "http://localhost:9000/mcp"},  # ok
            ])
        })
        server_mod._get_kuzu_store = original
        self.assertEqual(result["services_indexed"], 1)


# ---------------------------------------------------------------------------
# M3 – kuzu_query handler logic
# ---------------------------------------------------------------------------

class TestKuzuQueryHandler(unittest.TestCase):

    DISALLOWED = ["CREATE ", "MERGE ", "DELETE ", "SET ", "REMOVE ", "DROP "]

    def test_requires_cypher(self):
        import importlib
        server_mod = importlib.import_module("server")
        store = KuzuStore(":memory:")
        store._available = False
        original = server_mod._get_kuzu_store
        server_mod._get_kuzu_store = lambda: store
        srv = server_mod.MCPServer()
        result = srv._handle_kuzu_query({"cypher": ""})
        server_mod._get_kuzu_store = original
        self.assertIn("error", result)

    def test_blocks_write_statements(self):
        import importlib
        server_mod = importlib.import_module("server")
        store = _make_available_store()
        original = server_mod._get_kuzu_store
        server_mod._get_kuzu_store = lambda: store
        srv = server_mod.MCPServer()
        for kw in self.DISALLOWED:
            with self.subTest(keyword=kw.strip()):
                result = srv._handle_kuzu_query({"cypher": f"{kw}(n:GeoEvent {{event_id: 'x'}})"})
                self.assertIn("error", result,
                              f"{kw.strip()} should be blocked")
        server_mod._get_kuzu_store = original

    def test_allows_match_statement(self):
        import importlib
        rows = [{"event_id": "evt-001"}]
        store = _make_available_store(rows)
        server_mod = importlib.import_module("server")
        original = server_mod._get_kuzu_store
        server_mod._get_kuzu_store = lambda: store
        srv = server_mod.MCPServer()
        result = srv._handle_kuzu_query({"cypher": "MATCH (e:GeoEvent) RETURN e.event_id AS event_id LIMIT 10"})
        server_mod._get_kuzu_store = original
        self.assertNotIn("error", result)
        self.assertIn("rows", result)

    def test_returns_row_count(self):
        import importlib
        rows = [{"event_id": "evt-001"}, {"event_id": "evt-002"}]
        store = _make_available_store(rows)
        server_mod = importlib.import_module("server")
        original = server_mod._get_kuzu_store
        server_mod._get_kuzu_store = lambda: store
        srv = server_mod.MCPServer()
        result = srv._handle_kuzu_query({"cypher": "MATCH (e:GeoEvent) RETURN e.event_id AS event_id"})
        server_mod._get_kuzu_store = original
        self.assertEqual(result["row_count"], 2)

    def test_returns_error_when_unavailable(self):
        import importlib
        server_mod = importlib.import_module("server")
        store = KuzuStore(":memory:")
        store._available = False
        original = server_mod._get_kuzu_store
        server_mod._get_kuzu_store = lambda: store
        srv = server_mod.MCPServer()
        result = srv._handle_kuzu_query({"cypher": "MATCH (e:GeoEvent) RETURN e"})
        server_mod._get_kuzu_store = original
        self.assertIn("error", result)


# ---------------------------------------------------------------------------
# M4 – get_alerts graph context enrichment
# ---------------------------------------------------------------------------

class TestGetAlertsEnrichment(unittest.TestCase):

    def test_no_enrichment_when_store_unavailable(self):
        import importlib
        server_mod = importlib.import_module("server")
        store = KuzuStore(":memory:")
        store._available = False
        original = server_mod._get_kuzu_store
        server_mod._get_kuzu_store = lambda: store
        srv = server_mod.MCPServer()
        srv.facts["alerts"] = [{"name": "test-alert", "severity": "warning"}]
        result = srv._handle_get_alerts({})
        server_mod._get_kuzu_store = original
        self.assertEqual(result["count"], 1)
        self.assertNotIn("graph_context", result["alerts"][0])

    def test_enrichment_attached_when_store_available(self):
        import importlib
        ctx_rows = [{"event_id": "evt-001", "event_type": "conflict",
                     "country": "Ukraine", "relation": "correlated_event"}]
        store = _make_available_store(ctx_rows)
        server_mod = importlib.import_module("server")
        original = server_mod._get_kuzu_store
        server_mod._get_kuzu_store = lambda: store
        srv = server_mod.MCPServer()
        srv.facts["alerts"] = [{"alert_id": "alt-001", "name": "High Activity", "severity": "critical"}]
        result = srv._handle_get_alerts({})
        server_mod._get_kuzu_store = original
        self.assertEqual(result["count"], 1)
        alert = result["alerts"][0]
        self.assertIn("graph_context", alert)
        self.assertIsInstance(alert["graph_context"], list)

    def test_enrichment_skipped_when_no_context_rows(self):
        import importlib
        store = _make_available_store([])  # mock returns no rows
        server_mod = importlib.import_module("server")
        original = server_mod._get_kuzu_store
        server_mod._get_kuzu_store = lambda: store
        srv = server_mod.MCPServer()
        srv.facts["alerts"] = [{"alert_id": "alt-002", "name": "Low Activity", "severity": "info"}]
        result = srv._handle_get_alerts({})
        server_mod._get_kuzu_store = original
        alert = result["alerts"][0]
        self.assertNotIn("graph_context", alert)

    def test_severity_filter_still_works_with_enrichment(self):
        import importlib
        store = _make_available_store([])
        server_mod = importlib.import_module("server")
        original = server_mod._get_kuzu_store
        server_mod._get_kuzu_store = lambda: store
        srv = server_mod.MCPServer()
        srv.facts["alerts"] = [
            {"alert_id": "alt-001", "name": "Critical Alert", "severity": "critical"},
            {"alert_id": "alt-002", "name": "Warning Alert", "severity": "warning"},
        ]
        result = srv._handle_get_alerts({"severity": "critical"})
        server_mod._get_kuzu_store = original
        self.assertEqual(result["count"], 1)
        self.assertEqual(result["alerts"][0]["alert_id"], "alt-001")

    def test_empty_alerts_list_returns_zero(self):
        import importlib
        store = _make_available_store([])
        server_mod = importlib.import_module("server")
        original = server_mod._get_kuzu_store
        server_mod._get_kuzu_store = lambda: store
        srv = server_mod.MCPServer()
        srv.facts["alerts"] = []
        result = srv._handle_get_alerts({})
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
            "available", "ensure_schema", "upsert_event", "upsert_service",
            "upsert_alert", "link_event_alert", "link_event_service",
            "link_alert_service", "run_query", "get_event_context", "get_alert_context",
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
        self.assertIn("events", schema["properties"])
        self.assertIn("services", schema["properties"])
        self.assertIn("alerts", schema["properties"])

    def test_kuzu_query_tool_schema(self):
        import importlib
        server_mod = importlib.import_module("server")
        srv = server_mod.MCPServer()
        schema = srv.tools["kuzu_query"]["inputSchema"]
        self.assertIn("cypher", schema["properties"])
        self.assertIn("cypher", schema["required"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
