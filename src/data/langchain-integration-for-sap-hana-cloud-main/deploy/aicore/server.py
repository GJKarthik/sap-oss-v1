"""
LangChain HANA - OpenAI-Compatible Vector Service
KServe InferenceService for SAP BTP AI Core

Endpoints:
  - POST /v1/embeddings - Generate embeddings (OpenAI format)
  - POST /v1/search - Similarity search in HANA Vector
  - GET /health - Health check
"""

import os
import time
from typing import Any, Dict, List, Optional, Union

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import openai

# HANA connection settings
HANA_HOST = os.getenv("HANA_HOST", "")
HANA_PORT = int(os.getenv("HANA_PORT", "443"))
HANA_USER = os.getenv("HANA_USER", "")
HANA_PASSWORD = os.getenv("HANA_PASSWORD", "")
VECTOR_TABLE = os.getenv("VECTOR_TABLE", "EMBEDDINGS")

# AI Core settings for embeddings
AI_CORE_URL = os.getenv("AI_CORE_URL", "")
AI_CORE_TOKEN = os.getenv("AI_CORE_TOKEN", "")

PORT = int(os.getenv("PORT", "8080"))


# Request/Response models
class EmbeddingRequest(BaseModel):
    model: str = "text-embedding-ada-002"
    input: Union[str, List[str]]
    encoding_format: Optional[str] = "float"
    user: Optional[str] = None


class SearchRequest(BaseModel):
    query: str
    table: Optional[str] = None
    column: Optional[str] = "embedding"
    top_k: Optional[int] = 5
    filter: Optional[Dict[str, Any]] = None


# FastAPI app
app = FastAPI(
    title="LangChain HANA Vector Service",
    description="OpenAI-compatible embeddings and vector search",
    version="1.0.0"
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# Initialize HANA connection lazily
_hana_connection = None

def get_hana_connection():
    global _hana_connection
    if _hana_connection is None:
        try:
            from hdbcli import dbapi
            _hana_connection = dbapi.connect(
                address=HANA_HOST,
                port=HANA_PORT,
                user=HANA_USER,
                password=HANA_PASSWORD,
                encrypt=True
            )
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"HANA connection failed: {e}")
    return _hana_connection


@app.get("/health")
@app.get("/healthz")
async def health():
    """Health check endpoint."""
    return {"status": "healthy", "timestamp": time.time()}


@app.post("/v1/embeddings")
async def create_embeddings(request: EmbeddingRequest):
    """
    OpenAI-compatible embeddings endpoint.
    Generates vector embeddings for input text.
    """
    inputs = request.input if isinstance(request.input, list) else [request.input]
    
    # Generate embeddings via AI Core or local model
    embeddings = []
    for i, text in enumerate(inputs):
        # Mock embedding for demo - in production, call AI Core embedding model
        embedding = [0.1] * 1536  # ada-002 dimension
        embeddings.append({
            "object": "embedding",
            "index": i,
            "embedding": embedding
        })
    
    return {
        "object": "list",
        "data": embeddings,
        "model": request.model,
        "usage": {
            "prompt_tokens": sum(len(t.split()) for t in inputs),
            "total_tokens": sum(len(t.split()) for t in inputs)
        }
    }


@app.post("/v1/search")
async def similarity_search(request: SearchRequest):
    """
    Similarity search in HANA Vector.
    Returns top-k most similar documents.
    """
    conn = get_hana_connection()
    cursor = conn.cursor()
    
    table = request.table or VECTOR_TABLE
    
    # Generate query embedding
    query_embedding = [0.1] * 1536  # Mock - use actual embedding model
    
    # HANA Vector similarity search
    sql = f"""
        SELECT id, content, COSINE_SIMILARITY({request.column}, TO_REAL_VECTOR(?)) as score
        FROM {table}
        ORDER BY score DESC
        LIMIT ?
    """
    
    try:
        cursor.execute(sql, (str(query_embedding), request.top_k))
        results = []
        for row in cursor.fetchall():
            results.append({
                "id": row[0],
                "content": row[1],
                "score": float(row[2])
            })
        
        return {
            "object": "list",
            "data": results,
            "query": request.query,
            "table": table
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Search failed: {e}")
    finally:
        cursor.close()


@app.get("/v1/models")
async def list_models():
    """List available embedding models."""
    return {
        "object": "list",
        "data": [
            {"id": "text-embedding-ada-002", "object": "model", "owned_by": "ai-core"},
            {"id": "text-embedding-3-small", "object": "model", "owned_by": "ai-core"},
            {"id": "text-embedding-3-large", "object": "model", "owned_by": "ai-core"},
        ]
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=PORT)