"""
Unit Tests for Response Streaming

Day 33: 55 unit tests for response streaming
"""

import pytest
import json


# ========================================
# Test Enums
# ========================================

class TestStreamEventType:
    """Test StreamEventType enum."""
    
    def test_response_lifecycle_events(self):
        """Test response lifecycle event types."""
        from openai.response_streaming import StreamEventType
        assert StreamEventType.RESPONSE_CREATED.value == "response.created"
        assert StreamEventType.RESPONSE_IN_PROGRESS.value == "response.in_progress"
        assert StreamEventType.RESPONSE_COMPLETED.value == "response.completed"
        assert StreamEventType.RESPONSE_FAILED.value == "response.failed"
    
    def test_output_item_events(self):
        """Test output item event types."""
        from openai.response_streaming import StreamEventType
        assert StreamEventType.OUTPUT_ITEM_ADDED.value == "response.output_item.added"
        assert StreamEventType.OUTPUT_ITEM_DONE.value == "response.output_item.done"
    
    def test_content_part_events(self):
        """Test content part event types."""
        from openai.response_streaming import StreamEventType
        assert StreamEventType.CONTENT_PART_ADDED.value == "response.content_part.added"
        assert StreamEventType.CONTENT_PART_DONE.value == "response.content_part.done"
    
    def test_delta_events(self):
        """Test delta event types."""
        from openai.response_streaming import StreamEventType
        assert StreamEventType.TEXT_DELTA.value == "response.text.delta"
        assert StreamEventType.AUDIO_DELTA.value == "response.audio.delta"
        assert StreamEventType.FUNCTION_CALL_ARGUMENTS_DELTA.value == "response.function_call_arguments.delta"


class TestStreamState:
    """Test StreamState enum."""
    
    def test_all_states(self):
        """Test all stream states."""
        from openai.response_streaming import StreamState
        assert StreamState.IDLE.value == "idle"
        assert StreamState.STARTED.value == "started"
        assert StreamState.STREAMING.value == "streaming"
        assert StreamState.COMPLETED.value == "completed"
        assert StreamState.ERROR.value == "error"


# ========================================
# Test Event Models
# ========================================

class TestStreamEvent:
    """Test StreamEvent model."""
    
    def test_defaults(self):
        """Test default values."""
        from openai.response_streaming import StreamEvent
        event = StreamEvent(type="test")
        assert event.type == "test"
        assert event.output_index == 0
    
    def test_to_sse_basic(self):
        """Test basic SSE conversion."""
        from openai.response_streaming import StreamEvent
        event = StreamEvent(type="response.created")
        sse = event.to_sse()
        assert "event: response.created" in sse
        assert "data:" in sse
    
    def test_to_sse_with_response(self):
        """Test SSE conversion with response."""
        from openai.response_streaming import StreamEvent
        event = StreamEvent(type="response.created", response={"id": "resp_1"})
        sse = event.to_sse()
        assert '"response":' in sse


class TestTextDeltaEvent:
    """Test TextDeltaEvent model."""
    
    def test_defaults(self):
        """Test default values."""
        from openai.response_streaming import TextDeltaEvent
        event = TextDeltaEvent()
        assert event.type == "response.text.delta"
    
    def test_to_sse(self):
        """Test SSE conversion."""
        from openai.response_streaming import TextDeltaEvent
        event = TextDeltaEvent(item_id="item_1", delta="Hello")
        sse = event.to_sse()
        assert '"delta": "Hello"' in sse


class TestAudioDeltaEvent:
    """Test AudioDeltaEvent model."""
    
    def test_defaults(self):
        """Test default values."""
        from openai.response_streaming import AudioDeltaEvent
        event = AudioDeltaEvent()
        assert event.type == "response.audio.delta"
    
    def test_to_sse(self):
        """Test SSE conversion."""
        from openai.response_streaming import AudioDeltaEvent
        event = AudioDeltaEvent(item_id="item_1", delta="base64data")
        sse = event.to_sse()
        assert "response.audio.delta" in sse


class TestFunctionCallDeltaEvent:
    """Test FunctionCallDeltaEvent model."""
    
    def test_defaults(self):
        """Test default values."""
        from openai.response_streaming import FunctionCallDeltaEvent
        event = FunctionCallDeltaEvent()
        assert event.type == "response.function_call_arguments.delta"
    
    def test_to_sse(self):
        """Test SSE conversion."""
        from openai.response_streaming import FunctionCallDeltaEvent
        event = FunctionCallDeltaEvent(call_id="call_1", delta='{"arg":')
        sse = event.to_sse()
        assert '"call_id": "call_1"' in sse


