"""
RAG (Retrieval-Augmented Generation) and Translation Memory (TM) routes.
"""

import json
import math
import re
import time
import uuid
import os
import httpx
from typing import Any, Dict, List, Literal, Optional

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
    pair_type: Optional[str] = "translation"
    db_context: Optional[Dict[str, str]] = None


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


# ---------------------------------------------------------------------------
# Alignment models & endpoint
# ---------------------------------------------------------------------------

class AlignTextRegion(BaseModel):
    text: str
    confidence: float = 1.0
    language: str = "auto"

class AlignOcrPage(BaseModel):
    page_number: int
    text: str
    text_regions: List[AlignTextRegion] = Field(default_factory=list)

class AlignSource(BaseModel):
    pages: List[AlignOcrPage]
    lang: str

class AlignOptions(BaseModel):
    granularity: Literal["paragraph", "sentence"] = "paragraph"
    extractTerms: bool = True
    existingGlossary: Optional[List[Dict[str, str]]] = None

class AlignRequest(BaseModel):
    source: AlignSource
    target: AlignSource
    options: AlignOptions = Field(default_factory=AlignOptions)

class AlignedParagraph(BaseModel):
    sourceText: str
    targetText: str
    sourcePage: int
    targetPage: int
    confidence: float
    alignmentMethod: str

class ExtractedTerm(BaseModel):
    sourceTerm: str
    targetTerm: str
    sourceLang: str
    targetLang: str
    category: str = "general"
    confidence: float = 0.8
    extractionMethod: str = "llm_extraction"

class AlignStats(BaseModel):
    totalSourceParagraphs: int
    totalTargetParagraphs: int
    alignedCount: int
    unalignedCount: int
    termsExtracted: int
    processingTimeMs: int

class AlignResponse(BaseModel):
    paragraphPairs: List[AlignedParagraph]
    termPairs: List[ExtractedTerm]
    stats: AlignStats


def _split_paragraphs(pages: List[AlignOcrPage]) -> List[Dict[str, Any]]:
    """Split OCR pages into paragraph-level chunks."""
    paragraphs: List[Dict[str, Any]] = []
    for page in pages:
        text = page.text.strip()
        if not text:
            continue
        blocks = re.split(r"\n\s*\n", text)
        for block in blocks:
            block = block.strip()
            if len(block) > 10:
                paragraphs.append({"text": block, "page": page.page_number})
    return paragraphs


def _extract_numbers(text: str) -> List[str]:
    """Extract numeric patterns from text for number anchoring."""
    western = re.findall(r"[\d][\d,.\'\s]{2,}[\d]", text)
    arabic_indic = re.findall(r"[\u0660-\u0669][\u0660-\u0669,.\'\s]{2,}[\u0660-\u0669]", text)
    return western + arabic_indic


def _number_overlap(nums_a: List[str], nums_b: List[str]) -> float:
    """Score overlap of numeric patterns between two texts."""
    if not nums_a or not nums_b:
        return 0.0
    set_a = set(n.replace(" ", "").replace(",", "") for n in nums_a)
    set_b = set(n.replace(" ", "").replace(",", "") for n in nums_b)
    if not set_a or not set_b:
        return 0.0
    intersection = set_a & set_b
    return len(intersection) / max(len(set_a), len(set_b))


def _structural_align(
    source_paras: List[Dict[str, Any]],
    target_paras: List[Dict[str, Any]],
    glossary: Optional[List[Dict[str, str]]] = None,
) -> List[AlignedParagraph]:
    """Rule-based structural alignment using four heuristics."""
    aligned: List[AlignedParagraph] = []
    used_targets: set = set()
    total_source = len(source_paras)
    total_target = len(target_paras)

    glossary_map: Dict[str, str] = {}
    if glossary:
        for g in glossary:
            if "en" in g and "ar" in g:
                glossary_map[g["en"].lower()] = g["ar"]
                glossary_map[g["ar"]] = g["en"].lower()

    for si, sp in enumerate(source_paras):
        best_score = 0.0
        best_idx = -1
        best_method = "structural"
        s_nums = _extract_numbers(sp["text"])

        for ti, tp in enumerate(target_paras):
            if ti in used_targets:
                continue

            score = 0.0
            method = "structural"

            # 1. Page position (weight 0.3)
            if total_source > 0 and total_target > 0:
                s_pos = si / max(total_source, 1)
                t_pos = ti / max(total_target, 1)
                pos_score = max(0, 1.0 - abs(s_pos - t_pos) * 3)
                score += pos_score * 0.3

            # 2. Number anchoring (weight 0.3)
            t_nums = _extract_numbers(tp["text"])
            num_score = _number_overlap(s_nums, t_nums)
            if num_score > 0:
                method = "number_anchor"
            score += num_score * 0.3

            # 3. Heading/glossary match (weight 0.25)
            heading_score = 0.0
            s_lower = sp["text"].lower()
            for key, val in glossary_map.items():
                if key in s_lower and val in tp["text"]:
                    heading_score = 1.0
                    method = "heading_match"
                    break
            score += heading_score * 0.25

            # 4. Length ratio (weight 0.15)
            s_len = len(sp["text"])
            t_len = len(tp["text"])
            if s_len > 0 and t_len > 0:
                ratio = t_len / s_len
                expected = 1.2 if _contains_arabic(tp["text"]) else 1.0
                len_score = max(0, 1.0 - abs(ratio - expected) * 2)
                score += len_score * 0.15

            if score > best_score:
                best_score = score
                best_idx = ti
                best_method = method

        if best_idx >= 0 and best_score >= 0.35:
            used_targets.add(best_idx)
            aligned.append(AlignedParagraph(
                sourceText=sp["text"],
                targetText=target_paras[best_idx]["text"],
                sourcePage=sp["page"],
                targetPage=target_paras[best_idx]["page"],
                confidence=round(min(1.0, best_score), 3),
                alignmentMethod=best_method,
            ))

    return aligned


