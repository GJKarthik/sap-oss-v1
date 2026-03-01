"""
OpenAI-compatible Vector Stores API

Day 26 Deliverable: Vector Stores endpoint handler

Implements:
- POST /v1/vector_stores - Create vector store
- GET /v1/vector_stores - List vector stores
- GET /v1/vector_stores/{vector_store_id} - Retrieve vector store
- POST /v1/vector_stores/{vector_store_id} - Modify vector store
- DELETE /v1/vector_stores/{vector_store_id} - Delete vector store
"""

import time
import hashlib
from enum import Enum
from typing import Dict, Any, Optional, List, Union
from dataclasses import dataclass, field


# ========================================
# Constants
# ========================================

MAX_VECTOR_STORES = 100
DEFAULT_CHUNKING_STRATEGY = "auto"
DEFAULT_CHUNK_SIZE = 800
MAX_CHUNK_SIZE = 4096
MIN_CHUNK_SIZE = 100
DEFAULT_CHUNK_OVERLAP = 400
MAX_CHUNK_OVERLAP_PERCENTAGE = 50
MAX_METADATA_PAIRS = 16
MAX_METADATA_KEY_LENGTH = 64
MAX_METADATA_VALUE_LENGTH = 512


# ========================================
# Enums
# ========================================

class VectorStoreStatus(str, Enum):
    """Vector store statuses."""
    EXPIRED = "expired"
    IN_PROGRESS = "in_progress"
    COMPLETED = "completed"


class ChunkingStrategyType(str, Enum):
    """Chunking strategy types."""
    AUTO = "auto"
    STATIC = "static"


class ExpirationPolicy(str, Enum):
    """Expiration anchor types."""
    LAST_ACTIVE_AT = "last_active_at"


# ========================================
# Chunking Models
# ========================================

@dataclass
class StaticChunkingStrategy:
    """Static chunking configuration."""
    max_chunk_size_tokens: int = DEFAULT_CHUNK_SIZE
    chunk_overlap_tokens: int = DEFAULT_CHUNK_OVERLAP
    
    def validate(self) -> List[str]:
        """Validate chunking parameters."""
        errors = []
        if self.max_chunk_size_tokens < MIN_CHUNK_SIZE:
            errors.append(f"max_chunk_size_tokens must be >= {MIN_CHUNK_SIZE}")
        if self.max_chunk_size_tokens > MAX_CHUNK_SIZE:
            errors.append(f"max_chunk_size_tokens must be <= {MAX_CHUNK_SIZE}")
        if self.chunk_overlap_tokens < 0:
            errors.append("chunk_overlap_tokens must be >= 0")
        max_overlap = self.max_chunk_size_tokens * MAX_CHUNK_OVERLAP_PERCENTAGE // 100
        if self.chunk_overlap_tokens > max_overlap:
            errors.append(f"chunk_overlap_tokens must be <= {max_overlap} (50% of max_chunk_size)")
        return errors
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "max_chunk_size_tokens": self.max_chunk_size_tokens,
            "chunk_overlap_tokens": self.chunk_overlap_tokens,
        }


@dataclass
class ChunkingStrategy:
    """Chunking strategy wrapper."""
    type: str = ChunkingStrategyType.AUTO.value
    static: Optional[StaticChunkingStrategy] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {"type": self.type}
        if self.type == ChunkingStrategyType.STATIC.value and self.static:
            result["static"] = self.static.to_dict()
        return result


# ========================================
# Expiration Policy Models
# ========================================

@dataclass
class ExpiresAfter:
    """Expiration policy configuration."""
    anchor: str = ExpirationPolicy.LAST_ACTIVE_AT.value
    days: int = 7
    
    def validate(self) -> List[str]:
        """Validate expiration policy."""
        errors = []
        if self.anchor != ExpirationPolicy.LAST_ACTIVE_AT.value:
            errors.append(f"anchor must be '{ExpirationPolicy.LAST_ACTIVE_AT.value}'")
        if self.days < 1 or self.days > 365:
            errors.append("days must be between 1 and 365")
        return errors
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "anchor": self.anchor,
            "days": self.days,
        }


