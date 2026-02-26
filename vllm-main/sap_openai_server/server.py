#!/usr/bin/env python3
"""
SAP OpenAI-Compatible Server for vLLM

Provides a full OpenAI-compatible API that routes to SAP AI Core.
Can be used as a drop-in replacement for the vLLM server endpoint.

Usage:
    python -m sap_openai_server.server
    # or
    uvicorn sap_openai_server.server:app --port 8000
"""

import os
import json
import uuid
import time
import urllib.request
import urllib.parse
from typing import List, Dict, Any, Optional, Union
from dataclasses import dataclass, asdict
from functools import lru_cache

# Try FastAPI first, fall back to Flask
try:
    from fastapi import FastAPI, HTTPException, Request
    from fastapi.responses import StreamingResponse, JSONResponse
    from pydantic import BaseModel
    USE_FASTAPI = True
except ImportError:
    USE_FASTAPI = False

# =============================================================================
# Configuration
# =============================================================================

@dataclass
class AICoreConfig:
    """SAP AI Core configuration from environment variables."""
    client_id: str
    client_secret: str
    auth_url: str
    base_url: str
    resource_group: str = "default"
    chat_deployment_id: Optional[str] = None
    embedding_deployment_id: Optional[str] = None

    @classmethod
    def from_env(cls) -> "AICoreConfig":
        return cls(
            client_id=os.environ.get("AICORE_CLIENT_ID", ""),
            client_secret=os.environ.get("AICORE_CLIENT_SECRET", ""),
            auth_url=os.environ.get("AICORE_AUTH_URL", ""),
            base_url=os.environ.get("AICORE_BASE_URL", os.environ.get("AICORE_SERVICE_URL", "")),
            resource_group=os.environ.get("AICORE_RESOURCE_GROUP", "default"),
            chat_deployment_id=os.environ.get("AICORE_CHAT_DEPLOYMENT_ID"),
            embedding_deployment_id=os.environ.get("AICORE_EMBEDDING_DEPLOYMENT_ID"),
        )


# =============================================================================
# AI Core Client
# =============================================================================

_cached_token = {"token": None, "expires_at": 0}
_cached_deployments: List[Dict] = []


def get_access_token(config: AICoreConfig) -> str:
    """Get OAuth access token from SAP AI Core."""
    global _cached_token
    
    if _cached_token["token"] and time.time() < _cached_token["expires_at"]:
        return _cached_token["token"]
    
    import base64
    auth = base64.b64encode(f"{config.client_id}:{config.client_secret}".encode()).decode()
    
    data = "grant_type=client_credentials".encode()
    req = urllib.request.Request(
        config.auth_url,
        data=data,
        headers={
            "Authorization": f"Basic {auth}",
            "Content-Type": "application/x-www-form-urlencoded",
        },
        method="POST"
    )
    
    with urllib.request.urlopen(req) as resp:
        result = json.loads(resp.read().decode())
        _cached_token["token"] = result["access_token"]
        _cached_token["expires_at"] = time.time() + result["expires_in"] - 60
        return result["access_token"]


def aicore_request(config: AICoreConfig, method: str, path: str, body: Optional[Dict] = None) -> Dict:
    """Make a request to SAP AI Core."""
    token = get_access_token(config)
    url = f"{config.base_url}{path}"
    
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Authorization": f"Bearer {token}",
            "AI-Resource-Group": config.resource_group,
            "Content-Type": "application/json",
        },
        method=method
    )
    
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        error_body = e.read().decode()
        raise HTTPException(status_code=e.code, detail=error_body)


def get_deployments(config: AICoreConfig) -> List[Dict]:
    """Get list of deployments from SAP AI Core."""
    global _cached_deployments
    
    if _cached_deployments:
        return _cached_deployments
    
    result = aicore_request(config, "GET", "/v2/lm/deployments")
    _cached_deployments = []
    
    for d in result.get("resources", []):
        model_name = d.get("details", {}).get("resources", {}).get("backend_details", {}).get("model", {}).get("name", "unknown")
        _cached_deployments.append({
            "id": d["id"],
            "model": model_name,
            "status": d.get("status", "unknown"),
            "is_anthropic": "anthropic" in model_name.lower(),
        })
    
    return _cached_deployments


