"""
Prometheus Metrics for HANA Integration.

Implements Enhancement 5.2: Detailed Metrics (Prometheus)
- Query latency histograms
- Operation counters
- Cache hit rates
- Circuit breaker states

Usage:
    from observability.hana_metrics import get_metrics_registry, record_query_latency
    
    record_query_latency("hana_vector", 150.5)
"""

import logging
import os
import time
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional
from functools import wraps

logger = logging.getLogger(__name__)

# Configuration
METRICS_ENABLED = os.getenv("METRICS_ENABLED", "true").lower() == "true"
METRICS_PORT = int(os.getenv("METRICS_PORT", "9090"))

# Try to import Prometheus client
try:
    from prometheus_client import (
        Counter, Gauge, Histogram, Summary, Info,
        CollectorRegistry, generate_latest, CONTENT_TYPE_LATEST,
        start_http_server
    )
    PROMETHEUS_AVAILABLE = True
except ImportError:
    PROMETHEUS_AVAILABLE = False
    logger.warning("Prometheus client not installed. Install with: pip install prometheus-client")


# Latency buckets (in milliseconds)
LATENCY_BUCKETS = (
    5, 10, 25, 50, 75, 100, 150, 200, 300, 500, 750, 1000, 2000, 5000, 10000
)


class HanaMetrics:
    """
    Prometheus metrics for HANA integration.
    
    Exposes metrics for:
    - Query operations (latency, count, errors)
    - Cache performance (hits, misses, size)
    - Embedding operations (batch size, throughput)
    - Circuit breaker states
    - Connection pool health
    """
    
    def __init__(self, enabled: bool = METRICS_ENABLED):
        self.enabled = enabled and PROMETHEUS_AVAILABLE
        self._registry = CollectorRegistry() if self.enabled else None
        self._initialized = False
        
        # Metric instances
        self._metrics: Dict[str, Any] = {}
        
        if self.enabled:
            self._create_metrics()
    
    def _create_metrics(self) -> None:
        """Create all Prometheus metrics."""
        if not self.enabled:
            return
        
        # === Query Metrics ===
        
        self._metrics["query_latency"] = Histogram(
            "hana_query_latency_seconds",
            "Query latency in seconds",
            ["operation", "path", "status"],
            buckets=[b/1000.0 for b in LATENCY_BUCKETS],
            registry=self._registry,
        )
        
        self._metrics["query_total"] = Counter(
            "hana_query_total",
            "Total queries processed",
            ["operation", "path", "status"],
            registry=self._registry,
        )
        
        self._metrics["query_errors"] = Counter(
            "hana_query_errors_total",
            "Total query errors",
            ["operation", "error_type"],
            registry=self._registry,
        )
        
        # === Cache Metrics ===
        
        self._metrics["cache_hits"] = Counter(
            "hana_cache_hits_total",
            "Cache hits",
            ["cache_type", "hit_type"],  # hit_type: exact, semantic
            registry=self._registry,
        )
        
        self._metrics["cache_misses"] = Counter(
            "hana_cache_misses_total",
            "Cache misses",
            ["cache_type"],
            registry=self._registry,
        )
        
        self._metrics["cache_size"] = Gauge(
            "hana_cache_size",
            "Current cache size",
            ["cache_type"],
            registry=self._registry,
        )
        
        self._metrics["cache_hit_rate"] = Gauge(
            "hana_cache_hit_rate",
            "Cache hit rate (0-1)",
            ["cache_type"],
            registry=self._registry,
        )
        
        # === Embedding Metrics ===
        
        self._metrics["embedding_latency"] = Histogram(
            "hana_embedding_latency_seconds",
            "Embedding generation latency",
            ["batch_size_bucket"],
            buckets=[b/1000.0 for b in LATENCY_BUCKETS],
            registry=self._registry,
        )
        
        self._metrics["embedding_batch_size"] = Histogram(
            "hana_embedding_batch_size",
            "Embedding batch sizes",
            buckets=[1, 2, 4, 8, 16, 32, 64, 128],
            registry=self._registry,
        )
        
        self._metrics["embedding_throughput"] = Gauge(
            "hana_embedding_throughput",
            "Embeddings per second",
            registry=self._registry,
        )
        
        # === Circuit Breaker Metrics ===
        
        self._metrics["circuit_state"] = Gauge(
            "hana_circuit_breaker_state",
            "Circuit breaker state (0=closed, 1=half-open, 2=open)",
            ["circuit_name"],
            registry=self._registry,
        )
        
        self._metrics["circuit_failures"] = Counter(
            "hana_circuit_breaker_failures_total",
            "Circuit breaker failure count",
            ["circuit_name"],
            registry=self._registry,
        )
        
        self._metrics["circuit_fallbacks"] = Counter(
            "hana_circuit_breaker_fallbacks_total",
            "Circuit breaker fallback count",
            ["circuit_name"],
            registry=self._registry,
        )
        
        # === Connection Pool Metrics ===
        
        self._metrics["pool_connections"] = Gauge(
            "hana_pool_connections",
            "Active pool connections",
            ["state"],  # idle, in_use
            registry=self._registry,
        )
        
        self._metrics["pool_wait_time"] = Histogram(
            "hana_pool_wait_seconds",
            "Time waiting for pool connection",
            buckets=[0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0],
            registry=self._registry,
        )
        
        # === Speculative Execution Metrics ===
        
        self._metrics["speculation_wins"] = Counter(
            "hana_speculation_wins_total",
            "Speculative execution wins",
            registry=self._registry,
        )
        
        self._metrics["speculation_latency_saved"] = Counter(
            "hana_speculation_latency_saved_seconds",
            "Total latency saved by speculation",
            registry=self._registry,
        )
        
        self._metrics["speculation_paths_cancelled"] = Counter(
            "hana_speculation_paths_cancelled_total",
            "Speculative paths cancelled",
            registry=self._registry,
        )
        
        # === Resolution Path Metrics ===
        
        self._metrics["resolution_path_selected"] = Counter(
            "hana_resolution_path_selected_total",
            "Resolution path selections",
            ["path"],
            registry=self._registry,
        )
        
        self._metrics["resolution_path_success"] = Counter(
            "hana_resolution_path_success_total",
            "Resolution path successes",
            ["path"],
            registry=self._registry,
        )
        
        # === Service Info ===
        
        self._metrics["info"] = Info(
            "hana_integration",
            "HANA integration service info",
            registry=self._registry,
        )
        self._metrics["info"].info({
            "version": "1.0.0",
            "service": "mangle-query-service",
        })
        
        self._initialized = True
        logger.info("Prometheus metrics initialized")
    
    # === Recording Methods ===
    
    def record_query(
        self,
        operation: str,
        path: str,
        latency_ms: float,
        success: bool = True,
        error_type: Optional[str] = None,
    ) -> None:
        """Record a query operation."""
        if not self.enabled:
            return
        
        status = "success" if success else "error"
        
        self._metrics["query_latency"].labels(
            operation=operation, path=path, status=status
        ).observe(latency_ms / 1000.0)
        
        self._metrics["query_total"].labels(
            operation=operation, path=path, status=status
        ).inc()
        
        if not success and error_type:
            self._metrics["query_errors"].labels(
                operation=operation, error_type=error_type
            ).inc()
    
    def record_cache_hit(self, cache_type: str, hit_type: str = "exact") -> None:
        """Record a cache hit."""
        if not self.enabled:
            return
        self._metrics["cache_hits"].labels(
            cache_type=cache_type, hit_type=hit_type
        ).inc()
    
    def record_cache_miss(self, cache_type: str) -> None:
        """Record a cache miss."""
        if not self.enabled:
            return
        self._metrics["cache_misses"].labels(cache_type=cache_type).inc()
    
    def set_cache_size(self, cache_type: str, size: int) -> None:
        """Set current cache size."""
        if not self.enabled:
            return
        self._metrics["cache_size"].labels(cache_type=cache_type).set(size)
    
    def set_cache_hit_rate(self, cache_type: str, rate: float) -> None:
        """Set cache hit rate."""
        if not self.enabled:
            return
        self._metrics["cache_hit_rate"].labels(cache_type=cache_type).set(rate)
    
    def record_embedding(self, batch_size: int, latency_ms: float) -> None:
        """Record an embedding operation."""
        if not self.enabled:
            return
        
        bucket = str(min(128, 2 ** (batch_size - 1).bit_length()))
        self._metrics["embedding_latency"].labels(
            batch_size_bucket=bucket
        ).observe(latency_ms / 1000.0)
        
        self._metrics["embedding_batch_size"].observe(batch_size)
    
    def set_embedding_throughput(self, throughput: float) -> None:
        """Set embedding throughput."""
        if not self.enabled:
            return
        self._metrics["embedding_throughput"].set(throughput)
    
    def set_circuit_state(self, circuit_name: str, state: str) -> None:
        """Set circuit breaker state."""
        if not self.enabled:
            return
        state_value = {"closed": 0, "half_open": 1, "open": 2}.get(state, 0)
        self._metrics["circuit_state"].labels(circuit_name=circuit_name).set(state_value)
    
    def record_circuit_failure(self, circuit_name: str) -> None:
        """Record circuit breaker failure."""
        if not self.enabled:
            return
        self._metrics["circuit_failures"].labels(circuit_name=circuit_name).inc()
    
    def record_circuit_fallback(self, circuit_name: str) -> None:
        """Record circuit breaker fallback."""
        if not self.enabled:
            return
        self._metrics["circuit_fallbacks"].labels(circuit_name=circuit_name).inc()
    
    def set_pool_connections(self, idle: int, in_use: int) -> None:
        """Set connection pool state."""
        if not self.enabled:
            return
        self._metrics["pool_connections"].labels(state="idle").set(idle)
        self._metrics["pool_connections"].labels(state="in_use").set(in_use)
    
    def record_pool_wait(self, wait_seconds: float) -> None:
        """Record time waiting for pool connection."""
        if not self.enabled:
            return
        self._metrics["pool_wait_time"].observe(wait_seconds)
    
    def record_speculation_win(self, latency_saved_ms: float) -> None:
        """Record a speculative execution win."""
        if not self.enabled:
            return
        self._metrics["speculation_wins"].inc()
        self._metrics["speculation_latency_saved"].inc(latency_saved_ms / 1000.0)
    
    def record_speculation_cancelled(self, count: int = 1) -> None:
        """Record cancelled speculative paths."""
        if not self.enabled:
            return
        self._metrics["speculation_paths_cancelled"].inc(count)
    
    def record_resolution_path(self, path: str, success: bool = True) -> None:
        """Record resolution path selection."""
        if not self.enabled:
            return
        self._metrics["resolution_path_selected"].labels(path=path).inc()
        if success:
            self._metrics["resolution_path_success"].labels(path=path).inc()
    
    # === Export Methods ===
    
    def get_metrics_output(self) -> bytes:
        """Get Prometheus metrics output."""
        if not self.enabled:
            return b"# Metrics disabled\n"
        return generate_latest(self._registry)
    
    def get_content_type(self) -> str:
        """Get Prometheus content type."""
        return CONTENT_TYPE_LATEST if self.enabled else "text/plain"
    
    def start_server(self, port: int = METRICS_PORT) -> None:
        """Start Prometheus metrics HTTP server."""
        if not self.enabled:
            logger.warning("Metrics server not started - metrics disabled")
            return
        
        start_http_server(port, registry=self._registry)
        logger.info(f"Prometheus metrics server started on port {port}")


