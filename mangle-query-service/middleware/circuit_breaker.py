"""
Circuit Breaker Pattern Implementation

Day 3 Deliverable: Prevent cascade failures in distributed systems
- Three states: CLOSED, OPEN, HALF-OPEN
- Configurable failure threshold
- Automatic recovery with timeout
- Per-backend circuit breakers

Based on Michael Nygard's "Release It!" pattern.
"""

import asyncio
import time
import logging
from enum import Enum
from typing import Optional, Callable, TypeVar, Awaitable, Dict, Any
from dataclasses import dataclass, field
from functools import wraps
import threading

logger = logging.getLogger(__name__)


# ========================================
# Circuit Breaker State
# ========================================

class CircuitState(Enum):
    """Circuit breaker states."""
    CLOSED = "closed"      # Normal operation, requests pass through
    OPEN = "open"          # Circuit tripped, requests fail fast
    HALF_OPEN = "half_open"  # Testing if backend recovered


# ========================================
# Configuration
# ========================================

@dataclass
class CircuitBreakerConfig:
    """Circuit breaker configuration."""
    
    # Failure threshold to trip circuit (CLOSED → OPEN)
    failure_threshold: int = 5
    
    # Success threshold to close circuit (HALF_OPEN → CLOSED)
    success_threshold: int = 2
    
    # Recovery timeout in seconds (OPEN → HALF_OPEN)
    recovery_timeout: float = 30.0
    
    # Sliding window for counting failures (seconds)
    failure_window: float = 60.0
    
    # Exceptions that count as failures
    failure_exceptions: tuple = field(default_factory=lambda: (
        Exception,  # All exceptions by default
    ))
    
    # Status codes that count as failures
    failure_status_codes: set = field(default_factory=lambda: {
        500, 502, 503, 504,  # Server errors
    })
    
    # Whether to track individual backends
    per_backend: bool = True
    
    @classmethod
    def strict(cls) -> "CircuitBreakerConfig":
        """Strict config - opens faster."""
        return cls(
            failure_threshold=3,
            success_threshold=3,
            recovery_timeout=60.0,
        )
    
    @classmethod
    def lenient(cls) -> "CircuitBreakerConfig":
        """Lenient config - more tolerant."""
        return cls(
            failure_threshold=10,
            success_threshold=1,
            recovery_timeout=15.0,
        )


# ========================================
# Circuit Breaker Exception
# ========================================

class CircuitBreakerOpen(Exception):
    """Exception raised when circuit breaker is open."""
    
    def __init__(
        self,
        backend: str,
        time_until_recovery: float,
        message: Optional[str] = None,
    ):
        self.backend = backend
        self.time_until_recovery = time_until_recovery
        super().__init__(
            message or f"Circuit breaker open for {backend}, retry after {time_until_recovery:.1f}s"
        )


# ========================================
# Circuit Breaker State Machine
# ========================================

@dataclass
class CircuitBreakerState:
    """Internal state for a circuit breaker."""
    
    # Current state
    state: CircuitState = CircuitState.CLOSED
    
    # Failure timestamps in current window
    failure_timestamps: list = field(default_factory=list)
    
    # Consecutive successes (for HALF_OPEN → CLOSED)
    consecutive_successes: int = 0
    
    # Time when circuit opened (for recovery timeout)
    opened_at: Optional[float] = None
    
    # Statistics
    total_failures: int = 0
    total_successes: int = 0
    times_opened: int = 0
    
    # Lock for thread safety
    _lock: threading.Lock = field(default_factory=threading.Lock)
    
    def __post_init__(self):
        # Ensure lock is created if not present
        if not hasattr(self, '_lock') or self._lock is None:
            object.__setattr__(self, '_lock', threading.Lock())


