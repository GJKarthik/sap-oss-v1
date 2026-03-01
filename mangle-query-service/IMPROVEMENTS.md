# Mangle Query Service - Improvement Roadmap

## Current State

The service provides an OpenAI-compatible HTTP API with:
- Dynamic metadata from Elasticsearch
- Mangle routing rules (routing.mg, analytics_routing.mg)
- Classification → Resolution → Augmentation pipeline

---

## High-Priority Improvements

### 1. **Streaming Support** (OpenAI SSE)
```python
# Current: Blocking response
response = await router.call_aicore(model, messages)

# Needed: Server-Sent Events for streaming
@app.post("/v1/chat/completions")
async def chat_completions(request: ChatCompletionRequest):
    if request.stream:
        return StreamingResponse(
            stream_completion(request),
            media_type="text/event-stream"
        )
```

**Why**: Chat applications expect streaming. vLLM and AI Core both support it.

---

### 2. **Vector Embeddings for RAG**
```json
// Current: BM25 text search only
{
  "query": {"multi_match": {"query": query, "fields": ["description"]}}
}

// Needed: Hybrid search with dense vectors
{
  "knn": {
    "field": "embedding",
    "query_vector": [...],
    "k": 5
  },
  "query": {"multi_match": {...}}
}
```

**Why**: Semantic search significantly improves retrieval quality.

**Implementation**:
1. Generate embeddings via AI Core embedding endpoint
2. Store in ES with `dense_vector` field
3. Hybrid score = α×BM25 + (1-α)×kNN

---

### 3. **HANA Connector for Real Queries**
```python
# Current: Mock HANA responses
context = {
    "note": "HANA analytical query prepared - results would be fetched"
}

# Needed: Actual HANA execution
async def _resolve_hana_analytical(self, query, classification):
    sql = self._build_analytical_sql(
        view=classification["view"],
        dimensions=classification["dimensions"],
        measures=classification["measures"],
        filters=classification["filters"]
    )
    results = await hana_client.execute(sql)
    return {"context": results, "source": "hana_analytical"}
```

**Why**: The whole point is to query SAP data.

---

### 4. **Reranking for RAG**
```python
# Current: Return top-k by ES score
context = [hit["_source"] for hit in hits]

# Needed: Cross-encoder reranking
async def _resolve_rag(self, query, classification):
    candidates = await self._es_retrieve(query, k=20)
    reranked = await self._rerank(query, candidates, k=5)
    return {"context": reranked}

async def _rerank(self, query, docs, k):
    # Call cross-encoder model via AI Core
    scores = await aicore.rerank(query, docs)
    return sorted(zip(docs, scores), key=lambda x: x[1])[:k]
```

**Why**: Initial retrieval (BM25/kNN) is fast but imprecise. Reranking improves precision.

---

### 5. **Query Caching with Semantic Similarity**
```python
# Current: Exact hash match only
cache_lookup(hash(query))

# Needed: Semantic cache
async def _check_cache(self, query):
    embedding = await self._embed(query)
    similar = await es.search(
        index="query_cache",
        knn={"field": "embedding", "query_vector": embedding, "k": 1}
    )
    if similar and similar[0]["_score"] > 0.95:
        return similar[0]["_source"]["answer"]
```

**Why**: "Show sales by region" and "Display regional sales" should hit the same cache.

---

### 6. **Tool/Function Calling Support**
```python
# Current: No tool support
tools = None

# Needed: Full tool calling
class ChatCompletionRequest(BaseModel):
    tools: Optional[List[ToolDefinition]] = None
    tool_choice: Optional[str] = "auto"

# Auto-generate tools from entity metadata
def _generate_entity_tools(self, entities):
    return [
        {
            "type": "function",
            "function": {
                "name": f"query_{entity}",
                "description": f"Query {entity} data from SAP",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "dimensions": {"type": "array", "items": {"type": "string"}},
                        "measures": {"type": "array", "items": {"type": "string"}},
                        "filters": {"type": "object"}
                    }
                }
            }
        }
        for entity in entities
    ]
```

**Why**: OpenAI tools let the model autonomously query data.

---

### 7. **Observability & Tracing**
```python
# Add OpenTelemetry
from opentelemetry import trace

tracer = trace.get_tracer(__name__)

async def classify_query(self, query, hints):
    with tracer.start_as_current_span("classify_query") as span:
        span.set_attribute("query", query[:100])
        span.set_attribute("route", classification["route"].value)
        # ...
```

**Metrics to track**:
- Classification accuracy (via feedback)
- Resolution path latency
- Cache hit rate
- RAG retrieval relevance

---

### 8. **Feedback Loop for Routing**
```python
@app.post("/v1/feedback")
async def submit_feedback(
    query_id: str,
    rating: int,  # 1-5
    correct_route: Optional[str] = None
):
    """User feedback to improve routing."""
    await es.index(
        index="routing_feedback",
        document={
            "query_id": query_id,
            "rating": rating,
            "correct_route": correct_route,
            "timestamp": datetime.now()
        }
    )
    # Periodically retrain classification model
```

**Why**: Let users correct bad routing decisions.

---

### 9. **Multi-tenant Metadata**
```python
# Current: Single global metadata
metadata = await metadata_loader.get_metadata()

# Needed: Tenant-scoped metadata
metadata = await metadata_loader.get_metadata(tenant_id=request.tenant)

# ES indices become tenant-prefixed
f"{tenant_id}_entity_registry"
```

**Why**: Different customers have different entities/dimensions.

---

### 10. **Conversation Context Management**
```python
# Current: Stateless - each request is independent

# Needed: Conversation memory
class ConversationManager:
    async def get_context(self, conversation_id: str) -> List[Message]:
        """Retrieve conversation history from Redis/ES."""
        
    async def append(self, conversation_id: str, messages: List[Message]):
        """Append new messages, trim to context window."""
        
    async def summarize(self, conversation_id: str):
        """Compress old messages into summary."""
```

**Why**: Multi-turn conversations need context.

---

## Implementation Priority

| Priority | Improvement | Effort | Impact |
|----------|-------------|--------|--------|
| P0 | Streaming support | Medium | High |
| P0 | HANA connector | High | Critical |
| P1 | Vector embeddings | Medium | High |
| P1 | Reranking | Low | Medium |
| P1 | Tool/function calling | Medium | High |
| P2 | Semantic cache | Medium | Medium |
| P2 | Observability | Low | Medium |
| P2 | Feedback loop | Low | Medium |
| P3 | Multi-tenant | High | Medium |
| P3 | Conversation context | Medium | Medium |

---

## Architecture Evolution

```
Current State:
┌────────────────────────────────────────────────┐
│              OpenAI HTTP API                    │
│  classify → resolve → augment → call_aicore    │
└────────────────────────────────────────────────┘

Target State:
┌────────────────────────────────────────────────────────────────┐
│                      OpenAI HTTP API                            │
│  (streaming, tools, conversations)                              │
├────────────────────────────────────────────────────────────────┤
│  Classification      │  Resolution        │  Generation         │
│  ├─ Mangle rules     │  ├─ ES (vector)    │  ├─ AI Core         │
│  ├─ ML classifier    │  ├─ HANA (live)    │  ├─ vLLM            │
│  └─ Feedback loop    │  ├─ Reranker       │  └─ Streaming       │
│                      │  └─ Cache (semantic)│                     │
├────────────────────────────────────────────────────────────────┤
│  Observability: OpenTelemetry → Prometheus → Grafana           │
└────────────────────────────────────────────────────────────────┘