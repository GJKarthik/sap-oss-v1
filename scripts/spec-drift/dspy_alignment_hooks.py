#!/usr/bin/env python3
"""
DSPy Alignment Hooks - Stub for future DSPy prompt optimization integration.

This module addresses the meeting requirement:
"Recommend prompt assessment metrics, future integration with tools like DSPy 
to align prompts with training vocabulary."

DSPy (Declarative Self-improving Python) is a framework for optimizing LM prompts
and weights. This stub provides hooks for:
- Vocabulary alignment checking before prompt execution
- Hallucination probability estimation
- Prompt optimization suggestions

Usage:
    # Check prompt alignment
    python3 scripts/spec-drift/dspy_alignment_hooks.py --check "Show me BUKRS 1000"

    # Estimate hallucination risk
    python3 scripts/spec-drift/dspy_alignment_hooks.py --risk "What is India revenue?"

    # Generate alignment report
    python3 scripts/spec-drift/dspy_alignment_hooks.py --report prompts.jsonl

Status: STUB - Full DSPy integration requires runtime LLM connection

Author: Spec-Drift Auditor Agent
Version: 1.0.0 (Stub)
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

# Risk thresholds
LOW_RISK_THRESHOLD = 0.20
MEDIUM_RISK_THRESHOLD = 0.50
HIGH_RISK_THRESHOLD = 0.75

# Common hallucination patterns
HALLUCINATION_RISK_PATTERNS = [
    # Entity confusion (India vs IN)
    (r'\b(India|China|Japan|Singapore|Hong Kong)\b(?!.*\b(IN|CN|JP|SG|HK)\b)', 
     "entity_name_without_code", 0.3),
    
    # Ambiguous time references
    (r'\b(last|this|next)\s+(month|year|quarter)\b(?!.*\d{4})', 
     "ambiguous_time_reference", 0.2),
    
    # Unqualified aggregations
    (r'\b(total|sum|average|count)\b(?!.*\b(by|for|of)\b)', 
     "unqualified_aggregation", 0.15),
    
    # Missing context for comparisons
    (r'\b(more|less|higher|lower|greater|smaller)\b(?!.*\b(than|compared)\b)', 
     "missing_comparison_context", 0.2),
    
    # Vague entity references
    (r'\b(the company|the customer|the vendor)\b(?!.*\b(code|id|number)\b)', 
     "vague_entity_reference", 0.25),
    
    # Currency ambiguity
    (r'\$\d+|\d+\s*(dollars?|euros?|yen|yuan)(?!.*\b(USD|EUR|JPY|CNY)\b)', 
     "ambiguous_currency", 0.2),
    
    # Unqualified "all" queries
    (r'\b(all|every|each)\s+(customer|vendor|company|account)s?\b', 
     "potentially_large_result_set", 0.1),
]

# Vocabulary alignment indicators
ALIGNMENT_INDICATORS = {
    "uses_canonical_terms": 0.2,       # Uses terms from vocabulary registry
    "uses_entity_codes": 0.15,         # Uses codes instead of names
    "has_explicit_filters": 0.15,      # Has clear WHERE conditions
    "has_time_bounds": 0.1,            # Has explicit date/time range
    "uses_registered_synonyms": 0.1,   # Uses registered synonyms correctly
    "avoids_ambiguity": 0.15,          # Avoids ambiguous patterns
    "proper_aggregation_scope": 0.15,  # Aggregations have GROUP BY context
}


# =============================================================================
# ENUMS & DATA CLASSES
# =============================================================================

class RiskLevel(Enum):
    """Hallucination risk level."""
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"
    CRITICAL = "critical"


class AlignmentStatus(Enum):
    """Vocabulary alignment status."""
    ALIGNED = "aligned"
    PARTIAL = "partial"
    MISALIGNED = "misaligned"
    UNKNOWN = "unknown"


@dataclass
class HallucinationRiskAssessment:
    """Assessment of hallucination risk for a prompt."""
    prompt: str
    overall_risk: float  # 0.0 - 1.0
    risk_level: RiskLevel
    risk_factors: List[Dict[str, Any]]
    suggestions: List[str]
    alignment_score: float  # 0.0 - 1.0
    alignment_status: AlignmentStatus
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            "prompt": self.prompt,
            "overall_risk": round(self.overall_risk, 3),
            "risk_level": self.risk_level.value,
            "risk_factors": self.risk_factors,
            "suggestions": self.suggestions,
            "alignment_score": round(self.alignment_score, 3),
            "alignment_status": self.alignment_status.value,
        }


@dataclass
class DSPyOptimizationSuggestion:
    """Suggestion for DSPy prompt optimization."""
    original_prompt: str
    suggested_prompt: str
    improvement_type: str
    expected_improvement: float
    rationale: str
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            "original_prompt": self.original_prompt,
            "suggested_prompt": self.suggested_prompt,
            "improvement_type": self.improvement_type,
            "expected_improvement": round(self.expected_improvement, 3),
            "rationale": self.rationale,
        }


@dataclass
class AlignmentReport:
    """Alignment report for a batch of prompts."""
    total_prompts: int
    aligned_count: int
    partial_count: int
    misaligned_count: int
    average_risk: float
    high_risk_prompts: int
    assessments: List[HallucinationRiskAssessment]
    optimization_suggestions: List[DSPyOptimizationSuggestion]
    timestamp: str
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            "total_prompts": self.total_prompts,
            "aligned_count": self.aligned_count,
            "partial_count": self.partial_count,
            "misaligned_count": self.misaligned_count,
            "average_risk": round(self.average_risk, 3),
            "high_risk_prompts": self.high_risk_prompts,
            "alignment_rate": round(self.aligned_count / max(self.total_prompts, 1), 3),
            "timestamp": self.timestamp,
            "assessments": [a.to_dict() for a in self.assessments],
            "optimization_suggestions": [s.to_dict() for s in self.optimization_suggestions[:10]],
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


def get_canonical_terms(vocab_registry: Dict[str, Any]) -> Set[str]:
    """Get all canonical terms from registry."""
    terms = set()
    
    for entry in vocab_registry.get("global_synonyms", []):
        terms.add(entry.get("canonical", "").lower())
    
    for domain in vocab_registry.get("domains", {}).values():
        for term in domain.get("canonical_terms", []):
            terms.add(term.get("canonical", "").lower())
            for form in term.get("training_forms", []):
                terms.add(form.lower())
    
    return terms


def get_entity_mappings(vocab_registry: Dict[str, Any]) -> Dict[str, str]:
    """Get entity name to code mappings."""
    mappings = {}
    
    for domain in vocab_registry.get("domains", {}).values():
        for entity in domain.get("entity_mappings", []):
            name = entity.get("name", "").lower()
            code = entity.get("code", "")
            if name and code:
                mappings[name] = code
                for var in entity.get("variations", []):
                    mappings[var.lower()] = code
    
    return mappings


def get_synonym_map(vocab_registry: Dict[str, Any]) -> Dict[str, str]:
    """Get synonym to canonical term mappings."""
    synonyms = {}
    
    for entry in vocab_registry.get("global_synonyms", []):
        canonical = entry.get("canonical", "")
        for syn in entry.get("synonyms", []):
            synonyms[syn.lower()] = canonical
    
    return synonyms


# =============================================================================
# RISK ASSESSMENT
# =============================================================================

def assess_hallucination_risk(
    prompt: str,
    vocab_registry: Dict[str, Any],
) -> HallucinationRiskAssessment:
    """Assess hallucination risk for a prompt."""
    risk_factors = []
    total_risk = 0.0
    suggestions = []
    
    # Check hallucination patterns
    for pattern, risk_type, risk_weight in HALLUCINATION_RISK_PATTERNS:
        matches = re.findall(pattern, prompt, re.IGNORECASE)
        if matches:
            total_risk += risk_weight
            risk_factors.append({
                "type": risk_type,
                "matches": matches[:3] if isinstance(matches[0], str) else [m[0] for m in matches[:3]],
                "risk_contribution": risk_weight,
            })
            
            # Generate suggestion based on risk type
            if risk_type == "entity_name_without_code":
                entity_mappings = get_entity_mappings(vocab_registry)
                for match in matches[:3]:
                    match_str = match if isinstance(match, str) else match[0]
                    if match_str.lower() in entity_mappings:
                        suggestions.append(
                            f"Use entity code '{entity_mappings[match_str.lower()]}' instead of '{match_str}'"
                        )
            elif risk_type == "ambiguous_time_reference":
                suggestions.append("Add explicit date range (e.g., '2024-01-01 to 2024-12-31')")
            elif risk_type == "ambiguous_currency":
                suggestions.append("Specify ISO currency code (e.g., USD, EUR, JPY)")
            elif risk_type == "vague_entity_reference":
                suggestions.append("Include entity code or ID for precise reference")
    
    # Calculate alignment score
    alignment_score = calculate_alignment_score(prompt, vocab_registry)
    
    # Adjust risk based on alignment
    if alignment_score > 0.7:
        total_risk *= 0.7  # Good alignment reduces risk
    elif alignment_score < 0.3:
        total_risk = min(1.0, total_risk * 1.3)  # Poor alignment increases risk
    
    # Cap total risk at 1.0
    total_risk = min(1.0, total_risk)
    
    # Determine risk level
    if total_risk >= HIGH_RISK_THRESHOLD:
        risk_level = RiskLevel.CRITICAL if total_risk >= 0.9 else RiskLevel.HIGH
    elif total_risk >= MEDIUM_RISK_THRESHOLD:
        risk_level = RiskLevel.MEDIUM
    else:
        risk_level = RiskLevel.LOW
    
    # Determine alignment status
    if alignment_score >= 0.7:
        alignment_status = AlignmentStatus.ALIGNED
    elif alignment_score >= 0.4:
        alignment_status = AlignmentStatus.PARTIAL
    elif alignment_score > 0:
        alignment_status = AlignmentStatus.MISALIGNED
    else:
        alignment_status = AlignmentStatus.UNKNOWN
    
    return HallucinationRiskAssessment(
        prompt=prompt,
        overall_risk=total_risk,
        risk_level=risk_level,
        risk_factors=risk_factors,
        suggestions=suggestions,
        alignment_score=alignment_score,
        alignment_status=alignment_status,
    )


def calculate_alignment_score(
    prompt: str,
    vocab_registry: Dict[str, Any],
) -> float:
    """Calculate vocabulary alignment score for a prompt."""
    score = 0.0
    canonical_terms = get_canonical_terms(vocab_registry)
    entity_mappings = get_entity_mappings(vocab_registry)
    synonym_map = get_synonym_map(vocab_registry)
    
    prompt_lower = prompt.lower()
    prompt_words = set(re.findall(r'\b\w+\b', prompt_lower))
    
    # Check for canonical terms
    canonical_matches = prompt_words & canonical_terms
    if canonical_matches:
        score += ALIGNMENT_INDICATORS["uses_canonical_terms"]
    
    # Check for entity codes
    for code in entity_mappings.values():
        if code.lower() in prompt_lower or code in prompt:
            score += ALIGNMENT_INDICATORS["uses_entity_codes"]
            break
    
    # Check for explicit filters (WHERE-like patterns)
    if re.search(r'\b(for|where|with|having|in|equals?|=)\b', prompt_lower):
        score += ALIGNMENT_INDICATORS["has_explicit_filters"]
    
    # Check for time bounds
    if re.search(r'\d{4}[-/]\d{2}|last\s+\d+\s+(days?|months?|years?)|between', prompt_lower):
        score += ALIGNMENT_INDICATORS["has_time_bounds"]
    
    # Check for registered synonyms
    for syn in synonym_map.keys():
        if syn in prompt_lower:
            score += ALIGNMENT_INDICATORS["uses_registered_synonyms"]
            break
    
    # Check for ambiguity (lower is better, so we add if NOT ambiguous)
    has_ambiguity = any(
        re.search(pattern, prompt, re.IGNORECASE) 
        for pattern, _, _ in HALLUCINATION_RISK_PATTERNS
    )
    if not has_ambiguity:
        score += ALIGNMENT_INDICATORS["avoids_ambiguity"]
    
    # Check aggregation scope
    if re.search(r'\b(total|sum|average|count)\b', prompt_lower):
        if re.search(r'\b(by|per|for each|grouped)\b', prompt_lower):
            score += ALIGNMENT_INDICATORS["proper_aggregation_scope"]
    else:
        # No aggregation = full score for this indicator
        score += ALIGNMENT_INDICATORS["proper_aggregation_scope"]
    
    return min(1.0, score)


# =============================================================================
# OPTIMIZATION SUGGESTIONS
# =============================================================================

def generate_optimization_suggestion(
    assessment: HallucinationRiskAssessment,
    vocab_registry: Dict[str, Any],
) -> Optional[DSPyOptimizationSuggestion]:
    """Generate DSPy optimization suggestion for a risky prompt."""
    if assessment.risk_level == RiskLevel.LOW:
        return None
    
    prompt = assessment.prompt
    suggested = prompt
    improvements = []
    
    entity_mappings = get_entity_mappings(vocab_registry)
    
    # Apply entity code replacements
    for name, code in entity_mappings.items():
        pattern = r'\b' + re.escape(name) + r'\b'
        if re.search(pattern, suggested, re.IGNORECASE):
            suggested = re.sub(pattern, f"{name} ({code})", suggested, flags=re.IGNORECASE)
            improvements.append(f"Added entity code for {name}")
    
    # Add time bounds if missing
    if "ambiguous_time_reference" in [f["type"] for f in assessment.risk_factors]:
        if "fiscal year" not in suggested.lower() and "fy" not in suggested.lower():
            suggested = suggested.rstrip('.') + " for fiscal year 2024."
            improvements.append("Added explicit time bound")
    
    # Add currency specification if missing
    if "ambiguous_currency" in [f["type"] for f in assessment.risk_factors]:
        suggested = re.sub(
            r'\$(\d+)', 
            r'USD \1', 
            suggested
        )
        improvements.append("Added currency specification")
    
    if not improvements or suggested == prompt:
        return None
    
    expected_improvement = min(0.3, len(improvements) * 0.1)
    
    return DSPyOptimizationSuggestion(
        original_prompt=prompt,
        suggested_prompt=suggested,
        improvement_type="vocabulary_alignment",
        expected_improvement=expected_improvement,
        rationale="; ".join(improvements),
    )


# =============================================================================
# BATCH PROCESSING
# =============================================================================

def assess_batch(
    prompts: List[str],
    vocab_registry: Dict[str, Any],
) -> AlignmentReport:
    """Assess a batch of prompts."""
    assessments = []
    optimization_suggestions = []
    
    for prompt in prompts:
        assessment = assess_hallucination_risk(prompt, vocab_registry)
        assessments.append(assessment)
        
        suggestion = generate_optimization_suggestion(assessment, vocab_registry)
        if suggestion:
            optimization_suggestions.append(suggestion)
    
    # Calculate statistics
    aligned_count = sum(1 for a in assessments if a.alignment_status == AlignmentStatus.ALIGNED)
    partial_count = sum(1 for a in assessments if a.alignment_status == AlignmentStatus.PARTIAL)
    misaligned_count = sum(1 for a in assessments if a.alignment_status == AlignmentStatus.MISALIGNED)
    average_risk = sum(a.overall_risk for a in assessments) / max(len(assessments), 1)
    high_risk_prompts = sum(1 for a in assessments if a.risk_level in (RiskLevel.HIGH, RiskLevel.CRITICAL))
    
    return AlignmentReport(
        total_prompts=len(prompts),
        aligned_count=aligned_count,
        partial_count=partial_count,
        misaligned_count=misaligned_count,
        average_risk=average_risk,
        high_risk_prompts=high_risk_prompts,
        assessments=assessments,
        optimization_suggestions=optimization_suggestions,
        timestamp=datetime.now().isoformat(),
    )


# =============================================================================
# OUTPUT FORMATTING
# =============================================================================

def format_console_output(report: AlignmentReport) -> str:
    """Format report for console output."""
    lines = []
    lines.append("=" * 80)
    lines.append("DSPY ALIGNMENT & HALLUCINATION RISK REPORT")
    lines.append("=" * 80)
    lines.append(f"Timestamp: {report.timestamp}")
    lines.append(f"Total Prompts: {report.total_prompts}")
    lines.append("-" * 80)
    
    lines.append("\nALIGNMENT SUMMARY")
    lines.append(f"  ✅ Aligned: {report.aligned_count} ({report.aligned_count / max(report.total_prompts, 1):.1%})")
    lines.append(f"  ⚠️ Partial: {report.partial_count}")
    lines.append(f"  ❌ Misaligned: {report.misaligned_count}")
    
    lines.append("\nRISK SUMMARY")
    lines.append(f"  Average Risk: {report.average_risk:.1%}")
    lines.append(f"  High-Risk Prompts: {report.high_risk_prompts}")
    
    # Show high-risk assessments
    high_risk = [a for a in report.assessments if a.risk_level in (RiskLevel.HIGH, RiskLevel.CRITICAL)]
    if high_risk:
        lines.append("\n🚨 HIGH-RISK PROMPTS")
        lines.append("-" * 40)
        for i, a in enumerate(high_risk[:5]):
            preview = a.prompt[:60] + "..." if len(a.prompt) > 60 else a.prompt
            lines.append(f"{i+1}. [{a.risk_level.value.upper()}] {preview}")
            lines.append(f"   Risk: {a.overall_risk:.1%}, Alignment: {a.alignment_score:.1%}")
            if a.risk_factors:
                factors = ", ".join(f["type"] for f in a.risk_factors[:3])
                lines.append(f"   Factors: {factors}")
            if a.suggestions:
                lines.append(f"   Suggestion: {a.suggestions[0]}")
            lines.append("")
    
    # Show optimization suggestions
    if report.optimization_suggestions:
        lines.append("\n💡 OPTIMIZATION SUGGESTIONS")
        lines.append("-" * 40)
        for i, s in enumerate(report.optimization_suggestions[:3]):
            lines.append(f"{i+1}. {s.improvement_type}")
            orig_preview = s.original_prompt[:50] + "..." if len(s.original_prompt) > 50 else s.original_prompt
            sugg_preview = s.suggested_prompt[:50] + "..." if len(s.suggested_prompt) > 50 else s.suggested_prompt
            lines.append(f"   Before: {orig_preview}")
            lines.append(f"   After:  {sugg_preview}")
            lines.append(f"   Rationale: {s.rationale}")
            lines.append("")
    
    lines.append("=" * 80)
    lines.append("\n⚠️ NOTE: This is a STUB implementation.")
    lines.append("Full DSPy integration requires runtime LLM connection for:")
    lines.append("  - Automatic prompt optimization via gradient-based methods")
    lines.append("  - Few-shot example selection from training corpus")
    lines.append("  - Chain-of-thought decomposition")
    lines.append("  - Self-consistency verification")
    lines.append("=" * 80)
    
    return "\n".join(lines)


def format_json_output(report: AlignmentReport) -> str:
    """Format report as JSON."""
    output = report.to_dict()
    output["_note"] = "STUB implementation - full DSPy integration pending"
    return json.dumps(output, indent=2)


# =============================================================================
# MAIN
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="DSPy alignment hooks for prompt optimization (STUB)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Check alignment for a single prompt
  %(prog)s --check "Show me BUKRS 1000 revenue"

  # Estimate hallucination risk
  %(prog)s --risk "What is India revenue?"

  # Generate alignment report for prompt file
  %(prog)s --report prompts.jsonl

  # Output as JSON
  %(prog)s --report prompts.jsonl --output-format json

NOTE: This is a STUB implementation. Full DSPy integration requires:
  - pip install dspy-ai
  - LLM API connection (OpenAI, Anthropic, etc.)
  - Training corpus for few-shot examples
        """,
    )
    
    parser.add_argument(
        "--check",
        help="Check alignment for a single prompt",
    )
    
    parser.add_argument(
        "--risk",
        help="Estimate hallucination risk for a prompt",
    )
    
    parser.add_argument(
        "--report",
        help="Generate report for JSONL prompt file",
    )
    
    parser.add_argument(
        "--vocab-registry",
        default=VOCABULARY_REGISTRY_PATH,
        help=f"Path to vocabulary registry (default: {VOCABULARY_REGISTRY_PATH})",
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
    
    args = parser.parse_args()
    
    # Load vocabulary registry
    vocab_registry = load_vocabulary_registry(args.vocab_registry)
    
    # Handle single prompt check
    if args.check or args.risk:
        prompt = args.check or args.risk
        assessment = assess_hallucination_risk(prompt, vocab_registry)
        
        if args.output_format == "json":
            output = json.dumps(assessment.to_dict(), indent=2)
        else:
            risk_icon = {
                RiskLevel.LOW: "🟢",
                RiskLevel.MEDIUM: "🟡",
                RiskLevel.HIGH: "🟠",
                RiskLevel.CRITICAL: "🔴",
            }.get(assessment.risk_level, "?")
            
            output = f"""
Prompt: {assessment.prompt}

{risk_icon} Risk Level: {assessment.risk_level.value.upper()}
Overall Risk: {assessment.overall_risk:.1%}
Alignment Score: {assessment.alignment_score:.1%}
Alignment Status: {assessment.alignment_status.value}

Risk Factors:
"""
            for factor in assessment.risk_factors:
                output += f"  - {factor['type']}: {factor['matches']}\n"
            
            if assessment.suggestions:
                output += "\nSuggestions:\n"
                for sugg in assessment.suggestions:
                    output += f"  → {sugg}\n"
        
        print(output)
        sys.exit(0)
    
    # Handle report generation
    if args.report:
        path = Path(args.report)
        if not path.exists():
            print(f"Error: File not found: {args.report}", file=sys.stderr)
            sys.exit(1)
        
        prompts = []
        with open(path, "r") as f:
            for line in f:
                try:
                    record = json.loads(line.strip())
                    for field in ["question", "query", "text", "content", "prompt", "input"]:
                        if field in record:
                            prompts.append(record[field])
                            break
                except json.JSONDecodeError:
                    continue
        
        report = assess_batch(prompts, vocab_registry)
        
        if args.output_format == "json":
            output = format_json_output(report)
        elif args.output_format == "yaml":
            output = yaml.dump(report.to_dict(), default_flow_style=False, allow_unicode=True)
        else:
            output = format_console_output(report)
        
        if args.output_file:
            with open(args.output_file, "w") as f:
                f.write(output)
            print(f"Report written to {args.output_file}")
        else:
            print(output)
        
        # Exit with error if too many high-risk prompts
        if report.high_risk_prompts > report.total_prompts * 0.2:
            sys.exit(1)
        
        sys.exit(0)
    
    # No arguments - show help
    parser.print_help()
    sys.exit(1)


if __name__ == "__main__":
    main()