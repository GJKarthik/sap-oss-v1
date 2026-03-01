"""
Middleware package for SAP Elasticsearch components.

Includes:
- Rate limiting
- Circuit breaker for external services
- Health check for cross-service monitoring
- Security headers  
- OpenTelemetry instrumentation
"""

from .rate_limiter import (
    RateLimiter,
    RateLimitConfig,
    get_mcp_limiter,
    get_openai_limiter,
    rate_limit_dependency
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
]