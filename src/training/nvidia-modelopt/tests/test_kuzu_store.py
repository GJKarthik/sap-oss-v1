#!/usr/bin/env python3
"""
Tests for KuzuStore (graph-RAG backend) and /graph/* endpoints.

All tests use an in-memory SQLite-backed KuzuStore mock so that neither
hippocpp nor kuzu needs to be installed for the test suite to pass.
"""

from __future__ import annotations

import hashlib
import os
import sys
from typing import Any, Dict, List, Optional
from unittest.mock import MagicMock, patch

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


# ---------------------------------------------------------------------------
# Helpers — build a mock KuzuStore that does NOT need kuzu/hippocpp
# ---------------------------------------------------------------------------

def _make_mock_store(available: bool = True, rows: Optional[List[Dict]] = None):
    store = MagicMock()
    store.available.return_value = available
    store.query.return_value = rows if rows is not None else []
    store.get_pair_count.return_value = len(rows) if rows else 0
    return store


# ---------------------------------------------------------------------------
# TestKuzuStoreUnit — pure unit tests against the KuzuStore class
# ---------------------------------------------------------------------------

class TestKuzuStoreAvailability:
    def test_unavailable_when_backend_missing(self):
        """Store is unavailable when neither hippocpp nor kuzu is installed."""
        import api.kuzu_store as ks_mod
        orig = ks_mod._kuzu_mod
        ks_mod._kuzu_mod = None
        store = ks_mod.KuzuStore(db_path=":memory:")
        assert not store.available()
        ks_mod._kuzu_mod = orig

    def test_available_flag_false_on_bad_path(self):
        import api.kuzu_store as ks_mod
        if ks_mod._kuzu_mod is None:
            pytest.skip("kuzu backend not installed")
        store = ks_mod.KuzuStore(db_path="/nonexistent/path/db")
        # Either available (if kuzu accepts it) or not — must not raise
        assert isinstance(store.available(), bool)

    def test_store_class_exists(self):
        from api.kuzu_store import KuzuStore
        assert KuzuStore is not None

    def test_get_kuzu_store_returns_instance(self):
        import api.kuzu_store as ks_mod
        # Reset singleton
        ks_mod._store = None
        store = ks_mod.get_kuzu_store()
        assert store is not None
        # Second call returns same object
        assert ks_mod.get_kuzu_store() is store
        ks_mod._store = None

    def test_get_kuzu_store_singleton(self):
        import api.kuzu_store as ks_mod
        ks_mod._store = None
        s1 = ks_mod.get_kuzu_store()
        s2 = ks_mod.get_kuzu_store()
        assert s1 is s2
        ks_mod._store = None


