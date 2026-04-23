#!/usr/bin/env python3
"""
Schema Validator for Training Data
===================================

Validates training data files against the official JSON schemas in docs/schema/.
Bridges the gap between src/training and docs/schema.

Usage:
    python -m schema_pipeline.schema_validator --file data/massive_semantic/training_data.jsonl
    python -m schema_pipeline.schema_validator --all --strict
"""

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
import logging

# Try to import jsonschema and referencing
try:
    from jsonschema import Draft7Validator
    HAS_JSONSCHEMA = True
except ImportError:
    HAS_JSONSCHEMA = False

try:
    from referencing import Registry, Resource
    from referencing.jsonschema import DRAFT7
    HAS_REFERENCING = True
except ImportError:
    HAS_REFERENCING = False

try:
    import yaml
    HAS_YAML = True
except ImportError:
    HAS_YAML = False

logging.basicConfig(level=logging.INFO, format='%(levelname)s: %(message)s')
logger = logging.getLogger(__name__)

# Path configuration
PROJECT_ROOT = Path(__file__).parent.parent.parent.parent  # sap-oss root
SCHEMA_DIR = PROJECT_ROOT / "docs" / "schema"
TRAINING_DIR = Path(__file__).parent.parent  # src/training

# Training data format schemas
# The current training data uses a simpler format, we define it here
SIMPLE_TRAINING_EXAMPLE_SCHEMA = {
    "$schema": "http://json-schema.org/draft-07/schema#",
    "$id": "https://sap-oss.github.io/schema/simula/simple-training-example.schema.json",
    "title": "Simple Training Example",
    "description": "Schema for current training data format (question/sql pairs)",
    "type": "object",
    "required": ["question", "sql"],
    "additionalProperties": True,  # Allow extra fields for flexibility
    "properties": {
        "question": {
            "type": "string",
            "minLength": 1,
            "description": "Natural language question"
        },
        "sql": {
            "type": "string",
            "minLength": 1,
            "description": "SQL query answer"
        },
        "domain": {
            "type": "string",
            "description": "Business domain"
        },
        "type": {
            "type": "string",
            "description": "Query type"
        },
        "term": {
            "type": "string",
            "description": "Financial term category"
        },
        "context": {
            "type": "string",
            "description": "Usage context"
        },
        "system_prompt": {
            "type": "string",
            "description": "System prompt for the assistant"
        }
    }
}

# Strict schema matching docs/schema/simula/training-example.schema.json
# Used when --strict flag is passed
STRICT_TRAINING_EXAMPLE_SCHEMA = None  # Loaded from docs/schema at runtime


def load_schema_registry() -> Optional[Registry]:
    """Load all schemas from docs/schema into a registry."""
    if not HAS_REFERENCING:
        logger.warning("referencing library not installed, cross-references won't work")
        return None
    
    resources = []
    
    # Load simula schemas
    simula_dir = SCHEMA_DIR / "simula"
    if simula_dir.exists():
        for schema_file in simula_dir.glob("*.json"):
            try:
                with open(schema_file) as f:
                    schema = json.load(f)
                if "$id" in schema:
                    resource = Resource.from_contents(schema, default_specification=DRAFT7)
                    resources.append((schema["$id"], resource))
            except Exception as e:
                logger.warning(f"Could not load {schema_file}: {e}")
    
    # Load common schemas
    common_dir = SCHEMA_DIR / "common"
    if common_dir.exists():
        for schema_file in common_dir.glob("*.json"):
            try:
                with open(schema_file) as f:
                    schema = json.load(f)
                if "$id" in schema:
                    resource = Resource.from_contents(schema, default_specification=DRAFT7)
                    resources.append((schema["$id"], resource))
            except Exception as e:
                logger.warning(f"Could not load {schema_file}: {e}")
    
    return Registry().with_resources(resources) if resources else None


def load_strict_schema() -> Dict[str, Any]:
    """Load the official training-example schema from docs/schema."""
    schema_path = SCHEMA_DIR / "simula" / "training-example.schema.json"
    if schema_path.exists():
        with open(schema_path) as f:
            return json.load(f)
    else:
        logger.warning(f"Strict schema not found at {schema_path}")
        return SIMPLE_TRAINING_EXAMPLE_SCHEMA


def validate_jsonl_file(
    file_path: Path,
    schema: Dict[str, Any],
    registry: Optional[Registry] = None,
    max_errors: int = 10
) -> Tuple[int, int, List[str]]:
    """
    Validate a JSONL file against a schema.
    
    Returns:
        Tuple of (valid_count, invalid_count, error_messages)
    """
    if not HAS_JSONSCHEMA:
        return 0, 0, ["jsonschema library not installed"]
    
    valid_count = 0
    invalid_count = 0
    errors = []
    
    if registry:
        validator = Draft7Validator(schema, registry=registry)
    else:
        validator = Draft7Validator(schema)
    
    with open(file_path, 'r', encoding='utf-8') as f:
        for line_num, line in enumerate(f, 1):
            if not line.strip():
                continue
            
            try:
                record = json.loads(line)
            except json.JSONDecodeError as e:
                invalid_count += 1
                if len(errors) < max_errors:
                    errors.append(f"Line {line_num}: JSON parse error: {e}")
                continue
            
            validation_errors = list(validator.iter_errors(record))
            if validation_errors:
                invalid_count += 1
                if len(errors) < max_errors:
                    for err in validation_errors[:2]:  # Max 2 errors per line
                        path = ".".join(str(p) for p in err.absolute_path) or "(root)"
                        errors.append(f"Line {line_num} [{path}]: {err.message}")
            else:
                valid_count += 1
    
    return valid_count, invalid_count, errors


