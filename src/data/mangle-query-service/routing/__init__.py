"""
Routing Module - Model Selection and Backend Routing

Day 8 Deliverable: Model registry and routing logic
"""

from routing.model_registry import (
    ModelProvider,
    ModelCapability,
    ModelTier,
    ModelDefinition,
    BackendDefinition,
    ModelRegistry,
    get_model_registry,
)

from routing.model_router import (
    RoutingStrategy,
    BackendHealth,
    RoutingDecision,
    ModelRouter,
    get_model_router,
)

__all__ = [
    # Registry
    "ModelProvider",
    "ModelCapability",
    "ModelTier",
    "ModelDefinition",
    "BackendDefinition",
    "ModelRegistry",
    "get_model_registry",
    # Router
    "RoutingStrategy",
    "BackendHealth",
    "RoutingDecision",
    "ModelRouter",
    "get_model_router",
]