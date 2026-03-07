"""
Unified OpenAI-Compliant Router with Mangle Proxies

All APIs expose OpenAI-compliant endpoints that are routed through
mangle rules to the appropriate backend services.

Request Flow:
1. Client sends OpenAI-compliant request to /v1/chat/completions
2. Mangle router classifies and routes to appropriate backend
3. Response transformed back to OpenAI format
4. Streaming via SSE for real-time responses

Backends (all Mangle-proxied with OpenAI interface):
- elasticsearch-main: Knowledge/RAG queries
- ai-core-pal: LLM inference
- ai-core-streaming: Streaming completions
- odata-vocabularies: Entity metadata
- HANA: Analytical queries
"""

import asyncio
import json
import time
import os
from typing import AsyncIterator, Dict, List, Optional, Any, Union
from dataclasses import dataclass
from datetime import datetime

from fastapi import FastAPI, Request, HTTPException, Depends
from fastapi.responses import StreamingResponse, JSONResponse
from pydantic import BaseModel, Field

# Import intelligence/efficiency modules
from ..intelligence.semantic_classifier import SemanticClassifier, get_semantic_classifier
from ..intelligence.speculative import SpeculativeExecutor, get_speculative_executor
from ..intelligence.adaptive_router import AdaptiveRouter, get_adaptive_router
from ..intelligence.model_selector import AdaptiveModelSelector
from ..efficiency.semantic_cache import SemanticCache, get_semantic_cache
from ..efficiency.batch_client import BatchingClient, get_batching_client
from ..connectors.flight_client import get_flight_client


# ========================================
# OpenAI-Compliant Request/Response Models
# ========================================

class ChatMessage(BaseModel):
    role: str
    content: str
    name: Optional[str] = None


class ChatCompletionRequest(BaseModel):
    """OpenAI-compliant chat completion request."""
    model: str = "gpt-4"
    messages: List[ChatMessage]
    temperature: float = Field(default=0.7, ge=0, le=2)
    top_p: float = Field(default=1, ge=0, le=1)
    n: int = Field(default=1, ge=1, le=10)
    stream: bool = False
    stop: Optional[Union[str, List[str]]] = None
    max_tokens: Optional[int] = None
    presence_penalty: float = Field(default=0, ge=-2, le=2)
    frequency_penalty: float = Field(default=0, ge=-2, le=2)
    user: Optional[str] = None
    
    # SAP-specific extensions
    mangle_route: Optional[str] = None  # Force specific route
    enable_rag: bool = True
    enable_cache: bool = True


class ChatCompletionChoice(BaseModel):
    index: int
    message: ChatMessage
    finish_reason: str


class Usage(BaseModel):
    prompt_tokens: int
    completion_tokens: int
    total_tokens: int


class ChatCompletionResponse(BaseModel):
    """OpenAI-compliant chat completion response."""
    id: str
    object: str = "chat.completion"
    created: int
    model: str
    choices: List[ChatCompletionChoice]
    usage: Usage
    
    # SAP-specific extensions
    mangle_route: Optional[str] = None
    classification: Optional[Dict[str, Any]] = None


class ChatCompletionChunk(BaseModel):
    """OpenAI-compliant streaming chunk."""
    id: str
    object: str = "chat.completion.chunk"
    created: int
    model: str
    choices: List[Dict[str, Any]]


# ========================================
# Mangle-Proxied Backend Clients
# ========================================

@dataclass
class MangleRoute:
    """Route configuration for a mangle proxy."""
    name: str
    endpoint: str
    timeout_seconds: float
    supports_streaming: bool
    model_prefix: str


