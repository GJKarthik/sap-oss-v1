"""
Metrics and dashboard statistics routes for SAP AI Fabric Console.
Aggregates data from the configured persistent store and probes MCP service health endpoints.
"""

import asyncio
import time
from typing import Any, Dict, List, Optional

import httpx
from prometheus_client import REGISTRY
import structlog
from fastapi import APIRouter, Depends
from pydantic import BaseModel

from ..config import settings
from ..routes.auth import (
    UserInfo,
    admin_action_metrics_snapshot,
    auth_metrics_snapshot,
    get_current_user,
)
from ..routes.mcp_proxy import mcp_metrics_snapshot, probe_health
from ..store import StoreBackend, get_store

router = APIRouter()
logger = structlog.get_logger()


# ---------------------------------------------------------------------------
# Pydantic schemas
# ---------------------------------------------------------------------------

class ServiceMetrics(BaseModel):
    service: str
    status: str
    latency_ms: Optional[float] = None
    error: Optional[str] = None


class DashboardStats(BaseModel):
    total_deployments: int
    running_deployments: int
    total_vector_stores: int
    total_documents: int
    active_governance_rules: int
    total_users: int
    services: List[ServiceMetrics]


def _prometheus_samples(name: str) -> list[Any]:
    samples: list[Any] = []
    for metric in REGISTRY.collect():
        for sample in metric.samples:
            if sample.name == name:
                samples.append(sample)
    return samples


def _api_metrics_snapshot() -> dict:
    total_requests = 0.0
    error_requests = 0.0
    duration_sum = 0.0
    duration_count = 0.0
    handlers: dict[str, dict[str, float | str]] = {}

    for sample in _prometheus_samples("http_requests_total"):
        value = float(sample.value)
        total_requests += value
        status = sample.labels.get("status", "unknown")
        handler = sample.labels.get("handler", "unknown")
        method = sample.labels.get("method", "UNKNOWN")
        key = f"{method} {handler}"
        entry = handlers.setdefault(key, {"handler": handler, "method": method, "requests": 0.0, "errors": 0.0})
        entry["requests"] = float(entry["requests"]) + value
        if not status.startswith(("2", "3")):
            error_requests += value
            entry["errors"] = float(entry["errors"]) + value

    for sample in _prometheus_samples("http_request_duration_seconds_sum"):
        duration_sum += float(sample.value)
        handler = sample.labels.get("handler", "unknown")
        method = sample.labels.get("method", "UNKNOWN")
        key = f"{method} {handler}"
        entry = handlers.setdefault(key, {"handler": handler, "method": method, "requests": 0.0, "errors": 0.0})
        entry["latency_sum_ms"] = float(entry.get("latency_sum_ms", 0.0)) + (float(sample.value) * 1000)

    for sample in _prometheus_samples("http_request_duration_seconds_count"):
        value = float(sample.value)
        duration_count += value
        handler = sample.labels.get("handler", "unknown")
        method = sample.labels.get("method", "UNKNOWN")
        key = f"{method} {handler}"
        entry = handlers.setdefault(key, {"handler": handler, "method": method, "requests": 0.0, "errors": 0.0})
        entry["latency_count"] = float(entry.get("latency_count", 0.0)) + value

    handler_rows = []
    for entry in handlers.values():
        latency_count = float(entry.get("latency_count", 0.0))
        latency_sum_ms = float(entry.get("latency_sum_ms", 0.0))
        handler_rows.append({
            "handler": entry["handler"],
            "method": entry["method"],
            "requests": int(float(entry["requests"])),
            "errors": int(float(entry["errors"])),
            "avg_latency_ms": round(latency_sum_ms / latency_count, 1) if latency_count else 0.0,
        })

    handler_rows.sort(key=lambda row: (row["errors"], row["avg_latency_ms"], row["requests"]), reverse=True)
    return {
        "requests_total": int(total_requests),
        "error_requests_total": int(error_requests),
        "error_rate": round((error_requests / total_requests) * 100, 2) if total_requests else 0.0,
        "avg_latency_ms": round((duration_sum / duration_count) * 1000, 1) if duration_count else 0.0,
        "handlers": handler_rows[:10],
    }


def _build_alerts(
    auth_snapshot: dict,
    mcp_snapshot: dict,
    store_health: dict,
    service_health: list[dict],
) -> list[dict]:
    recent_mcp_failures = mcp_snapshot.get("recent_failures", {})
    readiness_degraded = store_health.get("store") != "ok" or (
        settings.require_mcp_dependencies and any(service.get("status") not in {"ok", "healthy", "ready"} for service in service_health)
    )
    return [
        {
            "name": "auth_failure_spike",
            "active": auth_snapshot["recent_failures"] >= settings.auth_failure_alert_threshold,
            "observed": auth_snapshot["recent_failures"],
            "threshold": settings.auth_failure_alert_threshold,
            "window_seconds": settings.alert_window_seconds,
        },
        {
            "name": "mcp_failure_rate",
            "active": any(count >= settings.mcp_failure_alert_threshold for count in recent_mcp_failures.values()),
            "observed": recent_mcp_failures,
            "threshold": settings.mcp_failure_alert_threshold,
            "window_seconds": settings.alert_window_seconds,
        },
        {
            "name": "readiness_degradation",
            "active": readiness_degraded,
            "observed": {
                "store": store_health.get("store"),
                "required_mcp_dependencies": settings.require_mcp_dependencies,
                "services": {service["service"]: service["status"] for service in service_health},
            },
            "threshold": settings.readiness_failure_alert_threshold,
            "window_seconds": settings.alert_window_seconds,
        },
    ]


