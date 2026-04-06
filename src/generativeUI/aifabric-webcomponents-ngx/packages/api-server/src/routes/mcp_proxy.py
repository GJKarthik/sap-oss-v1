"""
MCP Proxy routes for SAP AI Fabric Console.

Proxies JSON-RPC requests from the Angular frontend to the MCP servers:
  - Elasticsearch MCP (elasticsearch_mcp_url) - search and indexing operations
  - AI Core PAL MCP (pal_mcp_url) - analytics and orchestration tools
  - Data Cleaning Copilot MCP (data_cleaning_mcp_url) - Data quality validation

This centralises all traffic through the FastAPI backend so that:
  1. Auth is enforced on every MCP call (Bearer token validated here).
  2. A single CORS origin (FastAPI port 8000) is needed by the browser.
  3. Correlation IDs are forwarded / generated consistently.
  4. Future rate-limiting, audit logging and retries apply uniformly.
"""

from collections import defaultdict, deque
import json
import time
from typing import Any, Dict, Optional

import httpx
from prometheus_client import Counter, Gauge
import structlog
from fastapi import APIRouter, Depends, Request, Response
from pydantic import BaseModel
from starlette.requests import ClientDisconnect

from ..config import settings
from ..routes.auth import UserInfo, get_current_user

router = APIRouter()
logger = structlog.get_logger()

_TIMEOUT = httpx.Timeout(30.0, connect=5.0)
MCP_PROXY_EVENTS_TOTAL = Counter(
    "sap_aifabric_mcp_proxy_events_total",
    "MCP proxy request and health probe events by service and result.",
    ["service", "result"],
)
MCP_UPSTREAM_HEALTH = Gauge(
    "sap_aifabric_mcp_upstream_health",
    "Current upstream MCP health status, 1 when healthy and 0 when unhealthy.",
    ["service"],
)
_MCP_FAILURE_TIMESTAMPS: dict[str, deque[float]] = defaultdict(lambda: deque(maxlen=1024))


# ---------------------------------------------------------------------------
# Pydantic schemas
# ---------------------------------------------------------------------------

class MCPRequest(BaseModel):
    jsonrpc: str = "2.0"
    id: int
    method: str
    params: Dict[str, Any] = {}


class MCPResponse(BaseModel):
    jsonrpc: str
    id: int
    result: Optional[Any] = None
    error: Optional[Dict[str, Any]] = None


# ---------------------------------------------------------------------------
# Proxy helper
# ---------------------------------------------------------------------------

def _jsonrpc_error(body: dict, code: int, message: str) -> dict:
    return {
        "jsonrpc": body.get("jsonrpc", "2.0"),
        "id": body.get("id"),
        "error": {
            "code": code,
            "message": message,
        },
    }


def _describe_exception(exc: Exception) -> str:
    return str(exc) or exc.__class__.__name__


def _service_name(target_url: str) -> str:
    if target_url == settings.elasticsearch_mcp_url:
        return "elasticsearch-mcp"
    if target_url == settings.pal_mcp_url:
        return "ai-core-pal-mcp"
    if target_url == settings.data_cleaning_mcp_url:
        return "data-cleaning-copilot-mcp"
    return target_url


def _record_mcp_event(service_name: str, result: str, *, healthy: bool | None = None) -> None:
    MCP_PROXY_EVENTS_TOTAL.labels(service_name, result).inc()
    if healthy is not None:
        MCP_UPSTREAM_HEALTH.labels(service_name).set(1 if healthy else 0)
    if result not in {"request_success", "health_success"}:
        _MCP_FAILURE_TIMESTAMPS[service_name].append(time.time())


def recent_mcp_failures(window_seconds: int) -> dict[str, int]:
    cutoff = time.time() - max(window_seconds, 1)
    snapshot: dict[str, int] = {}
    for service_name, timestamps in _MCP_FAILURE_TIMESTAMPS.items():
        while timestamps and timestamps[0] < cutoff:
            timestamps.popleft()
        snapshot[service_name] = len(timestamps)
    return snapshot


def mcp_metrics_snapshot(window_seconds: int) -> dict:
    services = ("elasticsearch-mcp", "ai-core-pal-mcp", "data-cleaning-copilot-mcp")
    recent_failures = recent_mcp_failures(window_seconds)
    return {
        "recent_failures": recent_failures,
        "services": {
            service_name: {
                "request_successes_total": float(
                    MCP_PROXY_EVENTS_TOTAL.labels(service_name, "request_success")._value.get()
                ),
                "request_failures_total": sum(
                    float(MCP_PROXY_EVENTS_TOTAL.labels(service_name, result)._value.get())
                    for result in (
                        "connect_error",
                        "http_error",
                        "request_error",
                        "unexpected_error",
                        "health_error",
                    )
                ),
                "healthy": bool(MCP_UPSTREAM_HEALTH.labels(service_name)._value.get()),
            }
            for service_name in services
        },
    }


