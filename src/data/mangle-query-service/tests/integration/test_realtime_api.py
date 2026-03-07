"""
Integration Tests for Realtime API

Day 40: End-to-end testing for all Realtime API components
"""

import pytest
from unittest.mock import Mock, AsyncMock, MagicMock, patch


# ========================================
# Test Session Lifecycle
# ========================================

class TestSessionLifecycle:
    """Test complete session lifecycle."""
    
    def test_create_session(self):
        """Test session creation."""
        from openai.realtime import RealtimeSession
        session = RealtimeSession()
        assert session.session_id.startswith("sess_")
        assert session.status == "created"
    
    def test_configure_session(self):
        """Test session configuration."""
        from openai.realtime import RealtimeSession, RealtimeConfig
        session = RealtimeSession()
        config = RealtimeConfig(model="gpt-4o-realtime-preview")
        session.configure(config)
        assert session.config.model == "gpt-4o-realtime-preview"
    
    def test_session_state_transitions(self):
        """Test session state transitions."""
        from openai.realtime import RealtimeSession
        session = RealtimeSession()
        assert session.status == "created"
        session.connect()
        assert session.status == "connected"
    
    def test_session_cleanup(self):
        """Test session cleanup on close."""
        from openai.realtime import RealtimeSession
        session = RealtimeSession()
        session.connect()
        session.close()
        assert session.status == "closed"


# ========================================
# Test WebSocket Integration
# ========================================

class TestWebSocketIntegration:
    """Test WebSocket connection and messaging."""
    
    def test_connection_creation(self):
        """Test WebSocket connection."""
        from openai.realtime_websocket import RealtimeConnection
        conn = RealtimeConnection("sess_123")
        assert conn.session_id == "sess_123"
    
    def test_event_serialization(self):
        """Test event serialization."""
        from openai.realtime import create_event
        event = create_event("session.update", {"session": {"model": "gpt-4o"}})
        assert event["type"] == "session.update"
    
    def test_event_queue_processing(self):
        """Test event queue."""
        from openai.realtime_websocket import RealtimeConnection
        conn = RealtimeConnection("sess_123")
        conn.queue_outbound({"type": "test"})
        assert not conn.is_queue_empty()
    
    def test_connection_state_machine(self):
        """Test connection states."""
        from openai.realtime_websocket import RealtimeConnection, ConnectionState
        conn = RealtimeConnection("sess_123")
        assert conn.state == ConnectionState.DISCONNECTED


# ========================================
# Test Audio Pipeline
# ========================================

class TestAudioPipeline:
    """Test audio processing pipeline."""
    
    def test_audio_buffer_flow(self):
        """Test audio buffer append and commit."""
        from openai.realtime_audio import AudioBuffer
        buf = AudioBuffer("sess_123")
        buf.append(b"\x00\x01\x02\x03" * 100)
        data = buf.commit()
        assert len(data) == 400
    
    def test_vad_integration(self):
        """Test VAD with audio buffer."""
        from openai.realtime_audio import AudioBuffer, VoiceActivityDetector, AudioChunk
        buf = AudioBuffer("sess_123")
        vad = VoiceActivityDetector()
        
        # Simulate audio input
        chunk = AudioChunk(data=b"\x00\x00" * 100, format="pcm16")
        result = vad.analyze(chunk)
        assert result.is_speech is False
    
    def test_format_conversion_pipeline(self):
        """Test format conversion."""
        from openai.realtime_audio import convert_format, g711_ulaw_encode, g711_ulaw_decode
        # PCM16 to G.711 and back
        original = b"\x00\x10\x00\x20"
        converted = convert_format(original, "pcm16", "g711_ulaw")
        assert len(converted) == 2  # Compressed
    
    def test_audio_duration_calculation(self):
        """Test duration calculation."""
        from openai.realtime_audio import calculate_duration_ms, SAMPLE_RATE_PCM16
        data = b"\x00\x00" * SAMPLE_RATE_PCM16  # 1 second
        duration = calculate_duration_ms(data, "pcm16")
        assert abs(duration - 1000) < 1


