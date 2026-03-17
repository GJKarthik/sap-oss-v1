#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
SAP OpenAI-Compatible Server for HANA Cloud Generative AI Toolkit

Provides a full OpenAI-compatible API that routes to SAP AI Core
with native HANA Cloud vector store integration for RAG.

Usage:
    python -m sap_openai_server.server
    # or
    uvicorn sap_openai_server.server:app --port 8100
"""

import os
import json
import logging
import uuid
import time
import urllib.request
from typing import List, Dict, Any, Optional, Union
from dataclasses import dataclass

# Try FastAPI first
try:
    from fastapi import FastAPI, HTTPException, Request
    from fastapi.responses import StreamingResponse, PlainTextResponse
    from pydantic import BaseModel
    USE_FASTAPI = True
except ImportError:
    USE_FASTAPI = False

logger = logging.getLogger(__name__)

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

@dataclass
class HANAConfig:
    """SAP HANA Cloud configuration."""
    host: str
    port: int
    user: str
    password: str
    
    @classmethod
    def from_env(cls) -> "HANAConfig":
        return cls(
            host=os.environ.get("HANA_HOST", ""),
            port=int(os.environ.get("HANA_PORT", "443")),
            user=os.environ.get("HANA_USER", ""),
            password=os.environ.get("HANA_PASSWORD", ""),
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
    
    for d in deployments:
        if d["id"] == model_id:
            return d
    
    for d in deployments:
        if d["model"] == model_id or model_id in d["model"] or d["model"] in model_id:
            return d
    
    for d in deployments:
        if model_id[:8] in d["id"] or d["id"][:8] in model_id:
            return d
    
    return None


# =============================================================================
# HANA Vector Store Integration
# =============================================================================

_hana_connection = None

def get_hana_connection():
    """Get HANA connection (lazy initialization)."""
    global _hana_connection
    if _hana_connection is None:
        try:
            from hana_ml import ConnectionContext
            hana_config = HANAConfig.from_env()
            if hana_config.host:
                _hana_connection = ConnectionContext(
                    address=hana_config.host,
                    port=hana_config.port,
                    user=hana_config.user,
                    password=hana_config.password
                )
        except Exception as e:
            print(f"HANA connection not available: {e}")
    return _hana_connection


def cosine_similarity(a: List[float], b: List[float]) -> float:
    """Calculate cosine similarity between two vectors."""
    if len(a) != len(b) or len(a) == 0:
        return 0.0
    dot_product = sum(x * y for x, y in zip(a, b))
    norm_a = sum(x * x for x in a) ** 0.5
    norm_b = sum(x * x for x in b) ** 0.5
    if norm_a == 0 or norm_b == 0:
        return 0.0
    return dot_product / (norm_a * norm_b)


# =============================================================================
# FastAPI Server
# =============================================================================

if USE_FASTAPI:
    app = FastAPI(
        title="SAP OpenAI-Compatible Server (HANA AI Toolkit)",
        description="OpenAI-compatible API with HANA Cloud vector store integration",
        version="1.0.0"
    )
    
    # In-memory storage (fallback when HANA not available)
    _file_storage: Dict[str, Dict] = {}
    _vector_tables: Dict[str, List[Dict]] = {}
    
    # =========================================================================
    # Pydantic Models
    # =========================================================================
    
    class ChatMessage(BaseModel):
        role: str
        content: str

    class ChatCompletionRequest(BaseModel):
        model: str
        messages: List[ChatMessage]
        temperature: Optional[float] = 0.7
        max_tokens: Optional[int] = 1024
        stream: Optional[bool] = False
        # HANA RAG options
        search_context: Optional[bool] = False
        context_top_k: Optional[int] = 5
        vector_table: Optional[str] = None

    class EmbeddingRequest(BaseModel):
        model: str
        input: Union[str, List[str]]
        # HANA storage options
        store_in_hana: Optional[bool] = False
        table_name: Optional[str] = None
        document_ids: Optional[List[str]] = None

    class SearchRequest(BaseModel):
        query: str
        documents: Optional[List[str]] = None
        model: Optional[str] = None
        max_rerank: Optional[int] = 10
        return_documents: Optional[bool] = True
        # HANA options
        use_hana: Optional[bool] = False
        vector_table: Optional[str] = None

    class FileUploadRequest(BaseModel):
        file: str
        purpose: Optional[str] = "search"
        filename: Optional[str] = None
        store_in_hana: Optional[bool] = False

    class HANAVectorRequest(BaseModel):
        table_name: str
        documents: List[str]
        ids: Optional[List[str]] = None
        model: Optional[str] = None

    # =========================================================================
    # Core OpenAI Endpoints
    # =========================================================================
    
    @app.get("/health")
    def health():
        """Health check endpoint."""
        hana_status = "connected" if get_hana_connection() else "not_configured"
        return {
            "status": "healthy",
            "service": "sap-openai-server-hana-ai-toolkit",
            "hana": hana_status
        }
    
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
        """Chat completions with optional HANA RAG."""
        config = AICoreConfig.from_env()
        
        deployment = find_deployment(config, request.model)
        if not deployment and config.chat_deployment_id:
            deployment = find_deployment(config, config.chat_deployment_id)
        if not deployment:
            raise HTTPException(status_code=400, detail=f"Model {request.model} not found")
        
        completion_id = f"chatcmpl-{uuid.uuid4()}"
        created = int(time.time())
        
        messages = [{"role": m.role, "content": m.content} for m in request.messages]
        
        # RAG: Inject context from HANA vector store
        if request.search_context and messages:
            user_query = messages[-1]["content"] if messages[-1]["role"] == "user" else ""
            if user_query:
                context_docs = await _search_hana_vectors(
                    query=user_query,
                    table_name=request.vector_table or "default_vectors",
                    top_k=request.context_top_k or 5,
                    config=config
                )
                if context_docs:
                    context_text = "\n\n".join([f"Document {i+1}: {doc}" for i, doc in enumerate(context_docs)])
                    system_msg = f"Use the following context to answer the question:\n\n{context_text}"
                    messages.insert(0, {"role": "system", "content": system_msg})
        
        if deployment["is_anthropic"]:
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
                async def generate():
                    yield f"data: {json.dumps({'id': completion_id, 'object': 'chat.completion.chunk', 'created': created, 'model': deployment['id'], 'choices': [{'index': 0, 'delta': {'role': 'assistant', 'content': ''}, 'finish_reason': None}]})}\n\n"
                    words = content.split()
                    for i, word in enumerate(words):
                        chunk_content = word if i == 0 else f" {word}"
                        yield f"data: {json.dumps({'id': completion_id, 'object': 'chat.completion.chunk', 'created': created, 'model': deployment['id'], 'choices': [{'index': 0, 'delta': {'content': chunk_content}, 'finish_reason': None}]})}\n\n"
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
            result = aicore_request(config, "POST",
                f"/v2/inference/deployments/{deployment['id']}/chat/completions",
                {
                    "model": request.model,
                    "messages": messages,
                    "max_tokens": request.max_tokens,
                    "temperature": request.temperature,
                }
            )
            return {"id": completion_id, **result, "model": deployment["id"]}
    
    @app.post("/v1/embeddings")
    async def embeddings(request: EmbeddingRequest):
        """Embeddings with optional HANA storage."""
        config = AICoreConfig.from_env()
        
        deployment = find_deployment(config, request.model)
        if not deployment and config.embedding_deployment_id:
            deployment = find_deployment(config, config.embedding_deployment_id)
        if not deployment:
            deployments = get_deployments(config)
            deployment = next((d for d in deployments if "embed" in d["model"].lower()), deployments[0] if deployments else None)
        
        if not deployment:
            raise HTTPException(status_code=400, detail="No embedding model available")
        
        inputs = request.input if isinstance(request.input, list) else [request.input]
        
        result = aicore_request(config, "POST",
            f"/v2/inference/deployments/{deployment['id']}/embeddings",
            {"input": inputs, "model": request.model}
        )
        
        # Store in HANA if requested
        if request.store_in_hana and request.table_name:
            embeddings_data = result.get("data", [])
            doc_ids = request.document_ids or [f"doc-{uuid.uuid4()}" for _ in inputs]
            await _store_vectors_in_hana(
                table_name=request.table_name,
                documents=inputs,
                embeddings=[e.get("embedding", []) for e in embeddings_data],
                ids=doc_ids
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
    
    @app.post("/v1/search")
    async def search(request: SearchRequest):
        """Semantic search with optional HANA vector store."""
        config = AICoreConfig.from_env()
        
        deployment = None
        if request.model:
            deployment = find_deployment(config, request.model)
        if not deployment:
            deployments = get_deployments(config)
            deployment = next((d for d in deployments if "embed" in d["model"].lower()), deployments[0] if deployments else None)
        
        if not deployment:
            raise HTTPException(status_code=400, detail="No embedding model available")
        
        # Use HANA vector store
        if request.use_hana and request.vector_table:
            results = await _search_hana_vectors(
                query=request.query,
                table_name=request.vector_table,
                top_k=request.max_rerank or 10,
                config=config
            )
            return {
                "object": "list",
                "data": [
                    {"object": "search_result", "document": i, "score": 1.0, "text": r}
                    for i, r in enumerate(results)
                ],
                "model": deployment["id"],
                "source": "hana_vector_store"
            }
        
        # Search within provided documents
        if request.documents and len(request.documents) > 0:
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
        
        # Search in file storage
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
        return {
            "object": "list",
            "data": scores[:request.max_rerank or 10],
            "model": deployment["id"],
        }
    
    @app.post("/v1/files")
    async def upload_file(request: FileUploadRequest):
        """Upload a file with optional HANA storage."""
        config = AICoreConfig.from_env()
        
        file_id = f"file-{uuid.uuid4()}"
        created_at = int(time.time())
        filename = request.filename or file_id
        
        # Generate embedding
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
        except Exception as e:
            logger.warning("Failed to compute embedding for file: %s", e)
        
        _file_storage[file_id] = {
            "id": file_id,
            "filename": filename,
            "purpose": request.purpose or "search",
            "bytes": len(request.file),
            "content": request.file,
            "embedding": embedding,
            "created_at": created_at,
        }
        
        # Store in HANA if requested
        if request.store_in_hana and embedding:
            await _store_vectors_in_hana(
                table_name="openai_files",
                documents=[request.file],
                embeddings=[embedding],
                ids=[file_id]
            )
        
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
        """List uploaded files."""
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
        """Get file details."""
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
        """Delete a file."""
        if file_id not in _file_storage:
            raise HTTPException(status_code=404, detail="File not found")
        del _file_storage[file_id]
        return {"id": file_id, "object": "file", "deleted": True}
    
    @app.get("/v1/files/{file_id}/content")
    def get_file_content(file_id: str):
        """Get file content."""
        if file_id not in _file_storage:
            raise HTTPException(status_code=404, detail="File not found")
        return PlainTextResponse(_file_storage[file_id]["content"])
    
    @app.get("/v1/fine-tunes")
    def list_fine_tunes():
        """List fine-tunes (SAP AI Core deployments)."""
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
        """Get fine-tune details."""
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
    # Additional OpenAI-Compliant Endpoints (Full API Coverage)
    # =========================================================================

    class ModerationRequest(BaseModel):
        input: Union[str, List[str]]
        model: Optional[str] = "text-moderation-latest"

    @app.post("/v1/moderations")
    async def moderations(request: ModerationRequest):
        """Content moderation endpoint (OpenAI-compliant)."""
        inputs = request.input if isinstance(request.input, list) else [request.input]
        
        results = []
        for text in inputs:
            # Simple keyword-based moderation (placeholder)
            flagged = any(word in text.lower() for word in ["hate", "violence", "self-harm"])
            results.append({
                "flagged": flagged,
                "categories": {
                    "hate": False,
                    "hate/threatening": False,
                    "harassment": False,
                    "harassment/threatening": False,
                    "self-harm": False,
                    "self-harm/intent": False,
                    "self-harm/instructions": False,
                    "sexual": False,
                    "sexual/minors": False,
                    "violence": False,
                    "violence/graphic": False,
                },
                "category_scores": {
                    "hate": 0.0,
                    "hate/threatening": 0.0,
                    "harassment": 0.0,
                    "harassment/threatening": 0.0,
                    "self-harm": 0.0,
                    "self-harm/intent": 0.0,
                    "self-harm/instructions": 0.0,
                    "sexual": 0.0,
                    "sexual/minors": 0.0,
                    "violence": 0.0,
                    "violence/graphic": 0.0,
                }
            })
        
        return {
            "id": f"modr-{uuid.uuid4()}",
            "model": request.model,
            "results": results
        }

    class ImageGenerationRequest(BaseModel):
        prompt: str
        model: Optional[str] = "dall-e-3"
        n: Optional[int] = 1
        size: Optional[str] = "1024x1024"
        quality: Optional[str] = "standard"
        response_format: Optional[str] = "url"

    @app.post("/v1/images/generations")
    async def image_generations(request: ImageGenerationRequest):
        """Image generation endpoint (placeholder - returns error as not supported)."""
        raise HTTPException(
            status_code=501, 
            detail="Image generation not supported. Use SAP AI Core image models directly."
        )

    class AudioTranscriptionRequest(BaseModel):
        file: str  # Base64 encoded audio
        model: Optional[str] = "whisper-1"
        language: Optional[str] = None
        prompt: Optional[str] = None
        response_format: Optional[str] = "json"

    @app.post("/v1/audio/transcriptions")
    async def audio_transcriptions(request: AudioTranscriptionRequest):
        """Audio transcription endpoint (placeholder)."""
        raise HTTPException(
            status_code=501,
            detail="Audio transcription not supported. Use SAP AI Core speech models directly."
        )

    @app.post("/v1/audio/translations")
    async def audio_translations(request: AudioTranscriptionRequest):
        """Audio translation endpoint (placeholder)."""
        raise HTTPException(
            status_code=501,
            detail="Audio translation not supported. Use SAP AI Core speech models directly."
        )

    @app.post("/v1/audio/speech")
    async def audio_speech(request: Request):
        """Text-to-speech endpoint (placeholder)."""
        raise HTTPException(
            status_code=501,
            detail="Text-to-speech not supported. Use SAP AI Core TTS models directly."
        )

    # Assistants API (v2)
    _assistants: Dict[str, Dict] = {}
    _threads: Dict[str, Dict] = {}
    _messages: Dict[str, List[Dict]] = {}
    _runs: Dict[str, Dict] = {}

    class AssistantCreate(BaseModel):
        model: str
        name: Optional[str] = None
        description: Optional[str] = None
        instructions: Optional[str] = None
        tools: Optional[List[Dict]] = []
        file_ids: Optional[List[str]] = []
        metadata: Optional[Dict] = {}

    @app.post("/v1/assistants")
    async def create_assistant(request: AssistantCreate):
        """Create an assistant (OpenAI-compliant)."""
        assistant_id = f"asst_{uuid.uuid4().hex[:24]}"
        created_at = int(time.time())
        
        _assistants[assistant_id] = {
            "id": assistant_id,
            "object": "assistant",
            "created_at": created_at,
            "name": request.name,
            "description": request.description,
            "model": request.model,
            "instructions": request.instructions,
            "tools": request.tools or [],
            "file_ids": request.file_ids or [],
            "metadata": request.metadata or {},
        }
        
        return _assistants[assistant_id]

    @app.get("/v1/assistants")
    def list_assistants(limit: int = 20, order: str = "desc"):
        """List assistants (OpenAI-compliant)."""
        assistants = list(_assistants.values())
        if order == "desc":
            assistants.sort(key=lambda x: x["created_at"], reverse=True)
        else:
            assistants.sort(key=lambda x: x["created_at"])
        return {
            "object": "list",
            "data": assistants[:limit],
            "first_id": assistants[0]["id"] if assistants else None,
            "last_id": assistants[-1]["id"] if assistants else None,
            "has_more": len(assistants) > limit
        }

    @app.get("/v1/assistants/{assistant_id}")
    def get_assistant(assistant_id: str):
        """Get assistant details (OpenAI-compliant)."""
        if assistant_id not in _assistants:
            raise HTTPException(status_code=404, detail="Assistant not found")
        return _assistants[assistant_id]

    @app.delete("/v1/assistants/{assistant_id}")
    def delete_assistant(assistant_id: str):
        """Delete an assistant (OpenAI-compliant)."""
        if assistant_id not in _assistants:
            raise HTTPException(status_code=404, detail="Assistant not found")
        del _assistants[assistant_id]
        return {"id": assistant_id, "object": "assistant.deleted", "deleted": True}

    @app.post("/v1/threads")
    async def create_thread(request: Request):
        """Create a thread (OpenAI-compliant)."""
        body = await request.json() if request.headers.get("content-length", "0") != "0" else {}
        thread_id = f"thread_{uuid.uuid4().hex[:24]}"
        created_at = int(time.time())
        
        _threads[thread_id] = {
            "id": thread_id,
            "object": "thread",
            "created_at": created_at,
            "metadata": body.get("metadata", {}),
        }
        _messages[thread_id] = []
        
        return _threads[thread_id]

    @app.get("/v1/threads/{thread_id}")
    def get_thread(thread_id: str):
        """Get thread details (OpenAI-compliant)."""
        if thread_id not in _threads:
            raise HTTPException(status_code=404, detail="Thread not found")
        return _threads[thread_id]

    @app.delete("/v1/threads/{thread_id}")
    def delete_thread(thread_id: str):
        """Delete a thread (OpenAI-compliant)."""
        if thread_id not in _threads:
            raise HTTPException(status_code=404, detail="Thread not found")
        del _threads[thread_id]
        if thread_id in _messages:
            del _messages[thread_id]
        return {"id": thread_id, "object": "thread.deleted", "deleted": True}

    class MessageCreate(BaseModel):
        role: str
        content: str
        file_ids: Optional[List[str]] = []
        metadata: Optional[Dict] = {}

    @app.post("/v1/threads/{thread_id}/messages")
    async def create_message(thread_id: str, request: MessageCreate):
        """Create a message in a thread (OpenAI-compliant)."""
        if thread_id not in _threads:
            raise HTTPException(status_code=404, detail="Thread not found")
        
        message_id = f"msg_{uuid.uuid4().hex[:24]}"
        created_at = int(time.time())
        
        message = {
            "id": message_id,
            "object": "thread.message",
            "created_at": created_at,
            "thread_id": thread_id,
            "role": request.role,
            "content": [{"type": "text", "text": {"value": request.content, "annotations": []}}],
            "file_ids": request.file_ids or [],
            "assistant_id": None,
            "run_id": None,
            "metadata": request.metadata or {},
        }
        
        _messages[thread_id].append(message)
        return message

    @app.get("/v1/threads/{thread_id}/messages")
    def list_messages(thread_id: str, limit: int = 20, order: str = "desc"):
        """List messages in a thread (OpenAI-compliant)."""
        if thread_id not in _threads:
            raise HTTPException(status_code=404, detail="Thread not found")
        
        messages = _messages.get(thread_id, [])
        if order == "desc":
            messages = list(reversed(messages))
        
        return {
            "object": "list",
            "data": messages[:limit],
            "first_id": messages[0]["id"] if messages else None,
            "last_id": messages[-1]["id"] if messages else None,
            "has_more": len(messages) > limit
        }

    class RunCreate(BaseModel):
        assistant_id: str
        model: Optional[str] = None
        instructions: Optional[str] = None
        tools: Optional[List[Dict]] = None

    @app.post("/v1/threads/{thread_id}/runs")
    async def create_run(thread_id: str, request: RunCreate):
        """Create a run in a thread (OpenAI-compliant)."""
        if thread_id not in _threads:
            raise HTTPException(status_code=404, detail="Thread not found")
        if request.assistant_id not in _assistants:
            raise HTTPException(status_code=404, detail="Assistant not found")
        
        config = AICoreConfig.from_env()
        assistant = _assistants[request.assistant_id]
        
        run_id = f"run_{uuid.uuid4().hex[:24]}"
        created_at = int(time.time())
        
        # Get messages from thread
        messages = [{"role": m["role"], "content": m["content"][0]["text"]["value"]} 
                   for m in _messages.get(thread_id, [])]
        
        # Add system instructions
        if assistant.get("instructions") or request.instructions:
            instructions = request.instructions or assistant.get("instructions")
            messages.insert(0, {"role": "system", "content": instructions})
        
        # Call SAP AI Core
        deployment = find_deployment(config, request.model or assistant["model"])
        if not deployment:
            deployments = get_deployments(config)
            deployment = deployments[0] if deployments else None
        
        if not deployment:
            raise HTTPException(status_code=400, detail="No model available")
        
        try:
            result = aicore_request(config, "POST", 
                f"/v2/inference/deployments/{deployment['id']}/invoke",
                {
                    "anthropic_version": "bedrock-2023-05-31",
                    "max_tokens": 1024,
                    "messages": messages,
                }
            )
            
            content = result.get("content", [{}])[0].get("text", "")
            
            # Add assistant response to messages
            response_msg = {
                "id": f"msg_{uuid.uuid4().hex[:24]}",
                "object": "thread.message",
                "created_at": int(time.time()),
                "thread_id": thread_id,
                "role": "assistant",
                "content": [{"type": "text", "text": {"value": content, "annotations": []}}],
                "file_ids": [],
                "assistant_id": request.assistant_id,
                "run_id": run_id,
                "metadata": {},
            }
            _messages[thread_id].append(response_msg)
            
            status = "completed"
        except Exception as e:
            status = "failed"
            content = str(e)
        
        run = {
            "id": run_id,
            "object": "thread.run",
            "created_at": created_at,
            "thread_id": thread_id,
            "assistant_id": request.assistant_id,
            "status": status,
            "model": deployment["id"] if deployment else None,
            "instructions": request.instructions or assistant.get("instructions"),
            "tools": request.tools or assistant.get("tools", []),
            "metadata": {},
        }
        
        _runs[run_id] = run
        return run

    @app.get("/v1/threads/{thread_id}/runs/{run_id}")
    def get_run(thread_id: str, run_id: str):
        """Get run details (OpenAI-compliant)."""
        if run_id not in _runs:
            raise HTTPException(status_code=404, detail="Run not found")
        return _runs[run_id]

    @app.get("/v1/threads/{thread_id}/runs")
    def list_runs(thread_id: str, limit: int = 20):
        """List runs in a thread (OpenAI-compliant)."""
        runs = [r for r in _runs.values() if r["thread_id"] == thread_id]
        return {
            "object": "list",
            "data": runs[:limit],
            "first_id": runs[0]["id"] if runs else None,
            "last_id": runs[-1]["id"] if runs else None,
            "has_more": len(runs) > limit
        }

    # Batches API
    _batches: Dict[str, Dict] = {}

    class BatchCreate(BaseModel):
        input_file_id: str
        endpoint: str
        completion_window: str = "24h"
        metadata: Optional[Dict] = {}

    @app.post("/v1/batches")
    async def create_batch(request: BatchCreate):
        """Create a batch (OpenAI-compliant)."""
        batch_id = f"batch_{uuid.uuid4().hex[:24]}"
        created_at = int(time.time())
        
        _batches[batch_id] = {
            "id": batch_id,
            "object": "batch",
            "endpoint": request.endpoint,
            "input_file_id": request.input_file_id,
            "completion_window": request.completion_window,
            "status": "validating",
            "created_at": created_at,
            "metadata": request.metadata or {},
        }
        
        return _batches[batch_id]

    @app.get("/v1/batches/{batch_id}")
    def get_batch(batch_id: str):
        """Get batch details (OpenAI-compliant)."""
        if batch_id not in _batches:
            raise HTTPException(status_code=404, detail="Batch not found")
        return _batches[batch_id]

    @app.get("/v1/batches")
    def list_batches(limit: int = 20):
        """List batches (OpenAI-compliant)."""
        batches = list(_batches.values())
        return {
            "object": "list",
            "data": batches[:limit],
        }

    @app.post("/v1/batches/{batch_id}/cancel")
    def cancel_batch(batch_id: str):
        """Cancel a batch (OpenAI-compliant)."""
        if batch_id not in _batches:
            raise HTTPException(status_code=404, detail="Batch not found")
        _batches[batch_id]["status"] = "cancelled"
        return _batches[batch_id]
    
    # =========================================================================
    # HANA Cloud Vector Store Endpoints
    # =========================================================================
    
    @app.get("/v1/hana/tables")
    def list_hana_vector_tables():
        """List HANA vector tables."""
        conn = get_hana_connection()
        if not conn:
            return {"object": "list", "data": list(_vector_tables.keys()), "source": "memory"}
        
        try:
            # Query HANA for vector tables
            result = conn.sql("""
                SELECT TABLE_NAME FROM SYS.TABLES 
                WHERE TABLE_TYPE = 'COLUMN' 
                AND TABLE_NAME LIKE '%VECTOR%'
            """).collect()
            tables = result["TABLE_NAME"].tolist() if not result.empty else []
            return {"object": "list", "data": tables, "source": "hana"}
        except Exception as e:
            logger.warning("Failed to list HANA tables, falling back to memory: %s", e)
            return {"object": "list", "data": list(_vector_tables.keys()), "source": "memory"}
    
    @app.post("/v1/hana/vectors")
    async def store_hana_vectors(request: HANAVectorRequest):
        """Store vectors in HANA Cloud."""
        config = AICoreConfig.from_env()
        
        # Generate embeddings
        deployment = None
        if request.model:
            deployment = find_deployment(config, request.model)
        if not deployment:
            deployments = get_deployments(config)
            deployment = next((d for d in deployments if "embed" in d["model"].lower()), deployments[0] if deployments else None)
        
        if not deployment:
            raise HTTPException(status_code=400, detail="No embedding model available")
        
        result = aicore_request(config, "POST",
            f"/v2/inference/deployments/{deployment['id']}/embeddings",
            {"input": request.documents}
        )
        
        embeddings = [d.get("embedding", []) for d in result.get("data", [])]
        ids = request.ids or [f"doc-{uuid.uuid4()}" for _ in request.documents]
        
        await _store_vectors_in_hana(
            table_name=request.table_name,
            documents=request.documents,
            embeddings=embeddings,
            ids=ids
        )
        
        return {
            "status": "stored",
            "table_name": request.table_name,
            "documents_stored": len(request.documents),
            "model": deployment["id"],
        }
    
    @app.post("/v1/hana/search")
    async def search_hana_vectors(request: SearchRequest):
        """Search HANA vector store."""
        if not request.vector_table:
            raise HTTPException(status_code=400, detail="vector_table is required")
        
        request.use_hana = True
        return await search(request)
    
    @app.delete("/v1/hana/tables/{table_name}")
    def delete_hana_vector_table(table_name: str):
        """Delete a HANA vector table."""
        conn = get_hana_connection()
        if conn:
            try:
                conn.sql(f'DROP TABLE "{table_name}"')
                return {"status": "deleted", "table_name": table_name}
            except Exception as e:
                raise HTTPException(status_code=500, detail=str(e))
        
        if table_name in _vector_tables:
            del _vector_tables[table_name]
            return {"status": "deleted", "table_name": table_name, "source": "memory"}
        
        raise HTTPException(status_code=404, detail="Table not found")
    
    # =========================================================================
    # HANA Vector Helper Functions
    # =========================================================================
    
    async def _store_vectors_in_hana(
        table_name: str,
        documents: List[str],
        embeddings: List[List[float]],
        ids: List[str]
    ):
        """Store vectors in HANA or memory."""
        conn = get_hana_connection()
        
        if conn:
            try:
                # Create table if not exists
                vector_dim = len(embeddings[0]) if embeddings else 768
                conn.sql(f'''
                    CREATE TABLE IF NOT EXISTS "{table_name}" (
                        "id" VARCHAR(500) PRIMARY KEY,
                        "content" NCLOB,
                        "embedding" REAL_VECTOR({vector_dim})
                    )
                ''')
                
                # Insert vectors
                for i, (doc_id, doc, emb) in enumerate(zip(ids, documents, embeddings)):
                    emb_str = ",".join(str(x) for x in emb)
                    conn.sql(f'''
                        UPSERT "{table_name}" ("id", "content", "embedding")
                        VALUES ('{doc_id}', '{doc.replace("'", "''")}', TO_REAL_VECTOR('[{emb_str}]'))
                    ''')
                return
            except Exception as e:
                print(f"HANA storage error: {e}")
        
        # Fallback to memory storage
        if table_name not in _vector_tables:
            _vector_tables[table_name] = []
        
        for doc_id, doc, emb in zip(ids, documents, embeddings):
            _vector_tables[table_name].append({
                "id": doc_id,
                "content": doc,
                "embedding": emb
            })
    
    async def _search_hana_vectors(
        query: str,
        table_name: str,
        top_k: int,
        config: AICoreConfig
    ) -> List[str]:
        """Search vectors in HANA or memory."""
        # Generate query embedding
        deployments = get_deployments(config)
        deployment = next((d for d in deployments if "embed" in d["model"].lower()), deployments[0] if deployments else None)
        
        if not deployment:
            return []
        
        result = aicore_request(config, "POST",
            f"/v2/inference/deployments/{deployment['id']}/embeddings",
            {"input": [query]}
        )
        query_embedding = result.get("data", [{}])[0].get("embedding", [])
        
        conn = get_hana_connection()
        if conn:
            try:
                emb_str = ",".join(str(x) for x in query_embedding)
                result = conn.sql(f'''
                    SELECT TOP {top_k} "content", 
                           COSINE_SIMILARITY("embedding", TO_REAL_VECTOR('[{emb_str}]')) AS score
                    FROM "{table_name}"
                    ORDER BY score DESC
                ''').collect()
                return result["content"].tolist() if not result.empty else []
            except Exception as e:
                print(f"HANA search error: {e}")
        
        # Fallback to memory search
        if table_name not in _vector_tables:
            return []
        
        scores = []
        for doc in _vector_tables[table_name]:
            score = cosine_similarity(query_embedding, doc.get("embedding", []))
            scores.append((score, doc["content"]))
        
        scores.sort(key=lambda x: x[0], reverse=True)
        return [s[1] for s in scores[:top_k]]


# =============================================================================
# CLI
# =============================================================================

def main():
    """Run the server."""
    import argparse
    
    parser = argparse.ArgumentParser(description="SAP OpenAI-Compatible Server (HANA AI Toolkit)")
    parser.add_argument("--host", default="0.0.0.0", help="Host to bind to")
    parser.add_argument("--port", type=int, default=8100, help="Port to listen on")
    parser.add_argument("--reload", action="store_true", help="Enable auto-reload")
    args = parser.parse_args()
    
    print(f"""
