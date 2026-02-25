# Elasticsearch + Mangle Query Service Design

> Unified query resolution architecture where Elasticsearch handles 80% of prompt load without LLM, orchestrated by Mangle as the central logic/routing/data-unification service.

**Date:** 2026-02-25
**Status:** Approved

---

## Problem

Today, 100% of user prompts go through the full RAG pipeline: embed, HANA vector search, LLM generation. The LLM (vLLM) consumes ~70% of execution time and cost. Most queries are repetitive or answerable from existing indexed content without generative reasoning.

## Goal

- Elasticsearch as the primary query resolver
- Smart routing via Mangle (deductive database / logic engine) decides: cached answer? direct retrieval? template RAG? or LLM needed?
- 80% of prompts resolved without vLLM
- HANA remains source of truth, synced to ES
- Incorporate `hana_ai` toolkit for classification, entity extraction, reranking, memory management
- Incorporate Mangle as the central brain: routing + orchestration + data unification

## Design Decisions

- **Approach chosen:** ES-First with Classifier Router, Mangle as central orchestrator
- **HANA role:** Source of truth. Data synced/indexed into ES. HANA for writes + structured queries, ES for search + retrieval.
- **Data types:** Both documents (for RAG) and structured business data (for factual lookups)
- **Sync strategy:** Hybrid. Batch ETL for bulk data + real-time CDC for high-priority tables.
- **Routing accuracy:** High accuracy required. Small classifier model (starting rule-based, graduating to ML).
- **Deployment:** Self-hosted on BTP (Kubernetes).

---

## 1. System Architecture

```
                         User Query (from Angular via CAP)
                              |
                              v
               +---------------------------------+
               |      MANGLE QUERY SERVICE        |
               |      (Go service on BTP)         |
               |                                  |
               |  Routing Rules (.mg files)        |
               |  External Predicates:            |
               |  +------+ +----+ +--------+      |
               |  |  ES  | |HANA| | hana_ai|      |
               |  +------+ +----+ +--------+      |
               +---------------------------------+
                    |          |          |
            +-------+          |          +-------+
            v                  v                  v
   +--------------+  +--------------+  +--------------+
   | Elasticsearch |  |  SAP HANA    |  |  hana_ai     |
   |               |  |  Cloud       |  |  (Python)    |
   | - cache-qa    |  |              |  |              |
   | - business-*  |  | - Source of  |  | - RAGAgent   |
   | - documents   |  |   truth      |  | - CrossEnc   |
   | - kNN + BM25  |  | - Vectors    |  | - Corrective |
   |               |  | - Anonymized |  | - Memory     |
   |               |  | - Structured |  | - vLLM proxy |
   +--------------+  +--------------+  +--------------+
```

### Four resolution paths

| Path | ~% of traffic | What happens | Latency target |
|---|---|---|---|
| **CACHED** | 30% | Semantic cache: ES finds a previously answered similar query above cosine threshold | <50ms |
| **FACTUAL** | 25% | Structured lookup: ES queries business data indices directly | <100ms |
| **RAG_RETRIEVAL** | 25% | ES hybrid search finds relevant docs, template-based response assembly without LLM | <200ms |
| **LLM_REQUIRED** | 20% | Complex reasoning: ES provides context, vLLM generates | 1-5s |

---

## 2. Mangle as Central Brain

### Why Mangle

Instead of hardcoded routing logic in TypeScript, all query routing, decomposition, and orchestration is expressed as **Datalog rules** in Mangle.

| Benefit | Explanation |
|---|---|
| **Rules are data** | Update routing logic by editing `.mg` files. No recompilation, no redeployment. Hot-reload. |
| **Composable** | Add a new data source by registering one new external predicate. Rules automatically compose. |
| **Auditable** | Every resolution is a Mangle proof trace. Explainable routing decisions. |
| **Temporal** | Built-in interval predicates handle cache TTL, data freshness, sync windows natively. |
| **Testable** | Rules are unit-testable with mock facts. No need to spin up ES/HANA/vLLM to test routing logic. |
| **Performant** | Go service with semi-naive bottom-up evaluation. Fast paths resolve in microseconds. |

### External predicate registration

