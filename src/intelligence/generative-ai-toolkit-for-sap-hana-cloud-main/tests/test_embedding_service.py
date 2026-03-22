from __future__ import annotations

import importlib.util
import sys
import types
import uuid
from pathlib import Path


def _load_embedding_service(monkeypatch, dropped_tables: list[str]):
    pandas_mod = types.ModuleType("pandas")
    pandas_mod.DataFrame = object
    monkeypatch.setitem(sys.modules, "pandas", pandas_mod)

    langchain_base = types.ModuleType("langchain.embeddings.base")
    langchain_base.Embeddings = object
    monkeypatch.setitem(sys.modules, "langchain", types.ModuleType("langchain"))
    monkeypatch.setitem(sys.modules, "langchain.embeddings", types.ModuleType("langchain.embeddings"))
    monkeypatch.setitem(sys.modules, "langchain.embeddings.base", langchain_base)

    proxy_langchain = types.ModuleType("gen_ai_hub.proxy.langchain")
    proxy_langchain.init_embedding_model = lambda *args, **kwargs: None
    monkeypatch.setitem(sys.modules, "gen_ai_hub", types.ModuleType("gen_ai_hub"))
    monkeypatch.setitem(sys.modules, "gen_ai_hub.proxy", types.ModuleType("gen_ai_hub.proxy"))
    monkeypatch.setitem(sys.modules, "gen_ai_hub.proxy.langchain", proxy_langchain)

    dataframe_mod = types.ModuleType("hana_ml.dataframe")
    dataframe_mod.ConnectionContext = object
    dataframe_mod.create_dataframe_from_pandas = lambda *args, **kwargs: None
    pal_embeddings_mod = types.ModuleType("hana_ml.text.pal_embeddings")
    pal_embeddings_mod.PALEmbeddings = object
    pal_base_mod = types.ModuleType("hana_ml.algorithms.pal.pal_base")
    pal_base_mod.try_drop = lambda _cc, table: dropped_tables.append(table)
    monkeypatch.setitem(sys.modules, "hana_ml", types.ModuleType("hana_ml"))
    monkeypatch.setitem(sys.modules, "hana_ml.dataframe", dataframe_mod)
    monkeypatch.setitem(sys.modules, "hana_ml.text", types.ModuleType("hana_ml.text"))
    monkeypatch.setitem(sys.modules, "hana_ml.text.pal_embeddings", pal_embeddings_mod)
    monkeypatch.setitem(sys.modules, "hana_ml.algorithms", types.ModuleType("hana_ml.algorithms"))
    monkeypatch.setitem(sys.modules, "hana_ml.algorithms.pal", types.ModuleType("hana_ml.algorithms.pal"))
    monkeypatch.setitem(sys.modules, "hana_ml.algorithms.pal.pal_base", pal_base_mod)

    module_path = Path(__file__).resolve().parents[1] / "src" / "hana_ai" / "vectorstore" / "embedding_service.py"
    module_name = f"embedding_service_under_test_{uuid.uuid4().hex}"
    spec = importlib.util.spec_from_file_location(module_name, module_path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


class FakeCursor:
    def __init__(self):
        self.execute_calls: list[str] = []
        self.executemany_calls: list[tuple[str, list[tuple[int, str]]]] = []

    def execute(self, sql: str):
        self.execute_calls.append(sql)

    def executemany(self, sql: str, params):
        self.executemany_calls.append((sql, list(params)))

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False


class FakeQueryFrame:
    def __init__(self, rows):
        self.rows = rows
        self.add_vector_kwargs = None
        self.selected = None

    def add_vector(self, column, **kwargs):
        assert column == "TEXT"
        self.add_vector_kwargs = kwargs
        return self

    def select(self, columns):
        self.selected = columns
        return self

    def collect(self):
        return types.SimpleNamespace(to_numpy=lambda: self.rows)


class FakeConnectionContext:
    def __init__(self, rows):
        self.cursor_obj = FakeCursor()
        self.connection = types.SimpleNamespace(cursor=lambda: self.cursor_obj)
        self.sql_calls: list[str] = []
        self.frame = FakeQueryFrame(rows)

    def sql(self, sql: str):
        self.sql_calls.append(sql)
        return self.frame


def test_cc_embed_query_uses_bind_parameters_for_batch_inputs(monkeypatch):
    dropped_tables: list[str] = []
    module = _load_embedding_service(monkeypatch, dropped_tables)
    malicious = "abc' UNION ALL SELECT secret FROM users --"
    cc = FakeConnectionContext(rows=[[[1.0, 2.0]], [[3.0, 4.0]]])

    result = module._cc_embed_query(cc, [malicious, "safe text"], model_version="TEST_MODEL")

    assert result == [[1.0, 2.0], [3.0, 4.0]]
    insert_sql, params = cc.cursor_obj.executemany_calls[0]
    table_name = dropped_tables[0]
    assert table_name.startswith("#CC_EMBED_QUERY_")
    assert "VALUES (?, ?)" in insert_sql
    assert params == [(0, malicious), (1, "safe text")]
    assert malicious not in cc.cursor_obj.execute_calls[0]
    assert malicious not in insert_sql
    assert malicious not in cc.sql_calls[0]
    assert table_name in cc.cursor_obj.execute_calls[0]
    assert table_name in insert_sql
    assert table_name in cc.sql_calls[0]
    assert cc.frame.add_vector_kwargs == {"text_type": "QUERY", "embed_col": "EMBEDDING", "model_version": "TEST_MODEL"}
    assert cc.frame.selected == ["EMBEDDING"]


def test_cc_embed_query_single_input_still_uses_bound_batch_insert(monkeypatch):
    module = _load_embedding_service(monkeypatch, [])
    text = "hello ' world"
    cc = FakeConnectionContext(rows=[[[9.0]]])

    result = module._cc_embed_query(cc, text)

    assert result == [[9.0]]
    insert_sql, params = cc.cursor_obj.executemany_calls[0]
    assert "VALUES (?, ?)" in insert_sql
    assert params == [(0, text)]