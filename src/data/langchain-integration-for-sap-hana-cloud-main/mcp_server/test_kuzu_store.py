# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
pytest unit tests for KùzuDB Graph-RAG integration in langchain-hana MCP server.

Covers:
  - L1: KuzuStore availability / graceful degradation
  - L2: kuzu_index handler logic
  - L3: kuzu_query read-only guard
  - L4: langchain_rag_chain graph-context enrichment
  - Structural: tool registration, schema shape, exports

All tests pass regardless of whether the `kuzu` package is installed;
when absent the store degrades gracefully and tests verify that behaviour.
"""
from __future__ import annotations

import json
import sys
import types
from typing import Any
from unittest.mock import MagicMock, patch, call

import pytest

# ---------------------------------------------------------------------------
# Helpers to build a fake kuzu connection / result
# ---------------------------------------------------------------------------

def _make_result(rows: list[dict]) -> MagicMock:
    cols = list(rows[0].keys()) if rows else []
    idx_box = [0]

    result = MagicMock()
    result.get_column_names.return_value = cols
    result.has_next.side_effect = lambda: idx_box[0] < len(rows)

    def _get_next():
        row = rows[idx_box[0]]
        idx_box[0] += 1
        return [row[c] for c in cols]

    result.get_next.side_effect = _get_next
    return result


def _make_conn(rows: list[dict] | None = None) -> MagicMock:
    conn = MagicMock()
    conn.execute.return_value = _make_result(rows or [])
    return conn


def _available_store(rows: list[dict] | None = None):
    """Return a KuzuStore instance with a mocked connection."""
    from mcp_server.kuzu_store import KuzuStore
    store = object.__new__(KuzuStore)
    store._db_path = ":memory:"
    store._db = MagicMock()
    store._conn = _make_conn(rows or [])
    store._available = True
    store._schema_ready = False
    return store


# ---------------------------------------------------------------------------
# 1. Availability / graceful degradation
# ---------------------------------------------------------------------------

class TestKuzuStoreAvailability:
    def setup_method(self):
        from mcp_server import kuzu_store
        kuzu_store._reset_kuzu_store()

    def teardown_method(self):
        from mcp_server import kuzu_store
        kuzu_store._reset_kuzu_store()

    def test_available_returns_bool(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        assert isinstance(store.available(), bool)

    def test_ensure_schema_no_throw_when_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        store.ensure_schema()  # must not raise

    def test_run_query_returns_empty_when_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        assert store.run_query("MATCH (s:HanaVectorStore) RETURN s") == []

    def test_get_store_context_returns_empty_when_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        assert store.get_store_context("vs-01") == []

    def test_get_schema_context_returns_empty_when_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        assert store.get_schema_context("sch-01") == []

    def test_upsert_vector_store_no_throw_when_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        store.upsert_vector_store("vs-01", "EMBEDDINGS", "text-ada-002", "PUBLIC")

    def test_upsert_deployment_no_throw_when_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        store.upsert_deployment("dep-001", "text-ada-002", "default", "RUNNING")

    def test_upsert_schema_no_throw_when_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        store.upsert_schema("sch-01", "PUBLIC", "public")

    def test_link_store_deployment_no_throw_when_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        store.link_store_deployment("vs-01", "dep-001")

    def test_link_store_schema_no_throw_when_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        store.link_store_schema("vs-01", "sch-01")

    def test_link_schemas_no_throw_when_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        store.link_schemas("sch-01", "sch-02")

    def test_singleton_returns_same_instance(self):
        from mcp_server.kuzu_store import get_kuzu_store
        a = get_kuzu_store()
        b = get_kuzu_store()
        assert a is b

    def test_reset_creates_new_singleton(self):
        from mcp_server.kuzu_store import get_kuzu_store, _reset_kuzu_store
        a = get_kuzu_store()
        _reset_kuzu_store()
        b = get_kuzu_store()
        assert a is not b


# ---------------------------------------------------------------------------
# 2. With mock connection (available store)
# ---------------------------------------------------------------------------

class TestKuzuStoreWithMock:
    def test_available_true_with_mock(self):
        store = _available_store()
        assert store.available() is True

    def test_ensure_schema_calls_execute(self):
        store = _available_store()
        store.ensure_schema()
        assert store._conn.execute.call_count > 0

    def test_ensure_schema_is_idempotent(self):
        store = _available_store()
        store.ensure_schema()
        count1 = store._conn.execute.call_count
        store.ensure_schema()
        assert store._conn.execute.call_count == count1  # no extra calls

    def test_upsert_vector_store_calls_execute(self):
        store = _available_store()
        store.upsert_vector_store("vs-01", "EMBEDDINGS", "ada-002", "PUBLIC")
        store._conn.execute.assert_called()

    def test_upsert_deployment_calls_execute(self):
        store = _available_store()
        store.upsert_deployment("dep-001", "ada-002", "default", "RUNNING")
        store._conn.execute.assert_called()

    def test_upsert_schema_calls_execute(self):
        store = _available_store()
        store.upsert_schema("sch-01", "PUBLIC", "public")
        store._conn.execute.assert_called()

    def test_link_store_deployment_calls_execute(self):
        store = _available_store()
        store.link_store_deployment("vs-01", "dep-001")
        store._conn.execute.assert_called()

    def test_link_store_schema_calls_execute(self):
        store = _available_store()
        store.link_store_schema("vs-01", "sch-01")
        store._conn.execute.assert_called()

    def test_link_schemas_calls_execute(self):
        store = _available_store()
        store.link_schemas("sch-01", "sch-02")
        store._conn.execute.assert_called()

    def test_run_query_returns_rows(self):
        rows = [{"storeId": "vs-01", "tableName": "EMBEDDINGS", "relation": "lives_in"}]
        store = _available_store(rows)
        result = store.run_query("MATCH (s:HanaVectorStore) RETURN s.storeId AS storeId LIMIT 5")
        assert len(result) == 1
        assert result[0]["storeId"] == "vs-01"

    def test_run_query_returns_empty_on_exception(self):
        store = _available_store()
        store._conn.execute.side_effect = RuntimeError("db gone")
        result = store.run_query("MATCH (s:HanaVectorStore) RETURN s")
        assert result == []

    def test_get_store_context_returns_list(self):
        rows = [{"deploymentId": "dep-001", "modelName": "ada-002",
                 "resourceGroup": "default", "status": "RUNNING", "relation": "uses_deployment"}]
        store = _available_store(rows)
        ctx = store.get_store_context("vs-01")
        assert isinstance(ctx, list)

    def test_get_schema_context_returns_list(self):
        rows = [{"storeId": "vs-01", "tableName": "EMBEDDINGS",
                 "embeddingModel": "ada-002", "relation": "lives_in"}]
        store = _available_store(rows)
        ctx = store.get_schema_context("sch-01")
        assert isinstance(ctx, list)


# ---------------------------------------------------------------------------
# 3. kuzu_index handler
# ---------------------------------------------------------------------------

class TestKuzuIndexHandler:
    """Tests for MCPServer._handle_kuzu_index via direct method call."""

    def _make_server(self, store):
        """Patch _kuzu_store_factory at the module level and return a fresh MCPServer."""
        import importlib
        import mcp_server.server as srv_mod
        srv_mod._kuzu_store_factory = lambda: store
        return srv_mod.MCPServer()

    def teardown_method(self):
        import mcp_server.server as srv_mod
        # restore to None so other tests are clean
        srv_mod._kuzu_store_factory = None

    def test_indexes_deployments(self):
        store = _available_store()
        server = self._make_server(store)
        result = server._handle_kuzu_index({
            "deployments": json.dumps([
                {"deploymentId": "dep-001", "modelName": "ada-002", "resourceGroup": "default", "status": "RUNNING"},
                {"deploymentId": "dep-002", "modelName": "gpt-4", "resourceGroup": "prod", "status": "RUNNING"},
            ])
        })
        assert result["deployments_indexed"] == 2

    def test_indexes_schemas(self):
        store = _available_store()
        server = self._make_server(store)
        result = server._handle_kuzu_index({
            "schemas": json.dumps([
                {"schemaId": "sch-pub", "schemaName": "PUBLIC", "classification": "public"},
            ])
        })
        assert result["schemas_indexed"] == 1

    def test_indexes_vector_stores(self):
        store = _available_store()
        server = self._make_server(store)
        result = server._handle_kuzu_index({
            "vector_stores": json.dumps([
                {"storeId": "vs-01", "tableName": "EMBEDDINGS", "embeddingModel": "ada-002", "schema": "PUBLIC"},
                {"storeId": "vs-02", "tableName": "DOCS", "embeddingModel": "ada-002", "schema": "PUBLIC"},
            ])
        })
        assert result["stores_indexed"] == 2

    def test_indexes_all_together(self):
        store = _available_store()
        server = self._make_server(store)
        result = server._handle_kuzu_index({
            "deployments": json.dumps([{"deploymentId": "dep-001", "modelName": "ada-002", "resourceGroup": "default", "status": "RUNNING"}]),
            "schemas": json.dumps([{"schemaId": "sch-pub", "schemaName": "PUBLIC", "classification": "public"}]),
            "vector_stores": json.dumps([{"storeId": "vs-01", "tableName": "EMBEDDINGS", "embeddingModel": "ada-002", "schema": "PUBLIC",
                                          "usesDeployment": "dep-001", "livesIn": "sch-pub"}]),
        })
        assert result["deployments_indexed"] == 1
        assert result["schemas_indexed"] == 1
        assert result["stores_indexed"] == 1

    def test_skips_deployments_with_missing_id(self):
        store = _available_store()
        server = self._make_server(store)
        result = server._handle_kuzu_index({
            "deployments": json.dumps([
                {"deploymentId": "", "modelName": "ada-002"},   # skip
                {"deploymentId": "dep-001", "modelName": "ada-002"},  # ok
            ])
        })
        assert result["deployments_indexed"] == 1

    def test_skips_schemas_with_missing_id(self):
        store = _available_store()
        server = self._make_server(store)
        result = server._handle_kuzu_index({
            "schemas": json.dumps([
                {"schemaId": "", "schemaName": "PUBLIC"},   # skip
                {"schemaId": "sch-pub", "schemaName": "PUBLIC"},  # ok
            ])
        })
        assert result["schemas_indexed"] == 1

    def test_skips_vector_stores_with_missing_id(self):
        store = _available_store()
        server = self._make_server(store)
        result = server._handle_kuzu_index({
            "vector_stores": json.dumps([
                {"storeId": "", "tableName": "EMBEDDINGS"},  # skip
                {"storeId": "vs-01", "tableName": "EMBEDDINGS"},  # ok
            ])
        })
        assert result["stores_indexed"] == 1

    def test_returns_error_when_store_unavailable(self):
        store = _available_store()
        store._available = False
        server = self._make_server(store)
        result = server._handle_kuzu_index({})
        assert "error" in result

    def test_returns_error_when_factory_none(self):
        import mcp_server.server as srv_mod
        srv_mod._kuzu_store_factory = None
        server = srv_mod.MCPServer()
        result = server._handle_kuzu_index({})
        assert "error" in result


# ---------------------------------------------------------------------------
# 4. kuzu_query handler
# ---------------------------------------------------------------------------

DISALLOWED_PREFIXES = ["CREATE ", "MERGE ", "DELETE ", "SET ", "REMOVE ", "DROP "]


class TestKuzuQueryHandler:
    def _make_server(self, store):
        import mcp_server.server as srv_mod
        srv_mod._kuzu_store_factory = lambda: store
        return srv_mod.MCPServer()

    def teardown_method(self):
        import mcp_server.server as srv_mod
        srv_mod._kuzu_store_factory = None

    def test_returns_error_for_empty_cypher(self):
        store = _available_store()
        server = self._make_server(store)
        result = server._handle_kuzu_query({"cypher": ""})
        assert "error" in result

    @pytest.mark.parametrize("kw", DISALLOWED_PREFIXES)
    def test_blocks_write_statement(self, kw):
        store = _available_store()
        server = self._make_server(store)
        result = server._handle_kuzu_query({"cypher": f"{kw}(s:HanaVectorStore {{storeId: 'x'}})"})
        assert "error" in result
        assert "not permitted" in result["error"].lower()

    def test_allows_match_statement(self):
        rows = [{"storeId": "vs-01", "tableName": "EMBEDDINGS", "relation": "test"}]
        store = _available_store(rows)
        server = self._make_server(store)
        result = server._handle_kuzu_query({"cypher": "MATCH (s:HanaVectorStore) RETURN s.storeId AS storeId LIMIT 10"})
        assert "error" not in result
        assert "rows" in result

    def test_returns_row_count(self):
        rows = [{"storeId": "vs-01", "tableName": "EMBEDDINGS", "relation": "test"}]
        store = _available_store(rows)
        server = self._make_server(store)
        result = server._handle_kuzu_query({"cypher": "MATCH (s:HanaVectorStore) RETURN s.storeId AS storeId"})
        assert result["rowCount"] == 1

    def test_returns_error_when_store_unavailable(self):
        store = _available_store()
        store._available = False
        server = self._make_server(store)
        result = server._handle_kuzu_query({"cypher": "MATCH (s:HanaVectorStore) RETURN s"})
        assert "error" in result

    def test_returns_error_when_factory_none(self):
        import mcp_server.server as srv_mod
        srv_mod._kuzu_store_factory = None
        server = srv_mod.MCPServer()
        result = server._handle_kuzu_query({"cypher": "MATCH (s:HanaVectorStore) RETURN s"})
        assert "error" in result

    def test_allows_match_with_where(self):
        store = _available_store([])
        server = self._make_server(store)
        result = server._handle_kuzu_query({
            "cypher": "MATCH (s:HanaVectorStore) WHERE s.schema = 'PUBLIC' RETURN s.storeId AS storeId"
        })
        assert "error" not in result


# ---------------------------------------------------------------------------
# 5. langchain_rag_chain enrichment
# ---------------------------------------------------------------------------

class TestRagChainEnrichment:
    def teardown_method(self):
        import mcp_server.server as srv_mod
        srv_mod._kuzu_store_factory = None

    def _make_server(self, store):
        import mcp_server.server as srv_mod
        srv_mod._kuzu_store_factory = lambda: store
        return srv_mod.MCPServer()

    def test_no_graphcontext_when_factory_none(self):
        import mcp_server.server as srv_mod
        srv_mod._kuzu_store_factory = None
        server = srv_mod.MCPServer()
        result = server._handle_langchain_rag_chain({"query": "test query", "table_name": "EMBEDDINGS"})
        assert "graphContext" not in result

    def test_no_graphcontext_when_store_unavailable(self):
        store = _available_store()
        store._available = False
        server = self._make_server(store)
        result = server._handle_langchain_rag_chain({"query": "test query", "table_name": "EMBEDDINGS"})
        assert "graphContext" not in result

    def test_no_graphcontext_when_context_empty(self):
        store = _available_store([])  # empty rows
        server = self._make_server(store)
        result = server._handle_langchain_rag_chain({"query": "test query", "table_name": "EMBEDDINGS"})
        assert "graphContext" not in result

    def test_graphcontext_present_when_rows_returned(self):
        rows = [{"deploymentId": "dep-001", "modelName": "ada-002",
                 "resourceGroup": "default", "status": "RUNNING", "relation": "uses_deployment"}]
        store = _available_store(rows)
        server = self._make_server(store)
        result = server._handle_langchain_rag_chain({"query": "test query", "table_name": "EMBEDDINGS"})
        assert "graphContext" in result
        assert isinstance(result["graphContext"], list)
        assert len(result["graphContext"]) == 1

    def test_rag_chain_returns_error_for_missing_args(self):
        import mcp_server.server as srv_mod
        srv_mod._kuzu_store_factory = None
        server = srv_mod.MCPServer()
        result = server._handle_langchain_rag_chain({"query": "", "table_name": ""})
        assert "error" in result


# ---------------------------------------------------------------------------
# 6. Structural tests
# ---------------------------------------------------------------------------

class TestStructural:
    def teardown_method(self):
        import mcp_server.server as srv_mod
        srv_mod._kuzu_store_factory = None

    def _make_server(self):
        import mcp_server.server as srv_mod
        srv_mod._kuzu_store_factory = lambda: _available_store()
        return srv_mod.MCPServer()

    def test_kuzu_store_exports_required_symbols(self):
        from mcp_server import kuzu_store
        assert callable(kuzu_store.KuzuStore)
        assert callable(kuzu_store.get_kuzu_store)
        assert callable(kuzu_store._reset_kuzu_store)

    def test_kuzu_store_has_required_methods(self):
        from mcp_server.kuzu_store import KuzuStore
        store = object.__new__(KuzuStore)
        store._available = False
        store._conn = None
        store._schema_ready = False
        methods = [
            "available", "ensure_schema",
            "upsert_vector_store", "upsert_deployment", "upsert_schema",
            "link_store_deployment", "link_store_schema", "link_schemas",
            "run_query", "get_store_context", "get_schema_context",
        ]
        for m in methods:
            assert callable(getattr(store, m)), f"Missing method: {m}"

    def test_server_registers_kuzu_index_tool(self):
        server = self._make_server()
        assert "kuzu_index" in server.tools

    def test_server_registers_kuzu_query_tool(self):
        server = self._make_server()
        assert "kuzu_query" in server.tools

    def test_kuzu_index_schema_has_vector_stores_property(self):
        server = self._make_server()
        schema = server.tools["kuzu_index"]["inputSchema"]
        assert "vector_stores" in schema["properties"]

    def test_kuzu_index_schema_has_deployments_property(self):
        server = self._make_server()
        schema = server.tools["kuzu_index"]["inputSchema"]
        assert "deployments" in schema["properties"]

    def test_kuzu_index_schema_has_schemas_property(self):
        server = self._make_server()
        schema = server.tools["kuzu_index"]["inputSchema"]
        assert "schemas" in schema["properties"]

    def test_kuzu_query_requires_cypher(self):
        server = self._make_server()
        schema = server.tools["kuzu_query"]["inputSchema"]
        assert "cypher" in schema.get("required", [])

    def test_kuzu_index_description_mentions_kuzudb(self):
        server = self._make_server()
        desc = server.tools["kuzu_index"]["description"]
        assert "kuzu" in desc.lower() or "K\u00f9zu" in desc

    def test_kuzu_query_description_mentions_kuzudb(self):
        server = self._make_server()
        desc = server.tools["kuzu_query"]["description"]
        assert "kuzu" in desc.lower() or "K\u00f9zu" in desc

    def test_handle_kuzu_index_method_exists(self):
        server = self._make_server()
        assert callable(getattr(server, "_handle_kuzu_index", None))

    def test_handle_kuzu_query_method_exists(self):
        server = self._make_server()
        assert callable(getattr(server, "_handle_kuzu_query", None))

    def test_kuzu_index_in_handlers_dispatch(self):
        """kuzu_index should be routed by handle_request tools/call."""
        store = _available_store()
        server = self._make_server()
        from mcp_server.server import MCPRequest
        req = MCPRequest({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": "kuzu_index", "arguments": {}},
        })
        response = server.handle_request(req)
        resp_dict = response.to_dict()
        # Should not return "Unknown tool" error
        assert resp_dict.get("error") is None or "Unknown tool" not in str(resp_dict.get("error", ""))

    def test_kuzu_query_in_handlers_dispatch(self):
        """kuzu_query with empty cypher should return an error dict, not Unknown tool."""
        server = self._make_server()
        from mcp_server.server import MCPRequest
        req = MCPRequest({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {"name": "kuzu_query", "arguments": {"cypher": ""}},
        })
        response = server.handle_request(req)
        resp_dict = response.to_dict()
        assert resp_dict.get("error") is None  # handled, not unknown-tool error
        # Result content should contain our "cypher is required" error
        content_text = resp_dict["result"]["content"][0]["text"]
        content = json.loads(content_text)
        assert "error" in content
