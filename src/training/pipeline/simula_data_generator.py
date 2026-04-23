"""
simula_data_generator.py — Reasoning-driven synthetic data generation (Algorithm 2).

Implements the Simula framework's agentic data synthesis:
1. Taxonomic sampling for global diversity
2. Meta-prompt generation for local diversity
3. Complexification for difficulty control
4. Double-critic filtering for quality

Reference: "Reasoning-Driven Synthetic Data Generation and Evaluation" (2026)
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import random
import re
from dataclasses import dataclass, field
from datetime import datetime
from itertools import product
from pathlib import Path
from typing import Iterator, Optional

from .simula_config import GenerationConfig, LLMConfig
from .simula_llm_client import SimulaLLMClient
from .simula_taxonomy_builder import Taxonomy, TaxonomyNode
from .schema_registry import SchemaRegistry, TableSchema

logger = logging.getLogger(__name__)


@dataclass
class CriticEvaluation:
    """Double-critic evaluation results (Step 5 of Algorithm 2)."""
    verdict: str = "ACCEPT"  # ACCEPT, REVISE, REJECT
    correct_query_response: str = ""
    correct_query_answer: str = ""  # YES, NO, UNCERTAIN
    incorrect_query_response: str = ""
    incorrect_query_answer: str = ""  # YES, NO, UNCERTAIN
    is_valid: bool = True
    confidence: float = 1.0
    evaluated_at: Optional[str] = None
    adaptive_threshold_applied: Optional[float] = None
    
    def to_dict(self) -> dict:
        """Serialize to dictionary."""
        result = {
            "verdict": self.verdict,
            "correct_query_response": self.correct_query_response,
            "correct_query_answer": self.correct_query_answer,
            "incorrect_query_response": self.incorrect_query_response,
            "incorrect_query_answer": self.incorrect_query_answer,
            "is_valid": self.is_valid,
            "confidence": self.confidence,
        }
        if self.evaluated_at:
            result["evaluated_at"] = self.evaluated_at
        if self.adaptive_threshold_applied is not None:
            result["adaptive_threshold_applied"] = self.adaptive_threshold_applied
        return result


@dataclass
class GenerationMetadata:
    """Generation process metadata."""
    model: str = ""
    temperature: float = 0.7
    generated_at: Optional[str] = None
    latency_ms: Optional[int] = None
    batch_id: str = ""
    seed: Optional[int] = None
    meta_prompt_id: str = ""
    
    def to_dict(self) -> dict:
        """Serialize to dictionary."""
        result = {
            "model": self.model,
            "temperature": self.temperature,
        }
        if self.generated_at:
            result["generated_at"] = self.generated_at
        if self.latency_ms is not None:
            result["latency_ms"] = self.latency_ms
        if self.batch_id:
            result["batch_id"] = self.batch_id
        if self.seed is not None:
            result["seed"] = self.seed
        if self.meta_prompt_id:
            result["meta_prompt_id"] = self.meta_prompt_id
        return result


@dataclass
class QualitySignals:
    """Quality signals for a training example."""
    sql_valid: bool = True
    sql_executable: Optional[bool] = None
    question_length: int = 0
    sql_length: int = 0
    join_count: int = 0
    subquery_count: int = 0
    cte_count: int = 0
    aggregate_count: int = 0
    embedding_vector: Optional[list[float]] = None
    nearest_neighbor_distance: Optional[float] = None
    
    def to_dict(self) -> dict:
        """Serialize to dictionary."""
        result = {
            "sql_valid": self.sql_valid,
            "question_length": self.question_length,
            "sql_length": self.sql_length,
            "join_count": self.join_count,
            "subquery_count": self.subquery_count,
            "cte_count": self.cte_count,
            "aggregate_count": self.aggregate_count,
        }
        if self.sql_executable is not None:
            result["sql_executable"] = self.sql_executable
        if self.embedding_vector is not None:
            result["embedding_vector"] = self.embedding_vector
        if self.nearest_neighbor_distance is not None:
            result["nearest_neighbor_distance"] = self.nearest_neighbor_distance
        return result


@dataclass
class TrainingExample:
    """
    A single training example (question + SQL pair).
    
    Schema-compliant with docs/schema/simula/training-example.schema.json.
    Required fields: id, question, sql, complexity_score, critic_passed
    """
    # Required fields per schema
    id: str
    question: str
    sql: str
    complexity_score: float = 0.5
    critic_passed: bool = True
    
    # Optional fields per schema
    schema_context: str = ""
    taxonomy_path: list[str] = field(default_factory=list)
    mix_id: str = ""
    complexity_level: str = "MEDIUM"  # EASY, MEDIUM, HARD
    elo_rating: Optional[float] = None
    is_complexified: bool = False
    original_question: Optional[str] = None
    original_sql: Optional[str] = None
    critic_evaluation: Optional[CriticEvaluation] = None
    generation_metadata: Optional[GenerationMetadata] = None
    quality_signals: Optional[QualitySignals] = None
    
    # Legacy fields for backward compatibility (not in schema)
    domain: str = ""
    table: str = ""
    difficulty: str = "medium"  # Maps to complexity_level
    taxonomy_mix: dict = field(default_factory=dict)  # Maps to taxonomy_path
    meta_prompt: str = ""
    meta_prompt_id: str = ""
    audience: str = "dual"  # human, agent, or dual
    critic_verdict: Optional[str] = None  # Maps to critic_evaluation.verdict
    
    def __post_init__(self):
        """Post-initialization to sync legacy and schema fields."""
        # Sync difficulty -> complexity_level
        if self.difficulty and not self.complexity_level:
            self.complexity_level = self.difficulty.upper()
        elif self.complexity_level and not self.difficulty:
            self.difficulty = self.complexity_level.lower()
        
        # Sync taxonomy_mix -> taxonomy_path
        if self.taxonomy_mix and not self.taxonomy_path:
            self.taxonomy_path = list(self.taxonomy_mix.values()) if isinstance(self.taxonomy_mix, dict) else []
        
        # Sync critic_verdict -> critic_evaluation.verdict
        if self.critic_verdict and not self.critic_evaluation:
            self.critic_evaluation = CriticEvaluation(verdict=self.critic_verdict)
        elif self.critic_evaluation and not self.critic_verdict:
            self.critic_verdict = self.critic_evaluation.verdict
    
    def to_dict(self) -> dict:
        """
        Serialize to dictionary for JSONL output.
        
        Produces schema-compliant output per docs/schema/simula/training-example.schema.json.
        """
        result = {
            # Required fields
            "id": self.id,
            "question": self.question,
            "sql": self.sql,
            "complexity_score": self.complexity_score,
            "critic_passed": self.critic_passed,
        }
        
        # Optional fields (include only if set)
        if self.schema_context:
            result["schema_context"] = self.schema_context
        if self.taxonomy_path:
            result["taxonomy_path"] = self.taxonomy_path
        if self.mix_id:
            result["mix_id"] = self.mix_id
        if self.complexity_level:
            result["complexity_level"] = self.complexity_level
        if self.elo_rating is not None:
            result["elo_rating"] = self.elo_rating
        if self.is_complexified:
            result["is_complexified"] = self.is_complexified
        if self.original_question:
            result["original_question"] = self.original_question
        if self.original_sql:
            result["original_sql"] = self.original_sql
        if self.meta_prompt_id:
            result["meta_prompt_id"] = self.meta_prompt_id
        if self.audience:
            result["audience"] = self.audience
        if self.critic_evaluation:
            result["critic_evaluation"] = self.critic_evaluation.to_dict()
        if self.generation_metadata:
            result["generation_metadata"] = self.generation_metadata.to_dict()
        if self.quality_signals:
            result["quality_signals"] = self.quality_signals.to_dict()
        
        return result
    
    def to_legacy_dict(self) -> dict:
        """Serialize to legacy dictionary format for backward compatibility."""
        return {
            "id": self.id,
            "question": self.question,
            "sql": self.sql,
            "domain": self.domain,
            "table": self.table,
            "difficulty": self.difficulty,
            "taxonomy_mix": self.taxonomy_mix,
            "meta_prompt": self.meta_prompt,
            "meta_prompt_id": self.meta_prompt_id,
            "audience": self.audience,
            "is_complexified": self.is_complexified,
        }
    
    def to_jsonl(self) -> str:
        """Serialize to JSONL line (schema-compliant format)."""
        return json.dumps(self.to_dict())


@dataclass
class SamplingStrategy:
    """Defines how to sample from taxonomies."""
    name: str
    taxonomy_names: list[str]
    weights: dict[str, float] = field(default_factory=dict)
    description: str = ""
    
    def get_weight(self, taxonomy_name: str) -> float:
        return self.weights.get(taxonomy_name, 1.0)


class SimulaDataGenerator:
    """
    Generate synthetic Text-to-SQL training data using Simula framework.
    
    Implements Algorithm 2:
    1. Sample taxonomy mixes for global diversity
    2. Generate meta-prompts for local diversity
    3. Apply complexification to fraction c of samples
    4. Filter with double-critic for quality
    """
    
    def __init__(
        self,
        taxonomies: list[Taxonomy],
        registry: SchemaRegistry,
        llm_config: LLMConfig | None = None,
        generation_config: GenerationConfig | None = None,
    ):
        self.taxonomies = {t.factor_name: t for t in taxonomies}
        self.registry = registry
        self.llm_config = llm_config or LLMConfig()
        self.config = generation_config or GenerationConfig()
        
        self._llm_client: SimulaLLMClient | None = None
        self._random = random.Random(self.config.seed)
        self._example_counter = 0
    
    @property
    def llm_client(self) -> SimulaLLMClient:
        if self._llm_client is None:
            self._llm_client = SimulaLLMClient(self.llm_config)
        return self._llm_client
    
    async def close(self):
        """Close LLM client."""
        if self._llm_client:
            await self._llm_client.close()
    
    def _next_example_id(self) -> str:
        """Generate unique example ID."""
        self._example_counter += 1
        timestamp = datetime.now().strftime("%Y%m%d")
        return f"simula_{timestamp}_{self._example_counter:08d}"

    @staticmethod
    def _meta_prompt_id(table: TableSchema, mix: dict[str, str], meta_prompt: str) -> str:
        """Create a stable identifier for a generated meta-prompt."""
        payload = json.dumps(
            {
                "table": f"{table.schema_name}.{table.name}",
                "mix": mix,
                "meta_prompt": meta_prompt,
            },
            sort_keys=True,
        )
        return f"mp-{hashlib.sha256(payload.encode('utf-8')).hexdigest()[:12]}"

    @staticmethod
    def _infer_audience(question: str, meta_prompt: str) -> str:
        """Infer whether the prompt is human-facing, agent-facing, or usable by both."""
        text = f"{question} {meta_prompt}"
        technical_patterns = [
            r"\b[A-Z]{3,}\b",
            r"\b\w+_\w+\b",
            r"\b[A-Za-z0-9]+\.[A-Za-z0-9_.]+\b",
            r"\b(SELECT|FROM|WHERE|JOIN|GROUP BY|HAVING)\b",
        ]
        human_patterns = [
            r"\b(show|display|list|get|find|what|how|which|please|can you)\b",
            r"\b(total|average|sum|count|trend|compare)\b",
        ]
        technical_count = sum(
            len(re.findall(pattern, text, flags=re.IGNORECASE))
            for pattern in technical_patterns
        )
        human_count = sum(
            len(re.findall(pattern, text, flags=re.IGNORECASE))
            for pattern in human_patterns
        )
        if technical_count >= 2 and human_count == 0:
            return "agent"
        if human_count > 0 and technical_count == 0:
            return "human"
        return "dual"
    
    # =========================================================================
    # Phase 1: Taxonomic Sampling (Global Diversity)
    # =========================================================================
    
    def create_default_strategies(self) -> list[SamplingStrategy]:
        """Create default sampling strategies based on available taxonomies."""
        strategies = []
        
        # Get taxonomy categories
        dim_taxonomies = [n for n, t in self.taxonomies.items() if "dim_" in n]
        measure_taxonomies = [n for n, t in self.taxonomies.items() if "measure_" in n]
        pattern_taxonomies = [n for n in self.taxonomies.keys() 
                            if n in ("aggregation", "filter_operation", "query_complexity")]
        
        # Strategy 1: Simple queries (dimensions + basic filters)
        if dim_taxonomies:
            strategies.append(SamplingStrategy(
                name="simple_queries",
                taxonomy_names=dim_taxonomies[:3] + ["filter_operation"],
                weights={"filter_operation": 0.5},
                description="Simple SELECT with filters",
            ))
        
        # Strategy 2: Aggregation queries (measures + aggregations + dimensions)
        if measure_taxonomies and dim_taxonomies:
            strategies.append(SamplingStrategy(
                name="aggregation_queries",
                taxonomy_names=measure_taxonomies[:2] + dim_taxonomies[:2] + ["aggregation"],
                weights={"aggregation": 1.0},
                description="Aggregation queries with GROUP BY",
            ))
        
        # Strategy 3: Complex queries (all patterns)
        if pattern_taxonomies:
            strategies.append(SamplingStrategy(
                name="complex_queries",
                taxonomy_names=list(self.taxonomies.keys())[:5],
                weights={"query_complexity": 1.0},
                description="Complex queries with joins, CTEs, etc.",
            ))
        
        # Fallback: use all taxonomies
        if not strategies:
            strategies.append(SamplingStrategy(
                name="default",
                taxonomy_names=list(self.taxonomies.keys()),
                description="Default strategy using all taxonomies",
            ))
        
        return strategies
    
    def sample_taxonomy_mix(
        self,
        strategy: SamplingStrategy,
        sample_from_leaves: bool = True,
    ) -> dict[str, str]:
        """
        Sample a mix of taxonomy nodes based on strategy.
        
        Args:
            strategy: Sampling strategy to use
            sample_from_leaves: If True, sample from leaf nodes for maximum specificity
            
        Returns:
            Dict mapping taxonomy name to sampled node name
        """
        mix = {}
        
        for taxonomy_name in strategy.taxonomy_names:
            if taxonomy_name not in self.taxonomies:
                continue
            
            taxonomy = self.taxonomies[taxonomy_name]
            
            # Get candidate nodes
            if sample_from_leaves:
                candidates = taxonomy.get_leaf_nodes()
            else:
                # Sample from all levels based on depth
                max_level = taxonomy.depth
                level = self._random.randint(1, max(1, max_level))
                candidates = taxonomy.get_nodes_at_level(level)
            
            if candidates:
                # Weight selection based on strategy
                weight = strategy.get_weight(taxonomy_name)
                if self._random.random() < weight:
                    node = self._random.choice(candidates)
                    mix[taxonomy_name] = node.name
        
        return mix
    
    def generate_mixes(
        self,
        strategies: list[SamplingStrategy] | None = None,
        count: int | None = None,
    ) -> Iterator[tuple[SamplingStrategy, dict[str, str]]]:
        """
        Generate taxonomy mixes for data generation.
        
        Args:
            strategies: Sampling strategies (defaults to auto-generated)
            count: Number of mixes to generate
            
        Yields:
            Tuples of (strategy, mix)
        """
        strategies = strategies or self.create_default_strategies()
        count = count or self.config.target_count
        
        for i in range(count):
            # Select strategy (round-robin or weighted)
            strategy = strategies[i % len(strategies)]
            mix = self.sample_taxonomy_mix(strategy)
            yield strategy, mix
    
    # =========================================================================
    # Phase 2: Meta-Prompt Generation (Local Diversity)
    # =========================================================================
    
    async def generate_meta_prompt(
        self,
        mix: dict[str, str],
        table: TableSchema,
    ) -> str:
        """
        Convert a taxonomy mix into a meta-prompt for data generation.
        
        Args:
            mix: Taxonomy mix (factor -> value)
            table: Target table
            
        Returns:
            Meta-prompt string describing the desired query
        """
        system_prompt = """You are creating a specification for a Text-to-SQL training example.
