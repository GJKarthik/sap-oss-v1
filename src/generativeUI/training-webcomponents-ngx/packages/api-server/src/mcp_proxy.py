"""
MCP Proxy routes for Training Console.

Proxies JSON-RPC requests from the Angular frontend to two MCP servers:
  - OData Vocabularies MCP (vocab_mcp_url) — SAP vocabulary search, RAG context, annotations
  - LangChain HANA MCP (hana_mcp_url) — HANA vector store, embeddings, SPARQL, analytics

Traffic is centralised through FastAPI so that CORS, correlation IDs, and rate-limiting
apply uniformly to all MCP calls.
"""

import os
from typing import Any, Dict, Optional

import httpx
import structlog
from fastapi import APIRouter, Request, Response
from pydantic import BaseModel

router = APIRouter()
logger = structlog.get_logger("mcp-proxy")

VOCAB_MCP_URL = os.getenv("VOCAB_MCP_URL", "http://localhost:9150/mcp")
HANA_MCP_URL = os.getenv("HANA_MCP_URL", "http://localhost:9140/mcp")

_TIMEOUT = httpx.Timeout(30.0, connect=5.0)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _jsonrpc_error(body: dict, code: int, message: str) -> dict:
    return {
        "jsonrpc": body.get("jsonrpc", "2.0"),
        "id": body.get("id"),
        "error": {"code": code, "message": message},
    }


def _health_url(target_url: str) -> str:
    if target_url.endswith("/mcp"):
        return target_url[: -len("/mcp")] + "/health"
    return target_url.rstrip("/") + "/health"


def _friendly_service_error(service_name: str, status_code: int | None = None) -> str:
    if service_name == "HANA Cloud":
        if status_code in (502, 503, 504) or status_code is None:
            return "HANA Cloud is reconnecting. Please try again in a moment."
    return f"{service_name} is currently unavailable."


def _get_correlation_id(request: Request) -> str:
    return request.headers.get("X-Correlation-ID") or f"training-proxy-{id(request)}"


async def _forward(target_url: str, body: dict, correlation_id: str, service_name: str) -> dict:
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
        return _jsonrpc_error(body, -32001, _friendly_service_error(service_name))
    except httpx.HTTPStatusError as exc:
        logger.error("MCP proxy HTTP error", target=target_url, status=exc.response.status_code)
        return _jsonrpc_error(body, -32002, _friendly_service_error(service_name, exc.response.status_code))
    except httpx.RequestError as exc:
        logger.error("MCP proxy request error", target=target_url, error=str(exc))
        return _jsonrpc_error(body, -32001, _friendly_service_error(service_name))
    except Exception as exc:
        logger.error("MCP proxy unexpected error", target=target_url, error=str(exc))
        return _jsonrpc_error(body, -32000, _friendly_service_error(service_name))


async def _probe_health(service_name: str, target_url: str) -> dict:
    health_url = _health_url(target_url)
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(health_url)
            resp.raise_for_status()
            payload = resp.json()
            if isinstance(payload, dict):
                return {"status": payload.get("status", "ok"), "service": service_name, **payload}
            return {"status": "ok", "service": service_name}
    except Exception as exc:
        logger.warning("MCP health probe failed", service=service_name, error=str(exc))
        return {
            "status": "degraded",
            "service": service_name,
            "error": _friendly_service_error("HANA Cloud" if service_name == "langchain-hana-mcp" else service_name),
        }


# ---------------------------------------------------------------------------
# OData Vocabularies MCP proxy
# ---------------------------------------------------------------------------

@router.post("/vocab", summary="Proxy to OData Vocabularies MCP")
async def vocab_proxy(request: Request):
    """Forward JSON-RPC requests to the OData Vocabularies MCP server."""
    body = await request.json()
    corr_id = _get_correlation_id(request)
    logger.info("MCP proxy -> vocab", method=body.get("method"), correlation_id=corr_id)
    return await _forward(VOCAB_MCP_URL, body, corr_id, "OData vocabularies")


@router.get("/vocab/health", summary="OData Vocabularies MCP health")
async def vocab_health():
    """Probe the OData Vocabularies MCP /health endpoint."""
    return await _probe_health("odata-vocabularies-mcp", VOCAB_MCP_URL)


# ---------------------------------------------------------------------------
# LangChain HANA MCP proxy
# ---------------------------------------------------------------------------

@router.post("/hana", summary="Proxy to LangChain HANA MCP")
async def hana_proxy(request: Request):
    """Forward JSON-RPC requests to the LangChain HANA MCP server."""
    body = await request.json()
    corr_id = _get_correlation_id(request)
    logger.info("MCP proxy -> hana", method=body.get("method"), correlation_id=corr_id)
    return await _forward(HANA_MCP_URL, body, corr_id, "HANA Cloud")


@router.get("/hana/health", summary="LangChain HANA MCP health")
async def hana_health():
    """Probe the LangChain HANA MCP /health endpoint."""
    return await _probe_health("langchain-hana-mcp", HANA_MCP_URL)


# ---------------------------------------------------------------------------
# Aggregated health
# ---------------------------------------------------------------------------

@router.get("/health", summary="Combined MCP health")
async def combined_health():
    """Aggregate health from both MCP backends."""
    vocab = await _probe_health("odata-vocabularies-mcp", VOCAB_MCP_URL)
    hana = await _probe_health("langchain-hana-mcp", HANA_MCP_URL)
    all_healthy = vocab.get("status") not in {"error", "degraded"} and hana.get("status") not in {"error", "degraded"}
    return {
        "status": "healthy" if all_healthy else "degraded",
        "services": {"vocab": vocab, "hana": hana},
    }
