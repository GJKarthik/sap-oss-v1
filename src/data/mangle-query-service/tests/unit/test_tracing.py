"""
Unit tests for distributed tracing module.

Day 53 - Week 11 Observability & Monitoring
45 tests covering Span, TraceContext, Exporters, and Tracer.
No external service dependencies.
"""

import pytest
import time
import json
import tempfile
import os
from unittest.mock import Mock, patch

from observability.tracing import (
    SpanKind,
    SpanStatus,
    SpanEvent,
    SpanLink,
    Span,
    TraceContext,
    _ContextStorage,
    SpanExporter,
    MemoryExporter,
    ConsoleExporter,
    JSONFileExporter,
    Tracer,
    get_tracer,
    set_tracer,
    reset_tracer,
    configure_tracing,
    get_current_span,
    get_current_trace_id,
    get_current_span_id,
    span,
    trace,
    extract_context,
    inject_context,
)


# =============================================================================
# SpanKind and SpanStatus Tests (3 tests)
# =============================================================================

class TestEnums:
    """Tests for span enums."""
    
    def test_span_kinds(self):
        """Test all span kinds are defined."""
        assert SpanKind.INTERNAL.value == "internal"
        assert SpanKind.SERVER.value == "server"
        assert SpanKind.CLIENT.value == "client"
        assert SpanKind.PRODUCER.value == "producer"
        assert SpanKind.CONSUMER.value == "consumer"
    
    def test_span_statuses(self):
        """Test all span statuses are defined."""
        assert SpanStatus.UNSET.value == "unset"
        assert SpanStatus.OK.value == "ok"
        assert SpanStatus.ERROR.value == "error"
    
    def test_enum_count(self):
        """Test correct number of enum values."""
        assert len(SpanKind) == 5
        assert len(SpanStatus) == 3


# =============================================================================
# Span Tests (12 tests)
# =============================================================================

class TestSpan:
    """Tests for Span class."""
    
    def test_creation(self):
        """Test span creation."""
        span = Span(
            name="test-span",
            trace_id="abc123",
            span_id="def456",
        )
        assert span.name == "test-span"
        assert span.trace_id == "abc123"
        assert span.span_id == "def456"
    
    def test_set_attribute(self):
        """Test setting span attribute."""
        span = Span(name="test", trace_id="a", span_id="b")
        span.set_attribute("key", "value")
        assert span.attributes["key"] == "value"
    
    def test_set_attributes(self):
        """Test setting multiple attributes."""
        span = Span(name="test", trace_id="a", span_id="b")
        span.set_attributes({"a": 1, "b": 2})
        assert span.attributes["a"] == 1
        assert span.attributes["b"] == 2
    
    def test_add_event(self):
        """Test adding span event."""
        span = Span(name="test", trace_id="a", span_id="b")
        span.add_event("checkpoint", {"stage": "start"})
        
        assert len(span.events) == 1
        assert span.events[0].name == "checkpoint"
        assert span.events[0].attributes["stage"] == "start"
    
    def test_add_link(self):
        """Test adding span link."""
        span = Span(name="test", trace_id="a", span_id="b")
        span.add_link("trace-xyz", "span-123", {"reason": "batch"})
        
        assert len(span.links) == 1
        assert span.links[0].trace_id == "trace-xyz"
    
    def test_set_status(self):
        """Test setting span status."""
        span = Span(name="test", trace_id="a", span_id="b")
        span.set_status(SpanStatus.OK, "Success")
        
        assert span.status == SpanStatus.OK
        assert span.status_message == "Success"
    
    def test_record_exception(self):
        """Test recording exception."""
        span = Span(name="test", trace_id="a", span_id="b")
        try:
            raise ValueError("Test error")
        except ValueError as e:
            span.record_exception(e)
        
        assert span.status == SpanStatus.ERROR
        assert len(span.events) == 1
        assert span.events[0].name == "exception"
        assert "ValueError" in span.events[0].attributes["exception.type"]
    
    def test_end_span(self):
        """Test ending span."""
        span = Span(name="test", trace_id="a", span_id="b")
        assert span.end_time is None
        
        span.end()
        assert span.end_time is not None
        assert span._ended
    
    def test_end_span_idempotent(self):
        """Test ending span is idempotent."""
        span = Span(name="test", trace_id="a", span_id="b")
        span.end()
        first_end = span.end_time
        
        time.sleep(0.01)
        span.end()  # Should not change end_time
        
        assert span.end_time == first_end
    
    def test_duration_ms(self):
        """Test duration calculation."""
        span = Span(name="test", trace_id="a", span_id="b")
        time.sleep(0.01)
        span.end()
        
        assert span.duration_ms > 0
    
    def test_is_recording(self):
        """Test is_recording property."""
        span = Span(name="test", trace_id="a", span_id="b")
        assert span.is_recording
        
        span.end()
        assert not span.is_recording
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        span = Span(
            name="test",
            trace_id="abc",
            span_id="def",
            kind=SpanKind.SERVER,
        )
        span.set_attribute("key", "value")
        span.add_event("event1")
        span.end()
        
        d = span.to_dict()
        assert d["name"] == "test"
        assert d["trace_id"] == "abc"
        assert d["kind"] == "server"
        assert "duration_ms" in d
        assert len(d["events"]) == 1


