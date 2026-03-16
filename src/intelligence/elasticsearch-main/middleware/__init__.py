"""
Middleware package for SAP Elasticsearch + Mangle Query Service components.

Includes:
- Rate limiting (token-bucket + sliding-window)
- Circuit breaker for external services
- Health check for cross-service monitoring
- Input validation (injection guards, size limits)
- Retry with exponential backoff
- mTLS configuration
- Health monitor (aggregated dependency health)
- Resilient HTTP client (retry + circuit-breaker composite)
- HANA-specific circuit breaker
"""

from .rate_limiter import (
    RateLimiter,
    RateLimitConfig,
    get_mcp_limiter,
    get_openai_limiter,
    rate_limit_dependency,
)

from .circuit_breaker import (
    CircuitBreaker,
    CircuitBreakerConfig,
    CircuitState,
    CircuitOpenError,
    circuit_breaker,
    get_circuit_breaker,
    get_mangle_service_breaker,
    get_odata_vocab_breaker,
    get_aicore_breaker,
    get_all_breaker_stats,
)

from .health import (
    HealthChecker,
    HealthStatus,
    ServiceHealth,
    get_health_checker,
    get_health,
    health_endpoint,
    check_local_health,
)

# ---------------------------------------------------------------------------
# Merged from mangle-query-service
# ---------------------------------------------------------------------------

try:
    from .validation import (
        ValidationMiddleware,
        ValidationConfig,
        validate_request,
    )
    _HAS_VALIDATION = True
except ImportError:
    _HAS_VALIDATION = False

try:
    from .retry import (
        RetryConfig,
        RetryStrategy,
        retry_async,
        with_retry,
    )
    _HAS_RETRY = True
except ImportError:
    _HAS_RETRY = False

try:
    from .retry_handler import RetryHandler
    _HAS_RETRY_HANDLER = True
except ImportError:
    _HAS_RETRY_HANDLER = False

try:
    from .health_monitor import HealthMonitor, ServiceStatus
    _HAS_HEALTH_MONITOR = True
except ImportError:
    _HAS_HEALTH_MONITOR = False

try:
    from .mtls import MTLSConfig, create_ssl_context
    _HAS_MTLS = True
except ImportError:
    _HAS_MTLS = False

try:
    from .resilient_client import (
        ResilientClientConfig,
        ResilientHTTPClient,
        create_resilient_client,
    )
    _HAS_RESILIENT_CLIENT = True
except ImportError:
    _HAS_RESILIENT_CLIENT = False

try:
    from .hana_circuit_breaker import HanaCircuitBreaker, get_hana_breaker
    _HAS_HANA_CB = True
except ImportError:
    _HAS_HANA_CB = False

__all__ = [
    # Rate Limiting
    "RateLimiter",
    "RateLimitConfig",
    "get_mcp_limiter",
    "get_openai_limiter",
    "rate_limit_dependency",
    # Circuit Breaker
    "CircuitBreaker",
    "CircuitBreakerConfig",
    "CircuitState",
    "CircuitOpenError",
    "circuit_breaker",
    "get_circuit_breaker",
    "get_mangle_service_breaker",
    "get_odata_vocab_breaker",
    "get_aicore_breaker",
    "get_all_breaker_stats",
    # Health Check
    "HealthChecker",
    "HealthStatus",
    "ServiceHealth",
    "get_health_checker",
    "get_health",
    "health_endpoint",
    "check_local_health",
    # Validation (merged from mqs)
    "ValidationMiddleware",
    "ValidationConfig",
    "validate_request",
    # Retry (merged from mqs)
    "RetryConfig",
    "RetryStrategy",
    "retry_async",
    "with_retry",
    "RetryHandler",
    # Health Monitor (merged from mqs)
    "HealthMonitor",
    "ServiceStatus",
    # mTLS (merged from mqs)
    "MTLSConfig",
    "create_ssl_context",
    # Resilient Client (merged from mqs)
    "ResilientClientConfig",
    "ResilientHTTPClient",
    "create_resilient_client",
    # HANA Circuit Breaker (merged from mqs)
    "HanaCircuitBreaker",
    "get_hana_breaker",
]