"""
Circuit breaker for external service calls.

Implements the circuit breaker pattern to handle failures gracefully
when calling external services like Mangle Query Service or OData Vocabularies.
"""

import time
import threading
from typing import Callable, TypeVar, Optional, Any
from dataclasses import dataclass, field
from enum import Enum
from functools import wraps
import logging

logger = logging.getLogger(__name__)

T = TypeVar('T')


class CircuitState(Enum):
    """Circuit breaker states."""
    CLOSED = "closed"      # Normal operation
    OPEN = "open"          # Failing, reject requests
    HALF_OPEN = "half_open"  # Testing if service recovered


@dataclass
class CircuitBreakerConfig:
    """Circuit breaker configuration."""
    failure_threshold: int = 5        # Failures before opening
    success_threshold: int = 3        # Successes in half-open to close
    timeout_seconds: float = 30.0     # Time in open state before half-open
    excluded_exceptions: tuple = ()   # Exceptions that don't count as failures


@dataclass
class CircuitBreakerStats:
    """Circuit breaker statistics."""
    state: CircuitState = CircuitState.CLOSED
    failure_count: int = 0
    success_count: int = 0
    last_failure_time: Optional[float] = None
    last_success_time: Optional[float] = None
    total_calls: int = 0
    total_failures: int = 0
    total_successes: int = 0
    total_rejected: int = 0
    last_error: Optional[str] = None


class CircuitOpenError(Exception):
    """Raised when circuit is open and request is rejected."""
    def __init__(self, service_name: str, retry_after: float):
        self.service_name = service_name
        self.retry_after = retry_after
        super().__init__(f"Circuit open for {service_name}. Retry after {retry_after:.1f}s")


class CircuitBreaker:
    """
    Circuit breaker for external service calls.
    
    Usage:
        breaker = CircuitBreaker("mangle-service")
        
        try:
            result = breaker.call(lambda: external_service.method())
        except CircuitOpenError as e:
            # Handle circuit open
            pass
    """
    
    def __init__(self, name: str, config: Optional[CircuitBreakerConfig] = None):
        self.name = name
        self.config = config or CircuitBreakerConfig()
        self._stats = CircuitBreakerStats()
        self._lock = threading.Lock()
    
    @property
    def state(self) -> CircuitState:
        """Get current circuit state."""
        with self._lock:
            return self._get_state()
    
    def _get_state(self) -> CircuitState:
        """Internal state getter (must hold lock)."""
        if self._stats.state == CircuitState.OPEN:
            # Check if timeout has passed
            if self._stats.last_failure_time:
                elapsed = time.time() - self._stats.last_failure_time
                if elapsed >= self.config.timeout_seconds:
                    self._stats.state = CircuitState.HALF_OPEN
                    self._stats.success_count = 0
                    logger.info(f"Circuit {self.name}: OPEN -> HALF_OPEN")
        return self._stats.state
    
    def call(self, func: Callable[[], T], fallback: Optional[Callable[[], T]] = None) -> T:
        """
        Execute function through circuit breaker.
        
        Args:
            func: Function to execute
            fallback: Optional fallback if circuit is open
            
        Returns:
            Function result
            
        Raises:
            CircuitOpenError: If circuit is open and no fallback
        """
        with self._lock:
            self._stats.total_calls += 1
            state = self._get_state()
            
            if state == CircuitState.OPEN:
                self._stats.total_rejected += 1
                retry_after = self.config.timeout_seconds
                if self._stats.last_failure_time:
                    retry_after -= (time.time() - self._stats.last_failure_time)
                
                if fallback:
                    logger.debug(f"Circuit {self.name}: Using fallback (circuit open)")
                    return fallback()
                raise CircuitOpenError(self.name, max(0, retry_after))
        
        try:
            result = func()
            self._record_success()
            return result
        except self.config.excluded_exceptions:
            # Re-raise excluded exceptions without counting as failure
            raise
        except Exception as e:
            self._record_failure(e)
            raise
    
    async def call_async(self, func: Callable, fallback: Optional[Callable] = None) -> Any:
        """
        Execute async function through circuit breaker.
        
        Args:
            func: Async function to execute
            fallback: Optional fallback if circuit is open
            
        Returns:
            Function result
        """
        with self._lock:
            self._stats.total_calls += 1
            state = self._get_state()
            
            if state == CircuitState.OPEN:
                self._stats.total_rejected += 1
                retry_after = self.config.timeout_seconds
                if self._stats.last_failure_time:
                    retry_after -= (time.time() - self._stats.last_failure_time)
                
                if fallback:
                    logger.debug(f"Circuit {self.name}: Using fallback (circuit open)")
                    return await fallback()
                raise CircuitOpenError(self.name, max(0, retry_after))
        
        try:
            result = await func()
            self._record_success()
            return result
        except self.config.excluded_exceptions:
            raise
        except Exception as e:
            self._record_failure(e)
            raise
    
    def _record_success(self):
        """Record successful call."""
        with self._lock:
            self._stats.success_count += 1
            self._stats.total_successes += 1
            self._stats.last_success_time = time.time()
            
            if self._stats.state == CircuitState.HALF_OPEN:
                if self._stats.success_count >= self.config.success_threshold:
                    self._stats.state = CircuitState.CLOSED
                    self._stats.failure_count = 0
                    logger.info(f"Circuit {self.name}: HALF_OPEN -> CLOSED")
            elif self._stats.state == CircuitState.CLOSED:
                # Reset failure count on success
                self._stats.failure_count = 0
    
    def _record_failure(self, error: Exception):
        """Record failed call."""
        with self._lock:
            self._stats.failure_count += 1
            self._stats.total_failures += 1
            self._stats.last_failure_time = time.time()
            self._stats.last_error = str(error)
            
            if self._stats.state == CircuitState.HALF_OPEN:
                # Immediate transition back to open
                self._stats.state = CircuitState.OPEN
                logger.warning(f"Circuit {self.name}: HALF_OPEN -> OPEN (failure: {error})")
            elif self._stats.state == CircuitState.CLOSED:
                if self._stats.failure_count >= self.config.failure_threshold:
                    self._stats.state = CircuitState.OPEN
                    logger.warning(f"Circuit {self.name}: CLOSED -> OPEN (threshold reached)")
    
    def get_stats(self) -> dict:
        """Get circuit breaker statistics."""
        with self._lock:
            return {
                "name": self.name,
                "state": self._stats.state.value,
                "failure_count": self._stats.failure_count,
                "success_count": self._stats.success_count,
                "total_calls": self._stats.total_calls,
                "total_failures": self._stats.total_failures,
                "total_successes": self._stats.total_successes,
                "total_rejected": self._stats.total_rejected,
                "last_error": self._stats.last_error,
                "last_failure_time": self._stats.last_failure_time,
                "last_success_time": self._stats.last_success_time
            }
    
    def reset(self):
        """Reset circuit breaker to closed state."""
        with self._lock:
            self._stats = CircuitBreakerStats()
            logger.info(f"Circuit {self.name}: Reset to CLOSED")


