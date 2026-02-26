"""
OpenAI Models Endpoint

GET /v1/models - List available models
GET /v1/models/{model_id} - Get specific model
"""

import time
from typing import Dict, Any, List, Optional
from dataclasses import dataclass, asdict


@dataclass
class ModelInfo:
    """OpenAI-compatible model information"""
    id: str
    object: str = "model"
    created: int = 1677610602  # Unix timestamp
    owned_by: str = "odata-vocabularies"
    permission: List[Dict] = None
    root: str = None
    parent: Optional[str] = None
    
    def __post_init__(self):
        if self.permission is None:
            self.permission = [{
                "id": f"modelperm-{self.id}",
                "object": "model_permission",
                "created": self.created,
                "allow_create_engine": False,
                "allow_sampling": True,
                "allow_logprobs": False,
                "allow_search_indices": True,
                "allow_view": True,
                "allow_fine_tuning": False,
                "organization": "*",
                "group": None,
                "is_blocking": False
            }]
        if self.root is None:
            self.root = self.id
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "object": self.object,
            "created": self.created,
            "owned_by": self.owned_by,
            "permission": self.permission,
            "root": self.root,
            "parent": self.parent
        }


# Available models for OData Vocabularies
AVAILABLE_MODELS = {
    # Chat/completion models
    "odata-vocab-search": ModelInfo(
        id="odata-vocab-search",
        owned_by="odata-vocabularies",
        created=int(time.time())
    ),
    "odata-vocab-annotator": ModelInfo(
        id="odata-vocab-annotator",
        owned_by="odata-vocabularies",
        created=int(time.time())
    ),
    "odata-vocab-generator": ModelInfo(
        id="odata-vocab-generator",
        owned_by="odata-vocabularies",
        created=int(time.time())
    ),
    "odata-vocab-gdpr": ModelInfo(
        id="odata-vocab-gdpr",
        owned_by="odata-vocabularies",
        created=int(time.time())
    ),
    
    # Embedding models
    "odata-vocab-embedding": ModelInfo(
        id="odata-vocab-embedding",
        owned_by="odata-vocabularies",
        created=int(time.time())
    ),
    "text-embedding-odata": ModelInfo(
        id="text-embedding-odata",
        owned_by="odata-vocabularies",
        created=int(time.time())
    ),
}

# Aliases for common OpenAI model names
MODEL_ALIASES = {
    "gpt-4": "odata-vocab-annotator",
    "gpt-4-turbo": "odata-vocab-annotator",
    "gpt-3.5-turbo": "odata-vocab-search",
    "text-embedding-ada-002": "text-embedding-odata",
    "text-embedding-3-small": "text-embedding-odata",
    "text-embedding-3-large": "text-embedding-odata",
}


def list_models() -> Dict[str, Any]:
    """
    List all available models.
    
    OpenAI-compatible response format:
    {
        "object": "list",
        "data": [...]
    }
    """
    return {
        "object": "list",
        "data": [model.to_dict() for model in AVAILABLE_MODELS.values()]
    }


def get_model(model_id: str) -> Optional[Dict[str, Any]]:
    """
    Get a specific model by ID.
    
    Supports aliases for common OpenAI model names.
    """
    # Check aliases first
    resolved_id = MODEL_ALIASES.get(model_id, model_id)
    
    model = AVAILABLE_MODELS.get(resolved_id)
    if model:
        return model.to_dict()
    
    return None


def resolve_model(model_id: str) -> str:
    """Resolve model alias to actual model ID"""
    return MODEL_ALIASES.get(model_id, model_id)


def is_embedding_model(model_id: str) -> bool:
    """Check if model is an embedding model"""
    resolved = resolve_model(model_id)
    return resolved in ["odata-vocab-embedding", "text-embedding-odata"]


def is_chat_model(model_id: str) -> bool:
    """Check if model is a chat/completion model"""
    resolved = resolve_model(model_id)
    return resolved in [
        "odata-vocab-search",
        "odata-vocab-annotator",
        "odata-vocab-generator",
        "odata-vocab-gdpr"
    ]


def get_model_capabilities(model_id: str) -> Dict[str, Any]:
    """Get capabilities for a model"""
    resolved = resolve_model(model_id)
    
    capabilities = {
        "odata-vocab-search": {
            "chat": True,
            "completion": True,
            "embedding": False,
            "function_calling": True,
            "tools": ["search_terms", "semantic_search", "get_vocabulary", "list_vocabularies"]
        },
        "odata-vocab-annotator": {
            "chat": True,
            "completion": True,
            "embedding": False,
            "function_calling": True,
            "tools": ["suggest_annotations", "get_term_definition", "validate_annotations"]
        },
        "odata-vocab-generator": {
            "chat": True,
            "completion": True,
            "embedding": False,
            "function_calling": True,
            "tools": ["generate_cds", "generate_graphql", "generate_sql"]
        },
        "odata-vocab-gdpr": {
            "chat": True,
            "completion": True,
            "embedding": False,
            "function_calling": True,
            "tools": ["classify_personal_data", "audit_personal_data"]
        },
        "odata-vocab-embedding": {
            "chat": False,
            "completion": False,
            "embedding": True,
            "dimensions": 1536
        },
        "text-embedding-odata": {
            "chat": False,
            "completion": False,
            "embedding": True,
            "dimensions": 1536
        }
    }
    
    return capabilities.get(resolved, {"error": "unknown_model"})