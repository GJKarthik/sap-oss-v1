#!/usr/bin/env python3
"""
Unified Schema Validator for SAP-OSS
=====================================

Validates JSON/YAML files against the unified schema registry.
Addresses review issue: "Unified validator implementation pending"

Updated: 2026-04-19 - Migrated from deprecated RefResolver to referencing library
Compatible with jsonschema 4.x/5.x

Usage:
    python docs/schema/validate.py --domain arabic --file data.json
    python docs/schema/validate.py --all
    python docs/schema/validate.py --registry-check
"""

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
import logging

try:
    import jsonschema
    from jsonschema import Draft7Validator
    HAS_JSONSCHEMA = True
except ImportError:
    HAS_JSONSCHEMA = False
    print("Warning: jsonschema not installed. Run: pip install jsonschema")

# Modern referencing library (replaces deprecated RefResolver)
try:
    from referencing import Registry, Resource
    from referencing.jsonschema import DRAFT7
    HAS_REFERENCING = True
except ImportError:
    HAS_REFERENCING = False
    print("Warning: referencing not installed. Run: pip install referencing")

try:
    import yaml
    HAS_YAML = True
except ImportError:
    HAS_YAML = False

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(levelname)s: %(message)s')
logger = logging.getLogger(__name__)

# Schema registry base path
SCHEMA_BASE = Path(__file__).parent
REGISTRY_PATH = SCHEMA_BASE / "registry.json"

# Domain to schema directory mapping
DOMAIN_SCHEMAS = {
    "arabic": {
        "directory": "arabic",
        "schemas": [
            "invoice.schema.json",
            "vendor.schema.json", 
            "ocr-result.schema.json",
            "vat-checklist.schema.json"
        ]
    },
    "tb": {
        "directory": "tb",
        "schemas": [
            "tb-extract.schema.json",
            "pl-extract.schema.json",
            "variance-record.schema.json",
            "commentary-draft.schema.json",
            "decision-point.schema.json",
            "entity-params.schema.json"
        ]
    },
    "simula": {
        "directory": "simula",
        "schemas": [
            "taxonomy.schema.json",
            "training-example.schema.json",
            "config.schema.json",
            "meta-prompt.schema.json",
            "hana-schema-entry.schema.json"
        ]
    },
    "regulations": {
        "directory": "regulations",
        "schemas": [
            "regulation.schema.json",
            "requirement.schema.json",
            "conformance-tool.schema.json",
            "corpus.schema.json"
        ]
    },
    "common": {
        "directory": "common",
        "schemas": [
            "enums.yaml",
            "moscow.yaml",
            "base-types.schema.json"
        ]
    }
}


def load_file(path: Path) -> Optional[Dict[str, Any]]:
    """Load JSON or YAML file."""
    if not path.exists():
        logger.error(f"File not found: {path}")
        return None
    
    try:
        with open(path, 'r', encoding='utf-8') as f:
            if path.suffix in ['.yaml', '.yml']:
                if not HAS_YAML:
                    logger.error("PyYAML not installed for YAML files")
                    return None
                return yaml.safe_load(f)
            else:
                return json.load(f)
    except Exception as e:
        logger.error(f"Error loading {path}: {e}")
        return None


def load_schema(schema_path: Path) -> Optional[Dict[str, Any]]:
    """Load a JSON Schema file."""
    return load_file(schema_path)


def build_schema_registry() -> "Registry":
    """
    Build a referencing Registry with all schemas pre-loaded.
    This replaces the deprecated RefResolver approach.
    """
    if not HAS_REFERENCING:
        return None
    
    resources = []
    
    # Load all schemas from all domains
    for domain, config in DOMAIN_SCHEMAS.items():
        domain_dir = SCHEMA_BASE / config["directory"]
        if not domain_dir.exists():
            continue
            
        for schema_name in config["schemas"]:
            if not schema_name.endswith('.json'):
                continue  # Skip YAML files for JSON Schema registry
            
            schema_path = domain_dir / schema_name
            if not schema_path.exists():
                continue
            
            schema = load_file(schema_path)
            if schema is None or "$id" not in schema:
                continue
            
            # Create a Resource for this schema
            try:
                resource = Resource.from_contents(schema, default_specification=DRAFT7)
                resources.append((schema["$id"], resource))
            except Exception as e:
                logger.warning(f"Could not create resource for {schema_path}: {e}")
    
    # Build the registry
    return Registry().with_resources(resources)


