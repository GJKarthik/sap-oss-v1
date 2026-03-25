# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
Unit tests for graph-RAG features (M1-M4) in data-cleaning-copilot.

All tests pass whether or not the ``kuzu`` package is installed; when it is
absent the KuzuStore reports available()=False and every MCP tool returns a
descriptive error rather than raising.
"""

import json
import os
import sys
import unittest
from unittest.mock import MagicMock, patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from mcp_server.server import MCPRequest, MCPServer, parse_json_arg


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _req(tool: str, arguments: dict) -> MCPRequest:
    return MCPRequest({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {"name": tool, "arguments": arguments},
    })


_SIMPLE_SCHEMA = json.dumps({
    "tables": [
        {
            "name": "SalesOrders",
            "columns": [
                {"name": "OrderID", "type": "INTEGER"},
                {"name": "CustomerID", "type": "INTEGER"},
            ],
            "foreign_keys": [
                {"column": "CustomerID", "ref_table": "Customers", "ref_column": "ID"}
            ],
        },
        {
            "name": "Customers",
            "columns": [
                {"name": "ID", "type": "INTEGER"},
                {"name": "Name", "type": "VARCHAR"},
            ],
            "foreign_keys": [],
        },
    ]
})


# ---------------------------------------------------------------------------
# M1 – KuzuStore schema / availability
# ---------------------------------------------------------------------------

class TestKuzuStoreUnavailable(unittest.TestCase):

    def test_available_false_without_kuzu(self):
        with patch.dict("sys.modules", {"kuzu": None}):
            import importlib
            import graph.kuzu_store as ks
            importlib.reload(ks)
            store = ks.KuzuStore(":memory:")
            self.assertFalse(store.available())

    def test_ensure_schema_noop_when_unavailable(self):
        with patch.dict("sys.modules", {"kuzu": None}):
            import importlib
            import graph.kuzu_store as ks
            importlib.reload(ks)
            store = ks.KuzuStore(":memory:")
            store.ensure_schema()  # must not raise

    def test_run_query_returns_empty_when_unavailable(self):
        with patch.dict("sys.modules", {"kuzu": None}):
            import importlib
            import graph.kuzu_store as ks
            importlib.reload(ks)
            store = ks.KuzuStore(":memory:")
            self.assertEqual(store.run_query("MATCH (n) RETURN n"), [])

    def test_get_table_context_returns_empty_when_unavailable(self):
        with patch.dict("sys.modules", {"kuzu": None}):
            import importlib
            import graph.kuzu_store as ks
            importlib.reload(ks)
            store = ks.KuzuStore(":memory:")
            self.assertEqual(store.get_table_context("SalesOrders"), [])

    def test_upsert_table_noop_when_unavailable(self):
        with patch.dict("sys.modules", {"kuzu": None}):
            import importlib
            import graph.kuzu_store as ks
            importlib.reload(ks)
            store = ks.KuzuStore(":memory:")
            store.upsert_table("SalesOrders")  # must not raise

    def test_upsert_column_returns_empty_id_when_unavailable(self):
        with patch.dict("sys.modules", {"kuzu": None}):
            import importlib
            import graph.kuzu_store as ks
            importlib.reload(ks)
            store = ks.KuzuStore(":memory:")
            result = store.upsert_column("SalesOrders", "OrderID", "INTEGER")
            self.assertEqual(result, "")

    def test_link_fk_noop_when_unavailable(self):
        with patch.dict("sys.modules", {"kuzu": None}):
            import importlib
            import graph.kuzu_store as ks
            importlib.reload(ks)
            store = ks.KuzuStore(":memory:")
            store.link_fk("SalesOrders", "CustomerID", "Customers", "ID")  # must not raise


# ---------------------------------------------------------------------------
# M2 – kuzu_index MCP tool
# ---------------------------------------------------------------------------

class TestKuzuIndexTool(unittest.TestCase):

    def setUp(self):
        self.server = MCPServer()

    def test_tool_registered(self):
        self.assertIn("kuzu_index", self.server.tools)

    def test_schema_has_required_field(self):
        schema = self.server.tools["kuzu_index"]["inputSchema"]
        self.assertIn("schema_definition", schema["properties"])
        self.assertIn("schema_definition", schema.get("required", []))

    def test_requires_schema_definition(self):
        resp = self.server.handle_request(_req("kuzu_index", {}))
        self.assertIsNone(resp.error)
        content = json.loads(resp.result["content"][0]["text"])
        self.assertIn("error", content)

    def test_rejects_non_json_schema(self):
        resp = self.server.handle_request(
            _req("kuzu_index", {"schema_definition": "not json"})
        )
        self.assertIsNone(resp.error)
        content = json.loads(resp.result["content"][0]["text"])
        self.assertIn("error", content)

    def test_returns_error_when_kuzu_absent(self):
        with patch.dict("sys.modules", {"kuzu": None}):
            import importlib
            import graph.kuzu_store as ks
            importlib.reload(ks)
            with patch("graph.kuzu_store.get_store", return_value=ks.KuzuStore(":memory:")):
                resp = self.server.handle_request(
                    _req("kuzu_index", {"schema_definition": _SIMPLE_SCHEMA})
                )
        self.assertIsNone(resp.error)
        content = json.loads(resp.result["content"][0]["text"])
        self.assertIn("error", content)

    def test_counts_returned_when_store_available(self):
        mock_store = MagicMock()
        mock_store.available.return_value = True
        mock_store.upsert_table.return_value = None
        mock_store.upsert_column.return_value = "SalesOrders.OrderID"
        mock_store.link_fk.return_value = None
        mock_store.upsert_quality_check.return_value = None

        with patch("graph.kuzu_store.get_store", return_value=mock_store):
            resp = self.server.handle_request(
                _req("kuzu_index", {"schema_definition": _SIMPLE_SCHEMA})
            )
        self.assertIsNone(resp.error)
        content = json.loads(resp.result["content"][0]["text"])
        self.assertEqual(content["tables_indexed"], 2)
        self.assertEqual(content["columns_indexed"], 4)
        self.assertEqual(content["fks_indexed"], 1)
        self.assertEqual(content["checks_indexed"], 0)

    def test_indexes_quality_checks(self):
        mock_store = MagicMock()
        mock_store.available.return_value = True

        checks = json.dumps([
            {"table": "SalesOrders", "check_type": "completeness",
             "status": "PASS", "score": "98.5", "columns": ["OrderID"]},
        ])
        with patch("graph.kuzu_store.get_store", return_value=mock_store):
            resp = self.server.handle_request(
                _req("kuzu_index", {"schema_definition": _SIMPLE_SCHEMA, "checks": checks})
            )
        content = json.loads(resp.result["content"][0]["text"])
        self.assertEqual(content["checks_indexed"], 1)
        mock_store.upsert_quality_check.assert_called_once()


# ---------------------------------------------------------------------------
# M3 – kuzu_query MCP tool
# ---------------------------------------------------------------------------

class TestKuzuQueryTool(unittest.TestCase):

    def setUp(self):
        self.server = MCPServer()

    def test_tool_registered(self):
        self.assertIn("kuzu_query", self.server.tools)

    def test_schema_has_required_field(self):
        schema = self.server.tools["kuzu_query"]["inputSchema"]
        self.assertIn("cypher", schema["properties"])
        self.assertIn("cypher", schema.get("required", []))

    def test_requires_cypher(self):
        resp = self.server.handle_request(_req("kuzu_query", {}))
        content = json.loads(resp.result["content"][0]["text"])
        self.assertIn("error", content)

    def test_blocks_create(self):
        resp = self.server.handle_request(
            _req("kuzu_query", {"cypher": "CREATE (n:DbTable {table_name: 'x'})"})
        )
        content = json.loads(resp.result["content"][0]["text"])
        self.assertIn("error", content)
        self.assertIn("not permitted", content["error"].lower())

    def test_blocks_merge(self):
        resp = self.server.handle_request(
            _req("kuzu_query", {"cypher": "MERGE (n:DbTable {table_name: 'x'})"})
        )
        content = json.loads(resp.result["content"][0]["text"])
        self.assertIn("error", content)

    def test_blocks_delete(self):
        resp = self.server.handle_request(
            _req("kuzu_query", {"cypher": "DELETE (n)"})
        )
        content = json.loads(resp.result["content"][0]["text"])
        self.assertIn("error", content)

    def test_blocks_drop(self):
        resp = self.server.handle_request(
            _req("kuzu_query", {"cypher": "DROP TABLE DbTable"})
        )
        content = json.loads(resp.result["content"][0]["text"])
        self.assertIn("error", content)

    def test_allows_match(self):
        resp = self.server.handle_request(
            _req("kuzu_query", {"cypher": "MATCH (t:DbTable) RETURN t LIMIT 1"})
        )
        content = json.loads(resp.result["content"][0]["text"])
        if "error" in content:
            self.assertNotIn("not permitted", content["error"].lower())

    def test_returns_rows_when_store_available(self):
        mock_store = MagicMock()
        mock_store.available.return_value = True
        mock_store.run_query.return_value = [{"table_name": "SalesOrders"}]

        with patch("graph.kuzu_store.get_store", return_value=mock_store):
            resp = self.server.handle_request(
                _req("kuzu_query", {"cypher": "MATCH (t:DbTable) RETURN t.table_name AS table_name"})
            )
        content = json.loads(resp.result["content"][0]["text"])
        self.assertEqual(content["row_count"], 1)
        self.assertEqual(content["rows"][0]["table_name"], "SalesOrders")


# ---------------------------------------------------------------------------
# M4 – graph context enrichment in data_quality_check
# ---------------------------------------------------------------------------

class TestGraphContextEnrichment(unittest.TestCase):

    def setUp(self):
        self.server = MCPServer()

    def test_graph_context_absent_when_store_unavailable(self):
        mock_store = MagicMock()
        mock_store.available.return_value = False

        with patch("graph.kuzu_store.get_store", return_value=mock_store):
            result = self.server._graph_context_for_table("SalesOrders")
        self.assertEqual(result, [])

    def test_graph_context_returned_when_store_available(self):
        mock_store = MagicMock()
        mock_store.available.return_value = True
        mock_store.get_table_context.return_value = [
            {"col_name": "CustomerID", "col_type": "INTEGER", "relation": "own_column"},
            {"ref_table": "Customers", "ref_col": "ID", "relation": "fk_reference"},
        ]

        with patch("graph.kuzu_store.get_store", return_value=mock_store):
            result = self.server._graph_context_for_table("SalesOrders")

        self.assertEqual(len(result), 2)
        mock_store.get_table_context.assert_called_once_with("SalesOrders", hops=2)

    def test_graph_context_in_data_quality_check_response(self):
        mock_store = MagicMock()
        mock_store.available.return_value = True
        mock_store.get_table_context.return_value = [
            {"col_name": "OrderID", "col_type": "INTEGER", "relation": "own_column"},
        ]

        with patch("graph.kuzu_store.get_store", return_value=mock_store):
            resp = self.server.handle_request(
                _req("data_quality_check", {"table_name": "SalesOrders"})
            )
        content = json.loads(resp.result["content"][0]["text"])
        self.assertIn("graph_context", content)
        self.assertEqual(len(content["graph_context"]), 1)

    def test_graph_context_absent_from_response_when_empty(self):
        mock_store = MagicMock()
        mock_store.available.return_value = True
        mock_store.get_table_context.return_value = []

        with patch("graph.kuzu_store.get_store", return_value=mock_store):
            resp = self.server.handle_request(
                _req("data_quality_check", {"table_name": "SalesOrders"})
            )
        content = json.loads(resp.result["content"][0]["text"])
        self.assertNotIn("graph_context", content)

    def test_graph_context_exception_does_not_break_response(self):
        with patch("graph.kuzu_store.get_store", side_effect=RuntimeError("kuzu exploded")):
            resp = self.server.handle_request(
                _req("data_quality_check", {"table_name": "SalesOrders"})
            )
        self.assertIsNone(resp.error)
        content = json.loads(resp.result["content"][0]["text"])
        self.assertIn("table", content)
        self.assertNotIn("graph_context", content)


# ---------------------------------------------------------------------------
# Tool registration count
# ---------------------------------------------------------------------------

class TestToolRegistration(unittest.TestCase):

    def test_all_14_tools_registered(self):
        """Test all 14 MCP tools are registered (9 core + 5 training)."""
        server = MCPServer()
        expected = {
            # Core tools
            "data_quality_check", "schema_analysis", "data_profiling",
            "anomaly_detection", "generate_cleaning_query", "ai_chat",
            "mangle_query", "kuzu_index", "kuzu_query",
            # Training integration tools
            "list_training_products", "validate_training_product",
            "get_training_schema", "generate_training_data", "modelopt_infer",
        }
        self.assertEqual(expected, set(server.tools.keys()))


if __name__ == "__main__":
    unittest.main()
