# Technical Assessment: ai-core-pal (BDC MCP PAL)

Repository `SAP/ai-core-pal` (internal codename `mcppal-be-po-mesh-gateway`) is a native Zig MCP server that exposes SAP HANA Predictive Analysis Library (PAL) algorithms as Model Context Protocol tools for AI agents and LLM orchestrators. It is version 1.0.0, licensed Apache-2.0, and identified in the REUSE manifest under the SPDX package name `mdk-mcp-server` with supplier "The MDK team". The primary implementation language is Zig 0.14.0, augmented by a Mojo FFI layer for chain-of-thought and SQL validation logic, and a Python governance wrapper called `AICorePALAgent`. The build system is `zig build`, producing a single statically-linked binary named `mcp-mesh-gateway`. The container runtime base is `nvidia/cuda:12.2.0-runtime-ubuntu22.04`.

---

## 1. Purpose and Positioning

`ai-core-pal` is the ML operations gateway within the BDC intelligence fabric. Its primary job is to translate high-level MCP tool calls from AI agents into `CALL _SYS_AFL.*` SQL statements that invoke HANA PAL stored procedures, then return structured results. It covers 162 PAL algorithms across 13 categories — classification, regression, clustering, time series forecasting, anomaly detection, profiling, outlier detection, text analysis, dimensionality reduction, scaling, missing value handling, fair ML, recommendation, and AutoML.

The server also acts as a mesh gateway, federating seven downstream BTP services (HANA, Neo4j, Elasticsearch, news, object store, agent, and pipeline) under a single OpenAI-compatible `/v1/chat/completions` interface, so that any agent or orchestrator that speaks the OpenAI API can reach all of them without knowing their individual addresses or protocols.

Compared to `generative-ai-toolkit-for-sap-hana-cloud`, which is Python-native, LangChain-centric, and focused on RAG and conversational retrieval, `ai-core-pal` sits one level lower. It is performance-oriented (native Zig, GPU Tensor Core support, INT8 quantization), algorithm-centric (the PAL catalog is a first-class data structure, not a utility), and designed to be a stable, low-latency gateway rather than an agent framework.

---

## 2. Repository Layout

The repository is organised into five principal areas. The `zig/` tree contains the entire server implementation: `main.zig` is the entry point; `domain/` holds `pal.zig` (catalog and SQL generation), `config.zig` (env-var configuration), `snapshot.zig` (cross-session state), and `gpu_telemetry.zig` (live GPU metric polling); `mcp/` holds the JSON-RPC handler, HANA schema explorer, SQL validator, and HTTP clients for Elasticsearch and Neo4j; `openai/` provides the OpenAI-compatible shim; `hana/` provides the connection pool; `mangle/` embeds the rule engine interpreter; and `gpu/` contains multi-backend GPU abstractions for CUDA, Metal, and WebGPU.

The `mojo/src/` tree contains a single file, `ffi_exports.mojo`, which provides C-ABI functions for chain-of-thought reasoning, ReAct step execution, SQL template validation, token counting, and tool relevance scoring. These are callable from Zig via the C ABI.

The `mangle/` tree contains fourteen rule files organised into five namespaces: `a2a/` for agent-to-agent protocol rules and service registry, `connectors/` for typed interface schemas (HANA, LLM, MCP-PAL, integration ground facts), `domain/` for agent policy, data product rules, mesh gateway routing, and tool registry, `standard/` for ODPS 4.1 quality and compliance rules, and `toon/` for the TOON serialization grammar.

The `agent/` tree contains the Python governance layer: `aicore_pal_agent.py` defines both `MangleEngine` (an in-process Python replica of the Mangle governance rules) and `AICorePALAgent` (the orchestration wrapper). The `data_products/` tree holds the ODPS 4.1 data product descriptor and registry. The `deploy/aicore/` tree holds the KServe ServingTemplate and AI Core deployment configuration. The `Dockerfile` performs a two-stage build — a Zig compilation stage on Ubuntu 22.04 followed by a CUDA runtime stage — and `scripts/deploy_to_aicore.sh` automates the Docker build, push, and AI Core scenario registration.

---

## 3. High-Level Architecture

