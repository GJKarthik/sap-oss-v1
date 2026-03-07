"""
OpenAI-compatible Vector Store File Batches API

Day 28 Deliverable: Vector Store File Batches endpoint handler

Implements:
- POST /v1/vector_stores/{id}/file_batches - Create file batch
- GET /v1/vector_stores/{id}/file_batches/{batch_id} - Retrieve batch
- POST /v1/vector_stores/{id}/file_batches/{batch_id}/cancel - Cancel batch
- GET /v1/vector_stores/{id}/file_batches/{batch_id}/files - List files in batch
"""

import time
import hashlib
from enum import Enum
from typing import Dict, Any, Optional, List
from dataclasses import dataclass, field


# ========================================
# Constants
# ========================================

MAX_FILES_PER_BATCH = 500
MAX_BATCHES_PER_STORE = 100
DEFAULT_PAGE_SIZE = 20
MAX_PAGE_SIZE = 100


# ========================================
# Enums
# ========================================

class FileBatchStatus(str, Enum):
    """File batch processing statuses."""
    IN_PROGRESS = "in_progress"
    COMPLETED = "completed"
    CANCELLED = "cancelled"
    FAILED = "failed"


class FileBatchFileStatus(str, Enum):
    """Individual file status within a batch."""
    IN_PROGRESS = "in_progress"
    COMPLETED = "completed"
    CANCELLED = "cancelled"
    FAILED = "failed"


# ========================================
# File Counts Model
# ========================================

@dataclass
class BatchFileCounts:
    """File counts for a batch."""
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
    
    def update_status(self, file_status: str) -> None:
        """Update counts based on file status change."""
        if file_status == FileBatchFileStatus.IN_PROGRESS.value:
            self.in_progress += 1
        elif file_status == FileBatchFileStatus.COMPLETED.value:
            self.completed += 1
        elif file_status == FileBatchFileStatus.FAILED.value:
            self.failed += 1
        elif file_status == FileBatchFileStatus.CANCELLED.value:
            self.cancelled += 1


# ========================================
# Chunking Strategy Model
# ========================================

@dataclass
class BatchChunkingStrategy:
    """Chunking strategy for batch files."""
    type: str = "auto"
    max_chunk_size_tokens: Optional[int] = None
    chunk_overlap_tokens: Optional[int] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {"type": self.type}
        if self.type == "static":
            result["static"] = {
                "max_chunk_size_tokens": self.max_chunk_size_tokens or 800,
                "chunk_overlap_tokens": self.chunk_overlap_tokens or 400,
            }
        return result


# ========================================
# Request Models
# ========================================

@dataclass
class CreateFileBatchRequest:
    """Request to create a file batch."""
    file_ids: List[str] = field(default_factory=list)
    chunking_strategy: Optional[Dict[str, Any]] = None
    
    def validate(self) -> List[str]:
        """Validate the request."""
        errors = []
        if not self.file_ids:
            errors.append("file_ids is required and must not be empty")
        elif len(self.file_ids) > MAX_FILES_PER_BATCH:
            errors.append(f"Maximum {MAX_FILES_PER_BATCH} files per batch")
        return errors


# ========================================
# Response Models
# ========================================

@dataclass
class FileBatchObject:
    """File batch object."""
    id: str
    object: str = "vector_store.file_batch"
    created_at: int = 0
    vector_store_id: str = ""
    status: str = FileBatchStatus.IN_PROGRESS.value
    file_counts: Optional[BatchFileCounts] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "id": self.id,
            "object": self.object,
            "created_at": self.created_at,
            "vector_store_id": self.vector_store_id,
            "status": self.status,
            "file_counts": self.file_counts.to_dict() if self.file_counts else BatchFileCounts().to_dict(),
        }


@dataclass
class BatchFileObject:
    """File object within a batch."""
    id: str
    object: str = "vector_store.file"
    created_at: int = 0
    vector_store_id: str = ""
    batch_id: str = ""
    status: str = FileBatchFileStatus.IN_PROGRESS.value
    usage_bytes: int = 0
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "id": self.id,
            "object": self.object,
            "created_at": self.created_at,
            "vector_store_id": self.vector_store_id,
            "status": self.status,
            "usage_bytes": self.usage_bytes,
        }


@dataclass
class BatchFileListResponse:
    """Response for list files in batch."""
    object: str = "list"
    data: List[BatchFileObject] = field(default_factory=list)
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
class FileBatchErrorResponse:
    """Error response for batch operations."""
    error: Dict[str, Any] = field(default_factory=dict)
    
    def __init__(self, message: str, type: str = "invalid_request_error", code: Optional[str] = None):
        self.error = {"message": message, "type": type}
        if code:
            self.error["code"] = code
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {"error": self.error}


# ========================================
# File Batch Handler
# ========================================

