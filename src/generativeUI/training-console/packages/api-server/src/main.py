"""
Training Console API Server
Thin FastAPI proxy/wrapper around the nvidia-modelopt service on port 8001.
Adds CORS for the Angular dev server on port 4200.
"""

from contextlib import asynccontextmanager
import os
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

UPSTREAM = os.getenv("MODELOPT_URL", "http://localhost:8001")

_allowed_origins_raw = os.getenv(
    "ALLOWED_ORIGINS",
    "http://localhost:4200,http://localhost:4201",
)
ALLOWED_ORIGINS: list[str] = [o.strip() for o in _allowed_origins_raw.split(",") if o.strip()]

_client: httpx.AsyncClient | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):  # type: ignore[type-arg]
    global _client
    _client = httpx.AsyncClient(base_url=UPSTREAM, timeout=120.0)
    yield
    await _client.aclose()


app = FastAPI(
    title="Training Console API",
    description="Proxy to nvidia-modelopt service with CORS for Angular shell",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "healthy", "service": "training-console-api", "upstream": UPSTREAM}


async def _proxy(request: Request, path: str) -> JSONResponse:
    if _client is None:
        raise HTTPException(status_code=503, detail="Proxy client not initialised")

    body = await request.body()
    headers = {
        k: v
        for k, v in request.headers.items()
        if k.lower() not in {"host", "content-length"}
    }

    try:
        upstream_resp = await _client.request(
            method=request.method,
            url=f"/{path}",
            content=body,
            headers=headers,
            params=dict(request.query_params),
        )
    except httpx.ConnectError:
        raise HTTPException(
            status_code=502,
            detail=f"Cannot connect to upstream at {UPSTREAM}. Is nvidia-modelopt running?",
        )

    try:
        data: Any = upstream_resp.json()
    except Exception:
        data = upstream_resp.text

    return JSONResponse(content=data, status_code=upstream_resp.status_code)


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"])
async def proxy_all(request: Request, path: str) -> JSONResponse:
    return await _proxy(request, path)


if __name__ == "__main__":
    import uvicorn

    port = int(os.getenv("PORT", "8000"))
    uvicorn.run(app, host="0.0.0.0", port=port)
