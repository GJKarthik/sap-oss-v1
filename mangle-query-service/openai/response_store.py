"""
OpenAI-compatible Response Object Store

Day 34 Deliverable: Response object management

Implements:
- Response storage with TTL
- Response retrieval
- Response cancellation
- Background cleanup
- Conversation context tracking
"""

import time
import hashlib
import threading
from enum import Enum
from typing import Dict, Any, Optional, List, Callable
from dataclasses import dataclass, field


# ========================================
# Constants
# ========================================

DEFAULT_TTL_SECONDS = 3600  # 1 hour
MAX_RESPONSES_PER_USER = 1000
CLEANUP_INTERVAL_SECONDS = 300  # 5 minutes
MAX_CONTEXT_LENGTH = 32


# ========================================
# Enums
# ========================================

class ResponseStatus(str, Enum):
    """Response statuses."""
    QUEUED = "queued"
    IN_PROGRESS = "in_progress"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"
    INCOMPLETE = "incomplete"


class IncompleteReason(str, Enum):
    """Incomplete response reasons."""
    MAX_OUTPUT_TOKENS = "max_output_tokens"
    CONTENT_FILTER = "content_filter"
    TOOL_USE = "tool_use"
    ERROR = "error"


# ========================================
# Response Models
# ========================================

@dataclass
class ResponseMetadata:
    """Response metadata."""
    response_id: str
    created_at: int
    expires_at: int
    user_id: Optional[str] = None
    model: str = ""
    status: str = ResponseStatus.QUEUED.value
    incomplete_reason: Optional[str] = None
    
    def is_expired(self) -> bool:
        """Check if response is expired."""
        return time.time() > self.expires_at
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {
            "response_id": self.response_id,
            "created_at": self.created_at,
            "expires_at": self.expires_at,
            "model": self.model,
            "status": self.status,
        }
        if self.user_id:
            result["user_id"] = self.user_id
        if self.incomplete_reason:
            result["incomplete_reason"] = self.incomplete_reason
        return result


