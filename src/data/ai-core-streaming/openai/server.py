"""
SAP AI Core Streaming - OpenAI-Compatible Server
Exposes /v1/chat/completions, /v1/completions, /v1/embeddings, /v1/models

Deploy as KServe InferenceService on SAP AI Core.
"""

import os
import json
import time
import uuid
import asyncio
from typing import Any, Dict, List, Optional
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, Response, HTTPException, Header
from fastapi.responses import StreamingResponse, JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from .router import MeshRouter
from .chat_completions import ChatCompletionsHandler
from .completions import CompletionsHandler
from .embeddings import EmbeddingsHandler
from .models import ModelsHandler


# Environment configuration
AI_CORE_URL = os.getenv("AI_CORE_URL", "https://api.ai.prod.eu-central-1.aws.ml.hana.ondemand.com")
AI_CORE_CLIENT_ID = os.getenv("AI_CORE_CLIENT_ID", "")
AI_CORE_CLIENT_SECRET = os.getenv("AI_CORE_CLIENT_SECRET", "")
AI_CORE_RESOURCE_GROUP = os.getenv("AI_CORE_RESOURCE_GROUP", "default")
VLLM_URL = os.getenv("VLLM_URL", "http://localhost:8000")
PORT = int(os.getenv("PORT", "8080"))


# Request/Response models (OpenAI-compatible)
class Message(BaseModel):
    role: str
    content: str
    name: Optional[str] = None
    tool_calls: Optional[List[Dict]] = None
    tool_call_id: Optional[str] = None


class ChatCompletionRequest(BaseModel):
    model: str
    messages: List[Message]
    temperature: Optional[float] = 1.0
    top_p: Optional[float] = 1.0
    n: Optional[int] = 1
    stream: Optional[bool] = False
    stop: Optional[List[str]] = None
    max_tokens: Optional[int] = None
    presence_penalty: Optional[float] = 0
    frequency_penalty: Optional[float] = 0
    logit_bias: Optional[Dict[str, float]] = None
    user: Optional[str] = None
    tools: Optional[List[Dict]] = None
    tool_choice: Optional[Any] = None


class CompletionRequest(BaseModel):
    model: str
    prompt: str
    temperature: Optional[float] = 1.0
    top_p: Optional[float] = 1.0
    n: Optional[int] = 1
    stream: Optional[bool] = False
    stop: Optional[List[str]] = None
    max_tokens: Optional[int] = 16
    presence_penalty: Optional[float] = 0
    frequency_penalty: Optional[float] = 0
    logit_bias: Optional[Dict[str, float]] = None
    user: Optional[str] = None


class EmbeddingRequest(BaseModel):
    model: str
    input: Any  # str or List[str]
    encoding_format: Optional[str] = "float"
    user: Optional[str] = None


# Lifespan for startup/shutdown
@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    print(f"Starting OpenAI-compatible server on port {PORT}")
    print(f"AI Core URL: {AI_CORE_URL}")
    print(f"Resource Group: {AI_CORE_RESOURCE_GROUP}")
    yield
    # Shutdown
    print("Shutting down server")


# Create FastAPI app
app = FastAPI(
    title="SAP AI Core Streaming - OpenAI API",
    description="OpenAI-compatible API for SAP AI Core with smart routing",
    version="1.0.0",
    lifespan=lifespan,
    docs_url="/docs",
    openapi_url="/openapi.json"
)

# CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Initialize handlers
router = MeshRouter()
router.BACKENDS = {
    "ai-core-streaming": AI_CORE_URL,
    "vllm": VLLM_URL
}
chat_handler = ChatCompletionsHandler(router)
completions_handler = CompletionsHandler(router)
embeddings_handler = EmbeddingsHandler(router)
models_handler = ModelsHandler()


# Health check endpoints (KServe compatible)
@app.get("/health")
@app.get("/healthz")
@app.get("/ready")
@app.get("/readyz")
async def health():
    """Health check endpoint for KServe."""
    return {"status": "healthy", "timestamp": time.time()}


@app.get("/v1/health")
async def health_v1():
    """Health check under v1 prefix."""
    return {"status": "healthy", "timestamp": time.time()}


