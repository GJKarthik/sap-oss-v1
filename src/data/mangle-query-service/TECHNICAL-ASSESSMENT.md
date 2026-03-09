# Technical Assessment: `Mangle Query Service`

**Package:** `mangle-query-service` v0.1.0 / v1.1.0 (data products registry)
**Author:** SAP SE
**License:** Apache-2.0
**Module:** `github.com/sap-oss/mangle-query-service`
**Runtime requirements:** Go 1.24, Python ≥ 3.11, Node.js ≥ 18 (TypeScript client)

---

## Purpose and Positioning

The Mangle Query Service is a polyglot, OpenAI-compatible API gateway and intelligent query-routing engine designed for enterprise AI workloads within the SAP BTP ecosystem. Its primary function is to intercept natural-language queries submitted via a standard OpenAI-compatible REST API and resolve them through the most appropriate backend — a semantic cache, SAP HANA Cloud vector engine, Elasticsearch, or SAP AI Core / private vLLM — without exposing clients to the complexity of that routing logic. The routing decisions are not heuristic code; they are **declarative Mangle Datalog rules** that are evaluated at runtime by the embedded Google Mangle interpreter, making the routing layer fully introspectable and auditable without recompilation.

The service sits at the intersection of three distinct subsystems: the **Go gRPC layer** (`cmd/server/main.go`, `internal/engine/engine.go`) hosts the Mangle rule engine and exposes a typed gRPC `QueryService`; the **Python FastAPI layer** (`cmd/server/main.py`, `openai/router.py`) hosts the OpenAI-compatible HTTP endpoints, the intelligence pipeline (semantic classifier, adaptive router, speculative executor, reranker), and the resilience middleware; and the **MCP server** (`mcp_server/langchain_hana_mcp.py`) bridges the Mangle rule engine to the LangChain HANA vector search library, exposing HANA operations as MCP tool calls that rules can invoke as extensional predicates.

Beyond query routing, the repository implements a comprehensive data governance layer. The `governance.mg` Mangle rules implement GDPR compliance logic derived from the OData `PersonalData` vocabulary, including data-subject entity detection, sensitive-field identification, consent management, and data-retention expiry. This governance layer wraps every resolution path through `resolve_with_governance/4`, ensuring that access-control checks, anonymisation, and audit logging are applied before any answer is returned to the caller. The service self-classifies at **autonomy level L2 (Human-on-loop)** in accordance with the Singapore IMDA Model AI Governance Framework (MGF) and the 2025 AI Agent Index published by MIT/Cambridge/Stanford/Harvard.

---

## Repository Layout and Architecture

The repository is a single-module Go project with co-located Python packages. Go governs the rule engine and gRPC server; Python governs the HTTP API surface, connectors, intelligence pipeline, and observability. The two runtimes communicate via local gRPC calls from the Python `openai/router.py` layer into the Go `QueryService`, although the Python layer also has its own lightweight Mangle simulation path for development contexts where the Go binary is not running.

```
mangle-query-service/
├── cmd/server/
│   ├── main.go          # Go gRPC entry point (Mangle engine + ETL sync)
│   └── main.py          # Python FastAPI entry point (HTTP API + component init)
├── internal/
│   ├── config/          # Go configuration loader (MQS_CONFIG env)
│   ├── engine/          # MangleEngine wrapper (engine.go, tests)
│   ├── es/              # Elasticsearch Go client
│   ├── predicates/      # Extensional predicate callbacks (ES, MCP, LLM)
│   ├── resilience/      # Go-side retry / circuit breaker
│   ├── server/          # gRPC server implementation
│   └── sync/            # Batch ETL pipeline (ES synchronisation, 5-minute interval)
├── rules/               # Mangle Datalog rules (7 .mg files)
├── connectors/          # Python connectors (AI Core, HANA, LangChain, HTTP, embeddings)
├── intelligence/        # Python AI pipeline (adaptive router, reranker, classifier, speculative)
├── middleware/          # Python resilience middleware (circuit breaker, retry, rate limiter, mTLS, validation)
├── observability/       # OpenTelemetry tracing + Prometheus metrics
├── openai/              # Full OpenAI-compatible Python API surface (~35 files)
├── routing/             # Python model registry, model router, service router
├── performance/         # Python cache layer, connection pool, query optimizer
├── efficiency/          # Python semantic cache, batch client
├── mcp_server/          # LangChain HANA MCP server
├── client/typescript/   # TypeScript client
├── api/proto/           # gRPC protobuf definitions
├── data_products/       # ODPS 4.1 data product registry
├── deploy/              # Dockerfile, docker-compose, Prometheus config
├── hippocpp/            # Vendored C++ artefact (3,358 items, unreferenced)
├── kuzu/                # Vendored graph DB artefact (2,073 items, unreferenced)
└── vendor/              # Go module vendor directory (5,422 items)
```

