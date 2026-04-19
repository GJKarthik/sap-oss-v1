"""
Simula Complexity Calibrator — Algorithm 3 from the Simula Research Paper.

Implements calibrated complexity scoring using batch-wise relative scoring
and Elo ranking as described in Section 2.3 and Appendix E.3.

Key insight from 6171: Raw per-sample complexity scores are noisy due to
model overconfidence. Batch-wise scoring with Elo calibration significantly
improves alignment with human complexity judgments (Figure 10).

Reference: Davidson et al. (2026) "Reasoning-Driven Synthetic Data Generation"
           TMLR, Section 2.3 and Appendix E.3
"""

from __future__ import annotations

import asyncio
import json
import logging
import random
import math
from dataclasses import dataclass, field
from typing import TYPE_CHECKING
from collections import defaultdict

if TYPE_CHECKING:
    from .simula_llm_client import SimulaLLMClient
    from .simula_data_generator import TrainingExample

logger = logging.getLogger(__name__)


@dataclass
class ComplexityConfig:
    """Configuration for complexity calibration (Algorithm 3)."""
    
    # Batch size for relative scoring (BS parameter from paper)
    # BS=5 found optimal in Figure 10
    batch_size: int = 5
    
    # Number of times each example appears in batches (N parameter)
    # N=5 found optimal in Figure 10
    n_samples: int = 5
    
    # Enable Elo-based calibration (vs. raw score averaging)
    enable_elo: bool = True
    
    # Initial Elo rating
    initial_elo: float = 400.0
    
    # Elo K-factor (controls how much ratings change per comparison)
    elo_k_factor: float = 32.0
    
    # Prompt template for complexity scoring
    scoring_prompt_template: str = """
You are evaluating the relative complexity of Text-to-SQL examples.
Rate each example on a scale of 1-10 based on:
- Query complexity (joins, subqueries, aggregations, CTEs)
- Edge cases and NULL handling
- Domain knowledge required
- Ambiguity in the natural language question

Examples to rate (rate ALL of them relative to each other):
{examples}

Output JSON with scores for each example ID:
{{"scores": {{"id1": 7, "id2": 4, ...}}}}
"""

    @classmethod
    def from_env(cls) -> "ComplexityConfig":
        """Load configuration from environment variables."""
        import os
        return cls(
            batch_size=int(os.getenv("SIMULA_COMPLEXITY_BATCH_SIZE", "5")),
            n_samples=int(os.getenv("SIMULA_COMPLEXITY_N_SAMPLES", "5")),
            enable_elo=os.getenv("SIMULA_COMPLEXITY_ENABLE_ELO", "true").lower() == "true",
        )


@dataclass
class ComplexityScore:
    """Complexity score for a single example."""
    example_id: str
    raw_scores: list[float] = field(default_factory=list)
    elo_rating: float = 400.0
    
    @property
    def mean_raw_score(self) -> float:
        """Average of raw scores across all batch appearances."""
        return sum(self.raw_scores) / len(self.raw_scores) if self.raw_scores else 0.0
    
    @property
    def normalized_score(self) -> float:
        """Normalized score between 0.0 and 1.0."""
        # Elo scores typically range 100-700 in our setup
        # Normalize to 0-1 range
        return max(0.0, min(1.0, (self.elo_rating - 100) / 600))


