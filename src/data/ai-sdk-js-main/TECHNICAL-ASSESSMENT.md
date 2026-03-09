# Technical Assessment: `SAP Cloud SDK for AI (JavaScript/TypeScript)`

**Package:** `sap-ai-sdk` v2.7.0  
**Author:** SAP SE and ai-sdk-js contributors  
**License:** Apache-2.0  
**Repository:** `https://github.com/SAP/ai-sdk-js`  
**Runtime requirement:** Node.js ≥ 18, TypeScript ≥ 5.3, pnpm workspace

---

## Purpose and Positioning

The SAP Cloud SDK for AI is the official TypeScript/JavaScript Software Development Kit for integrating with **SAP AI Core**, **SAP Generative AI Hub**, and the **Orchestration Service**. Its primary purpose is to provide a type-safe, enterprise-grade set of npm packages that abstract the underlying REST APIs of SAP AI Core, exposing them through idiomatic TypeScript clients with first-class support for streaming, content filtering, data masking, document grounding, prompt templating, and multi-provider LLM model routing.

The library serves as the authoritative client SDK for any Node.js or TypeScript application wishing to call AI Core endpoints without writing raw HTTP logic. Authentication, resource group routing, destination resolution, and response streaming are all handled internally through the `@sap-cloud-sdk/connectivity` and `@sap-cloud-sdk/http-client` layers already used by the broader SAP Cloud SDK for JavaScript ecosystem. This means existing SAP BTP applications built on the SAP Cloud SDK can adopt the AI SDK with minimal friction, reusing the same service binding and destination infrastructure they already configure for OData or REST services.

Beyond the core SDK packages, the repository also includes extended tooling that broadens its footprint into the broader enterprise AI ecosystem: a vLLM integration for on-premise self-hosted LLM inference, an HANA Cloud vector engine client for RAG workloads, a BTP Object Store client for document storage, an OpenAI-compatible HTTP proxy server, an MCP (Model Context Protocol) server, and a governance-aware Python AI agent. This combination makes the repository both a developer SDK and a reference platform for enterprise AI governance architecture.

The project is licensed under Apache-2.0 with full REUSE 1.0 compliance. Copyright is attributed to SAP SE and ai-sdk-js contributors (2024). All API calls to SAP or third-party products are governed by separate agreements as documented in `REUSE.toml`.

---

## Repository Layout and Build Architecture

The repository is managed as a pnpm workspace (`pnpm-workspace.yaml`) using pnpm version implied by the lockfile (pnpm 8+). The root `package.json` is `private: true` and defines workspace-level scripts that delegate to individual packages via pnpm filter flags. The root-level `"type": "module"` declaration confirms that the workspace operates in ECMAScript Module mode throughout, a deliberate architectural decision documented in `adr/001-esm.md`.

The workspace contains fifteen packages in the `packages/` directory, grouped into three functional tiers. The first tier covers the canonical published packages included in the `pnpm-workspace.yaml` package registry: `@sap-ai-sdk/core`, `@sap-ai-sdk/ai-api`, `@sap-ai-sdk/orchestration`, `@sap-ai-sdk/foundation-models`, `@sap-ai-sdk/langchain`, `@sap-ai-sdk/document-grounding`, `@sap-ai-sdk/prompt-registry`, and `@sap-ai-sdk/rpt`. These eight are on version `2.7.0` and are the primary public-facing SDK packages. The second tier consists of infrastructure packages — `@sap-ai-sdk/mcp-server`, `@sap-ai-sdk/openai-server`, `@sap-ai-sdk/vllm`, `@sap-ai-sdk/hana-vector`, and `@sap-ai-sdk/btp-object-store` — which are versioned independently (1.0.0 or 0.1.0) and not included in the core workspace configuration. The third tier comprises test and sample packages located at `tests/e2e-tests`, `tests/smoke-tests`, `tests/type-tests`, `sample-code`, and `sample-cap`.

All core SDK packages follow a consistent layout: a `src/` directory containing TypeScript sources, a `dist/` directory for compiled ESM output, a `tsconfig.cjs.json` for optional CommonJS compilation, a `jest.config.mjs` for unit tests, and an `internal.js`/`internal.d.ts` pair that re-exports generated OpenAPI types intended for internal package-to-package use only. This `internal` entry point pattern is a key architectural decision documented in `adr/004-api-facade.md`: generated OpenAPI client types are exposed internally between packages through `internal.js` but are only exposed to end users via explicitly curated type wrappers in `src/orchestration-types.ts`, `src/model-types.ts`, and related files. This approach protects consumers from breaking changes when the upstream OpenAPI specifications change.

