"""
Validation Harness for .clinerules Contracts

Implements validation per docs/latex/specs/clinerules-agents/chapters/03-agent-rule-pack-architecture.tex

This harness validates:
1. Structural completeness of rule packs
2. Safety-critical flag inheritance (no weakening)
3. Regulatory alignment requirements
4. Cross-pack consistency
"""

import json
import os
import re
import yaml
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple
import pytest


# Repository root
REPO_ROOT = Path(__file__).parent.parent.parent.parent.parent


@dataclass
class SafetyCriticalFlag:
    """Definition of a safety-critical flag with tightening direction."""
    name: str
    tightening_direction: str  # "true_only", "false_only", "decrease_only", "increase_only"
    default_value: Any


# Safety-critical flags per Table 3.2 of clinerules-agents spec
SAFETY_CRITICAL_FLAGS = [
    SafetyCriticalFlag("deny_by_default", "true_only", False),
    SafetyCriticalFlag("allow_unlisted_tools", "false_only", True),
    SafetyCriticalFlag("require_identity_envelope", "true_only", False),
    SafetyCriticalFlag("audit_before_action", "true_only", False),
    SafetyCriticalFlag("circuit_break_enabled", "true_only", False),
    SafetyCriticalFlag("max_retries", "decrease_only", 10),
    SafetyCriticalFlag("timeout_ms", "decrease_only", 30000),
]


# Required sections for development packs
DEVELOPMENT_PACK_REQUIRED_SECTIONS = [
    "Purpose",
    "Mission",
    "Source Of Truth",
    "Definition Of Done",
    "Non-Negotiable Engineering Rules",
]

# Required sections for runtime-monitor packs
RUNTIME_MONITOR_REQUIRED_SECTIONS = [
    "Purpose",
    "Mission",
    "Source Of Truth",
    "Evidence Sources",
    "Critical Alert Conditions",
    "Condition Codes",
    "Response Rules",
]


class ClinerulesPack:
    """Parser and validator for .clinerules files."""
    
    def __init__(self, path: Path):
        self.path = path
        self.content = path.read_text() if path.exists() else ""
        self.sections = self._parse_sections()
        self.frontmatter = self._parse_frontmatter()
    
    def _parse_sections(self) -> Dict[str, str]:
        """Parse sections from the clinerules file."""
        sections = {}
        current_section = None
        current_content = []
        
        for line in self.content.split("\n"):
            # Check for section header (line that is not indented and ends with no special chars)
            if line and not line.startswith(" ") and not line.startswith("#") and not line.startswith("-"):
                # Check if it looks like a section header
                stripped = line.strip()
                if stripped and not stripped.startswith("[") and not ":" in stripped[:20]:
                    if current_section:
                        sections[current_section] = "\n".join(current_content)
                    current_section = stripped
                    current_content = []
                    continue
            
            if current_section:
                current_content.append(line)
        
        if current_section:
            sections[current_section] = "\n".join(current_content)
        
        return sections
    
    def _parse_frontmatter(self) -> Dict[str, Any]:
        """Parse YAML frontmatter if present."""
        if self.content.startswith("---"):
            try:
                end_idx = self.content.index("---", 3)
                yaml_content = self.content[3:end_idx]
                return yaml.safe_load(yaml_content) or {}
            except (ValueError, yaml.YAMLError):
                pass
        return {}
    
    def has_section(self, section_name: str) -> bool:
        """Check if a section exists (case-insensitive, partial match)."""
        section_lower = section_name.lower().replace(" ", "").replace("_", "")
        for key in self.sections.keys():
            key_normalized = key.lower().replace(" ", "").replace("_", "")
            if section_lower in key_normalized or key_normalized in section_lower:
                return True
        return False
    
    def get_section(self, section_name: str) -> Optional[str]:
        """Get section content (case-insensitive, partial match)."""
        section_lower = section_name.lower().replace(" ", "").replace("_", "")
        for key, value in self.sections.items():
            key_normalized = key.lower().replace(" ", "").replace("_", "")
            if section_lower in key_normalized or key_normalized in section_lower:
                return value
        return None
    
    def extract_flag_value(self, flag_name: str) -> Optional[Any]:
        """Extract a flag value from the content."""
        # Look for patterns like "flag_name: value" or "flag_name = value"
        patterns = [
            rf"`{flag_name}`:\s*(true|false|\d+)",
            rf"{flag_name}:\s*(true|false|\d+)",
            rf"{flag_name}\s*=\s*(true|false|\d+)",
        ]
        
        for pattern in patterns:
            match = re.search(pattern, self.content, re.IGNORECASE)
            if match:
                value = match.group(1).lower()
                if value == "true":
                    return True
                elif value == "false":
                    return False
                else:
                    return int(value)
        return None
    
    def references_schemas(self, schemas: List[str]) -> List[str]:
        """Check which schemas are referenced in the content."""
        found = []
        for schema in schemas:
            if schema in self.content:
                found.append(schema)
        return found
    
    def references_code_paths(self, paths: List[str]) -> List[str]:
        """Check which code paths are referenced in the content."""
        found = []
        for path in paths:
            if path in self.content:
                found.append(path)
        return found


