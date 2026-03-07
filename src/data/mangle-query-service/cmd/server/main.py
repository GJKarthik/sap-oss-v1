"""
Production-Ready Server Entry Point.

Main server with:
- FastAPI application
- Graceful shutdown
- Signal handling
- Health checks
- Metrics endpoint
- MCP server integration
"""

import asyncio
import logging
import os
import signal
import sys
from contextlib import asynccontextmanager
from datetime import datetime
from typing import Any, Dict, List, Optional

import uvicorn
from fastapi import FastAPI, HTTPException, Request, Response, Depends
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

# Configure logging first
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
LOG_FORMAT = os.getenv("LOG_FORMAT", "json")

if LOG_FORMAT == "json":
    import json
    
    class JsonFormatter(logging.Formatter):
        def format(self, record):
            log_data = {
                "timestamp": datetime.utcnow().isoformat() + "Z",
                "level": record.levelname,
                "logger": record.name,
                "message": record.getMessage(),
            }
            if record.exc_info:
                log_data["exception"] = self.formatException(record.exc_info)
            return json.dumps(log_data)
    
    handler = logging.StreamHandler()
    handler.setFormatter(JsonFormatter())
    logging.root.handlers = [handler]
else:
    logging.basicConfig(
        level=LOG_LEVEL,
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
    )

logging.getLogger().setLevel(LOG_LEVEL)
logger = logging.getLogger(__name__)


# ============================================================================
# Request/Response Models
# ============================================================================

class QueryRequest(BaseModel):
    """Query request model."""
    query: str = Field(..., description="Query text")
    k: int = Field(5, ge=1, le=100, description="Number of results")
    table_name: Optional[str] = Field(None, description="Target table")
    filters: Optional[Dict[str, Any]] = Field(None, description="Metadata filters")
    client_id: Optional[str] = Field(None, description="Client identifier")
    include_metadata: bool = Field(True, description="Include document metadata")


class QueryResponse(BaseModel):
    """Query response model."""
    query: str
    results: List[Dict[str, Any]]
    latency_ms: float
    cache_hit: bool = False
    path_used: str = "unknown"
    rewritten_query: Optional[str] = None


class HealthResponse(BaseModel):
    """Health check response."""
    status: str
    timestamp: str
    services: Dict[str, Any]
    version: str = "1.0.0"


class StatsResponse(BaseModel):
    """Statistics response."""
    cache: Dict[str, Any]
    circuit_breaker: Dict[str, Any]
    rate_limiter: Dict[str, Any]
    router: Dict[str, Any]
    tracing: Dict[str, Any]


# ============================================================================
# Application Lifecycle
# ============================================================================

class ApplicationState:
    """Global application state."""
    
    def __init__(self):
        self.running = True
        self.startup_time = datetime.utcnow()
        self.shutdown_event = asyncio.Event()
        
        # Components (lazy initialized)
        self._cache = None
        self._circuit_breaker = None
        self._rate_limiter = None
        self._health_monitor = None
        self._router = None
        self._rewriter = None
        self._reranker = None
        self._bridge = None
        self._tracer = None
        self._metrics = None
    
    async def initialize(self) -> None:
        """Initialize all components."""
        logger.info("Initializing application components...")
        
        try:
            # Initialize in order of dependency
            
            # 1. Observability first
            from observability.hana_tracing import get_tracer
            from observability.hana_metrics import get_metrics_registry
            
            self._tracer = get_tracer()
            self._tracer.initialize()
            
            self._metrics = get_metrics_registry()
            
            logger.info("Observability initialized")
            
            # 2. Core components
            from performance.hana_semantic_cache import get_semantic_cache
            from middleware.hana_circuit_breaker import get_hana_circuit_breaker
            from middleware.rate_limiter import get_rate_limiter
            from middleware.health_monitor import setup_default_health_checks
            
            self._cache = await get_semantic_cache()
            self._circuit_breaker = await get_hana_circuit_breaker()
            self._rate_limiter = await get_rate_limiter()
            self._health_monitor = await setup_default_health_checks()
            
            logger.info("Core components initialized")
            
            # 3. Intelligence components
            from intelligence.adaptive_router import get_adaptive_router
            from intelligence.query_rewriter import get_query_rewriter
            from intelligence.reranker import get_reranker
            
            self._router = await get_adaptive_router()
            self._rewriter = await get_query_rewriter()
            self._reranker = await get_reranker()
            
            logger.info("Intelligence components initialized")
            
            # 4. HANA Bridge (with warmup)
            from connectors.langchain_hana_bridge import get_bridge
            from connectors.batch_embeddings import warmup_connections
            
            self._bridge = get_bridge()
            
            if os.getenv("HANA_HOST"):
                if await self._bridge.initialize():
                    logger.info("HANA bridge initialized")
                    
                    # Warm up connections
                    warmup_result = await warmup_connections(pool_size=3)
                    logger.info(f"Connection warmup: {warmup_result}")
                else:
                    logger.warning("HANA bridge initialization failed - running in degraded mode")
            else:
                logger.warning("HANA_HOST not set - HANA features disabled")
            
            logger.info("Application initialization complete")
            
        except Exception as e:
            logger.error(f"Initialization error: {e}", exc_info=True)
            raise
    
    async def shutdown(self) -> None:
        """Graceful shutdown."""
        logger.info("Starting graceful shutdown...")
        self.running = False
        
        try:
            # Stop health monitor
            if self._health_monitor:
                await self._health_monitor.stop()
            
            # Export router model for persistence
            if self._router:
                model = await self._router.export_model()
                # TODO: Save to file or external storage
                logger.info("Router model exported")
            
            # Flush caches
            if self._cache:
                stats = self._cache.get_stats()
                logger.info(f"Cache final stats: {stats}")
            
            # Shutdown tracing
            if self._tracer:
                self._tracer.shutdown()
            
            logger.info("Graceful shutdown complete")
            
        except Exception as e:
            logger.error(f"Shutdown error: {e}", exc_info=True)
        
        self.shutdown_event.set()


