"""
Training Console API Server
Thin FastAPI proxy/wrapper around the nvidia-modelopt service on port 8001.
Adds CORS for the Angular dev server on port 4200.
"""

import json
import os
from contextlib import asynccontextmanager
from typing import Any

import asyncio
from datetime import datetime
import httpx
from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from slowapi.util import get_remote_address
from prometheus_fastapi_instrumentator import Instrumentator
from prometheus_client import Gauge

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
# Rate limiter & Logging
# ---------------------------------------------------------------------------

limiter = Limiter(key_func=get_remote_address)

import structlog
import time

structlog.configure(
    processors=[
        structlog.stdlib.add_log_level,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.JSONRenderer()
    ],
    context_class=dict,
    logger_factory=structlog.stdlib.LoggerFactory(),
    wrapper_class=structlog.stdlib.BoundLogger,
    cache_logger_on_first_use=True,
)
logger = structlog.get_logger("training-console")


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

# Prometheus standard HTTP instrumentation
Instrumentator().instrument(app).expose(app)

ACTIVE_WEBSOCKETS = Gauge("active_websocket_connections", "Number of currently active WebSocket consumers")

app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.middleware("http")
async def security_headers_middleware(request: Request, call_next):
    response = await call_next(request)
    response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Content-Security-Policy"] = "default-src 'self' 'unsafe-inline' 'unsafe-eval' data:; connect-src 'self' ws: wss: http: https:;"
    return response

@app.middleware("http")
async def structlog_middleware(request: Request, call_next):
    start_time = time.time()
    try:
        response = await call_next(request)
        process_time = time.time() - start_time
        logger.info("request_completed", method=request.method, path=request.url.path, status=response.status_code, duration_s=round(process_time, 4))
        return response
    except Exception as e:
        process_time = time.time() - start_time
        logger.exception("request_failed", method=request.method, path=request.url.path, error=str(e), duration_s=round(process_time, 4))
        raise


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    ACTIVE_WEBSOCKETS.inc()
    try:
        progress = 0.0
        history = []
        epoch_count = 0
        train_loss = 2.5
        val_loss = 2.6
        
        while True:
            progress = min(1.0, progress + 0.05)
            epoch_count += 1
            train_loss = max(0.2, train_loss * 0.9)
            val_loss = max(0.25, val_loss * 0.92 + 0.05 * (-1 if epoch_count % 2 == 0 else 1))
            
            history.append({
                "epoch": epoch_count,
                "train_loss": round(train_loss, 4),
                "val_loss": round(val_loss, 4)
            })

            gpu_data = {
                "type": "gpu",
                "data": {
                    "gpu_name": "NVIDIA T4 (Live)",
                    "total_memory_gb": 16.0,
                    "used_memory_gb": 5.2 + (progress * 2),
                    "free_memory_gb": 10.8 - (progress * 2),
                    "utilization_percent": int(30 + (progress * 50)),
                    "temperature_c": 50 + int(progress * 20),
                    "driver_version": "535.0",
                    "cuda_version": "12.2"
                }
            }
            job_data = {
                "type": "jobs",
                "data": [
                    {
                        "id": "job-live",
                        "name": "Live Job Optimization",
                        "status": "running" if progress < 1.0 else "completed",
                        "progress": progress,
                        "created_at": datetime.now().isoformat(),
                        "config": {"model_name": "Qwen", "quant_format": "int4", "export_format": "hf"},
                        "history": history
                    }
                ]
            }
            await websocket.send_json(gpu_data)
            await websocket.send_json(job_data)
            
            if progress >= 1.0:
                progress = 0.0  # Reset for infinite loop demo
                history = []
                epoch_count = 0
                train_loss = 2.5
                val_loss = 2.6
                
            await asyncio.sleep(2)
    except WebSocketDisconnect:
        pass
    finally:
        ACTIVE_WEBSOCKETS.dec()


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "healthy", "service": "training-console-api", "upstream": UPSTREAM}


async def _proxy(request: Request, path: str) -> JSONResponse:
    body = await request.body()

    if len(body) > MAX_BODY_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"Request body exceeds limit of {MAX_BODY_BYTES // (1024 * 1024)} MB",
        )

    if _client is None:
        raise HTTPException(status_code=503, detail="Proxy client not initialised")

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
