"""
agent/btp_server_client.py

HTTP client for the elastic-chili-claw server's BTP REST endpoints:
  GET  /api/integrations/hana/btp/registry   — querySchemaRegistry
  POST /api/integrations/hana/btp/search     — searchSchemaRegistry (ES + HANA fan-out)
  POST /api/integrations/hana/btp/apply      — applyBtpSchema (DDL bootstrap)

Environment variables:
  BTP_SERVER_URL  — base URL of the elastic-chili-claw server
                    (default: http://localhost:8080)
  BTP_API_KEY     — value for X-Api-Key header (optional)
"""
from __future__ import annotations

import json
import os
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

def _server_url() -> str:
    return os.environ.get("BTP_SERVER_URL", "http://localhost:8080").rstrip("/")


def _headers() -> Dict[str, str]:
    h = {"Content-Type": "application/json", "Accept": "application/json"}
    api_key = os.environ.get("BTP_API_KEY", "")
    if api_key:
        h["X-Api-Key"] = api_key
    return h


# ---------------------------------------------------------------------------
# Low-level HTTP helpers
# ---------------------------------------------------------------------------

def _get(path: str, params: Optional[Dict[str, str]] = None, timeout: int = 30) -> Any:
    url = _server_url() + path
    if params:
        url = url + "?" + urllib.parse.urlencode({k: v for k, v in params.items() if v is not None})
    req = urllib.request.Request(url, headers=_headers(), method="GET")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def _post(path: str, body: Dict[str, Any], timeout: int = 60) -> Any:
    url = _server_url() + path
    data = json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, headers=_headers(), method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


# ---------------------------------------------------------------------------
# BTP endpoint wrappers
# ---------------------------------------------------------------------------

def registry_query(
    domain: Optional[str] = None,
    source_table: Optional[str] = None,
    wide_table: Optional[str] = None,
    limit: int = 200,
    offset: int = 0,
) -> Dict[str, Any]:
    """
    GET /api/integrations/hana/btp/registry

    Returns: {"fields": [...], "total": int}
    Each field: registry_id, domain, source_table, field_name, hana_type,
                description, wide_table
    """
    try:
        params: Dict[str, str] = {"limit": str(limit), "offset": str(offset)}
        if domain:
            params["domain"] = domain
        if source_table:
            params["sourceTable"] = source_table
        if wide_table:
            params["wideTable"] = wide_table
        return _get("/api/integrations/hana/btp/registry", params)
    except Exception as exc:
        return {"error": str(exc), "fields": [], "total": 0}


def search(
    query: str,
    domain: Optional[str] = None,
    wide_table: Optional[str] = None,
    limit: int = 50,
) -> Dict[str, Any]:
    """
    POST /api/integrations/hana/btp/search

    Fans out to both Elasticsearch (semantic) and HANA SCHEMA_REGISTRY (exact).
    Returns: {"es": [...], "hana": [...], "query": str}
    """
    try:
        body: Dict[str, Any] = {"query": query, "limit": limit}
        if domain:
            body["domain"] = domain
        if wide_table:
            body["wideTable"] = wide_table
        return _post("/api/integrations/hana/btp/search", body)
    except Exception as exc:
        return {"error": str(exc), "es": [], "hana": [], "query": query}


def apply_schema(timeout: int = 300) -> Dict[str, Any]:
    """
    POST /api/integrations/hana/btp/apply

    Triggers DDL bootstrap of BTP.sql against the connected HANA instance.
    Returns: {"statements_attempted": int, "statements_ok": int,
              "statements_skipped": int, "errors": [...]}
    """
    try:
        return _post("/api/integrations/hana/btp/apply", {}, timeout=timeout)
    except Exception as exc:
        return {"error": str(exc)}


def health_check() -> bool:
    """Return True if the server is reachable."""
    try:
        _get("/healthz", timeout=5)
        return True
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Convenience: list distinct domains from the registry
# ---------------------------------------------------------------------------

def list_domains(limit: int = 500) -> List[str]:
    """Return distinct domain values from the BTP schema registry."""
    result = registry_query(limit=limit)
    fields: List[Dict[str, Any]] = result.get("fields", [])
    return sorted({f["domain"] for f in fields if f.get("domain")})


def list_wide_tables(limit: int = 500) -> List[str]:
    """Return distinct wide_table values from the BTP schema registry."""
    result = registry_query(limit=limit)
    fields: List[Dict[str, Any]] = result.get("fields", [])
    return sorted({f["wide_table"] for f in fields if f.get("wide_table")})
