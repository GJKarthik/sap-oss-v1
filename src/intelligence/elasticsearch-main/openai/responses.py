"""
OpenAI-compatible Responses API

Day 31 Deliverable: Responses endpoint handler with input items

Implements:
- POST /v1/responses - Create response
- GET /v1/responses/{response_id} - Retrieve response
- DELETE /v1/responses/{response_id} - Delete response
- GET /v1/responses/{response_id}/input_items - List input items
"""

import time
import hashlib
from enum import Enum
from typing import Dict, Any, Optional, List, Union
from dataclasses import dataclass, field


# ========================================
# Constants
# ========================================

MAX_INPUT_ITEMS = 256
MAX_INSTRUCTIONS_LENGTH = 256000
MAX_CONTEXT_LENGTH = 1000000
DEFAULT_PAGE_SIZE = 20
MAX_PAGE_SIZE = 100


# ========================================
# Enums
# ========================================

class ResponseStatus(str, Enum):
    """Response statuses."""
    IN_PROGRESS = "in_progress"
    COMPLETED = "completed"
    INCOMPLETE = "incomplete"
    CANCELLED = "cancelled"
    FAILED = "failed"


class InputItemType(str, Enum):
    """Input item types."""
    MESSAGE = "message"
    ITEM_REFERENCE = "item_reference"
    FILE = "file"
    FUNCTION_CALL_OUTPUT = "function_call_output"


class MessageRole(str, Enum):
    """Message roles for input items."""
    USER = "user"
    ASSISTANT = "assistant"
    SYSTEM = "system"
    DEVELOPER = "developer"


class ContentType(str, Enum):
    """Content types for messages."""
    TEXT = "input_text"
    AUDIO = "input_audio"
    IMAGE = "input_image"


# ========================================
# Content Models
# ========================================

@dataclass
class TextContent:
    """Text content for input."""
    type: str = "input_text"
    text: str = ""
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {"type": self.type, "text": self.text}


@dataclass
class AudioContent:
    """Audio content for input."""
    type: str = "input_audio"
    data: str = ""  # base64
    format: str = "wav"
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {"type": self.type, "data": self.data, "format": self.format}


@dataclass
class ImageContent:
    """Image content for input."""
    type: str = "input_image"
    image_url: str = ""
    detail: str = "auto"
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {"type": self.type, "image_url": self.image_url, "detail": self.detail}


# ========================================
# Input Item Models
# ========================================

@dataclass
class MessageInputItem:
    """Message input item."""
    type: str = "message"
    id: str = ""
    role: str = "user"
    content: List[Dict[str, Any]] = field(default_factory=list)
    status: str = "completed"
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "type": self.type,
            "id": self.id,
            "role": self.role,
            "content": self.content,
            "status": self.status,
        }


@dataclass
class ItemReference:
    """Reference to a previous item."""
    type: str = "item_reference"
    id: str = ""
    item_id: str = ""
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {"type": self.type, "id": self.id, "item_id": self.item_id}


@dataclass
class FileInputItem:
    """File input item."""
    type: str = "file"
    id: str = ""
    file_id: str = ""
    filename: str = ""
    status: str = "completed"
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "type": self.type,
            "id": self.id,
            "file_id": self.file_id,
            "filename": self.filename,
            "status": self.status,
        }


@dataclass
class FunctionCallOutput:
    """Function call output input item."""
    type: str = "function_call_output"
    id: str = ""
    call_id: str = ""
    output: str = ""
    status: str = "completed"
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "type": self.type,
            "id": self.id,
            "call_id": self.call_id,
            "output": self.output,
            "status": self.status,
        }


# ========================================
# Request Models
# ========================================

