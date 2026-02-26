"""
SAP OSS Service Mesh - OpenAI-Compatible API
100% Drop-in replacement for OpenAI Python SDK

Endpoints:
- POST /v1/chat/completions
- POST /v1/completions
- POST /v1/embeddings
- GET /v1/models
- GET /v1/models/{model_id}

All responses follow OpenAI API specification exactly.
"""

from .router import MeshRouter
from .chat_completions import ChatCompletionsHandler
from .completions import CompletionsHandler
from .embeddings import EmbeddingsHandler
from .models import ModelsHandler

__all__ = [
    "MeshRouter",
    "ChatCompletionsHandler",
    "CompletionsHandler",
    "EmbeddingsHandler",
    "ModelsHandler",
]

# Version info
__version__ = "1.0.0"
__openai_api_version__ = "v1"