class TestKuzuStoreReadonly:
    def setup_method(self):
        import api.kuzu_store as ks_mod
        self.ks_mod = ks_mod

    def _store_with_available(self, rows=None):
        store = self.ks_mod.KuzuStore.__new__(self.ks_mod.KuzuStore)
        store._db = MagicMock()
        store._conn = MagicMock()
        # Simulate query returning rows
        mock_result = MagicMock()
        mock_result.has_next.side_effect = ([True] * len(rows or []) + [False])
        mock_result.get_next.side_effect = [(list(r.values()),) for r in (rows or [])]
        mock_result.get_column_names.return_value = list((rows or [{}])[0].keys()) if rows else []
        store._conn.execute.return_value = mock_result
        return store

    def test_is_readonly_match(self):
        import api.kuzu_store as ks_mod
        store = ks_mod.KuzuStore.__new__(ks_mod.KuzuStore)
        store._conn = MagicMock()
        assert store._is_readonly("MATCH (n) RETURN n")

    def test_is_readonly_return(self):
        import api.kuzu_store as ks_mod
        store = ks_mod.KuzuStore.__new__(ks_mod.KuzuStore)
        store._conn = MagicMock()
        assert store._is_readonly("RETURN 1")

    def test_is_readonly_with(self):
        import api.kuzu_store as ks_mod
        store = ks_mod.KuzuStore.__new__(ks_mod.KuzuStore)
        store._conn = MagicMock()
        assert store._is_readonly("WITH n MATCH (n) RETURN n")

    def test_not_readonly_create(self):
        import api.kuzu_store as ks_mod
        store = ks_mod.KuzuStore.__new__(ks_mod.KuzuStore)
        store._conn = MagicMock()
        assert not store._is_readonly("CREATE (n:Node)")

    def test_not_readonly_merge(self):
        import api.kuzu_store as ks_mod
        store = ks_mod.KuzuStore.__new__(ks_mod.KuzuStore)
        store._conn = MagicMock()
        assert not store._is_readonly("MERGE (n:Node)")

    def test_not_readonly_delete(self):
        import api.kuzu_store as ks_mod
        store = ks_mod.KuzuStore.__new__(ks_mod.KuzuStore)
        store._conn = MagicMock()
        assert not store._is_readonly("DELETE n")

    def test_query_raises_on_write_cypher(self):
        import api.kuzu_store as ks_mod
        store = ks_mod.KuzuStore.__new__(ks_mod.KuzuStore)
        store._conn = MagicMock()
        store._db = MagicMock()
        with pytest.raises(ValueError, match="read-only"):
            store.query("CREATE (n:Foo)")

    def test_query_returns_empty_when_unavailable(self):
        import api.kuzu_store as ks_mod
        store = ks_mod.KuzuStore.__new__(ks_mod.KuzuStore)
        store._conn = None
        store._db = None
        result = store.query("MATCH (n) RETURN n")
        assert result == []

    def test_upsert_noop_when_unavailable(self):
        import api.kuzu_store as ks_mod
        store = ks_mod.KuzuStore.__new__(ks_mod.KuzuStore)
        store._conn = None
        store._db = None
        # Should not raise
        store.upsert_training_pair("p1", "q", "SELECT 1", "treasury", "easy")
        store.upsert_schema_table("T", "STG", "treasury")
        store.upsert_prompt_template("t1", "treasury", "cat", "prod", 2)
        store.upsert_sql_pattern("SELECT *", "NONE", "easy")

    def test_link_noop_when_unavailable(self):
        import api.kuzu_store as ks_mod
        store = ks_mod.KuzuStore.__new__(ks_mod.KuzuStore)
        store._conn = None
        store._db = None
        store.link_pair_to_template("p1", "t1")
        store.link_pair_to_table("p1", "T")
        store.link_pair_to_pattern("p1", "SELECT *")

    def test_upsert_calls_conn_execute(self):
        import api.kuzu_store as ks_mod
        store = ks_mod.KuzuStore.__new__(ks_mod.KuzuStore)
        store._conn = MagicMock()
        store._db = MagicMock()
        store.upsert_training_pair("p1", "question", "SELECT 1", "treasury", "easy")
        store._conn.execute.assert_called_once()

    def test_upsert_schema_table_calls_execute(self):
        import api.kuzu_store as ks_mod
        store = ks_mod.KuzuStore.__new__(ks_mod.KuzuStore)
        store._conn = MagicMock()
        store._db = MagicMock()
        store.upsert_schema_table("BOND_POSITIONS", "STG_TREASURY", "treasury")
        store._conn.execute.assert_called_once()

    def test_upsert_prompt_template_calls_execute(self):
        import api.kuzu_store as ks_mod
        store = ks_mod.KuzuStore.__new__(ks_mod.KuzuStore)
        store._conn = MagicMock()
        store._db = MagicMock()
        store.upsert_prompt_template("t1", "treasury", "ISIN", "Bonds", 2)
        store._conn.execute.assert_called_once()

    def test_upsert_sql_pattern_calls_execute(self):
        import api.kuzu_store as ks_mod
        store = ks_mod.KuzuStore.__new__(ks_mod.KuzuStore)
        store._conn = MagicMock()
        store._db = MagicMock()
        store.upsert_sql_pattern("SELECT t.MTM FROM ...", "SUM", "moderate")
        store._conn.execute.assert_called_once()

    def test_link_pair_to_template_calls_execute(self):
        import api.kuzu_store as ks_mod
        store = ks_mod.KuzuStore.__new__(ks_mod.KuzuStore)
        store._conn = MagicMock()
        store._db = MagicMock()
        store.link_pair_to_template("p1", "t1")
        store._conn.execute.assert_called_once()

    def test_link_pair_to_table_calls_execute(self):
        import api.kuzu_store as ks_mod
        store = ks_mod.KuzuStore.__new__(ks_mod.KuzuStore)
        store._conn = MagicMock()
        store._db = MagicMock()
        store.link_pair_to_table("p1", "BOND_POSITIONS")
        store._conn.execute.assert_called_once()

    def test_link_pair_to_pattern_calls_execute(self):
        import api.kuzu_store as ks_mod
        store = ks_mod.KuzuStore.__new__(ks_mod.KuzuStore)
        store._conn = MagicMock()
        store._db = MagicMock()
        store.link_pair_to_pattern("p1", "SELECT t.COUNTRY")
        store._conn.execute.assert_called_once()


