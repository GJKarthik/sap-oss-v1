"""
OpenAI Files Endpoints Handler

Day 13 Deliverable: /v1/files endpoint
Reference: https://platform.openai.com/docs/api-reference/files

Provides OpenAI-compatible file management:
- Upload files for fine-tuning, assistants, or batch processing
- List, retrieve, and delete files
- Download file content

Usage:
    from openai.files import FilesHandler
    
    handler = FilesHandler()
    result = handler.upload_file(file_data, "training.jsonl", "fine-tune")
"""

import time
import uuid
import logging
import hashlib
import json
from typing import Optional, Dict, Any, List, Union, BinaryIO
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path

logger = logging.getLogger(__name__)


# ========================================
# Enums
# ========================================

class FilePurpose(str, Enum):
    """Supported file purposes."""
    FINE_TUNE = "fine-tune"
    FINE_TUNE_RESULTS = "fine-tune-results"
    ASSISTANTS = "assistants"
    ASSISTANTS_OUTPUT = "assistants_output"
    BATCH = "batch"
    BATCH_OUTPUT = "batch_output"
    VISION = "vision"


class FileStatus(str, Enum):
    """File processing status."""
    UPLOADED = "uploaded"
    PROCESSED = "processed"
    PENDING = "pending"
    ERROR = "error"
    DELETED = "deleted"


# ========================================
# Data Models
# ========================================

@dataclass
class FileObject:
    """
    File object representing an uploaded file.
    
    Reference: https://platform.openai.com/docs/api-reference/files/object
    """
    id: str
    object: str = "file"
    bytes: int = 0
    created_at: int = field(default_factory=lambda: int(time.time()))
    filename: str = ""
    purpose: str = "fine-tune"
    status: str = "uploaded"
    status_details: Optional[str] = None
    
    @classmethod
    def create(
        cls,
        filename: str,
        purpose: str,
        file_size: int,
        file_id: str = None,
    ) -> "FileObject":
        """Create a new file object."""
        return cls(
            id=file_id or f"file-{uuid.uuid4().hex[:24]}",
            bytes=file_size,
            filename=filename,
            purpose=purpose,
            status="uploaded",
        )
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {
            "id": self.id,
            "object": self.object,
            "bytes": self.bytes,
            "created_at": self.created_at,
            "filename": self.filename,
            "purpose": self.purpose,
            "status": self.status,
        }
        if self.status_details:
            result["status_details"] = self.status_details
        return result


@dataclass
class FileListResponse:
    """Response for listing files."""
    data: List[FileObject] = field(default_factory=list)
    object: str = "list"
    has_more: bool = False
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "object": self.object,
            "data": [f.to_dict() for f in self.data],
            "has_more": self.has_more,
        }


@dataclass
class FileDeleteResponse:
    """Response for file deletion."""
    id: str
    object: str = "file"
    deleted: bool = True
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "id": self.id,
            "object": self.object,
            "deleted": self.deleted,
        }


