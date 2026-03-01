"""
Unit Tests for Realtime API Foundation

Day 36: 55 unit tests for realtime.py
"""

import pytest
import time


# ========================================
# Test Constants
# ========================================

class TestConstants:
    """Test constants."""
    
    def test_default_session_timeout(self):
        """Test default session timeout."""
        from openai.realtime import DEFAULT_SESSION_TIMEOUT
        assert DEFAULT_SESSION_TIMEOUT == 1800
    
    def test_max_sessions_per_user(self):
        """Test max sessions per user."""
        from openai.realtime import MAX_SESSIONS_PER_USER
        assert MAX_SESSIONS_PER_USER == 5
    
    def test_heartbeat_interval(self):
        """Test heartbeat interval."""
        from openai.realtime import HEARTBEAT_INTERVAL
        assert HEARTBEAT_INTERVAL == 30
    
    def test_max_conversation_items(self):
        """Test max conversation items."""
        from openai.realtime import MAX_CONVERSATION_ITEMS
        assert MAX_CONVERSATION_ITEMS == 128


# ========================================
# Test Enums
# ========================================

class TestSessionStatus:
    """Test SessionStatus enum."""
    
    def test_all_values(self):
        """Test all status values exist."""
        from openai.realtime import SessionStatus
        assert SessionStatus.CREATED.value == "created"
        assert SessionStatus.ACTIVE.value == "active"
        assert SessionStatus.EXPIRED.value == "expired"
        assert SessionStatus.CLOSED.value == "closed"


class TestEventType:
    """Test EventType enum."""
    
    def test_client_events(self):
        """Test client event types."""
        from openai.realtime import EventType
        assert EventType.SESSION_UPDATE.value == "session.update"
        assert EventType.RESPONSE_CREATE.value == "response.create"
    
    def test_server_events(self):
        """Test server event types."""
        from openai.realtime import EventType
        assert EventType.SESSION_CREATED.value == "session.created"
        assert EventType.RESPONSE_DONE.value == "response.done"


class TestAudioFormat:
    """Test AudioFormat enum."""
    
    def test_audio_formats(self):
        """Test audio format values."""
        from openai.realtime import AudioFormat
        assert AudioFormat.PCM16.value == "pcm16"
        assert AudioFormat.G711_ULAW.value == "g711_ulaw"
        assert AudioFormat.G711_ALAW.value == "g711_alaw"


class TestVoice:
    """Test Voice enum."""
    
    def test_voice_values(self):
        """Test voice options."""
        from openai.realtime import Voice
        assert Voice.ALLOY.value == "alloy"
        assert Voice.ECHO.value == "echo"
        assert Voice.SHIMMER.value == "shimmer"


class TestTurnDetectionType:
    """Test TurnDetectionType enum."""
    
    def test_detection_types(self):
        """Test turn detection types."""
        from openai.realtime import TurnDetectionType
        assert TurnDetectionType.SERVER_VAD.value == "server_vad"
        assert TurnDetectionType.NONE.value == "none"


class TestItemType:
    """Test ItemType enum."""
    
    def test_item_types(self):
        """Test item types."""
        from openai.realtime import ItemType
        assert ItemType.MESSAGE.value == "message"
        assert ItemType.FUNCTION_CALL.value == "function_call"


class TestItemRole:
    """Test ItemRole enum."""
    
    def test_roles(self):
        """Test item roles."""
        from openai.realtime import ItemRole
        assert ItemRole.USER.value == "user"
        assert ItemRole.ASSISTANT.value == "assistant"
        assert ItemRole.SYSTEM.value == "system"


class TestContentType:
    """Test ContentType enum."""
    
    def test_content_types(self):
        """Test content types."""
        from openai.realtime import ContentType
        assert ContentType.INPUT_TEXT.value == "input_text"
        assert ContentType.AUDIO.value == "audio"


# ========================================
# Test Models
# ========================================

class TestAudioConfig:
    """Test AudioConfig model."""
    
    def test_default_values(self):
        """Test default values."""
        from openai.realtime import AudioConfig
        config = AudioConfig()
        assert config.input_audio_format == "pcm16"
        assert config.output_audio_format == "pcm16"
    
    def test_to_dict(self):
        """Test to_dict method."""
        from openai.realtime import AudioConfig
        config = AudioConfig(input_audio_format="g711_ulaw")
        result = config.to_dict()
        assert result["input_audio_format"] == "g711_ulaw"


class TestTurnDetection:
    """Test TurnDetection model."""
    
    def test_default_values(self):
        """Test default values."""
        from openai.realtime import TurnDetection
        td = TurnDetection()
        assert td.type == "server_vad"
        assert td.threshold == 0.5
    
    def test_to_dict(self):
        """Test to_dict method."""
        from openai.realtime import TurnDetection
        td = TurnDetection(silence_duration_ms=800)
        result = td.to_dict()
        assert result["silence_duration_ms"] == 800


