"""
Simula Diversity Analyzer — Embedding-Based Diversity Metrics from Section 3.3.

Implements global and local diversity metrics using cosine distance in
embedding space, as described in the Simula paper (Figure 4, top and middle).

Key insight from 6171: Global and Local diversification have ADDITIVE effects.
You cannot optimize one without measuring both.

Reference: Davidson et al. (2026) "Reasoning-Driven Synthetic Data Generation"
           TMLR, Section 3.3 (Intrinsic Metrics)
"""

from __future__ import annotations

import json
import logging
import numpy as np
from dataclasses import dataclass, field
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .simula_data_generator import TrainingExample

logger = logging.getLogger(__name__)


@dataclass
class DiversityConfig:
    """Configuration for diversity analysis."""
    
    # Embedding model (paper uses Gecko from Lee et al. 2024b)
    embedding_model: str = "sentence-transformers/all-MiniLM-L6-v2"
    
    # K for k-nearest neighbors in local diversity
    knn_k: int = 10
    
    # Batch size for embedding computation
    batch_size: int = 64
    
    # Whether to use GPU if available
    use_gpu: bool = True
    
    @classmethod
    def from_env(cls) -> "DiversityConfig":
        """Load configuration from environment variables."""
        import os
        return cls(
            embedding_model=os.getenv(
                "SIMULA_DIVERSITY_EMBEDDING_MODEL",
                "sentence-transformers/all-MiniLM-L6-v2"
            ),
            knn_k=int(os.getenv("SIMULA_DIVERSITY_KNN", "10")),
        )


@dataclass
class DiversityReport:
    """Diversity metrics for a dataset."""
    
    # Global diversity: average pairwise cosine distance
    global_diversity: float = 0.0
    
    # Local diversity: average k-NN cosine distance
    local_diversity: float = 0.0
    
    # Per-example local diversity scores
    local_scores: dict[str, float] = field(default_factory=dict)
    
    # Statistics
    embedding_dim: int = 0
    example_count: int = 0
    
    @property
    def combined_diversity(self) -> float:
        """Combined metric (geometric mean of global and local)."""
        if self.global_diversity <= 0 or self.local_diversity <= 0:
            return 0.0
        return np.sqrt(self.global_diversity * self.local_diversity)