@dataclass
class FileContentResponse:
    """Response for file content retrieval."""
    content: bytes
    filename: str
    content_type: str = "application/octet-stream"
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary (for metadata)."""
        return {
            "filename": self.filename,
            "content_type": self.content_type,
            "size": len(self.content),
        }


@dataclass
class FileErrorResponse:
    """Error response for file operations."""
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
# File Validation
# ========================================

SUPPORTED_PURPOSES = {p.value for p in FilePurpose}

ALLOWED_EXTENSIONS = {
    "fine-tune": {"jsonl"},
    "fine-tune-results": {"json", "jsonl"},
    "assistants": {"c", "cpp", "css", "csv", "docx", "gif", "html", "java", 
                   "jpeg", "jpg", "js", "json", "md", "pdf", "php", "png", 
                   "pptx", "py", "rb", "sh", "tar", "tex", "ts", "txt", 
                   "webp", "xlsx", "xml", "zip"},
    "assistants_output": {"json", "jsonl"},
    "batch": {"jsonl"},
    "batch_output": {"jsonl"},
    "vision": {"gif", "jpeg", "jpg", "png", "webp"},
}

# Max file sizes by purpose (in bytes)
MAX_FILE_SIZES = {
    "fine-tune": 512 * 1024 * 1024,  # 512 MB
    "assistants": 512 * 1024 * 1024,  # 512 MB
    "batch": 100 * 1024 * 1024,  # 100 MB
    "vision": 20 * 1024 * 1024,  # 20 MB
}


def get_file_extension(filename: str) -> str:
    """Extract file extension."""
    return Path(filename).suffix.lower().lstrip(".")


def validate_file(
    filename: str,
    file_size: int,
    purpose: str,
) -> Optional[str]:
    """
    Validate file for upload.
    
    Returns error message if invalid, None if valid.
    """
    if not filename:
        return "filename is required"
    
    if file_size <= 0:
        return "file cannot be empty"
    
    if purpose not in SUPPORTED_PURPOSES:
        return f"Invalid purpose: {purpose}. Supported: {', '.join(SUPPORTED_PURPOSES)}"
    
    # Check file extension
    ext = get_file_extension(filename)
    allowed = ALLOWED_EXTENSIONS.get(purpose, set())
    if ext and allowed and ext not in allowed:
        return f"File extension .{ext} not allowed for purpose '{purpose}'. Allowed: {', '.join(sorted(allowed))}"
    
    # Check file size
    max_size = MAX_FILE_SIZES.get(purpose, 512 * 1024 * 1024)
    if file_size > max_size:
        max_mb = max_size / (1024 * 1024)
        return f"File too large: {file_size} bytes. Maximum for '{purpose}': {max_mb:.0f} MB"
    
    return None


def validate_jsonl_content(content: bytes) -> Optional[str]:
    """
    Validate JSONL file content.
    
    Returns error message if invalid, None if valid.
    """
    try:
        lines = content.decode("utf-8").strip().split("\n")
        for i, line in enumerate(lines):
            if line.strip():
                json.loads(line)
        return None
    except UnicodeDecodeError:
        return "File must be UTF-8 encoded"
    except json.JSONDecodeError as e:
        return f"Invalid JSON on line {i + 1}: {e}"


def get_content_type(filename: str) -> str:
    """Get content type for filename."""
    ext = get_file_extension(filename)
    content_types = {
        "json": "application/json",
        "jsonl": "application/jsonl",
        "txt": "text/plain",
        "md": "text/markdown",
        "csv": "text/csv",
        "html": "text/html",
        "css": "text/css",
        "js": "application/javascript",
        "ts": "application/typescript",
        "py": "text/x-python",
        "pdf": "application/pdf",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "xml": "application/xml",
        "zip": "application/zip",
        "tar": "application/x-tar",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    }
    return content_types.get(ext, "application/octet-stream")


# ========================================
# Files Handler
# ========================================

class FilesHandler:
    """
    Handler for file operations.
    
    Provides OpenAI-compatible file management endpoints.
    In production, files are stored in SAP HANA or cloud storage.
    """
    
    def __init__(self, storage_backend: Optional[Any] = None):
        """
        Initialize handler.
        
        Args:
            storage_backend: Storage backend for file persistence
        """
        self._storage = storage_backend
        self._mock_mode = storage_backend is None
        
        # In-memory storage for mock mode
        self._files: Dict[str, FileObject] = {}
        self._file_contents: Dict[str, bytes] = {}
    
    @property
    def is_mock_mode(self) -> bool:
        """Check if running in mock mode."""
        return self._mock_mode
    
    def upload_file(
        self,
        file_data: bytes,
        filename: str,
        purpose: str,
    ) -> Dict[str, Any]:
        """
        Upload a file.
        
        Args:
            file_data: Raw file content
            filename: Original filename
            purpose: Intended purpose of the file
        
        Returns:
            FileObject as dictionary
        """
        # Validate
        error = validate_file(filename, len(file_data), purpose)
        if error:
            return FileErrorResponse(message=error, param="file").to_dict()
        
        # Additional validation for JSONL files
        ext = get_file_extension(filename)
        if ext == "jsonl":
            error = validate_jsonl_content(file_data)
            if error:
                return FileErrorResponse(message=error, param="file").to_dict()
        
        # Create file object
        file_obj = FileObject.create(
            filename=filename,
            purpose=purpose,
            file_size=len(file_data),
        )
        
        if self._mock_mode:
            # Store in memory
            self._files[file_obj.id] = file_obj
            self._file_contents[file_obj.id] = file_data
        else:
            # TODO: Store in backend
            pass
        
        return file_obj.to_dict()
    
    def list_files(
        self,
        purpose: Optional[str] = None,
        limit: int = 10000,
        order: str = "desc",
        after: Optional[str] = None,
    ) -> Dict[str, Any]:
        """
        List uploaded files.
        
        Args:
            purpose: Filter by purpose
            limit: Maximum number of files to return
            order: Sort order (asc/desc by created_at)
            after: Cursor for pagination
        
        Returns:
            FileListResponse as dictionary
        """
        if self._mock_mode:
            files = list(self._files.values())
        else:
            # TODO: Fetch from backend
            files = []
        
        # Filter by purpose
        if purpose:
            files = [f for f in files if f.purpose == purpose]
        
        # Sort
        reverse = order == "desc"
        files.sort(key=lambda f: f.created_at, reverse=reverse)
        
        # Pagination
        if after:
            try:
                idx = next(i for i, f in enumerate(files) if f.id == after)
                files = files[idx + 1:]
            except StopIteration:
                pass
        
        # Limit
        has_more = len(files) > limit
        files = files[:limit]
        
        response = FileListResponse(data=files, has_more=has_more)
        return response.to_dict()
    
    def retrieve_file(self, file_id: str) -> Dict[str, Any]:
        """
        Retrieve a file's metadata.
        
        Args:
            file_id: File ID
        
        Returns:
            FileObject as dictionary
        """
        if self._mock_mode:
            file_obj = self._files.get(file_id)
        else:
            # TODO: Fetch from backend
            file_obj = None
        
        if not file_obj:
            return FileErrorResponse(
                message=f"No such File object: {file_id}",
                type="invalid_request_error",
                code="resource_not_found",
            ).to_dict()
        
        return file_obj.to_dict()
    
    def delete_file(self, file_id: str) -> Dict[str, Any]:
        """
        Delete a file.
        
        Args:
            file_id: File ID
        
        Returns:
            FileDeleteResponse as dictionary
        """
        if self._mock_mode:
            file_obj = self._files.pop(file_id, None)
            self._file_contents.pop(file_id, None)
        else:
            # TODO: Delete from backend
            file_obj = None
        
        if not file_obj:
            return FileErrorResponse(
                message=f"No such File object: {file_id}",
                type="invalid_request_error",
                code="resource_not_found",
            ).to_dict()
        
        return FileDeleteResponse(id=file_id).to_dict()
    
    def retrieve_file_content(self, file_id: str) -> Union[Dict[str, Any], FileContentResponse]:
        """
        Retrieve a file's content.
        
        Args:
            file_id: File ID
        
        Returns:
            FileContentResponse or error dict
        """
        if self._mock_mode:
            file_obj = self._files.get(file_id)
            content = self._file_contents.get(file_id)
        else:
            # TODO: Fetch from backend
            file_obj = None
            content = None
        
        if not file_obj or content is None:
            return FileErrorResponse(
                message=f"No such File object: {file_id}",
                type="invalid_request_error",
                code="resource_not_found",
            ).to_dict()
        
        return FileContentResponse(
            content=content,
            filename=file_obj.filename,
            content_type=get_content_type(file_obj.filename),
        )
    
    def handle_upload(
        self,
        form_data: Dict[str, Any],
        file_data: bytes,
        filename: str,
    ) -> Dict[str, Any]:
        """
        Handle file upload from HTTP form data.
        
        Args:
            form_data: Form field values
            file_data: Raw file bytes
            filename: Original filename
        
        Returns:
            Upload response
        """
        purpose = form_data.get("purpose", "fine-tune")
        
        try:
            return self.upload_file(file_data, filename, purpose)
        except Exception as e:
            logger.error(f"Upload error: {e}")
            return FileErrorResponse(
                message=str(e),
                type="server_error",
            ).to_dict()
    
    def get_file_stats(self) -> Dict[str, Any]:
        """Get statistics about stored files."""
        if self._mock_mode:
            files = list(self._files.values())
        else:
            files = []
        
        # Calculate stats
        by_purpose = {}
        total_bytes = 0
        
        for f in files:
            by_purpose[f.purpose] = by_purpose.get(f.purpose, 0) + 1
            total_bytes += f.bytes
        
        return {
            "total_files": len(files),
            "total_bytes": total_bytes,
            "by_purpose": by_purpose,
        }


# ========================================
# Utility Functions
# ========================================

def get_files_handler(storage_backend: Optional[Any] = None) -> FilesHandler:
    """Get a FilesHandler instance."""
    return FilesHandler(storage_backend=storage_backend)


def upload_file(
    file_data: bytes,
    filename: str,
    purpose: str = "fine-tune",
) -> Dict[str, Any]:
    """
    Convenience function for uploading a file.
    
    Args:
        file_data: File content
        filename: Filename
        purpose: File purpose
    
    Returns:
        File object response
    """
    handler = get_files_handler()
    return handler.upload_file(file_data, filename, purpose)


def list_files(purpose: Optional[str] = None) -> Dict[str, Any]:
    """
    Convenience function for listing files.
    
    Args:
        purpose: Optional purpose filter
    
    Returns:
        File list response
    """
    handler = get_files_handler()
    return handler.list_files(purpose=purpose)


def get_file(file_id: str) -> Dict[str, Any]:
    """
    Convenience function for retrieving a file.
    
    Args:
        file_id: File ID
    
    Returns:
        File object response
    """
    handler = get_files_handler()
    return handler.retrieve_file(file_id)


def delete_file(file_id: str) -> Dict[str, Any]:
    """
    Convenience function for deleting a file.
    
    Args:
        file_id: File ID
    
    Returns:
        Delete response
    """
    handler = get_files_handler()
    return handler.delete_file(file_id)


# ========================================
# Exports
# ========================================

__all__ = [
    # Enums
    "FilePurpose",
    "FileStatus",
    # Models
    "FileObject",
    "FileListResponse",
    "FileDeleteResponse",
    "FileContentResponse",
    "FileErrorResponse",
    # Handler
    "FilesHandler",
    # Utilities
    "get_files_handler",
    "upload_file",
    "list_files",
    "get_file",
    "delete_file",
    "validate_file",
    "validate_jsonl_content",
    "get_content_type",
    "get_file_extension",
    # Constants
    "SUPPORTED_PURPOSES",
    "ALLOWED_EXTENSIONS",
    "MAX_FILE_SIZES",
]