# ========================================
# File Counts Model
# ========================================

@dataclass
class FileCounts:
    """File counts for vector store."""
    in_progress: int = 0
    completed: int = 0
    failed: int = 0
    cancelled: int = 0
    total: int = 0
    
    def to_dict(self) -> Dict[str, int]:
        """Convert to dictionary."""
        return {
            "in_progress": self.in_progress,
            "completed": self.completed,
            "failed": self.failed,
            "cancelled": self.cancelled,
            "total": self.total,
        }


# ========================================
# Request Models
# ========================================

@dataclass
class CreateVectorStoreRequest:
    """Request to create a vector store."""
    name: Optional[str] = None
    file_ids: Optional[List[str]] = None
    expires_after: Optional[Dict[str, Any]] = None
    chunking_strategy: Optional[Dict[str, Any]] = None
    metadata: Optional[Dict[str, str]] = None
    
    def validate(self) -> List[str]:
        """Validate the request."""
        errors = []
        
        if self.file_ids and len(self.file_ids) > MAX_VECTOR_STORES:
            errors.append(f"Maximum {MAX_VECTOR_STORES} files per request")
        
        if self.metadata:
            if len(self.metadata) > MAX_METADATA_PAIRS:
                errors.append(f"Maximum {MAX_METADATA_PAIRS} metadata pairs")
            for key, value in self.metadata.items():
                if len(key) > MAX_METADATA_KEY_LENGTH:
                    errors.append(f"Metadata key exceeds {MAX_METADATA_KEY_LENGTH} chars")
                if len(value) > MAX_METADATA_VALUE_LENGTH:
                    errors.append(f"Metadata value exceeds {MAX_METADATA_VALUE_LENGTH} chars")
        
        if self.expires_after:
            exp = ExpiresAfter(
                anchor=self.expires_after.get("anchor", ExpirationPolicy.LAST_ACTIVE_AT.value),
                days=self.expires_after.get("days", 7)
            )
            errors.extend(exp.validate())
        
        if self.chunking_strategy:
            strategy_type = self.chunking_strategy.get("type", ChunkingStrategyType.AUTO.value)
            if strategy_type == ChunkingStrategyType.STATIC.value:
                static_config = self.chunking_strategy.get("static", {})
                static = StaticChunkingStrategy(
                    max_chunk_size_tokens=static_config.get("max_chunk_size_tokens", DEFAULT_CHUNK_SIZE),
                    chunk_overlap_tokens=static_config.get("chunk_overlap_tokens", DEFAULT_CHUNK_OVERLAP)
                )
                errors.extend(static.validate())
        
        return errors


@dataclass
class ModifyVectorStoreRequest:
    """Request to modify a vector store."""
    name: Optional[str] = None
    expires_after: Optional[Dict[str, Any]] = None
    metadata: Optional[Dict[str, str]] = None
    
    def validate(self) -> List[str]:
        """Validate the request."""
        errors = []
        
        if self.metadata:
            if len(self.metadata) > MAX_METADATA_PAIRS:
                errors.append(f"Maximum {MAX_METADATA_PAIRS} metadata pairs")
        
        if self.expires_after:
            exp = ExpiresAfter(
                anchor=self.expires_after.get("anchor", ExpirationPolicy.LAST_ACTIVE_AT.value),
                days=self.expires_after.get("days", 7)
            )
            errors.extend(exp.validate())
        
        return errors


# ========================================
# Response Models
# ========================================

