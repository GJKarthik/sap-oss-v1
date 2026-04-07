# Technical Assessment: cap-llm-plugin

**Repository:** `cap-llm-plugin`
**Version assessed:** 1.5.0
**Assessment date:** 2026-03-08
**Primary language:** TypeScript (Node.js / SAP CAP runtime)
**Secondary languages:** Python (governance agent), CDS (service contract)
**License:** Apache-2.0 (REUSE.toml, SPDX-FileCopyrightText 2025 SAP SE)
**Upstream location:** https://github.com/SAP/cap-llm-plugin

---

## 1. Purpose and Positioning

`cap-llm-plugin` is an open-source SAP CDS service plugin that provides a single, standardised LLM access layer for applications built with the SAP Cloud Application Programming Model (CAP). Rather than requiring individual CAP applications to wire their own connections to SAP AI Core, manage OAuth tokens, or implement RAG pipelines from scratch, the plugin exposes a typed CDS service contract (`CAPLLMPluginService`) covering six domains: vector embeddings, chat completion, RAG retrieval, HANA Cloud vector similarity search, HANA Cloud data anonymisation, and streaming chat via Server-Sent Events. All six operations are surfaced as first-class CDS actions in `srv/llm-service.cds` and implemented in the `CAPLLMPlugin` TypeScript class, which registers itself via the standard CAP `cds.once("served")` lifecycle hook.

The plugin occupies the "CAP LLM Integration" tier of the broader SAP AI experience map. Its natural peers in this repository collection are `ai-core-streaming` (the binary-protocol streaming broker it can delegate to) and `ai-sdk-js-main` (which provides the `@sap-ai-sdk/orchestration` client the plugin wraps). In the twelve-service SAP OSS mesh, `cap-llm-plugin` is registered with service ID `cap-llm-plugin`, default security class `internal`, and hybrid LLM routing: public and internal data flows to SAP AI Core; confidential business or financial data flows on-premise to vLLM.

---

## 2. Repository Layout

The repository is organised as a standard npm package with TypeScript source, compiled JavaScript output, and a standalone MCP sub-package.

```
cap-llm-plugin-main/
├── cds-plugin.ts            Plugin entry-point: CDS served handler, AG-UI route registration, anonymisation bootstrap
├── srv/
│   ├── cap-llm-plugin.ts    CAPLLMPlugin class: all six public methods + streaming
│   ├── llm-service.cds      CDS typed service contract (actions, types, errors)
│   ├── legacy.ts            Deprecated v1.3 Azure OpenAI path (env-variable based)
│   └── ag-ui/               AG-UI generative-UI sub-system (7 TypeScript modules)
│       ├── agent-service.ts   AgUiAgentService: SSE orchestrator, five routing branches
│       ├── event-types.ts     AG-UI event type definitions (21 event types)
│       ├── intent-router.ts   IntentRouter: 7-priority routing chain (TypeScript port of MeshRouter)
│       ├── pal-client.ts      PalClient: ai-core-pal MCP :8084 integration
│       ├── schema-generator.ts SchemaGenerator: LLM-driven A2UiSchema generation
│       ├── tool-handler.ts    ToolHandler + ToolRegistry: tool call lifecycle
│       ├── sac-schema-generator.ts  SAP Analytics Cloud widget generation
│       └── sac-tool-handler.ts      SAC-specific tool registrations
├── lib/
│   ├── anonymization-helper.ts  createAnonymizedView: DDL builder for HANA anonymisation views
│   └── validation-utils.js      validateSqlIdentifier, validatePositiveInteger, validateEmbeddingVector
├── src/
│   ├── index.ts             Public type re-exports
│   ├── errors/              Typed error hierarchy: CAPLLMPluginError, EmbeddingError, ChatCompletionError, etc.
│   └── telemetry/           OpenTelemetry integration: tracer.ts, ai-sdk-middleware.ts, angular-tracing.ts
├── mcp-server/
│   └── src/server.ts        Standalone MCP server (HTTP + WebSocket, port 9100)
├── agent/
│   └── cap_llm_agent.py     Python governance agent with inline MangleEngine stub
├── mangle/
│   ├── a2a/mcp.mg           MCP service registry (4 services, 4 intents, 5 tool mappings)
│   └── domain/
│       ├── agents.mg        Agent governance rules (L2 autonomy, tool permissions, routing)
│       └── data_products.mg ODPS 4.1 data product rules (cap-llm-service-v1)
├── data_products/
│   ├── registry.yaml        ODPS 4.1 catalog with hybrid routing policy
│   └── cap_llm_service.yaml Data product definition: ports, routing rules, prompting policy
├── docs/
│   ├── api/openapi.yaml     OpenAPI 3.0 spec for the CDS service contract
│   └── *.md                 Architecture docs, migration guides, OTel design notes
├── tests/                   Jest unit and e2e test suite (97% coverage badge)
├── package.json             npm package manifest v1.5.0
├── tsconfig.json            TypeScript project configuration
└── kuzu/                    Vendored Kuzu embedded graph database (~2073 files)
```

