"""
OpenAI-compatible Response Streaming

Day 33 Deliverable: Streaming support for Responses API

Implements streaming event types:
- response.created
- response.in_progress
- response.output_item.added
- response.output_item.done
- response.content_part.added
- response.content_part.done
- response.text.delta
- response.audio.delta
- response.function_call_arguments.delta
- response.completed
- response.failed
"""

import json
import time
import hashlib
from enum import Enum
from typing import Dict, Any, Optional, List, AsyncGenerator, Generator
from dataclasses import dataclass, field


# ========================================
# Constants
# ========================================

DEFAULT_STREAM_TIMEOUT = 300
HEARTBEAT_INTERVAL = 15
MAX_BUFFER_SIZE = 65536


# ========================================
# Enums
# ========================================

class StreamEventType(str, Enum):
    """Stream event types for Responses API."""
    # Response lifecycle
    RESPONSE_CREATED = "response.created"
    RESPONSE_IN_PROGRESS = "response.in_progress"
    RESPONSE_COMPLETED = "response.completed"
    RESPONSE_FAILED = "response.failed"
    RESPONSE_INCOMPLETE = "response.incomplete"
    RESPONSE_CANCELLED = "response.cancelled"
    
    # Output item events
    OUTPUT_ITEM_ADDED = "response.output_item.added"
    OUTPUT_ITEM_DONE = "response.output_item.done"
    
    # Content part events
    CONTENT_PART_ADDED = "response.content_part.added"
    CONTENT_PART_DONE = "response.content_part.done"
    
    # Delta events
    TEXT_DELTA = "response.text.delta"
    AUDIO_DELTA = "response.audio.delta"
    AUDIO_TRANSCRIPT_DELTA = "response.audio_transcript.delta"
    FUNCTION_CALL_ARGUMENTS_DELTA = "response.function_call_arguments.delta"
    
    # Reasoning events
    REASONING_SUMMARY_PART_ADDED = "response.reasoning_summary_part.added"
    REASONING_SUMMARY_PART_DONE = "response.reasoning_summary_part.done"
    REASONING_SUMMARY_TEXT_DELTA = "response.reasoning_summary_text.delta"
    
    # Error event
    ERROR = "error"


class StreamState(str, Enum):
    """Stream state machine states."""
    IDLE = "idle"
    STARTED = "started"
    STREAMING = "streaming"
    COMPLETED = "completed"
    ERROR = "error"


# ========================================
# Event Models
# ========================================

@dataclass
class StreamEvent:
    """Base stream event."""
    type: str
    response: Optional[Dict[str, Any]] = None
    output_item: Optional[Dict[str, Any]] = None
    content_part: Optional[Dict[str, Any]] = None
    delta: Optional[str] = None
    item_id: Optional[str] = None
    output_index: int = 0
    content_index: int = 0
    
    def to_sse(self) -> str:
        """Convert to SSE format."""
        data = {"type": self.type}
        if self.response:
            data["response"] = self.response
        if self.output_item:
            data["output_item"] = self.output_item
        if self.content_part:
            data["content_part"] = self.content_part
        if self.delta is not None:
            data["delta"] = self.delta
        if self.item_id:
            data["item_id"] = self.item_id
        if self.output_index > 0:
            data["output_index"] = self.output_index
        if self.content_index > 0:
            data["content_index"] = self.content_index
        
        return f"event: {self.type}\ndata: {json.dumps(data)}\n\n"


@dataclass
class TextDeltaEvent:
    """Text delta event."""
    type: str = StreamEventType.TEXT_DELTA.value
    item_id: str = ""
    output_index: int = 0
    content_index: int = 0
    delta: str = ""
    
    def to_sse(self) -> str:
        """Convert to SSE format."""
        data = {
            "type": self.type,
            "item_id": self.item_id,
            "output_index": self.output_index,
            "content_index": self.content_index,
            "delta": self.delta,
        }
        return f"event: {self.type}\ndata: {json.dumps(data)}\n\n"


@dataclass
class AudioDeltaEvent:
    """Audio delta event."""
    type: str = StreamEventType.AUDIO_DELTA.value
    item_id: str = ""
    output_index: int = 0
    content_index: int = 0
    delta: str = ""  # base64 audio chunk
    
    def to_sse(self) -> str:
        """Convert to SSE format."""
        data = {
            "type": self.type,
            "item_id": self.item_id,
            "output_index": self.output_index,
            "content_index": self.content_index,
            "delta": self.delta,
        }
        return f"event: {self.type}\ndata: {json.dumps(data)}\n\n"


