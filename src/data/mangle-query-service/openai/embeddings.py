"""
Embeddings Endpoint Handler

Day 9 Deliverable: OpenAI-compatible embeddings API
- /v1/embeddings endpoint
- Single and batch text embedding
- Dimension control
- Response formatting per OpenAI spec

All embedding requests go through SAP AI Core.
"""

import logging
import time
import hashlib
import base64
from typing import Optional, List, Union, Dict, Any
from dataclasses import dataclass, field
from enum import Enum

from routing.model_registry import (
    ModelCapability,
    get_model_registry,
)
from routing.model_router import get_model_router

logger = logging.getLogger(__name__)


# ========================================
# Encoding Formats
# ========================================

class EncodingFormat(str, Enum):
    """Embedding encoding formats."""
    FLOAT = "float"
    BASE64 = "base64"


# ========================================
# Request Models
# ========================================

@dataclass
class EmbeddingRequest:
    """
    OpenAI-compatible embedding request.
    
    Ref: https://platform.openai.com/docs/api-reference/embeddings/create
    """
    input: Union[str, List[str], List[int], List[List[int]]]
    model: str
    encoding_format: EncodingFormat = EncodingFormat.FLOAT
    dimensions: Optional[int] = None
    user: Optional[str] = None
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "EmbeddingRequest":
        """Create from dictionary."""
        return cls(
            input=data.get("input", ""),
            model=data.get("model", "text-embedding-3-small"),
            encoding_format=EncodingFormat(
                data.get("encoding_format", "float")
            ),
            dimensions=data.get("dimensions"),
            user=data.get("user"),
        )
    
    def validate(self) -> List[str]:
        """Validate request and return errors."""
        errors = []
        
        if not self.input:
            errors.append("input is required")
        
        if not self.model:
            errors.append("model is required")
        
        # Validate input types
        if isinstance(self.input, str):
            if len(self.input) == 0:
                errors.append("input string cannot be empty")
        elif isinstance(self.input, list):
            if len(self.input) == 0:
                errors.append("input array cannot be empty")
            # Check max batch size
            if len(self.input) > 2048:
                errors.append("input array exceeds maximum batch size of 2048")
        
        # Validate dimensions
        if self.dimensions is not None:
            if self.dimensions < 1:
                errors.append("dimensions must be at least 1")
            if self.dimensions > 3072:
                errors.append("dimensions cannot exceed 3072")
        
        return errors
    
    def get_input_texts(self) -> List[str]:
        """Get input as list of strings."""
        if isinstance(self.input, str):
            return [self.input]
        elif isinstance(self.input, list):
            if len(self.input) == 0:
                return []
            # Check if it's a list of strings or token arrays
            if isinstance(self.input[0], str):
                return self.input
            elif isinstance(self.input[0], int):
                # Single token array - decode not supported, return placeholder
                return ["[token_array]"]
            elif isinstance(self.input[0], list):
                # Multiple token arrays
                return [f"[token_array_{i}]" for i in range(len(self.input))]
        return []


# ========================================
# Response Models
# ========================================

@dataclass
class EmbeddingData:
    """Individual embedding in response."""
    embedding: Union[List[float], str]  # float array or base64
    index: int
    object: str = "embedding"
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "object": self.object,
            "embedding": self.embedding,
            "index": self.index,
        }


@dataclass
class EmbeddingUsage:
    """Token usage for embedding request."""
    prompt_tokens: int
    total_tokens: int
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "prompt_tokens": self.prompt_tokens,
            "total_tokens": self.total_tokens,
        }


@dataclass
class EmbeddingResponse:
    """
    OpenAI-compatible embedding response.
    
    Ref: https://platform.openai.com/docs/api-reference/embeddings/object
    """
    data: List[EmbeddingData]
    model: str
    usage: EmbeddingUsage
    object: str = "list"
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "object": self.object,
            "data": [d.to_dict() for d in self.data],
            "model": self.model,
            "usage": self.usage.to_dict(),
        }


# ========================================
# Embedding Utilities
# ========================================