Convert the given requirements into a clear, natural meta-prompt that describes
what kind of question and SQL query should be generated."""
        
        # Build context from mix
        requirements = []
        for factor, value in mix.items():
            if "dim_" in factor:
                requirements.append(f"Filter or group by {value}")
            elif "measure_" in factor:
                requirements.append(f"Aggregate or analyze {value}")
            elif factor == "aggregation":
                requirements.append(f"Use {value} aggregation")
            elif factor == "filter_operation":
                requirements.append(f"Apply {value} filter condition")
            elif factor == "query_complexity":
                requirements.append(f"Query complexity: {value}")
        
        prompt = f"""Create a meta-prompt for generating a Text-to-SQL example:

TABLE: {table.schema_name}.{table.name}
COLUMNS: {', '.join(c.name for c in table.columns[:10])}

REQUIREMENTS:
{chr(10).join(f"- {r}" for r in requirements)}

Generate a concise meta-prompt (1-2 sentences) describing the question and query type.
Do NOT generate the actual question or SQL, just describe what should be generated."""
        
        try:
            response = await self.llm_client.generate(
                prompt=prompt,
                system_prompt=system_prompt,
                temperature=0.7,
                max_tokens=150,
            )
            return response.content.strip()
        except Exception as e:
            logger.warning(f"Meta-prompt generation failed: {e}")
            # Fallback to simple meta-prompt
            return f"Generate a query for {table.name} using {', '.join(mix.values())}"
    
    async def generate_multiple_meta_prompts(
        self,
        mix: dict[str, str],
        table: TableSchema,
        count: int = 3,
    ) -> list[str]:
        """
        Generate multiple diverse meta-prompts for the same mix (local diversity).
        
        Args:
            mix: Taxonomy mix
            table: Target table
            count: Number of meta-prompts to generate
            
        Returns:
            List of diverse meta-prompts
        """
        system_prompt = """You are creating diverse specifications for Text-to-SQL training examples.