╔══════════════════════════════════════════════════════════╗
║                                                          ║
║   SAP OpenAI-Compatible Server (HANA AI Toolkit)        ║
║   Powered by SAP AI Core + HANA Cloud Vector Store      ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝

Server running at: http://{args.host}:{args.port}

Core Endpoints:
  GET  /health              - Health check
  GET  /v1/models           - List available models
  POST /v1/chat/completions - Chat completions (with RAG)
  POST /v1/embeddings       - Generate embeddings
  POST /v1/search           - Semantic search
  GET  /v1/files            - List files
  GET  /v1/fine-tunes       - List fine-tunes

HANA Vector Endpoints:
  GET  /v1/hana/tables      - List vector tables
  POST /v1/hana/vectors     - Store vectors
  POST /v1/hana/search      - Search vectors
  DEL  /v1/hana/tables/:id  - Delete table

Example with RAG:
  curl http://localhost:{args.port}/v1/chat/completions \\
    -H "Content-Type: application/json" \\
    -d '{{"model": "claude-3.5-sonnet", "messages": [{{"role": "user", "content": "What is X?"}}], "search_context": true, "vector_table": "my_docs"}}'
""")
    
    if USE_FASTAPI:
        import uvicorn
        uvicorn.run(app, host=args.host, port=args.port, reload=args.reload)
    else:
        print("Error: FastAPI not installed. Run: pip install fastapi uvicorn")


if __name__ == "__main__":
    main()