"""
OpenAI Realtime API WebSocket Handlers

Day 37: WebSocket connection management and event routing
"""

from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Callable, Optional
import json
import time
import uuid
import asyncio
from collections import deque


# ========================================
# Constants
# ========================================

MAX_MESSAGE_SIZE = 16 * 1024 * 1024  # 16MB
PING_INTERVAL = 30  # seconds
PONG_TIMEOUT = 10  # seconds
MAX_PENDING_MESSAGES = 1000
RECONNECT_DELAY = 1.0  # seconds
MAX_RECONNECT_ATTEMPTS = 5


# ========================================
# Enums
# ========================================

class ConnectionState(Enum):
    """WebSocket connection states."""
    CONNECTING = "connecting"
    CONNECTED = "connected"
    AUTHENTICATED = "authenticated"
    CLOSING = "closing"
    CLOSED = "closed"
    ERROR = "error"


class MessagePriority(Enum):
    """Message priority levels."""
    HIGH = 1
    NORMAL = 2
    LOW = 3


class CloseCode(Enum):
    """WebSocket close codes."""
    NORMAL = 1000
    GOING_AWAY = 1001
    PROTOCOL_ERROR = 1002
    UNSUPPORTED = 1003
    NO_STATUS = 1005
    ABNORMAL = 1006
    INVALID_PAYLOAD = 1007
    POLICY_VIOLATION = 1008
    MESSAGE_TOO_BIG = 1009
    EXTENSION_ERROR = 1010
    INTERNAL_ERROR = 1011
    SERVICE_RESTART = 1012
    TRY_AGAIN_LATER = 1013


# ========================================
# Models
# ========================================

@dataclass
class WebSocketMessage:
    """WebSocket message wrapper."""
    data: str
    timestamp: float = field(default_factory=time.time)
    message_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    priority: MessagePriority = MessagePriority.NORMAL
    
    def to_dict(self) -> dict:
        return {
            "data": self.data,
            "timestamp": self.timestamp,
            "message_id": self.message_id,
            "priority": self.priority.value,
        }


@dataclass
class ConnectionInfo:
    """Connection information."""
    connection_id: str = field(default_factory=lambda: f"conn_{uuid.uuid4().hex[:16]}")
    session_id: Optional[str] = None
    user_id: Optional[str] = None
    state: ConnectionState = ConnectionState.CONNECTING
    connected_at: float = field(default_factory=time.time)
    last_ping: Optional[float] = None
    last_pong: Optional[float] = None
    messages_sent: int = 0
    messages_received: int = 0
    bytes_sent: int = 0
    bytes_received: int = 0
    
    def to_dict(self) -> dict:
        return {
            "connection_id": self.connection_id,
            "session_id": self.session_id,
            "user_id": self.user_id,
            "state": self.state.value,
            "connected_at": self.connected_at,
            "messages_sent": self.messages_sent,
            "messages_received": self.messages_received,
        }


@dataclass
class EventHandler:
    """Event handler registration."""
    event_type: str
    handler: Callable
    priority: int = 0
    
    def __lt__(self, other):
        return self.priority < other.priority


@dataclass
class PendingMessage:
    """Message waiting to be sent."""
    message: WebSocketMessage
    retries: int = 0
    max_retries: int = 3
    created_at: float = field(default_factory=time.time)


# ========================================
# Message Queue
# ========================================

class MessageQueue:
    """Priority message queue."""
    
    def __init__(self, max_size: int = MAX_PENDING_MESSAGES):
        self._queues: dict[MessagePriority, deque] = {
            MessagePriority.HIGH: deque(maxlen=max_size),
            MessagePriority.NORMAL: deque(maxlen=max_size),
            MessagePriority.LOW: deque(maxlen=max_size),
        }
        self._size = 0
    
    def enqueue(self, message: WebSocketMessage) -> bool:
        """Add message to queue."""
        if self._size >= MAX_PENDING_MESSAGES:
            return False
        self._queues[message.priority].append(message)
        self._size += 1
        return True
    
    def dequeue(self) -> Optional[WebSocketMessage]:
        """Get highest priority message."""
        for priority in MessagePriority:
            queue = self._queues[priority]
            if queue:
                self._size -= 1
                return queue.popleft()
        return None
    
    def peek(self) -> Optional[WebSocketMessage]:
        """Peek at highest priority message."""
        for priority in MessagePriority:
            queue = self._queues[priority]
            if queue:
                return queue[0]
        return None
    
    def size(self) -> int:
        return self._size
    
    def is_empty(self) -> bool:
        return self._size == 0
    
    def clear(self) -> None:
        for queue in self._queues.values():
            queue.clear()
        self._size = 0


