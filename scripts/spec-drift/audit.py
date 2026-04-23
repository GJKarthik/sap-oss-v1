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
Version: 4.0.0  # Long-term: LLM integration, feedback loop, DRIFT-008, differential analysis
"""

import argparse
import ast
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import urllib.request
import urllib.error
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from difflib import SequenceMatcher, unified_diff
from enum import Enum
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Set, Tuple

import yaml

# =============================================================================
# CONSTANTS
# =============================================================================

MAPPING_REGISTRY_PATH = "docs/schema/spec-code-mapping.yaml"
SCHEMA_REGISTRY_PATH = "docs/schema/registry.json"
DRIFT_EXCEPTIONS_PATH = "docs/schema/drift-exceptions.yaml"
AUDIT_LOG_DIR = "docs/audit-logs"
FEEDBACK_DB_PATH = "docs/audit-logs/feedback.db"
OPENAPI_SPECS_DIR = "docs/api"

# Confidence thresholds for findings
CONFIDENCE_HIGH = 0.85
CONFIDENCE_MEDIUM = 0.65
CONFIDENCE_LOW = 0.45

# False positive reduction settings
MIN_FIELD_MISMATCHES_TO_REPORT = 5  # Require at least 5 mismatches before reporting (raised from 3)
MIN_SCHEMA_ONLY_FIELDS_TO_REPORT = 7  # Require at least 7 undocumented fields (raised from 5)

# Allowlist of patterns that are commonly false positives
FALSE_POSITIVE_METHOD_PREFIXES = {
    'get_', 'set_', 'is_', 'has_', 'can_', 'should_', 'will_',
    'fetch_', 'load_', 'save_', 'create_', 'update_', 'delete_',
    'validate_', 'check_', 'parse_', 'format_', 'compute_', 'calculate_',
    'build_', 'make_', 'init_', 'reset_', 'clear_', 'add_', 'remove_',
    'find_', 'search_', 'filter_', 'sort_', 'transform_', 'convert_',
    'handle_', 'process_', 'on_', 'do_', 'run_', 'execute_',
}

# Field names that are too generic to be meaningful
GENERIC_FIELD_ALLOWLIST = {
    'id', 'name', 'type', 'value', 'status', 'state', 'data', 'result',
    'error', 'message', 'code', 'key', 'text', 'label', 'title',
    'description', 'content', 'body', 'payload', 'response', 'request',
    'input', 'output', 'source', 'target', 'path', 'url', 'uri',
    'timestamp', 'date', 'time', 'created', 'updated', 'deleted',
    'count', 'total', 'size', 'length', 'index', 'offset', 'limit',
    'enabled', 'disabled', 'active', 'visible', 'hidden', 'readonly',
    'config', 'options', 'settings', 'params', 'args', 'kwargs',
    'context', 'metadata', 'attributes', 'properties', 'fields',
    'items', 'list', 'array', 'map', 'dict', 'set', 'queue', 'stack',
    'parent', 'child', 'children', 'root', 'node', 'leaf',
    'start', 'end', 'begin', 'finish', 'first', 'last', 'next', 'prev',
    'min', 'max', 'avg', 'sum', 'mean', 'median', 'mode',
    'success', 'failure', 'pending', 'complete', 'done', 'ready',
}

# Method-to-field patterns that are commonly equivalent (method -> field)
METHOD_FIELD_EQUIVALENTS = {
    # Method prefix patterns that map to field patterns
    r'^get_(.+)$': r'\1',           # get_user -> user
    r'^is_(.+)$': r'\1',            # is_valid -> valid  
    r'^has_(.+)$': r'\1',           # has_children -> children
    r'^fetch_(.+)$': r'\1',         # fetch_data -> data
    r'^load_(.+)$': r'\1',          # load_config -> config
    r'^compute_(.+)$': r'\1',       # compute_score -> score
    r'^calculate_(.+)$': r'\1',     # calculate_total -> total
}

# =============================================================================
# MEDIUM-TERM: SEMANTIC FIELD CLASSIFICATION
# =============================================================================
# Patterns to identify computed properties vs data fields vs methods

class FieldCategory(Enum):
    """Semantic category for fields to improve drift detection accuracy."""
    DATA_FIELD = "data_field"          # Actual data stored in schema
    COMPUTED_PROPERTY = "computed"      # Derived/calculated values
    COLLECTION_ACCESSOR = "collection"  # List/dict access patterns
    TIMESTAMP_FIELD = "timestamp"       # Date/time fields
    IDENTIFIER_FIELD = "identifier"     # ID/key fields
    METADATA_FIELD = "metadata"         # Meta information
    INTERNAL_FIELD = "internal"         # Implementation details (not schema-relevant)

# Patterns for computed/derived properties (not in schema)
COMPUTED_PROPERTY_PATTERNS = {
    # Suffix patterns indicating computed values
    r'_count$', r'_total$', r'_sum$', r'_avg$', r'_mean$',
    r'_min$', r'_max$', r'_len$', r'_length$', r'_size$',
    r'_percent$', r'_pct$', r'_ratio$', r'_rate$',
    r'_formatted$', r'_display$', r'_string$', r'_repr$',
    r'_hash$', r'_digest$', r'_checksum$',
    # Prefix patterns
    r'^num_', r'^total_', r'^count_', r'^has_',
    r'^is_valid', r'^is_empty', r'^is_loaded',
    r'^can_', r'^should_', r'^needs_',
}

# Patterns for collection accessors (items, keys, values patterns)
COLLECTION_ACCESSOR_PATTERNS = {
    r'_items$', r'_keys$', r'_values$', r'_entries$',
    r'_list$', r'_set$', r'_dict$', r'_map$',
    r'^all_', r'^first_', r'^last_', r'^next_', r'^prev_',
    r'^filtered_', r'^sorted_', r'^unique_',
}

# Patterns for timestamp fields
TIMESTAMP_PATTERNS = {
    r'_at$', r'_date$', r'_time$', r'_timestamp$',
    r'^created', r'^updated', r'^modified', r'^deleted',
    r'^started', r'^ended', r'^completed', r'^expired',
}

# Patterns for identifier fields
IDENTIFIER_PATTERNS = {
    r'_id$', r'_uuid$', r'_guid$', r'_key$', r'_ref$',
    r'^id_', r'^pk_', r'^fk_', r'^ref_',
}

# Patterns for internal implementation fields (not schema-relevant)
INTERNAL_FIELD_PATTERNS = {
    r'^_',          # Private fields
    r'^__',         # Dunder fields
    r'_cache$', r'_cached$', r'_buffer$',
    r'_lock$', r'_mutex$', r'_semaphore$',
    r'_handler$', r'_callback$', r'_listener$',
    r'_logger$', r'_log$',
    r'_tmp$', r'_temp$', r'_scratch$',
}


def classify_field_semantically(field_name: str) -> FieldCategory:
    """Classify a field into semantic categories for smarter drift detection."""
    name = field_name.lower()
    
    # Check internal/private first
    for pattern in INTERNAL_FIELD_PATTERNS:
        if re.match(pattern, name):
            return FieldCategory.INTERNAL_FIELD
    
    # Check computed properties
    for pattern in COMPUTED_PROPERTY_PATTERNS:
        if re.search(pattern, name):
            return FieldCategory.COMPUTED_PROPERTY
    
    # Check collection accessors
    for pattern in COLLECTION_ACCESSOR_PATTERNS:
        if re.search(pattern, name):
            return FieldCategory.COLLECTION_ACCESSOR
    
    # Check timestamps
    for pattern in TIMESTAMP_PATTERNS:
        if re.search(pattern, name):
            return FieldCategory.TIMESTAMP_FIELD
    
    # Check identifiers
    for pattern in IDENTIFIER_PATTERNS:
        if re.search(pattern, name):
            return FieldCategory.IDENTIFIER_FIELD
    
    # Default to data field
    return FieldCategory.DATA_FIELD


def should_skip_field_for_schema_comparison(field_name: str) -> bool:
    """Determine if a field should be skipped during schema comparison.
    
    Returns True for:
    - Internal/private fields
    - Computed properties (derived values not stored in schema)
    - Collection accessors (dynamic access patterns)
    """
    category = classify_field_semantically(field_name)
    return category in {
        FieldCategory.INTERNAL_FIELD,
        FieldCategory.COMPUTED_PROPERTY,
        FieldCategory.COLLECTION_ACCESSOR,
    }


def get_schema_relevance_score(field_name: str) -> float:
    """Get a relevance score for how likely a field should be in a schema.
    
    Higher scores indicate fields more likely to be schema-relevant.
    """
    category = classify_field_semantically(field_name)
    
    relevance_scores = {
        FieldCategory.DATA_FIELD: 1.0,
        FieldCategory.IDENTIFIER_FIELD: 0.95,
        FieldCategory.TIMESTAMP_FIELD: 0.9,
        FieldCategory.METADATA_FIELD: 0.7,
        FieldCategory.COMPUTED_PROPERTY: 0.3,
        FieldCategory.COLLECTION_ACCESSOR: 0.2,
        FieldCategory.INTERNAL_FIELD: 0.1,
    }
    return relevance_scores.get(category, 0.5)

# LLM Configuration (for optional LLM-assisted analysis)
LLM_ENDPOINT = os.environ.get("VLLM_ENDPOINT", "http://localhost:8000/v1/chat/completions")
LLM_MODEL = os.environ.get("LLM_MODEL", "meta-llama/Llama-3.1-8B-Instruct")
LLM_ENABLED = False  # Set via CLI flag
LLM_TIMEOUT = 30  # seconds

# Severity levels
class Severity(Enum):
    CRITICAL = "CRITICAL"
    HIGH = "HIGH"
    MEDIUM = "MEDIUM"
    LOW = "LOW"
    INFO = "INFO"
    ACKNOWLEDGED = "ACKNOWLEDGED"  # MEDIUM-TERM: User acknowledged but not yet fixed


# Finding status for acknowledged state tracking
class FindingStatus(Enum):
    NEW = "new"
    ACKNOWLEDGED = "acknowledged"  # User knows about it, not blocking
    SUPPRESSED = "suppressed"      # Intentionally ignored with rationale
    FIXED = "fixed"                # Resolved


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
class SchemaField:
    """Represents a field extracted from a JSON schema."""
    name: str
    field_type: str
    required: bool
    description: Optional[str] = None
    path: str = ""  # JSON path to the field


@dataclass
class ThresholdValue:
    """Represents a threshold value extracted from code or spec."""
    name: str
    value: Any
    source_file: str
    line_number: int
    context: str = ""
    normalized_name: str = ""  # For semantic matching


@dataclass
class StateTransition:
    """Represents a state machine transition."""
    from_state: str
    to_state: str
    trigger: Optional[str] = None
    line_number: int = 0


@dataclass
class CodeFieldAccess:
    """Represents a field access pattern found in code via AST analysis."""
    field_name: str
    access_type: str  # dict_access, attr_access, string_literal
    line_number: int
    context: str = ""
    parent_object: Optional[str] = None


@dataclass
class VersionInfo:
    """Represents version information extracted from a file."""
    version: str
    source_file: str
    line_number: int
    version_type: str  # semver, date, numeric


@dataclass
class DriftFinding:
    """Represents a drift finding with confidence score."""
    id: str
    drift_type: DriftType
    severity: Severity
    source_file: str
    message: str
    confidence: float = 1.0  # Confidence score 0.0-1.0
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
            "confidence": round(self.confidence, 2),
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
    def high_confidence_count(self) -> int:
        return sum(1 for f in self.findings if f.confidence >= CONFIDENCE_HIGH)
    
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
                "high_confidence_count": self.high_confidence_count,
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
# FALSE POSITIVE REDUCTION
# =============================================================================

def is_likely_method_name(field_name: str) -> bool:
    """Check if a field name looks like a method rather than a data field."""
    # Check for method prefixes
    for prefix in FALSE_POSITIVE_METHOD_PREFIXES:
        if field_name.startswith(prefix):
            return True
    
    # Check for common method patterns
    if field_name.endswith(('_handler', '_callback', '_listener', '_worker')):
        return True
    
    return False


def is_method_for_field(method_name: str, field_name: str) -> bool:
    """Check if a method name is semantically equivalent to a field name.
    
    For example:
    - get_user_segment -> user_segment
    - is_primary_key -> primary_key
    - has_children -> children
    """
    for pattern, replacement in METHOD_FIELD_EQUIVALENTS.items():
        match = re.match(pattern, method_name)
        if match:
            derived_field = re.sub(pattern, replacement, method_name)
            # Exact match
            if derived_field == field_name:
                return True
            # Fuzzy match
            if calculate_similarity(derived_field, field_name) > 0.85:
                return True
    return False


def is_generic_field(field_name: str) -> bool:
    """Check if a field name is too generic to be meaningful for drift detection."""
    return field_name.lower() in GENERIC_FIELD_ALLOWLIST


def filter_false_positive_fields(
    code_fields: Set[str], 
    schema_fields: Set[str],
    strict: bool = False
) -> Tuple[Set[str], Set[str], Dict[str, str]]:
    """Filter out likely false positive field mismatches.
    
    Returns:
        - filtered_code_fields: Code fields that are likely real (not methods)
        - filtered_schema_fields: Schema fields worth checking
        - method_to_field_map: Mapping of method names to their equivalent field names
    """
    filtered_code = set()
    method_to_field = {}
    
    for code_field in code_fields:
        # Skip if it looks like a method name
        if is_likely_method_name(code_field):
            # But check if there's a corresponding schema field
            for schema_field in schema_fields:
                if is_method_for_field(code_field, schema_field):
                    method_to_field[code_field] = schema_field
                    break
            continue
        
        # Skip generic fields unless strict mode
        if not strict and is_generic_field(code_field):
            continue
            
        filtered_code.add(code_field)
    
    # Filter schema fields - remove generic ones
    if strict:
        filtered_schema = schema_fields
    else:
        filtered_schema = {f for f in schema_fields if not is_generic_field(f)}
    
    return filtered_code, filtered_schema, method_to_field


def calculate_finding_confidence(
    mismatch_count: int,
    total_fields: int,
    has_fuzzy_matches: bool,
    method_field_matches: int
) -> float:
    """Calculate confidence score for a drift finding based on evidence quality."""
    base_confidence = 0.5
    
    # More mismatches = higher confidence this is real
    if mismatch_count > 5:
        base_confidence += 0.2
    elif mismatch_count > 3:
        base_confidence += 0.1
    
    # Ratio of mismatches to total fields
    if total_fields > 0:
        ratio = mismatch_count / total_fields
        if ratio > 0.5:
            base_confidence += 0.15
        elif ratio > 0.2:
            base_confidence += 0.1
    
    # Fuzzy matches suggest real drift (renamed fields)
    if has_fuzzy_matches:
        base_confidence += 0.1
    
    # Method-to-field matches reduce confidence (false positives filtered)
    if method_field_matches > 0:
        base_confidence -= 0.05 * min(method_field_matches, 3)
    
    return min(0.95, max(0.45, base_confidence))


# =============================================================================
# SEMANTIC SIMILARITY
# =============================================================================

def normalize_identifier(name: str) -> str:
    """Normalize an identifier for comparison."""
    # Convert to lowercase
    name = name.lower()
    # Replace separators with underscores
    name = re.sub(r'[-\s]+', '_', name)
    # Remove common prefixes/suffixes
    name = re.sub(r'^(get_|set_|is_|has_|the_)', '', name)
    name = re.sub(r'(_threshold|_limit|_value|_rate|_count)$', '', name)
    # Remove trailing underscores
    name = name.strip('_')
    return name


def calculate_similarity(str1: str, str2: str) -> float:
    """Calculate similarity between two strings using SequenceMatcher."""
    return SequenceMatcher(None, str1.lower(), str2.lower()).ratio()


def find_best_match(name: str, candidates: Set[str], threshold: float = 0.85) -> Optional[Tuple[str, float]]:
    """Find the best matching name from candidates above threshold (raised from 0.7)."""
    normalized = normalize_identifier(name)
    best_match = None
    best_score = threshold
    
    for candidate in candidates:
        candidate_normalized = normalize_identifier(candidate)
        
        # Exact normalized match
        if normalized == candidate_normalized:
            return (candidate, 1.0)
        
        # Similarity match
        score = calculate_similarity(normalized, candidate_normalized)
        if score > best_score:
            best_score = score
            best_match = candidate
    
    if best_match:
        return (best_match, best_score)
    return None


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
# AST-BASED CODE ANALYSIS (NEW)
# =============================================================================

class FieldAccessVisitor(ast.NodeVisitor):
    """AST visitor to extract field access patterns from Python code."""
    
    def __init__(self):
        self.field_accesses: List[CodeFieldAccess] = []
        self.class_fields: Dict[str, List[str]] = {}  # class_name -> field_names
        self.dict_keys: Set[str] = set()
        self.string_literals: Set[str] = set()
        
    def visit_Subscript(self, node: ast.Subscript):
        """Capture dictionary access like data['field_name'] or data["field_name"]."""
        if isinstance(node.slice, ast.Constant) and isinstance(node.slice.value, str):
            field_name = node.slice.value
            # Get parent object name if available
            parent = None
            if isinstance(node.value, ast.Name):
                parent = node.value.id
            
            self.field_accesses.append(CodeFieldAccess(
                field_name=field_name,
                access_type="dict_access",
                line_number=node.lineno,
                parent_object=parent,
            ))
            self.dict_keys.add(field_name)
        self.generic_visit(node)
    
    def visit_Attribute(self, node: ast.Attribute):
        """Capture attribute access like obj.field_name."""
        parent = None
        if isinstance(node.value, ast.Name):
            parent = node.value.id
        
        self.field_accesses.append(CodeFieldAccess(
            field_name=node.attr,
            access_type="attr_access",
            line_number=node.lineno,
            parent_object=parent,
        ))
        self.generic_visit(node)
    
    def visit_ClassDef(self, node: ast.ClassDef):
        """Extract class field definitions."""
        fields = []
        for item in node.body:
            # Annotated assignments (dataclass fields, type hints)
            if isinstance(item, ast.AnnAssign) and isinstance(item.target, ast.Name):
                fields.append(item.target.id)
            # Regular assignments
            elif isinstance(item, ast.Assign):
                for target in item.targets:
                    if isinstance(target, ast.Name):
                        fields.append(target.id)
        
        self.class_fields[node.name] = fields
        self.generic_visit(node)
    
    def visit_Constant(self, node: ast.Constant):
        """Capture string literals that look like field names."""
        if isinstance(node.value, str):
            value = node.value
            # Only capture snake_case or camelCase identifiers
            if re.match(r'^[a-z][a-z0-9_]*$', value) or re.match(r'^[a-z][a-zA-Z0-9]*$', value):
                self.string_literals.add(value)
        self.generic_visit(node)
    
    def visit_Call(self, node: ast.Call):
        """Capture function calls that might define fields (e.g., TypedDict, dataclass)."""
        # Look for get() calls on dicts: data.get('field_name')
        if isinstance(node.func, ast.Attribute) and node.func.attr == 'get':
            if node.args and isinstance(node.args[0], ast.Constant):
                if isinstance(node.args[0].value, str):
                    self.dict_keys.add(node.args[0].value)
        self.generic_visit(node)


def extract_code_field_accesses(code_path: str) -> Tuple[List[CodeFieldAccess], Set[str], Dict[str, List[str]]]:
    """Extract field access patterns from Python code using AST analysis."""
    try:
        with open(code_path, "r") as f:
            content = f.read()
        
        tree = ast.parse(content)
        visitor = FieldAccessVisitor()
        visitor.visit(tree)
        
        return visitor.field_accesses, visitor.dict_keys, visitor.class_fields
    except (SyntaxError, FileNotFoundError):
        return [], set(), {}


def extract_code_constants(code_path: str) -> Dict[str, Tuple[Any, int]]:
    """Extract constant definitions from Python code."""
    constants = {}
    
    try:
        with open(code_path, "r") as f:
            content = f.read()
        
        tree = ast.parse(content)
        
        for node in ast.walk(tree):
            # Module-level assignments
            if isinstance(node, ast.Assign):
                for target in node.targets:
                    if isinstance(target, ast.Name):
                        name = target.id
                        # Check if it's a constant (UPPER_CASE)
                        if name.isupper() or '_' in name:
                            # Extract value
                            if isinstance(node.value, ast.Constant):
                                constants[name] = (node.value.value, node.lineno)
                            elif isinstance(node.value, ast.UnaryOp) and isinstance(node.value.operand, ast.Constant):
                                # Handle negative numbers
                                if isinstance(node.value.op, ast.USub):
                                    constants[name] = (-node.value.operand.value, node.lineno)
    except (SyntaxError, FileNotFoundError):
        pass
    
    return constants


# =============================================================================
# SCHEMA FIELD EXTRACTION
# =============================================================================

def extract_schema_fields(schema_path: str) -> List[SchemaField]:
    """Extract all field definitions from a JSON schema."""
    fields = []
    
    try:
        with open(schema_path, "r") as f:
            schema = json.load(f)
    except (json.JSONDecodeError, FileNotFoundError):
        return fields
    
    required_fields = set(schema.get("required", []))
    
    def extract_from_properties(properties: Dict, path_prefix: str = "", parent_required: Set[str] = None):
        """Recursively extract fields from properties."""
        if parent_required is None:
            parent_required = required_fields
            
        for name, prop in properties.items():
            field_path = f"{path_prefix}.{name}" if path_prefix else name
            field_type = prop.get("type", "unknown")
            
            # Handle array types
            if field_type == "array" and "items" in prop:
                items = prop["items"]
                if isinstance(items, dict) and "type" in items:
                    field_type = f"array<{items.get('type', 'unknown')}>"
            
            # Handle oneOf/anyOf
            if "oneOf" in prop or "anyOf" in prop:
                types = []
                for option in prop.get("oneOf", prop.get("anyOf", [])):
                    if "type" in option:
                        types.append(option["type"])
                if types:
                    field_type = " | ".join(types)
            
            fields.append(SchemaField(
                name=name,
                field_type=field_type,
                required=name in parent_required,
                description=prop.get("description"),
                path=field_path,
            ))
            
            # Recurse into nested objects
            if prop.get("type") == "object" and "properties" in prop:
                nested_required = set(prop.get("required", []))
                extract_from_properties(prop["properties"], field_path, nested_required)
            
            # Recurse into array items if they're objects
            if prop.get("type") == "array" and "items" in prop:
                items = prop["items"]
                if isinstance(items, dict) and items.get("type") == "object" and "properties" in items:
                    nested_required = set(items.get("required", []))
                    extract_from_properties(items["properties"], f"{field_path}[]", nested_required)
    
    # Extract from top-level properties
    if "properties" in schema:
        extract_from_properties(schema["properties"])
    
    # Handle definitions/defs
    for defs_key in ["definitions", "$defs"]:
        if defs_key in schema:
            for def_name, definition in schema[defs_key].items():
                if "properties" in definition:
                    def_required = set(definition.get("required", []))
                    extract_from_properties(definition["properties"], f"#{defs_key}/{def_name}", def_required)
    
    return fields


# =============================================================================
# LONG-TERM: TYPE-AWARE FIELD COMPARISON
# =============================================================================

def get_schema_fields_with_types(schema_path: str) -> Dict[str, str]:
    """Get field names mapped to their types for type-aware comparison."""
    fields = extract_schema_fields(schema_path)
    return {f.name: f.field_type for f in fields}


def is_type_compatible(code_field: str, schema_field: str, schema_types: Dict[str, str]) -> bool:
    """Check if two fields are type-compatible based on naming conventions.
    
    LONG-TERM: Eliminates false positives where:
    - `table_count` (integer) vs `tables` (array) are clearly different
    - `user_ids` (array) vs `user_id` (string) are related but different
    """
    schema_type = schema_types.get(schema_field, "unknown")
    
    # Pattern 1: field_count vs fields (integer vs array)
    # If one ends with _count/_total/_size and schema field is array, they're different concepts
    count_suffixes = ('_count', '_total', '_size', '_length', '_num')
    if any(code_field.endswith(s) for s in count_suffixes):
        # Code field is a count - only compatible with integer/number types
        if schema_type.startswith('array'):
            return False  # count vs array = incompatible
        base_name = code_field
        for suffix in count_suffixes:
            if code_field.endswith(suffix):
                base_name = code_field[:-len(suffix)]
                break
        # If schema field matches the base name and is an array, this is count vs collection
        if schema_field == base_name or schema_field == base_name + 's':
            return False
    
    # Pattern 2: field_ids (array) vs field_id (string)
    # Plural array vs singular ID
    if code_field.endswith('_ids') and schema_field.endswith('_id'):
        if schema_type == 'string' or not schema_type.startswith('array'):
            return False
    if schema_field.endswith('_ids') and code_field.endswith('_id'):
        if schema_type.startswith('array'):
            return False
    
    # Pattern 3: field_list/field_array vs field
    list_suffixes = ('_list', '_array', '_set', '_collection')
    for suffix in list_suffixes:
        if code_field.endswith(suffix) and not schema_field.endswith(suffix):
            base = code_field[:-len(suffix)]
            if schema_field == base or schema_field == base + 's':
                # code: items_list, schema: items (array) - compatible
                # code: item_list, schema: item (string) - incompatible
                if not schema_type.startswith('array'):
                    return False
    
    # Pattern 4: is_* or has_* boolean vs field
    if code_field.startswith(('is_', 'has_', 'can_', 'should_')):
        # These are boolean indicators
        if schema_type not in ('boolean', 'bool', 'unknown'):
            # Not a boolean in schema
            prefix_len = code_field.index('_') + 1
            base = code_field[prefix_len:]
            if schema_field == base:
                return False  # is_active (bool) vs active (string) = different
    
    return True  # Default to compatible if no incompatibility detected


def filter_type_incompatible_matches(
    fuzzy_matches: List[Tuple[str, str, float]],
    schema_types: Dict[str, str]
) -> List[Tuple[str, str, float]]:
    """Filter out fuzzy matches that are type-incompatible.
    
    LONG-TERM: Reduces false positives by understanding that
    `table_count` and `tables` are semantically different despite similar names.
    """
    filtered = []
    for code_field, schema_field, similarity in fuzzy_matches:
        if is_type_compatible(code_field, schema_field, schema_types):
            filtered.append((code_field, schema_field, similarity))
    return filtered


def get_schema_field_names(schema_path: str) -> Set[str]:
    """Get just the field names from a schema for quick comparison."""
    fields = extract_schema_fields(schema_path)
    return {f.name for f in fields}


# =============================================================================
# THRESHOLD EXTRACTION WITH SEMANTIC MATCHING (IMPROVED)
# =============================================================================

# Patterns for extracting thresholds from Python code
THRESHOLD_PATTERNS = [
    # Direct assignment: THRESHOLD = 0.95
    (r'(?P<name>[A-Z][A-Z0-9_]*(?:_THRESHOLD|_LIMIT|_MAX|_MIN|_RATE|_RATIO|_PERCENT|_PCT))\s*[=:]\s*(?P<value>[\d.]+)', 0.95),
    # Config dict: "threshold": 0.95
    (r'["\'](?P<name>\w*(?:threshold|limit|max|min|rate|ratio|percent|pct)\w*)["\']:\s*(?P<value>[\d.]+)', 0.85),
    # Variable: threshold = 0.95
    (r'(?P<name>\w*(?:threshold|limit|max_|min_|_rate|_ratio)\w*)\s*=\s*(?P<value>[\d.]+)', 0.75),
    # Comparison: if score >= 0.95 (lower confidence - context needed)
    (r'(?:if|elif|while)\s+(?P<name>\w+)\s*(?:>=|<=|>|<|==)\s*(?P<value>[\d.]+)', 0.50),
]

# Patterns for extracting thresholds from LaTeX specs
LATEX_THRESHOLD_PATTERNS = [
    # Table row: threshold & 0.95 \\
    (r'(?P<name>[\w\s-]+)\s*&\s*(?P<value>[\d.]+%?)\s*\\\\', 0.70),
    # Explicit definition: Z-score threshold: 3.0
    (r'(?P<name>[\w\s-]+(?:threshold|limit|rate|ratio)):\s*(?P<value>[\d.]+)', 0.90),
    # Metric target: Target: ≥70%
    (r'(?P<name>Target|Threshold|Limit|Kill-Switch):\s*[≥≤<>]?\s*(?P<value>[\d.]+%?)', 0.85),
    # Inline specification: "must be at least 95%"
    (r'(?:must be|should be|at least|at most|minimum|maximum)\s+(?P<value>[\d.]+%?)', 0.60),
]


def extract_thresholds_from_code(code_path: str) -> List[ThresholdValue]:
    """Extract threshold values from Python code with confidence scoring."""
    thresholds = []
    
    try:
        with open(code_path, "r") as f:
            lines = f.readlines()
    except FileNotFoundError:
        return thresholds
    
    # Also extract from AST for better accuracy
    constants = extract_code_constants(code_path)
    
    for const_name, (const_value, line_num) in constants.items():
        if isinstance(const_value, (int, float)):
            # Check if name suggests a threshold
            normalized = const_name.lower()
            if any(kw in normalized for kw in ['threshold', 'limit', 'max', 'min', 'rate', 'ratio', 'percent']):
                thresholds.append(ThresholdValue(
                    name=const_name,
                    value=const_value,
                    source_file=code_path,
                    line_number=line_num,
                    normalized_name=normalize_identifier(const_name),
                    context=lines[line_num - 1].strip() if line_num <= len(lines) else "",
                ))
    
    # Regex-based extraction for non-constant patterns
    for line_num, line in enumerate(lines, 1):
        for pattern, base_confidence in THRESHOLD_PATTERNS:
            matches = re.finditer(pattern, line, re.IGNORECASE)
            for match in matches:
                groups = match.groupdict()
                name = groups.get("name", f"line_{line_num}")
                value_str = groups.get("value", "")
                
                try:
                    value = float(value_str.rstrip("%"))
                    if value_str.endswith("%"):
                        value = value / 100
                except ValueError:
                    continue
                
                # Skip if already captured by AST
                if any(t.line_number == line_num and t.name == name for t in thresholds):
                    continue
                
                thresholds.append(ThresholdValue(
                    name=name,
                    value=value,
                    source_file=code_path,
                    line_number=line_num,
                    normalized_name=normalize_identifier(name),
                    context=line.strip(),
                ))
    
    return thresholds


def extract_thresholds_from_spec(spec_path: str) -> List[ThresholdValue]:
    """Extract threshold values from LaTeX specification with confidence scoring."""
    thresholds = []
    
    try:
        with open(spec_path, "r") as f:
            content = f.read()
            lines = content.split("\n")
    except FileNotFoundError:
        return thresholds
    
    for line_num, line in enumerate(lines, 1):
        for pattern, base_confidence in LATEX_THRESHOLD_PATTERNS:
            matches = re.finditer(pattern, line, re.IGNORECASE)
            for match in matches:
                groups = match.groupdict()
                name = groups.get("name", f"spec_line_{line_num}").strip()
                value_str = groups.get("value", "")
                
                try:
                    value = float(value_str.rstrip("%"))
                    if value_str.endswith("%"):
                        value = value / 100
                except ValueError:
                    continue
                
                thresholds.append(ThresholdValue(
                    name=name,
                    value=value,
                    source_file=spec_path,
                    line_number=line_num,
                    normalized_name=normalize_identifier(name),
                    context=line.strip(),
                ))
    
    return thresholds


# =============================================================================
# STATE MACHINE EXTRACTION WITH TRANSITIONS (IMPROVED)
# =============================================================================

def extract_state_machine_from_code(code_path: str) -> Tuple[Set[str], List[StateTransition]]:
    """Extract state machine states AND transitions from Python code."""
    states = set()
    transitions = []
    
    try:
        with open(code_path, "r") as f:
            content = f.read()
    except FileNotFoundError:
        return states, transitions
    
    # Parse with AST to find Enum definitions
    try:
        tree = ast.parse(content)
        
        for node in ast.walk(tree):
            # Look for Enum class definitions
            if isinstance(node, ast.ClassDef):
                # Check if it's an Enum subclass
                is_enum = any(
                    (isinstance(base, ast.Name) and 'Enum' in base.id) or
                    (isinstance(base, ast.Attribute) and 'Enum' in base.attr)
                    for base in node.bases
                )
                
                if is_enum or 'State' in node.name or 'Status' in node.name:
                    for item in node.body:
                        if isinstance(item, ast.Assign):
                            for target in item.targets:
                                if isinstance(target, ast.Name):
                                    states.add(target.id)
    except SyntaxError:
        pass
    
    # Pattern-based extraction for transitions
    # Look for state assignment patterns: self.state = NewState
    transition_patterns = [
        r'(?:self\.)?(?:state|status)\s*=\s*(?:\w+\.)?([A-Z][A-Z0-9_]+)',
        r'transition(?:_to)?\s*\(\s*["\']?([A-Z][A-Z0-9_]+)["\']?\s*\)',
        r'set_state\s*\(\s*["\']?([A-Z][A-Z0-9_]+)["\']?\s*\)',
    ]
    
    lines = content.split('\n')
    for line_num, line in enumerate(lines, 1):
        for pattern in transition_patterns:
            matches = re.findall(pattern, line)
            for match in matches:
                states.add(match)
    
    # Look for explicit transition definitions
    # Pattern: FROM_STATE -> TO_STATE or transitions = {FROM: [TO1, TO2]}
    transition_dict_pattern = r'["\']([A-Z][A-Z0-9_]+)["\']\s*:\s*\[([^\]]+)\]'
    for match in re.finditer(transition_dict_pattern, content):
        from_state = match.group(1)
        to_states = re.findall(r'["\']([A-Z][A-Z0-9_]+)["\']', match.group(2))
        states.add(from_state)
        for to_state in to_states:
            states.add(to_state)
            transitions.append(StateTransition(
                from_state=from_state,
                to_state=to_state,
            ))
    
    # Arrow notation: FROM_STATE -> TO_STATE
    arrow_pattern = r'([A-Z][A-Z0-9_]+)\s*[-=]>\s*([A-Z][A-Z0-9_]+)'
    for match in re.finditer(arrow_pattern, content):
        from_state, to_state = match.groups()
        states.add(from_state)
        states.add(to_state)
        transitions.append(StateTransition(
            from_state=from_state,
            to_state=to_state,
        ))
    
    # Filter out common false positives
    false_positives = {'TRUE', 'FALSE', 'NONE', 'NULL', 'DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL'}
    states = {s for s in states if s not in false_positives}
    
    return states, transitions


def extract_state_machine_from_spec(spec_path: str) -> Tuple[Set[str], List[StateTransition]]:
    """Extract state machine states AND transitions from LaTeX spec."""
    states = set()
    transitions = []
    
    try:
        with open(spec_path, "r") as f:
            content = f.read()
    except FileNotFoundError:
        return states, transitions
    
    # Pattern for state names in various formats
    state_patterns = [
        r'\\texttt\{([A-Z][A-Z0-9_]+)\}',  # \texttt{STATE_NAME}
        r'`([A-Z][A-Z0-9_]+)`',  # `STATE_NAME`
        r'\b(STATE_[A-Z0-9_]+)\b',  # STATE_PREFIX pattern
        r'\b([A-Z][A-Z0-9_]*(?:_STATE|_STATUS|_PHASE))\b',  # Suffix patterns
        r'\b(AWAITING_[A-Z0-9_]+)\b',  # AWAITING_ prefix
        r'\b(PENDING_[A-Z0-9_]+)\b',  # PENDING_ prefix
        r'\b(COMPLETED|APPROVED|REJECTED|ESCALATED|CANCELLED)\b',  # Terminal states
    ]
    
    for pattern in state_patterns:
        matches = re.findall(pattern, content)
        states.update(matches)
    
    # Look for transition tables
    # Pattern: FROM & TO & trigger \\
    table_row_pattern = r'([A-Z][A-Z0-9_]+)\s*&\s*([A-Z][A-Z0-9_]+)\s*(?:&[^\\]+)?\\\\' 
    for match in re.finditer(table_row_pattern, content):
        from_state, to_state = match.groups()
        if from_state in states or to_state in states:
            states.add(from_state)
            states.add(to_state)
            transitions.append(StateTransition(
                from_state=from_state,
                to_state=to_state,
            ))
    
    # Arrow notation in LaTeX: FROM $\rightarrow$ TO
    latex_arrow_pattern = r'([A-Z][A-Z0-9_]+)\s*(?:\\rightarrow|→|->)\s*([A-Z][A-Z0-9_]+)'
    for match in re.finditer(latex_arrow_pattern, content):
        from_state, to_state = match.groups()
        states.add(from_state)
        states.add(to_state)
        transitions.append(StateTransition(
            from_state=from_state,
            to_state=to_state,
        ))
    
    return states, transitions


# =============================================================================
# VERSION DRIFT DETECTION (NEW)
# =============================================================================

def extract_version_from_latex(spec_path: str) -> Optional[VersionInfo]:
    """Extract version information from LaTeX frontmatter."""
    try:
        with open(spec_path, "r") as f:
            content = f.read()
            lines = content.split('\n')
    except FileNotFoundError:
        return None
    
    # Patterns for version in LaTeX
    version_patterns = [
        (r'\\newcommand\{\\specversion\}\{([^}]+)\}', 'semver'),
        (r'\\def\\version\{([^}]+)\}', 'semver'),
        (r'Version:\s*([0-9]+\.[0-9]+(?:\.[0-9]+)?)', 'semver'),
        (r'version\s*=\s*["\']([^"\']+)["\']', 'semver'),
        (r'\\date\{([^}]+)\}', 'date'),
    ]
    
    for line_num, line in enumerate(lines, 1):
        for pattern, version_type in version_patterns:
            match = re.search(pattern, line)
            if match:
                return VersionInfo(
                    version=match.group(1).strip(),
                    source_file=spec_path,
                    line_number=line_num,
                    version_type=version_type,
                )
    
    return None


def extract_version_from_schema(schema_path: str) -> Optional[VersionInfo]:
    """Extract version information from JSON schema."""
    try:
        with open(schema_path, "r") as f:
            schema = json.load(f)
    except (json.JSONDecodeError, FileNotFoundError):
        return None
    
    # Check common version fields
    version_fields = ['version', '$version', 'schemaVersion', 'schema_version']
    for field in version_fields:
        if field in schema:
            return VersionInfo(
                version=str(schema[field]),
                source_file=schema_path,
                line_number=0,
                version_type='semver',
            )
    
    # Check in $id for version
    if '$id' in schema:
        id_match = re.search(r'/v?([0-9]+\.[0-9]+(?:\.[0-9]+)?)', schema['$id'])
        if id_match:
            return VersionInfo(
                version=id_match.group(1),
                source_file=schema_path,
                line_number=0,
                version_type='semver',
            )
    
    return None


def compare_versions(v1: str, v2: str) -> Tuple[bool, str]:
    """Compare two version strings. Returns (are_compatible, message)."""
    # Parse semver-style versions
    def parse_version(v: str) -> Tuple[int, int, int]:
        parts = re.findall(r'\d+', v)
        major = int(parts[0]) if len(parts) > 0 else 0
        minor = int(parts[1]) if len(parts) > 1 else 0
        patch = int(parts[2]) if len(parts) > 2 else 0
        return (major, minor, patch)
    
    try:
        v1_parts = parse_version(v1)
        v2_parts = parse_version(v2)
        
        if v1_parts[0] != v2_parts[0]:
            return False, f"Major version mismatch: {v1} vs {v2}"
        elif v1_parts[1] != v2_parts[1]:
            return True, f"Minor version difference: {v1} vs {v2}"
        elif v1_parts[2] != v2_parts[2]:
            return True, f"Patch version difference: {v1} vs {v2}"
        else:
            return True, "Versions match"
    except (ValueError, IndexError):
        return v1 == v2, f"Version comparison: {v1} vs {v2}"


# =============================================================================
# LATEX SPEC PARSING
# =============================================================================

def extract_spec_fields_from_latex(spec_path: str) -> Set[str]:
    """Extract field names mentioned in LaTeX spec data model sections."""
    fields = set()
    
    try:
        with open(spec_path, "r") as f:
            content = f.read()
    except FileNotFoundError:
        return fields
    
    # Pattern for tabular/tabularx rows that look like field definitions
    # Matches: field_name & type & description \\
    tabular_pattern = r'\\texttt\{([a-z_][a-z0-9_]*)\}'
    
    # Pattern for lstlisting/code blocks with field definitions
    code_pattern = r'["\']([a-z_][a-z0-9_]*)["\']:'
    
    # Pattern for field names in description lists
    desc_pattern = r'\\item\[([a-z_][a-z0-9_]*)\]'
    
    # Pattern for field names in inline code
    inline_pattern = r'`([a-z_][a-z0-9_]*)`'
    
    for pattern in [tabular_pattern, code_pattern, desc_pattern, inline_pattern]:
        matches = re.findall(pattern, content, re.IGNORECASE)
        fields.update(matches)
    
    # Also look for explicit field lists in specific sections
    # Look for lines like: - field_name: description
    yaml_style_pattern = r'^\s*-?\s*([a-z_][a-z0-9_]*):'
    matches = re.findall(yaml_style_pattern, content, re.MULTILINE | re.IGNORECASE)
    fields.update(matches)
    
    return fields


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


def detect_schema_spec_drift(
    schema_path: str,
    spec_path: str,
    domain: str,
) -> List[DriftFinding]:
    """Detect actual field drift between schema and spec (DRIFT-001) with confidence scoring."""
    findings = []
    
    # Skip directories - only process actual schema files
    if not Path(schema_path).exists() or not Path(spec_path).exists():
        return findings
    
    if Path(schema_path).is_dir() or Path(spec_path).is_dir():
        return findings
    
    schema_fields = get_schema_field_names(schema_path)
    spec_fields = extract_spec_fields_from_latex(spec_path)
    
    # Filter spec fields to likely schema fields (lowercase with underscores)
    spec_fields = {f for f in spec_fields if re.match(r'^[a-z][a-z0-9_]*$', f)}
    
    # Fields in schema but not mentioned in spec
    schema_only = schema_fields - spec_fields
    # Fields mentioned in spec but not in schema
    spec_only = spec_fields - schema_fields
    
    # Filter out common false positives
    common_words = {'type', 'name', 'id', 'description', 'value', 'status', 'data', 'items', 'properties'}
    schema_only = schema_only - common_words
    spec_only = spec_only - common_words
    
    # Calculate confidence based on field count ratio and naming patterns
    if schema_fields:
        # Check for fuzzy matches to reduce false positives
        matched_via_similarity = set()
        for schema_field in schema_only:
            match = find_best_match(schema_field, spec_fields, threshold=0.75)
            if match:
                matched_via_similarity.add(schema_field)
        
        schema_only_high_confidence = schema_only - matched_via_similarity
        
        if schema_only_high_confidence and len(schema_only_high_confidence) > 2:
            # Higher confidence if many fields are missing
            confidence = min(0.95, 0.6 + (len(schema_only_high_confidence) / len(schema_fields)) * 0.35)
            
            findings.append(DriftFinding(
                id=f"DRIFT-001-SCHEMA-{len(findings)+1:03d}",
                drift_type=DriftType.DRIFT_001,
                severity=Severity.MEDIUM if confidence >= CONFIDENCE_MEDIUM else Severity.LOW,
                confidence=confidence,
                source_file=schema_path,
                message=f"Schema has {len(schema_only_high_confidence)} fields not documented in spec",
                related_artifacts=[RelatedArtifact(
                    path=spec_path,
                    artifact_type="specification",
                    status="possibly_stale",
                    domain=domain,
                )],
                evidence={
                    "schema_only_fields": sorted(list(schema_only_high_confidence))[:20],
                    "fuzzy_matched_fields": sorted(list(matched_via_similarity))[:10],
                    "schema_field_count": len(schema_fields),
                    "spec_field_count": len(spec_fields),
                },
                remediation=f"Document these fields in {spec_path}: {', '.join(sorted(list(schema_only_high_confidence))[:10])}",
                blocking=False,
            ))
    
    if spec_only and len(spec_only) > 2:
        # Lower confidence for spec-only fields (may be conceptual)
        confidence = min(0.75, 0.4 + (len(spec_only) / max(len(spec_fields), 1)) * 0.35)
        
        findings.append(DriftFinding(
            id=f"DRIFT-001-SPEC-{len(findings)+1:03d}",
            drift_type=DriftType.DRIFT_001,
            severity=Severity.LOW,
            confidence=confidence,
            source_file=spec_path,
            message=f"Spec mentions {len(spec_only)} fields not in schema (may be removed or renamed)",
            related_artifacts=[RelatedArtifact(
                path=schema_path,
                artifact_type="schema",
                status="possibly_stale",
                domain=domain,
            )],
            evidence={
                "spec_only_fields": sorted(list(spec_only))[:20],
            },
            remediation=f"Verify these fields are still valid or update spec: {', '.join(sorted(list(spec_only))[:10])}",
            blocking=False,
        ))
    
    return findings


def detect_code_schema_drift(
    code_path: str,
    schema_path: str,
    domain: str,
) -> List[DriftFinding]:
    """Detect drift between code field accesses and schema (DRIFT-002) using AST analysis.
    
    MEDIUM-TERM IMPROVEMENTS:
    - Semantic field classification (data_field, computed, internal, etc.)
    - Filters out method names (get_*, is_*, has_*, etc.)
    - Filters out generic field names
    - Recognizes method-to-field equivalents (get_user -> user)
    - Requires minimum mismatch count before reporting
    - Uses schema relevance scoring to prioritize findings
    """
    findings = []
    
    if not Path(code_path).exists() or not Path(schema_path).exists():
        return findings
    
    if Path(code_path).is_dir() or Path(schema_path).is_dir():
        return findings
    
    # Get schema fields
    schema_fields = get_schema_field_names(schema_path)
    if not schema_fields:
        return findings
    
    # Get code field accesses via AST
    field_accesses, dict_keys, class_fields = extract_code_field_accesses(code_path)
    
    # Combine all accessed fields
    code_accessed_fields = dict_keys.copy()
    for access in field_accesses:
        if access.access_type in ('dict_access', 'attr_access'):
            code_accessed_fields.add(access.field_name)
    
    # Filter to snake_case identifiers likely to be schema fields
    code_accessed_fields = {f for f in code_accessed_fields if re.match(r'^[a-z][a-z0-9_]*$', f)}
    
    # Common programming keywords to exclude
    common_keywords = {'self', 'cls', 'args', 'kwargs', 'name', 'value', 'key', 'item', 
                       'index', 'count', 'result', 'response', 'request', 'data', 'config',
                       'path', 'file', 'line', 'type', 'id', 'get', 'set', 'items', 'keys',
                       'values', 'append', 'extend', 'update', 'pop', 'clear'}
    
    code_accessed_fields -= common_keywords
    
    # MEDIUM-TERM: Apply semantic field classification to filter non-schema-relevant fields
    semantically_filtered = set()
    computed_fields = []
    internal_fields = []
    
    for field in code_accessed_fields:
        if should_skip_field_for_schema_comparison(field):
            category = classify_field_semantically(field)
            if category == FieldCategory.COMPUTED_PROPERTY:
                computed_fields.append(field)
            elif category == FieldCategory.INTERNAL_FIELD:
                internal_fields.append(field)
        else:
            semantically_filtered.add(field)
    
    # Apply false positive filtering on semantically-filtered set
    filtered_code, filtered_schema, method_to_field = filter_false_positive_fields(
        semantically_filtered, schema_fields
    )
    
    # Fields accessed in code but not in schema (after filtering)
    code_only = filtered_code - filtered_schema
    
    # Use fuzzy matching to find potential matches - with schema relevance weighting
    likely_mismatches = []
    for code_field in code_only:
        # Skip if this was identified as a method for an existing field
        if code_field in method_to_field:
            continue
        
        # Get schema relevance score for this field
        relevance = get_schema_relevance_score(code_field)
        
        # Skip low-relevance fields (computed properties, etc.)
        if relevance < 0.5:
            continue
            
        match = find_best_match(code_field, filtered_schema, threshold=0.6)
        if match:
            schema_field, similarity = match
            # Additional check: is this a method-field pattern?
            if not is_method_for_field(code_field, schema_field):
                # Weight by relevance
                weighted_similarity = similarity * relevance
                likely_mismatches.append((code_field, schema_field, similarity, relevance))
    
    # Require minimum mismatches before reporting (reduce noise)
    if len(likely_mismatches) < MIN_FIELD_MISMATCHES_TO_REPORT:
        likely_mismatches = []  # Don't report if below threshold
    
    # Report findings with confidence
    if likely_mismatches:
        # Calculate confidence based on evidence quality
        confidence = calculate_finding_confidence(
            mismatch_count=len(likely_mismatches),
            total_fields=len(schema_fields),
            has_fuzzy_matches=True,
            method_field_matches=len(method_to_field)
        )
        
        for code_field, schema_field, similarity, relevance in likely_mismatches[:5]:  # Limit to top 5
            # Adjust confidence by relevance score
            finding_confidence = min(confidence, similarity * 0.9) * relevance
            
            findings.append(DriftFinding(
                id=f"DRIFT-002-MISMATCH-{len(findings)+1:03d}",
                drift_type=DriftType.DRIFT_002,
                severity=Severity.MEDIUM if finding_confidence >= CONFIDENCE_MEDIUM else Severity.LOW,
                confidence=finding_confidence,
                source_file=code_path,
                message=f"Code accesses '{code_field}' but schema has '{schema_field}' (possible typo or rename)",
                related_artifacts=[RelatedArtifact(
                    path=schema_path,
                    artifact_type="schema",
                    status="possibly_stale",
                    domain=domain,
                )],
                evidence={
                    "code_field": code_field,
                    "similar_schema_field": schema_field,
                    "similarity_score": round(similarity, 2),
                    "schema_relevance": round(relevance, 2),
                    "field_category": classify_field_semantically(code_field).value,
                    "method_field_equivalents_filtered": len(method_to_field),
                    "computed_fields_skipped": len(computed_fields),
                    "internal_fields_skipped": len(internal_fields),
                },
                remediation=f"Update code to use '{schema_field}' instead of '{code_field}', or update schema",
                blocking=False,
            ))
    
    # Report completely unknown fields (not fuzzy-matched)
    matched_code_fields = {m[0] for m in likely_mismatches}
    truly_unknown = code_only - matched_code_fields - set(method_to_field.keys())
    
    # Filter truly_unknown by relevance score
    high_relevance_unknown = {f for f in truly_unknown if get_schema_relevance_score(f) >= 0.7}
    
    # Require more unknown fields before reporting
    if high_relevance_unknown and len(high_relevance_unknown) >= MIN_FIELD_MISMATCHES_TO_REPORT:
        confidence = calculate_finding_confidence(
            mismatch_count=len(high_relevance_unknown),
            total_fields=len(schema_fields),
            has_fuzzy_matches=False,
            method_field_matches=len(method_to_field)
        )
        
        findings.append(DriftFinding(
            id=f"DRIFT-002-UNKNOWN-{len(findings)+1:03d}",
            drift_type=DriftType.DRIFT_002,
            severity=Severity.LOW,
            confidence=confidence,
            source_file=code_path,
            message=f"Code accesses {len(high_relevance_unknown)} fields not in schema (high relevance, may need review)",
            related_artifacts=[RelatedArtifact(
                path=schema_path,
                artifact_type="schema",
                status="possibly_stale",
                domain=domain,
            )],
            evidence={
                "unknown_fields": sorted(list(high_relevance_unknown))[:15],
                "filtered_as_methods": len([f for f in code_accessed_fields if is_likely_method_name(f)]),
                "filtered_as_generic": len([f for f in code_accessed_fields if is_generic_field(f)]),
                "filtered_as_computed": len(computed_fields),
                "filtered_as_internal": len(internal_fields),
                "low_relevance_skipped": len(truly_unknown) - len(high_relevance_unknown),
            },
            remediation="Review if these fields should be added to schema or if code references are incorrect",
            blocking=False,
        ))
    
    return findings


def detect_threshold_drift(
    code_path: str,
    spec_path: str,
    domain: str,
) -> List[DriftFinding]:
    """Detect threshold value drift between code and spec (DRIFT-006) with semantic matching."""
    findings = []
    
    if not Path(code_path).exists() or not Path(spec_path).exists():
        return findings
    
    code_thresholds = extract_thresholds_from_code(code_path)
    spec_thresholds = extract_thresholds_from_spec(spec_path)
    
    if not code_thresholds or not spec_thresholds:
        return findings
    
    # Build lookup by normalized name
    code_by_name = {t.normalized_name: t for t in code_thresholds if t.normalized_name}
    spec_by_name = {t.normalized_name: t for t in spec_thresholds if t.normalized_name}
    
    # Find exact matches by normalized name
    for name, code_threshold in code_by_name.items():
        if name in spec_by_name:
            spec_threshold = spec_by_name[name]
            
            # Compare values with tolerance
            if abs(code_threshold.value - spec_threshold.value) > 0.001:
                # Calculate confidence based on name match quality
                confidence = 0.95  # High confidence for exact name match
                
                findings.append(DriftFinding(
                    id=f"DRIFT-006-{len(findings)+1:03d}",
                    drift_type=DriftType.DRIFT_006,
                    severity=Severity.HIGH,
                    confidence=confidence,
                    source_file=code_path,
                    message=f"Threshold '{code_threshold.name}' differs: code={code_threshold.value}, spec={spec_threshold.value}",
                    related_artifacts=[RelatedArtifact(
                        path=spec_path,
                        artifact_type="specification",
                        status="drift_detected",
                        domain=domain,
                    )],
                    evidence={
                        "code_value": code_threshold.value,
                        "code_line": code_threshold.line_number,
                        "code_context": code_threshold.context,
                        "spec_value": spec_threshold.value,
                        "spec_line": spec_threshold.line_number,
                        "spec_context": spec_threshold.context,
                    },
                    remediation=f"Align threshold in code ({code_path}:{code_threshold.line_number}) with spec value {spec_threshold.value}",
                    blocking=True,
                ))
    
    # Fuzzy match for similar names
    unmatched_code = [t for t in code_thresholds if t.normalized_name not in spec_by_name]
    unmatched_spec = set(spec_by_name.keys()) - set(code_by_name.keys())
    
    for code_threshold in unmatched_code:
        match = find_best_match(code_threshold.normalized_name, unmatched_spec, threshold=0.7)
        if match:
            spec_name, similarity = match
            spec_threshold = spec_by_name[spec_name]
            
            if abs(code_threshold.value - spec_threshold.value) > 0.001:
                confidence = similarity * 0.85  # Slightly lower confidence for fuzzy match
                
                findings.append(DriftFinding(
                    id=f"DRIFT-006-FUZZY-{len(findings)+1:03d}",
                    drift_type=DriftType.DRIFT_006,
                    severity=Severity.MEDIUM,
                    confidence=confidence,
                    source_file=code_path,
                    message=f"Possible threshold mismatch: code '{code_threshold.name}'={code_threshold.value} vs spec '{spec_threshold.name}'={spec_threshold.value}",
                    related_artifacts=[RelatedArtifact(
                        path=spec_path,
                        artifact_type="specification",
                        status="drift_detected",
                        domain=domain,
                    )],
                    evidence={
                        "code_name": code_threshold.name,
                        "spec_name": spec_threshold.name,
                        "name_similarity": round(similarity, 2),
                        "code_value": code_threshold.value,
                        "spec_value": spec_threshold.value,
                    },
                    remediation=f"Verify if '{code_threshold.name}' should match '{spec_threshold.name}' and align values",
                    blocking=False,
                ))
    
    return findings


def detect_state_machine_drift(
    code_path: str,
    spec_path: str,
    domain: str,
) -> List[DriftFinding]:
    """Detect state machine drift between code and spec (DRIFT-007) with transition analysis."""
    findings = []
    
    if not Path(code_path).exists() or not Path(spec_path).exists():
        return findings
    
    code_states, code_transitions = extract_state_machine_from_code(code_path)
    spec_states, spec_transitions = extract_state_machine_from_spec(spec_path)
    
    if not code_states and not spec_states:
        return findings
    
    # States in code but not spec
    code_only = code_states - spec_states
    # States in spec but not code
    spec_only = spec_states - code_states
    
    # Calculate confidence based on state count and overlap
    total_states = len(code_states | spec_states)
    overlap = len(code_states & spec_states)
    overlap_ratio = overlap / total_states if total_states > 0 else 0
    
    if code_only:
        # Higher confidence if there's good overlap (indicating real state machine, not false positives)
        confidence = min(0.9, 0.5 + overlap_ratio * 0.4)
        
        findings.append(DriftFinding(
            id=f"DRIFT-007-CODE-{len(findings)+1:03d}",
            drift_type=DriftType.DRIFT_007,
            severity=Severity.HIGH if confidence >= CONFIDENCE_HIGH else Severity.MEDIUM,
            confidence=confidence,
            source_file=code_path,
            message=f"Code has {len(code_only)} states not documented in spec",
            related_artifacts=[RelatedArtifact(
                path=spec_path,
                artifact_type="specification",
                status="possibly_stale",
                domain=domain,
            )],
            evidence={
                "code_only_states": sorted(list(code_only)),
                "total_code_states": len(code_states),
                "total_spec_states": len(spec_states),
                "overlap_ratio": round(overlap_ratio, 2),
            },
            remediation=f"Document these states in spec: {', '.join(sorted(code_only))}",
            blocking=confidence >= CONFIDENCE_HIGH,
        ))
    
    if spec_only:
        confidence = min(0.95, 0.6 + overlap_ratio * 0.35)
        
        findings.append(DriftFinding(
            id=f"DRIFT-007-SPEC-{len(findings)+1:03d}",
            drift_type=DriftType.DRIFT_007,
            severity=Severity.CRITICAL if confidence >= CONFIDENCE_HIGH else Severity.HIGH,
            confidence=confidence,
            source_file=spec_path,
            message=f"Spec has {len(spec_only)} states not implemented in code",
            related_artifacts=[RelatedArtifact(
                path=code_path,
                artifact_type="code",
                status="possibly_stale",
                domain=domain,
            )],
            evidence={
                "spec_only_states": sorted(list(spec_only)),
                "overlap_ratio": round(overlap_ratio, 2),
            },
            remediation=f"Implement these states in code or remove from spec: {', '.join(sorted(spec_only))}",
            blocking=confidence >= CONFIDENCE_HIGH,
        ))
    
    # Compare transitions if both have them
    if code_transitions and spec_transitions:
        code_trans_set = {(t.from_state, t.to_state) for t in code_transitions}
        spec_trans_set = {(t.from_state, t.to_state) for t in spec_transitions}
        
        missing_in_code = spec_trans_set - code_trans_set
        missing_in_spec = code_trans_set - spec_trans_set
        
        if missing_in_code:
            findings.append(DriftFinding(
                id=f"DRIFT-007-TRANS-{len(findings)+1:03d}",
                drift_type=DriftType.DRIFT_007,
                severity=Severity.HIGH,
                confidence=0.85,
                source_file=code_path,
                message=f"{len(missing_in_code)} state transitions in spec not implemented in code",
                related_artifacts=[RelatedArtifact(
                    path=spec_path,
                    artifact_type="specification",
                    status="possibly_stale",
                    domain=domain,
                )],
                evidence={
                    "missing_transitions": [f"{f}->{t}" for f, t in sorted(missing_in_code)[:10]],
                },
                remediation="Implement missing state transitions or update spec",
                blocking=True,
            ))
        
        if missing_in_spec:
            findings.append(DriftFinding(
                id=f"DRIFT-007-TRANS-{len(findings)+1:03d}",
                drift_type=DriftType.DRIFT_007,
                severity=Severity.MEDIUM,
                confidence=0.80,
                source_file=spec_path,
                message=f"{len(missing_in_spec)} state transitions in code not documented in spec",
                related_artifacts=[RelatedArtifact(
                    path=code_path,
                    artifact_type="code",
                    status="possibly_stale",
                    domain=domain,
                )],
                evidence={
                    "undocumented_transitions": [f"{f}->{t}" for f, t in sorted(missing_in_spec)[:10]],
                },
                remediation="Document these transitions in spec",
                blocking=False,
            ))
    
    return findings


def detect_version_drift(
    changed_files: List[str],
    mapping_registry: Dict[str, Any],
    schema_registry: Dict[str, Any],
) -> List[DriftFinding]:
    """Detect version inconsistencies across artifacts (DRIFT-004)."""
    findings = []
    
    domains = mapping_registry.get("domains", {})
    
    for domain_name, domain_config in domains.items():
        spec_root = domain_config.get("spec_root")
        schema_root = domain_config.get("schema_root")
        
        if not spec_root or not schema_root:
            continue
        
        # Find main spec file
        spec_dir = Path(spec_root)
        if not spec_dir.exists():
            continue
        
        main_spec_files = list(spec_dir.glob("*-spec.tex")) + list(spec_dir.glob("*-spec-*.tex"))
        
        for spec_file in main_spec_files:
            spec_version = extract_version_from_latex(str(spec_file))
            if not spec_version:
                continue
            
            # Compare with schema versions
            schema_dir = Path(schema_root)
            if not schema_dir.exists():
                continue
            
            for schema_file in schema_dir.glob("*.schema.json"):
                schema_version = extract_version_from_schema(str(schema_file))
                if not schema_version:
                    continue
                
                compatible, message = compare_versions(spec_version.version, schema_version.version)
                
                if not compatible:
                    findings.append(DriftFinding(
                        id=f"DRIFT-004-{len(findings)+1:03d}",
                        drift_type=DriftType.DRIFT_004,
                        severity=Severity.HIGH,
                        confidence=0.90,
                        source_file=str(spec_file),
                        message=f"Version mismatch between spec and schema: {message}",
                        related_artifacts=[RelatedArtifact(
                            path=str(schema_file),
                            artifact_type="schema",
                            status="version_mismatch",
                            domain=domain_name,
                        )],
                        evidence={
                            "spec_version": spec_version.version,
                            "spec_file": str(spec_file),
                            "schema_version": schema_version.version,
                            "schema_file": str(schema_file),
                        },
                        remediation="Synchronize version numbers across spec and schema",
                        blocking=True,
                    ))
    
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
                    confidence=0.95,
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
                    confidence=0.85,
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
        domain = get_domain_for_file(filepath, mapping_registry)
        
        # Check if related artifacts are also being changed
        for artifact in related:
            if artifact.path not in changed_set:
                # Check if it's a directory pattern
                if artifact.path.endswith("/"):
                    dir_updated = any(f.startswith(artifact.path) for f in changed_set)
                    if dir_updated:
                        artifact.status = "updated"
                        continue
                
                # Determine correct drift type based on source and target categories
                if category == "schema" and artifact.artifact_type == "specification":
                    drift_type = DriftType.DRIFT_001  # Schema-Spec Drift
                elif category == "specification" and artifact.artifact_type == "schema":
                    drift_type = DriftType.DRIFT_001  # Schema-Spec Drift
                elif category == "code" and artifact.artifact_type == "schema":
                    drift_type = DriftType.DRIFT_002  # Code-Schema Drift
                elif category == "schema" and artifact.artifact_type == "code":
                    drift_type = DriftType.DRIFT_002  # Code-Schema Drift
                elif category == "code" and artifact.artifact_type == "specification":
                    drift_type = DriftType.DRIFT_003  # Code-Spec Drift
                elif category == "specification" and artifact.artifact_type == "code":
                    drift_type = DriftType.DRIFT_003  # Code-Spec Drift
                else:
                    drift_type = DriftType.DRIFT_003  # Default to Code-Spec Drift
                
                # Related artifact not in changeset - potential drift
                report.findings.append(DriftFinding(
                    id=f"{drift_type.name}-{len(report.findings)+1:03d}",
                    drift_type=drift_type,
                    severity=Severity.MEDIUM,
                    confidence=0.70,  # Moderate confidence for changeset-based detection
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
                    confidence=1.0,
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
    
    # Update blocking status based on severity AND confidence
    for finding in report.findings:
        if finding.severity == Severity.CRITICAL:
            finding.blocking = True
        elif finding.severity == Severity.HIGH and finding.confidence >= CONFIDENCE_HIGH:
            finding.blocking = True
        elif finding.severity == Severity.HIGH and finding.confidence < CONFIDENCE_MEDIUM:
            # Downgrade low-confidence HIGH to MEDIUM
            finding.blocking = False
    
    return report


def run_full_audit(domain: Optional[str] = None, dry_run: bool = False) -> AuditReport:
    """Run comprehensive full audit with semantic analysis.
    
    Args:
        domain: Optional domain to restrict audit to
        dry_run: If True, run without saving results, show expected vs actual counts
    """
    mapping_registry = load_mapping_registry()
    schema_registry = load_schema_registry()
    
    report = AuditReport(
        report_id=f"DRIFT-AUDIT-FULL-{datetime.now().strftime('%Y%m%d%H%M%S')}",
        trigger="full" if not dry_run else "dry-run",
        commit_sha=get_current_commit_sha(),
        branch=get_current_branch(),
        timestamp=datetime.now().isoformat(),
        changed_files=[],  # Full audit doesn't use changed files
    )
    
    domains_to_check = mapping_registry.get("domains", {})
    if domain:
        domains_to_check = {domain: domains_to_check.get(domain, {})}
    
    # Check each domain for structural integrity AND semantic drift
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
                confidence=1.0,
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
                confidence=1.0,
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
                        confidence=1.0,
                        source_file=str(schema_file),
                        message=f"Schema validation failed: {error}",
                        evidence={"validation_error": error, "domain": domain_name},
                        remediation="Fix schema validation errors",
                        blocking=True,
                    ))
        
        # Check artifacts in domain - with SEMANTIC ANALYSIS
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
                    confidence=1.0,
                    source_file=spec_path,
                    message=f"Spec file referenced in mapping does not exist",
                    evidence={"artifact_id": artifact.get("id"), "domain": domain_name},
                    remediation="Create spec file or update mapping registry",
                    blocking=False,
                ))
                continue  # Skip further checks for this artifact
            
            # Schema-Spec field comparison (DRIFT-001)
            for schema_path in related_schemas:
                if Path(schema_path).exists() and spec_path and Path(spec_path).exists():
                    report.findings.extend(
                        detect_schema_spec_drift(schema_path, spec_path, domain_name)
                    )
            
            # Code-Schema drift detection (DRIFT-002) - NEW AST-based
            for code_path in related_code:
                if code_path.endswith("/"):
                    code_dir = Path(code_path)
                    if code_dir.exists():
                        for py_file in code_dir.glob("*.py"):
                            for schema_path in related_schemas:
                                if Path(schema_path).exists():
                                    report.findings.extend(
                                        detect_code_schema_drift(str(py_file), schema_path, domain_name)
                                    )
                elif Path(code_path).exists():
                    for schema_path in related_schemas:
                        if Path(schema_path).exists():
                            report.findings.extend(
                                detect_code_schema_drift(code_path, schema_path, domain_name)
                            )
            
            # Threshold drift detection (DRIFT-006)
            if spec_path and Path(spec_path).exists():
                for code_path in related_code:
                    if code_path.endswith("/"):
                        code_dir = Path(code_path)
                        if code_dir.exists():
                            for py_file in code_dir.glob("*.py"):
                                report.findings.extend(
                                    detect_threshold_drift(str(py_file), spec_path, domain_name)
                                )
                    elif Path(code_path).exists():
                        report.findings.extend(
                            detect_threshold_drift(code_path, spec_path, domain_name)
                        )
            
            # State machine drift detection (DRIFT-007) for workflow specs
            if spec_path and ("workflow" in spec_path.lower() or "state" in spec_path.lower()):
                for code_path in related_code:
                    if code_path.endswith("/"):
                        code_dir = Path(code_path)
                        if code_dir.exists():
                            for py_file in code_dir.glob("*.py"):
                                if "state" in py_file.name.lower() or "workflow" in py_file.name.lower():
                                    report.findings.extend(
                                        detect_state_machine_drift(str(py_file), spec_path, domain_name)
                                    )
                    elif Path(code_path).exists():
                        report.findings.extend(
                            detect_state_machine_drift(code_path, spec_path, domain_name)
                        )
            
            # Verify related schemas exist
            for schema_path in related_schemas:
                if not Path(schema_path).exists():
                    report.findings.append(DriftFinding(
                        id=f"DRIFT-002-{len(report.findings)+1:03d}",
                        drift_type=DriftType.DRIFT_002,
                        severity=Severity.MEDIUM,
                        confidence=1.0,
                        source_file=schema_path,
                        message=f"Related schema referenced in mapping does not exist",
                        evidence={"artifact_id": artifact.get("id"), "domain": domain_name},
                        remediation="Create schema file or update mapping registry",
                        blocking=False,
                    ))
    
    # Version drift check (DRIFT-004)
    report.findings.extend(
        detect_version_drift([], mapping_registry, schema_registry)
    )
    
    # API Contract drift check (DRIFT-008)
    # Check for OpenAPI specs in docs/api/ directory
    openapi_dir = Path(OPENAPI_SPECS_DIR)
    if openapi_dir.exists():
        for openapi_file in openapi_dir.glob("*.yaml"):
            # Try to match OpenAPI spec to a domain based on naming
            openapi_name = openapi_file.stem.lower()
            matched_domain = None
            code_paths = []
            
            for domain_name, domain_config in domains_to_check.items():
                # First check for explicit mapping in artifacts
                domain_artifacts = domain_config.get("artifacts", [])
                found_explicit = False
                for art in domain_artifacts:
                    if art.get("type") == "openapi" and (
                        art.get("path") == str(openapi_file) or
                        art.get("path") == f"docs/api/{openapi_file.name}"
                    ):
                        matched_domain = domain_name
                        explicit_code = art.get("related_code", [])
                        if explicit_code:
                            code_paths.extend(explicit_code)
                        elif domain_config.get("code_root"):
                            code_paths.append(domain_config.get("code_root"))
                        found_explicit = True
                        break

                if found_explicit:
                    break

                if domain_name.lower() in openapi_name or openapi_name in domain_name.lower():
                    matched_domain = domain_name
                    code_root = domain_config.get("code_root")
                    if code_root:
                        code_paths.append(code_root)
                    break
            
            if not matched_domain:
                # Use generic intelligence code root as fallback
                code_paths = ["src/intelligence/"]
                matched_domain = "api"
            
            if code_paths:
                report.findings.extend(
                    detect_api_contract_drift(str(openapi_file), code_paths, matched_domain)
                )
    
    # Verify schema registry integrity
    for domain_name, domain_info in schema_registry.get("domains", {}).items():
        for schema_info in domain_info.get("schemas", []):
            schema_path = f"docs/schema/{schema_info.get('path', '')}"
            if not Path(schema_path).exists():
                report.findings.append(DriftFinding(
                    id=f"DRIFT-002-{len(report.findings)+1:03d}",
                    drift_type=DriftType.DRIFT_002,
                    severity=Severity.HIGH,
                    confidence=1.0,
                    source_file=schema_path,
                    message=f"Schema in registry does not exist on disk",
                    evidence={"schema_id": schema_info.get("id"), "registry_domain": domain_name},
                    remediation="Create schema file or remove from registry",
                    blocking=False,
                ))
    
    # Filter out low-confidence findings in full audit
    report.findings = [f for f in report.findings if f.confidence >= CONFIDENCE_LOW]
    
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
    """Format report for console output with confidence scores."""
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
        lines.append(f"\nFINDINGS ({len(report.findings)} total, {report.high_confidence_count} high-confidence):")
        lines.append("-" * 40)
        
        # Sort by severity, then confidence
        sorted_findings = sorted(
            report.findings, 
            key=lambda f: (f.severity.value, -f.confidence, f.id)
        )
        
        for finding in sorted_findings:
            severity_icon = {
                Severity.CRITICAL: "🔴",
                Severity.HIGH: "🟠",
                Severity.MEDIUM: "🟡",
                Severity.LOW: "🔵",
                Severity.INFO: "⚪",
            }.get(finding.severity, "⚪")
            
            blocking_mark = " [BLOCKING]" if finding.blocking else ""
            confidence_mark = f" ({int(finding.confidence * 100)}%)"
            
            lines.append(f"\n{severity_icon} [{finding.severity.value}] {finding.id}{blocking_mark}{confidence_mark}")
            lines.append(f"   Type: {finding.drift_type.value}")
            lines.append(f"   File: {finding.source_file}")
            lines.append(f"   Message: {finding.message}")
            
            if finding.related_artifacts:
                lines.append("   Related Artifacts:")
                for artifact in finding.related_artifacts:
                    lines.append(f"     - {artifact.path} ({artifact.artifact_type}, {artifact.status})")
            
            # Show evidence for semantic drift findings
            if finding.evidence:
                evidence_keys = ['schema_only_fields', 'spec_only_fields', 'code_value', 'spec_value', 
                               'code_only_states', 'spec_only_states', 'missing_transitions',
                               'undocumented_transitions', 'code_field', 'similar_schema_field',
                               'similarity_score', 'fuzzy_matched_fields']
                shown_evidence = {k: v for k, v in finding.evidence.items() if k in evidence_keys}
                if shown_evidence:
                    lines.append("   Evidence:")
                    for key, value in shown_evidence.items():
                        if isinstance(value, list):
                            lines.append(f"     {key}: {', '.join(str(v) for v in value[:5])}")
                            if len(value) > 5:
                                lines.append(f"       ... and {len(value) - 5} more")
                        else:
                            lines.append(f"     {key}: {value}")
            
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
    lines.append(f"High-Confidence (≥{int(CONFIDENCE_HIGH*100)}%): {report.high_confidence_count}")
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
        confidence_pct = int(finding.confidence * 100)
        lines.append(f"::{level} file={finding.source_file}::{finding.message} (confidence: {confidence_pct}%)")
    
    # Summary
    lines.append("")
    lines.append(f"## Spec-Drift Audit Summary")
    lines.append(f"| Severity | Count | High-Confidence |")
    lines.append(f"|----------|-------|-----------------|")
    lines.append(f"| Critical | {report.critical_count} | - |")
    lines.append(f"| High | {report.high_count} | {sum(1 for f in report.findings if f.severity == Severity.HIGH and f.confidence >= CONFIDENCE_HIGH)} |")
    lines.append(f"| Medium | {report.medium_count} | {sum(1 for f in report.findings if f.severity == Severity.MEDIUM and f.confidence >= CONFIDENCE_HIGH)} |")
    lines.append(f"| Low | {report.low_count} | - |")
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

  # Show historical trends
  %(prog)s --mode trends --days 30

  # Enable LLM-assisted analysis
  %(prog)s --mode full --enable-llm

  # Record feedback on a finding
  %(prog)s --feedback false_positive --finding-id DRIFT-002-001
        """,
    )
    
    parser.add_argument(
        "--mode",
        choices=["pre-commit", "pr", "full", "trends", "feedback"],
        required=True,
        help="Audit mode (trends: show historical analysis, feedback: record feedback on findings)",
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
    
    parser.add_argument(
        "--min-confidence",
        type=float,
        default=CONFIDENCE_LOW,
        help=f"Minimum confidence threshold for findings (default: {CONFIDENCE_LOW})",
    )
    
    parser.add_argument(
        "--days",
        type=int,
        default=30,
        help="Number of days for historical trends (default: 30)",
    )
    
    parser.add_argument(
        "--enable-llm",
        action="store_true",
        help="Enable LLM-assisted analysis (requires vLLM endpoint)",
    )
    
    parser.add_argument(
        "--enable-feedback",
        action="store_true",
        default=True,  # ENABLED BY DEFAULT - apply learned FP adjustments
        help="Enable feedback-based confidence adjustments (default: enabled)",
    )
    
    parser.add_argument(
        "--disable-feedback",
        action="store_false",
        dest="enable_feedback",
        help="Disable feedback-based confidence adjustments",
    )
    
    parser.add_argument(
        "--feedback",
        choices=["false_positive", "true_positive", "fixed"],
        help="Record feedback type for a finding (use with --finding-id)",
    )
    
    parser.add_argument(
        "--finding-id",
        help="Finding ID to record feedback for (e.g., DRIFT-002-001)",
    )
    
    parser.add_argument(
        "--feedback-comment",
        default="",
        help="Optional comment for the feedback",
    )
    
    args = parser.parse_args()
    
    # Handle LLM flag
    global LLM_ENABLED
    if args.enable_llm:
        LLM_ENABLED = True
        print(f"LLM-assisted analysis enabled (endpoint: {LLM_ENDPOINT})")
    
    # Run appropriate audit mode
    if args.mode == "trends":
        # Historical trends mode
        trends = get_historical_trends(args.days)
        if "error" in trends:
            print(f"Error: {trends['error']}", file=sys.stderr)
            sys.exit(1)
        output = format_trends_output(trends)
        print(output)
        sys.exit(0)
    
    if args.mode == "feedback":
        # Feedback recording mode
        if not args.feedback or not args.finding_id:
            print("Error: --feedback and --finding-id required for feedback mode", file=sys.stderr)
            print("Example: --mode feedback --feedback false_positive --finding-id DRIFT-002-001", file=sys.stderr)
            sys.exit(1)
        
        # Create a minimal finding from the ID to record feedback
        init_feedback_db()
        
        # Parse finding ID to extract drift type
        drift_type_match = re.match(r'(DRIFT-\d+)', args.finding_id)
        drift_type_name = drift_type_match.group(1) if drift_type_match else "DRIFT_002"
        drift_type_name = drift_type_name.replace("-", "_")
        
        try:
            drift_type = DriftType[drift_type_name]
        except KeyError:
            drift_type = DriftType.DRIFT_002
        
        # Create placeholder finding
        finding = DriftFinding(
            id=args.finding_id,
            drift_type=drift_type,
            severity=Severity.MEDIUM,
            source_file="<recorded via CLI>",
            message=f"Feedback recorded for {args.finding_id}",
        )
        
        record_feedback(finding, args.feedback, args.feedback_comment)
        print(f"✅ Recorded feedback: {args.feedback} for {args.finding_id}")
        if args.feedback_comment:
            print(f"   Comment: {args.feedback_comment}")
        
        # Show current adjustment for this pattern
        adjustment = get_confidence_adjustment(finding)
        if adjustment < 1.0:
            print(f"   Confidence adjustment: {adjustment:.2f}x (based on historical feedback)")
        
        sys.exit(0)
    
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
    
    # Filter by minimum confidence
    if args.min_confidence > CONFIDENCE_LOW:
        report.findings = [f for f in report.findings if f.confidence >= args.min_confidence]
    
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


# =============================================================================
# LONG-TERM FEATURES: FEEDBACK LOOP (False Positive Tracking)
# =============================================================================

def init_feedback_db(db_path: str = FEEDBACK_DB_PATH):
    """Initialize SQLite database for feedback tracking."""
    db_dir = Path(db_path).parent
    db_dir.mkdir(parents=True, exist_ok=True)
    
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS feedback (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            finding_id TEXT NOT NULL,
            finding_hash TEXT NOT NULL,
            drift_type TEXT NOT NULL,
            source_file TEXT NOT NULL,
            feedback_type TEXT NOT NULL,  -- 'false_positive', 'true_positive', 'fixed'
            user_comment TEXT,
            commit_sha TEXT,
            created_at TEXT NOT NULL,
            UNIQUE(finding_hash, feedback_type)
        )
    """)
    
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS confidence_adjustments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            pattern_hash TEXT NOT NULL UNIQUE,
            drift_type TEXT NOT NULL,
            file_pattern TEXT,
            adjustment_factor REAL DEFAULT 1.0,
            sample_count INTEGER DEFAULT 0,
            false_positive_count INTEGER DEFAULT 0,
            last_updated TEXT NOT NULL
        )
    """)
    
    conn.commit()
    conn.close()