class MangleProxyRegistry:
    """Registry of all mangle-proxied OpenAI-compliant backends."""
    
    ROUTES: Dict[str, MangleRoute] = {
        "elasticsearch": MangleRoute(
            name="elasticsearch",
            endpoint=os.getenv("ES_OPENAI_ENDPOINT", "http://localhost:9201/v1"),
            timeout_seconds=30.0,
            supports_streaming=True,
            model_prefix="es-",
        ),
        "ai-core-pal": MangleRoute(
            name="ai-core-pal",
            endpoint=os.getenv("AICORE_OPENAI_ENDPOINT", "http://localhost:8080/v1"),
            timeout_seconds=60.0,
            supports_streaming=True,
            model_prefix="aicore-",
        ),
        "ai-core-streaming": MangleRoute(
            name="ai-core-streaming",
            endpoint=os.getenv("STREAMING_OPENAI_ENDPOINT", "http://localhost:8081/v1"),
            timeout_seconds=120.0,
            supports_streaming=True,
            model_prefix="stream-",
        ),
        "odata-vocab": MangleRoute(
            name="odata-vocab",
            endpoint=os.getenv("VOCAB_OPENAI_ENDPOINT", "http://localhost:8082/v1"),
            timeout_seconds=15.0,
            supports_streaming=False,
            model_prefix="vocab-",
        ),
        "hana-analytical": MangleRoute(
            name="hana-analytical",
            endpoint=os.getenv("HANA_OPENAI_ENDPOINT", "http://localhost:8083/v1"),
            timeout_seconds=30.0,
            supports_streaming=False,
            model_prefix="hana-",
        ),
    }
    
    @classmethod
    def get_route(cls, route_name: str) -> Optional[MangleRoute]:
        return cls.ROUTES.get(route_name)
    
    @classmethod
    def route_for_category(cls, category: str) -> MangleRoute:
        """Map classification category to mangle route."""
        mapping = {
            "factual": cls.ROUTES["elasticsearch"],
            "knowledge": cls.ROUTES["elasticsearch"],
            "analytical": cls.ROUTES["hana-analytical"],
            "hierarchy": cls.ROUTES["hana-analytical"],
            "timeseries": cls.ROUTES["hana-analytical"],
            "metadata": cls.ROUTES["odata-vocab"],
            "llm_required": cls.ROUTES["ai-core-pal"],
            "cache": cls.ROUTES["elasticsearch"],  # Semantic cache fallback
        }
        return mapping.get(category, cls.ROUTES["ai-core-pal"])


class MangleProxyClient:
    """
    Client for forwarding requests to mangle-proxied OpenAI-compliant backends.
    All backends expose the same OpenAI API, routed by mangle rules.
    """
    
    def __init__(self):
        # HTTP client would be initialized here (aiohttp, httpx)
        self._sessions: Dict[str, Any] = {}
    
    async def forward_request(
        self,
        route: MangleRoute,
        request: ChatCompletionRequest,
        stream: bool = False,
    ) -> Union[ChatCompletionResponse, AsyncIterator[ChatCompletionChunk]]:
        """Forward OpenAI request to mangle-proxied backend."""
        
        # Transform model name with route prefix
        transformed_request = request.copy()
        if not request.model.startswith(route.model_prefix):
            transformed_request.model = f"{route.model_prefix}{request.model}"
        
        endpoint = f"{route.endpoint}/chat/completions"
        
        # In production, use actual HTTP client
        # For now, return mock response
        if stream:
            return self._stream_mock_response(transformed_request, route)
        else:
            return self._mock_response(transformed_request, route)
    
    def _mock_response(
        self, 
        request: ChatCompletionRequest,
        route: MangleRoute,
    ) -> ChatCompletionResponse:
        """Mock response for development."""
        return ChatCompletionResponse(
            id=f"chatcmpl-{route.name}-{int(time.time())}",
            created=int(time.time()),
            model=request.model,
            choices=[
                ChatCompletionChoice(
                    index=0,
                    message=ChatMessage(
                        role="assistant",
                        content=f"Response from {route.name} backend",
                    ),
                    finish_reason="stop",
                )
            ],
            usage=Usage(prompt_tokens=10, completion_tokens=5, total_tokens=15),
            mangle_route=route.name,
        )
    
    async def _stream_mock_response(
        self,
        request: ChatCompletionRequest,
        route: MangleRoute,
    ) -> AsyncIterator[ChatCompletionChunk]:
        """Mock streaming response for development."""
        chunk_id = f"chatcmpl-{route.name}-{int(time.time())}"
        content = f"Streaming response from {route.name} backend"
        
        for word in content.split():
            yield ChatCompletionChunk(
                id=chunk_id,
                created=int(time.time()),
                model=request.model,
                choices=[{
                    "index": 0,
                    "delta": {"content": word + " "},
                    "finish_reason": None,
                }],
            )
            await asyncio.sleep(0.05)
        
        # Final chunk
        yield ChatCompletionChunk(
            id=chunk_id,
            created=int(time.time()),
            model=request.model,
            choices=[{
                "index": 0,
                "delta": {},
                "finish_reason": "stop",
            }],
        )


