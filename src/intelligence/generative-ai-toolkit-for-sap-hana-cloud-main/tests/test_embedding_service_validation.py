import importlib
import sys
import types
from pathlib import Path
from unittest.mock import MagicMock

import pandas as pd
import pytest


class FakePALColumn:
    def __init__(self, vectors):
        self.vectors = vectors

    def collect(self):
        return self

    def to_numpy(self):
        return [[vector] for vector in self.vectors]


class FakePALResult:
    columns = ["EMBEDDING", "META"]

    def __init__(self, vectors):
        self.vectors = vectors

    def __getitem__(self, _):
        return FakePALColumn(self.vectors)


class FakePALBackend:
    def __init__(self, vectors):
        self.vectors = vectors
        self.stat_ = MagicMock()
        self.stat_.collect.return_value = pd.DataFrame([[None, None], [None, "fake-model"]])
        self._fit_output_table_names = "#PAL_FAKE_OUTPUT"

    def fit_transform(self, **_kwargs):
        return FakePALResult(self.vectors)


class FakeGenAIModel:
    def __init__(self, vectors):
        self.embed_documents = MagicMock(return_value=vectors)
        self.embed_query = MagicMock(return_value=vectors[0])


def _package(name):
    module = types.ModuleType(name)
    module.__path__ = []
    return module


@pytest.fixture
def embedding_service(monkeypatch):
    src_dir = Path(__file__).resolve().parents[1] / "src"
    monkeypatch.syspath_prepend(str(src_dir))

    base_mod = types.ModuleType("langchain.embeddings.base")
    base_mod.Embeddings = type("Embeddings", (), {})
    langchain_embeddings_mod = _package("langchain.embeddings")
    langchain_embeddings_mod.base = base_mod
    langchain_mod = _package("langchain")
    langchain_mod.embeddings = langchain_embeddings_mod
    monkeypatch.setitem(sys.modules, "langchain.embeddings.base", base_mod)
    monkeypatch.setitem(sys.modules, "langchain.embeddings", langchain_embeddings_mod)
    monkeypatch.setitem(sys.modules, "langchain", langchain_mod)

    dataframe_mod = types.ModuleType("hana_ml.dataframe")
    dataframe_mod.ConnectionContext = type("ConnectionContext", (), {})
    dataframe_mod.create_dataframe_from_pandas = lambda *_args, **_kwargs: object()
    hana_ml_text_mod = _package("hana_ml.text")
    hana_ml_algorithms_pal_mod = _package("hana_ml.algorithms.pal")
    hana_ml_algorithms_mod = _package("hana_ml.algorithms")
    hana_ml_algorithms_mod.pal = hana_ml_algorithms_pal_mod
    hana_ml_mod = _package("hana_ml")
    hana_ml_mod.dataframe = dataframe_mod
    hana_ml_mod.text = hana_ml_text_mod
    hana_ml_mod.algorithms = hana_ml_algorithms_mod
    monkeypatch.setitem(sys.modules, "hana_ml.dataframe", dataframe_mod)

    pal_embeddings_mod = types.ModuleType("hana_ml.text.pal_embeddings")
    pal_embeddings_mod.PALEmbeddings = FakePALBackend
    hana_ml_text_mod.pal_embeddings = pal_embeddings_mod
    monkeypatch.setitem(sys.modules, "hana_ml.text.pal_embeddings", pal_embeddings_mod)

    pal_base_mod = types.ModuleType("hana_ml.algorithms.pal.pal_base")
    pal_base_mod.try_drop = lambda *_args, **_kwargs: None
    hana_ml_algorithms_pal_mod.pal_base = pal_base_mod
    monkeypatch.setitem(sys.modules, "hana_ml.algorithms.pal.pal_base", pal_base_mod)
    monkeypatch.setitem(sys.modules, "hana_ml.text", hana_ml_text_mod)
    monkeypatch.setitem(sys.modules, "hana_ml.algorithms.pal", hana_ml_algorithms_pal_mod)
    monkeypatch.setitem(sys.modules, "hana_ml.algorithms", hana_ml_algorithms_mod)
    monkeypatch.setitem(sys.modules, "hana_ml", hana_ml_mod)

    genai_langchain_mod = types.ModuleType("gen_ai_hub.proxy.langchain")
    genai_langchain_mod.init_embedding_model = lambda *_args, **_kwargs: FakeGenAIModel([[0.1, 0.2]])
    gen_ai_hub_proxy_mod = _package("gen_ai_hub.proxy")
    gen_ai_hub_proxy_mod.langchain = genai_langchain_mod
    gen_ai_hub_mod = _package("gen_ai_hub")
    gen_ai_hub_mod.proxy = gen_ai_hub_proxy_mod
    monkeypatch.setitem(sys.modules, "gen_ai_hub.proxy.langchain", genai_langchain_mod)
    monkeypatch.setitem(sys.modules, "gen_ai_hub.proxy", gen_ai_hub_proxy_mod)
    monkeypatch.setitem(sys.modules, "gen_ai_hub", gen_ai_hub_mod)

    sys.modules.pop("hana_ai.vectorstore.embedding_service", None)
    return importlib.import_module("hana_ai.vectorstore.embedding_service")