At the outermost boundary, AI agents and LLM orchestrators communicate with the gateway either through MCP JSON-RPC (`POST /mcp`, `GET /sse`) or through the OpenAI-compatible API (`POST /v1/chat/completions`, `GET /v1/models`). The gateway listens on port 9881 by default (configurable via `MCP_PORT`).

Inside the gateway, every incoming request passes through three internal stages. First, the Tool Registry resolves which internal tool should handle the request — either by reading the MCP `tool` field directly, or by running the Mangle intent engine against the natural language content of a chat message. Second, the Mangle Router applies policy rules: it verifies that the tool is in the permitted set, checks whether human approval is required, and determines which backend (always the local vLLM) to use. Third, the Tool Executor runs the tool — generating and validating a PAL SQL statement, executing it against HANA Cloud, querying Elasticsearch or Neo4j via their respective HTTP clients, or calling the local LLM endpoint.

Underneath the tool executor sits the GPU layer, which handles embedding generation and inference acceleration. A GPU telemetry poller continuously feeds live hardware metrics (SM version, memory utilisation, temperature, power draw, compute utilisation) into the Mangle engine as facts, which the engine then uses to select the optimal GPU kernel variant for each operation.

The Python `AICorePALAgent` sits alongside the Zig server as an optional governance wrapper. It intercepts tool calls before they reach the Zig server, runs its own in-process Mangle rule evaluation, enforces vLLM-only routing, gates destructive operations behind a human-approval check, and logs every action to an in-memory audit trail.

---

## 4. MCP Tool Surface

The server exposes four core PAL tools to MCP clients. `pal-catalog` allows an agent to list or search the 162 PAL algorithms by name or category. `pal-execute` generates a `CALL _SYS_AFL.*` SQL statement for a named algorithm given a set of parameters. `pal-spec` returns the ODPS YAML specification for an algorithm. `pal-sql` retrieves the raw SQL template. At the higher-level agent interface documented in the README, these map to five named operations: `pal_classification` (backed by `_SYS_AFL.PAL_HGBT`), `pal_regression` (`_SYS_AFL.PAL_LINEAR_REGRESSION`), `pal_clustering` (`_SYS_AFL.PAL_KMEANS`), `pal_forecast` (`_SYS_AFL.PAL_ARIMA`), and `pal_anomaly` (`_SYS_AFL.PAL_ISOLATION_FOREST`).

Beyond PAL, the server exposes schema tools (`schema-explore`, `describe-table`, `schema-refresh`) that let an agent inspect the HANA database structure before constructing a PAL call. It also exposes search tools (`hybrid-search`, `es-translate`, `pal-optimize`) that route to the Elasticsearch search-svc, graph tools (`graph-publish`, `graph-query`) that route to the Neo4j deductive-db, and an `odata-fetch` tool for SAP OData resource access.

The task-to-algorithm mapping is declared as Mangle `pal_for_task/2` ground facts in `mangle/domain/mesh_gateway.mg`. Each task atom such as `/profiling`, `/time_series`, or `/fair_ml` maps to a specific `_SYS_AFL.*` procedure that the engine selects when no explicit algorithm is named by the caller. This means an agent can say "forecast the next 12 months" and the gateway will automatically resolve that to `_SYS_AFL.PAL_ARIMA` without the agent needing to know the PAL procedure name.

---

## 5. Zig Server Core

Server startup in `main.zig` follows a strict sequential initialisation sequence. Configuration is loaded first via `Config.fromEnv()`, which reads environment variables for HANA connection details, PAL SDK path, search service path and URL, deductive DB URL, MCP port, the private LLM URL, and the model name. The shared AI Fabric — a blackboard and distributed tracing substrate shared across BDC services — is initialised next. If the fabric is unavailable, the server continues without it, logging a warning. Model discovery then queries `ai-core-privatellm:8000/v1/models` to learn the architecture (vocabulary size, layer count, attention heads) of the deployed model, which is used to size GPU kernel parameters. The GPU serving engine is initialised with T4-optimised configuration. The PAL catalog is loaded from the SDK path. The Mangle rule engine loads all `.mg` files from the SDK `mangle/` directory and optionally from the search-svc Mangle directory. HANA credentials are resolved with env vars taking priority over Mangle facts loaded from `.vscode/sap_config.local.mg`. Finally the HTTP server begins accepting connections.

