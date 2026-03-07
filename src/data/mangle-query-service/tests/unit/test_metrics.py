"""
Unit tests for metrics module.

Day 51 - Week 11 Observability & Monitoring
45 tests covering Counter, Gauge, Histogram, Timer, and Registry.
No external service dependencies.
"""

import pytest
import time
import json
from unittest.mock import Mock, patch

from observability.metrics import (
    MetricType,
    MetricValue,
    BaseMetric,
    Counter,
    Gauge,
    Histogram,
    Timer,
    MetricsRegistry,
    get_registry,
    set_registry,
    reset_registry,
    counter,
    gauge,
    histogram,
    timer,
)


# =============================================================================
# MetricType Tests (2 tests)
# =============================================================================

class TestMetricType:
    """Tests for MetricType enum."""
    
    def test_all_types_defined(self):
        """Test all metric types are defined."""
        types = list(MetricType)
        assert len(types) == 4
    
    def test_type_values(self):
        """Test metric type values."""
        assert MetricType.COUNTER.value == "counter"
        assert MetricType.GAUGE.value == "gauge"
        assert MetricType.HISTOGRAM.value == "histogram"
        assert MetricType.TIMER.value == "timer"


# =============================================================================
# MetricValue Tests (3 tests)
# =============================================================================

class TestMetricValue:
    """Tests for MetricValue dataclass."""
    
    def test_creation(self):
        """Test metric value creation."""
        mv = MetricValue(
            name="test_metric",
            value=42,
            metric_type=MetricType.COUNTER,
        )
        assert mv.name == "test_metric"
        assert mv.value == 42
    
    def test_with_labels(self):
        """Test metric value with labels."""
        mv = MetricValue(
            name="test_metric",
            value=100,
            metric_type=MetricType.GAUGE,
            labels={"env": "prod", "service": "api"},
        )
        assert mv.labels["env"] == "prod"
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        mv = MetricValue(
            name="test",
            value=1,
            metric_type=MetricType.COUNTER,
        )
        d = mv.to_dict()
        assert "name" in d
        assert "value" in d
        assert "type" in d


# =============================================================================
# Counter Tests (8 tests)
# =============================================================================

class TestCounter:
    """Tests for Counter metric."""
    
    def test_increment(self):
        """Test basic increment."""
        c = Counter("test_counter")
        c.inc()
        assert c.get() == 1
        c.inc()
        assert c.get() == 2
    
    def test_increment_by_value(self):
        """Test increment by specific value."""
        c = Counter("test_counter")
        c.inc(5)
        assert c.get() == 5
        c.inc(10)
        assert c.get() == 15
    
    def test_negative_increment_raises(self):
        """Test that negative increment raises error."""
        c = Counter("test_counter")
        with pytest.raises(ValueError):
            c.inc(-1)
    
    def test_with_labels(self):
        """Test counter with labels."""
        c = Counter("http_requests")
        c.inc(labels={"method": "GET"})
        c.inc(labels={"method": "POST"})
        c.inc(labels={"method": "GET"})
        
        assert c.get(labels={"method": "GET"}) == 2
        assert c.get(labels={"method": "POST"}) == 1
    
    def test_reset(self):
        """Test counter reset."""
        c = Counter("test_counter")
        c.inc(10)
        c.reset()
        assert c.get() == 0
    
    def test_get_all(self):
        """Test getting all values."""
        c = Counter("test_counter")
        c.inc(5, labels={"env": "dev"})
        c.inc(10, labels={"env": "prod"})
        
        values = c.get_all()
        assert len(values) == 2
    
    def test_default_labels(self):
        """Test default labels."""
        c = Counter("test_counter", labels={"service": "api"})
        c.inc()
        
        values = c.get_all()
        assert len(values) >= 1
    
    def test_thread_safety(self):
        """Test thread-safe increments."""
        import threading
        
        c = Counter("test_counter")
        threads = []
        
        def increment():
            for _ in range(100):
                c.inc()
        
        for _ in range(10):
            t = threading.Thread(target=increment)
            threads.append(t)
            t.start()
        
        for t in threads:
            t.join()
        
        assert c.get() == 1000


# =============================================================================
# Gauge Tests (8 tests)
# =============================================================================