@dataclass
class FunctionCallDeltaEvent:
    """Function call arguments delta event."""
    type: str = StreamEventType.FUNCTION_CALL_ARGUMENTS_DELTA.value
    item_id: str = ""
    output_index: int = 0
    call_id: str = ""
    delta: str = ""
    
    def to_sse(self) -> str:
        """Convert to SSE format."""
        data = {
            "type": self.type,
            "item_id": self.item_id,
            "output_index": self.output_index,
            "call_id": self.call_id,
            "delta": self.delta,
        }
        return f"event: {self.type}\ndata: {json.dumps(data)}\n\n"


@dataclass
class ErrorEvent:
    """Error event."""
    type: str = StreamEventType.ERROR.value
    code: str = ""
    message: str = ""
    param: Optional[str] = None
    
    def to_sse(self) -> str:
        """Convert to SSE format."""
        data = {
            "type": self.type,
            "error": {
                "code": self.code,
                "message": self.message,
            }
        }
        if self.param:
            data["error"]["param"] = self.param
        return f"event: error\ndata: {json.dumps(data)}\n\n"


# ========================================
# Stream Handler
# ========================================

class ResponseStreamHandler:
    """Handler for response streaming."""
    
    def __init__(self):
        """Initialize stream handler."""
        self._state = StreamState.IDLE
        self._events: List[StreamEvent] = []
        self._buffer = ""
        self._response_id = ""
        self._output_index = 0
        self._content_index = 0
    
    def _generate_id(self, prefix: str = "evt") -> str:
        """Generate event ID."""
        return f"{prefix}_{hashlib.md5(f'{time.time()}'.encode()).hexdigest()[:16]}"
    
    def start_stream(self, response: Dict[str, Any]) -> str:
        """Start streaming a response."""
        self._state = StreamState.STARTED
        self._response_id = response.get("id", self._generate_id("resp"))
        
        # Emit response.created
        event = StreamEvent(
            type=StreamEventType.RESPONSE_CREATED.value,
            response=response
        )
        self._events.append(event)
        return event.to_sse()
    
    def emit_in_progress(self, response: Dict[str, Any]) -> str:
        """Emit response in progress event."""
        self._state = StreamState.STREAMING
        event = StreamEvent(
            type=StreamEventType.RESPONSE_IN_PROGRESS.value,
            response=response
        )
        self._events.append(event)
        return event.to_sse()
    
    def add_output_item(self, item: Dict[str, Any]) -> str:
        """Emit output item added event."""
        event = StreamEvent(
            type=StreamEventType.OUTPUT_ITEM_ADDED.value,
            output_item=item,
            output_index=self._output_index
        )
        self._output_index += 1
        self._events.append(event)
        return event.to_sse()
    
    def complete_output_item(self, item: Dict[str, Any]) -> str:
        """Emit output item done event."""
        event = StreamEvent(
            type=StreamEventType.OUTPUT_ITEM_DONE.value,
            output_item=item,
            output_index=self._output_index - 1
        )
        self._events.append(event)
        self._content_index = 0  # Reset for next item
        return event.to_sse()
    
    def add_content_part(self, part: Dict[str, Any]) -> str:
        """Emit content part added event."""
        event = StreamEvent(
            type=StreamEventType.CONTENT_PART_ADDED.value,
            content_part=part,
            output_index=self._output_index - 1,
            content_index=self._content_index
        )
        self._content_index += 1
        self._events.append(event)
        return event.to_sse()
    
    def complete_content_part(self, part: Dict[str, Any]) -> str:
        """Emit content part done event."""
        event = StreamEvent(
            type=StreamEventType.CONTENT_PART_DONE.value,
            content_part=part,
            output_index=self._output_index - 1,
            content_index=self._content_index - 1
        )
        self._events.append(event)
        return event.to_sse()
    
    def emit_text_delta(
        self,
        item_id: str,
        delta: str
    ) -> str:
        """Emit text delta event."""
        event = TextDeltaEvent(
            item_id=item_id,
            output_index=self._output_index - 1,
            content_index=self._content_index - 1,
            delta=delta
        )
        return event.to_sse()
    
    def emit_audio_delta(
        self,
        item_id: str,
        delta: str
    ) -> str:
        """Emit audio delta event."""
        event = AudioDeltaEvent(
            item_id=item_id,
            output_index=self._output_index - 1,
            content_index=self._content_index - 1,
            delta=delta
        )
        return event.to_sse()
    
    def emit_function_call_delta(
        self,
        item_id: str,
        call_id: str,
        delta: str
    ) -> str:
        """Emit function call arguments delta event."""
        event = FunctionCallDeltaEvent(
            item_id=item_id,
            output_index=self._output_index - 1,
            call_id=call_id,
            delta=delta
        )
        return event.to_sse()
    
    def complete_stream(self, response: Dict[str, Any]) -> str:
        """Complete the stream."""
        self._state = StreamState.COMPLETED
        event = StreamEvent(
            type=StreamEventType.RESPONSE_COMPLETED.value,
            response=response
        )
        self._events.append(event)
        return event.to_sse()
    
    def emit_error(
        self,
        code: str,
        message: str,
        param: Optional[str] = None
    ) -> str:
        """Emit error event."""
        self._state = StreamState.ERROR
        event = ErrorEvent(code=code, message=message, param=param)
        return event.to_sse()
    
    def generate_mock_stream(self, text: str) -> Generator[str, None, None]:
        """Generate mock streaming events for text."""
        # Response created
        response = {
            "id": self._generate_id("resp"),
            "object": "response",
            "status": "in_progress",
            "output": [],
        }
        yield self.start_stream(response)
        
        # In progress
        yield self.emit_in_progress(response)
        
        # Add output item
        item_id = self._generate_id("item")
        item = {
            "type": "message",
            "id": item_id,
            "role": "assistant",
            "content": [],
            "status": "in_progress",
        }
        yield self.add_output_item(item)
        
        # Add content part
        part = {"type": "output_text", "text": ""}
        yield self.add_content_part(part)
        
        # Stream text deltas
        chunk_size = 5
        for i in range(0, len(text), chunk_size):
            chunk = text[i:i + chunk_size]
            yield self.emit_text_delta(item_id, chunk)
        
        # Complete content part
        part["text"] = text
        yield self.complete_content_part(part)
        
        # Complete output item
        item["content"] = [part]
        item["status"] = "completed"
        yield self.complete_output_item(item)
        
        # Complete response
        response["status"] = "completed"
        response["output"] = [item]
        yield self.complete_stream(response)
    
    @property
    def state(self) -> StreamState:
        """Get current state."""
        return self._state
    
    @property
    def event_count(self) -> int:
        """Get event count."""
        return len(self._events)


