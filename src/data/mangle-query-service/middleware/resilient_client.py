"""
Resilient HTTP Client

Day 4 Deliverable: Unified client combining all resilience patterns
- HTTP Client Foundation (Day 1)
- Retry with Exponential Backoff (Day 2)
- Circuit Breaker (Day 3)
- Request Timeout and Metrics (Day 4)

Usage:
    from middleware import ResilientHTTPClient, ResilientClientConfig
    
    client = ResilientHTTPClient(ResilientClientConfig())
    response = await client.post("http://llm-backend:8080/v1/chat", json=payload)
"""

import asyncio
import time
import logging
from typing import Optional, Dict, Any, Callable
from dataclasses import dataclass, field
from urllib.parse import urlparse
import threading

from mangle_query_service.middleware.retry import (
    RetryConfig,
    RetryStrategy,
    retry_async,
    StructuredError,
    create_error_from_status,
    create_error_from_exception,
)
from mangle_query_service.middleware.circuit_breaker import (
    CircuitBreaker,
    CircuitBreakerConfig,
    CircuitBreakerContext,
    CircuitBreakerOpen,
    get_circuit_breaker,
)

logger = logging.getLogger(__name__)


# ========================================
# Configuration
# ========================================

@dataclass
class ResilientClientConfig:
    """
    Configuration for resilient HTTP client.
    
    Combines HTTP, retry, and circuit breaker settings.
    """
    
    # HTTP settings
    base_timeout: float = 30.0
    connect_timeout: float = 5.0
    read_timeout: float = 60.0
    pool_size: int = 100
    
    # Retry settings
    max_retries: int = 3
    retry_base_delay: float = 1.0
    retry_max_delay: float = 8.0
    retry_strategy: RetryStrategy = RetryStrategy.EXPONENTIAL
    retry_jitter: float = 0.25
    
    # Circuit breaker settings
    cb_failure_threshold: int = 5
    cb_success_threshold: int = 2
    cb_recovery_timeout: float = 30.0
    cb_failure_window: float = 60.0
    
    # Feature flags
    enable_retry: bool = True
    enable_circuit_breaker: bool = True
    enable_metrics: bool = True
    
    # Retryable status codes
    retryable_status_codes: set = field(default_factory=lambda: {
        500, 502, 503, 504, 429,
    })
    
    # Circuit breaker failure status codes
    cb_failure_status_codes: set = field(default_factory=lambda: {
        500, 502, 503, 504,
    })
    
    @classmethod
    def for_llm_backend(cls) -> "ResilientClientConfig":
        """Config optimized for LLM backends (longer timeouts)."""
        return cls(
            base_timeout=120.0,
            read_timeout=120.0,
            max_retries=2,
            retry_base_delay=2.0,
            retry_max_delay=16.0,
            cb_failure_threshold=3,
            cb_recovery_timeout=60.0,
        )
    
    @classmethod
    def for_metadata_service(cls) -> "ResilientClientConfig":
        """Config optimized for fast metadata lookups."""
        return cls(
            base_timeout=5.0,
            read_timeout=10.0,
            max_retries=3,
            retry_base_delay=0.5,
            retry_max_delay=4.0,
            cb_failure_threshold=10,
            cb_recovery_timeout=15.0,
        )
    
    @classmethod
    def for_elasticsearch(cls) -> "ResilientClientConfig":
        """Config optimized for Elasticsearch."""
        return cls(
            base_timeout=10.0,
            read_timeout=30.0,
            max_retries=3,
            retry_base_delay=1.0,
            retry_max_delay=8.0,
            cb_failure_threshold=5,
            cb_recovery_timeout=30.0,
        )
    
    def to_retry_config(self) -> RetryConfig:
        """Convert to RetryConfig."""
        return RetryConfig(
            max_retries=self.max_retries,
            base_delay=self.retry_base_delay,
            max_delay=self.retry_max_delay,
            exponential_base=2.0,
            jitter_factor=self.retry_jitter,
            retryable_status_codes=self.retryable_status_codes,
        )
    
    def to_circuit_breaker_config(self) -> CircuitBreakerConfig:
        """Convert to CircuitBreakerConfig."""
        return CircuitBreakerConfig(
            failure_threshold=self.cb_failure_threshold,
            success_threshold=self.cb_success_threshold,
            recovery_timeout=self.cb_recovery_timeout,
            failure_window=self.cb_failure_window,
            failure_status_codes=self.cb_failure_status_codes,
        )


# ========================================
# Request Metrics
# ========================================

@dataclass
class RequestMetrics:
    """Metrics for a single request."""
    
    method: str
    url: str
    backend: str
    status_code: Optional[int] = None
    duration_ms: float = 0.0
    retry_count: int = 0
    circuit_breaker_state: str = "unknown"
    error: Optional[str] = None
    success: bool = False