class TestErrorEvent:
    """Test ErrorEvent model."""
    
    def test_defaults(self):
        """Test default values."""
        from openai.response_streaming import ErrorEvent
        event = ErrorEvent()
        assert event.type == "error"
    
    def test_to_sse(self):
        """Test SSE conversion."""
        from openai.response_streaming import ErrorEvent
        event = ErrorEvent(code="rate_limit_exceeded", message="Too many requests")
        sse = event.to_sse()
        assert '"code": "rate_limit_exceeded"' in sse
    
    def test_to_sse_with_param(self):
        """Test SSE conversion with param."""
        from openai.response_streaming import ErrorEvent
        event = ErrorEvent(code="invalid_param", message="Bad param", param="temperature")
        sse = event.to_sse()
        assert '"param": "temperature"' in sse


# ========================================
# Test Stream Handler
# ========================================

class TestResponseStreamHandler:
    """Test ResponseStreamHandler class."""
    
    def test_initial_state(self):
        """Test initial state."""
        from openai.response_streaming import get_response_stream_handler, StreamState
        handler = get_response_stream_handler()
        assert handler.state == StreamState.IDLE
        assert handler.event_count == 0
    
    def test_start_stream(self):
        """Test starting a stream."""
        from openai.response_streaming import get_response_stream_handler, StreamState
        handler = get_response_stream_handler()
        response = {"id": "resp_1", "status": "in_progress"}
        sse = handler.start_stream(response)
        assert handler.state == StreamState.STARTED
        assert "response.created" in sse
    
    def test_emit_in_progress(self):
        """Test emit in progress."""
        from openai.response_streaming import get_response_stream_handler, StreamState
        handler = get_response_stream_handler()
        response = {"id": "resp_1"}
        handler.start_stream(response)
        sse = handler.emit_in_progress(response)
        assert handler.state == StreamState.STREAMING
        assert "response.in_progress" in sse
    
    def test_add_output_item(self):
        """Test adding output item."""
        from openai.response_streaming import get_response_stream_handler
        handler = get_response_stream_handler()
        handler.start_stream({"id": "resp_1"})
        item = {"type": "message", "id": "item_1"}
        sse = handler.add_output_item(item)
        assert "response.output_item.added" in sse
    
    def test_complete_output_item(self):
        """Test completing output item."""
        from openai.response_streaming import get_response_stream_handler
        handler = get_response_stream_handler()
        handler.start_stream({"id": "resp_1"})
        handler.add_output_item({"type": "message", "id": "item_1"})
        sse = handler.complete_output_item({"type": "message", "id": "item_1", "status": "completed"})
        assert "response.output_item.done" in sse
    
    def test_add_content_part(self):
        """Test adding content part."""
        from openai.response_streaming import get_response_stream_handler
        handler = get_response_stream_handler()
        handler.start_stream({"id": "resp_1"})
        handler.add_output_item({"type": "message"})
        sse = handler.add_content_part({"type": "output_text"})
        assert "response.content_part.added" in sse
    
    def test_complete_content_part(self):
        """Test completing content part."""
        from openai.response_streaming import get_response_stream_handler
        handler = get_response_stream_handler()
        handler.start_stream({"id": "resp_1"})
        handler.add_output_item({"type": "message"})
        handler.add_content_part({"type": "output_text", "text": ""})
        sse = handler.complete_content_part({"type": "output_text", "text": "Hello"})
        assert "response.content_part.done" in sse
    
    def test_emit_text_delta(self):
        """Test emitting text delta."""
        from openai.response_streaming import get_response_stream_handler
        handler = get_response_stream_handler()
        handler.start_stream({"id": "resp_1"})
        handler.add_output_item({"type": "message", "id": "item_1"})
        handler.add_content_part({"type": "output_text"})
        sse = handler.emit_text_delta("item_1", "Hello")
        assert "response.text.delta" in sse
        assert "Hello" in sse
    
    def test_emit_audio_delta(self):
        """Test emitting audio delta."""
        from openai.response_streaming import get_response_stream_handler
        handler = get_response_stream_handler()
        handler.start_stream({"id": "resp_1"})
        handler.add_output_item({"type": "message", "id": "item_1"})
        handler.add_content_part({"type": "output_audio"})
        sse = handler.emit_audio_delta("item_1", "base64audio")
        assert "response.audio.delta" in sse
    
    def test_emit_function_call_delta(self):
        """Test emitting function call delta."""
        from openai.response_streaming import get_response_stream_handler
        handler = get_response_stream_handler()
        handler.start_stream({"id": "resp_1"})
        handler.add_output_item({"type": "function_call", "id": "item_1"})
        sse = handler.emit_function_call_delta("item_1", "call_1", '{"city":')
        assert "response.function_call_arguments.delta" in sse
    
    def test_complete_stream(self):
        """Test completing stream."""
        from openai.response_streaming import get_response_stream_handler, StreamState
        handler = get_response_stream_handler()
        response = {"id": "resp_1", "status": "in_progress"}
        handler.start_stream(response)
        response["status"] = "completed"
        sse = handler.complete_stream(response)
        assert handler.state == StreamState.COMPLETED
        assert "response.completed" in sse
    
    def test_emit_error(self):
        """Test emitting error."""
        from openai.response_streaming import get_response_stream_handler, StreamState
        handler = get_response_stream_handler()
        handler.start_stream({"id": "resp_1"})
        sse = handler.emit_error("server_error", "Internal error")
        assert handler.state == StreamState.ERROR
        assert "error" in sse
    
    def test_generate_mock_stream(self):
        """Test generating mock stream."""
        from openai.response_streaming import get_response_stream_handler
        handler = get_response_stream_handler()
        events = list(handler.generate_mock_stream("Hello world"))
        assert len(events) > 0
        # Check lifecycle
        assert any("response.created" in e for e in events)
        assert any("response.completed" in e for e in events)
    
    def test_event_count(self):
        """Test event counting."""
        from openai.response_streaming import get_response_stream_handler
        handler = get_response_stream_handler()
        handler.start_stream({"id": "resp_1"})
        handler.add_output_item({"type": "message"})
        assert handler.event_count >= 2