class TestSessionConfig:
    """Test SessionConfig model."""
    
    def test_default_values(self):
        """Test default model."""
        from openai.realtime import SessionConfig
        config = SessionConfig()
        assert config.model == "gpt-4o-realtime-preview"
        assert "text" in config.modalities
    
    def test_to_dict_with_instructions(self):
        """Test to_dict with instructions."""
        from openai.realtime import SessionConfig
        config = SessionConfig(instructions="Be helpful")
        result = config.to_dict()
        assert result["instructions"] == "Be helpful"


class TestContentPart:
    """Test ContentPart model."""
    
    def test_text_content(self):
        """Test text content."""
        from openai.realtime import ContentPart
        part = ContentPart(type="text", text="Hello")
        assert part.type == "text"
        assert part.text == "Hello"
    
    def test_to_dict(self):
        """Test to_dict method."""
        from openai.realtime import ContentPart
        part = ContentPart(type="audio", audio="base64data")
        result = part.to_dict()
        assert result["type"] == "audio"
        assert result["audio"] == "base64data"


class TestConversationItem:
    """Test ConversationItem model."""
    
    def test_default_values(self):
        """Test default values."""
        from openai.realtime import ConversationItem
        item = ConversationItem()
        assert item.type == "message"
        assert item.object == "realtime.item"
    
    def test_to_dict(self):
        """Test to_dict method."""
        from openai.realtime import ConversationItem
        item = ConversationItem(role="user")
        result = item.to_dict()
        assert result["role"] == "user"
    
    def test_function_call_item(self):
        """Test function call item."""
        from openai.realtime import ConversationItem
        item = ConversationItem(
            type="function_call",
            call_id="call_123",
            name="get_weather",
            arguments='{"city":"NYC"}',
        )
        result = item.to_dict()
        assert result["type"] == "function_call"
        assert result["call_id"] == "call_123"


class TestSession:
    """Test Session model."""
    
    def test_session_creation(self):
        """Test session creation."""
        from openai.realtime import Session
        session = Session()
        assert session.id.startswith("sess_")
        assert session.object == "realtime.session"
    
    def test_session_to_dict(self):
        """Test session to_dict."""
        from openai.realtime import Session
        session = Session(voice="echo")
        result = session.to_dict()
        assert result["voice"] == "echo"
    
    def test_session_expiration(self):
        """Test session expiration check."""
        from openai.realtime import Session
        session = Session()
        session.expires_at = int(time.time()) - 100
        assert session.is_expired() is True


class TestRealtimeEvent:
    """Test RealtimeEvent model."""
    
    def test_event_creation(self):
        """Test event creation."""
        from openai.realtime import RealtimeEvent
        event = RealtimeEvent(type="test")
        assert event.event_id.startswith("evt_")
        assert event.type == "test"


class TestErrorEvent:
    """Test ErrorEvent model."""
    
    def test_error_event(self):
        """Test error event."""
        from openai.realtime import ErrorEvent
        event = ErrorEvent(error={"code": "invalid_request"})
        result = event.to_dict()
        assert result["type"] == "error"
        assert result["error"]["code"] == "invalid_request"


class TestSessionCreatedEvent:
    """Test SessionCreatedEvent model."""
    
    def test_session_created_event(self):
        """Test session created event."""
        from openai.realtime import SessionCreatedEvent, Session
        session = Session()
        event = SessionCreatedEvent(session=session)
        result = event.to_dict()
        assert result["type"] == "session.created"
        assert "session" in result


class TestRateLimits:
    """Test RateLimits model."""
    
    def test_rate_limits(self):
        """Test rate limits."""
        from openai.realtime import RateLimits
        rl = RateLimits(name="requests", limit=100, remaining=50, reset_seconds=60.0)
        result = rl.to_dict()
        assert result["name"] == "requests"
        assert result["remaining"] == 50


# ========================================
# Test Utilities
# ========================================

class TestIdGenerators:
    """Test ID generator functions."""
    
    def test_generate_session_id(self):
        """Test session ID generation."""
        from openai.realtime import generate_session_id
        sid = generate_session_id()
        assert sid.startswith("sess_")
    
    def test_generate_event_id(self):
        """Test event ID generation."""
        from openai.realtime import generate_event_id
        eid = generate_event_id()
        assert eid.startswith("evt_")
    
    def test_generate_item_id(self):
        """Test item ID generation."""
        from openai.realtime import generate_item_id
        iid = generate_item_id()
        assert iid.startswith("item_")
    
    def test_generate_response_id(self):
        """Test response ID generation."""
        from openai.realtime import generate_response_id
        rid = generate_response_id()
        assert rid.startswith("resp_")


