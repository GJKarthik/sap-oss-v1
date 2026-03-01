"""
OpenAI Models Endpoint Handler

Day 10 Deliverable: /v1/models endpoint for listing and retrieving models
Reference: https://platform.openai.com/docs/api-reference/models

Usage:
    from openai.models_endpoint import ModelsHandler
    
    handler = ModelsHandler()
    models_list = handler.list_models()
    model = handler.get_model("gpt-4")
"""

import time
import logging
from typing import Optional, Dict, Any, List
from dataclasses import dataclass, field
from enum import Enum

from routing.model_registry import (
    ModelRegistry,
    ModelDefinition,
    ModelCapability,
    ModelTier,
    get_model_registry,
)

logger = logging.getLogger(__name__)


# ========================================
# Permission Types
# ========================================

class ModelPermission(str, Enum):
    """Model permission types."""
    CREATE_ENGINE = "create_engine"
    FINE_TUNE = "fine_tune"
    SAMPLE = "sample"


# ========================================
# Model Object (OpenAI Compatible)
# ========================================

@dataclass
class ModelObject:
    """
    OpenAI-compatible model object.
    
    Reference: https://platform.openai.com/docs/api-reference/models/object
    """
    id: str
    object: str = "model"
    created: int = 0
    owned_by: str = "sap-ai-core"
    
    # Extended fields (not in OpenAI spec but useful)
    permission: Optional[List[Dict[str, Any]]] = None
    root: Optional[str] = None
    parent: Optional[str] = None
    
    @classmethod
    def from_definition(
        cls,
        definition: ModelDefinition,
        include_permissions: bool = False,
    ) -> "ModelObject":
        """Create from ModelDefinition."""
        model = cls(
            id=definition.id,
            object="model",
            created=0,  # OpenAI returns 0 for most models
            owned_by=definition.provider.value,
            root=definition.id,
        )
        
        if include_permissions:
            model.permission = [
                {
                    "id": f"modelperm-{definition.id[:8]}",
                    "object": "model_permission",
                    "created": 0,
                    "allow_create_engine": False,
                    "allow_sampling": True,
                    "allow_logprobs": True,
                    "allow_search_indices": False,
                    "allow_view": True,
                    "allow_fine_tuning": False,
                    "organization": "*",
                    "group": None,
                    "is_blocking": False,
                }
            ]
        
        return model
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {
            "id": self.id,
            "object": self.object,
            "created": self.created,
            "owned_by": self.owned_by,
        }
        
        if self.permission is not None:
            result["permission"] = self.permission
        if self.root is not None:
            result["root"] = self.root
        if self.parent is not None:
            result["parent"] = self.parent
        
        return result


@dataclass
class ModelObjectExtended(ModelObject):
    """
    Extended model object with additional SAP-specific fields.
    
    Includes capabilities, context window, tier information.
    """
    display_name: Optional[str] = None
    capabilities: Optional[List[str]] = None
    context_window: Optional[int] = None
    max_output_tokens: Optional[int] = None
    tier: Optional[str] = None
    enabled: bool = True
    
    @classmethod
    def from_definition(
        cls,
        definition: ModelDefinition,
        include_permissions: bool = False,
    ) -> "ModelObjectExtended":
        """Create from ModelDefinition with extended fields."""
        base = super().from_definition(definition, include_permissions)
        
        return cls(
            id=base.id,
            object=base.object,
            created=base.created,
            owned_by=base.owned_by,
            permission=base.permission,
            root=base.root,
            parent=base.parent,
            display_name=definition.display_name,
            capabilities=[c.value for c in definition.capabilities],
            context_window=definition.context_window,
            max_output_tokens=definition.max_output_tokens,
            tier=definition.tier.value,
            enabled=definition.enabled,
        )
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary with extended fields."""
        result = super().to_dict()
        
        if self.display_name is not None:
            result["display_name"] = self.display_name
        if self.capabilities is not None:
            result["capabilities"] = self.capabilities
        if self.context_window is not None:
            result["context_window"] = self.context_window
        if self.max_output_tokens is not None:
            result["max_output_tokens"] = self.max_output_tokens
        if self.tier is not None:
            result["tier"] = self.tier
        result["enabled"] = self.enabled
        
        return result


# ========================================
# Models List Response
# ========================================

@dataclass
class ModelsListResponse:
    """
    OpenAI-compatible models list response.
    
    Reference: https://platform.openai.com/docs/api-reference/models/list
    """
    object: str = "list"
    data: List[ModelObject] = field(default_factory=list)
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "object": self.object,
            "data": [m.to_dict() for m in self.data],
        }


@dataclass
class ModelsListResponseExtended(ModelsListResponse):
    """
    Extended models list response with filtering metadata.
    """
    total: int = 0
    filtered_by: Optional[Dict[str, Any]] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary with extended fields."""
        result = super().to_dict()
        result["total"] = self.total
        if self.filtered_by:
            result["filtered_by"] = self.filtered_by
        return result