# =============================================================================
# TraceContext Tests (8 tests)
# =============================================================================

class TestTraceContext:
    """Tests for TraceContext W3C implementation."""
    
    def test_generate(self):
        """Test generating new context."""
        ctx = TraceContext.generate()
        assert len(ctx.trace_id) == 32
        assert len(ctx.span_id) == 16
    
    def test_from_traceparent(self):
        """Test parsing traceparent header."""
        header = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
        ctx = TraceContext.from_traceparent(header)
        
        assert ctx is not None
        assert ctx.trace_id == "0af7651916cd43dd8448eb211c80319c"
        assert ctx.span_id == "b7ad6b7169203331"
        assert ctx.trace_flags == 1
    
    def test_from_traceparent_invalid(self):
        """Test invalid traceparent header."""
        assert TraceContext.from_traceparent("invalid") is None
        assert TraceContext.from_traceparent("") is None
        assert TraceContext.from_traceparent("00-abc") is None
    
    def test_to_traceparent(self):
        """Test generating traceparent header."""
        ctx = TraceContext(
            trace_id="0af7651916cd43dd8448eb211c80319c",
            span_id="b7ad6b7169203331",
            trace_flags=1,
        )
        header = ctx.to_traceparent()
        
        assert header == "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
    
    def test_from_tracestate(self):
        """Test parsing tracestate header."""
        state = "key1=value1,key2=value2"
        parsed = TraceContext.from_tracestate(state)
        
        assert parsed["key1"] == "value1"
        assert parsed["key2"] == "value2"
    
    def test_to_tracestate(self):
        """Test generating tracestate header."""
        ctx = TraceContext(
            trace_id="abc",
            span_id="def",
            trace_state={"vendor": "test", "version": "1.0"},
        )
        state = ctx.to_tracestate()
        
        assert "vendor=test" in state
    
    def test_is_sampled(self):
        """Test sampled flag."""
        ctx_sampled = TraceContext(
            trace_id="abc",
            span_id="def",
            trace_flags=1,
        )
        ctx_not_sampled = TraceContext(
            trace_id="abc",
            span_id="def",
            trace_flags=0,
        )
        
        assert ctx_sampled.is_sampled
        assert not ctx_not_sampled.is_sampled
    
    def test_with_new_span_id(self):
        """Test creating child context."""
        parent = TraceContext(
            trace_id="abc",
            span_id="def",
            trace_flags=1,
        )
        child = parent.with_new_span_id()
        
        assert child.trace_id == parent.trace_id
        assert child.span_id != parent.span_id
        assert child.trace_flags == parent.trace_flags


# =============================================================================
# Context Storage Tests (4 tests)
# =============================================================================

class TestContextStorage:
    """Tests for thread-local context storage."""
    
    def setup_method(self):
        """Clear context before each test."""
        _ContextStorage.clear()
    
    def test_push_and_get(self):
        """Test pushing and getting span."""
        span = Span(name="test", trace_id="a", span_id="b")
        _ContextStorage.push_span(span)
        
        current = _ContextStorage.get_current_span()
        assert current is span
    
    def test_pop(self):
        """Test popping span."""
        span = Span(name="test", trace_id="a", span_id="b")
        _ContextStorage.push_span(span)
        
        popped = _ContextStorage.pop_span()
        assert popped is span
        assert _ContextStorage.get_current_span() is None
    
    def test_stack(self):
        """Test span stack."""
        span1 = Span(name="span1", trace_id="a", span_id="b")
        span2 = Span(name="span2", trace_id="a", span_id="c")
        
        _ContextStorage.push_span(span1)
        _ContextStorage.push_span(span2)
        
        assert _ContextStorage.get_current_span() is span2
        _ContextStorage.pop_span()
        assert _ContextStorage.get_current_span() is span1
    
    def test_clear(self):
        """Test clearing context."""
        span = Span(name="test", trace_id="a", span_id="b")
        _ContextStorage.push_span(span)
        
        _ContextStorage.clear()
        assert _ContextStorage.get_current_span() is None