# ========================================
# Event Router
# ========================================

class EventRouter:
    """Route events to handlers."""
    
    def __init__(self):
        self._handlers: dict[str, list[EventHandler]] = {}
        self._default_handler: Optional[Callable] = None
    
    def register(self, event_type: str, handler: Callable, priority: int = 0) -> None:
        """Register an event handler."""
        if event_type not in self._handlers:
            self._handlers[event_type] = []
        self._handlers[event_type].append(EventHandler(event_type, handler, priority))
        self._handlers[event_type].sort()
    
    def unregister(self, event_type: str, handler: Callable) -> bool:
        """Unregister an event handler."""
        if event_type not in self._handlers:
            return False
        for i, eh in enumerate(self._handlers[event_type]):
            if eh.handler == handler:
                self._handlers[event_type].pop(i)
                return True
        return False
    
    def set_default_handler(self, handler: Callable) -> None:
        """Set default handler for unregistered events."""
        self._default_handler = handler
    
    def route(self, event_type: str, event_data: dict) -> list:
        """Route event to handlers and return results."""
        results = []
        handlers = self._handlers.get(event_type, [])
        if handlers:
            for eh in handlers:
                try:
                    result = eh.handler(event_data)
                    results.append(result)
                except Exception as e:
                    results.append({"error": str(e)})
        elif self._default_handler:
            try:
                result = self._default_handler(event_data)
                results.append(result)
            except Exception as e:
                results.append({"error": str(e)})
        return results
    
    def has_handler(self, event_type: str) -> bool:
        """Check if handler exists for event type."""
        return event_type in self._handlers and len(self._handlers[event_type]) > 0
    
    def list_handlers(self) -> dict[str, int]:
        """List registered handlers by event type."""
        return {et: len(handlers) for et, handlers in self._handlers.items()}


# ========================================
# WebSocket Connection
# ========================================

class WebSocketConnection:
    """WebSocket connection wrapper."""
    
    def __init__(self, connection_id: Optional[str] = None):
        self.info = ConnectionInfo()
        if connection_id:
            self.info.connection_id = connection_id
        self._message_queue = MessageQueue()
        self._event_router = EventRouter()
        self._send_callbacks: list[Callable] = []
        self._receive_callbacks: list[Callable] = []
        self._close_callbacks: list[Callable] = []
        self._error_callbacks: list[Callable] = []
    
    def connect(self, session_id: Optional[str] = None) -> bool:
        """Mark connection as connected."""
        self.info.state = ConnectionState.CONNECTED
        self.info.session_id = session_id
        return True
    
    def authenticate(self, user_id: str) -> bool:
        """Mark connection as authenticated."""
        self.info.state = ConnectionState.AUTHENTICATED
        self.info.user_id = user_id
        return True
    
    def send(self, data: str, priority: MessagePriority = MessagePriority.NORMAL) -> bool:
        """Queue message for sending."""
        message = WebSocketMessage(data=data, priority=priority)
        result = self._message_queue.enqueue(message)
        if result:
            self.info.messages_sent += 1
            self.info.bytes_sent += len(data)
            for callback in self._send_callbacks:
                try:
                    callback(message)
                except Exception:
                    pass
        return result
    
    def receive(self, data: str) -> dict:
        """Process received message."""
        self.info.messages_received += 1
        self.info.bytes_received += len(data)
        
        for callback in self._receive_callbacks:
            try:
                callback(data)
            except Exception:
                pass
        
        try:
            event = json.loads(data)
            event_type = event.get("type", "unknown")
            results = self._event_router.route(event_type, event)
            return {"event_type": event_type, "results": results}
        except json.JSONDecodeError:
            return {"error": "invalid_json"}
    
    def close(self, code: CloseCode = CloseCode.NORMAL, reason: str = "") -> None:
        """Close the connection."""
        self.info.state = ConnectionState.CLOSED
        for callback in self._close_callbacks:
            try:
                callback(code, reason)
            except Exception:
                pass
    
    def on_send(self, callback: Callable) -> None:
        """Register send callback."""
        self._send_callbacks.append(callback)
    
    def on_receive(self, callback: Callable) -> None:
        """Register receive callback."""
        self._receive_callbacks.append(callback)
    
    def on_close(self, callback: Callable) -> None:
        """Register close callback."""
        self._close_callbacks.append(callback)
    
    def on_error(self, callback: Callable) -> None:
        """Register error callback."""
        self._error_callbacks.append(callback)
    
    def register_handler(self, event_type: str, handler: Callable) -> None:
        """Register event handler."""
        self._event_router.register(event_type, handler)
    
    def get_pending_count(self) -> int:
        """Get pending message count."""
        return self._message_queue.size()
    
    def is_connected(self) -> bool:
        """Check if connected."""
        return self.info.state in (ConnectionState.CONNECTED, ConnectionState.AUTHENTICATED)