The build system uses TypeScript `tsc` for compilation across all core packages, with `tsup` used for the newer independent packages (`@sap-ai-sdk/vllm`, `@sap-ai-sdk/hana-vector`, `@sap-ai-sdk/btp-object-store`). Code generation for OpenAPI clients is driven by `@sap-cloud-sdk/openapi-generator` and orchestrated through per-package `generate` scripts that invoke `orval` or custom `postgenerate` scripts to fix import extensions and remove unwanted generated files. The root `jest.config.mjs` configures the Jest test runner with `NODE_OPTIONS=--experimental-vm-modules` to support ESM-native test execution. Global test setup and teardown scripts (`global-test-setup.mjs` and `global-test-teardown.mjs`) are present at the root level. Linting uses ESLint 9 with `@sap-cloud-sdk/eslint-config`, and Prettier 3 for formatting.

Version management is handled by Changesets (`@changesets/cli` v2.29.8) through the `.changeset/` directory, replacing the Lerna-based conventional commits approach used in some other SAP OSS repositories. This means changelog entries are produced from individual changeset markdown files authored during PR development.

The ADR directory (`adr/`) records four architectural decisions: ESM-only module syntax, project structure with `internal.js`, CHANGELOG maintenance via Changesets, and the API facade pattern for generated types.

---

## Core Authentication and Destination Layer (`@sap-ai-sdk/core`)

The `@sap-ai-sdk/core` package is the foundational layer of the SDK and the only package that directly interacts with the `@sap-cloud-sdk/connectivity` and `@sap-cloud-sdk/http-client` libraries. It provides three primary exports: `executeRequest`, `getAiCoreDestination`, and `OpenApiRequestBuilder`, along with a streaming utilities module and a comprehensive `model-types.ts` catalogue.

The `getAiCoreDestination` function in `context.ts` is the credential resolution entry point for the entire SDK. It supports three authentication flows: an explicit `HttpDestinationOrFetchOptions` passed at call site (with destination caching enabled by default), a JSON service key injected via the `AICORE_SERVICE_KEY` environment variable (intended for local development only, with a warning logged), and automatic BTP service binding discovery via `getServiceBinding('aicore')` using the standard Cloud Foundry `VCAP_SERVICES` mechanism. This means the SDK integrates transparently into BTP-deployed applications without any code changes.

The `executeRequest` function in `http-client.ts` constructs the final HTTP call by combining the resolved AI Core destination with endpoint-specific options (`url`, `apiVersion`, `resourceGroup`). It always sets the `ai-resource-group` header for AI Core resource group routing and the `ai-client-type: AI SDK JavaScript` telemetry header, which appears in AI Core audit logs. The function also handles a known axios streaming error (documented with a link to the upstream GitHub issue) by reading the stream body before re-throwing. Response streaming is supported through the `SseStream`, `LineDecoder`, and `SSEDecoder` utilities exported from `src/stream/`.

The `model-types.ts` file is particularly informative for understanding the SDK's supported model landscape. It defines TypeScript `LiteralUnion` types covering six model families: `AzureOpenAiChatModel` (gpt-4o, gpt-4.1, gpt-4.1-mini, gpt-4.1-nano, o1, o3, o3-mini, o4-mini, gpt-5, gpt-5-mini, gpt-5-nano), `GcpVertexAiChatModel` (gemini-2.5-flash, gemini-2.5-flash-lite, gemini-2.5-pro), `AwsBedrockChatModel` (anthropic Claude 3, 4, 4.5 series and Amazon Nova series), `PerplexityChatModel` (sonar, sonar-pro), `AiCoreOpenSourceChatModel` (Cohere Command, Mistral series, sap-abap-1), and `SapRptModel` (sap-rpt-1-small, sap-rpt-1-large). The use of `LiteralUnion` means consumers receive IntelliSense autocompletion for known model names while remaining free to pass arbitrary string identifiers for custom deployments.

---

## AI Core API Management Client (`@sap-ai-sdk/ai-api`)

The `@sap-ai-sdk/ai-api` package is a fully generated OpenAPI client for the AI Core API specification (`src/spec/AI_CORE_API.yaml`). It provides programmatic management of AI Core resources including deployment creation and configuration, model training pipeline management, artifact registration, Docker registry configuration, Git repository synchronization, object storage registration, and batch inference job execution. The generated code is produced by `@sap-cloud-sdk/openapi-generator` with the `--generateESM` flag, followed by an import-fixing script (`scripts/update-imports.ts`) that rewrites `.js` extensions into the generated TypeScript files.

This package intentionally does not have a hand-written API facade — the generated client types are used directly, and all generated types are exposed through the public entry point. This is appropriate because the management API types (deployment IDs, scenario names, resource groups) are less volatile than the inference API types and change less frequently between AI Core API versions.

---

## Orchestration Client (`@sap-ai-sdk/orchestration`)

The `@sap-ai-sdk/orchestration` package is the highest-level and most feature-rich client in the SDK. It exposes the SAP AI Core Orchestration Service, which is a pipeline-based middleware that chains together prompt templating, content filtering, data masking, document grounding, and translation before and after calling the underlying LLM. The package is structured around two primary client classes: `OrchestrationClient` for chat completions and `OrchestrationEmbeddingClient` for embeddings.