def find_deployment(config: AICoreConfig, model_id: str) -> Optional[Dict]:
    """Find a deployment by model ID."""
    deployments = get_deployments(config)
    
    # Exact match
    for d in deployments:
        if d["id"] == model_id:
            return d
    
    # Model name match
    for d in deployments:
        if d["model"] == model_id or model_id in d["model"] or d["model"] in model_id:
            return d
    
    # Partial match
    for d in deployments:
        if model_id[:8] in d["id"] or d["id"][:8] in model_id:
            return d
    
    return None


# =============================================================================
# Pydantic Models (for FastAPI)
# =============================================================================

if USE_FASTAPI:
    class ChatMessage(BaseModel):
        role: str
        content: str

    class ChatCompletionRequest(BaseModel):
        model: str
        messages: List[ChatMessage]
        temperature: Optional[float] = 0.7
        max_tokens: Optional[int] = 1024
        stream: Optional[bool] = False
        top_p: Optional[float] = None
        frequency_penalty: Optional[float] = None
        presence_penalty: Optional[float] = None
        stop: Optional[Union[str, List[str]]] = None

    class EmbeddingRequest(BaseModel):
        model: str
        input: Union[str, List[str]]
        encoding_format: Optional[str] = "float"


# =============================================================================
# FastAPI Server
# =============================================================================