def create_validator(schema: Dict[str, Any], registry: Optional["Registry"] = None) -> Draft7Validator:
    """
    Create a Draft7Validator with the schema registry.
    Uses modern referencing library instead of deprecated RefResolver.
    """
    if registry is not None:
        return Draft7Validator(schema, registry=registry)
    else:
        return Draft7Validator(schema)


def validate_instance(
    instance: Dict[str, Any],
    schema: Dict[str, Any],
    schema_path: Path,
    registry: Optional["Registry"] = None
) -> Tuple[bool, List[str]]:
    """
    Validate a data instance against a schema.
    
    Returns:
        Tuple of (is_valid, list of error messages)
    """
    if not HAS_JSONSCHEMA:
        return False, ["jsonschema library not installed"]
    
    errors = []
    try:
        # Build registry if not provided and referencing is available
        if registry is None and HAS_REFERENCING:
            registry = build_schema_registry()
        
        validator = create_validator(schema, registry)
        
        for error in validator.iter_errors(instance):
            path = ".".join(str(p) for p in error.absolute_path)
            if path:
                errors.append(f"  [{path}] {error.message}")
            else:
                errors.append(f"  {error.message}")
    except Exception as e:
        errors.append(f"Validation error: {e}")
    
    return len(errors) == 0, errors


def validate_file(
    data_path: Path,
    schema_path: Path,
    registry: Optional["Registry"] = None
) -> Tuple[bool, List[str]]:
    """Validate a data file against a schema file."""
    data = load_file(data_path)
    if data is None:
        return False, [f"Could not load data file: {data_path}"]
    
    schema = load_schema(schema_path)
    if schema is None:
        return False, [f"Could not load schema file: {schema_path}"]
    
    return validate_instance(data, schema, schema_path, registry)


# JSON Schema meta-schema for validating schema files themselves
META_SCHEMA = {
    "$schema": "http://json-schema.org/draft-07/schema#",
    "$id": "https://sap-oss.github.io/schema/meta-schema.json",
    "title": "SAP OSS Schema Meta-Schema",
    "description": "Meta-schema for validating SAP-OSS schema files",
    "type": "object",
    "required": ["$schema", "$id", "title"],
    "properties": {
        "$schema": {
            "type": "string",
            "pattern": "^http://json-schema.org/draft-0[47]/schema#?$"
        },
        "$id": {
            "type": "string",
            "format": "uri"
        },
        "title": {
            "type": "string",
            "minLength": 1
        },
        "description": {
            "type": "string"
        },
        "type": {
            "oneOf": [
                {"type": "string", "enum": ["object", "array", "string", "number", "integer", "boolean", "null"]},
                {"type": "array", "items": {"type": "string"}}
            ]
        },
        "properties": {
            "type": "object"
        },
        "required": {
            "type": "array",
            "items": {"type": "string"}
        },
        "additionalProperties": {
            "oneOf": [{"type": "boolean"}, {"type": "object"}]
        }
    }
}


def validate_schema_against_meta(schema_path: Path) -> Tuple[bool, List[str]]:
    """
    Validate a schema file against the SAP-OSS meta-schema.
    Ensures all schemas follow consistent conventions.
    """
    if not HAS_JSONSCHEMA:
        return False, ["jsonschema library not installed"]
    
    schema = load_schema(schema_path)
    if schema is None:
        return False, [f"Could not load schema: {schema_path}"]
    
    errors = []
    
    # Validate against meta-schema
    try:
        validator = Draft7Validator(META_SCHEMA)
        for error in validator.iter_errors(schema):
            path = ".".join(str(p) for p in error.absolute_path)
            if path:
                errors.append(f"  [{path}] {error.message}")
            else:
                errors.append(f"  {error.message}")
    except Exception as e:
        errors.append(f"Meta-schema validation error: {e}")
    
    # Additional SAP-OSS conventions
    if "$id" in schema:
        if not schema["$id"].startswith("https://sap-oss.github.io/schema/"):
            errors.append("  $id should start with https://sap-oss.github.io/schema/")
    
    if "title" in schema and len(schema["title"]) < 3:
        errors.append("  title should be at least 3 characters")
    
    # Check for additionalProperties: false (new convention)
    if schema.get("type") == "object" and "additionalProperties" not in schema:
        errors.append("  Missing 'additionalProperties: false' at root level (strict schema convention)")
    
    return len(errors) == 0, errors


