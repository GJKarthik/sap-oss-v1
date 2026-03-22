import importlib
import sys
import types
from pathlib import Path


def _package(name):
    module = types.ModuleType(name)
    module.__path__ = []
    return module


def _import_corrective_retriever(monkeypatch):
    src_dir = Path(__file__).resolve().parents[1] / "src"
    monkeypatch.syspath_prepend(str(src_dir))

    class DummyStateGraph:
        def __init__(self, *_args, **_kwargs):
            pass

    monkeypatch.setitem(sys.modules, "langgraph", _package("langgraph"))
    monkeypatch.setitem(
        sys.modules,
        "langgraph.graph",
        types.SimpleNamespace(END="END", StateGraph=DummyStateGraph),
    )
    monkeypatch.setitem(sys.modules, "langchain_core", _package("langchain_core"))
    monkeypatch.setitem(sys.modules, "langchain_core.utils", _package("langchain_core.utils"))
    monkeypatch.setitem(
        sys.modules,
        "langchain_core.utils.function_calling",
        types.SimpleNamespace(convert_to_openai_tool=lambda tool: tool),
    )
    monkeypatch.setitem(
        sys.modules,
        "hana_ai.langchain_compat",
        types.SimpleNamespace(PydanticToolsParser=object, PromptTemplate=object),
    )

    sys.modules.pop("hana_ai.vectorstore.corrective_retriever", None)
    return importlib.import_module("hana_ai.vectorstore.corrective_retriever")


def test_corrective_retriever_uses_nli_before_llm_fallback(monkeypatch):
    module = _import_corrective_retriever(monkeypatch)

    class FakeVectorDB:
        connection_context = None

    class ExplodingLLM:
        def bind(self, *_args, **_kwargs):
            raise AssertionError("LLM fallback should not be used when NLI prediction is available")

    retriever = module.CorrectiveRetriever(FakeVectorDB(), ExplodingLLM())
    retriever._nli_backend = types.SimpleNamespace(
        predict=lambda pairs: [
            {"label": "contradiction", "scores": {"contradiction": 0.9, "entailment": 0.05, "neutral": 0.05}}
        ]
    )

    result = retriever._grade_documents(
        {"keys": {"question": "What is SAP HANA?", "documents": "Irrelevant content", "top_k": 3, "init_k": 1}}
    )

    assert result["keys"]["run_second_search"] == "Yes"
    assert result["keys"]["init_k"] == 2


def test_corrective_retriever_keeps_document_when_nli_marks_relevant(monkeypatch):
    module = _import_corrective_retriever(monkeypatch)

    class FakeVectorDB:
        connection_context = None

    retriever = module.CorrectiveRetriever(FakeVectorDB(), llm=None)
    retriever._nli_backend = types.SimpleNamespace(
        predict=lambda pairs: [
            {"label": "entailment", "scores": {"contradiction": 0.1, "entailment": 0.8, "neutral": 0.1}}
        ]
    )

    result = retriever._grade_documents(
        {"keys": {"question": "What is SAP HANA?", "documents": "SAP HANA is an in-memory database.", "top_k": 3, "init_k": 1}}
    )

    assert result["keys"]["run_second_search"] == "No"
    assert result["keys"]["init_k"] == 1