# Singleton instance
_metrics: Optional[HanaMetrics] = None


def get_metrics_registry() -> HanaMetrics:
    """Get or create the metrics registry singleton."""
    global _metrics
    
    if _metrics is None:
        _metrics = HanaMetrics()
    
    return _metrics


# Convenience functions
def record_query_latency(operation: str, path: str, latency_ms: float, success: bool = True):
    """Record query latency."""
    get_metrics_registry().record_query(operation, path, latency_ms, success)


def record_cache_hit(cache_type: str, hit_type: str = "exact"):
    """Record cache hit."""
    get_metrics_registry().record_cache_hit(cache_type, hit_type)


def record_cache_miss(cache_type: str):
    """Record cache miss."""
    get_metrics_registry().record_cache_miss(cache_type)


# Decorator for automatic latency recording
def measure_latency(operation: str, path: str = "default"):
    """Decorator to measure and record operation latency."""
    def decorator(func: Callable) -> Callable:
        @wraps(func)
        async def async_wrapper(*args, **kwargs):
            start = time.time()
            success = True
            try:
                return await func(*args, **kwargs)
            except Exception:
                success = False
                raise
            finally:
                latency_ms = (time.time() - start) * 1000
                record_query_latency(operation, path, latency_ms, success)
        
        @wraps(func)
        def sync_wrapper(*args, **kwargs):
            start = time.time()
            success = True
            try:
                return func(*args, **kwargs)
            except Exception:
                success = False
                raise
            finally:
                latency_ms = (time.time() - start) * 1000
                record_query_latency(operation, path, latency_ms, success)
        
        import asyncio
        if asyncio.iscoroutinefunction(func):
            return async_wrapper
        return sync_wrapper
    
    return decorator