def check_registry() -> Tuple[bool, List[str]]:
    """
    Check that all schemas in registry exist and are valid JSON Schema.
    
    Returns:
        Tuple of (all_valid, list of issues)
    """
    issues = []
    
    # Check registry.json exists
    if not REGISTRY_PATH.exists():
        issues.append(f"Registry file not found: {REGISTRY_PATH}")
        return False, issues
    
    registry = load_file(REGISTRY_PATH)
    if registry is None:
        issues.append("Could not load registry.json")
        return False, issues
    
    # Check all domain schemas exist
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
            
            # Try to load and validate schema syntax
            schema = load_file(schema_path)
            if schema is None:
                issues.append(f"Could not load schema: {schema_path}")
                continue
            
            # Check for $schema declaration
            if schema_name.endswith('.json') and '$schema' not in schema:
                issues.append(f"Missing $schema declaration: {schema_path}")
            
            # Check for $id declaration
            if schema_name.endswith('.json') and '$id' not in schema:
                issues.append(f"Missing $id declaration: {schema_path}")
            
            # Check for additionalProperties: false
            if schema_name.endswith('.json') and schema.get("type") == "object":
                if schema.get("additionalProperties") is not False:
                    issues.append(f"Missing 'additionalProperties: false': {schema_path}")
    
    return len(issues) == 0, issues


def check_registry_status() -> Dict[str, Any]:
    """
    Check migration status of all domains.
    
    Returns status report addressing review issue about "migration pending".
    """
    status = {
        "registry_exists": REGISTRY_PATH.exists(),
        "domains": {}
    }
    
    for domain, config in DOMAIN_SCHEMAS.items():
        domain_dir = SCHEMA_BASE / config["directory"]
        existing = []
        missing = []
        
        for schema_name in config["schemas"]:
            schema_path = domain_dir / schema_name
            if schema_path.exists():
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
            "completion_percent": round(100 * complete / total, 1) if total > 0 else 0,
            "status": "complete" if len(missing) == 0 else "incomplete",
            "missing_schemas": missing
        }
    
    # Calculate overall status
    total_schemas = sum(d["total_schemas"] for d in status["domains"].values())
    existing_schemas = sum(d["existing"] for d in status["domains"].values())
    status["overall"] = {
        "total_schemas": total_schemas,
        "existing_schemas": existing_schemas,
        "completion_percent": round(100 * existing_schemas / total_schemas, 1) if total_schemas > 0 else 0,
        "migration_status": "complete" if existing_schemas == total_schemas else "in_progress"
    }
    
    return status


def validate_all_schemas() -> Tuple[bool, List[str]]:
    """Validate all schema files in the registry for syntax and conventions."""
    all_issues = []
    
    for domain, config in DOMAIN_SCHEMAS.items():
        domain_dir = SCHEMA_BASE / config["directory"]
        if not domain_dir.exists():
            all_issues.append(f"Domain directory missing: {domain}")
            continue
        
        for schema_name in config["schemas"]:
            if not schema_name.endswith('.json'):
                continue  # Skip YAML files
            
            schema_path = domain_dir / schema_name
            if not schema_path.exists():
                all_issues.append(f"Schema missing: {schema_path}")
                continue
            
            valid, issues = validate_schema_against_meta(schema_path)
            if not valid:
                all_issues.append(f"\n{schema_path}:")
                all_issues.extend(issues)
    
    return len(all_issues) == 0, all_issues