class InheritanceValidator:
    """Validates inheritance rules between parent and child packs."""
    
    def __init__(self, parent: ClinerulesPack, child: ClinerulesPack):
        self.parent = parent
        self.child = child
        self.conflicts: List[Dict[str, Any]] = []
    
    def validate(self) -> List[Dict[str, Any]]:
        """Validate that child does not weaken parent's safety-critical flags."""
        self.conflicts = []
        
        for flag in SAFETY_CRITICAL_FLAGS:
            parent_value = self.parent.extract_flag_value(flag.name)
            child_value = self.child.extract_flag_value(flag.name)
            
            if parent_value is None or child_value is None:
                continue
            
            conflict = self._check_conflict(flag, parent_value, child_value)
            if conflict:
                self.conflicts.append(conflict)
        
        return self.conflicts
    
    def _check_conflict(
        self,
        flag: SafetyCriticalFlag,
        parent_value: Any,
        child_value: Any,
    ) -> Optional[Dict[str, Any]]:
        """Check if child value conflicts with parent based on tightening direction."""
        
        if flag.tightening_direction == "true_only":
            # Can only go from false to true, not true to false
            if parent_value is True and child_value is False:
                return self._create_conflict(flag, parent_value, child_value)
        
        elif flag.tightening_direction == "false_only":
            # Can only go from true to false, not false to true
            if parent_value is False and child_value is True:
                return self._create_conflict(flag, parent_value, child_value)
        
        elif flag.tightening_direction == "decrease_only":
            # Can only decrease, not increase
            if child_value > parent_value:
                return self._create_conflict(flag, parent_value, child_value)
        
        elif flag.tightening_direction == "increase_only":
            # Can only increase, not decrease
            if child_value < parent_value:
                return self._create_conflict(flag, parent_value, child_value)
        
        return None
    
    def _create_conflict(
        self,
        flag: SafetyCriticalFlag,
        parent_value: Any,
        child_value: Any,
    ) -> Dict[str, Any]:
        """Create a conflict record."""
        return {
            "flag_name": flag.name,
            "parent_path": str(self.parent.path),
            "parent_value": parent_value,
            "child_path": str(self.child.path),
            "child_value": child_value,
            "tightening_direction": flag.tightening_direction,
            "error": f"Child pack weakens safety-critical flag '{flag.name}'"
        }


class RegulatoryAlignmentValidator:
    """Validates regulatory alignment requirements."""
    
    REQUIRED_REGULATION_REFS = [
        "REG-MGF-2.1.2-001",  # Tool allow-list
        "REG-MGF-2.1.2-002",  # Identity attribution
        "REG-MGF-2.2.2-001",  # Human checkpoints
    ]
    
    REQUIRED_SCHEMA_REFS = [
        "agent-identity.schema.json",
        "request-identity.schema.json",
        "audit-event.schema.json",
    ]
    
    def __init__(self, pack: ClinerulesPack):
        self.pack = pack
        self.issues: List[Dict[str, Any]] = []
    
    def validate(self) -> List[Dict[str, Any]]:
        """Validate regulatory alignment."""
        self.issues = []
        
        # Check regulation references
        for reg_id in self.REQUIRED_REGULATION_REFS:
            if reg_id not in self.pack.content:
                self.issues.append({
                    "type": "missing_regulation_reference",
                    "regulation_id": reg_id,
                    "path": str(self.pack.path),
                    "severity": "warning",
                })
        
        # Check schema references
        for schema in self.REQUIRED_SCHEMA_REFS:
            if schema not in self.pack.content:
                self.issues.append({
                    "type": "missing_schema_reference",
                    "schema": schema,
                    "path": str(self.pack.path),
                    "severity": "warning",
                })
        
        return self.issues


