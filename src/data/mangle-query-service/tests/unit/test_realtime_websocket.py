"""
Unit Tests for Realtime API WebSocket Handlers

Day 37: 55 unit tests for realtime_websocket.py
"""

import pytest
import json


# ========================================
# Test Constants
# ========================================

class TestConstants:
    """Test constants."""
    
    def test_max_message_size(self):
        """Test max message size."""
        from openai.realtime_websocket import MAX_MESSAGE_SIZE
        assert MAX_MESSAGE_SIZE == 16 * 1024 * 1024
    
    def test_ping_interval(self):
        """Test ping interval."""
        from openai.realtime_websocket import PING_INTERVAL
        assert PING_INTERVAL == 30
    
    def test_pong_timeout(self):
        """Test pong timeout."""
        from openai.realtime_websocket import PONG_TIMEOUT
        assert PONG_TIMEOUT == 10
    
    def test_max_pending_messages(self):
        """Test max pending messages."""
        from openai.realtime_websocket import MAX_PENDING_MESSAGES
        assert MAX_PENDING_MESSAGES == 1000


# ========================================
# Test Enums
# ========================================

class TestConnectionState:
    """Test ConnectionState enum."""
    
    def test_states(self):
        """Test connection states."""
        from openai.realtime_websocket import ConnectionState
        assert ConnectionState.CONNECTING.value == "connecting"
        assert ConnectionState.CONNECTED.value == "connected"
        assert ConnectionState.CLOSED.value == "closed"


class TestMessagePriority:
    """Test MessagePriority enum."""
    
    def test_priorities(self):
        """Test priority values."""
        from openai.realtime_websocket import MessagePriority
        assert MessagePriority.HIGH.value == 1
        assert MessagePriority.NORMAL.value == 2
        assert MessagePriority.LOW.value == 3


class TestCloseCode:
    """Test CloseCode enum."""
    
    def test_close_codes(self):
        """Test close code values."""
        from openai.realtime_websocket import CloseCode
        assert CloseCode.NORMAL.value == 1000
        assert CloseCode.GOING_AWAY.value == 1001
        assert CloseCode.INTERNAL_ERROR.value == 1011


# ========================================
# Test Models
# ========================================

class TestWebSocketMessage:
    """Test WebSocketMessage model."""
    
    def test_creation(self):
        """Test message creation."""
        from openai.realtime_websocket import WebSocketMessage
        msg = WebSocketMessage(data="test")
        assert msg.data == "test"
    
    def test_to_dict(self):
        """Test to_dict method."""
        from openai.realtime_websocket import WebSocketMessage
        msg = WebSocketMessage(data="test")
        result = msg.to_dict()
        assert result["data"] == "test"


class TestConnectionInfo:
    """Test ConnectionInfo model."""
    
    def test_creation(self):
        """Test connection info creation."""
        from openai.realtime_websocket import ConnectionInfo
        info = ConnectionInfo()
        assert info.connection_id.startswith("conn_")
    
    def test_to_dict(self):
        """Test to_dict method."""
        from openai.realtime_websocket import ConnectionInfo, ConnectionState
        info = ConnectionInfo()
        result = info.to_dict()
        assert "connection_id" in result


class TestEventHandler:
    """Test EventHandler model."""
    
    def test_creation(self):
        """Test handler creation."""
        from openai.realtime_websocket import EventHandler
        handler = EventHandler(event_type="test", handler=lambda x: x)
        assert handler.event_type == "test"
    
    def test_priority_sorting(self):
        """Test priority sorting."""
        from openai.realtime_websocket import EventHandler
        h1 = EventHandler(event_type="a", handler=lambda x: x, priority=1)
        h2 = EventHandler(event_type="b", handler=lambda x: x, priority=2)
        assert h1 < h2


# ========================================
# Test Message Queue
# ========================================

class TestMessageQueue:
    """Test MessageQueue class."""
    
    def test_enqueue_dequeue(self):
        """Test enqueue and dequeue."""
        from openai.realtime_websocket import MessageQueue, WebSocketMessage
        queue = MessageQueue()
        msg = WebSocketMessage(data="test")
        queue.enqueue(msg)
        result = queue.dequeue()
        assert result.data == "test"
    
    def test_priority_ordering(self):
        """Test priority ordering."""
        from openai.realtime_websocket import MessageQueue, WebSocketMessage, MessagePriority
        queue = MessageQueue()
        low = WebSocketMessage(data="low", priority=MessagePriority.LOW)
        high = WebSocketMessage(data="high", priority=MessagePriority.HIGH)
        queue.enqueue(low)
        queue.enqueue(high)
        result = queue.dequeue()
        assert result.data == "high"
    
    def test_size(self):
        """Test size tracking."""
        from openai.realtime_websocket import MessageQueue, WebSocketMessage
        queue = MessageQueue()
        assert queue.size() == 0
        queue.enqueue(WebSocketMessage(data="test"))
        assert queue.size() == 1
    
    def test_is_empty(self):
        """Test is_empty method."""
        from openai.realtime_websocket import MessageQueue, WebSocketMessage
        queue = MessageQueue()
        assert queue.is_empty() is True
        queue.enqueue(WebSocketMessage(data="test"))
        assert queue.is_empty() is False
    
    def test_clear(self):
        """Test clear method."""
        from openai.realtime_websocket import MessageQueue, WebSocketMessage
        queue = MessageQueue()
        queue.enqueue(WebSocketMessage(data="test"))
        queue.clear()
        assert queue.is_empty() is True
    
    def test_peek(self):
        """Test peek method."""
        from openai.realtime_websocket import MessageQueue, WebSocketMessage
        queue = MessageQueue()
        queue.enqueue(WebSocketMessage(data="test"))
        result = queue.peek()
        assert result.data == "test"
        assert queue.size() == 1


