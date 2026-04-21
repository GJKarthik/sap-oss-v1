#!/usr/bin/env python3
"""
Spec-Drift Auditor - Automated specification drift detection.

This script implements the spec-drift auditor agent defined in .clinerules.spec-drift-auditor.
It monitors the repository for specification drift between LaTeX specs, JSON schemas, 
and implementation code.

Usage:
    # Pre-commit mode (lightweight, fast)
    python3 scripts/spec-drift/audit.py --mode pre-commit --changed-files file1.py file2.tex

    # PR mode (full audit for CI)
    python3 scripts/spec-drift/audit.py --mode pr --base-ref main --head-ref feature-branch

    # Full audit (comprehensive check)
    python3 scripts/spec-drift/audit.py --mode full

    # Specific domain audit
    python3 scripts/spec-drift/audit.py --mode full --domain simula

Author: Spec-Drift Auditor Agent
Version: 1.0.0
"""

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple

import yaml

# =============================================================================
# CONSTANTS
# =============================================================================

MAPPING_REGISTRY_PATH = "docs/schema/spec-code-mapping.yaml"
SCHEMA_REGISTRY_PATH = "docs/schema/registry.json"
DRIFT_EXCEPTIONS_PATH = "docs/schema/drift-exceptions.yaml"
AUDIT_LOG_DIR = "docs/audit-logs"

# Severity levels
class Severity(Enum):
    CRITICAL = "CRITICAL"
    HIGH = "HIGH"
    MEDIUM = "MEDIUM"
    LOW = "LOW"
    INFO = "INFO"


# Drift types
class DriftType(Enum):
    DRIFT_001 = "Schema-Spec Drift"
    DRIFT_002 = "Code-Schema Drift"
    DRIFT_003 = "Code-Spec Drift"
    DRIFT_004 = "Version Drift"
    DRIFT_005 = "Cross-Domain Drift"
    DRIFT_006 = "Threshold Drift"
    DRIFT_007 = "State Machine Drift"
    DRIFT_008 = "API Contract Drift"


# =============================================================================
# DATA CLASSES
# =============================================================================

@dataclass
class RelatedArtifact:
    """Represents an artifact related to a changed file."""
    path: str
    artifact_type: str  # spec, schema, code
    status: str  # not_updated, possibly_stale, updated
    domain: Optional[str] = None


@dataclass
class DriftFinding:
    """Represents a drift finding."""
    id: str
    drift_type: DriftType
    severity: Severity
    source_file: str
    message: str
    related_artifacts: List[RelatedArtifact] = field(default_factory=list)
    evidence: Dict[str, Any] = field(default_factory=dict)
    remediation: str = ""
    blocking: bool = False
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "type": self.drift_type.name,
            "type_description": self.drift_type.value,
            "severity": self.severity.value,
            "source_file": self.source_file,
            "message": self.message,
            "related_artifacts": [
                {"path": a.path, "type": a.artifact_type, "status": a.status, "domain": a.domain}
                for a in self.related_artifacts
            ],
            "evidence": self.evidence,
            "remediation": self.remediation,
            "blocking": self.blocking,
        }


@dataclass
class AuditReport:
    """Represents a complete audit report."""
    report_id: str
    trigger: str
    commit_sha: Optional[str]
    branch: Optional[str]
    timestamp: str
    changed_files: List[str]
    findings: List[DriftFinding] = field(default_factory=list)
    
    @property
    def critical_count(self) -> int:
        return sum(1 for f in self.findings if f.severity == Severity.CRITICAL)
    
    @property
    def high_count(self) -> int:
        return sum(1 for f in self.findings if f.severity == Severity.HIGH)
    
    @property
    def medium_count(self) -> int:
        return sum(1 for f in self.findings if f.severity == Severity.MEDIUM)
    
    @property
    def low_count(self) -> int:
        return sum(1 for f in self.findings if f.severity == Severity.LOW)
    
    @property
    def is_blocking(self) -> bool:
        return any(f.blocking for f in self.findings)
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            "report_id": self.report_id,
            "trigger": self.trigger,
            "commit_sha": self.commit_sha,
            "branch": self.branch,
            "timestamp": self.timestamp,
            "changed_files": self.changed_files,
            "findings": [f.to_dict() for f in self.findings],
            "summary": {
                "critical_count": self.critical_count,
                "high_count": self.high_count,
                "medium_count": self.medium_count,
                "low_count": self.low_count,
                "total_findings": len(self.findings),
                "blocking": self.is_blocking,
            },
        }


