"""
Training Console API Server
Thin FastAPI proxy/wrapper around the nvidia-modelopt service on port 8001.
Adds CORS for the Angular dev server on port 4200.
"""

import json
import os
from contextlib import asynccontextmanager
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from slowapi.util import get_remote_address

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

UPSTREAM = os.getenv("MODELOPT_URL", "http://localhost:8001")
MAX_BODY_BYTES = int(os.getenv("MAX_BODY_BYTES", str(10 * 1024 * 1024)))  # 10 MB default
PROXY_RATE_LIMIT = os.getenv("PROXY_RATE_LIMIT", "60/minute")

_allowed_origins_raw = os.getenv(
    "ALLOWED_ORIGINS",
    "http://localhost:4200,http://localhost:4201",
)
ALLOWED_ORIGINS: list[str] = [o.strip() for o in _allowed_origins_raw.split(",") if o.strip()]

_client: httpx.AsyncClient | None = None

# ---------------------------------------------------------------------------
# Rate limiter
# ---------------------------------------------------------------------------

limiter = Limiter(key_func=get_remote_address)


# ---------------------------------------------------------------------------
# App lifecycle
# ---------------------------------------------------------------------------

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

app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "healthy", "service": "training-console-api", "upstream": UPSTREAM}


async def _proxy(request: Request, path: str) -> JSONResponse:
    if _client is None:
        raise HTTPException(status_code=503, detail="Proxy client not initialised")

    body = await request.body()

    if len(body) > MAX_BODY_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"Request body exceeds limit of {MAX_BODY_BYTES // (1024 * 1024)} MB",
        )

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
    except json.JSONDecodeError:
        data = upstream_resp.text

    return JSONResponse(content=data, status_code=upstream_resp.status_code)


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"])
@limiter.limit(PROXY_RATE_LIMIT)
async def proxy_all(request: Request, path: str) -> JSONResponse:
    return await _proxy(request, path)


if __name__ == "__main__":
    import uvicorn

    port = int(os.getenv("PORT", "8000"))
    host = os.getenv("HOST", "0.0.0.0")
    uvicorn.run(app, host=host, port=port)