The dual-runtime design reflects an incremental development history: the Go gRPC server was the original architecture and embeds the Mangle engine natively; the Python FastAPI layer was added to provide an OpenAI-compatible HTTP surface and a richer intelligence pipeline that could iterate more quickly. In production the Python layer acts as the primary entry point (port 8080) while calling the Go gRPC server internally for rule evaluation.

---

## Go gRPC Layer and the Mangle Rule Engine

The Go entry point (`cmd/server/main.go`) loads configuration from the path specified by `MQS_CONFIG`, creates an Elasticsearch client, starts a `BatchETL` pipeline on a five-minute ticker to synchronise facts into Elasticsearch, creates the `MangleEngine`, registers the gRPC `QueryService`, and handles `SIGINT`/`SIGTERM` for graceful shutdown. The gRPC port is configurable via the loaded config; no hardcoded port is exposed in the Go layer.

`internal/engine/engine.go` wraps the `github.com/google/mangle` library. The `MangleEngine` struct holds a `sync.RWMutex`-guarded interpreter (`*interpreter.Interpreter`) for tests and a `factstore.FactStoreWithRemove` plus `*analysis.ProgramInfo` for the production path that supports externally-registered predicate callbacks. The `New` constructor loads only `routing.mg`; `NewWithRules` concatenates any set of `.mg` files, allowing test suites to compose `routing.mg + governance.mg + rag_enrichment.mg` in a single pass.

`DefineFact(clauseText)` appends a ground fact and triggers a full reload of the interpreter, keeping derived predicates consistent. `Resolve(query)` evaluates `resolve(Query, Answer, Path, Score)` via `interp.Query(atom)` and maps the first result's arguments to the typed `Resolution` struct (`Answer`, `Path`, `Confidence float64`, `Sources []Source`). When external predicates are registered (production mode), `reloadWithEngine` uses `mangleEngine.EvalProgram` with the `WithExternalPredicates` option so that callbacks for `es_cache_lookup`, `es_search`, `classify_query`, `llm_generate`, and the HANA predicates are dispatched out of the rule engine into Go functions.

---

## Mangle Datalog Rules

All routing, governance, analytics, and vocabulary logic is encoded in seven `.mg` files in the `rules/` directory. These rules are loaded into the Mangle engine at startup and evaluated on every query. The rules interact with the outside world exclusively through *extensional predicates* — declared with `descr [extensional()]` — which the Go engine satisfies by calling registered callbacks.

### `routing.mg` — Core Resolution

Defines five resolution paths in priority order. `resolve/4` is the top-level predicate evaluated for every query.

| Path | Trigger | Backend |
|---|---|---|
| `cache` | `es_cache_lookup` score ≥ 95 | Elasticsearch semantic cache |
| `factual` | `classify_query("FACTUAL", ≥70)` + entity extraction | Elasticsearch entity index |
| `rag` | `classify_query("RAG_RETRIEVAL", ≥70)` | ES hybrid search + rerank |
| `llm` | `classify_query("LLM_REQUIRED", _)` | ES hybrid search + `llm_generate` |
| `llm_fallback` | No classification match | ES hybrid search + `llm_generate` (score 50) |

### `analytics_routing.mg` — HANA Analytics and OData Vocabulary

Extends `routing.mg` with three additional resolution paths for analytical, hierarchy, and time-series queries. The `should_route_to_hana/2` predicate fires when a query involves an `analytical_entity` (e.g., `SalesOrder → CV_SALES_ORDER`, `CostCenter → CV_COST_CENTER_ANALYSIS`) and HANA is available. Dimensions, measures, and hierarchies are loaded as extensional facts at startup from the OData vocabulary MCP. GDPR/personal data masking is integrated directly: `apply_gdpr_mask/3` is called on results containing entities declared in `entity_personal_data/3`. A `resolution_priority/2` fact table controls which path wins when multiple paths match, preferring `cache (1)` → `hana_analytical (2)` → `hana_hierarchy (3)` → `es_factual (4)` → `es_aggregation (5)` → `rag_enriched (6)`.

### `hana_vector.mg` — HANA Vector Engine Integration