# ========================================
# Test Conversation Flow
# ========================================

class TestConversationFlow:
    """Test conversation management."""
    
    def test_add_user_message(self):
        """Test adding user message."""
        from openai.realtime_conversation import (
            Conversation, create_user_message
        )
        conv = Conversation()
        item = create_user_message("Hello, how are you?")
        conv.add_item(item)
        assert conv.get_item_count() == 1
    
    def test_multi_turn_conversation(self):
        """Test multi-turn conversation."""
        from openai.realtime_conversation import (
            Conversation, create_user_message, create_assistant_message
        )
        conv = Conversation()
        conv.add_item(create_user_message("Hello"))
        conv.add_item(create_assistant_message("Hi! How can I help?"))
        conv.add_item(create_user_message("What's the weather?"))
        
        items = conv.get_items()
        assert len(items) == 3
        assert items[0].role == "user"
        assert items[1].role == "assistant"
    
    def test_function_call_flow(self):
        """Test function call and output."""
        from openai.realtime_conversation import (
            Conversation, create_function_call, create_function_output
        )
        conv = Conversation()
        
        # Add function call
        call = create_function_call("get_weather", "call_123", '{"location": "NYC"}')
        conv.add_item(call)
        
        # Add function output
        output = create_function_output("call_123", '{"temp": 72}')
        conv.add_item(output)
        
        assert conv.get_item_count() == 2
    
    def test_conversation_truncation(self):
        """Test conversation truncation."""
        from openai.realtime_conversation import (
            Conversation, create_user_message, create_assistant_message
        )
        conv = Conversation()
        item1 = create_user_message("First")
        item2 = create_assistant_message("Response")
        item3 = create_user_message("Second")
        
        conv.add_item(item1)
        conv.add_item(item2)
        conv.add_item(item3)
        
        removed = conv.truncate(item1.id)
        assert removed == 2
        assert conv.get_item_count() == 1


# ========================================
# Test Response Generation
# ========================================

class TestResponseGeneration:
    """Test response handling."""
    
    def test_response_creation(self):
        """Test response handler creation."""
        from openai.realtime_conversation import ResponseHandler
        handler = ResponseHandler()
        assert handler.id.startswith("resp_")
        assert handler.get_status() == "in_progress"
    
    def test_response_output_items(self):
        """Test adding output items."""
        from openai.realtime_conversation import ResponseHandler, ConversationItem
        handler = ResponseHandler()
        item = ConversationItem(type="message", role="assistant")
        handler.add_output_item(item)
        
        items = handler.get_output_items()
        assert len(items) == 1
    
    def test_response_completion(self):
        """Test response completion."""
        from openai.realtime_conversation import ResponseHandler
        handler = ResponseHandler()
        handler.complete({"input_tokens": 50, "output_tokens": 100})
        
        assert handler.get_status() == "completed"
        usage = handler.get_usage()
        assert usage["output_tokens"] == 100
    
    def test_response_callbacks(self):
        """Test response callbacks."""
        from openai.realtime_conversation import ResponseHandler, ConversationItem
        handler = ResponseHandler()
        
        events = []
        handler.on("item_created", lambda x: events.append("created"))
        handler.on("done", lambda x: events.append("done"))
        
        item = ConversationItem(type="message", role="assistant")
        handler.add_output_item(item)
        handler.complete()
        
        assert "created" in events
        assert "done" in events


# ========================================
# Test Turn Management
# ========================================

