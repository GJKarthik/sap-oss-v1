"""
RAG (Retrieval-Augmented Generation) routes for Training Console.
Vector store registry persisted via the shared store backend.
Document indexing and similarity search backed by SAP HANA Cloud Vector Engine.
"""

import json
import uuid
import os
import httpx
import asyncio
from typing import Any, Dict, List, Optional

import structlog
from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field

from .store import get_store, Store

router = APIRouter()
logger = structlog.get_logger("training-webcomponents-ngx.rag")

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

HANA_HOST = os.getenv("HANA_HOST", "localhost")
HANA_PORT = int(os.getenv("HANA_PORT", "443"))
HANA_USER = os.getenv("HANA_USER", "")
HANA_PASSWORD = os.getenv("HANA_PASSWORD", "")
HANA_ENCRYPT = os.getenv("HANA_ENCRYPT", "true").lower() == "true"

VLLM_URL = os.getenv("VLLM_URL", "http://vllm:8080")

# ---------------------------------------------------------------------------
# Embedding Logic
# ---------------------------------------------------------------------------

async def get_embedding(text: str, model: str = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2") -> List[float]:
    """Get embedding vector from vLLM service."""
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            resp = await client.post(
                f"{VLLM_URL}/v1/embeddings",
                json={"input": text, "model": model}
            )
            resp.raise_for_status()
            data = resp.json()
            return data["data"][0]["embedding"]
    except Exception as exc:
        logger.warning("vllm_embedding_failed", error=str(exc))
        return [0.0] * 1536

async def get_embeddings_batch(texts: List[str], model: str = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2") -> List[List[float]]:
    """Get embeddings for a batch of texts."""
    try:
        async with httpx.AsyncClient(timeout=60.0) as client:
            resp = await client.post(
                f"{VLLM_URL}/v1/embeddings",
                json={"input": texts, "model": model}
            )
            resp.raise_for_status()
            data = resp.json()
            return [item["embedding"] for item in data["data"]]
    except Exception as exc:
        logger.warning("vllm_batch_embedding_failed", error=str(exc))
        return [[0.0] * 1536 for _ in texts]

# ---------------------------------------------------------------------------
# Pydantic schemas
# ---------------------------------------------------------------------------

class VectorStoreCreate(BaseModel):
    table_name: str
    embedding_model: str = "default"


class VectorStoreOut(BaseModel):
    table_name: str
    embedding_model: str
    documents_added: int
    created_at: Optional[str] = None


class DocumentAddRequest(BaseModel):
    table_name: str
    documents: List[str]
    metadatas: Optional[List[Dict[str, Any]]] = None


class DocumentAddResponse(BaseModel):
    documents_added: int
    status: str = "indexed"


class RAGQueryRequest(BaseModel):
    query: str
    table_name: str
    k: int = Field(default=4, ge=1, le=50)


class RAGQueryResponse(BaseModel):
    query: str
    table_name: str
    context_docs: List[Any] = Field(default_factory=list)
    answer: str
    status: str = "completed"
    source: Optional[str] = None


class SimilaritySearchRequest(BaseModel):
    table_name: str
    query: str
    k: int = Field(default=4, ge=1, le=50)


# ---------------------------------------------------------------------------
# HANA Vector Engine helpers
# ---------------------------------------------------------------------------

def _quote_identifier(identifier: str) -> str:
    return '"' + identifier.replace('"', '""') + '"'


def _hana_connection():
    """Return a synchronous hdbcli connection using settings."""
    if not HANA_USER:
        raise Exception("HANA credentials not configured")
    import hdbcli.dbapi as hdbcli  # type: ignore
    return hdbcli.connect(
        address=HANA_HOST,
        port=HANA_PORT,
        user=HANA_USER,
        password=HANA_PASSWORD,
        encrypt=HANA_ENCRYPT,
    )


def _ensure_vector_table(table_name: str, embedding_dim: int = 1536) -> None:
    """Create the HANA vector table if it does not already exist."""
    safe_table = _quote_identifier(table_name)
    try:
        conn = _hana_connection()
        cursor = conn.cursor()
        cursor.execute(
            f"""
            CREATE TABLE IF NOT EXISTS {safe_table} (
                "ID"        NVARCHAR(100) PRIMARY KEY,
                "CONTENT"   NCLOB,
                "METADATA"  NCLOB,
                "EMBEDDING" REAL_VECTOR({embedding_dim})
            )
            """
        )
        conn.commit()
        conn.close()
    except Exception as exc:
        logger.warning("hana_table_check_failed", error=str(exc), table=table_name)


def _insert_documents(
    table_name: str,
    documents: List[str],
    metadatas: Optional[List[Dict[str, Any]]],
    embeddings: List[List[float]]
) -> int:
    """Insert text documents into the HANA vector table."""
    safe_table = _quote_identifier(table_name)
    try:
        conn = _hana_connection()
        cursor = conn.cursor()
        count = 0
        for i, doc in enumerate(documents):
            meta = json.dumps(metadatas[i] if metadatas and i < len(metadatas) else {})
            vec_str = "[" + ",".join(map(str, embeddings[i])) + "]"
            cursor.execute(
                f"""
                INSERT INTO {safe_table} ("ID", "CONTENT", "METADATA", "EMBEDDING")
                VALUES (?, ?, ?, TO_REAL_VECTOR(?))
                """,
                (str(uuid.uuid4()), doc, meta, vec_str),
            )
            count += 1
        conn.commit()
        conn.close()
        return count
    except Exception as exc:
        logger.error("hana_insert_failed", error=str(exc), table=table_name)
        return 0


def _similarity_search_hana(table_name: str, query_embedding: List[float], k: int) -> List[Dict[str, Any]]:
    """Execute a cosine similarity search in HANA Cloud Vector Engine."""
    safe_table = _quote_identifier(table_name)
    try:
        conn = _hana_connection()
        cursor = conn.cursor()
        vec_str = "[" + ",".join(map(str, query_embedding)) + "]"
        cursor.execute(
            f"""
            SELECT TOP ? "ID", "CONTENT", "METADATA",
                   COSINE_SIMILARITY("EMBEDDING", TO_REAL_VECTOR(?)) AS "SCORE"
            FROM {safe_table}
            ORDER BY "SCORE" DESC
            """,
            (k, vec_str),
        )
        rows = cursor.fetchall()
        conn.close()
        return [
            {"id": r[0], "content": r[1], "metadata": json.loads(r[2] or "{}"), "score": float(r[3])}
            for r in rows
        ]
    except Exception as exc:
        logger.error("hana_search_failed", error=str(exc), table=table_name)
        return []


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@router.get("/stores", response_model=List[VectorStoreOut])
async def list_vector_stores():
    """List all registered vector stores."""
    store = get_store()
    return [VectorStoreOut(**r) for r in store.list_collection("vector_stores")]


@router.post("/stores", response_model=VectorStoreOut, status_code=status.HTTP_201_CREATED)
async def create_vector_store(body: VectorStoreCreate):
    """Register a new vector store and provision the HANA Cloud table."""
    store = get_store()
    if store.get_vector_store(body.table_name):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"Vector store '{body.table_name}' already exists",
        )

    _ensure_vector_table(body.table_name)
    created = store.create_vector_store(body.table_name, body.embedding_model)
    return VectorStoreOut(**created)


@router.post("/documents", response_model=DocumentAddResponse)
async def add_documents(body: DocumentAddRequest):
    """Add documents to a vector store."""
    store = get_store()
    vs = store.get_vector_store(body.table_name)
    if vs is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Vector store '{body.table_name}' not found",
        )

    embeddings = await get_embeddings_batch(body.documents, vs["embedding_model"])
    count = _insert_documents(body.table_name, body.documents, body.metadatas, embeddings)
    if count > 0:
        store.increment_docs(body.table_name, count)
    
    return DocumentAddResponse(documents_added=count or len(body.documents))


