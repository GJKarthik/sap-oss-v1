#!/usr/bin/env python3
"""
Persona Classifier - Separate training data for human users vs schema-aware agents.

This module addresses the meeting requirement:
"Pipeline needs separate handling / training files for human users vs schema-aware 
agents to keep prompts appropriate."

It analyzes training data and splits it into human-appropriate and agent-appropriate
prompts based on vocabulary complexity, technical terminology, and NL readiness.

Usage:
    # Classify a single training file
    python3 scripts/spec-drift/persona_classifier.py --input train.jsonl

    # Generate separate human/agent training files
    python3 scripts/spec-drift/persona_classifier.py --input train.jsonl --split

    # Assess prompt suitability for personas
    python3 scripts/spec-drift/persona_classifier.py --assess "Show me BUKRS 1000 data"

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

# Persona thresholds
HUMAN_SUITABILITY_THRESHOLD = 0.70  # >= 70% is human-suitable
AGENT_SUITABILITY_THRESHOLD = 0.30  # >= 30% is agent-suitable (lower = more technical OK)

# Technical indicators that make a prompt more agent-friendly
TECHNICAL_INDICATORS = [
    r'\b[A-Z]{2,6}\b',                    # SAP-style abbreviations (BUKRS, WAERS)
    r'\b\d{4,}\b',                          # Long numbers (IDs, codes)
    r'SELECT|FROM|WHERE|JOIN|GROUP BY',     # SQL keywords
    r'\.\w+\.',                             # Dot notation (table.field)
    r'_id\b|_code\b|_key\b',               # Technical field suffixes
    r'\bGET\b|\bPOST\b|\bAPI\b',           # API terminology
    r'\bjson\b|\bxml\b|\byaml\b',          # Data format terms
    r'\[\s*\]|\{\s*\}',                    # Array/object notation
    r'==|!=|>=|<=|&&|\|\|',                # Programming operators
]

# Human-friendly indicators
HUMAN_INDICATORS = [
    r'\b(show|display|list|get|find|what|how|why|when|where)\b',
    r'\b(please|could you|can you|I want|I need)\b',
    r'\b(total|average|sum|count|maximum|minimum)\b',
    r'\b(last|this|next|previous)\s+(month|year|week|quarter)\b',
    r'\b(sales|revenue|profit|loss|expense|income)\b',
    r'\b(customer|vendor|employee|company|department)\b',
]

# Words that should be translated for humans
TECHNICAL_TO_HUMAN_MAP = {
    'bukrs': 'company code',
    'waers': 'currency',
    'hkont': 'GL account',
    'gjahr': 'fiscal year',
    'monat': 'period',
    'kunnr': 'customer number',
    'lifnr': 'vendor number',
    'select': 'show',
    'where': 'where',
    'from': 'from',
}


# =============================================================================
# ENUMS & DATA CLASSES
# =============================================================================

class PersonaType(Enum):
    """Target persona for the prompt."""
    HUMAN = "human"           # Non-technical end users
    AGENT = "agent"           # Schema-aware AI agents
    DUAL = "dual"             # Suitable for both
    AMBIGUOUS = "ambiguous"   # Unclear classification


class ComplexityLevel(Enum):
    """Complexity level of the prompt."""
    SIMPLE = "simple"         # Basic queries, natural language
    MODERATE = "moderate"     # Some technical terms
    COMPLEX = "complex"       # Heavy technical vocabulary
    EXPERT = "expert"         # Requires domain expertise


@dataclass
class PromptClassification:
    """Classification result for a single prompt."""
    text: str
    persona: PersonaType
    human_score: float  # 0.0 - 1.0
    agent_score: float  # 0.0 - 1.0
    complexity: ComplexityLevel
    technical_terms: List[str]
    human_friendly_version: Optional[str]
    issues: List[str] = field(default_factory=list)
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            "text": self.text,
            "persona": self.persona.value,
            "human_score": round(self.human_score, 3),
            "agent_score": round(self.agent_score, 3),
            "complexity": self.complexity.value,
            "technical_terms": self.technical_terms,
            "human_friendly_version": self.human_friendly_version,
            "issues": self.issues,
        }


@dataclass
class ClassificationReport:
    """Report for a batch of classified prompts."""
    total_prompts: int
    human_suitable: int
    agent_suitable: int
    dual_suitable: int
    ambiguous: int
    classifications: List[PromptClassification]
    timestamp: str
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            "total_prompts": self.total_prompts,
            "human_suitable": self.human_suitable,
            "agent_suitable": self.agent_suitable,
            "dual_suitable": self.dual_suitable,
            "ambiguous": self.ambiguous,
            "human_ratio": round(self.human_suitable / max(self.total_prompts, 1), 3),
            "agent_ratio": round(self.agent_suitable / max(self.total_prompts, 1), 3),
            "timestamp": self.timestamp,
            "classifications": [c.to_dict() for c in self.classifications],
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


def get_technical_terms(vocab_registry: Dict[str, Any]) -> Dict[str, str]:
    """Extract technical terms with their human-friendly equivalents."""
    terms = {}
    
    for domain in vocab_registry.get("domains", {}).values():
        for tech_term in domain.get("technical_terms", []):
            tech_name = tech_term.get("technical_name", "").lower()
            human_name = tech_term.get("human_name", "")
            if tech_name and human_name:
                terms[tech_name] = human_name
    
    # Add abbreviations
    for abbrev in vocab_registry.get("abbreviations", []):
        abbr = abbrev.get("abbreviation", "").lower()
        expansion = abbrev.get("expansion", "")
        if abbr and expansion:
            terms[abbr] = expansion
    
    return terms


def get_human_friendly_terms(vocab_registry: Dict[str, Any]) -> Set[str]:
    """Get set of human-friendly terms."""
    terms = set()
    
    for domain in vocab_registry.get("domains", {}).values():
        for term in domain.get("canonical_terms", []):
            human = term.get("human_friendly", "")
            if human:
                terms.add(human.lower())
            for var in term.get("variations", []):
                terms.add(var.lower())
    
    return terms


# =============================================================================
# CLASSIFICATION LOGIC
# =============================================================================

def count_technical_indicators(text: str) -> Tuple[int, List[str]]:
    """Count technical indicators in text."""
    count = 0
    found_terms = []
    
    for pattern in TECHNICAL_INDICATORS:
        matches = re.findall(pattern, text, re.IGNORECASE)
        count += len(matches)
        found_terms.extend(matches)
    
    return count, list(set(found_terms))


def count_human_indicators(text: str) -> int:
    """Count human-friendly indicators in text."""
    count = 0
    
    for pattern in HUMAN_INDICATORS:
        matches = re.findall(pattern, text, re.IGNORECASE)
        count += len(matches)
    
    return count


def identify_technical_terms(
    text: str,
    technical_terms: Dict[str, str],
) -> List[str]:
    """Identify known technical terms in text."""
    found = []
    text_lower = text.lower()
    
    for term in technical_terms.keys():
        if re.search(r'\b' + re.escape(term) + r'\b', text_lower):
            found.append(term)
    
    return found


def generate_human_friendly_version(
    text: str,
    technical_terms: Dict[str, str],
) -> Optional[str]:
    """Generate a human-friendly version of technical text."""
    result = text
    made_changes = False
    
    for tech, human in technical_terms.items():
        pattern = r'\b' + re.escape(tech) + r'\b'
        if re.search(pattern, result, re.IGNORECASE):
            result = re.sub(pattern, human, result, flags=re.IGNORECASE)
            made_changes = True
    
    # Also expand from our static map
    for tech, human in TECHNICAL_TO_HUMAN_MAP.items():
        pattern = r'\b' + re.escape(tech) + r'\b'
        if re.search(pattern, result, re.IGNORECASE):
            result = re.sub(pattern, human, result, flags=re.IGNORECASE)
            made_changes = True
    
    return result if made_changes else None


def calculate_complexity(
    tech_count: int,
    human_count: int,
    text_length: int,
) -> ComplexityLevel:
    """Calculate complexity level based on indicators."""
    # Normalize by text length (per 100 chars)
    normalized_length = max(text_length, 1) / 100
    tech_density = tech_count / normalized_length
    human_density = human_count / normalized_length
    
    if tech_density > 3:
        return ComplexityLevel.EXPERT
    elif tech_density > 1.5:
        return ComplexityLevel.COMPLEX
    elif tech_density > 0.5 or (tech_count > 0 and human_count == 0):
        return ComplexityLevel.MODERATE
    else:
        return ComplexityLevel.SIMPLE


def classify_prompt(
    text: str,
    vocab_registry: Dict[str, Any],
) -> PromptClassification:
    """Classify a single prompt for persona suitability."""
    technical_terms = get_technical_terms(vocab_registry)
    
    # Count indicators
    tech_count, tech_found = count_technical_indicators(text)
    human_count = count_human_indicators(text)
    found_tech_terms = identify_technical_terms(text, technical_terms)
    
    # Add found technical terms to count
    tech_count += len(found_tech_terms)
    
    # Calculate scores (0.0 - 1.0)
    total_indicators = max(tech_count + human_count, 1)
    
    # Human score: higher with more human indicators, lower with technical
    human_base = human_count / total_indicators
    tech_penalty = min(tech_count * 0.1, 0.5)
    human_score = max(0, min(1, human_base + 0.3 - tech_penalty))
    
    # Agent score: higher with technical indicators
    agent_base = tech_count / total_indicators
    agent_score = max(0, min(1, agent_base + 0.2))
    
    # Boost human score if text uses natural language patterns
    if re.search(r'^(show|display|what|how|list|get|find)\s', text, re.IGNORECASE):
        human_score = min(1, human_score + 0.2)
    
    # Boost agent score if text contains SQL or code patterns
    if re.search(r'SELECT|FROM|WHERE|\.|\[|\{', text, re.IGNORECASE):
        agent_score = min(1, agent_score + 0.2)
        human_score = max(0, human_score - 0.2)
    
    # Determine complexity
    complexity = calculate_complexity(tech_count, human_count, len(text))
    
    # Determine persona
    if human_score >= HUMAN_SUITABILITY_THRESHOLD and agent_score >= AGENT_SUITABILITY_THRESHOLD:
        persona = PersonaType.DUAL
    elif human_score >= HUMAN_SUITABILITY_THRESHOLD:
        persona = PersonaType.HUMAN
    elif agent_score >= AGENT_SUITABILITY_THRESHOLD:
        persona = PersonaType.AGENT
    else:
        persona = PersonaType.AMBIGUOUS
    
    # Generate human-friendly version if needed
    human_friendly = None
    if persona in (PersonaType.AGENT, PersonaType.AMBIGUOUS) and found_tech_terms:
        human_friendly = generate_human_friendly_version(text, technical_terms)
    
    # Collect issues
    issues = []
    if found_tech_terms and persona == PersonaType.HUMAN:
        issues.append(f"Technical terms found in human prompt: {', '.join(found_tech_terms[:3])}")
    if complexity == ComplexityLevel.EXPERT:
        issues.append("Expert-level complexity may be too difficult for end users")
    
    return PromptClassification(
        text=text,
        persona=persona,
        human_score=human_score,
        agent_score=agent_score,
        complexity=complexity,
        technical_terms=found_tech_terms,
        human_friendly_version=human_friendly,
        issues=issues,
    )


# =============================================================================
# BATCH PROCESSING
# =============================================================================

def classify_batch(
    prompts: List[str],
    vocab_registry: Dict[str, Any],
) -> ClassificationReport:
    """Classify a batch of prompts."""
    classifications = []
    
    for prompt in prompts:
        classification = classify_prompt(prompt, vocab_registry)
        classifications.append(classification)
    
    # Count by persona
    human_suitable = sum(1 for c in classifications if c.persona in (PersonaType.HUMAN, PersonaType.DUAL))
    agent_suitable = sum(1 for c in classifications if c.persona in (PersonaType.AGENT, PersonaType.DUAL))
    dual_suitable = sum(1 for c in classifications if c.persona == PersonaType.DUAL)
    ambiguous = sum(1 for c in classifications if c.persona == PersonaType.AMBIGUOUS)
    
    return ClassificationReport(
        total_prompts=len(prompts),
        human_suitable=human_suitable,
        agent_suitable=agent_suitable,
        dual_suitable=dual_suitable,
        ambiguous=ambiguous,
        classifications=classifications,
        timestamp=datetime.now().isoformat(),
    )


def load_prompts_from_jsonl(
    filepath: str,
    text_fields: List[str] = None,
) -> List[Dict[str, Any]]:
    """Load prompts from JSONL file."""
    if text_fields is None:
        text_fields = ["question", "query", "text", "content", "prompt", "input", "natural_language"]
    
    records = []
    path = Path(filepath)
    
    if not path.exists():
        return []
    
    with open(path, "r") as f:
        for line in f:
            try:
                record = json.loads(line.strip())
                # Find the text field
                for field in text_fields:
                    if field in record and isinstance(record[field], str):
                        record["_text"] = record[field]
                        break
                if "_text" in record:
                    records.append(record)
            except json.JSONDecodeError:
                continue
    
    return records


def split_training_file(
    input_path: str,
    output_dir: str,
    vocab_registry: Dict[str, Any],
) -> Tuple[str, str, ClassificationReport]:
    """Split training file into human and agent versions."""
    records = load_prompts_from_jsonl(input_path)
    
    human_records = []
    agent_records = []
    
    prompts = [r.get("_text", "") for r in records]
    report = classify_batch(prompts, vocab_registry)
    
    for record, classification in zip(records, report.classifications):
        # Remove our internal field
        clean_record = {k: v for k, v in record.items() if k != "_text"}
        
        if classification.persona in (PersonaType.HUMAN, PersonaType.DUAL):
            human_records.append(clean_record)
        
        if classification.persona in (PersonaType.AGENT, PersonaType.DUAL):
            agent_records.append(clean_record)
        
        # For ambiguous, try to create both versions
        if classification.persona == PersonaType.AMBIGUOUS:
            agent_records.append(clean_record)
            
            # Create human-friendly version if we can
            if classification.human_friendly_version:
                human_record = clean_record.copy()
                # Find and replace the text field
                for field in ["question", "query", "text", "content", "prompt", "input", "natural_language"]:
                    if field in human_record:
                        human_record[field] = classification.human_friendly_version
                        break
                human_records.append(human_record)
    
    # Write output files
    output_path = Path(output_dir)
    output_path.mkdir(parents=True, exist_ok=True)
    
    input_stem = Path(input_path).stem
    human_path = output_path / f"{input_stem}_human.jsonl"
    agent_path = output_path / f"{input_stem}_agent.jsonl"
    
    with open(human_path, "w") as f:
        for record in human_records:
            f.write(json.dumps(record) + "\n")
    
    with open(agent_path, "w") as f:
        for record in agent_records:
            f.write(json.dumps(record) + "\n")
    
    return str(human_path), str(agent_path), report


# =============================================================================
# OUTPUT FORMATTING
# =============================================================================

def format_console_output(report: ClassificationReport) -> str:
    """Format report for console output."""
    lines = []
    lines.append("=" * 80)
    lines.append("PERSONA CLASSIFICATION REPORT")
    lines.append("=" * 80)
    lines.append(f"Timestamp: {report.timestamp}")
    lines.append(f"Total Prompts: {report.total_prompts}")
    lines.append("-" * 80)
    
    lines.append("\nSUMMARY")
    lines.append(f"  Human-Suitable: {report.human_suitable} ({report.human_suitable / max(report.total_prompts, 1):.1%})")
    lines.append(f"  Agent-Suitable: {report.agent_suitable} ({report.agent_suitable / max(report.total_prompts, 1):.1%})")
    lines.append(f"  Dual-Suitable: {report.dual_suitable}")
    lines.append(f"  Ambiguous: {report.ambiguous}")
    
    # Show sample classifications
    lines.append("\nSAMPLE CLASSIFICATIONS")
    lines.append("-" * 40)
    
    for i, c in enumerate(report.classifications[:10]):
        icon = {
            PersonaType.HUMAN: "👤",
            PersonaType.AGENT: "🤖",
            PersonaType.DUAL: "👥",
            PersonaType.AMBIGUOUS: "❓",
        }.get(c.persona, "?")
        
        text_preview = c.text[:50] + "..." if len(c.text) > 50 else c.text
        lines.append(f"{i+1}. {icon} [{c.persona.value}] {text_preview}")
        lines.append(f"   Human: {c.human_score:.2f}, Agent: {c.agent_score:.2f}, Complexity: {c.complexity.value}")
        
        if c.technical_terms:
            lines.append(f"   Technical terms: {', '.join(c.technical_terms[:3])}")
        if c.human_friendly_version:
            hf_preview = c.human_friendly_version[:50] + "..." if len(c.human_friendly_version) > 50 else c.human_friendly_version
            lines.append(f"   Human-friendly: {hf_preview}")
        lines.append("")
    
    if len(report.classifications) > 10:
        lines.append(f"... and {len(report.classifications) - 10} more")
    
    lines.append("=" * 80)
    
    return "\n".join(lines)


def format_json_output(report: ClassificationReport) -> str:
    """Format report as JSON."""
    return json.dumps(report.to_dict(), indent=2)


def format_yaml_output(report: ClassificationReport) -> str:
    """Format report as YAML."""
    return yaml.dump(report.to_dict(), default_flow_style=False, sort_keys=False, allow_unicode=True)


# =============================================================================
# MAIN
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Classify training prompts for human vs agent personas",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Classify prompts in a training file
  %(prog)s --input train.jsonl

  # Generate separate human/agent training files
  %(prog)s --input train.jsonl --split --output-dir ./split_training

  # Assess a single prompt
  %(prog)s --assess "Show me BUKRS 1000 revenue"

  # Output as JSON for CI
  %(prog)s --input train.jsonl --output-format json
        """,
    )
    
    parser.add_argument(
        "--input",
        help="Path to JSONL training file to classify",
    )
    
    parser.add_argument(
        "--assess",
        help="Assess a single prompt string",
    )
    
    parser.add_argument(
        "--split",
        action="store_true",
        help="Generate separate human and agent training files",
    )
    
    parser.add_argument(
        "--output-dir",
        default=".",
        help="Output directory for split files (default: current directory)",
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
    
    # Handle single assessment
    if args.assess:
        classification = classify_prompt(args.assess, vocab_registry)
        
        if args.output_format == "json":
            output = json.dumps(classification.to_dict(), indent=2)
        elif args.output_format == "yaml":
            output = yaml.dump(classification.to_dict(), default_flow_style=False)
        else:
            icon = {
                PersonaType.HUMAN: "👤 HUMAN",
                PersonaType.AGENT: "🤖 AGENT",
                PersonaType.DUAL: "👥 DUAL",
                PersonaType.AMBIGUOUS: "❓ AMBIGUOUS",
            }.get(classification.persona, "UNKNOWN")
            
            output = f"""
Prompt: {classification.text}
Classification: {icon}
Human Score: {classification.human_score:.2f}
Agent Score: {classification.agent_score:.2f}
Complexity: {classification.complexity.value}
Technical Terms: {', '.join(classification.technical_terms) or 'None'}
"""
            if classification.human_friendly_version:
                output += f"Human-Friendly Version: {classification.human_friendly_version}\n"
        
        print(output)
        sys.exit(0)
    
    # Handle file processing
    if not args.input:
        print("Error: Specify --input or --assess", file=sys.stderr)
        sys.exit(1)
    
    # Split mode
    if args.split:
        human_path, agent_path, report = split_training_file(
            args.input,
            args.output_dir,
            vocab_registry,
        )
        
        print(f"Human training file: {human_path} ({report.human_suitable} examples)")
        print(f"Agent training file: {agent_path} ({report.agent_suitable} examples)")
        
        if args.output_format != "console":
            if args.output_format == "json":
                output = format_json_output(report)
            else:
                output = format_yaml_output(report)
            
            if args.output_file:
                with open(args.output_file, "w") as f:
                    f.write(output)
            else:
                print(output)
        
        sys.exit(0)
    
    # Classification mode
    records = load_prompts_from_jsonl(args.input)
    prompts = [r.get("_text", "") for r in records]
    report = classify_batch(prompts, vocab_registry)
    
    # Format output
    if args.output_format == "console":
        output = format_console_output(report)
    elif args.output_format == "json":
        output = format_json_output(report)
    elif args.output_format == "yaml":
        output = format_yaml_output(report)
    
    # Write output
    if args.output_file:
        with open(args.output_file, "w") as f:
            f.write(output)
        print(f"Report written to {args.output_file}")
    else:
        print(output)
    
    # Exit with warning if many ambiguous
    if report.ambiguous > report.total_prompts * 0.2:
        sys.exit(1)
    
    sys.exit(0)


if __name__ == "__main__":
    main()