```go
engine.EvalProgram(program, store,
    engine.WithExternalPredicates(map[ast.PredicateSym]ExternalPredicateCallback{
        "es_cache_lookup":    &ESCachePredicate{client: esClient},
        "es_search":          &ESSearchPredicate{client: esClient},
        "es_hybrid_search":   &ESHybridPredicate{client: esClient},
        "hana_query":         &HANAQueryPredicate{conn: hanaConn},
        "hana_entity":        &HANAEntityPredicate{conn: hanaConn},
        "classify_query":     &HanaAIClassifyPredicate{mcpClient: mcpClient},
        "extract_entities":   &HanaAIEntityPredicate{mcpClient: mcpClient},
        "rerank":             &HanaAIRerankPredicate{mcpClient: mcpClient},
        "llm_generate":       &HanaAILLMPredicate{mcpClient: mcpClient},
    }),
)
```

### Core routing rules

```prolog
% Query Classification
is_cached(Query) :-
    es_cache_lookup(Query, _Answer, Score),
    Score >= 0.95.

is_factual(Query) :-
    classify_query(Query, "FACTUAL", Confidence),
    Confidence >= 0.7,
    extract_entities(Query, EntityType, _EntityId).

is_knowledge(Query) :-
    classify_query(Query, "RAG_RETRIEVAL", Confidence),
    Confidence >= 0.7.

llm_required(Query) :-
    classify_query(Query, "LLM_REQUIRED", _Confidence).

llm_required(Query) :-
    !is_cached(Query),
    !is_factual(Query),
    !is_knowledge(Query).

% Resolution Paths
resolve(Query, Answer, "cache", Score) :-
    is_cached(Query),
    es_cache_lookup(Query, Answer, Score).

resolve(Query, Answer, "factual", Score) :-
    is_factual(Query),
    extract_entities(Query, EntityType, EntityId),
    es_search(EntityType, EntityId, Answer, Score).

resolve(Query, Answer, "rag", Score) :-
    is_knowledge(Query),
    es_hybrid_search(Query, Documents, Score),
    rerank(Query, Documents, RankedDocs),
    assemble_response(RankedDocs, Answer).

resolve(Query, Answer, "llm", Score) :-
    llm_required(Query),
    es_hybrid_search(Query, Context, _),
    llm_generate(Query, Context, Answer),
    Score = 1.0.
```

### Service structure

```
mangle-query-service/
+-- cmd/server/main.go               # gRPC + REST entry point
+-- predicates/
|   +-- es_predicates.go             # Elasticsearch external predicates
|   +-- hana_predicates.go           # HANA external predicates
|   +-- hana_ai_predicates.go        # hana_ai MCP client predicates
+-- rules/
|   +-- routing.mg                   # Query classification rules
|   +-- resolution.mg                # Resolution path rules
|   +-- caching.mg                   # Cache management rules
|   +-- freshness.mg                 # Temporal data freshness rules
|   +-- error_handling.mg            # Fallback and degradation rules
|   +-- sync.mg                      # HANA -> ES sync coordination
+-- api/
|   +-- query.proto                  # gRPC service definition
|   +-- query.go                     # REST handler
+-- sync/
|   +-- batch_etl.go                 # Scheduled HANA -> ES batch sync
|   +-- cdc_listener.go              # Real-time change listener
+-- Dockerfile
+-- k8s/deployment.yaml              # BTP Kubernetes deployment
```

---

## 3. Query Router (Classifier)

### Phase 1: Rule-Based Router

Classification rules evaluated in order:

| Priority | Rule | Path | Example |
|---|---|---|---|
| 1 | ES cache hit: cosine >= 0.95 | CACHED | "What is our return policy?" (asked before) |
| 2 | Factual intent pattern + entity keywords | FACTUAL | "Show me orders from last quarter" |
| 3 | Knowledge question, no reasoning keywords | RAG_RETRIEVAL | "What are the steps to configure SSO?" |
| 4 | Everything else | LLM_REQUIRED | "Why did sales drop in Q3?" |

- Patterns stored in ES as `router-config` index (hot-updatable)
- Every routing decision logged as training data for Phase 2

### Phase 2: ML Classifier (after ~10K labeled routing decisions)

- Fine-tune `sentence-transformers/all-MiniLM-L6-v2` (22M params) on collected routing logs
- Deploy on BTP as lightweight inference endpoint
- Route to highest-probability class if confidence > 0.7; else fall back to rule-based
- Retrain monthly

