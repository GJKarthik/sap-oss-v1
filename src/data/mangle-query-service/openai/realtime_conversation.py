"""
OpenAI Realtime API Conversation Management

Day 39: Conversation items, turn management, and response handling
"""

from dataclasses import dataclass, field
from enum import Enum
from typing import Optional, Any, Callable
import json
import time
import uuid


# ========================================
# Constants
# ========================================

MAX_CONVERSATION_ITEMS = 100
MAX_ITEM_CONTENT_LENGTH = 100 * 1024  # 100KB
MAX_FUNCTION_ARGUMENTS_LENGTH = 128 * 1024  # 128KB
DEFAULT_MAX_RESPONSE_TOKENS = 4096
CONVERSATION_TIMEOUT_SECONDS = 3600  # 1 hour


# ========================================
# Enums
# ========================================

class ItemType(Enum):
    """Conversation item types."""
    MESSAGE = "message"
    FUNCTION_CALL = "function_call"
    FUNCTION_CALL_OUTPUT = "function_call_output"


class ItemRole(Enum):
    """Message roles."""
    USER = "user"
    ASSISTANT = "assistant"
    SYSTEM = "system"


class ItemStatus(Enum):
    """Item processing status."""
    PENDING = "pending"
    IN_PROGRESS = "in_progress"
    COMPLETED = "completed"
    INCOMPLETE = "incomplete"
    CANCELLED = "cancelled"
    FAILED = "failed"


class ContentType(Enum):
    """Content types."""
    INPUT_TEXT = "input_text"
    INPUT_AUDIO = "input_audio"
    TEXT = "text"
    AUDIO = "audio"


class TurnDetectionMode(Enum):
    """Turn detection modes."""
    SERVER_VAD = "server_vad"
    NONE = "none"


# ========================================
# Models
# ========================================

@dataclass
class ContentPart:
    """Content part within an item."""
    type: str
    text: Optional[str] = None
    audio: Optional[str] = None  # base64
    transcript: Optional[str] = None
    
    def to_dict(self) -> dict:
        result = {"type": self.type}
        if self.text:
            result["text"] = self.text
        if self.audio:
            result["audio"] = self.audio
        if self.transcript:
            result["transcript"] = self.transcript
        return result
    
    @classmethod
    def from_dict(cls, data: dict) -> "ContentPart":
        return cls(
            type=data.get("type", "text"),
            text=data.get("text"),
            audio=data.get("audio"),
            transcript=data.get("transcript"),
        )


@dataclass
class ConversationItem:
    """A conversation item."""
    id: str = field(default_factory=lambda: f"item_{uuid.uuid4().hex[:16]}")
    type: str = "message"
    role: Optional[str] = None
    status: str = "completed"
    content: list[ContentPart] = field(default_factory=list)
    call_id: Optional[str] = None
    name: Optional[str] = None
    arguments: Optional[str] = None
    output: Optional[str] = None
    created_at: float = field(default_factory=time.time)
    
    def to_dict(self) -> dict:
        result = {
            "id": self.id,
            "type": self.type,
            "status": self.status,
        }
        if self.role:
            result["role"] = self.role
        if self.content:
            result["content"] = [c.to_dict() for c in self.content]
        if self.call_id:
            result["call_id"] = self.call_id
        if self.name:
            result["name"] = self.name
        if self.arguments:
            result["arguments"] = self.arguments
        if self.output:
            result["output"] = self.output
        return result
    
    @classmethod
    def from_dict(cls, data: dict) -> "ConversationItem":
        content = [ContentPart.from_dict(c) for c in data.get("content", [])]
        return cls(
            id=data.get("id", f"item_{uuid.uuid4().hex[:16]}"),
            type=data.get("type", "message"),
            role=data.get("role"),
            status=data.get("status", "completed"),
            content=content,
            call_id=data.get("call_id"),
            name=data.get("name"),
            arguments=data.get("arguments"),
            output=data.get("output"),
        )


@dataclass
class ResponseConfig:
    """Response generation configuration."""
    modalities: list[str] = field(default_factory=lambda: ["text", "audio"])
    instructions: Optional[str] = None
    voice: str = "alloy"
    output_audio_format: str = "pcm16"
    tools: list[dict] = field(default_factory=list)
    tool_choice: str = "auto"
    temperature: float = 0.8
    max_response_output_tokens: int = DEFAULT_MAX_RESPONSE_TOKENS
    
    def to_dict(self) -> dict:
        return {
            "modalities": self.modalities,
            "instructions": self.instructions,
            "voice": self.voice,
            "output_audio_format": self.output_audio_format,
            "tools": self.tools,
            "tool_choice": self.tool_choice,
            "temperature": self.temperature,
            "max_response_output_tokens": self.max_response_output_tokens,
        }