def compute_finding_hash(finding: DriftFinding) -> str:
    """Compute a stable hash for a finding to track across runs."""
    # Hash based on structural properties, not transient ones
    hashable = f"{finding.drift_type.name}:{finding.source_file}:{finding.message[:100]}"
    return hashlib.md5(hashable.encode()).hexdigest()[:16]


def record_feedback(finding: DriftFinding, feedback_type: str, comment: str = ""):
    """Record user feedback on a finding."""
    init_feedback_db()
    conn = sqlite3.connect(FEEDBACK_DB_PATH)
    cursor = conn.cursor()
    
    finding_hash = compute_finding_hash(finding)
    
    try:
        cursor.execute("""
            INSERT OR REPLACE INTO feedback 
            (finding_id, finding_hash, drift_type, source_file, feedback_type, user_comment, commit_sha, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, (
            finding.id,
            finding_hash,
            finding.drift_type.name,
            finding.source_file,
            feedback_type,
            comment,
            get_current_commit_sha(),
            datetime.now().isoformat(),
        ))
        
        # Update confidence adjustment based on feedback
        if feedback_type == "false_positive":
            update_confidence_adjustment(cursor, finding, is_false_positive=True)
        elif feedback_type == "true_positive":
            update_confidence_adjustment(cursor, finding, is_false_positive=False)
        
        conn.commit()
    finally:
        conn.close()


def update_confidence_adjustment(cursor: sqlite3.Cursor, finding: DriftFinding, is_false_positive: bool):
    """Update confidence adjustment factors based on feedback."""
    # Create pattern based on drift type and file pattern
    file_pattern = re.sub(r'[0-9]+', '*', finding.source_file)  # Generalize numbers
    pattern_hash = hashlib.md5(f"{finding.drift_type.name}:{file_pattern}".encode()).hexdigest()[:16]
    
    # Get existing adjustment
    cursor.execute("""
        SELECT sample_count, false_positive_count FROM confidence_adjustments
        WHERE pattern_hash = ?
    """, (pattern_hash,))
    row = cursor.fetchone()
    
    if row:
        sample_count = row[0] + 1
        fp_count = row[1] + (1 if is_false_positive else 0)
    else:
        sample_count = 1
        fp_count = 1 if is_false_positive else 0
    
    # Calculate adjustment factor: reduce confidence for patterns with high FP rate
    fp_rate = fp_count / sample_count if sample_count > 0 else 0
    adjustment = max(0.5, 1.0 - (fp_rate * 0.5))  # At most 50% reduction
    
    cursor.execute("""
        INSERT OR REPLACE INTO confidence_adjustments
        (pattern_hash, drift_type, file_pattern, adjustment_factor, sample_count, false_positive_count, last_updated)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    """, (
        pattern_hash,
        finding.drift_type.name,
        file_pattern,
        adjustment,
        sample_count,
        fp_count,
        datetime.now().isoformat(),
    ))


def get_confidence_adjustment(finding: DriftFinding) -> float:
    """Get confidence adjustment factor for a finding based on historical feedback."""
    if not Path(FEEDBACK_DB_PATH).exists():
        return 1.0
    
    try:
        conn = sqlite3.connect(FEEDBACK_DB_PATH)
        cursor = conn.cursor()
        
        file_pattern = re.sub(r'[0-9]+', '*', finding.source_file)
        pattern_hash = hashlib.md5(f"{finding.drift_type.name}:{file_pattern}".encode()).hexdigest()[:16]
        
        cursor.execute("""
            SELECT adjustment_factor FROM confidence_adjustments
            WHERE pattern_hash = ?
        """, (pattern_hash,))
        row = cursor.fetchone()
        
        conn.close()
        return row[0] if row else 1.0
    except sqlite3.Error:
        return 1.0


def apply_feedback_adjustments(findings: List[DriftFinding]) -> List[DriftFinding]:
    """Apply historical feedback adjustments to finding confidence scores."""
    for finding in findings:
        adjustment = get_confidence_adjustment(finding)
        finding.confidence *= adjustment
        if adjustment < 1.0:
            finding.evidence["feedback_adjustment"] = round(adjustment, 2)
    return findings


# =============================================================================
# LONG-TERM FEATURES: API CONTRACT DRIFT (DRIFT-008)
# =============================================================================

@dataclass
class APIEndpoint:
    """Represents an API endpoint from OpenAPI spec."""
    path: str
    method: str
    operation_id: str
    parameters: List[Dict] = field(default_factory=list)
    request_body_fields: Set[str] = field(default_factory=set)
    response_fields: Set[str] = field(default_factory=set)


def extract_openapi_endpoints(openapi_path: str) -> List[APIEndpoint]:
    """Extract endpoint definitions from OpenAPI YAML spec."""
    endpoints = []
    
    try:
        with open(openapi_path, "r") as f:
            spec = yaml.safe_load(f)
    except (FileNotFoundError, yaml.YAMLError):
        return endpoints
    
    paths = spec.get("paths", {})
    
    for path, path_item in paths.items():
        for method in ["get", "post", "put", "patch", "delete"]:
            if method not in path_item:
                continue
            
            operation = path_item[method]
            operation_id = operation.get("operationId", f"{method}_{path}")
            
            # Extract parameters
            params = operation.get("parameters", [])
            
            # Extract request body fields
            request_fields = set()
            request_body = operation.get("requestBody", {})
            if request_body:
                content = request_body.get("content", {})
                for content_type, content_spec in content.items():
                    schema = content_spec.get("schema", {})
                    request_fields.update(extract_schema_field_names_from_dict(schema))
            
            # Extract response fields
            response_fields = set()
            responses = operation.get("responses", {})
            for status_code, response in responses.items():
                content = response.get("content", {})
                for content_type, content_spec in content.items():
                    schema = content_spec.get("schema", {})
                    response_fields.update(extract_schema_field_names_from_dict(schema))
            
            endpoints.append(APIEndpoint(
                path=path,
                method=method.upper(),
                operation_id=operation_id,
                parameters=params,
                request_body_fields=request_fields,
                response_fields=response_fields,
            ))
    
    return endpoints


def extract_schema_field_names_from_dict(schema: Dict) -> Set[str]:
    """Extract field names from an inline schema definition."""
    fields = set()
    
    if "properties" in schema:
        fields.update(schema["properties"].keys())
        for prop_name, prop_schema in schema["properties"].items():
            if isinstance(prop_schema, dict):
                fields.update(extract_schema_field_names_from_dict(prop_schema))
    
    if "items" in schema and isinstance(schema["items"], dict):
        fields.update(extract_schema_field_names_from_dict(schema["items"]))
    
    if "$ref" in schema:
        # For refs, extract the definition name
        ref = schema["$ref"]
        if "/" in ref:
            fields.add(ref.split("/")[-1])
    
    return fields


# Track already-reported undocumented endpoints across OpenAPI specs to prevent duplicates
_reported_undocumented_endpoints: Set[Tuple[str, str]] = set()


def detect_api_contract_drift(
    openapi_path: str,
    code_paths: List[str],
    domain: str,
) -> List[DriftFinding]:
    """Detect drift between OpenAPI spec and implementation (DRIFT-008).
    
    FIXED: Deduplication - tracks reported undocumented endpoints to prevent duplicates
    when multiple OpenAPI specs share the same code paths.
    """
    global _reported_undocumented_endpoints
    findings = []
    
    if not Path(openapi_path).exists():
        return findings
    
    spec_endpoints = extract_openapi_endpoints(openapi_path)
    if not spec_endpoints:
        return findings
    
    # Extract route definitions from code
    code_routes = set()
    for code_path in code_paths:
        if not Path(code_path).exists():
            continue
        
        if code_path.endswith("/"):
            for py_file in Path(code_path).glob("**/*.py"):
                code_routes.update(extract_routes_from_code(str(py_file)))
        else:
            code_routes.update(extract_routes_from_code(code_path))
    
    # Compare spec endpoints with code routes
    spec_paths = {(e.path, e.method) for e in spec_endpoints}
    
    # Endpoints in spec but not in code
    missing_in_code = spec_paths - code_routes
    if missing_in_code:
        findings.append(DriftFinding(
            id=f"DRIFT-008-MISSING-{len(findings)+1:03d}",
            drift_type=DriftType.DRIFT_008,
            severity=Severity.HIGH,
            confidence=0.80,
            source_file=openapi_path,
            message=f"{len(missing_in_code)} API endpoints in spec not found in code",
            related_artifacts=[RelatedArtifact(
                path=code_paths[0] if code_paths else "",
                artifact_type="code",
                status="missing_endpoints",
                domain=domain,
            )],
            evidence={
                "missing_endpoints": [f"{m} {p}" for p, m in sorted(missing_in_code)[:10]],
            },
            remediation="Implement missing endpoints or update OpenAPI spec",
            blocking=True,
        ))
    
    # Endpoints in code but not in spec - DEDUPLICATION FIX
    extra_in_code = code_routes - spec_paths
    # Remove already-reported endpoints from previous OpenAPI spec comparisons
    new_undocumented = extra_in_code - _reported_undocumented_endpoints
    
    if new_undocumented:
        # Track these as reported to prevent duplicates
        _reported_undocumented_endpoints.update(new_undocumented)
        
        findings.append(DriftFinding(
            id=f"DRIFT-008-UNDOC-{len(findings)+1:03d}",
            drift_type=DriftType.DRIFT_008,
            severity=Severity.MEDIUM,
            confidence=0.75,
            source_file=code_paths[0] if code_paths else "",
            message=f"{len(new_undocumented)} API endpoints in code not documented in spec",
            related_artifacts=[RelatedArtifact(
                path=openapi_path,
                artifact_type="specification",
                status="missing_endpoints",
                domain=domain,
            )],
            evidence={
                "undocumented_endpoints": [f"{m} {p}" for p, m in sorted(new_undocumented)[:10]],
            },
            remediation="Document these endpoints in OpenAPI spec",
            blocking=False,
        ))
    
    return findings


def extract_routes_from_code(code_path: str) -> Set[Tuple[str, str]]:
    """Extract API route definitions from Python code."""
    routes = set()
    
    try:
        with open(code_path, "r") as f:
            content = f.read()
    except FileNotFoundError:
        return routes
    
    # Flask-style routes: @app.route('/path', methods=['GET'])
    flask_pattern = r'@\w+\.(?:route|get|post|put|patch|delete)\s*\(\s*["\']([^"\']+)["\']'
    for match in re.finditer(flask_pattern, content):
        path = match.group(1)
        # Determine method from decorator name
        method_match = re.search(r'@\w+\.(get|post|put|patch|delete|route)', match.group(0), re.IGNORECASE)
        if method_match:
            method = method_match.group(1).upper()
            if method == "ROUTE":
                method = "GET"  # Default
            routes.add((path, method))
    
    # FastAPI-style routes: @router.get('/path')
    fastapi_pattern = r'@\w+\.(get|post|put|patch|delete)\s*\(\s*["\']([^"\']+)["\']'
    for match in re.finditer(fastapi_pattern, content, re.IGNORECASE):
        method = match.group(1).upper()
        path = match.group(2)
        routes.add((path, method))
    
    return routes


# =============================================================================
# LONG-TERM FEATURES: DIFFERENTIAL ANALYSIS
# =============================================================================

@dataclass
class FileDiff:
    """Represents changes between two versions of a file."""
    file_path: str
    added_lines: List[Tuple[int, str]]
    removed_lines: List[Tuple[int, str]]
    added_fields: Set[str]
    removed_fields: Set[str]
    added_functions: Set[str]
    removed_functions: Set[str]


def get_file_diff(file_path: str, base_ref: str = "HEAD~1") -> Optional[FileDiff]:
    """Get detailed diff for a file between current and base ref."""
    try:
        # Get old content
        result = subprocess.run(
            ["git", "show", f"{base_ref}:{file_path}"],
            capture_output=True,
            text=True,
        )
        old_content = result.stdout if result.returncode == 0 else ""
        
        # Get new content
        try:
            with open(file_path, "r") as f:
                new_content = f.read()
        except FileNotFoundError:
            new_content = ""
        
        if not old_content and not new_content:
            return None
        
        # Compute line-level diff
        old_lines = old_content.splitlines(keepends=True)
        new_lines = new_content.splitlines(keepends=True)
        
        added_lines = []
        removed_lines = []
        
        diff_result = list(unified_diff(old_lines, new_lines, lineterm=''))
        line_num = 0
        for line in diff_result:
            if line.startswith('+') and not line.startswith('+++'):
                added_lines.append((line_num, line[1:].strip()))
            elif line.startswith('-') and not line.startswith('---'):
                removed_lines.append((line_num, line[1:].strip()))
            elif not line.startswith('@@'):
                line_num += 1
        
        # Extract structural changes for Python files
        added_fields = set()
        removed_fields = set()
        added_functions = set()
        removed_functions = set()
        
        if file_path.endswith('.py'):
            old_fields = extract_python_definitions(old_content)
            new_fields = extract_python_definitions(new_content)
            
            added_fields = new_fields['fields'] - old_fields['fields']
            removed_fields = old_fields['fields'] - new_fields['fields']
            added_functions = new_fields['functions'] - old_fields['functions']
            removed_functions = old_fields['functions'] - new_fields['functions']
        
        return FileDiff(
            file_path=file_path,
            added_lines=added_lines,
            removed_lines=removed_lines,
            added_fields=added_fields,
            removed_fields=removed_fields,
            added_functions=added_functions,
            removed_functions=removed_functions,
        )
    except subprocess.CalledProcessError:
        return None


def extract_python_definitions(content: str) -> Dict[str, Set[str]]:
    """Extract field and function definitions from Python code."""
    result = {"fields": set(), "functions": set(), "classes": set()}
    
    if not content:
        return result
    
    try:
        tree = ast.parse(content)
        
        for node in ast.walk(tree):
            if isinstance(node, ast.FunctionDef) or isinstance(node, ast.AsyncFunctionDef):
                result["functions"].add(node.name)
            elif isinstance(node, ast.ClassDef):
                result["classes"].add(node.name)
            elif isinstance(node, ast.Assign):
                for target in node.targets:
                    if isinstance(target, ast.Name):
                        result["fields"].add(target.id)
            elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
                result["fields"].add(node.target.id)
    except SyntaxError:
        pass
    
    return result


def analyze_differential_impact(
    changed_files: List[str],
    mapping_registry: Dict[str, Any],
) -> List[DriftFinding]:
    """Analyze the impact of changes using differential analysis."""
    findings = []
    
    for filepath in changed_files:
        diff = get_file_diff(filepath)
        if not diff:
            continue
        
        # High-impact changes: removed fields or functions
        if diff.removed_fields or diff.removed_functions:
            category = classify_file(filepath)
            domain = get_domain_for_file(filepath, mapping_registry)
            
            if diff.removed_fields:
                findings.append(DriftFinding(
                    id=f"DIFF-REMOVED-{len(findings)+1:03d}",
                    drift_type=DriftType.DRIFT_002 if category == "code" else DriftType.DRIFT_001,
                    severity=Severity.HIGH,
                    confidence=0.90,
                    source_file=filepath,
                    message=f"Breaking change: {len(diff.removed_fields)} field(s) removed",
                    evidence={
                        "removed_fields": sorted(list(diff.removed_fields))[:10],
                        "change_type": "breaking",
                    },
                    remediation="Ensure consumers of these fields are updated",
                    blocking=True,
                ))
            
            if diff.removed_functions:
                findings.append(DriftFinding(
                    id=f"DIFF-FUNC-{len(findings)+1:03d}",
                    drift_type=DriftType.DRIFT_003,
                    severity=Severity.MEDIUM,
                    confidence=0.85,
                    source_file=filepath,
                    message=f"{len(diff.removed_functions)} function(s) removed",
                    evidence={
                        "removed_functions": sorted(list(diff.removed_functions))[:10],
                    },
                    remediation="Ensure spec is updated if these were documented",
                    blocking=False,
                ))
    
    return findings


# =============================================================================
# LONG-TERM FEATURES: HISTORICAL TRENDS
# =============================================================================

def get_historical_trends(days: int = 30) -> Dict[str, Any]:
    """Analyze historical drift trends from audit logs."""
    log_dir = Path(AUDIT_LOG_DIR)
    if not log_dir.exists():
        return {"error": "No audit logs found"}
    
    cutoff = datetime.now() - timedelta(days=days)
    
    # Aggregate findings by type and date
    daily_counts = defaultdict(lambda: defaultdict(int))
    type_counts = defaultdict(int)
    severity_counts = defaultdict(int)
    total_findings = 0
    reports_analyzed = 0
    
    for log_file in sorted(log_dir.glob("*.yaml")):
        try:
            with open(log_file, "r") as f:
                report = yaml.safe_load(f)
            
            timestamp = datetime.fromisoformat(report.get("timestamp", ""))
            if timestamp < cutoff:
                continue
            
            reports_analyzed += 1
            date_key = timestamp.strftime("%Y-%m-%d")
            
            for finding in report.get("findings", []):
                drift_type = finding.get("type", "UNKNOWN")
                severity = finding.get("severity", "UNKNOWN")
                
                daily_counts[date_key][drift_type] += 1
                type_counts[drift_type] += 1
                severity_counts[severity] += 1
                total_findings += 1
        except (yaml.YAMLError, ValueError, KeyError):
            continue
    
    # Calculate trends
    dates = sorted(daily_counts.keys())
    if len(dates) >= 2:
        first_half = dates[:len(dates)//2]
        second_half = dates[len(dates)//2:]
        
        first_avg = sum(sum(daily_counts[d].values()) for d in first_half) / len(first_half) if first_half else 0
        second_avg = sum(sum(daily_counts[d].values()) for d in second_half) / len(second_half) if second_half else 0
        
        trend = "improving" if second_avg < first_avg else "worsening" if second_avg > first_avg else "stable"
        trend_pct = ((second_avg - first_avg) / first_avg * 100) if first_avg > 0 else 0
    else:
        trend = "insufficient_data"
        trend_pct = 0
    
    return {
        "period_days": days,
        "reports_analyzed": reports_analyzed,
        "total_findings": total_findings,
        "by_type": dict(type_counts),
        "by_severity": dict(severity_counts),
        "trend": trend,
        "trend_percentage": round(trend_pct, 1),
        "daily_summary": {d: dict(daily_counts[d]) for d in dates[-7:]},  # Last 7 days
    }


def format_trends_output(trends: Dict[str, Any]) -> str:
    """Format historical trends for display."""
    lines = []
    lines.append("=" * 80)
    lines.append("SPEC-DRIFT HISTORICAL TRENDS")
    lines.append("=" * 80)
    lines.append(f"Period: Last {trends.get('period_days', 30)} days")
    lines.append(f"Reports Analyzed: {trends.get('reports_analyzed', 0)}")
    lines.append(f"Total Findings: {trends.get('total_findings', 0)}")
    lines.append("-" * 40)
    
    lines.append("\nBy Type:")
    for drift_type, count in sorted(trends.get('by_type', {}).items()):
        lines.append(f"  {drift_type}: {count}")
    
    lines.append("\nBy Severity:")
    for severity, count in sorted(trends.get('by_severity', {}).items()):
        lines.append(f"  {severity}: {count}")
    
    lines.append("-" * 40)
    trend = trends.get('trend', 'unknown')
    trend_pct = trends.get('trend_percentage', 0)
    trend_icon = "📈" if trend == "worsening" else "📉" if trend == "improving" else "➡️"
    lines.append(f"\nTrend: {trend_icon} {trend.upper()} ({trend_pct:+.1f}%)")
    
    lines.append("\nLast 7 Days:")
    for date, counts in sorted(trends.get('daily_summary', {}).items()):
        total = sum(counts.values())
        lines.append(f"  {date}: {total} findings")
    
    lines.append("=" * 80)
    return "\n".join(lines)


# =============================================================================
# LONG-TERM FEATURES: BASELINE MECHANISM
# =============================================================================
# Compare current state against a "known good" baseline to detect drift

BASELINE_FILE_PATH = "docs/audit-logs/baseline.yaml"


@dataclass
class AuditBaseline:
    """Represents a known-good baseline state for comparison."""
    created_at: str
    commit_sha: str
    schema_field_counts: Dict[str, int]  # schema_path -> field count
    spec_field_counts: Dict[str, int]    # spec_path -> field count
    threshold_values: Dict[str, float]   # normalized_name -> value
    state_counts: Dict[str, int]         # domain -> state count
    api_endpoint_counts: Dict[str, int]  # openapi_path -> endpoint count


def save_baseline(baseline: AuditBaseline, path: str = BASELINE_FILE_PATH):
    """Save current state as baseline for future comparison."""
    baseline_dir = Path(path).parent
    baseline_dir.mkdir(parents=True, exist_ok=True)
    
    data = {
        "created_at": baseline.created_at,
        "commit_sha": baseline.commit_sha,
        "schema_field_counts": baseline.schema_field_counts,
        "spec_field_counts": baseline.spec_field_counts,
        "threshold_values": baseline.threshold_values,
        "state_counts": baseline.state_counts,
        "api_endpoint_counts": baseline.api_endpoint_counts,
    }
    
    with open(path, "w") as f:
        yaml.dump(data, f, default_flow_style=False)
    
    print(f"✅ Baseline saved to {path}")


def load_baseline(path: str = BASELINE_FILE_PATH) -> Optional[AuditBaseline]:
    """Load baseline from file."""
    if not Path(path).exists():
        return None
    
    try:
        with open(path, "r") as f:
            data = yaml.safe_load(f)
        
        return AuditBaseline(
            created_at=data.get("created_at", ""),
            commit_sha=data.get("commit_sha", ""),
            schema_field_counts=data.get("schema_field_counts", {}),
            spec_field_counts=data.get("spec_field_counts", {}),
            threshold_values=data.get("threshold_values", {}),
            state_counts=data.get("state_counts", {}),
            api_endpoint_counts=data.get("api_endpoint_counts", {}),
        )
    except (yaml.YAMLError, KeyError):
        return None


def capture_current_baseline(mapping_registry: Dict[str, Any]) -> AuditBaseline:
    """Capture current state as a baseline."""
    schema_counts = {}
    spec_counts = {}
    threshold_values = {}
    state_counts = {}
    api_counts = {}
    
    for domain_name, domain_config in mapping_registry.get("domains", {}).items():
        schema_root = domain_config.get("schema_root")
        spec_root = domain_config.get("spec_root")
        
        # Count schema fields
        if schema_root and Path(schema_root).exists():
            for schema_file in Path(schema_root).glob("*.schema.json"):
                fields = get_schema_field_names(str(schema_file))
                schema_counts[str(schema_file)] = len(fields)
        
        # Count spec fields
        if spec_root and Path(spec_root).exists():
            for spec_file in Path(spec_root).glob("**/*.tex"):
                fields = extract_spec_fields_from_latex(str(spec_file))
                spec_counts[str(spec_file)] = len(fields)
        
        # Extract thresholds from artifacts
        for artifact in domain_config.get("artifacts", []):
            spec_path = artifact.get("spec_path", artifact.get("path"))
            if spec_path and Path(spec_path).exists():
                thresholds = extract_thresholds_from_spec(spec_path)
                for t in thresholds:
                    if t.normalized_name:
                        threshold_values[t.normalized_name] = t.value
        
        # Count states
        for artifact in domain_config.get("artifacts", []):
            spec_path = artifact.get("spec_path", "")
            if spec_path and ("workflow" in spec_path.lower() or "state" in spec_path.lower()):
                if Path(spec_path).exists():
                    states, _ = extract_state_machine_from_spec(spec_path)
                    state_counts[domain_name] = len(states)
    
    # Count API endpoints
    openapi_dir = Path(OPENAPI_SPECS_DIR)
    if openapi_dir.exists():
        for openapi_file in openapi_dir.glob("*.yaml"):
            endpoints = extract_openapi_endpoints(str(openapi_file))
            api_counts[str(openapi_file)] = len(endpoints)
    
    return AuditBaseline(
        created_at=datetime.now().isoformat(),
        commit_sha=get_current_commit_sha() or "",
        schema_field_counts=schema_counts,
        spec_field_counts=spec_counts,
        threshold_values=threshold_values,
        state_counts=state_counts,
        api_endpoint_counts=api_counts,
    )


def compare_with_baseline(
    baseline: AuditBaseline,
    mapping_registry: Dict[str, Any],
) -> List[DriftFinding]:
    """Compare current state with baseline to detect drift.
    
    LONG-TERM: Enables detection of gradual drift by comparing against
    a known-good snapshot rather than just spec vs code at current moment.
    """
    findings = []
    current = capture_current_baseline(mapping_registry)
    
    # Compare schema field counts
    for schema_path, baseline_count in baseline.schema_field_counts.items():
        current_count = current.schema_field_counts.get(schema_path, 0)
        if current_count == 0:
            # Schema was removed
            findings.append(DriftFinding(
                id=f"BASELINE-SCHEMA-REMOVED-{len(findings)+1:03d}",
                drift_type=DriftType.DRIFT_001,
                severity=Severity.HIGH,
                confidence=0.95,
                source_file=schema_path,
                message=f"Schema removed since baseline (was {baseline_count} fields)",
                evidence={
                    "baseline_commit": baseline.commit_sha,
                    "baseline_count": baseline_count,
                    "current_count": 0,
                },
                remediation="Restore schema or update baseline if removal was intentional",
                blocking=True,
            ))
        elif abs(current_count - baseline_count) > 5:
            # Significant field count change
            direction = "added" if current_count > baseline_count else "removed"
            findings.append(DriftFinding(
                id=f"BASELINE-SCHEMA-DRIFT-{len(findings)+1:03d}",
                drift_type=DriftType.DRIFT_001,
                severity=Severity.MEDIUM,
                confidence=0.80,
                source_file=schema_path,
                message=f"Schema field count changed significantly: {current_count - baseline_count:+d} fields {direction}",
                evidence={
                    "baseline_commit": baseline.commit_sha,
                    "baseline_count": baseline_count,
                    "current_count": current_count,
                    "delta": current_count - baseline_count,
                },
                remediation="Review schema changes and update baseline if valid",
                blocking=False,
            ))
    
    # Check for new schemas not in baseline
    for schema_path, current_count in current.schema_field_counts.items():
        if schema_path not in baseline.schema_field_counts:
            findings.append(DriftFinding(
                id=f"BASELINE-SCHEMA-NEW-{len(findings)+1:03d}",
                drift_type=DriftType.DRIFT_001,
                severity=Severity.LOW,
                confidence=0.90,
                source_file=schema_path,
                message=f"New schema added since baseline ({current_count} fields)",
                evidence={
                    "baseline_commit": baseline.commit_sha,
                    "current_count": current_count,
                },
                remediation="Update baseline to include new schema",
                blocking=False,
            ))
    
    # Compare threshold values
    for name, baseline_value in baseline.threshold_values.items():
        current_value = current.threshold_values.get(name)
        if current_value is not None and abs(current_value - baseline_value) > 0.001:
            findings.append(DriftFinding(
                id=f"BASELINE-THRESHOLD-{len(findings)+1:03d}",
                drift_type=DriftType.DRIFT_006,
                severity=Severity.HIGH,
                confidence=0.90,
                source_file="<spec>",
                message=f"Threshold '{name}' changed: {baseline_value} → {current_value}",
                evidence={
                    "baseline_commit": baseline.commit_sha,
                    "baseline_value": baseline_value,
                    "current_value": current_value,
                },
                remediation="Verify threshold change was intentional, update baseline",
                blocking=True,
            ))
    
    # Compare state counts
    for domain, baseline_count in baseline.state_counts.items():
        current_count = current.state_counts.get(domain, 0)
        if current_count != baseline_count:
            direction = "added" if current_count > baseline_count else "removed"
            severity = Severity.HIGH if current_count < baseline_count else Severity.MEDIUM
            findings.append(DriftFinding(
                id=f"BASELINE-STATES-{len(findings)+1:03d}",
                drift_type=DriftType.DRIFT_007,
                severity=severity,
                confidence=0.85,
                source_file=f"<{domain}>",
                message=f"State count changed in {domain}: {baseline_count} → {current_count} ({current_count - baseline_count:+d} {direction})",
                evidence={
                    "baseline_commit": baseline.commit_sha,
                    "baseline_count": baseline_count,
                    "current_count": current_count,
                    "domain": domain,
                },
                remediation=f"Review state machine changes in {domain}, update baseline",
                blocking=current_count < baseline_count,
            ))
    
    # Compare API endpoint counts
    for api_path, baseline_count in baseline.api_endpoint_counts.items():
        current_count = current.api_endpoint_counts.get(api_path, 0)
        if current_count == 0:
            findings.append(DriftFinding(
                id=f"BASELINE-API-REMOVED-{len(findings)+1:03d}",
                drift_type=DriftType.DRIFT_008,
                severity=Severity.HIGH,
                confidence=0.95,
                source_file=api_path,
                message=f"OpenAPI spec removed since baseline (was {baseline_count} endpoints)",
                evidence={
                    "baseline_commit": baseline.commit_sha,
                    "baseline_count": baseline_count,
                },
                remediation="Restore API spec or update baseline",
                blocking=True,
            ))
        elif abs(current_count - baseline_count) > 3:
            direction = "added" if current_count > baseline_count else "removed"
            findings.append(DriftFinding(
                id=f"BASELINE-API-DRIFT-{len(findings)+1:03d}",
                drift_type=DriftType.DRIFT_008,
                severity=Severity.MEDIUM,
                confidence=0.80,
                source_file=api_path,
                message=f"API endpoint count changed: {current_count - baseline_count:+d} {direction}",
                evidence={
                    "baseline_commit": baseline.commit_sha,
                    "baseline_count": baseline_count,
                    "current_count": current_count,
                },
                remediation="Review API changes and update baseline",
                blocking=False,
            ))
    
    return findings


# =============================================================================
# LONG-TERM FEATURES: LLM-ASSISTED ANALYSIS (Optional)
# =============================================================================

def query_llm(prompt: str) -> Optional[str]:
    """Query vLLM endpoint for semantic analysis."""
    global LLM_ENABLED
    if not LLM_ENABLED:
        return None
    
    try:
        request_body = json.dumps({
            "model": LLM_MODEL,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": 500,
            "temperature": 0.1,
        }).encode()
        
        req = urllib.request.Request(
            LLM_ENDPOINT,
            data=request_body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        
        with urllib.request.urlopen(req, timeout=LLM_TIMEOUT) as response:
            result = json.loads(response.read().decode())
            return result.get("choices", [{}])[0].get("message", {}).get("content", "")
    except (urllib.error.URLError, json.JSONDecodeError, TimeoutError):
        return None


def llm_analyze_field_mismatch(code_field: str, schema_field: str, context: str) -> Optional[Dict]:
    """Use LLM to analyze if a field mismatch is intentional or a bug."""
    prompt = f"""Analyze this potential field name mismatch:
- Code uses: '{code_field}'
- Schema defines: '{schema_field}'
- Context: {context[:200]}

Is this likely:
1. A typo/bug (fields should match)
2. An intentional difference (different concepts)
3. A rename that needs sync

Respond with JSON: {{"verdict": "bug"|"intentional"|"rename", "confidence": 0.0-1.0, "reason": "..."}}"""

    response = query_llm(prompt)
    if response:
        try:
            # Extract JSON from response
            json_match = re.search(r'\{[^}]+\}', response)
            if json_match:
                return json.loads(json_match.group())
        except json.JSONDecodeError:
            pass
    return None


def enhance_findings_with_llm(findings: List[DriftFinding]) -> List[DriftFinding]:
    """Enhance findings with LLM analysis for better accuracy."""
    global LLM_ENABLED
    if not LLM_ENABLED:
        return findings
    
    for finding in findings:
        if finding.drift_type == DriftType.DRIFT_002:
            # Analyze field mismatches
            code_field = finding.evidence.get("code_field", "")
            schema_field = finding.evidence.get("similar_schema_field", "")
            
            if code_field and schema_field:
                analysis = llm_analyze_field_mismatch(
                    code_field, schema_field,
                    finding.evidence.get("context", "")
                )
                
                if analysis:
                    finding.evidence["llm_analysis"] = analysis
                    # Adjust confidence based on LLM verdict
                    if analysis.get("verdict") == "intentional":
                        finding.confidence *= 0.5
                        finding.severity = Severity.LOW
                    elif analysis.get("verdict") == "bug":
                        finding.confidence = min(0.95, finding.confidence * 1.2)
    
    return findings


if __name__ == "__main__":
    main()