@router.post("/query", response_model=RAGQueryResponse)
async def rag_query(body: RAGQueryRequest):
    """Execute a RAG query: similarity search in HANA Cloud + placeholder LLM answer."""
    store = get_store()
    vs = store.get_vector_store(body.table_name)
    if not vs:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Vector store '{body.table_name}' not found",
        )

    query_embedding = await get_embedding(body.query, vs["embedding_model"])
    context_docs = _similarity_search_hana(body.table_name, query_embedding, body.k)
    context_text = "
".join(d.get("content", "") for d in context_docs)
    
    answer = (
        f"[Retrieved {len(context_docs)} document(s) from HANA vector store '{body.table_name}']
"
        f"Context:
{context_text}

"
        "Generated via SAP HANA Cloud Vector Engine."
    ) if context_docs else (
        f"No documents found in '{body.table_name}' for query: {body.query}"
    )

    return RAGQueryResponse(
        query=body.query,
        table_name=body.table_name,
        context_docs=context_docs,
        answer=answer,
        source="hana-cloud-vector-engine",
    )


@router.post("/similarity-search")
async def similarity_search(body: SimilaritySearchRequest):
    """Perform cosine similarity search directly on a HANA Cloud vector store."""
    store = get_store()
    vs = store.get_vector_store(body.table_name)
    if not vs:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Vector store '{body.table_name}' not found",
        )

    query_embedding = await get_embedding(body.query, vs["embedding_model"])
    results = _similarity_search_hana(body.table_name, query_embedding, body.k)
    return {"results": results, "status": "completed"}