# =============================================================================
# REGISTRY LOADING
# =============================================================================

def load_mapping_registry(path: str = MAPPING_REGISTRY_PATH) -> Dict[str, Any]:
    """Load the spec-code mapping registry."""
    registry_path = Path(path)
    if not registry_path.exists():
        print(f"⚠️  Warning: Mapping registry not found at {path}")
        return {}
    
    with open(registry_path, "r") as f:
        return yaml.safe_load(f)


def load_schema_registry(path: str = SCHEMA_REGISTRY_PATH) -> Dict[str, Any]:
    """Load the schema registry."""
    registry_path = Path(path)
    if not registry_path.exists():
        print(f"⚠️  Warning: Schema registry not found at {path}")
        return {}
    
    with open(registry_path, "r") as f:
        return json.load(f)


def load_drift_exceptions(path: str = DRIFT_EXCEPTIONS_PATH) -> Dict[str, Any]:
    """Load drift exceptions."""
    exceptions_path = Path(path)
    if not exceptions_path.exists():
        return {"exceptions": []}
    
    with open(exceptions_path, "r") as f:
        return yaml.safe_load(f) or {"exceptions": []}


# =============================================================================
# FILE CLASSIFICATION
# =============================================================================

def classify_file(filepath: str) -> str:
    """Classify a file into artifact category."""
    if filepath.endswith(".tex"):
        if "docs/latex/specs" in filepath:
            return "specification"
    
    if filepath.endswith(".schema.json") or (filepath.endswith(".yaml") and "schema" in filepath):
        if "docs/schema" in filepath:
            return "schema"
    
    if filepath.endswith((".py", ".ts", ".tsx", ".js")):
        if filepath.startswith("src/"):
            return "code"
    
    if ".clinerules" in filepath:
        return "clinerules"
    
    return "other"


def get_domain_for_file(filepath: str, mapping_registry: Dict[str, Any]) -> Optional[str]:
    """Determine which domain a file belongs to."""
    domains = mapping_registry.get("domains", {})
    
    for domain_name, domain_config in domains.items():
        spec_root = domain_config.get("spec_root", "")
        schema_root = domain_config.get("schema_root", "")
        code_root = domain_config.get("code_root", "")
        
        if spec_root and filepath.startswith(spec_root):
            return domain_name
        if schema_root and filepath.startswith(schema_root):
            return domain_name
        if code_root and filepath.startswith(code_root):
            return domain_name
    
    # Check common artifacts
    if "docs/schema/common" in filepath:
        return "common"
    
    return None


# =============================================================================
# RELATED ARTIFACT LOOKUP
# =============================================================================

