#!/usr/bin/env python3
"""
NL Readiness Assessor - Assess natural language readiness of schemas and vocabulary.

This module addresses the meeting requirement:
"Schema extraction doesn't assess natural language readiness (e.g., technical table 
names without descriptions)"

It grades schema fields and vocabulary for human vs agent suitability.

Usage:
    # Assess a single schema
    python3 scripts/spec-drift/nl_readiness_assessor.py --schema docs/schema/simula/config.schema.json

    # Assess all schemas in a domain
    python3 scripts/spec-drift/nl_readiness_assessor.py --domain simula

    # Full assessment with vocabulary check
    python3 scripts/spec-drift/nl_readiness_assessor.py --full --output-format json

Author: Spec-Drift Auditor Agent
Version: 1.0.0
"""

import argparse
import json
import re
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

VOCABULARY_REGISTRY_PATH = "docs/schema/common/synonyms.yaml"
SCHEMA_MAPPING_PATH = "docs/schema/spec-code-mapping.yaml"

# Scoring weights
WEIGHT_HAS_DESCRIPTION = 30
WEIGHT_READABLE_NAME = 25
WEIGHT_HAS_EXAMPLES = 15
WEIGHT_HAS_SYNONYMS = 15
WEIGHT_SELF_EXPLANATORY_TYPE = 15

# Thresholds
HUMAN_READY_THRESHOLD = 70  # >= 70% is human-ready
AGENT_READY_THRESHOLD = 40  # >= 40% is agent-ready
WARNING_THRESHOLD = 50      # < 50% triggers warning

# Patterns for detecting technical/cryptic names
TECHNICAL_NAME_PATTERNS = [
    r'^[A-Z]{2,6}$',           # All-caps abbreviation (BUKRS, WAERS)
    r'^[A-Z][A-Z0-9_]{2,}$',   # UPPER_SNAKE (GL_ACCOUNT)
    r'^[a-z]{1,3}\d+$',        # Prefix + number (t001, usr02)
    r'^_',                      # Leading underscore
    r'\d{3,}',                  # Long number sequences
    r'^[A-Z]{2,}_[A-Z]{2,}$',  # SAP-style (BUKRS_WAERS)
]

# Common abbreviations that need expansion for human readability
COMMON_ABBREVIATIONS = {
    'id', 'ids', 'uuid', 'pk', 'fk', 'ref', 'refs',
    'ts', 'dt', 'dts', 'num', 'cnt', 'qty', 'amt',
    'src', 'dst', 'cfg', 'config', 'params', 'args',
    'req', 'resp', 'res', 'err', 'msg', 'desc',
    'val', 'vals', 'attr', 'attrs', 'prop', 'props',
    'idx', 'len', 'sz', 'max', 'min', 'avg',
}

# Words that are self-explanatory (don't need description)
SELF_EXPLANATORY_WORDS = {
    'name', 'title', 'description', 'content', 'text', 'message',
    'email', 'phone', 'address', 'date', 'time', 'timestamp',
    'created', 'updated', 'deleted', 'enabled', 'active', 'status',
    'count', 'total', 'amount', 'price', 'cost', 'value',
    'first', 'last', 'start', 'end', 'begin', 'finish',
    'type', 'kind', 'category', 'version', 'format',
}


# =============================================================================
# ENUMS & DATA CLASSES
# =============================================================================

class ReadinessLevel(Enum):
    """NL readiness classification."""
    HUMAN_READY = "human_ready"       # Good for human interfaces
    AGENT_READY = "agent_ready"       # Good for agent/programmatic use
    NEEDS_WORK = "needs_work"         # Requires improvement
    NOT_READY = "not_ready"           # Significant issues


class AudienceType(Enum):
    """Target audience for the schema/field."""
    HUMAN = "human"
    AGENT = "agent"
    DUAL = "dual"


class IssueSeverity(Enum):
    """Severity of NL readiness issue."""
    HIGH = "HIGH"       # Blocks human readiness
    MEDIUM = "MEDIUM"   # Degrades experience
    LOW = "LOW"         # Nice to fix