### Fallback chain

```
CACHED (miss) -> FACTUAL (no match) -> RAG_RETRIEVAL (low score) -> LLM_REQUIRED
```

Every path has a confidence threshold. Below threshold, query cascades to next path.

### Router config (hot-reloadable from ES)

```typescript
interface RouterConfig {
  cacheThreshold: number;          // default 0.95
  factualPatterns: RegexPattern[];
  ragConfidenceMin: number;        // default 0.75
  llmBypassKeywords: string[];     // force LLM: "explain why", "compare"
  enableMLClassifier: boolean;     // feature flag for Phase 2
}
```

---

## 4. Incorporating hana_ai Toolkit

The `generative-ai-toolkit-for-sap-hana-cloud` (Python) provides components we reuse rather than build:

| Our need | hana_ai component | Usage |
|---|---|---|
| Query classification | `Mem0IngestionClassifier` | Adapted: categories changed to CACHED/FACTUAL/RAG_RETRIEVAL/LLM_REQUIRED |
| Entity extraction | `Mem0EntityExtractor` | Reused directly for FACTUAL path entity parsing |
| RAG with reranking | `PALCrossEncoder` | Reranks ES hybrid search results for higher precision |
| Corrective retrieval | `CorrectiveRetriever` | Self-refining RAG for LLM_REQUIRED path |
| Memory management | `Mem0MemoryManager` | Powers semantic cache with TTL, priority, tags |
| Full RAG agent | `HANAMLRAGAgent` | Used for LLM_REQUIRED path with short-term + long-term memory |
| MCP server | `HANAMLToolkit.launch_mcp_server()` | Bridge between Go (Mangle) and Python (hana_ai) |

### Language boundary: Go/TypeScript <-> Python

```
Angular (TypeScript)
    |
    v HTTP/OData
cap-llm-plugin (TypeScript/CDS)
    |
    v gRPC
Mangle Query Service (Go)
    |
    +-- ES queries -> @elastic/elasticsearch (direct, fast)
    |
    +-- hana_ai calls -> MCP Server (Python, via HANAMLToolkit)
                          +-- QueryClassifier
                          +-- EntityExtractor
                          +-- PALCrossEncoder
                          +-- CorrectiveRetriever
                          +-- HANAMLRAGAgent + vLLM
```

- Fast paths (CACHED, FACTUAL, simple RAG): handled in Go via ES. No Python call. <200ms.
- Heavy paths (RAG with reranking, LLM): routed to Python hana_ai via MCP.

---

## 5. Elasticsearch Index Design

### Index schemas

**`cache-qa` -- Semantic cache for past Q&A pairs**

| Field | Type | Purpose |
|---|---|---|
| `query_text` | text | Original query for BM25 fallback |
| `query_embedding` | dense_vector (1536, cosine) | Semantic similarity matching |
| `answer_text` | text | Cached answer |
| `source_path` | keyword | Which resolution path generated it |
| `generated_by` | keyword | "llm" or "rag" |
| `created_at` | date | For TTL |
| `hit_count` | integer | Popularity for retention |
| `ttl_expires` | date | Expiry (default 7 days) |

**`business-{entity}` -- Structured business data (one index per HANA entity)**

| Field | Type | Purpose |
|---|---|---|
| `hana_key` | keyword | Primary key from HANA |
| `entity_type` | keyword | Entity classification |
| `fields` | object (dynamic) | Mirrors HANA columns for filtering |
| `display_text` | text | Pre-rendered human-readable summary |
| `last_synced_at` | date | Sync tracking |
| `hana_changed_at` | date | Source change timestamp |

**`documents` -- Knowledge base with hybrid search**

| Field | Type | Purpose |
|---|---|---|
| `title` | text | Document title for BM25 |
| `content` | text | Full text for BM25 |
| `content_embedding` | dense_vector (1536, cosine) | For kNN search |
| `source` | keyword | Source system |
| `category` | keyword | Document category |
| `chunk_index` | integer | Position in parent doc |
| `parent_doc_id` | keyword | Links chunks to source document |
| `hana_table` | keyword | Source HANA table |

---

## 6. HANA -> ES Sync Pipeline

### Sync modes (configured as Mangle facts)