# Models endpoint
@app.get("/v1/models")
async def list_models():
    """List available models (OpenAI-compatible)."""
    return {
        "object": "list",
        "data": [
            {"id": "gpt-4", "object": "model", "owned_by": "ai-core", "permission": []},
            {"id": "gpt-4-turbo", "object": "model", "owned_by": "ai-core", "permission": []},
            {"id": "gpt-3.5-turbo", "object": "model", "owned_by": "ai-core", "permission": []},
            {"id": "claude-3-sonnet", "object": "model", "owned_by": "ai-core", "permission": []},
            {"id": "claude-3-opus", "object": "model", "owned_by": "ai-core", "permission": []},
            {"id": "text-embedding-ada-002", "object": "model", "owned_by": "ai-core", "permission": []},
            {"id": "text-embedding-3-small", "object": "model", "owned_by": "ai-core", "permission": []},
            {"id": "llama-3.1-70b", "object": "model", "owned_by": "vllm", "permission": []},
            {"id": "llama-3.1-8b", "object": "model", "owned_by": "vllm", "permission": []},
            {"id": "mistral-7b", "object": "model", "owned_by": "vllm", "permission": []},
        ]
    }


@app.get("/v1/models/{model_id}")
async def get_model(model_id: str):
    """Get model details (OpenAI-compatible)."""
    return {
        "id": model_id,
        "object": "model",
        "owned_by": "ai-core",
        "permission": []
    }


# Chat completions endpoint
def _extract_trace_id(traceparent: Optional[str], correlation_id: Optional[str]) -> Optional[str]:
    """Extract trace ID from W3C traceparent header or X-Correlation-ID."""
    if traceparent:
        parts = traceparent.split("-")
        if len(parts) >= 2:
            return parts[1]
    return correlation_id


@app.post("/v1/chat/completions")
async def chat_completions(
    request: ChatCompletionRequest,
    x_mesh_service: Optional[str] = Header(None, alias="X-Mesh-Service"),
    x_mesh_security_class: Optional[str] = Header(None, alias="X-Mesh-Security-Class"),
    x_mesh_routing: Optional[str] = Header(None, alias="X-Mesh-Routing"),
    traceparent: Optional[str] = Header(None),
    x_correlation_id: Optional[str] = Header(None, alias="X-Correlation-ID"),
):
    """
    OpenAI-compatible chat completions endpoint.

    Supports streaming via SSE when stream=true.
    Routes to AI Core or vLLM based on governance rules.
    """
    trace_id = _extract_trace_id(traceparent, x_correlation_id)
    headers = {
        "X-Mesh-Service": x_mesh_service,
        "X-Mesh-Security-Class": x_mesh_security_class,
        "X-Mesh-Routing": x_mesh_routing,
    }
    headers = {k: v for k, v in headers.items() if v is not None}

    # Convert to dict for handler
    req_dict = request.model_dump(exclude_none=True)
    req_dict["messages"] = [m.model_dump(exclude_none=True) for m in request.messages]

    if request.stream:
        return StreamingResponse(
            stream_chat_completion(req_dict, headers, trace_id=trace_id),
            media_type="text/event-stream"
        )

    response = await chat_handler.handle(req_dict, headers)

    if "error" in response:
        raise HTTPException(
            status_code=response["error"].get("code", 500),
            detail=response["error"]["message"]
        )

    return response


async def stream_chat_completion(request: Dict, headers: Dict, trace_id: Optional[str] = None):
    """Generate SSE stream for chat completion."""
    request_id = f"chatcmpl-{uuid.uuid4().hex[:24]}"
    model = request.get("model", "gpt-4")

    # Route to determine backend
    backend, endpoint, reason = router.route(
        request,
        service_id=headers.get("X-Mesh-Service"),
        security_class=headers.get("X-Mesh-Security-Class"),
        force_backend=headers.get("X-Mesh-Routing"),
        trace_id=trace_id,
    )
    router.log_routing(request_id, backend, reason, model, "streaming", trace_id=trace_id)
    
    # For demo, yield mock streaming response
    # In production, this would proxy to backend SSE
    content = "Hello! I'm an AI assistant running on SAP AI Core. How can I help you today?"
    
    for i, char in enumerate(content):
        chunk = {
            "id": request_id,
            "object": "chat.completion.chunk",
            "created": int(time.time()),
            "model": model,
            "choices": [{
                "index": 0,
                "delta": {"content": char} if i > 0 else {"role": "assistant", "content": char},
                "finish_reason": None
            }]
        }
        yield f"data: {json.dumps(chunk)}\n\n"
        await asyncio.sleep(0.02)  # Simulate streaming
    
    # Final chunk
    final_chunk = {
        "id": request_id,
        "object": "chat.completion.chunk",
        "created": int(time.time()),
        "model": model,
        "choices": [{
            "index": 0,
            "delta": {},
            "finish_reason": "stop"
        }]
    }
    yield f"data: {json.dumps(final_chunk)}\n\n"
    yield "data: [DONE]\n\n"