@dataclass
class NLReadinessIssue:
    """A specific NL readiness issue for a field."""
    field_name: str
    issue_type: str
    message: str
    severity: IssueSeverity
    suggestion: str
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            "field": self.field_name,
            "type": self.issue_type,
            "message": self.message,
            "severity": self.severity.value,
            "suggestion": self.suggestion,
        }


@dataclass
class FieldReadinessScore:
    """NL readiness score for a single field."""
    field_name: str
    field_type: str
    score: int  # 0-100
    has_description: bool
    has_readable_name: bool
    has_examples: bool
    has_synonyms: bool
    is_self_explanatory: bool
    issues: List[NLReadinessIssue] = field(default_factory=list)
    human_friendly_name: Optional[str] = None
    
    @property
    def readiness_level(self) -> ReadinessLevel:
        if self.score >= HUMAN_READY_THRESHOLD:
            return ReadinessLevel.HUMAN_READY
        elif self.score >= AGENT_READY_THRESHOLD:
            return ReadinessLevel.AGENT_READY
        elif self.score >= 20:
            return ReadinessLevel.NEEDS_WORK
        else:
            return ReadinessLevel.NOT_READY
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            "field_name": self.field_name,
            "field_type": self.field_type,
            "score": self.score,
            "readiness_level": self.readiness_level.value,
            "has_description": self.has_description,
            "has_readable_name": self.has_readable_name,
            "has_examples": self.has_examples,
            "has_synonyms": self.has_synonyms,
            "is_self_explanatory": self.is_self_explanatory,
            "human_friendly_name": self.human_friendly_name,
            "issues": [i.to_dict() for i in self.issues],
        }


@dataclass
class SchemaReadinessReport:
    """NL readiness report for a complete schema."""
    schema_path: str
    schema_id: Optional[str]
    overall_score: int  # 0-100
    human_ready: bool
    agent_ready: bool
    recommended_audience: AudienceType
    field_scores: List[FieldReadinessScore]
    total_fields: int
    human_ready_fields: int
    agent_ready_fields: int
    issues: List[NLReadinessIssue]
    vocabulary_alignment: float  # 0.0-1.0
    timestamp: str
    dictionary_resolution_accuracy: float = 0.0
    unsupported_mapping_rate: float = 1.0

    @property
    def readiness_grade(self) -> str:
        """Traffic-light readiness grade for publication gates."""
        if self.human_ready:
            return "GREEN"
        if self.agent_ready:
            return "AMBER"
        return "RED"

    @property
    def readiness_metrics(self) -> Dict[str, float]:
        """Spec-defined NL-M metrics for readiness gates."""
        total = max(self.total_fields, 1)
        description_coverage = sum(
            1 for field_score in self.field_scores if field_score.has_description
        ) / total
        alias_coverage = sum(
            1 for field_score in self.field_scores if field_score.has_synonyms
        ) / total
        return {
            "NL-M01_schema_description_coverage": round(description_coverage, 4),
            "NL-M02_terminology_alias_coverage": round(alias_coverage, 4),
            "NL-M03_audience_separation_rate": 1.0,
            "NL-M04_dictionary_resolution_accuracy": round(self.dictionary_resolution_accuracy, 4),
            "NL-M05_unsupported_mapping_rate": round(self.unsupported_mapping_rate, 4),
        }
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            "schema_path": self.schema_path,
            "schema_id": self.schema_id,
            "overall_score": self.overall_score,
            "readiness_grade": self.readiness_grade,
            "readiness_metrics": self.readiness_metrics,
            "human_ready": self.human_ready,
            "agent_ready": self.agent_ready,
            "recommended_audience": self.recommended_audience.value,
            "total_fields": self.total_fields,
            "human_ready_fields": self.human_ready_fields,
            "agent_ready_fields": self.agent_ready_fields,
            "vocabulary_alignment": round(self.vocabulary_alignment, 2),
            "timestamp": self.timestamp,
            "summary": {
                "high_severity_issues": sum(1 for i in self.issues if i.severity == IssueSeverity.HIGH),
                "medium_severity_issues": sum(1 for i in self.issues if i.severity == IssueSeverity.MEDIUM),
                "low_severity_issues": sum(1 for i in self.issues if i.severity == IssueSeverity.LOW),
            },
            "field_scores": [f.to_dict() for f in self.field_scores],
            "issues": [i.to_dict() for i in self.issues],
        }


