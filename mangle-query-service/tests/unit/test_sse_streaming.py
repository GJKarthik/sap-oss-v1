"""
Unit Tests for SSE Streaming

Day 7 Deliverable: Tests for streaming response handling
Target: >80% code coverage
"""

import pytest
import asyncio
import json
import time
from unittest.mock import AsyncMock, MagicMock

from openai.sse_streaming import (
    SSEEvent,
    StreamState,
    StreamingResponseHandler,
    format_sse_event,
    format_sse_done,
    mock_stream_generator,
    stream_text_response,
)
from openai.models import ChatCompletionChunk, DeltaMessage, StreamChoice


# ========================================
# SSEEvent Tests
# ========================================

class TestSSEEvent:
    """Tests for SSEEvent class."""
    
    def test_basic_event(self):
        event = SSEEvent(data="hello")
        result = event.to_bytes()
        assert b"data: hello" in result
        assert result.endswith(b"\n")
    
    def test_event_with_type(self):
        event = SSEEvent(data="hello", event="message")
        result = event.to_bytes()
        assert b"event: message" in result
        assert b"data: hello" in result
    
    def test_event_with_id(self):
        event = SSEEvent(data="hello", id="123")
        result = event.to_bytes()
        assert b"id: 123" in result
    
    def test_event_with_retry(self):
        event = SSEEvent(data="hello", retry=5000)
        result = event.to_bytes()
        assert b"retry: 5000" in result
    
    def test_multiline_data(self):
        event = SSEEvent(data="line1\nline2")
        result = event.to_bytes()
        assert b"data: line1" in result
        assert b"data: line2" in result
    
    def test_from_chunk(self):
        chunk = ChatCompletionChunk(
            id="test-id",
            model="gpt-4",
            choices=[StreamChoice(index=0, delta=DeltaMessage(content="hi"))],
        )
        event = SSEEvent.from_chunk(chunk)
        assert "test-id" in event.data
        assert "hi" in event.data
    
    def test_done_event(self):
        event = SSEEvent.done()
        assert event.data == "[DONE]"


# ========================================
# Format Functions Tests
# ========================================

class TestFormatFunctions:
    """Tests for format helper functions."""
    
    def test_format_sse_event_dict(self):
        data = {"message": "hello"}
        result = format_sse_event(data)
        assert result.startswith(b"data: ")
        assert b"hello" in result
        assert result.endswith(b"\n\n")
    
    def test_format_sse_event_string(self):
        result = format_sse_event("hello world")
        assert result == b"data: hello world\n\n"
    
    def test_format_sse_done(self):
        result = format_sse_done()
        assert result == b"data: [DONE]\n\n"


# ========================================
# StreamState Tests
# ========================================

class TestStreamState:
    """Tests for StreamState class."""
    
    def test_initial_state(self):
        state = StreamState(completion_id="test-123", model="gpt-4")
        assert state.completion_id == "test-123"
        assert state.model == "gpt-4"
        assert state.full_content == ""
        assert state.started is False
        assert state.finished is False
        assert state.cancelled is False
    
    def test_add_content(self):
        state = StreamState(completion_id="test-123", model="gpt-4")
        state.add_content("Hello")
        state.add_content(" world")
        
        assert state.full_content == "Hello world"
        assert state.completion_tokens == 2
        assert state.first_token_time is not None
        assert state.last_token_time is not None
    
    def test_total_tokens(self):
        state = StreamState(
            completion_id="test-123",
            model="gpt-4",
            prompt_tokens=10,
        )
        state.completion_tokens = 5
        
        assert state.total_tokens == 15
    
    def test_time_to_first_token(self):
        state = StreamState(completion_id="test-123", model="gpt-4")
        # No first token yet
        assert state.time_to_first_token is None
        
        # Add content
        time.sleep(0.01)
        state.add_content("Hello")
        
        assert state.time_to_first_token is not None
        assert state.time_to_first_token >= 0


# ========================================
# StreamingResponseHandler Tests
# ========================================

