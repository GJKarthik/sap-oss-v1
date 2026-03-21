import importlib
import sys
import types
from pathlib import Path
from unittest.mock import MagicMock

import pandas as pd


def _package(name):
    module = types.ModuleType(name)
    module.__path__ = []
    return module


class FakeVectorStore:
    def __init__(self, texts=None):
        self.texts = list(texts or [])
        self.saved_paths = []

    def save_local(self, path):
        self.saved_paths.append(path)


class FakeFAISS:
    from_texts_calls = []

    @classmethod
    def reset(cls):
        cls.from_texts_calls = []

    @classmethod
    def load_local(cls, *_args, **_kwargs):
        raise FileNotFoundError("missing index")

    @classmethod
    def from_texts(cls, texts, embedding):
        cls.from_texts_calls.append(list(texts))
        return FakeVectorStore(texts)

    @classmethod
    def from_documents(cls, docs, _embedding):
        return FakeVectorStore([doc.page_content for doc in docs])


class FakeHanaDB:
    init_calls = []
    from_texts_calls = []

    def __init__(self, embedding, connection, table_name):
        type(self).init_calls.append((embedding, connection, table_name))

    @classmethod
    def reset(cls):
        cls.init_calls = []
        cls.from_texts_calls = []


def _compat_class(name):
    return type(name, (), {"__init__": lambda self, *args, **kwargs: None})


def _import_rag_module(monkeypatch):
    src_dir = Path(__file__).resolve().parents[1] / "src"
    monkeypatch.syspath_prepend(str(src_dir))
    FakeFAISS.reset()
    FakeHanaDB.reset()

    dump_mod = types.ModuleType("langchain.load.dump")
    dump_mod.dumps = lambda value: value
    monkeypatch.setitem(sys.modules, "langchain", _package("langchain"))
    monkeypatch.setitem(sys.modules, "langchain.load", _package("langchain.load"))
    monkeypatch.setitem(sys.modules, "langchain.load.dump", dump_mod)

    splitters_mod = types.ModuleType("langchain_text_splitters")
    splitters_mod.RecursiveCharacterTextSplitter = _compat_class("RecursiveCharacterTextSplitter")
    monkeypatch.setitem(sys.modules, "langchain_text_splitters", splitters_mod)

    community_mod = _package("langchain_community")
    chat_histories_mod = types.ModuleType("langchain_community.chat_message_histories")
    chat_histories_mod.SQLChatMessageHistory = _compat_class("SQLChatMessageHistory")
    vectorstores_mod = types.ModuleType("langchain_community.vectorstores")
    vectorstores_mod.FAISS = FakeFAISS
    hanavector_mod = types.ModuleType("langchain_community.vectorstores.hanavector")
    hanavector_mod.HanaDB = FakeHanaDB
    community_mod.chat_message_histories = chat_histories_mod
    community_mod.vectorstores = vectorstores_mod
    vectorstores_mod.hanavector = hanavector_mod
    monkeypatch.setitem(sys.modules, "langchain_community", community_mod)
    monkeypatch.setitem(sys.modules, "langchain_community.chat_message_histories", chat_histories_mod)
    monkeypatch.setitem(sys.modules, "langchain_community.vectorstores", vectorstores_mod)
    monkeypatch.setitem(sys.modules, "langchain_community.vectorstores.hanavector", hanavector_mod)

    sqlalchemy_mod = types.ModuleType("sqlalchemy")
    sqlalchemy_mod.delete = lambda *_args, **_kwargs: None
    monkeypatch.setitem(sys.modules, "sqlalchemy", sqlalchemy_mod)

    utility_mod = types.ModuleType("hana_ml.algorithms.pal.utility")
    utility_mod.check_pal_function_exist = lambda *_args, **_kwargs: False
    monkeypatch.setitem(sys.modules, "hana_ml", _package("hana_ml"))
    monkeypatch.setitem(sys.modules, "hana_ml.algorithms", _package("hana_ml.algorithms"))
    monkeypatch.setitem(sys.modules, "hana_ml.algorithms.pal", _package("hana_ml.algorithms.pal"))
    monkeypatch.setitem(sys.modules, "hana_ml.algorithms.pal.utility", utility_mod)

    compat_mod = types.ModuleType("hana_ai.langchain_compat")
    for name in ["AIMessage", "BaseTool", "Embeddings", "FormatSafeAgentExecutor", "HumanMessage", "MessagesPlaceholder", "SystemMessage", "Tool"]:
        setattr(compat_mod, name, _compat_class(name))
    compat_mod.ChatPromptTemplate = type("ChatPromptTemplate", (), {"from_messages": classmethod(lambda cls, messages: messages)})
    compat_mod.HumanMessagePromptTemplate = type("HumanMessagePromptTemplate", (), {"from_template": classmethod(lambda cls, template: template)})
    compat_mod.build_agent_executor = lambda *_args, **_kwargs: (None, None)
    compat_mod.get_conversation_buffer_window_memory = lambda **_kwargs: types.SimpleNamespace(clear=lambda: None)
    monkeypatch.setitem(sys.modules, "hana_ai.langchain_compat", compat_mod)

    agents_util_mod = types.ModuleType("hana_ai.agents.utilities")
    agents_util_mod._check_generated_cap_for_bas = lambda *_args, **_kwargs: None
    agents_util_mod._get_user_info = lambda *_args, **_kwargs: "user"
    agents_util_mod._inspect_python_code = lambda *_args, **_kwargs: None
    monkeypatch.setitem(sys.modules, "hana_ai.agents.utilities", agents_util_mod)

    embedding_service_mod = types.ModuleType("hana_ai.vectorstore.embedding_service")
    embedding_service_mod.GenAIHubEmbeddings = _compat_class("GenAIHubEmbeddings")
    embedding_service_mod.HANAVectorEmbeddings = _compat_class("HANAVectorEmbeddings")
    monkeypatch.setitem(sys.modules, "hana_ai.vectorstore.embedding_service", embedding_service_mod)

    pal_cross_encoder_mod = types.ModuleType("hana_ai.vectorstore.pal_cross_encoder")
    pal_cross_encoder_mod.PALCrossEncoder = _compat_class("PALCrossEncoder")
    monkeypatch.setitem(sys.modules, "hana_ai.vectorstore.pal_cross_encoder", pal_cross_encoder_mod)

    sys.modules.pop("hana_ai.agents.hanaml_rag_agent", None)
    return importlib.import_module("hana_ai.agents.hanaml_rag_agent")


