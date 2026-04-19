#!/usr/bin/env python3
"""
Offline JSON Schema validator for the TB corpus.

Walks docs/tb/structured/, pairs each record with its schema, and validates
using a local referencing.Registry so no network is touched.

Usage:
    python3 docs/tb/structured/validate.py
Exit code 0 on success, non-zero on first validation failure.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

try:
    from jsonschema import Draft7Validator
    from referencing import Registry, Resource
    from referencing.jsonschema import DRAFT7
except ImportError as exc:
    print(f"Missing dependency: {exc}. Install with: pip install jsonschema referencing")
    sys.exit(2)

HERE = Path(__file__).resolve().parent  # docs/tb/structured
SCHEMAS = HERE / "schema"

# Map subdirectory -> schema file. Each record in that dir is validated
# against that schema.
RECORD_DIRS = {
    "controls":        "control.schema.json",
    "decision-points": "decision-point.schema.json",
    "workflows":       "workflow.schema.json",
    "requirements":    "requirement.schema.json",
    "data-products":   "data-product.schema.json",
    "glossary":        "glossary.schema.json",
}


def load_registry() -> Registry:
    """Load all schemas into a local referencing.Registry."""
    registry = Registry()
    for schema_file in SCHEMAS.glob("*.schema.json"):
        schema = json.loads(schema_file.read_text())
        resource = Resource(contents=schema, specification=DRAFT7)
        uri = schema.get("$id", schema_file.name)
        registry = registry.with_resource(uri, resource)
    return registry


def validate_file(path: Path, schema: dict, registry: Registry) -> list[str]:
    data = json.loads(path.read_text())
    validator = Draft7Validator(schema, registry=registry)
    return [f"{path.name}: {e.message} (at {list(e.absolute_path)})"
            for e in validator.iter_errors(data)]


def validate_kpi_collection(path: Path, schema: dict, registry: Registry) -> list[str]:
    """KPI file stores a collection; validate each KPI record."""
    data = json.loads(path.read_text())
    errors = []
    validator = Draft7Validator(schema, registry=registry)
    for idx, kpi in enumerate(data.get("kpis", [])):
        errors.extend(f"{path.name}[{idx}]: {e.message}"
                      for e in validator.iter_errors(kpi))
    return errors


def main() -> int:
    registry = load_registry()
    total, failed = 0, 0

    for subdir, schema_name in RECORD_DIRS.items():
        schema_path = SCHEMAS / schema_name
        if not schema_path.exists():
            print(f"[skip] schema missing: {schema_name}")
            continue
        schema = json.loads(schema_path.read_text())

        target_dir = HERE / subdir
        if not target_dir.exists():
            continue
        for record in sorted(target_dir.glob("*.json")):
            total += 1
            errors = validate_file(record, schema, registry)
            if errors:
                failed += 1
                for e in errors:
                    print(f"[FAIL] {e}")
            else:
                print(f"[ok]   {subdir}/{record.name}")

    # Special-case: kpi collection file
    kpi_schema_path = SCHEMAS / "kpi.schema.json"
    kpi_file = HERE / "kpis" / "tb-kpis.json"
    if kpi_schema_path.exists() and kpi_file.exists():
        total += 1
        kpi_schema = json.loads(kpi_schema_path.read_text())
        errors = validate_kpi_collection(kpi_file, kpi_schema, registry)
        if errors:
            failed += 1
            for e in errors:
                print(f"[FAIL] {e}")
        else:
            print(f"[ok]   kpis/{kpi_file.name} ({len(json.loads(kpi_file.read_text())['kpis'])} KPIs)")

    # Corpus integrity
    corpus = json.loads((HERE / "corpus.json").read_text())
    repo_root = HERE.parents[2]
    missing = []
    for item in corpus["items"]:
        for key in ("source_path", "text_path", "structured_path"):
            p = item.get(key)
            if p and not (repo_root / p).exists():
                missing.append(f"  {item['id']}.{key}: {p}")
    if missing:
        failed += 1
        print("[FAIL] corpus paths missing:")
        print("\n".join(missing))
    else:
        print(f"[ok]   corpus.json ({len(corpus['items'])} items, all paths resolved)")

    print(f"\n{total - failed}/{total} records validated, corpus {'OK' if not missing else 'FAIL'}")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
