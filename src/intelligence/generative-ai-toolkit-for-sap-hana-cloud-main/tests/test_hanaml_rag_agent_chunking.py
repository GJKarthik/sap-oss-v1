import importlib
import inspect
import sys
import types
from pathlib import Path
from types import SimpleNamespace

import pytest


class FakeDocument:
    def __init__(self, page_content, metadata):
        self.page_content = page_content
        self.metadata = dict(metadata)


class FakeSplitter:
    init_calls = []

    def __init__(self, **kwargs):
        type(self).init_calls.append(kwargs)

    def create_documents(self, texts, metadatas):
        metadata = dict(metadatas[0])
        return [FakeDocument(f"{texts[0]} [1]", metadata), FakeDocument(f"{texts[0]} [2]", metadata)]


class FakeFAISSStore:
    last_from_documents = None

    def __init__(self):
        self.added_documents = []

    def add_documents(self, documents):
        self.added_documents.extend(documents)

    def save_local(self, _path):
        return None

    @classmethod
    def from_documents(cls, documents, embedding):
        cls.last_from_documents = {"documents": list(documents), "embedding": embedding}
        store = cls()
        store.add_documents(documents)
        return store

    @classmethod
    def from_texts(cls, _texts, embedding=None):
        cls.last_from_documents = {"documents": [], "embedding": embedding}
        return cls()


class FakeMessage:
    def __init__(self, content=None, metadata=None, id=None):
        self.content = content
        self.metadata = metadata or {}
        self.id = id or self.metadata.get("timestamp", "msg")


def _package(name):
    module = types.ModuleType(name)
    module.__path__ = []
    return module


@pytest.fixture
def rag_module(monkeypatch):
    src_dir = Path(__file__).resolve().parents[1] / "src"
    monkeypatch.syspath_prepend(str(src_dir))
    FakeSplitter.init_calls.clear()
    FakeFAISSStore.last_from_documents = None

    monkeypatch.setitem(sys.modules, "sqlalchemy", types.SimpleNamespace(delete=lambda *args, **kwargs: None))
    monkeypatch.setitem(sys.modules, "langchain_text_splitters", types.SimpleNamespace(RecursiveCharacterTextSplitter=FakeSplitter))
    monkeypatch.setitem(sys.modules, "langchain_core.load.dump", types.SimpleNamespace(dumps=lambda value: value))
    monkeypatch.setitem(sys.modules, "langchain_community.chat_message_histories", types.SimpleNamespace(SQLChatMessageHistory=object))
    monkeypatch.setitem(sys.modules, "langchain_community.vectorstores", types.SimpleNamespace(FAISS=FakeFAISSStore))
    monkeypatch.setitem(sys.modules, "langchain_community.vectorstores.hanavector", types.SimpleNamespace(HanaDB=object))
    monkeypatch.setitem(sys.modules, "hana_ml.algorithms.pal.utility", types.SimpleNamespace(check_pal_function_exist=lambda *_args, **_kwargs: False))
    monkeypatch.setitem(
        sys.modules,
        "hana_ai.langchain_compat",
        types.SimpleNamespace(
            AIMessage=FakeMessage,
            BaseTool=object,
            ChatPromptTemplate=object,
            Embeddings=object,
            FormatSafeAgentExecutor=object,
            HumanMessage=FakeMessage,
            HumanMessagePromptTemplate=object,
            MessagesPlaceholder=object,
            SystemMessage=object,
            Tool=object,
            build_agent_executor=lambda *_args, **_kwargs: None,
            get_conversation_buffer_window_memory=lambda *_args, **_kwargs: SimpleNamespace(chat_memory=SimpleNamespace(messages=[])),
        ),
    )
    monkeypatch.setitem(
        sys.modules,
        "hana_ai.agents.utilities",
        types.SimpleNamespace(
            _check_generated_cap_for_bas=lambda *_args, **_kwargs: None,
            _get_user_info=lambda *_args, **_kwargs: "test-user",
            _inspect_python_code=lambda *_args, **_kwargs: None,
        ),
    )
    monkeypatch.setitem(sys.modules, "hana_ai.vectorstore.embedding_service", types.SimpleNamespace(GenAIHubEmbeddings=object, HANAVectorEmbeddings=object))
    monkeypatch.setitem(sys.modules, "hana_ai.vectorstore.pal_cross_encoder", types.SimpleNamespace(PALCrossEncoder=object))

    sys.modules.pop("hana_ai.agents.hanaml_rag_agent", None)
    return importlib.import_module("hana_ai.agents.hanaml_rag_agent")


def test_chunking_defaults_are_updated(rag_module):
    params = inspect.signature(rag_module.HANAMLRAGAgent.__init__).parameters
    assert params["chunk_size"].default == 1000
    assert params["chunk_overlap"].default == 200


def test_update_long_term_memory_adds_chunk_metadata(rag_module):
    store = SimpleNamespace(messages=[])
    store.add_messages = lambda messages: store.messages.extend(messages)
    agent = rag_module.HANAMLRAGAgent.__new__(rag_module.HANAMLRAGAgent)
    agent.chunk_size = 1000
    agent.chunk_overlap = 200
    agent.long_term_store = store
    agent.vectorstore = FakeFAISSStore()
    agent.vectorstore_type = "hanadb"
    agent._should_store = lambda _response: True
    agent._forget_old_memories = lambda: None

    agent._update_long_term_memory("hello", "world")

    assert FakeSplitter.init_calls[-1]["separators"] == ["\nUser: ", "\nAssistant: ", "\n\n", "\n", " "]
    assert [doc.metadata["chunk_index"] for doc in agent.vectorstore.added_documents] == [0, 1]
    assert all(doc.metadata["total_chunks"] == 2 for doc in agent.vectorstore.added_documents)


def test_forget_old_memories_rebuilds_chunks_with_metadata(rag_module):
    agent = rag_module.HANAMLRAGAgent.__new__(rag_module.HANAMLRAGAgent)
    agent.chunk_size = 1000
    agent.chunk_overlap = 200
    agent.forget_percentage = 0.5
    agent.long_term_memory_limit = 4
    agent.vectorstore_type = "faiss"
    agent.embedding_service = object()
    agent.vectorstore_path = "fake-index"
    agent._save_faiss_checksum = lambda _path: None
    agent.long_term_store = SimpleNamespace(messages=[
        FakeMessage("old-user", {"timestamp": "2024-01-01T00:00:00"}, "m1"),
        FakeMessage("old-ai", {"timestamp": "2024-01-01T00:00:01"}, "m2"),
        FakeMessage("keep-user-1", {"timestamp": "2024-01-01T00:00:02"}, "m3"),
        FakeMessage("keep-ai-1", {"timestamp": "2024-01-01T00:00:03"}, "m4"),
        FakeMessage("keep-user-2", {"timestamp": "2024-01-01T00:00:04"}, "m5"),
        FakeMessage("keep-ai-2", {"timestamp": "2024-01-01T00:00:05"}, "m6"),
    ])
    agent.delete_message_long_term_store = lambda message_id: setattr(
        agent.long_term_store,
        "messages",
        [message for message in agent.long_term_store.messages if message.id != message_id],
    )

    agent._forget_old_memories()

    rebuilt = FakeFAISSStore.last_from_documents["documents"]
    assert FakeSplitter.init_calls[-1]["separators"] == ["\nUser: ", "\nAssistant: ", "\n\n", "\n", " "]
    assert [doc.metadata["chunk_index"] for doc in rebuilt] == [0, 1, 0, 1]
    assert all(doc.metadata["total_chunks"] == 2 for doc in rebuilt)