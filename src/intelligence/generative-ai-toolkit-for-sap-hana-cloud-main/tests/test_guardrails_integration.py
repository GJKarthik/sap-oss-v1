import importlib
import sys
import types
from pathlib import Path
from unittest.mock import MagicMock

import pytest


def _package(name):
    module = types.ModuleType(name)
    module.__path__ = []
    return module


def _compat_class(name):
    return type(name, (), {"__init__": lambda self, *args, **kwargs: None})


def _import_smart_dataframe_module(monkeypatch):
    src_dir = Path(__file__).resolve().parents[1] / "src"
    monkeypatch.syspath_prepend(str(src_dir))

    dataframe_mod = types.ModuleType("hana_ml.dataframe")
    dataframe_mod.DataFrame = _compat_class("DataFrame")
    monkeypatch.setitem(sys.modules, "hana_ml", _package("hana_ml"))
    monkeypatch.setitem(sys.modules, "hana_ml.dataframe", dataframe_mod)

    compat_mod = types.ModuleType("hana_ai.langchain_compat")
    for name in [
        "AgentExecutor",
        "BaseLLM",
        "BaseTool",
        "MessagesPlaceholder",
        "SystemMessage",
    ]:
        setattr(compat_mod, name, _compat_class(name))
    compat_mod.ChatPromptTemplate = type(
        "ChatPromptTemplate",
        (),
        {"from_messages": classmethod(lambda cls, messages: messages)},
    )
    compat_mod.HumanMessagePromptTemplate = type(
        "HumanMessagePromptTemplate",
        (),
        {"from_template": classmethod(lambda cls, template: template)},
    )
    compat_mod.build_agent_executor = lambda *_args, **_kwargs: MagicMock()
    monkeypatch.setitem(sys.modules, "hana_ai.langchain_compat", compat_mod)

    for module_name, class_names in {
        "hana_ai.tools.df_tools.additive_model_forecast_tools": [
            "AdditiveModelForecastFitAndSave",
            "AdditiveModelForecastLoadModelAndPredict",
        ],
        "hana_ai.tools.df_tools.automatic_timeseries_tools": [
            "AutomaticTimeSeriesFitAndSave",
            "AutomaticTimeSeriesLoadModelAndPredict",
            "AutomaticTimeSeriesLoadModelAndScore",
        ],
        "hana_ai.tools.df_tools.fetch_tools": ["FetchDataTool"],
        "hana_ai.tools.df_tools.intermittent_forecast_tools": ["IntermittentForecast"],
        "hana_ai.tools.df_tools.ts_outlier_detection_tools": ["TSOutlierDetection"],
        "hana_ai.tools.df_tools.ts_visualizer_tools": ["TimeSeriesDatasetReport"],
    }.items():
        module = types.ModuleType(module_name)
        for class_name in class_names:
            setattr(module, class_name, _compat_class(class_name))
        monkeypatch.setitem(sys.modules, module_name, module)

    sys.modules.pop("hana_ai.smart_dataframe", None)
    return importlib.import_module("hana_ai.smart_dataframe")


def _import_rag_module(monkeypatch):
    src_dir = Path(__file__).resolve().parents[1] / "src"
    monkeypatch.syspath_prepend(str(src_dir))

    dump_mod = types.ModuleType("langchain.load.dump")
    dump_mod.dumps = lambda value: value
    monkeypatch.setitem(sys.modules, "langchain", _package("langchain"))
    monkeypatch.setitem(sys.modules, "langchain.load", _package("langchain.load"))
    monkeypatch.setitem(sys.modules, "langchain.load.dump", dump_mod)
    monkeypatch.setitem(
        sys.modules,
        "langchain_text_splitters",
        types.SimpleNamespace(RecursiveCharacterTextSplitter=_compat_class("RecursiveCharacterTextSplitter")),
    )

    monkeypatch.setitem(
        sys.modules,
        "langchain_community.chat_message_histories",
        types.SimpleNamespace(SQLChatMessageHistory=_compat_class("SQLChatMessageHistory")),
    )
    monkeypatch.setitem(
        sys.modules,
        "langchain_community.vectorstores",
        types.SimpleNamespace(FAISS=_compat_class("FAISS")),
    )
    monkeypatch.setitem(
        sys.modules,
        "langchain_community.vectorstores.hanavector",
        types.SimpleNamespace(HanaDB=_compat_class("HanaDB")),
    )
    monkeypatch.setitem(sys.modules, "sqlalchemy", types.SimpleNamespace(delete=lambda *_args, **_kwargs: None))
    monkeypatch.setitem(sys.modules, "hana_ml", _package("hana_ml"))
    monkeypatch.setitem(sys.modules, "hana_ml.algorithms", _package("hana_ml.algorithms"))
    monkeypatch.setitem(sys.modules, "hana_ml.algorithms.pal", _package("hana_ml.algorithms.pal"))
    monkeypatch.setitem(
        sys.modules,
        "hana_ml.algorithms.pal.utility",
        types.SimpleNamespace(check_pal_function_exist=lambda *_args, **_kwargs: False),
    )

    compat_mod = types.ModuleType("hana_ai.langchain_compat")
    for name in [
        "AIMessage",
        "BaseTool",
        "Embeddings",
        "FormatSafeAgentExecutor",
        "HumanMessage",
        "MessagesPlaceholder",
        "SystemMessage",
        "Tool",
    ]:
        setattr(compat_mod, name, _compat_class(name))
    compat_mod.ChatPromptTemplate = type(
        "ChatPromptTemplate",
        (),
        {"from_messages": classmethod(lambda cls, messages: messages)},
    )
    compat_mod.HumanMessagePromptTemplate = type(
        "HumanMessagePromptTemplate",
        (),
        {"from_template": classmethod(lambda cls, template: template)},
    )
    compat_mod.build_agent_executor = lambda *_args, **_kwargs: (None, None)
    compat_mod.get_conversation_buffer_window_memory = lambda **_kwargs: types.SimpleNamespace(clear=lambda: None)
    monkeypatch.setitem(sys.modules, "hana_ai.langchain_compat", compat_mod)
    monkeypatch.setitem(
        sys.modules,
        "hana_ai.agents.utilities",
        types.SimpleNamespace(
            _check_generated_cap_for_bas=lambda *_args, **_kwargs: None,
            _get_user_info=lambda *_args, **_kwargs: "user",
            _inspect_python_code=lambda *_args, **_kwargs: None,
        ),
    )
    monkeypatch.setitem(
        sys.modules,
        "hana_ai.vectorstore.embedding_service",
        types.SimpleNamespace(
            GenAIHubEmbeddings=_compat_class("GenAIHubEmbeddings"),
            HANAVectorEmbeddings=_compat_class("HANAVectorEmbeddings"),
        ),
    )
    monkeypatch.setitem(
        sys.modules,
        "hana_ai.vectorstore.pal_cross_encoder",
        types.SimpleNamespace(PALCrossEncoder=_compat_class("PALCrossEncoder")),
    )

    sys.modules.pop("hana_ai.agents.hanaml_rag_agent", None)
    return importlib.import_module("hana_ai.agents.hanaml_rag_agent")


