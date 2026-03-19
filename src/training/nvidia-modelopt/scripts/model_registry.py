#!/usr/bin/env python3
"""
Model Registry for SAP-OSS Training
Supports Qwen 3.5, Qwen 2.5, and NVIDIA Nemotron models
"""

from dataclasses import dataclass
from typing import Dict, Optional, List
from enum import Enum
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


class ModelFamily(Enum):
    QWEN35 = "qwen3.5"
    QWEN25 = "qwen2.5"
    NEMOTRON = "nemotron"
    MINITRON = "minitron"


class ModelTier(Enum):
    ROUTER = "router"           # Small, fast classification
    SPECIALIST = "specialist"    # Domain-specific training
    COMPLEX = "complex"          # Complex multi-step queries
    EDGE = "edge"                # Edge deployment, minimal resources


@dataclass
class ModelConfig:
    """Configuration for a model."""
    model_id: str
    family: ModelFamily
    tier: ModelTier
    size_b: float  # Size in billions
    min_vram_gb: int
    recommended_vram_gb: int
    supports_4bit: bool = True
    supports_8bit: bool = True
    supports_lora: bool = True
    lora_target_modules: List[str] = None
    max_context_length: int = 8192
    released: bool = True  # False if not yet released
    
    def __post_init__(self):
        if self.lora_target_modules is None:
            self.lora_target_modules = [
                "q_proj", "k_proj", "v_proj", "o_proj",
                "gate_proj", "up_proj", "down_proj"
            ]


# =============================================================================
# QWEN 3.5 MODELS (Upcoming Release)
# =============================================================================
QWEN35_MODELS = {
    "qwen3.5-0.8b": ModelConfig(
        model_id="Qwen/Qwen3.5-0.8B-Instruct",
        family=ModelFamily.QWEN35,
        tier=ModelTier.ROUTER,
        size_b=0.8,
        min_vram_gb=2,
        recommended_vram_gb=4,
        max_context_length=32768,
        released=False,  # Not yet released
    ),
    "qwen3.5-4b": ModelConfig(
        model_id="Qwen/Qwen3.5-4B-Instruct",
        family=ModelFamily.QWEN35,
        tier=ModelTier.SPECIALIST,
        size_b=4.0,
        min_vram_gb=10,
        recommended_vram_gb=16,
        max_context_length=32768,
        released=False,
    ),
    "qwen3.5-9b": ModelConfig(
        model_id="Qwen/Qwen3.5-9B-Instruct",
        family=ModelFamily.QWEN35,
        tier=ModelTier.SPECIALIST,
        size_b=9.0,
        min_vram_gb=20,
        recommended_vram_gb=40,
        max_context_length=32768,
        released=False,
    ),
    "qwen3.5-35b": ModelConfig(
        model_id="Qwen/Qwen3.5-35B-Instruct",
        family=ModelFamily.QWEN35,
        tier=ModelTier.COMPLEX,
        size_b=35.0,
        min_vram_gb=70,
        recommended_vram_gb=80,
        max_context_length=32768,
        released=False,
    ),
}