The `OrchestrationModuleConfig` interface in `orchestration-types.ts` is the central configuration object, allowing consumers to compose an orchestration pipeline by specifying a `promptTemplating` module (required, contains the model selection and system template), an optional `filtering` module (input and output with Azure Content Safety or Llama Guard 3 8B), an optional `masking` module (SAP Data Privacy Integration for PII entity detection and masking), an optional `grounding` module (document grounding service with vector repository filters), and an optional `translation` module (input and output language translation via SAP Document Translation). The SDK provides builder functions for each module: `buildAzureContentSafetyFilter`, `buildLlamaGuard38BFilter`, `buildDocumentGroundingConfig`, `buildDpiMaskingProvider`, and `buildTranslationConfig`.

Template support is a first-class feature. Prompt templates can be defined inline via `PromptTemplate` with `{{?placeholder}}` syntax for static system prompts, or referenced remotely via `TemplateRef` pointing to entries in the Prompt Registry by ID or by `scenario/name/version` tuple. Per-request dynamic messages are passed separately in `.chatCompletion({ messages })` to avoid mixing static and dynamic templating concerns. The `OrchestrationModuleConfigList` type allows defining a fallback list of module configurations that the orchestration service tries in order until one succeeds, supporting model failover scenarios.

Streaming is fully supported through `OrchestrationStream`, `OrchestrationStreamResponse`, and `OrchestrationStreamChunkResponse` classes that decode the SSE stream, reassemble per-module chunk results, and expose typed accessors for intermediate grounding results, filter decisions, and token usage statistics. The `RequestOptions.streamOptions` field allows configuring per-module streaming behavior, including output filtering stream options and global stream options such as usage inclusion in the final chunk.

The package's generated client was produced from `src/spec/api.yaml` via `openapi-generator`, but its public surface is entirely hand-written wrappers as required by the API facade ADR. The generated types are exported only through `internal.js`.

---

## Foundation Models Client (`@sap-ai-sdk/foundation-models`)

The `@sap-ai-sdk/foundation-models` package provides clients for directly calling the inference endpoints of foundation models deployed in AI Core, bypassing the Orchestration Service pipeline. It is primarily used when application logic needs direct, low-overhead access to a model without the orchestration middleware, or when integrating with models whose APIs do not fit the orchestration pipeline schema.

The package contains dedicated clients for Azure OpenAI deployments, generated from the Azure OpenAI inference OpenAPI specification (`src/azure-openai/spec/inference.json`) via the `@sap-cloud-sdk/openapi-generator` with a `--schemaPrefix AzureOpenAi` flag to namespace the generated types. Like the orchestration package, the generated types are kept internal and hand-written facade types are exposed publicly. The client supports chat completions, streaming, embeddings, and the full Azure OpenAI parameter surface including `max_tokens`, `temperature`, `frequency_penalty`, `presence_penalty`, `top_p`, and `n`.

---

## LangChain Integration (`@sap-ai-sdk/langchain`)

The `@sap-ai-sdk/langchain` package provides LangChain-compatible model clients built on top of the `foundation-models` and `orchestration` clients. It exports `AzureOpenAiChatClient` and `AzureOpenAiEmbeddingClient` (from the `openai/` sub-module) and an `OrchestrationClient` (from the `orchestration/` sub-module) that conform to the LangChain `BaseChatModel` interface, enabling drop-in use with LangChain chains, agents, LangGraph workflows, and LCEL (LangChain Expression Language) pipelines.

The peer dependency on `@langchain/core` v1.1.16+ and the dev dependency on `@langchain/langgraph` v1.1.5 indicate that the package targets the LangChain v0.3/v1.x ecosystem. The `uuid` v13 runtime dependency is used for stable message ID generation required by the LangChain message format. The `OrchestrationMessageChunk` export allows streaming orchestration responses to be consumed as LangChain `AIMessageChunk` objects, enabling streaming in LangGraph nodes.

The CJS compilation for this package requires a workaround (temporarily swapping `package.json` during build) due to the `"type": "module"` workspace setting and the need to emit CommonJS for LangChain consumers that may not yet have migrated to ESM.

---

## Document Grounding Client (`@sap-ai-sdk/document-grounding`)

The `@sap-ai-sdk/document-grounding` package wraps the AI Core Document Grounding Service APIs: the Pipeline API (for configuring document ingestion pipelines), the Vector API (for managing vector repositories and documents), and the Retrieval API (for semantic search and context retrieval). It is a generated OpenAPI client produced from `src/spec/api.yaml` with per-service options from `src/spec/options-per-service.json`.

This package is a direct dependency of `@sap-ai-sdk/orchestration` — the grounding module configuration in `OrchestrationModuleConfig` ultimately maps to document grounding service filters that are resolved by the orchestration service calling the document grounding APIs at runtime. Applications that manage their own document repositories (uploading documents, configuring pipelines, triggering indexing) use this package directly, while applications that only consume grounding as part of an orchestration pipeline need only configure the orchestration client.

---

## Prompt Registry Client (`@sap-ai-sdk/prompt-registry`)

