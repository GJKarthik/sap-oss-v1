"""
OpenAI-compatible Vector Store Files API

Day 27 Deliverable: Vector Store Files endpoint handler

Implements:
- POST /v1/vector_stores/{id}/files - Create file in vector store
- GET /v1/vector_stores/{id}/files - List files in vector store
- GET /v1/vector_stores/{id}/files/{file_id} - Retrieve file
- DELETE /v1/vector_stores/{id}/files/{file_id} - Delete file
"""

import time
import hashlib
from enum import Enum
from typing import Dict, Any, Optional, List
from dataclasses import dataclass, field


# ========================================
# Constants
# ========================================

MAX_FILES_PER_STORE = 10000
MAX_FILES_PER_REQUEST = 500
DEFAULT_PAGE_SIZE = 20
MAX_PAGE_SIZE = 100


# ========================================
# Enums
# ========================================

class VectorStoreFileStatus(str, Enum):
    """Vector store file processing statuses."""
    IN_PROGRESS = "in_progress"
    COMPLETED = "completed"
    CANCELLED = "cancelled"
    FAILED = "failed"


class LastErrorCode(str, Enum):
    """Error codes for file processing failures."""
    SERVER_ERROR = "server_error"
    RATE_LIMIT_EXCEEDED = "rate_limit_exceeded"
    INVALID_FILE = "invalid_file"
    UNSUPPORTED_FILE = "unsupported_file"


# ========================================
# Error Model
# ========================================

@dataclass
class LastError:
    """Last error information for failed files."""
    code: str = ""
    message: str = ""
    
    def to_dict(self) -> Dict[str, str]:
        """Convert to dictionary."""
        return {
            "code": self.code,
            "message": self.message,
        }


# ========================================
# Chunking Strategy Models
# ========================================

@dataclass
class StaticChunkingConfig:
    """Static chunking configuration."""
    max_chunk_size_tokens: int = 800
    chunk_overlap_tokens: int = 400
    
    def to_dict(self) -> Dict[str, int]:
        """Convert to dictionary."""
        return {
            "max_chunk_size_tokens": self.max_chunk_size_tokens,
            "chunk_overlap_tokens": self.chunk_overlap_tokens,
        }


@dataclass 
class FileChunkingStrategy:
    """Chunking strategy for a file."""
    type: str = "static"
    static: Optional[StaticChunkingConfig] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {"type": self.type}
        if self.type == "static" and self.static:
            result["static"] = self.static.to_dict()
        return result


# ========================================
# Request Models
# ========================================

@dataclass
class CreateVectorStoreFileRequest:
    """Request to add a file to a vector store."""
    file_id: str = ""
    chunking_strategy: Optional[Dict[str, Any]] = None
    
    def validate(self) -> List[str]:
        """Validate the request."""
        errors = []
        if not self.file_id:
            errors.append("file_id is required")
        if not self.file_id.startswith("file-") and self.file_id:
            # Allow mock IDs for testing
            if not self.file_id.startswith("file_"):
                errors.append("file_id must be a valid file ID")
        return errors


# ========================================
# Response Models
# ========================================

@dataclass
class VectorStoreFileObject:
    """Vector store file object."""
    id: str
    object: str = "vector_store.file"
    usage_bytes: int = 0
    created_at: int = 0
    vector_store_id: str = ""
    status: str = VectorStoreFileStatus.IN_PROGRESS.value
    last_error: Optional[LastError] = None
    chunking_strategy: Optional[FileChunkingStrategy] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {
            "id": self.id,
            "object": self.object,
            "usage_bytes": self.usage_bytes,
            "created_at": self.created_at,
            "vector_store_id": self.vector_store_id,
            "status": self.status,
        }
        
        if self.last_error:
            result["last_error"] = self.last_error.to_dict()
        else:
            result["last_error"] = None
            
        if self.chunking_strategy:
            result["chunking_strategy"] = self.chunking_strategy.to_dict()
        
        return result


@dataclass
class VectorStoreFileListResponse:
    """Response for list files in vector store."""
    object: str = "list"
    data: List[VectorStoreFileObject] = field(default_factory=list)
    first_id: Optional[str] = None
    last_id: Optional[str] = None
    has_more: bool = False
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "object": self.object,
            "data": [f.to_dict() for f in self.data],
            "first_id": self.first_id,
            "last_id": self.last_id,
            "has_more": self.has_more,
        }


@dataclass
class VectorStoreFileDeleteResponse:
    """Response for delete file from vector store."""
    id: str = ""
    object: str = "vector_store.file.deleted"
    deleted: bool = True
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "id": self.id,
            "object": self.object,
            "deleted": self.deleted,
        }


@dataclass
class VectorStoreFileErrorResponse:
    """Error response for file operations."""
    error: Dict[str, Any] = field(default_factory=dict)
    
    def __init__(self, message: str, type: str = "invalid_request_error", code: Optional[str] = None):
        self.error = {"message": message, "type": type}
        if code:
            self.error["code"] = code
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {"error": self.error}


# ========================================
# Vector Store Files Handler
# ========================================