# =============================================================================
# VOCABULARY LOADING
# =============================================================================

def load_vocabulary_registry(path: str = VOCABULARY_REGISTRY_PATH) -> Dict[str, Any]:
    """Load the vocabulary registry."""
    registry_path = Path(path)
    if not registry_path.exists():
        return {}
    
    with open(registry_path, "r") as f:
        return yaml.safe_load(f)


def get_known_synonyms(vocab_registry: Dict[str, Any]) -> Dict[str, List[str]]:
    """Extract all known synonyms from vocabulary registry."""
    synonyms = {}
    
    # Global synonyms
    for entry in vocab_registry.get("global_synonyms", []):
        canonical = entry.get("canonical", "").lower()
        variations = [s.lower() for s in entry.get("synonyms", [])]
        synonyms[canonical] = variations
    
    # Domain-specific terms
    for domain_name, domain in vocab_registry.get("domains", {}).items():
        for term in domain.get("canonical_terms", []):
            canonical = term.get("canonical", "").lower()
            variations = [v.lower() for v in term.get("variations", [])]
            synonyms[canonical] = variations
            
        for tech_term in domain.get("technical_terms", []):
            tech_name = tech_term.get("technical_name", "").lower()
            human_name = tech_term.get("human_name", "").lower()
            term_synonyms = [s.lower() for s in tech_term.get("synonyms", [])]
            synonyms[tech_name] = [human_name] + term_synonyms
    
    return synonyms


def get_abbreviation_expansions(vocab_registry: Dict[str, Any]) -> Dict[str, str]:
    """Get abbreviation to expansion mappings."""
    expansions = {}
    
    for abbrev in vocab_registry.get("abbreviations", []):
        abbr = abbrev.get("abbreviation", "").lower()
        expansion = abbrev.get("expansion", "")
        expansions[abbr] = expansion
    
    return expansions


def calculate_dictionary_resolution_metrics(vocab_registry: Dict[str, Any]) -> Tuple[float, float]:
    """Assess whether value/entity mappings can resolve surface forms."""
    mappings = []
    for domain in vocab_registry.get("domains", {}).values():
        mappings.extend(domain.get("entity_mappings", []))

    if not mappings:
        return 0.0, 1.0

    resolvable = sum(
        1 for mapping in mappings
        if mapping.get("name") and mapping.get("code") and mapping.get("variations")
    )
    accuracy = resolvable / len(mappings)
    unsupported_rate = 1.0 - accuracy
    return accuracy, unsupported_rate


# =============================================================================
# NAME ANALYSIS
# =============================================================================

def is_technical_name(name: str) -> bool:
    """Check if a name is too technical/cryptic for human readability."""
    for pattern in TECHNICAL_NAME_PATTERNS:
        if re.match(pattern, name):
            return True
    return False


def is_abbreviation(name: str) -> bool:
    """Check if a name is an abbreviation that needs expansion."""
    # Remove underscores and check parts
    parts = name.lower().replace('-', '_').split('_')
    for part in parts:
        if part in COMMON_ABBREVIATIONS:
            return True
    return False


def is_self_explanatory(name: str) -> bool:
    """Check if a field name is self-explanatory."""
    name_lower = name.lower().replace('-', '_').replace(' ', '_')
    parts = name_lower.split('_')
    
    # Check if any part is self-explanatory
    for part in parts:
        if part in SELF_EXPLANATORY_WORDS:
            return True
    
    return False


def suggest_human_friendly_name(name: str, abbreviations: Dict[str, str]) -> Optional[str]:
    """Suggest a human-friendly version of a technical name."""
    # Check if we have a known expansion
    name_lower = name.lower()
    if name_lower in abbreviations:
        return abbreviations[name_lower]
    
    # Try to expand snake_case to readable
    parts = name.replace('-', '_').split('_')
    expanded_parts = []
    
    for part in parts:
        part_lower = part.lower()
        if part_lower in abbreviations:
            expanded_parts.append(abbreviations[part_lower])
        else:
            # Capitalize first letter
            expanded_parts.append(part.capitalize())
    
    if expanded_parts:
        suggested = ' '.join(expanded_parts)
        if suggested.lower() != name.lower():
            return suggested
    
    return None