# =============================================================================
# QWEN 2.5 MODELS (Current Fallback)
# =============================================================================
QWEN25_MODELS = {
    "qwen2.5-0.5b": ModelConfig(
        model_id="Qwen/Qwen2.5-0.5B-Instruct",
        family=ModelFamily.QWEN25,
        tier=ModelTier.EDGE,
        size_b=0.5,
        min_vram_gb=2,
        recommended_vram_gb=4,
        max_context_length=32768,
        released=True,
    ),
    "qwen2.5-1.5b": ModelConfig(
        model_id="Qwen/Qwen2.5-1.5B-Instruct",
        family=ModelFamily.QWEN25,
        tier=ModelTier.ROUTER,
        size_b=1.5,
        min_vram_gb=4,
        recommended_vram_gb=8,
        max_context_length=32768,
        released=True,
    ),
    "qwen2.5-3b": ModelConfig(
        model_id="Qwen/Qwen2.5-3B-Instruct",
        family=ModelFamily.QWEN25,
        tier=ModelTier.ROUTER,
        size_b=3.0,
        min_vram_gb=8,
        recommended_vram_gb=12,
        max_context_length=32768,
        released=True,
    ),
    "qwen2.5-7b": ModelConfig(
        model_id="Qwen/Qwen2.5-7B-Instruct",
        family=ModelFamily.QWEN25,
        tier=ModelTier.SPECIALIST,
        size_b=7.0,
        min_vram_gb=16,
        recommended_vram_gb=24,
        max_context_length=32768,
        released=True,
    ),
    "qwen2.5-14b": ModelConfig(
        model_id="Qwen/Qwen2.5-14B-Instruct",
        family=ModelFamily.QWEN25,
        tier=ModelTier.SPECIALIST,
        size_b=14.0,
        min_vram_gb=30,
        recommended_vram_gb=40,
        max_context_length=32768,
        released=True,
    ),
    "qwen2.5-32b": ModelConfig(
        model_id="Qwen/Qwen2.5-32B-Instruct",
        family=ModelFamily.QWEN25,
        tier=ModelTier.COMPLEX,
        size_b=32.0,
        min_vram_gb=70,
        recommended_vram_gb=80,
        max_context_length=32768,
        released=True,
    ),
    "qwen2.5-72b": ModelConfig(
        model_id="Qwen/Qwen2.5-72B-Instruct",
        family=ModelFamily.QWEN25,
        tier=ModelTier.COMPLEX,
        size_b=72.0,
        min_vram_gb=150,
        recommended_vram_gb=160,
        max_context_length=32768,
        released=True,
    ),
}

# =============================================================================
# NVIDIA NEMOTRON MODELS
# =============================================================================
NEMOTRON_MODELS = {
    "nemotron-3-8b": ModelConfig(
        model_id="nvidia/Nemotron-3-8B-Chat-Instruct",
        family=ModelFamily.NEMOTRON,
        tier=ModelTier.SPECIALIST,
        size_b=8.0,
        min_vram_gb=18,
        recommended_vram_gb=24,
        max_context_length=8192,
        lora_target_modules=[
            "q_proj", "k_proj", "v_proj", "o_proj",
            "gate_proj", "up_proj", "down_proj"
        ],
        released=True,
    ),
    "nemotron-4-15b": ModelConfig(
        model_id="nvidia/Nemotron-4-15B-Chat-Instruct",
        family=ModelFamily.NEMOTRON,
        tier=ModelTier.SPECIALIST,
        size_b=15.0,
        min_vram_gb=35,
        recommended_vram_gb=40,
        max_context_length=8192,
        released=True,
    ),
    "nemotron-nano-4b-a3b": ModelConfig(
        model_id="nvidia/Nemotron-Nano-4B-Instruct",
        family=ModelFamily.NEMOTRON,
        tier=ModelTier.ROUTER,
        size_b=4.0,  # 4B total, 3B active (A3B)
        min_vram_gb=10,
        recommended_vram_gb=16,
        max_context_length=8192,
        released=True,
    ),
    "minitron-8b": ModelConfig(
        model_id="nvidia/Minitron-8B-Base",
        family=ModelFamily.MINITRON,
        tier=ModelTier.SPECIALIST,
        size_b=8.0,
        min_vram_gb=18,
        recommended_vram_gb=24,
        max_context_length=8192,
        released=True,
    ),
    "minitron-4b": ModelConfig(
        model_id="nvidia/Minitron-4B-Base",
        family=ModelFamily.MINITRON,
        tier=ModelTier.ROUTER,
        size_b=4.0,
        min_vram_gb=10,
        recommended_vram_gb=16,
        max_context_length=8192,
        released=True,
    ),
}

# =============================================================================
# COMBINED REGISTRY
# =============================================================================
MODEL_REGISTRY: Dict[str, ModelConfig] = {
    **QWEN35_MODELS,
    **QWEN25_MODELS,
    **NEMOTRON_MODELS,
}

