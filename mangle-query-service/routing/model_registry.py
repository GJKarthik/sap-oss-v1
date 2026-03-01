"""
Model Registry for OpenAI-Compatible API

Day 8 Deliverable: Model definitions, capabilities, and backend mapping
- Model metadata and capabilities
- Backend configuration
- Model aliasing
- Context window limits

Usage:
    from routing.model_registry import ModelRegistry
    
    registry = ModelRegistry()
    model_info = registry.get_model("gpt-4")
"""

import logging
from typing import Optional, Dict, Any, List, Set
from dataclasses import dataclass, field
from enum import Enum

logger = logging.getLogger(__name__)


# ========================================
# Enums
# ========================================

class ModelProvider(str, Enum):
    """Model providers."""
    OPENAI = "openai"
    ANTHROPIC = "anthropic"
    GOOGLE = "google"
    AZURE = "azure"
    SAP_AI_CORE = "sap_ai_core"
    LOCAL = "local"


class ModelCapability(str, Enum):
    """Model capabilities."""
    CHAT = "chat"
    COMPLETION = "completion"
    EMBEDDING = "embedding"
    VISION = "vision"
    FUNCTION_CALLING = "function_calling"
    TOOL_USE = "tool_use"
    JSON_MODE = "json_mode"
    STREAMING = "streaming"


class ModelTier(str, Enum):
    """Model tiers for routing decisions."""
    PREMIUM = "premium"
    STANDARD = "standard"
    ECONOMY = "economy"


# ========================================
# Model Definition
# ========================================