class TestKuzuStoreHelperQueries:
    def _make_store_with_query(self, rows):
        import api.kuzu_store as ks_mod
        store = ks_mod.KuzuStore.__new__(ks_mod.KuzuStore)
        store._conn = MagicMock()
        store._db = MagicMock()
        store.query = MagicMock(return_value=rows)
        return store

    def test_get_pairs_for_domain(self):
        rows = [{"id": "p1", "question": "Q", "sql": "SELECT 1", "difficulty": "easy"}]
        store = self._make_store_with_query(rows)
        result = store.get_pairs_for_domain("treasury")
        store.query.assert_called_once()
        assert result == rows

    def test_get_patterns_for_difficulty(self):
        rows = [{"pattern_text": "SELECT t.MTM", "agg_func": "SUM", "complexity": "moderate"}]
        store = self._make_store_with_query(rows)
        result = store.get_patterns_for_difficulty("moderate")
        store.query.assert_called_once()
        assert result == rows

    def test_get_tables_for_domain(self):
        rows = [{"name": "BOND_POSITIONS", "schema_name": "STG_TREASURY", "domain": "treasury"}]
        store = self._make_store_with_query(rows)
        result = store.get_tables_for_domain("treasury")
        store.query.assert_called_once()
        assert result == rows

    def test_get_pair_count_empty(self):
        import api.kuzu_store as ks_mod
        store = ks_mod.KuzuStore.__new__(ks_mod.KuzuStore)
        store._conn = None
        store._db = None
        assert store.get_pair_count() == 0

    def test_get_pair_count_with_rows(self):
        import api.kuzu_store as ks_mod
        store = ks_mod.KuzuStore.__new__(ks_mod.KuzuStore)
        store._conn = MagicMock()
        store._db = MagicMock()
        store.query = MagicMock(return_value=[{"cnt": 42}])
        count = store.get_pair_count()
        assert count == 42

    def test_get_pair_count_empty_rows(self):
        import api.kuzu_store as ks_mod
        store = ks_mod.KuzuStore.__new__(ks_mod.KuzuStore)
        store._conn = MagicMock()
        store._db = MagicMock()
        store.query = MagicMock(return_value=[])
        assert store.get_pair_count() == 0


# ---------------------------------------------------------------------------
# TestGraphEndpoints — FastAPI endpoint tests
# ---------------------------------------------------------------------------

@pytest.fixture
def mock_store():
    return _make_mock_store(available=True)


@pytest.fixture
def unavailable_store():
    return _make_mock_store(available=False)


@pytest.fixture
def client():
    from fastapi.testclient import TestClient
    from api.main import app
    return TestClient(app)


@pytest.fixture
def auth_headers():
    import api.auth as auth_mod
    # Use in-memory SQLite for test isolation
    import api.kuzu_store as ks_mod
    ks_mod._store = None
    auth_mod._key_store = auth_mod.ApiKeyStore(db_path=":memory:")
    key = auth_mod.generate_api_key("test")
    return {"Authorization": f"Bearer {key}"}


