"""
OpenAI-compatible Messages API

Day 29 Deliverable: Messages endpoint handler for assistant threads

Implements:
- POST /v1/threads/{id}/messages - Create message
- GET /v1/threads/{id}/messages - List messages
- GET /v1/threads/{id}/messages/{message_id} - Retrieve message
- POST /v1/threads/{id}/messages/{message_id} - Modify message
- DELETE /v1/threads/{id}/messages/{message_id} - Delete message
"""

import time
import hashlib
from enum import Enum
from typing import Dict, Any, Optional, List, Union
from dataclasses import dataclass, field


# ========================================
# Constants
# ========================================

MAX_MESSAGES_PER_THREAD = 32768
DEFAULT_PAGE_SIZE = 20
MAX_PAGE_SIZE = 100
MAX_CONTENT_PARTS = 10
MAX_ATTACHMENTS = 10


# ========================================
# Enums
# ========================================

class MessageRole(str, Enum):
    """Message roles."""
    USER = "user"
    ASSISTANT = "assistant"


class MessageStatus(str, Enum):
    """Message statuses."""
    IN_PROGRESS = "in_progress"
    INCOMPLETE = "incomplete"
    COMPLETED = "completed"


class ContentType(str, Enum):
    """Content types."""
    TEXT = "text"
    IMAGE_FILE = "image_file"
    IMAGE_URL = "image_url"


class IncompleteReason(str, Enum):
    """Reasons for incomplete messages."""
    CONTENT_FILTER = "content_filter"
    MAX_TOKENS = "max_tokens"
    RUN_CANCELLED = "run_cancelled"
    RUN_EXPIRED = "run_expired"
    RUN_FAILED = "run_failed"


# ========================================
# Content Models
# ========================================

@dataclass
class TextContent:
    """Text content part."""
    type: str = "text"
    value: str = ""
    annotations: List[Dict[str, Any]] = field(default_factory=list)
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "type": self.type,
            "text": {
                "value": self.value,
                "annotations": self.annotations,
            }
        }


@dataclass
class ImageFileContent:
    """Image file content part."""
    type: str = "image_file"
    file_id: str = ""
    detail: str = "auto"
    
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
    """Image URL content part."""
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


# ========================================
# Attachment Model
# ========================================

@dataclass
class MessageAttachment:
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
# Incomplete Details Model
# ========================================

@dataclass
class IncompleteDetails:
    """Details about incomplete message."""
    reason: str = ""
    
    def to_dict(self) -> Dict[str, str]:
        """Convert to dictionary."""
        return {"reason": self.reason}


# ========================================
# Request Models
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
            errors.append(f"Invalid role: {self.role}")
        if not self.content:
            errors.append("content is required")
        if isinstance(self.content, list) and len(self.content) > MAX_CONTENT_PARTS:
            errors.append(f"Maximum {MAX_CONTENT_PARTS} content parts")
        if self.attachments and len(self.attachments) > MAX_ATTACHMENTS:
            errors.append(f"Maximum {MAX_ATTACHMENTS} attachments")
        return errors


@dataclass
class ModifyMessageRequest:
    """Request to modify a message."""
    metadata: Optional[Dict[str, str]] = None


# ========================================
# Response Models
# ========================================

@dataclass
class MessageObject:
    """Message object."""
    id: str
    object: str = "thread.message"
    created_at: int = 0
    thread_id: str = ""
    status: str = MessageStatus.COMPLETED.value
    incomplete_details: Optional[IncompleteDetails] = None
    completed_at: Optional[int] = None
    incomplete_at: Optional[int] = None
    role: str = "user"
    content: List[Dict[str, Any]] = field(default_factory=list)
    assistant_id: Optional[str] = None
    run_id: Optional[str] = None
    attachments: List[MessageAttachment] = field(default_factory=list)
    metadata: Dict[str, str] = field(default_factory=dict)
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {
            "id": self.id,
            "object": self.object,
            "created_at": self.created_at,
            "thread_id": self.thread_id,
            "status": self.status,
            "incomplete_details": self.incomplete_details.to_dict() if self.incomplete_details else None,
            "completed_at": self.completed_at,
            "incomplete_at": self.incomplete_at,
            "role": self.role,
            "content": self.content,
            "assistant_id": self.assistant_id,
            "run_id": self.run_id,
            "attachments": [a.to_dict() if hasattr(a, 'to_dict') else a for a in self.attachments],
            "metadata": self.metadata,
        }
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
    id: str = ""
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
class MessageErrorResponse:
    """Error response for message operations."""
    error: Dict[str, Any] = field(default_factory=dict)
    
    def __init__(self, message: str, type: str = "invalid_request_error", code: Optional[str] = None):
        self.error = {"message": message, "type": type}
        if code:
            self.error["code"] = code
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {"error": self.error}