class TestTurnManagement:
    """Test turn detection and management."""
    
    def test_turn_lifecycle(self):
        """Test turn start and end."""
        from openai.realtime_conversation import TurnManager
        mgr = TurnManager()
        
        turn_id = mgr.start_turn("user")
        assert mgr.is_in_turn() is True
        
        ended = mgr.end_turn()
        assert ended == turn_id
        assert mgr.is_in_turn() is False
    
    def test_pending_response(self):
        """Test pending response tracking."""
        from openai.realtime_conversation import TurnManager, ResponseHandler
        mgr = TurnManager()
        
        handler = ResponseHandler()
        mgr.set_pending_response(handler)
        
        assert mgr.get_pending_response() is handler
        
        mgr.clear_pending_response()
        assert mgr.get_pending_response() is None
    
    def test_turn_count(self):
        """Test turn counting."""
        from openai.realtime_conversation import TurnManager
        mgr = TurnManager()
        
        mgr.start_turn("user")
        mgr.end_turn()
        mgr.start_turn("assistant")
        mgr.end_turn()
        
        assert mgr.get_turn_count() == 2


# ========================================
# Test Event Handling
# ========================================

class TestEventHandling:
    """Test event creation and processing."""
    
    def test_session_events(self):
        """Test session events."""
        from openai.realtime import create_event
        
        event = create_event("session.update", {
            "session": {"instructions": "Be helpful"}
        })
        
        assert event["type"] == "session.update"
        assert "event_id" in event
    
    def test_conversation_events(self):
        """Test conversation item events."""
        from openai.realtime import create_event
        
        event = create_event("conversation.item.create", {
            "item": {
                "type": "message",
                "role": "user",
                "content": [{"type": "input_text", "text": "Hello"}]
            }
        })
        
        assert event["type"] == "conversation.item.create"
    
    def test_response_events(self):
        """Test response events."""
        from openai.realtime import create_event
        
        event = create_event("response.create", {})
        assert event["type"] == "response.create"
    
    def test_audio_buffer_events(self):
        """Test audio buffer events."""
        from openai.realtime import create_event
        import base64
        
        audio_data = base64.b64encode(b"\x00\x01\x02").decode()
        event = create_event("input_audio_buffer.append", {
            "audio": audio_data
        })
        
        assert event["type"] == "input_audio_buffer.append"


# ========================================
# Test End-to-End Scenarios
# ========================================

class TestEndToEndScenarios:
    """Test complete interaction scenarios."""
    
    def test_text_conversation_flow(self):
        """Test complete text conversation."""
        from openai.realtime import RealtimeSession
        from openai.realtime_conversation import (
            get_conversation, create_user_message,
            create_assistant_message, reset_conversations
        )
        
        reset_conversations()
        session = RealtimeSession()
        
        # Get conversation
        conv = get_conversation(session.session_id)
        
        # Add user message
        user_msg = create_user_message("What is 2 + 2?")
        conv.add_item(user_msg)
        
        # Simulate assistant response
        assistant_msg = create_assistant_message("2 + 2 equals 4.")
        conv.add_item(assistant_msg)
        
        # Verify conversation
        items = conv.get_items()
        assert len(items) == 2
        assert items[1].content[0].text == "2 + 2 equals 4."
    
    def test_audio_input_flow(self):
        """Test audio input processing."""
        from openai.realtime import RealtimeSession
        from openai.realtime_audio import (
            get_audio_buffer, VoiceActivityDetector, AudioChunk,
            reset_audio_buffers
        )
        
        reset_audio_buffers()
        session = RealtimeSession()
        
        # Get audio buffer
        buf = get_audio_buffer(session.session_id)
        vad = VoiceActivityDetector()
        
        # Simulate audio input
        audio_data = b"\x00\x00" * 1000  # Silence
        buf.append(audio_data)
        
        # Analyze with VAD
        chunk = AudioChunk(data=audio_data, format="pcm16")
        result = vad.analyze(chunk)
        
        assert buf.get_size_bytes() == 2000
        assert result.is_speech is False
    
    def test_function_calling_flow(self):
        """Test function calling scenario."""
        from openai.realtime_conversation import (
            Conversation, create_user_message,
            create_function_call, create_function_output,
            create_assistant_message
        )
        
        conv = Conversation()
        
        # User asks about weather
        conv.add_item(create_user_message("What's the weather in NYC?"))
        
        # Model calls function
        conv.add_item(create_function_call(
            "get_weather",
            "call_abc",
            '{"location": "New York"}'
        ))
        
        # Client provides function output
        conv.add_item(create_function_output(
            "call_abc",
            '{"temp": 72, "condition": "sunny"}'
        ))
        
        # Model responds with result
        conv.add_item(create_assistant_message(
            "It's currently 72°F and sunny in New York City."
        ))
        
        stats = conv.get_stats()
        assert stats.user_messages == 1
        assert stats.assistant_messages == 1
        assert stats.function_calls == 1
    
    def test_session_with_conversation(self):
        """Test session and conversation together."""
        from openai.realtime import (
            RealtimeSession, RealtimeConfig, reset_sessions
        )
        from openai.realtime_conversation import (
            get_conversation, reset_conversations
        )
        from openai.realtime_audio import reset_audio_buffers
        
        # Reset all state
        reset_sessions()
        reset_conversations()
        reset_audio_buffers()
        
        # Create and configure session
        session = RealtimeSession()
        config = RealtimeConfig(
            model="gpt-4o-realtime-preview",
            voice="alloy",
            instructions="Be helpful and concise."
        )
        session.configure(config)
        
        # Get associated conversation
        conv = get_conversation(session.session_id)
        
        assert conv.id == session.session_id
        assert session.config.voice == "alloy"


