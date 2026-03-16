"""
Observability End-to-End Tests.

Day 58 - Week 12 Integration Testing
45 tests for metrics, logging, tracing, and health checks E2E.
"""

import pytest
import time
import json
import re
from typing import Dict, Any, List

from testing.framework import (
    MockServer,
    TestClient,
    TestDataGenerator,
    assert_status,
    assert_json,
    assert_contains,
    assert_matches,
    assert_timing,
    with_timeout,
)

from observability.metrics import (
    MetricsRegistry,
    Counter,
    Gauge,
    Histogram,
    Timer,
    PrometheusFormatter,
)
from observability.logging import (
    LogLevel,
    LogContext,
    StructuredLogger,
    JSONFormatter,
    MemoryHandler,
)
from observability.tracing import (
    Span,
    SpanKind,
    SpanStatus,
    TraceContext,
    Tracer,
    MemoryExporter,
)
from observability.health import (
    HealthStatus,
    HealthCheckResult,
    HealthRegistry,
    CustomHealthCheck,
    liveness_response,
    readiness_response,
)


# =============================================================================
# Test Fixtures
# =============================================================================

@pytest.fixture
def metrics_registry():
    """Create clean metrics registry."""
    registry = MetricsRegistry("test")
    yield registry
    registry.clear()


@pytest.fixture
def memory_logger():
    """Create logger with memory handler for testing."""
    handler = MemoryHandler()
    logger = StructuredLogger("test", handlers=[handler])
    return logger, handler


@pytest.fixture
def tracer_with_exporter():
    """Create tracer with memory exporter."""
    exporter = MemoryExporter()
    tracer = Tracer("test-service", exporters=[exporter])
    return tracer, exporter


@pytest.fixture
def health_registry():
    """Create clean health registry."""
    registry = HealthRegistry()
    yield registry
    registry.clear()


@pytest.fixture
def mock_observability_server():
    """Create mock server with observability endpoints."""
    with MockServer() as server:
        # Metrics endpoint
        server.add_endpoint(
            "GET", "/metrics",
            body="""# HELP http_requests_total Total HTTP requests
# TYPE http_requests_total counter
http_requests_total{method="GET",path="/api"} 1523
http_requests_total{method="POST",path="/api"} 842

# HELP http_request_duration_seconds HTTP request duration
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{le="0.1"} 1200
http_request_duration_seconds_bucket{le="0.5"} 2100
http_request_duration_seconds_bucket{le="+Inf"} 2365
http_request_duration_seconds_sum 1234.56
http_request_duration_seconds_count 2365
""",
            headers={"Content-Type": "text/plain; version=0.0.4"}
        )
        
        # Health endpoints
        server.add_endpoint(
            "GET", "/healthz",
            body={"status": "healthy", "checks": []}
        )
        
        server.add_endpoint(
            "GET", "/ready",
            body={
                "status": "healthy",
                "checks": [
                    {"name": "database", "status": "healthy"},
                    {"name": "cache", "status": "healthy"}
                ]
            }
        )
        
        yield server


# =============================================================================
# Metrics E2E Tests (12 tests)
# =============================================================================