def find_related_artifacts(
    filepath: str,
    category: str,
    mapping_registry: Dict[str, Any],
) -> List[RelatedArtifact]:
    """Find artifacts related to a changed file using the mapping registry."""
    related = []
    domains = mapping_registry.get("domains", {})
    
    for domain_name, domain_config in domains.items():
        artifacts = domain_config.get("artifacts", [])
        
        for artifact in artifacts:
            # Check if the changed file matches this artifact's paths
            spec_path = artifact.get("spec_path", artifact.get("path", ""))
            related_schemas = artifact.get("related_schemas", [])
            related_code = artifact.get("related_code", [])
            related_files = artifact.get("related_files", [])
            
            # If changed file is a spec, find related schemas and code
            if category == "specification" and spec_path and filepath == spec_path:
                for schema in related_schemas:
                    related.append(RelatedArtifact(
                        path=schema,
                        artifact_type="schema",
                        status="possibly_stale",
                        domain=domain_name,
                    ))
                for code in related_code:
                    related.append(RelatedArtifact(
                        path=code,
                        artifact_type="code",
                        status="possibly_stale",
                        domain=domain_name,
                    ))
            
            # If changed file is a schema, find related specs and code
            if category == "schema" and filepath in related_schemas:
                if spec_path:
                    related.append(RelatedArtifact(
                        path=spec_path,
                        artifact_type="specification",
                        status="possibly_stale",
                        domain=domain_name,
                    ))
                for code in related_code:
                    related.append(RelatedArtifact(
                        path=code,
                        artifact_type="code",
                        status="possibly_stale",
                        domain=domain_name,
                    ))
            
            # If changed file is code, find related specs and schemas
            if category == "code":
                for code in related_code:
                    if filepath == code or filepath.startswith(code.rstrip("/")):
                        if spec_path:
                            related.append(RelatedArtifact(
                                path=spec_path,
                                artifact_type="specification",
                                status="possibly_stale",
                                domain=domain_name,
                            ))
                        for schema in related_schemas:
                            related.append(RelatedArtifact(
                                path=schema,
                                artifact_type="schema",
                                status="possibly_stale",
                                domain=domain_name,
                            ))
                        break
    
    # Check common artifacts
    common = mapping_registry.get("common", {})
    for artifact in common.get("artifacts", []):
        if filepath == artifact.get("path"):
            consumers = artifact.get("consumers", [])
            for consumer in consumers:
                related.append(RelatedArtifact(
                    path=consumer,
                    artifact_type="schema",
                    status="possibly_stale",
                    domain="multiple",
                ))
    
    return related


# =============================================================================
# DRIFT DETECTION
# =============================================================================

def check_schema_validity(schema_path: str) -> Tuple[bool, Optional[str]]:
    """Check if a JSON schema is valid."""
    try:
        import jsonschema
        
        with open(schema_path, "r") as f:
            schema = json.load(f)
        
        # Check if it's a valid JSON Schema
        jsonschema.Draft202012Validator.check_schema(schema)
        return True, None
    except json.JSONDecodeError as e:
        return False, f"Invalid JSON: {e}"
    except jsonschema.exceptions.SchemaError as e:
        return False, f"Invalid JSON Schema: {e.message}"
    except ImportError:
        # jsonschema not installed, skip validation
        return True, None
    except FileNotFoundError:
        return False, f"Schema file not found: {schema_path}"


def check_spec_latex_validity(spec_path: str) -> Tuple[bool, Optional[str]]:
    """Basic LaTeX structure check for specification files."""
    try:
        with open(spec_path, "r") as f:
            content = f.read()
        
        # Check for basic LaTeX structure
        issues = []
        
        # Check for unmatched braces (basic check)
        open_braces = content.count("{")
        close_braces = content.count("}")
        if open_braces != close_braces:
            issues.append(f"Unmatched braces: {open_braces} open, {close_braces} close")
        
        # Check for common LaTeX commands
        if "\\chapter{" in content or "\\section{" in content:
            pass  # Has structure
        elif "\\input{" not in content and "\\include{" not in content:
            issues.append("No chapter/section structure or includes found")
        
        if issues:
            return False, "; ".join(issues)
        return True, None
    except FileNotFoundError:
        return False, f"Spec file not found: {spec_path}"


def detect_version_drift(
    changed_files: List[str],
    mapping_registry: Dict[str, Any],
    schema_registry: Dict[str, Any],
) -> List[DriftFinding]:
    """Detect version inconsistencies across artifacts."""
    findings = []
    finding_seq = 1
    
    # Check if schema registry was updated
    if SCHEMA_REGISTRY_PATH in changed_files:
        # Extract version from schema registry
        registry_version = schema_registry.get("version", "unknown")
        
        # TODO: Compare with spec frontmatter versions
        # This would require parsing LaTeX files
    
    return findings


