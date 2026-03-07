"""
OpenAI Realtime API Foundation

Day 36: Realtime API session, events, and models
"""

from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Optional
import time
import uuid


# ========================================
# Constants
# ========================================

DEFAULT_SESSION_TIMEOUT = 1800  # 30 minutes
MAX_SESSIONS_PER_USER = 5
HEARTBEAT_INTERVAL = 30  # seconds
MAX_CONVERSATION_ITEMS = 128


# ========================================
# Enums
# ========================================

class SessionStatus(Enum):
    """Session status values."""
    CREATED = "created"
    ACTIVE = "active"
    EXPIRED = "expired"
    CLOSED = "closed"


class EventType(Enum):
    """Realtime event types."""
    # Client events
    SESSION_UPDATE = "session.update"
    INPUT_AUDIO_BUFFER_APPEND = "input_audio_buffer.append"
    INPUT_AUDIO_BUFFER_COMMIT = "input_audio_buffer.commit"
    INPUT_AUDIO_BUFFER_CLEAR = "input_audio_buffer.clear"
    CONVERSATION_ITEM_CREATE = "conversation.item.create"
    CONVERSATION_ITEM_TRUNCATE = "conversation.item.truncate"
    CONVERSATION_ITEM_DELETE = "conversation.item.delete"
    RESPONSE_CREATE = "response.create"
    RESPONSE_CANCEL = "response.cancel"
    
    # Server events
    ERROR = "error"
    SESSION_CREATED = "session.created"
    SESSION_UPDATED = "session.updated"
    CONVERSATION_CREATED = "conversation.created"
    CONVERSATION_ITEM_CREATED = "conversation.item.created"
    CONVERSATION_ITEM_DELETED = "conversation.item.deleted"
    CONVERSATION_ITEM_TRUNCATED = "conversation.item.truncated"
    INPUT_AUDIO_BUFFER_COMMITTED = "input_audio_buffer.committed"
    INPUT_AUDIO_BUFFER_CLEARED = "input_audio_buffer.cleared"
    INPUT_AUDIO_BUFFER_SPEECH_STARTED = "input_audio_buffer.speech_started"
    INPUT_AUDIO_BUFFER_SPEECH_STOPPED = "input_audio_buffer.speech_stopped"
    RESPONSE_CREATED = "response.created"
    RESPONSE_DONE = "response.done"
    RESPONSE_OUTPUT_ITEM_ADDED = "response.output_item.added"
    RESPONSE_OUTPUT_ITEM_DONE = "response.output_item.done"
    RESPONSE_CONTENT_PART_ADDED = "response.content_part.added"
    RESPONSE_CONTENT_PART_DONE = "response.content_part.done"
    RESPONSE_TEXT_DELTA = "response.text.delta"
    RESPONSE_TEXT_DONE = "response.text.done"
    RESPONSE_AUDIO_DELTA = "response.audio.delta"
    RESPONSE_AUDIO_DONE = "response.audio.done"
    RESPONSE_AUDIO_TRANSCRIPT_DELTA = "response.audio_transcript.delta"
    RESPONSE_AUDIO_TRANSCRIPT_DONE = "response.audio_transcript.done"
    RESPONSE_FUNCTION_CALL_ARGUMENTS_DELTA = "response.function_call_arguments.delta"
    RESPONSE_FUNCTION_CALL_ARGUMENTS_DONE = "response.function_call_arguments.done"
    RATE_LIMITS_UPDATED = "rate_limits.updated"


class AudioFormat(Enum):
    """Audio format types."""
    PCM16 = "pcm16"
    G711_ULAW = "g711_ulaw"
    G711_ALAW = "g711_alaw"


class Voice(Enum):
    """Voice options."""
    ALLOY = "alloy"
    ECHO = "echo"
    SHIMMER = "shimmer"
    ASH = "ash"
    BALLAD = "ballad"
    CORAL = "coral"
    SAGE = "sage"
    VERSE = "verse"


class TurnDetectionType(Enum):
    """Turn detection modes."""
    SERVER_VAD = "server_vad"
    NONE = "none"


class ItemType(Enum):
    """Conversation item types."""
    MESSAGE = "message"
    FUNCTION_CALL = "function_call"
    FUNCTION_CALL_OUTPUT = "function_call_output"


class ItemRole(Enum):
    """Conversation item roles."""
    USER = "user"
    ASSISTANT = "assistant"
    SYSTEM = "system"


class ContentType(Enum):
    """Content part types."""
    INPUT_TEXT = "input_text"
    INPUT_AUDIO = "input_audio"
    TEXT = "text"
    AUDIO = "audio"


# ========================================
# Models
# ========================================

@dataclass
class AudioConfig:
    """Audio configuration."""
    input_audio_format: str = "pcm16"
    output_audio_format: str = "pcm16"
    input_audio_transcription: Optional[dict] = None
    
    def to_dict(self) -> dict:
        return {
            "input_audio_format": self.input_audio_format,
            "output_audio_format": self.output_audio_format,
            "input_audio_transcription": self.input_audio_transcription,
        }