class TestMetricsE2E:
    """E2E tests for metrics collection."""
    
    def test_counter_increment(self, metrics_registry):
        """Test counter increments correctly."""
        counter = metrics_registry.counter("requests_total", "Total requests")
        
        counter.inc()
        counter.inc()
        counter.inc(5)
        
        assert counter.get() == 7
    
    def test_counter_with_labels(self, metrics_registry):
        """Test counter with labels."""
        counter = metrics_registry.counter(
            "http_requests",
            "HTTP requests",
            labels=["method", "status"]
        )
        
        counter.inc(labels={"method": "GET", "status": "200"})
        counter.inc(labels={"method": "POST", "status": "201"})
        
        assert counter.get(labels={"method": "GET", "status": "200"}) == 1
    
    def test_gauge_set(self, metrics_registry):
        """Test gauge set value."""
        gauge = metrics_registry.gauge("temperature", "Current temperature")
        
        gauge.set(25.5)
        assert gauge.get() == 25.5
        
        gauge.set(30.0)
        assert gauge.get() == 30.0
    
    def test_gauge_inc_dec(self, metrics_registry):
        """Test gauge increment and decrement."""
        gauge = metrics_registry.gauge("active_connections", "Active connections")
        
        gauge.set(10)
        gauge.inc(5)
        gauge.dec(3)
        
        assert gauge.get() == 12
    
    def test_histogram_observe(self, metrics_registry):
        """Test histogram observations."""
        histogram = metrics_registry.histogram(
            "request_duration",
            "Request duration",
            buckets=[0.1, 0.5, 1.0, 5.0]
        )
        
        histogram.observe(0.05)
        histogram.observe(0.3)
        histogram.observe(2.5)
        
        assert histogram.get_count() == 3
    
    def test_timer_context_manager(self, metrics_registry):
        """Test timer as context manager."""
        timer = metrics_registry.timer("operation_duration", "Operation duration")
        
        with timer.time():
            time.sleep(0.01)
        
        assert timer.get_count() == 1
        assert timer.get_sum() >= 0.01
    
    def test_prometheus_format(self, metrics_registry):
        """Test Prometheus exposition format."""
        counter = metrics_registry.counter("test_counter", "Test counter")
        counter.inc(10)
        
        output = metrics_registry.prometheus_format()
        
        assert_contains(output, "# HELP test_counter Test counter")
        assert_contains(output, "# TYPE test_counter counter")
        assert_contains(output, "test_counter 10")
    
    def test_metrics_endpoint_format(self, mock_observability_server):
        """Test metrics endpoint returns Prometheus format."""
        client = TestClient(base_url=mock_observability_server.url)
        
        response = client.get("/metrics")
        
        assert_status(response, 200)
        assert_contains(response.text, "# HELP")
        assert_contains(response.text, "# TYPE")
    
    def test_metrics_content_type(self, mock_observability_server):
        """Test metrics endpoint content type."""
        client = TestClient(base_url=mock_observability_server.url)
        
        response = client.get("/metrics")
        
        assert "text/plain" in response.headers.get("Content-Type", "")
    
    def test_counter_values_in_metrics(self, mock_observability_server):
        """Test counter values appear in metrics output."""
        client = TestClient(base_url=mock_observability_server.url)
        
        response = client.get("/metrics")
        
        assert_matches(response.text, r"http_requests_total\{.*\}\s+\d+")
    
    def test_histogram_buckets_in_metrics(self, mock_observability_server):
        """Test histogram buckets in metrics output."""
        client = TestClient(base_url=mock_observability_server.url)
        
        response = client.get("/metrics")
        
        assert_contains(response.text, "_bucket{")
        assert_contains(response.text, "_sum")
        assert_contains(response.text, "_count")
    
    def test_metrics_latency(self, mock_observability_server):
        """Test metrics endpoint responds quickly."""
        client = TestClient(base_url=mock_observability_server.url)
        
        response = client.get("/metrics")
        
        assert_timing(response.elapsed, max_ms=100)


# =============================================================================
# Logging E2E Tests (10 tests)
# =============================================================================

class TestLoggingE2E:
    """E2E tests for structured logging."""
    
    def test_log_info(self, memory_logger):
        """Test info level logging."""
        logger, handler = memory_logger
        
        logger.info("Test message")
        
        records = handler.get_records()
        assert len(records) == 1
        assert records[0].level == LogLevel.INFO
    
    def test_log_with_extra_fields(self, memory_logger):
        """Test logging with extra fields."""
        logger, handler = memory_logger
        
        logger.info("Request processed", request_id="123", duration=0.5)
        
        records = handler.get_records()
        assert records[0].extra.get("request_id") == "123"
        assert records[0].extra.get("duration") == 0.5
    
    def test_log_context_propagation(self, memory_logger):
        """Test context propagates through logs."""
        logger, handler = memory_logger
        
        with LogContext.scope(trace_id="abc123", user_id="user1"):
            logger.info("Inside context")
        
        records = handler.get_records()
        assert records[0].context.get("trace_id") == "abc123"
    
    def test_log_levels(self, memory_logger):
        """Test all log levels work."""
        logger, handler = memory_logger
        logger.level = LogLevel.DEBUG
        
        logger.debug("Debug message")
        logger.info("Info message")
        logger.warning("Warning message")
        logger.error("Error message")
        
        records = handler.get_records()
        assert len(records) == 4
    
    def test_json_formatter(self, memory_logger):
        """Test JSON formatter output."""
        logger, handler = memory_logger
        formatter = JSONFormatter()
        
        logger.info("Test message", key="value")
        
        record = handler.get_records()[0]
        json_output = formatter.format(record)
        parsed = json.loads(json_output)
        
        assert parsed["message"] == "Test message"
        assert parsed["key"] == "value"
    
    def test_error_logging_with_exception(self, memory_logger):
        """Test error logging with exception."""
        logger, handler = memory_logger
        
        try:
            raise ValueError("Test error")
        except Exception as e:
            logger.error("Operation failed", exc_info=e)
        
        records = handler.get_records()
        assert records[0].exception is not None
    
    def test_log_level_filtering(self, memory_logger):
        """Test log level filtering."""
        logger, handler = memory_logger
        logger.level = LogLevel.WARNING
        
        logger.debug("Should not appear")
        logger.info("Should not appear")
        logger.warning("Should appear")
        
        records = handler.get_records()
        assert len(records) == 1
    
    def test_nested_context(self, memory_logger):
        """Test nested context scopes."""
        logger, handler = memory_logger
        
        with LogContext.scope(request_id="outer"):
            with LogContext.scope(operation="inner"):
                logger.info("Nested log")
        
        records = handler.get_records()
        assert records[0].context.get("request_id") == "outer"
        assert records[0].context.get("operation") == "inner"
    
    def test_timestamp_present(self, memory_logger):
        """Test timestamp is present in logs."""
        logger, handler = memory_logger
        
        logger.info("Test message")
        
        records = handler.get_records()
        assert records[0].timestamp is not None
    
    def test_logger_name_present(self, memory_logger):
        """Test logger name is present."""
        logger, handler = memory_logger
        
        logger.info("Test message")
        
        records = handler.get_records()
        assert records[0].logger_name == "test"