Declares extensional predicates for HANA vector search (`hana_vector_search/5`), Maximum Marginal Relevance search (`hana_mmr_search/6`), and internal embeddings (`hana_embed/2`). Defines 16 HANA data sources (SAP S/4HANA core tables: `ACDOCA`, `BKPF`, `BSEG`, `KNA1`, `LFA1`, `MARA`, `VBAK`, `VBAP`, `EKKO`, `EKPO`, plus trading/risk/treasury tables and vector-specific tables). The `requires_hana_vector/1` classification fires on entity type match, on keyword patterns matching `trading|risk|treasury|financial|customer|internal`, or on vector operation keywords. Adds `hana_vector`, `hana_vector_filtered`, `hana_mmr`, `hana_es_hybrid`, and `hana_factual` resolution paths. The `get_embedding/3` predicate routes embedding generation to HANA's internal `SAP_NEB_V2` model for HANA data and to an external embedding service otherwise, consolidating the embedding strategy through the rule layer.

### `governance.mg` — GDPR Compliance and Data Governance

Implements data governance at the Mangle rule level using OData `PersonalData` vocabulary annotations. References three external regulatory documents: Singapore IMDA MGF (`mgf-for-agentic-ai.pdf`), 2025 AI Agent Index, and Johns Hopkins/MIT Sloan research paper `2503.18238v3.pdf`. Key rule groups:

- **Data subject detection** (`is_data_subject_entity/1`): Entity-annotation lookup for `PersonalData.EntitySemantics = DataSubject/DataSubjectDetails`, plus regex pattern fallback matching `customer|employee|user|person|contact|patient|member`.
- **Personal / sensitive field detection** (`is_personal_data_field/2`, `is_sensitive_data_field/2`): Annotation-based and regex-based (PII patterns, GDPR special-category patterns: `health|medical|ethnic|religion|political|sexual|genetic|biometric|criminal`).
- **Consent management** (`requires_consent/2`, `consent_verified/2`, `consent_for_purpose/3`): Sensitive field reads always require consent; export of personal data always requires consent; consent validity is time-bounded.
- **Anonymisation** (`must_anonymize/2`): Sensitive fields anonymised in non-production; personal fields masked in audit log contexts.
- **Audit** (`audit_required/2`): Four triggers — data-subject entity access, personal data queries matching regex patterns, sensitive data access, bulk exports.
- **Access control** (`access_allowed/3`): DPO role unrestricted; admin blocked from sensitive fields; regular users gate on `consent_verified`; negation rules deny access to sensitive fields for all roles except `dpo` and `medical_staff`.
- **Data retention** (`data_retention_expired/2`, `should_delete/2`): Reads `PersonalData.EndOfBusinessDate` annotation and compares to `current_date()`.
- **GDPR subject rights**: Four resolution predicates — `subject_access_request/2`, `subject_erasure_request/2`, `subject_rectification_request/4`, `subject_portability_request/2`.
- **Governance wrapper** (`resolve_with_governance/4`): Calls `audit_required`, `log_audit`, `access_allowed`, then `resolve/4`, then `apply_anonymization` before returning. Access-denied short-circuit returns score 0.

### `model_registry.mg` — Mangle-Based Model Configuration

Declares model facts as extensional data rather than code, supporting two provider types: `sap_ai_core` and `vllm`. Hard-declares no external API providers (OpenAI, Anthropic direct). Defines two backends: `aicore_primary` (priority 100, 60 s timeout) and `vllm_primary` (priority 90, 120 s timeout). Twelve models are registered: five GPT models via AI Core (`gpt-4`, `gpt-4-turbo`, `gpt-4o`, `gpt-4o-mini`, `gpt-3.5-turbo`), four private vLLM models (`llama-3-70b`, `llama-3-8b`, `mixtral-8x7b`, `codellama-34b`), and three embedding models via AI Core (`text-embedding-3-small`, `text-embedding-3-large`, `text-embedding-ada-002`). Capabilities, context windows, tiers, and model aliases are all encoded as facts. Health-aware routing (`backend_healthy/1`, `get_fallback_backend/2`) and priority-based backend selection (`get_primary_backend/2`) are derived predicates.

### `agent_classification.mg` — Agent Category and Autonomy

Implements the 2025 AI Agent Index taxonomy: three agent categories (`chat`, `browser`, `enterprise`), five autonomy levels (`L1` through `L5`), four agency criteria (`has_autonomy`, `has_goal_complexity`, `has_env_interaction`, `has_generality`), five safety controls (`guardrails`, `sandboxing`, `approval_gates`, `monitoring`, `emergency_stop`), and four action space types (`crm`, `cli`, `browser`, `read_only`, `write`). `route_to_vllm/2` fires for high-risk agents, for agents accessing sensitive data fields, and for L3–L5 agents without an emergency stop. The service self-classifies via ground facts: `agent_category("mangle-query-service", "enterprise")`, `autonomy_level("mangle-query-service", "L2")`, `agent_risk_level("mangle-query-service", "medium")`, with all four safety controls present.