The compiled JavaScript output mirrors the source tree. The package declares `cds-plugin.js` as its `main` entry and `src/index.d.ts` as its TypeScript types entry, which is the conventional CDS plugin layout. The `files` array in `package.json` exports `lib/`, `srv/`, `src/`, `types/`, and `docs/` but deliberately excludes `mcp-server/`, `agent/`, `mangle/`, `data_products/`, and `kuzu/` — those directories are present in the repository for governance, agent integration, and local development purposes but are not shipped to npm consumers.

---

## 3. Core Plugin Service

### 3.1 CDS Service Contract

The authoritative API contract is defined in `srv/llm-service.cds`. It declares seven shared CDS types (`LLMErrorDetail`, `LLMErrorResponse`, `EmbeddingConfig`, `ChatConfig`, `ChatMessage`, `SimilaritySearchResult`) and a single service `CAPLLMPluginService` with seven actions:

| Action | Input | Output | Notes |
|---|---|---|---|
| `getEmbeddingWithConfig` | `EmbeddingConfig`, `String` | `String` | JSON-serialised SDK embedding response |
| `getChatCompletionWithConfig` | `ChatConfig`, `array of ChatMessage` | `String` | JSON-serialised SDK chat completion response |
| `getRagResponse` | input, tableName, columns, configs, context, topK, algoName | `{ completion, additionalContents[] }` | Full embed → search → complete pipeline |
| `similaritySearch` | tableName, columns, embedding (JSON String), algoName, topK | `array of SimilaritySearchResult` | COSINE_SIMILARITY or L2DISTANCE |
| `getAnonymizedData` | `entityName`, `array of String` | `String` | Reads from HANA `_ANOMYZ_V` view |
| `getHarmonizedChatCompletion` | clientConfig, chatCompletionConfig, boolean flags | `String` | Full Orchestration Service feature set |
| `streamChatCompletion` | clientConfig, chatCompletionConfig, abortOnFilterViolation | `String` | SSE streaming; returns `""` in SSE mode |
| `getContentFilters` | type (`"azure"`), config | `String` | Azure Content Safety filter builder |

All errors follow a uniform `{ code, message, details }` schema documented in `docs/ERROR-CATALOG.md`. Contract drift from the CDS definition is detected in CI via `scripts/contract-check.js` (the `contract:check` script).

### 3.2 CAPLLMPlugin Class

`CAPLLMPlugin` extends `cds.Service` and is registered as the implementation for the `cap-llm-plugin` CDS kind in `package.json` under `cds.requires.kinds`. Each public method wraps an `@sap-ai-sdk/orchestration` client call and is instrumented with an OpenTelemetry span:

- **`getEmbeddingWithConfig`** constructs an `OrchestrationEmbeddingClient` with the caller-supplied `modelName` and `resourceGroup`, calls `client.embed()`, and attaches an `OtelMiddleware` for distributed tracing. It validates that `modelName` and `resourceGroup` are non-empty before calling the SDK.

- **`getChatCompletionWithConfig`** constructs an `OrchestrationClient` with `promptTemplating.model.name` set to the caller-supplied `modelName`, calls `client.chatCompletion()`, and similarly attaches `OtelMiddleware`. Input validation is the same two-field check as embeddings.

- **`getRagResponseWithConfig`** composes the above two methods into a three-step pipeline: (1) embed the user query via `getEmbeddingWithConfig`, (2) similarity-search HANA via `similaritySearch`, (3) construct a system prompt injecting the matched content in triple-backtick fences, then call `getChatCompletionWithConfig`. The method is fully traced across all three steps with intermediate OTel events.

- **`similaritySearch`** first validates all inputs via `lib/validation-utils.js`, then attempts to use `@sap-ai-sdk/hana-vector`'s `HANAVectorStore` if the SDK is resolvable at runtime. On import failure it silently falls back to a raw SQL path using double-quoted identifiers and a pre-validated numeric embedding array serialised directly into the query string. Both algorithms (`COSINE_SIMILARITY` descending, `L2DISTANCE` ascending) are supported.

- **`getAnonymizedData`** derives the HANA view name as `<SERVICE_ENTITY_ANOMYZ_V>`, validates both the view name and the sequence column name via `validateSqlIdentifier`, and executes a parameterised `SELECT ... WHERE col IN (?, ?, ...)` query with the caller-supplied sequence IDs.

- **`getHarmonizedChatCompletion`** passes the caller's `clientConfig` directly to `OrchestrationClient`, supporting the full Orchestration Service feature set (prompt templating, input/output content filtering, grounding). Three boolean flags — `getContent`, `getTokenUsage`, `getFinishReason` — allow callers to extract specific response fields without parsing the raw SDK object.