class TestGraphIndexEndpoint:
    def _payload(self, **kwargs):
        base = {
            "pair_id": "p-001",
            "question": "Show total MTM for US bonds",
            "sql": "SELECT SUM(t.MTM) FROM STG_TREASURY.BOND_POSITIONS t WHERE t.COUNTRY = 'US'",
            "domain": "treasury",
            "difficulty": "moderate",
        }
        base.update(kwargs)
        return base

    def test_index_unavailable_store_returns_unavailable(self, client, auth_headers):
        store = _make_mock_store(available=False)
        with patch("api.main.get_kuzu_store", return_value=store):
            resp = client.post("/graph/index", json=self._payload(), headers=auth_headers)
        assert resp.status_code == 200
        assert resp.json()["status"] == "unavailable"

    def test_index_available_store_returns_indexed(self, client, auth_headers, mock_store):
        with patch("api.main.get_kuzu_store", return_value=mock_store):
            resp = client.post("/graph/index", json=self._payload(), headers=auth_headers)
        assert resp.status_code == 200
        body = resp.json()
        assert body["status"] == "indexed"
        assert body["pair_id"] == "p-001"

    def test_index_calls_upsert_training_pair(self, client, auth_headers, mock_store):
        with patch("api.main.get_kuzu_store", return_value=mock_store):
            client.post("/graph/index", json=self._payload(), headers=auth_headers)
        mock_store.upsert_training_pair.assert_called_once_with(
            "p-001",
            "Show total MTM for US bonds",
            "SELECT SUM(t.MTM) FROM STG_TREASURY.BOND_POSITIONS t WHERE t.COUNTRY = 'US'",
            "treasury",
            "moderate",
            "template_expansion",
        )

    def test_index_with_template_id_links_template(self, client, auth_headers, mock_store):
        payload = self._payload(template_id="tmpl-1")
        with patch("api.main.get_kuzu_store", return_value=mock_store):
            resp = client.post("/graph/index", json=payload, headers=auth_headers)
        assert resp.status_code == 200
        mock_store.upsert_prompt_template.assert_called_once()
        mock_store.link_pair_to_template.assert_called_once_with("p-001", "tmpl-1")

    def test_index_with_table_name_links_table(self, client, auth_headers, mock_store):
        payload = self._payload(table_name="BOND_POSITIONS")
        with patch("api.main.get_kuzu_store", return_value=mock_store):
            resp = client.post("/graph/index", json=payload, headers=auth_headers)
        assert resp.status_code == 200
        mock_store.upsert_schema_table.assert_called_once()
        mock_store.link_pair_to_table.assert_called_once_with("p-001", "BOND_POSITIONS")

    def test_index_with_pattern_links_pattern(self, client, auth_headers, mock_store):
        payload = self._payload(
            pattern_text="SELECT SUM(t.MTM)", agg_func="SUM", complexity="moderate"
        )
        with patch("api.main.get_kuzu_store", return_value=mock_store):
            resp = client.post("/graph/index", json=payload, headers=auth_headers)
        assert resp.status_code == 200
        mock_store.upsert_sql_pattern.assert_called_once_with("SELECT SUM(t.MTM)", "SUM", "moderate")
        mock_store.link_pair_to_pattern.assert_called_once_with("p-001", "SELECT SUM(t.MTM)")

    def test_index_no_template_skips_template_upsert(self, client, auth_headers, mock_store):
        with patch("api.main.get_kuzu_store", return_value=mock_store):
            client.post("/graph/index", json=self._payload(), headers=auth_headers)
        mock_store.upsert_prompt_template.assert_not_called()
        mock_store.link_pair_to_template.assert_not_called()

    def test_index_no_table_skips_table_upsert(self, client, auth_headers, mock_store):
        with patch("api.main.get_kuzu_store", return_value=mock_store):
            client.post("/graph/index", json=self._payload(), headers=auth_headers)
        mock_store.upsert_schema_table.assert_not_called()
        mock_store.link_pair_to_table.assert_not_called()

    def test_index_missing_required_fields_returns_422(self, client, auth_headers):
        resp = client.post("/graph/index", json={"pair_id": "p1"}, headers=auth_headers)
        assert resp.status_code == 422

    def test_index_default_source_is_template_expansion(self, client, auth_headers, mock_store):
        with patch("api.main.get_kuzu_store", return_value=mock_store):
            client.post("/graph/index", json=self._payload(), headers=auth_headers)
        call_args = mock_store.upsert_training_pair.call_args
        assert call_args[0][5] == "template_expansion"

    def test_index_custom_source(self, client, auth_headers, mock_store):
        payload = self._payload(source="manual")
        with patch("api.main.get_kuzu_store", return_value=mock_store):
            client.post("/graph/index", json=payload, headers=auth_headers)
        call_args = mock_store.upsert_training_pair.call_args
        assert call_args[0][5] == "manual"