The `@sap-ai-sdk/prompt-registry` package provides access to the AI Core Prompt Registry, which stores versioned, reusable prompt templates that can be referenced by name and version from orchestration configurations. This allows prompt engineering teams to manage, version, and iterate on system prompts independently of application code.

The package is generated from `src/spec/prompt-registry.yaml` via both `@sap-cloud-sdk/openapi-generator` and `orval` (for additional Zod schema generation, as indicated by `orval.config.js` and the `zod` v4 dependency). The runtime `zod` v4 dependency — notably absent from most other core packages — suggests this package performs runtime validation of prompt registry responses, which is appropriate given the dynamic nature of template content. The package is an explicit dependency of `@sap-ai-sdk/orchestration`, which uses it to resolve `TemplateRef` identifiers.

---

## SAP RPT Client (`@sap-ai-sdk/rpt`)

The `@sap-ai-sdk/rpt` package provides a client for SAP's Relational Pretrained Transformer model family (`sap-rpt-1-small` and `sap-rpt-1-large`). These are SAP-managed, enterprise-specific models optimised for structured data reasoning tasks. The client is generated from `src/spec/rpt.json` with pre- and post-generation scripts (`pregenerate-rpt.ts` and `postgenerate-rpt.ts`) that prepare the OpenAPI spec and make certain generated types internal respectively. The RPT model identifiers are also present in the core `model-types.ts` `SapRptModel` union type.

---

## vLLM Integration (`@sap-ai-sdk/vllm`)

The `@sap-ai-sdk/vllm` package, at version 0.1.0, provides a TypeScript client for vLLM (a high-throughput, memory-efficient open-source LLM inference engine with an OpenAI-compatible API). This package is architecturally significant because it represents the on-premise inference pathway in the hybrid routing governance model: when the `AISdkAgent` (see below) determines that a request contains confidential financial data, it routes to the vLLM endpoint rather than to AI Core.

The package provides a `VllmChatClient` class with `chat()`, `chatStream()`, `complete()`, `embed()`, `listModels()`, and `healthCheck()` methods. It also provides a `ModelRouter` class supporting `round-robin`, `random`, `weighted`, `least-latency`, and `priority` load balancing strategies across multiple vLLM deployments, a `HealthMonitor` for periodic health checks with configurable failure and recovery thresholds and an event callback interface, a `ModelDiscovery` class for auto-detecting available models from an endpoint, and a `StreamBuilder` fluent API with `onContent`, `onStart`, and `onComplete` callbacks. Retry logic includes an exponential backoff utility and a `CircuitBreaker` class. This is the most fully featured of the independent packages and is built with `tsup` rather than `tsc` directly, producing both ESM and CJS outputs.

---

## HANA Cloud Vector Engine Client (`@sap-ai-sdk/hana-vector`)

The `@sap-ai-sdk/hana-vector` package, at version 1.0.0, provides a TypeScript client for SAP HANA Cloud's vector engine, enabling Retrieval-Augmented Generation (RAG) workflows backed by HANA's native similarity search capabilities. It depends on the official `@sap/hana-client` v2.19.0 driver and provides APIs for creating vector collections, inserting document embeddings, and running cosine similarity searches. The package also surfaces as the `hana_vector_search` tool in the MCP server, and is referenced in the `openai-server` proxy via HANA vector endpoints. Like `@sap-ai-sdk/vllm`, it is built with `tsup` and targets Node.js ≥ 18.

---

## BTP Object Store Client (`@sap-ai-sdk/btp-object-store`)

The `@sap-ai-sdk/btp-object-store` package, at version 1.0.0, provides an S3-compatible object storage client for SAP BTP's Object Store service. It wraps the AWS SDK v3 (`@aws-sdk/client-s3`, `@aws-sdk/lib-storage`, `@aws-sdk/s3-request-presigner`) with a higher-level abstraction providing `upload`, `download`, `downloadStream`, `list`, `listAll`, `delete`, `deleteMany`, `copy`, `move`, and `getPresignedDownloadUrl`/`getPresignedUploadUrl` operations.

Configuration can be sourced from a VCAP_SERVICES service binding (via `getConfigFromVcap()`), from environment variables (`BTP_OBJECT_STORE_*` or `AWS_*` prefixes, via `createBTPObjectStoreFromEnv()`), or from an explicit configuration object. The package is primarily intended to support AI use cases such as storing training documents for RAG pipelines, persisting model artefacts, and enabling client-side direct uploads via presigned URLs.

---

## OpenAI-Compatible Server (`@sap-ai-sdk/openai-server`)

The `@sap-ai-sdk/openai-server` package is a standalone Express 4 server that exposes an OpenAI-compatible API (`/v1/chat/completions`, `/v1/embeddings`, `/v1/models`, etc.) while proxying requests to SAP AI Core. It allows any OpenAI-compatible client library or tool (including the OpenAI Python SDK, LangChain, and others) to target SAP AI Core deployments without modification. The server ships with a `sap-openai-server` CLI entry point.