def detect_cross_domain_drift(
    changed_files: List[str],
    all_changed_files: Set[str],
    mapping_registry: Dict[str, Any],
) -> List[DriftFinding]:
    """Detect drift in shared/common artifacts that affect multiple domains."""
    findings = []
    finding_seq = 1
    
    common = mapping_registry.get("common", {})
    cross_deps = mapping_registry.get("cross_spec_dependencies", [])
    
    for artifact in common.get("artifacts", []):
        artifact_path = artifact.get("path", "")
        consumers = artifact.get("consumers", [])
        
        if artifact_path in changed_files:
            # Check if all consumers are also updated
            missing_updates = []
            for consumer in consumers:
                # Check if any file in the consumer directory is updated
                consumer_updated = any(
                    f.startswith(consumer.rstrip("/"))
                    for f in all_changed_files
                )
                if not consumer_updated:
                    missing_updates.append(consumer)
            
            if missing_updates:
                findings.append(DriftFinding(
                    id=f"DRIFT-005-{finding_seq:03d}",
                    drift_type=DriftType.DRIFT_005,
                    severity=Severity.HIGH,
                    source_file=artifact_path,
                    message=f"Shared artifact changed but consumers not updated",
                    related_artifacts=[
                        RelatedArtifact(
                            path=consumer,
                            artifact_type="schema",
                            status="not_updated",
                            domain="multiple",
                        )
                        for consumer in missing_updates
                    ],
                    evidence={
                        "shared_artifact": artifact_path,
                        "consumers_not_updated": missing_updates,
                        "sync_rules": artifact.get("sync_rules", []),
                    },
                    remediation="Update all consuming domains or add exception with RFC",
                    blocking=True,
                ))
                finding_seq += 1
    
    return findings


def detect_mapping_coverage_drift(
    changed_files: List[str],
    mapping_registry: Dict[str, Any],
) -> List[DriftFinding]:
    """Detect files that are changed but not covered by the mapping registry."""
    findings = []
    finding_seq = 1
    
    for filepath in changed_files:
        category = classify_file(filepath)
        
        if category in ("specification", "schema", "code"):
            domain = get_domain_for_file(filepath, mapping_registry)
            related = find_related_artifacts(filepath, category, mapping_registry)
            
            if domain is None and category != "other":
                # File is in a governed category but not mapped to any domain
                findings.append(DriftFinding(
                    id=f"DRIFT-003-{finding_seq:03d}",
                    drift_type=DriftType.DRIFT_003,
                    severity=Severity.MEDIUM,
                    source_file=filepath,
                    message=f"Governed file not mapped to any domain in spec-code-mapping.yaml",
                    evidence={
                        "file_category": category,
                        "suggestion": "Add file to appropriate domain in docs/schema/spec-code-mapping.yaml",
                    },
                    remediation="Add file to spec-code mapping registry",
                    blocking=False,
                ))
                finding_seq += 1
    
    return findings


# =============================================================================
# AUDIT EXECUTION
# =============================================================================

def run_precommit_audit(changed_files: List[str]) -> AuditReport:
    """Run lightweight pre-commit audit."""
    mapping_registry = load_mapping_registry()
    schema_registry = load_schema_registry()
    
    report = AuditReport(
        report_id=f"DRIFT-AUDIT-{datetime.now().strftime('%Y%m%d%H%M%S')}",
        trigger="pre-commit",
        commit_sha=get_current_commit_sha(),
        branch=get_current_branch(),
        timestamp=datetime.now().isoformat(),
        changed_files=changed_files,
    )
    
    changed_set = set(changed_files)
    
    # Classify and analyze each changed file
    for filepath in changed_files:
        category = classify_file(filepath)
        
        if category == "other":
            continue
        
        # Find related artifacts
        related = find_related_artifacts(filepath, category, mapping_registry)
        
        # Check if related artifacts are also being changed
        for artifact in related:
            if artifact.path not in changed_set:
                # Check if it's a directory pattern
                if artifact.path.endswith("/"):
                    dir_updated = any(f.startswith(artifact.path) for f in changed_set)
                    if dir_updated:
                        artifact.status = "updated"
                        continue
                
                # Related artifact not in changeset - potential drift
                report.findings.append(DriftFinding(
                    id=f"DRIFT-001-{len(report.findings)+1:03d}",
                    drift_type=DriftType.DRIFT_001 if artifact.artifact_type == "schema" else DriftType.DRIFT_003,
                    severity=Severity.MEDIUM,
                    source_file=filepath,
                    message=f"Changed {category} may require update to related {artifact.artifact_type}",
                    related_artifacts=[artifact],
                    evidence={
                        "changed_category": category,
                        "related_not_updated": artifact.path,
                    },
                    remediation=f"Review and update {artifact.path} if needed, or document why no update is required",
                    blocking=False,
                ))
    
    # Check for cross-domain drift
    report.findings.extend(
        detect_cross_domain_drift(changed_files, changed_set, mapping_registry)
    )
    
    return report