def _health_url(target_url: str) -> str:
    if target_url.endswith("/mcp"):
        return target_url[: -len("/mcp")] + "/health"
    return target_url.rstrip("/") + "/health"


async def _read_json_body(request: Request) -> dict | None:
    try:
        return await request.json()
    except ClientDisconnect:
        logger.info("MCP proxy client disconnected before request body was read", path=request.url.path)
        return None


def _upstream_headers(target_url: str, correlation_id: str) -> dict[str, str]:
    headers = {
        "Content-Type": "application/json",
        "X-Correlation-ID": correlation_id,
    }
    if target_url == settings.elasticsearch_mcp_url and settings.elasticsearch_mcp_api_key:
        headers["Authorization"] = f"ApiKey {settings.elasticsearch_mcp_api_key}"
    if target_url == settings.pal_mcp_url and settings.pal_mcp_bearer_token:
        headers["Authorization"] = f"Bearer {settings.pal_mcp_bearer_token}"
    return headers


async def _forward(target_url: str, body: dict, correlation_id: str) -> dict:
    """Forward a JSON-RPC body to the target MCP server and return its response."""
    service_name = _service_name(target_url)
    headers = _upstream_headers(target_url, correlation_id)
    try:
        async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
            resp = await client.post(target_url, json=body, headers=headers)
            resp.raise_for_status()
            _record_mcp_event(service_name, "request_success")
            return resp.json()
    except httpx.ConnectError as exc:
        error = _describe_exception(exc)
        logger.error("MCP proxy connect error", target=target_url, error=error)
        _record_mcp_event(service_name, "connect_error")
        return _jsonrpc_error(
            body,
            -32001,
            f"Cannot reach MCP service at {target_url}: {error}",
        )
    except httpx.HTTPStatusError as exc:
        logger.error("MCP proxy HTTP error", target=target_url, status=exc.response.status_code)
        _record_mcp_event(service_name, "http_error")
        return _jsonrpc_error(
            body,
            -32002,
            f"MCP service returned {exc.response.status_code}",
        )
    except httpx.RequestError as exc:
        error = _describe_exception(exc)
        logger.error("MCP proxy request error", target=target_url, error=error)
        _record_mcp_event(service_name, "request_error")
        return _jsonrpc_error(
            body,
            -32001,
            f"Cannot reach MCP service at {target_url}: {error}",
        )
    except Exception as exc:
        error = _describe_exception(exc)
        logger.error("MCP proxy unexpected error", target=target_url, error=error)
        _record_mcp_event(service_name, "unexpected_error")
        return _jsonrpc_error(
            body,
            -32000,
            f"MCP proxy error: {error}",
        )


def _parse_tool_result(response: dict) -> Any:
    if response.get("error"):
        message = response["error"].get("message", "Unknown MCP tool error")
        raise RuntimeError(message)
    result = response.get("result")
    if not isinstance(result, dict):
        return result
    content = result.get("content")
    if isinstance(content, list) and content:
        text = content[0].get("text")
        if isinstance(text, str):
            try:
                return json.loads(text)
            except json.JSONDecodeError:
                return text
    return result


async def call_tool(target_url: str, tool_name: str, arguments: dict[str, Any], correlation_id: str) -> Any:
    response = await _forward(
        target_url,
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": tool_name,
                "arguments": arguments,
            },
        },
        correlation_id,
    )
    return _parse_tool_result(response)


async def list_tools(target_url: str, correlation_id: str) -> list[dict[str, Any]]:
    response = await _forward(
        target_url,
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
            "params": {},
        },
        correlation_id,
    )
    if response.get("error"):
        message = response["error"].get("message", "Unknown MCP list-tools error")
        raise RuntimeError(message)
    tools = response.get("result", {}).get("tools", [])
    return tools if isinstance(tools, list) else []


async def probe_health(service_name: str, target_url: str, timeout_seconds: float = 5.0) -> dict:
    health_url = _health_url(target_url)
    try:
        async with httpx.AsyncClient(timeout=timeout_seconds) as client:
            resp = await client.get(health_url)
            resp.raise_for_status()
            payload = resp.json()
            _record_mcp_event(service_name, "health_success", healthy=True)
            if isinstance(payload, dict):
                return {
                    "status": payload.get("status", "ok"),
                    "service": service_name,
                    "target": health_url,
                    **payload,
                }
            return {
                "status": "ok",
                "service": service_name,
                "target": health_url,
                "payload": payload,
            }
    except Exception as exc:
        error = _describe_exception(exc)
        logger.warning("MCP health probe failed", service=service_name, target=health_url, error=error)
        _record_mcp_event(service_name, "health_error", healthy=False)
        return {
            "status": "error",
            "service": service_name,
            "target": health_url,
            "error": error,
        }


