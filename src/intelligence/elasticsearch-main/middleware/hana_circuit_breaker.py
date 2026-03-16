"""
Circuit Breaker for HANA Connection Resilience.

Implements Enhancement 4.1: Circuit Breaker for HANA
- Automatic failure detection and circuit opening
- Graceful fallback to Elasticsearch
- Automatic recovery with half-open state

This provides graceful degradation during HANA outages,
preventing cascade failures across the service.
"""

import asyncio
import logging
import os
import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Callable, Dict, List, Optional, TypeVar

logger = logging.getLogger(__name__)

# Configuration
FAILURE_THRESHOLD = int(os.getenv("HANA_CB_FAILURE_THRESHOLD", "5"))
RECOVERY_TIMEOUT_SECONDS = float(os.getenv("HANA_CB_RECOVERY_TIMEOUT", "30.0"))
HALF_OPEN_REQUESTS = int(os.getenv("HANA_CB_HALF_OPEN_REQUESTS", "3"))
SUCCESS_THRESHOLD = int(os.getenv("HANA_CB_SUCCESS_THRESHOLD", "2"))
MONITORING_WINDOW_SECONDS = float(os.getenv("HANA_CB_MONITORING_WINDOW", "60.0"))

T = TypeVar("T")


class CircuitState(Enum):
    """Circuit breaker states."""
    CLOSED = "closed"       # Normal operation
    OPEN = "open"           # Failing, reject requests
    HALF_OPEN = "half_open" # Testing recovery


@dataclass
class CircuitStats:
    """Statistics for circuit breaker."""
    state: CircuitState = CircuitState.CLOSED
    consecutive_failures: int = 0
    consecutive_successes: int = 0
    total_requests: int = 0
    total_failures: int = 0
    total_successes: int = 0
    total_fallbacks: int = 0
    last_failure_time: Optional[float] = None
    last_success_time: Optional[float] = None
    state_changed_at: float = field(default_factory=time.time)
    
    # Window-based metrics
    recent_failures: List[float] = field(default_factory=list)
    recent_successes: List[float] = field(default_factory=list)