def run_pr_audit(base_ref: str, head_ref: str) -> AuditReport:
    """Run full PR audit."""
    # Get changed files between refs
    try:
        result = subprocess.run(
            ["git", "diff", "--name-only", f"{base_ref}...{head_ref}"],
            capture_output=True,
            text=True,
            check=True,
        )
        changed_files = [f.strip() for f in result.stdout.strip().split("\n") if f.strip()]
    except subprocess.CalledProcessError:
        changed_files = []
    
    mapping_registry = load_mapping_registry()
    schema_registry = load_schema_registry()
    exceptions = load_drift_exceptions()
    
    report = AuditReport(
        report_id=f"DRIFT-AUDIT-{datetime.now().strftime('%Y%m%d%H%M%S')}",
        trigger="pr",
        commit_sha=head_ref,
        branch=get_current_branch(),
        timestamp=datetime.now().isoformat(),
        changed_files=changed_files,
    )
    
    changed_set = set(changed_files)
    
    # Run all pre-commit checks
    precommit_report = run_precommit_audit(changed_files)
    report.findings.extend(precommit_report.findings)
    
    # Additional PR-specific checks
    
    # 1. Schema validation for changed schemas
    for filepath in changed_files:
        if filepath.endswith(".schema.json"):
            is_valid, error = check_schema_validity(filepath)
            if not is_valid:
                report.findings.append(DriftFinding(
                    id=f"DRIFT-002-{len(report.findings)+1:03d}",
                    drift_type=DriftType.DRIFT_002,
                    severity=Severity.CRITICAL,
                    source_file=filepath,
                    message=f"Schema validation failed: {error}",
                    evidence={"validation_error": error},
                    remediation="Fix schema validation errors before merging",
                    blocking=True,
                ))
    
    # 2. Check mapping coverage
    report.findings.extend(
        detect_mapping_coverage_drift(changed_files, mapping_registry)
    )
    
    # 3. Version drift check
    report.findings.extend(
        detect_version_drift(changed_files, mapping_registry, schema_registry)
    )
    
    # Apply exceptions
    active_exceptions = [
        e for e in exceptions.get("exceptions", [])
        if not is_exception_expired(e)
    ]
    
    for finding in report.findings:
        for exc in active_exceptions:
            if matches_exception(finding, exc):
                finding.severity = Severity.INFO
                finding.blocking = False
                finding.message += f" [Exception: {exc.get('id')}]"
    
    # Update blocking status based on severity
    for finding in report.findings:
        if finding.severity == Severity.CRITICAL:
            finding.blocking = True
        elif finding.severity == Severity.HIGH:
            # HIGH findings block by default, but can be configured
            finding.blocking = True
    
    return report


