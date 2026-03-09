#!/usr/bin/env python3
"""
Model Registry — single source of truth for model metadata and paths.

All model ID → path mappings, catalog entries, and OpenAI model objects
are defined here. Other modules import from this registry instead of
maintaining their own copies.
"""

import os
import logging
from datetime import datetime
from dataclasses import dataclass, field
from typing import Dict, List, Optional
from pathlib import Path

logger = logging.getLogger(__name__)

OUTPUT_DIR = Path(os.getenv("MODELOPT_OUTPUT_DIR", "./outputs"))


@dataclass
class ModelEntry:
    """A single model known to the service."""

    model_id: str
    hf_name: str
    local_path: str
    size_gb: float
    parameters: str
    recommended_quant: str
    t4_compatible: bool
    created_timestamp: int = field(
        default_factory=lambda: int(datetime(2024, 12, 1).timestamp())
    )
    owned_by: str = "nvidia-modelopt"

    # --- derived helpers ---

    @property
    def resolved_path(self) -> str:
        """Return local path if it exists on disk, else the HF name."""
        local = OUTPUT_DIR / self.local_path
        if local.exists():
            return str(local)
        return self.hf_name

    @property
    def is_local(self) -> bool:
        return (OUTPUT_DIR / self.local_path).exists()


# ============================================================================
# Canonical model definitions — edit HERE to add/remove models
# ============================================================================

_MODELS: List[ModelEntry] = [
    ModelEntry(
        model_id="qwen3.5-0.6b-int8",
        hf_name="Qwen/Qwen3.5-0.6B",
        local_path="Qwen3.5-0.6B_int8",
        size_gb=1.2,
        parameters="0.6B",
        recommended_quant="int8",
        t4_compatible=True,
    ),
    ModelEntry(
        model_id="qwen3.5-1.8b-int8",
        hf_name="Qwen/Qwen3.5-1.8B",
        local_path="Qwen3.5-1.8B_int8",
        size_gb=3.6,
        parameters="1.8B",
        recommended_quant="int8",
        t4_compatible=True,
    ),
    ModelEntry(
        model_id="qwen3.5-4b-int8",
        hf_name="Qwen/Qwen3.5-4B",
        local_path="Qwen3.5-4B_int8",
        size_gb=8.0,
        parameters="4B",
        recommended_quant="int8",
        t4_compatible=True,
    ),
    ModelEntry(
        model_id="qwen3.5-9b-int4-awq",
        hf_name="Qwen/Qwen3.5-9B",
        local_path="Qwen3.5-9B_int4_awq",
        size_gb=18.0,
        parameters="9B",
        recommended_quant="int4_awq",
        t4_compatible=True,
    ),
]

# Fast lookup by model_id
_BY_ID: Dict[str, ModelEntry] = {m.model_id: m for m in _MODELS}


# ============================================================================
# Public API
# ============================================================================


def list_models() -> List[ModelEntry]:
    """Return all registered models."""
    return list(_MODELS)


def get_model(model_id: str) -> Optional[ModelEntry]:
    """Look up a model by its ID. Returns None if not found."""
    return _BY_ID.get(model_id)


def model_ids() -> List[str]:
    """Return all known model IDs."""
    return list(_BY_ID.keys())


def resolve_path(model_id: str) -> str:
    """Resolve a model ID to a loadable path (local or HF)."""
    entry = _BY_ID.get(model_id)
    if entry:
        return entry.resolved_path
    # Unknown model — assume it's a HF name or raw path
    return model_id


def model_exists_locally(model_id: str) -> bool:
    """Check whether the quantised model exists on disk."""
    entry = _BY_ID.get(model_id)
    return entry.is_local if entry else False

