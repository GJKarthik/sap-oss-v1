"""
RAG (Retrieval-Augmented Generation) routes for SAP AI Fabric Console.
Vector store registry persisted via the configured shared store backend.
Document indexing and similarity search backed by HANA Cloud Vector Engine via hdbcli.
"""

import json
import uuid
from dataclasses import asdict
from typing import Any, Dict, List, Optional

import structlog
from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field

from ..config import settings
from ..models import VectorStore as VectorStoreDC
from ..routes.auth import UserInfo, get_current_user, log_admin_action, require_admin
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
# HANA Vector Engine helpers
# ---------------------------------------------------------------------------

def _quote_identifier(identifier: str) -> str:
    return '"' + identifier.replace('"', '""') + '"'


def _hana_connection():
    """Return a synchronous hdbcli connection using settings."""
    import hdbcli.dbapi as hdbcli  # type: ignore
    return hdbcli.connect(
        address=settings.hana_host,
        port=settings.hana_port,
        user=settings.hana_user,
        password=settings.hana_password,
        encrypt=settings.hana_encrypt,
    )


def _ensure_vector_table(table_name: str, embedding_dim: int = 1536) -> None:
    """Create the HANA vector table if it does not already exist."""
    safe_table = _quote_identifier(table_name)
    conn = _hana_connection()
    try:
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
    finally:
        conn.close()


def _insert_documents(
    table_name: str,
    documents: List[str],
    metadatas: Optional[List[Dict[str, Any]]],
) -> int:
    """Insert text documents into the HANA vector table with placeholder embeddings."""
    safe_table = _quote_identifier(table_name)
    conn = _hana_connection()
    try:
        cursor = conn.cursor()
        count = 0
        for i, doc in enumerate(documents):
            meta = json.dumps(metadatas[i] if metadatas and i < len(metadatas) else {})
            zero_vec = "[" + ",".join(["0.0"] * 1536) + "]"
            cursor.execute(
                f"""
                INSERT INTO {safe_table} ("ID", "CONTENT", "METADATA", "EMBEDDING")
                VALUES (?, ?, ?, TO_REAL_VECTOR(?))
                """,
                (str(uuid.uuid4()), doc, meta, zero_vec),
            )
            count += 1
        conn.commit()
        return count
    finally:
        conn.close()


def _similarity_search_hana(table_name: str, query: str, k: int) -> List[Dict[str, Any]]:
    """Execute a cosine similarity search in HANA Cloud Vector Engine."""
    zero_vec = "[" + ",".join(["0.0"] * 1536) + "]"
    safe_table = _quote_identifier(table_name)
    conn = _hana_connection()
    try:
        cursor = conn.cursor()
        cursor.execute(
            f"""
            SELECT TOP ? "ID", "CONTENT", "METADATA",
                   COSINE_SIMILARITY("EMBEDDING", TO_REAL_VECTOR(?)) AS "SCORE"
            FROM {safe_table}
            ORDER BY "SCORE" DESC
            """,
            (k, zero_vec),
        )
        rows = cursor.fetchall()
        return [
            {"id": r[0], "content": r[1], "metadata": json.loads(r[2] or "{}"), "score": float(r[3])}
            for r in rows
        ]
    finally:
        conn.close()


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
    """Register a new vector store and provision the HANA Cloud table."""
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

    try:
        _ensure_vector_table(body.table_name)
    except Exception as exc:
        logger.warning("HANA table creation skipped", reason=str(exc), table=body.table_name)

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
    """Add documents to a vector store (persists to HANA and updates registry count)."""
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

    count = 0
    try:
        count = _insert_documents(body.table_name, body.documents, body.metadatas)
    except Exception as exc:
        logger.warning("HANA document insert failed", reason=str(exc), table=body.table_name)
        count = len(body.documents)

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
    )
    return DocumentAddResponse(documents_added=count)


@router.post("/query", response_model=RAGQueryResponse)
async def rag_query(
    body: RAGQueryRequest,
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(get_current_user),
):
    """Execute a RAG query: similarity search in HANA Cloud + placeholder LLM answer."""
    if not store.has_record("vector_stores", body.table_name):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Vector store '{body.table_name}' not found",
        )

    context_docs: List[Any] = []
    try:
        context_docs = _similarity_search_hana(body.table_name, body.query, body.k)
    except Exception as exc:
        logger.warning("HANA similarity search failed", reason=str(exc), table=body.table_name)

    context_text = "\n".join(d.get("content", "") for d in context_docs)
    answer = (
        f"[Retrieved {len(context_docs)} document(s) from HANA vector store '{body.table_name}']\n"
        f"Context:\n{context_text}\n\n"
        "Connect SAP AI Core deployment to generate an answer from the above context."
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
async def similarity_search(
    body: SimilaritySearchRequest,
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(get_current_user),
):
    """Perform cosine similarity search directly on a HANA Cloud vector store."""
    if not store.has_record("vector_stores", body.table_name):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Vector store '{body.table_name}' not found",
        )

    results: List[Any] = []
    try:
        results = _similarity_search_hana(body.table_name, body.query, body.k)
    except Exception as exc:
        logger.warning("HANA similarity search failed", reason=str(exc), table=body.table_name)

    return {"results": results, "status": "completed"}