The MCP handler in `mcp/mcp.zig` implements the MCP 2024-11-05 protocol. It responds to `initialize` with server capabilities (`tools`, `resources`, `prompts`) and protocol version. `tools/list` returns the full tool schema set. `tools/call` dispatches to the appropriate internal handler and wraps any error in a well-formed MCP error response. `resources/list` and `resources/read` expose HANA schema objects as browsable MCP resources. `prompts/list` and `prompts/get` expose PAL workflow prompt templates.

The OpenAI compatibility shim in `openai/openai_compliant.zig` accepts standard `POST /v1/chat/completions` requests, extracts the last user message, runs Mangle intent detection over its text, resolves the matched tool, executes it, and wraps the result in an OpenAI `ChatCompletion` response object, including support for streaming via Server-Sent Events. This makes the gateway a drop-in replacement for an OpenAI endpoint for any PAL-aware agent.

SQL safety is enforced in `mcp/validation.zig` before any statement reaches HANA. The validator blocks any SQL containing the keywords `DROP`, `TRUNCATE`, `DELETE FROM`, `ALTER`, `GRANT`, or `REVOKE`. It requires that every statement begin with one of `SELECT`, `CALL`, `INSERT`, `UPDATE`, or `WITH`. It checks that all parentheses are balanced. An optional schema-based table name check can be applied when schema metadata is available.

---

## 6. GPU Acceleration Layer

The GPU layer in `zig/src/gpu/` abstracts across three backends: a CUDA backend targeting NVIDIA GPUs (primary, tuned for the T4 at SM 7.5), a Metal backend for Apple Silicon, and a WebGPU backend as a cross-platform fallback. Kernel selection and dispatch are handled by `kernels.zig`, which consults the Mangle engine at runtime rather than using static configuration.

The T4-optimised configuration enables Tensor Cores for FP16 GEMM at 65 TFLOPS, INT8 quantization at 130 TOPS, Flash Attention for linear memory complexity, and continuous batching of up to 256 concurrent sequences with a maximum sequence length of 8192 tokens. Prefix caching is enabled to avoid recomputing the KV cache for repeated prompt prefixes. The serving engine from `deps/llama/src/serving_engine.zig` manages a paged KV-cache across 4096 pages of 16 tokens each.

What makes the GPU layer architecturally interesting is that kernel selection is driven by live telemetry rather than static policy. `gpu_telemetry.zig` polls hardware metrics — SM architecture version, memory utilisation percentage, temperature, power draw in watts, and compute utilisation — and injects them as Mangle facts. The `select_kernel/2` rules in `mangle/domain/mesh_gateway.mg` then derive the appropriate kernel variant. When the GPU temperature exceeds 78°C the engine falls back to `simd_f32` on CPU to avoid thermal throttling. Under high memory pressure with INT8 available it selects `tensor_int8`. With thermal headroom and Tensor Cores present it selects `tensor_fp16`. For attention operations with Tensor Core support it selects `flash_v2`. This makes the execution profile genuinely adaptive to the current hardware state rather than requiring manual tuning.

When no GPU engine is available, `generateDeterministicEmbedding()` in `main.zig` produces 256-dimensional L2-normalised embeddings using a Wyhash-seeded PRNG, ensuring the server remains fully functional on CPU-only hosts.

---

## 7. PAL Catalog and Algorithm Dispatch

`domain/pal.zig` owns the PAL algorithm catalog. On startup it reads YAML specification files for all 162 algorithms from the SDK path and organises them into 13 categories. At runtime it exposes four operations: `search(query)` for fuzzy algorithm discovery by name or category, `getSpec(name)` for the full ODPS YAML specification, `getSql(name)` for the raw `_SYS_AFL.` SQL template, and `execute(name, params, hana_client)` which generates the `CALL _SYS_AFL.*` statement, validates it, and dispatches it to HANA. Table names and parameter values are always resolved from the catalog or from typed MCP input parameters, never interpolated from raw user strings, which eliminates the most common SQL injection surface for stored procedure calls.

---

## 8. Mangle Rules Engine

The Zig server embeds a complete Mangle rule interpreter in `mangle/mangle.zig`. On startup it bootstraps default intent patterns, then recursively loads all `.mg` files from the SDK Mangle directory. The engine exposes `factCount()`, `ruleCount()`, and `intent_patterns.count()` for observability at startup. The `queryFactValue(predicate, key)` method provides point lookups used for credential resolution.