@dataclass
class TurnDetection:
    """Turn detection configuration."""
    type: str = "server_vad"
    threshold: float = 0.5
    prefix_padding_ms: int = 300
    silence_duration_ms: int = 500
    create_response: bool = True
    
    def to_dict(self) -> dict:
        return {
            "type": self.type,
            "threshold": self.threshold,
            "prefix_padding_ms": self.prefix_padding_ms,
            "silence_duration_ms": self.silence_duration_ms,
            "create_response": self.create_response,
        }


@dataclass
class SessionConfig:
    """Session configuration."""
    model: str = "gpt-4o-realtime-preview"
    modalities: list = field(default_factory=lambda: ["text", "audio"])
    instructions: Optional[str] = None
    voice: str = "alloy"
    input_audio_format: str = "pcm16"
    output_audio_format: str = "pcm16"
    input_audio_transcription: Optional[dict] = None
    turn_detection: Optional[TurnDetection] = None
    tools: list = field(default_factory=list)
    tool_choice: str = "auto"
    temperature: float = 0.8
    max_response_output_tokens: Optional[int] = None
    
    def to_dict(self) -> dict:
        result = {
            "model": self.model,
            "modalities": self.modalities,
            "voice": self.voice,
            "input_audio_format": self.input_audio_format,
            "output_audio_format": self.output_audio_format,
            "tools": self.tools,
            "tool_choice": self.tool_choice,
            "temperature": self.temperature,
        }
        if self.instructions:
            result["instructions"] = self.instructions
        if self.input_audio_transcription:
            result["input_audio_transcription"] = self.input_audio_transcription
        if self.turn_detection:
            result["turn_detection"] = self.turn_detection.to_dict()
        if self.max_response_output_tokens:
            result["max_response_output_tokens"] = self.max_response_output_tokens
        return result


@dataclass
class ContentPart:
    """Content part for items."""
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


@dataclass
class ConversationItem:
    """Conversation item."""
    id: str = field(default_factory=lambda: f"item_{uuid.uuid4().hex[:12]}")
    type: str = "message"
    role: Optional[str] = None
    content: list = field(default_factory=list)
    call_id: Optional[str] = None
    name: Optional[str] = None
    arguments: Optional[str] = None
    output: Optional[str] = None
    object: str = "realtime.item"
    status: str = "completed"
    
    def to_dict(self) -> dict:
        result = {
            "id": self.id,
            "type": self.type,
            "object": self.object,
            "status": self.status,
        }
        if self.role:
            result["role"] = self.role
        if self.content:
            result["content"] = [c.to_dict() if hasattr(c, 'to_dict') else c for c in self.content]
        if self.call_id:
            result["call_id"] = self.call_id
        if self.name:
            result["name"] = self.name
        if self.arguments:
            result["arguments"] = self.arguments
        if self.output:
            result["output"] = self.output
        return result


@dataclass
class Session:
    """Realtime session."""
    id: str = field(default_factory=lambda: f"sess_{uuid.uuid4().hex[:24]}")
    object: str = "realtime.session"
    model: str = "gpt-4o-realtime-preview"
    expires_at: int = field(default_factory=lambda: int(time.time()) + DEFAULT_SESSION_TIMEOUT)
    modalities: list = field(default_factory=lambda: ["text", "audio"])
    instructions: Optional[str] = None
    voice: str = "alloy"
    input_audio_format: str = "pcm16"
    output_audio_format: str = "pcm16"
    input_audio_transcription: Optional[dict] = None
    turn_detection: Optional[dict] = None
    tools: list = field(default_factory=list)
    tool_choice: str = "auto"
    temperature: float = 0.8
    max_response_output_tokens: Optional[int] = None
    status: SessionStatus = SessionStatus.CREATED
    created_at: int = field(default_factory=lambda: int(time.time()))
    
    def to_dict(self) -> dict:
        result = {
            "id": self.id,
            "object": self.object,
            "model": self.model,
            "expires_at": self.expires_at,
            "modalities": self.modalities,
            "voice": self.voice,
            "input_audio_format": self.input_audio_format,
            "output_audio_format": self.output_audio_format,
            "tools": self.tools,
            "tool_choice": self.tool_choice,
            "temperature": self.temperature,
        }
        if self.instructions:
            result["instructions"] = self.instructions
        if self.input_audio_transcription:
            result["input_audio_transcription"] = self.input_audio_transcription
        if self.turn_detection:
            result["turn_detection"] = self.turn_detection
        if self.max_response_output_tokens:
            result["max_response_output_tokens"] = self.max_response_output_tokens
        return result
    
    def is_expired(self) -> bool:
        return time.time() > self.expires_at


