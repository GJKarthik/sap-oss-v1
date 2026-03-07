"""
OpenTelemetry Tracing for HANA Integration.

Implements Enhancement 5.1: Distributed Tracing (OpenTelemetry)
- End-to-end request tracing
- HANA operation spans
- Automatic context propagation

Usage:
    from observability.hana_tracing import trace_hana_operation, get_tracer
    
    @trace_hana_operation("vector_search")
    async def search(query: str):
        ...
"""

import asyncio
import logging
import os
import time
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from functools import wraps
from typing import Any, Callable, Dict, List, Optional

logger = logging.getLogger(__name__)

# Configuration
OTEL_ENABLED = os.getenv("OTEL_ENABLED", "true").lower() == "true"
OTEL_SERVICE_NAME = os.getenv("OTEL_SERVICE_NAME", "mangle-query-service")
OTEL_EXPORTER_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4317")
SLOW_QUERY_THRESHOLD_MS = float(os.getenv("SLOW_QUERY_THRESHOLD_MS", "500.0"))

# Try to import OpenTelemetry
try:
    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
    from opentelemetry.trace import Status, StatusCode, SpanKind
    from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator
    OTEL_AVAILABLE = True
except ImportError:
    OTEL_AVAILABLE = False
    logger.warning("OpenTelemetry not installed. Install with: pip install opentelemetry-api opentelemetry-sdk opentelemetry-exporter-otlp")


@dataclass
class SpanMetrics:
    """Metrics collected from spans."""
    total_spans: int = 0
    total_errors: int = 0
    total_duration_ms: float = 0.0
    slow_queries: int = 0
    by_operation: Dict[str, Dict[str, Any]] = field(default_factory=dict)


class HanaTracer:
    """
    OpenTelemetry tracer for HANA operations.
    
    Provides distributed tracing for:
    - Query resolution paths
    - HANA vector search
    - Embedding generation
    - MCP tool calls
    - Circuit breaker events
    """
    
    def __init__(
        self,
        service_name: str = OTEL_SERVICE_NAME,
        exporter_endpoint: str = OTEL_EXPORTER_ENDPOINT,
        enabled: bool = OTEL_ENABLED,
    ):
        self.service_name = service_name
        self.exporter_endpoint = exporter_endpoint
        self.enabled = enabled and OTEL_AVAILABLE
        
        self._tracer = None
        self._provider = None
        self._propagator = None
        self._metrics = SpanMetrics()
        self._initialized = False
    
    def initialize(self) -> bool:
        """Initialize OpenTelemetry tracer."""
        if not self.enabled:
            logger.info("OpenTelemetry tracing disabled")
            return False
        
        if self._initialized:
            return True
        
        try:
            # Create resource with service info
            resource = Resource.create({
                "service.name": self.service_name,
                "service.namespace": "sap-oss",
                "deployment.environment": os.getenv("ENVIRONMENT", "development"),
            })
            
            # Create tracer provider
            self._provider = TracerProvider(resource=resource)
            
            # Add OTLP exporter
            exporter = OTLPSpanExporter(endpoint=self.exporter_endpoint, insecure=True)
            processor = BatchSpanProcessor(exporter)
            self._provider.add_span_processor(processor)
            
            # Set as global tracer provider
            trace.set_tracer_provider(self._provider)
            
            # Get tracer
            self._tracer = trace.get_tracer(
                instrumenting_module_name="hana_integration",
                instrumenting_library_version="1.0.0",
            )
            
            # Create propagator for context propagation
            self._propagator = TraceContextTextMapPropagator()
            
            self._initialized = True
            logger.info(f"OpenTelemetry tracing initialized: endpoint={self.exporter_endpoint}")
            return True
            
        except Exception as e:
            logger.error(f"Failed to initialize OpenTelemetry: {e}")
            return False
    
    def get_tracer(self):
        """Get the OpenTelemetry tracer."""
        if not self._initialized:
            self.initialize()
        return self._tracer
    
    @asynccontextmanager
    async def span(
        self,
        name: str,
        kind: str = "internal",
        attributes: Optional[Dict[str, Any]] = None,
    ):
        """
        Create a traced span for an operation.
        
        Usage:
            async with tracer.span("hana_vector_search", attributes={"k": 5}):
                results = await search(query)
        """
        if not self.enabled or not self._initialized:
            yield None
            return
        
        span_kind = {
            "internal": SpanKind.INTERNAL,
            "client": SpanKind.CLIENT,
            "server": SpanKind.SERVER,
            "producer": SpanKind.PRODUCER,
            "consumer": SpanKind.CONSUMER,
        }.get(kind, SpanKind.INTERNAL)
        
        start_time = time.time()
        
        with self._tracer.start_as_current_span(
            name,
            kind=span_kind,
            attributes=attributes or {},
        ) as span:
            self._metrics.total_spans += 1
            
            try:
                yield span
                
                duration_ms = (time.time() - start_time) * 1000
                span.set_attribute("duration_ms", duration_ms)
                
                # Track slow queries
                if duration_ms > SLOW_QUERY_THRESHOLD_MS:
                    self._metrics.slow_queries += 1
                    span.set_attribute("slow_query", True)
                    span.add_event("slow_query_detected", {
                        "threshold_ms": SLOW_QUERY_THRESHOLD_MS,
                        "duration_ms": duration_ms,
                    })
                
                self._metrics.total_duration_ms += duration_ms
                self._update_operation_metrics(name, duration_ms, success=True)
                
            except Exception as e:
                duration_ms = (time.time() - start_time) * 1000
                
                span.set_status(Status(StatusCode.ERROR, str(e)))
                span.record_exception(e)
                span.set_attribute("error.type", type(e).__name__)
                span.set_attribute("error.message", str(e))
                
                self._metrics.total_errors += 1
                self._update_operation_metrics(name, duration_ms, success=False)
                
                raise
    
    def _update_operation_metrics(
        self,
        operation: str,
        duration_ms: float,
        success: bool,
    ) -> None:
        """Update per-operation metrics."""
        if operation not in self._metrics.by_operation:
            self._metrics.by_operation[operation] = {
                "count": 0,
                "errors": 0,
                "total_duration_ms": 0.0,
                "min_duration_ms": float("inf"),
                "max_duration_ms": 0.0,
            }
        
        op_metrics = self._metrics.by_operation[operation]
        op_metrics["count"] += 1
        op_metrics["total_duration_ms"] += duration_ms
        op_metrics["min_duration_ms"] = min(op_metrics["min_duration_ms"], duration_ms)
        op_metrics["max_duration_ms"] = max(op_metrics["max_duration_ms"], duration_ms)
        
        if not success:
            op_metrics["errors"] += 1
    
    def inject_context(self, carrier: Dict[str, str]) -> None:
        """Inject trace context into carrier for propagation."""
        if self._propagator:
            self._propagator.inject(carrier)
    
    def extract_context(self, carrier: Dict[str, str]):
        """Extract trace context from carrier."""
        if self._propagator:
            return self._propagator.extract(carrier)
        return None
    
    def get_metrics(self) -> Dict[str, Any]:
        """Get tracing metrics."""
        metrics = {
            "enabled": self.enabled,
            "initialized": self._initialized,
            "total_spans": self._metrics.total_spans,
            "total_errors": self._metrics.total_errors,
            "error_rate": self._metrics.total_errors / self._metrics.total_spans if self._metrics.total_spans > 0 else 0,
            "slow_queries": self._metrics.slow_queries,
            "avg_duration_ms": self._metrics.total_duration_ms / self._metrics.total_spans if self._metrics.total_spans > 0 else 0,
            "by_operation": {},
        }
        
        for op, op_metrics in self._metrics.by_operation.items():
            count = op_metrics["count"]
            metrics["by_operation"][op] = {
                "count": count,
                "errors": op_metrics["errors"],
                "error_rate": op_metrics["errors"] / count if count > 0 else 0,
                "avg_duration_ms": op_metrics["total_duration_ms"] / count if count > 0 else 0,
                "min_duration_ms": op_metrics["min_duration_ms"] if op_metrics["min_duration_ms"] != float("inf") else 0,
                "max_duration_ms": op_metrics["max_duration_ms"],
            }
        
        return metrics
    
    def shutdown(self) -> None:
        """Shutdown tracer and flush spans."""
        if self._provider:
            self._provider.shutdown()