The fourteen rule files are organised into five namespaces. The `a2a/` namespace contains `facts.mg` (declaration-only schema for service registry, API request/response, and model registry), `mcp.mg` (service registry ground facts and the A2A request factory for the OData vocabulary service), `rules.mg` (derived rules for routing, health assessment, model selection, and prompt enhancement), `service_registry.mg` (the full catalog of seven BDC mesh services with ports, capabilities, and priorities), and `fractal_pointers.mg` (fractal ID generation and TOON pointer rules). The `connectors/` namespace contains typed `Decl` schemas for HANA, LLM gateway, MCP-PAL binding, and the ground fact configuration for the `ai-core-pal` service instance. The `domain/` namespace contains agent policy (`agents.mg`), ODPS 4.1 data product rules (`data_products.mg`), mesh gateway intent patterns and GPU kernel selection (`mesh_gateway.mg`), and tool registry rules (`tool_registry.mg`). The `standard/` namespace applies ODPS quality, lineage, SLA, access control, and license compliance rules. The `toon/` namespace defines the TOON serialization grammar.

The most critical predicates at runtime are `resolve_tool/2` (mapping a natural language message to an MCP tool via intent pattern matching), `default_algorithm/2` (mapping a task atom to a `_SYS_AFL.*` procedure), `select_kernel/2` (GPU telemetry to kernel variant), `route_to_vllm/1` (always true), `route_to_aicore/1` (always false), `requires_human_review/1` (gates destructive operations), and `best_route/2` (highest-priority healthy mesh server for a given tool).

---

## 9. A2A Service Mesh and Intent Routing

The service mesh is defined in `mangle/a2a/service_registry.mg` and consists of seven BDC services. `hana-svc` on port 9881 is the primary PAL and HANA service (priority 1). `neo4j-svc` on port 9882 handles Cypher, graph, and GDS queries (priority 1). `agent-svc` on port 9886 provides RAG, memory, embeddings, and data discovery (priority 1). `news-svc` on port 9883, `object-svc` on port 9884, `search-svc` on port 9885, and `pipeline-svc` on port 9887 all carry priority 2. Three additional services are declared in `a2a/mcp.mg`: the OData Vocabularies service at `localhost:9150/mcp`, a local inference service (`local-models`) at `local-models:8080`, and a deductive reasoning service (`deductive-db`) at `deductive-db:8080`.

Every service exposes an OpenAI-compatible `/v1/chat/completions` endpoint, so the mesh gateway can forward intent-resolved requests to any peer using a single uniform HTTP call pattern. Intent detection runs inside the gateway via `resolve_service_for_intent/2` Mangle rules, which map intent atoms (`/pal_execute`, `/news_search`, `/graph_query`, `/vocabulary_lookup`, etc.) to specific service URLs. Natural language patterns are matched via `intent_pattern/2` facts in `mesh_gateway.mg`, covering phrases like "list algorithms", "execute clustering", "show me the spec for", and so on.

A bidirectional reasoning feature makes the gateway more than a simple router. `optimization_hint/2` rules in `rules.mg` analyse the text content of upstream API responses and derive recommendations for the next PAL operation. If a search service response mentions "skewed distribution", the engine suggests using Isolation Forest. If it mentions "time series pattern", it suggests LSTM. If it mentions "anomaly detected", it suggests further outlier investigation. This allows the gateway to act as a reasoning intermediary rather than just a proxy.

---

## 10. TOON and Fractal Pointer System

TOON (Token Oriented Object Notation) is a lightweight serialization grammar defined in `mangle/toon/rules.mg`. It uses a small token vocabulary — keys, values, separators (`:` and `=`), pipes (`|` for arrays), tildes (`~` for null), and brackets — to represent structured data compactly. TOON pointers appear in connector schemas as lightweight cross-service data references, allowing one service to refer to data held by another without copying it into the response payload.

