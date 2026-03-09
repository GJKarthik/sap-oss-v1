# Technical Assessment: elasticsearch-main (SAP Elasticsearch Integration)

Repository `SAP/elasticsearch-main` is a fork of the upstream Elastic/elasticsearch codebase extended with SAP-specific components: an MCP server, an OpenAI-compatible API server, a governance agent, production-grade middleware, and Mangle-driven policy rules. The SAP additions sit entirely in purpose-built directories (`mcp_server/`, `sap_openai_server/`, `agent/`, `middleware/`, `mangle/`, `data_products/`) and do not modify upstream Elasticsearch Java source, which allows the fork to track upstream changes cleanly. The container image is Python 3.11-slim with FastAPI, the Elasticsearch Python client 8.12.0, and OpenTelemetry instrumentation. The SAP layer is version 1.0.0, Apache-2.0 licensed, and labelled for governance level L2 in its OCI image metadata.

An important secondary component in this repository is an embedded fork of `kuzu/` — the KùzuDB embedded graph database, a C++ project with its own CMake build system, Mojo extension layer, and test suite. This sits alongside the Elasticsearch work and is discussed later in this assessment.

---

## 1. Purpose and Positioning

The project solves two related problems. First, it exposes Elasticsearch search and analytics capabilities to AI agents and LLM orchestrators via the Model Context Protocol, making Elasticsearch a first-class MCP tool provider in the BDC intelligence fabric. Second, it wraps SAP AI Core — which speaks a proprietary inference API — in a full OpenAI-compatible HTTP surface, with Elasticsearch providing vector storage and RAG persistence behind that surface.

Within the broader BDC fabric, this service sits at port 9885 and is registered as `search-svc` in the A2A mesh service registry used by `ai-core-pal` and other mesh peers. Its primary role from the fabric's perspective is hybrid search: keyword-based Elasticsearch queries combined with kNN vector similarity search over AI Core embeddings.

The design philosophy differs from the other SAP intelligence repositories in this monorepo. Where `ai-core-pal` is a from-scratch Zig server purpose-built for PAL operations, and `generative-ai-toolkit-for-sap-hana-cloud` is a Python framework for HANA RAG, `elasticsearch-main` is a thin SAP governance and AI layer bolted on top of a mature, production-grade open-source search engine. The upstream Elasticsearch Java server handles all storage, indexing, and query execution; the SAP Python layer handles governance, routing policy, MCP protocol, and the OpenAI compatibility shim.

---

## 2. Repository Layout

The repository contains the full upstream Elasticsearch source alongside the SAP additions. The upstream directories (`server/`, `modules/`, `plugins/`, `libs/`, `x-pack/`, `qa/`, `distribution/`, `rest-api-spec/`, `build-conventions/`, `build-tools/`, `build-tools-internal/`, `docs/`, `benchmarks/`) are unmodified Elasticsearch. The build system is Gradle with JDK 25, driven by the bundled `gradlew` wrapper.

The SAP-specific surface is entirely contained in eight directories. `mcp_server/server.py` is the MCP server implementation. `sap_openai_server/server.py` is the OpenAI-compatible FastAPI application, with `proxy.mg` defining its Mangle routing configuration and `README.md` documenting its API surface. `agent/elasticsearch_agent.py` is the governance wrapper. `middleware/` contains `circuit_breaker.py`, `rate_limiter.py`, and `health.py`. `mangle/` contains `a2a/mcp.mg` for the A2A mesh protocol and `domain/agents.mg` plus `domain/data_products.mg` for agent governance rules. `data_products/` holds the ODPS 4.1 product descriptor and registry. `Dockerfile.sap` builds the SAP Python components only, not the upstream Java server. `scripts/entrypoint.sh` starts either the MCP server or the OpenAI server depending on the `CMD` argument.

The `kuzu/` directory is a self-contained embedded graph database project with its own `CMakeLists.txt`, `Makefile`, `src/`, `extension/`, `tools/`, `scripts/`, and a `mojo/` subdirectory for Mojo language extensions. It is not referenced by the Elasticsearch MCP server code and appears to be a co-located independent project within the same repository boundary.

---

## 3. High-Level Architecture

