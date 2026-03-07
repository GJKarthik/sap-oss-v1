"""
OpenAI-Compatible API for OData Vocabularies

Provides OpenAI API-compatible endpoints for vocabulary operations,
enabling integration with AI platforms expecting OpenAI-style APIs.
"""

from .router import router, create_app
from .models import list_models, get_model
from .chat_completions import create_chat_completion
from .embeddings import create_embedding

__all__ = [
    "router",
    "create_app",
    "list_models",
    "get_model", 
    "create_chat_completion",
    "create_embedding"
]