Generate multiple DIFFERENT meta-prompts for the same requirements.
Each should describe a unique question type or angle."""
        
        requirements = []
        for factor, value in mix.items():
            requirements.append(f"{factor}: {value}")
        
        prompt = f"""Create {count} DIVERSE meta-prompts for Text-to-SQL examples:

TABLE: {table.schema_name}.{table.name}
COLUMNS: {', '.join(c.name for c in table.columns[:10])}

REQUIREMENTS:
{chr(10).join(f"- {r}" for r in requirements)}

Generate {count} different meta-prompts, each describing a UNIQUE question type.
Respond with JSON:
{{
    "meta_prompt_id": ["prompt1", "prompt2", "prompt3"]
}}"""
        
        try:
            result = await self.llm_client.generate_json(
                prompt=prompt,
                system_prompt=system_prompt,
                temperature=0.8,
            )
            return result.get("meta_prompt_id", [])[:count]
        except Exception as e:
            logger.warning(f"Multiple meta-prompt generation failed: {e}")
            # Fallback to single generation
            single = await self.generate_meta_prompt(mix, table)
            return [single]
    
    # =========================================================================
    # Phase 3: Complexification
    # =========================================================================
    
    async def complexify_meta_prompt(self, meta_prompt: str, table: TableSchema) -> str:
        """
        Increase complexity of a meta-prompt.
        
        Adds:
        - Edge cases
        - Multi-step reasoning
        - Additional constraints
        - Uncommon patterns
        """
        system_prompt = """You are making a Text-to-SQL specification more complex and challenging.