class SimulaComplexityCalibrator:
    """
    Implements Algorithm 3: Calibrated Attribute Scoring.
    
    The key innovation is batch-wise relative scoring combined with Elo ranking:
    1. Each example appears in ~N batches of size BS
    2. Within each batch, examples are scored relative to each other
    3. Pairwise comparisons from batches are used to compute Elo ratings
    
    This addresses model overconfidence on individual samples by forcing
    calibration against peers.
    """
    
    def __init__(
        self,
        llm_client: "SimulaLLMClient",
        config: ComplexityConfig | None = None,
    ):
        self.llm = llm_client
        self.config = config or ComplexityConfig.from_env()
        self._scores: dict[str, ComplexityScore] = {}
    
    async def calibrate(
        self,
        examples: list["TrainingExample"],
        domain_description: str = "Text-to-SQL queries for SAP HANA",
    ) -> dict[str, ComplexityScore]:
        """
        Compute calibrated complexity scores for all examples.
        
        Args:
            examples: List of training examples to score
            domain_description: Context for complexity assessment
            
        Returns:
            Dict mapping example ID to ComplexityScore
        """
        if len(examples) < self.config.batch_size:
            logger.warning(
                f"Not enough examples ({len(examples)}) for batch size "
                f"({self.config.batch_size}). Scoring individually."
            )
            return await self._score_individually(examples, domain_description)
        
        # Phase 1: Prepare batches (Algorithm 3, line 3)
        batches = self._prepare_batches(examples)
        logger.info(
            f"Prepared {len(batches)} batches for {len(examples)} examples "
            f"(BS={self.config.batch_size}, N={self.config.n_samples})"
        )
        
        # Phase 2: Batch-wise relative scoring (Algorithm 3, lines 6-12)
        await self._batch_score(batches, domain_description)
        
        # Phase 3: Elo calibration (Algorithm 3, line 14)
        if self.config.enable_elo:
            self._compute_elo_rankings(batches)
        
        logger.info(
            f"Calibrated {len(self._scores)} examples. "
            f"Elo range: {min(s.elo_rating for s in self._scores.values()):.0f} - "
            f"{max(s.elo_rating for s in self._scores.values()):.0f}"
        )
        
        return self._scores
    
    def _prepare_batches(
        self,
        examples: list["TrainingExample"],
    ) -> list[list["TrainingExample"]]:
        """
        Create batches ensuring each example appears ~N times.
        
        From Algorithm 3, line 3:
        "Create batch schedule ensuring every item appears in ≈K varied batches"
        """
        batches = []
        example_counts = defaultdict(int)
        
        # Initialize scores
        for ex in examples:
            self._scores[ex.id] = ComplexityScore(
                example_id=ex.id,
                elo_rating=self.config.initial_elo,
            )
        
        # Calculate target number of batches
        # Each batch has BS examples, each example appears N times
        # Total appearances = len(examples) * N
        # Total batches needed = (len(examples) * N) / BS
        target_batches = (len(examples) * self.config.n_samples) // self.config.batch_size
        
        all_examples = list(examples)
        
        for _ in range(target_batches):
            # Select examples with lowest counts for this batch
            # This ensures roughly equal appearance counts
            candidates = sorted(all_examples, key=lambda e: example_counts[e.id])
            batch = candidates[:self.config.batch_size]
            
            for ex in batch:
                example_counts[ex.id] += 1
            
            batches.append(batch)
            
            # Shuffle to vary batch composition
            random.shuffle(all_examples)
        
        return batches
    
    async def _batch_score(
        self,
        batches: list[list["TrainingExample"]],
        domain_description: str,
    ) -> None:
        """
        Score all batches with relative complexity assessment.
        
        From Algorithm 3, lines 6-12:
        "For each batch B, prompt M3 to score items relative to others"
        """
        tasks = [
            self._score_single_batch(batch, i, domain_description)
            for i, batch in enumerate(batches)
        ]
        
        # Process in chunks to avoid overwhelming the LLM
        chunk_size = 10
        for i in range(0, len(tasks), chunk_size):
            chunk = tasks[i:i + chunk_size]
            await asyncio.gather(*chunk)
    
    async def _score_single_batch(
        self,
        batch: list["TrainingExample"],
        batch_idx: int,
        domain_description: str,
    ) -> None:
        """Score a single batch of examples."""
        # Format examples for the prompt
        examples_text = "\n\n".join([
            f"Example {ex.id}:\n"
            f"Question: {ex.question}\n"
            f"SQL: {ex.sql}"
            for ex in batch
        ])
        
        prompt = self.config.scoring_prompt_template.format(
            examples=examples_text,
            domain=domain_description,
        )
        
        try:
            response = await self.llm.generate(prompt, temperature=0.3)
            scores = self._parse_scores(response.content, [ex.id for ex in batch])
            
            for ex_id, score in scores.items():
                if ex_id in self._scores:
                    self._scores[ex_id].raw_scores.append(score)
                    
        except Exception as e:
            logger.warning(f"Failed to score batch {batch_idx}: {e}")
    
    def _parse_scores(
        self,
        response: str,
        expected_ids: list[str],
    ) -> dict[str, float]:
        """Parse scores from LLM response."""
        try:
            # Try to extract JSON from response
            start = response.find("{")
            end = response.rfind("}") + 1
            if start >= 0 and end > start:
                data = json.loads(response[start:end])
                scores = data.get("scores", data)
                return {
                    str(k): float(v)
                    for k, v in scores.items()
                    if str(k) in expected_ids
                }
        except (json.JSONDecodeError, ValueError, KeyError) as e:
            logger.debug(f"Failed to parse scores: {e}")
        
        return {}
    
    def _compute_elo_rankings(
        self,
        batches: list[list["TrainingExample"]],
    ) -> None:
        """
        Compute Elo ratings from pairwise comparisons within batches.
        
        From Algorithm 3, line 14:
        "Derive pairwise comparisons from batches to compute global Elo ratings"
        """
        # Extract pairwise comparisons from each batch
        for batch in batches:
            batch_scores = {
                ex.id: self._scores[ex.id].mean_raw_score
                for ex in batch
                if self._scores[ex.id].raw_scores
            }
            
            if len(batch_scores) < 2:
                continue
            
            # For each pair in the batch, update Elo based on raw score comparison
            ids = list(batch_scores.keys())
            for i in range(len(ids)):
                for j in range(i + 1, len(ids)):
                    id_a, id_b = ids[i], ids[j]
                    score_a, score_b = batch_scores[id_a], batch_scores[id_b]
                    
                    # Determine winner (higher complexity = higher Elo)
                    if score_a > score_b:
                        self._update_elo(id_a, id_b, 1.0)
                    elif score_b > score_a:
                        self._update_elo(id_a, id_b, 0.0)
                    else:
                        self._update_elo(id_a, id_b, 0.5)
    
    def _update_elo(self, id_a: str, id_b: str, outcome_a: float) -> None:
        """
        Update Elo ratings for a pairwise comparison.
        
        outcome_a: 1.0 if A wins (higher complexity), 0.0 if B wins, 0.5 for draw
        """
        rating_a = self._scores[id_a].elo_rating
        rating_b = self._scores[id_b].elo_rating
        
        # Expected outcomes
        expected_a = 1 / (1 + math.pow(10, (rating_b - rating_a) / 400))
        expected_b = 1 - expected_a
        
        # Update ratings
        self._scores[id_a].elo_rating = rating_a + self.config.elo_k_factor * (outcome_a - expected_a)
        self._scores[id_b].elo_rating = rating_b + self.config.elo_k_factor * ((1 - outcome_a) - expected_b)
    
    async def _score_individually(
        self,
        examples: list["TrainingExample"],
        domain_description: str,
    ) -> dict[str, ComplexityScore]:
        """Fallback for when batch size exceeds example count."""
        for ex in examples:
            self._scores[ex.id] = ComplexityScore(
                example_id=ex.id,
                raw_scores=[5.0],  # Default mid-range score
                elo_rating=self.config.initial_elo,
            )
        return self._scores
    
    def get_complexity_percentile(self, example_id: str) -> float:
        """Get the percentile rank of an example's complexity."""
        if example_id not in self._scores:
            return 0.5
        
        target_rating = self._scores[example_id].elo_rating
        lower_count = sum(
            1 for s in self._scores.values()
            if s.elo_rating < target_rating
        )
        return lower_count / len(self._scores)
    
    def split_by_complexity(
        self,
        examples: list["TrainingExample"],
        low_percentile: float = 0.4,
        high_percentile: float = 0.6,
    ) -> tuple[list["TrainingExample"], list["TrainingExample"], list["TrainingExample"]]:
        """
        Split examples into low, medium, and high complexity sets.
        
        From Figure 7: Downstream Impact of Data Complexity
        The paper shows that complexity splits have domain-dependent effects.
        
        Returns:
            (low_complexity, mid_complexity, high_complexity)
        """
        # Sort examples by Elo rating
        sorted_examples = sorted(
            examples,
            key=lambda e: self._scores.get(e.id, ComplexityScore(e.id)).elo_rating
        )
        
        low_idx = int(len(sorted_examples) * low_percentile)
        high_idx = int(len(sorted_examples) * high_percentile)
        
        return (
            sorted_examples[:low_idx],
            sorted_examples[low_idx:high_idx],
            sorted_examples[high_idx:],
        )
    
    def export_scores(self, output_path: str) -> None:
        """Export complexity scores to JSON file."""
        data = {
            "config": {
                "batch_size": self.config.batch_size,
                "n_samples": self.config.n_samples,
                "enable_elo": self.config.enable_elo,
            },
            "scores": {
                ex_id: {
                    "raw_scores": score.raw_scores,
                    "mean_raw_score": score.mean_raw_score,
                    "elo_rating": score.elo_rating,
                    "normalized_score": score.normalized_score,
                }
                for ex_id, score in self._scores.items()
            },
            "statistics": {
                "count": len(self._scores),
                "elo_min": min(s.elo_rating for s in self._scores.values()) if self._scores else 0,
                "elo_max": max(s.elo_rating for s in self._scores.values()) if self._scores else 0,
                "elo_mean": sum(s.elo_rating for s in self._scores.values()) / len(self._scores) if self._scores else 0,
            },
        }
        
        with open(output_path, "w") as f:
            json.dump(data, f, indent=2)
        
        logger.info(f"Exported complexity scores to {output_path}")