def run_full_audit(domain: Optional[str] = None) -> AuditReport:
    """Run comprehensive full audit."""
    mapping_registry = load_mapping_registry()
    schema_registry = load_schema_registry()
    
    report = AuditReport(
        report_id=f"DRIFT-AUDIT-FULL-{datetime.now().strftime('%Y%m%d%H%M%S')}",
        trigger="full",
        commit_sha=get_current_commit_sha(),
        branch=get_current_branch(),
        timestamp=datetime.now().isoformat(),
        changed_files=[],  # Full audit doesn't use changed files
    )
    
    domains_to_check = mapping_registry.get("domains", {})
    if domain:
        domains_to_check = {domain: domains_to_check.get(domain, {})}
    
    # Check each domain for structural integrity
    for domain_name, domain_config in domains_to_check.items():
        spec_root = domain_config.get("spec_root")
        schema_root = domain_config.get("schema_root")
        code_root = domain_config.get("code_root")
        
        # Verify spec root exists
        if spec_root and not Path(spec_root).exists():
            report.findings.append(DriftFinding(
                id=f"DRIFT-003-{len(report.findings)+1:03d}",
                drift_type=DriftType.DRIFT_003,
                severity=Severity.HIGH,
                source_file=spec_root,
                message=f"Spec root does not exist for domain {domain_name}",
                evidence={"domain": domain_name, "missing_path": spec_root},
                remediation="Create spec directory or update mapping registry",
                blocking=False,
            ))
        
        # Verify schema root exists
        if schema_root and not Path(schema_root).exists():
            report.findings.append(DriftFinding(
                id=f"DRIFT-002-{len(report.findings)+1:03d}",
                drift_type=DriftType.DRIFT_002,
                severity=Severity.HIGH,
                source_file=schema_root,
                message=f"Schema root does not exist for domain {domain_name}",
                evidence={"domain": domain_name, "missing_path": schema_root},
                remediation="Create schema directory or update mapping registry",
                blocking=False,
            ))
        
        # Validate all schemas in domain
        if schema_root and Path(schema_root).exists():
            for schema_file in Path(schema_root).glob("*.schema.json"):
                is_valid, error = check_schema_validity(str(schema_file))
                if not is_valid:
                    report.findings.append(DriftFinding(
                        id=f"DRIFT-002-{len(report.findings)+1:03d}",
                        drift_type=DriftType.DRIFT_002,
                        severity=Severity.CRITICAL,
                        source_file=str(schema_file),
                        message=f"Schema validation failed: {error}",
                        evidence={"validation_error": error, "domain": domain_name},
                        remediation="Fix schema validation errors",
                        blocking=True,
                    ))
        
        # Check artifacts in domain
        for artifact in domain_config.get("artifacts", []):
            spec_path = artifact.get("spec_path", artifact.get("path"))
            related_schemas = artifact.get("related_schemas", [])
            related_code = artifact.get("related_code", [])
            
            # Verify spec file exists
            if spec_path and not Path(spec_path).exists():
                report.findings.append(DriftFinding(
                    id=f"DRIFT-003-{len(report.findings)+1:03d}",
                    drift_type=DriftType.DRIFT_003,
                    severity=Severity.MEDIUM,
                    source_file=spec_path,
                    message=f"Spec file referenced in mapping does not exist",
                    evidence={"artifact_id": artifact.get("id"), "domain": domain_name},
                    remediation="Create spec file or update mapping registry",
                    blocking=False,
                ))
            
            # Verify related schemas exist
            for schema_path in related_schemas:
                if not Path(schema_path).exists():
                    report.findings.append(DriftFinding(
                        id=f"DRIFT-002-{len(report.findings)+1:03d}",
                        drift_type=DriftType.DRIFT_002,
                        severity=Severity.MEDIUM,
                        source_file=schema_path,
                        message=f"Related schema referenced in mapping does not exist",
                        evidence={"artifact_id": artifact.get("id"), "domain": domain_name},
                        remediation="Create schema file or update mapping registry",
                        blocking=False,
                    ))
    
    # Verify schema registry integrity
    for domain_name, domain_info in schema_registry.get("domains", {}).items():
        for schema_info in domain_info.get("schemas", []):
            schema_path = f"docs/schema/{schema_info.get('path', '')}"
            if not Path(schema_path).exists():
                report.findings.append(DriftFinding(
                    id=f"DRIFT-002-{len(report.findings)+1:03d}",
                    drift_type=DriftType.DRIFT_002,
                    severity=Severity.HIGH,
                    source_file=schema_path,
                    message=f"Schema in registry does not exist on disk",
                    evidence={"schema_id": schema_info.get("id"), "registry_domain": domain_name},
                    remediation="Create schema file or remove from registry",
                    blocking=False,
                ))
    
    return report


# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

def get_current_commit_sha() -> Optional[str]:
    """Get current git commit SHA."""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        )
        return result.stdout.strip()
    except subprocess.CalledProcessError:
        return None


def get_current_branch() -> Optional[str]:
    """Get current git branch name."""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        )
        return result.stdout.strip()
    except subprocess.CalledProcessError:
        return None


