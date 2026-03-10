# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
pytest unit tests for KùzuDB / HippoCPP Graph-RAG integration in ai-core-pal.

Covers:
  - A1: KuzuStore availability / graceful degradation (hippocpp or kuzu)
  - A2: kuzu_index handler (PAL algorithms, HANA tables, mesh services, query intents)
  - A2: kuzu_query handler (read-only guard, routing)
  - A3: invoke graph context enrichment (graphContext on success)
  - A5: MangleEngine agent_can_use facts (kuzu_index, kuzu_query)
  - Structural: exports, schema shape, dispatch routing

All tests pass regardless of whether hippocpp/kuzu is installed; when absent
the store degrades gracefully and tests verify that behaviour.
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
from typing import Any
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

_ROOT = os.path.dirname(os.path.dirname(__file__))
_MCP_SERVER = os.path.join(_ROOT, "mcp_server")
_AGENT = os.path.join(_ROOT, "agent")
for _p in (_MCP_SERVER, _AGENT, _ROOT):
    if _p not in sys.path:
        sys.path.insert(0, _p)


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
        assert store.run_query("MATCH (a:PALAlgorithm) RETURN a") == []

    def test_get_algos_for_intent_empty_when_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        assert store.get_algos_for_intent("pal_forecast") == []

    def test_get_tables_for_algo_empty_when_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        assert store.get_tables_for_algo("ARIMA") == []

    def test_get_services_for_intent_empty_when_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        assert store.get_services_for_intent("pal_forecast") == []

    def test_get_related_algos_empty_when_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        assert store.get_related_algos("ARIMA") == []

    def test_upsert_pal_algorithm_no_throw_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        store.upsert_pal_algorithm("ARIMA", "ARIMA", "time_series", "_SYS_AFL.PAL_ARIMA", "Time series")

    def test_upsert_hana_table_no_throw_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        store.upsert_hana_table("ACDOCA", "ACDOCA", "SAPHANADB", "TABLE")

    def test_upsert_mesh_service_no_throw_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        store.upsert_mesh_service("hana-svc", "HANA Service", "http://localhost:9881", 9881, 1)

    def test_upsert_query_intent_no_throw_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        store.upsert_query_intent("pal_forecast", "PAL Forecast", "forecast*", "time_series")

    def test_link_algo_table_no_throw_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        store.link_algo_table("ARIMA", "ACDOCA")

    def test_link_intent_service_no_throw_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        store.link_intent_service("pal_forecast", "hana-svc")

    def test_link_related_algos_no_throw_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        store.link_related_algos("ARIMA", "LSTM")

    def test_link_intent_algo_no_throw_unavailable(self):
        from mcp_server.kuzu_store import KuzuStore
        store = KuzuStore(":memory:")
        store._available = False
        store.link_intent_algo("pal_forecast", "ARIMA")

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

    def test_upsert_pal_algorithm_calls_execute(self):
        store = _available_store()
        store.upsert_pal_algorithm("ARIMA", "ARIMA", "time_series", "_SYS_AFL.PAL_ARIMA", "Time series")
        store._conn.execute.assert_called()

    def test_upsert_hana_table_calls_execute(self):
        store = _available_store()
        store.upsert_hana_table("ACDOCA", "ACDOCA", "SAPHANADB", "TABLE")
        store._conn.execute.assert_called()

    def test_upsert_mesh_service_calls_execute(self):
        store = _available_store()
        store.upsert_mesh_service("hana-svc", "HANA Service", "http://localhost:9881", 9881, 1)
        store._conn.execute.assert_called()

    def test_upsert_query_intent_calls_execute(self):
        store = _available_store()
        store.upsert_query_intent("pal_forecast", "PAL Forecast", "forecast*", "time_series")
        store._conn.execute.assert_called()

    def test_link_algo_table_calls_execute(self):
        store = _available_store()
        store.link_algo_table("ARIMA", "ACDOCA")
        store._conn.execute.assert_called()

    def test_link_intent_service_calls_execute(self):
        store = _available_store()
        store.link_intent_service("pal_forecast", "hana-svc")
        store._conn.execute.assert_called()

    def test_link_related_algos_calls_execute(self):
        store = _available_store()
        store.link_related_algos("ARIMA", "LSTM")
        store._conn.execute.assert_called()

    def test_link_intent_algo_calls_execute(self):
        store = _available_store()
        store.link_intent_algo("pal_forecast", "ARIMA")
        store._conn.execute.assert_called()

    def test_run_query_returns_rows(self):
        rows = [{"algoId": "ARIMA", "name": "ARIMA", "category": "time_series",
                 "procedure": "_SYS_AFL.PAL_ARIMA", "description": "Time series"}]
        store = _available_store(rows)
        result = store.run_query("MATCH (a:PALAlgorithm) RETURN a.algoId AS algoId LIMIT 5")
        assert len(result) == 1
        assert result[0]["algoId"] == "ARIMA"

    def test_run_query_empty_on_exception(self):
        store = _available_store()
        store._conn.execute.side_effect = RuntimeError("db error")
        assert store.run_query("MATCH (a:PALAlgorithm) RETURN a") == []

    def test_get_algos_for_intent_returns_list(self):
        rows = [{"algoId": "ARIMA", "name": "ARIMA", "category": "time_series",
                 "procedure": "_SYS_AFL.PAL_ARIMA", "description": "Time series"}]
        store = _available_store(rows)
        result = store.get_algos_for_intent("pal_forecast")
        assert isinstance(result, list)

    def test_get_tables_for_algo_returns_list(self):
        rows = [{"tableId": "ACDOCA", "name": "ACDOCA",
                 "schema_name": "SAPHANADB", "table_type": "TABLE"}]
        store = _available_store(rows)
        result = store.get_tables_for_algo("ARIMA")
        assert isinstance(result, list)

    def test_get_services_for_intent_returns_list(self):
        rows = [{"serviceId": "hana-svc", "name": "HANA Service",
                 "url": "http://localhost:9881", "port": 9881, "priority": 1}]
        store = _available_store(rows)
        result = store.get_services_for_intent("pal_forecast")
        assert isinstance(result, list)

    def test_get_related_algos_returns_list(self):
        rows = [{"algoId": "LSTM", "name": "LSTM", "category": "time_series",
                 "procedure": "_SYS_AFL.PAL_LSTM", "description": "LSTM"}]
        store = _available_store(rows)
        result = store.get_related_algos("ARIMA")
        assert isinstance(result, list)