class TestGraphQueryEndpoint:
    def test_query_unavailable_store(self, client):
        store = _make_mock_store(available=False)
        with patch("api.main.get_kuzu_store", return_value=store):
            resp = client.post("/graph/query", json={"cypher": "MATCH (n) RETURN n"})
        assert resp.status_code == 200
        body = resp.json()
        assert body["status"] == "unavailable"
        assert body["rows"] == []

    def test_query_returns_rows(self, client, mock_store):
        mock_store.query.return_value = [{"id": "p1", "question": "Q"}]
        with patch("api.main.get_kuzu_store", return_value=mock_store):
            resp = client.post("/graph/query", json={"cypher": "MATCH (p:TrainingPair) RETURN p"})
        assert resp.status_code == 200
        body = resp.json()
        assert body["status"] == "ok"
        assert body["count"] == 1
        assert body["rows"][0]["id"] == "p1"

    def test_query_write_cypher_returns_400(self, client):
        import api.kuzu_store as ks_mod
        store = ks_mod.KuzuStore.__new__(ks_mod.KuzuStore)
        store._conn = MagicMock()
        store._db = MagicMock()
        # Real store raises ValueError for write Cypher
        with patch("api.main.get_kuzu_store", return_value=store):
            resp = client.post("/graph/query", json={"cypher": "CREATE (n:Foo)"})
        assert resp.status_code == 400

    def test_query_empty_rows(self, client, mock_store):
        mock_store.query.return_value = []
        with patch("api.main.get_kuzu_store", return_value=mock_store):
            resp = client.post("/graph/query", json={"cypher": "MATCH (n) RETURN n"})
        assert resp.status_code == 200
        assert resp.json()["count"] == 0

    def test_query_passes_params(self, client, mock_store):
        mock_store.query.return_value = []
        with patch("api.main.get_kuzu_store", return_value=mock_store):
            resp = client.post(
                "/graph/query",
                json={"cypher": "MATCH (p:TrainingPair {domain: $d}) RETURN p", "params": {"d": "esg"}},
            )
        assert resp.status_code == 200
        mock_store.query.assert_called_once_with(
            "MATCH (p:TrainingPair {domain: $d}) RETURN p", {"d": "esg"}
        )

    def test_query_no_params_defaults_to_none(self, client, mock_store):
        mock_store.query.return_value = []
        with patch("api.main.get_kuzu_store", return_value=mock_store):
            resp = client.post("/graph/query", json={"cypher": "MATCH (n) RETURN n"})
        assert resp.status_code == 200
        mock_store.query.assert_called_once_with("MATCH (n) RETURN n", None)

    def test_query_missing_cypher_returns_422(self, client):
        resp = client.post("/graph/query", json={})
        assert resp.status_code == 422


class TestGraphStatsEndpoint:
    def test_stats_unavailable(self, client):
        store = _make_mock_store(available=False)
        with patch("api.main.get_kuzu_store", return_value=store):
            resp = client.get("/graph/stats")
        assert resp.status_code == 200
        body = resp.json()
        assert body["available"] is False
        assert body["pair_count"] == 0

    def test_stats_available_with_count(self, client):
        store = _make_mock_store(available=True)
        store.get_pair_count.return_value = 37
        with patch("api.main.get_kuzu_store", return_value=store):
            resp = client.get("/graph/stats")
        assert resp.status_code == 200
        body = resp.json()
        assert body["available"] is True
        assert body["pair_count"] == 37

    def test_stats_available_zero_count(self, client):
        store = _make_mock_store(available=True)
        store.get_pair_count.return_value = 0
        with patch("api.main.get_kuzu_store", return_value=store):
            resp = client.get("/graph/stats")
        assert resp.status_code == 200
        assert resp.json()["pair_count"] == 0


# ---------------------------------------------------------------------------
# TestAuthPersistence — SQLite-backed ApiKeyStore
# ---------------------------------------------------------------------------