The accompanying `proxy.mg` file is a Mangle Datalog configuration that defines the full routing logic for this proxy. It maps all OpenAI API endpoints to `http://localhost:3000/v1/`, sets model aliases mapping `gpt-4`, `gpt-4-turbo`, `gpt-3.5-turbo`, `claude-3.5-sonnet`, and `anthropic--claude-3.5-sonnet` to a single AI Core deployment ID (`dca062058f34402b`), specifies Anthropic-to-OpenAI request and response format transformation rules (`transform_request`/`transform_response`), configures a round-robin load balancer across available deployments, sets rate limits (60 requests/minute, 100k tokens/minute, 10 concurrent), caches `/v1/models` responses for 300 seconds, and configures structured request logging with latency tracking but without request/response body logging.

The server's direct dependencies are `express`, `cors`, `dotenv`, and `uuid` — deliberately lightweight, with no dependence on the core SDK packages. This decoupling allows the server to be deployed as an independent sidecar.

---

## MCP Server (`@sap-ai-sdk/mcp-server`)

The `@sap-ai-sdk/mcp-server` package implements a Model Context Protocol server exposing AI Core capabilities as JSON-RPC tools consumable by MCP clients such as Claude Desktop, Cursor, or any other MCP-compliant agent runtime. The server supports three transport modes: HTTP (`POST /mcp`), Server-Sent Events (`GET /mcp/sse`), and WebSocket (`WS /mcp/ws`).

The MCP server exposes six tools: `ai_core_chat` (chat completions via AI Core), `ai_core_embed` (embeddings via AI Core), `hana_vector_search` (HANA Cloud vector similarity search), `list_deployments` (enumerate AI Core deployments), `orchestration_run` (execute an orchestration scenario), and `mangle_query` (query the Mangle reasoning engine directly). It also exposes three resources: `deployment://list` (real-time deployment list), `mangle://facts` (current Mangle fact store), and `mangle://rules` (loaded Mangle reasoning rules). Two prompt templates are registered: `rag_query` and `data_analysis`.

The server integrates with the local Mangle rule files at `../../mangle/`, specifically `a2a/mcp.mg` (service registry and routing), `connectors/aicore.mg` (AI Core deployment rules), and `standard/rules.mg` (audit, health, and quality rules). Configuration is entirely via environment variables: `AICORE_CLIENT_ID`, `AICORE_CLIENT_SECRET`, `AICORE_AUTH_URL`, `AICORE_BASE_URL`, `AICORE_RESOURCE_GROUP`, and `MCP_PORT` (default 9090). The server depends on `@modelcontextprotocol/sdk` v1.0.0, `express`, `ws` (WebSocket), `dotenv`, and `uuid`.

---

## AI Agent with Governance-Aware Routing (`agent/ai_sdk_agent.py`)

The `agent/ai_sdk_agent.py` file contains a Python implementation of the `AISdkAgent`, a governance-aware LLM routing agent for the AI SDK. Unlike the `ui5-webcomponents-ngx-main` agent (which operates at autonomy level L3 for public code), this agent operates at **autonomy level L2**, reflecting the higher sensitivity of the data domains it handles.

The agent is composed of two classes. The `MangleEngine` class simulates a Mangle Datalog inference engine by loading facts into a Python dictionary and exposing a `query(predicate, *args)` interface. The predicates implemented are `route_to_vllm`, `route_to_aicore`, `requires_human_review`, `safety_check_passed`, `agent_can_use`, `get_prompting_policy`, and `autonomy_level`. The routing decision is based on a keyword set of confidential financial terms: `trading`, `position`, `pnl`, `profit`, `loss`, `balance`, `fx`, `derivative`, `swap`, `hedge`, `var`, `exposure`, `counterparty`, `risk`, `liquidity`, and `capital`. If any of these appear in the prompt (case-insensitive), the request is routed to the vLLM on-premise backend; otherwise it goes to AI Core. This keyword list is domain-specific to financial services use cases.

The `AISdkAgent` class exposes an `invoke(prompt, context)` async method that implements a five-step governance pipeline: (1) routing decision via Mangle, (2) human review gate for destructive tools (`create_deployment`, `delete_deployment`, `modify_deployment`), (3) safety check against the tool allowlist (`aicore_chat`, `aicore_embed`, `list_deployments`, `get_deployment_info`, `mangle_query`), (4) prompting policy retrieval with a system prompt that prohibits external disclosure of financial data, and (5) MCP tool invocation at either the AI Core MCP endpoint (`:9090`) or vLLM MCP endpoint (`:9180`).

The agent also contains a `VocabularyClient` class that connects to an OData Vocabularies MCP server on port 9150, enabling the agent to search vocabulary terms, look up specific OData vocabulary definitions (UI, Common, Analytics, PersonalData), suggest annotations for entity types, generate TypeScript interfaces from vocabulary definitions, and validate OData annotation strings. This positions the agent as a development assistant for OData/CAP development in addition to its runtime governance role.