# ---------------------------------------------------------------------------
# 3. kuzu_index handler
# ---------------------------------------------------------------------------

class TestKuzuIndexHandler:
    def _make_agent(self, store):
        import agent.aicore_pal_agent as agent_mod
        agent_mod._kuzu_store_factory = lambda: store
        agent = agent_mod.AICorePALAgent.__new__(agent_mod.AICorePALAgent)
        agent.mangle = MagicMock()
        agent.mcp_endpoint = "http://localhost:8084/mcp"
        agent.vllm_endpoint = "http://localhost:9180/mcp"
        agent.vocab_client = MagicMock()
        agent.audit_log = []
        return agent

    def teardown_method(self):
        import agent.aicore_pal_agent as agent_mod
        agent_mod._kuzu_store_factory = None

    def test_indexes_algorithms(self):
        store = _available_store()
        agent = self._make_agent(store)
        result = run(agent.handle_kuzu_index({
            "algorithms": json.dumps([
                {"algoId": "ARIMA", "name": "ARIMA", "category": "time_series",
                 "procedure": "_SYS_AFL.PAL_ARIMA", "description": "ARIMA forecasting"},
                {"algoId": "KMEANS", "name": "K-Means", "category": "clustering",
                 "procedure": "_SYS_AFL.PAL_KMEANS", "description": "Clustering"},
            ])
        }))
        assert result["algos_indexed"] == 2

    def test_indexes_hana_tables(self):
        store = _available_store()
        agent = self._make_agent(store)
        result = run(agent.handle_kuzu_index({
            "hana_tables": json.dumps([
                {"tableId": "ACDOCA", "name": "ACDOCA", "schema_name": "SAPHANADB", "table_type": "TABLE"},
                {"tableId": "VBAK", "name": "VBAK", "schema_name": "SAPHANADB", "table_type": "TABLE"},
            ])
        }))
        assert result["tables_indexed"] == 2

    def test_indexes_mesh_services(self):
        store = _available_store()
        agent = self._make_agent(store)
        result = run(agent.handle_kuzu_index({
            "mesh_services": json.dumps([
                {"serviceId": "hana-svc", "name": "HANA Service", "url": "http://localhost:9881", "port": 9881, "priority": 1},
                {"serviceId": "neo4j-svc", "name": "Neo4j Service", "url": "http://localhost:9882", "port": 9882, "priority": 1},
            ])
        }))
        assert result["services_indexed"] == 2

    def test_indexes_query_intents(self):
        store = _available_store()
        agent = self._make_agent(store)
        result = run(agent.handle_kuzu_index({
            "query_intents": json.dumps([
                {"intentId": "pal_forecast", "name": "PAL Forecast", "pattern": "forecast*", "category": "time_series"},
                {"intentId": "pal_cluster", "name": "PAL Cluster", "pattern": "cluster*", "category": "clustering"},
            ])
        }))
        assert result["intents_indexed"] == 2

    def test_indexes_all_together(self):
        store = _available_store()
        agent = self._make_agent(store)
        result = run(agent.handle_kuzu_index({
            "algorithms": json.dumps([{"algoId": "ARIMA", "name": "ARIMA", "category": "time_series", "procedure": "_SYS_AFL.PAL_ARIMA", "description": ""}]),
            "hana_tables": json.dumps([{"tableId": "ACDOCA", "name": "ACDOCA", "schema_name": "SAPHANADB", "table_type": "TABLE"}]),
            "mesh_services": json.dumps([{"serviceId": "hana-svc", "name": "HANA", "url": "http://localhost:9881", "port": 9881, "priority": 1}]),
            "query_intents": json.dumps([{"intentId": "pal_forecast", "name": "Forecast", "pattern": "forecast*", "category": "time_series", "servedBy": "ARIMA", "routesTo": "hana-svc"}]),
        }))
        assert result["algos_indexed"] == 1
        assert result["tables_indexed"] == 1
        assert result["services_indexed"] == 1
        assert result["intents_indexed"] == 1

    def test_skips_algos_with_missing_id(self):
        store = _available_store()
        agent = self._make_agent(store)
        result = run(agent.handle_kuzu_index({
            "algorithms": json.dumps([
                {"algoId": "", "name": "Empty"},   # skip
                {"algoId": "ARIMA", "name": "ARIMA"},  # ok
            ])
        }))
        assert result["algos_indexed"] == 1

    def test_skips_tables_with_missing_id(self):
        store = _available_store()
        agent = self._make_agent(store)
        result = run(agent.handle_kuzu_index({
            "hana_tables": json.dumps([
                {"tableId": "", "name": "Empty"},        # skip
                {"tableId": "ACDOCA", "name": "ACDOCA"}, # ok
            ])
        }))
        assert result["tables_indexed"] == 1

    def test_skips_services_with_missing_id(self):
        store = _available_store()
        agent = self._make_agent(store)
        result = run(agent.handle_kuzu_index({
            "mesh_services": json.dumps([
                {"serviceId": "", "name": "Empty"},
                {"serviceId": "hana-svc", "name": "HANA"},
            ])
        }))
        assert result["services_indexed"] == 1

    def test_skips_intents_with_missing_id(self):
        store = _available_store()
        agent = self._make_agent(store)
        result = run(agent.handle_kuzu_index({
            "query_intents": json.dumps([
                {"intentId": "", "name": "Empty"},
                {"intentId": "pal_forecast", "name": "Forecast"},
            ])
        }))
        assert result["intents_indexed"] == 1

    def test_error_when_store_unavailable(self):
        store = _available_store()
        store._available = False
        agent = self._make_agent(store)
        result = run(agent.handle_kuzu_index({}))
        assert "error" in result

    def test_error_when_factory_none(self):
        import agent.aicore_pal_agent as agent_mod
        agent_mod._kuzu_store_factory = None
        agent = agent_mod.AICorePALAgent.__new__(agent_mod.AICorePALAgent)
        agent.mangle = MagicMock()
        agent.audit_log = []
        result = run(agent.handle_kuzu_index({}))
        assert "error" in result

    def test_related_algo_link_wired(self):
        store = _available_store()
        agent = self._make_agent(store)
        run(agent.handle_kuzu_index({
            "algorithms": json.dumps([{"algoId": "ARIMA", "name": "ARIMA", "relatedAlgo": "LSTM"}]),
        }))
        store._conn.execute.assert_called()

    def test_executed_by_link_wired(self):
        store = _available_store()
        agent = self._make_agent(store)
        run(agent.handle_kuzu_index({
            "hana_tables": json.dumps([{"tableId": "ACDOCA", "name": "ACDOCA", "schema_name": "SAPHANADB", "table_type": "TABLE", "executedBy": "ARIMA"}]),
        }))
        store._conn.execute.assert_called()

    def test_routes_to_link_wired(self):
        store = _available_store()
        agent = self._make_agent(store)
        run(agent.handle_kuzu_index({
            "query_intents": json.dumps([{"intentId": "pal_forecast", "name": "Forecast", "pattern": "*", "category": "ts", "routesTo": "hana-svc"}]),
        }))
        store._conn.execute.assert_called()

    def test_served_by_link_wired(self):
        store = _available_store()
        agent = self._make_agent(store)
        run(agent.handle_kuzu_index({
            "query_intents": json.dumps([{"intentId": "pal_forecast", "name": "Forecast", "pattern": "*", "category": "ts", "servedBy": "ARIMA"}]),
        }))
        store._conn.execute.assert_called()