- **`streamChatCompletion`** calls `OrchestrationClient.stream()` and writes SSE frames directly to `req.http.res`. Delta frames carry `{ delta, index: 0 }`, the done frame carries `{ finishReason, totalTokens }`, and the sentinel is `data: [DONE]`. Client disconnect is detected via the `close` event on the HTTP response object, which aborts the upstream AI Core stream through an `AbortController`. In non-SSE mode (e.g., unit tests), the method returns the full accumulated content string instead.

- **`getContentFilters`** currently supports only `type === "azure"`, delegating to `buildAzureContentSafetyFilter` from `@sap-ai-sdk/orchestration`.

### 3.3 Legacy API Path

`srv/legacy.ts` retains the v1.3 API surface (`getEmbedding`, `getChatCompletion`, `getRagResponse`) which was based on Azure OpenAI environment variables (`AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_API_ENDPOINT`, etc.). These are marked `@deprecated` since v1.4.0 and delegate to the legacy module. The migration path documented in `README.md` moves callers from the positional Azure methods to the `*WithConfig` family that uses `@sap-ai-sdk/orchestration`.

---

## 4. Anonymisation Sub-system

### 4.1 CDS Annotation Model

CAP application developers annotate CDS entities with `@anonymize` at both the entity level (specifying the HANA Cloud anonymisation algorithm clause, e.g., `ALGORITHM 'K-ANONYMITY' PARAMETERS 'k=5'`) and the element level (specifying per-column parameters including the mandatory `is_sequence` marker for the primary key column). The plugin's `cds.once("served")` handler in `cds-plugin.ts` iterates all loaded services and entities, collects annotated entities with a `projection` qualifier, and calls `createAnonymizedView` for each.

### 4.2 Anonymised View Lifecycle

`lib/anonymization-helper.ts` implements `createAnonymizedView`, which performs the following sequence on every CAP application boot:

1. Validates `schemaName`, derived `entityViewName`, and `viewName` identifiers via `validateSqlIdentifier`.
2. Validates the algorithm clause against the three known SAP HANA Cloud algorithm prefixes (`K-ANONYMITY`, `L-DIVERSITY`, `DIFFERENTIAL_PRIVACY`) using `validateAnonymizationAlgorithm`.
3. Checks for an existing view via a parameterised `SELECT count(1) FROM SYS.VIEWS WHERE VIEW_NAME = ? AND SCHEMA_NAME = ?`.
4. Drops the existing view if present (`DROP VIEW "<viewName>"`).
5. Constructs the `CREATE VIEW ... WITH ANONYMIZATION` DDL using double-quoted identifiers for all column names and single-quote-escaped annotation values via `escapeSqlSingleQuote`.
6. Executes `REFRESH VIEW "<viewName>" ANONYMIZATION` to materialise the anonymised data.

The anonymised view name follows the deterministic convention `<SERVICE>_<ENTITY>_ANOMYZ_V`. The `getAnonymizedData` API then reads from this view, replacing the raw CDS entity for LLM ingestion.

### 4.3 Supported Algorithms

Three SAP HANA Cloud anonymisation algorithms are whitelisted:

- **k-Anonymity** — Groups records so that each quasi-identifier combination appears at least `k` times.
- **l-Diversity** — Extends k-Anonymity by requiring at least `l` distinct sensitive attribute values per group.
- **Differential Privacy** — Adds calibrated statistical noise to query results, providing formal privacy guarantees.

---

## 5. AG-UI Generative UI Sub-system

Version 1.5.0 introduces a significant new capability in `srv/ag-ui/`: an implementation of the AG-UI streaming agent protocol that generates dynamic SAP UI5 component schemas (`A2UiSchema`) in response to natural language prompts. This is exposed via two HTTP endpoints registered directly on the CAP Express app in `cds-plugin.ts`:

- `POST /ag-ui/run` — accepts an `AgUiRunRequest` (threadId, runId, messages, optional forceBackend) and streams AG-UI lifecycle events as SSE.
- `POST /ag-ui/tool-result` — accepts an `AgUiToolResultRequest` for frontend-driven tool call callbacks.

### 5.1 AgUiAgentService

`AgUiAgentService` is the central orchestrator. It maintains an in-process session map keyed by `threadId`, accumulates conversation history, routes each request through `IntentRouter`, and delegates schema generation to the appropriate backend branch. On construction it initialises a `SchemaGenerator` (LLM-driven A2UiSchema builder), a `ToolHandler` with a `ToolRegistry`, a `PalClient`, and the `IntentRouter`. SAC (SAP Analytics Cloud) specific tools from `sac-tool-handler.ts` are always registered; the `GENERATE_SAC_WIDGET_FUNCTION` is additionally registered when `config.serviceId === 'sac-ai-widget'`.

### 5.2 IntentRouter

`IntentRouter` (`srv/ag-ui/intent-router.ts`) is a TypeScript port of the Python `MeshRouter` from `ai-core-streaming/openai/router.py`. It implements a seven-priority decision chain:

1. **Forced backend** — `forceBackend` field in the request body (validated against a `Set` of five valid values in `cds-plugin.ts` before reaching the router).
2. **Service-ID policy** — eight hard-coded service-to-backend entries (e.g., `data-cleaning-copilot → vllm`, `ai-core-pal → pal`, `sac-ai-widget → aicore-streaming`).
3. **Security class** — `public/internal → aicore-streaming`, `confidential → vllm`, `restricted → blocked`.
4. **Model alias** — three confidential Qwen3.5 model aliases reroute to the local vLLM instance.
5. **Model name** — six Qwen3.5 model IDs map to vLLM.
6. **Content keyword analysis** — three sub-checks in order: restricted keywords (block), confidential keywords (vLLM), PAL analytics keywords (ai-core-pal MCP).
7. **Default** — `aicore-streaming` MCP at `http://localhost:9190/mcp`.

The five routing outcomes are: `blocked` (HTTP 403, no LLM call), `vllm` (on-premise Qwen3.5-35B), `pal` (ai-core-pal MCP for HANA PAL analytics), `rag` (HANAVectorStore + OrchestrationClient), and `aicore-streaming` (MCP JSON-RPC `stream_complete` call).

### 5.3 AG-UI Event Protocol

`event-types.ts` defines 21 AG-UI event types across five categories: lifecycle (`RUN_STARTED`, `RUN_FINISHED`, `RUN_ERROR`, `STEP_STARTED`, `STEP_FINISHED`), text message (`TEXT_MESSAGE_START`, `TEXT_MESSAGE_CONTENT`, `TEXT_MESSAGE_END`), tool call (`TOOL_CALL_START`, `TOOL_CALL_ARGS`, `TOOL_CALL_END`, `TOOL_CALL_RESULT`), state (`STATE_SNAPSHOT`, `STATE_DELTA`, `MESSAGES_SNAPSHOT`), and custom (`CUSTOM`, `RAW`). The generative UI flow uses the `CUSTOM` event type with the `ui_schema_snapshot` name constant to deliver the full `A2UiSchema` object to the Angular frontend. All events are serialised as `data: <JSON>\n\n` SSE frames.

### 5.4 SAP Analytics Cloud Integration

`sac-schema-generator.ts` and `sac-tool-handler.ts` implement SAC-specific tool registration and schema generation. The `GENERATE_SAC_WIDGET_FUNCTION` tool is conditionally registered for the `sac-ai-widget` service ID, enabling the agent to produce SAC widget component schemas through the same SSE pipeline.

---

## 6. MCP Server

`mcp-server/src/server.ts` is a standalone TypeScript MCP (Model Context Protocol) server implementing protocol version `2024-11-05`. It exposes both HTTP (`POST /mcp`) and WebSocket (`/mcp/ws`) transports on port 9100 (configurable via `MCP_PORT`), and a `GET /health` endpoint that reports `degraded` if AI Core environment variables are missing.

The server registers six tools:

| Tool | Description |
|---|---|
| `cap_llm_chat` | Chat completion via AI Core deployments (auto-selects Anthropic Claude when available) |
| `cap_llm_rag` | RAG query placeholder (status stub — requires HANA Cloud integration) |
| `cap_llm_vector_search` | Vector similarity search placeholder (status stub) |
| `cap_llm_anonymize` | Anonymisation placeholder (status stub) |
| `cap_llm_embed` | Embedding generation via AI Core deployments (auto-selects embedding model) |
| `mangle_query` | Queries the in-process Mangle fact store; fans out to remote MCP endpoints via `CAP_LLM_REMOTE_MCP_ENDPOINTS` |

Three resources are registered: `cap://services` (CAP service list), `mangle://facts` (full fact store snapshot), `mangle://rules` (rule file listing). The MCP server is a self-contained sub-package under `mcp-server/` with its own `package.json` and `tsconfig.json`; it is not part of the npm-published package.

The `cap_llm_chat` handler auto-discovers AI Core deployments by calling `GET /v2/lm/deployments`, preferring an Anthropic Claude deployment and falling back to the first available deployment. It switches between the Anthropic invoke path and the standard OpenAI-compatible chat completions path based on the model name. OAuth 2.0 client credentials are obtained via `getAccessToken`, which caches the token in a module-level variable and refreshes it 60 seconds before expiry.

Input safety controls include a 1 MB body limit (`MAX_JSON_BODY_BYTES`), a `topK` ceiling of 100 (`MAX_TOP_K`), a token ceiling of 8,192 (`MAX_TOOL_TOKENS`), and JSON-RPC parameter validation rejecting null or array `params` objects.

---

## 7. Mangle Governance Layer

Three Mangle Datalog files govern the plugin's agent behaviour and data product classification.

### 7.1 MCP Service Registry (`mangle/a2a/mcp.mg`)

Declares four services in the A2A service registry: `cap-llm-chat`, `cap-llm-rag`, `cap-llm-vector`, and `cap-llm-anon`, all resolving to `http://localhost:9100/mcp`. Four intent routes map `/chat`, `/rag`, `/vector_search`, and `/anonymize`. Five tool-to-service mappings connect `cap_llm_chat`, `cap_llm_rag`, `cap_llm_vector_search`, `cap_llm_anonymize`, and `cap_llm_embed` to their respective services.