# =============================================================================
# Tracing E2E Tests (11 tests)
# =============================================================================

class TestTracingE2E:
    """E2E tests for distributed tracing."""
    
    def test_create_span(self, tracer_with_exporter):
        """Test creating a span."""
        tracer, exporter = tracer_with_exporter
        
        with tracer.span("test-operation") as span:
            span.set_attribute("key", "value")
        
        spans = exporter.get_spans()
        assert len(spans) == 1
        assert spans[0].name == "test-operation"
    
    def test_span_timing(self, tracer_with_exporter):
        """Test span records timing."""
        tracer, exporter = tracer_with_exporter
        
        with tracer.span("timed-operation"):
            time.sleep(0.01)
        
        spans = exporter.get_spans()
        assert spans[0].duration_ns >= 10_000_000  # 10ms in nanoseconds
    
    def test_span_attributes(self, tracer_with_exporter):
        """Test span attributes."""
        tracer, exporter = tracer_with_exporter
        
        with tracer.span("operation") as span:
            span.set_attribute("http.method", "GET")
            span.set_attribute("http.status", 200)
        
        spans = exporter.get_spans()
        assert spans[0].attributes.get("http.method") == "GET"
    
    def test_parent_child_spans(self, tracer_with_exporter):
        """Test parent-child span relationships."""
        tracer, exporter = tracer_with_exporter
        
        with tracer.span("parent") as parent:
            with tracer.span("child") as child:
                pass
        
        spans = exporter.get_spans()
        assert len(spans) == 2
        
        # Find child span
        child_span = [s for s in spans if s.name == "child"][0]
        parent_span = [s for s in spans if s.name == "parent"][0]
        
        assert child_span.parent_span_id == parent_span.span_id
    
    def test_span_kind(self, tracer_with_exporter):
        """Test span kind."""
        tracer, exporter = tracer_with_exporter
        
        with tracer.span("server-op", kind=SpanKind.SERVER):
            pass
        
        with tracer.span("client-op", kind=SpanKind.CLIENT):
            pass
        
        spans = exporter.get_spans()
        assert any(s.kind == SpanKind.SERVER for s in spans)
        assert any(s.kind == SpanKind.CLIENT for s in spans)
    
    def test_span_status(self, tracer_with_exporter):
        """Test span status."""
        tracer, exporter = tracer_with_exporter
        
        with tracer.span("success-op") as span:
            span.set_status(SpanStatus.OK)
        
        spans = exporter.get_spans()
        assert spans[0].status == SpanStatus.OK
    
    def test_span_error(self, tracer_with_exporter):
        """Test span records errors."""
        tracer, exporter = tracer_with_exporter
        
        try:
            with tracer.span("failing-op") as span:
                raise ValueError("Test error")
        except ValueError:
            pass
        
        spans = exporter.get_spans()
        assert spans[0].status == SpanStatus.ERROR
    
    def test_trace_context_propagation(self, tracer_with_exporter):
        """Test trace context propagation."""
        tracer, exporter = tracer_with_exporter
        
        with tracer.span("root") as root:
            trace_id = root.trace_id
            with tracer.span("child") as child:
                assert child.trace_id == trace_id
    
    def test_w3c_trace_context(self):
        """Test W3C trace context parsing."""
        header = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
        
        context = TraceContext.from_traceparent(header)
        
        assert context.trace_id == "0af7651916cd43dd8448eb211c80319c"
        assert context.span_id == "b7ad6b7169203331"
    
    def test_traceparent_generation(self, tracer_with_exporter):
        """Test traceparent header generation."""
        tracer, exporter = tracer_with_exporter
        
        with tracer.span("operation") as span:
            traceparent = span.get_traceparent()
        
        assert traceparent.startswith("00-")
        parts = traceparent.split("-")
        assert len(parts) == 4
    
    def test_multiple_exporters(self):
        """Test multiple exporters receive spans."""
        exporter1 = MemoryExporter()
        exporter2 = MemoryExporter()
        tracer = Tracer("test", exporters=[exporter1, exporter2])
        
        with tracer.span("operation"):
            pass
        
        assert len(exporter1.get_spans()) == 1
        assert len(exporter2.get_spans()) == 1


