"""
OpenAI-compatible Threads and Messages API

Day 22 Deliverable: Conversation state management for Assistants

Implements:
- POST /v1/threads - Create thread
- GET /v1/threads/{thread_id} - Retrieve thread
- POST /v1/threads/{thread_id} - Modify thread
- DELETE /v1/threads/{thread_id} - Delete thread
- POST /v1/threads/{thread_id}/messages - Create message
- GET /v1/threads/{thread_id}/messages - List messages
- GET /v1/threads/{thread_id}/messages/{message_id} - Retrieve message
- POST /v1/threads/{thread_id}/messages/{message_id} - Modify message
- DELETE /v1/threads/{thread_id}/messages/{message_id} - Delete message
"""

import time
import hashlib
from enum import Enum
from typing import Dict, Any, Optional, List, Union
from dataclasses import dataclass, field


# ========================================
# Constants
# ========================================

MAX_THREAD_METADATA_PAIRS = 16
MAX_MESSAGE_CONTENT_LENGTH = 256000
MAX_MESSAGES_PER_THREAD = 10000


# ========================================
# Enums
# ========================================

class MessageRole(str, Enum):
    """Message roles."""
    USER = "user"
    ASSISTANT = "assistant"


class MessageContentType(str, Enum):
    """Message content types."""
    TEXT = "text"
    IMAGE_FILE = "image_file"
    IMAGE_URL = "image_url"


class MessageStatus(str, Enum):
    """Message status."""
    IN_PROGRESS = "in_progress"
    INCOMPLETE = "incomplete"
    COMPLETED = "completed"


# ========================================
# Content Types
# ========================================

@dataclass
class TextContent:
    """Text content block."""
    type: str = "text"
    text: str = ""
    annotations: List[Dict[str, Any]] = field(default_factory=list)
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "type": self.type,
            "text": {
                "value": self.text,
                "annotations": self.annotations,
            }
        }


@dataclass
class ImageFileContent:
    """Image file content block."""
    type: str = "image_file"
    file_id: str = ""
    detail: str = "auto"  # auto, low, high
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "type": self.type,
            "image_file": {
                "file_id": self.file_id,
                "detail": self.detail,
            }
        }


@dataclass
class ImageUrlContent:
    """Image URL content block."""
    type: str = "image_url"
    url: str = ""
    detail: str = "auto"
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "type": self.type,
            "image_url": {
                "url": self.url,
                "detail": self.detail,
            }
        }


@dataclass
class Attachment:
    """Message attachment."""
    file_id: str = ""
    tools: List[Dict[str, str]] = field(default_factory=list)
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "file_id": self.file_id,
            "tools": self.tools,
        }


# ========================================
# Thread Models
# ========================================

@dataclass
class CreateThreadRequest:
    """Request to create a thread."""
    messages: Optional[List[Dict[str, Any]]] = None
    tool_resources: Optional[Dict[str, Any]] = None
    metadata: Optional[Dict[str, str]] = None
    
    def validate(self) -> List[str]:
        """Validate the request."""
        errors = []
        
        if self.metadata and len(self.metadata) > MAX_THREAD_METADATA_PAIRS:
            errors.append(f"metadata cannot have more than {MAX_THREAD_METADATA_PAIRS} pairs")
        
        if self.messages:
            for i, msg in enumerate(self.messages):
                if "role" not in msg:
                    errors.append(f"messages[{i}].role is required")
                elif msg.get("role") not in [r.value for r in MessageRole]:
                    errors.append(f"messages[{i}].role must be 'user' or 'assistant'")
                if "content" not in msg:
                    errors.append(f"messages[{i}].content is required")
        
        return errors


@dataclass
class ModifyThreadRequest:
    """Request to modify a thread."""
    tool_resources: Optional[Dict[str, Any]] = None
    metadata: Optional[Dict[str, str]] = None
    
    def validate(self) -> List[str]:
        """Validate the request."""
        errors = []
        if self.metadata and len(self.metadata) > MAX_THREAD_METADATA_PAIRS:
            errors.append(f"metadata cannot have more than {MAX_THREAD_METADATA_PAIRS} pairs")
        return errors


@dataclass
class ThreadObject:
    """Thread object response."""
    id: str
    object: str = "thread"
    created_at: int = 0
    tool_resources: Optional[Dict[str, Any]] = None
    metadata: Optional[Dict[str, str]] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {
            "id": self.id,
            "object": self.object,
            "created_at": self.created_at,
        }
        if self.tool_resources is not None:
            result["tool_resources"] = self.tool_resources
        if self.metadata is not None:
            result["metadata"] = self.metadata
        return result


@dataclass
class ThreadDeleteResponse:
    """Response for delete thread."""
    id: str
    object: str = "thread.deleted"
    deleted: bool = True
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "id": self.id,
            "object": self.object,
            "deleted": self.deleted,
        }