### `rag_enrichment.mg` — Vocabulary-Enriched RAG Context

Enriches RAG context by merging Elasticsearch document retrieval with OData vocabulary annotations (`Common`, `Analytics`, `UI`, `PersonalData`). Three query classifiers: `is_knowledge_query` (what/how/explain/vocabulary/OData), `is_data_query` (entity extraction or show/get/find), `is_annotation_query` (`@UI.`, `@Common.` patterns). The `enrich_rag_context/2` predicate merges raw ES documents with vocabulary context from the OData vocabularies MCP. Adds resolution paths `rag_enriched` (score 85), `vocabulary_lookup` via MCP (score 90), and `entity_data` (score 88). `suggest_annotations/3` and `suggest_property_annotation/2` provide pattern-based OData annotation recommendations for entity properties. HANA type mapping (`hana_to_odata_type/2`) and column-name-based annotation inference are also defined here.

---

## Python FastAPI Layer

`cmd/server/main.py` is the production Python entry point. It initialises components in dependency order using `asyncio`'s lifespan context manager:

1. **Observability** (`observability.hana_tracing`, `observability.hana_metrics`) — OpenTelemetry tracer and Prometheus metrics registry.
2. **Core middleware** — semantic cache (`performance.hana_semantic_cache`), HANA circuit breaker (`middleware.hana_circuit_breaker`), rate limiter (`middleware.rate_limiter`), health monitor (`middleware.health_monitor`).
3. **Intelligence** — adaptive router (`intelligence.adaptive_router`), query rewriter (`intelligence.query_rewriter`), reranker (`intelligence.reranker`).
4. **HANA bridge** (`connectors.langchain_hana_bridge`) — initialised only if `HANA_HOST` is set; includes connection warmup for the async connection pool.

The request lifecycle for the core `/query` POST endpoint follows five ordered steps:

1. **Semantic cache lookup** — embeds the query via the HANA bridge and calls `cache.get(query, embedding)` with a configurable similarity threshold (default `SEMANTIC_CACHE_THRESHOLD=0.95`). Cache hits short-circuit all further processing.
2. **Query rewriting** (`intelligence.query_rewriter`) — expands and clarifies the query before search.
3. **HANA vector search** — invoked through the HANA circuit breaker; falls back gracefully to an empty result set if HANA is unavailable.
4. **Reranking** (`intelligence.reranker`) — cross-encoder reranking of the top-k candidates.
5. **Cache population** — the result is stored in the semantic cache for future lookups.

The `StatsResponse` endpoint (`GET /stats`) exposes runtime statistics from all five subsystems: cache, circuit breaker, rate limiter, router, and tracer. The `GET /health`, `GET /ready`, and `GET /live` endpoints implement Kubernetes health probes. `GET /metrics` serves Prometheus exposition format output.

---

## OpenAI-Compatible API Surface

The `openai/` directory provides a near-complete implementation of the OpenAI REST API:

| Module | Endpoints |
|---|---|
| `chat_completions.py` | `POST /v1/chat/completions` (streaming + non-streaming) |
| `completions.py` | `POST /v1/completions` |
| `embeddings.py` | `POST /v1/embeddings` |
| `models.py`, `models_endpoint.py` | `GET /v1/models`, `GET /v1/models/{model}` |
| `assistants.py` | CRUD `/v1/assistants/{id}` |
| `threads.py`, `messages.py`, `runs.py`, `run_steps.py` | Threads/Runs API |
| `files.py` | `/v1/files` upload/download |
| `fine_tuning.py`, `fine_tuning_advanced.py` | Fine-tuning jobs |
| `batches.py` | `/v1/batches` |
| `images.py` | `/v1/images/generations` |
| `audio.py` | `/v1/audio/*` |
| `moderations.py` | `/v1/moderations` |
| `vector_stores.py`, `vector_store_files.py`, `vector_store_file_batches.py` | Vector Store API |
| `realtime.py`, `realtime_audio.py`, `realtime_conversation.py`, `realtime_websocket.py` | Realtime API |
| `responses.py`, `response_output.py`, `response_store.py`, `response_streaming.py` | Responses API |
| `router.py` | Main `FastAPI` app and Mangle routing integration |
| `unified_router.py` | Unified routing for all model backends |
| `sse_streaming.py`, `streaming.py` | SSE and streaming response helpers |

