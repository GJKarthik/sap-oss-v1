# =============================================================================
# template_parser.py — Parse text-to-SQL prompt templates from CSV
# =============================================================================
from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

from .csv_parser import parse_csv_file, parse_csv_string


@dataclass
class TemplateParam:
    name: str
    description: str = ""


@dataclass
class Template:
    domain: str
    category: str
    product: str
    template_text: str
    example_text: str = ""
    params: list[TemplateParam] = field(default_factory=list)


_PARAM_RE = re.compile(r"\{(\w+)\}")


def _extract_params(template_text: str) -> list[TemplateParam]:
    """Extract {{param}} placeholders from a template string."""
    seen: set[str] = set()
    params: list[TemplateParam] = []
    for match in _PARAM_RE.finditer(template_text):
        name = match.group(1)
        if name not in seen:
            seen.add(name)
            params.append(TemplateParam(name=name))
    return params


def parse_templates_csv(csv_path: str | Path, domain: str) -> list[Template]:
    """Parse a templates CSV file.

    Expected CSV columns: category, product, template_text, example_text
    """
    rows = parse_csv_file(csv_path)
    return _parse_rows(rows, domain)


def parse_templates_csv_string(csv_data: str, domain: str) -> list[Template]:
    """Parse templates from an in-memory CSV string."""
    rows = parse_csv_string(csv_data)
    return _parse_rows(rows, domain)


def _parse_rows(rows: list, domain: str) -> list[Template]:
    """Internal: convert parsed CSV rows into Template objects."""
    templates: list[Template] = []

    # Skip header row
    data_rows = rows[1:] if len(rows) > 1 else []

    for row in data_rows:
        if len(row.fields) < 3:
            continue

        category = row.fields[0].strip()
        product = row.fields[1].strip()
        template_text = row.fields[2].strip()
        example_text = row.fields[3].strip() if len(row.fields) > 3 else ""

        if not template_text:
            continue

        templates.append(
            Template(
                domain=domain,
                category=category,
                product=product,
                template_text=template_text,
                example_text=example_text,
                params=_extract_params(template_text),
            )
        )

    return templates