# ========================================
# Messages Handler
# ========================================

class MessagesHandler:
    """Handler for message operations."""
    
    def __init__(self, mock_mode: bool = True):
        """Initialize handler."""
        self.mock_mode = mock_mode
        # Thread ID -> List[MessageObject]
        self._messages: Dict[str, List[MessageObject]] = {}
    
    def _generate_id(self) -> str:
        """Generate message ID."""
        return f"msg_{hashlib.md5(f'{time.time()}'.encode()).hexdigest()[:24]}"
    
    def _ensure_thread(self, thread_id: str) -> None:
        """Ensure thread exists in internal structure."""
        if thread_id not in self._messages:
            self._messages[thread_id] = []
    
    def _parse_content(self, content: Union[str, List[Dict[str, Any]]]) -> List[Dict[str, Any]]:
        """Parse content to standard format."""
        if isinstance(content, str):
            return [TextContent(value=content).to_dict()]
        return content
    
    def create(
        self,
        thread_id: str,
        request: CreateMessageRequest
    ) -> Dict[str, Any]:
        """Create a message in a thread."""
        errors = request.validate()
        if errors:
            return MessageErrorResponse("; ".join(errors)).to_dict()
        
        self._ensure_thread(thread_id)
        
        # Check message limit
        if len(self._messages[thread_id]) >= MAX_MESSAGES_PER_THREAD:
            return MessageErrorResponse(
                f"Thread has reached maximum of {MAX_MESSAGES_PER_THREAD} messages",
                code="messages_limit_exceeded"
            ).to_dict()
        
        now = int(time.time())
        
        # Parse attachments
        attachments = []
        if request.attachments:
            for att in request.attachments:
                attachments.append(MessageAttachment(
                    file_id=att.get("file_id", ""),
                    tools=att.get("tools", [])
                ))
        
        message = MessageObject(
            id=self._generate_id(),
            created_at=now,
            thread_id=thread_id,
            status=MessageStatus.COMPLETED.value,
            completed_at=now,
            role=request.role,
            content=self._parse_content(request.content),
            attachments=attachments,
            metadata=request.metadata or {},
        )
        
        self._messages[thread_id].append(message)
        return message.to_dict()
    
    def list(
        self,
        thread_id: str,
        limit: int = DEFAULT_PAGE_SIZE,
        order: str = "desc",
        after: Optional[str] = None,
        before: Optional[str] = None,
        run_id: Optional[str] = None,
    ) -> Dict[str, Any]:
        """List messages in a thread."""
        self._ensure_thread(thread_id)
        
        messages = list(self._messages[thread_id])
        
        # Filter by run_id
        if run_id:
            messages = [m for m in messages if m.run_id == run_id]
        
        # Sort by created_at
        messages = sorted(messages, key=lambda m: m.created_at, reverse=(order == "desc"))
        
        # Apply cursor pagination
        if after:
            found_idx = -1
            for i, m in enumerate(messages):
                if m.id == after:
                    found_idx = i
                    break
            if found_idx >= 0:
                messages = messages[found_idx + 1:]
        
        if before:
            found_idx = -1
            for i, m in enumerate(messages):
                if m.id == before:
                    found_idx = i
                    break
            if found_idx >= 0:
                messages = messages[:found_idx]
        
        # Apply limit
        limit = min(limit, MAX_PAGE_SIZE)
        has_more = len(messages) > limit
        messages = messages[:limit]
        
        return MessageListResponse(
            data=messages,
            first_id=messages[0].id if messages else None,
            last_id=messages[-1].id if messages else None,
            has_more=has_more,
        ).to_dict()
    
    def retrieve(
        self,
        thread_id: str,
        message_id: str
    ) -> Dict[str, Any]:
        """Retrieve a message."""
        self._ensure_thread(thread_id)
        
        for message in self._messages[thread_id]:
            if message.id == message_id:
                return message.to_dict()
        
        return MessageErrorResponse(
            f"No message found with id '{message_id}'",
            code="message_not_found"
        ).to_dict()
    
    def modify(
        self,
        thread_id: str,
        message_id: str,
        request: ModifyMessageRequest
    ) -> Dict[str, Any]:
        """Modify a message."""
        self._ensure_thread(thread_id)
        
        for message in self._messages[thread_id]:
            if message.id == message_id:
                if request.metadata:
                    message.metadata = request.metadata
                return message.to_dict()
        
        return MessageErrorResponse(
            f"No message found with id '{message_id}'",
            code="message_not_found"
        ).to_dict()
    
    def delete(
        self,
        thread_id: str,
        message_id: str
    ) -> Dict[str, Any]:
        """Delete a message."""
        self._ensure_thread(thread_id)
        
        for i, message in enumerate(self._messages[thread_id]):
            if message.id == message_id:
                del self._messages[thread_id][i]
                return MessageDeleteResponse(id=message_id).to_dict()
        
        return MessageErrorResponse(
            f"No message found with id '{message_id}'",
            code="message_not_found"
        ).to_dict()
    
    def add_assistant_message(
        self,
        thread_id: str,
        content: str,
        assistant_id: str,
        run_id: str
    ) -> Dict[str, Any]:
        """Add an assistant message (internal use)."""
        self._ensure_thread(thread_id)
        
        now = int(time.time())
        message = MessageObject(
            id=self._generate_id(),
            created_at=now,
            thread_id=thread_id,
            status=MessageStatus.COMPLETED.value,
            completed_at=now,
            role=MessageRole.ASSISTANT.value,
            content=[TextContent(value=content).to_dict()],
            assistant_id=assistant_id,
            run_id=run_id,
        )
        
        self._messages[thread_id].append(message)
        return message.to_dict()
    
    def get_message_count(self, thread_id: str) -> int:
        """Get message count for a thread."""
        self._ensure_thread(thread_id)
        return len(self._messages[thread_id])