if USE_FASTAPI:
    app = FastAPI(
        title="SAP OpenAI-Compatible Server",
        description="OpenAI-compatible API that routes to SAP AI Core",
        version="1.0.0"
    )
    
    @app.get("/health")
    def health():
        """Health check endpoint."""
        return {"status": "healthy", "service": "sap-openai-server-vllm"}
    
    @app.get("/v1/models")
    def list_models():
        """List available models."""
        config = AICoreConfig.from_env()
        deployments = get_deployments(config)
        
        return {
            "object": "list",
            "data": [
                {
                    "id": d["id"],
                    "object": "model",
                    "created": int(time.time()),
                    "owned_by": "anthropic" if d["is_anthropic"] else "openai",
                    "permission": [],
                    "root": d["model"],
                    "parent": None,
                }
                for d in deployments
            ]
        }
    
    @app.get("/v1/models/{model_id}")
    def get_model(model_id: str):
        """Get model details."""
        config = AICoreConfig.from_env()
        deployment = find_deployment(config, model_id)
        
        if not deployment:
            raise HTTPException(status_code=404, detail="Model not found")
        
        return {
            "id": deployment["id"],
            "object": "model",
            "created": int(time.time()),
            "owned_by": "anthropic" if deployment["is_anthropic"] else "openai",
            "permission": [],
            "root": deployment["model"],
            "parent": None,
        }
    
    @app.post("/v1/chat/completions")
    async def chat_completions(request: ChatCompletionRequest):
        """Chat completions endpoint."""
        config = AICoreConfig.from_env()
        
        # Find deployment
        deployment = find_deployment(config, request.model)
        if not deployment and config.chat_deployment_id:
            deployment = find_deployment(config, config.chat_deployment_id)
        if not deployment:
            raise HTTPException(status_code=400, detail=f"Model {request.model} not found")
        
        completion_id = f"chatcmpl-{uuid.uuid4()}"
        created = int(time.time())
        
        messages = [{"role": m.role, "content": m.content} for m in request.messages]
        
        if deployment["is_anthropic"]:
            # Anthropic Claude format
            result = aicore_request(config, "POST", 
                f"/v2/inference/deployments/{deployment['id']}/invoke",
                {
                    "anthropic_version": "bedrock-2023-05-31",
                    "max_tokens": request.max_tokens or 1024,
                    "messages": messages,
                }
            )
            
            content = result.get("content", [{}])[0].get("text", "")
            input_tokens = result.get("usage", {}).get("input_tokens", 0)
            output_tokens = result.get("usage", {}).get("output_tokens", 0)
            
            if request.stream:
                # Simulate streaming for Anthropic
                async def generate():
                    # Initial chunk
                    yield f"data: {json.dumps({'id': completion_id, 'object': 'chat.completion.chunk', 'created': created, 'model': deployment['id'], 'choices': [{'index': 0, 'delta': {'role': 'assistant', 'content': ''}, 'finish_reason': None}]})}\n\n"
                    
                    # Content chunks
                    words = content.split()
                    for i, word in enumerate(words):
                        chunk_content = word if i == 0 else f" {word}"
                        yield f"data: {json.dumps({'id': completion_id, 'object': 'chat.completion.chunk', 'created': created, 'model': deployment['id'], 'choices': [{'index': 0, 'delta': {'content': chunk_content}, 'finish_reason': None}]})}\n\n"
                    
                    # Final chunk
                    yield f"data: {json.dumps({'id': completion_id, 'object': 'chat.completion.chunk', 'created': created, 'model': deployment['id'], 'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}]})}\n\n"
                    yield "data: [DONE]\n\n"
                
                return StreamingResponse(generate(), media_type="text/event-stream")
            else:
                return {
                    "id": completion_id,
                    "object": "chat.completion",
                    "created": created,
                    "model": deployment["id"],
                    "choices": [{
                        "index": 0,
                        "message": {"role": "assistant", "content": content},
                        "finish_reason": "stop",
                    }],
                    "usage": {
                        "prompt_tokens": input_tokens,
                        "completion_tokens": output_tokens,
                        "total_tokens": input_tokens + output_tokens,
                    },
                }
        else:
            # OpenAI format
            result = aicore_request(config, "POST",
                f"/v2/inference/deployments/{deployment['id']}/chat/completions",
                {
                    "model": request.model,
                    "messages": messages,
                    "max_tokens": request.max_tokens,
                    "temperature": request.temperature,
                    "stream": request.stream,
                }
            )
            
            return {
                "id": completion_id,
                **result,
                "model": deployment["id"],
            }
    
    @app.post("/v1/embeddings")
    async def embeddings(request: EmbeddingRequest):
        """Embeddings endpoint."""
        config = AICoreConfig.from_env()
        
        # Find embedding deployment
        deployment = find_deployment(config, request.model)
        if not deployment and config.embedding_deployment_id:
            deployment = find_deployment(config, config.embedding_deployment_id)
        if not deployment:
            raise HTTPException(status_code=400, detail=f"Embedding model {request.model} not found")
        
        inputs = request.input if isinstance(request.input, list) else [request.input]
        
        result = aicore_request(config, "POST",
            f"/v2/inference/deployments/{deployment['id']}/embeddings",
            {"input": inputs, "model": request.model}
        )
        
        return {
            "object": "list",
            "data": result.get("data", []),
            "model": deployment["id"],
            "usage": result.get("usage", {"prompt_tokens": 0, "total_tokens": 0}),
        }
    
    @app.post("/v1/completions")
    async def completions(request: Request):
        """Legacy completions endpoint."""
        body = await request.json()
        
        # Convert to chat format
        chat_request = ChatCompletionRequest(
            model=body.get("model", ""),
            messages=[ChatMessage(role="user", content=body.get("prompt", ""))],
            max_tokens=body.get("max_tokens"),
            temperature=body.get("temperature"),
            stream=body.get("stream", False),
        )
        
        return await chat_completions(chat_request)

    # =========================================================================
    # OpenAI-Compliant Additional Endpoints
    # =========================================================================

    # In-memory storage for files
    _file_storage: Dict[str, Dict] = {}
    
    # Private inference models (vLLM local models)
    _private_models: Dict[str, Dict] = {
        "llama-3.1-70b-instruct": {
            "id": "llama-3.1-70b-instruct",
            "model": "meta-llama/Llama-3.1-70B-Instruct",
            "status": "available",
            "is_private": True,
            "endpoint": "http://localhost:8080/v1",
        },
        "codellama-34b-instruct": {
            "id": "codellama-34b-instruct",
            "model": "codellama/CodeLlama-34b-Instruct-hf",
            "status": "available",
            "is_private": True,
            "endpoint": "http://localhost:8081/v1",
        },
        "mistral-7b-instruct": {
            "id": "mistral-7b-instruct",
            "model": "mistralai/Mistral-7B-Instruct-v0.2",
            "status": "available",
            "is_private": True,
            "endpoint": "http://localhost:8082/v1",
        },
        "qwen2-72b-instruct": {
            "id": "qwen2-72b-instruct",
            "model": "Qwen/Qwen2-72B-Instruct",
            "status": "available",
            "is_private": True,
            "endpoint": "http://localhost:8083/v1",
        },
    }

    def cosine_similarity(a: List[float], b: List[float]) -> float:
        """Calculate cosine similarity between two vectors."""
        if len(a) != len(b):
            return 0.0
        dot_product = sum(x * y for x, y in zip(a, b))
        norm_a = sum(x * x for x in a) ** 0.5
        norm_b = sum(x * x for x in b) ** 0.5
        if norm_a == 0 or norm_b == 0:
            return 0.0
        return dot_product / (norm_a * norm_b)

    class SearchRequest(BaseModel):
        query: str
        documents: Optional[List[str]] = None
        model: Optional[str] = None
        max_rerank: Optional[int] = 10
        return_documents: Optional[bool] = True

    class FileUploadRequest(BaseModel):
        file: str
        purpose: Optional[str] = "search"
        filename: Optional[str] = None

    @app.post("/v1/search")
    async def search(request: SearchRequest):
        """Semantic search endpoint (OpenAI-compliant)."""
        config = AICoreConfig.from_env()
        
        # Find embedding deployment
        deployment = None
        if request.model:
            deployment = find_deployment(config, request.model)
        if not deployment:
            deployments = get_deployments(config)
            deployment = next((d for d in deployments if "embed" in d["model"].lower()), None)
            if not deployment and deployments:
                deployment = deployments[0]
        
        if not deployment:
            raise HTTPException(status_code=400, detail="No embedding model available")
        
        if request.documents and len(request.documents) > 0:
            # Search within provided documents
            all_inputs = [request.query] + request.documents
            
            result = aicore_request(config, "POST",
                f"/v2/inference/deployments/{deployment['id']}/embeddings",
                {"input": all_inputs}
            )
            
            embeddings = [d.get("embedding", []) for d in result.get("data", [])]
            query_embedding = embeddings[0] if embeddings else []
            doc_embeddings = embeddings[1:]
            
            scores = []
            for i, emb in enumerate(doc_embeddings):
                score = cosine_similarity(query_embedding, emb)
                scores.append({
                    "document": i,
                    "score": score,
                    "text": request.documents[i] if request.return_documents else None,
                })
            
            scores.sort(key=lambda x: x["score"], reverse=True)
            top_results = scores[:request.max_rerank or 10]
            
            return {
                "object": "list",
                "data": [
                    {"object": "search_result", "document": r["document"], "score": r["score"], "text": r["text"]}
                    for r in top_results
                ],
                "model": deployment["id"],
            }
        else:
            # Search in stored files
            stored_files = [f for f in _file_storage.values() if f.get("embedding")]
            
            if not stored_files:
                return {"object": "list", "data": [], "model": deployment["id"]}
            
            result = aicore_request(config, "POST",
                f"/v2/inference/deployments/{deployment['id']}/embeddings",
                {"input": [request.query]}
            )
            
            query_embedding = result.get("data", [{}])[0].get("embedding", [])
            
            scores = []
            for i, f in enumerate(stored_files):
                score = cosine_similarity(query_embedding, f.get("embedding", []))
                scores.append({
                    "document": i,
                    "score": score,
                    "text": f.get("content") if request.return_documents else None,
                    "file_id": f.get("id"),
                })
            
            scores.sort(key=lambda x: x["score"], reverse=True)
            top_results = scores[:request.max_rerank or 10]
            
            return {
                "object": "list",
                "data": [
                    {"object": "search_result", "document": r["document"], "score": r["score"], "text": r["text"], "file_id": r["file_id"]}
                    for r in top_results
                ],
                "model": deployment["id"],
            }

    @app.post("/v1/files")
    async def upload_file(request: FileUploadRequest):
        """Upload a file (OpenAI-compliant)."""
        config = AICoreConfig.from_env()
        
        file_id = f"file-{uuid.uuid4()}"
        created_at = int(time.time())
        filename = request.filename or file_id
        
        # Try to generate embedding
        embedding = None
        try:
            deployments = get_deployments(config)
            embed_deployment = next((d for d in deployments if "embed" in d["model"].lower()), deployments[0] if deployments else None)
            
            if embed_deployment:
                result = aicore_request(config, "POST",
                    f"/v2/inference/deployments/{embed_deployment['id']}/embeddings",
                    {"input": [request.file]}
                )
                embedding = result.get("data", [{}])[0].get("embedding")
        except:
            pass
        
        _file_storage[file_id] = {
            "id": file_id,
            "filename": filename,
            "purpose": request.purpose or "search",
            "bytes": len(request.file),
            "content": request.file,
            "embedding": embedding,
            "created_at": created_at,
        }
        
        return {
            "id": file_id,
            "object": "file",
            "bytes": len(request.file),
            "created_at": created_at,
            "filename": filename,
            "purpose": request.purpose or "search",
            "status": "processed",
        }

    @app.get("/v1/files")
    def list_files():
        """List uploaded files (OpenAI-compliant)."""
        return {
            "object": "list",
            "data": [
                {
                    "id": f["id"],
                    "object": "file",
                    "bytes": f["bytes"],
                    "created_at": f["created_at"],
                    "filename": f["filename"],
                    "purpose": f["purpose"],
                    "status": "processed",
                }
                for f in _file_storage.values()
            ]
        }

    @app.get("/v1/files/{file_id}")
    def get_file(file_id: str):
        """Get file details (OpenAI-compliant)."""
        if file_id not in _file_storage:
            raise HTTPException(status_code=404, detail="File not found")
        
        f = _file_storage[file_id]
        return {
            "id": f["id"],
            "object": "file",
            "bytes": f["bytes"],
            "created_at": f["created_at"],
            "filename": f["filename"],
            "purpose": f["purpose"],
            "status": "processed",
        }

    @app.delete("/v1/files/{file_id}")
    def delete_file(file_id: str):
        """Delete a file (OpenAI-compliant)."""
        if file_id not in _file_storage:
            raise HTTPException(status_code=404, detail="File not found")
        
        del _file_storage[file_id]
        return {"id": file_id, "object": "file", "deleted": True}

    @app.get("/v1/files/{file_id}/content")
    def get_file_content(file_id: str):
        """Get file content (OpenAI-compliant)."""
        if file_id not in _file_storage:
            raise HTTPException(status_code=404, detail="File not found")
        
        from fastapi.responses import PlainTextResponse
        return PlainTextResponse(_file_storage[file_id]["content"])

    @app.get("/v1/fine-tunes")
    def list_fine_tunes():
        """List fine-tunes / deployments (OpenAI-compliant)."""
        config = AICoreConfig.from_env()
        deployments = get_deployments(config)
        
        return {
            "object": "list",
            "data": [
                {
                    "id": f"ft-{d['id']}",
                    "object": "fine-tune",
                    "model": d["model"],
                    "created_at": int(time.time()),
                    "status": "succeeded" if d["status"] == "RUNNING" else "pending",
                    "fine_tuned_model": d["id"],
                }
                for d in deployments
            ]
        }

    @app.get("/v1/fine-tunes/{fine_tune_id}")
    def get_fine_tune(fine_tune_id: str):
        """Get fine-tune details (OpenAI-compliant)."""
        config = AICoreConfig.from_env()
        ft_id = fine_tune_id.replace("ft-", "")
        deployment = find_deployment(config, ft_id)
        
        if not deployment:
            raise HTTPException(status_code=404, detail="Fine-tune not found")
        
        return {
            "id": f"ft-{deployment['id']}",
            "object": "fine-tune",
            "model": deployment["model"],
            "created_at": int(time.time()),
            "status": "succeeded" if deployment["status"] == "RUNNING" else "pending",
            "fine_tuned_model": deployment["id"],
        }

    # =========================================================================
    # Private Inference Endpoints (vLLM local models)
    # =========================================================================

    @app.get("/v1/private/models")
    def list_private_models():
        """List private inference models (vLLM local models)."""
        return {
            "object": "list",
            "data": [
                {
                    "id": m["id"],
                    "object": "model",
                    "created": int(time.time()),
                    "owned_by": "private",
                    "permission": [],
                    "root": m["model"],
                    "parent": None,
                    "is_private": True,
                    "endpoint": m["endpoint"],
                    "status": m["status"],
                }
                for m in _private_models.values()
            ]
        }

    @app.get("/v1/private/models/{model_id}")
    def get_private_model(model_id: str):
        """Get private model details."""
        if model_id not in _private_models:
            raise HTTPException(status_code=404, detail="Private model not found")
        
        m = _private_models[model_id]
        return {
            "id": m["id"],
            "object": "model",
            "created": int(time.time()),
            "owned_by": "private",
            "permission": [],
            "root": m["model"],
            "parent": None,
            "is_private": True,
            "endpoint": m["endpoint"],
            "status": m["status"],
        }

    class PrivateChatRequest(BaseModel):
        model: str
        messages: List[ChatMessage]
        temperature: Optional[float] = 0.7
        max_tokens: Optional[int] = 1024
        stream: Optional[bool] = False

    @app.post("/v1/private/chat/completions")
    async def private_chat_completions(request: PrivateChatRequest):
        """Chat completions with private vLLM models."""
        if request.model not in _private_models:
            raise HTTPException(status_code=404, detail=f"Private model {request.model} not found")
        
        model_info = _private_models[request.model]
        endpoint = model_info["endpoint"]
        
        completion_id = f"chatcmpl-{uuid.uuid4()}"
        created = int(time.time())
        
        try:
            # Make request to local vLLM server
            body = {
                "model": model_info["model"],
                "messages": [{"role": m.role, "content": m.content} for m in request.messages],
                "max_tokens": request.max_tokens,
                "temperature": request.temperature,
                "stream": request.stream,
            }
            
            req = urllib.request.Request(
                f"{endpoint}/chat/completions",
                data=json.dumps(body).encode(),
                headers={"Content-Type": "application/json"},
                method="POST"
            )
            
            with urllib.request.urlopen(req, timeout=120) as resp:
                result = json.loads(resp.read().decode())
                
                return {
                    "id": completion_id,
                    "object": "chat.completion",
                    "created": created,
                    "model": request.model,
                    "choices": result.get("choices", []),
                    "usage": result.get("usage", {}),
                    "is_private": True,
                }
        except Exception as e:
            raise HTTPException(status_code=503, detail=f"Private model unavailable: {str(e)}")

    @app.post("/v1/private/register")
    async def register_private_model(request: Request):
        """Register a new private vLLM model endpoint."""
        body = await request.json()
        
        model_id = body.get("id") or body.get("model_id")
        if not model_id:
            raise HTTPException(status_code=400, detail="model_id is required")
        
        _private_models[model_id] = {
            "id": model_id,
            "model": body.get("model", model_id),
            "status": "available",
            "is_private": True,
            "endpoint": body.get("endpoint", "http://localhost:8080/v1"),
        }
        
        return {
            "id": model_id,
            "status": "registered",
            "endpoint": _private_models[model_id]["endpoint"],
        }

    @app.delete("/v1/private/models/{model_id}")
    def unregister_private_model(model_id: str):
        """Unregister a private model."""
        if model_id not in _private_models:
            raise HTTPException(status_code=404, detail="Private model not found")
        
        del _private_models[model_id]
        return {"id": model_id, "deleted": True}