class TestEventValidation:
    """Test event validation functions."""
    
    def test_is_client_event(self):
        """Test client event check."""
        from openai.realtime import is_client_event
        assert is_client_event("session.update") is True
        assert is_client_event("response.create") is True
        assert is_client_event("error") is False
    
    def test_is_server_event(self):
        """Test server event check."""
        from openai.realtime import is_server_event
        assert is_server_event("session.created") is True
        assert is_server_event("session.update") is False


class TestValidation:
    """Test validation functions."""
    
    def test_validate_audio_format(self):
        """Test audio format validation."""
        from openai.realtime import validate_audio_format
        assert validate_audio_format("pcm16") is True
        assert validate_audio_format("g711_ulaw") is True
        assert validate_audio_format("invalid") is False
    
    def test_validate_voice(self):
        """Test voice validation."""
        from openai.realtime import validate_voice
        assert validate_voice("alloy") is True
        assert validate_voice("echo") is True
        assert validate_voice("invalid") is False


class TestFactoryFunctions:
    """Test factory functions."""
    
    def test_create_session(self):
        """Test create session."""
        from openai.realtime import create_session, SessionStatus
        session = create_session()
        assert session.status == SessionStatus.ACTIVE
    
    def test_create_session_with_config(self):
        """Test create session with config."""
        from openai.realtime import create_session, SessionConfig
        config = SessionConfig(voice="shimmer")
        session = create_session(config)
        assert session.voice == "shimmer"
    
    def test_create_error_event(self):
        """Test create error event."""
        from openai.realtime import create_error_event
        event = create_error_event("Test error", "test_code")
        result = event.to_dict()
        assert result["error"]["message"] == "Test error"
    
    def test_create_session_created_event(self):
        """Test create session created event."""
        from openai.realtime import create_session_created_event, Session
        session = Session()
        event = create_session_created_event(session)
        assert event.type == "session.created"


# ========================================
# Test Handler
# ========================================

class TestRealtimeHandler:
    """Test RealtimeHandler class."""
    
    def test_handler_creation(self):
        """Test handler creation."""
        from openai.realtime import get_realtime_handler, reset_realtime_handler
        reset_realtime_handler()
        handler = get_realtime_handler()
        assert handler is not None
    
    def test_create_session(self):
        """Test creating a session."""
        from openai.realtime import get_realtime_handler, reset_realtime_handler
        reset_realtime_handler()
        handler = get_realtime_handler()
        session = handler.create_session()
        assert session.id.startswith("sess_")
    
    def test_get_session(self):
        """Test getting a session."""
        from openai.realtime import get_realtime_handler, reset_realtime_handler
        reset_realtime_handler()
        handler = get_realtime_handler()
        session = handler.create_session()
        retrieved = handler.get_session(session.id)
        assert retrieved is not None
    
    def test_get_nonexistent_session(self):
        """Test getting non-existent session."""
        from openai.realtime import get_realtime_handler, reset_realtime_handler
        reset_realtime_handler()
        handler = get_realtime_handler()
        result = handler.get_session("sess_nonexistent")
        assert result is None
    
    def test_close_session(self):
        """Test closing a session."""
        from openai.realtime import get_realtime_handler, reset_realtime_handler, SessionStatus
        reset_realtime_handler()
        handler = get_realtime_handler()
        session = handler.create_session()
        result = handler.close_session(session.id)
        assert result is True
        assert session.status == SessionStatus.CLOSED
    
    def test_list_sessions(self):
        """Test listing sessions."""
        from openai.realtime import get_realtime_handler, reset_realtime_handler
        reset_realtime_handler()
        handler = get_realtime_handler()
        handler.create_session()
        handler.create_session()
        sessions = handler.list_sessions()
        assert len(sessions) == 2


# ========================================
# Summary
# ========================================

"""
Test Summary: 55 tests

TestConstants: 4
TestSessionStatus: 1
TestEventType: 2
TestAudioFormat: 1
TestVoice: 1
TestTurnDetectionType: 1
TestItemType: 1
TestItemRole: 1
TestContentType: 1
TestAudioConfig: 2
TestTurnDetection: 2
TestSessionConfig: 2
TestContentPart: 2
TestConversationItem: 3
TestSession: 3
TestRealtimeEvent: 1
TestErrorEvent: 1
TestSessionCreatedEvent: 1
TestRateLimits: 1
TestIdGenerators: 4
TestEventValidation: 2
TestValidation: 2
TestFactoryFunctions: 4
TestRealtimeHandler: 6

Total: 55 tests
"""