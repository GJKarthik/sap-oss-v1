"""
Personal knowledge base routes backed by HANA Cloud vectors when available.

This module is the first integrated slice of a Graphify-style personal memory
system. It stays inside the existing API server instead of introducing another
service, scopes data by owner, and falls back to an in-process preview backend
when HANA is unavailable.
"""

from __future__ import annotations

import hashlib
import json
import math
import re
import uuid
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Sequence

import httpx
import structlog
from fastapi import APIRouter, HTTPException, Query, Request, status
from pydantic import BaseModel, Field

from .hana_config import HANA_ENCRYPT, HANA_HOST, HANA_PASSWORD, HANA_PORT, HANA_USER, VLLM_URL
from .identity import resolve_effective_owner

router = APIRouter()
logger = structlog.get_logger("training-webcomponents-ngx.personal-knowledge")

EMBEDDING_DIM = 1536
BASES_TABLE = "PERSONAL_KNOWLEDGE_BASES"
CHUNKS_TABLE = "PERSONAL_KNOWLEDGE_CHUNKS"
WIKI_TABLE = "PERSONAL_KNOWLEDGE_WIKI"

EN_STOPWORDS = {
    "about", "after", "again", "also", "always", "among", "been", "being", "between", "built",
    "could", "daily", "document", "documents", "during", "each", "from", "have", "into", "just",
    "knowledge", "launch", "memory", "notes", "over", "page", "pages", "personal", "project",
    "should", "some", "summary", "that", "their", "them", "there", "these", "this", "those",
    "through", "what", "when", "where", "which", "while", "with", "work", "workspace", "would",
}
AR_STOPWORDS = {
    "هذا", "هذه", "ذلك", "هناك", "الى", "إلى", "على", "من", "عن", "في", "تم", "ثم", "كما",
    "وقد", "كان", "كانت", "التي", "الذي", "العمل", "الوثيقة", "المعرفة", "ملاحظات", "مستند",
}


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _slugify(value: str) -> str:
    normalized = re.sub(r"[^a-zA-Z0-9]+", "-", value.strip().lower()).strip("-")
    return normalized or "knowledge-base"


def _normalize_owner_id(owner_id: Optional[str]) -> str:
    cleaned = (owner_id or "").strip()
    return cleaned or "personal-user"


def _excerpt(text: str, limit: int = 220) -> str:
    compact = re.sub(r"\s+", " ", text).strip()
    if len(compact) <= limit:
        return compact
    return compact[: limit - 1].rstrip() + "…"


def _local_embedding(text: str, dim: int = EMBEDDING_DIM) -> List[float]:
    vector = [0.0] * dim
    tokens = re.findall(r"[\w\u0600-\u06FF]+", text.lower())
    if not tokens:
        return vector
    for token in tokens:
        digest = hashlib.sha256(token.encode("utf-8")).digest()
        index = int.from_bytes(digest[:4], "big") % dim
        sign = 1.0 if digest[4] % 2 == 0 else -1.0
        vector[index] += sign
    norm = math.sqrt(sum(value * value for value in vector))
    if norm == 0:
        return vector
    return [value / norm for value in vector]


def _cosine_similarity(left: Sequence[float], right: Sequence[float]) -> float:
    if not left or not right:
        return 0.0
    numerator = sum(a * b for a, b in zip(left, right))
    left_norm = math.sqrt(sum(a * a for a in left))
    right_norm = math.sqrt(sum(b * b for b in right))
    if left_norm == 0 or right_norm == 0:
        return 0.0
    return numerator / (left_norm * right_norm)


async def _embed_texts(texts: List[str], model: str) -> List[List[float]]:
    if not texts:
        return []
    try:
        async with httpx.AsyncClient(timeout=8.0) as client:
            response = await client.post(
                f"{VLLM_URL}/v1/embeddings",
                json={"input": texts, "model": model},
            )
            response.raise_for_status()
            payload = response.json()
            data = payload.get("data") or []
            embeddings = [item.get("embedding") for item in data]
            if len(embeddings) == len(texts) and all(isinstance(item, list) for item in embeddings):
                return embeddings  # type: ignore[return-value]
    except Exception as exc:
        logger.warning("knowledge_embeddings_fell_back_to_local", error=str(exc), count=len(texts))
    return [_local_embedding(text) for text in texts]


def _build_overview_content(base_name: str, documents: Sequence[str]) -> str:
    if not documents:
        return (
            f"# {base_name}\n\n"
            "This personal knowledge base is ready. Add notes, documents, and observations to start building a durable memory."
        )
    bullets = "\n".join(f"- {_excerpt(document, 180)}" for document in documents[:6])
    return (
        f"# {base_name}\n\n"
        "## What this knowledge base currently knows\n"
        f"{bullets}\n\n"
        "Refine this page as the durable summary for your personal agent."
    )