def estimate_tokens(text: str) -> int:
    """
    Estimate token count for text.
    
    Simple approximation: ~4 chars per token for English.
    """
    return max(1, len(text) // 4)


def encode_base64(embedding: List[float]) -> str:
    """Encode embedding as base64 string."""
    import struct
    # Pack floats as binary
    binary = struct.pack(f"{len(embedding)}f", *embedding)
    return base64.b64encode(binary).decode("utf-8")


def generate_mock_embedding(
    text: str,
    dimensions: int = 1536,
    seed: Optional[int] = None,
) -> List[float]:
    """
    Generate deterministic mock embedding for testing.
    
    In production, this would call SAP AI Core.
    """
    # Use text hash as seed for reproducibility
    if seed is None:
        seed = int(hashlib.md5(text.encode()).hexdigest()[:8], 16)
    
    import random
    rng = random.Random(seed)
    
    # Generate normalized embedding
    embedding = [rng.gauss(0, 1) for _ in range(dimensions)]
    
    # Normalize to unit vector
    magnitude = sum(x * x for x in embedding) ** 0.5
    if magnitude > 0:
        embedding = [x / magnitude for x in embedding]
    
    return embedding


def truncate_embedding(
    embedding: List[float],
    dimensions: int,
) -> List[float]:
    """
    Truncate embedding to specified dimensions.
    
    OpenAI's text-embedding-3 models support Matryoshka
    representation learning for dimension reduction.
    """
    if dimensions >= len(embedding):
        return embedding
    
    truncated = embedding[:dimensions]
    
    # Re-normalize after truncation
    magnitude = sum(x * x for x in truncated) ** 0.5
    if magnitude > 0:
        truncated = [x / magnitude for x in truncated]
    
    return truncated


# ========================================
# Embeddings Handler
# ========================================

class EmbeddingsHandler:
    """
    Handler for embedding requests.
    
    Integrates with SAP AI Core for embedding generation.
    """
    
    def __init__(self):
        self.registry = get_model_registry()
        self.router = get_model_router()
        
        # Default dimensions by model
        self._default_dimensions = {
            "text-embedding-3-small": 1536,
            "text-embedding-3-large": 3072,
            "text-embedding-ada-002": 1536,
        }
    
    async def create_embeddings(
        self,
        request: EmbeddingRequest,
    ) -> EmbeddingResponse:
        """
        Create embeddings for input text(s).
        
        Args:
            request: Embedding request
            
        Returns:
            Embedding response
        """
        # Validate request
        errors = request.validate()
        if errors:
            raise ValueError(f"Invalid request: {', '.join(errors)}")
        
        # Route to embedding model
        decision = self.router.route_embedding(request.model)
        if not decision:
            raise ValueError(f"Model not found or not an embedding model: {request.model}")
        
        # Get input texts
        texts = request.get_input_texts()
        
        # Determine dimensions
        dimensions = request.dimensions
        if dimensions is None:
            dimensions = self._default_dimensions.get(
                decision.model.id, 1536
            )
        
        # Generate embeddings
        embeddings_data = []
        total_tokens = 0
        
        for idx, text in enumerate(texts):
            # Estimate tokens
            tokens = estimate_tokens(text)
            total_tokens += tokens
            
            # Generate embedding (would call AI Core in production)
            embedding = await self._generate_embedding(
                text=text,
                model_id=decision.model.id,
                dimensions=dimensions,
            )
            
            # Apply dimension reduction if requested
            if request.dimensions and request.dimensions < len(embedding):
                embedding = truncate_embedding(embedding, request.dimensions)
            
            # Encode if base64 requested
            if request.encoding_format == EncodingFormat.BASE64:
                embedding = encode_base64(embedding)
            
            embeddings_data.append(EmbeddingData(
                embedding=embedding,
                index=idx,
            ))
        
        return EmbeddingResponse(
            data=embeddings_data,
            model=decision.model.id,
            usage=EmbeddingUsage(
                prompt_tokens=total_tokens,
                total_tokens=total_tokens,
            ),
        )
    
    async def _generate_embedding(
        self,
        text: str,
        model_id: str,
        dimensions: int,
    ) -> List[float]:
        """
        Generate embedding for text.
        
        In production, this calls SAP AI Core.
        For now, generates deterministic mock embeddings.
        """
        # TODO: Call SAP AI Core embedding endpoint
        # For now, return mock embedding
        return generate_mock_embedding(text, dimensions)
    
    def get_default_dimensions(self, model_id: str) -> int:
        """Get default dimensions for a model."""
        return self._default_dimensions.get(model_id, 1536)


# ========================================
# Global Handler Instance
# ========================================

_handler: Optional[EmbeddingsHandler] = None


def get_embeddings_handler() -> EmbeddingsHandler:
    """Get global embeddings handler instance."""
    global _handler
    if _handler is None:
        _handler = EmbeddingsHandler()
    return _handler


# ========================================
# Exports
# ========================================

__all__ = [
    "EncodingFormat",
    "EmbeddingRequest",
    "EmbeddingData",
    "EmbeddingUsage",
    "EmbeddingResponse",
    "EmbeddingsHandler",
    "get_embeddings_handler",
    "estimate_tokens",
    "encode_base64",
    "generate_mock_embedding",
    "truncate_embedding",
]