class TestGauge:
    """Tests for Gauge metric."""
    
    def test_set(self):
        """Test setting gauge value."""
        g = Gauge("memory_usage")
        g.set(100.5)
        assert g.get() == 100.5
    
    def test_increment(self):
        """Test gauge increment."""
        g = Gauge("active_connections")
        g.set(10)
        g.inc(5)
        assert g.get() == 15
    
    def test_decrement(self):
        """Test gauge decrement."""
        g = Gauge("active_connections")
        g.set(10)
        g.dec(3)
        assert g.get() == 7
    
    def test_default_value(self):
        """Test default value is zero."""
        g = Gauge("test_gauge")
        assert g.get() == 0.0
    
    def test_with_labels(self):
        """Test gauge with labels."""
        g = Gauge("queue_size")
        g.set(100, labels={"queue": "high"})
        g.set(50, labels={"queue": "low"})
        
        assert g.get(labels={"queue": "high"}) == 100
        assert g.get(labels={"queue": "low"}) == 50
    
    def test_track_inprogress(self):
        """Test track_inprogress context manager."""
        g = Gauge("requests_in_progress")
        
        assert g.get() == 0
        
        with g.track_inprogress():
            assert g.get() == 1
        
        assert g.get() == 0
    
    def test_with_unit(self):
        """Test gauge with unit."""
        g = Gauge("memory", unit="bytes")
        g.set(1024)
        
        values = g.get_all()
        assert values[0].unit == "bytes"
    
    def test_get_all(self):
        """Test getting all gauge values."""
        g = Gauge("test_gauge")
        g.set(1, labels={"type": "a"})
        g.set(2, labels={"type": "b"})
        
        values = g.get_all()
        assert len(values) == 2


# =============================================================================
# Histogram Tests (10 tests)
# =============================================================================

class TestHistogram:
    """Tests for Histogram metric."""
    
    def test_observe(self):
        """Test recording observations."""
        h = Histogram("request_latency")
        h.observe(0.1)
        h.observe(0.2)
        h.observe(0.3)
        
        assert h.get_count() == 3
    
    def test_sum(self):
        """Test sum of observations."""
        h = Histogram("request_latency")
        h.observe(0.1)
        h.observe(0.2)
        h.observe(0.3)
        
        assert h.get_sum() == pytest.approx(0.6)
    
    def test_mean(self):
        """Test mean calculation."""
        h = Histogram("request_latency")
        h.observe(0.1)
        h.observe(0.2)
        h.observe(0.3)
        
        assert h.get_mean() == pytest.approx(0.2)
    
    def test_percentile(self):
        """Test percentile calculation."""
        h = Histogram("request_latency")
        for i in range(100):
            h.observe(i + 1)
        
        p50 = h.get_percentile(50)
        assert 49 < p50 < 52
    
    def test_bucket_counts(self):
        """Test bucket count distribution."""
        h = Histogram("latency", buckets=(0.1, 0.5, 1.0, float("inf")))
        h.observe(0.05)  # <= 0.1
        h.observe(0.3)   # <= 0.5
        h.observe(0.8)   # <= 1.0
        
        counts = h.get_bucket_counts()
        assert counts["le_0.1"] == 1
    
    def test_stats(self):
        """Test comprehensive statistics."""
        h = Histogram("request_latency")
        for i in range(100):
            h.observe(i / 100)
        
        stats = h.get_stats()
        assert "count" in stats
        assert "mean" in stats
        assert "p95" in stats
        assert "p99" in stats
    
    def test_reset(self):
        """Test histogram reset."""
        h = Histogram("test")
        h.observe(1)
        h.observe(2)
        h.reset()
        
        assert h.get_count() == 0
    
    def test_with_labels(self):
        """Test histogram with labels."""
        h = Histogram("request_latency")
        h.observe(0.1, labels={"endpoint": "/api"})
        h.observe(0.2, labels={"endpoint": "/api"})
        h.observe(0.5, labels={"endpoint": "/health"})
        
        assert h.get_count(labels={"endpoint": "/api"}) == 2
        assert h.get_count(labels={"endpoint": "/health"}) == 1
    
    def test_custom_buckets(self):
        """Test custom bucket configuration."""
        h = Histogram("latency", buckets=(1, 5, 10, 50, 100))
        assert h.buckets == (1, 5, 10, 50, 100)
    
    def test_empty_percentile(self):
        """Test percentile on empty histogram."""
        h = Histogram("empty")
        assert h.get_percentile(50) == 0.0


# =============================================================================
# Timer Tests (7 tests)
# =============================================================================