### 7.2 Agent Domain Rules (`mangle/domain/agents.mg`)

Configures the `cap-llm-agent` with L2 autonomy, MCP endpoint `http://localhost:9100/mcp`, default backend `aicore`, and confidential backend `vllm`. Tool permission rules divide into two groups: freely usable (`cap_chat`, `cap_rag_query`, `cap_embed`, `get_rag_response`, `mangle_query`) and approval-required (`update_vector_store`, `delete_embeddings`, `modify_rag_config`). Data routing rules delegate to `route_to_vllm` for requests containing business keywords (customer, order, invoice, contract, supplier), financial keywords (revenue, profit, cost, budget, forecast), or CAP domain keywords (cds entity, cap service); all other requests route to AI Core. Governance rules classify `update_vector_store`, `delete_embeddings`, `modify_rag_config`, and `bulk_import` as high-risk actions requiring human review. Safety controls require guardrails on `cap_chat`, `cap_rag_query`, `cap_embed`, and `mangle_query`. All tool invocations and approval-required actions require audit logging at `full` level.

### 7.3 Data Product Rules (`mangle/domain/data_products.mg`)

Generated from ODPS 4.1, these rules declare the `cap-llm-service-v1` data product as `internal/hybrid`. Output ports: `chat-completion` (internal/hybrid), `rag-query` (internal/hybrid), `embeddings` (public/aicore-ok). Input ports: `cap-entities` (confidential, no streaming), `user-prompts` (variable, streaming allowed). Routing outcomes: requests through confidential products or confidential input ports → `vllm-only`; public products → `aicore-ok`; internal hybrid products → `hybrid`. Prompting policy: `max_tokens=2048`, `temperature=0.7`, system prompt instructs the model to follow enterprise governance and use RAG context. Regulatory frameworks: MGF-Agentic-AI and AI-Agent-Index. Quality SLAs: 99.9% availability, 2,500 ms p95 latency, 500 req/min throughput.

---

## 8. Python Governance Agent

`agent/cap_llm_agent.py` provides a Python-native governance layer implementing the same routing logic as `agents.mg`. The `MangleEngine` class is an in-process stub that mirrors the Mangle facts in a Python dictionary and exposes a `query(predicate, *args)` interface supporting six predicates: `route_to_vllm`, `route_to_aicore`, `requires_human_review`, `safety_check_passed`, `get_prompting_policy`, and `autonomy_level`.

`CapLlmAgent.invoke()` executes a four-step governance pipeline before dispatching to the MCP endpoint:

1. Route classification via `route_to_vllm` keyword matching → selects `aicore` (`:9100/mcp`) or `vllm` (`:9180/mcp`).
2. Human-review gate via `requires_human_review` → returns `pending_approval` status without executing.
3. Safety check via `safety_check_passed` → returns `blocked` status if the tool is not in the allowed set.
4. Prompting policy retrieval → injects system prompt, max_tokens, and temperature into the MCP payload.

MCP calls are made synchronously via `urllib.request.urlopen` with a 120-second timeout. Audit entries record timestamp, agent ID, status, tool, backend, prompt hash (`hash(prompt)`), and prompt length. The audit log is stored in-process and not persisted.

---

## 9. OpenTelemetry Instrumentation

The `src/telemetry/` directory provides comprehensive observability across all plugin operations. `tracer.ts` implements a no-op tracer fallback when `@opentelemetry/api` is not installed (the package is a listed optional peer dependency), ensuring zero runtime impact in deployments without OTel. `ai-sdk-middleware.ts` implements the `AiSdkMiddleware` interface from `@sap-ai-sdk/orchestration` to inject W3C `traceparent` and `tracestate` headers into outbound AI Core HTTP requests, enabling end-to-end trace propagation from CAP application through the plugin to AI Core. `angular-tracing.ts` exports helper utilities (`withSpan`, `withChatSpan`, `withRagSpan`, `withFilterSpan`, `addEventToActiveSpan`, `injectTraceContextHeaders`) for Angular frontend components to participate in the same trace context.

Span attributes recorded across the plugin methods include: `anonymization.entity`, `anonymization.sequence_id_count`, `llm.embedding.model`, `llm.resource_group`, `llm.chat.model`, `db.hana.table`, `db.hana.algo`, `db.hana.top_k`, `db.hana.embedding_dims`, `llm.rag.top_k`, `llm.harmonized.get_content`, `llm.harmonized.get_token_usage`, `llm.harmonized.get_finish_reason`, `content_filter.type`, and the AG-UI routing attributes `ag-ui.route.backend` and `ag-ui.route.reason`.

---

## 10. Software Bill of Materials (SBOM)

### 10.1 Runtime Peer Dependencies

These packages must be installed alongside the plugin by the consuming CAP application. They are not bundled.