# ========================================
# Connection Manager
# ========================================

class ConnectionManager:
    """Manage multiple WebSocket connections."""
    
    def __init__(self):
        self._connections: dict[str, WebSocketConnection] = {}
        self._session_connections: dict[str, str] = {}  # session_id -> connection_id
        self._user_connections: dict[str, list[str]] = {}  # user_id -> [connection_ids]
    
    def create_connection(self, session_id: Optional[str] = None) -> WebSocketConnection:
        """Create a new connection."""
        conn = WebSocketConnection()
        conn.connect(session_id)
        self._connections[conn.info.connection_id] = conn
        if session_id:
            self._session_connections[session_id] = conn.info.connection_id
        return conn
    
    def get_connection(self, connection_id: str) -> Optional[WebSocketConnection]:
        """Get connection by ID."""
        return self._connections.get(connection_id)
    
    def get_by_session(self, session_id: str) -> Optional[WebSocketConnection]:
        """Get connection by session ID."""
        conn_id = self._session_connections.get(session_id)
        if conn_id:
            return self._connections.get(conn_id)
        return None
    
    def get_by_user(self, user_id: str) -> list[WebSocketConnection]:
        """Get all connections for a user."""
        conn_ids = self._user_connections.get(user_id, [])
        return [self._connections[cid] for cid in conn_ids if cid in self._connections]
    
    def authenticate_connection(self, connection_id: str, user_id: str) -> bool:
        """Authenticate a connection."""
        conn = self._connections.get(connection_id)
        if not conn:
            return False
        conn.authenticate(user_id)
        if user_id not in self._user_connections:
            self._user_connections[user_id] = []
        self._user_connections[user_id].append(connection_id)
        return True
    
    def close_connection(self, connection_id: str, code: CloseCode = CloseCode.NORMAL) -> bool:
        """Close and remove a connection."""
        conn = self._connections.get(connection_id)
        if not conn:
            return False
        conn.close(code)
        
        # Cleanup mappings
        if conn.info.session_id:
            self._session_connections.pop(conn.info.session_id, None)
        if conn.info.user_id and conn.info.user_id in self._user_connections:
            self._user_connections[conn.info.user_id] = [
                cid for cid in self._user_connections[conn.info.user_id]
                if cid != connection_id
            ]
        
        del self._connections[connection_id]
        return True
    
    def broadcast(self, message: str, user_id: Optional[str] = None) -> int:
        """Broadcast message to connections."""
        count = 0
        if user_id:
            connections = self.get_by_user(user_id)
        else:
            connections = list(self._connections.values())
        
        for conn in connections:
            if conn.is_connected() and conn.send(message):
                count += 1
        return count
    
    def get_connection_count(self) -> int:
        """Get total connection count."""
        return len(self._connections)
    
    def get_active_connections(self) -> list[WebSocketConnection]:
        """Get all active connections."""
        return [c for c in self._connections.values() if c.is_connected()]
    
    def cleanup_stale_connections(self, max_age: float = 3600) -> int:
        """Remove stale connections."""
        now = time.time()
        stale = [
            cid for cid, conn in self._connections.items()
            if now - conn.info.connected_at > max_age and not conn.is_connected()
        ]
        for cid in stale:
            self.close_connection(cid)
        return len(stale)


# ========================================
# Factory
# ========================================

_connection_manager = None


def get_connection_manager() -> ConnectionManager:
    """Get or create connection manager."""
    global _connection_manager
    if _connection_manager is None:
        _connection_manager = ConnectionManager()
    return _connection_manager


def reset_connection_manager() -> None:
    """Reset connection manager."""
    global _connection_manager
    _connection_manager = None


# ========================================
# Utilities
# ========================================

def parse_event(data: str) -> Optional[dict]:
    """Parse event from JSON string."""
    try:
        return json.loads(data)
    except json.JSONDecodeError:
        return None


def serialize_event(event: dict) -> str:
    """Serialize event to JSON string."""
    return json.dumps(event)


def create_error_response(code: str, message: str) -> dict:
    """Create error response event."""
    return {
        "type": "error",
        "error": {
            "type": "error",
            "code": code,
            "message": message,
        },
    }


def create_ack_response(event_id: str) -> dict:
    """Create acknowledgement response."""
    return {
        "type": "ack",
        "event_id": event_id,
    }


def validate_message_size(data: str) -> bool:
    """Validate message size."""
    return len(data.encode()) <= MAX_MESSAGE_SIZE