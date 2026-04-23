"""
simula_taxonomy_builder.py — Reasoning-driven taxonomy generation (Algorithm 1).

Implements the Simula framework's taxonomy building approach:
1. Factor identification from schema metadata
2. Breadth-first taxonomy expansion with Best-of-N sampling
3. Generator-critic refinement loop
4. Level planning for consistent granularity

Reference: "Reasoning-Driven Synthetic Data Generation and Evaluation" (2026)
"""
from __future__ import annotations

import asyncio
import json
import logging
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

from .simula_config import TaxonomyConfig, LLMConfig
from .simula_llm_client import SimulaLLMClient
from .schema_registry import SchemaRegistry, TableSchema, Column

logger = logging.getLogger(__name__)


@dataclass
class TaxonomyNode:
    """
    A node in the taxonomy tree.
    
    Schema-compliant with docs/schema/simula/taxonomy.schema.json#/definitions/taxonomy_node.
    Required fields: node_id, name, node_type
    """
    # Required fields per schema
    name: str
    node_id: str = ""  # Unique identifier within taxonomy
    node_type: str = "FACTOR"  # ROOT, FACTOR, LEAF
    
    # Optional fields per schema
    description: str = ""
    level: int = 0
    path: str = ""  # Full path from root (e.g., query_type/aggregation/sum)
    examples: list[str] = field(default_factory=list)
    sampling_weight: float = 1.0
    sample_count: int = 0
    coverage_ratio: Optional[float] = None
    
    # Internal fields (not in schema)
    parent: Optional["TaxonomyNode"] = None
    children: list["TaxonomyNode"] = field(default_factory=list)
    metadata: dict = field(default_factory=dict)
    
    def __post_init__(self):
        """Post-initialization to generate node_id and path if not provided."""
        if not self.node_id:
            self.node_id = self._generate_node_id()
        if not self.path:
            self.path = self._compute_path()
        if not self.node_type:
            self.node_type = self._infer_node_type()
    
    def _generate_node_id(self) -> str:
        """Generate a unique node ID based on path."""
        return self.name.lower().replace(" ", "_").replace("-", "_")
    
    def _compute_path(self) -> str:
        """Compute the full path from root."""
        ancestors = self.get_ancestors()
        return "/".join(ancestors + [self.name]) if ancestors else self.name
    
    def _infer_node_type(self) -> str:
        """Infer node type based on position in tree."""
        if self.parent is None and self.level == 0:
            return "ROOT"
        elif not self.children:
            return "LEAF"
        return "FACTOR"
    
    # Alias properties for schema compatibility
    @property
    def id(self) -> str:
        """Alias for node_id (used by evaluators)."""
        return self.node_id
    
    @id.setter
    def id(self, value: str):
        """Setter for id alias."""
        self.node_id = value
    
    def add_child(self, name: str, description: str = "", **metadata) -> "TaxonomyNode":
        """Add a child node."""
        child = TaxonomyNode(
            name=name,
            description=description,
            parent=self,
            level=self.level + 1,
            node_type="LEAF",  # Will be updated if children are added
            metadata=metadata,
        )
        # Update path after setting parent
        child.path = child._compute_path()
        child.node_id = child._generate_node_id()
        self.children.append(child)
        # Update parent node_type since it now has children
        if self.node_type == "LEAF":
            self.node_type = "FACTOR"
        return child
    
    def get_ancestors(self) -> list[str]:
        """Get list of ancestor names from root to parent."""
        ancestors = []
        node = self.parent
        while node:
            ancestors.insert(0, node.name)
            node = node.parent
        return ancestors
    
    def get_siblings(self) -> list[str]:
        """Get names of sibling nodes."""
        if not self.parent:
            return []
        return [c.name for c in self.parent.children if c != self]
    
    def get_leaf_nodes(self) -> list["TaxonomyNode"]:
        """Get all leaf nodes under this node."""
        if not self.children:
            return [self]
        leaves = []
        for child in self.children:
            leaves.extend(child.get_leaf_nodes())
        return leaves
    
    def to_dict(self) -> dict:
        """
        Serialize to dictionary.
        
        Produces schema-compliant output per docs/schema/simula/taxonomy.schema.json.
        """
        result = {
            # Required fields
            "node_id": self.node_id,
            "name": self.name,
            "node_type": self.node_type,
        }
        
        # Optional fields (include only if set/non-default)
        if self.description:
            result["description"] = self.description
        result["level"] = self.level
        if self.path:
            result["path"] = self.path
        if self.children:
            result["children"] = [c.to_dict() for c in self.children]
        if self.examples:
            result["examples"] = self.examples
        if self.sampling_weight != 1.0:
            result["sampling_weight"] = self.sampling_weight
        if self.sample_count > 0:
            result["sample_count"] = self.sample_count
        if self.coverage_ratio is not None:
            result["coverage_ratio"] = self.coverage_ratio
        
        return result
    
    def to_legacy_dict(self) -> dict:
        """Serialize to legacy dictionary format for backward compatibility."""
        return {
            "name": self.name,
            "description": self.description,
            "level": self.level,
            "metadata": self.metadata,
            "children": [c.to_legacy_dict() for c in self.children],
        }
    
    @classmethod
    def from_dict(cls, data: dict, parent: Optional["TaxonomyNode"] = None) -> "TaxonomyNode":
        """Deserialize from dictionary (handles both schema and legacy formats)."""
        node = cls(
            name=data["name"],
            node_id=data.get("node_id", ""),
            node_type=data.get("node_type", "FACTOR"),
            description=data.get("description", ""),
            parent=parent,
            level=data.get("level", 0),
            path=data.get("path", ""),
            examples=data.get("examples", []),
            sampling_weight=data.get("sampling_weight", 1.0),
            sample_count=data.get("sample_count", 0),
            coverage_ratio=data.get("coverage_ratio"),
            metadata=data.get("metadata", {}),
        )
        for child_data in data.get("children", []):
            child = cls.from_dict(child_data, parent=node)
            node.children.append(child)
        return node