| Package | Min Version | Role |
|---|---|---|
| `@sap/cds` | `>=7.1.1` | CAP runtime: service registration, CDS lifecycle, `cds.db` access |
| `@sap/cds-hana` | `>=2` | HANA ODBC driver for CDS — required for anonymisation and similarity search |
| `@sap-ai-sdk/orchestration` | `>=2.0.0` | `OrchestrationClient`, `OrchestrationEmbeddingClient`, `buildAzureContentSafetyFilter` |
| `@opentelemetry/api` | `>=1.0.0` | OpenTelemetry tracing API — optional; no-op stub used when absent |

### 10.2 Optional Runtime Dependencies (resolved dynamically)

These packages are imported with `await import(pkg)` inside try/catch blocks and are therefore optional at runtime. The plugin falls back gracefully when they are absent.

| Package | Used in | Fallback behaviour |
|---|---|---|
| `@sap-ai-sdk/hana-vector` | `similaritySearch` | Raw SQL fallback via `cds.db.run` |
| `@sap-ai-sdk/vllm` | `AgUiAgentService.generateSchemaViaVllm` | Direct `fetch` to vLLM OpenAI-compatible endpoint |
| `@sap-ai-sdk/mcp-server` | `AgUiAgentService.generateSchemaViaAicoreStreaming` | Raw MCP JSON-RPC `fetch` call |

### 10.3 Development Dependencies

| Package | Version | Role |
|---|---|---|
| `typescript` | `^5.9.3` | TypeScript compiler |
| `jest` | `^30.2.0` | Unit and e2e test runner |
| `jest-junit` | `^16.0.0` | JUnit XML output for CI |
| `eslint` | `^9.39.3` | Linting |
| `prettier` | `^3.8.1` | Code formatting |
| `@opentelemetry/api` | `^1.9.0` | OTel dev dependency (for type checking) |
| `@babel/plugin-transform-*` | `^7.x` | Jest transpilation for ES modules |

### 10.4 MCP Server Sub-package Dependencies

The `mcp-server/` sub-package has a separate `package.json`. Based on its source imports it requires:

| Package | Role |
|---|---|
| `ws` | WebSocket server for MCP `/mcp/ws` transport |
| Node.js `http`, `https`, `url` | HTTP server and OAuth token acquisition (stdlib) |

### 10.5 Build Artefacts

| Artefact | Description |
|---|---|
| `cds-plugin.js` | Plugin entry-point (main) |
| `srv/cap-llm-plugin.js` | CAPLLMPlugin class implementation |
| `lib/anonymization-helper.js` | Anonymisation view DDL builder |
| `src/**/*.js` | Public type and telemetry exports |
| `srv/ag-ui/**/*.js` | AG-UI sub-system compiled output |

### 10.6 Vendored Artefact: kuzu/

The `kuzu/` directory contains approximately 2,073 files consistent with the Kuzu embedded graph database (an open-source, embeddable property graph database). This is a significant vendored dependency. It is not referenced from any TypeScript import in the `src/`, `srv/`, `lib/`, or `mcp-server/` source trees examined, and it is not listed in `package.json` dependencies. Its provenance and intended integration path are not documented in the repository. It is excluded from the npm-published package via the `files` array. See Section 13 (Pre-Production Items) for the recommended action.

---

## 11. CDS Service Registration and Initialisation

The plugin registers itself as a CDS kind `cap-llm-plugin` in `package.json` under `cds.requires.kinds.cap-llm-plugin`. Any CAP application that lists this package as a dependency and includes `cap-llm-plugin` in its `cds.requires` block will receive the plugin at runtime. The implementation is resolved from `cap-llm-plugin/srv/cap-llm-plugin.js`. A VCAP binding hint (`vcap: { label: "hana", plan: "hdi-shared" }`) signals to CAP that HANA connectivity is required for the plugin's database operations.

On each application start the `cds.once("served")` handler in `cds-plugin.ts` runs two initialisation sequences. The AG-UI block checks for a `cds.requires["ag-ui"]` configuration key and, if present (and not explicitly disabled with `enabled: false`), mounts the `POST /ag-ui/run` and `POST /ag-ui/tool-result` routes on the CAP Express app. The anonymisation block iterates all service entities, collects those bearing `@anonymize` annotations with a `projection` qualifier, and calls `createAnonymizedView` for each — but only when `cds.db.kind === "hana"`. Non-HANA deployments receive a warning log and no anonymisation view is created.

---

## 12. Security Profile

### 12.1 SQL Injection Prevention

The plugin applies a multi-layer defence against SQL injection across its HANA-facing code paths:

- `lib/validation-utils.js` defines `validateSqlIdentifier` with the regex `/^[A-Za-z_][A-Za-z0-9_-]*$/`. All caller-supplied table names, column names, view names, and schema names must pass this check before appearing in SQL.
- `validatePositiveInteger` bounds the `topK` parameter to `[1, 10000]`.
- `validateEmbeddingVector` requires a non-empty array of finite numbers; the array is then serialised as a numeric literal string directly into the SQL query, with no possibility of string injection.
- `lib/anonymization-helper.ts` validates the algorithm clause against a whitelist of three known prefixes via `validateAnonymizationAlgorithm` and escapes all annotation values with `escapeSqlSingleQuote`.
- The `getAnonymizedData` method uses parameterised queries (`WHERE col IN (?, ?, ...)`) for sequence ID filtering.
- The `SYS.VIEWS` check in `createAnonymizedView` uses parameterised queries for the view name and schema name lookups.