# ========================================
# Delete Response
# ========================================

@dataclass
class DeleteModelResponse:
    """
    Response for model deletion (fine-tuned models only).
    
    Note: SAP AI Core managed models cannot be deleted.
    """
    id: str
    object: str = "model"
    deleted: bool = False
    error: Optional[str] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {
            "id": self.id,
            "object": self.object,
            "deleted": self.deleted,
        }
        if self.error:
            result["error"] = self.error
        return result


# ========================================
# Models Handler
# ========================================

class ModelsHandler:
    """
    Handler for /v1/models endpoint.
    
    Provides OpenAI-compatible model listing and retrieval.
    All models are via SAP AI Core or private vLLM - no direct
    external API access.
    """
    
    def __init__(self, registry: Optional[ModelRegistry] = None):
        """
        Initialize handler.
        
        Args:
            registry: Model registry instance. Uses global if not provided.
        """
        self._registry = registry or get_model_registry()
    
    @property
    def registry(self) -> ModelRegistry:
        """Get model registry."""
        return self._registry
    
    def list_models(
        self,
        enabled_only: bool = True,
        capability: Optional[str] = None,
        tier: Optional[str] = None,
        provider: Optional[str] = None,
        extended: bool = False,
    ) -> Dict[str, Any]:
        """
        List available models.
        
        Args:
            enabled_only: Only return enabled models
            capability: Filter by capability (chat, embedding, etc.)
            tier: Filter by tier (premium, standard, economy)
            provider: Filter by provider (sap_ai_core, vllm)
            extended: Include extended model information
        
        Returns:
            OpenAI-compatible models list response
        
        Example:
            GET /v1/models
            GET /v1/models?capability=chat
            GET /v1/models?extended=true
        """
        models = self._registry.list_models(enabled_only=enabled_only)
        
        # Apply filters
        if capability:
            try:
                cap = ModelCapability(capability)
                models = [m for m in models if m.supports(cap)]
            except ValueError:
                logger.warning(f"Unknown capability filter: {capability}")
        
        if tier:
            try:
                tier_enum = ModelTier(tier)
                models = [m for m in models if m.tier == tier_enum]
            except ValueError:
                logger.warning(f"Unknown tier filter: {tier}")
        
        if provider:
            models = [m for m in models if m.provider.value == provider]
        
        # Convert to response objects
        if extended:
            model_objects = [
                ModelObjectExtended.from_definition(m)
                for m in models
            ]
            response = ModelsListResponseExtended(
                data=model_objects,
                total=len(model_objects),
                filtered_by={
                    "capability": capability,
                    "tier": tier,
                    "provider": provider,
                } if any([capability, tier, provider]) else None,
            )
        else:
            model_objects = [ModelObject.from_definition(m) for m in models]
            response = ModelsListResponse(data=model_objects)
        
        return response.to_dict()
    
    def get_model(
        self,
        model_id: str,
        extended: bool = False,
    ) -> Optional[Dict[str, Any]]:
        """
        Get a specific model by ID.
        
        Args:
            model_id: Model ID or alias
            extended: Include extended model information
        
        Returns:
            Model object or None if not found
        
        Example:
            GET /v1/models/gpt-4
        """
        definition = self._registry.get_model(model_id)
        
        if not definition:
            return None
        
        if extended:
            return ModelObjectExtended.from_definition(
                definition,
                include_permissions=True,
            ).to_dict()
        else:
            return ModelObject.from_definition(
                definition,
                include_permissions=True,
            ).to_dict()
    
    def model_exists(self, model_id: str) -> bool:
        """Check if a model exists."""
        return self._registry.model_exists(model_id)
    
    def delete_model(self, model_id: str) -> Dict[str, Any]:
        """
        Delete a model (fine-tuned models only).
        
        Note: SAP AI Core managed models cannot be deleted.
        This endpoint is included for OpenAI API compatibility
        but will return an error for all managed models.
        
        Args:
            model_id: Model ID to delete
        
        Returns:
            Delete response indicating success/failure
        """
        definition = self._registry.get_model(model_id)
        
        if not definition:
            return DeleteModelResponse(
                id=model_id,
                deleted=False,
                error="Model not found",
            ).to_dict()
        
        # SAP-managed models cannot be deleted
        return DeleteModelResponse(
            id=model_id,
            deleted=False,
            error="Cannot delete SAP AI Core managed models",
        ).to_dict()
    
    def list_chat_models(self, extended: bool = False) -> Dict[str, Any]:
        """
        List models with chat capability.
        
        Convenience method for filtering chat models.
        """
        return self.list_models(capability="chat", extended=extended)
    
    def list_embedding_models(self, extended: bool = False) -> Dict[str, Any]:
        """
        List models with embedding capability.
        
        Convenience method for filtering embedding models.
        """
        return self.list_models(capability="embedding", extended=extended)
    
    def list_models_by_tier(
        self,
        tier: str,
        extended: bool = False,
    ) -> Dict[str, Any]:
        """
        List models by tier.
        
        Args:
            tier: Model tier (premium, standard, economy)
            extended: Include extended information
        """
        return self.list_models(tier=tier, extended=extended)
    
    def get_model_capabilities(self, model_id: str) -> Optional[List[str]]:
        """
        Get capabilities for a specific model.
        
        Args:
            model_id: Model ID or alias
        
        Returns:
            List of capability strings or None if not found
        """
        definition = self._registry.get_model(model_id)
        if not definition:
            return None
        return [c.value for c in definition.capabilities]
    
    def get_context_window(self, model_id: str) -> Optional[int]:
        """
        Get context window size for a model.
        
        Args:
            model_id: Model ID or alias
        
        Returns:
            Context window size or None if not found
        """
        definition = self._registry.get_model(model_id)
        if not definition:
            return None
        return definition.context_window
    
    def supports_capability(
        self,
        model_id: str,
        capability: str,
    ) -> bool:
        """
        Check if a model supports a capability.
        
        Args:
            model_id: Model ID or alias
            capability: Capability to check
        
        Returns:
            True if model supports capability
        """
        definition = self._registry.get_model(model_id)
        if not definition:
            return False
        
        try:
            cap = ModelCapability(capability)
            return definition.supports(cap)
        except ValueError:
            return False