Fractal IDs are the addressing scheme for TOON pointers. Defined in `mangle/a2a/fractal_pointers.mg`, a fractal ID is a six-level hierarchical identifier structured as `TTTTTTTT.SSSSSS.NNNNNN.MMMM.QQQQ.XXXX`, where each segment encodes a different scope: tenant (8 chars), service (6 chars), session (6 chars), message (4 chars), within-message sequence (4 chars), and an enumeration-resistant nonce (4 chars). The URI form is `toon-write://FRACTAL_ID@DEST?type=text`, where `type` can be `text`, `embedding` (1536-dimensional vector), `json`, or `binary`. The scheme ensures that every LLM output is scoped by tenant, service, and session without any PII appearing in the identifier itself, which is important for multi-tenant deployments where outputs from different customers must be strictly isolated.

---

## 11. Mojo FFI Module

`mojo/src/ffi_exports.mojo` provides seven C-ABI functions callable from Zig. `mojo_init()` initialises the Mojo runtime and attempts to load the tiktoken `cl100k_base` tokenizer. `mojo_shutdown()` releases the runtime. `mojo_chain_of_thought()` generates a four-step reasoning template for PAL operations: understanding the request, analysing available context, formulating an approach (identify PAL procedures, map parameters, generate the SQL CALL statement), and signalling readiness to execute. `mojo_react_step()` implements one iteration of the ReAct (Reason+Act) loop — it reads an observation buffer, classifies the situation based on keywords, and outputs one of four actions: `retry_with_fallback` if the observation indicates an error, `query_schema` if it mentions schema or table names, `finalize_response` if it indicates success, or `gather_more_context` otherwise.

`mojo_validate_sql_template()` is a secondary SQL safety check that runs at generation time, before the Zig validator runs at execution time. It blocks dangerous keywords, requires a valid statement start, checks balanced parentheses, and optionally validates table names against a provided schema JSON. Return codes are `0` for valid, `-2` for dangerous SQL, `-3` for invalid structure, and `-4` for unbalanced parentheses. `mojo_count_tokens()` estimates token counts either via the loaded tiktoken tokenizer or via a word-boundary approximation of roughly 4 characters per token. `mojo_score_tool_match()` scores a set of tool descriptions against a query using keyword overlap, returning normalised scores in the range [0.0, 1.0] for use in tool selection when intent detection is ambiguous.

---

## 12. AICorePALAgent — Python Governance Layer

`agent/aicore_pal_agent.py` provides a Python-layer governance wrapper around the Zig MCP server. It contains two classes. `MangleEngine` is an in-process Python implementation of the Mangle governance rules from `mangle/domain/agents.mg`, hardcoding the same facts the Zig engine carries. It knows which tools the agent is permitted to use (`pal_classification`, `pal_regression`, `pal_clustering`, `pal_forecast`, `pal_anomaly`, `mangle_query`), which require explicit approval (`pal_train_model`, `pal_delete_model`, `hana_write`), that all HANA data routes to vLLM and never to AI Core, that the prompting policy sets `max_tokens=4096`, `temperature=0.3`, and `response_format=structured`, and that the agent operates at autonomy level L2.

`AICorePALAgent.invoke()` runs a fixed sequence before any MCP call reaches the Zig server. The backend is set unconditionally to `"vllm"` at the very first line, before any branching. The `MangleEngine` is then queried for `requires_human_review` on the requested tool; if true, the method returns immediately with `status: "pending_approval"` without making any network call. If the tool passes that gate, `safety_check_passed` is checked; a false result returns `status: "blocked"`. Only after both gates pass does the method retrieve the prompting policy and call `POST http://localhost:9180/mcp` (the vLLM MCP endpoint) with the assembled JSON-RPC payload. Every outcome — success, blocked, pending approval, or error — is appended to an in-memory `audit_log` list containing the timestamp, agent name, status, tool name, backend, a hash of the prompt, and the prompt length.

The `annotate_pal_output()` method post-processes PAL results by classifying output column names. Names matching patterns like `prediction`, `forecast`, `score`, `probability`, `amount`, or `count` are annotated as `@Analytics.Measure: true`. Names matching `category`, `segment`, `cluster`, `group`, `type`, or `id` are annotated as `@Analytics.Dimension: true`. Unrecognised names are sent to the OData Vocabularies service at `localhost:9150` for a vocabulary-based suggestion. This annotation logic is also mirrored in pure Mangle via the `suggest_pal_annotation/2` rules in `mangle/a2a/mcp.mg`.