The system has two independent service processes, both exposing HTTP APIs, both built from `Dockerfile.sap`. The MCP server listens on port 9120 and speaks the MCP 2024-11-05 JSON-RPC protocol. The OpenAI-compatible server listens on port 9201 and speaks the standard OpenAI REST API, powered by FastAPI and uvicorn. Both servers connect to the same upstream Elasticsearch cluster (defaulting to `http://localhost:9200`) and to the same SAP AI Core deployment via OAuth client credentials.

The `ElasticsearchAgent` in `agent/elasticsearch_agent.py` is not a continuously-running third process; it is a library class that can be imported by orchestrators to apply index-based governance policy before routing a request to either the MCP server or the vLLM endpoint.

The `middleware/` package is designed to be imported by both servers. In the current codebase it is fully implemented but not yet wired into the MCP server's `BaseHTTPRequestHandler` — the MCP server uses plain Python `http.server` rather than FastAPI, so FastAPI-specific middleware integration would require porting. The circuit breakers, rate limiter, and health checker are fully usable from any Python code that imports the package.

Upstream Elasticsearch itself is not modified. The SAP layer communicates with it over its standard REST API using `urllib.request`, authenticating with either an API key (`Authorization: ApiKey ...`) or HTTP Basic credentials.

---

## 4. MCP Server

`mcp_server/server.py` implements the MCP 2024-11-05 protocol using only Python standard library primitives — `http.server.HTTPServer`, `urllib.request`, and `json`. It exposes eight tools and three resources.

The tools are `es_search` (keyword search against any index or pattern using Elasticsearch Query DSL), `es_vector_search` (kNN nearest-neighbour search over a named dense vector field, with a configurable `k` and `num_candidates = k * 2`), `es_index` (index a single JSON document, with optional explicit ID), `es_cluster_health` (proxy to `/_cluster/health`), `es_index_info` (proxy to `GET /{index}` for mapping and settings), `generate_embedding` (call AI Core to embed a text string, returning the raw embedding object), `ai_semantic_search` (orchestrate embedding generation followed by kNN search in a single call), and `mangle_query` (expose the server's internal fact store for governance introspection). The resources are `es://cluster` (live cluster health JSON), `es://indices` (live index list via `/_cat/indices?format=json`), and `mangle://facts` (the server's in-memory Mangle fact dictionary).

Input bounds are enforced by environment-variable-configurable limits: `MCP_MAX_REQUEST_BYTES` (default 1 MiB), `MCP_MAX_SEARCH_SIZE` (default 100 hits), and `MCP_MAX_KNN_K` (default 100 neighbours). The `clamp_int` function ensures caller-supplied `size` and `k` parameters are always kept within these bounds. CORS is handled via `CORS_ALLOWED_ORIGINS` (default `http://localhost:3000,http://127.0.0.1:3000`), enforced on both `OPTIONS` preflight and actual responses.

The AI Core integration in the MCP server uses a manually managed OAuth token cache with a 60-second pre-expiry buffer. It queries `GET /v2/lm/deployments` to discover embedding deployments dynamically, selecting the first deployment whose details string contains the word "embed" and falling back to the first available deployment if no embedding-specific one is found. This heuristic-based deployment discovery is a notable fragility: if the deployment name or details string format changes, the fallback will silently select an inappropriate model.

Tool invocations are tracked in the server's `facts["tool_invocation"]` list for the `es_search` tool, recording the index name and Unix timestamp. This is the only tool whose invocations are recorded in this way; other tools do not append audit entries.

---

## 5. OpenAI-Compatible Server

`sap_openai_server/server.py` is a FastAPI application that presents a complete OpenAI-compatible API surface while routing inference calls to SAP AI Core and using Elasticsearch for vector persistence and RAG.