# ========================================
# Error Response
# ========================================

@dataclass
class ModelErrorResponse:
    """Error response for model endpoints."""
    message: str
    type: str = "invalid_request_error"
    param: Optional[str] = None
    code: Optional[str] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {
            "error": {
                "message": self.message,
                "type": self.type,
            }
        }
        if self.param:
            result["error"]["param"] = self.param
        if self.code:
            result["error"]["code"] = self.code
        return result


# ========================================
# Utility Functions
# ========================================

def get_models_handler() -> ModelsHandler:
    """Get a ModelsHandler instance with global registry."""
    return ModelsHandler()


def list_all_models() -> Dict[str, Any]:
    """List all available models."""
    return get_models_handler().list_models()


def get_model_info(model_id: str) -> Optional[Dict[str, Any]]:
    """Get information about a specific model."""
    return get_models_handler().get_model(model_id)


def model_supports_streaming(model_id: str) -> bool:
    """Check if a model supports streaming."""
    return get_models_handler().supports_capability(model_id, "streaming")


def model_supports_tools(model_id: str) -> bool:
    """Check if a model supports tool/function calling."""
    handler = get_models_handler()
    return (
        handler.supports_capability(model_id, "function_calling") or
        handler.supports_capability(model_id, "tool_use")
    )


def get_recommended_model(
    capability: str = "chat",
    tier: str = "standard",
) -> Optional[str]:
    """
    Get recommended model for a capability and tier.
    
    Args:
        capability: Required capability
        tier: Preferred tier
    
    Returns:
        Model ID or None if no matching model
    """
    handler = get_models_handler()
    result = handler.list_models(capability=capability, tier=tier)
    
    models = result.get("data", [])
    if models:
        return models[0]["id"]
    
    # Fall back to any model with the capability
    result = handler.list_models(capability=capability)
    models = result.get("data", [])
    return models[0]["id"] if models else None


# ========================================
# Exports
# ========================================

__all__ = [
    # Core types
    "ModelObject",
    "ModelObjectExtended",
    "ModelsListResponse",
    "ModelsListResponseExtended",
    "DeleteModelResponse",
    "ModelErrorResponse",
    "ModelPermission",
    # Handler
    "ModelsHandler",
    # Utilities
    "get_models_handler",
    "list_all_models",
    "get_model_info",
    "model_supports_streaming",
    "model_supports_tools",
    "get_recommended_model",
]