The three key endpoints the Python agent uses are `http://localhost:8084/mcp` for the primary Zig MCP server, `http://localhost:9180/mcp` for the vLLM MCP endpoint that always handles HANA data, and `http://localhost:9150` for the OData Vocabularies service.

---

## 13. OData Vocabularies Integration

The OData Vocabularies service at port 9150 is treated as a first-class peer in the service mesh. It is registered both as an A2A mesh service in `a2a/mcp.mg` and as a Python `VocabularyClient` in the agent layer. The service exposes two model endpoints: `odata-vocab-annotator` for suggesting annotations on PAL output columns and `odata-vocab-search` for looking up SAP vocabulary term definitions.

The vocabulary integration bridges two SAP standard ecosystems. PAL algorithms produce numerical outputs — predictions, scores, cluster labels, anomaly flags — that have no inherent semantic meaning to downstream analytics tools. The OData Analytics vocabulary (`com.sap.vocabularies.Analytics.v1`) provides the annotations (`@Analytics.Measure`, `@Analytics.Dimension`, `@Analytics.AggregatedProperty`) that give those columns semantic meaning within SAP Analytics Cloud and other OData consumers. The Common vocabulary (`com.sap.vocabularies.Common.v1`) adds labels and semantic keys. The OData Aggregation vocabulary (`Org.OData.Aggregation.V1`) specifies how measures should be aggregated.

The Mangle `pal_vocabulary_mapping/2` facts in `a2a/mcp.mg` encode the mapping at a coarser granularity: forecast outputs map to `Analytics.Measure` and `Analytics.AggregatedProperty`, clustering outputs map to `Analytics.Dimension` and `Analytics.GroupableProperty`, and regression outputs map to `Analytics.Measure` and `Analytics.AccumulativeMeasure`. This allows the mesh gateway to produce vocabulary-annotated responses without always deferring to the vocabulary service.

---

## 14. Data Product (ODPS 4.1)

The service is formally described as data product `aicore-pal-service-v1` version 1.0.0 in `data_products/aicore_pal_service.yaml`. It carries a security class of `confidential` and a governance class of `analytics`, with ownership assigned to the Data Science Team and Analytics Platform. The LLM routing policy is declared as `vllm-only` at the product level, which mirrors and reinforces the same constraint in the Mangle rules and the Python agent code.

The product exposes five output ports — classification, regression, clustering, forecast, and anomaly — each individually marked `confidential` and `vllm-only`. Its single input port is `hana-tables`, wired to three upstream financial and ESG data products from the `training-main` monorepo dependency: `treasury-capital-markets-v1` (bond and issuance positions with measures like `GLB_MTM_USD`, `GLB_NOTIONAL_USD`, and `GLB_RWA`), `esg-sustainability-v1` (Net Zero emissions and ESG metrics like `ATT_EMI` and `RWAASSTR`), and `performance-bpc-v1` (CRD and NFRP fact data with Account, Location, Product, Segment, and Cost hierarchies from L0 to L6).

The product declares compliance with three regulatory frameworks: `MGF-Agentic-AI` for agentic AI model governance, `AI-Agent-Index` for agent capability indexing, and `GDPR-Data-Processing` for EU data protection. It operates at autonomy level L2, meaning human oversight is required for any destructive action. Quality SLAs target 99.5% availability, P95 latency of 5000ms, and 100 requests per minute throughput.

---

## 15. Upstream Data Product Dependencies

`data_products/registry.yaml` declares two upstream dependency categories. The first is the `training-main` monorepo path, which provides the three financial and ESG data products described above. Their enrichment pipeline runs `training-main/scripts/xlsx_to_odps.py` and the `training-console` quality tool, with enriched outputs stored under `training-main/data_products/enriched/`.

The second is the `odata-vocabularies` service, declared as a registry dependency with MCP endpoint `http://localhost:9150/mcp` and OpenAI endpoint `http://localhost:9150/v1`. The registry configuration specifies two models: `odata-vocab-annotator` for annotation suggestion and `odata-vocab-search` for term search. Integration points include PAL output column annotation, KPI template generation, and vocabulary term lookup.

---

## 16. SAP AI Core Deployment