def is_exception_expired(exception: Dict[str, Any]) -> bool:
    """Check if a drift exception has expired."""
    expiration = exception.get("expires")
    if not expiration:
        return False
    
    try:
        exp_date = datetime.fromisoformat(expiration)
        return datetime.now() > exp_date
    except ValueError:
        return False


def matches_exception(finding: DriftFinding, exception: Dict[str, Any]) -> bool:
    """Check if a finding matches an exception."""
    exc_file = exception.get("file_pattern", "")
    exc_type = exception.get("drift_type", "")
    
    if exc_file and not re.match(exc_file, finding.source_file):
        return False
    
    if exc_type and finding.drift_type.name != exc_type:
        return False
    
    return True


# =============================================================================
# OUTPUT FORMATTING
# =============================================================================

def format_console_output(report: AuditReport) -> str:
    """Format report for console output."""
    lines = []
    lines.append("=" * 80)
    lines.append(f"SPEC-DRIFT AUDIT REPORT: {report.report_id}")
    lines.append("=" * 80)
    lines.append(f"Trigger: {report.trigger}")
    lines.append(f"Timestamp: {report.timestamp}")
    lines.append(f"Commit: {report.commit_sha or 'N/A'}")
    lines.append(f"Branch: {report.branch or 'N/A'}")
    lines.append(f"Changed Files: {len(report.changed_files)}")
    lines.append("-" * 80)
    
    if report.findings:
        lines.append(f"\nFINDINGS ({len(report.findings)} total):")
        lines.append("-" * 40)
        
        for finding in sorted(report.findings, key=lambda f: (f.severity.value, f.id)):
            severity_icon = {
                Severity.CRITICAL: "🔴",
                Severity.HIGH: "🟠",
                Severity.MEDIUM: "🟡",
                Severity.LOW: "🔵",
                Severity.INFO: "⚪",
            }.get(finding.severity, "⚪")
            
            blocking_mark = " [BLOCKING]" if finding.blocking else ""
            
            lines.append(f"\n{severity_icon} [{finding.severity.value}] {finding.id}{blocking_mark}")
            lines.append(f"   Type: {finding.drift_type.value}")
            lines.append(f"   File: {finding.source_file}")
            lines.append(f"   Message: {finding.message}")
            
            if finding.related_artifacts:
                lines.append("   Related Artifacts:")
                for artifact in finding.related_artifacts:
                    lines.append(f"     - {artifact.path} ({artifact.artifact_type}, {artifact.status})")
            
            if finding.remediation:
                lines.append(f"   Remediation: {finding.remediation}")
    else:
        lines.append("\n✅ No drift findings!")
    
    lines.append("\n" + "=" * 80)
    lines.append("SUMMARY")
    lines.append("-" * 40)
    lines.append(f"Critical: {report.critical_count}")
    lines.append(f"High: {report.high_count}")
    lines.append(f"Medium: {report.medium_count}")
    lines.append(f"Low: {report.low_count}")
    lines.append(f"Blocking: {'YES' if report.is_blocking else 'NO'}")
    lines.append("=" * 80)
    
    return "\n".join(lines)


def format_github_actions_output(report: AuditReport) -> str:
    """Format report for GitHub Actions."""
    lines = []
    
    for finding in report.findings:
        level = {
            Severity.CRITICAL: "error",
            Severity.HIGH: "error",
            Severity.MEDIUM: "warning",
            Severity.LOW: "notice",
            Severity.INFO: "notice",
        }.get(finding.severity, "notice")
        
        # GitHub Actions annotation format
        lines.append(f"::{level} file={finding.source_file}::{finding.message}")
    
    # Summary
    lines.append("")
    lines.append(f"## Spec-Drift Audit Summary")
    lines.append(f"| Severity | Count |")
    lines.append(f"|----------|-------|")
    lines.append(f"| Critical | {report.critical_count} |")
    lines.append(f"| High | {report.high_count} |")
    lines.append(f"| Medium | {report.medium_count} |")
    lines.append(f"| Low | {report.low_count} |")
    lines.append("")
    
    if report.is_blocking:
        lines.append("❌ **BLOCKING**: This PR cannot be merged until drift issues are resolved.")
    else:
        lines.append("✅ **PASS**: No blocking drift issues found.")
    
    return "\n".join(lines)