class VectorStoreFilesHandler:
    """Handler for vector store file operations."""
    
    def __init__(self, mock_mode: bool = True):
        """Initialize handler."""
        self.mock_mode = mock_mode
        # Store ID -> Dict[File ID -> VectorStoreFileObject]
        self._files: Dict[str, Dict[str, VectorStoreFileObject]] = {}
    
    def _generate_id(self) -> str:
        """Generate vector store file relationship ID."""
        return f"file-{hashlib.md5(f'{time.time()}'.encode()).hexdigest()[:24]}"
    
    def _ensure_store(self, vector_store_id: str) -> None:
        """Ensure store exists in internal structure."""
        if vector_store_id not in self._files:
            self._files[vector_store_id] = {}
    
    def create(
        self,
        vector_store_id: str,
        request: CreateVectorStoreFileRequest
    ) -> Dict[str, Any]:
        """Add a file to a vector store."""
        errors = request.validate()
        if errors:
            return VectorStoreFileErrorResponse("; ".join(errors)).to_dict()
        
        self._ensure_store(vector_store_id)
        
        # Check file limit
        if len(self._files[vector_store_id]) >= MAX_FILES_PER_STORE:
            return VectorStoreFileErrorResponse(
                f"Vector store has reached maximum of {MAX_FILES_PER_STORE} files",
                code="files_limit_exceeded"
            ).to_dict()
        
        # Check if file already exists
        if request.file_id in self._files[vector_store_id]:
            return VectorStoreFileErrorResponse(
                f"File '{request.file_id}' already exists in vector store",
                code="file_already_exists"
            ).to_dict()
        
        now = int(time.time())
        
        # Parse chunking strategy
        chunking = None
        if request.chunking_strategy:
            strategy_type = request.chunking_strategy.get("type", "static")
            static_config = request.chunking_strategy.get("static", {})
            chunking = FileChunkingStrategy(
                type=strategy_type,
                static=StaticChunkingConfig(
                    max_chunk_size_tokens=static_config.get("max_chunk_size_tokens", 800),
                    chunk_overlap_tokens=static_config.get("chunk_overlap_tokens", 400)
                ) if strategy_type == "static" else None
            )
        
        file_obj = VectorStoreFileObject(
            id=request.file_id,
            created_at=now,
            vector_store_id=vector_store_id,
            status=VectorStoreFileStatus.IN_PROGRESS.value,
            chunking_strategy=chunking,
        )
        
        self._files[vector_store_id][request.file_id] = file_obj
        return file_obj.to_dict()
    
    def list(
        self,
        vector_store_id: str,
        limit: int = DEFAULT_PAGE_SIZE,
        order: str = "desc",
        after: Optional[str] = None,
        before: Optional[str] = None,
        filter: Optional[str] = None,
    ) -> Dict[str, Any]:
        """List files in a vector store."""
        self._ensure_store(vector_store_id)
        
        files = list(self._files[vector_store_id].values())
        
        # Apply status filter
        if filter:
            files = [f for f in files if f.status == filter]
        
        # Sort by created_at
        files = sorted(files, key=lambda f: f.created_at, reverse=(order == "desc"))
        
        # Apply cursor pagination
        if after:
            found_idx = -1
            for i, f in enumerate(files):
                if f.id == after:
                    found_idx = i
                    break
            if found_idx >= 0:
                files = files[found_idx + 1:]
        
        if before:
            found_idx = -1
            for i, f in enumerate(files):
                if f.id == before:
                    found_idx = i
                    break
            if found_idx >= 0:
                files = files[:found_idx]
        
        # Apply limit
        limit = min(limit, MAX_PAGE_SIZE)
        has_more = len(files) > limit
        files = files[:limit]
        
        return VectorStoreFileListResponse(
            data=files,
            first_id=files[0].id if files else None,
            last_id=files[-1].id if files else None,
            has_more=has_more,
        ).to_dict()
    
    def retrieve(
        self,
        vector_store_id: str,
        file_id: str
    ) -> Dict[str, Any]:
        """Retrieve a file from a vector store."""
        self._ensure_store(vector_store_id)
        
        if file_id not in self._files[vector_store_id]:
            return VectorStoreFileErrorResponse(
                f"No file found with id '{file_id}' in vector store '{vector_store_id}'",
                code="file_not_found"
            ).to_dict()
        
        return self._files[vector_store_id][file_id].to_dict()
    
    def delete(
        self,
        vector_store_id: str,
        file_id: str
    ) -> Dict[str, Any]:
        """Delete a file from a vector store."""
        self._ensure_store(vector_store_id)
        
        if file_id not in self._files[vector_store_id]:
            return VectorStoreFileErrorResponse(
                f"No file found with id '{file_id}' in vector store '{vector_store_id}'",
                code="file_not_found"
            ).to_dict()
        
        del self._files[vector_store_id][file_id]
        return VectorStoreFileDeleteResponse(id=file_id).to_dict()
    
    def complete(
        self,
        vector_store_id: str,
        file_id: str,
        usage_bytes: int = 0
    ) -> Dict[str, Any]:
        """Mark a file as completed (mock operation)."""
        self._ensure_store(vector_store_id)
        
        if file_id not in self._files[vector_store_id]:
            return VectorStoreFileErrorResponse(
                f"No file found with id '{file_id}'",
                code="file_not_found"
            ).to_dict()
        
        file_obj = self._files[vector_store_id][file_id]
        file_obj.status = VectorStoreFileStatus.COMPLETED.value
        file_obj.usage_bytes = usage_bytes
        
        return file_obj.to_dict()
    
    def fail(
        self,
        vector_store_id: str,
        file_id: str,
        error_code: str,
        error_message: str
    ) -> Dict[str, Any]:
        """Mark a file as failed (mock operation)."""
        self._ensure_store(vector_store_id)
        
        if file_id not in self._files[vector_store_id]:
            return VectorStoreFileErrorResponse(
                f"No file found with id '{file_id}'",
                code="file_not_found"
            ).to_dict()
        
        file_obj = self._files[vector_store_id][file_id]
        file_obj.status = VectorStoreFileStatus.FAILED.value
        file_obj.last_error = LastError(code=error_code, message=error_message)
        
        return file_obj.to_dict()
    
    def cancel(
        self,
        vector_store_id: str,
        file_id: str
    ) -> Dict[str, Any]:
        """Cancel file processing (mock operation)."""
        self._ensure_store(vector_store_id)
        
        if file_id not in self._files[vector_store_id]:
            return VectorStoreFileErrorResponse(
                f"No file found with id '{file_id}'",
                code="file_not_found"
            ).to_dict()
        
        file_obj = self._files[vector_store_id][file_id]
        if file_obj.status == VectorStoreFileStatus.IN_PROGRESS.value:
            file_obj.status = VectorStoreFileStatus.CANCELLED.value
        
        return file_obj.to_dict()
    
    def get_file_count(self, vector_store_id: str) -> Dict[str, int]:
        """Get file counts by status."""
        self._ensure_store(vector_store_id)
        
        counts = {
            "in_progress": 0,
            "completed": 0,
            "cancelled": 0,
            "failed": 0,
            "total": 0,
        }
        
        for file_obj in self._files[vector_store_id].values():
            counts["total"] += 1
            if file_obj.status == VectorStoreFileStatus.IN_PROGRESS.value:
                counts["in_progress"] += 1
            elif file_obj.status == VectorStoreFileStatus.COMPLETED.value:
                counts["completed"] += 1
            elif file_obj.status == VectorStoreFileStatus.CANCELLED.value:
                counts["cancelled"] += 1
            elif file_obj.status == VectorStoreFileStatus.FAILED.value:
                counts["failed"] += 1
        
        return counts