@dataclass
class RealtimeEvent:
    """Base realtime event."""
    event_id: str = field(default_factory=lambda: f"evt_{uuid.uuid4().hex[:24]}")
    type: str = ""
    
    def to_dict(self) -> dict:
        return {
            "event_id": self.event_id,
            "type": self.type,
        }


@dataclass
class ErrorEvent(RealtimeEvent):
    """Error event."""
    type: str = "error"
    error: Optional[dict] = None
    
    def to_dict(self) -> dict:
        result = super().to_dict()
        result["error"] = self.error or {}
        return result


@dataclass
class SessionCreatedEvent(RealtimeEvent):
    """Session created event."""
    type: str = "session.created"
    session: Optional[Session] = None
    
    def to_dict(self) -> dict:
        result = super().to_dict()
        if self.session:
            result["session"] = self.session.to_dict()
        return result


@dataclass
class RateLimits:
    """Rate limit information."""
    name: str
    limit: int
    remaining: int
    reset_seconds: float
    
    def to_dict(self) -> dict:
        return {
            "name": self.name,
            "limit": self.limit,
            "remaining": self.remaining,
            "reset_seconds": self.reset_seconds,
        }


# ========================================
# Utilities
# ========================================

def generate_session_id() -> str:
    """Generate a session ID."""
    return f"sess_{uuid.uuid4().hex[:24]}"


def generate_event_id() -> str:
    """Generate an event ID."""
    return f"evt_{uuid.uuid4().hex[:24]}"


def generate_item_id() -> str:
    """Generate an item ID."""
    return f"item_{uuid.uuid4().hex[:12]}"


def generate_response_id() -> str:
    """Generate a response ID."""
    return f"resp_{uuid.uuid4().hex[:24]}"


def is_client_event(event_type: str) -> bool:
    """Check if event type is a client event."""
    client_events = {
        "session.update",
        "input_audio_buffer.append",
        "input_audio_buffer.commit",
        "input_audio_buffer.clear",
        "conversation.item.create",
        "conversation.item.truncate",
        "conversation.item.delete",
        "response.create",
        "response.cancel",
    }
    return event_type in client_events


def is_server_event(event_type: str) -> bool:
    """Check if event type is a server event."""
    return not is_client_event(event_type)


def validate_audio_format(fmt: str) -> bool:
    """Validate audio format."""
    valid_formats = {"pcm16", "g711_ulaw", "g711_alaw"}
    return fmt in valid_formats


def validate_voice(voice: str) -> bool:
    """Validate voice option."""
    valid_voices = {"alloy", "echo", "shimmer", "ash", "ballad", "coral", "sage", "verse"}
    return voice in valid_voices


def create_session(config: Optional[SessionConfig] = None) -> Session:
    """Create a new session."""
    session = Session()
    if config:
        session.model = config.model
        session.modalities = config.modalities
        session.instructions = config.instructions
        session.voice = config.voice
        session.input_audio_format = config.input_audio_format
        session.output_audio_format = config.output_audio_format
        session.input_audio_transcription = config.input_audio_transcription
        if config.turn_detection:
            session.turn_detection = config.turn_detection.to_dict()
        session.tools = config.tools
        session.tool_choice = config.tool_choice
        session.temperature = config.temperature
        session.max_response_output_tokens = config.max_response_output_tokens
    session.status = SessionStatus.ACTIVE
    return session


def create_error_event(message: str, code: str = "error", param: Optional[str] = None) -> ErrorEvent:
    """Create an error event."""
    return ErrorEvent(
        error={
            "type": "error",
            "code": code,
            "message": message,
            "param": param,
        }
    )


def create_session_created_event(session: Session) -> SessionCreatedEvent:
    """Create session.created event."""
    return SessionCreatedEvent(session=session)


# ========================================
# Factory
# ========================================

_realtime_handler = None


class RealtimeHandler:
    """Handler for realtime operations."""
    
    def __init__(self):
        self.sessions: dict[str, Session] = {}
        
    def create_session(self, config: Optional[SessionConfig] = None) -> Session:
        """Create a new session."""
        session = create_session(config)
        self.sessions[session.id] = session
        return session
    
    def get_session(self, session_id: str) -> Optional[Session]:
        """Get session by ID."""
        return self.sessions.get(session_id)
    
    def close_session(self, session_id: str) -> bool:
        """Close a session."""
        if session_id in self.sessions:
            self.sessions[session_id].status = SessionStatus.CLOSED
            return True
        return False
    
    def list_sessions(self) -> list[Session]:
        """List all sessions."""
        return list(self.sessions.values())


def get_realtime_handler() -> RealtimeHandler:
    """Get or create realtime handler."""
    global _realtime_handler
    if _realtime_handler is None:
        _realtime_handler = RealtimeHandler()
    return _realtime_handler


def reset_realtime_handler() -> None:
    """Reset realtime handler."""
    global _realtime_handler
    _realtime_handler = None