Audit entries record `timestamp`, `agent`, `status`, `tool`, `backend`, `prompt_hash` (not the prompt itself), and `prompt_length`. The actual prompt content is deliberately not stored in the audit log, which is consistent with the `retentionPolicy: no-storage` in the data product descriptor.

---

## Mangle Datalog Governance Layer

The `mangle/` directory contains four Mangle Datalog rule files organized into sub-namespaces: `a2a/mcp.mg` (service registry mapping, tool routing, MCP endpoint definitions), `connectors/aicore.mg` (AI Core deployment discovery and capability rules), `domain/agents.mg` (agent-level facts including autonomy levels, tool permissions, and approval gates), and `standard/rules.mg` (cross-cutting audit logging, health monitoring, and quality rules).

The agent's `MangleEngine` constructor references both `mangle/domain/agents.mg` and `../regulations/mangle/rules.mg`, the latter being the cross-repository regulatory rules file from the shared `regulations` module in the workspace. The `mangle_query` MCP tool surfaces the Mangle reasoning layer to external MCP clients, allowing AI agents like Claude Desktop or Cursor to query the rule base directly as part of agentic workflows.

---

## Data Product Contract (ODPS 4.1)

The `data_products/` directory contains two ODPS 4.1 descriptor files. The `ai_core_inference.yaml` defines the `ai-core-inference-v1` data product with `dataSecurityClass: internal` and `dataGovernanceClass: enterprise-ai`. Its `x-llm-policy` extension specifies `routing: hybrid`, `defaultBackend: aicore`, `confidentialBackend: vllm`, `auditLevel: full`, and `retentionPolicy: no-storage`.

The routing rules in the data product map `contains_financial_data` and `contains_trading_data` conditions to the vLLM backend, while `general_query` routes to AI Core. Individual output ports carry their own security class overrides: chat and text completion endpoints are `internal`, while embeddings are `public`. The input `context-data` port is classified as `confidential` with `routing: vllm-only` and `allowTokenization: false`, enforcing that no enterprise context data is ever tokenized by an external LLM provider.

The regulatory compliance section specifies frameworks `MGF-Agentic-AI` and `AI-Agent-Index`, `autonomyLevel: L2`, and `requiresHumanOversight: false` (consistent with L2 where only deployment mutations require approval, but inference and read operations do not).

The `registry.yaml` serves as the data product catalog, registering three data products (`ai_core_inference.yaml`, `embeddings.yaml`, `deployments.yaml`) under `ai-sdk-js-catalog`. It also documents an OData Vocabularies service dependency at `http://localhost:9150/mcp` with `vocabularies` entries for the UI, Common, Analytics, and PersonalData SAP vocabulary namespaces.

---

## Software Bill of Materials (SBOM)

### Published SDK Packages (v2.7.0 unless noted)

| Package | Description |
|---|---|
| `@sap-ai-sdk/core` | HTTP client, auth, streaming, model type catalogue |
| `@sap-ai-sdk/ai-api` | AI Core management API (generated OpenAPI client) |
| `@sap-ai-sdk/orchestration` | Orchestration Service — templating, filtering, masking, grounding, translation |
| `@sap-ai-sdk/foundation-models` | Direct foundation model inference (Azure OpenAI, etc.) |
| `@sap-ai-sdk/langchain` | LangChain-compatible wrappers for foundation models and orchestration |
| `@sap-ai-sdk/document-grounding` | Document Grounding Service — pipeline, vector, retrieval APIs |
| `@sap-ai-sdk/prompt-registry` | Prompt Registry — versioned template storage and retrieval |
| `@sap-ai-sdk/rpt` | SAP RPT model client (sap-rpt-1-small, sap-rpt-1-large) |

### Extended Infrastructure Packages (independent versions)

| Package | Version | Description |
|---|---|---|
| `@sap-ai-sdk/vllm` | 0.1.0 | vLLM on-premise LLM inference client with routing, health monitoring, retry |
| `@sap-ai-sdk/hana-vector` | 1.0.0 | HANA Cloud vector engine client for RAG/similarity search |
| `@sap-ai-sdk/btp-object-store` | 1.0.0 | BTP Object Store (S3-compatible) client |
| `@sap-ai-sdk/mcp-server` | 1.0.0 | MCP server exposing AI Core tools and Mangle reasoning |
| `@sap-ai-sdk/openai-server` | 1.0.0 | OpenAI-compatible proxy server for AI Core |

### Runtime Dependencies (core SDK packages)

| Dependency | Version | Role |
|---|---|---|
| `@sap-cloud-sdk/connectivity` | ^4.4.0 | BTP destination and service binding resolution |
| `@sap-cloud-sdk/http-client` | ^4.4.0 | HTTP execution with CSRF token support |
| `@sap-cloud-sdk/openapi` | ^4.4.0 | OpenAPI request builder base |
| `@sap-cloud-sdk/util` | ^4.4.0 | Error handling, header merging, URL utilities |
| `@langchain/core` | ^1.1.16 | LangChain base model interface (peer, langchain package) |
| `yaml` | ^2.8.2 | YAML parsing for orchestration specs |
| `zod` | ^4.3.6 | Runtime schema validation (prompt-registry) |
| `uuid` | ^13.0.0 | Message ID generation (langchain, mcp-server, openai-server) |