class TestApiKeyStore:
    def _store(self):
        import api.auth as auth_mod
        return auth_mod.ApiKeyStore(db_path=":memory:")

    def test_add_and_contains(self):
        store = self._store()
        store.add("hash123", "test-key")
        assert store.contains("hash123")

    def test_not_contains_unknown(self):
        store = self._store()
        assert not store.contains("unknown_hash")

    def test_touch_updates_last_used(self):
        store = self._store()
        store.add("hash456", "test-key")
        store.touch("hash456")
        keys = store.list_keys()
        assert len(keys) == 1
        assert keys[0]["last_used"] is not None

    def test_delete_removes_key(self):
        store = self._store()
        store.add("hash789", "to-delete")
        assert store.delete("hash789")
        assert not store.contains("hash789")

    def test_delete_nonexistent_returns_false(self):
        store = self._store()
        assert not store.delete("nonexistent")

    def test_list_keys_empty(self):
        store = self._store()
        assert store.list_keys() == []

    def test_list_keys_multiple(self):
        store = self._store()
        store.add("h1", "key-1")
        store.add("h2", "key-2")
        keys = store.list_keys()
        assert len(keys) == 2

    def test_add_idempotent(self):
        store = self._store()
        store.add("hdup", "dup-key")
        store.add("hdup", "dup-key")  # INSERT OR IGNORE
        assert len(store.list_keys()) == 1

    def test_generate_api_key_persists(self):
        import api.auth as auth_mod
        orig = auth_mod._key_store
        auth_mod._key_store = auth_mod.ApiKeyStore(db_path=":memory:")
        key = auth_mod.generate_api_key("persist-test")
        assert key.startswith("mo-")
        key_hash = hashlib.sha256(key.encode()).hexdigest()
        assert auth_mod._key_store.contains(key_hash)
        auth_mod._key_store = orig

    def test_validate_api_key_true_for_generated(self):
        import api.auth as auth_mod
        orig = auth_mod._key_store
        auth_mod._key_store = auth_mod.ApiKeyStore(db_path=":memory:")
        key = auth_mod.generate_api_key("validate-test")
        assert auth_mod.validate_api_key(key)
        auth_mod._key_store = orig

    def test_validate_api_key_false_for_unknown(self):
        import api.auth as auth_mod
        orig = auth_mod._key_store
        auth_mod._key_store = auth_mod.ApiKeyStore(db_path=":memory:")
        assert not auth_mod.validate_api_key("not-a-real-key")
        auth_mod._key_store = orig

    def test_validate_empty_string_false(self):
        import api.auth as auth_mod
        assert not auth_mod.validate_api_key("")

    def test_key_store_survives_re_instantiation(self):
        """Simulates restart: re-open same db_path and key is still there."""
        import tempfile, os
        import api.auth as auth_mod
        with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as f:
            db_path = f.name
        try:
            s1 = auth_mod.ApiKeyStore(db_path=db_path)
            s1.add("persist_hash", "my-key")
            # Re-open
            s2 = auth_mod.ApiKeyStore(db_path=db_path)
            assert s2.contains("persist_hash")
        finally:
            os.unlink(db_path)


# ---------------------------------------------------------------------------
# TestKuzuStoreStructural
# ---------------------------------------------------------------------------

class TestKuzuStoreStructural:
    def test_module_exports_kuzu_store(self):
        from api.kuzu_store import KuzuStore
        assert KuzuStore is not None

    def test_module_exports_get_kuzu_store(self):
        from api.kuzu_store import get_kuzu_store
        assert callable(get_kuzu_store)

    def test_kuzu_store_has_upsert_training_pair(self):
        from api.kuzu_store import KuzuStore
        assert hasattr(KuzuStore, "upsert_training_pair")

    def test_kuzu_store_has_upsert_schema_table(self):
        from api.kuzu_store import KuzuStore
        assert hasattr(KuzuStore, "upsert_schema_table")

    def test_kuzu_store_has_upsert_prompt_template(self):
        from api.kuzu_store import KuzuStore
        assert hasattr(KuzuStore, "upsert_prompt_template")

    def test_kuzu_store_has_upsert_sql_pattern(self):
        from api.kuzu_store import KuzuStore
        assert hasattr(KuzuStore, "upsert_sql_pattern")

    def test_kuzu_store_has_link_methods(self):
        from api.kuzu_store import KuzuStore
        assert hasattr(KuzuStore, "link_pair_to_template")
        assert hasattr(KuzuStore, "link_pair_to_table")
        assert hasattr(KuzuStore, "link_pair_to_pattern")

    def test_kuzu_store_has_query(self):
        from api.kuzu_store import KuzuStore
        assert hasattr(KuzuStore, "query")

    def test_kuzu_store_has_available(self):
        from api.kuzu_store import KuzuStore
        assert hasattr(KuzuStore, "available")

    def test_kuzu_store_has_helper_queries(self):
        from api.kuzu_store import KuzuStore
        assert hasattr(KuzuStore, "get_pairs_for_domain")
        assert hasattr(KuzuStore, "get_patterns_for_difficulty")
        assert hasattr(KuzuStore, "get_tables_for_domain")
        assert hasattr(KuzuStore, "get_pair_count")

    def test_main_has_graph_index_route(self):
        from api.main import app
        paths = [r.path for r in app.routes]
        assert "/graph/index" in paths

    def test_main_has_graph_query_route(self):
        from api.main import app
        paths = [r.path for r in app.routes]
        assert "/graph/query" in paths

    def test_main_has_graph_stats_route(self):
        from api.main import app
        paths = [r.path for r in app.routes]
        assert "/graph/stats" in paths
