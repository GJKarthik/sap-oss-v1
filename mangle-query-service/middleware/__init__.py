"""
Middleware Package for Mangle Query Service

Day 4 Deliverable: Public API for resilience middleware
Exports all components from Days 1-4

Usage:
    from middleware import ResilientHTTPClient, ResilientClientConfig
    
    client = ResilientHTTPClient(ResilientClientConfig())
    response = await client.post(url, json=data)
"""

# HTTP Client (Day 1)
from mangle_query_service.connectors.http_client import (
    AsyncHTTPClient,
    HTTPClientConfig,
    HTTPResponse,
)

# Retry Logic (Day 2)
from mangle_query_service.middleware.retry import (
    RetryConfig,
    RetryStrategy,
    RetryContext,
    RetryableHTTPClient,
    StructuredError,
    ErrorCodes,
    retry_async,
    with_retry,
    calculate_delay,
    is_retryable_status,
    is_retryable_exception,
    create_error_from_status,
    create_error_from_exception,
)

# Circuit Breaker (Day 3)
from mangle_query_service.middleware.circuit_breaker import (
    CircuitState,
    CircuitBreakerConfig,
    CircuitBreakerState,
    CircuitBreaker,
    CircuitBreakerOpen,
    CircuitBreakerContext,
    CircuitBreakerHTTPClient,
    CircuitBreakerRegistry,
    with_circuit_breaker,
    get_circuit_breaker,
    get_all_circuit_breaker_stats,
)

# Resilient Client (Day 4) - imported at end
from mangle_query_service.middleware.resilient_client import (
    ResilientClientConfig,
    ResilientHTTPClient,
    create_resilient_client,
    get_resilient_client,
)


__all__ = [
    # HTTP Client
    "AsyncHTTPClient",
    "HTTPClientConfig",
    "HTTPResponse",
    # Retry
    "RetryConfig",
    "RetryStrategy",
    "RetryContext",
    "RetryableHTTPClient",
    "StructuredError",
    "ErrorCodes",
    "retry_async",
    "with_retry",
    "calculate_delay",
    "is_retryable_status",
    "is_retryable_exception",
    "create_error_from_status",
    "create_error_from_exception",
    # Circuit Breaker
    "CircuitState",
    "CircuitBreakerConfig",
    "CircuitBreakerState",
    "CircuitBreaker",
    "CircuitBreakerOpen",
    "CircuitBreakerContext",
    "CircuitBreakerHTTPClient",
    "CircuitBreakerRegistry",
    "with_circuit_breaker",
    "get_circuit_breaker",
    "get_all_circuit_breaker_stats",
    # Resilient Client
    "ResilientClientConfig",
    "ResilientHTTPClient",
    "create_resilient_client",
    "get_resilient_client",
]