def test_guardrail_integration_smart_dataframe_uses_sql_guardrail(monkeypatch):
    smart_dataframe = _import_smart_dataframe_module(monkeypatch)

    assert smart_dataframe._validate_select_only(" SELECT 1; ") == "SELECT 1"
    with pytest.raises(ValueError, match="Only SELECT statements are permitted"):
        smart_dataframe._validate_select_only("DELETE FROM T")


def test_guardrail_integration_rag_chat_leaves_output_unchanged_when_disabled(monkeypatch):
    rag_module = _import_rag_module(monkeypatch)

    agent = rag_module.HANAMLRAGAgent.__new__(rag_module.HANAMLRAGAgent)
    agent.executor = MagicMock(invoke=MagicMock(return_value={"output": "raw output"}))
    agent.output_guardrails = None
    agent._build_long_term_context = lambda _user_input: "context"
    agent._update_long_term_memory = MagicMock()
    agent.clear_long_term_memory = MagicMock()
    agent.clear_short_term_memory = MagicMock()

    result = agent.chat("hello")

    assert result == "raw output"
    agent._update_long_term_memory.assert_called_once_with("hello", "raw output")


def test_guardrail_integration_rag_chat_blocks_guardrail_failures(monkeypatch):
    rag_module = _import_rag_module(monkeypatch)
    guardrails_module = importlib.import_module("hana_ai.guardrails")

    agent = rag_module.HANAMLRAGAgent.__new__(rag_module.HANAMLRAGAgent)
    agent.executor = MagicMock(invoke=MagicMock(return_value={"output": "this answer is too long"}))
    agent.output_guardrails = guardrails_module.GuardrailChain([
        guardrails_module.MaxLengthGuardrail(max_length=5)
    ])
    agent._build_long_term_context = lambda _user_input: "context"
    agent._update_long_term_memory = MagicMock()
    agent.clear_long_term_memory = MagicMock()
    agent.clear_short_term_memory = MagicMock()

    with pytest.raises(ValueError, match="MaxLengthGuardrail"):
        agent.chat("hello")

    agent._update_long_term_memory.assert_not_called()


def test_guardrail_integration_rag_chat_sets_grounding_context(monkeypatch):
    rag_module = _import_rag_module(monkeypatch)

    class StubGroundingGuardrail:
        def __init__(self):
            self.contexts = []

        def set_context(self, context):
            self.contexts.append(context)

        def validate(self, output):
            return types.SimpleNamespace(passed=True, violations=[], sanitized_output=output)

    grounding_guardrail = StubGroundingGuardrail()
    agent = rag_module.HANAMLRAGAgent.__new__(rag_module.HANAMLRAGAgent)
    agent.executor = MagicMock(invoke=MagicMock(return_value={"output": "grounded output"}))
    agent.output_guardrails = None
    agent.grounding_guardrail = grounding_guardrail
    agent._build_long_term_context = lambda _user_input: "retrieved context"
    agent._update_long_term_memory = MagicMock()
    agent.clear_long_term_memory = MagicMock()
    agent.clear_short_term_memory = MagicMock()

    result = agent.chat("hello")

    assert result == "grounded output"
    assert grounding_guardrail.contexts == ["retrieved context"]