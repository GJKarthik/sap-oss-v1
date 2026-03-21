import importlib
import sys
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