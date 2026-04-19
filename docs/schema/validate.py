#!/usr/bin/env python3
"""
Unified Schema Validator for SAP-OSS
=====================================

Validates JSON/YAML files against the unified schema registry.
Addresses review issue: "Unified validator implementation pending"

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
    from jsonschema import Draft7Validator, RefResolver
    HAS_JSONSCHEMA = True
except ImportError:
    HAS_JSONSCHEMA = False
    print("Warning: jsonschema not installed. Run: pip install jsonschema")

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
            "decision-point.schema.json"
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


def create_resolver(schema: Dict[str, Any], schema_path: Path) -> RefResolver:
    """Create a RefResolver for handling $ref in schemas."""
    schema_uri = f"file://{schema_path.parent.absolute()}/"
    return RefResolver(schema_uri, schema)


def validate_instance(
    instance: Dict[str, Any],
    schema: Dict[str, Any],
    schema_path: Path
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
        resolver = create_resolver(schema, schema_path)
        validator = Draft7Validator(schema, resolver=resolver)
        
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
    schema_path: Path
) -> Tuple[bool, List[str]]:
    """Validate a data file against a schema file."""
    data = load_file(data_path)
    if data is None:
        return False, [f"Could not load data file: {data_path}"]
    
    schema = load_schema(schema_path)
    if schema is None:
        return False, [f"Could not load schema file: {schema_path}"]
    
    return validate_instance(data, schema, schema_path)


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


def main():
    parser = argparse.ArgumentParser(
        description="Unified Schema Validator for SAP-OSS",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s --registry-check
  %(prog)s --registry-status
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
    
    # Validate schema file
    if args.validate_schema:
        schema = load_schema(args.validate_schema)
        if schema is None:
            print(f"✗ Could not load schema: {args.validate_schema}")
            sys.exit(1)
        
        issues = []
        if '$schema' not in schema:
            issues.append("Missing $schema declaration")
        if '$id' not in schema:
            issues.append("Missing $id declaration")
        if 'type' not in schema and 'oneOf' not in schema and 'anyOf' not in schema:
            issues.append("Missing type definition")
        
        if issues:
            print(f"✗ Schema validation issues:")
            for issue in issues:
                print(f"  - {issue}")
            sys.exit(1)
        else:
            print(f"✓ Schema is valid: {args.validate_schema}")
            sys.exit(0)
    
    # Validate data file against schema
    if args.domain and args.schema and args.file:
        if args.domain not in DOMAIN_SCHEMAS:
            print(f"Unknown domain: {args.domain}")
            sys.exit(1)
        
        schema_path = SCHEMA_BASE / DOMAIN_SCHEMAS[args.domain]["directory"] / args.schema
        if not schema_path.exists():
            print(f"Schema not found: {schema_path}")
            sys.exit(1)
        
        valid, errors = validate_file(args.file, schema_path)
        
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