### Infrastructure Package Dependencies

| Dependency | Version | Package | Role |
|---|---|---|---|
| `@aws-sdk/client-s3` | ^3.500.0 | btp-object-store | S3 API client |
| `@aws-sdk/lib-storage` | ^3.500.0 | btp-object-store | Multipart upload |
| `@aws-sdk/s3-request-presigner` | ^3.500.0 | btp-object-store | Presigned URL generation |
| `@sap/hana-client` | ^2.19.0 | hana-vector | HANA Cloud native driver |
| `@modelcontextprotocol/sdk` | ^1.0.0 | mcp-server | MCP protocol implementation |
| `express` | ^4.18.2 | mcp-server, openai-server | HTTP server |
| `ws` | ^8.14.2 | mcp-server | WebSocket transport |
| `cors` | ^2.8.5 | openai-server | CORS middleware |
| `dotenv` | ^16.3.1 | mcp-server, openai-server | Environment variable loading |

### Build and Development Tooling

| Tool | Version | Role |
|---|---|---|
| TypeScript | ^5.9.3 (root), ^5.3.3 (infra) | Compiler |
| pnpm | 8+ (implied by lock) | Package manager and workspace |
| Jest | ^30.2.0 | Unit test runner |
| `@changesets/cli` | ^2.29.8 | Versioning and changelog |
| ESLint | ^9.39.2 | Linting (`@sap-cloud-sdk/eslint-config`) |
| Prettier | ^3.8.1 | Code formatting |
| `@sap-cloud-sdk/openapi-generator` | ^4.4.0 | OpenAPI client code generation |
| `orval` | ^8.4.2 | Additional code generation with Zod (prompt-registry) |
| `ts-jest` | ^29.4.6 | TypeScript Jest transformer |
| `nock` | ^14.0.11 | HTTP mocking for unit tests |
| `mock-fs` | ^5.5.0 | Filesystem mocking for unit tests |
| `tsup` | ^8.0.1 | Build tool for infra packages (vllm, hana-vector, btp-object-store) |

---

## Testing Architecture

The testing strategy is organized across three test packages. The `@sap-ai-sdk/type-tests` package performs compile-time TypeScript type checks to ensure public API types remain stable across versions — these are intentional TypeScript code snippets that must compile cleanly rather than tests that execute at runtime. The `@sap-ai-sdk/e2e-tests` package contains end-to-end tests requiring a live AI Core service binding. The `@sap-ai-sdk/smoke-tests` package provides lightweight integration tests for deployment validation.

Unit tests across the core SDK packages use Jest 30 with `ts-jest` v29 and the `--experimental-vm-modules` flag for ESM-compatible execution. HTTP calls are mocked with `nock` v14. Filesystem operations in the `@sap-cloud-sdk/util` layer are mocked with `mock-fs`. Snapshot tests in the orchestration package capture the serialized request payload structure to detect unexpected regressions in pipeline composition logic.

The root `jest.config.mjs` applies global configuration including `global-test-setup.mjs` and `global-test-teardown.mjs` scripts, and defines module name mapper overrides for path aliases. The `tsconfig.test.json` extends the root `tsconfig.json` with test-specific includes.

---

## Architecture Decision Records Summary

Four ADRs formally document key technical choices:

`adr/001-esm.md` records the decision to use ESM-only syntax in a "secret hybrid mode" — ESM imports throughout, but dependencies restricted to CJS or hybrid packages until a final ESM transition after GA + 1 year. The rationale was to benefit from ESM performance features (tree shaking, async loading) while maintaining CJS compatibility via `compile:cjs` scripts, without the ugliness of dynamic import wrappers.

`adr/002-project-structure.md` documents the monorepo layout decision.

`adr/003-history-maintenance.md` covers changelog maintenance using Changesets.

`adr/004-api-facade.md` is the most consequential for SDK consumers. It mandates that for manually-written client packages (`foundation-models`, `orchestration`), all generated OpenAPI types are hidden behind `internal.js` and only curated, stable wrapper types are exported publicly. This protects consumers from OpenAPI spec evolution. Exceptions (types used directly in sample code or documentation) are decided case by case.

---

## Security Posture

The following items warrant attention for production deployment or security review:

**Hardcoded deployment ID in `proxy.mg`.** The model alias mappings in `packages/openai-server/proxy.mg` reference a literal AI Core deployment ID (`dca062058f34402b`) for all model aliases including `gpt-4`, `gpt-4-turbo`, `gpt-3.5-turbo`, and the Claude variants. This deployment ID is repository-wide and would need to be replaced per-environment before deployment.

