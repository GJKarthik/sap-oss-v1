# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
Circuit Breaker for HANA AI Tools.

Protects tools from cascading failures by implementing the circuit breaker pattern.
When failures exceed a threshold, the circuit opens and fails fast, allowing
the system to recover.
"""

import logging
import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Callable, Dict, List, Optional, TypeVar

logger = logging.getLogger(__name__)

T = TypeVar("T")


class CircuitState(Enum):
    """Circuit breaker states."""
    CLOSED = "closed"       # Normal operation
    OPEN = "open"           # Failing fast
    HALF_OPEN = "half_open" # Testing recovery


class CircuitOpenError(Exception):
    """Exception raised when circuit is open."""
    def __init__(self, message: str, tool_name: str = ""):
        super().__init__(message)
        self.tool_name = tool_name


@dataclass
class CircuitStats:
    """Statistics for circuit breaker."""
    total_calls: int = 0
    successful_calls: int = 0
    failed_calls: int = 0
    rejected_calls: int = 0
    fallback_calls: int = 0
    last_failure_time: Optional[float] = None
    last_success_time: Optional[float] = None
    state_changes: List[Dict[str, Any]] = field(default_factory=list)


class ToolCircuitBreaker:
    """
    Circuit breaker for HANA AI tools.
    
    Implements the circuit breaker pattern to protect against cascading failures
    when tools fail repeatedly.
    
    Parameters
    ----------
    name : str
        Name of the circuit (typically tool name).
    failure_threshold : int
        Number of failures before opening circuit.
    success_threshold : int
        Number of successes needed to close circuit from half-open.
    recovery_timeout : float
        Seconds to wait before attempting recovery (half-open).
    half_open_requests : int
        Number of requests to allow in half-open state.
    
    Examples
    --------
    >>> breaker = ToolCircuitBreaker(name="FetchDataTool")
    >>> 
    >>> result = await breaker.execute(
    ...     tool._run,
    ...     table_name="my_table",
    ...     fallback=lambda: {"error": "Service unavailable"}
    ... )
    """
    
    # Exceptions that should trigger the circuit breaker
    TRIGGER_EXCEPTIONS = (
        ConnectionError,
        TimeoutError,
        OSError,
    )
    
    def __init__(
        self,
        name: str,
        failure_threshold: int = 5,
        success_threshold: int = 2,
        recovery_timeout: float = 30.0,
        half_open_requests: int = 3,
    ):
        self.name = name
        self.failure_threshold = failure_threshold
        self.success_threshold = success_threshold
        self.recovery_timeout = recovery_timeout
        self.half_open_requests = half_open_requests
        
        self._state = CircuitState.CLOSED
        self._failure_count = 0
        self._success_count = 0
        self._last_failure_time: Optional[float] = None
        self._half_open_count = 0
        self._stats = CircuitStats()
    
    @property
    def state(self) -> CircuitState:
        """Get current circuit state."""
        return self._state
    
    def execute(
        self,
        func: Callable[..., T],
        *args,
        fallback: Optional[Callable[..., T]] = None,
        **kwargs,
    ) -> T:
        """
        Execute a function with circuit breaker protection.
        
        Parameters
        ----------
        func : Callable
            The function to execute.
        fallback : Callable, optional
            Fallback function to call when circuit is open.
        *args, **kwargs
            Arguments to pass to the function.
        
        Returns
        -------
        T
            Result from the function or fallback.
        
        Raises
        ------
        CircuitOpenError
            If circuit is open and no fallback provided.
        """
        self._stats.total_calls += 1
        
        # Check if we should attempt recovery
        if self._state == CircuitState.OPEN:
            if self._should_attempt_recovery():
                self._transition_to(CircuitState.HALF_OPEN)
            else:
                return self._handle_open(fallback, *args, **kwargs)
        
        # Rate limit requests in half-open state
        if self._state == CircuitState.HALF_OPEN:
            if self._half_open_count >= self.half_open_requests:
                return self._handle_open(fallback, *args, **kwargs)
            self._half_open_count += 1
        
        # Execute the function
        try:
            result = func(*args, **kwargs)
            self._record_success()
            return result
        except self.TRIGGER_EXCEPTIONS as e:
            self._record_failure(e)
            if fallback:
                return self._call_fallback(fallback, *args, **kwargs)
            raise
        except Exception as e:
            # Non-trigger exceptions don't affect circuit state
            logger.warning(f"Circuit {self.name}: Non-trigger exception: {e}")
            raise
    
    async def execute_async(
        self,
        func: Callable[..., T],
        *args,
        fallback: Optional[Callable[..., T]] = None,
        **kwargs,
    ) -> T:
        """
        Execute an async function with circuit breaker protection.
        
        Same as execute() but for async functions.
        """
        self._stats.total_calls += 1
        
        if self._state == CircuitState.OPEN:
            if self._should_attempt_recovery():
                self._transition_to(CircuitState.HALF_OPEN)
            else:
                return await self._handle_open_async(fallback, *args, **kwargs)
        
        if self._state == CircuitState.HALF_OPEN:
            if self._half_open_count >= self.half_open_requests:
                return await self._handle_open_async(fallback, *args, **kwargs)
            self._half_open_count += 1
        
        try:
            import asyncio
            if asyncio.iscoroutinefunction(func):
                result = await func(*args, **kwargs)
            else:
                result = func(*args, **kwargs)
            self._record_success()
            return result
        except self.TRIGGER_EXCEPTIONS as e:
            self._record_failure(e)
            if fallback:
                return await self._call_fallback_async(fallback, *args, **kwargs)
            raise
        except Exception as e:
            logger.warning(f"Circuit {self.name}: Non-trigger exception: {e}")
            raise
    
    def _should_attempt_recovery(self) -> bool:
        """Check if recovery timeout has passed."""
        if self._last_failure_time is None:
            return True
        return time.time() - self._last_failure_time >= self.recovery_timeout
    
    def _record_success(self) -> None:
        """Record a successful call."""
        self._stats.successful_calls += 1
        self._stats.last_success_time = time.time()
        
        if self._state == CircuitState.HALF_OPEN:
            self._success_count += 1
            if self._success_count >= self.success_threshold:
                self._transition_to(CircuitState.CLOSED)
        else:
            # Reset failure count on success
            self._failure_count = 0
    
    def _record_failure(self, exception: Exception) -> None:
        """Record a failed call."""
        self._stats.failed_calls += 1
        self._stats.last_failure_time = time.time()
        self._last_failure_time = time.time()
        self._failure_count += 1
        
        logger.warning(
            f"Circuit {self.name}: Failure {self._failure_count}/{self.failure_threshold}: {exception}"
        )
        
        if self._state == CircuitState.HALF_OPEN:
            # Any failure in half-open state reopens circuit
            self._transition_to(CircuitState.OPEN)
        elif self._failure_count >= self.failure_threshold:
            self._transition_to(CircuitState.OPEN)
    
    def _transition_to(self, new_state: CircuitState) -> None:
        """Transition to a new state."""
        old_state = self._state
        self._state = new_state
        
        logger.info(f"Circuit {self.name}: {old_state.value} -> {new_state.value}")
        
        self._stats.state_changes.append({
            "from": old_state.value,
            "to": new_state.value,
            "timestamp": time.time(),
        })
        
        if new_state == CircuitState.CLOSED:
            self._failure_count = 0
            self._success_count = 0
            self._half_open_count = 0
        elif new_state == CircuitState.HALF_OPEN:
            self._success_count = 0
            self._half_open_count = 0
    
    def _handle_open(
        self,
        fallback: Optional[Callable[..., T]],
        *args,
        **kwargs,
    ) -> T:
        """Handle call when circuit is open."""
        self._stats.rejected_calls += 1
        
        if fallback:
            return self._call_fallback(fallback, *args, **kwargs)
        
        raise CircuitOpenError(
            f"Circuit breaker {self.name} is OPEN",
            tool_name=self.name,
        )
    
    async def _handle_open_async(
        self,
        fallback: Optional[Callable[..., T]],
        *args,
        **kwargs,
    ) -> T:
        """Handle async call when circuit is open."""
        self._stats.rejected_calls += 1
        
        if fallback:
            return await self._call_fallback_async(fallback, *args, **kwargs)
        
        raise CircuitOpenError(
            f"Circuit breaker {self.name} is OPEN",
            tool_name=self.name,
        )
    
    def _call_fallback(
        self,
        fallback: Callable[..., T],
        *args,
        **kwargs,
    ) -> T:
        """Call fallback function."""
        self._stats.fallback_calls += 1
        logger.info(f"Circuit {self.name}: Using fallback")
        
        try:
            return fallback(*args, **kwargs)
        except Exception as e:
            logger.error(f"Circuit {self.name}: Fallback failed: {e}")
            raise
    
    async def _call_fallback_async(
        self,
        fallback: Callable[..., T],
        *args,
        **kwargs,
    ) -> T:
        """Call async fallback function."""
        self._stats.fallback_calls += 1
        logger.info(f"Circuit {self.name}: Using fallback")
        
        try:
            import asyncio
            if asyncio.iscoroutinefunction(fallback):
                return await fallback(*args, **kwargs)
            return fallback(*args, **kwargs)
        except Exception as e:
            logger.error(f"Circuit {self.name}: Fallback failed: {e}")
            raise
    
    def force_open(self) -> None:
        """Manually open the circuit."""
        self._transition_to(CircuitState.OPEN)
        self._last_failure_time = time.time()
    
    def force_close(self) -> None:
        """Manually close the circuit."""
        self._transition_to(CircuitState.CLOSED)
    
    def get_stats(self) -> Dict[str, Any]:
        """Get circuit breaker statistics."""
        return {
            "name": self.name,
            "state": self._state.value,
            "failure_count": self._failure_count,
            "success_count": self._success_count,
            "total_calls": self._stats.total_calls,
            "successful_calls": self._stats.successful_calls,
            "failed_calls": self._stats.failed_calls,
            "rejected_calls": self._stats.rejected_calls,
            "fallback_calls": self._stats.fallback_calls,
            "last_failure_time": self._stats.last_failure_time,
            "last_success_time": self._stats.last_success_time,
            "config": {
                "failure_threshold": self.failure_threshold,
                "success_threshold": self.success_threshold,
                "recovery_timeout": self.recovery_timeout,
            }
        }


class CircuitBreakerRegistry:
    """
    Registry for managing multiple circuit breakers.
    
    Provides centralized management of circuit breakers for all tools.
    """
    
    def __init__(self):
        self._breakers: Dict[str, ToolCircuitBreaker] = {}
    
    def get_or_create(
        self,
        name: str,
        **kwargs,
    ) -> ToolCircuitBreaker:
        """Get existing or create new circuit breaker."""
        if name not in self._breakers:
            self._breakers[name] = ToolCircuitBreaker(name=name, **kwargs)
            logger.info(f"Created circuit breaker: {name}")
        return self._breakers[name]
    
    def get(self, name: str) -> Optional[ToolCircuitBreaker]:
        """Get circuit breaker by name."""
        return self._breakers.get(name)
    
    def get_all_stats(self) -> Dict[str, Dict[str, Any]]:
        """Get stats for all circuit breakers."""
        return {name: breaker.get_stats() for name, breaker in self._breakers.items()}
    
    def reset_all(self) -> None:
        """Reset all circuit breakers to closed state."""
        for breaker in self._breakers.values():
            breaker.force_close()


# Global registry
_registry: Optional[CircuitBreakerRegistry] = None


def get_circuit_breaker_registry() -> CircuitBreakerRegistry:
    """Get the global circuit breaker registry."""
    global _registry
    if _registry is None:
        _registry = CircuitBreakerRegistry()
    return _registry


def circuit_protected(
    name: Optional[str] = None,
    fallback: Optional[Callable] = None,
    **breaker_kwargs,
):
    """
    Decorator to protect a function with a circuit breaker.
    
    Parameters
    ----------
    name : str, optional
        Circuit breaker name. Defaults to function name.
    fallback : Callable, optional
        Fallback function.
    **breaker_kwargs
        Additional arguments for circuit breaker.
    
    Examples
    --------
    >>> @circuit_protected(failure_threshold=3)
    ... def fetch_data(table_name: str):
    ...     # Implementation
    ...     pass
    """
    def decorator(func: Callable[..., T]) -> Callable[..., T]:
        breaker_name = name or func.__name__
        registry = get_circuit_breaker_registry()
        breaker = registry.get_or_create(breaker_name, **breaker_kwargs)
        
        def wrapper(*args, **kwargs) -> T:
            return breaker.execute(func, *args, fallback=fallback, **kwargs)
        
        async def async_wrapper(*args, **kwargs) -> T:
            return await breaker.execute_async(func, *args, fallback=fallback, **kwargs)
        
        import asyncio
        if asyncio.iscoroutinefunction(func):
            return async_wrapper
        return wrapper
    
    return decorator