class SimulaDiversityAnalyzer:
    """
    Analyzes embedding-based diversity of generated datasets.
    
    From Section 3.3:
    "Following Yu et al. (2023), we evaluate diversity by transforming datapoints
    into an embedding space and measuring cosine distances. For global diversity
    we report the average dataset-wide, pairwise cosine distance. To evaluate
    local diversity, we first group data points by taking the k=10 nearest
    neighbors to each data point in embedding space."
    """
    
    def __init__(self, config: DiversityConfig | None = None):
        self.config = config or DiversityConfig.from_env()
        self._encoder = None
        self._embeddings_cache: dict[str, np.ndarray] = {}
    
    def _load_encoder(self):
        """Lazy-load the sentence transformer model."""
        if self._encoder is None:
            try:
                from sentence_transformers import SentenceTransformer
                device = "cuda" if self.config.use_gpu else "cpu"
                self._encoder = SentenceTransformer(
                    self.config.embedding_model,
                    device=device,
                )
                logger.info(f"Loaded embedding model: {self.config.embedding_model}")
            except ImportError:
                logger.warning(
                    "sentence-transformers not installed. "
                    "Install with: pip install sentence-transformers"
                )
                raise
    
    def analyze(
        self,
        examples: list["TrainingExample"],
        text_field: str = "question",
    ) -> DiversityReport:
        """
        Compute diversity metrics for a set of examples.
        
        Args:
            examples: Training examples to analyze
            text_field: Which field to use for embedding ("question" or "sql")
            
        Returns:
            DiversityReport with global and local diversity metrics
        """
        self._load_encoder()
        
        # Extract texts for embedding
        texts = []
        ids = []
        for ex in examples:
            text = getattr(ex, text_field, None) or ex.question
            texts.append(text)
            ids.append(ex.id)
        
        # Compute embeddings
        logger.info(f"Computing embeddings for {len(texts)} examples...")
        embeddings = self._encoder.encode(
            texts,
            batch_size=self.config.batch_size,
            show_progress_bar=len(texts) > 1000,
            convert_to_numpy=True,
        )
        
        # Normalize for cosine similarity
        embeddings = embeddings / np.linalg.norm(embeddings, axis=1, keepdims=True)
        
        # Cache embeddings
        for i, ex_id in enumerate(ids):
            self._embeddings_cache[ex_id] = embeddings[i]
        
        # Compute global diversity
        global_div = self._compute_global_diversity(embeddings)
        
        # Compute local diversity
        local_div, local_scores = self._compute_local_diversity(embeddings, ids)
        
        report = DiversityReport(
            global_diversity=global_div,
            local_diversity=local_div,
            local_scores=local_scores,
            embedding_dim=embeddings.shape[1],
            example_count=len(examples),
        )
        
        logger.info(
            f"Diversity metrics: global={global_div:.4f}, "
            f"local={local_div:.4f}, combined={report.combined_diversity:.4f}"
        )
        
        return report
    
    def _compute_global_diversity(self, embeddings: np.ndarray) -> float:
        """
        Compute global diversity as average pairwise cosine distance.
        
        From Section 3.3:
        "For global diversity we report the average dataset-wide, pairwise
        cosine distance."
        
        Cosine distance = 1 - cosine_similarity
        """
        n = len(embeddings)
        if n < 2:
            return 0.0
        
        # For large datasets, sample pairs to avoid O(n²) computation
        if n > 5000:
            # Sample ~25M pairs (5000 * 5000)
            sample_size = min(n, 5000)
            indices = np.random.choice(n, sample_size, replace=False)
            embeddings = embeddings[indices]
            n = sample_size
        
        # Compute pairwise cosine similarity matrix
        similarity_matrix = embeddings @ embeddings.T
        
        # Extract upper triangle (excluding diagonal)
        upper_tri_indices = np.triu_indices(n, k=1)
        similarities = similarity_matrix[upper_tri_indices]
        
        # Convert to distance and average
        distances = 1 - similarities
        return float(np.mean(distances))
    
    def _compute_local_diversity(
        self,
        embeddings: np.ndarray,
        ids: list[str],
    ) -> tuple[float, dict[str, float]]:
        """
        Compute local diversity as average k-NN cosine distance.
        
        From Section 3.3:
        "To evaluate local diversity, we first group data points by taking
        the k=10 nearest neighbors to each data point in embedding space.
        We then take the average pairwise cosine distance across these clusters."
        """
        n = len(embeddings)
        k = min(self.config.knn_k, n - 1)
        
        if k < 1:
            return 0.0, {}
        
        # Compute similarity matrix
        similarity_matrix = embeddings @ embeddings.T
        
        local_scores = {}
        total_distance = 0.0
        
        for i, ex_id in enumerate(ids):
            # Get similarities to all other points
            similarities = similarity_matrix[i]
            
            # Find k nearest neighbors (highest similarity, excluding self)
            # Set self-similarity to -1 to exclude it
            similarities_copy = similarities.copy()
            similarities_copy[i] = -1
            knn_indices = np.argpartition(similarities_copy, -k)[-k:]
            knn_similarities = similarities[knn_indices]
            
            # Compute average distance to neighbors
            local_distance = float(1 - np.mean(knn_similarities))
            local_scores[ex_id] = local_distance
            total_distance += local_distance
        
        avg_local_diversity = total_distance / n
        return avg_local_diversity, local_scores
    
    def compare_datasets(
        self,
        dataset_a: list["TrainingExample"],
        dataset_b: list["TrainingExample"],
        text_field: str = "question",
    ) -> dict:
        """
        Compare diversity metrics between two datasets.
        
        Useful for comparing synthetic vs. real data diversity.
        """
        report_a = self.analyze(dataset_a, text_field)
        report_b = self.analyze(dataset_b, text_field)
        
        return {
            "dataset_a": {
                "global": report_a.global_diversity,
                "local": report_a.local_diversity,
                "combined": report_a.combined_diversity,
                "count": report_a.example_count,
            },
            "dataset_b": {
                "global": report_b.global_diversity,
                "local": report_b.local_diversity,
                "combined": report_b.combined_diversity,
                "count": report_b.example_count,
            },
            "comparison": {
                "global_ratio": report_a.global_diversity / report_b.global_diversity if report_b.global_diversity > 0 else float('inf'),
                "local_ratio": report_a.local_diversity / report_b.local_diversity if report_b.local_diversity > 0 else float('inf'),
                "combined_ratio": report_a.combined_diversity / report_b.combined_diversity if report_b.combined_diversity > 0 else float('inf'),
            },
        }
    
    def identify_outliers(
        self,
        report: DiversityReport,
        threshold_percentile: float = 5.0,
    ) -> tuple[list[str], list[str]]:
        """
        Identify examples with unusually low or high local diversity.
        
        Low diversity examples are likely duplicates or near-duplicates.
        High diversity examples may be outliers or errors.
        
        Returns:
            (low_diversity_ids, high_diversity_ids)
        """
        scores = list(report.local_scores.values())
        if not scores:
            return [], []
        
        low_threshold = np.percentile(scores, threshold_percentile)
        high_threshold = np.percentile(scores, 100 - threshold_percentile)
        
        low_ids = [
            ex_id for ex_id, score in report.local_scores.items()
            if score < low_threshold
        ]
        high_ids = [
            ex_id for ex_id, score in report.local_scores.items()
            if score > high_threshold
        ]
        
        return low_ids, high_ids
    
    def export_report(self, report: DiversityReport, output_path: str) -> None:
        """Export diversity report to JSON."""
        data = {
            "global_diversity": report.global_diversity,
            "local_diversity": report.local_diversity,
            "combined_diversity": report.combined_diversity,
            "embedding_dim": report.embedding_dim,
            "example_count": report.example_count,
            "knn_k": self.config.knn_k,
            "embedding_model": self.config.embedding_model,
            "local_scores_summary": {
                "min": min(report.local_scores.values()) if report.local_scores else 0,
                "max": max(report.local_scores.values()) if report.local_scores else 0,
                "mean": np.mean(list(report.local_scores.values())) if report.local_scores else 0,
                "std": np.std(list(report.local_scores.values())) if report.local_scores else 0,
            },
        }
        
        with open(output_path, "w") as f:
            json.dump(data, f, indent=2)
        
        logger.info(f"Exported diversity report to {output_path}")