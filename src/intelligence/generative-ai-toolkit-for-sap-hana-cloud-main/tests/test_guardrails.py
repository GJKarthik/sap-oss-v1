import importlib
import sys
import types
from pathlib import Path

import pytest


@pytest.fixture
def guardrails_module(monkeypatch):
    src_dir = Path(__file__).resolve().parents[1] / "src"
    monkeypatch.syspath_prepend(str(src_dir))
    sys.modules.pop("hana_ai.guardrails", None)
    return importlib.import_module("hana_ai.guardrails")


def test_guardrail_chain_sanitizes_sql_output(guardrails_module):
    chain = guardrails_module.GuardrailChain([guardrails_module.SQLSafetyGuardrail()])

    result = chain.run("  SELECT * FROM DUMMY;  ")

    assert result.passed is True
    assert result.violations == []
    assert result.sanitized_output == "SELECT * FROM DUMMY"


def test_empty_response_guardrail_blocks_blank_output(guardrails_module):
    result = guardrails_module.EmptyResponseGuardrail().validate("   ")

    assert result.passed is False
    assert result.violations[0].guardrail == "EmptyResponseGuardrail"
    assert "whitespace-only" in result.violations[0].message


def test_max_length_guardrail_blocks_excessive_output(guardrails_module):
    result = guardrails_module.MaxLengthGuardrail(max_length=5).validate("toolong")

    assert result.passed is False
    assert "maximum length of 5" in result.violations[0].message


@pytest.mark.parametrize(
    "sql, expected_message",
    [
        ("UPDATE T SET X = 1", "Only SELECT statements are permitted"),
        ("SELECT * FROM T; DROP TABLE T", "SQL contains prohibited DDL/DML keywords"),
    ],
)
def test_sql_safety_guardrail_blocks_unsafe_queries(guardrails_module, sql, expected_message):
    result = guardrails_module.SQLSafetyGuardrail().validate(sql)

    assert result.passed is False
    assert any(expected_message in violation.message for violation in result.violations)


def test_pii_detection_guardrail_warns_without_blocking(guardrails_module):
    result = guardrails_module.PII_DetectionGuardrail(action="warn").validate(
        "Contact me at analyst@example.com"
    )

    assert result.passed is True
    assert result.violations[0].action == "warn"
    assert result.violations[0].matches == ["analyst@example.com"]


def test_pii_detection_guardrail_blocks_credit_card_like_content(guardrails_module):
    result = guardrails_module.PII_DetectionGuardrail(action="block").validate(
        "Card 4111 1111 1111 1111 should never be returned"
    )

    assert result.passed is False
    assert result.violations[0].action == "block"
    assert any("4111 1111 1111 1111" in match for match in result.violations[0].matches)


def test_nli_grounding_guardrail_warns_on_low_grounding_score(guardrails_module):
    guardrail = guardrails_module.NLIGroundingGuardrail(threshold=0.6, action="warn")
    guardrail.set_context("SAP HANA stores vectors in the database. Retrieval uses semantic search.")

    class StubBackend:
        backend_name = "sentence_transformers"

        def predict(self, _pairs):
            return [
                {"label": "entailment", "scores": {"contradiction": 0.1, "entailment": 0.8, "neutral": 0.1}},
                {"label": "contradiction", "scores": {"contradiction": 0.9, "entailment": 0.05, "neutral": 0.05}},
            ]

    guardrail._backend = StubBackend()

    result = guardrail.validate("SAP HANA stores vectors. It never uses semantic search.")

    assert result.passed is True
    assert result.violations[0].action == "warn"
    assert result.violations[0].details["grounding_score"] == pytest.approx(0.5)
    assert result.violations[0].details["backend"] == "sentence_transformers"
    assert result.violations[0].details["contradicted_pairs"]


def test_nli_grounding_guardrail_passes_through_without_backend(guardrails_module):
    guardrail = guardrails_module.NLIGroundingGuardrail(action="block")
    guardrail.set_context("Context that would normally be checked.")

    class StubBackend:
        backend_name = "pass_through"

        def predict(self, _pairs):
            return []

    guardrail._backend = StubBackend()

    result = guardrail.validate("Any answer")

    assert result.passed is True
    assert result.violations == []


def test_guardrails_import_does_not_load_sentence_transformers(monkeypatch):
    src_dir = Path(__file__).resolve().parents[1] / "src"
    monkeypatch.syspath_prepend(str(src_dir))

    real_import = __import__

    def guarded_import(name, *args, **kwargs):
        if name.startswith("sentence_transformers"):
            raise AssertionError("sentence_transformers should not be imported at module import time")
        return real_import(name, *args, **kwargs)

    monkeypatch.setattr("builtins.__import__", guarded_import)
    sys.modules.pop("hana_ai.guardrails", None)

    module = importlib.import_module("hana_ai.guardrails")

    assert isinstance(module, types.ModuleType)