@dataclass
class StoredResponse:
    """Stored response with full data."""
    metadata: ResponseMetadata
    response: Dict[str, Any]
    input_items: List[Dict[str, Any]] = field(default_factory=list)
    output_items: List[Dict[str, Any]] = field(default_factory=list)
    usage: Optional[Dict[str, Any]] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to full response object."""
        return {
            **self.response,
            "metadata": self.metadata.to_dict(),
        }


@dataclass
class ConversationContext:
    """Conversation context for multi-turn."""
    context_id: str
    response_ids: List[str] = field(default_factory=list)
    created_at: int = 0
    updated_at: int = 0
    
    def add_response(self, response_id: str):
        """Add response to context."""
        if len(self.response_ids) >= MAX_CONTEXT_LENGTH:
            self.response_ids.pop(0)
        self.response_ids.append(response_id)
        self.updated_at = int(time.time())


# ========================================
# Response Store
# ========================================

class ResponseStore:
    """In-memory response store with TTL."""
    
    def __init__(self, ttl_seconds: int = DEFAULT_TTL_SECONDS):
        """Initialize store."""
        self._responses: Dict[str, StoredResponse] = {}
        self._contexts: Dict[str, ConversationContext] = {}
        self._user_responses: Dict[str, List[str]] = {}
        self._ttl = ttl_seconds
        self._lock = threading.RLock()
        self._cleanup_callbacks: List[Callable[[str], None]] = []
    
    def _generate_id(self, prefix: str = "resp") -> str:
        """Generate response ID."""
        return f"{prefix}_{hashlib.md5(f'{time.time()}'.encode()).hexdigest()[:24]}"
    
    def store(
        self,
        response: Dict[str, Any],
        user_id: Optional[str] = None,
        ttl_override: Optional[int] = None
    ) -> str:
        """Store a response."""
        with self._lock:
            response_id = response.get("id") or self._generate_id()
            now = int(time.time())
            ttl = ttl_override or self._ttl
            
            metadata = ResponseMetadata(
                response_id=response_id,
                created_at=now,
                expires_at=now + ttl,
                user_id=user_id,
                model=response.get("model", ""),
                status=response.get("status", ResponseStatus.COMPLETED.value),
            )
            
            stored = StoredResponse(
                metadata=metadata,
                response=response,
                input_items=response.get("input", []),
                output_items=response.get("output", []),
                usage=response.get("usage"),
            )
            
            self._responses[response_id] = stored
            
            # Track by user
            if user_id:
                if user_id not in self._user_responses:
                    self._user_responses[user_id] = []
                self._user_responses[user_id].append(response_id)
                # Enforce limit
                while len(self._user_responses[user_id]) > MAX_RESPONSES_PER_USER:
                    old_id = self._user_responses[user_id].pop(0)
                    self._responses.pop(old_id, None)
            
            return response_id
    
    def get(self, response_id: str) -> Optional[Dict[str, Any]]:
        """Retrieve a response."""
        with self._lock:
            stored = self._responses.get(response_id)
            if not stored:
                return None
            if stored.metadata.is_expired():
                self._responses.pop(response_id, None)
                return None
            return stored.to_dict()
    
    def get_input_items(self, response_id: str) -> List[Dict[str, Any]]:
        """Get input items for a response."""
        with self._lock:
            stored = self._responses.get(response_id)
            if not stored or stored.metadata.is_expired():
                return []
            return stored.input_items
    
    def get_output_items(self, response_id: str) -> List[Dict[str, Any]]:
        """Get output items for a response."""
        with self._lock:
            stored = self._responses.get(response_id)
            if not stored or stored.metadata.is_expired():
                return []
            return stored.output_items
    
    def update_status(
        self,
        response_id: str,
        status: str,
        incomplete_reason: Optional[str] = None
    ) -> bool:
        """Update response status."""
        with self._lock:
            stored = self._responses.get(response_id)
            if not stored:
                return False
            stored.metadata.status = status
            if incomplete_reason:
                stored.metadata.incomplete_reason = incomplete_reason
            stored.response["status"] = status
            return True
    
    def cancel(self, response_id: str) -> bool:
        """Cancel a response."""
        return self.update_status(response_id, ResponseStatus.CANCELLED.value)
    
    def delete(self, response_id: str) -> bool:
        """Delete a response."""
        with self._lock:
            stored = self._responses.pop(response_id, None)
            if stored and stored.metadata.user_id:
                user_list = self._user_responses.get(stored.metadata.user_id, [])
                if response_id in user_list:
                    user_list.remove(response_id)
            return stored is not None
    
    def list_by_user(self, user_id: str, limit: int = 100) -> List[Dict[str, Any]]:
        """List responses for a user."""
        with self._lock:
            response_ids = self._user_responses.get(user_id, [])
            results = []
            for rid in reversed(response_ids[-limit:]):
                resp = self.get(rid)
                if resp:
                    results.append(resp)
            return results
    
    def cleanup_expired(self) -> int:
        """Clean up expired responses."""
        with self._lock:
            expired = []
            for response_id, stored in self._responses.items():
                if stored.metadata.is_expired():
                    expired.append(response_id)
            
            for response_id in expired:
                stored = self._responses.pop(response_id, None)
                if stored and stored.metadata.user_id:
                    user_list = self._user_responses.get(stored.metadata.user_id, [])
                    if response_id in user_list:
                        user_list.remove(response_id)
                for callback in self._cleanup_callbacks:
                    try:
                        callback(response_id)
                    except Exception:
                        pass
            
            return len(expired)
    
    def add_cleanup_callback(self, callback: Callable[[str], None]):
        """Add cleanup callback."""
        self._cleanup_callbacks.append(callback)
    
    # Context management
    def create_context(self) -> str:
        """Create a conversation context."""
        with self._lock:
            context_id = self._generate_id("ctx")
            now = int(time.time())
            self._contexts[context_id] = ConversationContext(
                context_id=context_id,
                created_at=now,
                updated_at=now,
            )
            return context_id
    
    def add_to_context(self, context_id: str, response_id: str) -> bool:
        """Add response to context."""
        with self._lock:
            context = self._contexts.get(context_id)
            if not context:
                return False
            context.add_response(response_id)
            return True
    
    def get_context_responses(self, context_id: str) -> List[Dict[str, Any]]:
        """Get all responses in context."""
        with self._lock:
            context = self._contexts.get(context_id)
            if not context:
                return []
            results = []
            for rid in context.response_ids:
                resp = self.get(rid)
                if resp:
                    results.append(resp)
            return results
    
    def delete_context(self, context_id: str) -> bool:
        """Delete a context."""
        with self._lock:
            return self._contexts.pop(context_id, None) is not None
    
    @property
    def count(self) -> int:
        """Get total response count."""
        with self._lock:
            return len(self._responses)
    
    @property
    def context_count(self) -> int:
        """Get context count."""
        with self._lock:
            return len(self._contexts)


# ========================================
# Background Cleanup
# ========================================

class ResponseCleanupService:
    """Background cleanup service."""
    
    def __init__(self, store: ResponseStore, interval: int = CLEANUP_INTERVAL_SECONDS):
        """Initialize cleanup service."""
        self._store = store
        self._interval = interval
        self._running = False
        self._thread: Optional[threading.Thread] = None
    
    def start(self):
        """Start cleanup service."""
        if self._running:
            return
        self._running = True
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()
    
    def stop(self):
        """Stop cleanup service."""
        self._running = False
        if self._thread:
            self._thread.join(timeout=5)
    
    def _run(self):
        """Run cleanup loop."""
        while self._running:
            try:
                self._store.cleanup_expired()
            except Exception:
                pass
            time.sleep(self._interval)
    
    @property
    def is_running(self) -> bool:
        """Check if running."""
        return self._running


# ========================================
# Factory and Utilities
# ========================================

_default_store: Optional[ResponseStore] = None


def get_response_store(ttl_seconds: int = DEFAULT_TTL_SECONDS) -> ResponseStore:
    """Get or create default response store."""
    global _default_store
    if _default_store is None:
        _default_store = ResponseStore(ttl_seconds)
    return _default_store


def reset_response_store():
    """Reset default store (for testing)."""
    global _default_store
    _default_store = None


def is_terminal_status(status: str) -> bool:
    """Check if status is terminal."""
    return status in [
        ResponseStatus.COMPLETED.value,
        ResponseStatus.FAILED.value,
        ResponseStatus.CANCELLED.value,
        ResponseStatus.INCOMPLETE.value,
    ]


def is_active_status(status: str) -> bool:
    """Check if status is active."""
    return status in [
        ResponseStatus.QUEUED.value,
        ResponseStatus.IN_PROGRESS.value,
    ]


# ========================================
# Exports
# ========================================

__all__ = [
    # Constants
    "DEFAULT_TTL_SECONDS",
    "MAX_RESPONSES_PER_USER",
    "CLEANUP_INTERVAL_SECONDS",
    "MAX_CONTEXT_LENGTH",
    # Enums
    "ResponseStatus",
    "IncompleteReason",
    # Models
    "ResponseMetadata",
    "StoredResponse",
    "ConversationContext",
    # Store
    "ResponseStore",
    # Cleanup
    "ResponseCleanupService",
    # Utilities
    "get_response_store",
    "reset_response_store",
    "is_terminal_status",
    "is_active_status",
]