@dataclass
class VectorStoreObject:
    """Vector store object."""
    id: str
    object: str = "vector_store"
    created_at: int = 0
    name: Optional[str] = None
    usage_bytes: int = 0
    file_counts: Optional[FileCounts] = None
    status: str = VectorStoreStatus.COMPLETED.value
    expires_after: Optional[ExpiresAfter] = None
    expires_at: Optional[int] = None
    last_active_at: Optional[int] = None
    metadata: Optional[Dict[str, str]] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {
            "id": self.id,
            "object": self.object,
            "created_at": self.created_at,
            "name": self.name,
            "usage_bytes": self.usage_bytes,
            "file_counts": self.file_counts.to_dict() if self.file_counts else FileCounts().to_dict(),
            "status": self.status,
            "last_active_at": self.last_active_at,
            "metadata": self.metadata or {},
        }
        
        if self.expires_after:
            result["expires_after"] = self.expires_after.to_dict()
        if self.expires_at:
            result["expires_at"] = self.expires_at
        
        return result


@dataclass
class VectorStoreListResponse:
    """Response for list vector stores."""
    object: str = "list"
    data: List[VectorStoreObject] = field(default_factory=list)
    first_id: Optional[str] = None
    last_id: Optional[str] = None
    has_more: bool = False
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "object": self.object,
            "data": [vs.to_dict() for vs in self.data],
            "first_id": self.first_id,
            "last_id": self.last_id,
            "has_more": self.has_more,
        }


@dataclass
class VectorStoreDeleteResponse:
    """Response for delete vector store."""
    id: str = ""
    object: str = "vector_store.deleted"
    deleted: bool = True
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "id": self.id,
            "object": self.object,
            "deleted": self.deleted,
        }


@dataclass
class VectorStoreErrorResponse:
    """Error response for vector store operations."""
    error: Dict[str, Any] = field(default_factory=dict)
    
    def __init__(self, message: str, type: str = "invalid_request_error", code: Optional[str] = None):
        self.error = {"message": message, "type": type}
        if code:
            self.error["code"] = code
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {"error": self.error}


# ========================================
# Vector Stores Handler
# ========================================

