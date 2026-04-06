"""
RAG (Retrieval-Augmented Generation) routes for SAP AI Fabric Console.
Vector store registry persisted via the configured shared store backend.
Document indexing and similarity search backed by Elasticsearch MCP with AI Core embeddings.
"""

import json
from dataclasses import asdict
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

import structlog
from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field

from ..models import VectorStore as VectorStoreDC
from ..routes.auth import UserInfo, get_current_user, log_admin_action, require_admin
from ..routes import mcp_proxy
from ..store import StoreBackend, get_store

router = APIRouter()
logger = structlog.get_logger()


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
    status: str


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
# Elasticsearch MCP helpers
# ---------------------------------------------------------------------------

def _correlation_id(scope: str, table_name: str, offset: int = 0) -> str:
    return f"rag-{scope}-{table_name}-{offset}"


def _normalize_es_hits(payload: dict[str, Any]) -> list[dict[str, Any]]:
    hits = payload.get("hits", {}).get("hits", []) if isinstance(payload, dict) else []
    normalized: list[dict[str, Any]] = []
    for hit in hits:
        source = hit.get("_source", {}) if isinstance(hit, dict) else {}
        metadata = source.get("metadata", {})
        normalized.append(
            {
                "id": hit.get("_id"),
                "content": source.get("content", ""),
                "metadata": metadata if isinstance(metadata, dict) else {},
                "score": float(hit.get("_score") or 0.0),
            }
        )
    return normalized


async def _index_documents_es(
    table_name: str,
    documents: List[str],
    metadatas: Optional[List[Dict[str, Any]]],
) -> tuple[int, list[str]]:
    count = 0
    errors: list[str] = []
    for index, doc in enumerate(documents):
        metadata = metadatas[index] if metadatas and index < len(metadatas) else {}
        try:
            embedding_result = await mcp_proxy.call_tool(
                mcp_proxy.settings.elasticsearch_mcp_url,
                "generate_embedding",
                {"text": doc},
                _correlation_id("embed", table_name, index),
            )
            if isinstance(embedding_result, dict) and embedding_result.get("error"):
                raise RuntimeError(str(embedding_result["error"]))
            embedding = embedding_result.get("data", [{}])[0].get("embedding", []) if isinstance(embedding_result, dict) else []
            if not isinstance(embedding, list) or not embedding:
                raise RuntimeError("Embedding payload was empty")

            index_payload = {
                "content": doc,
                "metadata": metadata,
                "embedding": embedding,
                "indexed_at": datetime.now(timezone.utc).isoformat(),
            }
            index_result = await mcp_proxy.call_tool(
                mcp_proxy.settings.elasticsearch_mcp_url,
                "es_index",
                {
                    "index": table_name,
                    "document": json.dumps(index_payload),
                },
                _correlation_id("index", table_name, index),
            )
            if isinstance(index_result, dict) and index_result.get("error"):
                raise RuntimeError(str(index_result["error"]))
            count += 1
        except Exception as exc:
            errors.append(f"document {index + 1}: {exc}")
            logger.warning("Elasticsearch document indexing failed", index=table_name, error=str(exc))

    return count, errors


async def _similarity_search_es(table_name: str, query: str, k: int) -> List[Dict[str, Any]]:
    """Execute semantic similarity search through Elasticsearch MCP."""
    result = await mcp_proxy.call_tool(
        mcp_proxy.settings.elasticsearch_mcp_url,
        "ai_semantic_search",
        {
            "index": table_name,
            "query": query,
            "vector_field": "embedding",
            "k": k,
        },
        _correlation_id("search", table_name, k),
    )
    if isinstance(result, dict) and result.get("error"):
        raise RuntimeError(str(result["error"]))
    return _normalize_es_hits(result if isinstance(result, dict) else {})


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@router.get("/stores", response_model=List[VectorStoreOut])
async def list_vector_stores(
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(get_current_user),
):
    """List all registered vector stores."""
    rows = sorted(store.list_records("vector_stores"), key=lambda v: v["table_name"])
    return [VectorStoreOut(**r) for r in rows]