# ---------------------------------------------------------------------------
# 4. kuzu_query handler
# ---------------------------------------------------------------------------

DISALLOWED = ["CREATE ", "MERGE ", "DELETE ", "SET ", "REMOVE ", "DROP "]


class TestKuzuQueryHandler:
    def _make_agent(self, store):
        import agent.aicore_pal_agent as agent_mod
        agent_mod._kuzu_store_factory = lambda: store
        agent = agent_mod.AICorePALAgent.__new__(agent_mod.AICorePALAgent)
        agent.mangle = MagicMock()
        agent.audit_log = []
        return agent

    def teardown_method(self):
        import agent.aicore_pal_agent as agent_mod
        agent_mod._kuzu_store_factory = None

    def test_error_for_empty_cypher(self):
        store = _available_store()
        agent = self._make_agent(store)
        result = run(agent.handle_kuzu_query({"cypher": ""}))
        assert "error" in result

    @pytest.mark.parametrize("kw", DISALLOWED)
    def test_blocks_write_statements(self, kw):
        store = _available_store()
        agent = self._make_agent(store)
        result = run(agent.handle_kuzu_query({"cypher": f"{kw}(a:PALAlgorithm {{algoId: 'x'}})"}))
        assert "error" in result
        assert "not permitted" in result["error"].lower()

    def test_allows_match_statement(self):
        rows = [{"algoId": "ARIMA", "name": "ARIMA"}]
        store = _available_store(rows)
        agent = self._make_agent(store)
        result = run(agent.handle_kuzu_query({"cypher": "MATCH (a:PALAlgorithm) RETURN a.algoId AS algoId LIMIT 5"}))
        assert "error" not in result
        assert "rows" in result

    def test_returns_row_count(self):
        rows = [{"algoId": "ARIMA", "name": "ARIMA"}]
        store = _available_store(rows)
        agent = self._make_agent(store)
        result = run(agent.handle_kuzu_query({"cypher": "MATCH (a:PALAlgorithm) RETURN a.algoId AS algoId"}))
        assert result["rowCount"] == 1

    def test_error_when_store_unavailable(self):
        store = _available_store()
        store._available = False
        agent = self._make_agent(store)
        result = run(agent.handle_kuzu_query({"cypher": "MATCH (a:PALAlgorithm) RETURN a"}))
        assert "error" in result

    def test_error_when_factory_none(self):
        import agent.aicore_pal_agent as agent_mod
        agent_mod._kuzu_store_factory = None
        agent = agent_mod.AICorePALAgent.__new__(agent_mod.AICorePALAgent)
        agent.mangle = MagicMock()
        agent.audit_log = []
        result = run(agent.handle_kuzu_query({"cypher": "MATCH (a:PALAlgorithm) RETURN a"}))
        assert "error" in result

    def test_allows_match_with_where(self):
        store = _available_store([])
        agent = self._make_agent(store)
        result = run(agent.handle_kuzu_query({"cypher": "MATCH (a:PALAlgorithm) WHERE a.category = 'time_series' RETURN a.algoId AS algoId"}))
        assert "error" not in result

    def test_allows_relationship_traversal(self):
        store = _available_store([])
        agent = self._make_agent(store)
        result = run(agent.handle_kuzu_query({"cypher": "MATCH (i:QueryIntent)-[:SERVED_BY]->(a:PALAlgorithm) RETURN i.intentId AS intentId LIMIT 5"}))
        assert "error" not in result

    def test_allows_multi_hop_traversal(self):
        store = _available_store([])
        agent = self._make_agent(store)
        result = run(agent.handle_kuzu_query({"cypher": "MATCH (a:PALAlgorithm)-[:EXECUTES_ON]->(t:HANATable) RETURN a.algoId AS algoId, t.name AS table"}))
        assert "error" not in result


