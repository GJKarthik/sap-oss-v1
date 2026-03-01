"""
OpenAI-compatible Batches API Endpoint

Day 19 Deliverable: Batch processing endpoint for asynchronous request handling

Implements:
- POST /v1/batches - Create batch
- GET /v1/batches - List batches
- GET /v1/batches/{batch_id} - Retrieve batch
- POST /v1/batches/{batch_id}/cancel - Cancel batch
"""

import time
import hashlib
import json
from enum import Enum
from typing import Dict, Any, Optional, List, Union
from dataclasses import dataclass, field


# ========================================
# Constants
# ========================================

SUPPORTED_ENDPOINTS = [
    "/v1/chat/completions",
    "/v1/embeddings",
    "/v1/completions",
]

BATCH_COMPLETION_WINDOWS = [
    "24h",
]

DEFAULT_COMPLETION_WINDOW = "24h"

MAX_INPUT_FILE_SIZE_MB = 100
MAX_REQUESTS_PER_BATCH = 50000


# ========================================
# Enums
# ========================================

class BatchStatus(str, Enum):
    """Batch processing status."""
    VALIDATING = "validating"
    FAILED = "failed"
    IN_PROGRESS = "in_progress"
    FINALIZING = "finalizing"
    COMPLETED = "completed"
    EXPIRED = "expired"
    CANCELLING = "cancelling"
    CANCELLED = "cancelled"
    
    @classmethod
    def terminal_states(cls) -> List["BatchStatus"]:
        """Get terminal states."""
        return [cls.FAILED, cls.COMPLETED, cls.EXPIRED, cls.CANCELLED]
    
    @classmethod
    def active_states(cls) -> List["BatchStatus"]:
        """Get active states."""
        return [cls.VALIDATING, cls.IN_PROGRESS, cls.FINALIZING, cls.CANCELLING]


class BatchEndpoint(str, Enum):
    """Supported batch endpoints."""
    CHAT_COMPLETIONS = "/v1/chat/completions"
    EMBEDDINGS = "/v1/embeddings"
    COMPLETIONS = "/v1/completions"


# ========================================
# Request/Response Models
# ========================================

@dataclass
class BatchRequest:
    """Request to create a batch."""
    input_file_id: str
    endpoint: str
    completion_window: str = "24h"
    metadata: Optional[Dict[str, str]] = None
    
    def validate(self) -> List[str]:
        """Validate the request."""
        errors = []
        
        if not self.input_file_id:
            errors.append("input_file_id is required")
        elif not self.input_file_id.startswith("file-"):
            errors.append("input_file_id must be a valid file ID")
        
        if self.endpoint not in SUPPORTED_ENDPOINTS:
            errors.append(f"endpoint must be one of: {SUPPORTED_ENDPOINTS}")
        
        if self.completion_window not in BATCH_COMPLETION_WINDOWS:
            errors.append(f"completion_window must be one of: {BATCH_COMPLETION_WINDOWS}")
        
        return errors


@dataclass
class BatchRequestCounts:
    """Counts of requests in a batch."""
    total: int = 0
    completed: int = 0
    failed: int = 0
    
    def to_dict(self) -> Dict[str, int]:
        """Convert to dictionary."""
        return {
            "total": self.total,
            "completed": self.completed,
            "failed": self.failed,
        }


@dataclass
class BatchErrors:
    """Error information for failed batch."""
    object: str = "list"
    data: List[Dict[str, Any]] = field(default_factory=list)
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "object": self.object,
            "data": self.data,
        }


