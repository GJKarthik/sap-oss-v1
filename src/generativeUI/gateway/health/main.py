from __future__ import annotations

import asyncio
import os
from typing import Any

import httpx
from fastapi import FastAPI, Response

app = FastAPI(title="suite-health-aggregator", version="1.0.0")


def env(name: str, default: str) -> str:
    return os.getenv(name, default).strip()


CHECKS: list[tuple[str, str, bool]] = [
    ("aifabric_web", env("AIFABRIC_WEB_HEALTH_URL", "http://aifabric-web/health"), True),
    ("aifabric_api", env("AIFABRIC_API_HEALTH_URL", "http://aifabric-api/health"), True),
    ("training_web", env("TRAINING_WEB_HEALTH_URL", "http://training-web/"), True),
    ("training_api", env("TRAINING_API_HEALTH_URL", "http://training-api/health"), True),
    ("sac_web", env("SAC_WEB_HEALTH_URL", "http://sac-web/health"), False),
    ("ui5_web", env("UI5_WEB_HEALTH_URL", "http://ui5-web/health"), False),
    ("ui5_mcp", env("UI5_MCP_HEALTH_URL", "http://ui5-mcp:9160/health"), False),
    ("cap_llm_openai", env("CAP_LLM_HEALTH_URL", "http://cap-llm-plugin:8080/health"), False),
    ("ui5_harness", env("UI5_HARNESS_REPORT_URL", "http://ui5-web/health"), False),
]

optional_external_pal = env("AI_CORE_PAL_HEALTH_URL", "")
optional_external_es_mcp = env("ES_MCP_HEALTH_URL", "")

if optional_external_pal:
    CHECKS.append(("ai_core_pal", optional_external_pal, False))
if optional_external_es_mcp:
    CHECKS.append(("es_mcp", optional_external_es_mcp, False))


async def probe(client: httpx.AsyncClient, name: str, url: str, required: bool) -> dict[str, Any]:
    try:
        resp = await client.get(url)
        body: Any
        try:
            body = resp.json()
        except Exception:
            body = resp.text[:300]
        ok = 200 <= resp.status_code < 300
        return {
            "name": name,
            "url": url,
            "required": required,
            "ok": ok,
            "status_code": resp.status_code,
            "details": body,
        }
    except Exception as exc:
        return {
            "name": name,
            "url": url,
            "required": required,
            "ok": False,
            "status_code": 0,
            "details": str(exc),
        }


async def run_checks() -> dict[str, Any]:
    async with httpx.AsyncClient(timeout=3.0, follow_redirects=True) as client:
        results = await asyncio.gather(
            *(probe(client, name, url, required) for name, url, required in CHECKS)
        )
    required_failures = [item for item in results if item["required"] and not item["ok"]]
    return {
        "status": "ok" if not required_failures else "degraded",
        "required_failures": len(required_failures),
        "checks": results,
    }


@app.get("/health")
async def health() -> dict[str, Any]:
    return {"suite": "sap-ai-open-source-suite", "status": "healthy"}


@app.get("/live")
async def live() -> dict[str, Any]:
    return {"suite": "sap-ai-open-source-suite", "status": "healthy"}


@app.get("/ready")
async def ready(response: Response) -> dict[str, Any]:
    summary = await run_checks()
    response.status_code = 200 if summary["status"] == "ok" else 503
    return {"suite": "sap-ai-open-source-suite", **summary}


@app.get("/health/details")
async def health_details(response: Response) -> dict[str, Any]:
    summary = await run_checks()
    response.status_code = 200 if summary["status"] == "ok" else 503
    return {"suite": "sap-ai-open-source-suite", **summary}


@app.get("/ready/details")
async def ready_details(response: Response) -> dict[str, Any]:
    summary = await run_checks()
    response.status_code = 200 if summary["status"] == "ok" else 503
    return {"suite": "sap-ai-open-source-suite", **summary}
