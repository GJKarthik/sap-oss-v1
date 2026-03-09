#!/usr/bin/env python3
"""
Prometheus-style /metrics endpoint.

Exposes counters and gauges in the Prometheus text exposition format so
the service can be scraped by Prometheus, Grafana Agent, or Datadog.
No external dependencies required — we emit the text format directly.
"""

import time
import threading
from typing import Dict

from fastapi import APIRouter, Response

router = APIRouter()


class _Counter:
    """Thread-safe monotonic counter."""

    def __init__(self) -> None:
        self._value: float = 0
        self._lock = threading.Lock()

    def inc(self, amount: float = 1) -> None:
        with self._lock:
            self._value += amount

    @property
    def value(self) -> float:
        return self._value


class _Gauge:
    """Thread-safe gauge (can go up and down)."""

    def __init__(self) -> None:
        self._value: float = 0
        self._lock = threading.Lock()

    def set(self, value: float) -> None:
        with self._lock:
            self._value = value

    def inc(self, amount: float = 1) -> None:
        with self._lock:
            self._value += amount

    def dec(self, amount: float = 1) -> None:
        with self._lock:
            self._value -= amount

    @property
    def value(self) -> float:
        return self._value


class _Histogram:
    """Minimal histogram tracking sum, count, and a few buckets."""

    BUCKETS = (0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0)

    def __init__(self) -> None:
        self._sum: float = 0
        self._count: int = 0
        self._buckets: Dict[float, int] = {b: 0 for b in self.BUCKETS}
        self._lock = threading.Lock()

    def observe(self, value: float) -> None:
        with self._lock:
            self._sum += value
            self._count += 1
            for b in self.BUCKETS:
                if value <= b:
                    self._buckets[b] += 1

    def render(self, name: str) -> str:
        lines = []
        with self._lock:
            for b in self.BUCKETS:
                lines.append(f'{name}_bucket{{le="{b}"}} {self._buckets[b]}')
            lines.append(f'{name}_bucket{{le="+Inf"}} {self._count}')
            lines.append(f"{name}_sum {self._sum:.6f}")
            lines.append(f"{name}_count {self._count}")
        return "\n".join(lines)


# ── Global metrics instances ─────────────────────────────────────────────────

request_count = _Counter()
request_errors = _Counter()
request_latency = _Histogram()
active_jobs = _Gauge()
models_loaded = _Gauge()
startup_time = time.time()


# ── Endpoint ─────────────────────────────────────────────────────────────────

@router.get("/metrics")
async def prometheus_metrics():
    """Prometheus text exposition format."""
    lines = [
        "# HELP modelopt_request_total Total HTTP requests received.",
        "# TYPE modelopt_request_total counter",
        f"modelopt_request_total {request_count.value}",
        "",
        "# HELP modelopt_request_errors_total Total HTTP 5xx errors.",
        "# TYPE modelopt_request_errors_total counter",
        f"modelopt_request_errors_total {request_errors.value}",
        "",
        "# HELP modelopt_request_duration_seconds Request latency.",
        "# TYPE modelopt_request_duration_seconds histogram",
        request_latency.render("modelopt_request_duration_seconds"),
        "",
        "# HELP modelopt_active_jobs Number of currently running jobs.",
        "# TYPE modelopt_active_jobs gauge",
        f"modelopt_active_jobs {active_jobs.value}",
        "",
        "# HELP modelopt_models_loaded Number of models loaded in memory.",
        "# TYPE modelopt_models_loaded gauge",
        f"modelopt_models_loaded {models_loaded.value}",
        "",
        "# HELP modelopt_uptime_seconds Seconds since service start.",
        "# TYPE modelopt_uptime_seconds gauge",
        f"modelopt_uptime_seconds {time.time() - startup_time:.1f}",
        "",
    ]
    return Response(
        content="\n".join(lines) + "\n",
        media_type="text/plain; version=0.0.4; charset=utf-8",
    )