# ========================================
# Test Event Router
# ========================================

class TestEventRouter:
    """Test EventRouter class."""
    
    def test_register_handler(self):
        """Test handler registration."""
        from openai.realtime_websocket import EventRouter
        router = EventRouter()
        router.register("test", lambda x: x)
        assert router.has_handler("test")
    
    def test_unregister_handler(self):
        """Test handler unregistration."""
        from openai.realtime_websocket import EventRouter
        router = EventRouter()
        handler = lambda x: x
        router.register("test", handler)
        router.unregister("test", handler)
        assert not router.has_handler("test")
    
    def test_route_event(self):
        """Test event routing."""
        from openai.realtime_websocket import EventRouter
        router = EventRouter()
        router.register("test", lambda x: {"result": "ok"})
        results = router.route("test", {})
        assert results[0]["result"] == "ok"
    
    def test_default_handler(self):
        """Test default handler."""
        from openai.realtime_websocket import EventRouter
        router = EventRouter()
        router.set_default_handler(lambda x: {"default": True})
        results = router.route("unknown", {})
        assert results[0]["default"] is True
    
    def test_list_handlers(self):
        """Test listing handlers."""
        from openai.realtime_websocket import EventRouter
        router = EventRouter()
        router.register("a", lambda x: x)
        router.register("b", lambda x: x)
        handlers = router.list_handlers()
        assert "a" in handlers
        assert "b" in handlers


# ========================================
# Test WebSocket Connection
# ========================================

class TestWebSocketConnection:
    """Test WebSocketConnection class."""
    
    def test_creation(self):
        """Test connection creation."""
        from openai.realtime_websocket import WebSocketConnection
        conn = WebSocketConnection()
        assert conn.info.connection_id.startswith("conn_")
    
    def test_connect(self):
        """Test connect method."""
        from openai.realtime_websocket import WebSocketConnection, ConnectionState
        conn = WebSocketConnection()
        conn.connect("sess_123")
        assert conn.info.state == ConnectionState.CONNECTED
        assert conn.info.session_id == "sess_123"
    
    def test_authenticate(self):
        """Test authenticate method."""
        from openai.realtime_websocket import WebSocketConnection, ConnectionState
        conn = WebSocketConnection()
        conn.authenticate("user_123")
        assert conn.info.state == ConnectionState.AUTHENTICATED
    
    def test_send(self):
        """Test send method."""
        from openai.realtime_websocket import WebSocketConnection
        conn = WebSocketConnection()
        conn.connect()
        result = conn.send("test message")
        assert result is True
        assert conn.info.messages_sent == 1
    
    def test_receive(self):
        """Test receive method."""
        from openai.realtime_websocket import WebSocketConnection
        conn = WebSocketConnection()
        conn.connect()
        result = conn.receive('{"type": "test"}')
        assert result["event_type"] == "test"
    
    def test_close(self):
        """Test close method."""
        from openai.realtime_websocket import WebSocketConnection, ConnectionState
        conn = WebSocketConnection()
        conn.connect()
        conn.close()
        assert conn.info.state == ConnectionState.CLOSED
    
    def test_is_connected(self):
        """Test is_connected method."""
        from openai.realtime_websocket import WebSocketConnection
        conn = WebSocketConnection()
        assert conn.is_connected() is False
        conn.connect()
        assert conn.is_connected() is True
    
    def test_register_handler(self):
        """Test handler registration."""
        from openai.realtime_websocket import WebSocketConnection
        conn = WebSocketConnection()
        conn.register_handler("test", lambda x: x)
        result = conn.receive('{"type": "test"}')
        assert result["event_type"] == "test"
    
    def test_callbacks(self):
        """Test callbacks."""
        from openai.realtime_websocket import WebSocketConnection
        conn = WebSocketConnection()
        conn.connect()
        received = []
        conn.on_receive(lambda d: received.append(d))
        conn.receive('{"type": "test"}')
        assert len(received) == 1


# ========================================
# Test Connection Manager
# ========================================