`openai/router.py` is the principal integration point between the Python OpenAI surface and the Mangle/intelligence pipeline. It imports connectors (`hana_resolver`, `hybrid_search`), efficiency modules (`semantic_cache`, `batch_client`), and intelligence modules (`semantic_classifier`, `speculative_executor`, `model_selector`) with graceful `ImportError` fallback, controlled by feature flags (`ENABLE_SEMANTIC_CACHE`, `ENABLE_REQUEST_BATCHING`, `ENABLE_SEMANTIC_CLASSIFIER`, `ENABLE_SPECULATIVE_EXECUTION`, `ENABLE_MODEL_SELECTION`). All LLM calls are routed to SAP AI Core (`AICORE_URL`) or private vLLM; no direct OpenAI/Anthropic external API access is permitted, as enforced by both the `model_registry.mg` `valid_provider` facts and the documented `.env.example` policy.

---

## Connectors

### `aicore_adapter.py` — SAP AI Core Request/Response Transformation

Handles multi-model-family request format differences when targeting SAP AI Core. A `ModelFamily` enum (`ANTHROPIC`, `OPENAI`, `GEMINI`, `MISTRAL`) drives `detect_model_family(model_id)` via prefix-based lookup. `AnthropicBedrockAdapter` transforms standard OpenAI chat requests to the `bedrock-2023-05-31` Anthropic format that SAP AI Core uses for Claude models. Separate adapters handle each model family's request and response format.

### `langchain_hana_bridge.py` — LangChain HANA Integration

The central bridge between the Python service and HANA Cloud. Uses `langchain_hana.HanaDB` and `langchain_hana.HanaInternalEmbeddings` (model `SAP_NEB_V2`). Implements an `AsyncConnectionPool` to work around the synchronous connection pool in `langchain-hana`. Exposes `similarity_search`, `mmr_search`, `embed_query`, and `embed_documents` as async methods, running all blocking `hdbcli` operations through `loop.run_in_executor`. Connection warmup is triggered at application startup via `warmup_connections(pool_size=3)`.

### Other Connectors

- **`embeddings.py`, `batch_embeddings.py`** — embedding generation with batching and async pooling; `warmup_connections` pre-creates connections before first request.
- **`hana.py`** — direct HANA SQL execution for non-vector analytical queries.
- **`http_client.py`** — generic async HTTP client for AI Core and other REST services.
- **`streaming_client.py`** — SSE streaming client for AI Core streaming responses.
- **`vocabulary_client.py`** — OData vocabulary service client; supports `LOCAL` mode for sandboxed operation.
- **`flight_client.py`** — Apache Arrow Flight client for high-throughput data transfer.

---

## Intelligence Pipeline

### `adaptive_router.py` — Contextual Bandit Routing

Implements Thompson Sampling with context features to balance exploration and exploitation across eight resolution paths: `cache`, `hana_vector`, `hana_mmr`, `hana_analytical`, `hana_factual`, `es_hybrid`, `es_factual`, `llm`. Each path has a `PathStats` record tracking `selections`, `successes`, `total_reward`, and `total_latency_ms`. Context features include query length, entity presence, classification confidence, `is_hana_query`, and time bucketing. The router is configurable via environment variables (`ROUTING_EXPLORATION_RATE=0.1`, `ROUTING_LEARNING_RATE=0.1`, `ROUTING_UCB_CONFIDENCE=2.0`). Router state can be exported at shutdown and reimported at startup for continuity across restarts.

### `query_rewriter.py` — Query Expansion

Expands and disambiguates queries before search to improve retrieval precision.

### `reranker.py` — Cross-Encoder Reranking

Reranks retrieved documents using a cross-encoder model, returning `RankedResult` items with `content`, `metadata`, `final_score`, and `rank`.

### `model_selector.py` — Capability-Based Model Selection

Selects the optimal model for a given request based on capability requirements, tier, and load, using the same `model_registry.mg` facts exposed through a Python interface.

### `semantic_classifier.py` — Query Classification

Classifies queries into categories (FACTUAL, RAG_RETRIEVAL, LLM_REQUIRED, ANALYTICAL, etc.) with confidence scores. Used by both the Python layer and as a callback for the `classify_query` Mangle extensional predicate.

### `speculative.py`, `hana_speculative_executor.py` — Speculative Execution

Initiates parallel HANA queries and LLM calls, using the faster result and cancelling the slower one when `SPECULATIVE_THRESHOLD` confidence is met.

---

## Middleware and Resilience

The `middleware/` package provides a full resilience stack:

- **`circuit_breaker.py`, `hana_circuit_breaker.py`** — two-variant circuit breaker (generic and HANA-specific). `CB_FAILURE_THRESHOLD=5`, `CB_SUCCESS_THRESHOLD=2`, `CB_RECOVERY_TIMEOUT=30s`. State: closed → open → half-open. `ServiceRouter.emergency_stop()` is the emergency-stop mechanism referenced in the data product registry.
- **`retry.py`, `retry_handler.py`** — exponential backoff retry with jitter. `MAX_RETRIES=3`, `RETRY_BASE_DELAY=1.0s`, `RETRY_MAX_DELAY=8.0s`.
- **`rate_limiter.py`, `rate_limiter_v2.py`** — token-bucket and sliding-window rate limiting. `RATE_LIMIT_REQUESTS=100`, `RATE_LIMIT_WINDOW=60s`.
- **`health_monitor.py`** — aggregated health status for all registered service dependencies; drives `/health` and `/ready` responses.
- **`mtls.py`** — mutual TLS configuration for inter-service communication.
- **`validation.py`** — input validation middleware hardened against SQL injection (`DECLARE`, `UNION`, `EXEC`, etc.), NoSQL injection (`$where`, `$gt`, etc.), and path traversal. Enforces size limits: 10 MB max request body, 100 KB max single message, 500,000 chars max prompt, 128 max tools, 1,000 max array items. Model ID validated against `^[a-zA-Z0-9][a-zA-Z0-9\-_\.:/]{0,255}$`. Control characters stripped from safe-string fields.

---

## Performance Layer

- **`performance/cache_layer.py`** — multi-tier cache with in-memory LRU and optional Redis backend; configurable TTL (`CACHE_TTL=3600s`) and maximum entries (`CACHE_MAX_ENTRIES=10000`).
- **`performance/hana_semantic_cache.py`** — semantic cache backed by HANA vector search; uses embedding similarity to answer repeated or semantically equivalent queries. Threshold configurable (`SEMANTIC_CACHE_THRESHOLD=0.95`).
- **`performance/connection_pool.py`** — async connection pool management for HANA and other backends.
- **`performance/query_optimizer.py`** — query plan optimisation for HANA analytical queries.
- **`performance/load_tester.py`** — built-in load testing utilities.
- **`efficiency/semantic_cache.py`** — lighter-weight semantic cache used by the OpenAI router layer.
- **`efficiency/batch_client.py`** — request batching for embedding generation to reduce AI Core round-trips.

---

## Observability

The `observability/` package provides full OpenTelemetry instrumentation:

- **`tracing.py`, `hana_tracing.py`** — distributed tracing with OTLP exporter; `TRACING_ENDPOINT` and `TRACING_ENABLED` configuration.
- **`metrics.py`, `hana_metrics.py`** — Prometheus metrics registry; exposes `METRICS_PORT=9090` alongside the main service. The `deploy/prometheus.yml` configures a Prometheus scrape job for the service.
- **`logging.py`** — structured JSON logging with `timestamp`, `level`, `logger`, `message` fields; controlled by `LOG_FORMAT=json` and `LOG_LEVEL`.
- **`health.py`** — health check registry for use by `health_monitor.py`.

---

## MCP Server

`mcp_server/langchain_hana_mcp.py` implements a JSON-RPC 2.0 MCP server (port 9150) that exposes the following LangChain HANA tools as MCP-callable functions, bridging the gap between Mangle's extensional predicate callbacks and the Python `langchain_hana` library:

| Tool | Description |
|---|---|
| `hana_vector_search` | Similarity search returning top-k documents with scores |
| `hana_mmr_search` | Maximum Marginal Relevance search for diverse results |
| `hana_embed` | Internal embedding generation via `SAP_NEB_V2` |
| `hana_analytical` | Analytical query execution via `HanaAnalytical` |

The MCP server is initialised lazily on first invocation and runs as a sidecar alongside the Python FastAPI server.

---

## Data Product Registry (ODPS 4.1)

`data_products/registry.yaml` defines four data products at registry version 1.1.0:

| Product | Type | Autonomy | Safety Controls |
|---|---|---|---|
| `mangle-query-completion` | API | L2 | guardrails, monitoring, emergency-stop |
| `mangle-embeddings` | API | L2 | monitoring |
| `mangle-model-router` | Internal | L2 | guardrails, emergency-stop |
| `mangle-vocabulary-service` | Internal | L2 | monitoring |

The registry cross-references three regulatory compliance frameworks:

- **Singapore IMDA MGF v1.0** (January 2026) — status `HIGHLY_COMPLIANT`; chunks `mgf_004` (technical controls), `mgf_006` (risk assessment), `mgf_008` (safety controls), `mgf_012` (autonomy levels), `mgf_015` (emergency stop).
- **2025 AI Agent Index** (MIT/Cambridge/Stanford/Harvard) — status `COMPLIANT`.
- **Johns Hopkins/MIT Sloan research paper 2503.18238v3** (February 2026) — status `ALIGNED`.

