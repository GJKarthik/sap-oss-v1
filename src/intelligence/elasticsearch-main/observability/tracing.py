"""
Distributed Tracing Module - Observability Without External Dependencies.

Day 53 Implementation - Week 11 Observability & Monitoring
Provides distributed tracing with W3C Trace Context support.
No external service dependencies - pure Python implementation.
"""

import time
import threading
import uuid
from typing import Optional, Dict, Any, List, Callable
from dataclasses import dataclass, field
from enum import Enum
from contextlib import contextmanager
from functools import wraps
import json


# =============================================================================
# Trace Context
# =============================================================================

class SpanKind(Enum):
    """Type of span."""
    INTERNAL = "internal"
    SERVER = "server"
    CLIENT = "client"
    PRODUCER = "producer"
    CONSUMER = "consumer"


class SpanStatus(Enum):
    """Span execution status."""
    UNSET = "unset"
    OK = "ok"
    ERROR = "error"


@dataclass
class SpanEvent:
    """Event recorded during span execution."""
    name: str
    timestamp: float
    attributes: Dict[str, Any] = field(default_factory=dict)
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            "name": self.name,
            "timestamp": self.timestamp,
            "attributes": self.attributes,
        }


@dataclass
class SpanLink:
    """Link to another span (for batch processing, fan-out, etc.)."""
    trace_id: str
    span_id: str
    attributes: Dict[str, Any] = field(default_factory=dict)
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            "trace_id": self.trace_id,
            "span_id": self.span_id,
            "attributes": self.attributes,
        }


# =============================================================================
# Span
# =============================================================================