# ---------------------------------------------------------------------------
# MCP service health probe helper
# ---------------------------------------------------------------------------

async def _probe_service(name: str, url: str) -> ServiceMetrics:
    """Probe a service health endpoint and return its status."""
    start = time.monotonic()
    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            resp = await client.get(url)
            latency = (time.monotonic() - start) * 1000
            if resp.status_code < 400:
                return ServiceMetrics(service=name, status="healthy", latency_ms=round(latency, 1))
            return ServiceMetrics(
                service=name,
                status="degraded",
                latency_ms=round(latency, 1),
                error=f"HTTP {resp.status_code}",
            )
    except Exception as exc:
        return ServiceMetrics(service=name, status="unreachable", error=str(exc))


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@router.get("/dashboard", response_model=DashboardStats)
async def dashboard_stats(
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(get_current_user),
):
    """Aggregate dashboard statistics from the persistent store and MCP service probes."""
    deployments = store.list_records("deployments")
    total_deps = len(deployments)
    running_deps = sum(1 for d in deployments if d.get("status") == "RUNNING")

    vector_stores = store.list_records("vector_stores")
    total_vs = len(vector_stores)
    total_docs = sum(vs.get("documents_added", 0) for vs in vector_stores)

    active_rules = sum(1 for r in store.list_records("governance_rules") if r.get("active", True))
    total_users = store.count("users")

    elasticsearch_url = settings.elasticsearch_mcp_url.replace("/mcp", "/health")
    pal_url = settings.pal_mcp_url.replace("/mcp", "/health")
    services = await asyncio.gather(
        _probe_service("elasticsearch-mcp", elasticsearch_url),
        _probe_service("ai-core-pal-mcp", pal_url),
    )

    return DashboardStats(
        total_deployments=total_deps,
        running_deployments=running_deps,
        total_vector_stores=total_vs,
        total_documents=total_docs,
        active_governance_rules=active_rules,
        total_users=total_users,
        services=list(services),
    )


@router.get("/services", response_model=List[ServiceMetrics])
async def service_health(_: UserInfo = Depends(get_current_user)):
    """Probe all backend service health endpoints."""
    elasticsearch_url = settings.elasticsearch_mcp_url.replace("/mcp", "/health")
    pal_url = settings.pal_mcp_url.replace("/mcp", "/health")
    results = await asyncio.gather(
        _probe_service("elasticsearch-mcp", elasticsearch_url),
        _probe_service("ai-core-pal-mcp", pal_url),
    )
    return list(results)


@router.get("/operations")
async def operations_dashboard(
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(get_current_user),
):
    """Operational dashboard snapshot built from existing Prometheus and store health data."""
    auth_snapshot = auth_metrics_snapshot(settings.alert_window_seconds)
    store_health = store.health_snapshot()
    service_health_snapshot = await asyncio.gather(
        probe_health("elasticsearch-mcp", settings.elasticsearch_mcp_url, settings.mcp_healthcheck_timeout_seconds),
        probe_health("ai-core-pal-mcp", settings.pal_mcp_url, settings.mcp_healthcheck_timeout_seconds),
    )
    mcp_snapshot = mcp_metrics_snapshot(settings.alert_window_seconds)
    alerts = _build_alerts(auth_snapshot, mcp_snapshot, store_health, list(service_health_snapshot))

    return {
        "window_seconds": settings.alert_window_seconds,
        "api": _api_metrics_snapshot(),
        "auth": auth_snapshot,
        "mcp": {
            **mcp_snapshot,
            "service_health": list(service_health_snapshot),
        },
        "store": store_health,
        "audit": admin_action_metrics_snapshot(),
        "alerts": alerts,
    }


@router.get("/usage")
async def usage_metrics(
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(get_current_user),
):
    """Usage metrics aggregated from the persistent store."""
    deployments = store.list_records("deployments")
    vector_stores = store.list_records("vector_stores")

    total_docs = sum(vs.get("documents_added", 0) for vs in vector_stores)
    total_stores = len(vector_stores)
    total_deployments = len(deployments)

    from collections import Counter
    scenario_counter: Counter = Counter(
        d["scenario_id"] for d in deployments if d.get("scenario_id")
    )
    top_models = [
        {"model": scenario, "deployments": count}
        for scenario, count in scenario_counter.most_common(5)
    ]

    return {
        "total_documents_indexed": total_docs,
        "total_vector_stores": total_stores,
        "total_deployments": total_deployments,
        "top_models": top_models,
    }