Add edge cases, multi-step reasoning, or additional constraints while keeping it realistic."""
        
        prompt = f"""Make this meta-prompt MORE COMPLEX and challenging:

ORIGINAL: {meta_prompt}
TABLE: {table.schema_name}.{table.name}

Add complexity by:
1. Adding edge cases (NULL handling, empty results)
2. Requiring multi-step reasoning (subqueries, CTEs)
3. Adding constraints (HAVING, multiple conditions)
4. Using less common SQL patterns

Return the enhanced meta-prompt (1-3 sentences)."""
        
        try:
            response = await self.llm_client.generate(
                prompt=prompt,
                system_prompt=system_prompt,
                temperature=0.7,
                max_tokens=200,
            )
            return response.content.strip()
        except Exception as e:
            logger.warning(f"Complexification failed: {e}")
            return meta_prompt  # Return original on failure
    
    # =========================================================================
    # Phase 4: Example Generation
    # =========================================================================
    
    async def generate_example(
        self,
        meta_prompt: str,
        table: TableSchema,
        mix: dict[str, str],
        is_complexified: bool = False,
    ) -> TrainingExample | None:
        """
        Generate a single training example from a meta-prompt.
        
        Args:
            meta_prompt: Description of desired query
            table: Target table
            mix: Taxonomy mix used
            is_complexified: Whether this was complexified
            
        Returns:
            TrainingExample or None if generation failed
        """
        system_prompt = """You are generating Text-to-SQL training data.
