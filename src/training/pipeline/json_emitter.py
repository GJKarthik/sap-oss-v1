# =============================================================================
# json_emitter.py — JSON serialisation helpers for the pipeline
# =============================================================================
from __future__ import annotations

import json
from pathlib import Path

from .schema_registry import SchemaRegistry
from .template_expander import TrainingPair
from .template_parser import Template


def emit_schema_json(registry: SchemaRegistry, path: str | Path) -> None:
    """Write the schema registry to a JSON file."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as fh:
        json.dump(registry.to_dict(), fh, indent=2, ensure_ascii=False)


def emit_templates_json(templates: list[Template], path: str | Path) -> None:
    """Write parsed templates to a JSON file."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    data = [
        {
            "domain": t.domain,
            "category": t.category,
            "product": t.product,
            "template": t.template_text,
            "param_count": len(t.params),
        }
        for t in templates
    ]
    with path.open("w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)


def emit_pairs_json(pairs: list[TrainingPair], path: str | Path) -> None:
    """Write training pairs to a JSON file."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    data = [
        {
            "question": p.question,
            "sql": p.sql,
            "domain": p.domain,
            "difficulty": p.difficulty,
        }
        for p in pairs
    ]
    with path.open("w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)


def load_pairs_json(path: str | Path) -> list[TrainingPair]:
    """Load training pairs from a JSON file."""
    path = Path(path)
    with path.open("r", encoding="utf-8") as fh:
        data = json.load(fh)
    return [
        TrainingPair(
            question=d["question"],
            sql=d["sql"],
            domain=d["domain"],
            difficulty=d["difficulty"],
        )
        for d in data
    ]