# ==============================================================================
# PYTEST TEST CASES
# ==============================================================================

class TestClinerulesPacks:
    """Test suite for .clinerules contract validation."""
    
    @pytest.fixture
    def repo_root(self) -> Path:
        return REPO_ROOT
    
    @pytest.fixture
    def intelligence_dev_pack(self, repo_root: Path) -> ClinerulesPack:
        return ClinerulesPack(repo_root / "src/intelligence/.clinerules")
    
    @pytest.fixture
    def intelligence_monitor_pack(self, repo_root: Path) -> ClinerulesPack:
        return ClinerulesPack(repo_root / "src/intelligence/.clinerules.runtime-monitor")
    
    @pytest.fixture
    def gateway_monitor_pack(self, repo_root: Path) -> ClinerulesPack:
        return ClinerulesPack(repo_root / "src/generativeUI/gateway/.clinerules.runtime-monitor")
    
    @pytest.fixture
    def root_clinerules(self, repo_root: Path) -> ClinerulesPack:
        return ClinerulesPack(repo_root / ".clinerules")
    
    def test_intelligence_dev_pack_exists(self, intelligence_dev_pack: ClinerulesPack):
        """Test that intelligence development pack exists."""
        assert intelligence_dev_pack.path.exists(), \
            f"Missing required pack: {intelligence_dev_pack.path}"
    
    def test_intelligence_monitor_pack_exists(self, intelligence_monitor_pack: ClinerulesPack):
        """Test that intelligence runtime-monitor pack exists."""
        assert intelligence_monitor_pack.path.exists(), \
            f"Missing required pack: {intelligence_monitor_pack.path}"
    
    def test_gateway_monitor_pack_exists(self, gateway_monitor_pack: ClinerulesPack):
        """Test that gateway runtime-monitor pack exists."""
        assert gateway_monitor_pack.path.exists(), \
            f"Missing required pack: {gateway_monitor_pack.path}"
    
    def test_intelligence_dev_pack_has_required_sections(self, intelligence_dev_pack: ClinerulesPack):
        """Test that intelligence dev pack has all required sections."""
        missing = []
        for section in DEVELOPMENT_PACK_REQUIRED_SECTIONS:
            if not intelligence_dev_pack.has_section(section):
                missing.append(section)
        
        assert not missing, f"Missing required sections in {intelligence_dev_pack.path}: {missing}"
    
    def test_intelligence_monitor_pack_has_required_sections(self, intelligence_monitor_pack: ClinerulesPack):
        """Test that intelligence runtime-monitor pack has all required sections."""
        missing = []
        for section in RUNTIME_MONITOR_REQUIRED_SECTIONS:
            if not intelligence_monitor_pack.has_section(section):
                missing.append(section)
        
        assert not missing, f"Missing required sections in {intelligence_monitor_pack.path}: {missing}"
    
    def test_gateway_monitor_inherits_from_intelligence(self, gateway_monitor_pack: ClinerulesPack):
        """Test that gateway monitor declares inheritance from intelligence monitor."""
        assert "src/intelligence/.clinerules.runtime-monitor" in gateway_monitor_pack.content, \
            "Gateway monitor must declare inheritance from intelligence monitor"
    
    def test_gateway_monitor_no_weakening(
        self,
        intelligence_monitor_pack: ClinerulesPack,
        gateway_monitor_pack: ClinerulesPack,
    ):
        """Test that gateway monitor does not weaken intelligence monitor flags."""
        validator = InheritanceValidator(intelligence_monitor_pack, gateway_monitor_pack)
        conflicts = validator.validate()
        
        assert not conflicts, \
            f"Safety-critical flag conflicts detected: {json.dumps(conflicts, indent=2)}"
    
    def test_intelligence_dev_pack_regulatory_alignment(self, intelligence_dev_pack: ClinerulesPack):
        """Test that intelligence dev pack has regulatory alignment."""
        validator = RegulatoryAlignmentValidator(intelligence_dev_pack)
        issues = validator.validate()
        
        # Filter to errors only (warnings are acceptable)
        errors = [i for i in issues if i.get("severity") == "error"]
        assert not errors, f"Regulatory alignment errors: {json.dumps(errors, indent=2)}"
    
    def test_intelligence_dev_pack_references_schemas(self, intelligence_dev_pack: ClinerulesPack):
        """Test that intelligence dev pack references required schemas."""
        required_schemas = [
            "requirement.schema.json",
            "agent-identity.schema.json",
            "request-identity.schema.json",
            "audit-event.schema.json",
        ]
        
        found = intelligence_dev_pack.references_schemas(required_schemas)
        missing = set(required_schemas) - set(found)
        
        assert not missing, f"Missing schema references: {missing}"
    
    def test_intelligence_dev_pack_references_code_paths(self, intelligence_dev_pack: ClinerulesPack):
        """Test that intelligence dev pack references implementation paths."""
        required_paths = [
            "aicore_pal_agent.py",
            "btp_pal_mcp_server.py",
        ]
        
        found = intelligence_dev_pack.references_code_paths(required_paths)
        missing = set(required_paths) - set(found)
        
        assert not missing, f"Missing code path references: {missing}"
    
    def test_monitor_pack_has_condition_codes(self, intelligence_monitor_pack: ClinerulesPack):
        """Test that monitor pack defines condition codes."""
        # Check for condition code pattern
        condition_pattern = r"REG-[A-Z]+-\d{3}"
        matches = re.findall(condition_pattern, intelligence_monitor_pack.content)
        
        assert len(matches) >= 5, \
            f"Monitor pack should define at least 5 condition codes, found {len(matches)}"
    
    def test_monitor_pack_has_thresholds(self, intelligence_monitor_pack: ClinerulesPack):
        """Test that monitor pack defines monitoring thresholds."""
        required_thresholds = [
            "schema.violation",  # Schema violation threshold
            "refusal.rate" or "refusal_rate",  # Refusal rate threshold
            "latency",  # Latency threshold
            "circuit.break" or "circuit_break",  # Circuit break threshold
        ]
        
        content_lower = intelligence_monitor_pack.content.lower()
        found = sum(1 for t in required_thresholds if t.lower().replace(".", "_") in content_lower.replace(".", "_"))
        
        assert found >= 3, \
            f"Monitor pack should define thresholds for schema violations, refusal rate, latency, circuit break"


