"""
Metrics and dashboard statistics routes for SAP AI Fabric Console.
"""

from typing import Any, Dict

from fastapi import APIRouter
from pydantic import BaseModel

router = APIRouter()


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

class DashboardStats(BaseModel):
    services_healthy: int = 0
    total_services: int = 2
    active_deployments: int = 0
    total_deployments: int = 0
    active_streams: int = 0
    total_streams: int = 0
    vector_stores: int = 0
    documents_indexed: int = 0


class ServiceMetrics(BaseModel):
    requests_total: int = 0
    requests_per_second: float = 0.0
    latency_p50_ms: float = 0.0
    latency_p99_ms: float = 0.0
    error_rate: float = 0.0


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@router.get("/dashboard", response_model=DashboardStats)
async def dashboard_stats():
    """Aggregate dashboard statistics."""
    # In production, aggregate from real services
    return DashboardStats()


@router.get("/services")
async def service_metrics() -> Dict[str, ServiceMetrics]:
    """Per-service metrics."""
    return {
        "langchain-hana-mcp": ServiceMetrics(),
        "ai-core-streaming-mcp": ServiceMetrics(),
    }


@router.get("/usage")
async def usage_metrics():
    """Usage metrics for billing and capacity planning."""
    return {
        "total_requests_24h": 0,
        "total_tokens_24h": 0,
        "unique_users_24h": 0,
        "top_models": [],
    }