The Dockerfile uses a two-stage build. The builder stage starts from `ubuntu:22.04`, installs Zig 0.14.0, and builds the `mcp-mesh-gateway` binary using `zig build -Doptimize=ReleaseFast`. The runtime stage starts from `nvidia/cuda:12.2.0-runtime-ubuntu22.04`, copies the compiled binary and Mangle rule files, installs curl for health checks, creates a non-root user `appuser` at UID 10001, and sets environment variables for `PORT=8080`, `CUDA_VISIBLE_DEVICES=0`, `NVIDIA_VISIBLE_DEVICES=all`, and `NVIDIA_DRIVER_CAPABILITIES=compute,utility`. The health check runs `curl -f http://localhost:${PORT}/health` every 30 seconds with a 10-second timeout, a 5-second start period, and 3 retries. Ports 8080 (HTTP) and 9090 (metrics/gRPC) are exposed.

The KServe ServingTemplate in `deploy/aicore/serving-template.yaml` targets the `infer.s` resource plan (NVIDIA T4). It configures Knative concurrency-based autoscaling with a target of 10 concurrent requests, a minimum of 1 replica, and a maximum of 4. Resource requests are 2 CPU cores and 4GiB memory, with limits of 4 cores and 8GiB. One `nvidia.com/gpu` unit is requested per replica. The deployment script `scripts/deploy_to_aicore.sh` orchestrates `docker build`, `docker push` to the configured registry (defaulting to `ghcr.io/turrellcraigjohn-alt`), and, when `AI_CORE_TOKEN` is set, posts a scenario registration to the AI Core API at `$AI_CORE_URL/v2/lm/scenarios`.

---

## 17. Connector Schema Layer (Mangle)

The `mangle/connectors/` directory defines typed `Decl` schemas that serve as the formal interface contracts between the Zig implementation and the rule engine. Rather than leaving integration semantics implicit in code, these schemas make every integration point first-class Mangle facts that can be queried, reasoned over, and validated.

`hana.mg` defines the full CRUD schema for HANA operations: connection configuration, DDL operations (schema and table create, list, describe, alter, drop, grant, revoke), DML (query, result set, transaction, commit, rollback), and PAL execution (function call, result). `llm.mg` defines the OpenAI-compatible LLM gateway schema: gateway configuration, model registry with context window and cost metadata, chat completion request and response, streaming deltas, tool call lifecycle tracking, embedding request and response, rate limiting, and usage tracking. `mcp_pal.mg` defines the MCP-PAL binding schema: server identity and capabilities, the full tool lifecycle (tool, parameter, call, result), resource access (resource, template, read, content with TOON pointer references), prompt management, PAL function execution lifecycle, PAL-to-MCP tool binding with input/output mappings, and mesh routing configuration. `integration.mg` provides the ground-truth configuration facts for the `ai-core-pal` service instance, declaring the service at version 1.0.0 with protocol `2024-11-05`, a `phi-2` model at `ai-core-privatellm:8080`, HANA at `hana-cloud.hanacloud.ondemand.com:443` with schema `PAL_STORE`, and a BTP object store in the `eu10` region.

---

## 18. Integration Topology

An external AI agent or LLM orchestrator enters the system through either the MCP JSON-RPC endpoint or the OpenAI-compatible chat endpoint, both served by the Zig gateway on port 9881. From there the gateway fans out to five downstream systems: HANA Cloud on port 443 for PAL stored procedure execution, the Elasticsearch search-svc on port 9885 for hybrid search, the Neo4j deductive-db on port 9882 for graph queries, the OData Vocabularies service on port 9150 for column annotation, and the private LLM service on port 8000 for model discovery and GPU inference. The Python `AICorePALAgent` operates as a governance proxy in front of the Zig server, intercepting calls on port 8084, enforcing routing and approval policy, and then forwarding permitted calls to the vLLM MCP endpoint on port 9180 rather than directly to the Zig server's PAL tools. The seven A2A mesh peer services (ports 9881–9887) communicate peer-to-peer through the same OpenAI-compatible interface, using the Mangle service registry for capability discovery and health-based route selection.

