#!/usr/bin/env python3
"""
Unified Schema Validator for SAP-OSS
=====================================

Validates JSON/YAML files against the unified schema registry.

Changes in v1.2.0 (April 2026):
  - Migrated from deprecated `jsonschema.RefResolver` to `referencing`
    library (required for jsonschema >= 4.18).
  - Added `--run-fixtures`: validates every file under tests/fixtures/
    against its declared schema, fails non-zero on any error.
  - Added `--check-roadmap`: ensures every RoadmapReference in the
    fixtures references a known milestone from common/moscow.yaml.
  - Added graceful fallback: if `referencing` is not installed, falls
    back to `RefResolver` with a deprecation warning silenced (so the
    tool still works on older Python toolchains).

Usage:
    python docs/schema/validate.py --registry-check
    python docs/schema/validate.py --registry-status
    python docs/schema/validate.py --run-fixtures
    python docs/schema/validate.py --check-roadmap
    python docs/schema/validate.py --domain arabic --schema invoice.schema.json --file data.json
    python docs/schema/validate.py --all
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
import warnings
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# -----------------------------------------------------------------------------
# Optional deps (jsonschema, referencing, yaml)
# -----------------------------------------------------------------------------
try:
    import jsonschema
    from jsonschema import Draft7Validator
    HAS_JSONSCHEMA = True
except ImportError:
    HAS_JSONSCHEMA = False
    print("Warning: jsonschema not installed. Run: pip install -r docs/schema/requirements.txt")

# Prefer the new `referencing` API (jsonschema >= 4.18). Fall back to the
# deprecated RefResolver if `referencing` is absent so older environments keep
# working — but silence the DeprecationWarning so CI output stays clean.
HAS_REFERENCING = False
if HAS_JSONSCHEMA:
    try:
        from referencing import Registry, Resource
        from referencing.jsonschema import DRAFT7
        HAS_REFERENCING = True
    except ImportError:
        # Silence the legacy RefResolver deprecation warning in one place.
        warnings.filterwarnings(
            "ignore",
            message=r"jsonschema\.RefResolver is deprecated.*",
            category=DeprecationWarning,
        )
        from jsonschema import RefResolver  # type: ignore

try:
    import yaml
    HAS_YAML = True
except ImportError:
    HAS_YAML = False

# -----------------------------------------------------------------------------
# Setup
# -----------------------------------------------------------------------------
logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
logger = logging.getLogger(__name__)

SCHEMA_BASE = Path(__file__).parent
REGISTRY_PATH = SCHEMA_BASE / "registry.json"
MOSCOW_PATH = SCHEMA_BASE / "common" / "moscow.yaml"
FIXTURES_BASE = SCHEMA_BASE / "tests" / "fixtures"

DOMAIN_SCHEMAS = {
    "arabic": {
        "directory": "arabic",
        "schemas": [
            "invoice.schema.json",
            "vendor.schema.json",
            "ocr-result.schema.json",
            "vat-checklist.schema.json",
        ],
    },
    "tb": {
        "directory": "tb",
        "schemas": [
            "tb-extract.schema.json",
            "pl-extract.schema.json",
            "variance-record.schema.json",
            "commentary-draft.schema.json",
            "decision-point.schema.json",
            "entity-params.schema.json",
        ],
    },
    "simula": {
        "directory": "simula",
        "schemas": [
            "taxonomy.schema.json",
            "training-example.schema.json",
            "config.schema.json",
            "meta-prompt.schema.json",
            "hana-schema-entry.schema.json",
        ],
    },
    "regulations": {
        "directory": "regulations",
        "schemas": [
            "regulation.schema.json",
            "requirement.schema.json",
            "conformance-tool.schema.json",
            "corpus.schema.json",
        ],
    },
    "common": {
        "directory": "common",
        "schemas": [
            "base-types.schema.json",
        ],
    },
}


# -----------------------------------------------------------------------------
# File loading
# -----------------------------------------------------------------------------
def load_file(path: Path) -> Optional[Dict[str, Any]]:
    """Load JSON or YAML file."""
    if not path.exists():
        logger.error(f"File not found: {path}")
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            if path.suffix in [".yaml", ".yml"]:
                if not HAS_YAML:
                    logger.error("PyYAML not installed for YAML files")
                    return None
                return yaml.safe_load(f)
            return json.load(f)
    except Exception as e:
        logger.error(f"Error loading {path}: {e}")
        return None


def load_schema(schema_path: Path) -> Optional[Dict[str, Any]]:
    return load_file(schema_path)


# -----------------------------------------------------------------------------
# Validator construction (referencing first, RefResolver fallback)
# -----------------------------------------------------------------------------
def _build_registry() -> Any:
    """Build a `referencing.Registry` populated with every local schema.

    This lets `$ref: "https://sap-oss.github.io/schema/common/base-types.schema.json#/definitions/..."`
    resolve to the local file without network I/O.
    """
    registry = Registry()
    for schema_path in SCHEMA_BASE.glob("**/*.schema.json"):
        schema = load_schema(schema_path)
        if schema is None or "$id" not in schema:
            continue
        resource = Resource(contents=schema, specification=DRAFT7)
        registry = registry.with_resource(schema["$id"], resource)
    return registry


def _make_validator(schema: Dict[str, Any], schema_path: Path) -> Any:
    """Return a Draft7Validator that can resolve cross-schema $refs."""
    if HAS_REFERENCING:
        registry = _build_registry()
        return Draft7Validator(schema, registry=registry)
    # Fallback path (deprecated RefResolver)
    schema_uri = f"file://{schema_path.parent.absolute()}/"
    resolver = RefResolver(schema_uri, schema)  # type: ignore[name-defined]
    return Draft7Validator(schema, resolver=resolver)


def validate_instance(
    instance: Dict[str, Any],
    schema: Dict[str, Any],
    schema_path: Path,
) -> Tuple[bool, List[str]]:
    """Validate a data instance against a schema. Returns (ok, errors)."""
    if not HAS_JSONSCHEMA:
        return False, ["jsonschema library not installed"]

    errors: List[str] = []
    try:
        validator = _make_validator(schema, schema_path)
        for error in validator.iter_errors(instance):
            path = ".".join(str(p) for p in error.absolute_path)
            prefix = f"  [{path}] " if path else "  "
            errors.append(f"{prefix}{error.message}")
    except Exception as e:
        errors.append(f"Validation error: {e}")

    return len(errors) == 0, errors


def validate_file(data_path: Path, schema_path: Path) -> Tuple[bool, List[str]]:
    data = load_file(data_path)
    if data is None:
        return False, [f"Could not load data file: {data_path}"]
    schema = load_schema(schema_path)
    if schema is None:
        return False, [f"Could not load schema file: {schema_path}"]
    return validate_instance(data, schema, schema_path)


# -----------------------------------------------------------------------------
# Meta-schema (conventions enforced on every SAP-OSS schema)
# -----------------------------------------------------------------------------
META_SCHEMA = {
    "$schema": "http://json-schema.org/draft-07/schema#",
    "$id": "https://sap-oss.github.io/schema/meta-schema.json",
    "title": "SAP OSS Schema Meta-Schema",
    "description": "Conventions every SAP-OSS schema must follow.",
    "type": "object",
    "required": ["$schema", "$id", "title"],
    "properties": {
        "$schema": {
            "type": "string",
            "pattern": "^http://json-schema.org/draft-0[47]/schema#?$",
        },
        "$id": {"type": "string", "format": "uri"},
        "title": {"type": "string", "minLength": 1},
        "description": {"type": "string"},
        "type": {
            "oneOf": [
                {"type": "string", "enum": ["object", "array", "string", "number", "integer", "boolean", "null"]},
                {"type": "array", "items": {"type": "string"}},
            ]
        },
        "properties": {"type": "object"},
        "required": {"type": "array", "items": {"type": "string"}},
        "additionalProperties": {"oneOf": [{"type": "boolean"}, {"type": "object"}]},
    },
}


def validate_schema_against_meta(schema_path: Path) -> Tuple[bool, List[str]]:
    """Validate a schema file against the SAP-OSS meta-schema + conventions."""
    if not HAS_JSONSCHEMA:
        return False, ["jsonschema library not installed"]

    schema = load_schema(schema_path)
    if schema is None:
        return False, [f"Could not load schema: {schema_path}"]

    errors: List[str] = []
    try:
        validator = Draft7Validator(META_SCHEMA)
        for error in validator.iter_errors(schema):
            path = ".".join(str(p) for p in error.absolute_path)
            prefix = f"  [{path}] " if path else "  "
            errors.append(f"{prefix}{error.message}")
    except Exception as e:
        errors.append(f"Meta-schema validation error: {e}")

    if "$id" in schema and not schema["$id"].startswith("https://sap-oss.github.io/schema/"):
        errors.append("  $id should start with https://sap-oss.github.io/schema/")

    if "title" in schema and len(schema["title"]) < 3:
        errors.append("  title should be at least 3 characters")

    # Enforce strict-by-default: every object with `properties` needs
    # `additionalProperties: false` OR explicit `true`/{...}.
    def walk(node: Any, path: str) -> None:
        if isinstance(node, dict):
            if node.get("type", "object") == "object" and "properties" in node:
                if "additionalProperties" not in node:
                    errors.append(f"  [{path}] object has properties but no additionalProperties (strict-by-default)")
            for k, v in node.items():
                walk(v, f"{path}.{k}" if path else k)
        elif isinstance(node, list):
            for i, v in enumerate(node):
                walk(v, f"{path}[{i}]")

    walk(schema, "$")
    return len(errors) == 0, errors


# -----------------------------------------------------------------------------
# Registry checks
# -----------------------------------------------------------------------------
def check_registry() -> Tuple[bool, List[str]]:
    """Every schema in DOMAIN_SCHEMAS exists, parses, and declares `$schema`+`$id`."""
    issues: List[str] = []

    if not REGISTRY_PATH.exists():
        return False, [f"Registry file not found: {REGISTRY_PATH}"]
    if load_file(REGISTRY_PATH) is None:
        return False, ["Could not load registry.json"]

    for domain, config in DOMAIN_SCHEMAS.items():
        domain_dir = SCHEMA_BASE / config["directory"]
        if not domain_dir.exists():
            issues.append(f"Domain directory missing: {domain_dir}")
            continue

        for schema_name in config["schemas"]:
            schema_path = domain_dir / schema_name
            if not schema_path.exists():
                issues.append(f"Schema file missing: {schema_path}")
                continue

            schema = load_file(schema_path)
            if schema is None:
                issues.append(f"Could not load schema: {schema_path}")
                continue

            if schema_name.endswith(".json"):
                if "$schema" not in schema:
                    issues.append(f"Missing $schema declaration: {schema_path}")
                if "$id" not in schema:
                    issues.append(f"Missing $id declaration: {schema_path}")

    return len(issues) == 0, issues


def check_registry_status() -> Dict[str, Any]:
    status: Dict[str, Any] = {"registry_exists": REGISTRY_PATH.exists(), "domains": {}}
    for domain, config in DOMAIN_SCHEMAS.items():
        domain_dir = SCHEMA_BASE / config["directory"]
        existing: List[str] = []
        missing: List[str] = []
        for schema_name in config["schemas"]:
            if (domain_dir / schema_name).exists():
                existing.append(schema_name)
            else:
                missing.append(schema_name)
        total = len(config["schemas"])
        complete = len(existing)
        status["domains"][domain] = {
            "directory": str(domain_dir),
            "total_schemas": total,
            "existing": complete,
            "missing": len(missing),
            "completion_percent": round(100 * complete / total, 1) if total else 0,
            "status": "complete" if not missing else "incomplete",
            "missing_schemas": missing,
        }

    total_schemas = sum(d["total_schemas"] for d in status["domains"].values())
    existing_schemas = sum(d["existing"] for d in status["domains"].values())
    status["overall"] = {
        "total_schemas": total_schemas,
        "existing_schemas": existing_schemas,
        "completion_percent": round(100 * existing_schemas / total_schemas, 1) if total_schemas else 0,
        "migration_status": "complete" if existing_schemas == total_schemas else "in_progress",
    }
    return status


# -----------------------------------------------------------------------------
# Fixture + roadmap checks
# -----------------------------------------------------------------------------
def _iter_fixtures() -> List[Tuple[Path, Path]]:
    """Yield (fixture_path, schema_path) pairs.

    Fixture file-naming convention:
        tests/fixtures/<domain>/<schema-stem>.sample.json
            -> docs/schema/<domain>/<schema-stem>.schema.json

        e.g. tests/fixtures/arabic/invoice.sample.json
            -> docs/schema/arabic/invoice.schema.json
    """
    pairs: List[Tuple[Path, Path]] = []
    if not FIXTURES_BASE.exists():
        return pairs
    for fx in FIXTURES_BASE.glob("**/*.sample.json"):
        domain = fx.parent.name
        schema_stem = fx.stem.replace(".sample", "")
        schema_path = SCHEMA_BASE / domain / f"{schema_stem}.schema.json"
        if schema_path.exists():
            pairs.append((fx, schema_path))
    return pairs


def run_fixtures() -> Tuple[bool, List[str]]:
    """Validate every fixture against its matching schema."""
    pairs = _iter_fixtures()
    if not pairs:
        return True, ["No fixtures discovered under tests/fixtures/"]
    all_ok = True
    report: List[str] = []
    for fx, schema_path in pairs:
        ok, errors = validate_file(fx, schema_path)
        marker = "✓" if ok else "✗"
        report.append(f"  {marker} {fx.relative_to(SCHEMA_BASE)} -> {schema_path.name}")
        if not ok:
            all_ok = False
            for e in errors:
                report.append(f"      {e}")
    return all_ok, report


def _load_moscow_milestones() -> Dict[str, set]:
    """Return {domain: {milestone_id, ...}} from common/moscow.yaml."""
    data = load_file(MOSCOW_PATH) or {}
    result: Dict[str, set] = {}
    for domain, key in [
        ("arabic", "arabic_milestones"),
        ("tb", "tb_milestones"),
        ("simula", "simula_milestones"),
        ("regulations", "regulations_milestones"),
    ]:
        section = data.get(key, {}) or {}
        ids: set = set()
        for bucket in ("values", "should", "could", "wont"):
            ids.update((section.get(bucket) or {}).keys())
        result[domain] = ids
    return result


def check_roadmap() -> Tuple[bool, List[str]]:
    """Every RoadmapReference in fixtures references a milestone in moscow.yaml."""
    known = _load_moscow_milestones()
    issues: List[str] = []
    fixtures = list(FIXTURES_BASE.glob("**/*.sample.json")) if FIXTURES_BASE.exists() else []
    if not fixtures:
        return True, ["No fixtures to check."]

    def walk(node: Any, fx_name: str) -> None:
        if isinstance(node, dict):
            if "roadmap" in node and isinstance(node["roadmap"], dict):
                rm = node["roadmap"]
                domain = rm.get("domain")
                milestones = rm.get("milestones") or []
                if domain not in known:
                    issues.append(f"{fx_name}: unknown roadmap.domain '{domain}'")
                    return
                unknown = [m for m in milestones if m not in known[domain]]
                if unknown:
                    issues.append(
                        f"{fx_name}: roadmap.milestones {unknown} not in moscow.yaml[{domain}]"
                    )
            for v in node.values():
                walk(v, fx_name)
        elif isinstance(node, list):
            for v in node:
                walk(v, fx_name)

    for fx in fixtures:
        data = load_file(fx)
        if data is None:
            issues.append(f"{fx.name}: could not load")
            continue
        walk(data, str(fx.relative_to(SCHEMA_BASE)))

    return len(issues) == 0, issues or ["All RoadmapReferences resolve against moscow.yaml."]


# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(
        description="Unified Schema Validator for SAP-OSS",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s --registry-check
  %(prog)s --registry-status
  %(prog)s --run-fixtures
  %(prog)s --check-roadmap
  %(prog)s --domain arabic --schema invoice.schema.json --file invoice.json
  %(prog)s --validate-schema docs/schema/tb/variance-record.schema.json
  %(prog)s --all        # runs registry-check + run-fixtures + check-roadmap
        """,
    )

    parser.add_argument("--registry-check", action="store_true", help="Verify schemas exist and parse")
    parser.add_argument("--registry-status", action="store_true", help="Show domain migration status")
    parser.add_argument("--run-fixtures", action="store_true", help="Validate every tests/fixtures/**/*.sample.json")
    parser.add_argument("--check-roadmap", action="store_true", help="Resolve all RoadmapReferences against moscow.yaml")
    parser.add_argument("--all", action="store_true", help="Run registry-check + run-fixtures + check-roadmap")
    parser.add_argument("--domain", choices=list(DOMAIN_SCHEMAS.keys()), help="Domain to validate against")
    parser.add_argument("--schema", help="Schema file name within domain")
    parser.add_argument("--file", type=Path, help="Data file to validate")
    parser.add_argument("--validate-schema", type=Path, help="Validate a schema file is valid JSON Schema + conventions")
    parser.add_argument("--json", action="store_true", help="Output as JSON")

    args = parser.parse_args()

    # --all bundles three checks.
    if args.all:
        exit_code = 0
        for name, fn in [
            ("registry-check", check_registry),
            ("run-fixtures", run_fixtures),
            ("check-roadmap", check_roadmap),
        ]:
            ok, issues = fn()
            icon = "✓" if ok else "✗"
            print(f"{icon} {name}")
            for issue in issues:
                print(issue if issue.startswith("  ") else f"  - {issue}")
            if not ok:
                exit_code = 1
        return exit_code

    if args.registry_check:
        valid, issues = check_registry()
        if args.json:
            print(json.dumps({"valid": valid, "issues": issues}, indent=2))
        else:
            if valid:
                print("✓ Registry check passed - all schemas present and valid")
            else:
                print("✗ Registry check failed:")
                for issue in issues:
                    print(f"  - {issue}")
        return 0 if valid else 1

    if args.registry_status:
        status = check_registry_status()
        if args.json:
            print(json.dumps(status, indent=2))
        else:
            print("\n=== Schema Registry Migration Status ===\n")
            print(f"Registry exists: {'Yes' if status['registry_exists'] else 'No'}")
            o = status["overall"]
            print(f"\nOverall: {o['existing_schemas']}/{o['total_schemas']} schemas ({o['completion_percent']}%)")
            print(f"Migration status: {o['migration_status'].upper()}\n")
            for domain, info in status["domains"].items():
                icon = "✓" if info["status"] == "complete" else "○"
                print(f"{icon} {domain}: {info['existing']}/{info['total_schemas']} ({info['completion_percent']}%)")
                for m in info["missing_schemas"]:
                    print(f"    - Missing: {m}")
        return 0

    if args.run_fixtures:
        ok, report = run_fixtures()
        icon = "✓" if ok else "✗"
        print(f"{icon} run-fixtures")
        for line in report:
            print(line)
        return 0 if ok else 1

    if args.check_roadmap:
        ok, report = check_roadmap()
        icon = "✓" if ok else "✗"
        print(f"{icon} check-roadmap")
        for line in report:
            print(f"  {line}" if not line.startswith(" ") else line)
        return 0 if ok else 1

    if args.validate_schema:
        ok, errors = validate_schema_against_meta(args.validate_schema)
        if ok:
            print(f"✓ Schema is valid: {args.validate_schema}")
            return 0
        print(f"✗ Schema validation issues: {args.validate_schema}")
        for e in errors:
            print(e)
        return 1

    if args.domain and args.schema and args.file:
        if args.domain not in DOMAIN_SCHEMAS:
            print(f"Unknown domain: {args.domain}")
            return 1
        schema_path = SCHEMA_BASE / DOMAIN_SCHEMAS[args.domain]["directory"] / args.schema
        if not schema_path.exists():
            print(f"Schema not found: {schema_path}")
            return 1
        valid, errors = validate_file(args.file, schema_path)
        if args.json:
            print(json.dumps({"valid": valid, "errors": errors}, indent=2))
        else:
            if valid:
                print(f"✓ Validation passed: {args.file}")
            else:
                print(f"✗ Validation failed: {args.file}")
                for e in errors:
                    print(e)
        return 0 if valid else 1

    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