def _compose_answer(base_name: str, query: str, docs: Sequence[Dict[str, Any]]) -> str:
    if not docs:
        return (
            f"I could not find a direct answer in {base_name} yet. "
            "Add more notes, documents, or observations to strengthen this knowledge base."
        )
    bullets = "\n".join(f"- {_excerpt(str(doc.get('content', '')), 180)}" for doc in docs[:4])
    return (
        f'Here is the strongest signal from {base_name} for "{query}":\n'
        f"{bullets}\n\n"
        "Use the personal wiki to turn these fragments into a durable summary."
    )


def _extract_candidate_entities(text: str, limit: int = 5) -> List[str]:
    tokens = re.findall(r"[A-Za-z\u0600-\u06FF][A-Za-z0-9\u0600-\u06FF_-]{2,}", text)
    counts: Counter[str] = Counter()
    original_case: Dict[str, str] = {}
    for token in tokens:
        normalized = token.lower()
        if normalized in EN_STOPWORDS or normalized in AR_STOPWORDS:
            continue
        if normalized.isdigit():
            continue
        if len(normalized) < 4:
            continue
        counts[normalized] += 1
        original_case.setdefault(normalized, token)
    return [original_case[token] for token, _ in counts.most_common(limit)]


def _entity_id(owner_id: str, label: str) -> str:
    digest = hashlib.sha1(f"{owner_id}:{label.lower()}".encode("utf-8")).hexdigest()[:12]
    return f"entity-{digest}"


class KnowledgeGraphSummary(BaseModel):
    node_count: int
    edge_count: int
    node_types: List[Dict[str, Any]] = Field(default_factory=list)
    edge_types: List[Dict[str, Any]] = Field(default_factory=list)
    status: str = "preview_ready"


class KnowledgeGraphQueryRequest(BaseModel):
    owner_id: Optional[str] = None
    query: str = "show graph relationships"
    base_id: Optional[str] = None
    limit: int = Field(default=40, ge=5, le=200)


class KnowledgeGraphQueryResponse(BaseModel):
    rows: List[Dict[str, Any]] = Field(default_factory=list)
    row_count: int = 0
    status: str = "preview_ready"


class KnowledgeBaseCreate(BaseModel):
    owner_id: Optional[str] = None
    name: str
    description: str = ""
    embedding_model: str = "default"


class KnowledgeBaseOut(BaseModel):
    id: str
    owner_id: str
    name: str
    slug: str
    description: str = ""
    embedding_model: str = "default"
    documents_added: int = 0
    wiki_pages: int = 0
    created_at: str
    updated_at: str
    storage_backend: str = "preview"


class KnowledgeDocumentAddRequest(BaseModel):
    owner_id: Optional[str] = None
    documents: List[str]
    metadatas: Optional[List[Dict[str, Any]]] = None


class KnowledgeDocumentAddResponse(BaseModel):
    knowledge_base_id: str
    documents_added: int
    wiki_pages_updated: int = 0
    status: str = "indexed"
    storage_backend: str = "preview"


class KnowledgeContextDoc(BaseModel):
    id: str
    content: str
    metadata: Dict[str, Any] = Field(default_factory=dict)
    score: float


class KnowledgeQueryRequest(BaseModel):
    owner_id: Optional[str] = None
    query: str
    k: int = Field(default=4, ge=1, le=12)


class KnowledgeQueryResponse(BaseModel):
    knowledge_base_id: str
    owner_id: str
    query: str
    answer: str
    context_docs: List[KnowledgeContextDoc] = Field(default_factory=list)
    suggested_wiki_page: Optional[str] = None
    source: str = "preview"
    status: str = "completed"


class WikiPageOut(BaseModel):
    slug: str
    title: str
    content: str
    generated: bool = False
    created_at: str
    updated_at: str


class WikiPageUpdateRequest(BaseModel):
    owner_id: Optional[str] = None
    title: str
    content: str


@dataclass
class _KnowledgeBaseRecord:
    id: str
    owner_id: str
    name: str
    slug: str
    description: str
    embedding_model: str
    documents_added: int
    created_at: str
    updated_at: str