class FileBatchHandler:
    """Handler for file batch operations."""
    
    def __init__(self, mock_mode: bool = True):
        """Initialize handler."""
        self.mock_mode = mock_mode
        # Store ID -> Dict[Batch ID -> FileBatchObject]
        self._batches: Dict[str, Dict[str, FileBatchObject]] = {}
        # Batch ID -> List[BatchFileObject]
        self._batch_files: Dict[str, List[BatchFileObject]] = {}
    
    def _generate_id(self) -> str:
        """Generate batch ID."""
        return f"vsfb_{hashlib.md5(f'{time.time()}'.encode()).hexdigest()[:24]}"
    
    def _ensure_store(self, vector_store_id: str) -> None:
        """Ensure store exists in internal structure."""
        if vector_store_id not in self._batches:
            self._batches[vector_store_id] = {}
    
    def create(
        self,
        vector_store_id: str,
        request: CreateFileBatchRequest
    ) -> Dict[str, Any]:
        """Create a file batch."""
        errors = request.validate()
        if errors:
            return FileBatchErrorResponse("; ".join(errors)).to_dict()
        
        self._ensure_store(vector_store_id)
        
        # Check batch limit
        if len(self._batches[vector_store_id]) >= MAX_BATCHES_PER_STORE:
            return FileBatchErrorResponse(
                f"Vector store has reached maximum of {MAX_BATCHES_PER_STORE} batches",
                code="batches_limit_exceeded"
            ).to_dict()
        
        batch_id = self._generate_id()
        now = int(time.time())
        
        # Create file counts
        file_counts = BatchFileCounts(
            in_progress=len(request.file_ids),
            total=len(request.file_ids)
        )
        
        batch = FileBatchObject(
            id=batch_id,
            created_at=now,
            vector_store_id=vector_store_id,
            status=FileBatchStatus.IN_PROGRESS.value,
            file_counts=file_counts,
        )
        
        # Create batch files
        batch_files = []
        for file_id in request.file_ids:
            batch_file = BatchFileObject(
                id=file_id,
                created_at=now,
                vector_store_id=vector_store_id,
                batch_id=batch_id,
                status=FileBatchFileStatus.IN_PROGRESS.value,
            )
            batch_files.append(batch_file)
        
        self._batches[vector_store_id][batch_id] = batch
        self._batch_files[batch_id] = batch_files
        
        return batch.to_dict()
    
    def retrieve(
        self,
        vector_store_id: str,
        batch_id: str
    ) -> Dict[str, Any]:
        """Retrieve a file batch."""
        self._ensure_store(vector_store_id)
        
        if batch_id not in self._batches[vector_store_id]:
            return FileBatchErrorResponse(
                f"No batch found with id '{batch_id}' in vector store '{vector_store_id}'",
                code="batch_not_found"
            ).to_dict()
        
        return self._batches[vector_store_id][batch_id].to_dict()
    
    def cancel(
        self,
        vector_store_id: str,
        batch_id: str
    ) -> Dict[str, Any]:
        """Cancel a file batch."""
        self._ensure_store(vector_store_id)
        
        if batch_id not in self._batches[vector_store_id]:
            return FileBatchErrorResponse(
                f"No batch found with id '{batch_id}'",
                code="batch_not_found"
            ).to_dict()
        
        batch = self._batches[vector_store_id][batch_id]
        
        # Only cancel if in progress
        if batch.status != FileBatchStatus.IN_PROGRESS.value:
            return FileBatchErrorResponse(
                f"Batch cannot be cancelled, current status: {batch.status}",
                code="invalid_operation"
            ).to_dict()
        
        # Cancel batch and its files
        batch.status = FileBatchStatus.CANCELLED.value
        
        # Update file counts
        if batch.file_counts:
            batch.file_counts.cancelled = batch.file_counts.in_progress
            batch.file_counts.in_progress = 0
        
        # Cancel all in-progress files
        if batch_id in self._batch_files:
            for file_obj in self._batch_files[batch_id]:
                if file_obj.status == FileBatchFileStatus.IN_PROGRESS.value:
                    file_obj.status = FileBatchFileStatus.CANCELLED.value
        
        return batch.to_dict()
    
    def list_files(
        self,
        vector_store_id: str,
        batch_id: str,
        limit: int = DEFAULT_PAGE_SIZE,
        order: str = "desc",
        after: Optional[str] = None,
        before: Optional[str] = None,
        filter: Optional[str] = None,
    ) -> Dict[str, Any]:
        """List files in a batch."""
        self._ensure_store(vector_store_id)
        
        if batch_id not in self._batches[vector_store_id]:
            return FileBatchErrorResponse(
                f"No batch found with id '{batch_id}'",
                code="batch_not_found"
            ).to_dict()
        
        files = self._batch_files.get(batch_id, [])
        
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
        
        return BatchFileListResponse(
            data=files,
            first_id=files[0].id if files else None,
            last_id=files[-1].id if files else None,
            has_more=has_more,
        ).to_dict()
    
    def complete_file(
        self,
        batch_id: str,
        file_id: str,
        usage_bytes: int = 0
    ) -> bool:
        """Mark a file as completed (mock operation)."""
        if batch_id not in self._batch_files:
            return False
        
        for file_obj in self._batch_files[batch_id]:
            if file_obj.id == file_id:
                file_obj.status = FileBatchFileStatus.COMPLETED.value
                file_obj.usage_bytes = usage_bytes
                self._update_batch_counts(batch_id)
                return True
        
        return False
    
    def fail_file(
        self,
        batch_id: str,
        file_id: str
    ) -> bool:
        """Mark a file as failed (mock operation)."""
        if batch_id not in self._batch_files:
            return False
        
        for file_obj in self._batch_files[batch_id]:
            if file_obj.id == file_id:
                file_obj.status = FileBatchFileStatus.FAILED.value
                self._update_batch_counts(batch_id)
                return True
        
        return False
    
    def _update_batch_counts(self, batch_id: str) -> None:
        """Update batch file counts based on current file statuses."""
        if batch_id not in self._batch_files:
            return
        
        # Find batch
        batch = None
        for store_batches in self._batches.values():
            if batch_id in store_batches:
                batch = store_batches[batch_id]
                break
        
        if not batch or not batch.file_counts:
            return
        
        # Recalculate counts
        counts = BatchFileCounts()
        for file_obj in self._batch_files[batch_id]:
            counts.total += 1
            counts.update_status(file_obj.status)
        
        batch.file_counts = counts
        
        # Update batch status if all files processed
        if counts.in_progress == 0:
            if counts.failed > 0 and counts.completed == 0:
                batch.status = FileBatchStatus.FAILED.value
            elif counts.cancelled == counts.total:
                batch.status = FileBatchStatus.CANCELLED.value
            else:
                batch.status = FileBatchStatus.COMPLETED.value
    
    def complete_batch(
        self,
        vector_store_id: str,
        batch_id: str
    ) -> Dict[str, Any]:
        """Mark all files in batch as completed (mock operation)."""
        self._ensure_store(vector_store_id)
        
        if batch_id not in self._batches[vector_store_id]:
            return FileBatchErrorResponse(
                f"No batch found with id '{batch_id}'",
                code="batch_not_found"
            ).to_dict()
        
        if batch_id in self._batch_files:
            for file_obj in self._batch_files[batch_id]:
                if file_obj.status == FileBatchFileStatus.IN_PROGRESS.value:
                    file_obj.status = FileBatchFileStatus.COMPLETED.value
        
        self._update_batch_counts(batch_id)
        return self._batches[vector_store_id][batch_id].to_dict()