# =============================================================================
# RECOMMENDED CONFIGURATIONS
# =============================================================================
RECOMMENDED_BY_GPU = {
    "T4_16GB": {
        "router": "qwen2.5-1.5b",
        "specialist": "qwen2.5-7b",  # 4-bit quantized
        "fallback": "qwen2.5-0.5b",
    },
    "L4_24GB": {
        "router": "qwen2.5-3b",
        "specialist": "qwen2.5-14b",  # 4-bit quantized
        "nemotron": "nemotron-3-8b",
    },
    "A10_24GB": {
        "router": "qwen2.5-3b",
        "specialist": "qwen2.5-14b",
        "nemotron": "nemotron-3-8b",
    },
    "A100_40GB": {
        "router": "qwen2.5-7b",
        "specialist": "qwen2.5-14b",  # 8-bit
        "nemotron": "nemotron-4-15b",
    },
    "A100_80GB": {
        "router": "qwen2.5-7b",
        "specialist": "qwen2.5-32b",  # 8-bit
        "complex": "qwen2.5-72b",  # 4-bit
    },
    "H100_80GB": {
        "router": "qwen3.5-0.8b",  # When released
        "specialist": "qwen3.5-9b",
        "complex": "qwen3.5-35b",
        "nemotron": "nemotron-4-15b",
    },
    "H200_141GB": {
        "router": "qwen3.5-0.8b",
        "specialist": "qwen3.5-35b",  # Full precision
        "complex": "qwen2.5-72b",  # 16-bit
    },
}

# =============================================================================
# FALLBACK MAPPING (Qwen3.5 -> Qwen2.5)
# =============================================================================
FALLBACK_MAP = {
    "qwen3.5-0.8b": "qwen2.5-1.5b",
    "qwen3.5-4b": "qwen2.5-7b",
    "qwen3.5-9b": "qwen2.5-14b",
    "qwen3.5-35b": "qwen2.5-32b",
}


class ModelSelector:
    """Select appropriate model based on requirements."""
    
    @staticmethod
    def get_model(model_name: str, allow_fallback: bool = True) -> ModelConfig:
        """Get model config, with optional fallback for unreleased models."""
        if model_name not in MODEL_REGISTRY:
            raise ValueError(f"Unknown model: {model_name}")
        
        config = MODEL_REGISTRY[model_name]
        
        if not config.released and allow_fallback:
            if model_name in FALLBACK_MAP:
                fallback_name = FALLBACK_MAP[model_name]
                logger.warning(
                    f"Model {model_name} not yet released. "
                    f"Falling back to {fallback_name}"
                )
                return MODEL_REGISTRY[fallback_name]
            else:
                raise ValueError(f"Model {model_name} not released and no fallback available")
        
        return config
    
    @staticmethod
    def get_for_gpu(gpu_type: str, tier: str = "specialist") -> ModelConfig:
        """Get recommended model for GPU type and tier."""
        if gpu_type not in RECOMMENDED_BY_GPU:
            raise ValueError(f"Unknown GPU type: {gpu_type}")
        
        recommendations = RECOMMENDED_BY_GPU[gpu_type]
        if tier not in recommendations:
            raise ValueError(f"No {tier} model recommended for {gpu_type}")
        
        model_name = recommendations[tier]
        return ModelSelector.get_model(model_name)
    
    @staticmethod
    def get_by_vram(vram_gb: int, tier: ModelTier = ModelTier.SPECIALIST) -> ModelConfig:
        """Get best model that fits in available VRAM."""
        candidates = [
            config for config in MODEL_REGISTRY.values()
            if config.released 
            and config.tier == tier 
            and config.min_vram_gb <= vram_gb
        ]
        
        if not candidates:
            raise ValueError(f"No {tier.value} models fit in {vram_gb}GB VRAM")
        
        # Return largest model that fits
        return max(candidates, key=lambda c: c.size_b)
    
    @staticmethod
    def list_available(tier: Optional[ModelTier] = None, 
                       family: Optional[ModelFamily] = None) -> List[ModelConfig]:
        """List available (released) models."""
        models = MODEL_REGISTRY.values()
        
        if tier:
            models = [m for m in models if m.tier == tier]
        if family:
            models = [m for m in models if m.family == family]
        
        return [m for m in models if m.released]


