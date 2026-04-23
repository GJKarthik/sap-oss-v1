"""
Simula Coverage Evaluator — Taxonomic Coverage Metrics from Section 2.3.

Implements the Level Ratio Coverage metric from the Simula paper (Figure 4)
to evaluate how well generated data covers the taxonomic concept space.

Key insight from 6171: Real data often misses large taxonomic subsets.
Without coverage metrics, systematic gaps in synthetic data go undetected.

Reference: Davidson et al. (2026) "Reasoning-Driven Synthetic Data Generation"
           TMLR, Section 2.3 (Using Taxonomies to Curate Dataset Coverage)
"""

from __future__ import annotations

import asyncio
import json
import logging
from dataclasses import dataclass, field
from typing import TYPE_CHECKING
from collections import defaultdict

if TYPE_CHECKING:
    from .simula_llm_client import SimulaLLMClient
    from .simula_taxonomy_builder import Taxonomy, TaxonomyNode
    from .simula_data_generator import TrainingExample

logger = logging.getLogger(__name__)


@dataclass
class CoverageConfig:
    """Configuration for coverage evaluation."""
    
    # Maximum taxonomy depth to evaluate
    max_level: int = 4
    
    # Sample size for coverage evaluation (0 = all examples)
    sample_size: int = 1000
    
    # Prompt template for taxonomy assignment
    assignment_prompt_template: str = """
You are assigning a data point to the most appropriate node in a taxonomy.

Taxonomy structure:
{taxonomy_tree}

Data point:
Question: {question}
SQL: {sql}

Select the MOST SPECIFIC node that describes this data point.
Output JSON: {{"node_id": "selected_node_id", "path": ["root", "level1", ...]}}
"""

    @classmethod
    def from_env(cls) -> "CoverageConfig":
        """Load configuration from environment variables."""
        import os
        return cls(
            max_level=int(os.getenv("SIMULA_COVERAGE_MAX_LEVEL", "4")),
            sample_size=int(os.getenv("SIMULA_COVERAGE_SAMPLE_SIZE", "1000")),
        )


@dataclass
class CoverageReport:
    """Coverage metrics for a dataset against a taxonomy."""
    
    taxonomy_id: str
    taxonomy_factor: str
    total_nodes_by_level: dict[int, int] = field(default_factory=dict)
    covered_nodes_by_level: dict[int, set] = field(default_factory=dict)
    assignments: dict[str, str] = field(default_factory=dict)  # example_id -> node_id
    
    @property
    def level_ratio_coverage(self) -> dict[int, float]:
        """
        Level Ratio Coverage metric from Figure 4 (bottom panel).
        
        Returns proportion of unique nodes covered at each level.
        """
        return {
            level: len(covered) / total if total > 0 else 0.0
            for level, (covered, total) in self._level_data().items()
        }
    
    def _level_data(self) -> dict[int, tuple[set, int]]:
        """Get (covered_nodes, total_nodes) for each level."""
        return {
            level: (
                self.covered_nodes_by_level.get(level, set()),
                self.total_nodes_by_level.get(level, 0)
            )
            for level in self.total_nodes_by_level.keys()
        }
    
    @property
    def overall_coverage(self) -> float:
        """Overall coverage across all levels."""
        total_covered = sum(len(c) for c in self.covered_nodes_by_level.values())
        total_nodes = sum(self.total_nodes_by_level.values())
        return total_covered / total_nodes if total_nodes > 0 else 0.0
    
    @property
    def missing_nodes_by_level(self) -> dict[int, list[str]]:
        """Nodes that have zero coverage at each level."""
        result = {}
        for level in self.total_nodes_by_level.keys():
            covered = self.covered_nodes_by_level.get(level, set())
            all_nodes = self._all_nodes_at_level.get(level, set())
            result[level] = list(all_nodes - covered)
        return result
    
    _all_nodes_at_level: dict[int, set] = field(default_factory=dict)