def validate_json_file(
    file_path: Path,
    schema: Dict[str, Any],
    registry: Optional[Registry] = None
) -> Tuple[bool, List[str]]:
    """Validate a single JSON file."""
    if not HAS_JSONSCHEMA:
        return False, ["jsonschema library not installed"]
    
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            data = json.load(f)
    except Exception as e:
        return False, [f"Could not load file: {e}"]
    
    if registry:
        validator = Draft7Validator(schema, registry=registry)
    else:
        validator = Draft7Validator(schema)
    
    errors = []
    for err in validator.iter_errors(data):
        path = ".".join(str(p) for p in err.absolute_path) or "(root)"
        errors.append(f"[{path}]: {err.message}")
    
    return len(errors) == 0, errors


def find_training_files() -> List[Path]:
    """Find all training data files in src/training/data."""
    data_dir = TRAINING_DIR / "data"
    files = []
    
    # JSONL files
    for jsonl in data_dir.rglob("*.jsonl"):
        files.append(jsonl)
    
    # JSON files that look like training data
    for json_file in data_dir.rglob("*.json"):
        # Skip config/metadata files
        if not any(skip in json_file.name for skip in ["config", "statistics", "metadata"]):
            files.append(json_file)
    
    return sorted(files)


def main():
    parser = argparse.ArgumentParser(
        description="Validate training data against JSON schemas",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python -m schema_pipeline.schema_validator --file data/massive_semantic/train.jsonl
  python -m schema_pipeline.schema_validator --all
  python -m schema_pipeline.schema_validator --all --strict
        """
    )
    
    parser.add_argument(
        '--file', '-f',
        type=Path,
        help='Specific file to validate'
    )
    
    parser.add_argument(
        '--all', '-a',
        action='store_true',
        help='Validate all training data files'
    )
    
    parser.add_argument(
        '--strict',
        action='store_true',
        help='Use strict schema from docs/schema (requires all fields)'
    )
    
    parser.add_argument(
        '--max-errors',
        type=int,
        default=10,
        help='Maximum errors to report per file'
    )
    
    parser.add_argument(
        '--json-output',
        action='store_true',
        help='Output results as JSON'
    )
    
    args = parser.parse_args()
    
    # Check dependencies
    if not HAS_JSONSCHEMA:
        print("ERROR: jsonschema not installed. Run: pip install jsonschema", file=sys.stderr)
        sys.exit(1)
    
    # Load schema
    if args.strict:
        schema = load_strict_schema()
        logger.info("Using strict schema from docs/schema/simula/training-example.schema.json")
    else:
        schema = SIMPLE_TRAINING_EXAMPLE_SCHEMA
        logger.info("Using simple/flexible training schema")
    
    # Load registry for cross-references
    registry = load_schema_registry()
    
    # Collect files to validate
    if args.file:
        files = [args.file]
    elif args.all:
        files = find_training_files()
    else:
        parser.print_help()
        sys.exit(1)
    
    # Validate files
    results = []
    total_valid = 0
    total_invalid = 0
    
    for file_path in files:
        if not file_path.exists():
            print(f"File not found: {file_path}", file=sys.stderr)
            continue
        
        if file_path.suffix == '.jsonl':
            valid, invalid, errors = validate_jsonl_file(
                file_path, schema, registry, args.max_errors
            )
            total_valid += valid
            total_invalid += invalid
            
            result = {
                "file": str(file_path.relative_to(TRAINING_DIR) if file_path.is_relative_to(TRAINING_DIR) else file_path),
                "valid": valid,
                "invalid": invalid,
                "errors": errors
            }
        else:
            valid, errors = validate_json_file(file_path, schema, registry)
            if valid:
                total_valid += 1
            else:
                total_invalid += 1
            
            result = {
                "file": str(file_path.relative_to(TRAINING_DIR) if file_path.is_relative_to(TRAINING_DIR) else file_path),
                "valid": 1 if valid else 0,
                "invalid": 0 if valid else 1,
                "errors": errors
            }
        
        results.append(result)
    
    # Output results
    if args.json_output:
        output = {
            "schema_mode": "strict" if args.strict else "simple",
            "total_valid": total_valid,
            "total_invalid": total_invalid,
            "files": results
        }
        print(json.dumps(output, indent=2))
    else:
        print(f"\n{'='*60}")
        print(f"Training Data Validation Results")
        print(f"Schema mode: {'strict' if args.strict else 'simple (flexible)'}")
        print(f"{'='*60}\n")
        
        for result in results:
            file_name = result["file"]
            valid = result["valid"]
            invalid = result["invalid"]
            errors = result["errors"]
            
            if invalid == 0:
                print(f"✓ {file_name}: {valid} valid records")
            else:
                print(f"✗ {file_name}: {valid} valid, {invalid} invalid")
                for err in errors:
                    print(f"    - {err}")
        
        print(f"\n{'='*60}")
        print(f"Total: {total_valid} valid, {total_invalid} invalid")
        print(f"{'='*60}")
    
    # Exit with error code if any invalid
    sys.exit(0 if total_invalid == 0 else 1)


if __name__ == "__main__":
    main()