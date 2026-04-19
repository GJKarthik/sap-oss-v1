#!/usr/bin/env python3
"""Offline validator for docs/regulations/structured/.

Validates in three passes:

    1. JSON Schema (Draft-07) conformance for every record.
    2. Corpus-index integrity: every `structured_path` in corpus.json must exist
       and every record on disk must be referenced.
    3. Implementation / verification link checks:
           - Every `implementation[].path` resolves under the repo root (unless
             `kind == "none"`).
           - Every `verification[].path` resolves under the repo root.
           - Every `verification[].plugin` matches a plugin path in one of the
             conformance-tool records.
           - Every `verification[].testId` matches a benchmark id in one of the
             conformance-tool records.

Runs offline: no network, no tool installation. Exit code is 0 only when all
three passes succeed.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Iterable

try:
    from jsonschema import Draft7Validator
    from referencing import Registry, Resource
    from referencing.jsonschema import DRAFT7
except ImportError as exc:
    print(f"FATAL: missing dependency: {exc}. pip install jsonschema referencing",
          file=sys.stderr)
    sys.exit(2)


REPO_ROOT = Path(__file__).resolve().parents[3]
STRUCTURED = Path(__file__).resolve().parent
SCHEMAS = STRUCTURED / "schema"
CORPUS = STRUCTURED / "corpus.json"

RECORD_DIRS: dict[str, str] = {
    "regulations": "regulation.schema.json",
    "conformance-tools": "conformance-tool.schema.json",
}
# requirements/ holds collection files keyed by "requirements": [...]
REQUIREMENTS_DIR = "requirements"
REQUIREMENT_SCHEMA = "requirement.schema.json"


# ---------------------------------------------------------------------------
# schema registry
# ---------------------------------------------------------------------------
def load_registry() -> tuple[Registry, dict[str, dict]]:
    """Load every *.schema.json into a referencing Registry for offline $ref."""
    registry = Registry()
    schemas: dict[str, dict] = {}
    for schema_file in sorted(SCHEMAS.glob("*.schema.json")):
        schema = json.loads(schema_file.read_text(encoding="utf-8"))
        uri = schema.get("$id", schema_file.name)
        resource = Resource(contents=schema, specification=DRAFT7)
        registry = registry.with_resource(uri=uri, resource=resource)
        schemas[schema_file.name] = schema
    return registry, schemas


# ---------------------------------------------------------------------------
# pass 1: schema validation
# ---------------------------------------------------------------------------
def validate_record(path: Path, schema: dict, registry: Registry,
                    errors: list[str]) -> None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        errors.append(f"{path}: parse error: {exc}")
        return
    validator = Draft7Validator(schema, registry=registry)
    for err in sorted(validator.iter_errors(data), key=lambda e: list(e.absolute_path)):
        loc = "/".join(str(p) for p in err.absolute_path) or "<root>"
        errors.append(f"{path}: {loc}: {err.message}")


def validate_requirements_collection(path: Path, schema: dict, registry: Registry,
                                     errors: list[str]) -> int:
    """Requirement files store a list under the `requirements` key."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        errors.append(f"{path}: parse error: {exc}")
        return 0
    if not isinstance(data, dict) or not isinstance(data.get("requirements"), list):
        errors.append(f"{path}: requirement files must be {{\"requirements\": [...]}}")
        return 0
    validator = Draft7Validator(schema, registry=registry)
    count = 0
    for idx, req in enumerate(data["requirements"]):
        for err in sorted(validator.iter_errors(req), key=lambda e: list(e.absolute_path)):
            loc = "/".join(str(p) for p in err.absolute_path) or "<root>"
            errors.append(f"{path}[{idx}]: {loc}: {err.message}")
        count += 1
    return count


# ---------------------------------------------------------------------------
# pass 2: corpus integrity
# ---------------------------------------------------------------------------
def validate_corpus(registry: Registry, schemas: dict[str, dict],
                    errors: list[str]) -> set[Path]:
    """Returns the set of structured paths referenced by corpus.json."""
    try:
        data = json.loads(CORPUS.read_text(encoding="utf-8"))
    except Exception as exc:
        errors.append(f"{CORPUS}: parse error: {exc}")
        return set()
    schema = schemas.get("corpus-index.schema.json")
    if schema is not None:
        validator = Draft7Validator(schema, registry=registry)
        for err in sorted(validator.iter_errors(data), key=lambda e: list(e.absolute_path)):
            loc = "/".join(str(p) for p in err.absolute_path) or "<root>"
            errors.append(f"{CORPUS}: {loc}: {err.message}")
    referenced: set[Path] = set()
    for item in data.get("items", []):
        sp = item.get("structured_path")
        if sp:
            resolved = (REPO_ROOT / sp).resolve()
            if not resolved.exists():
                errors.append(f"corpus.json: structured_path missing: {sp}")
            referenced.add(resolved)
        src = item.get("source_path")
        if src and not (REPO_ROOT / src).exists():
            errors.append(f"corpus.json: source_path missing: {src}")
        txt = item.get("text_path")
        if txt and not (REPO_ROOT / txt).exists():
            errors.append(f"corpus.json: text_path missing: {txt}")
    return referenced