A concrete end-to-end example: an agent posts `POST /v1/chat/completions` with the message "forecast next 12 months of sales". The gateway's intent engine runs `resolve_tool` against the message and matches the `/time_series` intent. `default_algorithm(/time_series, Proc)` resolves to `_SYS_AFL.PAL_ARIMA`. `pal.zig` generates the SQL `CALL _SYS_AFL.PAL_ARIMA(SALES_DATA, #PAL_PARAMETER_TBL, ?)`, which passes both the Mojo and Zig validators. `hana.zig` executes the call against HANA Cloud. The result is wrapped in an OpenAI `ChatCompletion` response. If the Python agent is in the path, `annotate_pal_output()` then classifies the output columns — any column named `FORECAST` or `PREDICTION` receives `@Analytics.Measure: true` — before the response is returned to the caller.

---

## 19. Security Profile

The most significant security property of the system is the multi-layer enforcement of the vLLM-only routing constraint for all HANA PAL data. This constraint is independently enforced at four levels: the Zig server sets `backend = "vllm"` in its request handling before any branching occurs; the Mangle rule `route_to_vllm(_) :- true.` and `route_to_aicore(_) :- false.` in `mangle/domain/agents.mg` make it impossible for any derived rule to select a different backend; the Python `AICorePALAgent` sets `backend = "vllm"` on its very first executable line, before calling `MangleEngine`; and the ODPS data product descriptor declares `x-llm-policy: routing: vllm-only` on every output port. The intent is that confidential HANA data never leaves the on-premises or BTP-internal network boundary, even if any single layer of the enforcement stack is bypassed or misconfigured.

SQL injection prevention operates in two independent passes. At generation time, `mojo_validate_sql_template()` enforces a blocklist of dangerous keywords and validates structural correctness. At execution time, `mcp/validation.zig` repeats the same checks on the final generated statement. PAL SQL uses parameterized `CALL _SYS_AFL.*` patterns, and table names are always resolved from the catalog or from typed MCP input, not from raw user strings, closing the most common injection surface.

The human approval gate in `MangleEngine` blocks three destructive operations — `pal_train_model`, `pal_delete_model`, and `hana_write` — from executing automatically. Any invocation of these tools returns `status: "pending_approval"` without making any network call, requiring an explicit out-of-band approval before execution.

HANA credentials are never hardcoded. The resolution chain tries environment variables first, then Mangle facts loaded from `.vscode/sap_config.local.mg` (which is gitignored), then `.vscode/sap_config.mg`, and finally falls back to a BTP destination reference. The container runs as non-root user `appuser` at UID 10001.

There are five known limitations worth noting. First, the audit `prompt_hash` uses Python's built-in `hash()`, which is non-cryptographic, session-dependent, and not collision-resistant; it cannot provide a tamper-evident audit trail. Second, the audit log is an in-memory Python list with no persistence, size bound, or external sink, so it is lost on process restart. Third, PAL tool calls use a 120-second HTTP timeout with no circuit breaker, which means a hung HANA call will block the agent goroutine for up to two minutes with no intermediate error. Fourth, GPU model discovery failure falls back to the T4 configuration unconditionally without raising an alarm, so repeated failures are silent. Fifth, the Mangle `.mg` rule files are loaded from filesystem paths without cryptographic signature verification, meaning a compromised SDK path could silently alter routing policy.

---

## 20. Licensing and Compliance

The project is licensed under Apache-2.0. Copyright is held by `2025 SAP SE or an SAP affiliate company and mcp-server contributors`. `REUSE.toml` includes the standard SAP External Products disclaimer, which states that API calls to external products — specifically the `_SYS_AFL.*` PAL stored procedures, HANA Cloud access, and SAP AI Core APIs — are subject to separate agreements with the respective providers and are not covered by the Apache-2.0 license.

The Zig build carries two internal monorepo dependencies resolved as path references rather than versioned packages. `ai-core-fabric/zig/` provides the shared AI Fabric including the blackboard, distributed tracing, model discovery client, HTTP server, and OpenAI model types. `bdc-intelligence-fabric/zig/` provides the ANWID module for the MCP-to-OpenAI bridge. Because these are path dependencies they are not independently versioned or pinnable; the `build.zig.zon` fingerprint `0x234953c0f8f3d9fa` provides build-level reproducibility verification but does not substitute for dependency version management. The regulatory compliance declarations — `MGF-Agentic-AI`, `AI-Agent-Index`, and `GDPR-Data-Processing` — appear in the ODPS data product descriptor and in the Mangle domain rules, indicating that compliance is treated as a machine-readable property of the data product rather than a purely documentary claim.