# =============================================================================
# CLI
# =============================================================================

def main():
    """Run the server."""
    import argparse
    
    parser = argparse.ArgumentParser(description="SAP OpenAI-Compatible Server")
    parser.add_argument("--host", default="0.0.0.0", help="Host to bind to")
    parser.add_argument("--port", type=int, default=8000, help="Port to listen on")
    parser.add_argument("--reload", action="store_true", help="Enable auto-reload")
    args = parser.parse_args()
    
    print(f"""
╔══════════════════════════════════════════════════════════╗
║                                                          ║
║       SAP OpenAI-Compatible Server (vLLM)               ║
║       Powered by SAP AI Core                             ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝

Server running at: http://{args.host}:{args.port}

Endpoints:
  GET  /health              - Health check
  GET  /v1/models           - List available models
  GET  /v1/models/:id       - Get model details
  POST /v1/chat/completions - Chat completions (streaming supported)
  POST /v1/embeddings       - Generate embeddings
  POST /v1/completions      - Legacy completions

Example usage:
  curl http://localhost:{args.port}/v1/chat/completions \\
    -H "Content-Type: application/json" \\
    -d '{{"model": "claude-3.5-sonnet", "messages": [{{"role": "user", "content": "Hello!"}}]}}'
""")
    
    if USE_FASTAPI:
        import uvicorn
        uvicorn.run(app, host=args.host, port=args.port, reload=args.reload)
    else:
        print("Error: FastAPI not installed. Run: pip install fastapi uvicorn")


if __name__ == "__main__":
    main()