# ========================================
# Factory and Utilities
# ========================================

def get_file_batch_handler(mock_mode: bool = True) -> FileBatchHandler:
    """Factory function for file batch handler."""
    return FileBatchHandler(mock_mode=mock_mode)


def create_file_batch(
    vector_store_id: str,
    file_ids: List[str],
    chunking_strategy: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """Helper to create a file batch."""
    handler = get_file_batch_handler()
    return handler.create(
        vector_store_id,
        CreateFileBatchRequest(file_ids=file_ids, chunking_strategy=chunking_strategy)
    )


def is_batch_processing(batch: Dict[str, Any]) -> bool:
    """Check if batch is still processing."""
    return batch.get("status") == FileBatchStatus.IN_PROGRESS.value


def is_batch_complete(batch: Dict[str, Any]) -> bool:
    """Check if batch is complete."""
    return batch.get("status") == FileBatchStatus.COMPLETED.value


def is_batch_terminal(status: str) -> bool:
    """Check if status is terminal."""
    return status in [
        FileBatchStatus.COMPLETED.value,
        FileBatchStatus.FAILED.value,
        FileBatchStatus.CANCELLED.value,
    ]


def get_batch_progress(batch: Dict[str, Any]) -> float:
    """Get batch processing progress as percentage."""
    counts = batch.get("file_counts", {})
    total = counts.get("total", 0)
    if total == 0:
        return 100.0
    completed = counts.get("completed", 0) + counts.get("failed", 0) + counts.get("cancelled", 0)
    return (completed / total) * 100


def calculate_batch_usage(batch: Dict[str, Any], files: List[Dict[str, Any]]) -> int:
    """Calculate total usage bytes for batch."""
    return sum(f.get("usage_bytes", 0) for f in files)


# ========================================
# Exports
# ========================================

__all__ = [
    # Constants
    "MAX_FILES_PER_BATCH",
    "MAX_BATCHES_PER_STORE",
    "DEFAULT_PAGE_SIZE",
    "MAX_PAGE_SIZE",
    # Enums
    "FileBatchStatus",
    "FileBatchFileStatus",
    # Models
    "BatchFileCounts",
    "BatchChunkingStrategy",
    "CreateFileBatchRequest",
    "FileBatchObject",
    "BatchFileObject",
    "BatchFileListResponse",
    "FileBatchErrorResponse",
    # Handler
    "FileBatchHandler",
    # Utilities
    "get_file_batch_handler",
    "create_file_batch",
    "is_batch_processing",
    "is_batch_complete",
    "is_batch_terminal",
    "get_batch_progress",
    "calculate_batch_usage",
]