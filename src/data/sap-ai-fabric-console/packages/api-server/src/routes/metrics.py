"""
Metrics and dashboard statistics routes for SAP AI Fabric Console.
Aggregates data from the configured persistent store and probes MCP service health endpoints.
"""

import asyncio
import time
from typing import Any, Dict, List, Optional

import httpx
import structlog
from fastapi import APIRouter, Depends
from pydantic import BaseModel

from ..config import settings
from ..routes.auth import UserInfo, get_current_user
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

    langchain_url = settings.langchain_mcp_url.replace("/mcp", "/health")
    streaming_url = settings.streaming_mcp_url.replace("/mcp", "/health")
    services = await asyncio.gather(
        _probe_service("langchain-hana-mcp", langchain_url),
        _probe_service("ai-core-streaming-mcp", streaming_url),
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
    langchain_url = settings.langchain_mcp_url.replace("/mcp", "/health")
    streaming_url = settings.streaming_mcp_url.replace("/mcp", "/health")
    results = await asyncio.gather(
        _probe_service("langchain-hana-mcp", langchain_url),
        _probe_service("ai-core-streaming-mcp", streaming_url),
    )
    return list(results)


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