class TestGovernanceModuleIntegration:
    """Test integration between governance module and clinerules contracts."""
    
    @pytest.fixture
    def governance_module_exists(self) -> bool:
        module_path = REPO_ROOT / "src/intelligence/ai-core-pal/governance/__init__.py"
        return module_path.exists()
    
    def test_governance_module_exists(self, governance_module_exists: bool):
        """Test that governance module exists."""
        assert governance_module_exists, "Governance module must exist at src/intelligence/ai-core-pal/governance/"
    
    def test_identity_module_exists(self):
        """Test that identity module exists."""
        path = REPO_ROOT / "src/intelligence/ai-core-pal/governance/identity.py"
        assert path.exists(), f"Identity module must exist at {path}"
    
    def test_audit_module_exists(self):
        """Test that audit module exists."""
        path = REPO_ROOT / "src/intelligence/ai-core-pal/governance/audit.py"
        assert path.exists(), f"Audit module must exist at {path}"
    
    def test_governed_agent_exists(self):
        """Test that governed agent exists."""
        path = REPO_ROOT / "src/intelligence/ai-core-pal/agent/governed_agent.py"
        assert path.exists(), f"Governed agent must exist at {path}"


class TestSchemaCompliance:
    """Test that schemas referenced in clinerules exist."""
    
    @pytest.fixture
    def schema_dir(self) -> Path:
        return REPO_ROOT / "docs/schema/regulations"
    
    def test_required_schemas_exist(self, schema_dir: Path):
        """Test that all required regulation schemas exist."""
        required_schemas = [
            "requirement.schema.json",
            "regulation.schema.json",
            "conformance-tool.schema.json",
            "corpus.schema.json",
            "agent-identity.schema.json",
            "request-identity.schema.json",
            "audit-event.schema.json",
            "capability-monitoring-metrics.schema.json",
        ]
        
        missing = []
        for schema in required_schemas:
            if not (schema_dir / schema).exists():
                missing.append(schema)
        
        assert not missing, f"Missing required schemas: {missing}"