### 12.2 Input Validation in MCP Server

The MCP server applies the following input controls: 1 MB body limit enforced before JSON parsing, JSON-RPC parameter structure validation rejecting null or array `params`, `clampInt` applied to `topK` (ceiling 100) and `max_tokens` (ceiling 8,192), and `safeJsonParse` wrapping all user-supplied JSON strings.

### 12.3 Security Issues

**Finding 1 — MCP server has no authentication.** `mcp-server/src/server.ts` exposes `POST /mcp` with no authentication middleware. Any process that can reach port 9100 can invoke any tool, including `cap_llm_chat` which makes live AI Core API calls using the server's OAuth credentials. This is the same finding noted in `ai-sdk-js-main`. Authentication middleware (e.g., JWT validation against XSUAA, or mTLS) must be added before any network-accessible deployment.

**Finding 2 — CORS origin falls back to `corsAllowedOrigins[0]` for non-matching origins.** The `getCorsOrigin` function in `mcp-server/src/server.ts` returns `corsAllowedOrigins[0]` (defaulting to `http://localhost:3000`) for requests with no `Origin` header or a non-listed origin. This means server-to-server requests without an `Origin` header will receive a CORS header reflecting `localhost:3000`, which is misleading but not exploitable by browsers. The check should return `undefined` (no `Access-Control-Allow-Origin` header) for non-matching origins to follow the CORS specification correctly.

**Finding 3 — Token cache race condition in `getAccessToken`.** The module-level `cachedToken` object is shared across all concurrent requests. Under a thundering-herd scenario where many requests arrive after token expiry simultaneously, multiple concurrent token requests will be issued before any of them update the cache. A promise-based mutex or in-flight request coalescing should be applied.

**Finding 4 — Python agent uses `hash(prompt)` for audit log.** Python's built-in `hash()` is non-deterministic across processes and produces negative integers on some platforms. For a meaningful audit trail the prompt hash should use a deterministic one-way function such as `hashlib.sha256(prompt.encode()).hexdigest()[:16]`.

**Finding 5 — Business data keyword classifier is brittle.** Both `agents.mg` and `cap_llm_agent.py` classify confidential data by substring matching on a fixed vocabulary (customer, order, invoice, contract, supplier, revenue, profit, cost, budget, forecast, cds entity, cap service, business partner). General words like "cost" or "order" can appear in entirely non-sensitive queries, producing false positives that route innocuous requests to vLLM. For production financial data governance this classifier should be replaced with a semantic classifier or at minimum a higher-confidence term list using phrase matching rather than substring matching.

**Finding 6 — `kuzu/` vendored directory is unaccounted for.** The directory is not referenced from any source file, not documented, and not included in the published npm package. Its presence increases the repository surface area and may introduce transitive licensing obligations that have not been assessed. It should be either documented with a clear integration plan or removed.

---

## 13. Integration Topology

The plugin integrates with five external systems:

| System | Integration Point | Protocol |
|---|---|---|
| **SAP AI Core** | `@sap-ai-sdk/orchestration` `OrchestrationClient` / `OrchestrationEmbeddingClient` | HTTPS, OAuth 2.0 client credentials |
| **SAP HANA Cloud** | `cds.db.run` (CDS HANA adapter) / optional `@sap-ai-sdk/hana-vector` | ODBC via `@sap/cds-hana` |
| **vLLM (on-premise)** | `@sap-ai-sdk/vllm` `VllmChatClient` / direct `fetch` to `/v1/chat/completions` | HTTP, no auth configured |
| **ai-core-streaming** | MCP JSON-RPC `stream_complete` tool call / `@sap-ai-sdk/mcp-server` `AISdkMcpClient` | HTTP to `:9190/mcp` |
| **ai-core-pal** | `PalClient` MCP JSON-RPC / `callMcpTool` utility | HTTP to `:8084/mcp` |

The AG-UI routing layer (`IntentRouter`) determines which of these five paths is used for each request. The default path for public and internal data is the `ai-core-streaming` MCP. Confidential data (business/financial keyword match or `confidential` security class) goes to vLLM. PAL analytics intent keywords route to ai-core-pal. HANA RAG is invoked when `enableRag: true` is configured and a `ragTable` is specified.

---

## 14. Installation and Usage

### 14.1 Prerequisites

- Node.js ≥ 18 (required by `@sap/cds` ≥ 7)
- An `@sap/cds` CAP application with a HANA Cloud HDI container (for anonymisation and vector search)
- An SAP AI Core service instance with at least one deployment (for embeddings and chat completion)
- `@sap-ai-sdk/orchestration` ≥ 2.0.0 bound to AI Core via VCAP_SERVICES or `default-env.json`