@dataclass
class BatchObject:
    """Batch object response."""
    id: str
    object: str = "batch"
    endpoint: str = ""
    errors: Optional[BatchErrors] = None
    input_file_id: str = ""
    completion_window: str = "24h"
    status: str = BatchStatus.VALIDATING.value
    output_file_id: Optional[str] = None
    error_file_id: Optional[str] = None
    created_at: int = 0
    in_progress_at: Optional[int] = None
    expires_at: Optional[int] = None
    finalizing_at: Optional[int] = None
    completed_at: Optional[int] = None
    failed_at: Optional[int] = None
    expired_at: Optional[int] = None
    cancelling_at: Optional[int] = None
    cancelled_at: Optional[int] = None
    request_counts: BatchRequestCounts = field(default_factory=BatchRequestCounts)
    metadata: Optional[Dict[str, str]] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {
            "id": self.id,
            "object": self.object,
            "endpoint": self.endpoint,
            "input_file_id": self.input_file_id,
            "completion_window": self.completion_window,
            "status": self.status,
            "created_at": self.created_at,
            "request_counts": self.request_counts.to_dict(),
        }
        
        # Optional fields
        if self.errors:
            result["errors"] = self.errors.to_dict()
        if self.output_file_id:
            result["output_file_id"] = self.output_file_id
        if self.error_file_id:
            result["error_file_id"] = self.error_file_id
        if self.in_progress_at:
            result["in_progress_at"] = self.in_progress_at
        if self.expires_at:
            result["expires_at"] = self.expires_at
        if self.finalizing_at:
            result["finalizing_at"] = self.finalizing_at
        if self.completed_at:
            result["completed_at"] = self.completed_at
        if self.failed_at:
            result["failed_at"] = self.failed_at
        if self.expired_at:
            result["expired_at"] = self.expired_at
        if self.cancelling_at:
            result["cancelling_at"] = self.cancelling_at
        if self.cancelled_at:
            result["cancelled_at"] = self.cancelled_at
        if self.metadata:
            result["metadata"] = self.metadata
        
        return result


@dataclass
class BatchListResponse:
    """Response for list batches."""
    object: str = "list"
    data: List[BatchObject] = field(default_factory=list)
    first_id: Optional[str] = None
    last_id: Optional[str] = None
    has_more: bool = False
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "object": self.object,
            "data": [b.to_dict() for b in self.data],
            "first_id": self.first_id,
            "last_id": self.last_id,
            "has_more": self.has_more,
        }


@dataclass
class BatchInputLine:
    """A single line in batch input file."""
    custom_id: str
    method: str = "POST"
    url: str = ""
    body: Dict[str, Any] = field(default_factory=dict)
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "BatchInputLine":
        """Create from dictionary."""
        return cls(
            custom_id=data.get("custom_id", ""),
            method=data.get("method", "POST"),
            url=data.get("url", ""),
            body=data.get("body", {}),
        )
    
    def validate(self) -> List[str]:
        """Validate input line."""
        errors = []
        
        if not self.custom_id:
            errors.append("custom_id is required")
        if self.method not in ["POST"]:
            errors.append("method must be POST")
        if not self.url:
            errors.append("url is required")
        elif self.url not in SUPPORTED_ENDPOINTS:
            errors.append(f"url must be one of: {SUPPORTED_ENDPOINTS}")
        if not self.body:
            errors.append("body is required")
        
        return errors


@dataclass
class BatchOutputLine:
    """A single line in batch output file."""
    id: str
    custom_id: str
    response: Optional[Dict[str, Any]] = None
    error: Optional[Dict[str, Any]] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {
            "id": self.id,
            "custom_id": self.custom_id,
        }
        if self.response:
            result["response"] = self.response
        if self.error:
            result["error"] = self.error
        return result


@dataclass
class BatchErrorResponse:
    """Error response for batch operations."""
    error: Dict[str, Any] = field(default_factory=dict)
    
    def __init__(self, message: str, type: str = "invalid_request_error", code: Optional[str] = None):
        self.error = {
            "message": message,
            "type": type,
        }
        if code:
            self.error["code"] = code
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {"error": self.error}


# ========================================
# Batch Handler
# ========================================