class SimulaCoverageEvaluator:
    """
    Evaluates taxonomic coverage of generated datasets.
    
    From Section 2.3:
    "Given a dataset, we can generate or use existing taxonomies that define
    the conceptual space of interest. We then query an M3 to perform taxonomy
    assignments for each data point by prompting it with the full taxonomy in
    context, linking each item to the most relevant node."
    """
    
    def __init__(
        self,
        llm_client: "SimulaLLMClient",
        config: CoverageConfig | None = None,
    ):
        self.llm = llm_client
        self.config = config or CoverageConfig.from_env()
    
    async def evaluate(
        self,
        examples: list["TrainingExample"],
        taxonomy: "Taxonomy",
    ) -> CoverageReport:
        """
        Evaluate coverage of examples against a taxonomy.
        
        Args:
            examples: Training examples to evaluate
            taxonomy: Taxonomy to measure coverage against
            
        Returns:
            CoverageReport with level ratio coverage metrics
        """
        # Sample if needed
        if self.config.sample_size > 0 and len(examples) > self.config.sample_size:
            import random
            examples = random.sample(examples, self.config.sample_size)
        
        # Initialize report
        report = CoverageReport(
            taxonomy_id=taxonomy.id,
            taxonomy_factor=taxonomy.factor,
        )
        
        # Count nodes at each level
        self._count_nodes_by_level(taxonomy.root, report, 0)
        
        # Serialize taxonomy for prompts
        taxonomy_tree = self._serialize_taxonomy(taxonomy.root)
        
        # Assign examples to taxonomy nodes
        logger.info(f"Assigning {len(examples)} examples to taxonomy '{taxonomy.factor}'")
        
        tasks = [
            self._assign_example(ex, taxonomy_tree, report)
            for ex in examples
        ]
        
        # Process in chunks
        chunk_size = 20
        for i in range(0, len(tasks), chunk_size):
            chunk = tasks[i:i + chunk_size]
            await asyncio.gather(*chunk)
        
        # Log results
        coverage = report.level_ratio_coverage
        logger.info(
            f"Coverage for '{taxonomy.factor}': "
            f"L1={coverage.get(1, 0):.1%}, L2={coverage.get(2, 0):.1%}, "
            f"L3={coverage.get(3, 0):.1%}, Overall={report.overall_coverage:.1%}"
        )
        
        return report
    
    def _count_nodes_by_level(
        self,
        node: "TaxonomyNode",
        report: CoverageReport,
        level: int,
    ) -> None:
        """Recursively count nodes at each taxonomy level."""
        if level > self.config.max_level:
            return
        
        report.total_nodes_by_level[level] = report.total_nodes_by_level.get(level, 0) + 1
        
        if level not in report._all_nodes_at_level:
            report._all_nodes_at_level[level] = set()
        report._all_nodes_at_level[level].add(node.id)
        
        for child in node.children:
            self._count_nodes_by_level(child, report, level + 1)
    
    def _serialize_taxonomy(self, node: "TaxonomyNode", indent: int = 0) -> str:
        """Serialize taxonomy tree for prompt."""
        lines = [f"{'  ' * indent}- {node.id}: {node.name}"]
        if node.description:
            lines[0] += f" ({node.description})"
        
        for child in node.children:
            lines.append(self._serialize_taxonomy(child, indent + 1))
        
        return "\n".join(lines)
    
    async def _assign_example(
        self,
        example: "TrainingExample",
        taxonomy_tree: str,
        report: CoverageReport,
    ) -> None:
        """Assign a single example to a taxonomy node."""
        prompt = self.config.assignment_prompt_template.format(
            taxonomy_tree=taxonomy_tree,
            question=example.question,
            sql=example.sql,
        )
        
        try:
            response = await self.llm.generate(prompt, temperature=0.1)
            assignment = self._parse_assignment(response.content)
            
            if assignment:
                node_id = assignment.get("node_id")
                path = assignment.get("path", [])
                
                report.assignments[example.id] = node_id
                
                # Mark coverage at each level in the path
                for level, node in enumerate(path):
                    if level not in report.covered_nodes_by_level:
                        report.covered_nodes_by_level[level] = set()
                    report.covered_nodes_by_level[level].add(node)
                
        except Exception as e:
            logger.debug(f"Failed to assign example {example.id}: {e}")
    
    def _parse_assignment(self, response: str) -> dict | None:
        """Parse taxonomy assignment from LLM response."""
        try:
            start = response.find("{")
            end = response.rfind("}") + 1
            if start >= 0 and end > start:
                return json.loads(response[start:end])
        except (json.JSONDecodeError, ValueError):
            pass
        return None
    
    async def evaluate_multiple(
        self,
        examples: list["TrainingExample"],
        taxonomies: list["Taxonomy"],
    ) -> dict[str, CoverageReport]:
        """Evaluate coverage against multiple taxonomies."""
        reports = {}
        for taxonomy in taxonomies:
            reports[taxonomy.id] = await self.evaluate(examples, taxonomy)
        return reports
    
    def export_report(
        self,
        report: CoverageReport,
        output_path: str,
    ) -> None:
        """Export coverage report to JSON."""
        data = {
            "taxonomy_id": report.taxonomy_id,
            "taxonomy_factor": report.taxonomy_factor,
            "level_ratio_coverage": report.level_ratio_coverage,
            "overall_coverage": report.overall_coverage,
            "total_nodes_by_level": report.total_nodes_by_level,
            "covered_nodes_by_level": {
                str(k): list(v) for k, v in report.covered_nodes_by_level.items()
            },
            "missing_nodes_by_level": report.missing_nodes_by_level,
            "assignment_count": len(report.assignments),
        }
        
        with open(output_path, "w") as f:
            json.dump(data, f, indent=2)
        
        logger.info(f"Exported coverage report to {output_path}")
    
    def export_all_reports(
        self,
        reports: dict[str, CoverageReport],
        output_path: str,
    ) -> None:
        """Export all coverage reports to a single JSON file."""
        data = {
            "taxonomies": {
                tax_id: {
                    "factor": report.taxonomy_factor,
                    "level_ratio_coverage": report.level_ratio_coverage,
                    "overall_coverage": report.overall_coverage,
                    "missing_nodes": report.missing_nodes_by_level,
                }
                for tax_id, report in reports.items()
            },
            "summary": {
                "taxonomies_evaluated": len(reports),
                "average_coverage": sum(r.overall_coverage for r in reports.values()) / len(reports) if reports else 0,
            },
        }
        
        with open(output_path, "w") as f:
            json.dump(data, f, indent=2)
        
        logger.info(f"Exported {len(reports)} coverage reports to {output_path}")