def test_validation_helpers_reject_invalid_inputs(embedding_service):
    with pytest.raises(ValueError, match="cannot be None"):
        embedding_service._validate_single_text(None, 10)
    with pytest.raises(ValueError, match="cannot be empty"):
        embedding_service._validate_single_text("", 10)
    with pytest.raises(ValueError, match="exceeds maximum length"):
        embedding_service._validate_single_text("toolong", 3)
    with pytest.raises(ValueError, match="cannot be empty"):
        embedding_service._validate_text_list([], 10)
    with pytest.raises(ValueError, match="must be a string"):
        embedding_service._validate_text_list(["ok", 1], 10)


def test_validate_embeddings_rejects_invalid_vectors_and_warns_on_near_zero(embedding_service, caplog):
    with pytest.raises(ValueError, match="all-zero embedding vector"):
        embedding_service._validate_embeddings([[0.0, 0.0]], "TestEmbeddings")
    with pytest.raises(ValueError, match="NaN embedding value"):
        embedding_service._validate_embeddings([[float("nan"), 1.0]], "TestEmbeddings")
    with pytest.raises(ValueError, match="inconsistent embedding dimensions"):
        embedding_service._validate_embeddings([[1.0, 2.0], [3.0]], "TestEmbeddings")

    with caplog.at_level("WARNING"):
        result = embedding_service._validate_embeddings([[1e-12, -1e-12]], "TestEmbeddings")
    assert result == [[1e-12, -1e-12]]
    assert "degenerate embedding" in caplog.text


def test_pal_model_embeddings_validate_inputs_before_backend_call(embedding_service, monkeypatch):
    pal_ctor = MagicMock(return_value=FakePALBackend([[1.0, 2.0]]))
    monkeypatch.setattr(embedding_service, "PALEmbeddings", pal_ctor)

    model = embedding_service.PALModelEmbeddings(connection_context=object(), max_text_length=4)
    with pytest.raises(ValueError, match="Embedding input list cannot be empty"):
        model.embed_documents([])
    with pytest.raises(ValueError, match="exceeds maximum length"):
        model.embed_query("hello")
    pal_ctor.assert_not_called()


def test_hana_vector_embeddings_validate_inputs_before_backend_call(embedding_service, monkeypatch):
    cc_embed_query = MagicMock(return_value=[[1.0, 2.0]])
    monkeypatch.setattr(embedding_service, "_cc_embed_query", cc_embed_query)

    model = embedding_service.HANAVectorEmbeddings(connection_context=object(), max_text_length=4)
    with pytest.raises(ValueError, match="Embedding input list cannot be empty"):
        model.embed_documents([])
    with pytest.raises(ValueError, match="Embedding query cannot be None"):
        model.embed_query(None)
    cc_embed_query.assert_not_called()


def test_genai_hub_embeddings_validate_inputs_before_backend_call(embedding_service, monkeypatch):
    backend = FakeGenAIModel([[1.0, 2.0]])
    factory = MagicMock(return_value=backend)
    monkeypatch.setattr(embedding_service, "gen_ai_hub_embedding_model", factory)

    model = embedding_service.GenAIHubEmbeddings(max_text_length=4)
    with pytest.raises(ValueError, match="Embedding input list must be a list of strings"):
        model.embed_documents("test")
    with pytest.raises(ValueError, match="Embedding query cannot be empty"):
        model.embed_query("")
    backend.embed_documents.assert_not_called()
    backend.embed_query.assert_not_called()


def test_post_embedding_validation_runs_for_each_embedding_class(embedding_service, monkeypatch):
    monkeypatch.setattr(embedding_service, "PALEmbeddings", MagicMock(return_value=FakePALBackend([[0.0, 0.0]])))
    with pytest.raises(ValueError, match="all-zero embedding vector"):
        embedding_service.PALModelEmbeddings(connection_context=object())("hello")

    monkeypatch.setattr(embedding_service, "_cc_embed_query", MagicMock(return_value=[[0.0, 0.0]]))
    with pytest.raises(ValueError, match="all-zero embedding vector"):
        embedding_service.HANAVectorEmbeddings(connection_context=object())("hello")

    backend = FakeGenAIModel([[0.0, 0.0]])
    monkeypatch.setattr(embedding_service, "gen_ai_hub_embedding_model", MagicMock(return_value=backend))
    with pytest.raises(ValueError, match="all-zero embedding vector"):
        embedding_service.GenAIHubEmbeddings()("hello")