class PersonalKnowledgeBackend:
    def __init__(self) -> None:
        self.storage_backend = "preview"
        self._preview_bases: Dict[str, Dict[str, _KnowledgeBaseRecord]] = {}
        self._preview_chunks: Dict[str, List[Dict[str, Any]]] = {}
        self._preview_wiki: Dict[str, Dict[str, Dict[str, Any]]] = {}

        if self._hana_is_available():
            try:
                self._ensure_hana_tables()
                self.storage_backend = "hana"
            except Exception as exc:
                logger.warning("knowledge_backend_fell_back_to_preview", error=str(exc))

    def _hana_is_available(self) -> bool:
        if not HANA_USER or not HANA_PASSWORD or not HANA_HOST:
            return False
        try:
            import hdbcli.dbapi  # type: ignore  # noqa: F401
        except ImportError:
            return False
        return True

    def _hana_connection(self):
        import hdbcli.dbapi as hdbcli  # type: ignore

        return hdbcli.connect(
            address=HANA_HOST,
            port=HANA_PORT,
            user=HANA_USER,
            password=HANA_PASSWORD,
            encrypt=HANA_ENCRYPT,
        )

    def _ensure_hana_tables(self) -> None:
        conn = self._hana_connection()
        cursor = conn.cursor()
        cursor.execute(
            f'''
            CREATE TABLE IF NOT EXISTS "{BASES_TABLE}" (
                "ID" NVARCHAR(64) PRIMARY KEY,
                "OWNER_ID" NVARCHAR(200),
                "NAME" NVARCHAR(250),
                "SLUG" NVARCHAR(250),
                "DESCRIPTION" NCLOB,
                "EMBEDDING_MODEL" NVARCHAR(250),
                "DOCUMENTS_ADDED" INTEGER,
                "CREATED_AT" NVARCHAR(40),
                "UPDATED_AT" NVARCHAR(40)
            )
            '''
        )
        cursor.execute(
            f'''
            CREATE TABLE IF NOT EXISTS "{CHUNKS_TABLE}" (
                "ID" NVARCHAR(64) PRIMARY KEY,
                "BASE_ID" NVARCHAR(64),
                "OWNER_ID" NVARCHAR(200),
                "CONTENT" NCLOB,
                "METADATA" NCLOB,
                "EMBEDDING" REAL_VECTOR({EMBEDDING_DIM}),
                "CREATED_AT" NVARCHAR(40)
            )
            '''
        )
        cursor.execute(
            f'''
            CREATE TABLE IF NOT EXISTS "{WIKI_TABLE}" (
                "ID" NVARCHAR(64) PRIMARY KEY,
                "BASE_ID" NVARCHAR(64),
                "OWNER_ID" NVARCHAR(200),
                "SLUG" NVARCHAR(250),
                "TITLE" NVARCHAR(250),
                "CONTENT" NCLOB,
                "GENERATED" BOOLEAN,
                "CREATED_AT" NVARCHAR(40),
                "UPDATED_AT" NVARCHAR(40)
            )
            '''
        )
        conn.commit()
        conn.close()

    def list_bases(self, owner_id: str) -> List[KnowledgeBaseOut]:
        if self.storage_backend == "hana":
            return self._list_bases_hana(owner_id)
        records = sorted(
            self._preview_bases.get(owner_id, {}).values(),
            key=lambda item: item.updated_at,
            reverse=True,
        )
        return [self._serialize_base(record, self._preview_wiki_count(record.id)) for record in records]

    def create_base(self, owner_id: str, name: str, description: str, embedding_model: str) -> KnowledgeBaseOut:
        owner_id = _normalize_owner_id(owner_id)
        name = name.strip()
        if not name:
            raise HTTPException(status_code=400, detail="Knowledge base name is required.")
        slug = self._next_slug(owner_id, _slugify(name))
        now = _now_iso()
        record = _KnowledgeBaseRecord(
            id=f"kb-{uuid.uuid4().hex[:12]}",
            owner_id=owner_id,
            name=name,
            slug=slug,
            description=description.strip(),
            embedding_model=embedding_model.strip() or "default",
            documents_added=0,
            created_at=now,
            updated_at=now,
        )
        if self.storage_backend == "hana":
            self._create_base_hana(record)
            self._upsert_wiki_hana(
                base_id=record.id,
                owner_id=owner_id,
                slug="overview",
                title="Overview",
                content=_build_overview_content(record.name, []),
                generated=True,
            )
            return self._serialize_base(record, 1)

        self._preview_bases.setdefault(owner_id, {})[record.id] = record
        self._preview_chunks.setdefault(record.id, [])
        self._preview_wiki.setdefault(record.id, {})
        self._preview_wiki[record.id]["overview"] = self._preview_wiki_entry(
            title="Overview",
            content=_build_overview_content(record.name, []),
            generated=True,
        )
        return self._serialize_base(record, 1)

    async def add_documents(
        self,
        base_id: str,
        owner_id: str,
        documents: List[str],
        metadatas: Optional[List[Dict[str, Any]]] = None,
    ) -> KnowledgeDocumentAddResponse:
        owner_id = _normalize_owner_id(owner_id)
        base = self.get_base(base_id, owner_id)
        clean_docs = [document.strip() for document in documents if document.strip()]
        if not clean_docs:
            raise HTTPException(status_code=400, detail="At least one document is required.")

        embeddings = await _embed_texts(clean_docs, base.embedding_model)

        if self.storage_backend == "hana":
            added = self._insert_documents_hana(base, clean_docs, metadatas, embeddings)
            overview = _build_overview_content(base.name, clean_docs[:6])
            self._upsert_wiki_hana(
                base_id=base.id,
                owner_id=owner_id,
                slug="overview",
                title="Overview",
                content=overview,
                generated=True,
            )
            updated_base = self.get_base(base_id, owner_id)
            return KnowledgeDocumentAddResponse(
                knowledge_base_id=updated_base.id,
                documents_added=added,
                wiki_pages_updated=1,
                storage_backend=self.storage_backend,
            )

        chunk_bucket = self._preview_chunks.setdefault(base.id, [])
        for index, document in enumerate(clean_docs):
            chunk_bucket.append(
                {
                    "id": f"chunk-{uuid.uuid4().hex[:12]}",
                    "content": document,
                    "metadata": (metadatas[index] if metadatas and index < len(metadatas) else {}) or {},
                    "embedding": embeddings[index],
                    "created_at": _now_iso(),
                }
            )
        preview_base = self._preview_bases[owner_id][base.id]
        preview_base.documents_added += len(clean_docs)
        preview_base.updated_at = _now_iso()
        self._preview_wiki.setdefault(base.id, {})
        self._preview_wiki[base.id]["overview"] = self._preview_wiki_entry(
            title="Overview",
            content=_build_overview_content(base.name, clean_docs[:6]),
            generated=True,
        )
        return KnowledgeDocumentAddResponse(
            knowledge_base_id=base.id,
            documents_added=len(clean_docs),
            wiki_pages_updated=1,
            storage_backend=self.storage_backend,
        )

    async def query(self, base_id: str, owner_id: str, query: str, k: int) -> KnowledgeQueryResponse:
        owner_id = _normalize_owner_id(owner_id)
        base = self.get_base(base_id, owner_id)
        clean_query = query.strip()
        if not clean_query:
            raise HTTPException(status_code=400, detail="Query is required.")
        embedding = (await _embed_texts([clean_query], base.embedding_model))[0]
        if self.storage_backend == "hana":
            docs = self._search_hana(base.id, owner_id, embedding, k)
        else:
            docs = self._search_preview(base.id, embedding, k)
        answer = _compose_answer(base.name, clean_query, docs)
        return KnowledgeQueryResponse(
            knowledge_base_id=base.id,
            owner_id=owner_id,
            query=clean_query,
            answer=answer,
            context_docs=[KnowledgeContextDoc(**doc) for doc in docs],
            suggested_wiki_page="overview",
            source=self.storage_backend,
        )

    def get_base(self, base_id: str, owner_id: str) -> KnowledgeBaseOut:
        owner_id = _normalize_owner_id(owner_id)
        if self.storage_backend == "hana":
            base = self._get_base_hana(base_id, owner_id)
            if not base:
                raise HTTPException(status_code=404, detail="Knowledge base not found.")
            return base
        record = self._preview_bases.get(owner_id, {}).get(base_id)
        if not record:
            raise HTTPException(status_code=404, detail="Knowledge base not found.")
        return self._serialize_base(record, self._preview_wiki_count(base_id))

    def list_wiki_pages(self, base_id: str, owner_id: str) -> List[WikiPageOut]:
        owner_id = _normalize_owner_id(owner_id)
        self.get_base(base_id, owner_id)
        if self.storage_backend == "hana":
            return self._list_wiki_hana(base_id, owner_id)
        pages = self._preview_wiki.get(base_id, {})
        return [
            WikiPageOut(**value)
            for _, value in sorted(
                pages.items(),
                key=lambda item: item[1]["updated_at"],
                reverse=True,
            )
        ]

    def upsert_wiki_page(
        self,
        base_id: str,
        owner_id: str,
        slug: str,
        title: str,
        content: str,
    ) -> WikiPageOut:
        owner_id = _normalize_owner_id(owner_id)
        base = self.get_base(base_id, owner_id)
        clean_slug = _slugify(slug or title)
        if not title.strip() or not content.strip():
            raise HTTPException(status_code=400, detail="Wiki title and content are required.")
        if self.storage_backend == "hana":
            self._upsert_wiki_hana(
                base_id=base.id,
                owner_id=owner_id,
                slug=clean_slug,
                title=title.strip(),
                content=content.strip(),
                generated=False,
            )
            pages = self._list_wiki_hana(base.id, owner_id)
            return next(page for page in pages if page.slug == clean_slug)

        pages = self._preview_wiki.setdefault(base.id, {})
        existing = pages.get(clean_slug)
        now = _now_iso()
        pages[clean_slug] = {
            "slug": clean_slug,
            "title": title.strip(),
            "content": content.strip(),
            "generated": False,
            "created_at": existing["created_at"] if existing else now,
            "updated_at": now,
        }
        preview_base = self._preview_bases[owner_id][base.id]
        preview_base.updated_at = now
        return WikiPageOut(**pages[clean_slug])

    def graph_summary(self, owner_id: str, base_id: Optional[str] = None) -> KnowledgeGraphSummary:
        owner_id = _normalize_owner_id(owner_id)
        graph = self._build_graph(owner_id, base_id=base_id, query="")
        node_counts = Counter(node["type"] for node in graph["nodes"])
        edge_counts = Counter(edge["relationship"] for edge in graph["edges"])
        return KnowledgeGraphSummary(
            node_count=len(graph["nodes"]),
            edge_count=len(graph["edges"]),
            node_types=[{"type": node_type, "count": count} for node_type, count in node_counts.items()],
            edge_types=[{"type": edge_type, "count": count} for edge_type, count in edge_counts.items()],
            status=f"{self.storage_backend}_ready",
        )

    def graph_query(
        self,
        owner_id: str,
        query: str,
        base_id: Optional[str] = None,
        limit: int = 40,
    ) -> KnowledgeGraphQueryResponse:
        owner_id = _normalize_owner_id(owner_id)
        graph = self._build_graph(owner_id, base_id=base_id, query=query)
        rows = graph["rows"][:limit]
        return KnowledgeGraphQueryResponse(
            rows=rows,
            row_count=len(rows),
            status=f"{self.storage_backend}_ready",
        )

    def _next_slug(self, owner_id: str, candidate: str) -> str:
        existing = {base.slug for base in self.list_bases(owner_id)}
        if candidate not in existing:
            return candidate
        index = 2
        while f"{candidate}-{index}" in existing:
            index += 1
        return f"{candidate}-{index}"

    def _serialize_base(self, record: _KnowledgeBaseRecord, wiki_pages: int) -> KnowledgeBaseOut:
        return KnowledgeBaseOut(
            id=record.id,
            owner_id=record.owner_id,
            name=record.name,
            slug=record.slug,
            description=record.description,
            embedding_model=record.embedding_model,
            documents_added=int(record.documents_added),
            wiki_pages=wiki_pages,
            created_at=record.created_at,
            updated_at=record.updated_at,
            storage_backend=self.storage_backend,
        )

    def _preview_wiki_count(self, base_id: str) -> int:
        return len(self._preview_wiki.get(base_id, {}))

    def _preview_wiki_entry(self, title: str, content: str, generated: bool) -> Dict[str, Any]:
        now = _now_iso()
        return {
            "slug": _slugify(title),
            "title": title,
            "content": content,
            "generated": generated,
            "created_at": now,
            "updated_at": now,
        }

    def _search_preview(self, base_id: str, query_embedding: Sequence[float], k: int) -> List[Dict[str, Any]]:
        matches: List[Dict[str, Any]] = []
        for chunk in self._preview_chunks.get(base_id, []):
            score = _cosine_similarity(query_embedding, chunk.get("embedding") or [])
            matches.append(
                {
                    "id": chunk["id"],
                    "content": chunk["content"],
                    "metadata": chunk.get("metadata") or {},
                    "score": float(score),
                }
            )
        matches.sort(key=lambda item: item["score"], reverse=True)
        return matches[:k]

    def _preview_chunks_for_base(self, base_id: str) -> List[Dict[str, Any]]:
        return sorted(
            self._preview_chunks.get(base_id, []),
            key=lambda item: item.get("created_at", ""),
            reverse=True,
        )

    def _build_graph(self, owner_id: str, base_id: Optional[str], query: str) -> Dict[str, Any]:
        normalized_query = query.strip().lower()
        bases = self.list_bases(owner_id)
        if base_id:
            bases = [base for base in bases if base.id == base_id]

        nodes_by_id: Dict[str, Dict[str, Any]] = {}
        edges: List[Dict[str, Any]] = []

        def add_node(node_id: str, label: str, node_type: str, metadata: Optional[Dict[str, Any]] = None) -> None:
            nodes_by_id.setdefault(
                node_id,
                {
                    "id": node_id,
                    "name": label,
                    "type": node_type,
                    "metadata": metadata or {},
                },
            )

        def add_edge(source: str, target: str, relationship: str) -> None:
            edge_id = f"{source}->{target}:{relationship}"
            if any(item["id"] == edge_id for item in edges):
                return
            edges.append(
                {
                    "id": edge_id,
                    "source": source,
                    "target": target,
                    "relationship": relationship,
                }
            )

        for base in bases:
            add_node(base.id, base.name, "KnowledgeBase", {"slug": base.slug, "description": base.description})
            wiki_pages = self.list_wiki_pages(base.id, owner_id)
            chunks = self._chunks_for_base(base.id, owner_id)

            for page in wiki_pages:
                wiki_id = f"wiki:{base.id}:{page.slug}"
                add_node(wiki_id, page.title, "WikiPage", {"slug": page.slug, "generated": page.generated})
                add_edge(base.id, wiki_id, "summarizes")

                if "document" not in normalized_query:
                    for entity in _extract_candidate_entities(page.content, limit=4):
                        entity_node_id = _entity_id(owner_id, entity)
                        add_node(entity_node_id, entity, "Concept")
                        add_edge(wiki_id, entity_node_id, "mentions")

            for index, chunk in enumerate(chunks[:12]):
                metadata = chunk.get("metadata") or {}
                chunk_label = (
                    str(metadata.get("file_name") or metadata.get("title") or metadata.get("source") or f"Document {index + 1}")
                )
                add_node(chunk["id"], chunk_label[:40], "Document", metadata)
                add_edge(base.id, chunk["id"], "contains")

                if "wiki" not in normalized_query:
                    for entity in _extract_candidate_entities(str(chunk.get("content") or ""), limit=4):
                        entity_node_id = _entity_id(owner_id, entity)
                        add_node(entity_node_id, entity, "Concept")
                        add_edge(chunk["id"], entity_node_id, "mentions")

        rows = self._graph_rows_for_query(normalized_query, nodes_by_id, edges)
        return {"nodes": list(nodes_by_id.values()), "edges": edges, "rows": rows}

    def _graph_rows_for_query(
        self,
        query: str,
        nodes_by_id: Dict[str, Dict[str, Any]],
        edges: List[Dict[str, Any]],
    ) -> List[Dict[str, Any]]:
        if "node" in query and "relationship" not in query and "edge" not in query:
            return list(nodes_by_id.values())

        filtered_edges = edges
        if "wiki" in query:
            filtered_edges = [edge for edge in edges if edge["relationship"] == "summarizes" or nodes_by_id[edge["source"]]["type"] == "WikiPage"]
        elif "document" in query or "source" in query:
            filtered_edges = [edge for edge in edges if nodes_by_id[edge["source"]]["type"] in {"KnowledgeBase", "Document"} and nodes_by_id[edge["target"]]["type"] in {"Document", "Concept"}]
        elif "concept" in query or "entity" in query or "people" in query:
            filtered_edges = [edge for edge in edges if nodes_by_id[edge["target"]]["type"] == "Concept"]

        return [
            {
                "source_id": edge["source"],
                "source_name": nodes_by_id[edge["source"]]["name"],
                "source_type": nodes_by_id[edge["source"]]["type"],
                "target_id": edge["target"],
                "target_name": nodes_by_id[edge["target"]]["name"],
                "target_type": nodes_by_id[edge["target"]]["type"],
                "relationship": edge["relationship"],
            }
            for edge in filtered_edges
        ]

    def _chunks_for_base(self, base_id: str, owner_id: str) -> List[Dict[str, Any]]:
        if self.storage_backend == "hana":
            return self._list_chunks_hana(base_id, owner_id)
        return self._preview_chunks_for_base(base_id)

    def _list_bases_hana(self, owner_id: str) -> List[KnowledgeBaseOut]:
        conn = self._hana_connection()
        cursor = conn.cursor()
        cursor.execute(
            f'''
            SELECT "ID", "OWNER_ID", "NAME", "SLUG", "DESCRIPTION", "EMBEDDING_MODEL",
                   "DOCUMENTS_ADDED", "CREATED_AT", "UPDATED_AT"
            FROM "{BASES_TABLE}"
            WHERE "OWNER_ID" = ?
            ORDER BY "UPDATED_AT" DESC
            ''',
            (owner_id,),
        )
        rows = cursor.fetchall()
        conn.close()
        results: List[KnowledgeBaseOut] = []
        for row in rows:
            record = _KnowledgeBaseRecord(
                id=row[0],
                owner_id=row[1],
                name=row[2],
                slug=row[3],
                description=row[4] or "",
                embedding_model=row[5] or "default",
                documents_added=int(row[6] or 0),
                created_at=row[7],
                updated_at=row[8],
            )
            results.append(self._serialize_base(record, self._wiki_count_hana(record.id, owner_id)))
        return results

    def _get_base_hana(self, base_id: str, owner_id: str) -> Optional[KnowledgeBaseOut]:
        conn = self._hana_connection()
        cursor = conn.cursor()
        cursor.execute(
            f'''
            SELECT "ID", "OWNER_ID", "NAME", "SLUG", "DESCRIPTION", "EMBEDDING_MODEL",
                   "DOCUMENTS_ADDED", "CREATED_AT", "UPDATED_AT"
            FROM "{BASES_TABLE}"
            WHERE "ID" = ? AND "OWNER_ID" = ?
            ''',
            (base_id, owner_id),
        )
        row = cursor.fetchone()
        conn.close()
        if not row:
            return None
        record = _KnowledgeBaseRecord(
            id=row[0],
            owner_id=row[1],
            name=row[2],
            slug=row[3],
            description=row[4] or "",
            embedding_model=row[5] or "default",
            documents_added=int(row[6] or 0),
            created_at=row[7],
            updated_at=row[8],
        )
        return self._serialize_base(record, self._wiki_count_hana(base_id, owner_id))

    def _create_base_hana(self, record: _KnowledgeBaseRecord) -> None:
        conn = self._hana_connection()
        cursor = conn.cursor()
        cursor.execute(
            f'''
            INSERT INTO "{BASES_TABLE}"
                ("ID", "OWNER_ID", "NAME", "SLUG", "DESCRIPTION", "EMBEDDING_MODEL",
                 "DOCUMENTS_ADDED", "CREATED_AT", "UPDATED_AT")
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ''',
            (
                record.id,
                record.owner_id,
                record.name,
                record.slug,
                record.description,
                record.embedding_model,
                record.documents_added,
                record.created_at,
                record.updated_at,
            ),
        )
        conn.commit()
        conn.close()

    def _insert_documents_hana(
        self,
        base: KnowledgeBaseOut,
        documents: List[str],
        metadatas: Optional[List[Dict[str, Any]]],
        embeddings: List[List[float]],
    ) -> int:
        conn = self._hana_connection()
        cursor = conn.cursor()
        count = 0
        for index, document in enumerate(documents):
            metadata = (metadatas[index] if metadatas and index < len(metadatas) else {}) or {}
            cursor.execute(
                f'''
                INSERT INTO "{CHUNKS_TABLE}"
                    ("ID", "BASE_ID", "OWNER_ID", "CONTENT", "METADATA", "EMBEDDING", "CREATED_AT")
                VALUES (?, ?, ?, ?, ?, TO_REAL_VECTOR(?), ?)
                ''',
                (
                    f"chunk-{uuid.uuid4().hex[:12]}",
                    base.id,
                    base.owner_id,
                    document,
                    json.dumps(metadata),
                    "[" + ",".join(map(str, embeddings[index])) + "]",
                    _now_iso(),
                ),
            )
            count += 1
        updated_at = _now_iso()
        cursor.execute(
            f'''
            UPDATE "{BASES_TABLE}"
            SET "DOCUMENTS_ADDED" = "DOCUMENTS_ADDED" + ?, "UPDATED_AT" = ?
            WHERE "ID" = ? AND "OWNER_ID" = ?
            ''',
            (count, updated_at, base.id, base.owner_id),
        )
        conn.commit()
        conn.close()
        return count

    def _search_hana(
        self,
        base_id: str,
        owner_id: str,
        query_embedding: Sequence[float],
        k: int,
    ) -> List[Dict[str, Any]]:
        conn = self._hana_connection()
        cursor = conn.cursor()
        cursor.execute(
            f'''
            SELECT TOP ? "ID", "CONTENT", "METADATA",
                   COSINE_SIMILARITY("EMBEDDING", TO_REAL_VECTOR(?)) AS "SCORE"
            FROM "{CHUNKS_TABLE}"
            WHERE "BASE_ID" = ? AND "OWNER_ID" = ?
            ORDER BY "SCORE" DESC
            ''',
            (k, "[" + ",".join(map(str, query_embedding)) + "]", base_id, owner_id),
        )
        rows = cursor.fetchall()
        conn.close()
        return [
            {
                "id": row[0],
                "content": row[1] or "",
                "metadata": json.loads(row[2] or "{}"),
                "score": float(row[3] or 0.0),
            }
            for row in rows
        ]

    def _wiki_count_hana(self, base_id: str, owner_id: str) -> int:
        conn = self._hana_connection()
        cursor = conn.cursor()
        cursor.execute(
            f'SELECT COUNT(*) FROM "{WIKI_TABLE}" WHERE "BASE_ID" = ? AND "OWNER_ID" = ?',
            (base_id, owner_id),
        )
        row = cursor.fetchone()
        conn.close()
        return int(row[0] or 0)

    def _list_wiki_hana(self, base_id: str, owner_id: str) -> List[WikiPageOut]:
        conn = self._hana_connection()
        cursor = conn.cursor()
        cursor.execute(
            f'''
            SELECT "SLUG", "TITLE", "CONTENT", "GENERATED", "CREATED_AT", "UPDATED_AT"
            FROM "{WIKI_TABLE}"
            WHERE "BASE_ID" = ? AND "OWNER_ID" = ?
            ORDER BY "UPDATED_AT" DESC
            ''',
            (base_id, owner_id),
        )
        rows = cursor.fetchall()
        conn.close()
        return [
            WikiPageOut(
                slug=row[0],
                title=row[1],
                content=row[2] or "",
                generated=bool(row[3]),
                created_at=row[4],
                updated_at=row[5],
            )
            for row in rows
        ]

    def _list_chunks_hana(self, base_id: str, owner_id: str) -> List[Dict[str, Any]]:
        conn = self._hana_connection()
        cursor = conn.cursor()
        cursor.execute(
            f'''
            SELECT "ID", "CONTENT", "METADATA", "CREATED_AT"
            FROM "{CHUNKS_TABLE}"
            WHERE "BASE_ID" = ? AND "OWNER_ID" = ?
            ORDER BY "CREATED_AT" DESC
            ''',
            (base_id, owner_id),
        )
        rows = cursor.fetchall()
        conn.close()
        return [
            {
                "id": row[0],
                "content": row[1] or "",
                "metadata": json.loads(row[2] or "{}"),
                "created_at": row[3],
            }
            for row in rows
        ]

    def _upsert_wiki_hana(
        self,
        base_id: str,
        owner_id: str,
        slug: str,
        title: str,
        content: str,
        generated: bool,
    ) -> None:
        conn = self._hana_connection()
        cursor = conn.cursor()
        cursor.execute(
            f'''
            SELECT "ID", "CREATED_AT"
            FROM "{WIKI_TABLE}"
            WHERE "BASE_ID" = ? AND "OWNER_ID" = ? AND "SLUG" = ?
            ''',
            (base_id, owner_id, slug),
        )
        row = cursor.fetchone()
        now = _now_iso()
        if row:
            cursor.execute(
                f'''
                UPDATE "{WIKI_TABLE}"
                SET "TITLE" = ?, "CONTENT" = ?, "GENERATED" = ?, "UPDATED_AT" = ?
                WHERE "ID" = ?
                ''',
                (title, content, generated, now, row[0]),
            )
        else:
            cursor.execute(
                f'''
                INSERT INTO "{WIKI_TABLE}"
                    ("ID", "BASE_ID", "OWNER_ID", "SLUG", "TITLE", "CONTENT", "GENERATED", "CREATED_AT", "UPDATED_AT")
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ''',
                (f"wiki-{uuid.uuid4().hex[:12]}", base_id, owner_id, slug, title, content, generated, now, now),
            )
        cursor.execute(
            f'UPDATE "{BASES_TABLE}" SET "UPDATED_AT" = ? WHERE "ID" = ? AND "OWNER_ID" = ?',
            (now, base_id, owner_id),
        )
        conn.commit()
        conn.close()