@dataclass
class CreateResponseRequest:
    """Request to create a response."""
    model: str = "gpt-4o"
    input: List[Dict[str, Any]] = field(default_factory=list)
    instructions: Optional[str] = None
    modalities: List[str] = field(default_factory=lambda: ["text"])
    tools: Optional[List[Dict[str, Any]]] = None
    tool_choice: str = "auto"
    temperature: float = 1.0
    max_output_tokens: Optional[int] = None
    top_p: float = 1.0
    store: bool = True
    metadata: Optional[Dict[str, str]] = None
    previous_response_id: Optional[str] = None
    
    def validate(self) -> List[str]:
        """Validate the request."""
        errors = []
        if not self.model:
            errors.append("model is required")
        if len(self.input) > MAX_INPUT_ITEMS:
            errors.append(f"Maximum {MAX_INPUT_ITEMS} input items")
        if self.instructions and len(self.instructions) > MAX_INSTRUCTIONS_LENGTH:
            errors.append(f"Instructions exceed maximum length")
        if self.temperature < 0 or self.temperature > 2:
            errors.append("temperature must be between 0 and 2")
        return errors


# ========================================
# Response Models
# ========================================

@dataclass
class ResponseUsage:
    """Usage statistics for response."""
    input_tokens: int = 0
    output_tokens: int = 0
    total_tokens: int = 0
    
    def to_dict(self) -> Dict[str, int]:
        """Convert to dictionary."""
        return {
            "input_tokens": self.input_tokens,
            "output_tokens": self.output_tokens,
            "total_tokens": self.total_tokens,
        }


@dataclass
class ResponseError:
    """Error details for failed response."""
    code: str = ""
    message: str = ""
    
    def to_dict(self) -> Dict[str, str]:
        """Convert to dictionary."""
        return {"code": self.code, "message": self.message}


@dataclass
class ResponseObject:
    """Response object."""
    id: str
    object: str = "response"
    created_at: int = 0
    model: str = ""
    status: str = ResponseStatus.IN_PROGRESS.value
    status_details: Optional[Dict[str, Any]] = None
    output: List[Dict[str, Any]] = field(default_factory=list)
    usage: Optional[ResponseUsage] = None
    error: Optional[ResponseError] = None
    incomplete_details: Optional[Dict[str, Any]] = None
    instructions: Optional[str] = None
    max_output_tokens: Optional[int] = None
    modalities: List[str] = field(default_factory=lambda: ["text"])
    temperature: float = 1.0
    top_p: float = 1.0
    tools: Optional[List[Dict[str, Any]]] = None
    tool_choice: str = "auto"
    metadata: Dict[str, str] = field(default_factory=dict)
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "id": self.id,
            "object": self.object,
            "created_at": self.created_at,
            "model": self.model,
            "status": self.status,
            "status_details": self.status_details,
            "output": self.output,
            "usage": self.usage.to_dict() if self.usage else None,
            "error": self.error.to_dict() if self.error else None,
            "incomplete_details": self.incomplete_details,
            "instructions": self.instructions,
            "max_output_tokens": self.max_output_tokens,
            "modalities": self.modalities,
            "temperature": self.temperature,
            "top_p": self.top_p,
            "tools": self.tools,
            "tool_choice": self.tool_choice,
            "metadata": self.metadata,
        }


@dataclass
class InputItemListResponse:
    """Response for list input items."""
    object: str = "list"
    data: List[Dict[str, Any]] = field(default_factory=list)
    first_id: Optional[str] = None
    last_id: Optional[str] = None
    has_more: bool = False
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "object": self.object,
            "data": self.data,
            "first_id": self.first_id,
            "last_id": self.last_id,
            "has_more": self.has_more,
        }


@dataclass
class ResponseDeleteResult:
    """Response for delete operation."""
    id: str = ""
    object: str = "response.deleted"
    deleted: bool = True
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {"id": self.id, "object": self.object, "deleted": self.deleted}


@dataclass
class ResponseErrorResult:
    """Error response."""
    error: Dict[str, Any] = field(default_factory=dict)
    
    def __init__(self, message: str, type: str = "invalid_request_error", code: Optional[str] = None):
        self.error = {"message": message, "type": type}
        if code:
            self.error["code"] = code
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {"error": self.error}