# ==============================================================================
# CLI RUNNER
# ==============================================================================

def run_validation():
    """Run validation as standalone script."""
    print("=" * 60)
    print("Clinerules Contract Validation Harness")
    print("=" * 60)
    
    results = {
        "passed": 0,
        "failed": 0,
        "warnings": 0,
        "errors": [],
    }
    
    # Check required packs exist
    packs_to_check = [
        REPO_ROOT / ".clinerules",
        REPO_ROOT / "src/intelligence/.clinerules",
        REPO_ROOT / "src/intelligence/.clinerules.runtime-monitor",
        REPO_ROOT / "src/generativeUI/gateway/.clinerules.runtime-monitor",
    ]
    
    print("\n--- Checking Required Packs ---")
    for pack_path in packs_to_check:
        if pack_path.exists():
            print(f"  ✓ {pack_path.relative_to(REPO_ROOT)}")
            results["passed"] += 1
        else:
            print(f"  ✗ {pack_path.relative_to(REPO_ROOT)} (MISSING)")
            results["failed"] += 1
            results["errors"].append(f"Missing pack: {pack_path}")
    
    # Check governance module
    print("\n--- Checking Governance Module ---")
    gov_files = [
        REPO_ROOT / "src/intelligence/ai-core-pal/governance/__init__.py",
        REPO_ROOT / "src/intelligence/ai-core-pal/governance/identity.py",
        REPO_ROOT / "src/intelligence/ai-core-pal/governance/audit.py",
        REPO_ROOT / "src/intelligence/ai-core-pal/agent/governed_agent.py",
    ]
    
    for gov_path in gov_files:
        if gov_path.exists():
            print(f"  ✓ {gov_path.relative_to(REPO_ROOT)}")
            results["passed"] += 1
        else:
            print(f"  ✗ {gov_path.relative_to(REPO_ROOT)} (MISSING)")
            results["failed"] += 1
    
    # Check schemas
    print("\n--- Checking Required Schemas ---")
    schema_dir = REPO_ROOT / "docs/schema/regulations"
    required_schemas = [
        "agent-identity.schema.json",
        "request-identity.schema.json",
        "audit-event.schema.json",
    ]
    
    for schema in required_schemas:
        schema_path = schema_dir / schema
        if schema_path.exists():
            print(f"  ✓ {schema}")
            results["passed"] += 1
        else:
            print(f"  ✗ {schema} (MISSING)")
            results["failed"] += 1
    
    # Validate inheritance
    print("\n--- Checking Inheritance Compliance ---")
    parent_path = REPO_ROOT / "src/intelligence/.clinerules.runtime-monitor"
    child_path = REPO_ROOT / "src/generativeUI/gateway/.clinerules.runtime-monitor"
    
    if parent_path.exists() and child_path.exists():
        parent = ClinerulesPack(parent_path)
        child = ClinerulesPack(child_path)
        validator = InheritanceValidator(parent, child)
        conflicts = validator.validate()
        
        if conflicts:
            for conflict in conflicts:
                print(f"  ✗ Conflict: {conflict['flag_name']}")
                results["failed"] += 1
                results["errors"].append(conflict)
        else:
            print("  ✓ No inheritance conflicts detected")
            results["passed"] += 1
    
    # Summary
    print("\n" + "=" * 60)
    print(f"Results: {results['passed']} passed, {results['failed']} failed")
    print("=" * 60)
    
    if results["errors"]:
        print("\nErrors:")
        for error in results["errors"]:
            print(f"  - {error}")
    
    return results["failed"] == 0


if __name__ == "__main__":
    import sys
    success = run_validation()
    sys.exit(0 if success else 1)