def main():
    parser = argparse.ArgumentParser(
        description="Unified Schema Validator for SAP-OSS",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s --registry-check
  %(prog)s --registry-status
  %(prog)s --validate-all
  %(prog)s --domain arabic --schema invoice.schema.json --file invoice.json
  %(prog)s --validate-schema docs/schema/tb/variance-record.schema.json
        """
    )
    
    parser.add_argument(
        '--registry-check',
        action='store_true',
        help='Check that all schemas in registry exist and are valid'
    )
    
    parser.add_argument(
        '--registry-status',
        action='store_true',
        help='Show migration status of all domains'
    )
    
    parser.add_argument(
        '--validate-all',
        action='store_true',
        help='Validate all schema files against meta-schema and conventions'
    )
    
    parser.add_argument(
        '--domain',
        choices=list(DOMAIN_SCHEMAS.keys()),
        help='Domain to validate against'
    )
    
    parser.add_argument(
        '--schema',
        help='Schema file name within domain'
    )
    
    parser.add_argument(
        '--file',
        type=Path,
        help='Data file to validate'
    )
    
    parser.add_argument(
        '--validate-schema',
        type=Path,
        help='Validate that a schema file is valid JSON Schema'
    )
    
    parser.add_argument(
        '--json',
        action='store_true',
        help='Output results as JSON'
    )
    
    args = parser.parse_args()
    
    # Registry check
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
        sys.exit(0 if valid else 1)
    
    # Registry status
    if args.registry_status:
        status = check_registry_status()
        if args.json:
            print(json.dumps(status, indent=2))
        else:
            print("\n=== Schema Registry Migration Status ===\n")
            print(f"Registry exists: {'Yes' if status['registry_exists'] else 'No'}")
            print(f"\nOverall: {status['overall']['existing_schemas']}/{status['overall']['total_schemas']} schemas ({status['overall']['completion_percent']}%)")
            print(f"Migration status: {status['overall']['migration_status'].upper()}\n")
            
            for domain, info in status["domains"].items():
                icon = "✓" if info["status"] == "complete" else "○"
                print(f"{icon} {domain}: {info['existing']}/{info['total_schemas']} ({info['completion_percent']}%)")
                if info["missing_schemas"]:
                    for m in info["missing_schemas"]:
                        print(f"    - Missing: {m}")
        sys.exit(0)
    
    # Validate all schemas
    if args.validate_all:
        valid, issues = validate_all_schemas()
        if args.json:
            print(json.dumps({"valid": valid, "issues": issues}, indent=2))
        else:
            if valid:
                print("✓ All schemas pass validation")
            else:
                print("✗ Schema validation issues found:")
                for issue in issues:
                    print(issue)
        sys.exit(0 if valid else 1)
    
    # Validate schema file
    if args.validate_schema:
        schema = load_schema(args.validate_schema)
        if schema is None:
            print(f"✗ Could not load schema: {args.validate_schema}")
            sys.exit(1)
        
        valid, issues = validate_schema_against_meta(args.validate_schema)
        
        if args.json:
            print(json.dumps({"valid": valid, "issues": issues}, indent=2))
        else:
            if valid:
                print(f"✓ Schema is valid: {args.validate_schema}")
            else:
                print(f"✗ Schema validation issues:")
                for issue in issues:
                    print(issue)
        sys.exit(0 if valid else 1)
    
    # Validate data file against schema
    if args.domain and args.schema and args.file:
        if args.domain not in DOMAIN_SCHEMAS:
            print(f"Unknown domain: {args.domain}")
            sys.exit(1)
        
        schema_path = SCHEMA_BASE / DOMAIN_SCHEMAS[args.domain]["directory"] / args.schema
        if not schema_path.exists():
            print(f"Schema not found: {schema_path}")
            sys.exit(1)
        
        # Build registry for cross-schema references
        registry = build_schema_registry() if HAS_REFERENCING else None
        valid, errors = validate_file(args.file, schema_path, registry)
        
        if args.json:
            print(json.dumps({"valid": valid, "errors": errors}, indent=2))
        else:
            if valid:
                print(f"✓ Validation passed: {args.file}")
            else:
                print(f"✗ Validation failed: {args.file}")
                for error in errors:
                    print(error)
        
        sys.exit(0 if valid else 1)
    
    # No action specified
    parser.print_help()
    sys.exit(1)


if __name__ == "__main__":
    main()