# ========================================
# Factory and Utilities
# ========================================

def get_vector_store_files_handler(mock_mode: bool = True) -> VectorStoreFilesHandler:
    """Factory function for vector store files handler."""
    return VectorStoreFilesHandler(mock_mode=mock_mode)


def create_file_in_store(
    vector_store_id: str,
    file_id: str,
    chunking_strategy: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """Helper to add a file to a vector store."""
    handler = get_vector_store_files_handler()
    return handler.create(
        vector_store_id,
        CreateVectorStoreFileRequest(file_id=file_id, chunking_strategy=chunking_strategy)
    )


def is_file_processing(file_obj: Dict[str, Any]) -> bool:
    """Check if file is still processing."""
    return file_obj.get("status") == VectorStoreFileStatus.IN_PROGRESS.value


def is_file_ready(file_obj: Dict[str, Any]) -> bool:
    """Check if file is ready for use."""
    return file_obj.get("status") == VectorStoreFileStatus.COMPLETED.value


def is_file_terminal(status: str) -> bool:
    """Check if status is terminal (completed, failed, cancelled)."""
    return status in [
        VectorStoreFileStatus.COMPLETED.value,
        VectorStoreFileStatus.FAILED.value,
        VectorStoreFileStatus.CANCELLED.value,
    ]


def get_file_error(file_obj: Dict[str, Any]) -> Optional[Dict[str, str]]:
    """Get error details if file failed."""
    return file_obj.get("last_error")


def calculate_total_usage(files: List[Dict[str, Any]]) -> int:
    """Calculate total usage bytes across files."""
    return sum(f.get("usage_bytes", 0) for f in files)


# ========================================
# Exports
# ========================================

__all__ = [
    # Constants
    "MAX_FILES_PER_STORE",
    "MAX_FILES_PER_REQUEST",
    "DEFAULT_PAGE_SIZE",
    "MAX_PAGE_SIZE",
    # Enums
    "VectorStoreFileStatus",
    "LastErrorCode",
    # Models
    "LastError",
    "StaticChunkingConfig",
    "FileChunkingStrategy",
    "CreateVectorStoreFileRequest",
    "VectorStoreFileObject",
    "VectorStoreFileListResponse",
    "VectorStoreFileDeleteResponse",
    "VectorStoreFileErrorResponse",
    # Handler
    "VectorStoreFilesHandler",
    # Utilities
    "get_vector_store_files_handler",
    "create_file_in_store",
    "is_file_processing",
    "is_file_ready",
    "is_file_terminal",
    "get_file_error",
    "calculate_total_usage",
]