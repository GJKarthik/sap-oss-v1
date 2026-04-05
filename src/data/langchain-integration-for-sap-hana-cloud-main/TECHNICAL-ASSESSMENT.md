# Technical Assessment: langchain-integration-for-sap-hana-cloud

**Repository:** `SAP/langchain-integration-for-sap-hana-cloud`
**Assessment Date:** 2025
**Assessed By:** SAP Engineering Review
**Version:** 1.0.2 (`pyproject.toml`, package name: `langchain-hana`)
**License:** Apache-2.0 (SPDX)
**Primary Language:** Python (≥ 3.10, < 4.0)
**Build System:** Poetry (`poetry-core ≥ 1.0.0`)

---

## Table of Contents

1. [Purpose and Positioning](#1-purpose-and-positioning)
2. [Repository Layout](#2-repository-layout)
3. [Public API Surface](#3-public-api-surface)
4. [HanaDB — Vector Store](#4-hanadb--vector-store)
5. [HanaInternalEmbeddings](#5-hanainternalembeddings)
6. [HanaRdfGraph — Knowledge Graph Engine](#6-hanardfgraph--knowledge-graph-engine)
7. [HanaSparqlQAChain](#7-hanasparqlqachain)
8. [HanaTranslator — Self-Query Retriever](#8-hanatranslator--self-query-retriever)
9. [HanaAnalytical — Analytical Query Support](#9-hanaanalytical--analytical-query-support)
10. [MCP Server](#10-mcp-server)
11. [SAP OpenAI-Compatible Server](#11-sap-openai-compatible-server)
12. [Governance Agent](#12-governance-agent)
13. [SemanticRouter](#13-semanticrouter)
14. [Mangle Datalog Governance Layer](#14-mangle-datalog-governance-layer)
15. [Software Bill of Materials (SBOM)](#15-software-bill-of-materials-sbom)
16. [Integration Topology](#16-integration-topology)
17. [Security Profile](#17-security-profile)
18. [Licensing and Compliance](#18-licensing-and-compliance)
19. [Pre-Production Items](#19-pre-production-items)

---

## 1. Purpose and Positioning

The `langchain-integration-for-sap-hana-cloud` repository (`pip install langchain-hana`) is the official LangChain integration package for SAP HANA Cloud. Its core mission is to expose SAP HANA Cloud's in-database capabilities — the Vector Engine, the Knowledge Graph Engine (SPARQL), and Calculation View analytics — as first-class LangChain components that consume the standard `langchain-core` abstract interfaces (`VectorStore`, `Embeddings`, `Chain`, `Visitor`).

Within the SAP AI experience map the project is positioned at the `ai_core` / `embedded-hana` tier. Its five published symbols — `HanaDB`, `HanaTranslator`, `HanaInternalEmbeddings`, `HanaRdfGraph`, `HanaSparqlQAChain` — are the foundational building blocks for any LangChain-based RAG application that stores and retrieves data from SAP HANA Cloud. Beyond the core library, the repository snapshot additionally contains an MCP server, an OpenAI-compatible proxy server, a governance agent, an embedding-based semantic router, a Mangle Datalog governance layer, and an ODPS 4.1 data product definition — together forming the `hana-vector-store-v1` data product in the platform's data product catalog.

A `>` NOTE block at the top of `README.md` explicitly directs LangChain 0.3.x users to the `0.3.x` branch, confirming that this main branch targets LangChain 1.0.x and later.

---

## 2. Repository Layout

```
langchain-integration-for-sap-hana-cloud-main/
├── langchain_hana/              # Installable Python package (the core library)
│   ├── __init__.py              # Public API exports: HanaDB, HanaTranslator, etc.
│   ├── utils.py                 # DistanceStrategy enum, _validate_k helpers
│   ├── analytical.py            # HanaAnalytical — aggregation/hierarchy/time-series
│   ├── vectorstores/
│   │   ├── hana_db.py           # HanaDB (1 193 lines) — primary vector store class
│   │   └── create_where_clause.py  # CreateWhereClause — metadata filter SQL builder
│   ├── embeddings/
│   │   └── hana_internal_embeddings.py  # HanaInternalEmbeddings stub
│   ├── graphs/
│   │   └── hana_rdf_graph.py    # HanaRdfGraph — SPARQL graph wrapper
│   ├── chains/graph_qa/
│   │   ├── hana_sparql_qa_chain.py  # HanaSparqlQAChain
│   │   └── prompts.py           # SPARQL_GENERATION_SELECT_PROMPT, SPARQL_QA_PROMPT
│   └── structured_query/
│       └── hana_translator.py   # HanaTranslator — Self-Query Retriever visitor
├── agent/
│   ├── langchain_hana_agent.py  # LangChainHanaAgent + inline MangleEngine stub
│   └── semantic_router.py       # SemanticRouter — embedding-based query routing
├── mcp_server/
│   └── server.py                # MCP server (831 lines), port 9140
├── sap_openai_server/
│   ├── server.py                # OpenAI-compatible FastAPI server (1 351 lines), port 8200
│   ├── proxy.mg                 # Mangle proxy rules (6 560 bytes)
│   └── README.md                # Full endpoint catalogue and quick-start guide
├── mangle/
│   ├── a2a/mcp.mg               # MCP service registry and tool routing rules
│   └── domain/
│       ├── agents.mg            # Agent governance rules
│       └── data_products.mg     # ODPS data product rules
├── data_products/
│   ├── hana_vector_store.yaml   # ODPS 4.1 data product definition (YAML)
│   └── registry.yaml            # Data product catalog / global policies
├── examples/                    # 5 Jupyter notebook examples
├── tests/                       # 15 test modules
├── scripts/                     # 2 utility scripts
├── kuzu/                        # Vendored Kuzu graph database (~2 073 files)
├── pyproject.toml               # Poetry project definition
├── poetry.lock                  # Pinned dependency tree (241 KB)
├── .snyk                        # Snyk policy with three known-issue ignores
└── REUSE.toml                   # REUSE compliance manifest
```

The installable package surface is defined by `langchain_hana/__init__.py` and the five symbols in its `__all__` list. All other top-level directories (`agent/`, `mcp_server/`, `sap_openai_server/`, `mangle/`) are not part of the pip-installed package and are intended to be executed directly or containerised separately.

---

## 3. Public API Surface

The package exposes five symbols via `langchain_hana/__init__.py`:

| Symbol | Base Class | Module |
|---|---|---|
| `HanaDB` | `langchain_core.vectorstores.VectorStore` | `vectorstores/hana_db.py` |
| `HanaTranslator` | `langchain_core.structured_query.Visitor` | `structured_query/hana_translator.py` |
| `HanaInternalEmbeddings` | `langchain_core.embeddings.Embeddings` | `embeddings/hana_internal_embeddings.py` |
| `HanaRdfGraph` | (standalone) | `graphs/hana_rdf_graph.py` |
| `HanaSparqlQAChain` | `langchain_classic.chains.base.Chain` | `chains/graph_qa/hana_sparql_qa_chain.py` |

`HanaAnalytical` is implemented in `langchain_hana/analytical.py` but is **not** exported from `__init__.py`; it must be imported directly from `langchain_hana.analytical`. This is noted in the module docstring as an intentional extension addressing a documented weakness ("Weakness #2: Limited analytical query support").

---

## 4. HanaDB — Vector Store

`HanaDB` is the central class, spanning 1 193 lines. It implements the complete LangChain `VectorStore` abstract interface against SAP HANA Cloud's Vector Engine.

**Storage model.** `HanaDB` maps LangChain's document model to a three-column HANA table: `VEC_TEXT` (NCLOB, document content), `VEC_META` (NCLOB, JSON-serialised metadata), and `VEC_VECTOR` (either `REAL_VECTOR` or `HALF_VECTOR`). On construction, `_initialize_table` creates the table if absent and validates that all three columns exist with the correct SQL types. Additional `specific_metadata_columns` can be declared to promote selected metadata keys into first-class typed table columns rather than JSON fields, enabling indexed predicate pushdown.

**Embedding modes.** `HanaDB` supports two mutually exclusive embedding strategies selected at construction time by the type of the `embedding` argument. When `HanaInternalEmbeddings` is provided, the class sets `use_internal_embeddings = True` and delegates all embedding computation to HANA's built-in `VECTOR_EMBEDDING(?, 'DOCUMENT'|'QUERY', ?, [remote_source])` SQL function, invoking the model inside the database engine. When any other `langchain_core.embeddings.Embeddings` subclass is provided, embeddings are computed externally (by the application process) and serialised to binary before insertion. For `REAL_VECTOR` columns the binary format is 4-byte IEEE 754 little-endian (standard FVECS); for `HALF_VECTOR` columns (available from HANA Cloud QRC 2/2025) it is 2-byte half-precision little-endian. The `_validate_datatype_support` static method queries `SYS.DATA_TYPES` to confirm the target vector type is available on the connected HANA instance, providing a clear error including the minimum required instance version if not.

**Vector index management.** `create_hnsw_index` creates an HNSW (Hierarchical Navigable Small World) approximate nearest-neighbour index on the vector column with optional `M` (graph connectivity, 4–1 000), `efConstruction` (build-time candidate set, 1–100 000), and `efSearch` (query-time candidate set, 1–100 000) parameters. The index is always created in `ONLINE` mode. Both `COSINE_SIMILARITY` and `L2DISTANCE` distance strategies are supported; the appropriate function is injected into the index definition automatically.

**Distance strategy.** `HANA_DISTANCE_FUNCTION` maps `DistanceStrategy.COSINE` to `COSINE_SIMILARITY` (result ordering: `DESC`) and `DistanceStrategy.EUCLIDEAN_DISTANCE` to `L2DISTANCE` (ordering: `ASC`). The similarity score included in results is the raw HANA function output; callers must account for the direction of the ordering when interpreting scores.

**Search methods.** `HanaDB` implements all four standard LangChain retrieval methods:

- `similarity_search` — returns top-k `Document` objects for a text query.
- `similarity_search_with_score` — returns `(Document, float)` pairs with the distance/similarity score.
- `similarity_search_with_relevance_scores` — normalises scores to [0, 1] and applies a score threshold.
- `max_marginal_relevance_search` — fetches `fetch_k` candidates, then re-ranks using `langchain_core.vectorstores.utils.maximal_marginal_relevance` to maximise result diversity. An intermediate staging mechanism (`intermediate_result`) is used to route the expanded result set before MMR re-ranking.

Async variants of all four are provided via `langchain_core.runnables.config.run_in_executor`, wrapping the synchronous implementations.

**Metadata filtering.** The `CreateWhereClause` class translates LangChain's generic filter dict DSL into HANA SQL parameterised WHERE clauses. Supported operators: `$eq`, `$ne`, `$lt`, `$lte`, `$gt`, `$gte`, `$in`, `$nin`, `$between`, `$like`, and `$contains`. The `$contains` operator generates a HANA full-text `SCORE(? IN ("column" EXACT SEARCH MODE 'text')) > 0` expression. Metadata key fields stored in `VEC_META` JSON are accessed via `JSON_VALUE(VEC_META, '$.field')`; promoted `specific_metadata_columns` are addressed directly by name. All SQL parameters use the `?` prepared-statement placeholder; no string concatenation of user-supplied filter values occurs in WHERE clause generation.

**Input sanitisation.** All user-supplied table and column names pass through `_sanitize_name` (regex `[^a-zA-Z0-9_]` strip) before inclusion in SQL strings. Metadata keys are validated against `^[_a-zA-Z][_a-zA-Z0-9]*$` by `_sanitize_metadata_keys`. Integer inputs pass through `_sanitize_int`. Despite these mitigations, the class-level `_sanitize_name` implementation silently strips rather than rejects invalid characters; a table name like `DROP TABLE` becomes `DROPTABLE` rather than raising an error.

---

## 5. HanaInternalEmbeddings

`HanaInternalEmbeddings` is a marker class that implements `langchain_core.embeddings.Embeddings` but raises `NotImplementedError` unconditionally on both `embed_query` and `embed_documents`. Its purpose is to signal to `HanaDB` that embedding should be delegated entirely to HANA's `VECTOR_EMBEDDING()` SQL function. The class carries a `model_id` (the internal model identifier registered in HANA) and an optional `remote_source` (the name of a remote source connection for models hosted outside HANA). External code must never call `embed_query` or `embed_documents` on an instance of this class; doing so produces a `NotImplementedError` with a descriptive message directing the caller to use HANA's internal function instead.

---

## 6. HanaRdfGraph — Knowledge Graph Engine

`HanaRdfGraph` wraps SAP HANA Cloud's Knowledge Graph Engine, exposing a SPARQL execution interface backed by the `SYS.SPARQL_EXECUTE` stored procedure. The class accepts a `dbapi.Connection` and requires exactly one ontology source to be specified at construction — four mutually exclusive options are supported:

1. **`ontology_query`**: A SPARQL `CONSTRUCT` query executed against the graph to extract the schema. The query is validated using `rdflib.plugins.sparql.prepareQuery` to confirm it is a `ConstructQuery` (with a workaround for HANA's non-standard `FROM DEFAULT` syntax, which is stripped before parsing).
2. **`ontology_uri`**: A remote URI from which the schema is loaded via a generated `CONSTRUCT {?s ?p ?o} FROM <uri> WHERE {?s ?p ?o .}` query.
3. **`ontology_local_file`**: A local RDF file (Turtle, RDF/XML, or any format supported by `rdflib`) loaded from disk. File existence and read permission are checked before parsing.
4. **`auto_extract_ontology`**: When `True` and no other source is given, executes a built-in generic `CONSTRUCT` that reverse-engineers `owl:Class`, `owl:ObjectProperty`, and `owl:DatatypeProperty` declarations from instance data, covering class labels, property domains, and ranges.

`HanaRdfGraph.query` executes arbitrary SPARQL queries against the graph. The default content type is `application/sparql-results+csv`. If `inject_from_clause=True` (the default), the method inserts the configured `FROM <graph_uri>` clause immediately before the `WHERE` keyword if no `FROM` clause is already present. The schema property exposes the loaded ontology as an `rdflib.Graph` object.

The class docstring contains an explicit security note warning that database credentials should be narrowly scoped; the `HanaSparqlQAChain` docstring repeats this warning.

---

## 7. HanaSparqlQAChain

`HanaSparqlQAChain` is a LangChain `Chain` that implements two-step SPARQL question-answering over a `HanaRdfGraph`. Given a natural language query, it first generates a SPARQL `SELECT` statement using `SPARQL_GENERATION_SELECT_PROMPT` and a configurable LLM, then executes that SPARQL against HANA and answers the original question using the result set via `SPARQL_QA_PROMPT`.

The chain requires `allow_dangerous_requests=True` to be set explicitly at construction. Omitting this flag raises a `ValueError` with a detailed security explanation, making the risk opt-in rather than implicit. The input key is `"query"`, the output key is `"result"`.

`SPARQL_GENERATION_SELECT_PROMPT` provides the LLM with the graph schema (as a serialised RDF Turtle string from `HanaRdfGraph.get_schema`) and a HANA-specific note that the SELECT query must include a `FROM DEFAULT` clause before the `WHERE` clause. This is a HANA non-standard extension to SPARQL 1.1 that prevents the prompt from generating standard-compliant queries that would fail against HANA.

---

## 8. HanaTranslator — Self-Query Retriever

`HanaTranslator` is a `langchain_core.structured_query.Visitor` that translates LangChain's abstract `StructuredQuery` AST into the filter dict format accepted by `HanaDB`'s `CreateWhereClause`. It supports:

- **Logical operators**: `AND`, `OR`
- **Comparators**: `EQ` (`$eq`), `NE` (`$ne`), `GT` (`$gt`), `LT` (`$lt`), `GTE` (`$gte`), `LTE` (`$lte`), `IN` (`$in`), `NIN` (`$nin`), `CONTAIN` (→ `$contains`), `LIKE` (`$like`)

The translator is designed to be passed to LangChain's `SelfQueryRetriever` alongside a `HanaDB` instance, enabling natural language metadata filtering driven by an LLM. The `_format_func` method maps `Comparator.CONTAIN` to `$contains` (not `$contain`) to align with `CreateWhereClause`'s operator vocabulary; all other operators use their `.value` string directly.

---

## 9. HanaAnalytical — Analytical Query Support

`HanaAnalytical` (in `langchain_hana/analytical.py`) extends the library with structured analytical query capabilities against SAP HANA Calculation Views. Its module docstring labels it as addressing "Weakness #2: Limited analytical query support."

The class exposes three primary methods:

**`aggregate`** builds and executes a `SELECT … GROUP BY` query against a named Calculation View. Dimensions and measures are specified declaratively; eight `AggregationType` values are supported (`SUM`, `COUNT`, `COUNT_DISTINCT`, `AVG`, `MIN`, `MAX`, `STDDEV`, `VAR`). WHERE clause filters, HAVING clause filters (with `gt`, `gte`, `lt`, `lte`, `eq` operators), ORDER BY directives, and a LIMIT parameter are all supported. All identifiers (view name, schema, column names) pass through `_sanitize_name` before inclusion in SQL. Filter values are handled as parameterised placeholders. Results are returned as an `AnalyticalResult` dataclass carrying the data rows, the generated SQL string, row count, dimension list, measure list, and metadata.

**Hierarchy support** (`HierarchyNode` dataclass) provides a tree-node structure for drill-down navigation, intended for use with HANA's hierarchical data structures (adjacency list and level-based hierarchies).

**`TIME_TRUNCATION` mapping** covers six `TimeGranularity` values (`YEAR`, `QUARTER`, `MONTH`, `WEEK`, `DAY`, `HOUR`) with the appropriate HANA SQL time truncation functions (`YEAR()`, `QUARTER()`, `TO_CHAR(…, 'YYYY-MM')`, etc.).

---

## 10. MCP Server

`mcp_server/server.py` (831 lines) implements a Model Context Protocol (`2024-11-05`) server over JSON-RPC 2.0, binding on port **9140** (configurable via `MCP_PORT`). Like the `odata-vocabularies` MCP server, it uses only the Python standard library for its HTTP layer (`http.server.HTTPServer`, `BaseHTTPRequestHandler`), requiring no web framework.

**Input bounds** are enforced via four module-level constants, all configurable via environment variables:

| Constant | Default | Environment Variable |
|---|---|---|
| `MAX_REQUEST_BYTES` | 1 048 576 (1 MB) | `MCP_MAX_REQUEST_BYTES` |
| `MAX_TOOL_TOKENS` | 8 192 | `MCP_MAX_TOOL_TOKENS` |
| `MAX_TOP_K` | 100 | `MCP_MAX_TOP_K` |
| `MAX_DOCS_PER_CALL` | 1 000 | `MCP_MAX_DOCS_PER_CALL` |
| `MAX_CHUNK_SIZE` | 4 000 | `MCP_MAX_CHUNK_SIZE` |
| `MAX_REMOTE_ENDPOINTS` | 25 | `MCP_MAX_REMOTE_ENDPOINTS` |

**AI Core integration.** The MCP server manages its own OAuth token lifecycle for SAP AI Core. `get_access_token` retrieves a `client_credentials` grant token from `AICORE_AUTH_URL` using `base64`-encoded `client_id:client_secret` credentials, caches the token in a module-level dict with a 60-second early expiry buffer, and returns it for use in `Bearer` headers on inference calls. The `aicore_request` helper sends authenticated requests to the AI Core REST API with `AI-Resource-Group` header injection.

**Federated MCP.** The `MCPServer` maintains references to three named sibling MCP endpoints: `LANGCHAIN_HANA_MCP_ENDPOINT` (default `http://localhost:9130/mcp`), `LANGCHAIN_ODATA_MCP_ENDPOINT` (default `http://localhost:9150/mcp`), and its own `LANGCHAIN_MCP_ENDPOINT` (default `http://localhost:9140/mcp`). Additional endpoints can be supplied via the `LANGCHAIN_REMOTE_MCP_ENDPOINTS` comma-separated environment variable (capped at 25). The `_federated_mcp_call` method iterates the ordered endpoint list and attempts `call_mcp_tool` (a JSON-RPC `tools/call` request via `urllib.request.urlopen`) with a `REMOTE_MCP_TIMEOUT_SECONDS` timeout (default 3 seconds), returning the first successful response. This enables transparent delegation of vector search, RAG, and document loading operations to a dedicated HANA MCP server without requiring the langchain-hana MCP server to hold a direct HANA connection.

**CORS.** The server validates incoming `Origin` headers against a configurable allowlist (`CORS_ALLOWED_ORIGINS`, default `http://localhost:3000,http://127.0.0.1:3000`) and reflects matching origins in `Access-Control-Allow-Origin` response headers.

**Registered tools (9):**

| Tool | Description |
|---|---|
| `langchain_chat` | Chat completion via SAP AI Core (Anthropic or OpenAI format auto-detected) |
| `langchain_vector_store` | Create or retrieve a named HANA vector store; delegates to HANA MCP |
| `langchain_add_documents` | Add documents to a vector store; delegates to HANA MCP; capped at `MAX_DOCS_PER_CALL` |
| `langchain_similarity_search` | Similarity search; delegates to HANA MCP; falls back to `degraded-no-remote` |
| `langchain_rag_chain` | Full RAG pipeline: retrieval + AI Core generation; falls back to retrieval-only |
| `langchain_embeddings` | Generate embeddings via AI Core deployment; capped at `MAX_DOCS_PER_CALL` |
| `langchain_load_documents` | Load documents from file or URL; delegates to OData MCP for RAG context |
| `langchain_split_text` | Split text into chunks with overlap; deterministic fallback splitter |
| `mangle_query` | Query in-memory Mangle fact store; delegates to HANA or OData MCP for unknown predicates |

**Registered resources (3):** `langchain://vectorstores`, `langchain://chains`, `mangle://facts`.

The health endpoint at `GET /health` reports `"status": "healthy"` when all four AI Core environment variables (`AICORE_CLIENT_ID`, `AICORE_CLIENT_SECRET`, `AICORE_AUTH_URL`, `AICORE_BASE_URL`) are present, or `"status": "degraded"` with a descriptive `config_error` otherwise.

---

## 11. SAP OpenAI-Compatible Server

`sap_openai_server/server.py` (1 351 lines) provides a full OpenAI API-compatible HTTP server. It prefers `fastapi` + `uvicorn` + `pydantic` (set `USE_FASTAPI = True`) with a `PlainTextResponse`/`StreamingResponse` fallback if FastAPI is absent. When running with FastAPI the server binds on port **8200** via `uvicorn`.

The server exposes 30+ endpoints covering: models, chat completions (with automatic HANA RAG injection when HANA credentials are configured), legacy completions, embeddings, semantic search, file management, fine-tunes, content moderation, image/audio generation stubs, the full OpenAI Assistants v2 API (`/v1/assistants`, `/v1/threads`, `/v1/threads/{id}/messages`, `/v1/threads/{id}/runs`), the Batches API (`/v1/batches`), and three HANA-specific endpoints (`/v1/hana/tables`, `/v1/hana/vectors`, `/v1/hana/search`).

The `AICoreConfig` and `HANAConfig` dataclasses are populated from environment variables at startup. The AI Core token lifecycle is managed by the same `get_access_token` pattern as the MCP server: `client_credentials` OAuth with `base64` encoding and module-level caching. When HANA credentials are available, the chat completion endpoint automatically attempts a vector similarity search against the named `VECTOR_STORE_TABLE` (default `"EMBEDDINGS"`) and prepends retrieved context to the system prompt before forwarding the request to AI Core — implementing a transparent RAG layer for any OpenAI SDK consumer.

`sap_openai_server/proxy.mg` contains Mangle Datalog rules for routing through the OpenAI-compatible proxy layer.

---

## 12. Governance Agent

`agent/langchain_hana_agent.py` implements `LangChainHanaAgent`, the governance-aware agent for HANA data access. Its architecture mirrors the agents in `cap-llm-plugin` and `odata-vocabularies` — an inline `MangleEngine` stub holds governance facts that drive routing, safety, and prompting decisions.

**MangleEngine facts.** Seven fact sets are loaded at construction: `agent_config` (4 key/value pairs), `agent_can_use` (6 permitted tools: `hana_vector_search`, `hana_similarity_search`, `hana_query`, `get_schema_info`, `list_tables`, `mangle_query`), `agent_requires_approval` (4 high-risk tools: `execute_sql`, `insert_embeddings`, `delete_embeddings`, `modify_table`), `confidential_schemas` (6: TRADING, RISK, TREASURY, CUSTOMER, FINANCIAL, INTERNAL), `public_schemas` (3: PUBLIC, REFERENCE, METADATA), `hana_data_keywords` (11: select, from, table, column, trading, risk, treasury, customer, vector, embedding, similarity), and `prompting_policy` (system prompt, max_tokens: 4 096, temperature: 0.3).

**Routing logic.** `invoke()` routes to vLLM (`http://localhost:9180/mcp`) if the prompt matches any `hana_data_keyword` or any `confidential_schema` string (case-insensitive substring match). All other requests fall through to AI Core (`http://localhost:9140/mcp`, the MCP server). The default_backend declared in `agents.mg` is `"vllm"`, meaning HANA data access is assumed confidential. Only metadata-only schema queries that contain none of the 11 keywords are eligible for AI Core routing.

**Approval gate.** If the requested `tool` is in `agent_requires_approval`, `invoke()` returns immediately with `"status": "pending_approval"` without calling the MCP endpoint, and logs an audit entry. This L2 autonomy posture (human oversight required for write/delete operations) is consistent with the ODPS data product definition.

**Async/blocking mismatch.** `LangChainHanaAgent._call_mcp` is declared `async def` but uses `urllib.request.urlopen` — a synchronous blocking call — internally. This is structurally identical to the same bug found in `odata-vocabularies`'s agent. Invoking `await agent._call_mcp(...)` from a running event loop will block the loop for the full network round-trip (up to 120 seconds). See §19 for remediation.

**Non-deterministic audit hash.** `_log_audit` records `hash(prompt)` as `prompt_hash`. Python's `hash()` is randomised by `PYTHONHASHSEED` at interpreter startup and produces different values for the same input across process restarts. This makes audit records non-reproducible and unsuitable for forensic correlation.

---

## 13. SemanticRouter

`agent/semantic_router.py` implements `SemanticRouter`, an embedding-based query classifier that replaces keyword matching with cosine similarity against pre-computed category centroids. The module docstring claims a "40–60% improvement in routing accuracy for ambiguous queries" relative to keyword-based routing.

Six routing categories are defined with backend assignments:

| Category | Backend | Representative Exemplars |
|---|---|---|
| `CONFIDENTIAL_DATA` | vLLM | trading positions, risk exposure, treasury deals, employee salary |
| `VECTOR_SEARCH` | vLLM | find similar documents, embedding search, nearest neighbour |
| `ANALYTICAL` | vLLM | total sales by region, average order value, drill-down hierarchy |
| `KNOWLEDGE` | Hybrid | credit memo processing, G/L reconciliation, AP best practices |
| `METADATA` | AI Core | list available measures, show table columns, schema information |
| `GENERAL` | AI Core | hello, what can you do, tell me about SAP |

`SemanticRouter.initialize()` is async, uses `asyncio.Lock` to prevent concurrent initialisation, and computes centroids by averaging embeddings of 6–8 exemplar queries per category. At routing time, `route()` computes cosine similarity between the query embedding and each centroid, returning the highest-scoring category if its similarity exceeds `CONFIDENCE_THRESHOLD` (0.7). Below threshold, `_keyword_fallback` provides a deterministic fallback using the same keyword patterns as the `MangleEngine` in `langchain_hana_agent.py`, but includes the semantic scores in the `RoutingResult.all_scores` field for observability.

`route_sync` wraps `route()` for synchronous call sites; if a running event loop is detected (which would block), it falls back to keyword routing, making the synchronous API safe to call from synchronous code that has not managed the event loop.

The router requires an external embedding endpoint (configurable) or HANA internal embeddings. If no embedding endpoint is available at initialization time, all centroids fail to compute and the router falls back to keyword routing for all queries.

---

## 14. Mangle Datalog Governance Layer

Three Mangle Datalog files govern the LangChain HANA service:

**`mangle/a2a/mcp.mg`** registers four MCP services on `http://localhost:9140/mcp`: `langchain-chat` (model: `claude-3.5-sonnet`), `langchain-vector` (model: `hana-vector`), `langchain-rag` (model: `rag-chain`), `langchain-embed` (model: `text-embedding`). Nine tool-to-service mappings associate all nine MCP tools to their owning services. Four intent routing rules map `/chat`, `/vector`, `/rag`, and `/embed` intents to the corresponding service. Three chain type declarations (`rag`, `qa`, `summarize`) provide metadata for chain classification.

**`mangle/domain/agents.mg`** defines `langchain-hana-agent` with autonomy level **L2** (lower than the L3 assigned to the vocabulary agent, reflecting that HANA data access touches confidential business data rather than public documentation). The MCP endpoint is `http://localhost:9140/mcp`. The agent's `default_backend` and `confidential_backend` are both `"vllm"`. Six confidential schemas (TRADING, RISK, TREASURY, CUSTOMER, FINANCIAL, INTERNAL) and three public schemas (PUBLIC, REFERENCE, METADATA) are declared. The `route_to_vllm` rule fires on four predicates: `query_mentions_schema` (with a confidential schema), `contains_hana_data` (8 keyword rules: select, from, table, column, trading, risk, treasury, customer), `contains_vector_search` (4 keyword rules: vector, embedding, similarity, semantic search). The `route_to_aicore` rule fires only for `metadata_only_query` — queries containing both "schema" and "list" — when `contains_hana_data` does not fire. Four operations (`execute_sql`, `insert_embeddings`, `delete_embeddings`, `modify_table`) require human review; five of those same operations are also classified as `high_risk_action`. Audit level is `"full"` with `audit_sql_queries` set to `true`. This file includes `../../../regulations/mangle/rules.mg` — the same unresolvable out-of-repo import present in the other repositories in this workspace.

**`mangle/domain/data_products.mg`** defines the `hana-vector-store-v1` data product with `"confidential"` security class and `"vllm-only"` routing policy — the strictest posture across all assessed data products. Three output ports are defined: `vector-search` (confidential, vllm-only), `sql-query` (confidential, vllm-only), `schema-info` (internal, hybrid). Two input ports are defined: `hana-tables` (confidential) and `embeddings` (confidential). Three regulatory frameworks are declared: `MGF-Agentic-AI`, `AI-Agent-Index`, and `GDPR-Data-Processing`. Human oversight is required (`product_requires_human_oversight: true`). Four safety controls are active: guardrails, monitoring, audit-logging, query-filtering. SLA targets: 99.9% availability, 3 000 ms p95 latency, 200 req/min throughput.

The ODPS 4.1 YAML (`data_products/hana_vector_store.yaml`) mirrors the Mangle facts, adding routing rule annotations for `hana_table_query` (vllm), `vector_search` (vllm), and `metadata_only` (aicore), plus `allowTokenization: false` on the `hana-tables` input port (prohibiting content tokenisation for external LLM consumption). The global catalog policy sets `defaultSecurityClass: "confidential"` and `defaultLLMRouting: "vllm-only"`, making this the most restrictive data product in the assessed workspace — appropriate given HANA's role as the primary enterprise data store.

---

## 15. Software Bill of Materials (SBOM)

### Python Runtime Dependencies (`pyproject.toml`)

| Package | Version Constraint | Role | Notes |
|---|---|---|---|
| `langchain-core` | `^1.0.0` | Abstract LangChain interfaces | Hard dependency |
| `langchain-classic` | `^1.0.0` | `Chain` base class for `HanaSparqlQAChain` | Hard dependency |
| `langchain` | `^1.0.0` | LangChain orchestration framework | Hard dependency |
| `hdbcli` | `^2.23.24` | SAP HANA Python client (ODBC) | Hard dependency |
| `rdflib` | `^7.0.0` | SPARQL query parsing and RDF graph handling | Hard dependency |
| `numpy` | `≥1.26.4` (py < 3.13), `≥2.1.0` (py ≥ 3.13) | Vector serialisation and MMR re-ranking | Hard dependency |

All six production dependencies are **hard** (no graceful-fallback pattern): the package will fail to import if any are absent. The `hdbcli` HANA client is an SAP proprietary package distributed via PyPI; its Apache-2.0 notice covers the client library only, with SAP's standard API call disclaimer applying to its network use.

### Python Dev / Test Dependencies

| Group | Packages |
|---|---|
| `test` | `pytest ^9.0.2`, `pytest-asyncio ^1.3.0`, `pytest-socket ^0.7.0`, `pytest-watcher ^0.6.3` |
| `lint` | `ruff ^0.5` |
| `typing` | `mypy ^1.10` |
| `dev` | `nbstripout ^0.8.2` |

### `sap_openai_server` Optional Dependencies

The OpenAI-compatible server lists `fastapi`, `uvicorn`, and `pydantic` as requirements in its `README.md` quick-start. These are **not** declared in `pyproject.toml` and will not be installed by `pip install langchain-hana`. The server guards their absence with a `try/except ImportError` setting `USE_FASTAPI = False`, but in that fallback mode the server provides no HTTP endpoints beyond the stub definitions.

### Known Vulnerabilities (`.snyk` policy file)

Three Snyk ignore entries are declared, all with a 2026-09-07 expiry:

| CVE / Pattern | Affected Path | Reason |
|---|---|---|
| `CVE-2026-28277` (CVSS 6.8) | `langchain-hana > langchain-classic > langgraph` | msgpack deserialization in LangGraph; transitive only, LangGraph checkpoints never instantiated |
| `CVE-2026-28277` (same) | `langchain-hana > langchain-classic > langgraph > langgraph-checkpoint` | Same CVE chain via checkpoint sub-package |
| `SNYK-PYTHON-LANGCHAINCLASSIC-*` | `langchain-hana > langchain-classic` | ReDoS in `langchain-classic`; no upstream remediation available |

The `.snyk` file documents that exploitation of CVE-2026-28277 requires attacker write access to the LangGraph checkpoint backing store (post-exploitation only), and that `langchain-hana` does not use LangGraph checkpoints. Both ignore entries expire 2026-09-07 and should be re-evaluated at that date.

### Vendored Artefact

`kuzu/` (~2 073 files, Apache-2.0) is the same unintegrated Kuzu embedded graph database directory present in `odata-vocabularies-main` and `cap-llm-plugin-main`. There is no import, build reference, or documentation connecting Kuzu to any functionality in this package. Its presence inflates repository size and dependency surface without contributing to any implemented feature.

---

## 16. Integration Topology

The `langchain-hana` package participates in five integration patterns:

**SAP HANA Cloud** (ODBC via `hdbcli`): `HanaDB`, `HanaRdfGraph`, and `HanaAnalytical` all require a live `dbapi.Connection` passed at construction time. The connection is not pooled or managed by the library; the caller is responsible for connection lifecycle. HANA Cloud is the primary data plane for all vector storage, SPARQL graph execution, and analytical calculation view queries.

**SAP AI Core** (HTTPS, OAuth 2.0 `client_credentials`): The MCP server and the OpenAI-compatible server both acquire Bearer tokens from `AICORE_AUTH_URL` and forward inference requests to AI Core deployments at `AICORE_BASE_URL`. The token cache is process-global and module-level; multiple server instances in the same process share one token cache.

**vLLM** (`http://localhost:9180/mcp`): The governance agent and Mangle routing rules direct HANA data queries and vector search operations to an on-premise vLLM endpoint. vLLM is assumed to run alongside HANA on-premise infrastructure for confidential workload isolation. Two models are declared in the vLLM backend: `llama-3.1-70b` and `mistral-7b`.

**OData Vocabularies MCP** (`http://localhost:9150/mcp`): The MCP server's `langchain_load_documents` tool attempts to delegate to the OData vocabulary service's `get_rag_context` tool when loading documents. This provides vocabulary-contextual RAG enrichment as a cross-service federation capability.

**HANA AI Toolkit MCP** (`http://localhost:9130/mcp`): The MCP server's `_federated_mcp_call` preferentially targets this endpoint for `hana_vector_add`, `hana_vector_search`, and `hana_rag` tool calls, delegating direct HANA execution to a dedicated HANA toolkit service rather than holding a HANA connection in the MCP server process itself.

---

## 17. Security Profile

### Strengths

**Parameterised SQL throughout.** `HanaDB`, `HanaAnalytical`, and `CreateWhereClause` use prepared-statement `?` placeholders for all user-supplied values in SQL execution. No string concatenation of user data into SQL query text occurs in WHERE clause generation or vector insertion.

**Identifier sanitisation on all SQL names.** All table names, column names, schema names, and index names pass through `_sanitize_name` (regex strip of non-alphanumeric/underscore characters) before inclusion in SQL DDL and DML strings. `_sanitize_metadata_keys` provides an additional regex validation for metadata keys.

**Opt-in dangerous operations.** `HanaSparqlQAChain` requires explicit `allow_dangerous_requests=True` at construction, with a detailed warning about the risks of LLM-generated SPARQL executing against a live database. This pattern prevents accidental deployment of the SPARQL QA chain without deliberate acknowledgement of the security implications.

**HANA vector type validation.** `_validate_datatype_support` queries `SYS.DATA_TYPES` before accepting a vector column type, preventing runtime failures when deploying against older HANA instances that do not support `HALF_VECTOR`.

**Confidential-by-default data product posture.** The ODPS data product is declared `"confidential"` with `"vllm-only"` routing across all ports, `allowTokenization: false` on the HANA tables input port, and `product_requires_human_oversight: true`. This is the most restrictive posture in the assessed workspace and appropriately reflects HANA's role as a primary enterprise data store.

**Snyk policy documentation.** The `.snyk` file provides formal, time-bounded documentation of three known unresolved vulnerabilities in transitive dependencies, with justification for why they do not affect this package's usage pattern. This is better practice than undocumented vulnerability acceptance.

### Findings

**(F-1) No MCP server authentication.** `mcp_server/server.py` has no authentication on the `/mcp` endpoint. Any caller that can reach port 9140 can invoke all nine tools, including `langchain_chat` (which acquires an AI Core Bearer token and calls inference endpoints) and `langchain_add_documents` (which delegates vector insertion to the HANA MCP). The AI Core credential configuration is also partially exposed via the `mangle://facts` resource, which includes the `service_registry` entries with endpoint URLs.

**(F-2) No OpenAI server authentication.** `sap_openai_server/server.py` accepts any `api_key` value passed by clients (its quick-start guide explicitly sets `api_key="any"`). Any caller that can reach port 8200 can execute chat completions against the configured AI Core deployment and perform vector searches against the configured HANA instance.

**(F-3) Async/blocking mismatch in agent.** `LangChainHanaAgent._call_mcp` is declared `async def` but uses `urllib.request.urlopen` (synchronous, up to 120-second timeout). This blocks the event loop for every MCP call. Fix: replace with `aiohttp.ClientSession.post` or `asyncio.to_thread(urllib.request.urlopen, ...)`.

**(F-4) Non-deterministic audit hash.** `_log_audit` in `langchain_hana_agent.py:243` records `hash(prompt)` as `prompt_hash`. Python's `hash()` is `PYTHONHASHSEED`-randomised and non-deterministic across restarts. Fix: `hashlib.sha256(prompt.encode()).hexdigest()`.

**(F-5) Silent identifier stripping rather than rejection.** `HanaDB._sanitize_name` silently strips non-alphanumeric characters rather than raising a `ValueError`. A caller passing `"my-table"` receives a `HanaDB` instance operating against a table named `"mytable"` without any warning. While this cannot produce SQL injection given the character strip, it can cause silent data misrouting if table names contain hyphens (common in SAP naming conventions).

**(F-6) Unresolved Mangle import.** `mangle/domain/agents.mg` line 7: `include "../../../regulations/mangle/rules.mg"`. This path is unresolvable in a standalone repository checkout. The Mangle engine compile failure will prevent agent governance from initialising. Identical to the same issue in `odata-vocabularies`.

**(F-7) OAuth credential handling in bare-except.** `mcp_server/server.py:192`: the `get_access_token` function uses a bare `except:` block to swallow all exceptions from the OAuth token request, returning an empty string silently. This makes authentication failures indistinguishable from network failures and prevents alerting on credential rotation or misconfiguration.

---

## 18. Licensing and Compliance

The project is licensed under **Apache-2.0** (SPDX-FileCopyrightText: 2025 SAP SE or an SAP affiliate company and langchain-integration-for-sap-hana-cloud contributors). The `REUSE.toml` covers all files via a single aggregate annotation with the same API call disclaimer as the other assessed repositories, noting that calls to SAP External Products (AI Core, HANA Cloud) are governed by separate SAP license agreements.

The `hdbcli` dependency (`^2.23.24`) is the SAP HANA Client for Python, distributed under its own SAP license terms. The Apache-2.0 license of this package does not extend to the `hdbcli` binary or its network use of the SAP HANA Cloud service.

`langchain-classic` (`^1.0.0`) is the LangChain maintained legacy interface package. `langchain-core` (`^1.0.0`) and `langchain` (`^1.0.0`) are MIT-licensed. `rdflib` (`^7.0.0`) is BSD-3-Clause. `numpy` is BSD-3-Clause.

The `oasis-tcs/odata-vocabularies` GitHub source dependency present in the `odata-vocabularies` sibling repository does not appear in this package's dependency graph.

The `kuzu/` vendored directory is Apache-2.0 and requires a REUSE compliance assessment before any enterprise distribution, as its 2 073 files are not individually annotated in `REUSE.toml`.

A `CONTRIBUTING.md` is present describing the contribution workflow.

---

## 19. Pre-Production Items

Six items require resolution before production deployment:

**(1) MCP server authentication (F-1).** Port 9140 accepts all connections with no authentication. The `mangle://facts` resource exposes service registry endpoints; `langchain_chat` makes authenticated AI Core inference calls on behalf of unauthenticated callers. JWT/XSUAA token validation, mTLS, or network-policy enforcement at the service mesh layer must be implemented before the server is reachable from outside a trusted namespace.

**(2) OpenAI server authentication (F-2).** Port 8200 accepts `api_key="any"`. Any accessible caller can invoke AI Core inference and HANA vector search. The server should validate the API key against a configured secret or delegate to XSUAA token validation before forwarding requests to AI Core.

**(3) Async/blocking agent fix (F-3).** `LangChainHanaAgent._call_mcp` blocks the event loop for up to 120 seconds per call via `urllib.request.urlopen`. Replace with `aiohttp.ClientSession.post` (preferred) or `asyncio.to_thread`. This one-line structural change is required before the agent can safely serve concurrent requests.

**(4) Audit hash non-determinism (F-4).** Replace `hash(prompt)` in `langchain_hana_agent.py:243` with `hashlib.sha256(prompt.encode()).hexdigest()` to produce stable, PYTHONHASHSEED-independent, forensically useful content identifiers. One-line fix; import `hashlib` at the top of the module.

**(5) Bare-except on OAuth token fetch (F-7).** Replace the bare `except:` in `mcp_server/server.py`'s `get_access_token` with `except Exception as e:` and log the exception with `logger.error("AI Core token acquisition failed: %s", e)`. Silent authentication failure makes credential rotation incidents invisible to operators.

**(6) Mangle import path (F-6).** The `include "../../../regulations/mangle/rules.mg"` in `agents.mg` is unresolvable in a standalone checkout. Either bundle the required regulations rules or make the include conditional. The Mangle engine compile failure will prevent agent governance from initialising. Consistent with the same issue in `odata-vocabularies` — a shared remediation is appropriate.
