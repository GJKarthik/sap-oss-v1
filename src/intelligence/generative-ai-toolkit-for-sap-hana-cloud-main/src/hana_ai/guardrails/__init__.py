# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""Lightweight output guardrails for LLM-generated content."""

from __future__ import annotations

from dataclasses import dataclass, field
import importlib
import logging
import re
from typing import Any, Iterable

logger = logging.getLogger(__name__)

_SQL_DANGEROUS_PATTERN = re.compile(
    r"\b(DROP|DELETE|INSERT|UPDATE|CREATE|ALTER|TRUNCATE|EXEC|GRANT|REVOKE|MERGE)\b",
    re.IGNORECASE,
)
_EMAIL_PATTERN = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
_PHONE_PATTERN = re.compile(r"(?<!\w)(?:\+?\d{1,3}[\s.-]?)?(?:\(?\d{3}\)?[\s.-]?)?\d{3}[\s.-]?\d{4}(?!\w)")
_CREDIT_CARD_PATTERN = re.compile(r"(?<!\w)(?:\d[ -]*?){13,16}(?!\w)")
_SENTENCE_SPLIT_PATTERN = re.compile(r"(?<=[.!?])\s+")
_NLI_LABELS = ["contradiction", "entailment", "neutral"]
_MAX_CONTRADICTION_DETAILS = 5


def _coerce_output(output: Any) -> str:
    return "" if output is None else str(output)


@dataclass(frozen=True)
class GuardrailViolation:
    """A single guardrail violation."""

    guardrail: str
    message: str
    action: str = "block"
    matches: list[str] = field(default_factory=list)
    details: dict[str, Any] = field(default_factory=dict)


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


def _split_sentences(text: str) -> list[str]:
    stripped = _coerce_output(text).strip()
    if not stripped:
        return []
    segments = [segment.strip() for segment in _SENTENCE_SPLIT_PATTERN.split(stripped) if segment.strip()]
    return segments or [stripped]


def _chunk_text(text: str, max_chars: int = 500) -> list[str]:
    sentences = _split_sentences(text)
    if not sentences:
        return []

    chunks: list[str] = []
    current_chunk: list[str] = []
    current_length = 0
    for sentence in sentences:
        separator_length = 1 if current_chunk else 0
        if current_chunk and current_length + separator_length + len(sentence) > max_chars:
            chunks.append(" ".join(current_chunk))
            current_chunk = [sentence]
            current_length = len(sentence)
        else:
            current_chunk.append(sentence)
            current_length += separator_length + len(sentence)

    if current_chunk:
        chunks.append(" ".join(current_chunk))
    return chunks


def _normalize_score_rows(raw_scores: Any) -> list[list[float]]:
    if hasattr(raw_scores, "tolist"):
        raw_scores = raw_scores.tolist()

    if raw_scores is None:
        return []

    normalized_rows: list[list[float]] = []
    for row in raw_scores:
        if hasattr(row, "tolist"):
            row = row.tolist()
        if isinstance(row, dict):
            row = [row[label] for label in _NLI_LABELS]
        if not isinstance(row, (list, tuple)) or len(row) < 3:
            raise ValueError("NLI backend must return three class scores per pair")
        normalized_rows.append([float(value) for value in row[:3]])
    return normalized_rows


def _extract_table_score_rows(table_result: Any) -> list[list[float]]:
    if hasattr(table_result, "collect"):
        table_result = table_result.collect()

    columns = list(getattr(table_result, "columns", []))
    if len(columns) < 3:
        raise ValueError("PAL NLI backend must return at least three score columns")

    lower_columns = [str(column).lower() for column in columns]
    selected_columns: list[Any] = []
    for label in _NLI_LABELS:
        matched_column = next((column for column, lowered in zip(columns, lower_columns) if label in lowered), None)
        if matched_column is None:
            selected_columns = []
            break
        selected_columns.append(matched_column)

    if not selected_columns:
        selected_columns = columns[-3:]

    rows: list[list[float]] = []
    for _, row in table_result.iterrows():
        rows.append([float(row[column]) for column in selected_columns])
    return rows


def _score_rows_to_predictions(score_rows: list[list[float]]) -> list[dict[str, Any]]:
    predictions: list[dict[str, Any]] = []
    for row in score_rows:
        label_index = max(range(len(_NLI_LABELS)), key=lambda idx: row[idx])
        predictions.append(
            {
                "label": _NLI_LABELS[label_index],
                "scores": {label: float(score) for label, score in zip(_NLI_LABELS, row)},
            }
        )
    return predictions


def _resolve_connection_context(source: Any) -> Any:
    if source is None:
        return None
    if hasattr(source, "connection_context"):
        return getattr(source, "connection_context")
    if hasattr(source, "hana_connection_context"):
        return getattr(source, "hana_connection_context")
    if hasattr(source, "vectorstore"):
        connection_context = _resolve_connection_context(getattr(source, "vectorstore"))
        if connection_context is not None:
            return connection_context
    if hasattr(source, "vector_stores"):
        for vector_store in getattr(source, "vector_stores"):
            connection_context = _resolve_connection_context(vector_store)
            if connection_context is not None:
                return connection_context
    return None


