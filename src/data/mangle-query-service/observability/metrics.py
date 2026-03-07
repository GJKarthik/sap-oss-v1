"""
Metrics Collection Module - Observability Without External Dependencies.

Day 51 Implementation - Week 11 Observability & Monitoring
Provides Counter, Gauge, Histogram, Timer metrics collection.
No external service dependencies - pure Python implementation.
"""

import time
import threading
import statistics
from typing import Optional, Dict, Any, List, Callable, Union
from dataclasses import dataclass, field
from enum import Enum
from contextlib import contextmanager
from functools import wraps
import json
import logging

logger = logging.getLogger(__name__)


# =============================================================================
# Metric Types
# =============================================================================

class MetricType(str, Enum):
    """Types of metrics."""
    COUNTER = "counter"
    GAUGE = "gauge"
    HISTOGRAM = "histogram"
    TIMER = "timer"


@dataclass
class MetricValue:
    """Represents a metric value with metadata."""
    name: str
    value: Union[int, float]
    metric_type: MetricType
    labels: Dict[str, str] = field(default_factory=dict)
    timestamp: float = field(default_factory=time.time)
    unit: str = ""
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "name": self.name,
            "value": self.value,
            "type": self.metric_type.value,
            "labels": self.labels,
            "timestamp": self.timestamp,
            "unit": self.unit,
        }


# =============================================================================
# Base Metric
# =============================================================================

class BaseMetric:
    """Base class for all metrics."""
    
    def __init__(
        self,
        name: str,
        description: str = "",
        labels: Optional[Dict[str, str]] = None,
        unit: str = "",
    ):
        self.name = name
        self.description = description
        self.default_labels = labels or {}
        self.unit = unit
        self._lock = threading.Lock()
    
    def _merge_labels(self, labels: Optional[Dict[str, str]] = None) -> Dict[str, str]:
        """Merge default labels with provided labels."""
        merged = dict(self.default_labels)
        if labels:
            merged.update(labels)
        return merged


# =============================================================================
# Counter
# =============================================================================

class Counter(BaseMetric):
    """
    Counter metric - monotonically increasing value.
    
    Use for: request counts, error counts, total bytes processed.
    """
    
    def __init__(
        self,
        name: str,
        description: str = "",
        labels: Optional[Dict[str, str]] = None,
    ):
        super().__init__(name, description, labels)
        self._values: Dict[str, int] = {}
    
    def inc(self, value: int = 1, labels: Optional[Dict[str, str]] = None) -> None:
        """Increment counter."""
        if value < 0:
            raise ValueError("Counter can only be incremented by non-negative values")
        
        label_key = self._label_key(labels)
        with self._lock:
            if label_key not in self._values:
                self._values[label_key] = 0
            self._values[label_key] += value
    
    def get(self, labels: Optional[Dict[str, str]] = None) -> int:
        """Get current value."""
        label_key = self._label_key(labels)
        with self._lock:
            return self._values.get(label_key, 0)
    
    def reset(self, labels: Optional[Dict[str, str]] = None) -> None:
        """Reset counter to zero."""
        label_key = self._label_key(labels)
        with self._lock:
            self._values[label_key] = 0
    
    def get_all(self) -> List[MetricValue]:
        """Get all values as MetricValue objects."""
        with self._lock:
            return [
                MetricValue(
                    name=self.name,
                    value=value,
                    metric_type=MetricType.COUNTER,
                    labels=self._parse_label_key(key),
                )
                for key, value in self._values.items()
            ]
    
    def _label_key(self, labels: Optional[Dict[str, str]] = None) -> str:
        """Create string key from labels."""
        merged = self._merge_labels(labels)
        if not merged:
            return "__default__"
        return json.dumps(merged, sort_keys=True)
    
    def _parse_label_key(self, key: str) -> Dict[str, str]:
        """Parse label key back to dict."""
        if key == "__default__":
            return self.default_labels.copy()
        try:
            return json.loads(key)
        except json.JSONDecodeError:
            return {}


# =============================================================================
# Gauge
# =============================================================================

