#!/usr/bin/env python3
"""
SAP OpenAI-Compatible Server for Elasticsearch

Provides a full OpenAI-compatible API that routes to SAP AI Core,
with optional Elasticsearch integration for:
- Vector storage and semantic search
- Document retrieval for RAG
- Chat history persistence

Usage:
    uvicorn server:app --port 9200
"""

import os
import json
import uuid
import time
import urllib.request
import urllib.parse
from typing import List, Dict, Any, Optional, Union
from dataclasses import dataclass

try:
    from fastapi import FastAPI, HTTPException, Request
    from fastapi.responses import StreamingResponse, JSONResponse
    from pydantic import BaseModel
    USE_FASTAPI = True
except ImportError:
    USE_FASTAPI = False

# Optional: Elasticsearch client
try:
    from elasticsearch import Elasticsearch
    HAS_ELASTICSEARCH = True
except ImportError:
    HAS_ELASTICSEARCH = False

# =============================================================================
# Configuration
# =============================================================================

@dataclass
class AICoreConfig:
    """SAP AI Core configuration."""
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
class ElasticsearchConfig:
    """Elasticsearch configuration."""
    host: str = "http://localhost:9200"
    username: Optional[str] = None
    password: Optional[str] = None
    index_prefix: str = "sap_openai"
    vector_dims: int = 768

    @classmethod
    def from_env(cls) -> "ElasticsearchConfig":
        return cls(
            host=os.environ.get("ES_HOST", "http://localhost:9200"),
            username=os.environ.get("ES_USERNAME"),
            password=os.environ.get("ES_PASSWORD"),
            index_prefix=os.environ.get("ES_INDEX_PREFIX", "sap_openai"),
            vector_dims=int(os.environ.get("ES_VECTOR_DIMS", "768")),
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
        if USE_FASTAPI:
            raise HTTPException(status_code=e.code, detail=error_body)
        raise Exception(f"{e.code}: {error_body}")


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
# Elasticsearch Integration
# =============================================================================

def get_es_client() -> Optional[Any]:
    """Get Elasticsearch client if available."""
    if not HAS_ELASTICSEARCH:
        return None
    
    config = ElasticsearchConfig.from_env()
    
    if config.username and config.password:
        return Elasticsearch(
            [config.host],
            basic_auth=(config.username, config.password)
        )
    return Elasticsearch([config.host])


def store_embedding_in_es(
    es_client: Any,
    doc_id: str,
    text: str,
    embedding: List[float],
    metadata: Optional[Dict] = None
) -> None:
    """Store an embedding in Elasticsearch."""
    config = ElasticsearchConfig.from_env()
    index_name = f"{config.index_prefix}_vectors"
    
    # Create index with vector mapping if it doesn't exist
    if not es_client.indices.exists(index=index_name):
        es_client.indices.create(
            index=index_name,
            body={
                "mappings": {
                    "properties": {
                        "text": {"type": "text"},
                        "embedding": {
                            "type": "dense_vector",
                            "dims": config.vector_dims,
                            "index": True,
                            "similarity": "cosine"
                        },
                        "metadata": {"type": "object"},
                        "created_at": {"type": "date"}
                    }
                }
            }
        )
    
    es_client.index(
        index=index_name,
        id=doc_id,
        body={
            "text": text,
            "embedding": embedding,
            "metadata": metadata or {},
            "created_at": int(time.time() * 1000)
        }
    )


def search_similar_in_es(
    es_client: Any,
    query_embedding: List[float],
    top_k: int = 10
) -> List[Dict]:
    """Search for similar documents in Elasticsearch using vector similarity."""
    config = ElasticsearchConfig.from_env()
    index_name = f"{config.index_prefix}_vectors"
    
    if not es_client.indices.exists(index=index_name):
        return []
    
    result = es_client.search(
        index=index_name,
        body={
            "knn": {
                "field": "embedding",
                "query_vector": query_embedding,
                "k": top_k,
                "num_candidates": top_k * 10
            }
        }
    )
    
    return [
        {
            "id": hit["_id"],
            "score": hit["_score"],
            "text": hit["_source"]["text"],
            "metadata": hit["_source"].get("metadata", {})
        }
        for hit in result["hits"]["hits"]
    ]


def store_chat_history(
    es_client: Any,
    conversation_id: str,
    messages: List[Dict],
    metadata: Optional[Dict] = None
) -> None:
    """Store chat history in Elasticsearch."""
    config = ElasticsearchConfig.from_env()
    index_name = f"{config.index_prefix}_conversations"
    
    if not es_client.indices.exists(index=index_name):
        es_client.indices.create(
            index=index_name,
            body={
                "mappings": {
                    "properties": {
                        "messages": {"type": "object"},
                        "metadata": {"type": "object"},
                        "created_at": {"type": "date"},
                        "updated_at": {"type": "date"}
                    }
                }
            }
        )
    
    es_client.index(
        index=index_name,
        id=conversation_id,
        body={
            "messages": messages,
            "metadata": metadata or {},
            "created_at": int(time.time() * 1000),
            "updated_at": int(time.time() * 1000)
        }
    )


# =============================================================================
# Pydantic Models
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
        # Elasticsearch integration options
        store_in_es: Optional[bool] = False
        conversation_id: Optional[str] = None
        search_context: Optional[bool] = False
        context_top_k: Optional[int] = 5

    class EmbeddingRequest(BaseModel):
        model: str
        input: Union[str, List[str]]
        encoding_format: Optional[str] = "float"
        # Elasticsearch integration options
        store_in_es: Optional[bool] = False
        document_ids: Optional[List[str]] = None
        metadata: Optional[Dict] = None

    class SemanticSearchRequest(BaseModel):
        query: str
        top_k: Optional[int] = 10
        model: Optional[str] = None


# =============================================================================
# FastAPI Server
# =============================================================================

if USE_FASTAPI:
    app = FastAPI(
        title="SAP OpenAI-Compatible Server for Elasticsearch",
        description="OpenAI-compatible API with Elasticsearch vector storage integration",
        version="1.0.0"
    )
    
    @app.get("/health")
    def health():
        """Health check endpoint."""
        es_status = "not_configured"
        if HAS_ELASTICSEARCH:
            try:
                es = get_es_client()
                if es and es.ping():
                    es_status = "connected"
                else:
                    es_status = "disconnected"
            except:
                es_status = "error"
        
        return {
            "status": "healthy",
            "service": "sap-openai-server-elasticsearch",
            "elasticsearch": es_status
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
        """Chat completions with optional Elasticsearch RAG."""
        config = AICoreConfig.from_env()
        
        deployment = find_deployment(config, request.model)
        if not deployment and config.chat_deployment_id:
            deployment = find_deployment(config, config.chat_deployment_id)
        if not deployment:
            raise HTTPException(status_code=400, detail=f"Model {request.model} not found")
        
        messages = [{"role": m.role, "content": m.content} for m in request.messages]
        
        # RAG: Search for relevant context in Elasticsearch
        if request.search_context and HAS_ELASTICSEARCH:
            es = get_es_client()
            if es:
                # Get embedding for the last user message
                user_messages = [m for m in messages if m["role"] == "user"]
                if user_messages:
                    last_query = user_messages[-1]["content"]
                    # Generate embedding
                    if config.embedding_deployment_id:
                        embed_result = aicore_request(config, "POST",
                            f"/v2/inference/deployments/{config.embedding_deployment_id}/embeddings",
                            {"input": [last_query]}
                        )
                        query_embedding = embed_result.get("data", [{}])[0].get("embedding", [])
                        if query_embedding:
                            # Search for similar documents
                            similar_docs = search_similar_in_es(es, query_embedding, request.context_top_k or 5)
                            if similar_docs:
                                # Inject context into system message
                                context_text = "\n\n".join([
                                    f"[Document {i+1}]: {doc['text']}" 
                                    for i, doc in enumerate(similar_docs)
                                ])
                                context_message = {
                                    "role": "system",
                                    "content": f"Use the following context to help answer the user's question:\n\n{context_text}"
                                }
                                messages.insert(0, context_message)
        
        completion_id = f"chatcmpl-{uuid.uuid4()}"
        created = int(time.time())
        
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
            
            response = {
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
                    "stream": request.stream,
                }
            )
            response = {"id": completion_id, **result, "model": deployment["id"]}
            content = result.get("choices", [{}])[0].get("message", {}).get("content", "")
        
        # Store conversation in Elasticsearch
        if request.store_in_es and HAS_ELASTICSEARCH:
            es = get_es_client()
            if es:
                conv_id = request.conversation_id or completion_id
                messages.append({"role": "assistant", "content": content})
                store_chat_history(es, conv_id, messages)
        
        return response
    
    @app.post("/v1/embeddings")
    async def embeddings(request: EmbeddingRequest):
        """Generate embeddings with optional Elasticsearch storage."""
        config = AICoreConfig.from_env()
        
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
        
        # Store embeddings in Elasticsearch
        if request.store_in_es and HAS_ELASTICSEARCH:
            es = get_es_client()
            if es:
                embeddings_data = result.get("data", [])
                doc_ids = request.document_ids or [str(uuid.uuid4()) for _ in inputs]
                
                for i, (text, embed_data) in enumerate(zip(inputs, embeddings_data)):
                    doc_id = doc_ids[i] if i < len(doc_ids) else str(uuid.uuid4())
                    embedding = embed_data.get("embedding", [])
                    if embedding:
                        store_embedding_in_es(es, doc_id, text, embedding, request.metadata)
        
        return {
            "object": "list",
            "data": result.get("data", []),
            "model": deployment["id"],
            "usage": result.get("usage", {"prompt_tokens": 0, "total_tokens": 0}),
        }
    
    @app.post("/v1/semantic_search")
    async def semantic_search(request: SemanticSearchRequest):
        """Semantic search using Elasticsearch vector similarity."""
        if not HAS_ELASTICSEARCH:
            raise HTTPException(status_code=501, detail="Elasticsearch not available")
        
        config = AICoreConfig.from_env()
        
        # Get embedding for query
        deployment_id = config.embedding_deployment_id
        if request.model:
            deployment = find_deployment(config, request.model)
            if deployment:
                deployment_id = deployment["id"]
        
        if not deployment_id:
            raise HTTPException(status_code=400, detail="No embedding model configured")
        
        result = aicore_request(config, "POST",
            f"/v2/inference/deployments/{deployment_id}/embeddings",
            {"input": [request.query]}
        )
        
        query_embedding = result.get("data", [{}])[0].get("embedding", [])
        if not query_embedding:
            raise HTTPException(status_code=500, detail="Failed to generate embedding")
        
        # Search in Elasticsearch
        es = get_es_client()
        if not es:
            raise HTTPException(status_code=500, detail="Elasticsearch not connected")
        
        similar_docs = search_similar_in_es(es, query_embedding, request.top_k or 10)
        
        return {
            "object": "list",
            "data": similar_docs,
            "query": request.query,
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


# =============================================================================
# OpenAI-Compliant Endpoints with Elasticsearch Backend
# All endpoints follow OpenAI API spec exactly
# =============================================================================

# The standard OpenAI endpoints (/v1/chat/completions, /v1/embeddings, etc.)
# are defined above and already work with Elasticsearch.
# 
# Additional OpenAI-compliant endpoints for Elasticsearch operations:

if USE_FASTAPI:
    
    # -------------------------------------------------------------------------
    # OpenAI /v1/search - Search endpoint (follows OpenAI embedding search pattern)
    # -------------------------------------------------------------------------
    
    class SearchRequest(BaseModel):
        """OpenAI-style search request."""
        query: str
        documents: Optional[List[str]] = None
        model: Optional[str] = None
        max_rerank: Optional[int] = 10
        return_documents: Optional[bool] = True
    
    @app.post("/v1/search")
    async def openai_search(request: SearchRequest):
        """
        OpenAI-compliant /v1/search endpoint.
        Uses Elasticsearch for vector similarity search.
        
        Request format: https://platform.openai.com/docs/api-reference/searches
        """
        config = AICoreConfig.from_env()
        
        # Generate embedding for query using /v1/embeddings
        deployment = find_deployment(config, config.embedding_deployment_id or request.model or config.chat_deployment_id or "")
        if not deployment:
            # Try to get any available deployment
            deployments = get_deployments(config)
            if deployments:
                deployment = deployments[0]
            else:
                raise HTTPException(status_code=400, detail="No embedding model available")
        
        embed_result = aicore_request(config, "POST",
            f"/v2/inference/deployments/{deployment['id']}/embeddings",
            {"input": [request.query]}
        )
        
        query_embedding = embed_result.get("data", [{}])[0].get("embedding", [])
        
        # Search in Elasticsearch
        search_results = []
        if query_embedding and HAS_ELASTICSEARCH:
            es = get_es_client()
            if es:
                search_results = search_similar_in_es(es, query_embedding, request.max_rerank or 10)
        
        # Return OpenAI search-compliant response
        return {
            "object": "list",
            "data": [
                {
                    "object": "search_result",
                    "document": i,
                    "score": r.get("score", 0),
                    "text": r.get("text", "") if request.return_documents else None
                }
                for i, r in enumerate(search_results)
            ],
            "model": deployment["id"]
        }
    
    # -------------------------------------------------------------------------
    # OpenAI /v1/files - File upload for embedding storage (follows OpenAI files API)
    # -------------------------------------------------------------------------
    
    class FileUploadRequest(BaseModel):
        """File content for embedding."""
        file: str  # Base64 or text content
        purpose: str = "search"  # 'search' or 'answers'
        filename: Optional[str] = None
    
    @app.post("/v1/files")
    async def openai_files_upload(request: Request):
        """
        OpenAI-compliant /v1/files endpoint.
        Stores file content as embeddings in Elasticsearch.
        """
        body = await request.json()
        file_content = body.get("file", "")
        purpose = body.get("purpose", "search")
        filename = body.get("filename", f"file-{uuid.uuid4()}")
        
        if not file_content:
            raise HTTPException(status_code=400, detail="No file content provided")
        
        config = AICoreConfig.from_env()
        deployment = find_deployment(config, config.embedding_deployment_id or "")
        
        if not deployment:
            raise HTTPException(status_code=400, detail="No embedding model configured")
        
        # Generate embedding for file content
        result = aicore_request(config, "POST",
            f"/v2/inference/deployments/{deployment['id']}/embeddings",
            {"input": [file_content]}
        )
        
        embedding = result.get("data", [{}])[0].get("embedding", [])
        file_id = f"file-{uuid.uuid4()}"
        
        # Store in Elasticsearch
        if embedding and HAS_ELASTICSEARCH:
            es = get_es_client()
            if es:
                store_embedding_in_es(es, file_id, file_content, embedding, {"purpose": purpose, "filename": filename})
        
        # Return OpenAI files API compliant response
        return {
            "id": file_id,
            "object": "file",
            "bytes": len(file_content),
            "created_at": int(time.time()),
            "filename": filename,
            "purpose": purpose,
            "status": "processed"
        }
    
    @app.get("/v1/files")
    async def openai_files_list():
        """
        OpenAI-compliant GET /v1/files endpoint.
        Lists files stored in Elasticsearch.
        """
        files = []
        
        if HAS_ELASTICSEARCH:
            es = get_es_client()
            if es:
                config = ElasticsearchConfig.from_env()
                index_name = f"{config.index_prefix}_vectors"
                try:
                    if es.indices.exists(index=index_name):
                        result = es.search(index=index_name, body={"query": {"match_all": {}}, "size": 100})
                        for hit in result["hits"]["hits"]:
                            files.append({
                                "id": hit["_id"],
                                "object": "file",
                                "bytes": len(hit["_source"].get("text", "")),
                                "created_at": hit["_source"].get("created_at", 0) // 1000,
                                "filename": hit["_source"].get("metadata", {}).get("filename", hit["_id"]),
                                "purpose": hit["_source"].get("metadata", {}).get("purpose", "search"),
                                "status": "processed"
                            })
                except:
                    pass
        
        return {
            "object": "list",
            "data": files
        }
    
    @app.get("/v1/files/{file_id}")
    async def openai_files_get(file_id: str):
        """
        OpenAI-compliant GET /v1/files/{file_id} endpoint.
        """
        if HAS_ELASTICSEARCH:
            es = get_es_client()
            if es:
                config = ElasticsearchConfig.from_env()
                index_name = f"{config.index_prefix}_vectors"
                try:
                    doc = es.get(index=index_name, id=file_id)
                    return {
                        "id": file_id,
                        "object": "file",
                        "bytes": len(doc["_source"].get("text", "")),
                        "created_at": doc["_source"].get("created_at", 0) // 1000,
                        "filename": doc["_source"].get("metadata", {}).get("filename", file_id),
                        "purpose": doc["_source"].get("metadata", {}).get("purpose", "search"),
                        "status": "processed"
                    }
                except:
                    pass
        
        raise HTTPException(status_code=404, detail="File not found")
    
    @app.delete("/v1/files/{file_id}")
    async def openai_files_delete(file_id: str):
        """
        OpenAI-compliant DELETE /v1/files/{file_id} endpoint.
        """
        if HAS_ELASTICSEARCH:
            es = get_es_client()
            if es:
                config = ElasticsearchConfig.from_env()
                index_name = f"{config.index_prefix}_vectors"
                try:
                    es.delete(index=index_name, id=file_id)
                    return {
                        "id": file_id,
                        "object": "file",
                        "deleted": True
                    }
                except:
                    pass
        
        raise HTTPException(status_code=404, detail="File not found")
    
    # -------------------------------------------------------------------------
    # OpenAI /v1/fine-tunes (placeholder - maps to ES index operations)
    # -------------------------------------------------------------------------
    
    @app.get("/v1/fine-tunes")
    async def openai_fine_tunes_list():
        """
        OpenAI-compliant GET /v1/fine-tunes endpoint.
        Lists Elasticsearch indices as 'fine-tuned models'.
        """
        fine_tunes = []
        
        if HAS_ELASTICSEARCH:
            es = get_es_client()
            if es:
                try:
                    indices = es.cat.indices(format="json")
                    for idx in indices:
                        fine_tunes.append({
                            "id": f"ft-{idx.get('index', '')}",
                            "object": "fine-tune",
                            "model": idx.get("index", ""),
                            "created_at": int(time.time()),
                            "status": "succeeded" if idx.get("health") == "green" else "pending"
                        })
                except:
                    pass
        
        return {
            "object": "list",
            "data": fine_tunes
        }


# =============================================================================
# CLI
# =============================================================================

def main():
    """Run the server."""
    import argparse
    
    parser = argparse.ArgumentParser(description="SAP OpenAI-Compatible Server for Elasticsearch")
    parser.add_argument("--host", default="0.0.0.0", help="Host to bind to")
    parser.add_argument("--port", type=int, default=9201, help="Port to listen on")
    parser.add_argument("--reload", action="store_true", help="Enable auto-reload")
    args = parser.parse_args()
    
    print(f"""
╔══════════════════════════════════════════════════════════╗
║                                                          ║
║       SAP OpenAI-Compatible Server (Elasticsearch)      ║
║       Powered by SAP AI Core + Elasticsearch            ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝

Server running at: http://{args.host}:{args.port}

Endpoints:
  GET  /health                - Health check (includes ES status)
  GET  /v1/models             - List available models
  POST /v1/chat/completions   - Chat (with optional RAG)
  POST /v1/embeddings         - Embeddings (with ES storage)
  POST /v1/semantic_search    - Vector similarity search
""")
    
    if USE_FASTAPI:
        import uvicorn
        uvicorn.run(app, host=args.host, port=args.port, reload=args.reload)
    else:
        print("Error: FastAPI not installed. Run: pip install fastapi uvicorn")


if __name__ == "__main__":
    main()