# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
pytest unit tests for KùzuDB Graph-RAG integration in odata-vocabularies MCP server.

Covers:
  - L1: KuzuStore availability / graceful degradation
  - L2: kuzu_index handler logic
  - L3: kuzu_query read-only guard
  - L4: get_rag_context graph-context enrichment
  - Structural: tool registration, schema shape, exports

All tests pass regardless of whether the `kuzu` package is installed;
when absent the store degrades gracefully and tests verify that behaviour.
"""
from __future__ import annotations

import json
import sys
from typing import Any
from unittest.mock import MagicMock, patch

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
        store.ensure_schema()

    def test_run_query_returns_empty_when_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        assert store.run_query("MATCH (v:ODataVocabulary) RETURN v") == []

    def test_get_vocab_terms_returns_empty_when_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        assert store.get_vocab_terms("Common") == []

    def test_get_term_usage_returns_empty_when_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        assert store.get_term_usage("Common.Label") == []

    def test_upsert_vocabulary_no_throw_when_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        store.upsert_vocabulary("Common", "Common", "com.sap.vocabularies.Common.v1", "Common", "stable")

    def test_upsert_term_no_throw_when_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        store.upsert_term("Common.Label", "Label", "String", "Property", "Display label")

    def test_upsert_annotation_target_no_throw_when_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        store.upsert_annotation_target("SalesOrder", "SalesOrder", "com.sap.gateway", "UI")

    def test_link_vocab_term_no_throw_when_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        store.link_vocab_term("Common", "Common.Label")

    def test_link_target_term_no_throw_when_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        store.link_target_term("SalesOrder", "Common.Label")

    def test_link_vocabs_no_throw_when_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        store.link_vocabs("Common", "UI")

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
        assert store._conn.execute.call_count == count1

    def test_upsert_vocabulary_calls_execute(self):
        store = _available_store()
        store.upsert_vocabulary("Common", "Common", "com.sap.vocabularies.Common.v1", "Common", "stable")
        store._conn.execute.assert_called()

    def test_upsert_term_calls_execute(self):
        store = _available_store()
        store.upsert_term("Common.Label", "Label", "String", "Property", "Display label")
        store._conn.execute.assert_called()

    def test_upsert_annotation_target_calls_execute(self):
        store = _available_store()
        store.upsert_annotation_target("SalesOrder", "SalesOrder", "com.sap.gateway", "UI")
        store._conn.execute.assert_called()

    def test_link_vocab_term_calls_execute(self):
        store = _available_store()
        store.link_vocab_term("Common", "Common.Label")
        store._conn.execute.assert_called()

    def test_link_target_term_calls_execute(self):
        store = _available_store()
        store.link_target_term("SalesOrder", "Common.Label")
        store._conn.execute.assert_called()

    def test_link_vocabs_calls_execute(self):
        store = _available_store()
        store.link_vocabs("Common", "UI")
        store._conn.execute.assert_called()

    def test_run_query_returns_rows(self):
        rows = [{"vocabId": "Common", "name": "Common", "relation": "defines_term"}]
        store = _available_store(rows)
        result = store.run_query("MATCH (v:ODataVocabulary) RETURN v.vocabId AS vocabId LIMIT 5")
        assert len(result) == 1
        assert result[0]["vocabId"] == "Common"

    def test_run_query_returns_empty_on_exception(self):
        store = _available_store()
        store._conn.execute.side_effect = RuntimeError("db gone")
        result = store.run_query("MATCH (v:ODataVocabulary) RETURN v")
        assert result == []

    def test_get_vocab_terms_returns_list(self):
        rows = [{"termId": "Common.Label", "name": "Label", "type": "String",
                 "appliesTo": "Property", "description": "Display label", "relation": "defines_term"}]
        store = _available_store(rows)
        ctx = store.get_vocab_terms("Common")
        assert isinstance(ctx, list)

    def test_get_term_usage_returns_list(self):
        rows = [{"targetId": "SalesOrder", "entityType": "SalesOrder",
                 "namespace": "com.sap.gateway", "usedInVocab": "UI", "relation": "annotates"}]
        store = _available_store(rows)
        ctx = store.get_term_usage("Common.Label")
        assert isinstance(ctx, list)


# ---------------------------------------------------------------------------
# 3. kuzu_index handler
# ---------------------------------------------------------------------------

class TestKuzuIndexHandler:
    def _make_server(self, store):
        import mcp_server.server as srv_mod
        srv_mod._kuzu_store_factory = lambda: store
        return srv_mod.MCPServer()

    def teardown_method(self):
        import mcp_server.server as srv_mod
        srv_mod._kuzu_store_factory = None

    def test_indexes_vocabularies(self):
        store = _available_store()
        server = self._make_server(store)
        result = server._handle_kuzu_index({
            "vocabularies": json.dumps([
                {"vocabId": "Common", "name": "Common", "namespace": "com.sap.vocabularies.Common.v1", "alias": "Common", "status": "stable"},
                {"vocabId": "UI", "name": "UI", "namespace": "com.sap.vocabularies.UI.v1", "alias": "UI", "status": "stable"},
            ])
        })
        assert result["vocabs_indexed"] == 2

    def test_indexes_terms(self):
        store = _available_store()
        server = self._make_server(store)
        result = server._handle_kuzu_index({
            "terms": json.dumps([
                {"termId": "Common.Label", "name": "Label", "type": "String", "appliesTo": "Property", "description": "Display label"},
            ])
        })
        assert result["terms_indexed"] == 1

    def test_indexes_annotation_targets(self):
        store = _available_store()
        server = self._make_server(store)
        result = server._handle_kuzu_index({
            "annotation_targets": json.dumps([
                {"targetId": "SalesOrder", "entityType": "SalesOrder", "namespace": "com.sap.gateway", "usedInVocab": "UI"},
                {"targetId": "Customer", "entityType": "Customer", "namespace": "com.sap.gateway", "usedInVocab": "Common"},
            ])
        })
        assert result["targets_indexed"] == 2

    def test_indexes_all_together(self):
        store = _available_store()
        server = self._make_server(store)
        result = server._handle_kuzu_index({
            "vocabularies": json.dumps([{"vocabId": "Common", "name": "Common", "namespace": "com.sap.vocabularies.Common.v1", "alias": "Common", "status": "stable"}]),
            "terms": json.dumps([{"termId": "Common.Label", "name": "Label", "type": "String", "appliesTo": "Property", "description": "Display label", "definingVocab": "Common"}]),
            "annotation_targets": json.dumps([{"targetId": "SalesOrder", "entityType": "SalesOrder", "namespace": "com.sap.gateway", "usedInVocab": "UI", "annotatesTerm": "Common.Label"}]),
        })
        assert result["vocabs_indexed"] == 1
        assert result["terms_indexed"] == 1
        assert result["targets_indexed"] == 1

    def test_skips_vocabularies_with_missing_id(self):
        store = _available_store()
        server = self._make_server(store)
        result = server._handle_kuzu_index({
            "vocabularies": json.dumps([
                {"vocabId": "", "name": "Common"},  # skip
                {"vocabId": "UI", "name": "UI"},    # ok
            ])
        })
        assert result["vocabs_indexed"] == 1

    def test_skips_terms_with_missing_id(self):
        store = _available_store()
        server = self._make_server(store)
        result = server._handle_kuzu_index({
            "terms": json.dumps([
                {"termId": "", "name": "Label"},          # skip
                {"termId": "Common.Label", "name": "Label"},  # ok
            ])
        })
        assert result["terms_indexed"] == 1

    def test_skips_targets_with_missing_id(self):
        store = _available_store()
        server = self._make_server(store)
        result = server._handle_kuzu_index({
            "annotation_targets": json.dumps([
                {"targetId": "", "entityType": "SalesOrder"},      # skip
                {"targetId": "SalesOrder", "entityType": "SalesOrder"},  # ok
            ])
        })
        assert result["targets_indexed"] == 1

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

    def test_related_vocab_link_wired(self):
        store = _available_store()
        server = self._make_server(store)
        server._handle_kuzu_index({
            "vocabularies": json.dumps([
                {"vocabId": "Common", "name": "Common", "namespace": "com.sap.vocabularies.Common.v1", "alias": "Common", "status": "stable", "relatedVocab": "UI"},
            ])
        })
        store._conn.execute.assert_called()

    def test_defines_term_link_wired(self):
        store = _available_store()
        server = self._make_server(store)
        server._handle_kuzu_index({
            "terms": json.dumps([{"termId": "Common.Label", "name": "Label", "type": "String", "appliesTo": "Property", "description": "Display label", "definingVocab": "Common"}]),
        })
        store._conn.execute.assert_called()

    def test_annotates_term_link_wired(self):
        store = _available_store()
        server = self._make_server(store)
        server._handle_kuzu_index({
            "annotation_targets": json.dumps([{"targetId": "SalesOrder", "entityType": "SalesOrder", "namespace": "com.sap.gateway", "usedInVocab": "UI", "annotatesTerm": "Common.Label"}]),
        })
        store._conn.execute.assert_called()


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
        result = server._handle_kuzu_query({"cypher": f"{kw}(v:ODataVocabulary {{vocabId: 'x'}})"})
        assert "error" in result
        assert "not permitted" in result["error"].lower()

    def test_allows_match_statement(self):
        rows = [{"vocabId": "Common", "name": "Common", "relation": "test"}]
        store = _available_store(rows)
        server = self._make_server(store)
        result = server._handle_kuzu_query({"cypher": "MATCH (v:ODataVocabulary) RETURN v.vocabId AS vocabId LIMIT 10"})
        assert "error" not in result
        assert "rows" in result

    def test_returns_row_count(self):
        rows = [{"vocabId": "Common", "name": "Common", "relation": "test"}]
        store = _available_store(rows)
        server = self._make_server(store)
        result = server._handle_kuzu_query({"cypher": "MATCH (v:ODataVocabulary) RETURN v.vocabId AS vocabId"})
        assert result["rowCount"] == 1

    def test_returns_error_when_store_unavailable(self):
        store = _available_store()
        store._available = False
        server = self._make_server(store)
        result = server._handle_kuzu_query({"cypher": "MATCH (v:ODataVocabulary) RETURN v"})
        assert "error" in result

    def test_returns_error_when_factory_none(self):
        import mcp_server.server as srv_mod
        srv_mod._kuzu_store_factory = None
        server = srv_mod.MCPServer()
        result = server._handle_kuzu_query({"cypher": "MATCH (v:ODataVocabulary) RETURN v"})
        assert "error" in result

    def test_allows_match_with_where(self):
        store = _available_store([])
        server = self._make_server(store)
        result = server._handle_kuzu_query({
            "cypher": "MATCH (v:ODataVocabulary) WHERE v.status = 'stable' RETURN v.vocabId AS vocabId"
        })
        assert "error" not in result

    def test_allows_match_with_relationship(self):
        store = _available_store([])
        server = self._make_server(store)
        result = server._handle_kuzu_query({
            "cypher": "MATCH (v:ODataVocabulary)-[:DEFINES_TERM]->(t:VocabularyTerm) RETURN t.name AS name LIMIT 5"
        })
        assert "error" not in result


# ---------------------------------------------------------------------------
# 5. get_rag_context enrichment
# ---------------------------------------------------------------------------

class TestRagContextEnrichment:
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
        result = server._handle_get_rag_context({"query": "what is UI.LineItem"})
        assert "graphContext" not in result

    def test_no_graphcontext_when_store_unavailable(self):
        store = _available_store()
        store._available = False
        server = self._make_server(store)
        result = server._handle_get_rag_context({"query": "what is UI.LineItem"})
        assert "graphContext" not in result

    def test_no_graphcontext_when_context_empty(self):
        store = _available_store([])  # empty rows
        server = self._make_server(store)
        result = server._handle_get_rag_context({"query": "what is a vocabulary term"})
        assert "graphContext" not in result

    def test_graphcontext_present_when_rows_returned(self):
        rows = [{"termId": "UI.LineItem", "name": "LineItem", "type": "Collection",
                 "appliesTo": "EntitySet", "description": "Table columns", "relation": "defines_term"}]
        store = _available_store(rows)
        server = self._make_server(store)
        # "ui" keyword triggers relevant_vocabs to include "UI"
        result = server._handle_get_rag_context({"query": "ui display table list"})
        assert "graphContext" in result
        assert isinstance(result["graphContext"], list)
        assert len(result["graphContext"]) >= 1

    def test_rag_context_contains_query(self):
        store = _available_store([])
        server = self._make_server(store)
        result = server._handle_get_rag_context({"query": "odata annotation term"})
        assert result["query"] == "odata annotation term"


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
            "upsert_vocabulary", "upsert_term", "upsert_annotation_target",
            "link_vocab_term", "link_target_term", "link_vocabs",
            "run_query", "get_vocab_terms", "get_term_usage",
        ]
        for m in methods:
            assert callable(getattr(store, m)), f"Missing method: {m}"

    def test_server_registers_kuzu_index_tool(self):
        server = self._make_server()
        assert "kuzu_index" in server.tools

    def test_server_registers_kuzu_query_tool(self):
        server = self._make_server()
        assert "kuzu_query" in server.tools

    def test_kuzu_index_schema_has_vocabularies_property(self):
        server = self._make_server()
        schema = server.tools["kuzu_index"]["inputSchema"]
        assert "vocabularies" in schema["properties"]

    def test_kuzu_index_schema_has_terms_property(self):
        server = self._make_server()
        schema = server.tools["kuzu_index"]["inputSchema"]
        assert "terms" in schema["properties"]

    def test_kuzu_index_schema_has_annotation_targets_property(self):
        server = self._make_server()
        schema = server.tools["kuzu_index"]["inputSchema"]
        assert "annotation_targets" in schema["properties"]

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
        assert resp_dict.get("error") is None
        content_text = resp_dict["result"]["content"][0]["text"]
        content = json.loads(content_text)
        assert "error" in content