class Gauge(BaseMetric):
    """
    Gauge metric - value that can go up or down.
    
    Use for: current memory usage, active connections, queue size.
    """
    
    def __init__(
        self,
        name: str,
        description: str = "",
        labels: Optional[Dict[str, str]] = None,
        unit: str = "",
    ):
        super().__init__(name, description, labels, unit)
        self._values: Dict[str, float] = {}
    
    def set(self, value: float, labels: Optional[Dict[str, str]] = None) -> None:
        """Set gauge value."""
        label_key = self._label_key(labels)
        with self._lock:
            self._values[label_key] = value
    
    def inc(self, value: float = 1.0, labels: Optional[Dict[str, str]] = None) -> None:
        """Increment gauge."""
        label_key = self._label_key(labels)
        with self._lock:
            if label_key not in self._values:
                self._values[label_key] = 0.0
            self._values[label_key] += value
    
    def dec(self, value: float = 1.0, labels: Optional[Dict[str, str]] = None) -> None:
        """Decrement gauge."""
        label_key = self._label_key(labels)
        with self._lock:
            if label_key not in self._values:
                self._values[label_key] = 0.0
            self._values[label_key] -= value
    
    def get(self, labels: Optional[Dict[str, str]] = None) -> float:
        """Get current value."""
        label_key = self._label_key(labels)
        with self._lock:
            return self._values.get(label_key, 0.0)
    
    @contextmanager
    def track_inprogress(self, labels: Optional[Dict[str, str]] = None):
        """Context manager to track in-progress operations."""
        self.inc(labels=labels)
        try:
            yield
        finally:
            self.dec(labels=labels)
    
    def get_all(self) -> List[MetricValue]:
        """Get all values as MetricValue objects."""
        with self._lock:
            return [
                MetricValue(
                    name=self.name,
                    value=value,
                    metric_type=MetricType.GAUGE,
                    labels=self._parse_label_key(key),
                    unit=self.unit,
                )
                for key, value in self._values.items()
            ]
    
    def _label_key(self, labels: Optional[Dict[str, str]] = None) -> str:
        """Create string key from labels."""
        merged = self._merge_labels(labels)
        if not merged:
            return "__default__"
        return json.dumps(merged, sort_keys=True)
    
    def _parse_label_key(self, key: str) -> Dict[str, str]:
        """Parse label key back to dict."""
        if key == "__default__":
            return self.default_labels.copy()
        try:
            return json.loads(key)
        except json.JSONDecodeError:
            return {}


# =============================================================================
# Histogram
# =============================================================================

class Histogram(BaseMetric):
    """
    Histogram metric - distribution of values.
    
    Use for: request latencies, response sizes, queue wait times.
    """
    
    DEFAULT_BUCKETS = (
        0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75,
        1.0, 2.5, 5.0, 7.5, 10.0, float("inf")
    )
    
    def __init__(
        self,
        name: str,
        description: str = "",
        labels: Optional[Dict[str, str]] = None,
        buckets: Optional[tuple] = None,
        unit: str = "",
    ):
        super().__init__(name, description, labels, unit)
        self.buckets = buckets or self.DEFAULT_BUCKETS
        self._observations: Dict[str, List[float]] = {}
    
    def observe(self, value: float, labels: Optional[Dict[str, str]] = None) -> None:
        """Record an observation."""
        label_key = self._label_key(labels)
        with self._lock:
            if label_key not in self._observations:
                self._observations[label_key] = []
            self._observations[label_key].append(value)
    
    def get_count(self, labels: Optional[Dict[str, str]] = None) -> int:
        """Get total count of observations."""
        label_key = self._label_key(labels)
        with self._lock:
            return len(self._observations.get(label_key, []))
    
    def get_sum(self, labels: Optional[Dict[str, str]] = None) -> float:
        """Get sum of observations."""
        label_key = self._label_key(labels)
        with self._lock:
            return sum(self._observations.get(label_key, []))
    
    def get_mean(self, labels: Optional[Dict[str, str]] = None) -> float:
        """Get mean of observations."""
        label_key = self._label_key(labels)
        with self._lock:
            obs = self._observations.get(label_key, [])
            return statistics.mean(obs) if obs else 0.0
    
    def get_percentile(
        self,
        percentile: float,
        labels: Optional[Dict[str, str]] = None,
    ) -> float:
        """Get percentile value."""
        label_key = self._label_key(labels)
        with self._lock:
            obs = self._observations.get(label_key, [])
            if not obs:
                return 0.0
            sorted_obs = sorted(obs)
            k = (len(sorted_obs) - 1) * percentile / 100
            f = int(k)
            c = f + 1 if f + 1 < len(sorted_obs) else f
            return sorted_obs[f] + (k - f) * (sorted_obs[c] - sorted_obs[f])
    
    def get_bucket_counts(
        self,
        labels: Optional[Dict[str, str]] = None,
    ) -> Dict[str, int]:
        """Get observation counts per bucket."""
        label_key = self._label_key(labels)
        with self._lock:
            obs = self._observations.get(label_key, [])
            counts = {f"le_{b}": 0 for b in self.buckets}
            for value in obs:
                for bucket in self.buckets:
                    if value <= bucket:
                        counts[f"le_{bucket}"] += 1
                        break
            return counts
    
    def reset(self, labels: Optional[Dict[str, str]] = None) -> None:
        """Reset histogram."""
        label_key = self._label_key(labels)
        with self._lock:
            self._observations[label_key] = []
    
    def get_stats(self, labels: Optional[Dict[str, str]] = None) -> Dict[str, float]:
        """Get comprehensive statistics."""
        label_key = self._label_key(labels)
        with self._lock:
            obs = self._observations.get(label_key, [])
            if not obs:
                return {}
            
            return {
                "count": len(obs),
                "sum": sum(obs),
                "min": min(obs),
                "max": max(obs),
                "mean": statistics.mean(obs),
                "median": statistics.median(obs),
                "stdev": statistics.stdev(obs) if len(obs) > 1 else 0,
                "p50": self.get_percentile(50, labels),
                "p90": self.get_percentile(90, labels),
                "p95": self.get_percentile(95, labels),
                "p99": self.get_percentile(99, labels),
            }
    
    def _label_key(self, labels: Optional[Dict[str, str]] = None) -> str:
        """Create string key from labels."""
        merged = self._merge_labels(labels)
        if not merged:
            return "__default__"
        return json.dumps(merged, sort_keys=True)