def identify_coverage_gaps(
    reports: dict[str, CoverageReport],
    threshold: float = 0.5,
) -> dict[str, list[str]]:
    """
    Identify taxonomic areas with insufficient coverage.
    
    From Section 2.3:
    "This provides a fine-grained, actionable view into a dataset's composition,
    highlighting both well-represented areas and potential gaps to fill."
    
    Args:
        reports: Coverage reports for each taxonomy
        threshold: Minimum coverage ratio to consider "sufficient"
        
    Returns:
        Dict mapping taxonomy_id to list of under-covered node IDs
    """
    gaps = {}
    for tax_id, report in reports.items():
        under_covered = []
        for level, nodes in report.missing_nodes_by_level.items():
            under_covered.extend(nodes)
        
        # Also include partially covered areas
        for level, coverage in report.level_ratio_coverage.items():
            if coverage < threshold:
                under_covered.extend(
                    report._all_nodes_at_level.get(level, set()) - 
                    report.covered_nodes_by_level.get(level, set())
                )
        
        if under_covered:
            gaps[tax_id] = list(set(under_covered))
    
    return gaps


async def fill_coverage_gaps(
    gaps: dict[str, list[str]],
    generator: "SimulaDataGenerator",
    examples_per_node: int = 10,
) -> list["TrainingExample"]:
    """
    Generate additional examples to fill coverage gaps.
    
    From Section 2.3: "Using taxonomies offers a way forward not only for
    generating synthetic data, but also for better understanding existing data."
    
    This function addresses the gap: "The spec does not provide an automatic
    resampling mechanism to fill identified gaps."
    
    Args:
        gaps: Dict mapping taxonomy_id to list of under-covered node names
        generator: SimulaDataGenerator instance for creating examples
        examples_per_node: Number of examples to generate per gap node
        
    Returns:
        List of newly generated TrainingExample instances
    """
    from .simula_data_generator import TrainingExample
    
    additional_examples: list[TrainingExample] = []
    total_nodes = sum(len(nodes) for nodes in gaps.values())
    
    if total_nodes == 0:
        logger.info("No coverage gaps to fill")
        return additional_examples
    
    logger.info(
        f"Filling {total_nodes} coverage gaps with {examples_per_node} examples each "
        f"(target: {total_nodes * examples_per_node} examples)"
    )
    
    for taxonomy_id, node_names in gaps.items():
        for node_name in node_names:
            try:
                # Generate examples specifically targeting this node
                node_examples = await generator.generate_for_node(
                    taxonomy_name=taxonomy_id,
                    node_name=node_name,
                    count=examples_per_node,
                )
                additional_examples.extend(node_examples)
                logger.debug(f"Generated {len(node_examples)} examples for {taxonomy_id}/{node_name}")
            except Exception as e:
                logger.warning(f"Failed to fill gap {taxonomy_id}/{node_name}: {e}")
    
    logger.info(f"Generated {len(additional_examples)} examples to fill coverage gaps")
    return additional_examples