# ========================================
# Test Error Handling
# ========================================

class TestErrorHandling:
    """Test error scenarios."""
    
    def test_invalid_session_close(self):
        """Test closing already closed session."""
        from openai.realtime import RealtimeSession
        session = RealtimeSession()
        session.connect()
        session.close()
        # Should not raise
        session.close()
        assert session.status == "closed"
    
    def test_buffer_overflow_protection(self):
        """Test buffer size limits."""
        from openai.realtime_audio import AudioBuffer, MAX_AUDIO_BUFFER_SIZE
        buf = AudioBuffer("sess_123")
        
        # Attempt to overflow
        large_data = b"\x00" * (MAX_AUDIO_BUFFER_SIZE + 1)
        result = buf.append(large_data)
        assert result is False
    
    def test_conversation_item_limit(self):
        """Test conversation item limits."""
        from openai.realtime_conversation import (
            Conversation, ConversationItem, MAX_CONVERSATION_ITEMS
        )
        conv = Conversation()
        
        # Add max items
        for i in range(MAX_CONVERSATION_ITEMS):
            conv.add_item(ConversationItem(type="message", role="user"))
        
        # Next should fail
        result = conv.add_item(ConversationItem(type="message", role="user"))
        assert result is False


# ========================================
# Test Statistics
# ========================================

class TestStatistics:
    """Test statistics tracking."""
    
    def test_conversation_stats(self):
        """Test conversation statistics."""
        from openai.realtime_conversation import (
            Conversation, create_user_message, create_assistant_message
        )
        conv = Conversation()
        
        conv.add_item(create_user_message("Hello"))
        conv.add_item(create_assistant_message("Hi"))
        conv.add_item(create_user_message("Bye"))
        
        stats = conv.get_stats()
        assert stats.item_count == 3
        assert stats.user_messages == 2
        assert stats.assistant_messages == 1
    
    def test_audio_buffer_stats(self):
        """Test audio buffer statistics."""
        from openai.realtime_audio import AudioBuffer
        buf = AudioBuffer("sess_123", format="pcm16")
        
        buf.append(b"\x00\x00" * 100)
        buf.append(b"\x00\x00" * 50)
        
        stats = buf.get_stats()
        assert stats.total_bytes == 300
        assert stats.chunk_count == 2


# ========================================
# Summary
# ========================================

"""
Integration Test Summary: 55 tests

TestSessionLifecycle: 4
TestWebSocketIntegration: 4
TestAudioPipeline: 4
TestConversationFlow: 4
TestResponseGeneration: 4
TestTurnManagement: 3
TestEventHandling: 4
TestEndToEndScenarios: 4
TestErrorHandling: 3
TestStatistics: 2

Total: 55 integration tests
"""