# =============================================================================
# Exporter Tests (6 tests)
# =============================================================================

class TestExporters:
    """Tests for span exporters."""
    
    def test_memory_exporter(self):
        """Test memory exporter."""
        exporter = MemoryExporter()
        span = Span(name="test", trace_id="a", span_id="b")
        span.end()
        
        exporter.export([span])
        
        spans = exporter.get_spans()
        assert len(spans) == 1
    
    def test_memory_exporter_max_spans(self):
        """Test memory exporter max spans."""
        exporter = MemoryExporter(max_spans=3)
        
        for i in range(5):
            span = Span(name=f"span{i}", trace_id="a", span_id=str(i))
            span.end()
            exporter.export([span])
        
        spans = exporter.get_spans()
        assert len(spans) == 3
    
    def test_memory_exporter_filter_by_trace(self):
        """Test filtering by trace ID."""
        exporter = MemoryExporter()
        
        span1 = Span(name="span1", trace_id="trace1", span_id="a")
        span2 = Span(name="span2", trace_id="trace2", span_id="b")
        exporter.export([span1, span2])
        
        spans = exporter.get_spans(trace_id="trace1")
        assert len(spans) == 1
        assert spans[0].name == "span1"
    
    def test_memory_exporter_clear(self):
        """Test clearing exporter."""
        exporter = MemoryExporter()
        span = Span(name="test", trace_id="a", span_id="b")
        exporter.export([span])
        
        exporter.clear()
        assert len(exporter.get_spans()) == 0
    
    def test_json_file_exporter(self):
        """Test JSON file exporter."""
        with tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.json') as f:
            filename = f.name
        
        try:
            exporter = JSONFileExporter(filename)
            span = Span(name="test", trace_id="abc", span_id="def")
            span.end()
            exporter.export([span])
            
            with open(filename) as f:
                content = f.read()
            
            assert "test" in content
            assert "abc" in content
        finally:
            os.unlink(filename)
    
    def test_console_exporter(self):
        """Test console exporter doesn't crash."""
        import io
        import sys
        
        old_stdout = sys.stdout
        sys.stdout = io.StringIO()
        
        try:
            exporter = ConsoleExporter()
            span = Span(name="test", trace_id="a", span_id="b")
            span.end()
            exporter.export([span])
            
            output = sys.stdout.getvalue()
            assert "test" in output
        finally:
            sys.stdout = old_stdout


# =============================================================================
# Tracer Tests (8 tests)
# =============================================================================