# ========================================
# Factory and Utilities
# ========================================

def get_response_stream_handler() -> ResponseStreamHandler:
    """Factory function for stream handler."""
    return ResponseStreamHandler()


def parse_sse_event(sse_data: str) -> Dict[str, Any]:
    """Parse SSE event data."""
    lines = sse_data.strip().split("\n")
    event_type = ""
    data = {}
    
    for line in lines:
        if line.startswith("event: "):
            event_type = line[7:]
        elif line.startswith("data: "):
            data = json.loads(line[6:])
    
    return {"event": event_type, "data": data}


def is_terminal_event(event_type: str) -> bool:
    """Check if event type is terminal."""
    return event_type in [
        StreamEventType.RESPONSE_COMPLETED.value,
        StreamEventType.RESPONSE_FAILED.value,
        StreamEventType.RESPONSE_CANCELLED.value,
        StreamEventType.ERROR.value,
    ]


def is_delta_event(event_type: str) -> bool:
    """Check if event type is a delta."""
    return event_type in [
        StreamEventType.TEXT_DELTA.value,
        StreamEventType.AUDIO_DELTA.value,
        StreamEventType.AUDIO_TRANSCRIPT_DELTA.value,
        StreamEventType.FUNCTION_CALL_ARGUMENTS_DELTA.value,
        StreamEventType.REASONING_SUMMARY_TEXT_DELTA.value,
    ]


def format_sse(event_type: str, data: Dict[str, Any]) -> str:
    """Format data as SSE event."""
    return f"event: {event_type}\ndata: {json.dumps(data)}\n\n"


def stream_heartbeat() -> str:
    """Generate heartbeat event."""
    return ": heartbeat\n\n"


# ========================================
# Exports
# ========================================

__all__ = [
    # Constants
    "DEFAULT_STREAM_TIMEOUT",
    "HEARTBEAT_INTERVAL",
    "MAX_BUFFER_SIZE",
    # Enums
    "StreamEventType",
    "StreamState",
    # Event Models
    "StreamEvent",
    "TextDeltaEvent",
    "AudioDeltaEvent",
    "FunctionCallDeltaEvent",
    "ErrorEvent",
    # Handler
    "ResponseStreamHandler",
    # Utilities
    "get_response_stream_handler",
    "parse_sse_event",
    "is_terminal_event",
    "is_delta_event",
    "format_sse",
    "stream_heartbeat",
]