**Keyword-based routing is brittle.** The confidential data routing in `agent/ai_sdk_agent.py` relies on a hardcoded set of 16 financial keywords. Prompts that use synonyms, abbreviations, or non-English terms for the same concepts will not trigger vLLM routing and may inadvertently send confidential data to AI Core. A semantic classifier would be more robust in a production financial services context.

**`AICORE_SERVICE_KEY` in environment.** The `getAiCoreServiceKeyFromEnv()` function in `core/src/context.ts` explicitly warns that service key injection via environment variable is for local development only. Production deployments should use the `getServiceBinding('aicore')` path via VCAP_SERVICES. The warning is logged but does not block execution.

**No authentication on MCP server.** The `mcp-server` README and configuration contain no mention of API key or token authentication for the MCP endpoints. As the MCP server exposes `ai_core_chat`, `list_deployments`, `orchestration_run`, and `mangle_query` tools — all of which cost AI Core quota — unauthenticated deployment would be a billing and data exposure risk.

**`kuzu/` vendored artefact.** The root `kuzu/` directory contains 2073 items. Kuzu is an embedded graph database engine. No package in the pnpm workspace declares `kuzu` as a dependency, and it is not referenced in any `package.json`. This appears to be a vendored or checked-in binary artefact that warrants verification — either it should be in `.gitignore`, or its purpose and provenance should be documented.

**AWS SDK credential exposure risk.** The `@sap-ai-sdk/btp-object-store` accepts `accessKeyId` and `secretAccessKey` as inline configuration fields and reads them from `BTP_OBJECT_STORE_ACCESS_KEY` / `AWS_ACCESS_KEY_ID` environment variables. In VCAP_SERVICES-based configuration this is mitigated, but any code path that logs the configuration object risks credential exposure.

---

## Integration Topology

The SDK supports three primary deployment patterns.

In the simplest pattern, a Node.js or TypeScript application installs one or more SDK packages from npm, configures an AI Core service binding (via VCAP_SERVICES in Cloud Foundry or an `AICORE_SERVICE_KEY` in `.env` locally), and calls `OrchestrationClient.chatCompletion()` or `AzureOpenAiChatClient.chat()` directly. No infrastructure components are needed.

In the standard enterprise pattern, the application additionally uses `@sap-ai-sdk/document-grounding` to manage document repositories and `@sap-ai-sdk/prompt-registry` to store reusable system prompt templates, then references both via the orchestration pipeline configuration. This enables centralized prompt governance and RAG-augmented responses without application-side retrieval logic.

In the full agentic platform pattern (illustrated by the `mcp-server`, `openai-server`, `agent/`, and `data_products/` artifacts), the `@sap-ai-sdk/mcp-server` runs as a sidecar exposing AI Core tools to MCP-compliant agents, the `@sap-ai-sdk/openai-server` runs as an OpenAI-compatible proxy for tools that cannot natively speak to AI Core, the `AISdkAgent` Python process applies governance routing before forwarding to either the AI Core MCP endpoint or the on-premise `@sap-ai-sdk/vllm` MCP endpoint, and the OData Vocabularies service on port 9150 provides term lookup and TypeScript type generation capabilities to the agent's `VocabularyClient`. This pattern is appropriate for financial services or other regulated domains where prompt content classification and on-premise fallback are regulatory requirements.

---

## Assessment Summary

The SAP Cloud SDK for AI (JavaScript) is a well-structured, production-oriented SDK for SAP AI Core integration. The core eight packages are consistent in layout, test coverage, and API design. The ESM-first decision with optional CJS compilation is architecturally forward-looking and the API facade ADR effectively protects consumers from OpenAPI churn. The LangChain integration is comprehensive and current against the v0.3/v1.x LangChain ecosystem.

The five extended infrastructure packages (`vllm`, `hana-vector`, `btp-object-store`, `mcp-server`, `openai-server`) are independently versioned and somewhat less mature (0.1.0 or 1.0.0 versus the core 2.7.0), with minimal test coverage visible in their package layouts. Their inclusion in the same repository without pnpm workspace registration suggests they are maintained as companion tools rather than officially shipped SDK packages.

The Python governance agent and ODPS data product descriptors establish a coherent governance narrative — hybrid routing with on-premise fallback for confidential data, L2 autonomy with human approval for destructive operations, and no-storage audit log policy. However, the keyword-based routing classifier and the hardcoded deployment ID in `proxy.mg` would need hardening before production use at scale.

The five pre-production items that require attention are: (1) the `kuzu/` vendored artefact should be investigated and either documented or removed; (2) the MCP server should have authentication middleware added before any network-accessible deployment; (3) the confidential data classifier in `agent/ai_sdk_agent.py` should be upgraded from keyword matching to a semantic classifier for production financial data governance; (4) the hardcoded deployment ID in `proxy.mg` must be externalised to environment variables; and (5) the infrastructure packages (`vllm`, `hana-vector`, `btp-object-store`) should be registered in `pnpm-workspace.yaml` or explicitly documented as external to the core workspace if that is intentional.