# Singleton instance
_tracer: Optional[HanaTracer] = None


def get_tracer() -> HanaTracer:
    """Get or create the tracer singleton."""
    global _tracer
    
    if _tracer is None:
        _tracer = HanaTracer()
        _tracer.initialize()
    
    return _tracer


def trace_hana_operation(
    operation_name: str,
    kind: str = "client",
    include_args: bool = False,
):
    """
    Decorator to trace HANA operations.
    
    Usage:
        @trace_hana_operation("vector_search")
        async def search(query: str, k: int = 5):
            ...
    """
    def decorator(func: Callable) -> Callable:
        @wraps(func)
        async def async_wrapper(*args, **kwargs):
            tracer = get_tracer()
            
            attributes = {"operation": operation_name}
            if include_args:
                # Add serializable args to attributes
                for i, arg in enumerate(args):
                    if isinstance(arg, (str, int, float, bool)):
                        attributes[f"arg_{i}"] = arg
                for key, value in kwargs.items():
                    if isinstance(value, (str, int, float, bool)):
                        attributes[f"kwarg_{key}"] = value
            
            async with tracer.span(operation_name, kind=kind, attributes=attributes):
                return await func(*args, **kwargs)
        
        @wraps(func)
        def sync_wrapper(*args, **kwargs):
            # For sync functions, just call directly (no tracing)
            return func(*args, **kwargs)
        
        if asyncio.iscoroutinefunction(func):
            return async_wrapper
        return sync_wrapper
    
    return decorator


# Pre-defined operation tracers
def trace_vector_search(func):
    """Trace vector search operations."""
    return trace_hana_operation("hana.vector_search", kind="client")(func)


def trace_embedding(func):
    """Trace embedding operations."""
    return trace_hana_operation("hana.embedding", kind="client")(func)


def trace_analytical_query(func):
    """Trace analytical query operations."""
    return trace_hana_operation("hana.analytical", kind="client")(func)


def trace_mcp_call(func):
    """Trace MCP tool calls."""
    return trace_hana_operation("mcp.tool_call", kind="server")(func)


def trace_resolution(func):
    """Trace query resolution."""
    return trace_hana_operation("resolution.resolve", kind="internal")(func)