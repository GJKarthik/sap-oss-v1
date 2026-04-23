"""
simula_config.py — Configuration for HANA-Direct + Simula training data pipeline.

This module defines configuration dataclasses for:
- HANA Cloud schema extraction via AI Core PAL MCP
- vLLM TurboQuant LLM inference
- Simula taxonomy and data generation settings
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from enum import Enum
from typing import Optional


class LLMProvider(str, Enum):
    """Supported LLM providers for Simula reasoning tasks."""
    VLLM_TURBOQUANT = "vllm-turboquant"
    AICORE = "aicore"
    OPENAI = "openai"


@dataclass
class HanaSourceConfig:
    """Configuration for HANA Cloud schema extraction."""
    
    # AI Core PAL MCP endpoint (external or in-cluster)
    mcp_url: str = field(
        default_factory=lambda: os.getenv(
            "AICORE_PAL_MCP_URL",
            "https://ai-core-pal.c-054c570.kyma.ondemand.com/mcp"
        )
    )
    
    # Schemas to extract (comma-separated in env var)
    schemas: list[str] = field(
        default_factory=lambda: os.getenv(
            "HANA_SCHEMAS", "PAL_STORE"
        ).split(",")
    )
    
    # Optional table name pattern filter (SQL LIKE syntax)
    table_pattern: Optional[str] = field(
        default_factory=lambda: os.getenv("HANA_TABLE_PATTERN")
    )
    
    # Timeout for MCP requests (seconds)
    timeout: int = field(
        default_factory=lambda: int(os.getenv("HANA_MCP_TIMEOUT", "30"))
    )


@dataclass
class LLMConfig:
    """Configuration for LLM inference (vLLM TurboQuant or AI Core)."""
    
    # Provider selection
    provider: LLMProvider = field(
        default_factory=lambda: LLMProvider(
            os.getenv("SIMULA_LLM_PROVIDER", "vllm-turboquant")
        )
    )
    
    # vLLM TurboQuant endpoint (OpenAI-compatible)
    base_url: str = field(
        default_factory=lambda: os.getenv(
            "VLLM_BASE_URL", "http://localhost:8000/v1"
        )
    )
    
    # Model identifier
    model: str = field(
        default_factory=lambda: os.getenv(
            "VLLM_MODEL", "Qwen/Qwen2.5-7B-Instruct"
        )
    )
    
    # API key (required for OpenAI, optional for vLLM)
    api_key: str = field(
        default_factory=lambda: os.getenv("OPENAI_API_KEY", "none")
    )
    
    # Generation parameters
    temperature: float = field(
        default_factory=lambda: float(os.getenv("SIMULA_TEMPERATURE", "0.7"))
    )
    
    max_tokens: int = field(
        default_factory=lambda: int(os.getenv("SIMULA_MAX_TOKENS", "2048"))
    )
    
    # Concurrent request limit
    max_concurrent: int = field(
        default_factory=lambda: int(os.getenv("SIMULA_MAX_CONCURRENT", "8"))
    )


@dataclass
class TaxonomyConfig:
    """Configuration for Simula taxonomy generation (Algorithm 1)."""
    
    # Maximum depth of taxonomy trees
    depth: int = field(
        default_factory=lambda: int(os.getenv("SIMULA_TAXONOMY_DEPTH", "3"))
    )
    
    # Best-of-N sampling for node proposals
    best_of_n: int = field(
        default_factory=lambda: int(os.getenv("SIMULA_BEST_OF_N", "5"))
    )
    
    # Enable critic refinement step
    enable_critic: bool = field(
        default_factory=lambda: os.getenv(
            "SIMULA_ENABLE_CRITIC", "true"
        ).lower() == "true"
    )
    
    # Enable level planning for consistent granularity
    enable_level_planning: bool = field(
        default_factory=lambda: os.getenv(
            "SIMULA_ENABLE_LEVEL_PLANNING", "true"
        ).lower() == "true"
    )
    
    # Cache taxonomy to disk for reuse
    cache_dir: Optional[str] = field(
        default_factory=lambda: os.getenv("SIMULA_TAXONOMY_CACHE")
    )


@dataclass
class TrainingConfig:
    """Configuration for downstream training and student-teacher gap analysis.
    
    From Section 4.3: Student-teacher performance gap impacts scaling laws.
    Performance saturates when student bridges ~83% of the gap.
    """
    
    # Teacher model identifier (used for synthetic data generation)
    teacher_model: str = field(
        default_factory=lambda: os.getenv(
            "SIMULA_TEACHER_MODEL", "Qwen/Qwen3.5-35B"
        )
    )
    
    # Student model identifier (target for fine-tuning)
    student_model: str = field(
        default_factory=lambda: os.getenv(
            "SIMULA_STUDENT_MODEL", "google/gemma-3-4b"
        )
    )
    
    # Known teacher accuracy on target task (0-1, None if unknown)
    teacher_accuracy: Optional[float] = field(
        default_factory=lambda: (
            float(v) if (v := os.getenv("SIMULA_TEACHER_ACCURACY")) else None
        )
    )
    
    # Known student baseline accuracy (0-1, None if unknown)
    student_baseline: Optional[float] = field(
        default_factory=lambda: (
            float(v) if (v := os.getenv("SIMULA_STUDENT_BASELINE")) else None
        )
    )
    
    # Empirical saturation ratio from paper (student bridges this fraction of gap)
    saturation_ratio: float = field(
        default_factory=lambda: float(os.getenv("SIMULA_SATURATION_RATIO", "0.83"))
    )
    
    def expected_saturation_accuracy(self) -> Optional[float]:
        """Predict saturation point per Section 4.3.
        
        From the paper: "performance saturates at around 128k, after bridging
        (65−40)/(70−40) ≃ 83% of the performance gap"
        """
        if self.teacher_accuracy is None or self.student_baseline is None:
            return None
        gap = self.teacher_accuracy - self.student_baseline
        return self.student_baseline + self.saturation_ratio * gap
    
    def gap_analysis(self) -> dict:
        """Return student-teacher gap analysis."""
        expected = self.expected_saturation_accuracy()
        return {
            "teacher_model": self.teacher_model,
            "student_model": self.student_model,
            "teacher_accuracy": self.teacher_accuracy,
            "student_baseline": self.student_baseline,
            "performance_gap": (
                self.teacher_accuracy - self.student_baseline
                if self.teacher_accuracy and self.student_baseline else None
            ),
            "expected_saturation": expected,
            "saturation_ratio": self.saturation_ratio,
        }


@dataclass
class GenerationConfig:
    """Configuration for Simula data generation (Algorithm 2)."""
    
    # Target number of training examples
    target_count: int = field(
        default_factory=lambda: int(os.getenv("SIMULA_TARGET_COUNT", "100000"))
    )
    
    # Fraction of samples to complexify (0.0 - 1.0)
    complexity_ratio: float = field(
        default_factory=lambda: float(os.getenv("SIMULA_COMPLEXITY_RATIO", "0.5"))
    )
    
    # Enable adaptive complexity ratio based on teacher strength (Figure 7)
    adaptive_complexity: bool = field(
        default_factory=lambda: os.getenv(
            "SIMULA_ADAPTIVE_COMPLEXITY", "true"
        ).lower() == "true"
    )
    
    # Number of meta-prompts per taxonomy mix (local diversity)
    meta_prompts_per_mix: int = field(
        default_factory=lambda: int(os.getenv("SIMULA_META_PROMPTS_PER_MIX", "3"))
    )
    
    # Enable double-critic filtering
    enable_critic: bool = field(
        default_factory=lambda: os.getenv(
            "SIMULA_ENABLE_GEN_CRITIC", "true"
        ).lower() == "true"
    )
    
    # Enable adaptive critic thresholding (adjusts based on complexity)
    adaptive_critic_threshold: bool = field(
        default_factory=lambda: os.getenv(
            "SIMULA_CRITIC_ADAPTIVE_THRESHOLD", "true"
        ).lower() == "true"
    )
    
    # Base critic threshold (probability threshold for acceptance)
    critic_threshold: float = field(
        default_factory=lambda: float(os.getenv("SIMULA_CRITIC_THRESHOLD", "0.5"))
    )
    
    # Maximum retries for critic rejection
    max_critic_retries: int = field(
        default_factory=lambda: int(os.getenv("SIMULA_MAX_CRITIC_RETRIES", "3"))
    )
    
    # Output directory
    output_dir: str = field(
        default_factory=lambda: os.getenv(
            "SIMULA_OUTPUT_DIR", "data/hana_generated"
        )
    )
    
    # Output format
    output_format: str = field(
        default_factory=lambda: os.getenv("SIMULA_OUTPUT_FORMAT", "jsonl")
    )
    
    # Seed for reproducibility
    seed: int = field(
        default_factory=lambda: int(os.getenv("SIMULA_SEED", "42"))
    )
    
    def get_adaptive_complexity_ratio(
        self, teacher_accuracy: float | None
    ) -> float:
        """
        Get adaptive complexity ratio based on teacher model strength.
        
        From Figure 7: "complex data can be detrimental when the teacher
        model is weak (LEXam case)."
        
        Args:
            teacher_accuracy: Teacher model accuracy (0-1), None if unknown
            
        Returns:
            Adjusted complexity ratio
        """
        if not self.adaptive_complexity or teacher_accuracy is None:
            return self.complexity_ratio
        
        if teacher_accuracy < 0.6:
            # Weak teacher: significantly reduce complexity
            import logging
            logging.getLogger(__name__).warning(
                f"Teacher accuracy {teacher_accuracy:.1%} < 60%, "
                f"reducing complexity ratio from {self.complexity_ratio} to 0.2"
            )
            return 0.2
        elif teacher_accuracy < 0.7:
            # Moderate teacher: slightly reduce complexity
            return min(self.complexity_ratio, 0.35)
        else:
            return self.complexity_ratio
    
    def get_adaptive_critic_threshold(
        self, complexity_score: float | None
    ) -> float:
        """
        Get adaptive critic threshold based on example complexity.
        
        From Figure 3b: "maintaining [accuracy] lift requires a higher 'cost'
        in rejection rate" as complexity increases.
        
        Args:
            complexity_score: Example complexity (0-1), None if unknown
            
        Returns:
            Adjusted critic threshold
        """
        if not self.adaptive_critic_threshold or complexity_score is None:
            return self.critic_threshold
        
        if complexity_score > 0.7:
            # High complexity: more conservative threshold
            return min(0.7, self.critic_threshold + 0.2)
        elif complexity_score < 0.3:
            # Low complexity: more permissive
            return max(0.3, self.critic_threshold - 0.2)
        else:
            return self.critic_threshold


@dataclass
class SimulaConfig:
    """Master configuration combining all Simula pipeline settings."""
    
    hana: HanaSourceConfig = field(default_factory=HanaSourceConfig)
    llm: LLMConfig = field(default_factory=LLMConfig)
    taxonomy: TaxonomyConfig = field(default_factory=TaxonomyConfig)
    generation: GenerationConfig = field(default_factory=GenerationConfig)
    training: TrainingConfig = field(default_factory=TrainingConfig)
    
    @classmethod
    def from_env(cls) -> "SimulaConfig":
        """Create configuration from environment variables."""
        return cls()
    
    @classmethod
    def from_cli(
        cls,
        hana_schemas: Optional[str] = None,
        llm_url: Optional[str] = None,
        llm_model: Optional[str] = None,
        target_count: Optional[int] = None,
        complexity_ratio: Optional[float] = None,
        output_dir: Optional[str] = None,
        taxonomy_depth: Optional[int] = None,
    ) -> "SimulaConfig":
        """Create configuration from CLI arguments (with env fallback)."""
        config = cls()
        
        if hana_schemas:
            config.hana.schemas = [s.strip() for s in hana_schemas.split(",")]
        if llm_url:
            config.llm.base_url = llm_url
        if llm_model:
            config.llm.model = llm_model
        if target_count is not None:
            config.generation.target_count = target_count
        if complexity_ratio is not None:
            config.generation.complexity_ratio = complexity_ratio
        if output_dir:
            config.generation.output_dir = output_dir
        if taxonomy_depth is not None:
            config.taxonomy.depth = taxonomy_depth
        
        return config
    
    def to_dict(self) -> dict:
        """Serialize configuration to dictionary."""
        return {
            "hana": {
                "mcp_url": self.hana.mcp_url,
                "schemas": self.hana.schemas,
                "table_pattern": self.hana.table_pattern,
                "timeout": self.hana.timeout,
            },
            "llm": {
                "provider": self.llm.provider.value,
                "base_url": self.llm.base_url,
                "model": self.llm.model,
                "temperature": self.llm.temperature,
                "max_tokens": self.llm.max_tokens,
                "max_concurrent": self.llm.max_concurrent,
            },
            "taxonomy": {
                "depth": self.taxonomy.depth,
                "best_of_n": self.taxonomy.best_of_n,
                "enable_critic": self.taxonomy.enable_critic,
                "enable_level_planning": self.taxonomy.enable_level_planning,
                "cache_dir": self.taxonomy.cache_dir,
            },
            "generation": {
                "target_count": self.generation.target_count,
                "complexity_ratio": self.generation.complexity_ratio,
                "meta_prompts_per_mix": self.generation.meta_prompts_per_mix,
                "enable_critic": self.generation.enable_critic,
                "max_critic_retries": self.generation.max_critic_retries,
                "output_dir": self.generation.output_dir,
                "output_format": self.generation.output_format,
                "seed": self.generation.seed,
            },
            "training": self.training.gap_analysis(),
        }


# Default configuration instance
DEFAULT_CONFIG = SimulaConfig()