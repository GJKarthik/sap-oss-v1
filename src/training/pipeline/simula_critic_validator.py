"""
Simula Critic Validator — Critic Calibration from Section 3.1.

Validates that the double-critic mechanism is properly calibrated by
measuring acceptance rates for correct vs. corrupted examples.

Key insight from 6171: Critic effectiveness degrades with task complexity
(Figure 3b) and depends on teacher model strength (LEXam had 61% rejection).

Reference: Davidson et al. (2026) "Reasoning-Driven Synthetic Data Generation"
           TMLR, Section 3.1 (Are M3s Effective Critics?) and Figure 3
"""

from __future__ import annotations

import asyncio
import json
import logging
import random
from dataclasses import dataclass, field
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .simula_llm_client import SimulaLLMClient
    from .simula_data_generator import TrainingExample

logger = logging.getLogger(__name__)


@dataclass
class CriticValidationConfig:
    """Configuration for critic validation."""
    
    # Fraction of dataset to use for validation
    validation_split: float = 0.05
    
    # Maximum samples for validation
    max_samples: int = 200
    
    # Prompt for subtle SQL corruption
    corruption_prompt: str = """
You are creating a subtly incorrect SQL query for testing purposes.

Original question: {question}
Original SQL: {sql}

Create a SUBTLY incorrect version of this SQL that:
- Looks plausible at first glance
- Has a logical error (wrong join, missing WHERE clause, wrong aggregation)
- Would return different results than the correct query

Output ONLY the corrupted SQL, nothing else.
"""

    @classmethod
    def from_env(cls) -> "CriticValidationConfig":
        """Load configuration from environment variables."""
        import os
        return cls(
            validation_split=float(os.getenv("SIMULA_CRITIC_VALIDATION_SPLIT", "0.05")),
            max_samples=int(os.getenv("SIMULA_CRITIC_MAX_SAMPLES", "200")),
        )


@dataclass
class CriticValidationReport:
    """Results of critic calibration validation."""
    
    # Acceptance rates (per Section 3.1)
    p_y: float = 0.0          # P(accept | correct)
    p_y_corrupt: float = 0.0  # P(accept | corrupted)
    
    # Computed metrics
    expected_lift: float = 0.0  # E[μ_critic] - μ_gen (theoretical lift)
    rejection_rate: float = 0.0  # 1 - |D_accept|
    
    # Per-complexity breakdown
    metrics_by_complexity: dict[str, dict] = field(default_factory=dict)
    
    # Sample counts
    correct_samples: int = 0
    corrupted_samples: int = 0
    
    @property
    def is_well_calibrated(self) -> bool:
        """
        Check if critic is well-calibrated.
        
        From Section 3.1: For effective rejection sampling, we need
        p(y) to be high and p(y_corrupt) to be low.
        """
        return self.p_y > 0.8 and self.p_y_corrupt < 0.3
    
    @property
    def discrimination_ratio(self) -> float:
        """Ratio of correct to corrupted acceptance (higher = better)."""
        if self.p_y_corrupt == 0:
            return float('inf')
        return self.p_y / self.p_y_corrupt