# ========================================
# Factory and Utilities
# ========================================

def get_messages_handler(mock_mode: bool = True) -> MessagesHandler:
    """Factory function for messages handler."""
    return MessagesHandler(mock_mode=mock_mode)


def create_user_message(
    thread_id: str,
    content: str,
    attachments: Optional[List[Dict[str, Any]]] = None,
) -> Dict[str, Any]:
    """Helper to create a user message."""
    handler = get_messages_handler()
    return handler.create(
        thread_id,
        CreateMessageRequest(role="user", content=content, attachments=attachments)
    )


def extract_text_content(message: Dict[str, Any]) -> str:
    """Extract text from message content."""
    content = message.get("content", [])
    texts = []
    for part in content:
        if part.get("type") == "text":
            text_data = part.get("text", {})
            texts.append(text_data.get("value", ""))
    return "\n".join(texts)


def has_image_content(message: Dict[str, Any]) -> bool:
    """Check if message has image content."""
    content = message.get("content", [])
    for part in content:
        if part.get("type") in ["image_file", "image_url"]:
            return True
    return False


def is_user_message(message: Dict[str, Any]) -> bool:
    """Check if message is from user."""
    return message.get("role") == MessageRole.USER.value


def is_assistant_message(message: Dict[str, Any]) -> bool:
    """Check if message is from assistant."""
    return message.get("role") == MessageRole.ASSISTANT.value


def is_message_complete(message: Dict[str, Any]) -> bool:
    """Check if message is complete."""
    return message.get("status") == MessageStatus.COMPLETED.value


def get_message_attachments(message: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Get message attachments."""
    return message.get("attachments", [])


# ========================================
# Exports
# ========================================

__all__ = [
    # Constants
    "MAX_MESSAGES_PER_THREAD",
    "DEFAULT_PAGE_SIZE",
    "MAX_PAGE_SIZE",
    "MAX_CONTENT_PARTS",
    "MAX_ATTACHMENTS",
    # Enums
    "MessageRole",
    "MessageStatus",
    "ContentType",
    "IncompleteReason",
    # Content Models
    "TextContent",
    "ImageFileContent",
    "ImageUrlContent",
    # Models
    "MessageAttachment",
    "IncompleteDetails",
    "CreateMessageRequest",
    "ModifyMessageRequest",
    "MessageObject",
    "MessageListResponse",
    "MessageDeleteResponse",
    "MessageErrorResponse",
    # Handler
    "MessagesHandler",
    # Utilities
    "get_messages_handler",
    "create_user_message",
    "extract_text_content",
    "has_image_content",
    "is_user_message",
    "is_assistant_message",
    "is_message_complete",
    "get_message_attachments",
]