class VectorStoresHandler:
    """Handler for vector store operations."""
    
    def __init__(self, mock_mode: bool = True):
        """Initialize handler."""
        self.mock_mode = mock_mode
        self._stores: Dict[str, VectorStoreObject] = {}
    
    def _generate_id(self) -> str:
        """Generate vector store ID."""
        return f"vs_{hashlib.md5(f'{time.time()}'.encode()).hexdigest()[:24]}"
    
    def create(self, request: CreateVectorStoreRequest) -> Dict[str, Any]:
        """Create a vector store."""
        errors = request.validate()
        if errors:
            return VectorStoreErrorResponse("; ".join(errors)).to_dict()
        
        store_id = self._generate_id()
        now = int(time.time())
        
        # Calculate expiration
        expires_after = None
        expires_at = None
        if request.expires_after:
            expires_after = ExpiresAfter(
                anchor=request.expires_after.get("anchor", ExpirationPolicy.LAST_ACTIVE_AT.value),
                days=request.expires_after.get("days", 7)
            )
            expires_at = now + (expires_after.days * 86400)
        
        # Determine status based on files
        status = VectorStoreStatus.COMPLETED.value
        file_counts = FileCounts(total=len(request.file_ids) if request.file_ids else 0)
        if request.file_ids:
            status = VectorStoreStatus.IN_PROGRESS.value
            file_counts.in_progress = len(request.file_ids)
        
        store = VectorStoreObject(
            id=store_id,
            created_at=now,
            name=request.name,
            file_counts=file_counts,
            status=status,
            expires_after=expires_after,
            expires_at=expires_at,
            last_active_at=now,
            metadata=request.metadata,
        )
        
        self._stores[store_id] = store
        return store.to_dict()
    
    def list(
        self,
        limit: int = 20,
        order: str = "desc",
        after: Optional[str] = None,
        before: Optional[str] = None,
    ) -> Dict[str, Any]:
        """List vector stores."""
        stores = list(self._stores.values())
        
        # Sort
        stores = sorted(stores, key=lambda s: s.created_at, reverse=(order == "desc"))
        
        # Apply cursor pagination
        if after:
            found_idx = -1
            for i, store in enumerate(stores):
                if store.id == after:
                    found_idx = i
                    break
            if found_idx >= 0:
                stores = stores[found_idx + 1:]
        
        if before:
            found_idx = -1
            for i, store in enumerate(stores):
                if store.id == before:
                    found_idx = i
                    break
            if found_idx >= 0:
                stores = stores[:found_idx]
        
        has_more = len(stores) > limit
        stores = stores[:limit]
        
        return VectorStoreListResponse(
            data=stores,
            first_id=stores[0].id if stores else None,
            last_id=stores[-1].id if stores else None,
            has_more=has_more,
        ).to_dict()
    
    def retrieve(self, vector_store_id: str) -> Dict[str, Any]:
        """Retrieve a vector store."""
        if vector_store_id not in self._stores:
            return VectorStoreErrorResponse(
                f"No vector store found with id '{vector_store_id}'",
                code="vector_store_not_found"
            ).to_dict()
        
        store = self._stores[vector_store_id]
        store.last_active_at = int(time.time())
        return store.to_dict()
    
    def modify(
        self,
        vector_store_id: str,
        request: ModifyVectorStoreRequest
    ) -> Dict[str, Any]:
        """Modify a vector store."""
        if vector_store_id not in self._stores:
            return VectorStoreErrorResponse(
                f"No vector store found with id '{vector_store_id}'",
                code="vector_store_not_found"
            ).to_dict()
        
        errors = request.validate()
        if errors:
            return VectorStoreErrorResponse("; ".join(errors)).to_dict()
        
        store = self._stores[vector_store_id]
        now = int(time.time())
        
        if request.name is not None:
            store.name = request.name
        
        if request.expires_after is not None:
            store.expires_after = ExpiresAfter(
                anchor=request.expires_after.get("anchor", ExpirationPolicy.LAST_ACTIVE_AT.value),
                days=request.expires_after.get("days", 7)
            )
            store.expires_at = now + (store.expires_after.days * 86400)
        
        if request.metadata is not None:
            store.metadata = request.metadata
        
        store.last_active_at = now
        return store.to_dict()
    
    def delete(self, vector_store_id: str) -> Dict[str, Any]:
        """Delete a vector store."""
        if vector_store_id not in self._stores:
            return VectorStoreErrorResponse(
                f"No vector store found with id '{vector_store_id}'",
                code="vector_store_not_found"
            ).to_dict()
        
        del self._stores[vector_store_id]
        return VectorStoreDeleteResponse(id=vector_store_id).to_dict()
    
    def complete_files(self, vector_store_id: str) -> Dict[str, Any]:
        """Mark all files as completed (mock operation)."""
        if vector_store_id not in self._stores:
            return VectorStoreErrorResponse(
                f"No vector store found with id '{vector_store_id}'",
                code="vector_store_not_found"
            ).to_dict()
        
        store = self._stores[vector_store_id]
        if store.file_counts:
            store.file_counts.completed = store.file_counts.in_progress
            store.file_counts.in_progress = 0
        store.status = VectorStoreStatus.COMPLETED.value
        store.last_active_at = int(time.time())
        
        return store.to_dict()


# ========================================
# Factory and Utilities
# ========================================

def get_vector_stores_handler(mock_mode: bool = True) -> VectorStoresHandler:
    """Factory function for vector stores handler."""
    return VectorStoresHandler(mock_mode=mock_mode)


def create_vector_store(
    name: Optional[str] = None,
    file_ids: Optional[List[str]] = None,
    metadata: Optional[Dict[str, str]] = None,
) -> Dict[str, Any]:
    """Helper to create a vector store."""
    handler = get_vector_stores_handler()
    return handler.create(CreateVectorStoreRequest(
        name=name,
        file_ids=file_ids,
        metadata=metadata,
    ))