class BatchesHandler:
    """Handler for batch operations."""
    
    def __init__(
        self,
        backend: Optional[Any] = None,
        mock_mode: bool = True,
        file_store: Optional[Dict[str, str]] = None,
    ):
        """
        Initialize handler.
        
        Args:
            backend: Optional backend service
            mock_mode: If True, use mock responses
            file_store: Mock file storage
        """
        self.backend = backend
        self.mock_mode = mock_mode
        self.file_store = file_store or {}
        self._batches: Dict[str, BatchObject] = {}
        self._output_files: Dict[str, str] = {}
    
    def create_batch(self, request: BatchRequest) -> Dict[str, Any]:
        """
        Create a new batch.
        
        Args:
            request: Batch creation request
            
        Returns:
            Batch object dictionary
        """
        # Validate request
        errors = request.validate()
        if errors:
            return BatchErrorResponse("; ".join(errors)).to_dict()
        
        # Validate input file exists
        if request.input_file_id not in self.file_store:
            return BatchErrorResponse(
                f"No file with ID '{request.input_file_id}' found",
                code="file_not_found"
            ).to_dict()
        
        # Parse and validate input file
        content = self.file_store[request.input_file_id]
        validation = self._validate_input_file(content, request.endpoint)
        if validation["errors"]:
            return BatchErrorResponse(
                f"Input file validation failed: {validation['errors'][0]}",
                code="invalid_input_file"
            ).to_dict()
        
        # Generate batch ID
        batch_id = f"batch_{hashlib.md5(f'{time.time()}'.encode()).hexdigest()[:24]}"
        
        # Calculate expiry
        now = int(time.time())
        expires_at = now + 24 * 60 * 60  # 24 hours
        
        # Create batch object
        batch = BatchObject(
            id=batch_id,
            endpoint=request.endpoint,
            input_file_id=request.input_file_id,
            completion_window=request.completion_window,
            status=BatchStatus.VALIDATING.value,
            created_at=now,
            expires_at=expires_at,
            request_counts=BatchRequestCounts(total=validation["count"]),
            metadata=request.metadata,
        )
        
        self._batches[batch_id] = batch
        
        return batch.to_dict()
    
    def list_batches(
        self,
        after: Optional[str] = None,
        limit: int = 20,
    ) -> Dict[str, Any]:
        """
        List batches.
        
        Args:
            after: Cursor for pagination
            limit: Number of results
            
        Returns:
            List response dictionary
        """
        # Get all batches sorted by creation time
        batches = sorted(
            self._batches.values(),
            key=lambda b: b.created_at,
            reverse=True
        )
        
        # Apply pagination
        if after:
            found_idx = -1
            for i, batch in enumerate(batches):
                if batch.id == after:
                    found_idx = i
                    break
            if found_idx >= 0:
                batches = batches[found_idx + 1:]
        
        # Limit results
        has_more = len(batches) > limit
        batches = batches[:limit]
        
        response = BatchListResponse(
            data=batches,
            first_id=batches[0].id if batches else None,
            last_id=batches[-1].id if batches else None,
            has_more=has_more,
        )
        
        return response.to_dict()
    
    def retrieve_batch(self, batch_id: str) -> Dict[str, Any]:
        """
        Retrieve a batch.
        
        Args:
            batch_id: Batch ID
            
        Returns:
            Batch object dictionary
        """
        if batch_id not in self._batches:
            return BatchErrorResponse(
                f"No batch with ID '{batch_id}' found",
                code="batch_not_found"
            ).to_dict()
        
        return self._batches[batch_id].to_dict()
    
    def cancel_batch(self, batch_id: str) -> Dict[str, Any]:
        """
        Cancel a batch.
        
        Args:
            batch_id: Batch ID
            
        Returns:
            Batch object dictionary
        """
        if batch_id not in self._batches:
            return BatchErrorResponse(
                f"No batch with ID '{batch_id}' found",
                code="batch_not_found"
            ).to_dict()
        
        batch = self._batches[batch_id]
        
        # Check if batch can be cancelled
        if batch.status in [s.value for s in BatchStatus.terminal_states()]:
            return BatchErrorResponse(
                f"Batch is already {batch.status} and cannot be cancelled",
                code="invalid_batch_status"
            ).to_dict()
        
        # Update status
        batch.status = BatchStatus.CANCELLING.value
        batch.cancelling_at = int(time.time())
        
        return batch.to_dict()
    
    def advance_batch(self, batch_id: str) -> Optional[Dict[str, Any]]:
        """
        Advance batch processing (for simulation).
        
        Args:
            batch_id: Batch ID
            
        Returns:
            Updated batch or None if complete
        """
        if batch_id not in self._batches:
            return None
        
        batch = self._batches[batch_id]
        now = int(time.time())
        
        if batch.status == BatchStatus.VALIDATING.value:
            batch.status = BatchStatus.IN_PROGRESS.value
            batch.in_progress_at = now
        
        elif batch.status == BatchStatus.IN_PROGRESS.value:
            # Simulate processing
            batch.request_counts.completed += 1
            if batch.request_counts.completed >= batch.request_counts.total:
                batch.status = BatchStatus.FINALIZING.value
                batch.finalizing_at = now
        
        elif batch.status == BatchStatus.FINALIZING.value:
            # Generate output file
            output_file_id = f"file-output-{batch_id[-8:]}"
            self._output_files[batch_id] = output_file_id
            
            batch.status = BatchStatus.COMPLETED.value
            batch.completed_at = now
            batch.output_file_id = output_file_id
        
        elif batch.status == BatchStatus.CANCELLING.value:
            batch.status = BatchStatus.CANCELLED.value
            batch.cancelled_at = now
        
        return batch.to_dict()
    
    def get_batch_output(self, batch_id: str) -> Optional[str]:
        """
        Get batch output file content.
        
        Args:
            batch_id: Batch ID
            
        Returns:
            Output file content as JSONL
        """
        if batch_id not in self._batches:
            return None
        
        batch = self._batches[batch_id]
        if batch.status != BatchStatus.COMPLETED.value:
            return None
        
        # Generate mock output
        lines = []
        for i in range(batch.request_counts.total):
            output_line = BatchOutputLine(
                id=f"response-{i}",
                custom_id=f"request-{i}",
                response={
                    "status_code": 200,
                    "body": {"id": f"result-{i}", "object": "mock_response"},
                },
            )
            lines.append(json.dumps(output_line.to_dict()))
        
        return "\n".join(lines)
    
    def _validate_input_file(
        self,
        content: str,
        endpoint: str,
    ) -> Dict[str, Any]:
        """
        Validate batch input file.
        
        Args:
            content: JSONL file content
            endpoint: Expected endpoint
            
        Returns:
            Validation result with count and errors
        """
        errors = []
        count = 0
        
        lines = content.strip().split('\n')
        
        for i, line in enumerate(lines, 1):
            if not line.strip():
                continue
            
            try:
                data = json.loads(line)
                input_line = BatchInputLine.from_dict(data)
                
                # Validate line
                line_errors = input_line.validate()
                if line_errors:
                    errors.extend([f"Line {i}: {e}" for e in line_errors])
                    continue
                
                # Check endpoint matches
                if input_line.url != endpoint:
                    errors.append(f"Line {i}: url '{input_line.url}' does not match batch endpoint '{endpoint}'")
                    continue
                
                count += 1
                
            except json.JSONDecodeError as e:
                errors.append(f"Line {i}: Invalid JSON - {str(e)}")
        
        if count == 0 and not errors:
            errors.append("Input file is empty")
        
        if count > MAX_REQUESTS_PER_BATCH:
            errors.append(f"Input file has {count} requests, maximum is {MAX_REQUESTS_PER_BATCH}")
        
        return {
            "count": count,
            "errors": errors[:10],  # Limit errors returned
        }
    
    def handle_request(
        self,
        method: str,
        path: str,
        data: Optional[Dict[str, Any]] = None,
        params: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        """
        Handle batch API request.
        
        Args:
            method: HTTP method
            path: Request path
            data: Request body
            params: Query parameters
            
        Returns:
            Response dictionary
        """
        path = path.rstrip("/")
        params = params or {}
        
        if path == "/v1/batches" and method == "POST":
            request = BatchRequest(
                input_file_id=data.get("input_file_id", ""),
                endpoint=data.get("endpoint", ""),
                completion_window=data.get("completion_window", DEFAULT_COMPLETION_WINDOW),
                metadata=data.get("metadata"),
            )
            return self.create_batch(request)
        
        elif path == "/v1/batches" and method == "GET":
            return self.list_batches(
                after=params.get("after"),
                limit=int(params.get("limit", 20)),
            )
        
        elif path.startswith("/v1/batches/") and path.endswith("/cancel") and method == "POST":
            batch_id = path.split("/")[3]
            return self.cancel_batch(batch_id)
        
        elif path.startswith("/v1/batches/") and method == "GET":
            batch_id = path.split("/")[3]
            return self.retrieve_batch(batch_id)
        
        return BatchErrorResponse("Unknown endpoint", code="unknown_endpoint").to_dict()


# ========================================
# Factory and Utilities
# ========================================

def get_batches_handler(
    backend: Optional[Any] = None,
    mock_mode: bool = True,
    file_store: Optional[Dict[str, str]] = None,
) -> BatchesHandler:
    """
    Factory function to create batches handler.
    
    Args:
        backend: Optional backend service
        mock_mode: If True, use mock responses
        file_store: Mock file storage
        
    Returns:
        Configured BatchesHandler instance
    """
    return BatchesHandler(
        backend=backend,
        mock_mode=mock_mode,
        file_store=file_store,
    )


def create_batch(
    input_file_id: str,
    endpoint: str,
    completion_window: str = "24h",
    metadata: Optional[Dict[str, str]] = None,
) -> Dict[str, Any]:
    """
    Convenience function to create a batch.
    
    Args:
        input_file_id: Input file ID
        endpoint: API endpoint
        completion_window: Completion window
        metadata: Optional metadata
        
    Returns:
        Batch object dictionary
    """
    handler = get_batches_handler()
    request = BatchRequest(
        input_file_id=input_file_id,
        endpoint=endpoint,
        completion_window=completion_window,
        metadata=metadata,
    )
    return handler.create_batch(request)


def generate_batch_input(
    requests: List[Dict[str, Any]],
    endpoint: str = "/v1/chat/completions",
) -> str:
    """
    Generate batch input file content.
    
    Args:
        requests: List of request bodies
        endpoint: API endpoint for all requests
        
    Returns:
        JSONL string
    """
    lines = []
    for i, body in enumerate(requests):
        line = BatchInputLine(
            custom_id=f"request-{i}",
            method="POST",
            url=endpoint,
            body=body,
        )
        lines.append(json.dumps({
            "custom_id": line.custom_id,
            "method": line.method,
            "url": line.url,
            "body": line.body,
        }))
    return "\n".join(lines)


def parse_batch_output(content: str) -> List[BatchOutputLine]:
    """
    Parse batch output file content.
    
    Args:
        content: JSONL output content
        
    Returns:
        List of BatchOutputLine objects
    """
    results = []
    for line in content.strip().split('\n'):
        if not line.strip():
            continue
        data = json.loads(line)
        results.append(BatchOutputLine(
            id=data.get("id", ""),
            custom_id=data.get("custom_id", ""),
            response=data.get("response"),
            error=data.get("error"),
        ))
    return results


def validate_batch_request(request: BatchRequest) -> List[str]:
    """
    Validate a batch request.
    
    Args:
        request: Batch request
        
    Returns:
        List of error messages
    """
    return request.validate()


def is_batch_complete(batch: Dict[str, Any]) -> bool:
    """
    Check if batch is in a terminal state.
    
    Args:
        batch: Batch object dictionary
        
    Returns:
        True if batch is complete/failed/expired/cancelled
    """
    status = batch.get("status", "")
    return status in [s.value for s in BatchStatus.terminal_states()]


def get_batch_progress(batch: Dict[str, Any]) -> float:
    """
    Get batch processing progress.
    
    Args:
        batch: Batch object dictionary
        
    Returns:
        Progress as float 0-1
    """
    counts = batch.get("request_counts", {})
    total = counts.get("total", 0)
    completed = counts.get("completed", 0)
    
    if total == 0:
        return 0.0
    return completed / total


# ========================================
# Exports
# ========================================

__all__ = [
    # Constants
    "SUPPORTED_ENDPOINTS",
    "BATCH_COMPLETION_WINDOWS",
    "MAX_REQUESTS_PER_BATCH",
    # Enums
    "BatchStatus",
    "BatchEndpoint",
    # Models
    "BatchRequest",
    "BatchRequestCounts",
    "BatchErrors",
    "BatchObject",
    "BatchListResponse",
    "BatchInputLine",
    "BatchOutputLine",
    "BatchErrorResponse",
    # Handler
    "BatchesHandler",
    # Utilities
    "get_batches_handler",
    "create_batch",
    "generate_batch_input",
    "parse_batch_output",
    "validate_batch_request",
    "is_batch_complete",
    "get_batch_progress",
]