# ========================================
# Unified OpenAI Router with Intelligence
# ========================================

class UnifiedMangleRouter:
    """
    Unified router that applies all intelligence/efficiency phases
    and routes to appropriate mangle-proxied OpenAI backend.
    """
    
    def __init__(self):
        self.proxy_client = MangleProxyClient()
        self._classifier: Optional[SemanticClassifier] = None
        self._cache: Optional[SemanticCache] = None
        self._adaptive_router: Optional[AdaptiveRouter] = None
        self._speculative: Optional[SpeculativeExecutor] = None
        self._batcher: Optional[BatchingClient] = None
        
        # Statistics
        self.stats = RouterStats()
    
    async def initialize(self):
        """Initialize all intelligence/efficiency components."""
        self._classifier = await get_semantic_classifier()
        self._cache = await get_semantic_cache()
        self._adaptive_router = await get_adaptive_router()
        self._speculative = await get_speculative_executor()
        self._batcher = await get_batching_client()
    
    async def route_completion(
        self,
        request: ChatCompletionRequest,
    ) -> Union[ChatCompletionResponse, AsyncIterator[ChatCompletionChunk]]:
        """
        Route a chat completion request through the intelligence pipeline
        to the appropriate mangle-proxied OpenAI backend.
        """
        start_time = time.time()
        
        # Extract query from messages
        query = self._extract_query(request)
        
        # Phase 1: Check semantic cache
        if request.enable_cache and self._cache:
            cached = await self._cache.get(query)
            if cached:
                self.stats.cache_hits += 1
                return self._create_response_from_cache(cached, request)
        
        # Phase 2: Classify query
        classification = await self._classify_query(query, request)
        
        # Phase 3: Select route (adaptive)
        route = await self._select_route(classification, request)
        
        # Phase 4: Forward to backend
        if request.stream and route.supports_streaming:
            return self._stream_with_cache(
                self.proxy_client.forward_request(route, request, stream=True),
                query,
                classification,
            )
        else:
            response = await self.proxy_client.forward_request(route, request)
            
            # Cache the response
            if request.enable_cache and self._cache:
                await self._cache.put(query, classification, response)
            
            # Record feedback for adaptive routing
            if self._adaptive_router:
                latency_ms = (time.time() - start_time) * 1000
                await self._adaptive_router.record_feedback(
                    classification,
                    route.name,
                    success=True,
                    latency_ms=latency_ms,
                )
            
            # Add classification info
            response.classification = classification
            response.mangle_route = route.name
            
            self.stats.requests_routed += 1
            return response
    
    async def _classify_query(
        self,
        query: str,
        request: ChatCompletionRequest,
    ) -> Dict[str, Any]:
        """Classify query using semantic classifier."""
        if request.mangle_route:
            # Forced route - skip classification
            return {"category": request.mangle_route, "confidence": 100}
        
        if self._classifier:
            return await self._classifier.classify(query)
        
        # Default classification
        return {"category": "llm_required", "confidence": 50}
    
    async def _select_route(
        self,
        classification: Dict[str, Any],
        request: ChatCompletionRequest,
    ) -> MangleRoute:
        """Select route using adaptive router."""
        if request.mangle_route:
            # Forced route
            route = MangleProxyRegistry.get_route(request.mangle_route)
            if route:
                return route
        
        # Get candidates based on category
        category = classification.get("category", "llm_required")
        default_route = MangleProxyRegistry.route_for_category(category)
        
        # Adaptive selection from candidates
        if self._adaptive_router:
            candidates = [r.name for r in MangleProxyRegistry.ROUTES.values()]
            selected, confidence = await self._adaptive_router.select_route(
                classification, candidates
            )
            route = MangleProxyRegistry.get_route(selected)
            if route:
                return route
        
        return default_route
    
    async def _stream_with_cache(
        self,
        stream: AsyncIterator[ChatCompletionChunk],
        query: str,
        classification: Dict[str, Any],
    ) -> AsyncIterator[ChatCompletionChunk]:
        """Stream response and cache complete result."""
        content_buffer = []
        
        async for chunk in stream:
            # Accumulate content
            if chunk.choices and chunk.choices[0].get("delta", {}).get("content"):
                content_buffer.append(chunk.choices[0]["delta"]["content"])
            
            yield chunk
        
        # Cache complete response
        if self._cache and content_buffer:
            complete_content = "".join(content_buffer)
            # Create cache entry
            # await self._cache.put(query, classification, complete_content)
    
    def _extract_query(self, request: ChatCompletionRequest) -> str:
        """Extract the query from messages."""
        for msg in reversed(request.messages):
            if msg.role == "user":
                return msg.content
        return ""
    
    def _create_response_from_cache(
        self,
        cached: Any,
        request: ChatCompletionRequest,
    ) -> ChatCompletionResponse:
        """Create response from cached data."""
        return ChatCompletionResponse(
            id=f"chatcmpl-cache-{int(time.time())}",
            created=int(time.time()),
            model=request.model,
            choices=[
                ChatCompletionChoice(
                    index=0,
                    message=ChatMessage(
                        role="assistant",
                        content=cached.get("content", ""),
                    ),
                    finish_reason="stop",
                )
            ],
            usage=Usage(prompt_tokens=0, completion_tokens=0, total_tokens=0),
            mangle_route="cache",
        )


