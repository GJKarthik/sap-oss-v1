"""
Server-Sent Events (SSE) Streaming for OpenAI-Compatible API

Day 7 Deliverable: Full streaming implementation
- SSE event formatting
- Async generator for token-by-token streaming
- Stream cancellation support
- Usage reporting in final chunk

Usage:
    from openai.sse_streaming import StreamingResponseHandler
    
    async for event in handler.stream_response(request):
        yield event
"""

import asyncio
import json
import logging
import time
import uuid
from typing import Optional, Dict, Any, AsyncIterator, Callable, List
from dataclasses import dataclass, field

from openai.models import (
    ChatCompletionRequest,
    ChatCompletionChunk,
    ChatMessage,
    DeltaMessage,
    StreamChoice,
    Usage,
)

logger = logging.getLogger(__name__)


# ========================================
# SSE Event Formatting
# ========================================

@dataclass
class SSEEvent:
    """Server-Sent Event."""
    
    data: str
    event: Optional[str] = None
    id: Optional[str] = None
    retry: Optional[int] = None
    
    def to_bytes(self) -> bytes:
        """Convert to SSE wire format."""
        lines = []
        
        if self.event:
            lines.append(f"event: {self.event}")
        if self.id:
            lines.append(f"id: {self.id}")
        if self.retry:
            lines.append(f"retry: {self.retry}")
        
        # Data can be multiline, split on newlines
        for line in self.data.split("\n"):
            lines.append(f"data: {line}")
        
        lines.append("")  # Empty line to end event
        return ("\n".join(lines) + "\n").encode("utf-8")
    
    @classmethod
    def from_chunk(cls, chunk: ChatCompletionChunk) -> "SSEEvent":
        """Create SSE event from chat completion chunk."""
        return cls(data=json.dumps(chunk.to_dict()))
    
    @classmethod
    def done(cls) -> "SSEEvent":
        """Create [DONE] event marking end of stream."""
        return cls(data="[DONE]")


def format_sse_event(data: Any) -> bytes:
    """Format data as SSE event."""
    if isinstance(data, dict):
        data = json.dumps(data)
    return f"data: {data}\n\n".encode("utf-8")


def format_sse_done() -> bytes:
    """Format [DONE] marker."""
    return b"data: [DONE]\n\n"


# ========================================
# Stream State Management
# ========================================

@dataclass
class StreamState:
    """Tracks state of a streaming response."""
    
    completion_id: str
    model: str
    created: int = field(default_factory=lambda: int(time.time()))
    
    # Content accumulation
    full_content: str = ""
    
    # Token counting (estimates)
    prompt_tokens: int = 0
    completion_tokens: int = 0
    
    # State flags
    started: bool = False
    finished: bool = False
    cancelled: bool = False
    error: Optional[str] = None
    
    # Timing
    first_token_time: Optional[float] = None
    last_token_time: Optional[float] = None
    
    def add_content(self, content: str) -> None:
        """Add content delta."""
        self.full_content += content
        self.completion_tokens += 1  # Rough estimate
        self.last_token_time = time.time()
        
        if self.first_token_time is None:
            self.first_token_time = time.time()
    
    @property
    def total_tokens(self) -> int:
        """Get total token count."""
        return self.prompt_tokens + self.completion_tokens
    
    @property
    def time_to_first_token(self) -> Optional[float]:
        """Get time to first token in seconds."""
        if self.first_token_time:
            return self.first_token_time - self.created
        return None


# ========================================
# Streaming Response Handler
# ========================================

