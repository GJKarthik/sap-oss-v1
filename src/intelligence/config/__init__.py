"""
Config Module - TB-HITL Entity Parameters Implementation

This module provides per-legal-entity configuration loading
with JSON Schema validation and Git SHA versioning.
"""

from .entity_params import (
    EntityParams,
    EntityParamsRegistry,
    EntityParamsLoadError,
    MaterialityThresholds,
    ReviewConfig,
    create_example_entity_params,
)

__all__ = [
    "EntityParams",
    "EntityParamsRegistry",
    "EntityParamsLoadError",
    "MaterialityThresholds",
    "ReviewConfig",
    "create_example_entity_params",
]