_backend: Optional[PersonalKnowledgeBackend] = None


def get_backend() -> PersonalKnowledgeBackend:
    global _backend
    if _backend is None:
        _backend = PersonalKnowledgeBackend()
    return _backend


@router.get("/bases", response_model=List[KnowledgeBaseOut])
async def list_knowledge_bases(
    request: Request,
    owner_id: Optional[str] = Query(default=None, min_length=1),
) -> List[KnowledgeBaseOut]:
    return get_backend().list_bases(resolve_effective_owner(request, owner_id))


@router.post("/bases", response_model=KnowledgeBaseOut, status_code=status.HTTP_201_CREATED)
async def create_knowledge_base(request: Request, body: KnowledgeBaseCreate) -> KnowledgeBaseOut:
    return get_backend().create_base(
        owner_id=resolve_effective_owner(request, body.owner_id),
        name=body.name,
        description=body.description,
        embedding_model=body.embedding_model,
    )


@router.post("/bases/{base_id}/documents", response_model=KnowledgeDocumentAddResponse)
async def add_knowledge_documents(
    request: Request,
    base_id: str,
    body: KnowledgeDocumentAddRequest,
) -> KnowledgeDocumentAddResponse:
    return await get_backend().add_documents(
        base_id=base_id,
        owner_id=resolve_effective_owner(request, body.owner_id),
        documents=body.documents,
        metadatas=body.metadatas,
    )