# ========================================
# Responses Handler
# ========================================

class ResponsesHandler:
    """Handler for response operations."""
    
    def __init__(self, mock_mode: bool = True):
        """Initialize handler."""
        self.mock_mode = mock_mode
        self._responses: Dict[str, ResponseObject] = {}
        self._input_items: Dict[str, List[Dict[str, Any]]] = {}
    
    def _generate_id(self, prefix: str = "resp") -> str:
        """Generate response ID."""
        return f"{prefix}_{hashlib.md5(f'{time.time()}'.encode()).hexdigest()[:24]}"
    
    def _parse_input_items(self, input_list: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        """Parse and validate input items."""
        parsed = []
        for idx, item in enumerate(input_list):
            item_type = item.get("type", "message")
            item_id = self._generate_id("item")
            
            if item_type == "message":
                parsed_item = MessageInputItem(
                    id=item_id,
                    role=item.get("role", "user"),
                    content=item.get("content", []),
                ).to_dict()
            elif item_type == "item_reference":
                parsed_item = ItemReference(
                    id=item_id,
                    item_id=item.get("item_id", ""),
                ).to_dict()
            elif item_type == "file":
                parsed_item = FileInputItem(
                    id=item_id,
                    file_id=item.get("file_id", ""),
                    filename=item.get("filename", ""),
                ).to_dict()
            elif item_type == "function_call_output":
                parsed_item = FunctionCallOutput(
                    id=item_id,
                    call_id=item.get("call_id", ""),
                    output=item.get("output", ""),
                ).to_dict()
            else:
                parsed_item = {"type": item_type, "id": item_id, **item}
            
            parsed.append(parsed_item)
        
        return parsed
    
    def create(self, request: CreateResponseRequest) -> Dict[str, Any]:
        """Create a response."""
        errors = request.validate()
        if errors:
            return ResponseErrorResult("; ".join(errors)).to_dict()
        
        now = int(time.time())
        response_id = self._generate_id("resp")
        
        # Parse input items
        input_items = self._parse_input_items(request.input)
        self._input_items[response_id] = input_items
        
        response = ResponseObject(
            id=response_id,
            created_at=now,
            model=request.model,
            status=ResponseStatus.COMPLETED.value,
            instructions=request.instructions,
            max_output_tokens=request.max_output_tokens,
            modalities=request.modalities,
            temperature=request.temperature,
            top_p=request.top_p,
            tools=request.tools,
            tool_choice=request.tool_choice,
            metadata=request.metadata or {},
            usage=ResponseUsage(input_tokens=100, output_tokens=50, total_tokens=150),
            output=[{
                "type": "message",
                "id": self._generate_id("msg"),
                "role": "assistant",
                "content": [{"type": "output_text", "text": "Mock response"}],
                "status": "completed",
            }],
        )
        
        self._responses[response_id] = response
        return response.to_dict()
    
    def retrieve(self, response_id: str) -> Dict[str, Any]:
        """Retrieve a response."""
        if response_id not in self._responses:
            return ResponseErrorResult(
                f"No response found with id '{response_id}'",
                code="response_not_found"
            ).to_dict()
        
        return self._responses[response_id].to_dict()
    
    def delete(self, response_id: str) -> Dict[str, Any]:
        """Delete a response."""
        if response_id not in self._responses:
            return ResponseErrorResult(
                f"No response found with id '{response_id}'",
                code="response_not_found"
            ).to_dict()
        
        del self._responses[response_id]
        if response_id in self._input_items:
            del self._input_items[response_id]
        
        return ResponseDeleteResult(id=response_id).to_dict()
    
    def list_input_items(
        self,
        response_id: str,
        limit: int = DEFAULT_PAGE_SIZE,
        order: str = "asc",
        after: Optional[str] = None,
        before: Optional[str] = None,
    ) -> Dict[str, Any]:
        """List input items for a response."""
        if response_id not in self._responses:
            return ResponseErrorResult(
                f"No response found with id '{response_id}'",
                code="response_not_found"
            ).to_dict()
        
        items = self._input_items.get(response_id, [])
        
        # Sort
        if order == "desc":
            items = list(reversed(items))
        
        # Apply cursor pagination
        if after:
            found_idx = -1
            for i, item in enumerate(items):
                if item.get("id") == after:
                    found_idx = i
                    break
            if found_idx >= 0:
                items = items[found_idx + 1:]
        
        if before:
            found_idx = -1
            for i, item in enumerate(items):
                if item.get("id") == before:
                    found_idx = i
                    break
            if found_idx >= 0:
                items = items[:found_idx]
        
        # Apply limit
        limit = min(limit, MAX_PAGE_SIZE)
        has_more = len(items) > limit
        items = items[:limit]
        
        return InputItemListResponse(
            data=items,
            first_id=items[0]["id"] if items else None,
            last_id=items[-1]["id"] if items else None,
            has_more=has_more,
        ).to_dict()
    
    def cancel(self, response_id: str) -> Dict[str, Any]:
        """Cancel an in-progress response."""
        if response_id not in self._responses:
            return ResponseErrorResult(
                f"No response found with id '{response_id}'",
                code="response_not_found"
            ).to_dict()
        
        response = self._responses[response_id]
        if response.status != ResponseStatus.IN_PROGRESS.value:
            return ResponseErrorResult(
                "Only in-progress responses can be cancelled",
                code="invalid_response_status"
            ).to_dict()
        
        response.status = ResponseStatus.CANCELLED.value
        return response.to_dict()


# ========================================
# Factory and Utilities
# ========================================

def get_responses_handler(mock_mode: bool = True) -> ResponsesHandler:
    """Factory function for responses handler."""
    return ResponsesHandler(mock_mode=mock_mode)


def create_simple_response(model: str, messages: List[Dict[str, Any]]) -> Dict[str, Any]:
    """Helper to create a simple response."""
    handler = get_responses_handler()
    return handler.create(CreateResponseRequest(model=model, input=messages))


def is_response_complete(response: Dict[str, Any]) -> bool:
    """Check if response is complete."""
    return response.get("status") == ResponseStatus.COMPLETED.value


def is_response_terminal(status: str) -> bool:
    """Check if status is terminal."""
    return status in [
        ResponseStatus.COMPLETED.value,
        ResponseStatus.CANCELLED.value,
        ResponseStatus.FAILED.value,
    ]


def get_response_output(response: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Get response output items."""
    return response.get("output", [])


def count_input_items(response_id: str, handler: ResponsesHandler) -> int:
    """Count input items for a response."""
    return len(handler._input_items.get(response_id, []))


# ========================================
# Exports
# ========================================

__all__ = [
    # Constants
    "MAX_INPUT_ITEMS",
    "MAX_INSTRUCTIONS_LENGTH",
    "MAX_CONTEXT_LENGTH",
    "DEFAULT_PAGE_SIZE",
    "MAX_PAGE_SIZE",
    # Enums
    "ResponseStatus",
    "InputItemType",
    "MessageRole",
    "ContentType",
    # Content Models
    "TextContent",
    "AudioContent",
    "ImageContent",
    # Input Item Models
    "MessageInputItem",
    "ItemReference",
    "FileInputItem",
    "FunctionCallOutput",
    # Request/Response Models
    "CreateResponseRequest",
    "ResponseUsage",
    "ResponseError",
    "ResponseObject",
    "InputItemListResponse",
    "ResponseDeleteResult",
    "ResponseErrorResult",
    # Handler
    "ResponsesHandler",
    # Utilities
    "get_responses_handler",
    "create_simple_response",
    "is_response_complete",
    "is_response_terminal",
    "get_response_output",
    "count_input_items",
]