class HanaCircuitBreaker:
    """
    Circuit breaker for HANA connection resilience.
    
    States:
    - CLOSED: Normal operation, requests pass through
    - OPEN: Too many failures, requests rejected with fallback
    - HALF_OPEN: Testing recovery with limited requests
    
    Transitions:
    - CLOSED -> OPEN: After failure_threshold consecutive failures
    - OPEN -> HALF_OPEN: After recovery_timeout
    - HALF_OPEN -> CLOSED: After success_threshold successes
    - HALF_OPEN -> OPEN: On any failure
    """
    
    def __init__(
        self,
        name: str = "hana",
        failure_threshold: int = FAILURE_THRESHOLD,
        recovery_timeout: float = RECOVERY_TIMEOUT_SECONDS,
        half_open_requests: int = HALF_OPEN_REQUESTS,
        success_threshold: int = SUCCESS_THRESHOLD,
        monitoring_window: float = MONITORING_WINDOW_SECONDS,
    ):
        self.name = name
        self.failure_threshold = failure_threshold
        self.recovery_timeout = recovery_timeout
        self.half_open_requests = half_open_requests
        self.success_threshold = success_threshold
        self.monitoring_window = monitoring_window
        
        self._stats = CircuitStats()
        self._lock = asyncio.Lock()
        self._half_open_permits = 0
        
        # Fallback function
        self._fallback: Optional[Callable] = None
        
        # Event callbacks
        self._on_state_change: List[Callable[[CircuitState, CircuitState], None]] = []
        self._on_fallback: List[Callable[[Exception], None]] = []
    
    @property
    def state(self) -> CircuitState:
        """Current circuit state."""
        return self._stats.state
    
    @property
    def is_open(self) -> bool:
        """Check if circuit is open (rejecting requests)."""
        return self._stats.state == CircuitState.OPEN
    
    @property
    def is_closed(self) -> bool:
        """Check if circuit is closed (normal operation)."""
        return self._stats.state == CircuitState.CLOSED
    
    def set_fallback(self, fallback: Callable) -> None:
        """Set fallback function for when circuit is open."""
        self._fallback = fallback
    
    def on_state_change(self, callback: Callable[[CircuitState, CircuitState], None]) -> None:
        """Register callback for state changes."""
        self._on_state_change.append(callback)
    
    def on_fallback(self, callback: Callable[[Exception], None]) -> None:
        """Register callback for fallback invocations."""
        self._on_fallback.append(callback)
    
    async def execute(
        self,
        operation: Callable[[], T],
        fallback: Optional[Callable[[], T]] = None,
    ) -> T:
        """
        Execute operation with circuit breaker protection.
        
        Args:
            operation: Async function to execute
            fallback: Optional fallback if circuit is open
        
        Returns:
            Result from operation or fallback
        
        Raises:
            CircuitOpenError: If circuit is open and no fallback provided
        """
        fallback = fallback or self._fallback
        
        async with self._lock:
            # Check for state transition
            await self._check_state_transition()
            
            current_state = self._stats.state
            
            # Handle based on state
            if current_state == CircuitState.OPEN:
                # Circuit is open, use fallback
                if fallback:
                    self._stats.total_fallbacks += 1
                    for callback in self._on_fallback:
                        try:
                            callback(CircuitOpenError(f"Circuit {self.name} is open"))
                        except Exception:
                            pass
                    
                    # Release lock for fallback execution
                    self._lock.release()
                    try:
                        return await fallback()
                    finally:
                        await self._lock.acquire()
                else:
                    raise CircuitOpenError(
                        f"Circuit {self.name} is open and no fallback provided"
                    )
            
            elif current_state == CircuitState.HALF_OPEN:
                # Limited requests in half-open state
                if self._half_open_permits <= 0:
                    if fallback:
                        self._stats.total_fallbacks += 1
                        self._lock.release()
                        try:
                            return await fallback()
                        finally:
                            await self._lock.acquire()
                    else:
                        raise CircuitOpenError(
                            f"Circuit {self.name} is half-open, no permits available"
                        )
                
                self._half_open_permits -= 1
        
        # Execute operation
        self._stats.total_requests += 1
        
        try:
            result = await operation()
            await self._record_success()
            return result
            
        except Exception as e:
            await self._record_failure(e)
            
            # Try fallback
            if fallback:
                self._stats.total_fallbacks += 1
                for callback in self._on_fallback:
                    try:
                        callback(e)
                    except Exception:
                        pass
                return await fallback()
            
            raise
    
    async def _check_state_transition(self) -> None:
        """Check if state should transition based on time/metrics."""
        current_time = time.time()
        
        if self._stats.state == CircuitState.OPEN:
            # Check if recovery timeout has passed
            time_since_failure = current_time - (self._stats.last_failure_time or 0)
            
            if time_since_failure >= self.recovery_timeout:
                await self._transition_to(CircuitState.HALF_OPEN)
                self._half_open_permits = self.half_open_requests
    
    async def _record_success(self) -> None:
        """Record successful operation."""
        async with self._lock:
            current_time = time.time()
            
            self._stats.total_successes += 1
            self._stats.consecutive_successes += 1
            self._stats.consecutive_failures = 0
            self._stats.last_success_time = current_time
            
            # Window-based tracking
            self._stats.recent_successes.append(current_time)
            self._cleanup_window_metrics()
            
            # State transitions
            if self._stats.state == CircuitState.HALF_OPEN:
                if self._stats.consecutive_successes >= self.success_threshold:
                    await self._transition_to(CircuitState.CLOSED)
    
    async def _record_failure(self, error: Exception) -> None:
        """Record failed operation."""
        async with self._lock:
            current_time = time.time()
            
            self._stats.total_failures += 1
            self._stats.consecutive_failures += 1
            self._stats.consecutive_successes = 0
            self._stats.last_failure_time = current_time
            
            # Window-based tracking
            self._stats.recent_failures.append(current_time)
            self._cleanup_window_metrics()
            
            logger.warning(
                f"Circuit {self.name} failure #{self._stats.consecutive_failures}: {error}"
            )
            
            # State transitions
            if self._stats.state == CircuitState.CLOSED:
                if self._stats.consecutive_failures >= self.failure_threshold:
                    await self._transition_to(CircuitState.OPEN)
            
            elif self._stats.state == CircuitState.HALF_OPEN:
                # Any failure in half-open returns to open
                await self._transition_to(CircuitState.OPEN)
    
    async def _transition_to(self, new_state: CircuitState) -> None:
        """Transition to new state."""
        old_state = self._stats.state
        
        if old_state == new_state:
            return
        
        self._stats.state = new_state
        self._stats.state_changed_at = time.time()
        
        # Reset counters on state change
        if new_state == CircuitState.CLOSED:
            self._stats.consecutive_failures = 0
        elif new_state == CircuitState.OPEN:
            self._stats.consecutive_successes = 0
        elif new_state == CircuitState.HALF_OPEN:
            self._stats.consecutive_successes = 0
            self._stats.consecutive_failures = 0
            self._half_open_permits = self.half_open_requests
        
        logger.info(f"Circuit {self.name} state: {old_state.value} -> {new_state.value}")
        
        # Notify callbacks
        for callback in self._on_state_change:
            try:
                callback(old_state, new_state)
            except Exception as e:
                logger.error(f"State change callback error: {e}")
    
    def _cleanup_window_metrics(self) -> None:
        """Remove metrics outside the monitoring window."""
        cutoff = time.time() - self.monitoring_window
        
        self._stats.recent_failures = [
            t for t in self._stats.recent_failures if t > cutoff
        ]
        self._stats.recent_successes = [
            t for t in self._stats.recent_successes if t > cutoff
        ]
    
    def get_stats(self) -> Dict[str, Any]:
        """Get circuit breaker statistics."""
        current_time = time.time()
        
        return {
            "name": self.name,
            "state": self._stats.state.value,
            "consecutive_failures": self._stats.consecutive_failures,
            "consecutive_successes": self._stats.consecutive_successes,
            "total_requests": self._stats.total_requests,
            "total_failures": self._stats.total_failures,
            "total_successes": self._stats.total_successes,
            "total_fallbacks": self._stats.total_fallbacks,
            "failure_rate": self._stats.total_failures / self._stats.total_requests if self._stats.total_requests > 0 else 0,
            "last_failure_ago_seconds": current_time - self._stats.last_failure_time if self._stats.last_failure_time else None,
            "last_success_ago_seconds": current_time - self._stats.last_success_time if self._stats.last_success_time else None,
            "state_duration_seconds": current_time - self._stats.state_changed_at,
            "recent_failures_count": len(self._stats.recent_failures),
            "recent_successes_count": len(self._stats.recent_successes),
            "config": {
                "failure_threshold": self.failure_threshold,
                "recovery_timeout": self.recovery_timeout,
                "half_open_requests": self.half_open_requests,
                "success_threshold": self.success_threshold,
                "monitoring_window": self.monitoring_window,
            }
        }
    
    async def force_open(self) -> None:
        """Force circuit to open state (for testing/emergency)."""
        async with self._lock:
            await self._transition_to(CircuitState.OPEN)
    
    async def force_close(self) -> None:
        """Force circuit to closed state (for recovery)."""
        async with self._lock:
            self._stats.consecutive_failures = 0
            await self._transition_to(CircuitState.CLOSED)
    
    async def reset(self) -> None:
        """Reset circuit breaker to initial state."""
        async with self._lock:
            self._stats = CircuitStats()
            self._half_open_permits = 0


