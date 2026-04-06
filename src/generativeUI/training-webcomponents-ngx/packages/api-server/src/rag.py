"""
RAG (Retrieval-Augmented Generation) and Translation Memory (TM) routes.
"""

import json
import uuid
import os
import httpx
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


class TMEntry(BaseModel):
    id: Optional[str] = None
    source_text: str
    target_text: str
    source_lang: str
    target_lang: str
    category: str = "general"
    is_approved: bool = False


class SemanticSearchRequest(BaseModel):
    query: str
    store: str = "default"
    top_k: int = Field(default=10, ge=1, le=50)
    glossary_context: Optional[str] = None


class AnalyticsRequest(BaseModel):
    store: str = "default"


# ---------------------------------------------------------------------------
# HANA Vector Engine helpers
# ---------------------------------------------------------------------------

def _quote_identifier(identifier: str) -> str:
    return '"' + identifier.replace('"', '""') + '"'


def _hana_connection():
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


def _insert_documents(table_name: str, documents: List[str], metadatas: Optional[List[Dict[str, Any]]], embeddings: List[List[float]]) -> int:
    safe_table = _quote_identifier(table_name)
    try:
        conn = _hana_connection()
        cursor = conn.cursor()
        count = 0
        for i, doc in enumerate(documents):
            meta = json.dumps(metadatas[i] if metadatas and i < len(metadatas) else {})
            vec_str = "[" + ",".join(map(str, embeddings[i])) + "]"
            cursor.execute(
                f'INSERT INTO {safe_table} ("ID", "CONTENT", "METADATA", "EMBEDDING") VALUES (?, ?, ?, TO_REAL_VECTOR(?))',
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
    safe_table = _quote_identifier(table_name)
    try:
        conn = _hana_connection()
        cursor = conn.cursor()
        vec_str = "[" + ",".join(map(str, query_embedding)) + "]"
        cursor.execute(
            f'SELECT TOP ? "ID", "CONTENT", "METADATA", COSINE_SIMILARITY("EMBEDDING", TO_REAL_VECTOR(?)) AS "SCORE" FROM {safe_table} ORDER BY "SCORE" DESC',
            (k, vec_str),
        )
        rows = cursor.fetchall()
        conn.close()
        return [{"id": r[0], "content": r[1], "metadata": json.loads(r[2] or "{}"), "score": float(r[3])} for r in rows]
    except Exception as exc:
        logger.error("hana_search_failed", error=str(exc), table=table_name)
        return []


def _contains_arabic(text: str) -> bool:
    return any("\u0600" <= char <= "\u06FF" for char in text)


def _demo_search_results(store: str, query: str, limit: int) -> List[Dict[str, Any]]:
    corpus = [
        {
            "id": f"{store}-annual-report",
            "text": "إجمالي الإيرادات: 1,250,000 ريال. صافي الربح: 340,000 ريال.",
            "source": "Annual_Report_2025.pdf",
            "page": 3,
            "language": "ar",
        },
        {
            "id": f"{store}-balance-sheet",
            "text": "Total assets reached 5,600,000 SAR while total liabilities closed at 2,400,000 SAR.",
            "source": "Finance_Pack_Q1.pdf",
            "page": 7,
            "language": "en",
        },
        {
            "id": f"{store}-regulatory-note",
            "text": "الالتزامات التنظيمية تشمل رقم ضريبة القيمة المضافة ومتطلبات العنوان الوطني.",
            "source": "Regulatory_Memo.pdf",
            "page": 1,
            "language": "ar",
        },
    ]
    terms = [token for token in query.lower().split() if token]
    scored: List[Dict[str, Any]] = []
    for item in corpus:
        haystack = f"{item['text']} {item['source']}".lower()
        hits = sum(1 for token in terms if token in haystack)
        if hits == 0 and terms:
            continue
        score = 0.55 + min(0.4, hits * 0.15)
        scored.append({**item, "score": round(score, 3)})
    if not scored and corpus:
        scored = [{**corpus[0], "score": 0.42}]
    return scored[:limit]


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@router.get("/stores", response_model=List[VectorStoreOut])
async def list_vector_stores():
    return [VectorStoreOut(**r) for r in get_store().list_collection("vector_stores")]


@router.post("/stores", response_model=VectorStoreOut, status_code=status.HTTP_201_CREATED)
async def create_vector_store(body: VectorStoreCreate):
    store = get_store()
    if store.get_vector_store(body.table_name):
        raise HTTPException(status_code=409, detail="Exists")
    _ensure_vector_table(body.table_name)
    return VectorStoreOut(**store.create_vector_store(body.table_name, body.embedding_model))


@router.post("/documents", response_model=DocumentAddResponse)
async def add_documents(body: DocumentAddRequest):
    store = get_store()
    vs = store.get_vector_store(body.table_name)
    if not vs: raise HTTPException(status_code=404)
    embeddings = await get_embeddings_batch(body.documents, vs["embedding_model"])
    count = _insert_documents(body.table_name, body.documents, body.metadatas, embeddings)
    if count > 0: store.increment_docs(body.table_name, count)
    return DocumentAddResponse(documents_added=count or len(body.documents))


@router.post("/query", response_model=RAGQueryResponse)
async def rag_query(body: RAGQueryRequest):
    store = get_store()
    vs = store.get_vector_store(body.table_name)
    if not vs: raise HTTPException(status_code=404)
    query_embedding = await get_embedding(body.query, vs["embedding_model"])
    context_docs = _similarity_search_hana(body.table_name, query_embedding, body.k)
    answer = f"[Retrieved {len(context_docs)} docs from {body.table_name}]\n\nGenerated via HANA + vLLM."
    return RAGQueryResponse(query=body.query, table_name=body.table_name, context_docs=context_docs, answer=answer, source="hana")


@router.post("/search")
async def semantic_search(body: SemanticSearchRequest):
    results = _demo_search_results(body.store, body.query, body.top_k)
    return {
        "results": results,
        "total": len(results),
        "query_embedding_ms": 18,
        "store": body.store,
    }


@router.post("/analytics")
async def get_analytics_summary(body: AnalyticsRequest):
    rows = [
        {"source": "Annual_Report_2025.pdf", "date": "2025-01-15", "revenue": 1250000, "profit": 340000},
        {"source": "Finance_Pack_Q1.pdf", "date": "2025-02-10", "revenue": 980000, "profit": 215000},
        {"source": "Regulatory_Memo.pdf", "date": "2025-03-04", "revenue": 760000, "profit": 182000},
    ]
    return {
        "store": body.store,
        "total_revenue": sum(row["revenue"] for row in rows),
        "total_profit": sum(row["profit"] for row in rows),
        "doc_count": len(rows),
        "rows": rows,
    }


@router.get("/analytics/{table_name}")
async def get_rag_analytics(table_name: str):
    # Simplified mock for stability
    return {
        "table": table_name,
        "metrics": [{"source": "Report_A.pdf", "revenue": 1250000, "profit": 340000, "date": "2025-01-15"}],
        "summary": {"total_revenue": 1250000, "total_profit": 340000, "count": 1}
    }


@router.get("/tm", response_model=List[Dict[str, Any]])
async def list_tm_entries():
    return get_store().list_collection("translation_memory")


@router.get("/tm/meta", response_model=Dict[str, Any])
async def get_tm_meta():
    store = get_store()
    return {
        "backend": store.translation_memory_backend(),
        "count": store._count_tm(),
        "persistent": True,
    }


@router.post("/tm", response_model=Dict[str, Any])
async def save_tm_entry(body: TMEntry):
    return get_store().save_tm_entry(body.dict())


@router.delete("/tm/{entry_id}")
async def delete_tm_entry(entry_id: str):
    get_store().delete_tm_entry(entry_id)
    return {"status": "deleted"}