class MetricsCollector:
    """
    Collects request metrics.
    
    Thread-safe, designed for monitoring integration.
    """
    
    def __init__(self, max_history: int = 1000):
        self._history: list = []
        self._lock = threading.Lock()
        self._max_history = max_history
        
        # Aggregated stats
        self._total_requests = 0
        self._total_errors = 0
        self._total_retries = 0
        self._total_circuit_breaker_trips = 0
        
        # Per-backend stats
        self._backend_stats: Dict[str, Dict[str, Any]] = {}
    
    def record(self, metrics: RequestMetrics) -> None:
        """Record request metrics."""
        with self._lock:
            self._history.append(metrics)
            if len(self._history) > self._max_history:
                self._history.pop(0)
            
            self._total_requests += 1
            if not metrics.success:
                self._total_errors += 1
            self._total_retries += metrics.retry_count
            
            # Update backend stats
            backend = metrics.backend
            if backend not in self._backend_stats:
                self._backend_stats[backend] = {
                    "requests": 0,
                    "errors": 0,
                    "retries": 0,
                    "avg_duration_ms": 0.0,
                }
            
            stats = self._backend_stats[backend]
            stats["requests"] += 1
            if not metrics.success:
                stats["errors"] += 1
            stats["retries"] += metrics.retry_count
            
            # Rolling average duration
            n = stats["requests"]
            stats["avg_duration_ms"] = (
                (stats["avg_duration_ms"] * (n - 1) + metrics.duration_ms) / n
            )
    
    def get_summary(self) -> Dict[str, Any]:
        """Get metrics summary."""
        with self._lock:
            return {
                "total_requests": self._total_requests,
                "total_errors": self._total_errors,
                "total_retries": self._total_retries,
                "error_rate": (
                    self._total_errors / self._total_requests
                    if self._total_requests > 0 else 0.0
                ),
                "backend_stats": dict(self._backend_stats),
            }
    
    def get_recent(self, n: int = 10) -> list:
        """Get recent requests."""
        with self._lock:
            return list(self._history[-n:])


# ========================================
# Resilient HTTP Client
# ========================================