# =============================================================================
# Timer
# =============================================================================

class Timer(BaseMetric):
    """
    Timer metric - measures duration of operations.
    
    Use for: function execution time, API latency, database queries.
    """
    
    def __init__(
        self,
        name: str,
        description: str = "",
        labels: Optional[Dict[str, str]] = None,
    ):
        super().__init__(name, description, labels, unit="seconds")
        self._histogram = Histogram(name, description, labels, unit="seconds")
    
    @contextmanager
    def time(self, labels: Optional[Dict[str, str]] = None):
        """Context manager to time an operation."""
        start = time.perf_counter()
        try:
            yield
        finally:
            duration = time.perf_counter() - start
            self._histogram.observe(duration, labels)
    
    def time_func(self, labels: Optional[Dict[str, str]] = None):
        """Decorator to time a function."""
        def decorator(func: Callable):
            @wraps(func)
            def wrapper(*args, **kwargs):
                with self.time(labels):
                    return func(*args, **kwargs)
            return wrapper
        return decorator
    
    def record(self, duration: float, labels: Optional[Dict[str, str]] = None) -> None:
        """Manually record a duration."""
        self._histogram.observe(duration, labels)
    
    def get_stats(self, labels: Optional[Dict[str, str]] = None) -> Dict[str, float]:
        """Get timing statistics."""
        return self._histogram.get_stats(labels)
    
    def get_count(self, labels: Optional[Dict[str, str]] = None) -> int:
        """Get total count."""
        return self._histogram.get_count(labels)
    
    def get_mean(self, labels: Optional[Dict[str, str]] = None) -> float:
        """Get mean duration."""
        return self._histogram.get_mean(labels)
    
    def get_percentile(
        self,
        percentile: float,
        labels: Optional[Dict[str, str]] = None,
    ) -> float:
        """Get percentile duration."""
        return self._histogram.get_percentile(percentile, labels)
    
    def reset(self, labels: Optional[Dict[str, str]] = None) -> None:
        """Reset timer."""
        self._histogram.reset(labels)


# =============================================================================
# Metrics Registry
# =============================================================================

