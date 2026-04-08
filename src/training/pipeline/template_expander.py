# =============================================================================
# template_expander.py — Expand templates into text-SQL training pairs
# =============================================================================
from __future__ import annotations

import itertools
import re
from dataclasses import dataclass

from .template_parser import Template


@dataclass
class TrainingPair:
    question: str
    sql: str
    domain: str
    difficulty: str
    source: str = "template_expansion"


_PARAM_RE = re.compile(r"\{(\w+)\}")

# Default parameter value pools for expansion when no explicit values provided
_DEFAULT_VALUES: dict[str, list[str]] = {
    "company_code": ["1000", "2000", "3000"],
    "fiscal_year": ["2023", "2024", "2025"],
    "cost_center": ["CC001", "CC002", "CC003"],
    "currency": ["USD", "EUR", "GBP"],
    "amount": ["10000", "50000", "100000"],
    "account": ["400000", "500000", "600000"],
    "period": ["001", "006", "012"],
    "segment": ["SEG01", "SEG02", "SEG03"],
    "country": ["US", "DE", "GB"],
    "product": ["PROD_A", "PROD_B", "PROD_C"],
    "limit": ["5", "10", "20"],
}


def _classify_difficulty(template: Template) -> str:
    """Classify a template's difficulty based on complexity heuristics."""
    text = template.template_text.lower()
    param_count = len(template.params)

    if param_count >= 4 or "join" in text or "subquery" in text or "having" in text:
        return "hard"
    if param_count >= 2 or "group" in text or "order" in text:
        return "medium"
    return "easy"


def _get_param_values(param_name: str, provided: dict[str, list[str]]) -> list[str]:
    """Get value pool for a parameter, falling back to defaults."""
    if param_name in provided:
        return provided[param_name]
    return _DEFAULT_VALUES.get(param_name, [f"<{param_name}>"])


def expand_template(
    template: Template,
    param_values: dict[str, list[str]] | None = None,
    max_expansions: int = 500,
) -> list[TrainingPair]:
    """Expand a single template into training pairs.

    For each template, generate up to max_expansions pairs by substituting
    parameter values from the provided pool (or defaults).
    """
    param_values = param_values or {}
    difficulty = _classify_difficulty(template)

    param_names = [p.name for p in template.params]
    if not param_names:
        # No params — single expansion
        return [
            TrainingPair(
                question=template.template_text,
                sql=template.example_text or template.template_text,
                domain=template.domain,
                difficulty=difficulty,
            )
        ]

    # Build cartesian product of values (capped)
    value_pools = [_get_param_values(name, param_values) for name in param_names]
    product = list(itertools.islice(itertools.product(*value_pools), max_expansions))

    pairs: list[TrainingPair] = []
    for combo in product:
        substitutions = dict(zip(param_names, combo))
        question = _substitute(template.template_text, substitutions)
        sql = _substitute(template.example_text or template.template_text, substitutions)
        pairs.append(
            TrainingPair(
                question=question,
                sql=sql,
                domain=template.domain,
                difficulty=difficulty,
            )
        )

    return pairs


def expand_all(
    templates: list[Template],
    param_values: dict[str, list[str]] | None = None,
    max_per_template: int = 500,
) -> list[TrainingPair]:
    """Expand a list of templates into training pairs."""
    all_pairs: list[TrainingPair] = []
    for tmpl in templates:
        all_pairs.extend(expand_template(tmpl, param_values, max_per_template))
    return all_pairs


def _substitute(text: str, values: dict[str, str]) -> str:
    """Replace {param} placeholders with concrete values."""

    def _replacer(match: re.Match) -> str:
        key = match.group(1)
        return values.get(key, match.group(0))

    return _PARAM_RE.sub(_replacer, text)