def _build_agent(rag_module, vectorstore_type="faiss"):
    agent = rag_module.HANAMLRAGAgent.__new__(rag_module.HANAMLRAGAgent)
    agent.embedding_service = object()
    agent.vectorstore_path = "vectorstore-path"
    agent.vectorstore_type = vectorstore_type
    agent.skip_large_data_threshold = 10
    agent._verify_faiss_checksum = lambda _path: True
    agent._save_faiss_checksum = MagicMock()
    return agent


def test_faiss_initialization_and_reset_paths_do_not_seed_placeholder_documents(monkeypatch):
    rag_module = _import_rag_module(monkeypatch)
    agent = _build_agent(rag_module)
    agent.long_term_store = types.SimpleNamespace(clear=MagicMock())

    agent._initialize_faiss_vectorstore()
    agent.clear_long_term_memory()

    assert FakeFAISS.from_texts_calls == [[], []]
    assert agent.vectorstore.saved_paths == ["vectorstore-path"]
    assert agent._save_faiss_checksum.call_count == 2


def test_forget_old_memories_rebuilds_to_empty_faiss_without_placeholder_documents(monkeypatch):
    rag_module = _import_rag_module(monkeypatch)
    agent = _build_agent(rag_module)
    agent.long_term_memory_limit = 1
    agent.forget_percentage = 1.0
    agent.chunk_size = 100
    agent.chunk_overlap = 10
    messages = [types.SimpleNamespace(id="1", metadata={"timestamp": "2024-01-01"}), types.SimpleNamespace(id="2", metadata={"timestamp": "2024-01-02"})]
    store = types.SimpleNamespace(messages=messages)
    agent.long_term_store = store
    agent.delete_message_long_term_store = lambda _message_id: store.messages.clear()

    agent._forget_old_memories()

    assert FakeFAISS.from_texts_calls == [[]]
    assert agent.vectorstore.saved_paths == ["vectorstore-path"]
    agent._save_faiss_checksum.assert_called_once_with("vectorstore-path")


def test_clear_long_term_memory_reinitializes_hanadb_without_placeholder_text(monkeypatch):
    rag_module = _import_rag_module(monkeypatch)
    agent = _build_agent(rag_module, vectorstore_type="hanadb")
    agent.long_term_store = types.SimpleNamespace(clear=MagicMock())
    agent.hana_vector_table = "RAG_TABLE"
    agent.hana_connection_context = types.SimpleNamespace(connection="conn", drop_table=MagicMock())

    agent.clear_long_term_memory()

    assert FakeHanaDB.from_texts_calls == []
    assert FakeHanaDB.init_calls == [(agent.embedding_service, "conn", "RAG_TABLE")]


def test_should_store_rejects_large_and_special_content(monkeypatch):
    rag_module = _import_rag_module(monkeypatch)
    agent = _build_agent(rag_module)

    assert agent._should_store("small") is True
    assert agent._should_store("x" * 11) is False
    assert agent._should_store(pd.DataFrame({"col": [1, 2]})) is False
    assert agent._should_store(b"binary") is False
    assert agent._should_store({"payload": b"binary"}) is False