# Global state
app_state = ApplicationState()


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan manager."""
    # Startup
    await app_state.initialize()
    
    yield
    
    # Shutdown
    await app_state.shutdown()


# ============================================================================
# FastAPI Application
# ============================================================================

app = FastAPI(
    title="Mangle Query Service",
    description="HANA Vector Search with LangChain Integration",
    version="1.0.0",
    lifespan=lifespan,
)

# CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=os.getenv("CORS_ORIGINS", "*").split(","),
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ============================================================================
# Middleware
# ============================================================================

@app.middleware("http")
async def request_middleware(request: Request, call_next):
    """Request middleware for logging and metrics."""
    import time
    
    start_time = time.time()
    request_id = request.headers.get("X-Request-ID", str(id(request)))
    
    # Rate limiting
    if app_state._rate_limiter:
        client_id = request.client.host if request.client else "unknown"
        if not await app_state._rate_limiter.acquire(client_id, wait=False):
            return JSONResponse(
                status_code=429,
                content={"error": "Rate limit exceeded", "retry_after": 60}
            )
    
    try:
        response = await call_next(request)
        
        # Record metrics
        latency_ms = (time.time() - start_time) * 1000
        if app_state._metrics:
            app_state._metrics.record_query(
                operation="http",
                path=request.url.path,
                latency_ms=latency_ms,
                success=response.status_code < 400,
            )
        
        response.headers["X-Request-ID"] = request_id
        response.headers["X-Response-Time"] = f"{latency_ms:.2f}ms"
        
        return response
        
    except Exception as e:
        logger.error(f"Request error: {e}", exc_info=True)
        raise


# ============================================================================
# API Endpoints
# ============================================================================

@app.get("/health", response_model=HealthResponse)
async def health_check():
    """Health check endpoint."""
    services = {}
    
    if app_state._health_monitor:
        health_data = app_state._health_monitor.get_all_health()
        for name, health in health_data.items():
            services[name] = {
                "status": health.status.value,
                "latency_ms": health.latency_ms,
            }
    
    aggregate_status = "healthy"
    if app_state._health_monitor:
        from middleware.health_monitor import HealthStatus
        status = app_state._health_monitor.get_aggregate_status()
        aggregate_status = status.value
    
    return HealthResponse(
        status=aggregate_status,
        timestamp=datetime.utcnow().isoformat() + "Z",
        services=services,
    )


@app.get("/ready")
async def readiness_check():
    """Kubernetes readiness probe."""
    if not app_state.running:
        raise HTTPException(status_code=503, detail="Shutting down")
    
    if app_state._health_monitor:
        from middleware.health_monitor import HealthStatus
        status = app_state._health_monitor.get_aggregate_status()
        if status == HealthStatus.UNHEALTHY:
            raise HTTPException(status_code=503, detail="Service unhealthy")
    
    return {"status": "ready"}


@app.get("/live")
async def liveness_check():
    """Kubernetes liveness probe."""
    return {"status": "alive"}


@app.get("/metrics")
async def metrics():
    """Prometheus metrics endpoint."""
    if app_state._metrics:
        content = app_state._metrics.get_metrics_output()
        return Response(
            content=content,
            media_type=app_state._metrics.get_content_type(),
        )
    return Response(content=b"# Metrics not available\n", media_type="text/plain")


@app.get("/stats", response_model=StatsResponse)
async def get_stats():
    """Get service statistics."""
    return StatsResponse(
        cache=app_state._cache.get_stats() if app_state._cache else {},
        circuit_breaker=app_state._circuit_breaker.get_stats() if app_state._circuit_breaker else {},
        rate_limiter=app_state._rate_limiter.get_stats() if app_state._rate_limiter else {},
        router=app_state._router.get_stats() if app_state._router else {},
        tracing=app_state._tracer.get_metrics() if app_state._tracer else {},
    )


@app.post("/query", response_model=QueryResponse)
async def query(request: QueryRequest):
    """Execute a vector search query."""
    import time
    
    start_time = time.time()
    cache_hit = False
    path_used = "unknown"
    rewritten_query = None
    
    try:
        # 1. Check cache
        if app_state._cache and app_state._bridge:
            embedding = await app_state._bridge.embed_query(request.query)
            cached_result, similarity = await app_state._cache.get(request.query, embedding)
            
            if cached_result:
                cache_hit = True
                latency_ms = (time.time() - start_time) * 1000
                return QueryResponse(
                    query=request.query,
                    results=cached_result.get("results", []),
                    latency_ms=latency_ms,
                    cache_hit=True,
                    path_used="cache",
                )
        
        # 2. Rewrite query
        if app_state._rewriter:
            rewrite_result = await app_state._rewriter.rewrite(request.query)
            rewritten_query = rewrite_result.rewritten
        else:
            rewritten_query = request.query
        
        # 3. Execute search
        results = []
        
        if app_state._bridge:
            # Use circuit breaker
            async def hana_search():
                return await app_state._bridge.similarity_search(
                    rewritten_query,
                    k=request.k,
                    table_name=request.table_name,
                    filter=request.filters,
                )
            
            if app_state._circuit_breaker:
                results = await app_state._circuit_breaker.execute(hana_search)
                path_used = "hana_vector"
            else:
                results = await hana_search()
                path_used = "hana_vector"
        
        # 4. Rerank results
        if app_state._reranker and results:
            ranked_results = await app_state._reranker.rerank(
                request.query,
                [{"content": r.get("page_content", r.get("content", "")), 
                  "metadata": r.get("metadata", {}),
                  "score": r.get("score", 0.5)} for r in results],
            )
            results = [
                {
                    "content": r.content,
                    "metadata": r.metadata if request.include_metadata else {},
                    "score": r.final_score,
                    "rank": r.rank,
                }
                for r in ranked_results
            ]
        
        # 5. Cache result
        if app_state._cache and app_state._bridge and results:
            embedding = await app_state._bridge.embed_query(request.query)
            await app_state._cache.set(
                request.query,
                embedding,
                {"results": results},
            )
        
        latency_ms = (time.time() - start_time) * 1000
        
        return QueryResponse(
            query=request.query,
            results=results,
            latency_ms=latency_ms,
            cache_hit=cache_hit,
            path_used=path_used,
            rewritten_query=rewritten_query if rewritten_query != request.query else None,
        )
        
    except Exception as e:
        logger.error(f"Query error: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))


# ============================================================================
# Signal Handlers
# ============================================================================

def setup_signal_handlers():
    """Setup signal handlers for graceful shutdown."""
    loop = asyncio.get_event_loop()
    
    def signal_handler(signame):
        logger.info(f"Received signal {signame}")
        asyncio.create_task(app_state.shutdown())
    
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, lambda s=sig: signal_handler(s.name))


# ============================================================================
# Main Entry Point
# ============================================================================

def main():
    """Main entry point."""
    host = os.getenv("HOST", "0.0.0.0")
    port = int(os.getenv("PORT", "8080"))
    workers = int(os.getenv("WORKERS", "1"))
    
    logger.info(f"Starting server on {host}:{port}")
    
    # Validate critical configuration
    config_errors = []
    
    if not os.getenv("HANA_HOST"):
        logger.warning("HANA_HOST not configured - HANA features will be disabled")
    
    if config_errors:
        for error in config_errors:
            logger.error(f"Configuration error: {error}")
        sys.exit(1)
    
    uvicorn.run(
        "cmd.server.main:app",
        host=host,
        port=port,
        workers=workers,
        log_level=LOG_LEVEL.lower(),
        access_log=True,
        loop="uvloop" if os.name != "nt" else "asyncio",
    )


if __name__ == "__main__":
    main()