class SimulaCriticValidator:
    """
    Validates critic calibration using controlled experiments.
    
    From Section 3.1 (Controlled Setting):
    "We take reference tasks with correct answers, D_true, and create a
    corrupted copy D_corrupt by prompting an M3 to subtly change y_i while
    keeping x_i fixed. After performing this causal intervention on answer
    correctness, we evaluate the double critic on both datasets."
    """
    
    def __init__(
        self,
        llm_client: "SimulaLLMClient",
        config: CriticValidationConfig | None = None,
    ):
        self.llm = llm_client
        self.config = config or CriticValidationConfig.from_env()
    
    async def validate(
        self,
        examples: list["TrainingExample"],
        schema_context: str = "",
    ) -> CriticValidationReport:
        """
        Validate critic calibration on a holdout set.
        
        Args:
            examples: Training examples (a sample will be used)
            schema_context: Schema for evaluation
            
        Returns:
            CriticValidationReport with calibration metrics
        """
        # Sample holdout set
        sample_size = min(
            int(len(examples) * self.config.validation_split),
            self.config.max_samples,
        )
        holdout = random.sample(examples, sample_size)
        
        logger.info(f"Validating critic on {len(holdout)} examples...")
        
        # Create corrupted versions
        corrupted = await self._corrupt_examples(holdout)
        
        # Evaluate critic on correct examples
        correct_accepts = await self._evaluate_batch(holdout, schema_context)
        p_y = sum(correct_accepts) / len(correct_accepts) if correct_accepts else 0
        
        # Evaluate critic on corrupted examples
        corrupt_accepts = await self._evaluate_batch(corrupted, schema_context)
        p_y_corrupt = sum(corrupt_accepts) / len(corrupt_accepts) if corrupt_accepts else 0
        
        # Compute expected lift (per Section 4.1 equations)
        d_accept = p_y * 0.5 + p_y_corrupt * 0.5  # Assuming 50% baseline accuracy
        expected_lift = (0.5 * p_y / d_accept - 0.5) if d_accept > 0 else 0
        
        report = CriticValidationReport(
            p_y=p_y,
            p_y_corrupt=p_y_corrupt,
            expected_lift=expected_lift,
            rejection_rate=1 - d_accept,
            correct_samples=len(holdout),
            corrupted_samples=len(corrupted),
        )
        
        logger.info(
            f"Critic validation: p(y)={p_y:.3f}, p(y_corrupt)={p_y_corrupt:.3f}, "
            f"discrimination={report.discrimination_ratio:.2f}, "
            f"well_calibrated={report.is_well_calibrated}"
        )
        
        return report
    
    async def _corrupt_examples(
        self,
        examples: list["TrainingExample"],
    ) -> list["TrainingExample"]:
        """
        Create subtly corrupted versions of examples.
        
        From Section 3.1:
        "We create a corrupted copy D_corrupt by prompting an M3 to
        subtly change y_i while keeping x_i fixed."
        """
        tasks = [self._corrupt_single(ex) for ex in examples]
        return await asyncio.gather(*tasks)
    
    async def _corrupt_single(
        self,
        example: "TrainingExample",
    ) -> "TrainingExample":
        """Corrupt a single example's SQL."""
        from .simula_data_generator import TrainingExample
        
        prompt = self.config.corruption_prompt.format(
            question=example.question,
            sql=example.sql,
        )
        
        try:
            response = await self.llm.generate(prompt, temperature=0.7)
            corrupted_sql = response.content.strip()
            
            # Remove markdown code blocks if present
            if corrupted_sql.startswith("```"):
                lines = corrupted_sql.split("\n")
                corrupted_sql = "\n".join(lines[1:-1] if lines[-1] == "```" else lines[1:])
            
            return TrainingExample(
                id=f"{example.id}_corrupt",
                question=example.question,
                sql=corrupted_sql,
                schema_context=example.schema_context,
                taxonomy_path=example.taxonomy_path,
                complexity_score=example.complexity_score,
                meta_prompt=example.meta_prompt,
                is_complexified=example.is_complexified,
                critic_passed=False,  # By definition
                generation_metadata={"corrupted_from": example.id},
            )
        except Exception as e:
            logger.warning(f"Failed to corrupt example {example.id}: {e}")
            # Return original with modified SQL as fallback
            return TrainingExample(
                id=f"{example.id}_corrupt",
                question=example.question,
                sql=example.sql.replace("SELECT", "SELECT DISTINCT", 1),  # Simple corruption
                schema_context=example.schema_context,
                taxonomy_path=example.taxonomy_path,
                complexity_score=example.complexity_score,
                meta_prompt=example.meta_prompt,
                is_complexified=example.is_complexified,
                critic_passed=False,
                generation_metadata={"corrupted_from": example.id},
            )
    
    async def _evaluate_batch(
        self,
        examples: list["TrainingExample"],
        schema_context: str,
    ) -> list[bool]:
        """Evaluate critic acceptance for a batch of examples."""
        tasks = [
            self._evaluate_single(ex, schema_context)
            for ex in examples
        ]
        
        # Process in chunks
        results = []
        chunk_size = 20
        for i in range(0, len(tasks), chunk_size):
            chunk = tasks[i:i + chunk_size]
            chunk_results = await asyncio.gather(*chunk)
            results.extend(chunk_results)
        
        return results
    
    async def _evaluate_single(
        self,
        example: "TrainingExample",
        schema_context: str,
    ) -> bool:
        """Evaluate critic on a single example."""
        try:
            is_valid, _ = await self.llm.double_critic_evaluate(
                question=example.question,
                sql=example.sql,
                schema=schema_context or example.schema_context,
            )
            return is_valid
        except Exception as e:
            logger.debug(f"Critic evaluation failed for {example.id}: {e}")
            return False
    
    async def validate_by_complexity(
        self,
        examples: list["TrainingExample"],
        complexity_scores: dict[str, float],
        schema_context: str = "",
        n_buckets: int = 3,
    ) -> CriticValidationReport:
        """
        Validate critic calibration stratified by complexity.
        
        From Figure 3: Critic effectiveness varies with complexity.
        """
        # Bucket examples by complexity
        scored_examples = [
            (ex, complexity_scores.get(ex.id, 0.5))
            for ex in examples
        ]
        scored_examples.sort(key=lambda x: x[1])
        
        bucket_size = len(scored_examples) // n_buckets
        buckets = {
            f"bucket_{i}": [ex for ex, _ in scored_examples[i*bucket_size:(i+1)*bucket_size]]
            for i in range(n_buckets)
        }
        
        # Validate each bucket
        main_report = await self.validate(examples, schema_context)
        
        for bucket_name, bucket_examples in buckets.items():
            if bucket_examples:
                bucket_report = await self.validate(bucket_examples, schema_context)
                main_report.metrics_by_complexity[bucket_name] = {
                    "p_y": bucket_report.p_y,
                    "p_y_corrupt": bucket_report.p_y_corrupt,
                    "discrimination": bucket_report.discrimination_ratio,
                    "sample_count": len(bucket_examples),
                }
        
        return main_report
    
    def export_report(self, report: CriticValidationReport, output_path: str) -> None:
        """Export validation report to JSON."""
        data = {
            "acceptance_rates": {
                "p_y_correct": report.p_y,
                "p_y_corrupt": report.p_y_corrupt,
            },
            "metrics": {
                "expected_lift": report.expected_lift,
                "rejection_rate": report.rejection_rate,
                "discrimination_ratio": report.discrimination_ratio,
                "is_well_calibrated": report.is_well_calibrated,
            },
            "samples": {
                "correct": report.correct_samples,
                "corrupted": report.corrupted_samples,
            },
            "by_complexity": report.metrics_by_complexity,
        }
        
        with open(output_path, "w") as f:
            json.dump(data, f, indent=2)
        
        logger.info(f"Exported critic validation report to {output_path}")