Create a natural language question and corresponding SQL query based on the specification.
The SQL should be valid HANA SQL syntax."""
        
        # Build table context
        columns_desc = []
        for col in table.columns[:15]:
            columns_desc.append(f"  - {col.name}: {col.data_type} ({col.description or 'no description'})")
        
        prompt = f"""Generate a Text-to-SQL training example:

META-PROMPT: {meta_prompt}

TABLE: {table.schema_name}.{table.name}
COLUMNS:
{chr(10).join(columns_desc)}

Generate:
1. A natural language question a user might ask
2. The corresponding SQL query

Respond with JSON:
{{
    "question": "What is the total...",
    "sql": "SELECT ... FROM {table.schema_name}.{table.name} ...",
    "difficulty": "easy|medium|hard"
}}"""
        
        try:
            result = await self.llm_client.generate_json(
                prompt=prompt,
                system_prompt=system_prompt,
                temperature=0.6,
            )
            
            question = result.get("question", "").strip()
            sql = result.get("sql", "").strip()
            difficulty = result.get("difficulty", "medium")
            
            if not question or not sql:
                return None
            
            return TrainingExample(
                id=self._next_example_id(),
                question=question,
                sql=sql,
                domain=table.domain.value if hasattr(table.domain, 'value') else str(table.domain),
                table=f"{table.schema_name}.{table.name}",
                difficulty=difficulty,
                taxonomy_mix=mix,
                meta_prompt=meta_prompt,
                meta_prompt_id=self._meta_prompt_id(table, mix, meta_prompt),
                audience=self._infer_audience(question, meta_prompt),
                is_complexified=is_complexified,
            )
            
        except Exception as e:
            logger.warning(f"Example generation failed: {e}")
            return None
    
    # =========================================================================
    # Phase 5: Double-Critic Filtering
    # =========================================================================
    
    async def critic_filter(self, example: TrainingExample) -> tuple[bool, str]:
        """
        Apply double-critic filtering to an example.
        
        Checks:
        1. Question is natural and clear
        2. SQL is syntactically valid
        3. SQL correctly answers the question
        4. Example follows the meta-prompt requirements
        """
        requirements = [
            "The question is natural, clear, and grammatically correct",
            "The SQL query is syntactically valid",
            "The SQL query correctly answers the question",
            f"The example aligns with the meta-prompt: {example.meta_prompt}",
        ]
        
        content = f"""QUESTION: {example.question}