# =============================================================================
# TRAINING CONFIGURATION GENERATOR
# =============================================================================
def get_training_config(
    model_name: str,
    vram_gb: int,
    specialist_type: str = "general"
) -> dict:
    """Generate training configuration for a model."""
    config = ModelSelector.get_model(model_name)
    
    # Determine quantization based on VRAM
    if vram_gb < config.min_vram_gb:
        raise ValueError(f"Insufficient VRAM: {vram_gb}GB < {config.min_vram_gb}GB required")
    
    # Calculate optimal settings
    if vram_gb >= config.recommended_vram_gb * 2:
        quantization = None  # Full precision
        batch_size = 4
    elif vram_gb >= config.recommended_vram_gb:
        quantization = "8bit"
        batch_size = 2
    else:
        quantization = "4bit"
        batch_size = 1
    
    # LoRA settings based on model size
    if config.size_b <= 3:
        lora_r = 16
        lora_alpha = 32
    elif config.size_b <= 10:
        lora_r = 32
        lora_alpha = 64
    else:
        lora_r = 64
        lora_alpha = 128
    
    return {
        "model_id": config.model_id,
        "model_family": config.family.value,
        "model_tier": config.tier.value,
        "quantization": quantization,
        "batch_size": batch_size,
        "gradient_accumulation_steps": 16 // batch_size,
        "lora": {
            "r": lora_r,
            "alpha": lora_alpha,
            "target_modules": config.lora_target_modules,
            "dropout": 0.05,
        },
        "training": {
            "learning_rate": 2e-4,
            "warmup_ratio": 0.05,
            "max_seq_length": min(config.max_context_length, 2048),
            "num_train_epochs": 3,
        },
        "specialist_type": specialist_type,
    }


# =============================================================================
# CLI
# =============================================================================
if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description="Model Registry")
    parser.add_argument("--list", action="store_true", help="List all models")
    parser.add_argument("--tier", choices=["router", "specialist", "complex", "edge"])
    parser.add_argument("--family", choices=["qwen3.5", "qwen2.5", "nemotron", "minitron"])
    parser.add_argument("--gpu", help="GPU type (e.g., T4_16GB, A100_40GB)")
    parser.add_argument("--vram", type=int, help="Available VRAM in GB")
    parser.add_argument("--config", help="Generate training config for model")
    
    args = parser.parse_args()
    
    if args.list:
        tier = ModelTier(args.tier) if args.tier else None
        family = ModelFamily(args.family) if args.family else None
        
        models = ModelSelector.list_available(tier, family)
        print(f"\n{'Model Name':<25} {'Size':<8} {'Family':<12} {'Tier':<12} {'VRAM':<10}")
        print("=" * 70)
        for m in sorted(models, key=lambda x: x.size_b):
            print(f"{m.model_id:<25} {m.size_b:<8.1f}B {m.family.value:<12} {m.tier.value:<12} {m.min_vram_gb}GB+")
    
    elif args.gpu:
        tier = args.tier or "specialist"
        model = ModelSelector.get_for_gpu(args.gpu, tier)
        print(f"\nRecommended {tier} model for {args.gpu}:")
        print(f"  Model: {model.model_id}")
        print(f"  Size: {model.size_b}B")
        print(f"  VRAM: {model.min_vram_gb}GB min, {model.recommended_vram_gb}GB recommended")
    
    elif args.vram:
        tier = ModelTier(args.tier) if args.tier else ModelTier.SPECIALIST
        model = ModelSelector.get_by_vram(args.vram, tier)
        print(f"\nBest {tier.value} model for {args.vram}GB VRAM:")
        print(f"  Model: {model.model_id}")
        print(f"  Size: {model.size_b}B")
    
    elif args.config:
        vram = args.vram or 24
        config = get_training_config(args.config, vram)
        import json
        print(json.dumps(config, indent=2))
    
    else:
        parser.print_help()