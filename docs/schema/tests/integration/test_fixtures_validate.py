"""
End-to-end integration test: every fixture validates against its schema.

Discovery convention (see conftest.py):
    tests/fixtures/<domain>/<stem>.sample.json
        -> docs/schema/<domain>/<stem>.schema.json

Run:
    pytest docs/schema/tests/integration/ -v
"""
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Tuple

import pytest

# Make `validate.py` importable as a module.
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from validate import (  # noqa: E402  (sys.path manipulation above)
    validate_file,
    validate_schema_against_meta,
    check_registry,
    run_fixtures,
    check_roadmap,
)


def test_registry_check_passes() -> None:
    """Every schema in DOMAIN_SCHEMAS parses and declares $schema/$id."""
    ok, issues = check_registry()
    assert ok, f"Registry check failed:\n" + "\n".join(issues)


def test_every_schema_follows_conventions(schema_base) -> None:
    """Every *.schema.json in the tree validates against the meta-schema."""
    failures = {}
    for schema_path in sorted(schema_base.glob("**/*.schema.json")):
        ok, issues = validate_schema_against_meta(schema_path)
        if not ok:
            failures[str(schema_path.relative_to(schema_base))] = issues
    assert not failures, "Schema convention failures:\n" + json.dumps(failures, indent=2)


def test_fixture_validates_against_schema(fixture_pair: Tuple[Path, Path]) -> None:
    """Parametrised: each (fixture, schema) pair validates cleanly."""
    fixture_path, schema_path = fixture_pair
    ok, errors = validate_file(fixture_path, schema_path)
    assert ok, (
        f"{fixture_path.name} does not validate against {schema_path.name}:\n"
        + "\n".join(errors)
    )


def test_run_fixtures_command() -> None:
    """The `--run-fixtures` command exits cleanly."""
    ok, _ = run_fixtures()
    assert ok


def test_roadmap_references_resolve() -> None:
    """Every RoadmapReference in fixtures points to a known milestone."""
    ok, report = check_roadmap()
    assert ok, "Roadmap references fail to resolve:\n" + "\n".join(report)


def test_reg_mgf_2_1_2_002_is_partial_with_flip_trigger(fixtures_base) -> None:
    """The canonical REG-MGF-2.1.2-002 fixture is partial and flips to compliant."""
    fx = fixtures_base / "regulations" / "requirement.sample.json"
    data = json.loads(fx.read_text())
    assert data["requirement_id"] == "REG-MGF-2.1.2-002"
    assert data["status"] == "partial"
    assert data["flip_trigger"]["to_status"] == "compliant"
    assert data["flip_trigger"]["ticket"] == "REG-INTG-AP-001"


def test_simula_config_has_reproducibility_manifest(fixtures_base) -> None:
    """Simula config fixture pins M06 reference-run commit/tag/seed."""
    fx = fixtures_base / "simula" / "config.sample.json"
    data = json.loads(fx.read_text())
    rep = data["reproducibility"]
    assert rep["commit"] == "b8d40a1"
    assert rep["tag"] == "simula-v1.2-worked-example"
    assert rep["seed"] == 20251115
