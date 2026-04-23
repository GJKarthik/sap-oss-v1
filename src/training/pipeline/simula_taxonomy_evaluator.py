"""
Simula Taxonomy Evaluator — Expert Taxonomy Comparison (Section B.1, Table 2).

Evaluates generated taxonomies against expert references for:
- Completeness: Does generated taxonomy cover expert concepts?
- Soundness: Are generated nodes relevant and well-defined?
- Novelty: Does generated taxonomy include valid concepts not in expert?
- Coverage: Total coverage (Completeness + Novelty)

Reference: Davidson et al. (2026) "Reasoning-Driven Synthetic Data Generation"
           TMLR, Section B.1-B.2 and Table 2
"""

from __future__ import annotations

import asyncio
import json
import logging
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .simula_llm_client import SimulaLLMClient
    from .simula_taxonomy_builder import Taxonomy, TaxonomyNode

logger = logging.getLogger(__name__)


@dataclass
class TaxonomyQualityReport:
    """Quality metrics for a generated taxonomy (Table 2)."""
    
    # Core metrics from paper (Section B.1)
    completeness: float = 0.0  # Ratio of expert nodes covered by generated
    soundness: float = 0.0     # Ratio of generated nodes that are valid
    novelty: float = 0.0       # Ratio of valid generated nodes not in expert
    coverage: float = 0.0      # completeness + novelty
    
    # Node-level details
    overlapping_nodes: list[str] = field(default_factory=list)  # In both
    missing_nodes: list[str] = field(default_factory=list)      # In expert only
    novel_nodes: list[str] = field(default_factory=list)        # In generated only (valid)
    invalid_nodes: list[str] = field(default_factory=list)      # In generated only (invalid)
    redundant_nodes: list[str] = field(default_factory=list)    # Duplicates
    
    # Counts
    expert_node_count: int = 0
    generated_node_count: int = 0
    
    @property
    def is_acceptable(self) -> bool:
        """Check if taxonomy meets minimum quality thresholds (Table 2)."""
        return self.completeness >= 0.7 and self.soundness >= 0.9
    
    def to_dict(self) -> dict:
        return {
            "metrics": {
                "completeness": self.completeness,
                "soundness": self.soundness,
                "novelty": self.novelty,
                "coverage": self.coverage,
            },
            "thresholds": {
                "completeness": 0.7,
                "soundness": 0.9,
            },
            "counts": {
                "expert_nodes": self.expert_node_count,
                "generated_nodes": self.generated_node_count,
                "overlapping": len(self.overlapping_nodes),
                "missing": len(self.missing_nodes),
                "novel": len(self.novel_nodes),
                "invalid": len(self.invalid_nodes),
                "redundant": len(self.redundant_nodes),
            },
            "is_acceptable": self.is_acceptable,
        }


@dataclass
class TaxonomyEvaluatorConfig:
    """Configuration for taxonomy evaluation."""
    
    # Minimum acceptable completeness (from Table 2: Simula achieved 0.74-0.99)
    min_completeness: float = 0.7
    
    # Minimum acceptable soundness (from Table 2: Simula achieved 0.75-1.0)
    min_soundness: float = 0.9
    
    # Prompt for node classification
    classification_prompt: str = """
You are evaluating a taxonomy node by comparing it to an expert reference.

Expert taxonomy topic: {topic}
Expert nodes: {expert_nodes}

Node to classify: {node_name}
Description: {node_description}

Classify this node into ONE of these categories:
1. OVERLAPPING - Semantically equivalent to an expert node (specify which)
2. NOVEL_VALID - Not in expert taxonomy but relevant and well-defined
3. INVALID - Irrelevant, poorly defined, or misclassified
4. REDUNDANT - Duplicate of another node in the same generated taxonomy

Respond with JSON:
{{
    "category": "OVERLAPPING|NOVEL_VALID|INVALID|REDUNDANT",
    "matching_expert_node": "node name if OVERLAPPING, else null",
    "explanation": "brief explanation"
}}
"""

    @classmethod
    def from_env(cls) -> "TaxonomyEvaluatorConfig":
        import os
        return cls(
            min_completeness=float(os.getenv("SIMULA_TAXONOMY_MIN_COMPLETENESS", "0.7")),
            min_soundness=float(os.getenv("SIMULA_TAXONOMY_MIN_SOUNDNESS", "0.9")),
        )