# ---------------------------------------------------------------------------
# 5. Graph context enrichment in invoke()
# ---------------------------------------------------------------------------

class TestGraphContextEnrichment:
    def teardown_method(self):
        import agent.aicore_pal_agent as agent_mod
        agent_mod._kuzu_store_factory = None

    def _make_agent(self, store):
        import agent.aicore_pal_agent as agent_mod
        agent_mod._kuzu_store_factory = lambda: store
        agent = agent_mod.AICorePALAgent.__new__(agent_mod.AICorePALAgent)
        mangle = MagicMock()
        # requires_human_review → [] (falsy = no review needed)
        # safety_check_passed  → [True] (truthy = allowed)
        def _mangle_query(pred, *args):
            if pred == "safety_check_passed":
                return [{"result": True}]
            if pred == "get_prompting_policy":
                return [{"system_prompt": "", "max_tokens": 100, "temperature": 0.0}]
            return []
        mangle.query.side_effect = _mangle_query
        agent.mangle = mangle
        agent.mcp_endpoint = "http://localhost:8084/mcp"
        agent.vllm_endpoint = "http://localhost:9180/mcp"
        agent.vocab_client = MagicMock()
        agent.audit_log = []
        agent._call_mcp = AsyncMock(return_value={"content": "PAL result"})
        return agent

    def _make_agent_no_factory(self):
        """Build an agent with _kuzu_store_factory = None after init."""
        import agent.aicore_pal_agent as agent_mod
        store = _available_store([])
        agent = self._make_agent(store)
        agent_mod._kuzu_store_factory = None
        return agent

    def test_no_graphcontext_when_factory_none(self):
        agent = self._make_agent_no_factory()
        result = run(agent.invoke("Forecast sales", {"tool": "pal_forecast"}))
        assert "graphContext" not in result

    def test_no_graphcontext_when_store_unavailable(self):
        store = _available_store()
        store._available = False
        agent = self._make_agent(store)
        result = run(agent.invoke("Forecast sales", {"tool": "pal_forecast"}))
        assert "graphContext" not in result

    def test_no_graphcontext_when_empty_rows(self):
        store = _available_store([])
        agent = self._make_agent(store)
        result = run(agent.invoke("Forecast sales", {"tool": "pal_forecast"}))
        assert "graphContext" not in result

    def test_graphcontext_present_when_rows_returned(self):
        rows = [{"algoId": "ARIMA", "name": "ARIMA", "category": "time_series",
                 "procedure": "_SYS_AFL.PAL_ARIMA", "description": "Time series"}]
        store = _available_store(rows)
        agent = self._make_agent(store)
        result = run(agent.invoke("Forecast sales", {"tool": "pal_forecast"}))
        assert "graphContext" in result
        assert isinstance(result["graphContext"], list)

    def test_invoke_dispatches_kuzu_index(self):
        store = _available_store()
        agent = self._make_agent(store)
        result = run(agent.invoke("Index PAL", {"tool": "kuzu_index", "args": {}}))
        assert "error" in result or "algos_indexed" in result

    def test_invoke_dispatches_kuzu_query(self):
        store = _available_store()
        agent = self._make_agent(store)
        result = run(agent.invoke("Query graph", {"tool": "kuzu_query", "args": {"cypher": ""}}))
        assert "error" in result

    def test_invoke_status_success_on_mcp_call(self):
        store = _available_store([])
        agent = self._make_agent(store)
        result = run(agent.invoke("Forecast sales", {"tool": "pal_forecast"}))
        assert result["status"] == "success"

    def test_invoke_backend_always_vllm(self):
        store = _available_store([])
        agent = self._make_agent(store)
        result = run(agent.invoke("Classify customers", {"tool": "pal_classification"}))
        assert result.get("backend") == "vllm"