@dataclass
class ModelDefinition:
    """
    Definition of a model and its capabilities.
    
    Attributes:
        id: Model identifier (e.g., "gpt-4")
        provider: Model provider
        backend_id: Backend model identifier (may differ from id)
        display_name: Human-readable name
        capabilities: Set of capabilities
        tier: Model tier for routing
        context_window: Max context window size
        max_output_tokens: Max output tokens
        input_cost_per_1k: Cost per 1k input tokens (USD)
        output_cost_per_1k: Cost per 1k output tokens (USD)
        enabled: Whether model is enabled
        deprecated: Whether model is deprecated
        aliases: Alternative names for this model
    """
    id: str
    provider: ModelProvider
    backend_id: str
    display_name: str
    capabilities: Set[ModelCapability] = field(default_factory=set)
    tier: ModelTier = ModelTier.STANDARD
    context_window: int = 4096
    max_output_tokens: int = 4096
    input_cost_per_1k: float = 0.0
    output_cost_per_1k: float = 0.0
    enabled: bool = True
    deprecated: bool = False
    aliases: List[str] = field(default_factory=list)
    metadata: Dict[str, Any] = field(default_factory=dict)
    
    def supports(self, capability: ModelCapability) -> bool:
        """Check if model supports a capability."""
        return capability in self.capabilities
    
    def supports_all(self, capabilities: List[ModelCapability]) -> bool:
        """Check if model supports all capabilities."""
        return all(cap in self.capabilities for cap in capabilities)
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for API response."""
        return {
            "id": self.id,
            "object": "model",
            "created": 0,  # Not tracked
            "owned_by": self.provider.value,
            "permission": [],
            "root": self.id,
            "parent": None,
        }
    
    def to_detailed_dict(self) -> Dict[str, Any]:
        """Convert to detailed dictionary."""
        return {
            "id": self.id,
            "provider": self.provider.value,
            "backend_id": self.backend_id,
            "display_name": self.display_name,
            "capabilities": [cap.value for cap in self.capabilities],
            "tier": self.tier.value,
            "context_window": self.context_window,
            "max_output_tokens": self.max_output_tokens,
            "enabled": self.enabled,
            "deprecated": self.deprecated,
        }


# ========================================
# Backend Definition
# ========================================

@dataclass
class BackendDefinition:
    """
    Definition of a backend service.
    
    Attributes:
        id: Backend identifier
        provider: Backend provider
        base_url: Base URL for API calls
        api_key_env: Environment variable for API key
        enabled: Whether backend is enabled
        priority: Priority for load balancing (higher = preferred)
        max_concurrent: Max concurrent requests
        timeout: Request timeout in seconds
        supports_streaming: Whether backend supports streaming
        health_check_endpoint: Health check endpoint
    """
    id: str
    provider: ModelProvider
    base_url: str
    api_key_env: str = ""
    enabled: bool = True
    priority: int = 100
    max_concurrent: int = 100
    timeout: float = 60.0
    supports_streaming: bool = True
    health_check_endpoint: str = "/health"
    metadata: Dict[str, Any] = field(default_factory=dict)


# ========================================
# Model Registry
# ========================================

class ModelRegistry:
    """
    Registry of available models and backends.
    
    Responsibilities:
    - Store model definitions
    - Handle model aliases
    - Provide model lookup
    - List available models
    """
    
    def __init__(self):
        self._models: Dict[str, ModelDefinition] = {}
        self._backends: Dict[str, BackendDefinition] = {}
        self._aliases: Dict[str, str] = {}
        
        # Initialize with default models
        self._register_default_models()
        self._register_default_backends()
    
    def _register_default_models(self) -> None:
        """Register default model definitions."""
        
        # OpenAI GPT-4 series
        self.register_model(ModelDefinition(
            id="gpt-4",
            provider=ModelProvider.OPENAI,
            backend_id="gpt-4",
            display_name="GPT-4",
            capabilities={
                ModelCapability.CHAT,
                ModelCapability.FUNCTION_CALLING,
                ModelCapability.TOOL_USE,
                ModelCapability.JSON_MODE,
                ModelCapability.STREAMING,
            },
            tier=ModelTier.PREMIUM,
            context_window=8192,
            max_output_tokens=4096,
            input_cost_per_1k=0.03,
            output_cost_per_1k=0.06,
            aliases=["gpt-4-0613"],
        ))
        
        self.register_model(ModelDefinition(
            id="gpt-4-turbo",
            provider=ModelProvider.OPENAI,
            backend_id="gpt-4-turbo-preview",
            display_name="GPT-4 Turbo",
            capabilities={
                ModelCapability.CHAT,
                ModelCapability.VISION,
                ModelCapability.FUNCTION_CALLING,
                ModelCapability.TOOL_USE,
                ModelCapability.JSON_MODE,
                ModelCapability.STREAMING,
            },
            tier=ModelTier.PREMIUM,
            context_window=128000,
            max_output_tokens=4096,
            input_cost_per_1k=0.01,
            output_cost_per_1k=0.03,
            aliases=["gpt-4-turbo-preview", "gpt-4-1106-preview"],
        ))
        
        self.register_model(ModelDefinition(
            id="gpt-4o",
            provider=ModelProvider.OPENAI,
            backend_id="gpt-4o",
            display_name="GPT-4 Omni",
            capabilities={
                ModelCapability.CHAT,
                ModelCapability.VISION,
                ModelCapability.FUNCTION_CALLING,
                ModelCapability.TOOL_USE,
                ModelCapability.JSON_MODE,
                ModelCapability.STREAMING,
            },
            tier=ModelTier.PREMIUM,
            context_window=128000,
            max_output_tokens=16384,
            input_cost_per_1k=0.005,
            output_cost_per_1k=0.015,
            aliases=["gpt-4o-2024-05-13"],
        ))
        
        self.register_model(ModelDefinition(
            id="gpt-4o-mini",
            provider=ModelProvider.OPENAI,
            backend_id="gpt-4o-mini",
            display_name="GPT-4 Omni Mini",
            capabilities={
                ModelCapability.CHAT,
                ModelCapability.VISION,
                ModelCapability.FUNCTION_CALLING,
                ModelCapability.TOOL_USE,
                ModelCapability.JSON_MODE,
                ModelCapability.STREAMING,
            },
            tier=ModelTier.STANDARD,
            context_window=128000,
            max_output_tokens=16384,
            input_cost_per_1k=0.00015,
            output_cost_per_1k=0.0006,
        ))
        
        # OpenAI GPT-3.5 series
        self.register_model(ModelDefinition(
            id="gpt-3.5-turbo",
            provider=ModelProvider.OPENAI,
            backend_id="gpt-3.5-turbo",
            display_name="GPT-3.5 Turbo",
            capabilities={
                ModelCapability.CHAT,
                ModelCapability.FUNCTION_CALLING,
                ModelCapability.TOOL_USE,
                ModelCapability.JSON_MODE,
                ModelCapability.STREAMING,
            },
            tier=ModelTier.ECONOMY,
            context_window=16385,
            max_output_tokens=4096,
            input_cost_per_1k=0.0005,
            output_cost_per_1k=0.0015,
            aliases=["gpt-3.5-turbo-0125", "gpt-3.5-turbo-16k"],
        ))
        
        # Anthropic Claude series
        self.register_model(ModelDefinition(
            id="claude-3-opus",
            provider=ModelProvider.ANTHROPIC,
            backend_id="claude-3-opus-20240229",
            display_name="Claude 3 Opus",
            capabilities={
                ModelCapability.CHAT,
                ModelCapability.VISION,
                ModelCapability.TOOL_USE,
                ModelCapability.STREAMING,
            },
            tier=ModelTier.PREMIUM,
            context_window=200000,
            max_output_tokens=4096,
            input_cost_per_1k=0.015,
            output_cost_per_1k=0.075,
        ))
        
        self.register_model(ModelDefinition(
            id="claude-3-sonnet",
            provider=ModelProvider.ANTHROPIC,
            backend_id="claude-3-sonnet-20240229",
            display_name="Claude 3 Sonnet",
            capabilities={
                ModelCapability.CHAT,
                ModelCapability.VISION,
                ModelCapability.TOOL_USE,
                ModelCapability.STREAMING,
            },
            tier=ModelTier.STANDARD,
            context_window=200000,
            max_output_tokens=4096,
            input_cost_per_1k=0.003,
            output_cost_per_1k=0.015,
        ))
        
        self.register_model(ModelDefinition(
            id="claude-3-haiku",
            provider=ModelProvider.ANTHROPIC,
            backend_id="claude-3-haiku-20240307",
            display_name="Claude 3 Haiku",
            capabilities={
                ModelCapability.CHAT,
                ModelCapability.VISION,
                ModelCapability.TOOL_USE,
                ModelCapability.STREAMING,
            },
            tier=ModelTier.ECONOMY,
            context_window=200000,
            max_output_tokens=4096,
            input_cost_per_1k=0.00025,
            output_cost_per_1k=0.00125,
        ))
        
        # Embedding models
        self.register_model(ModelDefinition(
            id="text-embedding-3-small",
            provider=ModelProvider.OPENAI,
            backend_id="text-embedding-3-small",
            display_name="Text Embedding 3 Small",
            capabilities={ModelCapability.EMBEDDING},
            tier=ModelTier.ECONOMY,
            context_window=8191,
            max_output_tokens=0,
            input_cost_per_1k=0.00002,
            output_cost_per_1k=0.0,
        ))
        
        self.register_model(ModelDefinition(
            id="text-embedding-3-large",
            provider=ModelProvider.OPENAI,
            backend_id="text-embedding-3-large",
            display_name="Text Embedding 3 Large",
            capabilities={ModelCapability.EMBEDDING},
            tier=ModelTier.STANDARD,
            context_window=8191,
            max_output_tokens=0,
            input_cost_per_1k=0.00013,
            output_cost_per_1k=0.0,
        ))
    
    def _register_default_backends(self) -> None:
        """Register default backend definitions."""
        
        self.register_backend(BackendDefinition(
            id="openai",
            provider=ModelProvider.OPENAI,
            base_url="https://api.openai.com/v1",
            api_key_env="OPENAI_API_KEY",
            priority=100,
        ))
        
        self.register_backend(BackendDefinition(
            id="anthropic",
            provider=ModelProvider.ANTHROPIC,
            base_url="https://api.anthropic.com",
            api_key_env="ANTHROPIC_API_KEY",
            priority=90,
        ))
        
        self.register_backend(BackendDefinition(
            id="sap_ai_core",
            provider=ModelProvider.SAP_AI_CORE,
            base_url="",  # Configured via environment
            api_key_env="SAP_AI_CORE_API_KEY",
            priority=80,
        ))
    
    def register_model(self, model: ModelDefinition) -> None:
        """Register a model."""
        self._models[model.id] = model
        
        # Register aliases
        for alias in model.aliases:
            self._aliases[alias] = model.id
        
        logger.debug(f"Registered model: {model.id}")
    
    def register_backend(self, backend: BackendDefinition) -> None:
        """Register a backend."""
        self._backends[backend.id] = backend
        logger.debug(f"Registered backend: {backend.id}")
    
    def get_model(self, model_id: str) -> Optional[ModelDefinition]:
        """
        Get model by ID or alias.
        
        Args:
            model_id: Model ID or alias
        
        Returns:
            Model definition or None if not found
        """
        # Direct lookup
        if model_id in self._models:
            return self._models[model_id]
        
        # Alias lookup
        if model_id in self._aliases:
            return self._models[self._aliases[model_id]]
        
        return None
    
    def get_backend(self, backend_id: str) -> Optional[BackendDefinition]:
        """Get backend by ID."""
        return self._backends.get(backend_id)
    
    def get_backend_for_model(self, model_id: str) -> Optional[BackendDefinition]:
        """Get backend for a model."""
        model = self.get_model(model_id)
        if not model:
            return None
        
        # Find backend by provider
        for backend in self._backends.values():
            if backend.provider == model.provider and backend.enabled:
                return backend
        
        return None
    
    def list_models(
        self,
        enabled_only: bool = True,
        capability: Optional[ModelCapability] = None,
        tier: Optional[ModelTier] = None,
    ) -> List[ModelDefinition]:
        """
        List models with optional filtering.
        
        Args:
            enabled_only: Only return enabled models
            capability: Filter by capability
            tier: Filter by tier
        
        Returns:
            List of matching models
        """
        models = []
        
        for model in self._models.values():
            if enabled_only and not model.enabled:
                continue
            if capability and not model.supports(capability):
                continue
            if tier and model.tier != tier:
                continue
            
            models.append(model)
        
        return sorted(models, key=lambda m: m.id)
    
    def list_chat_models(self) -> List[ModelDefinition]:
        """List models that support chat."""
        return self.list_models(capability=ModelCapability.CHAT)
    
    def list_embedding_models(self) -> List[ModelDefinition]:
        """List models that support embeddings."""
        return self.list_models(capability=ModelCapability.EMBEDDING)
    
    def model_exists(self, model_id: str) -> bool:
        """Check if model exists."""
        return self.get_model(model_id) is not None
    
    def resolve_alias(self, model_id: str) -> str:
        """Resolve model alias to canonical ID."""
        if model_id in self._aliases:
            return self._aliases[model_id]
        return model_id


# ========================================
# Singleton Instance
# ========================================

_registry: Optional[ModelRegistry] = None


def get_model_registry() -> ModelRegistry:
    """Get global model registry instance."""
    global _registry
    if _registry is None:
        _registry = ModelRegistry()
    return _registry


# ========================================
# Exports
# ========================================

__all__ = [
    "ModelProvider",
    "ModelCapability",
    "ModelTier",
    "ModelDefinition",
    "BackendDefinition",
    "ModelRegistry",
    "get_model_registry",
]