@dataclass
class TaxonomyStatistics:
    """Taxonomy statistics per schema."""
    total_nodes: int = 0
    leaf_count: int = 0
    factor_count: int = 0
    max_depth: int = 0
    avg_branching_factor: float = 0.0
    level_distribution: dict[str, int] = field(default_factory=dict)
    
    def to_dict(self) -> dict:
        """Serialize to dictionary."""
        return {
            "total_nodes": self.total_nodes,
            "leaf_count": self.leaf_count,
            "factor_count": self.factor_count,
            "max_depth": self.max_depth,
            "avg_branching_factor": self.avg_branching_factor,
            "level_distribution": self.level_distribution,
        }


@dataclass
class TaxonomyGenerationMetadata:
    """Metadata about how taxonomy was generated."""
    method: str = "llm_generated"  # llm_generated, manual, hybrid, imported
    model: str = ""
    best_of_n: int = 5
    target_depth: int = 4
    generated_at: Optional[str] = None
    source_factors: list[str] = field(default_factory=list)
    seed: Optional[int] = None
    
    def to_dict(self) -> dict:
        """Serialize to dictionary."""
        result = {
            "method": self.method,
            "best_of_n": self.best_of_n,
            "target_depth": self.target_depth,
        }
        if self.model:
            result["model"] = self.model
        if self.generated_at:
            result["generated_at"] = self.generated_at
        if self.source_factors:
            result["source_factors"] = self.source_factors
        if self.seed is not None:
            result["seed"] = self.seed
        return result


@dataclass
class TaxonomyQualityMetrics:
    """Quality metrics from taxonomy evaluation."""
    completeness: Optional[float] = None  # Target: >70%
    soundness: Optional[float] = None  # Target: >90%
    expert_taxonomy_path: str = ""
    evaluated_at: Optional[str] = None
    passed_quality_gate: Optional[bool] = None
    
    def to_dict(self) -> dict:
        """Serialize to dictionary."""
        result = {}
        if self.completeness is not None:
            result["completeness"] = self.completeness
        if self.soundness is not None:
            result["soundness"] = self.soundness
        if self.expert_taxonomy_path:
            result["expert_taxonomy_path"] = self.expert_taxonomy_path
        if self.evaluated_at:
            result["evaluated_at"] = self.evaluated_at
        if self.passed_quality_gate is not None:
            result["passed_quality_gate"] = self.passed_quality_gate
        return result