@router.post("/bases/{base_id}/query", response_model=KnowledgeQueryResponse)
async def query_knowledge_base(
    request: Request,
    base_id: str,
    body: KnowledgeQueryRequest,
) -> KnowledgeQueryResponse:
    return await get_backend().query(
        base_id=base_id,
        owner_id=resolve_effective_owner(request, body.owner_id),
        query=body.query,
        k=body.k,
    )


@router.get("/bases/{base_id}/wiki", response_model=List[WikiPageOut])
async def list_wiki_pages(
    request: Request,
    base_id: str,
    owner_id: Optional[str] = Query(default=None, min_length=1),
) -> List[WikiPageOut]:
    return get_backend().list_wiki_pages(base_id, resolve_effective_owner(request, owner_id))


@router.put("/bases/{base_id}/wiki/{slug}", response_model=WikiPageOut)
async def update_wiki_page(request: Request, base_id: str, slug: str, body: WikiPageUpdateRequest) -> WikiPageOut:
    return get_backend().upsert_wiki_page(
        base_id=base_id,
        owner_id=resolve_effective_owner(request, body.owner_id),
        slug=slug,
        title=body.title,
        content=body.content,
    )


@router.get("/graph/summary", response_model=KnowledgeGraphSummary)
async def get_knowledge_graph_summary(
    request: Request,
    owner_id: Optional[str] = Query(default=None, min_length=1),
    base_id: Optional[str] = Query(default=None),
) -> KnowledgeGraphSummary:
    return get_backend().graph_summary(resolve_effective_owner(request, owner_id), base_id=base_id)


@router.post("/graph/query", response_model=KnowledgeGraphQueryResponse)
async def query_knowledge_graph(request: Request, body: KnowledgeGraphQueryRequest) -> KnowledgeGraphQueryResponse:
    return get_backend().graph_query(
        owner_id=resolve_effective_owner(request, body.owner_id),
        query=body.query,
        base_id=body.base_id,
        limit=body.limit,
    )
