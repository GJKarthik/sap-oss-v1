# Technical Assessment: generative-ai-toolkit-for-sap-hana-cloud

**Repository:** `SAP/generative-ai-toolkit-for-sap-hana-cloud`
**Assessment Date:** 2025
**Assessed By:** SAP Engineering Review
**Version:** 1.0.26021200 (package name: `hana_ai`)
**License:** Apache-2.0 (SPDX)
**Primary Language:** Python (declared `>=3.0`; runtime requires ≥ 3.10 for `str | None` syntax)
**Build System:** setuptools ≥ 62.4; `setuptools.dynamic` dependencies from `requirements.txt`
**Published As:** `pip install hana-ai`

---

## Table of Contents

1. [Purpose and Positioning](#1-purpose-and-positioning)
2. [Repository Layout](#2-repository-layout)
3. [Public API Surface](#3-public-api-surface)
4. [HANAMLToolkit — Tool Registry](#4-hanamltools-toolkit--tool-registry)
5. [HANAMLAgentWithMemory](#5-hanaml-agentwithmemory)
6. [HANAMLRAGAgent](#6-hanamlragagent)
7. [Mem0HANARAGAgent and Memory Layer](#7-mem0hanaraagent-and-memory-layer)
8. [SmartDataFrame](#8-smartdataframe)
9. [HANA SQL Agent](#9-hana-sql-agent)
10. [HANA Agent Base (AgentBase / DataAgent / DiscoveryAgent)](#10-hana-agent-base)
11. [Vector Store Layer](#11-vector-store-layer)
12. [Embedding Services](#12-embedding-services)
13. [HANASemanticCache](#13-hanasamantic-cache)
14. [CorrectiveRetriever](#14-corrective-retriever)
15. [EnhancedAICoreClient](#15-enhanced-ai-core-client)
16. [langchain_compat — Compatibility Shim](#16-langchain_compat--compatibility-shim)
17. [MCP Server (hana-ai-toolkit-mcp)](#17-mcp-server-hana-ai-toolkit-mcp)
18. [SAP OpenAI-Compatible Server](#18-sap-openai-compatible-server)
19. [Governance Agent (GenAiToolkitAgent)](#19-governance-agent)
20. [Mangle Datalog Governance Layer](#20-mangle-datalog-governance-layer)
21. [Software Bill of Materials (SBOM)](#21-software-bill-of-materials-sbom)
22. [Integration Topology](#22-integration-topology)
23. [Security Profile](#23-security-profile)
24. [Licensing and Compliance](#24-licensing-and-compliance)
25. [Pre-Production Items](#25-pre-production-items)

---

## 1. Purpose and Positioning

`hana_ai` (`pip install hana-ai`) is an extension of the SAP HANA ML Python client library (`hana-ml`), focused on Generative AI and RAG use cases on top of SAP HANA Cloud. It is positioned in `sap-ai-experience-map.yaml` at the `ai_core` / `ai-prompt-agent` tier.

The library's core value proposition is to bring conversational, LLM-driven workflows to HANA Cloud's built-in machine learning capabilities — the Predictive Analysis Library (PAL) time-series and forecasting functions, the HANA Vector Engine, and the `VECTOR_EMBEDDING()` SQL function. Callers supply a `hana_ml.ConnectionContext`, compose a `HANAMLToolkit` with the specific PAL tools needed, and attach that toolkit to one of three agent classes to get a conversational agent backed by HANA data.

Distinguishing capabilities relative to other repositories in this workspace:
- 28 PAL ML tools covering time-series forecasting, anomaly detection, accuracy measurement, and model storage.
- `EnhancedAICoreClient` (857 lines) with LRU response caching, token budgeting, rate limiting, and multi-strategy model routing.
- `HANASemanticCache` providing embedding-similarity caching of vector search results (claimed 60–80% hit rate).
- `Mem0HanaAdapter` / `Mem0MemoryManager` — a Mem0-compatible long-term memory layer on HANA, intended as a drop-in until the official Mem0 upstream `hana` provider lands.
- `HANAMLToolkit.launch_mcp_server()` — embedded MCP server launch from within the toolkit process over `stdio`, `sse`, or `http` transports.

---

## 2. Repository Layout

```
generative-ai-toolkit-for-sap-hana-cloud-main/
├── src/hana_ai/                        # Installable Python package
│   ├── __init__.py                     # Version only; no __all__ exports
│   ├── langchain_compat.py             # LangChain compatibility shim (336 lines)
│   ├── smart_dataframe.py              # SmartDataFrame (205 lines)
│   ├── utility.py                      # Minimal helpers
│   ├── agents/
│   │   ├── hanaml_agent_with_memory.py # HANAMLAgentWithMemory (429 lines)
│   │   ├── hanaml_rag_agent.py         # HANAMLRAGAgent (664 lines); stateless_chat
│   │   ├── hana_sql_agent.py           # create_hana_sql_agent (197 lines)
│   │   ├── mem0_hana_agent.py          # Mem0HANARAGAgent (297 lines)
│   │   ├── hanaml_dataframe_agent.py   # DataFrame agent
│   │   ├── utilities.py                # _check_generated_cap_for_bas, _get_user_info
│   │   └── hana_agent/                 # HANA native stored-procedure agent
│   │       ├── agent_base.py           # AgentBase (311 lines)
│   │       ├── data_agent.py           # DataAgent subclass
│   │       ├── discovery_agent.py      # DiscoveryAgent subclass
│   │       ├── progress_monitor.py     # TextProgressMonitor
│   │       └── utility.py             # AI Core PSE/remote source SQL helpers
│   ├── aicore/
│   │   └── enhanced_client.py          # EnhancedAICoreClient (857 lines)
│   ├── mem0/
│   │   ├── hana_mem0_adapter.py        # Mem0HanaAdapter (349 lines)
│   │   ├── memory_manager.py           # Mem0MemoryManager (434 lines)
│   │   ├── memory_classifier.py        # Mem0IngestionClassifier
│   │   └── memory_entity_extractor.py  # Mem0EntityExtractor
│   ├── tools/
│   │   ├── toolkit.py                  # HANAMLToolkit (689 lines); MCP server launch
│   │   ├── agent_as_a_tool.py          # Agent-as-tool wrapper
│   │   ├── code_template_tools.py      # GetCodeTemplateFromVectorDB (deprecated for SmartDataFrame)
│   │   ├── resilience/                 # Circuit-breaker helpers
│   │   ├── df_tools/                   # DataFrame-bound variants of all ML tools
│   │   └── hana_ml_tools/              # 19 PAL tool modules
│   └── vectorstore/
│       ├── hana_vector_engine.py       # HANAMLinVectorEngine (123 lines)
│       ├── embedding_service.py        # PALModelEmbeddings, HANAVectorEmbeddings, GenAIHubEmbeddings
│       ├── pal_cross_encoder.py        # PALCrossEncoder (93 lines)
│       ├── semantic_cache.py           # HANASemanticCache (321 lines)
│       ├── corrective_retriever.py     # CorrectiveRetriever (272 lines)
│       ├── union_vector_stores.py      # UnionVectorStores, merge_hana_vector_store
│       ├── code_templates.py           # get_code_templates()
│       ├── reserved_words.txt          # SQL reserved word list
│       └── knowledge_base/             # ~480 bundled knowledge files (SQL + Python templates)
├── agent/
│   └── gen_ai_toolkit_agent.py        # GenAiToolkitAgent + inline MangleEngine (268 lines)
├── mangle/
│   ├── a2a/mcp.mg                     # A2A MCP service registry + routing (48 lines)
│   └── domain/
│       ├── agents.mg                  # Agent governance rules (125 lines)
│       └── data_products.mg           # ODPS data product rules (72 lines)
├── mcp_server/
│   └── server.py                      # HANA AI Toolkit MCP Server (821 lines), port 9130
├── sap_openai_server/
│   ├── server.py                      # OpenAI-compatible server (51 420 bytes)
│   ├── proxy.mg                       # Mangle proxy routing rules
│   └── README.md                      # Endpoint catalogue
├── data_products/
│   ├── gen_ai_hana_service.yaml        # ODPS 4.1 data product definition
│   └── registry.yaml                  # Data product catalog / global policies
├── nutest/                             # 85 test/demo notebooks
├── pyproject.toml                      # Build config (setuptools)
└── requirements.txt                    # 9 runtime dependencies
```

The installable package is `src/hana_ai/`. The top-level `__init__.py` exports only `__version__`; there is no `__all__`. All imports are from sub-modules directly.

---

## 3. Public API Surface

| Class / Function | Module | Role |
|---|---|---|
| `HANAMLToolkit` | `tools.toolkit` | Tool registry; embedded MCP server launcher |
| `HANAMLAgentWithMemory` | `agents.hanaml_agent_with_memory` | Conversational ML agent with in-session memory |
| `HANAMLRAGAgent` | `agents.hanaml_rag_agent` | RAG agent with dual short/long-term memory |
| `Mem0HANARAGAgent` | `agents.mem0_hana_agent` | RAG agent using Mem0-style HANA memory |
| `SmartDataFrame` | `smart_dataframe` | Conversational HANA DataFrame interface |
| `create_hana_sql_agent` | `agents.hana_sql_agent` | SQL agent over HANA via SQLAlchemy |
| `AgentBase` / `DataAgent` / `DiscoveryAgent` | `agents.hana_agent` | HANA native stored-procedure agent |
| `HANAMLinVectorEngine` | `vectorstore.hana_vector_engine` | HANA Vector Engine wrapper |
| `PALModelEmbeddings` | `vectorstore.embedding_service` | In-database PAL embeddings |
| `HANAVectorEmbeddings` | `vectorstore.embedding_service` | HANA `VECTOR_EMBEDDING()` embeddings |
| `GenAIHubEmbeddings` | `vectorstore.embedding_service` | SAP AI Hub embeddings |
| `PALCrossEncoder` | `vectorstore.pal_cross_encoder` | In-database cross-encoder reranking |
| `HANASemanticCache` | `vectorstore.semantic_cache` | Cosine-similarity query cache |
| `CorrectiveRetriever` | `vectorstore.corrective_retriever` | LangGraph CRAG retriever |
| `UnionVectorStores` | `vectorstore.union_vector_stores` | Multi-store aggregation |
| `Mem0HanaAdapter` | `mem0.hana_mem0_adapter` | Mem0 API compatibility layer on HANA |
| `Mem0MemoryManager` | `mem0.memory_manager` | High-level memory with TTLs and ingestion rules |
| `EnhancedAICoreClient` | `aicore.enhanced_client` | AI Core client with caching, routing, rate limiting |

---

## 4. HANAMLToolkit — Tool Registry

`HANAMLToolkit` (689 lines) accepts a `hana_ml.ConnectionContext` and an optional `used_tools` filter. It assembles 28 PAL ML tool instances across 19 modules covering time-series forecasting, anomaly detection, model storage, artifact generation, data access, and visualization. All tools expose a `BaseTool`-compatible interface and carry the `connection_context` for HANA execution.

**Tool management**: `add_custom_tool`, `delete_tool`, and `reset_tools` (accepts tool instances or name strings) manage the active tool set. `set_bas(True)` swaps `CAPArtifactsTool` for `CAPArtifactsForBASTool` for BAS environments. A `_global_mcp_servers` class-level registry prevents duplicate server instances across `HANAMLToolkit` instances in the same process.

**Embedded MCP server** (`launch_mcp_server`): Registers all active tools with a `FastMCP` instance and starts it in a background daemon `threading.Thread`. Three transports: `stdio` (default, no port), `sse` (port auto-increments on conflict up to `max_retries`), `http` (requires `fastmcp` package; pre-builds explicit `inputSchema` from each tool's `args_schema` Pydantic model). An `auth_token` parameter is forwarded to FastMCP's token validation.

Two tools — `ClassificationTool` and `RegressionTool` — are imported from `unsupported_tools.py` and included in the default set despite their module name suggesting they are stub implementations.

---

## 5. HANAMLAgentWithMemory

Wraps a LangChain agent executor with `InMemoryChatMessageHistory` for session-scoped state. A `_ToolObservationCallbackHandler` enforces a bounded observation window (default 5 observations) by pruning the oldest `AIMessage("Observation: ...")` entries from memory before adding a new one.

**System prompt**: `"You're an assistant skilled in data science using hana-ml tools. Ask for missing parameters if needed. Regardless of whether this tool has been called before, it must be called."` — the final clause is a prompt engineering workaround for LLMs that skip tool calls after seeing cached observations.

No locking is in place on the shared `InMemoryChatMessageHistory`. Concurrent `invoke` calls from multiple threads are unsafe.

---

## 6. HANAMLRAGAgent

`HANAMLRAGAgent` (664 lines) implements a two-tier memory architecture:

**Short-term memory**: `ConversationBufferWindowMemory` (window `k`, default 10).

**Long-term memory**: `SQLChatMessageHistory` backed by either a HANA SQLAlchemy URL (`connection_context.to_sqlalchemy()`) or a local SQLite file. HANA-side table `HANAAI_LONG_TERM_DB_{user}` is created with `ID`, `SESSION_ID`, `MESSAGE` columns if absent.

**RAG vector store**: Two backends via `vector_store_type`:
- `"hanadb"` — `langchain_community.vectorstores.hanavector.HanaDB`; table `HANA_AI_CHAT_HISTORY_{user}`.
- `"faiss"` — `langchain_community.vectorstores.FAISS` serialised to disk; loaded with `allow_dangerous_deserialization=True` (pickle, arbitrary-code-execution risk if path is not controlled).

**Reranking**: Retrieves `rerank_candidates` (default 20) documents; reranks with cross-encoder to select top `rerank_k` (default 3) above `score_threshold` (default 0.5). Cross-encoder selection order: (1) `PALCrossEncoder` if `%PAL_CROSSENCODER%` PAL function exists, (2) `sentence_transformers.CrossEncoder('cross-encoder/ms-marco-MiniLM-L-6-v2')`, (3) dummy stub returning 0.0.

`delete_message_long_term_store(message_id)` deletes a specific message by ID using `sqlalchemy.delete`. `forget_percentage` (default 0.1) evicts the oldest 10% of long-term memories when `long_term_memory_limit` is reached.

---

## 7. Mem0HANARAGAgent and Memory Layer

`Mem0HANARAGAgent` routes all long-term memory through `Mem0MemoryManager` / `Mem0HanaAdapter` instead of direct SQLAlchemy access.

**Mem0HanaAdapter** (349 lines) provides `add`, `search`, `delete`, `update` backed by `langchain_community.vectorstores.hanavector.HanaDB`. `add` embeds with `sha256`-based content hash for deduplication. `search` supports optional `PALCrossEncoder` reranking. `update` falls back to delete-then-add.

**Mem0MemoryManager** (434 lines) adds: entity partitioning (`entity_id` + `entity_type` scoping), `IngestionRules` (min/max length, allow/deny tags), TTL management (`expires_at` in metadata; `cleanup_expired()` bulk-deletes), optional auto-classification (`Mem0IngestionClassifier`), optional entity extraction (`Mem0EntityExtractor`), pluggable `export_handler`. Graph architecture is declared in the API but not implemented.

---

## 8. SmartDataFrame

`SmartDataFrame` (205 lines) subclasses `hana_ml.dataframe.DataFrame`, adding `ask(question)` and `transform(question)`. `configure(llm, tools)` builds a LangChain agent executor. The default tool set covers time-series operations bound to the dataframe's `connection_context`. The system prompt prepends the dataframe's SQL `select_statement` as context. Note from `INTRODUCTION.md`: not compatible with GPT-4o; works with GPT-4 and other models.

---

## 9. HANA SQL Agent

`create_hana_sql_agent` wraps `langchain_community.agent_toolkits.sql.base.create_sql_agent` with a HANA-specific `_sql_toolkit` that merges caller-provided extra tools with `SQLDatabaseToolkit` tools (schema inspection, query execution, result formatting) against HANA via SQLAlchemy. The function signature mirrors `create_sql_agent` for drop-in compatibility.

---

## 10. HANA Agent Base

`AgentBase` (311 lines) is an `hana_ml.ml_base.MLBase` subclass wrapping HANA Cloud's native AI agent stored procedures. It manages a remote source (`HANA_DISCOVERY_AGENT_CREDENTIALS`) and PSE (`AI_CORE_PSE`) for AI Core TLS certificate management. `run(query)` calls the configured HANA stored procedure via `_call_agent_sql` and streams progress via `TextProgressMonitor`. `DataAgent` and `DiscoveryAgent` are thin subclasses with different default `procedure_name` values. The `agent_type` constructor parameter is deprecated in favour of `procedure_name`.

---

## 11. Vector Store Layer

**HANAMLinVectorEngine** (123 lines): Uses `REAL_VECTOR GENERATED ALWAYS AS VECTOR_EMBEDDING("description", 'DOCUMENT', '{model_version}')` — a computed column that triggers HANA's in-database embedding on insert, eliminating external embedding calls. Default model: `'SAP_NEB.20240715'`.

`query` constructs raw SQL with `TOP {top_n}`, `COSINE_SIMILARITY` (or specified function), and `TO_REAL_VECTOR(VECTOR_EMBEDDING('{input}', 'QUERY', '{model_version}'))`. **The `input` value is directly interpolated into the SQL string without parameterisation** — an SQL injection risk (see §23 F-1).

`upsert_knowledge` line 94 has a syntax bug: `f"REAL_VECTOR GENERATED ALWAYS AS VECTOR_EMBEDDING(\"description\", 'DOCUMENT', {self.model_version}"` — missing closing `)` and no quotes around `model_version`. This will produce a SQL syntax error on upsert.

**UnionVectorStores**: Aggregates multiple `HANAMLinVectorEngine` instances. All-HANA path queries each store and picks the highest-distance result using `np.sort`. `merge_hana_vector_store` materialises a SQL `UNION` into a new HANA table.

---

## 12. Embedding Services

**PALModelEmbeddings**: Delegates to `hana_ml.text.pal_embeddings.PALEmbeddings`. Creates a UUID-named temporary table, calls `PALEmbeddings.fit_transform`, collects results, cleans up. Thread-safe at the table-name level (UUID suffix) but the shared `PALEmbeddings` object is not guarded.

**HANAVectorEmbeddings**: Delegates to `VECTOR_EMBEDDING()` SQL function via `connection_context.sql`. Default embedding service for `HANAMLRAGAgent` and `Mem0HANARAGAgent` when HANA is available.

**GenAIHubEmbeddings**: Wraps `gen_ai_hub.proxy.langchain.init_embedding_model`. At import time, if `gen_ai_hub` is not installed, unconditionally runs `subprocess.check_call([sys.executable, "-m", "pip", "install", "sap-ai-sdk-gen[all]"])`. See §23 F-3.

---

## 13. HANASemanticCache

`HANASemanticCache` (321 lines) caches vector search results keyed by embedding similarity (not exact match). Architecture: `OrderedDict` LRU cache for entries + parallel `_embeddings` dict for embedding vectors. Lookup: SHA-256 hash fast-path (exact), then cosine similarity scan against all cached embeddings. Default `similarity_threshold` = 0.92. `CacheStats` tracks hits, misses, evictions, expirations, total latency. **No locking — not thread-safe for concurrent access.**

---

## 14. CorrectiveRetriever

`CorrectiveRetriever` (272 lines) implements CRAG using LangGraph `StateGraph`. Workflow: (1) `_retrieve` — vector search. (2) `_grade_documents` — LLM relevance grading via `PydanticToolsParser`. (3) `_decide_to_generate` — route to generate or rewrite+retry (up to `max_iter`). (4) `_generate` — synthesise answer. If `langgraph` is not installed, it is auto-installed via `subprocess.check_call` at module import time.

---

## 15. EnhancedAICoreClient

`EnhancedAICoreClient` (857 lines, `aicore/enhanced_client.py`) provides a production-grade async AI Core client with five subsystems:

**ResponseCache**: SHA-256-keyed LRU cache (default 1 000 entries, 1-hour TTL) for identical chat completions. Hit/miss stats exposed.

**TokenBudget**: Pre-flight budget check (per-request default 4 096 tokens, hourly 100 000, daily 1 000 000). Auto-resets at period boundaries.

**RateLimiter**: Token-bucket rate limiter (default 60 RPM, 100 000 TPM). Async `acquire(estimated_tokens)` sleeps if either bucket is empty.

**ModelRouter**: Selects AI Core deployments by `RoutingStrategy` — `COST_OPTIMIZED`, `LATENCY_OPTIMIZED` (rolling 100-sample average), `QUALITY_OPTIMIZED` (tier order), `BALANCED` (30% cost + 30% latency + 40% tier composite). Capabilities and tier auto-detected from deployment name heuristics.

**OAuth token management**: `_refresh_token` correctly uses `asyncio.get_event_loop().run_in_executor(None, urllib.request.urlopen)` — offloads blocking HTTP to thread pool, preserving event loop responsiveness. This is the **correct pattern** (contrast with `gen_ai_toolkit_agent.py::_call_mcp` which blocks directly).

Retry logic: up to `max_retries` (default 3) attempts with `asyncio.sleep(retry_delay * (attempt + 1))` on HTTP 429 or 5xx.

---

## 16. langchain_compat — Compatibility Shim

`langchain_compat.py` (336 lines) normalises import paths across LangChain versions via cascaded `try/except ImportError` blocks (up to 4 fallback levels per symbol). Covers `BaseLLM`, `ChatPromptTemplate`, `BaseTool`, `BaseToolkit`, `Embeddings`, `ConversationBufferWindowMemory`, `AgentExecutor`, `GraphAgentExecutor`, and agent construction factories. `BaseToolkit` falls back to `None` if unavailable in any location. The shim makes the library runnable against LangChain pre-0.1 through 1.x.

---

## 17. MCP Server (hana-ai-toolkit-mcp)

`mcp_server/server.py` (821 lines): MCP protocol `2024-11-05`, JSON-RPC 2.0, port **9130**. Standard library HTTP only (no web framework).

**Federated endpoints**:
- `HANA_TOOLKIT_VECTOR_MCP_ENDPOINT` (default `http://localhost:9120/mcp`) — Elasticsearch-backed vector MCP.
- `HANA_TOOLKIT_AGENT_MCP_ENDPOINT` (default `http://localhost:9180/mcp`) — vLLM MCP.

**9 registered tools**: `hana_chat` (AI Core), `hana_vector_add` (delegates `es_index` to vector endpoint), `hana_vector_search` (delegates `ai_semantic_search`), `hana_rag` (vector search + AI Core generation), `hana_embed` (AI Core), `hana_agent_run` (delegates `vllm_chat` to agent endpoint), `hana_memory_store` (process-local dict), `hana_memory_retrieve` (process-local dict), `mangle_query` (Mangle fact store + delegation).

**3 resources**: `hana://tables`, `hana://memory`, `mangle://facts`.

**Important**: `hana_memory_store`/`hana_memory_retrieve` use a process-local `self.facts["memory_store"]` dict. All stored memories are lost on process restart. Durable memory requires `Mem0HanaAdapter` or `HANAMLRAGAgent`'s SQL store.

**No authentication** on the `/mcp` endpoint. See §23 F-5.

---

## 18. SAP OpenAI-Compatible Server

`sap_openai_server/server.py` (51 420 bytes, the largest file in this workspace) provides a full OpenAI-compatible server equivalent to the one in `langchain-integration-for-sap-hana-cloud-main`. `proxy.mg` (7 440 bytes) contains Mangle Datalog routing rules for the proxy layer. The `README.md` covers five endpoint groups: Core, Moderations & Media, Assistants API v2, Batches API, and HANA Vector Store.

---

## 19. Governance Agent

`agent/gen_ai_toolkit_agent.py` (268 lines) implements `GenAiToolkitAgent`. **All requests unconditionally route to vLLM** — `route_to_vllm(Request) :- true.` and `route_to_aicore(_) :- false.`. No keyword or schema analysis is performed. The routing decision is a constant.

MangleEngine facts: `agent_can_use = {rag_query, generate_text, create_embeddings, semantic_search, summarize, mangle_query}`, `agent_requires_approval = {index_documents, delete_embeddings, update_vector_store, export_data}`. Prompting policy: max_tokens 4 096, temperature 0.7.

`invoke()` flow: (1) check `requires_human_review` → return `pending_approval` without calling MCP. (2) check `safety_check_passed` → return `blocked` if not in `agent_can_use`. (3) fetch prompting policy. (4) call vLLM MCP with policy-injected prompt. (5) log audit.

**Two structural bugs shared with langchain-hana agent**:
- `_call_mcp` is `async def` but calls `urllib.request.urlopen` synchronously (blocks event loop up to 120 s).
- `_log_audit` records `hash(prompt)` as `prompt_hash` — non-deterministic across process restarts.

---

## 20. Mangle Datalog Governance Layer

**`mangle/a2a/mcp.mg`** (48 lines) registers five services all on `http://localhost:9130/mcp`: `hana-chat`, `hana-vector`, `hana-rag`, `hana-agent`, `hana-memory`. Nine tool-to-service mappings. Five intent routing rules (`/chat`, `/vector`, `/rag`, `/agent`, `/memory`). Two RAG readiness rules.

**`mangle/domain/agents.mg`** (125 lines): `gen-ai-hana-agent`, autonomy **L2**, endpoint `http://localhost:9130/mcp`, `default_backend = "vllm"`. Routing rule: `route_to_vllm(Request) :- true.` — unconditional for every request, the most restrictive posture in the workspace. Audit level `"full"` with `audit_generations = true` (extends scope beyond the `langchain-hana` agent's `audit_sql_queries = true`).

Line 7: `include "../../../regulations/mangle/rules.mg"` — unresolvable out-of-repo import path (same issue as all other assessed repositories).

**`mangle/domain/data_products.mg`** (72 lines): `gen-ai-hana-service-v1`, confidential, vllm-only. Three output ports (rag-query, text-generation, embeddings — all confidential, vllm-only). Two input ports (hana-tables confidential; documents internal). SLA: 99.5% availability, 5 000 ms p95 latency (relaxed vs 3 000 ms in `langchain-hana`, reflecting heavier PAL workloads), 100 req/min. `retentionPolicy: "no-storage"` — LLM-generated outputs must not be persisted.

---

## 21. Software Bill of Materials (SBOM)

### Python Runtime Dependencies (`requirements.txt`)

| Package | Version Constraint | Role |
|---|---|---|
| `langchain-community` | unconstrained | SQL agent, FAISS, HanaDB (legacy) |
| `langchain-text-splitters` | unconstrained | Text chunking for long-term memory |
| `numpy` | unconstrained | Vector ops in UnionVectorStores, SemanticCache |
| `pandas` | unconstrained | PAL tool data exchange |
| `hana-ml` | `>=2.27.26020601` | HANA ML PAL client; MLBase, ConnectionContext |
| `pydantic` | `>=2.11,<2.13` | Schema validation; unusually tight range |
| `sap-ai-sdk-gen[all]` | unconstrained | SAP AI Hub / Gen AI SDK |
| `langchain-hana` | unconstrained | Sibling package (brings langchain-core, langchain, hdbcli) |
| `fastmcp` | `>=2.0` | HTTP/SSE transport for `launch_mcp_server` |

**Constraint concerns**:

1. `langchain-community`, `langchain-text-splitters`, `numpy`, `pandas`, `sap-ai-sdk-gen`, `langchain-hana` — all **completely unconstrained**. Reproducible builds are impossible.
2. `pydantic>=2.11,<2.13` — an unusually tight range that will break installation when Pydantic 2.13 releases unless `requirements.txt` is updated.
3. `langchain_community.vectorstores.hanavector.HanaDB` (used by `HANAMLRAGAgent` and `Mem0HanaAdapter`) may change or be removed in future `langchain-community` releases.
4. `requires-python = ">=3.0"` in `pyproject.toml` — allows installation on Python 3.0–3.9, but `str | None` syntax in `agent_base.py:24` requires Python 3.10+ at runtime.

### Optional Dependencies (not declared)

| Package | Used By | Note |
|---|---|---|
| `sentence-transformers` | `HANAMLRAGAgent` fallback cross-encoder | Guarded `try/except`; falls back to dummy |
| `langgraph` | `CorrectiveRetriever` | Auto-installs via `subprocess.check_call` at import |
| `mcp` | `HANAMLToolkit.launch_mcp_server` | Auto-installs via `subprocess.check_call` at import |
| `fastapi`, `uvicorn` | `sap_openai_server/server.py` | Optional; `USE_FASTAPI` flag |
| `faiss-cpu`/`faiss-gpu` | `HANAMLRAGAgent` FAISS path | Must be installed separately |

### Auto-Install Pattern (4 sites)

`toolkit.py:31`, `toolkit.py:41`, `embedding_service.py:27`, `corrective_retriever.py:25` — all use `subprocess.check_call([sys.executable, "-m", "pip", "install", ...])` at module import time. See §23 F-3.

### Vendored Artefact

`kuzu/` (~2 073 files, Apache-2.0) — same unintegrated Kuzu embedded graph database directory present in all assessed sibling repositories.

---

## 22. Integration Topology

**SAP HANA Cloud** (ODBC via `hana-ml`): All PAL tools, `HANAMLinVectorEngine`, `PALModelEmbeddings`, `PALCrossEncoder`, and `HANAVectorEmbeddings` require a live `ConnectionContext`. All PAL computations execute as HANA stored procedures — compute stays in-database.

**SAP AI Core** (HTTPS, OAuth `client_credentials`): `EnhancedAICoreClient` and the MCP server both use `client_credentials` grants. The MCP server's token cache is process-global (module-level `_cached_token` dict).

**SAP AI Hub / Gen AI Hub SDK**: `GenAIHubEmbeddings` uses `gen_ai_hub.proxy.langchain.init_embedding_model` with managed connection pooling.

**LangChain Community** (library): `SQLChatMessageHistory` for SQL-backed long-term memory; `HanaDB` (legacy community) for RAG vector store in `HANAMLRAGAgent` and `Mem0HanaAdapter`.

**Elasticsearch / Vector MCP** (`http://localhost:9120/mcp`): The MCP server's vector tools delegate to `es_index` and `ai_semantic_search` on a separate Elasticsearch-backed MCP server.

**vLLM** (`http://localhost:9180/mcp`): `hana_agent_run` delegates to `vllm_chat`. The governance agent hard-routes all requests here unconditionally.

---

## 23. Security Profile

### Strengths

**SHA-256 content identifiers.** `ResponseCache._make_key` and `Mem0HanaAdapter.add` both use `hashlib.sha256` for deterministic, collision-resistant content identifiers — the correct pattern absent from the sibling repositories' audit hash implementation.

**Async I/O offload in EnhancedAICoreClient.** `_refresh_token` and `_request` use `asyncio.get_event_loop().run_in_executor(None, urllib.request.urlopen)` correctly, keeping the event loop unblocked. Contrast with the blocking `urllib.request.urlopen` in `gen_ai_toolkit_agent.py::_call_mcp`.

**UUID temporary table names.** `PALModelEmbeddings` and `PALCrossEncoder` use UUID suffixes for temporary table names, preventing cross-session collision.

**In-database PAL compute.** Training data and model artefacts never leave HANA Cloud.

**Token budget enforcement.** `TokenBudget.check_budget` provides application-layer cost governance before AI Core requests.

### Findings

**(F-1) SQL injection in HANAMLinVectorEngine.query.** `hana_vector_engine.py:115` interpolates the `input` query string directly into a SQL string with `.format(...)`. A caller-supplied value containing a single quote (e.g., `"O'Brien"`) will produce malformed SQL. With a crafted input the caller can break out of the SPARQL string literal and inject arbitrary SQL. Fix: use a HANA parameterised query with `?` placeholder and pass `input` as a parameter to `connection_context.sql(..., parameters=[input, ...])`.

**(F-2) Async/blocking mismatch in GenAiToolkitAgent._call_mcp.** `gen_ai_toolkit_agent.py:173`: `_call_mcp` is declared `async def` but uses `urllib.request.urlopen(req, timeout=120)` — a synchronous blocking call that blocks the event loop for up to 120 seconds per MCP request. Identical to the bug in `langchain_hana_agent.py`. Fix: `asyncio.to_thread(urllib.request.urlopen, req, timeout=120)` or use `aiohttp`.

**(F-3) Import-time pip auto-install (4 sites).** `embedding_service.py:27`, `corrective_retriever.py:25`, `toolkit.py:31`, `toolkit.py:41` unconditionally run `subprocess.check_call([sys.executable, "-m", "pip", "install", ...])` at module import time. This: (a) mutates the deployment environment without user consent; (b) fails silently in read-only file systems (containers, k8s); (c) installs the `sap-ai-sdk-gen[all]` extras group unconditionally, pulling a large dependency tree. Fix: remove all auto-install calls; declare dependencies in `requirements.txt`; add clear `ImportError` messages with install instructions.

**(F-4) Non-deterministic audit hash.** `gen_ai_toolkit_agent.py:198`: `_log_audit` records `hash(prompt)` as `prompt_hash`. Python's `hash()` is `PYTHONHASHSEED`-randomised. Fix: `hashlib.sha256(prompt.encode()).hexdigest()`.

**(F-5) No MCP server authentication.** `mcp_server/server.py` has no authentication on the `/mcp` endpoint (port 9130). Any caller that can reach the port can invoke all tools, including `hana_chat` (acquires AI Core tokens, calls inference), `hana_vector_add` (delegates document indexing), and `hana_agent_run` (executes agent tasks). The `mangle://facts` resource exposes the service registry with endpoint URLs and tool invocation history.

**(F-6) No OpenAI server authentication.** `sap_openai_server/server.py` accepts any `api_key` value. See the equivalent finding in `langchain-integration-for-sap-hana-cloud`.

**(F-7) Unresolvable Mangle import.** `mangle/domain/agents.mg:7`: `include "../../../regulations/mangle/rules.mg"`. Path unresolvable in standalone checkout. Mangle engine compile failure prevents governance from initialising.

**(F-8) upsert_knowledge SQL syntax bug.** `hana_vector_engine.py:94`: the computed column DDL string is `f"REAL_VECTOR GENERATED ALWAYS AS VECTOR_EMBEDDING(\"description\", 'DOCUMENT', {self.model_version}"` — missing closing `)` and `model_version` is unquoted. Any call to `upsert_knowledge` will produce a SQL syntax error if the column definition is evaluated. Fix: close the parenthesis and quote the model version: `f"REAL_VECTOR GENERATED ALWAYS AS VECTOR_EMBEDDING(\"description\", 'DOCUMENT', '{self.model_version}')"`.

**(F-9) HANASemanticCache thread-safety.** No locking on `self._cache` or `self._embeddings`. Concurrent `get`/`set` calls from multiple threads produce data races. Fix: add `threading.RLock` guarding both structures.

**(F-10) FAISS deserialization risk.** `HANAMLRAGAgent._initialize_faiss_vectorstore` loads FAISS with `allow_dangerous_deserialization=True`. Pickle-based deserialization allows arbitrary code execution if the vectorstore file path is attacker-controlled. Fix: ensure the `vectorstore_path` is not user-supplied in production deployments; document this risk prominently.

**(F-11) Unconstrained dependency versions.** Six of nine `requirements.txt` entries have no version bounds. This makes reproducible builds impossible and creates silent breakage risk on any upstream release. Fix: pin all dependencies at tested versions in production deployments; use `pip-compile` or equivalent.

---

## 24. Licensing and Compliance

**Apache-2.0** (SPDX-FileCopyrightText: 2024 SAP SE). The `REUSE.toml` aggregate annotation covers all files. The same SAP External Products API disclaimer applies as in the sibling repositories.

**`hana-ml`** dependency (`>=2.27.26020601`) is the SAP HANA ML Python client, distributed under SAP's proprietary license terms for the `hdbcli` backend. The Apache-2.0 license of `hana_ai` does not extend to `hana-ml` or `hdbcli`.

**`sap-ai-sdk-gen[all]`** is the SAP Generative AI Hub SDK. Its license terms govern any API calls to SAP AI Hub / AI Core services.

**`langchain-community`** is MIT-licensed. `numpy` and `pandas` are BSD-3-Clause. `fastmcp` is MIT-licensed.

**`kuzu/`** vendored directory is Apache-2.0. Its 2 073 files are not individually annotated in `REUSE.toml`, creating a REUSE compliance gap.

**`pyproject.toml` `requires-python = ">=3.0"`** is misleading: the codebase requires ≥ 3.10. The declared minimum version should be corrected in the project metadata to prevent confusing installation errors on Python 3.0–3.9.

---

## 25. Pre-Production Items

Eleven items require resolution before production deployment:

**(1) SQL injection in HANAMLinVectorEngine.query (F-1, Critical).** Query text is interpolated directly into SQL. Fix: use parameterised queries for all user-supplied string inputs to `connection_context.sql`.

**(2) upsert_knowledge SQL syntax bug (F-8, High).** Missing `)` and unquoted `model_version` in computed column DDL causes SQL syntax errors on any call to `upsert_knowledge`. One-line fix.

**(3) Import-time pip auto-install (F-3, High).** Four `subprocess.check_call(pip install)` calls at module import time mutate the deployment environment without consent. Remove all four; add dependency declarations to `requirements.txt`; replace with clear `ImportError` messages.

**(4) Async/blocking mismatch in _call_mcp (F-2, High).** `GenAiToolkitAgent._call_mcp` blocks the event loop for up to 120 seconds. Replace `urllib.request.urlopen` with `asyncio.to_thread(urllib.request.urlopen, ...)` or `aiohttp`.

**(5) MCP server authentication (F-5, High).** Port 9130 accepts unauthenticated connections. JWT/XSUAA token validation, mTLS, or network-policy enforcement must be implemented before the server is reachable outside a trusted namespace.

**(6) OpenAI server authentication (F-6, High).** Port 8200 accepts any `api_key`. See equivalent item in `langchain-integration-for-sap-hana-cloud`.

**(7) Audit hash non-determinism (F-4, Medium).** Replace `hash(prompt)` with `hashlib.sha256(prompt.encode()).hexdigest()` in `_log_audit`. One-line fix; import `hashlib` at top of module.

**(8) Mangle import path (F-7, Medium).** `include "../../../regulations/mangle/rules.mg"` is unresolvable. Bundle the regulations rules or make the include conditional. Consistent with the same issue in all other assessed repositories — shared remediation appropriate.

**(9) HANASemanticCache thread-safety (F-9, Medium).** Add `threading.RLock` guarding `self._cache` and `self._embeddings` for multi-threaded use.

**(10) Unconstrained dependency versions (F-11, Medium).** Pin all six unconstrained `requirements.txt` entries to tested versions. Correct `requires-python` in `pyproject.toml` from `>=3.0` to `>=3.10`.

**(11) FAISS deserialization risk (F-10, Low/Contextual).** Document that `allow_dangerous_deserialization=True` carries pickle arbitrary-code-execution risk; ensure `vectorstore_path` is never user-controlled in production deployments.