class _NLIBackend:
    """Lazy, optional NLI backend loader with PAL and sentence-transformers fallbacks."""

    def __init__(self, model_name: str, connection_context: Any = None):
        self.model_name = model_name
        self.connection_context = connection_context
        self._backend_name: str | None = None
        self._model: Any = None
        self._pal_disabled = False
        self._warning_emitted = False

    @property
    def backend_name(self) -> str | None:
        return self._backend_name

    def set_connection_context(self, connection_context: Any) -> None:
        self.connection_context = connection_context
        if self._backend_name == "pass_through":
            self._backend_name = None
            self._model = None

    def predict(self, pairs: list[tuple[str, str]]) -> list[dict[str, Any]]:
        if not pairs:
            return []

        backend_name = self._ensure_backend()
        if backend_name == "pass_through":
            return []

        if backend_name == "pal":
            try:
                raw_scores = self._model.predict(
                    pairs,
                    model_version=self.model_name,
                    return_table=True,
                )
                return _score_rows_to_predictions(_extract_table_score_rows(raw_scores))
            except Exception as exc:  # pragma: no cover - depends on PAL runtime
                logger.warning(
                    "PAL NLI backend failed; falling back to sentence-transformers if available: %s",
                    exc,
                )
                self._backend_name = None
                self._model = None
                self._pal_disabled = True
                return self.predict(pairs)

        try:
            raw_scores = self._model.predict(pairs)
            return _score_rows_to_predictions(_normalize_score_rows(raw_scores))
        except Exception as exc:  # pragma: no cover - defensive fallback
            logger.warning("Sentence-transformers NLI backend failed; skipping grounding validation: %s", exc)
            self._backend_name = "pass_through"
            self._model = None
            return []

    def _ensure_backend(self) -> str:
        if self._backend_name is not None:
            return self._backend_name

        if not self._pal_disabled and self.connection_context is not None:
            try:
                pal_utility = importlib.import_module("hana_ml.algorithms.pal.utility")
                if pal_utility.check_pal_function_exist(self.connection_context, "%PAL_CROSSENCODER%", like=True):
                    pal_module = importlib.import_module("hana_ai.vectorstore.pal_cross_encoder")
                    self._model = pal_module.PALCrossEncoder(self.connection_context)
                    self._backend_name = "pal"
                    return self._backend_name
            except Exception as exc:  # pragma: no cover - optional PAL dependency
                logger.warning("PAL NLI backend unavailable; falling back to sentence-transformers: %s", exc)

        try:
            cross_encoder_module = importlib.import_module("sentence_transformers")
            self._model = cross_encoder_module.CrossEncoder(self.model_name)
            self._backend_name = "sentence_transformers"
            return self._backend_name
        except ImportError:
            pass
        except Exception as exc:  # pragma: no cover - model init can fail unexpectedly
            logger.warning("Failed to initialize NLI model '%s': %s", self.model_name, exc)

        if not self._warning_emitted:
            logger.warning("No NLI backend available; grounding validation will be skipped.")
            self._warning_emitted = True
        self._backend_name = "pass_through"
        self._model = None
        return self._backend_name


class NLIGroundingGuardrail:
    """Validate that model output is supported by retrieved context using NLI."""

    def __init__(
        self,
        threshold: float = 0.5,
        action: str = "warn",
        model_name: str = "cross-encoder/nli-deberta-v3-base",
    ):
        if not 0.0 <= threshold <= 1.0:
            raise ValueError("threshold must be between 0 and 1")
        if action not in {"warn", "block"}:
            raise ValueError("action must be either 'warn' or 'block'")
        self.threshold = threshold
        self.action = action
        self.model_name = model_name
        self.context = ""
        self._backend = _NLIBackend(model_name=model_name)

    def set_context(self, context: str) -> None:
        self.context = _coerce_output(context)

    def set_connection_context(self, connection_context: Any) -> None:
        self._backend.set_connection_context(connection_context)

    def validate(self, output: Any) -> GuardrailResult:
        text = _coerce_output(output)
        output_sentences = _split_sentences(text)
        context_chunks = _chunk_text(self.context)
        if not output_sentences or not context_chunks:
            return GuardrailResult(passed=True, violations=[], sanitized_output=text)

        pairs = [(context_chunk, output_sentence) for output_sentence in output_sentences for context_chunk in context_chunks]
        predictions = self._backend.predict(pairs)
        if not predictions:
            return GuardrailResult(passed=True, violations=[], sanitized_output=text)

        entailed_pairs = sum(1 for prediction in predictions if prediction["label"] == "entailment")
        grounding_score = entailed_pairs / len(predictions)
        contradicted_pairs = []
        for (context_chunk, output_sentence), prediction in zip(pairs, predictions):
            if prediction["label"] == "contradiction":
                contradicted_pairs.append(
                    {
                        "context": context_chunk,
                        "output": output_sentence,
                        "scores": prediction["scores"],
                    }
                )

        if grounding_score >= self.threshold:
            return GuardrailResult(passed=True, violations=[], sanitized_output=text)

        violation = GuardrailViolation(
            guardrail=self.__class__.__name__,
            message=(
                f"Output grounding score {grounding_score:.2f} is below threshold {self.threshold:.2f}"
            ),
            action=self.action,
            details={
                "grounding_score": grounding_score,
                "threshold": self.threshold,
                "backend": self._backend.backend_name,
                "entailed_pairs": entailed_pairs,
                "total_pairs": len(predictions),
                "contradicted_pairs": contradicted_pairs[:_MAX_CONTRADICTION_DETAILS],
            },
        )
        return GuardrailResult(
            passed=self.action != "block",
            violations=[violation],
            sanitized_output=text,
        )


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
    "NLIGroundingGuardrail",
    "PII_DetectionGuardrail",
    "SQLSafetyGuardrail",
]