def create_chunking_strategy(
    strategy_type: str = "auto",
    max_chunk_size: int = DEFAULT_CHUNK_SIZE,
    chunk_overlap: int = DEFAULT_CHUNK_OVERLAP,
) -> Dict[str, Any]:
    """Create a chunking strategy configuration."""
    if strategy_type == ChunkingStrategyType.STATIC.value:
        return ChunkingStrategy(
            type=strategy_type,
            static=StaticChunkingStrategy(
                max_chunk_size_tokens=max_chunk_size,
                chunk_overlap_tokens=chunk_overlap
            )
        ).to_dict()
    return ChunkingStrategy(type=strategy_type).to_dict()


def create_expiration_policy(days: int = 7) -> Dict[str, Any]:
    """Create an expiration policy."""
    return ExpiresAfter(days=days).to_dict()


def is_store_expired(store: Dict[str, Any]) -> bool:
    """Check if a vector store is expired."""
    return store.get("status") == VectorStoreStatus.EXPIRED.value


def is_store_ready(store: Dict[str, Any]) -> bool:
    """Check if a vector store is ready for use."""
    return store.get("status") == VectorStoreStatus.COMPLETED.value


def get_file_progress(store: Dict[str, Any]) -> float:
    """Get file processing progress as percentage."""
    counts = store.get("file_counts", {})
    total = counts.get("total", 0)
    if total == 0:
        return 100.0
    completed = counts.get("completed", 0)
    return (completed / total) * 100


def validate_chunk_size(size: int) -> bool:
    """Validate chunk size."""
    return MIN_CHUNK_SIZE <= size <= MAX_CHUNK_SIZE


def validate_chunk_overlap(overlap: int, chunk_size: int) -> bool:
    """Validate chunk overlap."""
    max_overlap = chunk_size * MAX_CHUNK_OVERLAP_PERCENTAGE // 100
    return 0 <= overlap <= max_overlap


def estimate_storage_bytes(
    file_count: int,
    avg_file_size_kb: int = 50,
    embedding_dimensions: int = 1536,
) -> int:
    """Estimate storage bytes for vector store."""
    # Rough estimate: original text + embeddings
    text_bytes = file_count * avg_file_size_kb * 1024
    # Assume ~100 chunks per file, each embedding is 4 bytes * dimensions
    embedding_bytes = file_count * 100 * embedding_dimensions * 4
    return text_bytes + embedding_bytes


# ========================================
# Exports
# ========================================

__all__ = [
    # Constants
    "MAX_VECTOR_STORES",
    "DEFAULT_CHUNKING_STRATEGY",
    "DEFAULT_CHUNK_SIZE",
    "MAX_CHUNK_SIZE",
    "MIN_CHUNK_SIZE",
    "DEFAULT_CHUNK_OVERLAP",
    "MAX_CHUNK_OVERLAP_PERCENTAGE",
    "MAX_METADATA_PAIRS",
    # Enums
    "VectorStoreStatus",
    "ChunkingStrategyType",
    "ExpirationPolicy",
    # Models
    "StaticChunkingStrategy",
    "ChunkingStrategy",
    "ExpiresAfter",
    "FileCounts",
    "CreateVectorStoreRequest",
    "ModifyVectorStoreRequest",
    "VectorStoreObject",
    "VectorStoreListResponse",
    "VectorStoreDeleteResponse",
    "VectorStoreErrorResponse",
    # Handler
    "VectorStoresHandler",
    # Utilities
    "get_vector_stores_handler",
    "create_vector_store",
    "create_chunking_strategy",
    "create_expiration_policy",
    "is_store_expired",
    "is_store_ready",
    "get_file_progress",
    "validate_chunk_size",
    "validate_chunk_overlap",
    "estimate_storage_bytes",
]