@dataclass
class Taxonomy:
    """
    A complete taxonomy tree for a factor of variation.
    
    Schema-compliant with docs/schema/simula/taxonomy.schema.json.
    Required fields: taxonomy_id, name, root, metadata
    """
    # Required fields per schema
    root: TaxonomyNode
    
    # Fields with defaults
    taxonomy_id: str = ""  # Unique identifier for this taxonomy
    name: str = ""  # Taxonomy name (e.g., query_type)
    description: str = ""
    domain: str = ""  # Domain this taxonomy applies to
    schema_context: str = ""  # Reference to HANA schema
    
    # Complex fields
    statistics: Optional[TaxonomyStatistics] = None
    generation_metadata: Optional[TaxonomyGenerationMetadata] = None
    quality_metrics: Optional[TaxonomyQualityMetrics] = None
    
    # Legacy fields for backward compatibility
    factor_name: str = ""  # Maps to name
    source_column: Optional[str] = None
    
    def __post_init__(self):
        """Post-initialization to sync legacy and schema fields."""
        # Sync factor_name <-> name
        if self.factor_name and not self.name:
            self.name = self.factor_name
        elif self.name and not self.factor_name:
            self.factor_name = self.name
        
        # Generate taxonomy_id if not set
        if not self.taxonomy_id:
            self.taxonomy_id = f"tax_{self.name}".lower().replace(" ", "_")
        
        # Compute statistics if not set
        if not self.statistics:
            self.statistics = self._compute_statistics()
    
    # Alias properties for schema compatibility
    @property
    def id(self) -> str:
        """Alias for taxonomy_id (used by evaluators)."""
        return self.taxonomy_id
    
    @id.setter
    def id(self, value: str):
        """Setter for id alias."""
        self.taxonomy_id = value
    
    @property
    def factor(self) -> str:
        """Alias for factor_name/name (used by evaluators)."""
        return self.factor_name or self.name
    
    @factor.setter
    def factor(self, value: str):
        """Setter for factor alias."""
        self.factor_name = value
        self.name = value
    
    def _compute_statistics(self) -> TaxonomyStatistics:
        """Compute taxonomy statistics."""
        total_nodes = 0
        leaf_count = 0
        factor_count = 0
        max_depth = 0
        level_distribution: dict[str, int] = {}
        branching_sum = 0
        non_leaf_count = 0
        
        def traverse(node: TaxonomyNode):
            nonlocal total_nodes, leaf_count, factor_count, max_depth, branching_sum, non_leaf_count
            total_nodes += 1
            
            level_key = str(node.level)
            level_distribution[level_key] = level_distribution.get(level_key, 0) + 1
            
            if node.level > max_depth:
                max_depth = node.level
            
            if not node.children:
                leaf_count += 1
            else:
                if node.level > 0:  # Don't count root as factor
                    factor_count += 1
                branching_sum += len(node.children)
                non_leaf_count += 1
                for child in node.children:
                    traverse(child)
        
        traverse(self.root)
        
        avg_branching = branching_sum / non_leaf_count if non_leaf_count > 0 else 0.0
        
        return TaxonomyStatistics(
            total_nodes=total_nodes,
            leaf_count=leaf_count,
            factor_count=factor_count,
            max_depth=max_depth,
            avg_branching_factor=avg_branching,
            level_distribution=level_distribution,
        )
    
    @property
    def depth(self) -> int:
        """Calculate maximum depth of the taxonomy."""
        if self.statistics:
            return self.statistics.max_depth
        
        def _max_depth(node: TaxonomyNode) -> int:
            if not node.children:
                return node.level
            return max(_max_depth(c) for c in node.children)
        return _max_depth(self.root)
    
    @property
    def node_count(self) -> int:
        """Count total nodes in taxonomy."""
        if self.statistics:
            return self.statistics.total_nodes
        
        def _count(node: TaxonomyNode) -> int:
            return 1 + sum(_count(c) for c in node.children)
        return _count(self.root)
    
    def get_nodes_at_level(self, level: int) -> list[TaxonomyNode]:
        """Get all nodes at a specific level."""
        def _collect(node: TaxonomyNode, target_level: int) -> list[TaxonomyNode]:
            if node.level == target_level:
                return [node]
            nodes = []
            for child in node.children:
                nodes.extend(_collect(child, target_level))
            return nodes
        return _collect(self.root, level)
    
    def get_leaf_nodes(self) -> list[TaxonomyNode]:
        """Get all leaf nodes."""
        return self.root.get_leaf_nodes()
    
    def to_dict(self) -> dict:
        """
        Serialize to dictionary.
        
        Produces schema-compliant output per docs/schema/simula/taxonomy.schema.json.
        """
        result = {
            # Required fields
            "taxonomy_id": self.taxonomy_id,
            "name": self.name,
            "root": self.root.to_dict(),
            "metadata": {
                "created_at": self.generation_metadata.generated_at if self.generation_metadata else None,
            },
        }
        
        # Optional fields
        if self.description:
            result["description"] = self.description
        if self.domain:
            result["domain"] = self.domain
        if self.schema_context:
            result["schema_context"] = self.schema_context
        if self.statistics:
            result["statistics"] = self.statistics.to_dict()
        if self.generation_metadata:
            result["generation_metadata"] = self.generation_metadata.to_dict()
        if self.quality_metrics:
            result["quality_metrics"] = self.quality_metrics.to_dict()
        
        return result
    
    def to_legacy_dict(self) -> dict:
        """Serialize to legacy dictionary format for backward compatibility."""
        return {
            "factor_name": self.factor_name,
            "description": self.description,
            "source_column": self.source_column,
            "depth": self.depth,
            "node_count": self.node_count,
            "root": self.root.to_legacy_dict(),
        }
    
    @classmethod
    def from_dict(cls, data: dict) -> "Taxonomy":
        """Deserialize from dictionary (handles both schema and legacy formats)."""
        # Handle legacy format (factor_name)
        factor_name = data.get("factor_name", "")
        name = data.get("name", factor_name)
        taxonomy_id = data.get("taxonomy_id", "")
        
        # Parse statistics if present
        statistics = None
        if "statistics" in data:
            stats_data = data["statistics"]
            statistics = TaxonomyStatistics(
                total_nodes=stats_data.get("total_nodes", 0),
                leaf_count=stats_data.get("leaf_count", 0),
                factor_count=stats_data.get("factor_count", 0),
                max_depth=stats_data.get("max_depth", 0),
                avg_branching_factor=stats_data.get("avg_branching_factor", 0.0),
                level_distribution=stats_data.get("level_distribution", {}),
            )
        
        # Parse generation_metadata if present
        gen_metadata = None
        if "generation_metadata" in data:
            gm_data = data["generation_metadata"]
            gen_metadata = TaxonomyGenerationMetadata(
                method=gm_data.get("method", "llm_generated"),
                model=gm_data.get("model", ""),
                best_of_n=gm_data.get("best_of_n", 5),
                target_depth=gm_data.get("target_depth", 4),
                generated_at=gm_data.get("generated_at"),
                source_factors=gm_data.get("source_factors", []),
                seed=gm_data.get("seed"),
            )
        
        # Parse quality_metrics if present
        quality_metrics = None
        if "quality_metrics" in data:
            qm_data = data["quality_metrics"]
            quality_metrics = TaxonomyQualityMetrics(
                completeness=qm_data.get("completeness"),
                soundness=qm_data.get("soundness"),
                expert_taxonomy_path=qm_data.get("expert_taxonomy_path", ""),
                evaluated_at=qm_data.get("evaluated_at"),
                passed_quality_gate=qm_data.get("passed_quality_gate"),
            )
        
        return cls(
            taxonomy_id=taxonomy_id,
            name=name,
            factor_name=factor_name,
            description=data.get("description", ""),
            domain=data.get("domain", ""),
            schema_context=data.get("schema_context", ""),
            source_column=data.get("source_column"),
            root=TaxonomyNode.from_dict(data["root"]),
            statistics=statistics,
            generation_metadata=gen_metadata,
            quality_metrics=quality_metrics,
        )