Data security class routing policy:

| Class | Policy |
|---|---|
| `public` | `aicore-ok` — use SAP AI Core |
| `internal` | `hybrid` — auto-select |
| `confidential` | `hybrid` — prefer vLLM |
| `restricted` | `vllm-only` — vLLM mandatory |

HANA entity security classifications: `ACDOCA` and `BKPF` are `confidential/hybrid`; `KNA1` and `VBAK` are `internal/hybrid`.

---

## Deployment

The service ships with two Docker Compose configurations:

**`docker-compose.yml`** — development topology:
- `mangle` service (Python FastAPI, port 8080) using `Dockerfile.python`
- `elasticsearch` service (Elasticsearch 8.19.3, ports 9200/9300, persistent volume)
- Both on `sap-oss-network` bridge

**`deploy/docker-compose.yaml`** — production topology with explicit Prometheus scraping and full environment variable configuration. `deploy/prometheus.yml` configures scrape intervals for the metrics endpoint.

The `Dockerfile` (Go) and `Dockerfile.python` are both present at the repository root; `deploy/Dockerfile` is the production multi-stage build. The service requires Go 1.24 for the gRPC layer and Python 3.11+ for the FastAPI layer, with `uvloop` used as the event loop on non-Windows platforms.

---

## TypeScript Client

`client/typescript/` contains a TypeScript client for the OpenAI-compatible HTTP API, allowing TypeScript/JavaScript applications to consume the service using the same request/response shapes as the standard OpenAI SDK.

---

## Software Bill of Materials (SBOM)

### Go Dependencies

| Package | Version | License | Role |
|---|---|---|---|
| `github.com/google/mangle` | vendored (0.0.0-00010101) | Apache-2.0 | Datalog interpreter (core) |
| `github.com/elastic/go-elasticsearch/v8` | 8.19.3 | Apache-2.0 | Elasticsearch client |
| `google.golang.org/grpc` | 1.79.1 | Apache-2.0 | gRPC transport |
| `google.golang.org/protobuf` | 1.36.11 | BSD-3-Clause | Protobuf serialisation |
| `github.com/antlr4-go/antlr/v4` | 4.13.1 | BSD-3-Clause | Mangle ANTLR parser |
| `github.com/cespare/xxhash/v2` | 2.3.0 | MIT | Fast hashing |
| `go.opentelemetry.io/otel` | 1.39.0 | Apache-2.0 | OpenTelemetry tracing |
| `go.uber.org/multierr` | 1.11.0 | MIT | Error aggregation |
| `golang.org/x/{exp,net,sys,text}` | various | BSD-3-Clause | Standard extensions |
| `bitbucket.org/creachadair/stringset` | 0.0.11 | MIT | Mangle dependency |

### Python Runtime Dependencies

| Package | Version Constraint | Role |
|---|---|---|
| `langchain-hana` | ≥ 0.1.0 | HANA vector search / LangChain bridge |
| `hdbcli` | ≥ 2.20.0 | SAP HANA Python driver |
| `langchain` | ≥ 0.1.0 | LangChain orchestration |
| `langchain-core` | ≥ 0.1.0 | LangChain core |
| `langchain-community` | ≥ 0.0.20 | LangChain community integrations |
| `fastapi` | ≥ 0.108.0 | OpenAI-compatible HTTP server |
| `uvicorn` | ≥ 0.25.0 | ASGI server |
| `pydantic` | ≥ 2.5.0 | Request/response validation |
| `pydantic-settings` | ≥ 2.1.0 | Settings management |
| `httpx` | ≥ 0.25.0 | Async HTTP client |
| `aiohttp` | ≥ 3.9.0 | Async HTTP (AI Core streaming) |
| `numpy` | ≥ 1.24.0 | Vector operations |
| `opentelemetry-api` | ≥ 1.21.0 | Distributed tracing |
| `opentelemetry-sdk` | ≥ 1.21.0 | Tracing SDK |
| `opentelemetry-exporter-otlp` | ≥ 1.21.0 | OTLP exporter |
| `prometheus-client` | ≥ 0.19.0 | Prometheus metrics |
| `mcp` | ≥ 0.1.0 | MCP protocol |
| `tenacity` | ≥ 8.2.0 | Retry logic |
| `cachetools` | ≥ 5.3.0 | In-memory caching |
| `asyncio-throttle` | ≥ 1.0.2 | Async rate limiting |
| `python-dotenv` | ≥ 1.0.0 | `.env` configuration |
| `pytest` | ≥ 7.4.0 | Test runner |
| `pytest-asyncio` | ≥ 0.23.0 | Async test support |