# ---------------------------------------------------------------------------
# 6. MangleEngine facts — kuzu tools included
# ---------------------------------------------------------------------------

class TestMangleEngineFacts:
    def test_kuzu_index_in_agent_can_use(self):
        import agent.aicore_pal_agent as agent_mod
        engine = agent_mod.MangleEngine()
        assert "kuzu_index" in engine.facts["agent_can_use"]

    def test_kuzu_query_in_agent_can_use(self):
        import agent.aicore_pal_agent as agent_mod
        engine = agent_mod.MangleEngine()
        assert "kuzu_query" in engine.facts["agent_can_use"]

    def test_safety_check_passes_kuzu_index(self):
        import agent.aicore_pal_agent as agent_mod
        engine = agent_mod.MangleEngine()
        result = engine.query("safety_check_passed", "kuzu_index")
        assert len(result) > 0

    def test_safety_check_passes_kuzu_query(self):
        import agent.aicore_pal_agent as agent_mod
        engine = agent_mod.MangleEngine()
        result = engine.query("safety_check_passed", "kuzu_query")
        assert len(result) > 0

    def test_kuzu_tools_not_in_requires_approval(self):
        import agent.aicore_pal_agent as agent_mod
        engine = agent_mod.MangleEngine()
        assert "kuzu_index" not in engine.facts["agent_requires_approval"]
        assert "kuzu_query" not in engine.facts["agent_requires_approval"]