@router.post("/stores", response_model=VectorStoreOut, status_code=status.HTTP_201_CREATED)
async def create_vector_store(
    body: VectorStoreCreate,
    store: StoreBackend = Depends(get_store),
    current_user: UserInfo = Depends(require_admin),
):
    """Register a new Elasticsearch-backed knowledge base in the shared store."""
    if store.has_record("vector_stores", body.table_name):
        log_admin_action(
            actor=current_user,
            resource="vector_stores",
            action="create",
            result="failure",
            target=body.table_name,
            reason="already_exists",
        )
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"Vector store '{body.table_name}' already exists",
        )

    vs = VectorStoreDC(table_name=body.table_name, embedding_model=body.embedding_model)
    created = store.set_record("vector_stores", body.table_name, asdict(vs))
    log_admin_action(
        actor=current_user,
        resource="vector_stores",
        action="create",
        result="success",
        target=body.table_name,
        embedding_model=body.embedding_model,
    )
    return VectorStoreOut(**created)


@router.post("/documents", response_model=DocumentAddResponse)
async def add_documents(
    body: DocumentAddRequest,
    store: StoreBackend = Depends(get_store),
    current_user: UserInfo = Depends(require_admin),
):
    """Add documents to a knowledge base using AI Core embeddings and Elasticsearch MCP."""
    vs = store.get_record("vector_stores", body.table_name)
    if vs is None:
        log_admin_action(
            actor=current_user,
            resource="vector_stores",
            action="add_documents",
            result="failure",
            target=body.table_name,
            reason="not_found",
        )
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Vector store '{body.table_name}' not found",
        )

    count, errors = await _index_documents_es(body.table_name, body.documents, body.metadatas)
    if count == 0 and errors:
        log_admin_action(
            actor=current_user,
            resource="vector_stores",
            action="add_documents",
            result="failure",
            target=body.table_name,
            errors=errors,
        )
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Failed to index documents via Elasticsearch MCP",
        )

    store.mutate_record(
        "vector_stores",
        body.table_name,
        lambda record: {
            **record,
            "documents_added": record.get("documents_added", 0) + count,
        },
    )
    log_admin_action(
        actor=current_user,
        resource="vector_stores",
        action="add_documents",
        result="success",
        target=body.table_name,
        documents_added=count,
        errors=errors,
    )
    return DocumentAddResponse(documents_added=count, status="partially_indexed" if errors else "indexed")


@router.post("/query", response_model=RAGQueryResponse)
async def rag_query(
    body: RAGQueryRequest,
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(get_current_user),
):
    """Execute a search-backed RAG query using Elasticsearch semantic retrieval."""
    if not store.has_record("vector_stores", body.table_name):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Vector store '{body.table_name}' not found",
        )

    context_docs: List[Any] = []
    try:
        context_docs = await _similarity_search_es(body.table_name, body.query, body.k)
    except Exception as exc:
        logger.warning("Elasticsearch similarity search failed", reason=str(exc), table=body.table_name)

    context_text = "\n\n".join(d.get("content", "") for d in context_docs[:3])
    answer = (
        f"[Retrieved {len(context_docs)} document(s) from Elasticsearch knowledge base '{body.table_name}']\n"
        f"Top evidence:\n{context_text}\n\n"
        "Use PAL workbench or a direct SAP AI Core inference flow to interpret the retrieved evidence."
    ) if context_docs else (
        f"No documents found in '{body.table_name}' for query: {body.query}"
    )

    return RAGQueryResponse(
        query=body.query,
        table_name=body.table_name,
        context_docs=context_docs,
        answer=answer,
        source="elasticsearch-mcp",
    )


@router.post("/similarity-search")
async def similarity_search(
    body: SimilaritySearchRequest,
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(get_current_user),
):
    """Perform semantic similarity search directly on an Elasticsearch-backed knowledge base."""
    if not store.has_record("vector_stores", body.table_name):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Vector store '{body.table_name}' not found",
        )

    results: List[Any] = []
    try:
        results = await _similarity_search_es(body.table_name, body.query, body.k)
    except Exception as exc:
        logger.warning("Elasticsearch similarity search failed", reason=str(exc), table=body.table_name)

    return {"results": results, "status": "completed"}