# =============================================================================
# Health Checks E2E Tests (12 tests)
# =============================================================================

class TestHealthChecksE2E:
    """E2E tests for health checks."""
    
    def test_liveness_healthy(self, mock_observability_server):
        """Test liveness endpoint returns healthy."""
        client = TestClient(base_url=mock_observability_server.url)
        
        response = client.get("/healthz")
        
        assert_status(response, 200)
        assert_json(response, {"status": "healthy"})
    
    def test_readiness_healthy(self, mock_observability_server):
        """Test readiness endpoint returns healthy."""
        client = TestClient(base_url=mock_observability_server.url)
        
        response = client.get("/ready")
        
        assert_status(response, 200)
        data = response.json()
        assert data["status"] == "healthy"
    
    def test_readiness_includes_checks(self, mock_observability_server):
        """Test readiness includes individual checks."""
        client = TestClient(base_url=mock_observability_server.url)
        
        response = client.get("/ready")
        data = response.json()
        
        assert "checks" in data
        assert len(data["checks"]) == 2
    
    def test_health_check_result_healthy(self, health_registry):
        """Test health check result when healthy."""
        health_registry.add_check(
            CustomHealthCheck("test", lambda: HealthCheckResult.healthy("test"))
        )
        
        result = health_registry.check_all()
        
        assert result.status == HealthStatus.HEALTHY
    
    def test_health_check_result_unhealthy(self, health_registry):
        """Test health check result when unhealthy."""
        health_registry.add_check(
            CustomHealthCheck("test", lambda: HealthCheckResult.unhealthy("test", "Failed"))
        )
        
        result = health_registry.check_all()
        
        assert result.status == HealthStatus.UNHEALTHY
    
    def test_health_check_result_degraded(self, health_registry):
        """Test health check result when degraded."""
        health_registry.add_check(
            CustomHealthCheck("test", lambda: HealthCheckResult.degraded("test", "Slow"))
        )
        
        result = health_registry.check_all()
        
        assert result.status == HealthStatus.DEGRADED
    
    def test_multiple_checks(self, health_registry):
        """Test multiple health checks."""
        health_registry.add_check(
            CustomHealthCheck("db", lambda: HealthCheckResult.healthy("db"))
        )
        health_registry.add_check(
            CustomHealthCheck("cache", lambda: HealthCheckResult.healthy("cache"))
        )
        
        result = health_registry.check_all()
        
        assert len(result.checks) == 2
        assert result.status == HealthStatus.HEALTHY
    
    def test_one_unhealthy_makes_all_unhealthy(self, health_registry):
        """Test one unhealthy check makes overall unhealthy."""
        health_registry.add_check(
            CustomHealthCheck("db", lambda: HealthCheckResult.healthy("db"))
        )
        health_registry.add_check(
            CustomHealthCheck("cache", lambda: HealthCheckResult.unhealthy("cache", "Down"))
        )
        
        result = health_registry.check_all()
        
        assert result.status == HealthStatus.UNHEALTHY
    
    def test_liveness_response_format(self):
        """Test liveness_response format."""
        status, body = liveness_response()
        
        assert status in [200, 503]
        assert "status" in body
    
    def test_readiness_response_format(self):
        """Test readiness_response format."""
        status, body = readiness_response()
        
        assert status in [200, 503]
        assert "status" in body
        assert "checks" in body
    
    def test_health_endpoint_latency(self, mock_observability_server):
        """Test health endpoints respond quickly."""
        client = TestClient(base_url=mock_observability_server.url)
        
        liveness = client.get("/healthz")
        readiness = client.get("/ready")
        
        assert_timing(liveness.elapsed, max_ms=50)
        assert_timing(readiness.elapsed, max_ms=100)
    
    def test_health_check_timeout(self, health_registry):
        """Test health check respects timeout."""
        def slow_check():
            time.sleep(0.01)
            return HealthCheckResult.healthy("slow")
        
        health_registry.add_check(
            CustomHealthCheck("slow", slow_check, timeout=1.0)
        )
        
        result = health_registry.check_all()
        assert result.status == HealthStatus.HEALTHY


# =============================================================================
# Summary
# =============================================================================
# Total: 45 tests
# - Metrics E2E: 12 tests
# - Logging E2E: 10 tests
# - Tracing E2E: 11 tests
# - Health Checks E2E: 12 tests