@dataclass
class ConversationStats:
    """Conversation statistics."""
    item_count: int = 0
    user_messages: int = 0
    assistant_messages: int = 0
    function_calls: int = 0
    total_input_tokens: int = 0
    total_output_tokens: int = 0
    
    def to_dict(self) -> dict:
        return {
            "item_count": self.item_count,
            "user_messages": self.user_messages,
            "assistant_messages": self.assistant_messages,
            "function_calls": self.function_calls,
            "total_input_tokens": self.total_input_tokens,
            "total_output_tokens": self.total_output_tokens,
        }


# ========================================
# Conversation Manager
# ========================================

class Conversation:
    """Manage conversation state."""
    
    def __init__(self, conversation_id: Optional[str] = None):
        self.id = conversation_id or f"conv_{uuid.uuid4().hex[:16]}"
        self._items: dict[str, ConversationItem] = {}
        self._item_order: list[str] = []
        self._stats = ConversationStats()
        self._created_at = time.time()
        self._updated_at = time.time()
    
    def add_item(self, item: ConversationItem, previous_item_id: Optional[str] = None) -> bool:
        """Add item to conversation."""
        if len(self._items) >= MAX_CONVERSATION_ITEMS:
            return False
        
        self._items[item.id] = item
        
        if previous_item_id and previous_item_id in self._items:
            idx = self._item_order.index(previous_item_id) + 1
            self._item_order.insert(idx, item.id)
        else:
            self._item_order.append(item.id)
        
        self._update_stats(item, added=True)
        self._updated_at = time.time()
        return True
    
    def get_item(self, item_id: str) -> Optional[ConversationItem]:
        """Get item by ID."""
        return self._items.get(item_id)
    
    def remove_item(self, item_id: str) -> bool:
        """Remove item from conversation."""
        if item_id not in self._items:
            return False
        
        item = self._items.pop(item_id)
        self._item_order.remove(item_id)
        self._update_stats(item, added=False)
        self._updated_at = time.time()
        return True
    
    def truncate(self, item_id: str) -> int:
        """Truncate conversation after item."""
        if item_id not in self._items:
            return 0
        
        idx = self._item_order.index(item_id)
        to_remove = self._item_order[idx + 1:]
        
        for id in to_remove:
            item = self._items.pop(id)
            self._update_stats(item, added=False)
        
        self._item_order = self._item_order[:idx + 1]
        self._updated_at = time.time()
        return len(to_remove)
    
    def clear(self) -> None:
        """Clear all items."""
        self._items.clear()
        self._item_order.clear()
        self._stats = ConversationStats()
        self._updated_at = time.time()
    
    def _update_stats(self, item: ConversationItem, added: bool) -> None:
        """Update conversation statistics."""
        delta = 1 if added else -1
        self._stats.item_count += delta
        
        if item.type == "message":
            if item.role == "user":
                self._stats.user_messages += delta
            elif item.role == "assistant":
                self._stats.assistant_messages += delta
        elif item.type == "function_call":
            self._stats.function_calls += delta
    
    def get_items(self) -> list[ConversationItem]:
        """Get all items in order."""
        return [self._items[id] for id in self._item_order]
    
    def get_stats(self) -> ConversationStats:
        return self._stats
    
    def get_item_count(self) -> int:
        return len(self._items)
    
    def is_empty(self) -> bool:
        return len(self._items) == 0
    
    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "items": [self._items[id].to_dict() for id in self._item_order],
            "stats": self._stats.to_dict(),
            "created_at": self._created_at,
            "updated_at": self._updated_at,
        }


# ========================================
# Response Handler
# ========================================