class TestTimer:
    """Tests for Timer metric."""
    
    def test_time_context_manager(self):
        """Test timing with context manager."""
        t = Timer("function_duration")
        
        with t.time():
            time.sleep(0.01)
        
        assert t.get_count() == 1
        assert t.get_mean() > 0
    
    def test_time_decorator(self):
        """Test timing with decorator."""
        t = Timer("function_duration")
        
        @t.time_func()
        def slow_function():
            time.sleep(0.01)
            return "done"
        
        result = slow_function()
        assert result == "done"
        assert t.get_count() == 1
    
    def test_manual_record(self):
        """Test manual duration recording."""
        t = Timer("external_call")
        t.record(0.5)
        t.record(1.0)
        
        assert t.get_count() == 2
        assert t.get_mean() == pytest.approx(0.75)
    
    def test_get_stats(self):
        """Test getting timer statistics."""
        t = Timer("api_latency")
        for _ in range(10):
            t.record(0.1)
        
        stats = t.get_stats()
        assert "count" in stats
        assert "mean" in stats
        assert "p99" in stats
    
    def test_with_labels(self):
        """Test timer with labels."""
        t = Timer("http_request_duration")
        
        with t.time(labels={"method": "GET"}):
            time.sleep(0.01)
        
        with t.time(labels={"method": "POST"}):
            time.sleep(0.01)
        
        assert t.get_count(labels={"method": "GET"}) == 1
    
    def test_percentile(self):
        """Test timer percentile."""
        t = Timer("latency")
        for i in range(100):
            t.record(i / 100)
        
        p99 = t.get_percentile(99)
        assert p99 > 0.9
    
    def test_reset(self):
        """Test timer reset."""
        t = Timer("test")
        t.record(1)
        t.reset()
        assert t.get_count() == 0


# =============================================================================
# MetricsRegistry Tests (7 tests)
# =============================================================================

class TestMetricsRegistry:
    """Tests for MetricsRegistry."""
    
    def test_counter_registration(self):
        """Test counter registration."""
        registry = MetricsRegistry()
        c = registry.counter("requests_total")
        c.inc()
        
        assert c.get() == 1
    
    def test_gauge_registration(self):
        """Test gauge registration."""
        registry = MetricsRegistry()
        g = registry.gauge("memory_usage")
        g.set(1024)
        
        assert g.get() == 1024
    
    def test_histogram_registration(self):
        """Test histogram registration."""
        registry = MetricsRegistry()
        h = registry.histogram("latency")
        h.observe(0.1)
        
        assert h.get_count() == 1
    
    def test_timer_registration(self):
        """Test timer registration."""
        registry = MetricsRegistry()
        t = registry.timer("duration")
        t.record(0.5)
        
        assert t.get_count() == 1
    
    def test_prefix(self):
        """Test metric name prefix."""
        registry = MetricsRegistry(prefix="myapp")
        c = registry.counter("requests")
        
        assert c.name == "myapp_requests"
    
    def test_export_json(self):
        """Test JSON export."""
        registry = MetricsRegistry()
        c = registry.counter("test")
        c.inc(5)
        
        json_str = registry.export_json()
        data = json.loads(json_str)
        
        assert "metrics" in data
        assert "timestamp" in data
    
    def test_export_prometheus(self):
        """Test Prometheus format export."""
        registry = MetricsRegistry()
        c = registry.counter("http_requests")
        c.inc(100)
        
        prom = registry.export_prometheus()
        assert "# TYPE http_requests counter" in prom
        assert "http_requests" in prom


# =============================================================================
# Global Registry Tests (5 tests)
# =============================================================================

class TestGlobalRegistry:
    """Tests for global registry functions."""
    
    def setup_method(self):
        """Reset registry before each test."""
        reset_registry()
    
    def test_get_registry(self):
        """Test getting default registry."""
        reg = get_registry()
        assert isinstance(reg, MetricsRegistry)
    
    def test_set_registry(self):
        """Test setting custom registry."""
        custom = MetricsRegistry(prefix="custom")
        set_registry(custom)
        
        reg = get_registry()
        assert reg.prefix == "custom"
    
    def test_convenience_counter(self):
        """Test convenience counter function."""
        c = counter("test_counter")
        c.inc()
        assert c.get() == 1
    
    def test_convenience_gauge(self):
        """Test convenience gauge function."""
        g = gauge("test_gauge")
        g.set(42)
        assert g.get() == 42
    
    def test_convenience_timer(self):
        """Test convenience timer function."""
        t = timer("test_timer")
        t.record(0.5)
        assert t.get_count() == 1


# =============================================================================
# Summary
# =============================================================================
# Total: 45 tests
# - MetricType: 2 tests
# - MetricValue: 3 tests
# - Counter: 8 tests
# - Gauge: 8 tests
# - Histogram: 10 tests
# - Timer: 7 tests
# - MetricsRegistry: 7 tests (with teardown reset not counted, 5 global tests)