SQL: {example.sql}

TABLE: {example.table}"""
        
        return await self.llm_client.double_critic_evaluate(content, requirements)
    
    async def refine_example(
        self,
        example: TrainingExample,
        explanation: str,
    ) -> TrainingExample | None:
        """
        Attempt to fix a rejected example based on critic feedback.
        """
        system_prompt = """You are fixing a Text-to-SQL training example based on feedback.
Correct any issues while maintaining the original intent."""
        
        prompt = f"""Fix this training example based on feedback:

ORIGINAL QUESTION: {example.question}
ORIGINAL SQL: {example.sql}
TABLE: {example.table}
META-PROMPT: {example.meta_prompt}

FEEDBACK: {explanation}

Provide corrected version as JSON:
{{
    "question": "corrected question",
    "sql": "corrected SQL",
    "difficulty": "easy|medium|hard"
}}"""
        
        try:
            result = await self.llm_client.generate_json(
                prompt=prompt,
                system_prompt=system_prompt,
                temperature=0.4,
            )
            
            return TrainingExample(
                id=example.id,
                question=result.get("question", example.question),
                sql=result.get("sql", example.sql),
                domain=example.domain,
                table=example.table,
                difficulty=result.get("difficulty", example.difficulty),
                taxonomy_mix=example.taxonomy_mix,
                meta_prompt=example.meta_prompt,
                meta_prompt_id=example.meta_prompt_id,
                audience=example.audience,
                is_complexified=example.is_complexified,
                critic_verdict="ACCEPT",
            )
        except Exception as e:
            logger.warning(f"Example refinement failed: {e}")
            return None
    
    # =========================================================================
    # Main Generation Loop
    # =========================================================================
    
    async def generate_examples(
        self,
        target_count: int | None = None,
        strategies: list[SamplingStrategy] | None = None,
    ) -> list[TrainingExample]:
        """
        Generate training examples using the full Simula pipeline.
        
        Args:
            target_count: Number of examples to generate
            strategies: Sampling strategies
            
        Returns:
            List of validated training examples
        """
        target_count = target_count or self.config.target_count
        strategies = strategies or self.create_default_strategies()
        
        examples: list[TrainingExample] = []
        rejected_count = 0
        
        # Get available tables
        tables = self.registry.tables
        if not tables:
            logger.error("No tables in registry")
            return examples
        
        logger.info(f"Generating {target_count} examples from {len(tables)} tables")
        
        # Semaphore for concurrent generation
        semaphore = asyncio.Semaphore(self.llm_config.max_concurrent)
        
        async def generate_one(
            strategy: SamplingStrategy,
            mix: dict[str, str],
        ) -> TrainingExample | None:
            async with semaphore:
                # Select random table
                table = self._random.choice(tables)
                
                # Generate meta-prompt
                meta_prompt = await self.generate_meta_prompt(mix, table)
                
                # Complexify if selected
                is_complexified = self._random.random() < self.config.complexity_ratio
                if is_complexified:
                    meta_prompt = await self.complexify_meta_prompt(meta_prompt, table)
                
                # Generate example
                example = await self.generate_example(
                    meta_prompt, table, mix, is_complexified
                )
                
                if not example:
                    return None
                
                # Critic filtering
                if self.config.enable_critic:
                    is_valid, explanation = await self.critic_filter(example)
                    
                    if not is_valid:
                        # Try to refine
                        for retry in range(self.config.max_critic_retries):
                            refined = await self.refine_example(example, explanation)
                            if refined:
                                is_valid, explanation = await self.critic_filter(refined)
                                if is_valid:
                                    refined.critic_verdict = "ACCEPT"
                                    return refined
                        
                        return None  # Rejected after retries
                    
                    example.critic_verdict = "ACCEPT"
                
                return example
        
        # Generate in batches
        batch_size = 100
        mix_generator = self.generate_mixes(strategies, target_count * 2)  # Over-generate
        
        while len(examples) < target_count:
            # Generate batch of mixes
            batch_mixes = []
            for _ in range(min(batch_size, target_count - len(examples) + 50)):
                try:
                    strategy, mix = next(mix_generator)
                    batch_mixes.append((strategy, mix))
                except StopIteration:
                    break
            
            if not batch_mixes:
                break
            
            # Generate examples concurrently
            tasks = [generate_one(s, m) for s, m in batch_mixes]
            results = await asyncio.gather(*tasks, return_exceptions=True)
            
            for result in results:
                if isinstance(result, TrainingExample):
                    examples.append(result)
                    if len(examples) >= target_count:
                        break
                elif isinstance(result, Exception):
                    logger.debug(f"Generation error: {result}")
                else:
                    rejected_count += 1
            
            logger.info(f"Progress: {len(examples)}/{target_count} examples (rejected: {rejected_count})")
        
        logger.info(f"Generated {len(examples)} examples (rejected: {rejected_count})")
        return examples[:target_count]
    
    # =========================================================================
    # Output
    # =========================================================================
    
    def save_examples(
        self,
        examples: list[TrainingExample],
        output_dir: str | Path | None = None,
    ) -> Path:
        """
        Save examples to JSONL file.
        
        Args:
            examples: Training examples
            output_dir: Output directory
            
        Returns:
            Path to saved file
        """
        output_dir = Path(output_dir or self.config.output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)
        
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        output_file = output_dir / f"simula_training_{timestamp}.jsonl"
        
        with open(output_file, "w") as f:
            for example in examples:
                f.write(example.to_jsonl() + "\n")
        
        logger.info(f"Saved {len(examples)} examples to {output_file}")
        
        # Also save statistics
        stats = {
            "total_examples": len(examples),
            "by_domain": {},
            "by_difficulty": {},
            "complexified_count": sum(1 for e in examples if e.is_complexified),
            "timestamp": timestamp,
        }
        
        for example in examples:
            stats["by_domain"][example.domain] = stats["by_domain"].get(example.domain, 0) + 1
            stats["by_difficulty"][example.difficulty] = stats["by_difficulty"].get(example.difficulty, 0) + 1
        
        stats_file = output_dir / f"simula_stats_{timestamp}.json"
        with open(stats_file, "w") as f:
            json.dump(stats, f, indent=2)

        self.save_audience_splits(examples, output_dir, timestamp)
        
        return output_file

    def save_audience_splits(
        self,
        examples: list[TrainingExample],
        output_dir: str | Path | None = None,
        timestamp: str | None = None,
    ) -> tuple[Path, Path]:
        """Save separate human-facing and schema-aware-agent training files."""
        output_dir = Path(output_dir or self.config.output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)
        timestamp = timestamp or datetime.now().strftime("%Y%m%d_%H%M%S")

        human_file = output_dir / f"simula_training_{timestamp}_human.jsonl"
        agent_file = output_dir / f"simula_training_{timestamp}_agent.jsonl"

        human_examples = [
            example for example in examples
            if example.audience in ("human", "dual")
        ]
        agent_examples = [
            example for example in examples
            if example.audience in ("agent", "dual")
        ]

        with open(human_file, "w") as f:
            for example in human_examples:
                f.write(example.to_jsonl() + "\n")

        with open(agent_file, "w") as f:
            for example in agent_examples:
                f.write(example.to_jsonl() + "\n")

        logger.info(
            "Saved audience splits: %s human examples, %s agent examples",
            len(human_examples),
            len(agent_examples),
        )
        return human_file, agent_file


# Convenience functions
async def generate_training_data(
    taxonomies: list[Taxonomy],
    registry: SchemaRegistry,
    llm_config: LLMConfig | None = None,
    generation_config: GenerationConfig | None = None,
    target_count: int | None = None,
) -> list[TrainingExample]:
    """
    Generate training data using Simula framework.
    
    Args:
        taxonomies: List of taxonomies for sampling
        registry: Schema registry with table definitions
        llm_config: LLM configuration
        generation_config: Generation configuration
        target_count: Number of examples (overrides config)
        
    Returns:
        List of training examples
    """
    generator = SimulaDataGenerator(
        taxonomies=taxonomies,
        registry=registry,
        llm_config=llm_config,
        generation_config=generation_config,
    )
    try:
        return await generator.generate_examples(target_count)
    finally:
        await generator.close()


def generate_training_data_sync(
    taxonomies: list[Taxonomy],
    registry: SchemaRegistry,
    llm_config: LLMConfig | None = None,
    generation_config: GenerationConfig | None = None,
    target_count: int | None = None,
) -> list[TrainingExample]:
    """Synchronous wrapper for generate_training_data."""
    return asyncio.run(generate_training_data(
        taxonomies, registry, llm_config, generation_config, target_count
    ))