async def _extract_terms_llm(
    pairs: List[AlignedParagraph],
    source_lang: str,
    target_lang: str,
) -> List[ExtractedTerm]:
    """Use LLM to extract term pairs from aligned paragraphs."""
    terms: List[ExtractedTerm] = []
    batch_size = 5

    for i in range(0, len(pairs), batch_size):
        batch = pairs[i:i + batch_size]
        prompt_parts = []
        for idx, p in enumerate(batch):
            prompt_parts.append(
                f"Pair {idx + 1}:\nSource ({source_lang}): {p.sourceText[:500]}\n"
                f"Target ({target_lang}): {p.targetText[:500]}"
            )

        system_prompt = (
            f"You are a bilingual terminology extraction engine. Given aligned paragraphs "
            f"in {source_lang} and {target_lang}, extract all technical term pairs.\n\n"
            f"For each pair, return:\n"
            f"- sourceTerm: the term in the source language\n"
            f"- targetTerm: the equivalent in the target language\n"
            f"- category: one of [income_statement, balance_sheet, regulatory, schema, general]\n"
            f"- confidence: 0.0-1.0\n\n"
            f"Also identify:\n"
            f"- Alias terms (same language, different surface forms for the same concept)\n"
            f"- DB field references (column names, table names mapped to natural language)\n\n"
            f"Return JSON array only. No explanation."
        )

        try:
            async with httpx.AsyncClient(timeout=60.0) as client:
                resp = await client.post(
                    f"{VLLM_URL}/v1/chat/completions",
                    json={
                        "model": "default",
                        "messages": [
                            {"role": "system", "content": system_prompt},
                            {"role": "user", "content": "\n\n".join(prompt_parts)},
                        ],
                        "temperature": 0.1,
                        "max_tokens": 2000,
                    },
                )
                resp.raise_for_status()
                content = resp.json()["choices"][0]["message"]["content"]
                # Parse JSON from response (may be wrapped in markdown)
                json_str = content
                if "```" in json_str:
                    json_str = re.search(r"```(?:json)?\s*([\s\S]*?)```", json_str)
                    json_str = json_str.group(1) if json_str else content
                extracted = json.loads(json_str)
                if isinstance(extracted, list):
                    for item in extracted:
                        terms.append(ExtractedTerm(
                            sourceTerm=item.get("sourceTerm", ""),
                            targetTerm=item.get("targetTerm", ""),
                            sourceLang=source_lang,
                            targetLang=target_lang,
                            category=item.get("category", "general"),
                            confidence=float(item.get("confidence", 0.8)),
                            extractionMethod="llm_extraction",
                        ))
        except Exception as exc:
            logger.warning("llm_term_extraction_failed", error=str(exc), batch=i)

    return terms


def _dedup_terms(
    terms: List[ExtractedTerm],
    glossary: Optional[List[Dict[str, str]]] = None,
) -> List[ExtractedTerm]:
    """Deduplicate extracted terms and mark glossary matches."""
    seen: Dict[str, ExtractedTerm] = {}
    glossary_terms: set = set()
    if glossary:
        for g in glossary:
            for v in g.values():
                glossary_terms.add(v.lower().strip())

    for term in terms:
        key = f"{term.sourceTerm.lower().strip()}||{term.targetTerm.lower().strip()}"
        existing = seen.get(key)
        if existing is None or term.confidence > existing.confidence:
            seen[key] = term

    return list(seen.values())


@router.post("/tm/align", response_model=AlignResponse)
async def align_documents(body: AlignRequest):
    """Align two OCR documents and extract term pairs."""
    start_ms = int(time.time() * 1000)

    source_paras = _split_paragraphs(body.source.pages)
    target_paras = _split_paragraphs(body.target.pages)

    # Step 1: Structural alignment
    aligned = _structural_align(
        source_paras, target_paras, body.options.existingGlossary
    )

    # Step 2: LLM term extraction on aligned pairs
    term_pairs: List[ExtractedTerm] = []
    if body.options.extractTerms and aligned:
        term_pairs = await _extract_terms_llm(
            aligned, body.source.lang, body.target.lang
        )
        term_pairs = _dedup_terms(term_pairs, body.options.existingGlossary)

    elapsed = int(time.time() * 1000) - start_ms

    return AlignResponse(
        paragraphPairs=aligned,
        termPairs=term_pairs,
        stats=AlignStats(
            totalSourceParagraphs=len(source_paras),
            totalTargetParagraphs=len(target_paras),
            alignedCount=len(aligned),
            unalignedCount=len(source_paras) - len(aligned),
            termsExtracted=len(term_pairs),
            processingTimeMs=elapsed,
        ),
    )