# ---------------------------------------------------------------------------
# 7. Structural tests
# ---------------------------------------------------------------------------

class TestStructural:
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
            "upsert_pal_algorithm", "upsert_hana_table",
            "upsert_mesh_service", "upsert_query_intent",
            "link_algo_table", "link_intent_service",
            "link_related_algos", "link_intent_algo",
            "run_query", "get_algos_for_intent",
            "get_tables_for_algo", "get_services_for_intent",
            "get_related_algos",
        ]
        for m in methods:
            assert callable(getattr(store, m)), f"Missing method: {m}"

    def test_agent_has_handle_kuzu_index(self):
        import agent.aicore_pal_agent as agent_mod
        agent = agent_mod.AICorePALAgent.__new__(agent_mod.AICorePALAgent)
        assert callable(getattr(agent, "handle_kuzu_index", None))

    def test_agent_has_handle_kuzu_query(self):
        import agent.aicore_pal_agent as agent_mod
        agent = agent_mod.AICorePALAgent.__new__(agent_mod.AICorePALAgent)
        assert callable(getattr(agent, "handle_kuzu_query", None))

    def test_parse_json_arg_handles_string(self):
        import agent.aicore_pal_agent as agent_mod
        result = agent_mod._parse_json_arg('[{"algoId": "X"}]', [])
        assert isinstance(result, list)
        assert result[0]["algoId"] == "X"

    def test_parse_json_arg_handles_list_passthrough(self):
        import agent.aicore_pal_agent as agent_mod
        val = [{"algoId": "X"}]
        assert agent_mod._parse_json_arg(val, []) is val

    def test_parse_json_arg_handles_none(self):
        import agent.aicore_pal_agent as agent_mod
        assert agent_mod._parse_json_arg(None, []) == []

    def test_parse_json_arg_handles_invalid_json(self):
        import agent.aicore_pal_agent as agent_mod
        assert agent_mod._parse_json_arg("not-json", []) == []

    def test_kuzu_store_factory_import_pattern(self):
        import agent.aicore_pal_agent as agent_mod
        assert hasattr(agent_mod, "_kuzu_store_factory")

    def test_invoke_kuzu_index_via_tool_dispatch(self):
        import agent.aicore_pal_agent as agent_mod
        agent_mod._kuzu_store_factory = None
        agent = agent_mod.AICorePALAgent.__new__(agent_mod.AICorePALAgent)
        agent.mangle = MagicMock()
        agent.audit_log = []
        result = run(agent.invoke("index PAL", {"tool": "kuzu_index", "args": {}}))
        assert "error" in result

    def test_invoke_kuzu_query_via_tool_dispatch_empty(self):
        import agent.aicore_pal_agent as agent_mod
        agent_mod._kuzu_store_factory = None
        agent = agent_mod.AICorePALAgent.__new__(agent_mod.AICorePALAgent)
        agent.mangle = MagicMock()
        agent.audit_log = []
        result = run(agent.invoke("query graph", {"tool": "kuzu_query", "args": {"cypher": ""}}))
        assert "error" in result
        assert "cypher" in result["error"].lower()
