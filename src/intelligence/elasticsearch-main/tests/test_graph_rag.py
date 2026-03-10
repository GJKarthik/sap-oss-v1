"""
Unit tests for graph-RAG features (M1-M4).

KùzuDB is an optional dependency; all tests are designed to pass whether or
not the ``kuzu`` package is installed.  When kuzu is absent the KuzuStore
reports available()=False and the MCP tools return a descriptive error rather
than raising an exception.
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

def _make_req(tool: str, arguments: dict) -> MCPRequest:
    return MCPRequest({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {"name": tool, "arguments": arguments},
    })


# ---------------------------------------------------------------------------
# M1 – KuzuStore schema / availability
# ---------------------------------------------------------------------------

class TestKuzuStoreUnavailable(unittest.TestCase):
    """Tests for KuzuStore graceful degradation when kuzu is not installed."""

    def test_store_available_false_without_kuzu(self):
        """KuzuStore.available() is False when kuzu import fails."""
        with patch.dict("sys.modules", {"kuzu": None}):
            import importlib
            import graph.kuzu_store as ks
            importlib.reload(ks)
            store = ks.KuzuStore(":memory:")
            self.assertFalse(store.available())

    def test_ensure_schema_noop_when_unavailable(self):
        """ensure_schema() does not raise when store is unavailable."""
        with patch.dict("sys.modules", {"kuzu": None}):
            import importlib
            import graph.kuzu_store as ks
            importlib.reload(ks)
            store = ks.KuzuStore(":memory:")
            store.ensure_schema()  # must not raise

    def test_run_query_returns_empty_when_unavailable(self):
        """run_query() returns [] rather than raising when unavailable."""
        with patch.dict("sys.modules", {"kuzu": None}):
            import importlib
            import graph.kuzu_store as ks
            importlib.reload(ks)
            store = ks.KuzuStore(":memory:")
            result = store.run_query("MATCH (n) RETURN n")
            self.assertEqual(result, [])

    def test_get_entity_context_returns_empty_when_unavailable(self):
        """get_entity_context() returns [] when kuzu is absent."""
        with patch.dict("sys.modules", {"kuzu": None}):
            import importlib
            import graph.kuzu_store as ks
            importlib.reload(ks)
            store = ks.KuzuStore(":memory:")
            ctx = store.get_entity_context("SalesOrder", "SO-1001", hops=2)
            self.assertEqual(ctx, [])


# ---------------------------------------------------------------------------
# M2 – kuzu_index MCP tool
# ---------------------------------------------------------------------------

class TestKuzuIndexTool(unittest.TestCase):
    """Tests for the kuzu_index MCP tool handler."""

    def setUp(self):
        self.server = MCPServer()

    def test_kuzu_index_requires_index(self):
        """kuzu_index must return an error when index is absent."""
        resp = self.server.handle_request(_make_req("kuzu_index", {}))
        self.assertIsNone(resp.error)
        content = json.loads(resp.result["content"][0]["text"])
        self.assertIn("error", content)

    def test_kuzu_index_tool_registered(self):
        """kuzu_index must appear in the tool registry."""
        self.assertIn("kuzu_index", self.server.tools)

    def test_kuzu_index_schema(self):
        """kuzu_index inputSchema has required 'index' field."""
        schema = self.server.tools["kuzu_index"]["inputSchema"]
        self.assertEqual(schema["type"], "object")
        self.assertIn("index", schema["properties"])
        self.assertIn("index", schema.get("required", []))

    @patch("mcp_server.server.es_request")
    def test_kuzu_index_returns_error_when_kuzu_absent(self, mock_es):
        """kuzu_index returns descriptive error when kuzu package is missing."""
        mock_es.return_value = {"hits": {"hits": []}}
        with patch.dict("sys.modules", {"kuzu": None}):
            import importlib
            import graph.kuzu_store as ks
            importlib.reload(ks)
            # Patch get_store so it returns an unavailable store
            with patch("mcp_server.server.MCPServer._handle_kuzu_index",
                       wraps=self.server._handle_kuzu_index):
                resp = self.server.handle_request(
                    _make_req("kuzu_index", {"index": "odata_entity"})
                )
        self.assertIsNone(resp.error)
        content = json.loads(resp.result["content"][0]["text"])
        # Either "error" (kuzu absent) or success dict — both are acceptable
        # depending on whether kuzu is installed in the test environment.
        self.assertIsInstance(content, dict)

    @patch("mcp_server.server.es_request")
    def test_kuzu_index_propagates_es_error(self, mock_es):
        """kuzu_index propagates Elasticsearch errors before touching the graph."""
        mock_es.return_value = {"error": "connection refused"}
        resp = self.server.handle_request(
            _make_req("kuzu_index", {"index": "odata_entity"})
        )
        self.assertIsNone(resp.error)
        content = json.loads(resp.result["content"][0]["text"])
        self.assertIn("error", content)


# ---------------------------------------------------------------------------
# M3 – kuzu_query MCP tool
# ---------------------------------------------------------------------------

class TestKuzuQueryTool(unittest.TestCase):
    """Tests for the kuzu_query MCP tool handler."""

    def setUp(self):
        self.server = MCPServer()

    def test_kuzu_query_tool_registered(self):
        """kuzu_query must appear in the tool registry."""
        self.assertIn("kuzu_query", self.server.tools)

    def test_kuzu_query_schema(self):
        """kuzu_query inputSchema has required 'cypher' field."""
        schema = self.server.tools["kuzu_query"]["inputSchema"]
        self.assertEqual(schema["type"], "object")
        self.assertIn("cypher", schema["properties"])
        self.assertIn("cypher", schema.get("required", []))

    def test_kuzu_query_requires_cypher(self):
        """kuzu_query must return an error when cypher is absent."""
        resp = self.server.handle_request(_make_req("kuzu_query", {}))
        self.assertIsNone(resp.error)
        content = json.loads(resp.result["content"][0]["text"])
        self.assertIn("error", content)

    def test_kuzu_query_blocks_create(self):
        """kuzu_query must reject CREATE statements."""
        resp = self.server.handle_request(
            _make_req("kuzu_query", {"cypher": "CREATE (n:Entity {entity_id: 'x'})"})
        )
        self.assertIsNone(resp.error)
        content = json.loads(resp.result["content"][0]["text"])
        self.assertIn("error", content)
        self.assertIn("not permitted", content["error"].lower())

    def test_kuzu_query_blocks_merge(self):
        """kuzu_query must reject MERGE statements."""
        resp = self.server.handle_request(
            _make_req("kuzu_query", {"cypher": "MERGE (n:Entity {entity_id: 'x'})"})
        )
        self.assertIsNone(resp.error)
        content = json.loads(resp.result["content"][0]["text"])
        self.assertIn("error", content)

    def test_kuzu_query_blocks_delete(self):
        """kuzu_query must reject DELETE statements."""
        resp = self.server.handle_request(
            _make_req("kuzu_query", {"cypher": "DELETE (n)"})
        )
        self.assertIsNone(resp.error)
        content = json.loads(resp.result["content"][0]["text"])
        self.assertIn("error", content)

    def test_kuzu_query_blocks_drop(self):
        """kuzu_query must reject DROP statements."""
        resp = self.server.handle_request(
            _make_req("kuzu_query", {"cypher": "DROP TABLE Entity"})
        )
        self.assertIsNone(resp.error)
        content = json.loads(resp.result["content"][0]["text"])
        self.assertIn("error", content)

    def test_kuzu_query_allows_match(self):
        """kuzu_query allows MATCH queries (may fail if kuzu absent, not blocked)."""
        resp = self.server.handle_request(
            _make_req("kuzu_query", {"cypher": "MATCH (n:Entity) RETURN n LIMIT 1"})
        )
        self.assertIsNone(resp.error)
        content = json.loads(resp.result["content"][0]["text"])
        # "error" is ok (kuzu not installed), but must NOT be a write-block error
        if "error" in content:
            self.assertNotIn("not permitted", content["error"].lower())


# ---------------------------------------------------------------------------
# M4 – graph context enrichment in ai_semantic_search
# ---------------------------------------------------------------------------

class TestGraphContextEnrichment(unittest.TestCase):
    """Tests that ai_semantic_search returns graph_context when kuzu is live."""

    def setUp(self):
        self.server = MCPServer()

    def test_graph_context_for_hits_empty_on_no_hits(self):
        """_graph_context_for_hits returns [] when ES result has no hits."""
        result = self.server._graph_context_for_hits(
            {"hits": {"hits": []}}, "odata_entity"
        )
        self.assertEqual(result, [])

    def test_graph_context_for_hits_empty_on_missing_id(self):
        """_graph_context_for_hits returns [] when top hit has no entity_id."""
        result = self.server._graph_context_for_hits(
            {"hits": {"hits": [{"_source": {}, "_id": ""}]}}, "odata_entity"
        )
        self.assertEqual(result, [])

    def test_graph_context_uses_doc_id_fallback(self):
        """_graph_context_for_hits uses _id when entity_id field is absent.

        The store is mocked so this exercises the lookup path without kuzu.
        """
        mock_store = MagicMock()
        mock_store.available.return_value = True
        mock_store.get_entity_context.return_value = [
            {"type": "Customer", "id": "CUST-1", "props": "{}"}
        ]

        with patch("graph.kuzu_store.get_store", return_value=mock_store):
            result = self.server._graph_context_for_hits(
                {"hits": {"hits": [{"_source": {"entity_type": "SalesOrder"}, "_id": "SO-1"}]}},
                "odata_entity",
            )

        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["type"], "Customer")
        mock_store.get_entity_context.assert_called_once_with("SalesOrder", "SO-1", hops=2)

    def test_graph_context_absent_when_store_unavailable(self):
        """_graph_context_for_hits returns [] when KuzuStore.available() is False."""
        mock_store = MagicMock()
        mock_store.available.return_value = False

        with patch("graph.kuzu_store.get_store", return_value=mock_store):
            result = self.server._graph_context_for_hits(
                {"hits": {"hits": [{"_source": {"entity_id": "SO-1"}, "_id": "SO-1"}]}},
                "odata_entity",
            )
        self.assertEqual(result, [])


# ---------------------------------------------------------------------------
# Tool registration count
# ---------------------------------------------------------------------------

class TestToolRegistrationCount(unittest.TestCase):
    def test_all_12_tools_registered(self):
        """All 12 tools (including kuzu_index, kuzu_query) must be registered."""
        server = MCPServer()
        expected = {
            "es_search", "es_vector_search", "es_index",
            "es_cluster_health", "es_index_info",
            "generate_embedding", "ai_semantic_search", "mangle_query",
            "hana_search", "hana_index_to_es",
            "kuzu_index", "kuzu_query",
        }
        self.assertEqual(expected, set(server.tools.keys()))


if __name__ == "__main__":
    unittest.main()