def discover_structured_files() -> list[Path]:
    paths: list[Path] = []
    for sub in list(RECORD_DIRS) + [REQUIREMENTS_DIR]:
        paths.extend(sorted((STRUCTURED / sub).glob("*.json")))
    return paths


# ---------------------------------------------------------------------------
# pass 3: implementation + verification link checks
# ---------------------------------------------------------------------------
def collect_conformance_catalogue() -> tuple[set[str], set[str]]:
    """Return (aiverify_plugin_ids, moonshot_benchmark_ids) from tool records."""
    plugins: set[str] = set()
    benchmarks: set[str] = set()
    for tool_path in sorted((STRUCTURED / "conformance-tools").glob("*.json")):
        data = json.loads(tool_path.read_text(encoding="utf-8"))
        for p in data.get("plugins", []) or []:
            if p.get("pluginId"):
                plugins.add(p["pluginId"])
            # Also check that the plugin path actually exists.
            p_path = p.get("path")
            if p_path and not (REPO_ROOT / p_path).exists():
                print(f"WARN: {tool_path.name}: plugin path missing: {p_path}",
                      file=sys.stderr)
        for b in data.get("benchmarks", []) or []:
            if b.get("benchmarkId"):
                benchmarks.add(b["benchmarkId"])
    return plugins, benchmarks


def verify_links(requirements_files: Iterable[Path],
                 plugin_ids: set[str],
                 benchmark_ids: set[str],
                 errors: list[str]) -> tuple[int, int]:
    """Walk all requirement records; check paths / plugins / testIds resolve."""
    impl_ok = impl_bad = 0
    for path in requirements_files:
        data = json.loads(path.read_text(encoding="utf-8"))
        for req in data.get("requirements", []):
            rid = req.get("requirementId", "<unknown>")
            for entry in req.get("implementation", []) or []:
                kind = entry.get("kind")
                if kind == "none":
                    continue
                p = entry.get("path")
                if not p:
                    errors.append(f"{rid}: implementation {kind} has no path")
                    impl_bad += 1
                    continue
                if not (REPO_ROOT / p).exists():
                    errors.append(f"{rid}: implementation path missing: {p}")
                    impl_bad += 1
                else:
                    impl_ok += 1
            for entry in req.get("verification", []) or []:
                kind = entry.get("kind")
                if kind == "aiverify-plugin":
                    plugin = entry.get("plugin")
                    if plugin not in plugin_ids:
                        errors.append(
                            f"{rid}: verification references unknown aiverify plugin '{plugin}'")
                elif kind == "moonshot-test":
                    test_id = entry.get("testId")
                    if test_id not in benchmark_ids:
                        errors.append(
                            f"{rid}: verification references unknown moonshot testId '{test_id}'")
                elif kind == "test":
                    p = entry.get("path")
                    if p and not (REPO_ROOT / p).exists():
                        errors.append(f"{rid}: verification test path missing: {p}")
    return impl_ok, impl_bad


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main() -> int:
    errors: list[str] = []
    registry, schemas = load_registry()

    # Pass 1 + walk
    total_records = 0
    total_requirements = 0
    for sub, schema_name in RECORD_DIRS.items():
        schema = schemas.get(schema_name)
        if schema is None:
            errors.append(f"missing schema: {schema_name}")
            continue
        for path in sorted((STRUCTURED / sub).glob("*.json")):
            validate_record(path, schema, registry, errors)
            total_records += 1

    requirements_schema = schemas.get(REQUIREMENT_SCHEMA)
    requirement_files = sorted((STRUCTURED / REQUIREMENTS_DIR).glob("*.json"))
    if requirements_schema is None:
        errors.append(f"missing schema: {REQUIREMENT_SCHEMA}")
    else:
        for path in requirement_files:
            total_requirements += validate_requirements_collection(
                path, requirements_schema, registry, errors)

    # Pass 2
    referenced = validate_corpus(registry, schemas, errors)
    discovered = {p.resolve() for p in discover_structured_files()}
    unreferenced = discovered - referenced
    for missing in sorted(unreferenced):
        errors.append(f"corpus.json: record not indexed: "
                      f"{missing.relative_to(REPO_ROOT)}")

    # Pass 3
    plugin_ids, benchmark_ids = collect_conformance_catalogue()
    impl_ok, impl_bad = verify_links(
        requirement_files, plugin_ids, benchmark_ids, errors)

    # Report
    if errors:
        print("FAIL", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        print(f"\n{len(errors)} error(s). "
              f"records={total_records} requirements={total_requirements} "
              f"impl_ok={impl_ok} impl_bad={impl_bad}", file=sys.stderr)
        return 1
    print(f"OK  records={total_records} requirements={total_requirements} "
          f"impl_links_ok={impl_ok} plugins={len(plugin_ids)} "
          f"benchmarks={len(benchmark_ids)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
