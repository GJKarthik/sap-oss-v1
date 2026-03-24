# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
OpenTelemetry distributed tracing for Data Cleaning Copilot.

Provides:
- Automatic trace context propagation
- Span creation for key operations
- Integration with LLM calls, sandbox execution, and MCP requests
- Export to OTLP endpoints (Jaeger, Zipkin, etc.)
"""

import os
import functools
from typing import Any, Callable, Dict, Optional
from contextlib import contextmanager
from loguru import logger

# =============================================================================
# OpenTelemetry Configuration (optional dependency)
# =============================================================================

_OTEL_AVAILABLE = False
_tracer = None

# Trace context for propagation
_current_trace_context: Dict[str, str] = {}

try:
    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor, ConsoleSpanExporter
    from opentelemetry.sdk.resources import Resource, SERVICE_NAME
    from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator
    from opentelemetry.propagate import set_global_textmap, inject, extract
    from opentelemetry.trace import Status, StatusCode, SpanKind

    # Check for OTLP exporter
    try:
        from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

        _OTLP_AVAILABLE = True
    except ImportError:
        _OTLP_AVAILABLE = False

    _OTEL_AVAILABLE = True

except ImportError:
    logger.debug("opentelemetry packages not installed; distributed tracing disabled")
    _OTLP_AVAILABLE = False


def init_tracing(
    service_name: str = "data-cleaning-copilot",
    otlp_endpoint: Optional[str] = None,
    enable_console_export: bool = False,
) -> bool:
    """
    Initialize OpenTelemetry tracing.

    Parameters
    ----------
    service_name : str
        Name of the service for trace identification
    otlp_endpoint : Optional[str]
        OTLP collector endpoint (e.g., "http://localhost:4317")
        Falls back to OTEL_EXPORTER_OTLP_ENDPOINT env var
    enable_console_export : bool
        If True, also export spans to console (for debugging)

    Returns
    -------
    bool
        True if tracing was initialized successfully
    """
    global _tracer

    if not _OTEL_AVAILABLE:
        logger.warning("OpenTelemetry not available; tracing disabled")
        return False

    try:
        # Create resource with service name
        resource = Resource.create({SERVICE_NAME: service_name})

        # Create tracer provider
        provider = TracerProvider(resource=resource)

        # Configure exporters
        endpoint = otlp_endpoint or os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT")

        if endpoint and _OTLP_AVAILABLE:
            otlp_exporter = OTLPSpanExporter(endpoint=endpoint, insecure=True)
            provider.add_span_processor(BatchSpanProcessor(otlp_exporter))
            logger.info(f"OTLP trace exporter configured: {endpoint}")

        if enable_console_export or os.environ.get("OTEL_CONSOLE_EXPORT") == "true":
            console_exporter = ConsoleSpanExporter()
            provider.add_span_processor(BatchSpanProcessor(console_exporter))
            logger.info("Console trace exporter enabled")

        # Set as global tracer provider
        trace.set_tracer_provider(provider)

        # Set up W3C Trace Context propagation
        set_global_textmap(TraceContextTextMapPropagator())

        # Get tracer
        _tracer = trace.get_tracer(service_name)

        logger.info(f"OpenTelemetry tracing initialized for service: {service_name}")
        return True

    except Exception as e:
        logger.error(f"Failed to initialize tracing: {e}")
        return False


def tracing_available() -> bool:
    """Check if tracing is available and initialized."""
    return _OTEL_AVAILABLE and _tracer is not None


def get_tracer():
    """Get the initialized tracer, or None if not available."""
    return _tracer


# =============================================================================
# Span Context Management
# =============================================================================


@contextmanager
def create_span(
    name: str,
    kind: Optional[str] = None,
    attributes: Optional[Dict[str, Any]] = None,
):
    """
    Create a new span for tracing an operation.

    Parameters
    ----------
    name : str
        Name of the span
    kind : Optional[str]
        Span kind: "internal", "server", "client", "producer", "consumer"
    attributes : Optional[Dict[str, Any]]
        Additional attributes to attach to the span

    Yields
    ------
    The span object (or a no-op context if tracing is disabled)
    """
    if not tracing_available():
        yield None
        return

    # Map string kind to SpanKind enum
    span_kind = SpanKind.INTERNAL
    if kind:
        kind_map = {
            "internal": SpanKind.INTERNAL,
            "server": SpanKind.SERVER,
            "client": SpanKind.CLIENT,
            "producer": SpanKind.PRODUCER,
            "consumer": SpanKind.CONSUMER,
        }
        span_kind = kind_map.get(kind.lower(), SpanKind.INTERNAL)

    with _tracer.start_as_current_span(name, kind=span_kind) as span:
        if attributes:
            for key, value in attributes.items():
                if value is not None:
                    span.set_attribute(key, str(value) if not isinstance(value, (int, float, bool)) else value)
        try:
            yield span
        except Exception as e:
            span.set_status(Status(StatusCode.ERROR, str(e)))
            span.record_exception(e)
            raise


def traced(
    name: Optional[str] = None,
    kind: str = "internal",
    attributes: Optional[Dict[str, Any]] = None,
):
    """
    Decorator to automatically trace a function.

    Parameters
    ----------
    name : Optional[str]
        Span name (defaults to function name)
    kind : str
        Span kind
    attributes : Optional[Dict[str, Any]]
        Static attributes to add to every span

    Example
    -------
    @traced("llm.generate_checks", kind="client")
    def generate_checks(self, table_name: str):
        ...
    """

    def decorator(func: Callable) -> Callable:
        span_name = name or f"{func.__module__}.{func.__qualname__}"

        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            with create_span(span_name, kind=kind, attributes=attributes) as span:
                return func(*args, **kwargs)

        @functools.wraps(func)
        async def async_wrapper(*args, **kwargs):
            with create_span(span_name, kind=kind, attributes=attributes) as span:
                return await func(*args, **kwargs)

        # Return appropriate wrapper based on function type
        if hasattr(func, "__wrapped__") or not callable(func):
            return func

        import asyncio

        if asyncio.iscoroutinefunction(func):
            return async_wrapper
        return wrapper

    return decorator


# =============================================================================
# Trace Context Propagation
# =============================================================================


def inject_trace_context(headers: Dict[str, str]) -> Dict[str, str]:
    """
    Inject trace context into HTTP headers for propagation.

    Parameters
    ----------
    headers : Dict[str, str]
        Headers dict to inject trace context into

    Returns
    -------
    Dict[str, str]
        Headers with trace context added
    """
    if not _OTEL_AVAILABLE:
        return headers

    inject(headers)
    return headers


def extract_trace_context(headers: Dict[str, str]):
    """
    Extract trace context from incoming HTTP headers.

    Parameters
    ----------
    headers : Dict[str, str]
        Headers dict containing trace context

    Returns
    -------
    Context object for continuing the trace
    """
    if not _OTEL_AVAILABLE:
        return None

    return extract(headers)


@contextmanager
def continue_trace(headers: Dict[str, str], span_name: str, kind: str = "server"):
    """
    Continue a trace from incoming headers.

    Parameters
    ----------
    headers : Dict[str, str]
        Incoming HTTP headers with trace context
    span_name : str
        Name for the new span
    kind : str
        Span kind (typically "server" for incoming requests)

    Yields
    ------
    The span object
    """
    if not tracing_available():
        yield None
        return

    context = extract_trace_context(headers)
    span_kind = SpanKind.SERVER if kind == "server" else SpanKind.INTERNAL

    with _tracer.start_as_current_span(span_name, context=context, kind=span_kind) as span:
        yield span


# =============================================================================
# Pre-configured Traced Operations
# =============================================================================


@contextmanager
def trace_llm_call(provider: str, model: str, operation: str = "completion"):
    """
    Trace an LLM API call.

    Parameters
    ----------
    provider : str
        LLM provider name (e.g., "anthropic", "openai")
    model : str
        Model identifier
    operation : str
        Operation type (e.g., "completion", "chat", "embedding")
    """
    attributes = {
        "llm.provider": provider,
        "llm.model": model,
        "llm.operation": operation,
    }

    with create_span(f"llm.{operation}", kind="client", attributes=attributes) as span:
        yield span

        # Allow caller to add token counts etc.
        if span and hasattr(span, "set_attribute"):
            pass  # Span attributes can be set by caller


@contextmanager
def trace_sandbox_execution(function_name: str, timeout: float, memory_limit_mb: int):
    """
    Trace a sandbox code execution.

    Parameters
    ----------
    function_name : str
        Name of the function being executed
    timeout : float
        Configured timeout in seconds
    memory_limit_mb : int
        Configured memory limit in MB
    """
    attributes = {
        "sandbox.function_name": function_name,
        "sandbox.timeout_seconds": timeout,
        "sandbox.memory_limit_mb": memory_limit_mb,
    }

    with create_span("sandbox.execute", kind="internal", attributes=attributes) as span:
        yield span


@contextmanager
def trace_mcp_tool_call(tool_name: str, endpoint: Optional[str] = None):
    """
    Trace an MCP tool call.

    Parameters
    ----------
    tool_name : str
        Name of the MCP tool being called
    endpoint : Optional[str]
        Remote endpoint if this is a federated call
    """
    attributes = {
        "mcp.tool_name": tool_name,
    }
    if endpoint:
        attributes["mcp.endpoint"] = endpoint
        span_kind = "client"
    else:
        span_kind = "internal"

    with create_span(f"mcp.tool.{tool_name}", kind=span_kind, attributes=attributes) as span:
        yield span


@contextmanager
def trace_database_operation(operation: str, table_name: Optional[str] = None):
    """
    Trace a database operation.

    Parameters
    ----------
    operation : str
        Operation type (e.g., "query", "validate", "profile")
    table_name : Optional[str]
        Table being operated on
    """
    attributes = {
        "db.operation": operation,
    }
    if table_name:
        attributes["db.table"] = table_name

    with create_span(f"db.{operation}", kind="internal", attributes=attributes) as span:
        yield span


@contextmanager
def trace_check_generation(agent_version: str, database_id: str, iteration: Optional[int] = None):
    """
    Trace check generation by an agent.

    Parameters
    ----------
    agent_version : str
        Version of the agent (v1, v2, v3)
    database_id : str
        Database identifier
    iteration : Optional[int]
        Iteration number for iterative agents
    """
    attributes = {
        "agent.version": agent_version,
        "agent.database_id": database_id,
    }
    if iteration is not None:
        attributes["agent.iteration"] = iteration

    with create_span("agent.generate_checks", kind="internal", attributes=attributes) as span:
        yield span


# =============================================================================
# Utility Functions
# =============================================================================


def add_span_attribute(key: str, value: Any) -> None:
    """Add an attribute to the current span."""
    if not _OTEL_AVAILABLE:
        return

    span = trace.get_current_span()
    if span and span.is_recording():
        span.set_attribute(key, str(value) if not isinstance(value, (int, float, bool)) else value)


def add_span_event(name: str, attributes: Optional[Dict[str, Any]] = None) -> None:
    """Add an event to the current span."""
    if not _OTEL_AVAILABLE:
        return

    span = trace.get_current_span()
    if span and span.is_recording():
        span.add_event(name, attributes=attributes or {})


def set_span_error(error: Exception) -> None:
    """Mark the current span as errored."""
    if not _OTEL_AVAILABLE:
        return

    span = trace.get_current_span()
    if span and span.is_recording():
        span.set_status(Status(StatusCode.ERROR, str(error)))
        span.record_exception(error)


def get_trace_id() -> Optional[str]:
    """Get the current trace ID as a hex string."""
    if not _OTEL_AVAILABLE:
        return None

    span = trace.get_current_span()
    if span and span.get_span_context().is_valid:
        return format(span.get_span_context().trace_id, "032x")
    return None


def get_span_id() -> Optional[str]:
    """Get the current span ID as a hex string."""
    if not _OTEL_AVAILABLE:
        return None

    span = trace.get_current_span()
    if span and span.get_span_context().is_valid:
        return format(span.get_span_context().span_id, "016x")
    return None