# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
pytest unit tests for KùzuDB / HippoCPP Graph-RAG integration in mangle-query-service.

Covers:
  - M1: KuzuStore availability / graceful degradation (hippocpp or kuzu)
  - M2: kuzu_index handler (resolution paths, data sources, categories, backends)
  - M2: kuzu_query handler (read-only guard, routing)
  - M3: hana_vector_search / hana_mmr_search graph context enrichment
  - Structural: tool registration, schema shape, exports, dispatch routing

All tests pass regardless of whether hippocpp/kuzu is installed; when absent
the store degrades gracefully and tests verify that behaviour.
"""
from __future__ import annotations

import json
import sys
import os
import asyncio
from typing import Any
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Path helpers so tests can import from mcp_server/
# ---------------------------------------------------------------------------

_ROOT = os.path.dirname(os.path.dirname(__file__))
_MCP_SERVER = os.path.join(_ROOT, "mcp_server")
if _MCP_SERVER not in sys.path:
    sys.path.insert(0, _MCP_SERVER)
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)


# ---------------------------------------------------------------------------
# Fake kuzu result / connection helpers
# ---------------------------------------------------------------------------

def _make_result(rows: list[dict]) -> MagicMock:
    cols = list(rows[0].keys()) if rows else []
    idx = [0]
    r = MagicMock()
    r.get_column_names.return_value = cols
    r.has_next.side_effect = lambda: idx[0] < len(rows)

    def _get_next():
        row = rows[idx[0]]
        idx[0] += 1
        return [row[c] for c in cols]

    r.get_next.side_effect = _get_next
    return r


def _make_conn(rows: list[dict] | None = None) -> MagicMock:
    conn = MagicMock()
    conn.execute.return_value = _make_result(rows or [])
    return conn


def _available_store(rows: list[dict] | None = None):
    from mcp_server.kuzu_store import KuzuStore
    store = object.__new__(KuzuStore)
    store._db_path = ":memory:"
    store._db = MagicMock()
    store._conn = _make_conn(rows or [])
    store._available = True
    store._schema_ready = False
    return store


# ---------------------------------------------------------------------------
# Async helpers
# ---------------------------------------------------------------------------

def run(coro):
    return asyncio.run(coro)


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

    def test_run_query_empty_when_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        assert store.run_query("MATCH (p:ResolutionPath) RETURN p") == []

    def test_get_paths_for_source_empty_when_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        assert store.get_paths_for_source("ACDOCA") == []

    def test_get_paths_for_category_empty_when_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        assert store.get_paths_for_category("RAG_RETRIEVAL") == []

    def test_get_backends_for_path_empty_when_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        assert store.get_backends_for_path("rag") == []

    def test_upsert_resolution_path_no_throw_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        store.upsert_resolution_path("rag", "RAG", 6, 85, "RAG retrieval path")

    def test_upsert_data_source_no_throw_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        store.upsert_data_source("ACDOCA", "ACDOCA", "hana", "ACDOCA", "SAPHANADB")

    def test_upsert_query_category_no_throw_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        store.upsert_query_category("RAG_RETRIEVAL", "RAG Retrieval", 70, "Knowledge query")

    def test_upsert_model_backend_no_throw_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        store.upsert_model_backend("aicore_primary", "AI Core Primary", "sap_ai_core", 100, 60)

    def test_link_source_path_no_throw_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        store.link_source_path("ACDOCA", "rag")

    def test_link_category_path_no_throw_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        store.link_category_path("RAG_RETRIEVAL", "rag")

    def test_link_path_backend_no_throw_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        store.link_path_backend("rag", "aicore_primary")

    def test_link_paths_no_throw_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        store.link_paths("llm", "llm_fallback")

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
    def test_available_true(self):
        store = _available_store()
        assert store.available() is True

    def test_ensure_schema_calls_execute(self):
        store = _available_store()
        store.ensure_schema()
        assert store._conn.execute.call_count > 0

    def test_ensure_schema_idempotent(self):
        store = _available_store()
        store.ensure_schema()
        count1 = store._conn.execute.call_count
        store.ensure_schema()
        assert store._conn.execute.call_count == count1

    def test_upsert_resolution_path_calls_execute(self):
        store = _available_store()
        store.upsert_resolution_path("rag", "RAG", 6, 85, "RAG retrieval")
        store._conn.execute.assert_called()

    def test_upsert_data_source_calls_execute(self):
        store = _available_store()
        store.upsert_data_source("ACDOCA", "ACDOCA", "hana", "ACDOCA", "SAPHANADB")
        store._conn.execute.assert_called()

    def test_upsert_query_category_calls_execute(self):
        store = _available_store()
        store.upsert_query_category("RAG_RETRIEVAL", "RAG Retrieval", 70, "Knowledge query")
        store._conn.execute.assert_called()

    def test_upsert_model_backend_calls_execute(self):
        store = _available_store()
        store.upsert_model_backend("aicore_primary", "AI Core Primary", "sap_ai_core", 100, 60)
        store._conn.execute.assert_called()

    def test_link_source_path_calls_execute(self):
        store = _available_store()
        store.link_source_path("ACDOCA", "rag")
        store._conn.execute.assert_called()

    def test_link_category_path_calls_execute(self):
        store = _available_store()
        store.link_category_path("RAG_RETRIEVAL", "rag")
        store._conn.execute.assert_called()

    def test_link_path_backend_calls_execute(self):
        store = _available_store()
        store.link_path_backend("rag", "aicore_primary")
        store._conn.execute.assert_called()

    def test_link_paths_calls_execute(self):
        store = _available_store()
        store.link_paths("llm", "llm_fallback")
        store._conn.execute.assert_called()

    def test_run_query_returns_rows(self):
        rows = [{"pathId": "rag", "name": "RAG", "priority": 6, "score": 85,
                 "description": "RAG retrieval", "relation": "resolves_via"}]
        store = _available_store(rows)
        result = store.run_query("MATCH (p:ResolutionPath) RETURN p.pathId AS pathId LIMIT 5")
        assert len(result) == 1
        assert result[0]["pathId"] == "rag"

    def test_run_query_empty_on_exception(self):
        store = _available_store()
        store._conn.execute.side_effect = RuntimeError("db error")
        assert store.run_query("MATCH (p:ResolutionPath) RETURN p") == []

    def test_get_paths_for_source_returns_list(self):
        rows = [{"pathId": "rag", "name": "RAG", "priority": 6, "score": 85,
                 "description": "RAG", "relation": "resolves_via"}]
        store = _available_store(rows)
        result = store.get_paths_for_source("ACDOCA")
        assert isinstance(result, list)

    def test_get_paths_for_category_returns_list(self):
        rows = [{"pathId": "rag", "name": "RAG", "priority": 6, "score": 85,
                 "description": "RAG", "relation": "classifies_to"}]
        store = _available_store(rows)
        result = store.get_paths_for_category("RAG_RETRIEVAL")
        assert isinstance(result, list)

    def test_get_backends_for_path_returns_list(self):
        rows = [{"backendId": "aicore_primary", "name": "AI Core", "provider": "sap_ai_core",
                 "priority": 100, "timeout_s": 60, "relation": "served_by"}]
        store = _available_store(rows)
        result = store.get_backends_for_path("rag")
        assert isinstance(result, list)


# ---------------------------------------------------------------------------
# 3. kuzu_index handler
# ---------------------------------------------------------------------------

class TestKuzuIndexHandler:
    def _make_server(self, store):
        import mcp_server.langchain_hana_mcp as srv_mod
        srv_mod._kuzu_store_factory = lambda: store
        server = srv_mod.LangChainHanaMCPServer()
        server._initialized = True
        server._bridge = MagicMock()
        return server

    def teardown_method(self):
        import mcp_server.langchain_hana_mcp as srv_mod
        srv_mod._kuzu_store_factory = None

    def test_indexes_resolution_paths(self):
        store = _available_store()
        server = self._make_server(store)
        result = run(server._handle_kuzu_index({
            "resolution_paths": json.dumps([
                {"pathId": "rag", "name": "RAG", "priority": 6, "score": 85, "description": "RAG retrieval"},
                {"pathId": "cache", "name": "Cache", "priority": 1, "score": 100, "description": "Semantic cache"},
            ])
        }))
        assert result["paths_indexed"] == 2

    def test_indexes_model_backends(self):
        store = _available_store()
        server = self._make_server(store)
        result = run(server._handle_kuzu_index({
            "model_backends": json.dumps([
                {"backendId": "aicore_primary", "name": "AI Core", "provider": "sap_ai_core", "priority": 100, "timeout_s": 60},
                {"backendId": "vllm_primary", "name": "vLLM", "provider": "vllm", "priority": 90, "timeout_s": 120},
            ])
        }))
        assert result["backends_indexed"] == 2

    def test_indexes_data_sources(self):
        store = _available_store()
        server = self._make_server(store)
        result = run(server._handle_kuzu_index({
            "data_sources": json.dumps([
                {"sourceId": "ACDOCA", "name": "ACDOCA", "sourceType": "hana", "table_name": "ACDOCA", "schema_name": "SAPHANADB"},
                {"sourceId": "VBAK", "name": "VBAK", "sourceType": "hana", "table_name": "VBAK", "schema_name": "SAPHANADB"},
            ])
        }))
        assert result["sources_indexed"] == 2

    def test_indexes_query_categories(self):
        store = _available_store()
        server = self._make_server(store)
        result = run(server._handle_kuzu_index({
            "query_categories": json.dumps([
                {"categoryId": "RAG_RETRIEVAL", "name": "RAG Retrieval", "confidence": 70, "description": "Knowledge query"},
                {"categoryId": "FACTUAL", "name": "Factual", "confidence": 70, "description": "Entity lookup"},
            ])
        }))
        assert result["categories_indexed"] == 2

    def test_indexes_all_together(self):
        store = _available_store()
        server = self._make_server(store)
        result = run(server._handle_kuzu_index({
            "model_backends": json.dumps([{"backendId": "aicore_primary", "name": "AI Core", "provider": "sap_ai_core", "priority": 100, "timeout_s": 60}]),
            "resolution_paths": json.dumps([{"pathId": "rag", "name": "RAG", "priority": 6, "score": 85, "description": "RAG", "servedBy": "aicore_primary"}]),
            "data_sources": json.dumps([{"sourceId": "ACDOCA", "name": "ACDOCA", "sourceType": "hana", "table_name": "ACDOCA", "schema_name": "SAPHANADB", "resolvesVia": "rag"}]),
            "query_categories": json.dumps([{"categoryId": "RAG_RETRIEVAL", "name": "RAG Retrieval", "confidence": 70, "description": "Knowledge", "classifiesTo": "rag"}]),
        }))
        assert result["paths_indexed"] == 1
        assert result["sources_indexed"] == 1
        assert result["categories_indexed"] == 1
        assert result["backends_indexed"] == 1

    def test_skips_paths_with_missing_id(self):
        store = _available_store()
        server = self._make_server(store)
        result = run(server._handle_kuzu_index({
            "resolution_paths": json.dumps([
                {"pathId": "", "name": "Empty"},   # skip
                {"pathId": "rag", "name": "RAG"},  # ok
            ])
        }))
        assert result["paths_indexed"] == 1

    def test_skips_sources_with_missing_id(self):
        store = _available_store()
        server = self._make_server(store)
        result = run(server._handle_kuzu_index({
            "data_sources": json.dumps([
                {"sourceId": "", "name": "Empty"},        # skip
                {"sourceId": "ACDOCA", "name": "ACDOCA"}, # ok
            ])
        }))
        assert result["sources_indexed"] == 1

    def test_skips_categories_with_missing_id(self):
        store = _available_store()
        server = self._make_server(store)
        result = run(server._handle_kuzu_index({
            "query_categories": json.dumps([
                {"categoryId": "", "name": "Empty"},             # skip
                {"categoryId": "FACTUAL", "name": "Factual"},    # ok
            ])
        }))
        assert result["categories_indexed"] == 1

    def test_skips_backends_with_missing_id(self):
        store = _available_store()
        server = self._make_server(store)
        result = run(server._handle_kuzu_index({
            "model_backends": json.dumps([
                {"backendId": "", "name": "Empty"},                     # skip
                {"backendId": "aicore_primary", "name": "AI Core"},     # ok
            ])
        }))
        assert result["backends_indexed"] == 1

    def test_error_when_store_unavailable(self):
        store = _available_store()
        store._available = False
        server = self._make_server(store)
        result = run(server._handle_kuzu_index({}))
        assert "error" in result

    def test_error_when_factory_none(self):
        import mcp_server.langchain_hana_mcp as srv_mod
        srv_mod._kuzu_store_factory = None
        server = srv_mod.LangChainHanaMCPServer()
        server._initialized = True
        server._bridge = MagicMock()
        result = run(server._handle_kuzu_index({}))
        assert "error" in result

    def test_served_by_link_wired(self):
        store = _available_store()
        server = self._make_server(store)
        run(server._handle_kuzu_index({
            "resolution_paths": json.dumps([{"pathId": "rag", "name": "RAG", "servedBy": "aicore_primary"}]),
        }))
        store._conn.execute.assert_called()

    def test_related_path_link_wired(self):
        store = _available_store()
        server = self._make_server(store)
        run(server._handle_kuzu_index({
            "resolution_paths": json.dumps([{"pathId": "llm", "name": "LLM", "relatedPath": "llm_fallback"}]),
        }))
        store._conn.execute.assert_called()

    def test_resolves_via_link_wired(self):
        store = _available_store()
        server = self._make_server(store)
        run(server._handle_kuzu_index({
            "data_sources": json.dumps([{"sourceId": "ACDOCA", "name": "ACDOCA", "resolvesVia": "rag"}]),
        }))
        store._conn.execute.assert_called()

    def test_classifies_to_link_wired(self):
        store = _available_store()
        server = self._make_server(store)
        run(server._handle_kuzu_index({
            "query_categories": json.dumps([{"categoryId": "RAG_RETRIEVAL", "name": "RAG", "classifiesTo": "rag"}]),
        }))
        store._conn.execute.assert_called()


# ---------------------------------------------------------------------------
# 4. kuzu_query handler
# ---------------------------------------------------------------------------

DISALLOWED = ["CREATE ", "MERGE ", "DELETE ", "SET ", "REMOVE ", "DROP "]


class TestKuzuQueryHandler:
    def _make_server(self, store):
        import mcp_server.langchain_hana_mcp as srv_mod
        srv_mod._kuzu_store_factory = lambda: store
        server = srv_mod.LangChainHanaMCPServer()
        server._initialized = True
        server._bridge = MagicMock()
        return server

    def teardown_method(self):
        import mcp_server.langchain_hana_mcp as srv_mod
        srv_mod._kuzu_store_factory = None

    def test_error_for_empty_cypher(self):
        store = _available_store()
        server = self._make_server(store)
        result = run(server._handle_kuzu_query({"cypher": ""}))
        assert "error" in result

    @pytest.mark.parametrize("kw", DISALLOWED)
    def test_blocks_write_statements(self, kw):
        store = _available_store()
        server = self._make_server(store)
        result = run(server._handle_kuzu_query({"cypher": f"{kw}(p:ResolutionPath {{pathId: 'x'}})"}))
        assert "error" in result
        assert "not permitted" in result["error"].lower()

    def test_allows_match_statement(self):
        rows = [{"pathId": "rag", "name": "RAG"}]
        store = _available_store(rows)
        server = self._make_server(store)
        result = run(server._handle_kuzu_query({"cypher": "MATCH (p:ResolutionPath) RETURN p.pathId AS pathId LIMIT 5"}))
        assert "error" not in result
        assert "rows" in result

    def test_returns_row_count(self):
        rows = [{"pathId": "rag", "name": "RAG"}]
        store = _available_store(rows)
        server = self._make_server(store)
        result = run(server._handle_kuzu_query({"cypher": "MATCH (p:ResolutionPath) RETURN p.pathId AS pathId"}))
        assert result["rowCount"] == 1

    def test_error_when_store_unavailable(self):
        store = _available_store()
        store._available = False
        server = self._make_server(store)
        result = run(server._handle_kuzu_query({"cypher": "MATCH (p:ResolutionPath) RETURN p"}))
        assert "error" in result

    def test_error_when_factory_none(self):
        import mcp_server.langchain_hana_mcp as srv_mod
        srv_mod._kuzu_store_factory = None
        server = srv_mod.LangChainHanaMCPServer()
        server._initialized = True
        server._bridge = MagicMock()
        result = run(server._handle_kuzu_query({"cypher": "MATCH (p:ResolutionPath) RETURN p"}))
        assert "error" in result

    def test_allows_match_with_where(self):
        store = _available_store([])
        server = self._make_server(store)
        result = run(server._handle_kuzu_query({"cypher": "MATCH (p:ResolutionPath) WHERE p.priority <= 5 RETURN p.pathId AS pathId"}))
        assert "error" not in result

    def test_allows_match_relationship_traversal(self):
        store = _available_store([])
        server = self._make_server(store)
        result = run(server._handle_kuzu_query({"cypher": "MATCH (s:DataSource)-[:RESOLVES_VIA]->(p:ResolutionPath) RETURN s.sourceId AS sourceId LIMIT 5"}))
        assert "error" not in result

    def test_allows_match_backend_traversal(self):
        store = _available_store([])
        server = self._make_server(store)
        result = run(server._handle_kuzu_query({"cypher": "MATCH (p:ResolutionPath)-[:SERVED_BY]->(m:ModelBackend) RETURN p.pathId AS pathId, m.name AS backend"}))
        assert "error" not in result


# ---------------------------------------------------------------------------
# 5. Graph context enrichment (hana_vector_search / hana_mmr_search)
# ---------------------------------------------------------------------------

class TestGraphContextEnrichment:
    def teardown_method(self):
        import mcp_server.langchain_hana_mcp as srv_mod
        srv_mod._kuzu_store_factory = None

    def _make_bridge_with_results(self, n=2):
        doc = MagicMock()
        doc.content = "test content"
        doc.metadata = {}
        doc.score = 0.9
        bridge = MagicMock()
        bridge.similarity_search = AsyncMock(return_value=[doc] * n)
        bridge.mmr_search = AsyncMock(return_value=[doc] * n)
        return bridge

    def _make_server(self, store):
        import mcp_server.langchain_hana_mcp as srv_mod
        srv_mod._kuzu_store_factory = lambda: store
        server = srv_mod.LangChainHanaMCPServer()
        server._initialized = True
        server._bridge = self._make_bridge_with_results()
        return server

    def test_no_graphcontext_in_vector_search_when_factory_none(self):
        import mcp_server.langchain_hana_mcp as srv_mod
        srv_mod._kuzu_store_factory = None
        server = srv_mod.LangChainHanaMCPServer()
        server._initialized = True
        server._bridge = self._make_bridge_with_results()
        result = run(server._handle_vector_search({"query": "financial data"}))
        assert "graphContext" not in result

    def test_no_graphcontext_in_mmr_search_when_factory_none(self):
        import mcp_server.langchain_hana_mcp as srv_mod
        srv_mod._kuzu_store_factory = None
        server = srv_mod.LangChainHanaMCPServer()
        server._initialized = True
        server._bridge = self._make_bridge_with_results()
        result = run(server._handle_mmr_search({"query": "financial data"}))
        assert "graphContext" not in result

    def test_no_graphcontext_when_store_unavailable(self):
        store = _available_store()
        store._available = False
        server = self._make_server(store)
        result = run(server._handle_vector_search({"query": "financial data"}))
        assert "graphContext" not in result

    def test_no_graphcontext_when_empty_rows(self):
        store = _available_store([])  # empty rows
        server = self._make_server(store)
        result = run(server._handle_vector_search({"query": "financial data"}))
        assert "graphContext" not in result

    def test_graphcontext_present_in_vector_search_when_rows_returned(self):
        rows = [{"pathId": "rag", "name": "RAG", "priority": 6, "score": 85,
                 "description": "RAG retrieval", "relation": "classifies_to"}]
        store = _available_store(rows)
        server = self._make_server(store)
        result = run(server._handle_vector_search({"query": "financial data"}))
        assert "graphContext" in result
        assert isinstance(result["graphContext"], list)

    def test_graphcontext_present_in_mmr_search_when_rows_returned(self):
        rows = [{"pathId": "rag", "name": "RAG", "priority": 6, "score": 85,
                 "description": "RAG retrieval", "relation": "classifies_to"}]
        store = _available_store(rows)
        server = self._make_server(store)
        result = run(server._handle_mmr_search({"query": "financial data"}))
        assert "graphContext" in result

    def test_vector_search_result_has_source_field(self):
        store = _available_store([])
        server = self._make_server(store)
        result = run(server._handle_vector_search({"query": "test"}))
        assert result["source"] == "hana_vector"

    def test_mmr_search_result_has_source_field(self):
        store = _available_store([])
        server = self._make_server(store)
        result = run(server._handle_mmr_search({"query": "test"}))
        assert result["source"] == "hana_mmr"


# ---------------------------------------------------------------------------
# 6. Structural tests
# ---------------------------------------------------------------------------

class TestStructural:
    def teardown_method(self):
        import mcp_server.langchain_hana_mcp as srv_mod
        srv_mod._kuzu_store_factory = None

    def _make_server(self):
        import mcp_server.langchain_hana_mcp as srv_mod
        srv_mod._kuzu_store_factory = lambda: _available_store()
        server = srv_mod.LangChainHanaMCPServer()
        server._initialized = True
        server._bridge = MagicMock()
        return server

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
            "upsert_resolution_path", "upsert_data_source",
            "upsert_query_category", "upsert_model_backend",
            "link_source_path", "link_category_path",
            "link_path_backend", "link_paths",
            "run_query", "get_paths_for_source",
            "get_paths_for_category", "get_backends_for_path",
        ]
        for m in methods:
            assert callable(getattr(store, m)), f"Missing method: {m}"

    def test_get_tools_includes_kuzu_index(self):
        server = self._make_server()
        names = [t["name"] for t in server.get_tools()]
        assert "kuzu_index" in names

    def test_get_tools_includes_kuzu_query(self):
        server = self._make_server()
        names = [t["name"] for t in server.get_tools()]
        assert "kuzu_query" in names

    def test_kuzu_index_schema_has_resolution_paths(self):
        server = self._make_server()
        schema = next(t for t in server.get_tools() if t["name"] == "kuzu_index")["inputSchema"]
        assert "resolution_paths" in schema["properties"]

    def test_kuzu_index_schema_has_data_sources(self):
        server = self._make_server()
        schema = next(t for t in server.get_tools() if t["name"] == "kuzu_index")["inputSchema"]
        assert "data_sources" in schema["properties"]

    def test_kuzu_index_schema_has_query_categories(self):
        server = self._make_server()
        schema = next(t for t in server.get_tools() if t["name"] == "kuzu_index")["inputSchema"]
        assert "query_categories" in schema["properties"]

    def test_kuzu_index_schema_has_model_backends(self):
        server = self._make_server()
        schema = next(t for t in server.get_tools() if t["name"] == "kuzu_index")["inputSchema"]
        assert "model_backends" in schema["properties"]

    def test_kuzu_query_requires_cypher(self):
        server = self._make_server()
        schema = next(t for t in server.get_tools() if t["name"] == "kuzu_query")["inputSchema"]
        assert "cypher" in schema.get("required", [])

    def test_kuzu_index_description_mentions_hippocpp(self):
        server = self._make_server()
        desc = next(t for t in server.get_tools() if t["name"] == "kuzu_index")["description"]
        assert "hippocpp" in desc.lower() or "K\u00f9zu" in desc

    def test_kuzu_query_description_mentions_hippocpp(self):
        server = self._make_server()
        desc = next(t for t in server.get_tools() if t["name"] == "kuzu_query")["description"]
        assert "hippocpp" in desc.lower() or "K\u00f9zu" in desc

    def test_handle_kuzu_index_method_exists(self):
        server = self._make_server()
        assert callable(getattr(server, "_handle_kuzu_index", None))

    def test_handle_kuzu_query_method_exists(self):
        server = self._make_server()
        assert callable(getattr(server, "_handle_kuzu_query", None))

    def test_kuzu_index_in_tool_dispatch(self):
        import mcp_server.langchain_hana_mcp as srv_mod
        srv_mod._kuzu_store_factory = None
        server = srv_mod.LangChainHanaMCPServer()
        server._initialized = True
        server._bridge = MagicMock()
        result = run(server.handle_tool_call("kuzu_index", {}))
        assert "error" in result
        assert "unknown tool" not in result.get("error", "").lower()

    def test_kuzu_query_in_tool_dispatch_empty_cypher(self):
        import mcp_server.langchain_hana_mcp as srv_mod
        srv_mod._kuzu_store_factory = None
        server = srv_mod.LangChainHanaMCPServer()
        server._initialized = True
        server._bridge = MagicMock()
        result = run(server.handle_tool_call("kuzu_query", {"cypher": ""}))
        assert "error" in result
        assert "cypher" in result["error"].lower()