# ========================================
# Message Models
# ========================================

@dataclass
class CreateMessageRequest:
    """Request to create a message."""
    role: str = "user"
    content: Union[str, List[Dict[str, Any]]] = ""
    attachments: Optional[List[Dict[str, Any]]] = None
    metadata: Optional[Dict[str, str]] = None
    
    def validate(self) -> List[str]:
        """Validate the request."""
        errors = []
        
        if self.role not in [r.value for r in MessageRole]:
            errors.append("role must be 'user' or 'assistant'")
        
        if not self.content:
            errors.append("content is required")
        elif isinstance(self.content, str) and len(self.content) > MAX_MESSAGE_CONTENT_LENGTH:
            errors.append(f"content must be {MAX_MESSAGE_CONTENT_LENGTH} characters or less")
        
        return errors


@dataclass
class ModifyMessageRequest:
    """Request to modify a message."""
    metadata: Optional[Dict[str, str]] = None
    
    def validate(self) -> List[str]:
        """Validate the request."""
        return []


@dataclass
class MessageObject:
    """Message object response."""
    id: str
    thread_id: str
    object: str = "thread.message"
    created_at: int = 0
    role: str = "user"
    content: List[Dict[str, Any]] = field(default_factory=list)
    assistant_id: Optional[str] = None
    run_id: Optional[str] = None
    attachments: List[Dict[str, Any]] = field(default_factory=list)
    metadata: Optional[Dict[str, str]] = None
    status: str = "completed"
    incomplete_details: Optional[Dict[str, Any]] = None
    completed_at: Optional[int] = None
    incomplete_at: Optional[int] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {
            "id": self.id,
            "object": self.object,
            "created_at": self.created_at,
            "thread_id": self.thread_id,
            "role": self.role,
            "content": self.content,
            "attachments": self.attachments,
            "status": self.status,
        }
        if self.assistant_id:
            result["assistant_id"] = self.assistant_id
        if self.run_id:
            result["run_id"] = self.run_id
        if self.metadata:
            result["metadata"] = self.metadata
        if self.incomplete_details:
            result["incomplete_details"] = self.incomplete_details
        if self.completed_at:
            result["completed_at"] = self.completed_at
        if self.incomplete_at:
            result["incomplete_at"] = self.incomplete_at
        return result


@dataclass
class MessageListResponse:
    """Response for list messages."""
    object: str = "list"
    data: List[MessageObject] = field(default_factory=list)
    first_id: Optional[str] = None
    last_id: Optional[str] = None
    has_more: bool = False
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "object": self.object,
            "data": [m.to_dict() for m in self.data],
            "first_id": self.first_id,
            "last_id": self.last_id,
            "has_more": self.has_more,
        }


@dataclass
class MessageDeleteResponse:
    """Response for delete message."""
    id: str
    object: str = "thread.message.deleted"
    deleted: bool = True
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "id": self.id,
            "object": self.object,
            "deleted": self.deleted,
        }


@dataclass
class ThreadsErrorResponse:
    """Error response for thread/message operations."""
    error: Dict[str, Any] = field(default_factory=dict)
    
    def __init__(self, message: str, type: str = "invalid_request_error", code: Optional[str] = None):
        self.error = {"message": message, "type": type}
        if code:
            self.error["code"] = code
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {"error": self.error}


# ========================================
# Threads Handler
# ========================================