def format_json_output(report: AuditReport) -> str:
    """Format report as JSON."""
    return json.dumps(report.to_dict(), indent=2)


def format_yaml_output(report: AuditReport) -> str:
    """Format report as YAML."""
    return yaml.dump(report.to_dict(), default_flow_style=False, sort_keys=False)


# =============================================================================
# MAIN
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Spec-Drift Auditor - Detect specification drift in the repository",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Pre-commit mode
  %(prog)s --mode pre-commit --changed-files src/training/pipeline/main.py docs/schema/simula/config.schema.json

  # PR mode
  %(prog)s --mode pr --base-ref main --head-ref feature-branch

  # Full audit
  %(prog)s --mode full

  # Full audit for specific domain
  %(prog)s --mode full --domain simula

  # Output as JSON
  %(prog)s --mode full --output-format json
        """,
    )
    
    parser.add_argument(
        "--mode",
        choices=["pre-commit", "pr", "full"],
        required=True,
        help="Audit mode",
    )
    
    parser.add_argument(
        "--changed-files",
        nargs="*",
        help="List of changed files (for pre-commit mode)",
    )
    
    parser.add_argument(
        "--base-ref",
        help="Base git ref for comparison (for PR mode)",
    )
    
    parser.add_argument(
        "--head-ref",
        help="Head git ref for comparison (for PR mode)",
    )
    
    parser.add_argument(
        "--domain",
        help="Specific domain to audit (for full mode)",
    )
    
    parser.add_argument(
        "--output-format",
        choices=["console", "json", "yaml", "github-actions"],
        default="console",
        help="Output format (default: console)",
    )
    
    parser.add_argument(
        "--output-file",
        help="Write output to file instead of stdout",
    )
    
    parser.add_argument(
        "--fail-on-blocking",
        action="store_true",
        default=True,
        help="Exit with non-zero code if blocking issues found (default: true)",
    )
    
    parser.add_argument(
        "--no-fail-on-blocking",
        action="store_false",
        dest="fail_on_blocking",
        help="Don't exit with non-zero code even if blocking issues found",
    )
    
    args = parser.parse_args()
    
    # Run appropriate audit mode
    if args.mode == "pre-commit":
        if not args.changed_files:
            print("Error: --changed-files required for pre-commit mode", file=sys.stderr)
            sys.exit(1)
        report = run_precommit_audit(args.changed_files)
        
    elif args.mode == "pr":
        if not args.base_ref or not args.head_ref:
            print("Error: --base-ref and --head-ref required for PR mode", file=sys.stderr)
            sys.exit(1)
        report = run_pr_audit(args.base_ref, args.head_ref)
        
    elif args.mode == "full":
        report = run_full_audit(args.domain)
    
    # Format output
    if args.output_format == "console":
        output = format_console_output(report)
    elif args.output_format == "json":
        output = format_json_output(report)
    elif args.output_format == "yaml":
        output = format_yaml_output(report)
    elif args.output_format == "github-actions":
        output = format_github_actions_output(report)
    
    # Write output
    if args.output_file:
        with open(args.output_file, "w") as f:
            f.write(output)
        print(f"Report written to {args.output_file}")
    else:
        print(output)
    
    # Save audit log
    if args.mode in ("pr", "full"):
        save_audit_log(report)
    
    # Exit with appropriate code
    if args.fail_on_blocking and report.is_blocking:
        sys.exit(1)
    
    sys.exit(0)


def save_audit_log(report: AuditReport):
    """Save audit report to log directory."""
    log_dir = Path(AUDIT_LOG_DIR)
    log_dir.mkdir(parents=True, exist_ok=True)
    
    log_file = log_dir / f"{report.report_id}.yaml"
    with open(log_file, "w") as f:
        yaml.dump(report.to_dict(), f, default_flow_style=False, sort_keys=False)


if __name__ == "__main__":
    main()