# Completions endpoint (legacy)
@app.post("/v1/completions")
async def completions(
    request: CompletionRequest,
    x_mesh_service: Optional[str] = Header(None, alias="X-Mesh-Service"),
    x_mesh_security_class: Optional[str] = Header(None, alias="X-Mesh-Security-Class"),
    x_mesh_routing: Optional[str] = Header(None, alias="X-Mesh-Routing"),
):
    """
    OpenAI-compatible completions endpoint (legacy).
    
    Use /v1/chat/completions for new applications.
    """
    headers = {
        "X-Mesh-Service": x_mesh_service,
        "X-Mesh-Security-Class": x_mesh_security_class,
        "X-Mesh-Routing": x_mesh_routing,
    }
    headers = {k: v for k, v in headers.items() if v is not None}
    
    req_dict = request.model_dump(exclude_none=True)
    
    if request.stream:
        return StreamingResponse(
            stream_completion(req_dict, headers),
            media_type="text/event-stream"
        )
    
    response = await completions_handler.handle(req_dict, headers)
    
    if "error" in response:
        raise HTTPException(
            status_code=response["error"].get("code", 500),
            detail=response["error"]["message"]
        )
    
    return response


async def stream_completion(request: Dict, headers: Dict):
    """Generate SSE stream for completion."""
    request_id = f"cmpl-{uuid.uuid4().hex[:24]}"
    model = request.get("model", "gpt-3.5-turbo-instruct")
    
    # Mock streaming
    content = "This is a completion response from SAP AI Core."
    
    for char in content:
        chunk = {
            "id": request_id,
            "object": "text_completion",
            "created": int(time.time()),
            "model": model,
            "choices": [{
                "text": char,
                "index": 0,
                "logprobs": None,
                "finish_reason": None
            }]
        }
        yield f"data: {json.dumps(chunk)}\n\n"
        await asyncio.sleep(0.02)
    
    # Final chunk
    final_chunk = {
        "id": request_id,
        "object": "text_completion",
        "created": int(time.time()),
        "model": model,
        "choices": [{
            "text": "",
            "index": 0,
            "logprobs": None,
            "finish_reason": "stop"
        }]
    }
    yield f"data: {json.dumps(final_chunk)}\n\n"
    yield "data: [DONE]\n\n"


# Embeddings endpoint
@app.post("/v1/embeddings")
async def embeddings(
    request: EmbeddingRequest,
    x_mesh_service: Optional[str] = Header(None, alias="X-Mesh-Service"),
    x_mesh_security_class: Optional[str] = Header(None, alias="X-Mesh-Security-Class"),
    x_mesh_routing: Optional[str] = Header(None, alias="X-Mesh-Routing"),
):
    """
    OpenAI-compatible embeddings endpoint.
    
    Generates vector embeddings for text input.
    """
    headers = {
        "X-Mesh-Service": x_mesh_service,
        "X-Mesh-Security-Class": x_mesh_security_class,
        "X-Mesh-Routing": x_mesh_routing,
    }
    headers = {k: v for k, v in headers.items() if v is not None}
    
    req_dict = request.model_dump(exclude_none=True)
    
    response = await embeddings_handler.handle(req_dict, headers)
    
    if "error" in response:
        raise HTTPException(
            status_code=response["error"].get("code", 500),
            detail=response["error"]["message"]
        )
    
    return response


# Routing info endpoint (SAP extension)
@app.get("/v1/routing/info")
async def routing_info():
    """Get routing configuration (SAP extension)."""
    return {
        "backends": router.BACKENDS,
        "security_routing": router.SECURITY_ROUTING,
        "model_backend": router.MODEL_BACKEND,
        "service_routing": router.SERVICE_ROUTING
    }


@app.get("/v1/routing/audit")
async def routing_audit():
    """Get routing audit log (SAP extension)."""
    return {
        "audit_log": router.get_audit_log()
    }


# Run server
if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=PORT)