class ThreadsHandler:
    """Handler for thread and message operations."""
    
    def __init__(self, mock_mode: bool = True):
        """Initialize handler."""
        self.mock_mode = mock_mode
        self._threads: Dict[str, ThreadObject] = {}
        self._messages: Dict[str, Dict[str, MessageObject]] = {}  # thread_id -> {message_id -> message}
    
    # Thread operations
    def create_thread(self, request: CreateThreadRequest) -> Dict[str, Any]:
        """Create a new thread."""
        errors = request.validate()
        if errors:
            return ThreadsErrorResponse("; ".join(errors)).to_dict()
        
        thread_id = f"thread_{hashlib.md5(f'{time.time()}'.encode()).hexdigest()[:24]}"
        now = int(time.time())
        
        thread = ThreadObject(
            id=thread_id,
            created_at=now,
            tool_resources=request.tool_resources,
            metadata=request.metadata,
        )
        
        self._threads[thread_id] = thread
        self._messages[thread_id] = {}
        
        # Create initial messages if provided
        if request.messages:
            for msg in request.messages:
                msg_request = CreateMessageRequest(
                    role=msg.get("role", "user"),
                    content=msg.get("content", ""),
                    attachments=msg.get("attachments"),
                    metadata=msg.get("metadata"),
                )
                self.create_message(thread_id, msg_request)
        
        return thread.to_dict()
    
    def retrieve_thread(self, thread_id: str) -> Dict[str, Any]:
        """Retrieve a thread."""
        if thread_id not in self._threads:
            return ThreadsErrorResponse(
                f"No thread found with id '{thread_id}'",
                code="thread_not_found"
            ).to_dict()
        return self._threads[thread_id].to_dict()
    
    def modify_thread(self, thread_id: str, request: ModifyThreadRequest) -> Dict[str, Any]:
        """Modify a thread."""
        if thread_id not in self._threads:
            return ThreadsErrorResponse(
                f"No thread found with id '{thread_id}'",
                code="thread_not_found"
            ).to_dict()
        
        errors = request.validate()
        if errors:
            return ThreadsErrorResponse("; ".join(errors)).to_dict()
        
        thread = self._threads[thread_id]
        
        if request.tool_resources is not None:
            thread.tool_resources = request.tool_resources
        if request.metadata is not None:
            thread.metadata = request.metadata
        
        return thread.to_dict()
    
    def delete_thread(self, thread_id: str) -> Dict[str, Any]:
        """Delete a thread."""
        if thread_id not in self._threads:
            return ThreadsErrorResponse(
                f"No thread found with id '{thread_id}'",
                code="thread_not_found"
            ).to_dict()
        
        del self._threads[thread_id]
        if thread_id in self._messages:
            del self._messages[thread_id]
        
        return ThreadDeleteResponse(id=thread_id).to_dict()
    
    # Message operations
    def create_message(self, thread_id: str, request: CreateMessageRequest) -> Dict[str, Any]:
        """Create a message in a thread."""
        if thread_id not in self._threads:
            return ThreadsErrorResponse(
                f"No thread found with id '{thread_id}'",
                code="thread_not_found"
            ).to_dict()
        
        errors = request.validate()
        if errors:
            return ThreadsErrorResponse("; ".join(errors)).to_dict()
        
        message_id = f"msg_{hashlib.md5(f'{time.time()}'.encode()).hexdigest()[:24]}"
        now = int(time.time())
        
        # Process content
        if isinstance(request.content, str):
            content = [{"type": "text", "text": {"value": request.content, "annotations": []}}]
        else:
            content = request.content
        
        message = MessageObject(
            id=message_id,
            thread_id=thread_id,
            created_at=now,
            role=request.role,
            content=content,
            attachments=request.attachments or [],
            metadata=request.metadata,
            completed_at=now,
        )
        
        self._messages[thread_id][message_id] = message
        return message.to_dict()
    
    def list_messages(
        self,
        thread_id: str,
        limit: int = 20,
        order: str = "desc",
        after: Optional[str] = None,
        before: Optional[str] = None,
        run_id: Optional[str] = None,
    ) -> Dict[str, Any]:
        """List messages in a thread."""
        if thread_id not in self._threads:
            return ThreadsErrorResponse(
                f"No thread found with id '{thread_id}'",
                code="thread_not_found"
            ).to_dict()
        
        messages = list(self._messages.get(thread_id, {}).values())
        
        # Filter by run_id if provided
        if run_id:
            messages = [m for m in messages if m.run_id == run_id]
        
        # Sort
        messages = sorted(messages, key=lambda m: m.created_at, reverse=(order == "desc"))
        
        # Apply cursor pagination
        if after:
            found_idx = -1
            for i, msg in enumerate(messages):
                if msg.id == after:
                    found_idx = i
                    break
            if found_idx >= 0:
                messages = messages[found_idx + 1:]
        
        if before:
            found_idx = -1
            for i, msg in enumerate(messages):
                if msg.id == before:
                    found_idx = i
                    break
            if found_idx >= 0:
                messages = messages[:found_idx]
        
        has_more = len(messages) > limit
        messages = messages[:limit]
        
        return MessageListResponse(
            data=messages,
            first_id=messages[0].id if messages else None,
            last_id=messages[-1].id if messages else None,
            has_more=has_more,
        ).to_dict()
    
    def retrieve_message(self, thread_id: str, message_id: str) -> Dict[str, Any]:
        """Retrieve a message."""
        if thread_id not in self._threads:
            return ThreadsErrorResponse(
                f"No thread found with id '{thread_id}'",
                code="thread_not_found"
            ).to_dict()
        
        if message_id not in self._messages.get(thread_id, {}):
            return ThreadsErrorResponse(
                f"No message found with id '{message_id}'",
                code="message_not_found"
            ).to_dict()
        
        return self._messages[thread_id][message_id].to_dict()
    
    def modify_message(
        self,
        thread_id: str,
        message_id: str,
        request: ModifyMessageRequest,
    ) -> Dict[str, Any]:
        """Modify a message."""
        if thread_id not in self._threads:
            return ThreadsErrorResponse(
                f"No thread found with id '{thread_id}'",
                code="thread_not_found"
            ).to_dict()
        
        if message_id not in self._messages.get(thread_id, {}):
            return ThreadsErrorResponse(
                f"No message found with id '{message_id}'",
                code="message_not_found"
            ).to_dict()
        
        message = self._messages[thread_id][message_id]
        
        if request.metadata is not None:
            message.metadata = request.metadata
        
        return message.to_dict()
    
    def delete_message(self, thread_id: str, message_id: str) -> Dict[str, Any]:
        """Delete a message."""
        if thread_id not in self._threads:
            return ThreadsErrorResponse(
                f"No thread found with id '{thread_id}'",
                code="thread_not_found"
            ).to_dict()
        
        if message_id not in self._messages.get(thread_id, {}):
            return ThreadsErrorResponse(
                f"No message found with id '{message_id}'",
                code="message_not_found"
            ).to_dict()
        
        del self._messages[thread_id][message_id]
        return MessageDeleteResponse(id=message_id).to_dict()
    
    def get_thread_message_count(self, thread_id: str) -> int:
        """Get message count for a thread."""
        return len(self._messages.get(thread_id, {}))