---

## Testing

Tests reside in `tests/` (59 items) and `internal/engine/engine_test.go` / `routing_test.go`. The Go unit tests directly instantiate `MangleEngine` with `NewWithRules` to compose rule file sets and verify resolution outcomes. `engine_test.go` tests the full cycle: `DefineFact` → `Resolve` → `Resolution` struct validation. `routing_test.go` tests path selection for the five core routing paths. The Python test suite under `tests/` uses `pytest-asyncio` for async component testing.

---

## Security Posture

The following items were identified during this assessment:

1. **Open CORS policy** — `openai/router.py` and `cmd/server/main.py` both configure `allow_origins=["*"]` unconditionally, without reading `CORS_ORIGINS` from environment in the router. The `.env.example` documents `CORS_ORIGINS` but the FastAPI middleware in `router.py` ignores it. This allows cross-origin requests from any domain.

2. **`API_KEYS` not validated in router** — `middleware/validation.py` defines the `API_KEY_HEADER` and `API_KEYS` configuration, but `openai/router.py` does not show injection of this middleware, leaving the possibility of unauthenticated API access unless explicitly wired in deployment.

3. **`JWT_SECRET` not hardened** — `JWT_SECRET` is an environment variable with no enforcement of minimum entropy. If left empty or weak in a deployment, the JWT authentication path (`JWT_ENABLED=true`) would be insecure.

4. **Brittle keyword routing in `hana_vector.mg`** — The `requires_hana_vector` predicate uses a broad regex `(?i)(trading|risk|treasury|financial|customer|internal)` to classify queries for HANA routing. This is a content-based security classifier prone to false positives and false negatives; a carefully constructed query could bypass HANA-only routing for restricted data.

5. **Two large vendored artefacts with no references** — `hippocpp/` (3,358 items) and `kuzu/` (2,073 items) are present in the repository root but are not referenced in `go.mod`, `requirements.txt`, or any source file identified during this assessment. Their provenance, licensing, and whether they are included in Docker image builds is unclear.

6. **`LOG_REQUEST_BODY` / `LOG_RESPONSE_BODY` risk** — When enabled for debugging, these flags would log full LLM request and response bodies, including any PII or sensitive data that `governance.mg` would otherwise anonymise. The `.env.example` notes `Warning: Enable only for debugging` but this is advisory only.

7. **gRPC server unauthenticated** — `cmd/server/main.go` creates a bare `grpc.NewServer()` with no interceptor for authentication or TLS. If the gRPC port is reachable from outside the service mesh, arbitrary callers could invoke `QueryService.Resolve` directly, bypassing all Python-layer governance.

---

## Integration Topology

The service can be deployed in two configurations.

**Standalone HTTP gateway** — Python FastAPI on port 8080 handles all requests. Elasticsearch on port 9200 provides semantic cache and hybrid search. SAP AI Core provides LLM inference (all models). HANA Cloud (optional) provides vector search for sensitive data. The MCP server on port 9150 bridges HANA tools to the Mangle engine. Prometheus on port 9090 scrapes metrics.

**With Go gRPC Rule Engine** — The Python FastAPI layer delegates rule evaluation to the Go gRPC `QueryService`. The Go layer has the real Mangle interpreter with registered external predicate callbacks for Elasticsearch, MCP, and LLM operations. This path supports the full production feature set including dynamic fact injection, rule hot-reload, and engine-mode external predicates.

---

## Assessment Summary

The Mangle Query Service is an architecturally ambitious system that makes a genuinely distinctive design choice: placing all routing, governance, and compliance logic in a declarative Datalog rule language rather than in imperative application code. This makes the governance rules independently auditable, testable, and modifiable without touching application code. The GDPR compliance coverage in `governance.mg` is thorough and references specific regulatory frameworks. The OpenAI compatibility layer is extensive.

The following pre-production items should be addressed before enterprise deployment:

1. **Wire `CORS_ORIGINS` into `openai/router.py`** — the `.env.example` configuration is not honoured by the main router.
2. **Validate that `validation.py` API key middleware is mounted** — confirm the authentication chain is active in all entry points.
3. **Protect the gRPC port** — add mutual TLS or a network-policy restriction to prevent direct unauthenticated access to the Go `QueryService`.
4. **Audit vendored `hippocpp/` and `kuzu/` artefacts** — determine their provenance, confirm their licences are compatible with Apache-2.0, and exclude them from Docker image builds if unreferenced.
5. **Harden the `hana_vector.mg` keyword classifier** — replace the broad `customer|internal` pattern with a more precise classification strategy to prevent misrouting of restricted data.
