"""
SAP AI Fabric Console - API Server
FastAPI Backend for real data integrations
"""

from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from prometheus_fastapi_instrumentator import Instrumentator
import structlog

from .routes import auth, models, rag, deployments, datasources, lineage, governance, metrics
from .config import settings

# Configure structured logging
structlog.configure(
    processors=[
        structlog.stdlib.filter_by_level,
        structlog.stdlib.add_logger_name,
        structlog.stdlib.add_log_level,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.JSONRenderer()
    ],
    wrapper_class=structlog.stdlib.BoundLogger,
    context_class=dict,
    logger_factory=structlog.stdlib.LoggerFactory(),
    cache_logger_on_first_use=True,
)

logger = structlog.get_logger()


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifecycle management."""
    logger.info("Starting SAP AI Fabric Console API Server")
    
    # Initialize connections on startup
    # await init_database()
    # await init_redis()
    # await init_k8s_client()
    
    yield
    
    # Cleanup on shutdown
    logger.info("Shutting down SAP AI Fabric Console API Server")
    # await close_database()
    # await close_redis()


# Create FastAPI app
app = FastAPI(
    title="SAP AI Fabric Console API",
    description="Backend API for SAP AI Fabric Console - Real integrations with KServe, HANA, Kubernetes",
    version="1.0.0",
    lifespan=lifespan,
    docs_url="/api/docs",
    redoc_url="/api/redoc",
    openapi_url="/api/openapi.json",
)

# CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Prometheus metrics instrumentation
Instrumentator().instrument(app).expose(app, endpoint="/metrics")

# Include routers
app.include_router(auth.router, prefix="/api/v1/auth", tags=["Authentication"])
app.include_router(models.router, prefix="/api/v1/models", tags=["Models"])
app.include_router(rag.router, prefix="/api/v1/rag", tags=["RAG"])
app.include_router(deployments.router, prefix="/api/v1/deployments", tags=["Deployments"])
app.include_router(datasources.router, prefix="/api/v1/datasources", tags=["Data Sources"])
app.include_router(lineage.router, prefix="/api/v1/lineage", tags=["Lineage"])
app.include_router(governance.router, prefix="/api/v1/governance", tags=["Governance"])
app.include_router(metrics.router, prefix="/api/v1/metrics", tags=["Metrics"])


@app.get("/")
async def root():
    """Root endpoint."""
    return {
        "service": "SAP AI Fabric Console API",
        "version": "1.0.0",
        "status": "healthy",
        "docs": "/api/docs"
    }


@app.get("/health")
async def health_check():
    """Health check endpoint for Kubernetes probes."""
    return {
        "status": "healthy",
        "checks": {
            "api": "ok",
            # "database": await check_database(),
            # "redis": await check_redis(),
            # "kubernetes": await check_k8s(),
        }
    }


@app.get("/ready")
async def readiness_check():
    """Readiness check for Kubernetes."""
    return {"status": "ready"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=8000,
        reload=True,
        log_level="info"
    )