class ResponseHandler:
    """Handle response generation and streaming."""
    
    def __init__(self, response_id: Optional[str] = None):
        self.id = response_id or f"resp_{uuid.uuid4().hex[:16]}"
        self._status = "in_progress"
        self._output_items: list[ConversationItem] = []
        self._created_at = time.time()
        self._completed_at: Optional[float] = None
        self._usage = {"input_tokens": 0, "output_tokens": 0}
        self._callbacks: dict[str, list[Callable]] = {
            "item_created": [],
            "item_done": [],
            "audio_delta": [],
            "text_delta": [],
            "done": [],
        }
    
    def add_output_item(self, item: ConversationItem) -> None:
        """Add output item to response."""
        self._output_items.append(item)
        self._trigger_callback("item_created", item)
    
    def complete_item(self, item_id: str) -> bool:
        """Mark item as complete."""
        for item in self._output_items:
            if item.id == item_id:
                item.status = "completed"
                self._trigger_callback("item_done", item)
                return True
        return False
    
    def complete(self, usage: Optional[dict] = None) -> None:
        """Complete the response."""
        self._status = "completed"
        self._completed_at = time.time()
        if usage:
            self._usage = usage
        self._trigger_callback("done", self)
    
    def cancel(self) -> None:
        """Cancel the response."""
        self._status = "cancelled"
        self._completed_at = time.time()
    
    def fail(self, error: str) -> None:
        """Mark response as failed."""
        self._status = "failed"
        self._completed_at = time.time()
    
    def _trigger_callback(self, event: str, data: Any) -> None:
        """Trigger registered callbacks."""
        for callback in self._callbacks.get(event, []):
            try:
                callback(data)
            except Exception:
                pass
    
    def on(self, event: str, callback: Callable) -> None:
        """Register event callback."""
        if event in self._callbacks:
            self._callbacks[event].append(callback)
    
    def get_status(self) -> str:
        return self._status
    
    def get_output_items(self) -> list[ConversationItem]:
        return self._output_items.copy()
    
    def get_usage(self) -> dict:
        return self._usage.copy()
    
    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "status": self._status,
            "output": [i.to_dict() for i in self._output_items],
            "usage": self._usage,
            "created_at": self._created_at,
            "completed_at": self._completed_at,
        }


# ========================================
# Turn Manager
# ========================================

class TurnManager:
    """Manage conversation turns."""
    
    def __init__(self, mode: str = "server_vad"):
        self.mode = mode
        self._current_turn: Optional[str] = None
        self._pending_response: Optional[ResponseHandler] = None
        self._turn_history: list[dict] = []
    
    def start_turn(self, role: str) -> str:
        """Start a new turn."""
        turn_id = f"turn_{uuid.uuid4().hex[:12]}"
        self._current_turn = turn_id
        self._turn_history.append({
            "id": turn_id,
            "role": role,
            "started_at": time.time(),
            "ended_at": None,
        })
        return turn_id
    
    def end_turn(self) -> Optional[str]:
        """End current turn."""
        if not self._current_turn:
            return None
        
        for turn in self._turn_history:
            if turn["id"] == self._current_turn:
                turn["ended_at"] = time.time()
                break
        
        turn_id = self._current_turn
        self._current_turn = None
        return turn_id
    
    def get_current_turn(self) -> Optional[str]:
        return self._current_turn
    
    def is_in_turn(self) -> bool:
        return self._current_turn is not None
    
    def set_pending_response(self, response: ResponseHandler) -> None:
        self._pending_response = response
    
    def get_pending_response(self) -> Optional[ResponseHandler]:
        return self._pending_response
    
    def clear_pending_response(self) -> None:
        self._pending_response = None
    
    def get_turn_count(self) -> int:
        return len(self._turn_history)


# ========================================
# Factory
# ========================================

_conversations: dict[str, Conversation] = {}


def get_conversation(session_id: str) -> Conversation:
    """Get or create conversation for session."""
    if session_id not in _conversations:
        _conversations[session_id] = Conversation(session_id)
    return _conversations[session_id]


def remove_conversation(session_id: str) -> bool:
    """Remove conversation."""
    if session_id in _conversations:
        del _conversations[session_id]
        return True
    return False


def reset_conversations() -> None:
    """Clear all conversations."""
    global _conversations
    _conversations = {}


# ========================================
# Utilities
# ========================================

def create_user_message(text: str) -> ConversationItem:
    """Create a user text message."""
    return ConversationItem(
        type="message",
        role="user",
        content=[ContentPart(type="input_text", text=text)],
    )


def create_assistant_message(text: str) -> ConversationItem:
    """Create an assistant text message."""
    return ConversationItem(
        type="message",
        role="assistant",
        content=[ContentPart(type="text", text=text)],
    )


def create_function_call(name: str, call_id: str, arguments: str) -> ConversationItem:
    """Create a function call item."""
    return ConversationItem(
        type="function_call",
        call_id=call_id,
        name=name,
        arguments=arguments,
    )


def create_function_output(call_id: str, output: str) -> ConversationItem:
    """Create a function call output item."""
    return ConversationItem(
        type="function_call_output",
        call_id=call_id,
        output=output,
    )