class MetricsRegistry:
    """
    Central registry for all metrics.
    
    Provides:
    - Metric registration
    - Metric retrieval
    - Export to various formats
    """
    
    def __init__(self, prefix: str = ""):
        self.prefix = prefix
        self._metrics: Dict[str, BaseMetric] = {}
        self._lock = threading.Lock()
    
    def _full_name(self, name: str) -> str:
        """Get full metric name with prefix."""
        if self.prefix:
            return f"{self.prefix}_{name}"
        return name
    
    def counter(
        self,
        name: str,
        description: str = "",
        labels: Optional[Dict[str, str]] = None,
    ) -> Counter:
        """Register and return a counter."""
        full_name = self._full_name(name)
        with self._lock:
            if full_name not in self._metrics:
                self._metrics[full_name] = Counter(full_name, description, labels)
            return self._metrics[full_name]
    
    def gauge(
        self,
        name: str,
        description: str = "",
        labels: Optional[Dict[str, str]] = None,
        unit: str = "",
    ) -> Gauge:
        """Register and return a gauge."""
        full_name = self._full_name(name)
        with self._lock:
            if full_name not in self._metrics:
                self._metrics[full_name] = Gauge(full_name, description, labels, unit)
            return self._metrics[full_name]
    
    def histogram(
        self,
        name: str,
        description: str = "",
        labels: Optional[Dict[str, str]] = None,
        buckets: Optional[tuple] = None,
        unit: str = "",
    ) -> Histogram:
        """Register and return a histogram."""
        full_name = self._full_name(name)
        with self._lock:
            if full_name not in self._metrics:
                self._metrics[full_name] = Histogram(
                    full_name, description, labels, buckets, unit
                )
            return self._metrics[full_name]
    
    def timer(
        self,
        name: str,
        description: str = "",
        labels: Optional[Dict[str, str]] = None,
    ) -> Timer:
        """Register and return a timer."""
        full_name = self._full_name(name)
        with self._lock:
            if full_name not in self._metrics:
                self._metrics[full_name] = Timer(full_name, description, labels)
            return self._metrics[full_name]
    
    def get(self, name: str) -> Optional[BaseMetric]:
        """Get a metric by name."""
        full_name = self._full_name(name)
        with self._lock:
            return self._metrics.get(full_name)
    
    def get_all(self) -> Dict[str, BaseMetric]:
        """Get all registered metrics."""
        with self._lock:
            return dict(self._metrics)
    
    def unregister(self, name: str) -> bool:
        """Unregister a metric."""
        full_name = self._full_name(name)
        with self._lock:
            if full_name in self._metrics:
                del self._metrics[full_name]
                return True
            return False
    
    def clear(self) -> None:
        """Clear all metrics."""
        with self._lock:
            self._metrics.clear()
    
    def export_json(self) -> str:
        """Export all metrics as JSON."""
        data = {"metrics": [], "timestamp": time.time()}
        
        with self._lock:
            for name, metric in self._metrics.items():
                if isinstance(metric, Counter):
                    for mv in metric.get_all():
                        data["metrics"].append(mv.to_dict())
                elif isinstance(metric, Gauge):
                    for mv in metric.get_all():
                        data["metrics"].append(mv.to_dict())
                elif isinstance(metric, Histogram):
                    stats = metric.get_stats()
                    if stats:
                        data["metrics"].append({
                            "name": name,
                            "type": "histogram",
                            "stats": stats,
                        })
                elif isinstance(metric, Timer):
                    stats = metric.get_stats()
                    if stats:
                        data["metrics"].append({
                            "name": name,
                            "type": "timer",
                            "stats": stats,
                        })
        
        return json.dumps(data, indent=2)
    
    def export_prometheus(self) -> str:
        """Export in Prometheus text format."""
        lines = []
        
        with self._lock:
            for name, metric in self._metrics.items():
                if isinstance(metric, Counter):
                    lines.append(f"# TYPE {name} counter")
                    for mv in metric.get_all():
                        label_str = self._format_labels(mv.labels)
                        lines.append(f"{name}{label_str} {mv.value}")
                
                elif isinstance(metric, Gauge):
                    lines.append(f"# TYPE {name} gauge")
                    for mv in metric.get_all():
                        label_str = self._format_labels(mv.labels)
                        lines.append(f"{name}{label_str} {mv.value}")
                
                elif isinstance(metric, Histogram):
                    lines.append(f"# TYPE {name} histogram")
                    stats = metric.get_stats()
                    if stats:
                        lines.append(f"{name}_count {stats.get('count', 0)}")
                        lines.append(f"{name}_sum {stats.get('sum', 0)}")
        
        return "\n".join(lines)
    
    def _format_labels(self, labels: Dict[str, str]) -> str:
        """Format labels for Prometheus."""
        if not labels:
            return ""
        pairs = [f'{k}="{v}"' for k, v in sorted(labels.items())]
        return "{" + ",".join(pairs) + "}"


# =============================================================================
# Global Registry
# =============================================================================

_default_registry: Optional[MetricsRegistry] = None
_registry_lock = threading.Lock()


def get_registry(prefix: str = "") -> MetricsRegistry:
    """Get or create the default metrics registry."""
    global _default_registry
    with _registry_lock:
        if _default_registry is None:
            _default_registry = MetricsRegistry(prefix)
        return _default_registry


def set_registry(registry: MetricsRegistry) -> None:
    """Set the default registry."""
    global _default_registry
    with _registry_lock:
        _default_registry = registry


def reset_registry() -> None:
    """Reset the default registry."""
    global _default_registry
    with _registry_lock:
        _default_registry = None


# =============================================================================
# Convenience Functions
# =============================================================================

def counter(
    name: str,
    description: str = "",
    labels: Optional[Dict[str, str]] = None,
) -> Counter:
    """Get or create a counter from the default registry."""
    return get_registry().counter(name, description, labels)


def gauge(
    name: str,
    description: str = "",
    labels: Optional[Dict[str, str]] = None,
    unit: str = "",
) -> Gauge:
    """Get or create a gauge from the default registry."""
    return get_registry().gauge(name, description, labels, unit)


def histogram(
    name: str,
    description: str = "",
    labels: Optional[Dict[str, str]] = None,
    buckets: Optional[tuple] = None,
    unit: str = "",
) -> Histogram:
    """Get or create a histogram from the default registry."""
    return get_registry().histogram(name, description, labels, buckets, unit)


def timer(
    name: str,
    description: str = "",
    labels: Optional[Dict[str, str]] = None,
) -> Timer:
    """Get or create a timer from the default registry."""
    return get_registry().timer(name, description, labels)