@dataclass
class Factor:
    """A factor of variation identified from schema."""
    name: str
    factor_type: str  # "dimension", "measure", "date", "aggregation", "filter"
    description: str = ""
    source_columns: list[str] = field(default_factory=list)
    sample_values: list[str] = field(default_factory=list)


class SimulaTaxonomyBuilder:
    """
    Build taxonomies from schema using reasoning-driven approach.
    
    Implements Algorithm 1 from the Simula paper:
    1. Factor disentanglement from schema
    2. Breadth-first taxonomic expansion
    3. Best-of-N proposal generation
    4. Critic refinement
    5. Level planning for consistency
    """
    
    def __init__(
        self,
        llm_config: LLMConfig | None = None,
        taxonomy_config: TaxonomyConfig | None = None,
    ):
        self.llm_config = llm_config or LLMConfig()
        self.taxonomy_config = taxonomy_config or TaxonomyConfig()
        self._llm_client: SimulaLLMClient | None = None
    
    @property
    def llm_client(self) -> SimulaLLMClient:
        if self._llm_client is None:
            self._llm_client = SimulaLLMClient(self.llm_config)
        return self._llm_client
    
    async def close(self):
        """Close LLM client."""
        if self._llm_client:
            await self._llm_client.close()
    
    # =========================================================================
    # Phase 1: Factor Disentanglement
    # =========================================================================
    
    def identify_factors_from_schema(self, registry: SchemaRegistry) -> list[Factor]:
        """
        Identify prime factors of variation from schema metadata.
        
        Extracts:
        - Dimension factors (VARCHAR columns)
        - Measure factors (DECIMAL/INTEGER columns)
        - Date factors (DATE/TIMESTAMP columns)
        - Standard SQL patterns (aggregations, filters)
        """
        factors = []
        
        # Collect columns across all tables
        dimension_cols = set()
        measure_cols = set()
        date_cols = set()
        
        for table in registry.tables:
            for col in table.columns:
                col_lower = col.name.lower()
                dtype = col.data_type.upper()
                
                if dtype.startswith("VARCHAR") or dtype.startswith("NVARCHAR") or dtype == "CHAR":
                    # Dimension column
                    dimension_cols.add((col.name, col.description or col.name))
                elif dtype.startswith("DECIMAL") or dtype == "INTEGER" or dtype == "BIGINT":
                    # Measure column
                    measure_cols.add((col.name, col.description or col.name))
                elif dtype in ("DATE", "TIMESTAMP", "TIME"):
                    # Date column
                    date_cols.add((col.name, col.description or col.name))
        
        # Create dimension factors
        for col_name, desc in dimension_cols:
            factors.append(Factor(
                name=f"dim_{col_name.lower()}",
                factor_type="dimension",
                description=f"Dimension: {desc}",
                source_columns=[col_name],
            ))
        
        # Create measure factors
        for col_name, desc in measure_cols:
            factors.append(Factor(
                name=f"measure_{col_name.lower()}",
                factor_type="measure",
                description=f"Measure: {desc}",
                source_columns=[col_name],
            ))
        
        # Create date factors
        for col_name, desc in date_cols:
            factors.append(Factor(
                name=f"date_{col_name.lower()}",
                factor_type="date",
                description=f"Date: {desc}",
                source_columns=[col_name],
            ))
        
        # Add standard aggregation factor
        factors.append(Factor(
            name="aggregation",
            factor_type="aggregation",
            description="SQL aggregation functions",
            sample_values=["SUM", "AVG", "COUNT", "MIN", "MAX", "COUNT DISTINCT"],
        ))
        
        # Add standard filter operations factor
        factors.append(Factor(
            name="filter_operation",
            factor_type="filter",
            description="SQL filter operations",
            sample_values=["=", ">", "<", ">=", "<=", "BETWEEN", "IN", "LIKE", "IS NULL"],
        ))
        
        # Add query complexity factor
        factors.append(Factor(
            name="query_complexity",
            factor_type="complexity",
            description="Query complexity levels",
            sample_values=["simple_select", "aggregation", "group_by", "join", "subquery", "cte", "window_function"],
        ))
        
        return factors
    
    async def identify_factors_with_llm(
        self,
        registry: SchemaRegistry,
        domain_description: str = "",
    ) -> list[Factor]:
        """
        Use LLM to identify additional factors of variation.
        
        Args:
            registry: Schema registry
            domain_description: Optional description of the data domain
            
        Returns:
            List of identified factors
        """
        # Start with schema-derived factors
        factors = self.identify_factors_from_schema(registry)
        
        # Use LLM to identify additional semantic factors
        schema_summary = self._summarize_schema(registry)
        
        system_prompt = """You are an expert in data analysis and SQL query patterns.
Your task is to identify semantic factors of variation for generating diverse SQL training data.
Focus on identifying meaningful business concepts and query patterns."""
        
        prompt = f"""Analyze this database schema and identify semantic factors of variation
that would be useful for generating diverse Text-to-SQL training data.

DOMAIN DESCRIPTION:
{domain_description or "Enterprise financial and analytics data"}

SCHEMA SUMMARY:
{schema_summary}

EXISTING FACTORS:
{json.dumps([{"name": f.name, "type": f.factor_type} for f in factors[:10]], indent=2)}

Identify 3-5 ADDITIONAL semantic factors that capture meaningful variation in:
1. Business questions users might ask
2. Query patterns and complexity
3. Domain-specific concepts

Respond with JSON:
{{
    "factors": [
        {{"name": "factor_name", "type": "dimension|measure|pattern", "description": "...", "examples": ["...", "..."]}}
    ]
}}"""
        
        try:
            result = await self.llm_client.generate_json(
                prompt=prompt,
                system_prompt=system_prompt,
                temperature=0.7,
            )
            
            for factor_data in result.get("factors", []):
                factors.append(Factor(
                    name=factor_data.get("name", "unknown"),
                    factor_type=factor_data.get("type", "dimension"),
                    description=factor_data.get("description", ""),
                    sample_values=factor_data.get("examples", []),
                ))
            
        except Exception as e:
            logger.warning(f"LLM factor identification failed: {e}")
        
        return factors
    
    def _summarize_schema(self, registry: SchemaRegistry) -> str:
        """Create a text summary of the schema for LLM context."""
        lines = []
        for table in registry.tables[:10]:  # Limit for context length
            cols = ", ".join(f"{c.name}:{c.data_type}" for c in table.columns[:8])
            lines.append(f"- {table.schema_name}.{table.name}: {cols}")
        return "\n".join(lines)
    
    # =========================================================================
    # Phase 2: Taxonomy Expansion (Algorithm 1)
    # =========================================================================
    
    async def build_taxonomy(
        self,
        factor: Factor,
        target_depth: int | None = None,
    ) -> Taxonomy:
        """
        Build a taxonomy for a single factor using breadth-first expansion.
        
        Args:
            factor: Factor to expand
            target_depth: Maximum depth (defaults to config)
            
        Returns:
            Complete Taxonomy
        """
        target_depth = target_depth or self.taxonomy_config.depth
        
        # Create root node
        root = TaxonomyNode(
            name=factor.name,
            description=factor.description,
            level=0,
            metadata={"factor_type": factor.factor_type},
        )
        
        # Initialize with sample values if available
        if factor.sample_values:
            for value in factor.sample_values:
                root.add_child(value, description=f"{factor.name}: {value}")
        else:
            # Use LLM to generate initial children
            initial_children = await self._propose_children(
                root, factor.description
            )
            for child_name, child_desc in initial_children:
                root.add_child(child_name, description=child_desc)
        
        # Breadth-first expansion
        for depth in range(1, target_depth):
            nodes_at_level = [root] if depth == 1 else self._get_nodes_at_level(root, depth - 1)
            
            # Optional: Generate level plan for consistency
            level_plan = ""
            if self.taxonomy_config.enable_level_planning:
                level_plan = await self._generate_level_plan(
                    factor, depth, nodes_at_level
                )
            
            # Expand each node at current level
            for node in nodes_at_level:
                if node.children:  # Skip if already has children
                    continue
                
                # Step 1: Best-of-N proposal generation
                proposals = await self._propose_children_best_of_n(
                    node, factor.description, level_plan
                )
                
                # Step 2: Critic refinement
                if self.taxonomy_config.enable_critic:
                    proposals = await self._critic_refine(
                        node, proposals, factor.description
                    )
                
                # Add refined children
                for child_name, child_desc in proposals:
                    node.add_child(child_name, description=child_desc)
        
        return Taxonomy(
            factor_name=factor.name,
            root=root,
            description=factor.description,
            source_column=factor.source_columns[0] if factor.source_columns else None,
        )
    
    def _get_nodes_at_level(self, root: TaxonomyNode, level: int) -> list[TaxonomyNode]:
        """Get all nodes at a specific level."""
        if level == 0:
            return [root]
        
        nodes = []
        def collect(node: TaxonomyNode):
            if node.level == level:
                nodes.append(node)
            for child in node.children:
                collect(child)
        
        collect(root)
        return nodes
    
    async def _propose_children(
        self,
        node: TaxonomyNode,
        factor_description: str,
    ) -> list[tuple[str, str]]:
        """Propose child nodes for expansion."""
        system_prompt = """You are expanding a taxonomy for training data generation.
Generate diverse, specific child categories that are mutually exclusive and collectively exhaustive."""
        
        ancestors = " > ".join(node.get_ancestors() + [node.name])
        siblings = node.get_siblings()
        
        prompt = f"""Expand this taxonomy node with 4-6 child categories:

FACTOR: {factor_description}
PATH: {ancestors}
SIBLINGS (avoid overlap): {siblings if siblings else "None"}

Generate diverse subcategories. Respond with JSON:
{{
    "children": [
        {{"name": "category_name", "description": "brief description"}}
    ]
}}"""
        
        try:
            result = await self.llm_client.generate_json(
                prompt=prompt,
                system_prompt=system_prompt,
                temperature=0.7,
            )
            
            return [
                (c.get("name", "unknown"), c.get("description", ""))
                for c in result.get("children", [])
            ]
        except Exception as e:
            logger.warning(f"Child proposal failed: {e}")
            return []
    
    async def _propose_children_best_of_n(
        self,
        node: TaxonomyNode,
        factor_description: str,
        level_plan: str = "",
    ) -> list[tuple[str, str]]:
        """
        Generate child proposals using Best-of-N sampling.
        
        Generates N diverse proposals and merges unique children.
        """
        system_prompt = """You are expanding a taxonomy for training data generation.
Generate diverse, specific child categories that are mutually exclusive and collectively exhaustive.
Focus on covering edge cases and uncommon instances."""
        
        ancestors = " > ".join(node.get_ancestors() + [node.name])
        siblings = node.get_siblings()
        
        prompt = f"""Expand this taxonomy node with child categories:

FACTOR: {factor_description}
PATH: {ancestors}
SIBLINGS (avoid overlap): {siblings if siblings else "None"}
{f"LEVEL GUIDANCE: {level_plan}" if level_plan else ""}

Generate 4-6 diverse subcategories covering common and edge cases.
Respond with JSON:
{{
    "children": [
        {{"name": "category_name", "description": "brief description"}}
    ]
}}"""
        
        # Best-of-N sampling
        n = self.taxonomy_config.best_of_n
        responses = await self.llm_client.best_of_n(
            prompt=prompt,
            n=n,
            system_prompt=system_prompt,
            temperature=0.8,
        )
        
        # Merge unique children from all responses
        seen_names = set()
        children = []
        
        for response_text in responses:
            try:
                # Parse JSON from response
                if "```json" in response_text:
                    start = response_text.find("```json") + 7
                    end = response_text.find("```", start)
                    response_text = response_text[start:end].strip()
                elif "```" in response_text:
                    start = response_text.find("```") + 3
                    end = response_text.find("```", start)
                    response_text = response_text[start:end].strip()
                
                result = json.loads(response_text)
                
                for c in result.get("children", []):
                    name = c.get("name", "").strip()
                    if name and name.lower() not in seen_names:
                        seen_names.add(name.lower())
                        children.append((name, c.get("description", "")))
                        
            except json.JSONDecodeError:
                continue
        
        return children
    
    async def _critic_refine(
        self,
        node: TaxonomyNode,
        proposals: list[tuple[str, str]],
        factor_description: str,
    ) -> list[tuple[str, str]]:
        """
        Apply critic refinement to proposed children.
        
        The critic can:
        - Add missing categories
        - Remove irrelevant ones
        - Merge duplicates
        - Edit for clarity
        """
        if not proposals:
            return proposals
        
        system_prompt = """You are a taxonomy critic ensuring quality and completeness.
Review the proposed categories and improve them."""
        
        ancestors = " > ".join(node.get_ancestors() + [node.name])
        
        prompt = f"""Review and improve these taxonomy children:

FACTOR: {factor_description}
PATH: {ancestors}

PROPOSED CHILDREN:
{json.dumps([{"name": n, "description": d} for n, d in proposals], indent=2)}

Evaluate for:
1. COMPLETENESS: Are important categories missing?
2. SOUNDNESS: Are any irrelevant or inappropriate?
3. SPECIFICITY: Are they at the right granularity level?
4. OVERLAP: Should any be merged?

Respond with the refined list as JSON:
{{
    "children": [
        {{"name": "category_name", "description": "brief description"}}
    ],
    "changes_made": "brief summary of changes"
}}"""
        
        try:
            result = await self.llm_client.generate_json(
                prompt=prompt,
                system_prompt=system_prompt,
                temperature=0.3,  # Lower temperature for consistent refinement
            )
            
            refined = [
                (c.get("name", ""), c.get("description", ""))
                for c in result.get("children", [])
                if c.get("name")
            ]
            
            if result.get("changes_made"):
                logger.debug(f"Critic refined {node.name}: {result['changes_made']}")
            
            return refined if refined else proposals
            
        except Exception as e:
            logger.warning(f"Critic refinement failed: {e}")
            return proposals
    
    async def _generate_level_plan(
        self,
        factor: Factor,
        level: int,
        parent_nodes: list[TaxonomyNode],
    ) -> str:
        """
        Generate a plan for consistent expansion at a taxonomy level.
        
        Ensures similar granularity across different branches.
        """
        system_prompt = """You are planning taxonomy expansion for consistent granularity."""
        
        parent_names = [n.name for n in parent_nodes[:10]]
        
        prompt = f"""Plan the expansion strategy for taxonomy level {level}:

FACTOR: {factor.description}
PARENT NODES: {parent_names}

Provide brief guidance for what granularity and type of subcategories
should be generated at this level. Keep it to 1-2 sentences."""
        
        try:
            response = await self.llm_client.generate(
                prompt=prompt,
                system_prompt=system_prompt,
                temperature=0.5,
                max_tokens=100,
            )
            return response.content.strip()
        except Exception:
            return ""
    
    # =========================================================================
    # Build All Taxonomies
    # =========================================================================
    
    async def build_all_taxonomies(
        self,
        registry: SchemaRegistry,
        domain_description: str = "",
        max_taxonomies: int = 20,
    ) -> list[Taxonomy]:
        """
        Build taxonomies for all identified factors.
        
        Args:
            registry: Schema registry
            domain_description: Optional domain description
            max_taxonomies: Maximum number of taxonomies to build
            
        Returns:
            List of Taxonomy objects
        """
        # Identify factors
        factors = await self.identify_factors_with_llm(registry, domain_description)
        logger.info(f"Identified {len(factors)} factors")
        
        # Limit factors
        factors = factors[:max_taxonomies]
        
        # Build taxonomies concurrently (with limit)
        taxonomies = []
        semaphore = asyncio.Semaphore(4)  # Limit concurrent builds
        
        async def build_with_limit(factor: Factor) -> Taxonomy | None:
            async with semaphore:
                try:
                    return await self.build_taxonomy(factor)
                except Exception as e:
                    logger.error(f"Failed to build taxonomy for {factor.name}: {e}")
                    return None
        
        tasks = [build_with_limit(f) for f in factors]
        results = await asyncio.gather(*tasks)
        
        for taxonomy in results:
            if taxonomy:
                taxonomies.append(taxonomy)
                logger.info(f"Built taxonomy: {taxonomy.factor_name} (depth={taxonomy.depth}, nodes={taxonomy.node_count})")
        
        return taxonomies
    
    # =========================================================================
    # Serialization
    # =========================================================================
    
    def save_taxonomies(self, taxonomies: list[Taxonomy], path: str | Path):
        """Save taxonomies to JSON file."""
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        
        data = {
            "taxonomies": [t.to_dict() for t in taxonomies],
            "count": len(taxonomies),
        }
        
        with open(path, "w") as f:
            json.dump(data, f, indent=2)
        
        logger.info(f"Saved {len(taxonomies)} taxonomies to {path}")
    
    @staticmethod
    def load_taxonomies(path: str | Path) -> list[Taxonomy]:
        """Load taxonomies from JSON file."""
        with open(path) as f:
            data = json.load(f)
        
        return [Taxonomy.from_dict(t) for t in data.get("taxonomies", [])]


# Convenience functions
async def build_taxonomies(
    registry: SchemaRegistry,
    llm_config: LLMConfig | None = None,
    taxonomy_config: TaxonomyConfig | None = None,
    domain_description: str = "",
) -> list[Taxonomy]:
    """
    Build taxonomies from schema registry.
    
    Args:
        registry: Schema registry with table definitions
        llm_config: LLM configuration
        taxonomy_config: Taxonomy building configuration
        domain_description: Optional domain description
        
    Returns:
        List of Taxonomy objects
    """
    builder = SimulaTaxonomyBuilder(llm_config, taxonomy_config)
    try:
        return await builder.build_all_taxonomies(registry, domain_description)
    finally:
        await builder.close()


def build_taxonomies_sync(
    registry: SchemaRegistry,
    llm_config: LLMConfig | None = None,
    taxonomy_config: TaxonomyConfig | None = None,
    domain_description: str = "",
) -> list[Taxonomy]:
    """Synchronous wrapper for build_taxonomies."""
    return asyncio.run(build_taxonomies(
        registry, llm_config, taxonomy_config, domain_description
    ))