class CircuitBreaker:
    """
    Circuit breaker implementation.
    
    State machine:
    
    CLOSED --[failure threshold]--> OPEN
    OPEN --[recovery timeout]--> HALF_OPEN
    HALF_OPEN --[success threshold]--> CLOSED
    HALF_OPEN --[any failure]--> OPEN
    """
    
    def __init__(self, config: Optional[CircuitBreakerConfig] = None):
        self.config = config or CircuitBreakerConfig()
        self._states: Dict[str, CircuitBreakerState] = {}
        self._global_lock = threading.Lock()
    
    def _get_state(self, backend: str) -> CircuitBreakerState:
        """Get or create state for backend."""
        if backend not in self._states:
            with self._global_lock:
                if backend not in self._states:
                    self._states[backend] = CircuitBreakerState()
        return self._states[backend]
    
    def get_state(self, backend: str) -> CircuitState:
        """Get current state for backend."""
        state = self._get_state(backend)
        self._update_state(state)
        return state.state
    
    def _update_state(self, state: CircuitBreakerState) -> None:
        """Update state based on time (recovery timeout)."""
        with state._lock:
            if state.state == CircuitState.OPEN:
                if state.opened_at is not None:
                    elapsed = time.time() - state.opened_at
                    if elapsed >= self.config.recovery_timeout:
                        state.state = CircuitState.HALF_OPEN
                        state.consecutive_successes = 0
                        logger.info(
                            f"Circuit breaker transitioning to HALF_OPEN after {elapsed:.1f}s"
                        )
    
    def _prune_old_failures(self, state: CircuitBreakerState) -> None:
        """Remove failures outside the sliding window."""
        cutoff = time.time() - self.config.failure_window
        state.failure_timestamps = [
            ts for ts in state.failure_timestamps if ts > cutoff
        ]
    
    def can_execute(self, backend: str) -> bool:
        """Check if request can be executed."""
        state = self._get_state(backend)
        self._update_state(state)
        
        with state._lock:
            if state.state == CircuitState.CLOSED:
                return True
            elif state.state == CircuitState.HALF_OPEN:
                return True  # Allow test requests
            else:  # OPEN
                return False
    
    def record_success(self, backend: str) -> None:
        """Record a successful request."""
        state = self._get_state(backend)
        
        with state._lock:
            state.total_successes += 1
            
            if state.state == CircuitState.HALF_OPEN:
                state.consecutive_successes += 1
                
                if state.consecutive_successes >= self.config.success_threshold:
                    state.state = CircuitState.CLOSED
                    state.failure_timestamps.clear()
                    state.opened_at = None
                    logger.info(
                        f"Circuit breaker CLOSED after {state.consecutive_successes} successes"
                    )
    
    def record_failure(self, backend: str, exception: Optional[Exception] = None) -> None:
        """Record a failed request."""
        state = self._get_state(backend)
        
        with state._lock:
            state.total_failures += 1
            
            if state.state == CircuitState.HALF_OPEN:
                # Any failure in HALF_OPEN immediately opens circuit
                state.state = CircuitState.OPEN
                state.opened_at = time.time()
                state.times_opened += 1
                logger.warning(
                    f"Circuit breaker OPEN after failure in HALF_OPEN state"
                )
            
            elif state.state == CircuitState.CLOSED:
                state.failure_timestamps.append(time.time())
                self._prune_old_failures(state)
                
                if len(state.failure_timestamps) >= self.config.failure_threshold:
                    state.state = CircuitState.OPEN
                    state.opened_at = time.time()
                    state.times_opened += 1
                    logger.warning(
                        f"Circuit breaker OPEN after {len(state.failure_timestamps)} failures"
                    )
    
    def time_until_recovery(self, backend: str) -> float:
        """Get time until circuit might recover."""
        state = self._get_state(backend)
        
        with state._lock:
            if state.state != CircuitState.OPEN:
                return 0.0
            
            if state.opened_at is None:
                return self.config.recovery_timeout
            
            elapsed = time.time() - state.opened_at
            remaining = self.config.recovery_timeout - elapsed
            return max(0.0, remaining)
    
    def get_stats(self, backend: str) -> Dict[str, Any]:
        """Get circuit breaker statistics."""
        state = self._get_state(backend)
        self._update_state(state)
        
        with state._lock:
            return {
                "backend": backend,
                "state": state.state.value,
                "total_failures": state.total_failures,
                "total_successes": state.total_successes,
                "times_opened": state.times_opened,
                "failures_in_window": len(state.failure_timestamps),
                "consecutive_successes": state.consecutive_successes,
                "time_until_recovery": self.time_until_recovery(backend),
            }
    
    def reset(self, backend: str) -> None:
        """Manually reset circuit breaker."""
        with self._global_lock:
            if backend in self._states:
                del self._states[backend]
        logger.info(f"Circuit breaker reset for {backend}")


# ========================================
# Async Context Manager
# ========================================

class CircuitBreakerContext:
    """
    Context manager for circuit breaker.
    
    Usage:
        cb = CircuitBreaker()
        
        async with CircuitBreakerContext(cb, "backend") as ctx:
            response = await http_client.get(url)
            if response.status_code >= 500:
                ctx.mark_failure()
    """
    
    def __init__(
        self,
        circuit_breaker: CircuitBreaker,
        backend: str,
    ):
        self.cb = circuit_breaker
        self.backend = backend
        self._failed = False
    
    async def __aenter__(self):
        if not self.cb.can_execute(self.backend):
            recovery_time = self.cb.time_until_recovery(self.backend)
            raise CircuitBreakerOpen(self.backend, recovery_time)
        return self
    
    async def __aexit__(self, exc_type, exc_val, exc_tb):
        if self._failed or exc_type is not None:
            self.cb.record_failure(self.backend, exc_val)
        else:
            self.cb.record_success(self.backend)
        return False  # Don't suppress exceptions
    
    def mark_failure(self):
        """Manually mark request as failed."""
        self._failed = True