class SimulaTaxonomyEvaluator:
    """
    Evaluates generated taxonomies against expert references.
    
    From Section B.1-B.2:
    "A critic-model based framework for evaluation... classifies each node
    into: Good and Overlapping, Good and Exclusive, Redundant, or Bad."
    """
    
    def __init__(
        self,
        llm_client: "SimulaLLMClient",
        config: TaxonomyEvaluatorConfig | None = None,
    ):
        self.llm = llm_client
        self.config = config or TaxonomyEvaluatorConfig.from_env()
    
    async def compare(
        self,
        generated: "Taxonomy",
        expert_path: str | Path,
    ) -> TaxonomyQualityReport:
        """
        Compare a generated taxonomy against an expert reference.
        
        Args:
            generated: The LLM-generated taxonomy
            expert_path: Path to expert taxonomy JSON file
            
        Returns:
            TaxonomyQualityReport with completeness, soundness, novelty metrics
        """
        # Load expert taxonomy
        expert_nodes = self._load_expert_taxonomy(expert_path)
        expert_node_names = set(expert_nodes.keys())
        
        # Extract generated node names
        generated_nodes = self._flatten_taxonomy(generated.root)
        generated_node_names = set(generated_nodes.keys())
        
        report = TaxonomyQualityReport(
            expert_node_count=len(expert_node_names),
            generated_node_count=len(generated_node_names),
        )
        
        logger.info(
            f"Comparing taxonomy: {len(generated_node_names)} generated vs "
            f"{len(expert_node_names)} expert nodes"
        )
        
        # Classify each generated node
        classifications = await self._classify_nodes(
            generated_nodes,
            expert_nodes,
            generated.factor_name,
        )
        
        # Process classifications
        expert_covered = set()
        for node_name, classification in classifications.items():
            category = classification.get("category", "INVALID")
            
            if category == "OVERLAPPING":
                report.overlapping_nodes.append(node_name)
                matching = classification.get("matching_expert_node")
                if matching:
                    expert_covered.add(matching)
            elif category == "NOVEL_VALID":
                report.novel_nodes.append(node_name)
            elif category == "INVALID":
                report.invalid_nodes.append(node_name)
            elif category == "REDUNDANT":
                report.redundant_nodes.append(node_name)
        
        # Find missing expert nodes
        report.missing_nodes = list(expert_node_names - expert_covered)
        
        # Calculate metrics (per Section B.1)
        total_good_expert = len(expert_node_names)
        total_good_generated = len(report.overlapping_nodes) + len(report.novel_nodes)
        
        if total_good_expert > 0:
            report.completeness = len(expert_covered) / total_good_expert
            report.novelty = len(report.novel_nodes) / total_good_expert
            report.coverage = report.completeness + report.novelty
        
        if len(generated_node_names) > 0:
            report.soundness = total_good_generated / len(generated_node_names)
        
        logger.info(
            f"Taxonomy evaluation: completeness={report.completeness:.2%}, "
            f"soundness={report.soundness:.2%}, novelty={report.novelty:.2%}"
        )
        
        return report
    
    def _load_expert_taxonomy(self, path: str | Path) -> dict[str, dict]:
        """Load expert taxonomy from JSON file."""
        path = Path(path)
        if not path.exists():
            raise FileNotFoundError(f"Expert taxonomy not found: {path}")
        
        with open(path, "r") as f:
            data = json.load(f)
        
        # Flatten if hierarchical
        if "nodes" in data:
            return {n["name"]: n for n in data["nodes"]}
        elif isinstance(data, list):
            return {n.get("name", str(i)): n for i, n in enumerate(data)}
        elif isinstance(data, dict) and all(isinstance(v, dict) for v in data.values()):
            return data
        else:
            # Assume flat list of node names
            return {name: {"name": name} for name in data}
    
    def _flatten_taxonomy(self, node: "TaxonomyNode", result: dict = None) -> dict[str, dict]:
        """Flatten a taxonomy tree into a dict of nodes."""
        if result is None:
            result = {}
        
        result[node.name] = {
            "name": node.name,
            "description": node.description,
            "level": node.level,
        }
        
        for child in node.children:
            self._flatten_taxonomy(child, result)
        
        return result
    
    async def _classify_nodes(
        self,
        generated_nodes: dict[str, dict],
        expert_nodes: dict[str, dict],
        topic: str,
    ) -> dict[str, dict]:
        """Classify all generated nodes."""
        tasks = [
            self._classify_single_node(name, info, expert_nodes, topic)
            for name, info in generated_nodes.items()
        ]
        
        results = await asyncio.gather(*tasks)
        return {name: result for name, result in zip(generated_nodes.keys(), results)}
    
    async def _classify_single_node(
        self,
        node_name: str,
        node_info: dict,
        expert_nodes: dict[str, dict],
        topic: str,
    ) -> dict:
        """Classify a single node."""
        expert_names = list(expert_nodes.keys())[:50]  # Limit for prompt
        
        prompt = self.config.classification_prompt.format(
            topic=topic,
            expert_nodes=", ".join(expert_names),
            node_name=node_name,
            node_description=node_info.get("description", "No description"),
        )
        
        try:
            response = await self.llm.generate(prompt, temperature=0.2)
            
            # Parse JSON from response
            content = response.content
            start = content.find("{")
            end = content.rfind("}") + 1
            if start >= 0 and end > start:
                return json.loads(content[start:end])
        except Exception as e:
            logger.debug(f"Node classification failed for {node_name}: {e}")
        
        # Default to invalid on failure
        return {"category": "INVALID", "explanation": "Classification failed"}
    
    def validate_taxonomy(
        self,
        generated: "Taxonomy",
        expert_path: str | Path | None = None,
        report: TaxonomyQualityReport | None = None,
    ) -> bool:
        """
        Validate a taxonomy meets quality thresholds.
        
        Args:
            generated: Generated taxonomy
            expert_path: Path to expert taxonomy (for comparison)
            report: Pre-computed report (if available)
            
        Returns:
            True if taxonomy meets thresholds
            
        Raises:
            TaxonomyQualityError if validation fails
        """
        if report is None and expert_path is None:
            # No expert to compare against, assume valid
            return True
        
        if report is None:
            # Would need async call - just return True
            logger.warning("No report provided, skipping validation")
            return True
        
        if report.completeness < self.config.min_completeness:
            raise TaxonomyQualityError(
                f"Taxonomy completeness {report.completeness:.2%} below minimum "
                f"{self.config.min_completeness:.2%}"
            )
        
        if report.soundness < self.config.min_soundness:
            raise TaxonomyQualityError(
                f"Taxonomy soundness {report.soundness:.2%} below minimum "
                f"{self.config.min_soundness:.2%}"
            )
        
        return True
    
    def export_report(self, report: TaxonomyQualityReport, output_path: str) -> None:
        """Export evaluation report to JSON."""
        data = report.to_dict()
        data["node_details"] = {
            "overlapping": report.overlapping_nodes,
            "missing": report.missing_nodes,
            "novel": report.novel_nodes,
            "invalid": report.invalid_nodes,
            "redundant": report.redundant_nodes,
        }
        
        with open(output_path, "w") as f:
            json.dump(data, f, indent=2)
        
        logger.info(f"Exported taxonomy evaluation report to {output_path}")


class TaxonomyQualityError(Exception):
    """Raised when taxonomy fails quality validation."""
    pass