```prolog
sync_mode("orders", "realtime").
sync_mode("customers", "realtime").
sync_mode("inventory", "realtime").
sync_mode("knowledge_base", "batch").
sync_mode("product_catalog", "batch").

batch_interval("knowledge_base", "15m").
batch_interval("product_catalog", "1h").
```

### Batch ETL

Runs inside Mangle Query Service as Go goroutine:

1. Query HANA: `SELECT * FROM {entity} WHERE changed_at > {last_sync}`
2. Branch by entity type:
   - `needs_embedding`: chunk text, generate embeddings via hana_ai GenAIHubEmbeddings (MCP, batched)
   - `is_business_entity`: render display_text from template
3. Bulk index into ES (`_bulk` API, 500 docs/batch)
4. Update last_sync timestamp (stored as Mangle temporal fact)

### Real-time CDC

CDS `@after` hooks in cap-llm-plugin forward to Mangle Query Service via gRPC:

1. Mangle evaluates `sync_mode(Entity, "realtime")`
2. Branches: business entity -> render + index; document entity -> chunk + embed + index
3. Invalidates cache entries that referenced the updated entity

### Cache invalidation (declarative, via Mangle rules)

```prolog
invalidate_cache(QueryHash) :-
    cache_references(QueryHash, EntityType, EntityId),
    entity_updated(EntityType, EntityId, UpdateTime),
    cache_created(QueryHash, CacheTime),
    UpdateTime > CacheTime.
```

### Sync monitoring

```prolog
sync_overdue(Entity) :-
    sync_mode(Entity, "batch"),
    batch_interval(Entity, Interval),
    last_sync_time(Entity, LastSync),
    fn:time_sub(fn:time_now(), LastSync) > fn:duration_parse(Interval).

sync_drift(Entity, Drift) :-
    hana_count(Entity, HCount),
    es_count(Entity, ECount),
    Drift = fn:abs(HCount - ECount) / HCount,
    Drift > 0.05.
```

### Embedding strategy

| Source | Method | When |
|---|---|---|
| Knowledge base docs | hana_ai GenAIHubEmbeddings via MCP (batched) | Batch ETL |
| Product descriptions | Same | Batch ETL |
| User queries (cache + search) | OrchestrationEmbeddingClient via ai-sdk-js (low-latency) | Query time, in cap-llm-plugin |
| HANA-native vectors | VECTOR_EMBEDDING() SQL | Stays in HANA, synced to ES during ETL |

---

## 7. Error Handling & Resilience

### Degradation cascade

```
Normal:       ES cache -> ES factual -> ES RAG + rerank -> vLLM
If ES down:   ---------------------------------- HANA + vLLM
If hana_ai    ES cache -> ES factual -> ES RAG (no rerank, raw ES scores)
  MCP down:
If vLLM down: ES cache -> ES factual -> ES RAG + template
              (80% still works without any LLM)
If all down:  Return structured error response
```

### Fallback rules (Mangle)

```prolog
% If classifier fails, fall back to heuristics
classify_query_safe(Query, Category, 0.5) :-
    classify_error(Query, ErrorCode),
    degraded_error(ErrorCode),
    heuristic_classify(Query, Category).

% If reranker fails, use raw ES scores
resolve_rag(Query, Answer, Score) :-
    es_hybrid_search(Query, Documents, Score),
    rerank_error(Query, _),
    assemble_response(Documents, Answer).

% If ES is completely down, fall through to HANA + LLM
resolve(Query, Answer, "llm_fallback", Score) :-
    es_unavailable(),
    hana_search(Query, Context),
    llm_generate(Query, Context, Answer),
    Score = 0.8.
```

### Circuit breakers

Each external predicate wraps a circuit breaker in Go. Circuit breaker state exposed as Mangle facts:

```prolog
es_unavailable() :- circuit_state("es_search", "open").
hana_ai_unavailable() :- circuit_state("hana_ai_classify", "open").
vllm_unavailable() :- circuit_state("vllm_generate", "open").
```

Fallback rules activate automatically when circuits open.

### Health endpoint

```prolog
service_healthy() :- !es_unavailable(), !sync_overdue(_), !sync_drift(_, _).
service_degraded() :- es_unavailable().
service_degraded() :- sync_overdue(Entity).
service_unhealthy() :- es_unavailable(), vllm_unavailable().
```

