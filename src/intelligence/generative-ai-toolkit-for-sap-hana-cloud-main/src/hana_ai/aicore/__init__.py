# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
Enhanced SAP AI Core Integration for HANA Cloud Generative AI Toolkit.

Provides advanced features for AI Core Foundation Model integration:
- Intelligent model routing (cost/latency/quality optimization)
- Response caching for reduced API calls
- Automatic fallback chains between models
- Token budget management
- Rate limiting
"""

from hana_ai.aicore.enhanced_client import (
    # Configuration
    AICoreConfig,
    
    # Model information
    ModelCapability,
    ModelTier,
    ModelInfo,
    
    # Token management
    TokenUsage,
    TokenBudget,
    
    # Routing
    RoutingStrategy,
    ModelRouter,
    
    # Client
    EnhancedAICoreClient,
    get_aicore_client,
)

__all__ = [
    # Configuration
    "AICoreConfig",
    
    # Model information
    "ModelCapability",
    "ModelTier",
    "ModelInfo",
    
    # Token management
    "TokenUsage",
    "TokenBudget",
    
    # Routing
    "RoutingStrategy",
    "ModelRouter",
    
    # Client
    "EnhancedAICoreClient",
    "get_aicore_client",
]