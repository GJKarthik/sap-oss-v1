"""
SAP AI Fabric Console - API Server
FastAPI Backend with SAP AI Core + HANA Cloud.
Configurable shared state store with SQLite for local development and SAP HANA Cloud for production persistence.
"""

from contextlib import asynccontextmanager

import structlog
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from prometheus_fastapi_instrumentator import Instrumentator

from .config import settings
from .database import close_database, init_database
from .routes import auth, models, rag, deployments, datasources, lineage, governance, metrics, mcp_proxy
from .seed import seed_store
from .store import get_store

# ---------------------------------------------------------------------------
# Structured logging
# ---------------------------------------------------------------------------

structlog.configure(
    processors=[
        structlog.stdlib.filter_by_level,
        structlog.stdlib.add_logger_name,
        structlog.stdlib.add_log_level,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.JSONRenderer(),
    ],
    wrapper_class=structlog.stdlib.BoundLogger,
    context_class=dict,
    logger_factory=structlog.stdlib.LoggerFactory(),
    cache_logger_on_first_use=True,
)

logger = structlog.get_logger()
SECURITY_HEADERS = {
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
    "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
    "Cross-Origin-Resource-Policy": "same-origin",
}


# ---------------------------------------------------------------------------
# Lifespan
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifecycle: initialise the persistent store and seed baseline data."""
    logger.info("Starting SAP AI Fabric Console API Server", environment=settings.environment)
    await init_database()
    seed_store()
    store = get_store()
    logger.info(
        "Persistent store initialised and seeded",
        store_backend=store.backend_name,
        connection_target=store.connection_target,
    )
    yield
    await close_database()
    logger.info("Shutting down SAP AI Fabric Console API Server")


# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------

app = FastAPI(
    title="SAP AI Fabric Console API",
    description="Backend API for SAP AI Fabric Console — SAP AI Core + HANA Cloud, configurable shared persistence backend",
    version="1.0.0",
    lifespan=lifespan,
    docs_url="/api/docs" if settings.expose_api_docs else None,
    redoc_url="/api/redoc" if settings.expose_api_docs else None,
    openapi_url="/api/openapi.json" if settings.expose_api_docs else None,
)

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type", "X-Correlation-ID", "Accept"],
)

# Prometheus metrics
Instrumentator().instrument(app).expose(app, endpoint="/metrics")


def _apply_security_headers(response, request_path: str) -> None:
    for header, value in SECURITY_HEADERS.items():
        response.headers.setdefault(header, value)

    if request_path.startswith("/api/v1/auth/"):
        response.headers.setdefault("Cache-Control", "no-store")


def _rate_limit_policy(path: str) -> tuple[str, int, str] | None:
    if path in {"/api/v1/auth/login", "/api/v1/auth/refresh"}:
        return ("auth", settings.auth_rate_limit_per_minute, "Too many authentication attempts")
    if path.startswith("/api/v1/mcp/"):
        return ("mcp", settings.mcp_rate_limit_per_minute, "Too many MCP proxy requests")
    return None


@app.middleware("http")
async def security_headers_middleware(request: Request, call_next):
    response = await call_next(request)
    _apply_security_headers(response, request.url.path)
    return response


@app.middleware("http")
async def rate_limit_middleware(request: Request, call_next):
    policy = _rate_limit_policy(request.url.path)
    if policy is not None:
        scope, limit, message = policy
        bucket_ip = request.client.host if request.client else "unknown"
        bucket_key = f"{scope}:{bucket_ip}"
        result = get_store().consume_rate_limit(
            bucket_key=bucket_key,
            limit=limit,
            window_seconds=settings.rate_limit_window_seconds,
        )
        if not result["allowed"]:
            response = JSONResponse(
                status_code=429,
                content={"detail": message},
            )
            response.headers["Retry-After"] = str(result["retry_after"])
            response.headers["X-RateLimit-Limit"] = str(result["limit"])
            response.headers["X-RateLimit-Remaining"] = str(result["remaining"])
            _apply_security_headers(response, request.url.path)
            return response

        response = await call_next(request)
        response.headers["X-RateLimit-Limit"] = str(result["limit"])
        response.headers["X-RateLimit-Remaining"] = str(result["remaining"])
        return response

    return await call_next(request)


def _store_health_snapshot() -> dict:
    store = get_store()
    snapshot = {
        "store": "ok",
        "store_backend": store.backend_name,
        "connection_target": store.connection_target,
        "users": store.count("users"),
        "models": store.count("models"),
        "governance_rules": store.count("governance_rules"),
    }
    if store.database_path is not None:
        snapshot["database_path"] = str(store.database_path)
    return snapshot

# Routers
app.include_router(auth.router, prefix="/api/v1/auth", tags=["Authentication"])
app.include_router(models.router, prefix="/api/v1/models", tags=["Models"])
app.include_router(rag.router, prefix="/api/v1/rag", tags=["RAG"])
app.include_router(deployments.router, prefix="/api/v1/deployments", tags=["Deployments"])
app.include_router(datasources.router, prefix="/api/v1/datasources", tags=["Data Sources"])
app.include_router(lineage.router, prefix="/api/v1/lineage", tags=["Lineage"])
app.include_router(governance.router, prefix="/api/v1/governance", tags=["Governance"])
app.include_router(metrics.router, prefix="/api/v1/metrics", tags=["Metrics"])
app.include_router(mcp_proxy.router, prefix="/api/v1/mcp", tags=["MCP Proxy"])


# ---------------------------------------------------------------------------
# Root / health
# ---------------------------------------------------------------------------

@app.get("/")
async def root():
    return {
        "service": "SAP AI Fabric Console API",
        "version": "1.0.0",
        "status": "healthy",
        "docs": app.docs_url,
    }


@app.get("/health")
async def health_check():
    """Liveness probe — always healthy as long as the process is running."""
    checks: dict = {
        "api": "ok",
        **_store_health_snapshot(),
    }
    return {"status": "healthy", "checks": checks}


@app.get("/ready")
async def readiness_check():
    """Readiness probe — verifies the persistent store is usable."""
    try:
        checks = {
            "api": "ok",
            **_store_health_snapshot(),
            "docs_exposed": bool(app.docs_url),
        }
        return {"status": "ready", "checks": checks}
    except Exception as exc:
        logger.error("Readiness check failed", error=str(exc))
        return JSONResponse(
            status_code=503,
            content={
                "status": "not_ready",
                "checks": {
                    "api": "ok",
                    "store": "error",
                    "error": str(exc),
                },
            },
        )


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "main:app",
        host=settings.host,
        port=settings.port,
        reload=settings.debug,
        log_level=settings.log_level.lower(),
    )