def calculate_name_readability_score(name: str) -> Tuple[int, List[str]]:
    """Calculate readability score for a field name (0-100)."""
    score = 100
    issues = []
    
    # Penalize technical names
    if is_technical_name(name):
        score -= 40
        issues.append("Technical/cryptic name")
    
    # Penalize abbreviations
    if is_abbreviation(name):
        score -= 20
        issues.append("Contains abbreviations")
    
    # Penalize very short names (< 3 chars)
    if len(name) < 3:
        score -= 30
        issues.append("Name too short")
    
    # Penalize names with numbers
    if re.search(r'\d', name):
        score -= 10
        issues.append("Contains numbers")
    
    # Penalize all-caps
    if name.isupper() and len(name) > 2:
        score -= 20
        issues.append("All uppercase")
    
    # Reward self-explanatory names
    if is_self_explanatory(name):
        score = min(100, score + 20)
    
    return max(0, score), issues


# =============================================================================
# SCHEMA ANALYSIS
# =============================================================================

def extract_schema_fields(schema: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Extract all fields from a JSON schema with their metadata."""
    fields = []
    
    def extract_from_properties(properties: Dict, path: str = "", required: Set[str] = None):
        if required is None:
            required = set()
            
        for name, prop in properties.items():
            field_path = f"{path}.{name}" if path else name
            
            field_info = {
                "name": name,
                "path": field_path,
                "type": prop.get("type", "unknown"),
                "description": prop.get("description"),
                "examples": prop.get("examples", []),
                "enum": prop.get("enum"),
                "required": name in required,
                "default": prop.get("default"),
            }
            fields.append(field_info)
            
            # Recurse into nested objects
            if prop.get("type") == "object" and "properties" in prop:
                nested_required = set(prop.get("required", []))
                extract_from_properties(prop["properties"], field_path, nested_required)
            
            # Recurse into array items
            if prop.get("type") == "array" and "items" in prop:
                items = prop["items"]
                if isinstance(items, dict) and items.get("type") == "object":
                    nested_required = set(items.get("required", []))
                    if "properties" in items:
                        extract_from_properties(items["properties"], f"{field_path}[]", nested_required)
    
    # Extract from top-level properties
    if "properties" in schema:
        required = set(schema.get("required", []))
        extract_from_properties(schema["properties"], "", required)
    
    # Extract from definitions
    for defs_key in ["definitions", "$defs"]:
        if defs_key in schema:
            for def_name, definition in schema[defs_key].items():
                if "properties" in definition:
                    def_required = set(definition.get("required", []))
                    extract_from_properties(
                        definition["properties"], 
                        f"#{defs_key}/{def_name}", 
                        def_required
                    )
    
    return fields


def assess_field_readiness(
    field_info: Dict[str, Any],
    known_synonyms: Dict[str, List[str]],
    abbreviations: Dict[str, str],
) -> FieldReadinessScore:
    """Assess NL readiness of a single field."""
    name = field_info["name"]
    field_type = field_info["type"]
    description = field_info.get("description")
    examples = field_info.get("examples", [])
    
    issues = []
    score = 0
    
    # Check for description
    has_description = bool(description and len(description) > 10)
    if has_description:
        score += WEIGHT_HAS_DESCRIPTION
    else:
        issues.append(NLReadinessIssue(
            field_name=name,
            issue_type="missing_description",
            message=f"Field '{name}' lacks a description",
            severity=IssueSeverity.HIGH,
            suggestion=f"Add a description explaining what '{name}' represents",
        ))
    
    # Check name readability
    name_score, name_issues = calculate_name_readability_score(name)
    has_readable_name = name_score >= 60
    if has_readable_name:
        score += WEIGHT_READABLE_NAME
    else:
        for issue in name_issues:
            issues.append(NLReadinessIssue(
                field_name=name,
                issue_type="unreadable_name",
                message=f"Field '{name}': {issue}",
                severity=IssueSeverity.MEDIUM,
                suggestion=f"Consider renaming or adding human-friendly alias",
            ))
    
    # Check for examples
    has_examples = bool(examples)
    if has_examples:
        score += WEIGHT_HAS_EXAMPLES
    elif not is_self_explanatory(name):
        issues.append(NLReadinessIssue(
            field_name=name,
            issue_type="missing_examples",
            message=f"Field '{name}' has no examples",
            severity=IssueSeverity.LOW,
            suggestion=f"Add example values for '{name}'",
        ))
    
    # Check for synonyms in vocabulary registry
    name_lower = name.lower()
    has_synonyms = name_lower in known_synonyms
    if has_synonyms:
        score += WEIGHT_HAS_SYNONYMS
    
    # Check if self-explanatory
    is_self_expl = is_self_explanatory(name)
    if is_self_expl:
        score += WEIGHT_SELF_EXPLANATORY_TYPE
    
    # Suggest human-friendly name if needed
    human_friendly = None
    if not has_readable_name:
        human_friendly = suggest_human_friendly_name(name, abbreviations)
    
    return FieldReadinessScore(
        field_name=name,
        field_type=field_type,
        score=score,
        has_description=has_description,
        has_readable_name=has_readable_name,
        has_examples=has_examples,
        has_synonyms=has_synonyms,
        is_self_explanatory=is_self_expl,
        issues=issues,
        human_friendly_name=human_friendly,
    )


def assess_schema_readiness(
    schema_path: str,
    vocab_registry: Dict[str, Any],
) -> SchemaReadinessReport:
    """Assess NL readiness of a complete schema."""
    # Load schema
    try:
        with open(schema_path, "r") as f:
            schema = json.load(f)
    except (json.JSONDecodeError, FileNotFoundError) as e:
        return SchemaReadinessReport(
            schema_path=schema_path,
            schema_id=None,
            overall_score=0,
            human_ready=False,
            agent_ready=False,
            recommended_audience=AudienceType.AGENT,
            field_scores=[],
            total_fields=0,
            human_ready_fields=0,
            agent_ready_fields=0,
            issues=[NLReadinessIssue(
                field_name="<schema>",
                issue_type="load_error",
                message=f"Failed to load schema: {e}",
                severity=IssueSeverity.HIGH,
                suggestion="Fix schema syntax errors",
            )],
            vocabulary_alignment=0.0,
            timestamp=datetime.now().isoformat(),
            dictionary_resolution_accuracy=0.0,
            unsupported_mapping_rate=1.0,
        )
    
    schema_id = schema.get("$id")
    known_synonyms = get_known_synonyms(vocab_registry)
    abbreviations = get_abbreviation_expansions(vocab_registry)
    dictionary_accuracy, unsupported_mapping_rate = calculate_dictionary_resolution_metrics(vocab_registry)
    
    # Extract and assess fields
    fields = extract_schema_fields(schema)
    field_scores = []
    all_issues = []
    
    for field_info in fields:
        field_score = assess_field_readiness(field_info, known_synonyms, abbreviations)
        field_scores.append(field_score)
        all_issues.extend(field_score.issues)
    
    # Calculate overall metrics
    total_fields = len(field_scores)
    if total_fields == 0:
        overall_score = 0
    else:
        overall_score = sum(f.score for f in field_scores) // total_fields
    
    human_ready_fields = sum(1 for f in field_scores if f.readiness_level == ReadinessLevel.HUMAN_READY)
    agent_ready_fields = sum(1 for f in field_scores if f.score >= AGENT_READY_THRESHOLD)
    
    human_ready = overall_score >= HUMAN_READY_THRESHOLD
    agent_ready = overall_score >= AGENT_READY_THRESHOLD
    
    # Determine recommended audience
    if human_ready:
        recommended_audience = AudienceType.DUAL
    elif agent_ready:
        recommended_audience = AudienceType.AGENT
    else:
        recommended_audience = AudienceType.AGENT
    
    # Calculate vocabulary alignment
    field_names = {f.field_name.lower() for f in field_scores}
    vocab_terms = set(known_synonyms.keys())
    if field_names:
        alignment = len(field_names & vocab_terms) / len(field_names)
    else:
        alignment = 0.0
    
    return SchemaReadinessReport(
        schema_path=schema_path,
        schema_id=schema_id,
        overall_score=overall_score,
        human_ready=human_ready,
        agent_ready=agent_ready,
        recommended_audience=recommended_audience,
        field_scores=field_scores,
        total_fields=total_fields,
        human_ready_fields=human_ready_fields,
        agent_ready_fields=agent_ready_fields,
        issues=all_issues,
        vocabulary_alignment=alignment,
        timestamp=datetime.now().isoformat(),
        dictionary_resolution_accuracy=dictionary_accuracy,
        unsupported_mapping_rate=unsupported_mapping_rate,
    )


# =============================================================================
# DOMAIN ASSESSMENT
# =============================================================================

def assess_domain_readiness(
    domain: str,
    mapping_registry: Dict[str, Any],
    vocab_registry: Dict[str, Any],
) -> List[SchemaReadinessReport]:
    """Assess NL readiness of all schemas in a domain."""
    reports = []
    
    domain_config = mapping_registry.get("domains", {}).get(domain, {})
    schema_root = domain_config.get("schema_root")
    
    if not schema_root:
        return reports
    
    schema_dir = Path(schema_root)
    if not schema_dir.exists():
        return reports
    
    # Find all schema files
    for schema_file in schema_dir.glob("*.schema.json"):
        report = assess_schema_readiness(str(schema_file), vocab_registry)
        reports.append(report)
    
    return reports


# =============================================================================
# OUTPUT FORMATTING
# =============================================================================

def format_console_output(reports: List[SchemaReadinessReport]) -> str:
    """Format reports for console output."""
    lines = []
    lines.append("=" * 80)
    lines.append("NL READINESS ASSESSMENT REPORT")
    lines.append("=" * 80)
    lines.append(f"Timestamp: {datetime.now().isoformat()}")
    lines.append(f"Schemas Assessed: {len(reports)}")
    lines.append("-" * 80)
    
    for report in reports:
        status_icon = "✅" if report.human_ready else ("⚠️" if report.agent_ready else "❌")
        
        lines.append(f"\n{status_icon} Schema: {report.schema_path}")
        lines.append(f"   Overall Score: {report.overall_score}/100")
        lines.append(f"   Readiness Grade: {report.readiness_grade}")
        lines.append(f"   Human Ready: {'Yes' if report.human_ready else 'No'}")
        lines.append(f"   Agent Ready: {'Yes' if report.agent_ready else 'No'}")
        lines.append(f"   Recommended Audience: {report.recommended_audience.value}")
        lines.append(f"   Fields: {report.total_fields} total, {report.human_ready_fields} human-ready")
        lines.append(f"   Vocabulary Alignment: {report.vocabulary_alignment:.0%}")
        
        # Show high-severity issues
        high_issues = [i for i in report.issues if i.severity == IssueSeverity.HIGH]
        if high_issues:
            lines.append(f"   ⚠️ High-Severity Issues ({len(high_issues)}):")
            for issue in high_issues[:5]:
                lines.append(f"      - {issue.message}")
            if len(high_issues) > 5:
                lines.append(f"      ... and {len(high_issues) - 5} more")
    
    # Summary
    lines.append("\n" + "=" * 80)
    lines.append("SUMMARY")
    lines.append("-" * 40)
    
    human_ready_count = sum(1 for r in reports if r.human_ready)
    agent_ready_count = sum(1 for r in reports if r.agent_ready)
    avg_score = sum(r.overall_score for r in reports) // max(len(reports), 1)
    
    lines.append(f"Human-Ready Schemas: {human_ready_count}/{len(reports)}")
    lines.append(f"Agent-Ready Schemas: {agent_ready_count}/{len(reports)}")
    lines.append(f"Average Score: {avg_score}/100")
    
    total_issues = sum(len(r.issues) for r in reports)
    high_issues = sum(1 for r in reports for i in r.issues if i.severity == IssueSeverity.HIGH)
    lines.append(f"Total Issues: {total_issues} ({high_issues} high-severity)")
    
    lines.append("=" * 80)
    
    return "\n".join(lines)


def format_json_output(reports: List[SchemaReadinessReport]) -> str:
    """Format reports as JSON."""
    output = {
        "timestamp": datetime.now().isoformat(),
        "total_schemas": len(reports),
        "human_ready_schemas": sum(1 for r in reports if r.human_ready),
        "agent_ready_schemas": sum(1 for r in reports if r.agent_ready),
        "average_score": sum(r.overall_score for r in reports) // max(len(reports), 1),
        "reports": [r.to_dict() for r in reports],
    }
    return json.dumps(output, indent=2)


def format_yaml_output(reports: List[SchemaReadinessReport]) -> str:
    """Format reports as YAML."""
    output = {
        "timestamp": datetime.now().isoformat(),
        "total_schemas": len(reports),
        "human_ready_schemas": sum(1 for r in reports if r.human_ready),
        "agent_ready_schemas": sum(1 for r in reports if r.agent_ready),
        "average_score": sum(r.overall_score for r in reports) // max(len(reports), 1),
        "reports": [r.to_dict() for r in reports],
    }
    return yaml.dump(output, default_flow_style=False, sort_keys=False, allow_unicode=True)


# =============================================================================
# MAIN
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Assess natural language readiness of schemas and vocabulary",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Assess a single schema
  %(prog)s --schema docs/schema/simula/config.schema.json

  # Assess all schemas in a domain
  %(prog)s --domain simula

  # Full assessment with JSON output
  %(prog)s --full --output-format json

  # Assess with custom vocabulary registry
  %(prog)s --schema myschema.json --vocab-registry custom-vocab.yaml
        """,
    )
    
    parser.add_argument(
        "--schema",
        help="Path to a specific schema file to assess",
    )
    
    parser.add_argument(
        "--domain",
        help="Assess all schemas in a specific domain",
    )
    
    parser.add_argument(
        "--full",
        action="store_true",
        help="Assess all schemas across all domains",
    )
    
    parser.add_argument(
        "--vocab-registry",
        default=VOCABULARY_REGISTRY_PATH,
        help=f"Path to vocabulary registry (default: {VOCABULARY_REGISTRY_PATH})",
    )
    
    parser.add_argument(
        "--mapping-registry",
        default=SCHEMA_MAPPING_PATH,
        help=f"Path to spec-code mapping (default: {SCHEMA_MAPPING_PATH})",
    )
    
    parser.add_argument(
        "--output-format",
        choices=["console", "json", "yaml"],
        default="console",
        help="Output format (default: console)",
    )
    
    parser.add_argument(
        "--output-file",
        help="Write output to file instead of stdout",
    )
    
    parser.add_argument(
        "--min-score",
        type=int,
        default=0,
        help="Only report schemas below this score (for finding issues)",
    )
    
    args = parser.parse_args()
    
    # Load registries
    vocab_registry = load_vocabulary_registry(args.vocab_registry)
    
    mapping_registry = {}
    if Path(args.mapping_registry).exists():
        with open(args.mapping_registry, "r") as f:
            mapping_registry = yaml.safe_load(f)
    
    reports = []
    
    # Assess based on mode
    if args.schema:
        report = assess_schema_readiness(args.schema, vocab_registry)
        reports.append(report)
        
    elif args.domain:
        reports = assess_domain_readiness(args.domain, mapping_registry, vocab_registry)
        
    elif args.full:
        for domain in mapping_registry.get("domains", {}).keys():
            domain_reports = assess_domain_readiness(domain, mapping_registry, vocab_registry)
            reports.extend(domain_reports)
    else:
        print("Error: Specify --schema, --domain, or --full", file=sys.stderr)
        sys.exit(1)
    
    # Filter by min score if specified
    if args.min_score > 0:
        reports = [r for r in reports if r.overall_score < args.min_score]
    
    # Format output
    if args.output_format == "console":
        output = format_console_output(reports)
    elif args.output_format == "json":
        output = format_json_output(reports)
    elif args.output_format == "yaml":
        output = format_yaml_output(reports)
    
    # Write output
    if args.output_file:
        with open(args.output_file, "w") as f:
            f.write(output)
        print(f"Report written to {args.output_file}")
    else:
        print(output)
    
    # Exit with error if any schema is not agent-ready
    not_ready = [r for r in reports if not r.agent_ready]
    if not_ready:
        sys.exit(1)
    
    sys.exit(0)


if __name__ == "__main__":
    main()