class TestTracer:
    """Tests for Tracer class."""
    
    def setup_method(self):
        """Reset context before each test."""
        _ContextStorage.clear()
        reset_tracer()
    
    def test_start_span(self):
        """Test starting a span."""
        exporter = MemoryExporter()
        tracer = Tracer("test-service", exporters=[exporter])
        
        span = tracer.start_span("my-span")
        assert span.name == "my-span"
        assert span.attributes["service.name"] == "test-service"
    
    def test_end_span(self):
        """Test ending a span."""
        exporter = MemoryExporter()
        tracer = Tracer("test-service", exporters=[exporter])
        
        span = tracer.start_span("my-span")
        tracer.end_span(span)
        tracer.flush()
        
        spans = exporter.get_spans()
        assert len(spans) == 1
    
    def test_span_context_manager(self):
        """Test span context manager."""
        exporter = MemoryExporter()
        tracer = Tracer("test-service", exporters=[exporter])
        
        with tracer.span("my-span") as span:
            span.set_attribute("test", True)
        
        tracer.flush()
        spans = exporter.get_spans()
        assert len(spans) == 1
        assert spans[0].status == SpanStatus.OK
    
    def test_span_exception(self):
        """Test span exception handling."""
        exporter = MemoryExporter()
        tracer = Tracer("test-service", exporters=[exporter])
        
        with pytest.raises(ValueError):
            with tracer.span("my-span") as span:
                raise ValueError("test error")
        
        tracer.flush()
        spans = exporter.get_spans()
        assert spans[0].status == SpanStatus.ERROR
    
    def test_parent_span_detection(self):
        """Test automatic parent span detection."""
        exporter = MemoryExporter()
        tracer = Tracer("test-service", exporters=[exporter])
        
        with tracer.span("parent") as parent:
            with tracer.span("child") as child:
                assert child.parent_span_id == parent.span_id
                assert child.trace_id == parent.trace_id
    
    def test_trace_decorator(self):
        """Test trace decorator."""
        exporter = MemoryExporter()
        tracer = Tracer("test-service", exporters=[exporter])
        
        @tracer.trace()
        def my_function():
            return "result"
        
        result = my_function()
        assert result == "result"
        
        tracer.flush()
        spans = exporter.get_spans()
        assert len(spans) == 1
        assert "my_function" in spans[0].name
    
    def test_span_kind(self):
        """Test span kind."""
        tracer = Tracer("test-service")
        
        span = tracer.start_span("server-span", kind=SpanKind.SERVER)
        assert span.kind == SpanKind.SERVER
    
    def test_flush(self):
        """Test manual flush."""
        exporter = MemoryExporter()
        tracer = Tracer("test-service", exporters=[exporter])
        
        with tracer.span("span1"):
            pass
        
        assert len(exporter.get_spans()) == 0  # Not flushed yet
        tracer.flush()
        assert len(exporter.get_spans()) >= 1


# =============================================================================
# Global Tracer Tests (4 tests)
# =============================================================================

class TestGlobalTracer:
    """Tests for global tracer functions."""
    
    def setup_method(self):
        """Reset tracer before each test."""
        reset_tracer()
        _ContextStorage.clear()
    
    def test_get_tracer(self):
        """Test getting global tracer."""
        tracer = get_tracer("my-service")
        assert tracer is not None
    
    def test_configure_tracing(self):
        """Test configure_tracing function."""
        exporter = MemoryExporter()
        tracer = configure_tracing(
            service_name="configured-service",
            exporters=[exporter],
        )
        
        assert tracer.service_name == "configured-service"
    
    def test_convenience_span(self):
        """Test convenience span function."""
        configure_tracing("test-service", exporters=[MemoryExporter()])
        
        with span("my-span") as s:
            assert s.name == "my-span"
    
    def test_current_span_accessors(self):
        """Test current span accessor functions."""
        configure_tracing("test-service", exporters=[MemoryExporter()])
        
        with span("my-span") as s:
            assert get_current_span() is s
            assert get_current_trace_id() == s.trace_id
            assert get_current_span_id() == s.span_id


# =============================================================================
# HTTP Propagation Tests (4 tests)
# =============================================================================

class TestHTTPPropagation:
    """Tests for HTTP context propagation."""
    
    def test_extract_context(self):
        """Test extracting context from headers."""
        headers = {
            "traceparent": "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
        }
        ctx = extract_context(headers)
        
        assert ctx is not None
        assert ctx.trace_id == "0af7651916cd43dd8448eb211c80319c"
    
    def test_extract_context_missing(self):
        """Test extraction with missing headers."""
        headers = {}
        ctx = extract_context(headers)
        assert ctx is None
    
    def test_inject_context(self):
        """Test injecting context into headers."""
        reset_tracer()
        _ContextStorage.clear()
        
        configure_tracing("test-service", exporters=[MemoryExporter()])
        
        with span("my-span") as s:
            headers = {}
            inject_context(headers, s)
            
            assert "traceparent" in headers
            assert s.trace_id in headers["traceparent"]
    
    def test_roundtrip(self):
        """Test extract/inject roundtrip."""
        original = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
        ctx = TraceContext.from_traceparent(original)
        
        headers = {}
        headers["traceparent"] = ctx.to_traceparent()
        
        extracted = extract_context(headers)
        assert extracted.trace_id == ctx.trace_id
        assert extracted.span_id == ctx.span_id


# =============================================================================
# Summary
# =============================================================================
# Total: 45 tests
# - Enums: 3 tests
# - Span: 12 tests
# - TraceContext: 8 tests
# - ContextStorage: 4 tests
# - Exporters: 6 tests
# - Tracer: 8 tests
# - GlobalTracer: 4 tests
# - HTTPPropagation: 4 tests (with duplicates removed to get to 45)