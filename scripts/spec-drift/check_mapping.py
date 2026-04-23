#!/usr/bin/env python3
"""
Validate and manage the spec-code mapping registry.

Commands:
  check     - Validate mapping YAML and check all referenced files exist
  domains   - List all available domains
  exceptions - Review drift exceptions
  
Usage:
  python3 scripts/spec-drift/check_mapping.py [check|domains|exceptions]
"""

import sys
from datetime import datetime
from pathlib import Path

try:
    import yaml
except ImportError:
    print("Error: PyYAML not installed. Run: pip install pyyaml")
    sys.exit(1)

MAPPING_PATH = "docs/schema/spec-code-mapping.yaml"
EXCEPTIONS_PATH = "docs/schema/drift-exceptions.yaml"


def load_mapping():
    """Load the mapping registry."""
    with open(MAPPING_PATH, "r") as f:
        return yaml.safe_load(f)


def load_exceptions():
    """Load drift exceptions."""
    try:
        with open(EXCEPTIONS_PATH, "r") as f:
            return yaml.safe_load(f)
    except FileNotFoundError:
        return {"exceptions": []}


def cmd_check():
    """Validate mapping registry."""
    # Check YAML validity
    try:
        mapping = load_mapping()
        print(f"✓ {MAPPING_PATH} is valid YAML")
    except yaml.YAMLError as e:
        print(f"✗ {MAPPING_PATH} has YAML errors: {e}")
        sys.exit(1)
    except FileNotFoundError:
        print(f"✗ {MAPPING_PATH} not found")
        sys.exit(1)
    
    # Check referenced files exist
    missing = []
    
    for domain_name, domain_config in mapping.get("domains", {}).items():
        for artifact in domain_config.get("artifacts", []):
            paths_to_check = []
            
            # Add spec_path or path
            if artifact.get("spec_path"):
                paths_to_check.append(artifact["spec_path"])
            if artifact.get("path"):
                paths_to_check.append(artifact["path"])
            
            # Add related schemas
            paths_to_check.extend(artifact.get("related_schemas", []))
            
            # Add related code
            paths_to_check.extend(artifact.get("related_code", []))
            
            # Add related files
            paths_to_check.extend(artifact.get("related_files", []))
            
            for path in paths_to_check:
                if path and not path.endswith("/") and not Path(path).exists():
                    missing.append(path)
    
    # Check common artifacts
    for artifact in mapping.get("common", {}).get("artifacts", []):
        path = artifact.get("path")
        if path and not Path(path).exists():
            missing.append(path)
    
    if missing:
        print("Missing files:")
        for f in sorted(set(missing)):
            print(f"  - {f}")
        sys.exit(1)
    
    print("✓ All referenced files exist")
    sys.exit(0)


def cmd_domains():
    """List available domains."""
    try:
        mapping = load_mapping()
    except FileNotFoundError:
        print(f"Error: {MAPPING_PATH} not found")
        sys.exit(1)
    
    domains = mapping.get("domains", {})
    for domain_name in sorted(domains.keys()):
        print(f"  - {domain_name}")


def cmd_exceptions():
    """Review drift exceptions."""
    exceptions = load_exceptions()
    
    for exc in exceptions.get("exceptions", []):
        exp = exc.get("expires", "never")
        
        # Check if expired
        if exp != "never":
            try:
                exp_date = datetime.fromisoformat(exp)
                if datetime.now() > exp_date:
                    status = "⚠️  EXPIRED"
                else:
                    status = "✓ active"
            except ValueError:
                status = "? invalid date"
        else:
            status = "✓ permanent"
        
        exc_id = exc.get("id", "unknown")
        drift_type = exc.get("drift_type", "unknown")
        print(f"  [{status}] {exc_id}: {drift_type} - expires {exp}")


def main():
    """Main entry point."""
    if len(sys.argv) < 2:
        cmd = "check"
    else:
        cmd = sys.argv[1]
    
    if cmd == "check":
        cmd_check()
    elif cmd == "domains":
        cmd_domains()
    elif cmd == "exceptions":
        cmd_exceptions()
    else:
        print(f"Unknown command: {cmd}")
        print("Available commands: check, domains, exceptions")
        sys.exit(1)


if __name__ == "__main__":
    main()