class CircuitOpenError(Exception):
    """Exception raised when circuit is open."""
    pass


class CircuitBreakerRegistry:
    """Registry for managing multiple circuit breakers."""
    
    def __init__(self):
        self._breakers: Dict[str, HanaCircuitBreaker] = {}
        self._lock = asyncio.Lock()
    
    async def get_or_create(
        self,
        name: str,
        **kwargs,
    ) -> HanaCircuitBreaker:
        """Get or create a circuit breaker by name."""
        async with self._lock:
            if name not in self._breakers:
                self._breakers[name] = HanaCircuitBreaker(name=name, **kwargs)
            return self._breakers[name]
    
    def get(self, name: str) -> Optional[HanaCircuitBreaker]:
        """Get circuit breaker by name."""
        return self._breakers.get(name)
    
    def get_all_stats(self) -> Dict[str, Any]:
        """Get stats for all circuit breakers."""
        return {
            name: breaker.get_stats()
            for name, breaker in self._breakers.items()
        }
    
    async def force_open_all(self) -> None:
        """Force all circuit breakers open."""
        for breaker in self._breakers.values():
            await breaker.force_open()
    
    async def force_close_all(self) -> None:
        """Force all circuit breakers closed."""
        for breaker in self._breakers.values():
            await breaker.force_close()


# Singleton registry
_registry: Optional[CircuitBreakerRegistry] = None
_registry_lock = asyncio.Lock()


async def get_circuit_breaker_registry() -> CircuitBreakerRegistry:
    """Get or create the circuit breaker registry singleton."""
    global _registry
    
    async with _registry_lock:
        if _registry is None:
            _registry = CircuitBreakerRegistry()
            logger.info("Initialized circuit breaker registry")
        return _registry


async def get_hana_circuit_breaker() -> HanaCircuitBreaker:
    """Get the HANA circuit breaker instance."""
    registry = await get_circuit_breaker_registry()
    return await registry.get_or_create("hana")


# Decorator for easy circuit breaker application
def with_circuit_breaker(
    breaker_name: str = "hana",
    fallback: Optional[Callable] = None,
):
    """
    Decorator to wrap function with circuit breaker.
    
    Usage:
        @with_circuit_breaker("hana", fallback=es_fallback)
        async def query_hana(query: str):
            ...
    """
    def decorator(func: Callable) -> Callable:
        async def wrapper(*args, **kwargs):
            registry = await get_circuit_breaker_registry()
            breaker = await registry.get_or_create(breaker_name)
            
            async def operation():
                return await func(*args, **kwargs)
            
            async def fallback_op():
                if fallback:
                    return await fallback(*args, **kwargs)
                raise CircuitOpenError(f"No fallback for {breaker_name}")
            
            return await breaker.execute(operation, fallback_op if fallback else None)
        
        return wrapper
    return decorator