@dataclass
class Span:
    """
    Represents a unit of work in a distributed trace.
    
    Follows OpenTelemetry span semantics.
    """
    name: str
    trace_id: str
    span_id: str
    parent_span_id: Optional[str] = None
    kind: SpanKind = SpanKind.INTERNAL
    status: SpanStatus = SpanStatus.UNSET
    status_message: Optional[str] = None
    start_time: float = field(default_factory=time.time)
    end_time: Optional[float] = None
    attributes: Dict[str, Any] = field(default_factory=dict)
    events: List[SpanEvent] = field(default_factory=list)
    links: List[SpanLink] = field(default_factory=list)
    
    # Internal state
    _ended: bool = field(default=False, repr=False)
    _lock: threading.Lock = field(default_factory=threading.Lock, repr=False)
    
    def set_attribute(self, key: str, value: Any) -> "Span":
        """Set a span attribute."""
        with self._lock:
            self.attributes[key] = value
        return self
    
    def set_attributes(self, attributes: Dict[str, Any]) -> "Span":
        """Set multiple attributes."""
        with self._lock:
            self.attributes.update(attributes)
        return self
    
    def add_event(self, name: str, attributes: Optional[Dict[str, Any]] = None) -> "Span":
        """Add an event to the span."""
        event = SpanEvent(
            name=name,
            timestamp=time.time(),
            attributes=attributes or {},
        )
        with self._lock:
            self.events.append(event)
        return self
    
    def add_link(self, trace_id: str, span_id: str, attributes: Optional[Dict[str, Any]] = None) -> "Span":
        """Add a link to another span."""
        link = SpanLink(
            trace_id=trace_id,
            span_id=span_id,
            attributes=attributes or {},
        )
        with self._lock:
            self.links.append(link)
        return self
    
    def set_status(self, status: SpanStatus, message: Optional[str] = None) -> "Span":
        """Set span status."""
        with self._lock:
            self.status = status
            self.status_message = message
        return self
    
    def record_exception(self, exception: BaseException, attributes: Optional[Dict[str, Any]] = None) -> "Span":
        """Record an exception event."""
        exc_attributes = {
            "exception.type": type(exception).__name__,
            "exception.message": str(exception),
        }
        if attributes:
            exc_attributes.update(attributes)
        
        self.add_event("exception", exc_attributes)
        self.set_status(SpanStatus.ERROR, str(exception))
        return self
    
    def end(self, end_time: Optional[float] = None) -> None:
        """End the span."""
        with self._lock:
            if self._ended:
                return
            self.end_time = end_time or time.time()
            self._ended = True
    
    @property
    def duration_ms(self) -> float:
        """Get span duration in milliseconds."""
        end = self.end_time or time.time()
        return (end - self.start_time) * 1000
    
    @property
    def is_recording(self) -> bool:
        """Check if span is still recording."""
        return not self._ended
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for serialization."""
        return {
            "name": self.name,
            "trace_id": self.trace_id,
            "span_id": self.span_id,
            "parent_span_id": self.parent_span_id,
            "kind": self.kind.value,
            "status": self.status.value,
            "status_message": self.status_message,
            "start_time": self.start_time,
            "end_time": self.end_time,
            "duration_ms": self.duration_ms,
            "attributes": self.attributes,
            "events": [e.to_dict() for e in self.events],
            "links": [l.to_dict() for l in self.links],
        }


# =============================================================================
# Trace Context (W3C)
# =============================================================================

@dataclass
class TraceContext:
    """
    W3C Trace Context representation.
    
    Supports parsing and generating traceparent/tracestate headers.
    """
    trace_id: str
    span_id: str
    trace_flags: int = 1  # 1 = sampled
    trace_state: Dict[str, str] = field(default_factory=dict)
    
    VERSION = "00"
    
    @classmethod
    def generate(cls) -> "TraceContext":
        """Generate new trace context."""
        return cls(
            trace_id=uuid.uuid4().hex,
            span_id=uuid.uuid4().hex[:16],
        )
    
    @classmethod
    def from_traceparent(cls, traceparent: str) -> Optional["TraceContext"]:
        """Parse W3C traceparent header."""
        try:
            parts = traceparent.split("-")
            if len(parts) != 4:
                return None
            
            version, trace_id, span_id, flags = parts
            if version != cls.VERSION:
                return None
            
            return cls(
                trace_id=trace_id,
                span_id=span_id,
                trace_flags=int(flags, 16),
            )
        except (ValueError, IndexError):
            return None
    
    def to_traceparent(self) -> str:
        """Generate W3C traceparent header value."""
        return f"{self.VERSION}-{self.trace_id}-{self.span_id}-{self.trace_flags:02x}"
    
    @classmethod
    def from_tracestate(cls, tracestate: str) -> Dict[str, str]:
        """Parse W3C tracestate header."""
        state = {}
        if not tracestate:
            return state
        
        for item in tracestate.split(","):
            item = item.strip()
            if "=" in item:
                key, value = item.split("=", 1)
                state[key.strip()] = value.strip()
        
        return state
    
    def to_tracestate(self) -> str:
        """Generate W3C tracestate header value."""
        return ",".join(f"{k}={v}" for k, v in self.trace_state.items())
    
    @property
    def is_sampled(self) -> bool:
        """Check if trace is sampled."""
        return bool(self.trace_flags & 0x01)
    
    def with_new_span_id(self) -> "TraceContext":
        """Create child context with new span ID."""
        return TraceContext(
            trace_id=self.trace_id,
            span_id=uuid.uuid4().hex[:16],
            trace_flags=self.trace_flags,
            trace_state=dict(self.trace_state),
        )


# =============================================================================
# Current Context (Thread-Local)
# =============================================================================

class _ContextStorage:
    """Thread-local storage for current span."""
    
    _local = threading.local()
    
    @classmethod
    def get_current_span(cls) -> Optional[Span]:
        """Get current active span."""
        stack = getattr(cls._local, "span_stack", [])
        return stack[-1] if stack else None
    
    @classmethod
    def push_span(cls, span: Span) -> None:
        """Push span onto stack."""
        if not hasattr(cls._local, "span_stack"):
            cls._local.span_stack = []
        cls._local.span_stack.append(span)
    
    @classmethod
    def pop_span(cls) -> Optional[Span]:
        """Pop span from stack."""
        stack = getattr(cls._local, "span_stack", [])
        return stack.pop() if stack else None
    
    @classmethod
    def clear(cls) -> None:
        """Clear all spans."""
        cls._local.span_stack = []
    
    @classmethod
    def get_trace_context(cls) -> Optional[TraceContext]:
        """Get current trace context."""
        return getattr(cls._local, "trace_context", None)
    
    @classmethod
    def set_trace_context(cls, ctx: TraceContext) -> None:
        """Set current trace context."""
        cls._local.trace_context = ctx


# =============================================================================
# Span Exporter
# =============================================================================

class SpanExporter:
    """Base class for span exporters."""
    
    def export(self, spans: List[Span]) -> None:
        """Export spans."""
        raise NotImplementedError
    
    def shutdown(self) -> None:
        """Shutdown exporter."""
        pass


class MemoryExporter(SpanExporter):
    """Exporter that stores spans in memory (for testing)."""
    
    def __init__(self, max_spans: int = 1000):
        self.max_spans = max_spans
        self.spans: List[Span] = []
        self._lock = threading.Lock()
    
    def export(self, spans: List[Span]) -> None:
        """Store spans in memory."""
        with self._lock:
            self.spans.extend(spans)
            if len(self.spans) > self.max_spans:
                self.spans = self.spans[-self.max_spans:]
    
    def get_spans(self, trace_id: Optional[str] = None) -> List[Span]:
        """Get stored spans."""
        with self._lock:
            if trace_id:
                return [s for s in self.spans if s.trace_id == trace_id]
            return list(self.spans)
    
    def clear(self) -> None:
        """Clear stored spans."""
        with self._lock:
            self.spans.clear()


class ConsoleExporter(SpanExporter):
    """Exporter that prints spans to console."""
    
    def __init__(self, pretty: bool = False):
        self.pretty = pretty
    
    def export(self, spans: List[Span]) -> None:
        """Print spans to console."""
        for span in spans:
            data = span.to_dict()
            if self.pretty:
                print(json.dumps(data, indent=2))
            else:
                print(json.dumps(data))


class JSONFileExporter(SpanExporter):
    """Exporter that writes spans to a JSON file."""
    
    def __init__(self, filename: str):
        self.filename = filename
        self._lock = threading.Lock()
    
    def export(self, spans: List[Span]) -> None:
        """Append spans to file."""
        with self._lock:
            with open(self.filename, "a") as f:
                for span in spans:
                    f.write(json.dumps(span.to_dict()) + "\n")


# =============================================================================
# Tracer
# =============================================================================

class Tracer:
    """
    Creates and manages spans.
    
    Thread-safe tracer for creating distributed traces.
    """
    
    def __init__(
        self,
        service_name: str,
        exporters: Optional[List[SpanExporter]] = None,
        sample_rate: float = 1.0,
    ):
        self.service_name = service_name
        self.exporters = exporters or []
        self.sample_rate = sample_rate
        self._lock = threading.Lock()
        self._pending_spans: List[Span] = []
    
    def _should_sample(self) -> bool:
        """Determine if trace should be sampled."""
        import random
        return random.random() < self.sample_rate
    
    def _generate_ids(self) -> tuple:
        """Generate trace and span IDs."""
        trace_id = uuid.uuid4().hex
        span_id = uuid.uuid4().hex[:16]
        return trace_id, span_id
    
    def start_span(
        self,
        name: str,
        kind: SpanKind = SpanKind.INTERNAL,
        attributes: Optional[Dict[str, Any]] = None,
        parent: Optional[Span] = None,
        context: Optional[TraceContext] = None,
    ) -> Span:
        """
        Start a new span.
        
        Args:
            name: Span name
            kind: Span kind (internal, server, client, etc.)
            attributes: Initial attributes
            parent: Parent span (auto-detected if not provided)
            context: Trace context (for propagation)
        """
        # Determine parent span and trace context
        if parent is None:
            parent = _ContextStorage.get_current_span()
        
        if context:
            trace_id = context.trace_id
            parent_span_id = context.span_id
        elif parent:
            trace_id = parent.trace_id
            parent_span_id = parent.span_id
        else:
            trace_id, _ = self._generate_ids()
            parent_span_id = None
        
        span_id = uuid.uuid4().hex[:16]
        
        # Create span
        span = Span(
            name=name,
            trace_id=trace_id,
            span_id=span_id,
            parent_span_id=parent_span_id,
            kind=kind,
            attributes=attributes or {},
        )
        
        # Add service name attribute
        span.set_attribute("service.name", self.service_name)
        
        # Push to context
        _ContextStorage.push_span(span)
        
        return span
    
    def end_span(self, span: Span) -> None:
        """End a span and queue for export."""
        span.end()
        _ContextStorage.pop_span()
        
        with self._lock:
            self._pending_spans.append(span)
        
        # Batch export
        if len(self._pending_spans) >= 10:
            self.flush()
    
    def flush(self) -> None:
        """Export pending spans."""
        with self._lock:
            spans = list(self._pending_spans)
            self._pending_spans.clear()
        
        if spans:
            for exporter in self.exporters:
                try:
                    exporter.export(spans)
                except Exception:
                    pass  # Silently ignore export errors
    
    @contextmanager
    def span(
        self,
        name: str,
        kind: SpanKind = SpanKind.INTERNAL,
        attributes: Optional[Dict[str, Any]] = None,
    ):
        """Context manager for creating spans."""
        span = self.start_span(name, kind=kind, attributes=attributes)
        try:
            yield span
            if span.status == SpanStatus.UNSET:
                span.set_status(SpanStatus.OK)
        except Exception as e:
            span.record_exception(e)
            raise
        finally:
            self.end_span(span)
    
    def trace(
        self,
        name: Optional[str] = None,
        kind: SpanKind = SpanKind.INTERNAL,
        attributes: Optional[Dict[str, Any]] = None,
    ):
        """Decorator for tracing functions."""
        def decorator(func: Callable) -> Callable:
            span_name = name or func.__name__
            
            @wraps(func)
            def wrapper(*args, **kwargs):
                with self.span(span_name, kind=kind, attributes=attributes) as span:
                    span.set_attribute("code.function", func.__name__)
                    span.set_attribute("code.filepath", func.__code__.co_filename)
                    return func(*args, **kwargs)
            
            @wraps(func)
            async def async_wrapper(*args, **kwargs):
                with self.span(span_name, kind=kind, attributes=attributes) as span:
                    span.set_attribute("code.function", func.__name__)
                    return await func(*args, **kwargs)
            
            if hasattr(func, "__wrapped__") or str(func).startswith("<coroutine"):
                return async_wrapper
            return wrapper
        
        return decorator
    
    def shutdown(self) -> None:
        """Shutdown tracer and exporters."""
        self.flush()
        for exporter in self.exporters:
            exporter.shutdown()


# =============================================================================
# Global Tracer
# =============================================================================

_global_tracer: Optional[Tracer] = None
_tracer_lock = threading.Lock()


def get_tracer(service_name: Optional[str] = None) -> Tracer:
    """Get or create the global tracer."""
    global _global_tracer
    
    with _tracer_lock:
        if _global_tracer is None:
            _global_tracer = Tracer(
                service_name=service_name or "default",
                exporters=[MemoryExporter()],
            )
        return _global_tracer


def set_tracer(tracer: Tracer) -> None:
    """Set the global tracer."""
    global _global_tracer
    with _tracer_lock:
        _global_tracer = tracer


def reset_tracer() -> None:
    """Reset the global tracer."""
    global _global_tracer
    with _tracer_lock:
        if _global_tracer:
            _global_tracer.shutdown()
        _global_tracer = None


def configure_tracing(
    service_name: str,
    exporters: Optional[List[SpanExporter]] = None,
    sample_rate: float = 1.0,
) -> Tracer:
    """Configure global tracer."""
    tracer = Tracer(
        service_name=service_name,
        exporters=exporters or [MemoryExporter()],
        sample_rate=sample_rate,
    )
    set_tracer(tracer)
    return tracer


# =============================================================================
# Convenience Functions
# =============================================================================

def get_current_span() -> Optional[Span]:
    """Get the current active span."""
    return _ContextStorage.get_current_span()


def get_current_trace_id() -> Optional[str]:
    """Get current trace ID."""
    span = get_current_span()
    return span.trace_id if span else None


def get_current_span_id() -> Optional[str]:
    """Get current span ID."""
    span = get_current_span()
    return span.span_id if span else None


@contextmanager
def span(
    name: str,
    kind: SpanKind = SpanKind.INTERNAL,
    attributes: Optional[Dict[str, Any]] = None,
):
    """Create a span using the global tracer."""
    tracer = get_tracer()
    with tracer.span(name, kind=kind, attributes=attributes) as s:
        yield s


def trace(
    name: Optional[str] = None,
    kind: SpanKind = SpanKind.INTERNAL,
    attributes: Optional[Dict[str, Any]] = None,
):
    """Decorator using the global tracer."""
    return get_tracer().trace(name=name, kind=kind, attributes=attributes)


# =============================================================================
# HTTP Propagation Helpers
# =============================================================================

def extract_context(headers: Dict[str, str]) -> Optional[TraceContext]:
    """Extract trace context from HTTP headers."""
    traceparent = headers.get("traceparent") or headers.get("Traceparent")
    if not traceparent:
        return None
    
    ctx = TraceContext.from_traceparent(traceparent)
    if ctx:
        tracestate = headers.get("tracestate") or headers.get("Tracestate")
        if tracestate:
            ctx.trace_state = TraceContext.from_tracestate(tracestate)
    
    return ctx


def inject_context(headers: Dict[str, str], span: Optional[Span] = None) -> Dict[str, str]:
    """Inject trace context into HTTP headers."""
    if span is None:
        span = get_current_span()
    
    if span:
        ctx = TraceContext(
            trace_id=span.trace_id,
            span_id=span.span_id,
        )
        headers["traceparent"] = ctx.to_traceparent()
        if ctx.trace_state:
            headers["tracestate"] = ctx.to_tracestate()
    
    return headers


def propagate_context_middleware(handler):
    """Middleware for HTTP context propagation."""
    @wraps(handler)
    async def wrapper(request, *args, **kwargs):
        # Extract context from incoming request
        ctx = extract_context(dict(request.headers))
        
        tracer = get_tracer()
        with tracer.span(
            f"{request.method} {request.path}",
            kind=SpanKind.SERVER,
            attributes={
                "http.method": request.method,
                "http.url": str(request.url),
            },
        ) as span:
            if ctx:
                # Link to parent trace
                span.add_link(ctx.trace_id, ctx.span_id)
            
            response = await handler(request, *args, **kwargs)
            span.set_attribute("http.status_code", response.status_code)
            return response
    
    return wrapper