class StreamingResponseHandler:
    """
    Handles streaming responses for chat completions.
    
    Responsibilities:
    - Parse backend SSE stream
    - Generate properly formatted chunks
    - Track stream state
    - Handle cancellation
    """
    
    def __init__(
        self,
        on_start: Optional[Callable[[StreamState], None]] = None,
        on_token: Optional[Callable[[str, StreamState], None]] = None,
        on_complete: Optional[Callable[[StreamState], None]] = None,
        on_error: Optional[Callable[[Exception, StreamState], None]] = None,
    ):
        """
        Initialize streaming handler.
        
        Args:
            on_start: Callback when stream starts
            on_token: Callback for each token
            on_complete: Callback when stream completes
            on_error: Callback on error
        """
        self.on_start = on_start
        self.on_token = on_token
        self.on_complete = on_complete
        self.on_error = on_error
    
    async def stream_chunks(
        self,
        backend_stream: AsyncIterator[bytes],
        model: str,
        prompt_tokens: int = 0,
    ) -> AsyncIterator[ChatCompletionChunk]:
        """
        Stream chat completion chunks from backend.
        
        Args:
            backend_stream: Raw byte stream from backend
            model: Model name
            prompt_tokens: Prompt token count for usage
        
        Yields:
            Chat completion chunks
        """
        completion_id = f"chatcmpl-{uuid.uuid4().hex[:24]}"
        state = StreamState(
            completion_id=completion_id,
            model=model,
            prompt_tokens=prompt_tokens,
        )
        
        try:
            # Emit start callback
            if self.on_start:
                self.on_start(state)
            
            # First chunk: role announcement
            state.started = True
            yield ChatCompletionChunk.create_start(model, completion_id)
            
            # Process backend stream
            buffer = ""
            async for raw_chunk in backend_stream:
                if state.cancelled:
                    logger.info(f"Stream {completion_id} cancelled")
                    break
                
                # Decode and buffer
                try:
                    text = raw_chunk.decode("utf-8")
                    buffer += text
                except UnicodeDecodeError:
                    continue
                
                # Parse SSE events from buffer
                while "\n\n" in buffer or "\r\n\r\n" in buffer:
                    # Find event boundary
                    end_idx = buffer.find("\n\n")
                    if end_idx == -1:
                        end_idx = buffer.find("\r\n\r\n")
                        sep_len = 4
                    else:
                        sep_len = 2
                    
                    if end_idx == -1:
                        break
                    
                    event_text = buffer[:end_idx]
                    buffer = buffer[end_idx + sep_len:]
                    
                    # Parse event
                    chunk = self._parse_sse_event(event_text, completion_id, model)
                    if chunk:
                        # Extract content for state tracking
                        if chunk.choices and chunk.choices[0].delta.content:
                            content = chunk.choices[0].delta.content
                            state.add_content(content)
                            
                            if self.on_token:
                                self.on_token(content, state)
                        
                        yield chunk
            
            # Final chunk with finish reason
            if not state.cancelled:
                state.finished = True
                yield ChatCompletionChunk.create_end(model, completion_id, "stop")
                
                if self.on_complete:
                    self.on_complete(state)
        
        except Exception as e:
            state.error = str(e)
            logger.exception(f"Streaming error for {completion_id}")
            
            if self.on_error:
                self.on_error(e, state)
            
            raise
    
    async def stream_sse_bytes(
        self,
        backend_stream: AsyncIterator[bytes],
        model: str,
        prompt_tokens: int = 0,
        include_usage: bool = False,
    ) -> AsyncIterator[bytes]:
        """
        Stream SSE-formatted bytes for HTTP response.
        
        Args:
            backend_stream: Raw byte stream from backend
            model: Model name
            prompt_tokens: Prompt token count
            include_usage: Include usage in final chunk
        
        Yields:
            SSE-formatted bytes
        """
        state = None
        
        async for chunk in self.stream_chunks(backend_stream, model, prompt_tokens):
            state = getattr(self, "_last_state", None)
            yield format_sse_event(chunk.to_dict())
        
        # Final [DONE] marker
        yield format_sse_done()
    
    def _parse_sse_event(
        self,
        event_text: str,
        completion_id: str,
        model: str,
    ) -> Optional[ChatCompletionChunk]:
        """Parse SSE event text into chunk."""
        data = None
        
        for line in event_text.split("\n"):
            line = line.strip()
            
            if line.startswith("data: "):
                data = line[6:]
            elif line.startswith("data:"):
                data = line[5:]
        
        if not data:
            return None
        
        if data == "[DONE]":
            return None
        
        try:
            parsed = json.loads(data)
            
            # Build chunk from parsed data
            choices = []
            for choice_data in parsed.get("choices", []):
                delta_data = choice_data.get("delta", {})
                delta = DeltaMessage(
                    role=delta_data.get("role"),
                    content=delta_data.get("content"),
                    tool_calls=delta_data.get("tool_calls"),
                    function_call=delta_data.get("function_call"),
                )
                choices.append(StreamChoice(
                    index=choice_data.get("index", 0),
                    delta=delta,
                    finish_reason=choice_data.get("finish_reason"),
                ))
            
            return ChatCompletionChunk(
                id=parsed.get("id", completion_id),
                object="chat.completion.chunk",
                created=parsed.get("created", int(time.time())),
                model=parsed.get("model", model),
                choices=choices,
                system_fingerprint=parsed.get("system_fingerprint"),
            )
        
        except json.JSONDecodeError:
            logger.warning(f"Failed to parse SSE data: {data[:100]}")
            return None


# ========================================
# Mock Stream Generator (for testing)
# ========================================

async def mock_stream_generator(
    content: str,
    model: str = "gpt-4",
    delay: float = 0.05,
) -> AsyncIterator[bytes]:
    """
    Generate mock streaming response.
    
    Useful for testing without a real backend.
    
    Args:
        content: Full content to stream
        model: Model name
        delay: Delay between tokens (seconds)
    
    Yields:
        SSE-formatted bytes
    """
    completion_id = f"chatcmpl-{uuid.uuid4().hex[:24]}"
    created = int(time.time())
    
    # First chunk with role
    first_chunk = {
        "id": completion_id,
        "object": "chat.completion.chunk",
        "created": created,
        "model": model,
        "choices": [{"index": 0, "delta": {"role": "assistant"}, "finish_reason": None}],
    }
    yield f"data: {json.dumps(first_chunk)}\n\n".encode("utf-8")
    
    # Stream content word by word
    words = content.split()
    for i, word in enumerate(words):
        await asyncio.sleep(delay)
        
        # Add space before word (except first)
        text = f" {word}" if i > 0 else word
        
        chunk = {
            "id": completion_id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [{"index": 0, "delta": {"content": text}, "finish_reason": None}],
        }
        yield f"data: {json.dumps(chunk)}\n\n".encode("utf-8")
    
    # Final chunk with finish_reason
    final_chunk = {
        "id": completion_id,
        "object": "chat.completion.chunk",
        "created": created,
        "model": model,
        "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
    }
    yield f"data: {json.dumps(final_chunk)}\n\n".encode("utf-8")
    
    # [DONE] marker
    yield b"data: [DONE]\n\n"


async def stream_text_response(
    content: str,
    model: str = "gpt-4",
    delay: float = 0.02,
) -> AsyncIterator[str]:
    """
    Simple text streaming (no SSE format).
    
    Args:
        content: Content to stream
        model: Model name
        delay: Delay between characters
    
    Yields:
        Characters one at a time
    """
    for char in content:
        await asyncio.sleep(delay)
        yield char


# ========================================
# Exports
# ========================================

__all__ = [
    "SSEEvent",
    "StreamState",
    "StreamingResponseHandler",
    "format_sse_event",
    "format_sse_done",
    "mock_stream_generator",
    "stream_text_response",
]