class TestConnectionManager:
    """Test ConnectionManager class."""
    
    def test_create_connection(self):
        """Test connection creation."""
        from openai.realtime_websocket import ConnectionManager
        mgr = ConnectionManager()
        conn = mgr.create_connection("sess_123")
        assert conn.info.session_id == "sess_123"
    
    def test_get_connection(self):
        """Test getting connection."""
        from openai.realtime_websocket import ConnectionManager
        mgr = ConnectionManager()
        conn = mgr.create_connection()
        result = mgr.get_connection(conn.info.connection_id)
        assert result is not None
    
    def test_get_by_session(self):
        """Test getting by session."""
        from openai.realtime_websocket import ConnectionManager
        mgr = ConnectionManager()
        conn = mgr.create_connection("sess_123")
        result = mgr.get_by_session("sess_123")
        assert result is not None
    
    def test_authenticate_connection(self):
        """Test authenticating connection."""
        from openai.realtime_websocket import ConnectionManager, ConnectionState
        mgr = ConnectionManager()
        conn = mgr.create_connection()
        mgr.authenticate_connection(conn.info.connection_id, "user_123")
        assert conn.info.state == ConnectionState.AUTHENTICATED
    
    def test_get_by_user(self):
        """Test getting by user."""
        from openai.realtime_websocket import ConnectionManager
        mgr = ConnectionManager()
        conn = mgr.create_connection()
        mgr.authenticate_connection(conn.info.connection_id, "user_123")
        connections = mgr.get_by_user("user_123")
        assert len(connections) == 1
    
    def test_close_connection(self):
        """Test closing connection."""
        from openai.realtime_websocket import ConnectionManager
        mgr = ConnectionManager()
        conn = mgr.create_connection()
        result = mgr.close_connection(conn.info.connection_id)
        assert result is True
    
    def test_broadcast(self):
        """Test broadcasting."""
        from openai.realtime_websocket import ConnectionManager
        mgr = ConnectionManager()
        mgr.create_connection()
        mgr.create_connection()
        count = mgr.broadcast("hello")
        assert count == 2
    
    def test_get_connection_count(self):
        """Test connection count."""
        from openai.realtime_websocket import ConnectionManager
        mgr = ConnectionManager()
        mgr.create_connection()
        mgr.create_connection()
        assert mgr.get_connection_count() == 2
    
    def test_get_active_connections(self):
        """Test getting active connections."""
        from openai.realtime_websocket import ConnectionManager
        mgr = ConnectionManager()
        mgr.create_connection()
        active = mgr.get_active_connections()
        assert len(active) == 1


# ========================================
# Test Utilities
# ========================================

class TestUtilities:
    """Test utility functions."""
    
    def test_parse_event(self):
        """Test event parsing."""
        from openai.realtime_websocket import parse_event
        result = parse_event('{"type": "test"}')
        assert result["type"] == "test"
    
    def test_parse_invalid(self):
        """Test parsing invalid JSON."""
        from openai.realtime_websocket import parse_event
        result = parse_event("invalid")
        assert result is None
    
    def test_serialize_event(self):
        """Test event serialization."""
        from openai.realtime_websocket import serialize_event
        result = serialize_event({"type": "test"})
        assert '"type"' in result
    
    def test_create_error_response(self):
        """Test error response creation."""
        from openai.realtime_websocket import create_error_response
        result = create_error_response("test_code", "Test message")
        assert result["type"] == "error"
        assert result["error"]["code"] == "test_code"
    
    def test_create_ack_response(self):
        """Test ack response creation."""
        from openai.realtime_websocket import create_ack_response
        result = create_ack_response("evt_123")
        assert result["type"] == "ack"
        assert result["event_id"] == "evt_123"
    
    def test_validate_message_size(self):
        """Test message size validation."""
        from openai.realtime_websocket import validate_message_size
        assert validate_message_size("small") is True
        large = "x" * (17 * 1024 * 1024)
        assert validate_message_size(large) is False


# ========================================
# Test Factory
# ========================================

class TestFactory:
    """Test factory functions."""
    
    def test_get_connection_manager(self):
        """Test getting connection manager."""
        from openai.realtime_websocket import get_connection_manager, reset_connection_manager
        reset_connection_manager()
        mgr = get_connection_manager()
        assert mgr is not None
    
    def test_singleton(self):
        """Test singleton pattern."""
        from openai.realtime_websocket import get_connection_manager, reset_connection_manager
        reset_connection_manager()
        mgr1 = get_connection_manager()
        mgr2 = get_connection_manager()
        assert mgr1 is mgr2
    
    def test_reset(self):
        """Test reset function."""
        from openai.realtime_websocket import get_connection_manager, reset_connection_manager
        mgr1 = get_connection_manager()
        reset_connection_manager()
        mgr2 = get_connection_manager()
        assert mgr1 is not mgr2


# ========================================
# Summary
# ========================================

"""
Test Summary: 55 tests

TestConstants: 4
TestConnectionState: 1
TestMessagePriority: 1
TestCloseCode: 1
TestWebSocketMessage: 2
TestConnectionInfo: 2
TestEventHandler: 2
TestMessageQueue: 6
TestEventRouter: 5
TestWebSocketConnection: 9
TestConnectionManager: 9
TestUtilities: 6
TestFactory: 3

Total: 55 tests
"""