Returns 200 (healthy), 207 (degraded), or 503 (unhealthy).

### Observability

**Structured logging** on every resolution: correlation_id, path_taken, classification, ES search stats, latency breakdown.

**Prometheus metrics:**

| Metric | Type | Labels |
|---|---|---|
| `query_total` | counter | path, status |
| `query_latency_seconds` | histogram | path |
| `cache_hit_ratio` | gauge | -- |
| `sync_lag_seconds` | gauge | entity, mode |
| `sync_drift_ratio` | gauge | entity |
| `fallback_total` | counter | from_path, to_path, error_code |
| `resolution_path_ratio` | gauge | path |

`resolution_path_ratio` is the primary KPI for the 80/20 target.

**OpenTelemetry traces:** Angular -> CAP -> Mangle -> ES/HANA/hana_ai. Correlation ID propagated via gRPC metadata.

---

## 8. Testing Strategy

### Test pyramid

| Layer | Count | Scope | What's tested |
|---|---|---|---|
| Unit (Go) | 50-60 | Each predicate, sync component, circuit breaker | Isolated with mocked clients |
| Mangle Rules | 30-40 | Pure `.mg` rule evaluation with mock facts | Routing, resolution, fallback, cache, freshness |
| Integration | 15-20 | Mangle + real ES, mocked HANA/hana_ai | Cache round-trip, hybrid search, ETL, CDC, circuit breaker recovery |
| E2E | 3-5 | Angular -> CAP -> Mangle -> ES/HANA/hana_ai | Full scenarios: cached, factual, RAG, LLM, degraded mode |

### 80/20 validation test

Dedicated test runs 100 representative queries and asserts:
- At least 75% resolved without LLM (with margin)
- At most 25% routed to LLM

---

## 9. Component Inventory

### What we build new

| Component | Language | Description |
|---|---|---|
| Mangle Query Service | Go | Central orchestrator: gRPC server, external predicates, sync engine |
| ES external predicates | Go | Cache, search, hybrid search predicates for Mangle |
| HANA external predicates | Go | Query, entity predicates for Mangle |
| hana_ai MCP predicates | Go | Classify, extract, rerank, LLM predicates via MCP |
| Routing/resolution rules | Mangle (.mg) | All routing, caching, freshness, error handling logic |
| Batch ETL | Go | Scheduled HANA -> ES sync with chunking + embedding |
| CDC listener | Go | Real-time HANA change propagation to ES |
| ResponseAssembler | Go | Template engine for RAG_RETRIEVAL path |
| cap-llm-plugin integration | TypeScript | Thin gRPC client calling Mangle service |

### What we reuse from hana_ai

| Component | Original | Adaptation |
|---|---|---|
| QueryClassifier | Mem0IngestionClassifier | Change categories to CACHED/FACTUAL/RAG_RETRIEVAL/LLM_REQUIRED |
| EntityExtractor | Mem0EntityExtractor | Reuse directly |
| Reranker | PALCrossEncoder | Reuse directly |
| CorrectiveRetriever | CorrectiveRetriever | Reuse for LLM_REQUIRED path |
| SemanticCache backend | Mem0MemoryManager | TTL + priority + tags for cache management |
| RAG Agent | HANAMLRAGAgent | Reuse for LLM_REQUIRED path |
| MCP Server | HANAMLToolkit | Bridge Go <-> Python |

### What we reuse from Mangle

| Component | Usage |
|---|---|
| Mangle engine | Core evaluation engine (semi-naive bottom-up) |
| External predicates interface | Connect ES, HANA, hana_ai as queryable data sources |
| Temporal predicates | Cache TTL, sync freshness, staleness checks |
| Built-in functions | String matching, time arithmetic, collections |

### What we reuse from existing SAP OSS repos

| Component | Source repo | Usage |
|---|---|---|
| OrchestrationClient | ai-sdk-js | vLLM chat completion (LLM_REQUIRED path) |
| OrchestrationEmbeddingClient | ai-sdk-js | Query-time embedding in cap-llm-plugin |
| cap-llm-plugin | cap-llm-plugin | CDS facade, CDC hooks, Angular-facing API |
| vLLM client | ai-sdk-js (vllm package) | Streaming, retry, circuit breaker for LLM calls |
