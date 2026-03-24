"""
MCP Proxy routes for SAP AI Fabric Console.

Proxies JSON-RPC requests from the Angular frontend to the two MCP servers:
  - LangChain HANA MCP  (langchain_mcp_url)
  - AI Core Streaming MCP (streaming_mcp_url)

This centralises all traffic through the FastAPI backend so that:
  1. Auth is enforced on every MCP call (Bearer token validated here).
  2. A single CORS origin (FastAPI port 8000) is needed by the browser.
  3. Correlation IDs are forwarded / generated consistently.
  4. Future rate-limiting, audit logging and retries apply uniformly.
"""

from typing import Any, Dict, Optional

import httpx
import structlog
from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel

from ..config import settings
from ..routes.auth import UserInfo, get_current_user

router = APIRouter()
logger = structlog.get_logger()

_TIMEOUT = httpx.Timeout(30.0, connect=5.0)


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


async def _forward(target_url: str, body: dict, correlation_id: str) -> dict:
    """Forward a JSON-RPC body to the target MCP server and return its response."""
    headers = {
        "Content-Type": "application/json",
        "X-Correlation-ID": correlation_id,
    }
    try:
        async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
            resp = await client.post(target_url, json=body, headers=headers)
            resp.raise_for_status()
            return resp.json()
    except httpx.ConnectError as exc:
        logger.error("MCP proxy connect error", target=target_url, error=str(exc))
        return _jsonrpc_error(
            body,
            -32001,
            f"Cannot reach MCP service at {target_url}: {exc}",
        )
    except httpx.HTTPStatusError as exc:
        logger.error("MCP proxy HTTP error", target=target_url, status=exc.response.status_code)
        return _jsonrpc_error(
            body,
            -32002,
            f"MCP service returned {exc.response.status_code}",
        )
    except Exception as exc:
        logger.error("MCP proxy unexpected error", target=target_url, error=str(exc))
        return _jsonrpc_error(
            body,
            -32000,
            f"MCP proxy error: {exc}",
        )


def _get_correlation_id(request: Request, counter: int = 0) -> str:
    return request.headers.get("X-Correlation-ID") or f"api-proxy-{id(request)}-{counter}"


# ---------------------------------------------------------------------------
# LangChain HANA MCP proxy
# ---------------------------------------------------------------------------

@router.post("/langchain", summary="Proxy to LangChain HANA MCP")
async def langchain_proxy(
    request: Request,
    _: UserInfo = Depends(get_current_user),
):
    """
    Forward JSON-RPC requests to the LangChain HANA MCP server.
    Auth is enforced here — the downstream MCP server need not check tokens.
    """
    body = await request.json()
    corr_id = _get_correlation_id(request)
    logger.info(
        "MCP proxy → langchain",
        method=body.get("method"),
        correlation_id=corr_id,
    )
    return await _forward(settings.langchain_mcp_url, body, corr_id)


@router.get("/langchain/health", summary="LangChain MCP health")
async def langchain_health(_: UserInfo = Depends(get_current_user)):
    """Probe the LangChain HANA MCP /health endpoint."""
    health_url = settings.langchain_mcp_url.replace("/mcp", "/health")
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(health_url)
            resp.raise_for_status()
            return resp.json()
    except Exception as exc:
        return {"status": "error", "service": "langchain-hana-mcp", "error": str(exc)}


# ---------------------------------------------------------------------------
# AI Core Streaming MCP proxy
# ---------------------------------------------------------------------------

@router.post("/streaming", summary="Proxy to AI Core Streaming MCP")
async def streaming_proxy(
    request: Request,
    _: UserInfo = Depends(get_current_user),
):
    """
    Forward JSON-RPC requests to the AI Core Streaming MCP server.
    Auth is enforced here — the downstream MCP server need not check tokens.
    """
    body = await request.json()
    corr_id = _get_correlation_id(request)
    logger.info(
        "MCP proxy → streaming",
        method=body.get("method"),
        correlation_id=corr_id,
    )
    return await _forward(settings.streaming_mcp_url, body, corr_id)


@router.get("/streaming/health", summary="Streaming MCP health")
async def streaming_health(_: UserInfo = Depends(get_current_user)):
    """Probe the AI Core Streaming MCP /health endpoint."""
    health_url = settings.streaming_mcp_url.replace("/mcp", "/health")
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(health_url)
            resp.raise_for_status()
            return resp.json()
    except Exception as exc:
        return {"status": "error", "service": "ai-core-streaming-mcp", "error": str(exc)}
