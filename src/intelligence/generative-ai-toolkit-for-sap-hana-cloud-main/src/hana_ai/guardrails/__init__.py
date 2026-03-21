# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""Lightweight output guardrails for LLM-generated content."""

from __future__ import annotations

from dataclasses import dataclass, field
import re
from typing import Any, Iterable

_SQL_DANGEROUS_PATTERN = re.compile(
    r"\b(DROP|DELETE|INSERT|UPDATE|CREATE|ALTER|TRUNCATE|EXEC|GRANT|REVOKE|MERGE)\b",
    re.IGNORECASE,
)
_EMAIL_PATTERN = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
_PHONE_PATTERN = re.compile(r"(?<!\w)(?:\+?\d{1,3}[\s.-]?)?(?:\(?\d{3}\)?[\s.-]?)?\d{3}[\s.-]?\d{4}(?!\w)")
_CREDIT_CARD_PATTERN = re.compile(r"(?<!\w)(?:\d[ -]*?){13,16}(?!\w)")


def _coerce_output(output: Any) -> str:
    return "" if output is None else str(output)


@dataclass(frozen=True)
class GuardrailViolation:
    """A single guardrail violation."""

    guardrail: str
    message: str
    action: str = "block"
    matches: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class GuardrailResult:
    """Aggregated result from one or more guardrails."""

    passed: bool
    violations: list[GuardrailViolation]
    sanitized_output: str


class GuardrailChain:
    """Run a configurable sequence of output guardrails."""

    def __init__(self, guardrails: Iterable[Any] | None = None):
        self.guardrails = list(guardrails or [])

    def run(self, output: Any) -> GuardrailResult:
        current_output = _coerce_output(output)
        passed = True
        violations: list[GuardrailViolation] = []

        for guardrail in self.guardrails:
            result = guardrail.validate(current_output)
            current_output = result.sanitized_output
            violations.extend(result.violations)
            passed = passed and result.passed

        return GuardrailResult(passed=passed, violations=violations, sanitized_output=current_output)

    def validate_or_raise(self, output: Any) -> str:
        result = self.run(output)
        if not result.passed:
            blocking_messages = [
                f"{violation.guardrail}: {violation.message}"
                for violation in result.violations
                if violation.action == "block"
            ]
            raise ValueError("; ".join(blocking_messages) or "Output failed guardrail validation")
        return result.sanitized_output


class EmptyResponseGuardrail:
    """Reject empty or whitespace-only outputs."""

    def validate(self, output: Any) -> GuardrailResult:
        text = _coerce_output(output)
        if text.strip():
            return GuardrailResult(passed=True, violations=[], sanitized_output=text)
        violation = GuardrailViolation(
            guardrail=self.__class__.__name__,
            message="Output cannot be empty or whitespace-only",
        )
        return GuardrailResult(passed=False, violations=[violation], sanitized_output=text)


class MaxLengthGuardrail:
    """Reject outputs longer than the configured limit."""

    def __init__(self, max_length: int):
        if max_length <= 0:
            raise ValueError("max_length must be greater than zero")
        self.max_length = max_length

    def validate(self, output: Any) -> GuardrailResult:
        text = _coerce_output(output)
        if len(text) <= self.max_length:
            return GuardrailResult(passed=True, violations=[], sanitized_output=text)
        violation = GuardrailViolation(
            guardrail=self.__class__.__name__,
            message=f"Output exceeds maximum length of {self.max_length} characters",
        )
        return GuardrailResult(passed=False, violations=[violation], sanitized_output=text)


class SQLSafetyGuardrail:
    """Reject non-SELECT SQL and dangerous SQL keywords."""

    def validate(self, output: Any) -> GuardrailResult:
        stripped = _coerce_output(output).strip().rstrip(";").strip()
        violations: list[GuardrailViolation] = []

        if not stripped.upper().startswith("SELECT"):
            violations.append(
                GuardrailViolation(
                    guardrail=self.__class__.__name__,
                    message="Only SELECT statements are permitted",
                )
            )
        if _SQL_DANGEROUS_PATTERN.search(stripped):
            violations.append(
                GuardrailViolation(
                    guardrail=self.__class__.__name__,
                    message="SQL contains prohibited DDL/DML keywords",
                )
            )

        return GuardrailResult(
            passed=not violations,
            violations=violations,
            sanitized_output=stripped,
        )


class PII_DetectionGuardrail:
    """Detect common PII patterns using lightweight regular expressions."""

    def __init__(self, action: str = "block"):
        if action not in {"warn", "block"}:
            raise ValueError("action must be either 'warn' or 'block'")
        self.action = action

    def validate(self, output: Any) -> GuardrailResult:
        text = _coerce_output(output)
        detected_matches = {
            "emails": _EMAIL_PATTERN.findall(text),
            "phone numbers": _PHONE_PATTERN.findall(text),
            "credit cards": self._find_credit_card_matches(text),
        }
        present_kinds = [kind for kind, matches in detected_matches.items() if matches]
        if not present_kinds:
            return GuardrailResult(passed=True, violations=[], sanitized_output=text)

        violation = GuardrailViolation(
            guardrail=self.__class__.__name__,
            message=f"Detected possible PII: {', '.join(present_kinds)}",
            action=self.action,
            matches=[match for matches in detected_matches.values() for match in matches],
        )
        return GuardrailResult(
            passed=self.action != "block",
            violations=[violation],
            sanitized_output=text,
        )

    @staticmethod
    def _find_credit_card_matches(text: str) -> list[str]:
        matches: list[str] = []
        for match in _CREDIT_CARD_PATTERN.findall(text):
            digits_only = re.sub(r"\D", "", match)
            if 13 <= len(digits_only) <= 16:
                matches.append(match)
        return matches


__all__ = [
    "EmptyResponseGuardrail",
    "GuardrailChain",
    "GuardrailResult",
    "GuardrailViolation",
    "MaxLengthGuardrail",
    "PII_DetectionGuardrail",
    "SQLSafetyGuardrail",
]