def _get_correlation_id(request: Request, counter: int = 0) -> str:
    return request.headers.get("X-Correlation-ID") or f"api-proxy-{id(request)}-{counter}"


# ---------------------------------------------------------------------------
# Elasticsearch MCP proxy
# ---------------------------------------------------------------------------

@router.post("/elasticsearch", summary="Proxy to Elasticsearch MCP")
async def elasticsearch_proxy(
    request: Request,
    _: UserInfo = Depends(get_current_user),
):
    """
    Forward JSON-RPC requests to the Elasticsearch MCP server.
    Auth is enforced here — the downstream MCP server need not check tokens.
    """
    body = await _read_json_body(request)
    if body is None:
        return Response(status_code=204)
    corr_id = _get_correlation_id(request)
    logger.info(
        "MCP proxy → elasticsearch",
        method=body.get("method"),
        correlation_id=corr_id,
    )
    return await _forward(settings.elasticsearch_mcp_url, body, corr_id)


@router.get("/elasticsearch/health", summary="Elasticsearch MCP health")
async def elasticsearch_health(_: UserInfo = Depends(get_current_user)):
    """Probe the Elasticsearch MCP /health endpoint."""
    return await probe_health(
        service_name="elasticsearch-mcp",
        target_url=settings.elasticsearch_mcp_url,
        timeout_seconds=settings.mcp_healthcheck_timeout_seconds,
    )


# ---------------------------------------------------------------------------
# AI Core PAL MCP proxy
# ---------------------------------------------------------------------------

@router.post("/pal", summary="Proxy to AI Core PAL MCP")
async def pal_proxy(
    request: Request,
    _: UserInfo = Depends(get_current_user),
):
    """
    Forward JSON-RPC requests to the AI Core PAL MCP server.
    Auth is enforced here — the downstream MCP server need not check tokens.
    """
    body = await _read_json_body(request)
    if body is None:
        return Response(status_code=204)
    corr_id = _get_correlation_id(request)
    logger.info(
        "MCP proxy → pal",
        method=body.get("method"),
        correlation_id=corr_id,
    )
    return await _forward(settings.pal_mcp_url, body, corr_id)


@router.get("/pal/health", summary="PAL MCP health")
async def pal_health(_: UserInfo = Depends(get_current_user)):
    """Probe the AI Core PAL MCP /health endpoint."""
    return await probe_health(
        service_name="ai-core-pal-mcp",
        target_url=settings.pal_mcp_url,
        timeout_seconds=settings.mcp_healthcheck_timeout_seconds,
    )


# ---------------------------------------------------------------------------
# Data Cleaning Copilot MCP proxy
# ---------------------------------------------------------------------------

@router.post("/data-cleaning", summary="Proxy to Data Cleaning Copilot MCP")
async def data_cleaning_proxy(
    request: Request,
    _: UserInfo = Depends(get_current_user),
):
    """
    Forward JSON-RPC requests to the Data Cleaning Copilot MCP server.
    Auth is enforced here — the downstream MCP server need not check tokens.
    
    Available tools:
    - data_quality_check: Run data quality checks on a table
    - schema_analysis: Analyze database schema for quality recommendations
    - data_profiling: Generate statistical profile of table data
    - anomaly_detection: Detect anomalies in column data
    - generate_cleaning_query: Generate SQL to fix data issues (requires approval)
    - ai_chat: General AI assistance
    - mangle_query: Query Mangle fact store for governance rules
    - kuzu_index: Index schema into graph database
    - kuzu_query: Query relationship graph
    """
    body = await _read_json_body(request)
    if body is None:
        return Response(status_code=204)
    corr_id = _get_correlation_id(request)
    logger.info(
        "MCP proxy → data-cleaning",
        method=body.get("method"),
        correlation_id=corr_id,
    )
    return await _forward(settings.data_cleaning_mcp_url, body, corr_id)


@router.get("/data-cleaning/health", summary="Data Cleaning Copilot MCP health")
async def data_cleaning_health(_: UserInfo = Depends(get_current_user)):
    """Probe the Data Cleaning Copilot MCP /health endpoint."""
    return await probe_health(
        service_name="data-cleaning-copilot-mcp",
        target_url=settings.data_cleaning_mcp_url,
        timeout_seconds=settings.mcp_healthcheck_timeout_seconds,
    )