# Global circuit breakers for external services
_breakers: dict[str, CircuitBreaker] = {}
_breakers_lock = threading.Lock()


def get_circuit_breaker(name: str, config: Optional[CircuitBreakerConfig] = None) -> CircuitBreaker:
    """Get or create a circuit breaker by name."""
    with _breakers_lock:
        if name not in _breakers:
            _breakers[name] = CircuitBreaker(name, config)
        return _breakers[name]


def circuit_breaker(name: str, config: Optional[CircuitBreakerConfig] = None, fallback: Optional[Callable] = None):
    """
    Decorator for circuit breaker protection.
    
    Usage:
        @circuit_breaker("mangle-service")
        def call_mangle():
            ...
    """
    def decorator(func: Callable[..., T]) -> Callable[..., T]:
        breaker = get_circuit_breaker(name, config)
        
        @wraps(func)
        def wrapper(*args, **kwargs):
            return breaker.call(
                lambda: func(*args, **kwargs),
                fallback=fallback
            )
        
        @wraps(func)
        async def async_wrapper(*args, **kwargs):
            return await breaker.call_async(
                lambda: func(*args, **kwargs),
                fallback=fallback
            )
        
        # Return async wrapper if func is async
        import asyncio
        if asyncio.iscoroutinefunction(func):
            return async_wrapper
        return wrapper
    
    return decorator


# Pre-configured circuit breakers for known services
def get_mangle_service_breaker() -> CircuitBreaker:
    """Get circuit breaker for Mangle Query Service."""
    return get_circuit_breaker("mangle-query-service", CircuitBreakerConfig(
        failure_threshold=3,
        success_threshold=2,
        timeout_seconds=30.0
    ))


def get_odata_vocab_breaker() -> CircuitBreaker:
    """Get circuit breaker for OData Vocabularies service."""
    return get_circuit_breaker("odata-vocabularies", CircuitBreakerConfig(
        failure_threshold=5,
        success_threshold=3,
        timeout_seconds=60.0
    ))


def get_aicore_breaker() -> CircuitBreaker:
    """Get circuit breaker for SAP AI Core."""
    return get_circuit_breaker("sap-aicore", CircuitBreakerConfig(
        failure_threshold=3,
        success_threshold=2,
        timeout_seconds=45.0
    ))


def get_all_breaker_stats() -> dict:
    """Get statistics for all circuit breakers."""
    with _breakers_lock:
        return {name: breaker.get_stats() for name, breaker in _breakers.items()}


if __name__ == "__main__":
    # Test circuit breaker
    import random
    
    breaker = CircuitBreaker("test-service", CircuitBreakerConfig(
        failure_threshold=3,
        success_threshold=2,
        timeout_seconds=5.0
    ))
    
    def unreliable_service():
        if random.random() < 0.7:  # 70% failure rate
            raise Exception("Service unavailable")
        return "Success!"
    
    print("Testing circuit breaker...")
    for i in range(20):
        try:
            result = breaker.call(unreliable_service)
            print(f"Call {i+1}: {result}")
        except CircuitOpenError as e:
            print(f"Call {i+1}: Circuit OPEN - {e}")
        except Exception as e:
            print(f"Call {i+1}: Error - {e}")
        
        time.sleep(0.5)
        print(f"  State: {breaker.state.value}")
    
    print("\nFinal stats:", breaker.get_stats())