### 14.2 Installation

```bash
npm install cap-llm-plugin @sap/cds @sap/cds-hana @sap-ai-sdk/orchestration
```

### 14.3 CDS Configuration

Add to `package.json` or `.cdsrc.json`:

```json
{
  "cds": {
    "requires": {
      "cap-llm-plugin": true,
      "ag-ui": {
        "enabled": true,
        "chatModelName": "gpt-4o",
        "resourceGroup": "default"
      }
    }
  }
}
```

### 14.4 Usage: Embedding Generation

```typescript
const plugin = await cds.connect.to("cap-llm-plugin");
const config = { modelName: "text-embedding-ada-002", resourceGroup: "default", destinationName: "...", deploymentUrl: "..." };
const response = await plugin.getEmbeddingWithConfig(config, "What is SAP HANA?");
const vector = response.getEmbeddings()[0].embedding;
```

### 14.5 Usage: RAG Pipeline

```typescript
const result = await plugin.getRagResponseWithConfig(
  "What is the revenue forecast?",
  "DOCUMENTS", "EMBEDDING", "CONTENT",
  "Answer based on the following context.",
  embeddingConfig, chatConfig
);
console.log(result.completion);         // Orchestration SDK response
console.log(result.additionalContents); // Array of { PAGE_CONTENT, SCORE }
```

### 14.6 Usage: Anonymised Data Retrieval

```typescript
// Entity must have @anonymize annotations in CDS model
const anonymisedRows = await plugin.getAnonymizedData("EmployeeService.Employees", [1001, 1002]);
```

### 14.7 Usage: Streaming Chat

```typescript
// From a CDS action handler with req.http.res available:
await plugin.streamChatCompletion({
  clientConfig: JSON.stringify({ promptTemplating: { model: { name: "gpt-4o" } } }),
  chatCompletionConfig: JSON.stringify({ messages: [{ role: "user", content: "Hello" }] }),
  abortOnFilterViolation: true,
}, req);
// Response delivered via SSE to the HTTP response; method returns ""
```

### 14.8 MCP Server

```bash
cd mcp-server
npm install
AICORE_CLIENT_ID=... AICORE_CLIENT_SECRET=... AICORE_AUTH_URL=... AICORE_BASE_URL=... npm start
# Listens on http://localhost:9100/mcp
```

### 14.9 Test Execution

```bash
npm test                  # Jest unit tests
npm run test:coverage     # Coverage report (target: 97%)
npm run test:e2e          # End-to-end tests
npm run contract:check    # CDS contract drift detection
```

---

## 15. Licensing and Compliance

The project is licensed under **Apache-2.0** (SPDX-FileCopyrightText: 2025 SAP SE or an SAP affiliate company and cap-llm-plugin contributors). The `REUSE.toml` covers all files via a single aggregate annotation with `path = "**"`. The REUSE.toml includes a prominent API call disclaimer noting that calls to SAP External Products (AI Core, HANA Cloud) are not covered by the Apache-2.0 license and are subject to separate SAP license agreements.

The `LICENSES/` directory contains the Apache-2.0 license text. The project is REUSE-compliant as indicated by the `[![REUSE status](...)]` badge in `README.md`.

The `kuzu/` vendored directory requires a separate compliance assessment. Kuzu is itself Apache-2.0 licensed, but its 2,073-file inclusion without documentation or build integration represents an unreviewed transitive dependency surface that should be resolved before any enterprise distribution.

---

## 16. Pre-Production Items

Five items require resolution before production deployment:

**(1) MCP server authentication.** `mcp-server/src/server.ts` has no authentication middleware. Any caller that can reach port 9100 can invoke tools that consume AI Core credentials. JWT middleware validating XSUAA tokens, or mTLS, must be implemented before network-accessible deployment.

**(2) CORS origin handling.** The `getCorsOrigin` function returns `corsAllowedOrigins[0]` for non-matching origins instead of returning `undefined`. While not directly exploitable, it produces incorrect CORS headers on server-to-server requests. The function should return `undefined` for non-matching origins so that no `Access-Control-Allow-Origin` header is set.

**(3) Token cache race condition.** The module-level `cachedToken` in `getAccessToken` is unguarded against concurrent expiry. A in-flight-request coalescing pattern (storing the pending promise and awaiting it) should replace the current check-and-fetch pattern.

**(4) Confidential data classifier upgrade.** The keyword-based classifier in `agents.mg` and `cap_llm_agent.py` uses single-word substring matching, which produces false positives on common English words. For production governance of CAP entity data, the classifier should use phrase matching at minimum, and a semantic classifier for production financial data governance scenarios.

**(5) `kuzu/` vendored directory.** The 2,073-file `kuzu/` directory has no documented integration path, no import references, and is not included in the published npm package. It should be either documented with a clear roadmap entry (e.g., graph-based RAG indexing) or removed from the repository to reduce surface area and clarify compliance obligations.