@dataclass
class RouterStats:
    """Statistics for the unified router."""
    requests_routed: int = 0
    cache_hits: int = 0
    classification_time_ms: float = 0
    avg_latency_ms: float = 0


# ========================================
# FastAPI Application
# ========================================

app = FastAPI(
    title="SAP Mangle Query Service - OpenAI Compatible API",
    description="Unified OpenAI-compatible API with mangle-proxied routing",
    version="1.0.0",
)

# Global router instance
_router: Optional[UnifiedMangleRouter] = None


async def get_router() -> UnifiedMangleRouter:
    global _router
    if _router is None:
        _router = UnifiedMangleRouter()
        await _router.initialize()
    return _router


@app.post("/v1/chat/completions")
async def chat_completions(
    request: ChatCompletionRequest,
    router: UnifiedMangleRouter = Depends(get_router),
):
    """
    OpenAI-compatible chat completions endpoint.
    
    All requests are classified and routed through mangle proxies
    to the appropriate backend service.
    """
    try:
        result = await router.route_completion(request)
        
        if request.stream:
            async def generate():
                async for chunk in result:
                    yield f"data: {chunk.json()}\n\n"
                yield "data: [DONE]\n\n"
            
            return StreamingResponse(
                generate(),
                media_type="text/event-stream",
            )
        else:
            return JSONResponse(content=result.dict())
            
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/v1/models")
async def list_models():
    """List available models across all mangle-proxied backends."""
    models = []
    
    for route_name, route in MangleProxyRegistry.ROUTES.items():
        models.append({
            "id": f"{route.model_prefix}gpt-4",
            "object": "model",
            "created": int(time.time()),
            "owned_by": f"sap-{route_name}",
            "permission": [],
            "root": route_name,
            "parent": None,
        })
    
    return {"object": "list", "data": models}


@app.get("/v1/routes")
async def list_routes():
    """List all mangle-proxied routes (SAP extension)."""
    return {
        "routes": [
            {
                "name": route.name,
                "endpoint": route.endpoint,
                "supports_streaming": route.supports_streaming,
                "model_prefix": route.model_prefix,
            }
            for route in MangleProxyRegistry.ROUTES.values()
        ]
    }


@app.get("/v1/stats")
async def get_stats(router: UnifiedMangleRouter = Depends(get_router)):
    """Get router statistics (SAP extension)."""
    return {
        "requests_routed": router.stats.requests_routed,
        "cache_hits": router.stats.cache_hits,
        "avg_latency_ms": router.stats.avg_latency_ms,
    }


@app.get("/health")
async def health():
    """Health check endpoint."""
    return {
        "status": "healthy",
        "service": "mangle-query-service",
        "api_version": "v1",
        "openai_compatible": True,
    }


# ========================================
# Startup/Shutdown
# ========================================

@app.on_event("startup")
async def startup():
    """Initialize router on startup."""
    router = await get_router()
    print("Unified Mangle Router initialized")
    print(f"Available routes: {list(MangleProxyRegistry.ROUTES.keys())}")


@app.on_event("shutdown")
async def shutdown():
    """Cleanup on shutdown."""
    global _router
    _router = None