# ========================================
# Factory and Utilities
# ========================================

def get_threads_handler(mock_mode: bool = True) -> ThreadsHandler:
    """Factory function to create threads handler."""
    return ThreadsHandler(mock_mode=mock_mode)


def create_thread(
    messages: Optional[List[Dict[str, Any]]] = None,
    metadata: Optional[Dict[str, str]] = None,
) -> Dict[str, Any]:
    """Convenience function to create a thread."""
    handler = get_threads_handler()
    request = CreateThreadRequest(messages=messages, metadata=metadata)
    return handler.create_thread(request)


def create_message(
    thread_id: str,
    content: str,
    role: str = "user",
    metadata: Optional[Dict[str, str]] = None,
) -> Dict[str, Any]:
    """Convenience function to create a message."""
    handler = get_threads_handler()
    request = CreateMessageRequest(role=role, content=content, metadata=metadata)
    return handler.create_message(thread_id, request)


def create_text_content(text: str) -> Dict[str, Any]:
    """Create text content block."""
    return TextContent(text=text).to_dict()


def create_image_file_content(file_id: str, detail: str = "auto") -> Dict[str, Any]:
    """Create image file content block."""
    return ImageFileContent(file_id=file_id, detail=detail).to_dict()


def create_image_url_content(url: str, detail: str = "auto") -> Dict[str, Any]:
    """Create image URL content block."""
    return ImageUrlContent(url=url, detail=detail).to_dict()


def create_attachment(file_id: str, tools: Optional[List[str]] = None) -> Dict[str, Any]:
    """Create attachment object."""
    tool_list = [{"type": t} for t in (tools or [])]
    return Attachment(file_id=file_id, tools=tool_list).to_dict()


def extract_text_from_message(message: Dict[str, Any]) -> str:
    """Extract text content from a message object."""
    content = message.get("content", [])
    texts = []
    for block in content:
        if block.get("type") == "text":
            text_obj = block.get("text", {})
            if isinstance(text_obj, dict):
                texts.append(text_obj.get("value", ""))
            else:
                texts.append(str(text_obj))
    return "\n".join(texts)


def is_user_message(message: Dict[str, Any]) -> bool:
    """Check if message is from user."""
    return message.get("role") == "user"


def is_assistant_message(message: Dict[str, Any]) -> bool:
    """Check if message is from assistant."""
    return message.get("role") == "assistant"


# ========================================
# Exports
# ========================================

__all__ = [
    # Constants
    "MAX_THREAD_METADATA_PAIRS",
    "MAX_MESSAGE_CONTENT_LENGTH",
    "MAX_MESSAGES_PER_THREAD",
    # Enums
    "MessageRole",
    "MessageContentType",
    "MessageStatus",
    # Content types
    "TextContent",
    "ImageFileContent",
    "ImageUrlContent",
    "Attachment",
    # Thread models
    "CreateThreadRequest",
    "ModifyThreadRequest",
    "ThreadObject",
    "ThreadDeleteResponse",
    # Message models
    "CreateMessageRequest",
    "ModifyMessageRequest",
    "MessageObject",
    "MessageListResponse",
    "MessageDeleteResponse",
    "ThreadsErrorResponse",
    # Handler
    "ThreadsHandler",
    # Utilities
    "get_threads_handler",
    "create_thread",
    "create_message",
    "create_text_content",
    "create_image_file_content",
    "create_image_url_content",
    "create_attachment",
    "extract_text_from_message",
    "is_user_message",
    "is_assistant_message",
]