The core chat completions handler at `POST /v1/chat/completions` supports two AI Core model families with different invocation formats. For Anthropic models it calls `POST /v2/inference/deployments/{id}/invoke` with the `anthropic_version` field, extracting the response from `result["content"][0]["text"]`. For other models (OpenAI-compatible deployments) it calls `POST /v2/inference/deployments/{id}/chat/completions` directly. Both paths support streaming via Server-Sent Events, where the Anthropic path simulates streaming by splitting the completed response word by word (since Anthropic's AI Core endpoint does not return streaming deltas in this integration).

The request model `ChatCompletionRequest` extends the standard OpenAI format with three optional fields. `search_context: bool` enables RAG: when true, the server generates an embedding for the last user message, performs a kNN search in the `sap_openai_vectors` index, and prepends the top-k retrieved document texts as a system message before calling AI Core. `store_in_es: bool` persists the full conversation (including the assistant reply) to the `sap_openai_conversations` index after completion. `conversation_id: str` allows callers to group messages under a persistent conversation, defaulting to the completion ID if not provided. The embedding dimensions are configurable via `ES_VECTOR_DIMS` (default 768).

Beyond standard OpenAI endpoints, the server exposes `POST /v1/semantic_search` for direct vector similarity queries, and a `/v1/files` CRUD implementation that stores file content as embeddings in Elasticsearch and lists them back in OpenAI Files API-compliant response format. Elasticsearch indices are mapped as "fine-tuned models" at `GET /v1/fine-tunes`, which is a creative but semantically stretched mapping that may confuse clients expecting actual fine-tuning lifecycle management.

Deployment lookup uses a three-pass strategy: exact ID match, then substring model name match, then 8-character prefix match. This flexibility accommodates AI Core deployment ID formats, which are opaque hashes like `dca062058f34402b`, but the prefix match could in theory return the wrong deployment if two deployments share a prefix.

---

## 6. Mangle Proxy Configuration

`sap_openai_server/proxy.mg` is a Mangle rule file that declares the OpenAI server's route mappings and Elasticsearch API translation rules. It serves as a machine-readable routing contract, though it is not loaded by the Python server at runtime — it documents the intended proxy topology and transformation rules for the Mangle rule engine in environments where that engine is present as an external service.

The file maps standard OpenAI endpoints (`/v1/chat/completions`, `/v1/embeddings`, `/v1/completions`, `/v1/semantic_search`) to `http://localhost:9201`, with rate limits of 60 requests per minute, 100k tokens per minute, and 10 concurrent requests. It maps Elasticsearch native API paths (`/_search`, `/{index}/_doc`, `/{index}/_knn_search`, `/_cluster/health`, `/_cat/indices`, `/{index}` PUT) to the same server with transformation flags. The transformation rules declare how Elasticsearch query structures should be converted: an ES `match` query becomes an `OpenAIQuery` with `query: MatchText` and `top_k: size`, an ES `query_string` query similarly maps to semantic search, and an ES `knn_search` with `query_text` triggers embedding generation. Document indexing events trigger `on_index_document` which calls SAP AI Core's embedding endpoint and stores the result back into Elasticsearch. These rules describe an AI-enriched transparent proxy that could sit in front of a standard Elasticsearch cluster and make it semantically searchable without application changes.

Model aliases map common OpenAI model names (`gpt-4`, `gpt-3.5-turbo`, `claude-3.5-sonnet`) to the configured AI Core deployment ID, so that unmodified OpenAI client code targeting any of these model names will be routed correctly to the SAP AI Core deployment.

---

## 7. ElasticsearchAgent — Governance Layer

`agent/elasticsearch_agent.py` provides the same governance-wrapper pattern seen in `ai-core-pal` and `generative-ai-toolkit-for-sap-hana-cloud`. It contains `MangleEngine`, an in-process Python replica of the Mangle domain rules from `mangle/domain/agents.mg`, and `ElasticsearchAgent`, which applies those rules to route and gate requests.

The governance model here is notably more nuanced than the vLLM-only policy in the PAL service. Rather than unconditionally routing all requests to vLLM, `ElasticsearchAgent` implements index-based routing: confidential indices (those whose names match patterns like `customer`, `order`, `transaction`, `trading`, `financial`, or `audit`) are always routed to vLLM at `http://localhost:9180/mcp`. Log indices (those whose names start with `logs-`, `metrics-`, or `traces-`) are also routed to vLLM on the basis that log data may contain sensitive information. Only public indices (`products`, `docs`, `help`) and cluster-level operational queries (cluster health and cluster status) are permitted to route to AI Core at `http://localhost:9120/mcp`. Any request that does not match a confidential or public pattern defaults to vLLM as the safe fallback.

The routing decision is made by the `MangleEngine.query("route_to_vllm", prompt)` call, which scans the prompt text for the presence of confidential index name patterns. This means the routing decision is based on what the prompt mentions, not on which index is actually being queried — a prompt that mentions "customer" even in a neutral context will be routed to vLLM. This is a deliberately conservative design that errs on the side of keeping data private.

The human approval gate blocks four operations: `create_index`, `delete_index`, `bulk_index`, and `update_mapping`. These are treated as high-risk DDL operations that require explicit human authorisation before execution. The safety check additionally requires that the tool be in the permitted set (`search_query`, `aggregation_query`, `get_mapping`, `cluster_health`, `list_indices`, `mangle_query`) and that guardrails be active for it. The guardrails-active predicate is declared for the read-only tools but not for `list_indices` or `mangle_query`, relying instead on the `not requires_guardrails` path in the safety check rule.

Every agent action — successful, blocked, pending approval, or error — is appended to an in-memory `audit_log` list with timestamp, agent name, status, tool, backend, a hash of the prompt, and the prompt length.

---

## 8. Mangle Rules

The Mangle rule layer consists of three files. `mangle/a2a/mcp.mg` declares the A2A service registry and intent routing for this service within the BDC mesh. It registers four services, all pointing to `http://localhost:9120/mcp`: `es-search` (model: `elasticsearch`), `es-vector` (model: `knn-search`), `es-index` (model: `indexer`), and `ai-embed` (model: `text-embedding`). Intent routing maps `/search` to `es-search`, `/vector_search` to `es-vector`, `/index` to `es-index`, and `/embed` to `ai-embed`. Tool-to-service mappings route `es_cluster_health`, `es_index_info`, and `mangle_query` through `es-search`, and `ai_semantic_search` through `es-vector`. Three cluster health predicates — `cluster_healthy`, `cluster_warning`, and `cluster_critical` — map the Elasticsearch cluster status strings `green`, `yellow`, and `red` to typed atoms that other Mangle rules can reason over.

`mangle/domain/agents.mg` contains the authoritative agent governance facts and rules for the Elasticsearch agent. It imports an external `regulations/mangle/rules.mg` (a shared monorepo governance knowledge base not present in this repository) and the data product rules. The confidential, log, and public index classifications are declared as ground facts (`confidential_index("customers")`, etc.) and the routing rules derive from those via `fn:contains` pattern matching over lowercased request strings. The `requires_human_review` rule is derived from either the `agent_requires_approval` facts or the conjunction of `high_risk_action` with a `governance_dimension` fact expected from the imported regulations rules. Audit requirements cover all tools, both permitted and approval-gated, at level "full" with query logging enabled.

`mangle/domain/data_products.mg` mirrors the ODPS YAML descriptor as Mangle facts. It declares the three index categories as glob-pattern facts (`es_confidential_index("customers*")`, etc.) and derives routing from `request_targets_index` and index category membership. The prompting policy sets `max_tokens=4096`, `temperature=0.3`, and `response_format=structured`, with a system prompt that instructs the LLM never to expose raw document content from confidential indices and to focus on query patterns and aggregation results rather than raw data.

---

## 9. Middleware Layer

The `middleware/` package provides three production-quality components that address resilience, throughput control, and observability.

`circuit_breaker.py` implements the standard three-state circuit breaker pattern (closed, open, half-open) with a thread-safe implementation using `threading.Lock`. The configuration allows independent tuning of the failure threshold (default 5), success threshold for recovery (default 3), and open-state timeout (default 30 seconds). Three pre-configured breakers are provided: `mangle-query-service` with a threshold of 3 failures and 30-second timeout, `odata-vocabularies` with a threshold of 5 failures and 60-second timeout, and `sap-aicore` with a threshold of 3 failures and 45-second timeout. Both synchronous and async call paths are supported. A `@circuit_breaker` decorator is provided for simple function-level protection. The breaker naming reveals which external services the system is designed to depend on: the Mangle query service (external governance rule evaluation), the OData Vocabularies annotation service, and SAP AI Core.

`rate_limiter.py` implements dual-strategy rate limiting combining a token bucket (for burst control) with a sliding window counter (for sustained rate limiting). The token bucket is filled at `requests_per_second` and has a configurable burst capacity. The sliding window uses a two-bucket weighted interpolation to smooth the boundary between window periods, avoiding the count-reset spike that pure fixed-window limiters produce. Pre-configured limiters are provided for the MCP endpoint (20 req/s, 200 req/min, burst of 50) and the OpenAI endpoint (10 req/s, 100 req/min, burst of 20). A FastAPI dependency factory `rate_limit_dependency()` extracts the rate-limit key from either the client IP or a SHA-256 hash of the Bearer token. Rate limit headers (`X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset`) are added to responses.

`health.py` provides `HealthChecker`, an async health monitor that polls registered service health endpoints with a 30-second result cache and a 5-second per-request timeout. Three services are registered by default: the Elasticsearch cluster at `http://localhost:9200/_cluster/health`, the Mangle query service at `http://localhost:50051/health`, and the OData Vocabularies service at `http://localhost:9100/health`. The aggregate status combines individual service statuses and circuit breaker states into a single response. The overall status is `healthy` if all services report healthy and `degraded` otherwise.

---

## 10. Data Product (ODPS 4.1)

The service is described as data product `elasticsearch-search-v1` version 1.0.0 in `data_products/elasticsearch_search_service.yaml`. It carries security class `confidential` and governance class `search-analytics`, owned by the Search Platform Team in the Data Infrastructure team. The LLM routing policy is `index-based`, with a `confidentialBackend` of `vllm` and `defaultBackend` of `vllm`, reflecting the conservative default-to-private routing strategy.

The product exposes three output ports. The `search-query` and `aggregations` ports are classified `confidential` with `index-based` routing. The `cluster-health` port is classified `internal` and carries `aicore-ok` routing, as cluster health data contains no business documents. The input ports are `business-indices` (`confidential`, `vllm-only`) and `log-indices` (`internal`, `vllm-only`). The index classification lists in the YAML descriptor exactly mirror those in the Mangle domain rules: confidential patterns `customers*`, `orders*`, `transactions*`, `trading*`, `financial*`, `audit*`; public patterns `products*`, `docs*`, `help*`; log patterns `logs-*`, `metrics-*`, `traces-*`.

Quality SLAs target 99.9% availability, P95 latency of 500ms, and 1000 requests per minute throughput. These targets are considerably more aggressive than the PAL service's 5000ms P95 target, reflecting the expectation that Elasticsearch queries are fast compared to ML operations. The data product registry `data_products/registry.yaml` declares a global default security class of `confidential`, hybrid LLM routing by default, and configures AI Core (with `anthropic-claude` model) for public security class and vLLM (with `llama-3.1-70b` and `codellama-34b`) for internal, confidential, and restricted classes.

---

## 11. KùzuDB Embedded Graph Database (kuzu/)

The `kuzu/` directory contains an embedded fork of the KùzuDB columnar graph database. KùzuDB is a C++ project that provides a Cypher-compatible query interface over a column-oriented storage engine, designed for in-process graph analytics. The fork adds a `mojo/` subdirectory for Mojo language bindings, suggesting the intent is to make KùzuDB callable from the BDC Mojo FFI layer that is also present in `ai-core-pal`.

The project has its own `CMakeLists.txt` (with a 16 KiB build definition), a full C++ source tree under `src/`, extension modules under `extension/`, Python and shell tooling under `scripts/`, and a comprehensive test suite under `tools/`. It has its own `.github/` configuration, `LICENSE` (MIT), `CONTRIBUTING.md`, `CLA.md`, and `CODE_OF_CONDUCT.md` — all consistent with it being maintained as a semi-independent sub-project.

The relationship between KùzuDB and the Elasticsearch MCP server is not directly wired in the current code. The Elasticsearch MCP server connects to the `deductive-db` role in the BDC mesh (Neo4j in the PAL service) for graph queries, not to KùzuDB. The kuzu embedding appears to be a parallel track — providing an in-process, no-server-required graph database for scenarios where a full Neo4j deployment is not available or desirable, potentially as a local alternative for the `deductive-db` role in the mesh.

---

## 12. Container and Deployment

`Dockerfile.sap` builds only the SAP Python components, not the upstream Java Elasticsearch server. It uses a two-stage build: a builder stage on `python:3.11-slim` installs system build tools and creates a virtual environment with all Python dependencies (`fastapi==0.109.0`, `uvicorn==0.27.0`, `pydantic==2.5.3`, `elasticsearch==8.12.0`, `httpx==0.26.0`, `python-dotenv==1.0.0`, `opentelemetry-api==1.22.0`, `opentelemetry-sdk==1.22.0`, `opentelemetry-instrumentation-fastapi==0.43b0`, `prometheus-client==0.19.0`). The production stage copies the virtual environment and the SAP application directories only, and runs as a non-root `sap` user.

OCI labels declare governance metadata: `ai.sap.component.type=mcp-server` and `ai.sap.governance.level=L2`. Ports 9120 (MCP) and 9201 (OpenAI server) are exposed. The health check polls `http://localhost:${MCP_PORT:-9120}/health` every 30 seconds. The entrypoint is `scripts/entrypoint.sh`, which selects between starting the MCP server and the OpenAI server based on the Docker `CMD` argument.

The upstream Elasticsearch Java server is not containerised by this Dockerfile. It is expected to run separately — either as a managed service (Elastic Cloud, SAP Discovery Center), a standalone Java process, or a separate Docker container — and to be reachable at the URL configured via `ES_HOST`.

Configuration is entirely environment-variable-driven. The Elasticsearch connection uses `ES_HOST` (default `http://localhost:9200`), `ES_USERNAME` (default `elastic`), `ES_PASSWORD`, and `ES_API_KEY`. SAP AI Core uses `AICORE_CLIENT_ID`, `AICORE_CLIENT_SECRET`, `AICORE_AUTH_URL`, `AICORE_BASE_URL`, `AICORE_RESOURCE_GROUP` (default `default`), `AICORE_CHAT_DEPLOYMENT_ID`, and `AICORE_EMBEDDING_DEPLOYMENT_ID`. The OpenAI server additionally uses `ES_INDEX_PREFIX` (default `sap_openai`) and `ES_VECTOR_DIMS` (default 768). The MCP server uses `MCP_MAX_REQUEST_BYTES`, `MCP_MAX_SEARCH_SIZE`, and `MCP_MAX_KNN_K` for input bounds, and `CORS_ALLOWED_ORIGINS` for CORS policy.

---

## 13. Security Profile

The routing model is more differentiated than the unconditional vLLM-only policy of the PAL service. The Elasticsearch agent performs content inspection on the prompt text to detect mentions of confidential index name patterns, routing those to vLLM. Any request mentioning "search" or "query" also routes to vLLM as a conservative default. Only cluster health queries and requests mentioning explicitly public index names are permitted to route to AI Core. The default for any unrecognised request is vLLM. This means the surface area for accidental AI Core routing is small: only cluster operations and three named public index patterns.

SQL injection is not a concern in the same sense as for the PAL service, since Elasticsearch Query DSL is JSON rather than SQL. The primary injection risk is query DSL manipulation. The `es_search` handler passes the caller-supplied query body directly to Elasticsearch after JSON-parsing it; there is no DSL sanitisation or allowlisting of query types. A caller with MCP access could construct aggregation-heavy or scripted queries that are expensive or that extract data beyond their authorised scope. The `MCP_MAX_SEARCH_SIZE` and `MCP_MAX_KNN_K` limits bound result set size but do not restrict query type or complexity.

The AI Core client in both the MCP server and the OpenAI server caches the OAuth token in a module-level global dictionary. This cache is not cleared between different users of the same process, which is appropriate for a single-tenant deployment but would cause credential leakage in a multi-tenant scenario where different callers should use different AI Core credentials.

The middleware circuit breakers provide resilience against downstream service failures, preventing cascading failures from taking down the MCP or OpenAI servers when AI Core or the Mangle query service is unreachable. The rate limiter protects against abusive request volumes from individual clients.

There are several notable gaps. The `mangle_query` tool exposes the server's entire internal fact store to any MCP client that can call it. The fact store includes the service registry, tool invocation history, and any governance configuration that has been loaded. This is useful for observability but represents an information disclosure channel. The partial audit trail — only `es_search` appends tool invocation facts, while other tools do not — means audit coverage is incomplete. The `generate_embedding` and `ai_semantic_search` tools call AI Core with caller-supplied text and no content filtering, meaning a caller can use the MCP server as an AI Core proxy without going through the agent governance layer. The in-memory audit log in `ElasticsearchAgent` is lost on process restart with no persistence.

---

## 14. Licensing and Compliance

The SAP-added components are Apache-2.0 licensed, as declared in `Dockerfile.sap` OCI labels and in the data product descriptor. The upstream Elasticsearch Java code is dual-licensed: files outside `x-pack/` are available under the Elastic License 2.0, Server Side Public License v1 (SSPL), or AGPL v3; files under `x-pack/` require Elastic License 2.0. The `AGENTS.md` file instructs contributors to copy license headers from existing sources to ensure correct header placement.

The data product declares compliance with `MGF-Agentic-AI` and `AI-Agent-Index` frameworks, operating at autonomy level L2 with human oversight required. Safety controls declared in the ODPS descriptor are guardrails, monitoring, audit-logging, and query-filtering. The vLLM-only routing for confidential and log indices supports GDPR compliance by ensuring that business and operational data from those indices is never sent to an external LLM service; the index-based routing policy makes this a data-classification-driven control rather than a blanket prohibition.

---

## 15. Evaluation of Software (9 March, 2026)

For SAP engineering evaluation, the following items require resolution before production readiness:

(1) MCP server authentication. `mcp_server/server.py` has no authentication middleware. Any caller that can reach port 9120 can invoke tools — including `es_search`, `es_index`, and `generate_embedding` — that consume AI Core credentials and access Elasticsearch indices directly. JWT middleware validating XSUAA tokens, or mTLS, must be implemented before network-accessible deployment. The `CORS_ALLOWED_ORIGINS` allowlist offers no protection against server-side callers and should not be treated as a substitute for request authentication.

(2) CORS origin handling. The `_cors_origin` function in `mcp_server/server.py` returns `CORS_ALLOWED_ORIGINS[0]` when the request `Origin` header is absent or does not match the allowlist, rather than returning `None`. This produces an incorrect `Access-Control-Allow-Origin` header on server-to-server requests that carry no `Origin` header, potentially permitting cross-origin reads by browsers that have been redirected to the server. The function should return `None` for non-matching origins so that no `Access-Control-Allow-Origin` header is emitted.

(3) Token cache race condition. The module-level `_cached_token` dictionary in both `mcp_server/server.py` and `sap_openai_server/server.py` is unguarded against concurrent expiry under multi-threaded or async load. Two concurrent callers that each read a stale `expires_at` value will both issue OAuth token refresh requests simultaneously, potentially causing one to overwrite the other's freshly cached token mid-flight. An in-flight-request coalescing pattern — storing the pending refresh as a future or lock and awaiting it — should replace the current check-then-fetch pattern in both files.

(4) Confidential index classifier fragility. The keyword-based routing classifier in `agent/elasticsearch_agent.py` and mirrored in `mangle/domain/agents.mg` uses single-word, case-insensitive substring matching against the full prompt text. This produces false positives for common English words: a prompt asking about "how to place a customer order in the products index" will route to vLLM even though no confidential index is being queried. For production governance of business index data, the classifier should use phrase matching tied to explicit index name boundaries at a minimum, and a semantic classifier for high-value financial data governance scenarios where prompt-level keyword matches are insufficient.

(5) `kuzu/` vendored directory. The 2,000-plus-file `kuzu/` directory lacks a documented integration path, is unreferenced by any import in the Elasticsearch MCP or OpenAI server code, and is not included in the container image built by `Dockerfile.sap`. It should be either documented with a clear roadmap entry (for example, graph-based RAG indexing as a local alternative to the Neo4j `deductive-db` mesh role) or removed from the repository to reduce compliance surface area, clarify licensing obligations (the KùzuDB `LICENSE` is MIT, distinct from both Apache-2.0 and Elastic License 2.0), and eliminate the maintenance burden of tracking a large upstream C++ project with no current integration.
