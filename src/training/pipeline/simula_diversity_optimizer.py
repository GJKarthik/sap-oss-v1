"""
Simula Diversity Optimizer — Adaptive Weight Adjustment (Section 3.3, Figure 4).

Adjusts taxonomy sampling weights to balance global and local diversity.

Key insight from 6171: "Global and Local diversification have additive effects"
(Figure 4). Optimizing only one is insufficient.

Reference: Davidson et al. (2026) "Reasoning-Driven Synthetic Data Generation"
           TMLR, Section 3.3 (Intrinsic Metrics)
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .simula_diversity_analyzer import DiversityReport

logger = logging.getLogger(__name__)


@dataclass
class DiversityTargets:
    """Target diversity levels for optimization."""
    
    # Target global diversity (average pairwise cosine distance)
    # From Figure 4: synthetic data typically achieves 0.48-0.54
    target_global: float = 0.52
    
    # Target local diversity (k-NN cosine distance)
    # From Figure 4: synthetic data typically achieves 0.10-0.30
    target_local: float = 0.20
    
    # Acceptable deviation from targets
    tolerance: float = 0.05
    
    # Learning rate for weight adjustments
    learning_rate: float = 0.1
    
    # Minimum weight for any taxonomy
    min_weight: float = 0.1
    
    # Maximum weight for any taxonomy
    max_weight: float = 2.0

    @classmethod
    def from_env(cls) -> "DiversityTargets":
        import os
        return cls(
            target_global=float(os.getenv("SIMULA_DIVERSITY_TARGET_GLOBAL", "0.52")),
            target_local=float(os.getenv("SIMULA_DIVERSITY_TARGET_LOCAL", "0.20")),
            tolerance=float(os.getenv("SIMULA_DIVERSITY_TOLERANCE", "0.05")),
            learning_rate=float(os.getenv("SIMULA_DIVERSITY_LEARNING_RATE", "0.1")),
        )


@dataclass
class WeightAdjustment:
    """Recommended weight adjustments for taxonomies."""
    taxonomy_weights: dict[str, float] = field(default_factory=dict)
    sampling_temperature: float = 0.8
    leaf_sampling_bias: float = 0.5  # 0 = all levels, 1 = leaves only
    
    global_diversity_gap: float = 0.0  # positive = need more
    local_diversity_gap: float = 0.0   # positive = need more
    
    @property
    def is_balanced(self) -> bool:
        """Check if diversity is within tolerance of targets."""
        return (
            abs(self.global_diversity_gap) < 0.05 and
            abs(self.local_diversity_gap) < 0.05
        )


class SimulaDiversityOptimizer:
    """
    Optimizes sampling weights to achieve target diversity levels.
    
    From Section 3.3:
    "We first note the Global diversification component is crucial to increase
    the dataset-wide embedding-based diversity... Second, the Local component
    improves over the baseline; hence meta-prompting effectively increases
    the diversity of the k nearest points."
    
    This addresses the review gap: "The spec does not provide a combined
    optimization strategy – it only measures, not controls."
    """
    
    def __init__(
        self,
        targets: DiversityTargets | None = None,
        taxonomy_weights: dict[str, float] | None = None,
    ):
        self.targets = targets or DiversityTargets.from_env()
        self._weights = taxonomy_weights or {}
        self._history: list[WeightAdjustment] = []
    
    def analyze(
        self,
        current_report: "DiversityReport",
    ) -> WeightAdjustment:
        """
        Analyze current diversity and recommend weight adjustments.
        
        Args:
            current_report: DiversityReport from SimulaDiversityAnalyzer
            
        Returns:
            WeightAdjustment with recommended changes
        """
        adjustment = WeightAdjustment(
            taxonomy_weights=dict(self._weights),
        )
        
        # Calculate gaps from targets
        adjustment.global_diversity_gap = (
            self.targets.target_global - current_report.global_diversity
        )
        adjustment.local_diversity_gap = (
            self.targets.target_local - current_report.local_diversity
        )
        
        # Adjust sampling temperature based on global diversity gap
        if adjustment.global_diversity_gap > self.targets.tolerance:
            # Need more global diversity: increase temperature
            adjustment.sampling_temperature = min(1.0, 0.8 + adjustment.global_diversity_gap)
            logger.info(
                f"Global diversity low ({current_report.global_diversity:.3f}), "
                f"increasing temperature to {adjustment.sampling_temperature:.2f}"
            )
        elif adjustment.global_diversity_gap < -self.targets.tolerance:
            # Too much variation: decrease temperature
            adjustment.sampling_temperature = max(0.5, 0.8 + adjustment.global_diversity_gap)
        
        # Adjust leaf sampling bias based on local diversity gap
        if adjustment.local_diversity_gap > self.targets.tolerance:
            # Need more local diversity: sample more from leaves
            adjustment.leaf_sampling_bias = min(0.9, 0.5 + adjustment.local_diversity_gap * 2)
            logger.info(
                f"Local diversity low ({current_report.local_diversity:.3f}), "
                f"increasing leaf sampling bias to {adjustment.leaf_sampling_bias:.2f}"
            )
        elif adjustment.local_diversity_gap < -self.targets.tolerance:
            # Sample more from intermediate nodes
            adjustment.leaf_sampling_bias = max(0.2, 0.5 + adjustment.local_diversity_gap * 2)
        
        self._history.append(adjustment)
        return adjustment
    
    def update_weights(
        self,
        current_report: "DiversityReport",
        taxonomy_coverage: dict[str, float] | None = None,
    ) -> dict[str, float]:
        """
        Update taxonomy weights based on diversity report and coverage.
        
        Args:
            current_report: Current diversity metrics
            taxonomy_coverage: Optional coverage per taxonomy
            
        Returns:
            Updated taxonomy weights
        """
        # Get base adjustment
        adjustment = self.analyze(current_report)
        
        # If coverage data is available, upweight under-covered taxonomies
        if taxonomy_coverage:
            avg_coverage = sum(taxonomy_coverage.values()) / len(taxonomy_coverage)
            
            for taxonomy_name, coverage in taxonomy_coverage.items():
                current_weight = self._weights.get(taxonomy_name, 1.0)
                
                # Increase weight for under-covered taxonomies
                coverage_gap = avg_coverage - coverage
                if coverage_gap > 0.1:  # Significantly under-covered
                    adjustment_factor = 1 + coverage_gap * self.targets.learning_rate * 2
                    new_weight = current_weight * adjustment_factor
                    new_weight = min(self.targets.max_weight, max(self.targets.min_weight, new_weight))
                    
                    self._weights[taxonomy_name] = new_weight
                    adjustment.taxonomy_weights[taxonomy_name] = new_weight
                    
                    logger.debug(
                        f"Upweighting {taxonomy_name}: {current_weight:.2f} -> {new_weight:.2f} "
                        f"(coverage gap: {coverage_gap:.2%})"
                    )
        
        return dict(self._weights)
    
    def suggest_meta_prompts_per_mix(
        self,
        current_report: "DiversityReport",
    ) -> int:
        """
        Suggest number of meta-prompts per taxonomy mix for local diversity.
        
        From Section 2.2:
        "As the number of meta prompts per node-set grows, we gradually
        increase local diversity."
        """
        local_gap = self.targets.target_local - current_report.local_diversity
        
        if local_gap > 0.1:
            # Significant gap: generate more meta-prompts
            return 5
        elif local_gap > 0.05:
            return 3
        else:
            return 1
    
    def suggest_complexification_ratio(
        self,
        current_report: "DiversityReport",
        teacher_accuracy: float | None = None,
    ) -> float:
        """
        Suggest complexification ratio based on diversity and teacher strength.
        
        From Figure 7: "complex data can be detrimental when the teacher model
        is weak."
        
        Args:
            current_report: Current diversity metrics
            teacher_accuracy: Optional teacher model accuracy
            
        Returns:
            Recommended complexification ratio (0.0 to 1.0)
        """
        base_ratio = 0.5  # Default from paper
        
        # Reduce if teacher is weak
        if teacher_accuracy is not None and teacher_accuracy < 0.6:
            base_ratio = 0.2
            logger.info(
                f"Weak teacher ({teacher_accuracy:.1%}), reducing "
                f"complexification ratio to {base_ratio}"
            )
        
        # Adjust based on local diversity
        # High local diversity with complexification can cause mode collapse
        if current_report.local_diversity > 0.3:
            base_ratio = max(0.3, base_ratio - 0.1)
        
        return base_ratio
    
    def get_optimization_summary(self) -> dict:
        """Get summary of optimization history."""
        if not self._history:
            return {"status": "no_history"}
        
        latest = self._history[-1]
        return {
            "current_weights": dict(self._weights),
            "latest_adjustment": {
                "global_gap": latest.global_diversity_gap,
                "local_gap": latest.local_diversity_gap,
                "temperature": latest.sampling_temperature,
                "leaf_bias": latest.leaf_sampling_bias,
                "is_balanced": latest.is_balanced,
            },
            "iterations": len(self._history),
        }