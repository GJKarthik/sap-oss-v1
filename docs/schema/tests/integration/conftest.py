"""pytest fixtures for the schema registry integration tests.

Exposes:
    schema_base      Path to docs/schema/
    fixtures_base    Path to docs/schema/tests/fixtures/
    fixture_pairs    List of (fixture_path, schema_path) tuples,
                     auto-discovered via the *.sample.json naming convention.
"""
from __future__ import annotations

from pathlib import Path
from typing import List, Tuple

import pytest

SCHEMA_BASE = Path(__file__).resolve().parents[2]  # docs/schema/
FIXTURES_BASE = SCHEMA_BASE / "tests" / "fixtures"


@pytest.fixture(scope="session")
def schema_base() -> Path:
    return SCHEMA_BASE


@pytest.fixture(scope="session")
def fixtures_base() -> Path:
    return FIXTURES_BASE


def _discover_pairs() -> List[Tuple[Path, Path]]:
    pairs: List[Tuple[Path, Path]] = []
    if not FIXTURES_BASE.exists():
        return pairs
    for fx in sorted(FIXTURES_BASE.glob("**/*.sample.json")):
        domain = fx.parent.name
        schema_stem = fx.stem.replace(".sample", "")
        schema_path = SCHEMA_BASE / domain / f"{schema_stem}.schema.json"
        if schema_path.exists():
            pairs.append((fx, schema_path))
    return pairs


@pytest.fixture(scope="session")
def fixture_pairs() -> List[Tuple[Path, Path]]:
    return _discover_pairs()


def pytest_generate_tests(metafunc):
    """Parametrize any test that takes a `fixture_pair` argument with every
    discovered (fixture, schema) tuple."""
    if "fixture_pair" in metafunc.fixturenames:
        pairs = _discover_pairs()
        metafunc.parametrize(
            "fixture_pair",
            pairs,
            ids=[f"{fx.parent.name}/{fx.stem}" for fx, _ in pairs],
        )