class ResilientHTTPClient:
    """
    Production-ready HTTP client with full resilience.
    
    Combines:
    - Async HTTP with connection pooling
    - Retry with exponential backoff
    - Circuit breaker pattern
    - Request metrics and logging
    
    Usage:
        client = ResilientHTTPClient(ResilientClientConfig.for_llm_backend())
        
        response = await client.post(
            "http://llm-backend:8080/v1/chat/completions",
            json={"model": "gpt-4", "messages": messages},
        )
    """
    
    def __init__(
        self,
        config: Optional[ResilientClientConfig] = None,
        http_client: Optional[Any] = None,  # AsyncHTTPClient or compatible
    ):
        self.config = config or ResilientClientConfig()
        self._http_client = http_client
        self._circuit_breaker = CircuitBreaker(self.config.to_circuit_breaker_config())
        self._metrics = MetricsCollector() if self.config.enable_metrics else None
        self._closed = False
    
    def _get_http_client(self):
        """Lazy initialization of HTTP client."""
        if self._http_client is None:
            # Import here to avoid circular imports
            try:
                from mangle_query_service.connectors.http_client import AsyncHTTPClient, HTTPClientConfig
                self._http_client = AsyncHTTPClient(HTTPClientConfig(
                    timeout=self.config.base_timeout,
                    pool_size=self.config.pool_size,
                ))
            except ImportError:
                # Fallback to httpx if available
                import httpx
                self._http_client = httpx.AsyncClient(
                    timeout=httpx.Timeout(self.config.base_timeout),
                )
        return self._http_client
    
    def _extract_backend(self, url: str) -> str:
        """Extract backend identifier from URL."""
        parsed = urlparse(url)
        return f"{parsed.scheme}://{parsed.netloc}"
    
    async def request(
        self,
        method: str,
        url: str,
        **kwargs,
    ) -> Any:
        """
        Make HTTP request with full resilience.
        
        Order of operations:
        1. Check circuit breaker
        2. Execute request with retry
        3. Record metrics
        4. Update circuit breaker state
        """
        backend = self._extract_backend(url)
        start_time = time.time()
        
        metrics = RequestMetrics(
            method=method,
            url=url,
            backend=backend,
        )
        
        retry_count = 0
        
        try:
            # Check circuit breaker
            if self.config.enable_circuit_breaker:
                metrics.circuit_breaker_state = self._circuit_breaker.get_state(backend).value
                
                async with CircuitBreakerContext(self._circuit_breaker, backend) as cb_ctx:
                    # Execute with retry
                    if self.config.enable_retry:
                        response, retry_count = await self._execute_with_retry(
                            method, url, **kwargs
                        )
                    else:
                        response = await self._execute_once(method, url, **kwargs)
                    
                    # Check response status for circuit breaker
                    if hasattr(response, 'status_code'):
                        if response.status_code in self.config.cb_failure_status_codes:
                            cb_ctx.mark_failure()
                    
                    metrics.status_code = getattr(response, 'status_code', None)
                    metrics.retry_count = retry_count
                    metrics.success = True
                    
                    return response
            else:
                # No circuit breaker
                if self.config.enable_retry:
                    response, retry_count = await self._execute_with_retry(
                        method, url, **kwargs
                    )
                else:
                    response = await self._execute_once(method, url, **kwargs)
                
                metrics.status_code = getattr(response, 'status_code', None)
                metrics.retry_count = retry_count
                metrics.success = True
                
                return response
        
        except CircuitBreakerOpen as e:
            metrics.error = f"Circuit breaker open: {e.backend}"
            metrics.circuit_breaker_state = "open"
            logger.warning(f"Circuit breaker open for {backend}, retry after {e.time_until_recovery:.1f}s")
            raise
        
        except Exception as e:
            metrics.error = str(e)
            logger.error(f"Request failed: {method} {url} - {e}")
            raise
        
        finally:
            metrics.duration_ms = (time.time() - start_time) * 1000
            
            if self._metrics:
                self._metrics.record(metrics)
            
            logger.debug(
                f"{method} {url} - {metrics.status_code or 'ERR'} "
                f"({metrics.duration_ms:.1f}ms, retries={retry_count})"
            )
    
    async def _execute_once(
        self,
        method: str,
        url: str,
        **kwargs,
    ) -> Any:
        """Execute single request without retry."""
        client = self._get_http_client()
        
        if hasattr(client, 'request'):
            return await client.request(method, url, **kwargs)
        else:
            # httpx-style client
            return await client.request(method, url, **kwargs)
    
    async def _execute_with_retry(
        self,
        method: str,
        url: str,
        **kwargs,
    ) -> tuple:
        """Execute request with retry, return (response, retry_count)."""
        retry_count = 0
        retry_config = self.config.to_retry_config()
        
        async def make_request():
            nonlocal retry_count
            retry_count += 1
            return await self._execute_once(method, url, **kwargs)
        
        response = await retry_async(make_request, retry_config)
        return response, max(0, retry_count - 1)  # -1 because first attempt isn't a "retry"
    
    # Convenience methods
    async def get(self, url: str, **kwargs) -> Any:
        """GET request."""
        return await self.request("GET", url, **kwargs)
    
    async def post(self, url: str, **kwargs) -> Any:
        """POST request."""
        return await self.request("POST", url, **kwargs)
    
    async def put(self, url: str, **kwargs) -> Any:
        """PUT request."""
        return await self.request("PUT", url, **kwargs)
    
    async def delete(self, url: str, **kwargs) -> Any:
        """DELETE request."""
        return await self.request("DELETE", url, **kwargs)
    
    async def patch(self, url: str, **kwargs) -> Any:
        """PATCH request."""
        return await self.request("PATCH", url, **kwargs)
    
    # Metrics and stats
    def get_metrics(self) -> Optional[Dict[str, Any]]:
        """Get request metrics summary."""
        if self._metrics:
            return self._metrics.get_summary()
        return None
    
    def get_circuit_breaker_stats(self, backend: Optional[str] = None) -> Dict[str, Any]:
        """Get circuit breaker stats."""
        if backend:
            return self._circuit_breaker.get_stats(backend)
        return {
            b: self._circuit_breaker.get_stats(b)
            for b in self._circuit_breaker._states.keys()
        }
    
    def reset_circuit_breaker(self, backend: str) -> None:
        """Reset circuit breaker for backend."""
        self._circuit_breaker.reset(backend)
        logger.info(f"Circuit breaker reset for {backend}")
    
    async def close(self) -> None:
        """Close the client."""
        if not self._closed and self._http_client:
            if hasattr(self._http_client, 'close'):
                await self._http_client.close()
            elif hasattr(self._http_client, 'aclose'):
                await self._http_client.aclose()
            self._closed = True
    
    async def __aenter__(self):
        return self
    
    async def __aexit__(self, exc_type, exc_val, exc_tb):
        await self.close()
        return False


# ========================================
# Factory Functions
# ========================================

_global_clients: Dict[str, ResilientHTTPClient] = {}
_clients_lock = threading.Lock()


def create_resilient_client(
    name: str = "default",
    config: Optional[ResilientClientConfig] = None,
) -> ResilientHTTPClient:
    """
    Create a named resilient client.
    
    Clients are cached by name, so calling with same name
    returns the same client instance.
    """
    with _clients_lock:
        if name not in _global_clients:
            _global_clients[name] = ResilientHTTPClient(config)
        return _global_clients[name]


def get_resilient_client(name: str = "default") -> Optional[ResilientHTTPClient]:
    """Get existing client by name."""
    return _global_clients.get(name)


# ========================================
# Pre-configured Clients
# ========================================

def get_llm_client() -> ResilientHTTPClient:
    """Get client configured for LLM backends."""
    return create_resilient_client("llm", ResilientClientConfig.for_llm_backend())


def get_metadata_client() -> ResilientHTTPClient:
    """Get client configured for metadata services."""
    return create_resilient_client("metadata", ResilientClientConfig.for_metadata_service())


def get_elasticsearch_client() -> ResilientHTTPClient:
    """Get client configured for Elasticsearch."""
    return create_resilient_client("elasticsearch", ResilientClientConfig.for_elasticsearch())