class TestStreamingResponseHandler:
    """Tests for StreamingResponseHandler class."""
    
    def test_init_with_callbacks(self):
        on_start = MagicMock()
        on_complete = MagicMock()
        
        handler = StreamingResponseHandler(
            on_start=on_start,
            on_complete=on_complete,
        )
        
        assert handler.on_start is on_start
        assert handler.on_complete is on_complete
    
    @pytest.mark.asyncio
    async def test_stream_chunks_basic(self):
        handler = StreamingResponseHandler()
        
        # Create mock stream
        async def mock_backend():
            yield b'data: {"choices":[{"delta":{"content":"Hello"}}]}\n\n'
            yield b'data: {"choices":[{"delta":{"content":" world"}}]}\n\n'
            yield b'data: [DONE]\n\n'
        
        chunks = []
        async for chunk in handler.stream_chunks(mock_backend(), "gpt-4"):
            chunks.append(chunk)
        
        # First chunk is role, then content, then end
        assert len(chunks) >= 3
        assert chunks[0].choices[0].delta.role == "assistant"
    
    @pytest.mark.asyncio
    async def test_stream_callbacks(self):
        start_called = False
        complete_called = False
        tokens = []
        
        def on_start(state):
            nonlocal start_called
            start_called = True
        
        def on_token(token, state):
            tokens.append(token)
        
        def on_complete(state):
            nonlocal complete_called
            complete_called = True
        
        handler = StreamingResponseHandler(
            on_start=on_start,
            on_token=on_token,
            on_complete=on_complete,
        )
        
        async def mock_backend():
            yield b'data: {"choices":[{"delta":{"content":"Test"}}]}\n\n'
            yield b'data: [DONE]\n\n'
        
        async for _ in handler.stream_chunks(mock_backend(), "gpt-4"):
            pass
        
        assert start_called
        assert complete_called
        assert "Test" in tokens
    
    def test_parse_sse_event_valid(self):
        handler = StreamingResponseHandler()
        
        event_text = 'data: {"choices":[{"delta":{"content":"Hello"}}]}'
        chunk = handler._parse_sse_event(event_text, "test-id", "gpt-4")
        
        assert chunk is not None
        assert chunk.choices[0].delta.content == "Hello"
    
    def test_parse_sse_event_done(self):
        handler = StreamingResponseHandler()
        
        event_text = "data: [DONE]"
        chunk = handler._parse_sse_event(event_text, "test-id", "gpt-4")
        
        assert chunk is None
    
    def test_parse_sse_event_invalid_json(self):
        handler = StreamingResponseHandler()
        
        event_text = "data: not-json"
        chunk = handler._parse_sse_event(event_text, "test-id", "gpt-4")
        
        assert chunk is None
    
    def test_parse_sse_event_empty(self):
        handler = StreamingResponseHandler()
        
        event_text = ""
        chunk = handler._parse_sse_event(event_text, "test-id", "gpt-4")
        
        assert chunk is None


# ========================================
# Mock Stream Generator Tests
# ========================================

class TestMockStreamGenerator:
    """Tests for mock_stream_generator."""
    
    @pytest.mark.asyncio
    async def test_generates_chunks(self):
        chunks = []
        async for chunk in mock_stream_generator("Hello world", delay=0.001):
            chunks.append(chunk)
        
        assert len(chunks) > 0
        # Should have first (role), content chunks, final, and [DONE]
        assert len(chunks) >= 4
    
    @pytest.mark.asyncio
    async def test_first_chunk_has_role(self):
        async for chunk in mock_stream_generator("Test", delay=0.001):
            decoded = chunk.decode("utf-8")
            if "role" in decoded:
                assert "assistant" in decoded
                break
    
    @pytest.mark.asyncio
    async def test_ends_with_done(self):
        chunks = []
        async for chunk in mock_stream_generator("Test", delay=0.001):
            chunks.append(chunk)
        
        assert chunks[-1] == b"data: [DONE]\n\n"
    
    @pytest.mark.asyncio
    async def test_content_in_chunks(self):
        all_content = b""
        async for chunk in mock_stream_generator("Hello world", delay=0.001):
            all_content += chunk
        
        assert b"Hello" in all_content
        assert b"world" in all_content


# ========================================
# Text Stream Tests
# ========================================

class TestStreamTextResponse:
    """Tests for stream_text_response."""
    
    @pytest.mark.asyncio
    async def test_streams_characters(self):
        chars = []
        async for char in stream_text_response("Hi", delay=0.001):
            chars.append(char)
        
        assert chars == ["H", "i"]
    
    @pytest.mark.asyncio
    async def test_empty_string(self):
        chars = []
        async for char in stream_text_response("", delay=0.001):
            chars.append(char)
        
        assert chars == []


# ========================================
# Integration Scenarios
# ========================================

class TestStreamingScenarios:
    """Integration-style tests for streaming scenarios."""
    
    @pytest.mark.asyncio
    async def test_full_streaming_flow(self):
        """Test complete streaming flow."""
        collected_content = []
        
        def on_token(token, state):
            collected_content.append(token)
        
        handler = StreamingResponseHandler(on_token=on_token)
        
        # Create backend stream with multiple chunks
        async def backend():
            yield b'data: {"choices":[{"delta":{"content":"The"}}]}\n\n'
            yield b'data: {"choices":[{"delta":{"content":" quick"}}]}\n\n'
            yield b'data: {"choices":[{"delta":{"content":" fox"}}]}\n\n'
            yield b'data: [DONE]\n\n'
        
        chunks = []
        async for chunk in handler.stream_chunks(backend(), "gpt-4"):
            chunks.append(chunk)
        
        # Verify all content was collected
        assert "The" in collected_content
        assert " quick" in collected_content
        assert " fox" in collected_content
    
    @pytest.mark.asyncio
    async def test_sse_bytes_output(self):
        """Test SSE byte output format."""
        handler = StreamingResponseHandler()
        
        async def backend():
            yield b'data: {"choices":[{"delta":{"content":"Test"}}]}\n\n'
            yield b'data: [DONE]\n\n'
        
        sse_chunks = []
        async for chunk in handler.stream_sse_bytes(backend(), "gpt-4"):
            sse_chunks.append(chunk)
        
        # All chunks should be bytes
        assert all(isinstance(c, bytes) for c in sse_chunks)
        
        # Last should be [DONE]
        assert sse_chunks[-1] == b"data: [DONE]\n\n"


# ========================================
# Run Tests
# ========================================

if __name__ == "__main__":
    pytest.main([__file__, "-v", "--tb=short"])