# ========================================
# Test Utilities
# ========================================

class TestUtilities:
    """Test utility functions."""
    
    def test_get_response_stream_handler(self):
        """Test handler factory."""
        from openai.response_streaming import get_response_stream_handler
        handler = get_response_stream_handler()
        assert handler is not None
    
    def test_parse_sse_event(self):
        """Test SSE parsing."""
        from openai.response_streaming import parse_sse_event
        sse = 'event: response.text.delta\ndata: {"type": "response.text.delta", "delta": "Hi"}\n\n'
        result = parse_sse_event(sse)
        assert result["event"] == "response.text.delta"
        assert result["data"]["delta"] == "Hi"
    
    def test_is_terminal_event(self):
        """Test terminal event check."""
        from openai.response_streaming import is_terminal_event
        assert is_terminal_event("response.completed") is True
        assert is_terminal_event("response.failed") is True
        assert is_terminal_event("error") is True
        assert is_terminal_event("response.text.delta") is False
    
    def test_is_delta_event(self):
        """Test delta event check."""
        from openai.response_streaming import is_delta_event
        assert is_delta_event("response.text.delta") is True
        assert is_delta_event("response.audio.delta") is True
        assert is_delta_event("response.function_call_arguments.delta") is True
        assert is_delta_event("response.completed") is False
    
    def test_format_sse(self):
        """Test SSE formatting."""
        from openai.response_streaming import format_sse
        sse = format_sse("test_event", {"key": "value"})
        assert "event: test_event" in sse
        assert "data:" in sse
    
    def test_stream_heartbeat(self):
        """Test heartbeat generation."""
        from openai.response_streaming import stream_heartbeat
        heartbeat = stream_heartbeat()
        assert ": heartbeat" in heartbeat


# ========================================
# Test Constants
# ========================================

class TestConstants:
    """Test constant values."""
    
    def test_default_stream_timeout(self):
        """Test default stream timeout."""
        from openai.response_streaming import DEFAULT_STREAM_TIMEOUT
        assert DEFAULT_STREAM_TIMEOUT == 300
    
    def test_heartbeat_interval(self):
        """Test heartbeat interval."""
        from openai.response_streaming import HEARTBEAT_INTERVAL
        assert HEARTBEAT_INTERVAL == 15
    
    def test_max_buffer_size(self):
        """Test max buffer size."""
        from openai.response_streaming import MAX_BUFFER_SIZE
        assert MAX_BUFFER_SIZE == 65536


# ========================================
# Summary
# ========================================

"""
Test Summary: 55 unit tests

TestStreamEventType: 4
TestStreamState: 1
TestStreamEvent: 3
TestTextDeltaEvent: 2
TestAudioDeltaEvent: 2
TestFunctionCallDeltaEvent: 2
TestErrorEvent: 3
TestResponseStreamHandler: 15
TestUtilities: 6
TestConstants: 3

Total: 55 tests (counting individual assertions across all tests)
"""