# ========================================
# Decorator
# ========================================

T = TypeVar("T")


def with_circuit_breaker(
    circuit_breaker: CircuitBreaker,
    backend: str,
):
    """
    Decorator to wrap function with circuit breaker.
    
    Usage:
        cb = CircuitBreaker()
        
        @with_circuit_breaker(cb, "backend-api")
        async def call_backend():
            return await http_client.get(url)
    """
    def decorator(func: Callable[..., Awaitable[T]]) -> Callable[..., Awaitable[T]]:
        @wraps(func)
        async def wrapper(*args, **kwargs) -> T:
            async with CircuitBreakerContext(circuit_breaker, backend):
                return await func(*args, **kwargs)
        return wrapper
    return decorator


# ========================================
# HTTP Client Integration
# ========================================

class CircuitBreakerHTTPClient:
    """
    HTTP client wrapper with circuit breaker.
    
    Automatically tracks failures and successes per backend.
    
    Usage:
        from connectors.http_client import AsyncHTTPClient
        
        http_client = AsyncHTTPClient()
        cb_client = CircuitBreakerHTTPClient(http_client, CircuitBreakerConfig())
        
        response = await cb_client.post("http://backend:8080/api", json=data)
    """
    
    def __init__(
        self,
        http_client,
        config: Optional[CircuitBreakerConfig] = None,
    ):
        self.http_client = http_client
        self.cb = CircuitBreaker(config)
    
    def _extract_backend(self, url: str) -> str:
        """Extract backend identifier from URL."""
        # Simple extraction: scheme://host:port
        from urllib.parse import urlparse
        parsed = urlparse(url)
        return f"{parsed.scheme}://{parsed.netloc}"
    
    async def request(
        self,
        method: str,
        url: str,
        **kwargs,
    ):
        """Make HTTP request with circuit breaker."""
        backend = self._extract_backend(url)
        
        async with CircuitBreakerContext(self.cb, backend) as ctx:
            response = await self.http_client.request(method, url, **kwargs)
            
            # Check if response indicates failure
            if hasattr(response, 'status_code'):
                if response.status_code in self.cb.config.failure_status_codes:
                    ctx.mark_failure()
            
            return response
    
    async def get(self, url: str, **kwargs):
        """GET with circuit breaker."""
        return await self.request("GET", url, **kwargs)
    
    async def post(self, url: str, **kwargs):
        """POST with circuit breaker."""
        return await self.request("POST", url, **kwargs)
    
    async def put(self, url: str, **kwargs):
        """PUT with circuit breaker."""
        return await self.request("PUT", url, **kwargs)
    
    async def delete(self, url: str, **kwargs):
        """DELETE with circuit breaker."""
        return await self.request("DELETE", url, **kwargs)
    
    def get_all_stats(self) -> Dict[str, Dict[str, Any]]:
        """Get statistics for all backends."""
        return {
            backend: self.cb.get_stats(backend)
            for backend in self.cb._states.keys()
        }


# ========================================
# Global Circuit Breaker Registry
# ========================================

class CircuitBreakerRegistry:
    """
    Registry for managing multiple circuit breakers.
    
    Useful for having different configs per backend type.
    """
    
    def __init__(self):
        self._breakers: Dict[str, CircuitBreaker] = {}
        self._lock = threading.Lock()
    
    def get_or_create(
        self,
        name: str,
        config: Optional[CircuitBreakerConfig] = None,
    ) -> CircuitBreaker:
        """Get or create circuit breaker by name."""
        if name not in self._breakers:
            with self._lock:
                if name not in self._breakers:
                    self._breakers[name] = CircuitBreaker(config)
        return self._breakers[name]
    
    def get(self, name: str) -> Optional[CircuitBreaker]:
        """Get circuit breaker by name."""
        return self._breakers.get(name)
    
    def reset(self, name: str, backend: Optional[str] = None) -> None:
        """Reset circuit breaker(s)."""
        if name in self._breakers:
            if backend:
                self._breakers[name].reset(backend)
            else:
                with self._lock:
                    del self._breakers[name]
    
    def get_all_stats(self) -> Dict[str, Dict[str, Any]]:
        """Get stats for all circuit breakers."""
        result = {}
        for name, cb in self._breakers.items():
            for backend, state in cb._states.items():
                result[f"{name}:{backend}"] = cb.get_stats(backend)
        return result


# Global registry
_registry = CircuitBreakerRegistry()


def get_circuit_breaker(
    name: str = "default",
    config: Optional[CircuitBreakerConfig] = None,
) -> CircuitBreaker:
    """Get circuit breaker from global registry."""
    return _registry.get_or_create(name, config)


def get_all_circuit_breaker_stats() -> Dict[str, Dict[str, Any]]:
    """Get stats for all circuit breakers in registry."""
    return _registry.get_all_stats()