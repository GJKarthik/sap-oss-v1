# Technical Assessment: `BDC AIPrompt Streaming`

**Package:** `bdc-aiprompt-streaming` v1.0.0
**Internal Name:** `ai-core-streaming`
**Author:** SAP SE
**License:** Apache-2.0 (REUSE.toml, SPDX annotation `2024-2026 SAP SE or an SAP affiliate company`)
**Runtime requirements:** Zig 0.14.0, Python ≥ 3.11 (MCP server), Mojo (stream processor FFI)

---

## Purpose and Positioning

BDC AIPrompt Streaming is a high-performance, wire-protocol-compatible streaming broker for AI prompt workloads running on SAP Business Technology Platform (BTP). Its primary architectural identity is a **reimplementation of the Apache Pulsar binary wire protocol (v21)** in Zig, with SAP HANA Cloud substituted for Apache BookKeeper as the durable message storage backend. The service is not a client library or SDK wrapper — it is a full server-side broker that accepts producer and consumer connections on the standard Pulsar binary port (6650/6651 TLS) and HTTP admin port (8080/8443), making it a drop-in infrastructure replacement for Apache Pulsar in BTP-hosted deployments.

The service occupies a specific role in the broader SAP OSS AI fabric: it is the **external AI Core inference backend** for public and internal data. The mesh-wide routing policy, declared in both the Mangle Datalog rule files under `mesh/` and the `MeshRouter` Python class, establishes that requests carrying public or internal security classifications are forwarded to `ai-core-streaming` on port 9190, while confidential or restricted payloads are diverted to a local vLLM instance. The service therefore acts as the gateway to SAP AI Core's hosted model fleet (GPT-4, GPT-4 Turbo, Claude 3 Sonnet/Opus, Anthropic Claude 3) for all non-sensitive workloads across the twelve services registered in `mesh/registry.yaml`.

The repository spans four implementation languages — Zig (broker core, GPU acceleration, HANA storage), Python (MCP server, OpenAI API handlers, mesh router, agent), Mojo (SIMD-accelerated stream processing FFI), and Mangle Datalog (governance, routing, and integration rules) — making it the most polyglot single service in the observed SAP OSS corpus. This multi-language architecture follows the SAP NIM (Native Inference Module) pattern documented in inline comments: Zig for system-level performance, Mojo for SIMD hot-paths, Python for API surface and orchestration, and Mangle for declarative policy.

---

## Repository Layout

```
ai-core-streaming/
├── zig/                        # Zig broker core (main implementation)
│   ├── src/
│   │   ├── main.zig            # Broker entrypoint, config, signal handling
│   │   ├── standalone.zig      # Standalone mode (broker + local metadata)
│   │   ├── broker/             # Core broker logic
│   │   ├── protocol/           # AIPrompt (Pulsar) binary protocol v21
│   │   ├── hana/               # HANA ODBC database layer
│   │   ├── sap/                # SAP config, HANA connector, TOON pointer
│   │   ├── gpu/                # GPU acceleration (CUDA, Metal, WebGPU)
│   │   ├── storage/            # Managed ledger abstraction
│   │   ├── http/               # HTTP admin API server
│   │   ├── auth/               # XSUAA authentication
│   │   ├── flight/             # Apache Arrow Flight endpoint
│   │   ├── fabric/             # Blackboard, RDMA channel (fabric integration)
│   │   ├── metrics/            # Prometheus metrics + HTTP server
│   │   ├── middleware/         # Middleware chain
│   │   ├── resilience/         # Circuit breaker, retry
│   │   ├── classification/     # Data classifier
│   │   ├── gen/                # SDK-generated connector types
│   │   └── tests/              # Integration tests
│   ├── deps/                   # llama.zig, cuda headers
│   └── build.zig               # Zig build system
├── mojo/                       # Mojo stream processing
│   └── src/
│       ├── ffi_exports.mojo    # C-ABI exports for Zig hot-path linking
│       ├── stream_processor.mojo  # SIMD stream processing primitives
│       └── streaming.mojo      # Streaming orchestration
├── mangle/                     # Mangle Datalog rules
│   ├── a2a/                    # Agent-to-Agent (A2A) protocol rules
│   │   ├── streaming_facts.mg  # Core entity declarations
│   │   ├── streaming_rules.mg  # Routing, delivery, ACK rules
│   │   └── mcp.mg              # MCP service registry and intent routing
│   ├── connectors/
│   │   ├── aiprompt_streaming.mg  # Service connector facts (1,501 lines)
│   │   └── integration.mg      # HANA tables, LLM gateway, health rules
│   ├── domain/
│   │   ├── agents.mg           # Agent config, routing, governance rules
│   │   └── data_products.mg    # ODPS 4.1 data product rules
│   ├── contracts/
│   │   └── contract_tests.mg   # Contract verification rules
│   └── dspy_streaming.mg       # DSPy self-improvement pipeline rules
├── mesh/                       # Service mesh configuration
│   ├── registry.yaml           # Central registry: 12 services
│   ├── routing_rules.mg        # LLM routing rules (security-based)
│   ├── governance_rules.mg     # MGF-Agentic-AI and GDPR governance
│   └── base_agent.py           # Base agent class
├── openai/                     # OpenAI-compatible HTTP API
│   ├── router.py               # MeshRouter (6-priority routing logic)
│   ├── chat_completions.py     # POST /v1/chat/completions handler
│   ├── completions.py          # POST /v1/completions handler
│   ├── embeddings.py           # POST /v1/embeddings handler
│   └── models.py               # GET /v1/models handler
├── agent/                      # Agent layer
│   ├── aicore_streaming_agent.py  # Security-routing agent with MangleEngine
│   └── mesh_coordinator.py     # Multi-service mesh orchestrator
├── mcp_server/
│   └── server.py               # MCP server (JSON-RPC 2.0, port 9190)
├── data_products/
│   ├── registry.yaml           # ODPS 4.1 catalog
│   └── aicore_streaming_service.yaml  # Product definition
├── deploy/
│   ├── aicore/                 # SAP AI Core deployment descriptors
│   └── k8s/                    # Kubernetes manifests (HPA, PDB)
├── conf/
│   └── standalone.conf         # Java-properties broker configuration
├── Dockerfile                  # Multi-stage: Zig builder + Debian slim runtime
└── REUSE.toml                  # SPDX license metadata
```

---

## Zig Broker Core

The primary compiled artefact is `aiprompt-broker`, built from `zig/src/main.zig` using `zig build -Doptimize=ReleaseFast`. The `main()` function parses CLI flags (`--config`, `--help`, `--version`), loads the `BrokerConfig` struct with a three-tier precedence (defaults → environment variables → file), initialises the `Broker` struct, registers POSIX signal handlers for `SIGINT`/`SIGTERM`, starts the broker, and blocks on `waitForShutdown()`. A secondary `aiprompt-standalone` binary (`src/standalone.zig`) bundles the broker with local metadata storage for single-node operation without an external ZooKeeper/etcd equivalent. Two additional CLI binaries are produced: `aiprompt-client` (producer/consumer CLI) and `aiprompt-admin` (administrative operations).

`BrokerConfig` maps directly to the Java-properties format used by `conf/standalone.conf`, supporting the same key names as Apache Pulsar (e.g., `clusterName`, `brokerServicePort`, `numIOThreads`, `managedLedgerStorageClassName`). The config parser is a hand-written line-by-line key=value parser with a 1 MB file size guard. Environment variable overrides use the `AIPROMPT_` prefix namespace (e.g., `AIPROMPT_BROKER_PORT`, `AIPROMPT_IO_THREADS`) plus `HANA_HOST`, `HANA_PORT`, `HANA_SCHEMA`, `HANA_USER`, `HANA_PASSWORD`, and `HANA_PASSWORD_FILE` for credential management without CLI argument exposure.

The `build.zig` declares eighteen Zig modules that compose the broker, including: `connector_types` (SDK-generated types), `protocol` (AIPrompt binary protocol), `storage` (managed ledger), `hana` (HANA database layer), `broker` (core broker), `flight` (Apache Arrow Flight), `blackboard` (fabric shared state), `rdma` (RDMA channel for high-performance networking), `classification` (data classifier), `metrics` (Prometheus), `metrics_http` (Prometheus HTTP endpoint), `client` (client library), `llama` (llama inference engine), and `sap_config` / `hana_connector` (SAP standard configuration modules). The broker executable links against libc and includes the `deps/cuda` headers, enabling the CUDA backend compilation path on Linux.

---

## AIPrompt Binary Protocol (v21)

`zig/src/protocol/aiprompt_protocol.zig` implements the Apache Pulsar binary wire protocol at protocol version 21. The protocol constants are: magic number `0x0e01`, maximum frame size 5.5 MB (5 MB payload + 512 KB overhead). The `CommandType` enum enumerates all 38 Pulsar command types from `CONNECT (2)` through `ACK_RESPONSE (38)`, including `SUBSCRIBE`, `PRODUCER`, `SEND`, `MESSAGE`, `ACK`, `FLOW`, transaction commands, schema commands, and authentication challenge/response. The `ServerError` enum covers all Pulsar server error codes including `PersistenceError`, `AuthenticationError`, `AuthorizationError`, `TopicTerminatedError`, and `ProducerBusy`. A CRC32-C checksum module (`crc32c.zig`) provides frame integrity verification, and a minimal Protobuf encoder/decoder (`protobuf.zig`) handles the wire-format framing of commands.

The schema registry module (`protocol/schema_registry.zig`, 24 KB) implements the Pulsar schema compatibility strategies: `FULL`, `FORWARD`, `BACKWARD`, and `NONE`. The `standalone.conf` defaults to `FULL` compatibility strategy (`schemaCompatibilityStrategy=FULL`) with auto-update enabled and validation not strictly enforced, allowing schema evolution while maintaining bi-directional compatibility.

---

## SAP HANA Storage Backend

The HANA integration replaces Apache BookKeeper as the durable storage layer. `zig/src/hana/hana_db.zig` implements the HANA ODBC database layer with explicit security hardening at the Zig level: `validateIdentifier()` enforces a strict character whitelist (`a-z`, `A-Z`, `0-9`, `_`, `-`, `/`, `:`, `.`) on all table and column names used in queries, and `escapeString()` performs single-quote doubling and backslash escaping. `HanaConfig` holds the connection parameters, defaulting to port 443 (HANA Cloud HTTPS), TLS enabled, connection pool min 1 / max 10, and a 30-second connect timeout. `zig/src/hana/odbc_connection.zig` (31 KB) implements the ODBC binding layer, and `zig/src/sap/hana_connector.zig` (20 KB) provides the higher-level SAP-specific connection abstraction.

The Mangle file `mangle/connectors/integration.mg` declares the five HANA tables that form the broker's persistent state:

| Table | Type | Purpose |
|---|---|---|
| `AIPROMPT_MESSAGES` | `message_store` | Message payload storage, partitioned by `topic_name, partition_id` |
| `AIPROMPT_CURSORS` | `cursor_store` | Subscription cursor positions |
| `AIPROMPT_TOPICS` | `metadata_store` | Topic metadata |
| `AIPROMPT_SUBSCRIPTIONS` | `metadata_store` | Subscription metadata, partitioned by `topic_name` |
| `AIPROMPT_TRANSACTIONS` | `transaction_store` | Two-phase commit transaction state |
| `AIPROMPT_LEDGERS` | `ledger_store` | Ledger lifecycle metadata |

The connection pool is configured in `integration.mg` at min 5 / max 50 connections with a 30-second connection timeout and 5-minute idle timeout. Service readiness (`service_ready/1`) is declared as a Mangle rule requiring `hana_connected/1`, which in turn requires all four primary tables to exist (`all_tables_exist/1`). The HANA destination name is `btp-destination-hana`, integrating with the SAP BTP Destination Service for credential management.

For tiered storage, `integration.mg` also declares an Object Store target at `https://objectstore.hana.ondemand.com` in region `eu10`, bucket `aiprompt-tiered-storage`, using BTP destination `btp-destination-objectstore`. Ledger offload is triggered when a ledger enters `Closed` state (`can_offload/2` rule). The `standalone.conf` sets the offload threshold at 1 GB and a 1-hour deletion lag after offload.

---

## GPU Acceleration Layer

The `zig/src/gpu/` directory contains 18 files implementing a comprehensive GPU acceleration framework following what the code comments call the "SAP NIM pattern". Three hardware backends are provided: CUDA (`cuda_backend.zig`, `cuda_bindings.zig`, `cuda_kernels.zig`), Metal for macOS/iOS (`metal_backend.zig`, `metal_bindings.zig`, `metal_shaders.zig`), and WebGPU for cross-platform deployments (`webgpu_backend.zig`). The backend abstraction (`gpu/backend.zig`) selects the appropriate backend at compile time. Shared infrastructure includes `memory_pool.zig` (13 KB), `kernel_autotuner.zig` (12 KB), `zero_copy_pipeline.zig` (25 KB), `multi_gpu_manager.zig` (27 KB), and NCCL bindings (`nccl_bindings.zig`, 22 KB) for multi-GPU collective operations.

The `CudaConfig` struct configures: maximum 4 concurrent CUDA streams, 128 MB compute buffer, device ordinal 0, and INT8 Tensor Core math enabled (optimised for NVIDIA Turing/T4 GPUs). The `CudaBackend` struct tracks kernel dispatches and total elements processed via atomic counters. The `KernelResult` struct reports execution time in nanoseconds, elements processed, and whether GPU utilisation occurred. The `kernel_autotuner.zig` provides runtime tuning of kernel launch parameters, and `zero_copy_pipeline.zig` implements pinned-memory pipelines for minimising host-device copy overhead.

---

## Mojo Stream Processing FFI

`mojo/src/ffi_exports.mojo` compiles to a shared library (`libmojo_streaming.so`/`.dylib`) that the Zig broker links dynamically for SIMD-accelerated hot paths. The module exports a C-ABI (`c_int`, `c_int64`, `c_float` type aliases) with `mojo_init()` as the initialisation entry point, which loads the embedding model in order: (1) SAP AI Core embedding service, (2) local `sentence-transformers` e5-small model, (3) mock fallback. The `_embedding_dim` is set to 384 (e5-small default).

`mojo/src/stream_processor.mojo` defines the core stream processing primitives using Mojo's SIMD intrinsics: `SIMD_WIDTH = 8` (AVX-512), `BATCH_SIZE = 256`, `EMBEDDING_DIM = 384`. Primitive types include `StreamMessage` (carrying `message_id`, `ledger_id`, `entry_id`, `topic`, `key`, payload pointer, timestamps, and properties) and `ProcessingResult`. The `StreamFunction` trait defines the `process()` and `get_name()` interface, with concrete implementations `MapFunction[T]` (one-to-one transformation), `FilterFunction[P]` (predicate filtering), and reduce operations. The `vectorize()` and `parallelize()` Mojo standard library functions are used for SIMD-parallel batch processing. `mojo/src/streaming.mojo` provides the higher-level streaming orchestration layer that consumes these primitives.

---

## Mangle Datalog Rules

The repository contains eight Mangle rule files across four logical layers: A2A streaming protocol facts and rules, connector integration configuration, domain governance and data products, and mesh-wide routing and governance shared with the rest of the SAP OSS fabric.

### `mangle/a2a/streaming_facts.mg` — Core Entity Declarations

This file contains exclusively `Decl` statements (no rules), defining the complete fact schema for the broker state. Fourteen entity types are declared: `message` (8-arity: `message_id`, `topic`, `partition`, `ledger_id`, `entry_id`, `publish_time`, `producer_name`, `sequence_id`), `message_payload` (with `compression_type`), `message_property` (key-value metadata), `message_schema` (schema versioning), `topic` (with `persistence_type` and `num_partitions`), `topic_stats`, `topic_policy`, `producer`, `producer_stats`, `consumer` (with `subscription` linkage), `consumer_stats`, `consumer_permits`, `subscription` (with `subscription_type`: Exclusive, Shared, Failover, Key_Shared), `subscription_cursor` (mark-delete position tracking), `subscription_backlog`, `ledger` (with `state`: Open, Closed, Offloaded), `ledger_entry`, `broker` (with `state`: Active, Draining, Offline), `broker_load`, `topic_owner`, `namespace`, `tenant`, `transaction` (ACID state: Open, Committing, Committed, Aborting, Aborted), `txn_produced`, `txn_acked`, `auth_principal`, `auth_role`, `connection`, `schema`, and `schema_compatibility`.

### `mangle/a2a/streaming_rules.mg` — Delivery, Routing, and Lifecycle Rules

This file defines the operational intelligence of the broker as 45 Datalog rules. Message routing: `message_deliverable/3` joins `message` with `subscription_cursor` via `position_after/4` (strict ledger:entry ordering). Consumer selection: `select_consumer_exclusive/3` picks the oldest consumer by `min(CreateTime)` for exclusive and failover subscription types; `select_consumer_shared/3` selects any consumer with available permits for round-robin distribution. Backlog management: `has_backlog/2` and `backlog_exceeded/3` track consumer lag; `subscription_healthy/2` fires when backlog is below 10,000 messages. Topic ownership: `topic_available/1` requires the owning broker to be in Active state; `topic_needs_reassignment/1` fires when the owning broker is not Active. Load balancing: `broker_overloaded/1` at CPU > 90% or memory > 90%; `broker_underloaded/1` at CPU < 30% and memory < 30%; `topic_should_move/3` triggers rebalancing from overloaded to underloaded brokers. Retention: `ledger_deletable/2` fires when a ledger is Closed and all subscription cursors have advanced past it; `message_expired/2` implements TTL via `topic_policy(Topic, "messageTTLSeconds", TTLStr)`. Transactions: `transaction_can_commit/2` requires active and non-timed-out state. Authorization: `can_produce/2`, `can_consume/2`, `can_admin/2` implement role-based access control with admin role bypass; `connection_authorized/3` applies per-connection checks. Health: `cluster_healthy/1` requires at least one healthy broker; `system_ready/0` requires cluster health and HANA connectivity. Schema: `schema_compatible/3` and `can_evolve_schema/2` enforce schema compatibility strategies.

### `mangle/a2a/mcp.mg` — MCP Service Registry and Intent Routing

This file declares the MCP service registry and tool routing for the A2A (Agent-to-Agent) communication layer. Three services are registered: `streaming-chat`, `streaming-generate`, and `streaming-events`, all bound to `http://localhost:9190/mcp`. Intent routing resolves `/stream_chat` → `streaming-chat`, `/stream_generate` → `streaming-generate`, and `/events` → `streaming-events`. Seven tool-to-service mappings are declared: `streaming_chat`, `streaming_generate`, `list_deployments` → `streaming-chat`; `stream_status`, `start_stream`, `stop_stream`, `publish_event` → `streaming-events`; `mangle_query` → `streaming-chat`. Streaming configuration facts set `max_tokens = 1024` for chat, `max_tokens = 256` for generation, and `timeout = 120` seconds as default.

### `mangle/connectors/aiprompt_streaming.mg` — Service Connector (1,501 lines)

This is the largest Mangle file in the repository (1,501 lines) and serves as the authoritative connector definition for the broker. It declares service metadata (`streaming_service/4` with protocol version 21), five endpoint configurations (binary 6650, binary TLS 6651, HTTP admin 8080, HTTPS admin 8443, WebSocket 8080), broker configuration facts, consumer and producer configuration, topic management rules, and detailed observability facts for Prometheus metric generation. This file functions as the machine-readable service contract, consumed by other services in the SAP OSS fabric to discover broker capabilities and integration parameters.

### `mangle/connectors/integration.mg` — HANA and ML Integration Rules

Beyond the table declarations described in the HANA section, this file defines: service readiness rules (`service_ready/1`, `hana_connected/1`, `all_tables_exist/1`); storage operation guards (`can_persist_message/1`, `can_read_message/1`, `hana_pool_available/1`); tiered storage eligibility (`tiered_storage_available/1`, `can_offload/2`); ML pipeline availability (`ml_pipeline_available/1`, `can_ml_process/2`), requiring both Mojo and ML pipeline enabled in service config plus a reachable LLM gateway (`http://ai-core-privatellm:8080`, default model `phi-2`); storage metrics rules; five compliance predicates (`service_hana_compliant/1`, `service_storage_compliant/1`, `service_objectstore_compliant/1`, `service_ml_compliant/1`, `service_fully_compliant/1`); three health status states (healthy, degraded, unhealthy) for the overall service; four component health rules for HANA, object store, ML pipeline, and Arrow Flight; and fabric integration rules (`can_exchange_arrow/2`, `can_share_cursor_state/1`) for cross-service data exchange via shared blackboard.

### `mangle/domain/agents.mg` — Agent Governance Rules

This file includes external rule files via `include "../../../regulations/mangle/rules.mg"` (SAP global regulations knowledge base) and `include "data_products.mg"` (ODPS product rules). Agent configuration declares `aicore-streaming-agent` at autonomy level L2, bound to MCP endpoint `http://localhost:9190/mcp` with default backend `aicore`. Tool permissions: `stream_complete`, `batch_complete`, `health_check`, `list_models`, `mangle_query` are permitted without approval; `change_config` and `update_credentials` require human approval (`agent_requires_approval/2`). Routing rules classify requests as public (no confidential or restricted content), internal (contains "internal" but not "confidential"), confidential (contains "confidential", "customer", or "personal"), or restricted (contains "restricted" or "classified"), routing the first two to AI Core and the third to vLLM, blocking the fourth. Safety controls: `guardrails_active/1` is asserted for `stream_complete` and `batch_complete`. Audit: all permitted tools require audit logging at the `standard` level.

### `mangle/domain/data_products.mg` — ODPS 4.1 Data Product Rules

Generated from the ODPS 4.1 product definition, this file declares: `data_product/3` with `aicore-streaming-service-v1` at `public` security class and `security-based` routing; two output ports (`streaming-inference` public, `batch-inference` internal); one input port (`prompts` internal); three `data_product_route/2` rules (public/internal → `aicore-ok`, confidential → `vllm-only`, restricted → `blocked`); prompting policy (max_tokens 4096, temperature 0.7, streaming true); system prompt text; two regulatory frameworks (`MGF-Agentic-AI`, `AI-Agent-Index`); autonomy level L2 with human oversight required; three safety controls; and quality SLAs (99.9% availability, 500 ms p95 latency, 1,000 req/min throughput).

### `mangle/dspy_streaming.mg` — DSPy Self-Improving Pipeline

This file configures a DSPy (Demonstrate-Search-Predict) self-improvement pipeline for streaming quality tracking. `dspy_streaming_config/3` sets: max 1,000 examples in the accumulator, minimum quality score 0.5 to retain an example, quality history window of 100, improvement threshold of 5%. `dspy_streaming_threshold/3` defines metric weights: correctness (threshold 0.5, weight 0.35), similarity (0.7, 0.25), safety (0.9, 0.25), latency (0.5, 0.15). Five seed examples are declared for bootstrapping. Three similarity test pairs validate embedding quality. Six streaming event types are declared (`example_generated`, `example_filtered`, `quality_improved`, `quality_degraded`, `optimization_started`, `optimization_completed`). Three `dspy_fabric_integration/3` facts route DSPy events to the shared fabric at `/api/dspy/examples`, `/api/dspy/quality`, and `/api/dspy/optimization` endpoints.

### `mesh/governance_rules.mg` and `mesh/routing_rules.mg` — Mesh-Wide Shared Rules

These files are shared across all twelve services in the SAP OSS mesh. `governance_rules.mg` defines: four regulatory frameworks (MGF-Agentic-AI, AI-Agent-Index, GDPR-Data-Processing, Infrastructure-Security); four autonomy levels L1–L4 with numeric values; service-level autonomy assignments for all twelve services (`ai-core-streaming` at L2); human oversight requirement for services at L2 and below; six always-requires-approval actions (`delete_data`, `write_production`, `train_model`, `deploy_model`, `modify_config`, `grant_access`); six safety controls; required safety controls per data security class (public requires guardrails+monitoring; restricted requires all six including encryption); five data retention policies (0 to 365 days); service-specific retention assignments (`ai-core-streaming` at 30 days standard); PII indicator keywords; four audit levels (none/minimal/standard/full) with service assignments (`ai-core-streaming` at standard); seven audit fields; and OpenAI-compatible error codes (400/401/403/404/429/500/503) with governance-specific errors (`blocked`→403, `pending_approval`→202, `audit_required`→200).

`mesh/routing_rules.mg` defines: four security classes with numeric levels (public=1, internal=2, confidential=3, restricted=4); two backend definitions (`ai-core-streaming` external at `http://localhost:9190`, `vllm` local at `http://localhost:9180`); core routing rules routing Level ≤ 2 to AI Core and Level ≥ 3 to vLLM; content-based routing with eleven confidential keywords and four restricted keywords; twelve service-specific routing overrides (e.g., `data-cleaning-copilot`, `gen-ai-toolkit-hana`, `ai-core-pal` → vllm-only; `ai-sdk-js`, `cap-llm-plugin` → hybrid; `ai-core-streaming` → external); model-to-backend mappings for eleven models (GPT-4, GPT-4 Turbo, GPT-3.5-Turbo, Claude 3 Sonnet/Opus, Anthropic Claude 3 → ai-core-streaming; LLaMA 3.1 70B/8B, CodeLLaMA 34B, Mistral 7B, Mixtral 8×7B → vllm); three model aliases for confidential routing (`gpt-4-confidential` → `llama-3.1-70b`); and routing audit rules logging decision reason (service-policy or content-detection).

---

## Python MCP Server

`mcp_server/server.py` implements a JSON-RPC 2.0 MCP server running on port 9190 using Python's built-in `http.server.HTTPServer`. The server exposes seven tools:

| Tool | Description |
|---|---|
| `streaming_chat` | Stream chat completion from AI Core (POST to AI Core `/chat/completions`) |
| `streaming_generate` | Stream text generation from AI Core |
| `list_deployments` | List available AI Core deployments via REST API |
| `stream_status` | Get status of active streaming sessions |
| `start_stream` | Start a new streaming session for a deployment |
| `stop_stream` | Terminate an active streaming session |
| `publish_event` | Publish an event to a named stream |
| `mangle_query` | Query the embedded Mangle reasoning engine |

Three MCP resources are registered: `streaming://deployments` (AI Core deployment list), `streaming://active` (active stream registry), and `mangle://facts` (Mangle fact store). The `MCPRequest` and `MCPResponse` classes wrap JSON-RPC 2.0 message structure. AI Core authentication uses OAuth 2.0 client credentials flow with token caching (`_cached_token`), refreshing 60 seconds before expiry. The `get_config()` function reads `AICORE_CLIENT_ID`, `AICORE_CLIENT_SECRET`, `AICORE_AUTH_URL`, `AICORE_BASE_URL` (or `AICORE_SERVICE_URL`), and `AICORE_RESOURCE_GROUP` from environment. Request size is bounded at 1 MB (`MCP_MAX_REQUEST_BYTES`), tool output at 8,192 tokens (`MCP_MAX_TOOL_TOKENS`), and event streams at 1,000 events (`MCP_MAX_STREAM_EVENTS`). CORS is controlled via `CORS_ALLOWED_ORIGINS` (default: `http://localhost:3000`, `http://127.0.0.1:3000`).

---

## OpenAI-Compatible HTTP API Layer

The `openai/` directory implements a full OpenAI API surface for the mesh gateway role. `MeshRouter` in `router.py` implements a six-priority routing decision chain:

1. **Forced backend** via `X-Mesh-Routing` header override
2. **Service-specific routing** by `service_id` parameter (hardcoded policy table)
3. **Security class routing** by `security_class` parameter (public/internal → ai-core-streaming, confidential/restricted → vllm)
4. **Model alias resolution** (e.g., `gpt-4-confidential` → `llama-3.1-70b` + vllm)
5. **Model-based routing** (direct model→backend table lookup)
6. **Content-based routing** (scan for eleven confidential keywords in message/prompt/embedding input)
7. **Default** (ai-core-streaming)

`ChatCompletionsHandler` (`chat_completions.py`) handles `POST /v1/chat/completions` with full OpenAI request/response format including `tools` and `tool_choice` fields for function calling. `CompletionsHandler` (`completions.py`) handles legacy `POST /v1/completions`. `EmbeddingsHandler` (`embeddings.py`) handles `POST /v1/embeddings`. `ModelsHandler` (`models.py`) handles `GET /v1/models`, enumerating all eleven registered models from both backends. All handlers accept the `stream: true` SSE streaming mode for chat and completions.

---

## Agent Layer

### `AICoreStreamingAgent` (`agent/aicore_streaming_agent.py`)

This Python agent wraps the routing logic in a `MangleEngine` stub (a pure-Python reimplementation of the governance predicates from `mangle/domain/agents.mg`) and exposes `invoke()` for async prompt execution and `check_governance()` for synchronous routing decisions. The `invoke()` lifecycle is: (1) `block_request` predicate check → 403 response if restricted keywords present; (2) `route_to_vllm` / `route_to_aicore` predicate resolution; (3) `requires_human_review` check for the specified tool → 202 pending_approval if triggered; (4) `safety_check_passed` for the tool → blocked if not in permitted set; (5) `get_prompting_policy` to retrieve system prompt, max_tokens (4096), temperature (0.7), streaming flag; (6) MCP JSON-RPC `tools/call` invocation. Every invocation path records an audit entry (`_log_audit`) containing timestamp, agent identity, status, tool, backend, prompt hash (not prompt content), and prompt length.

### `MeshCoordinator` (`agent/mesh_coordinator.py`)

The mesh coordinator is the top-level orchestrator for multi-service workflows. It loads `mesh/registry.yaml` at startup, instantiates all four OpenAI handlers (chat, completions, embeddings, models), and provides: `list_services()`, `get_service(id)`, `discover_by_capability(capability)`, `discover_by_type(type)`, and `get_backends()` for service discovery. The coordinator delegates all routing decisions to `MeshRouter` and exposes the same OpenAI API surface, making it a unified mesh-level API gateway across all twelve registered services.

---

## Service Mesh Registry

`mesh/registry.yaml` is the central service registry for the SAP OSS mesh. It registers twelve services spanning three categories:

**Infrastructure backends:**
- `ai-core-streaming` — external LLM backend, security class: public, models: GPT-4, GPT-4 Turbo, Claude 3 Sonnet, Anthropic Claude 3
- `vllm` — local LLM backend, security class: restricted, models: LLaMA 3.1 70B, CodeLLaMA 34B, Mistral 7B

**SAP AI services:**
- `ai-sdk-js` (port 8080) — SAP AI SDK for JavaScript, hybrid routing
- `cap-llm-plugin` (port 8081) — CAP LLM Plugin, hybrid routing
- `langchain-hana` (port 8082) — LangChain HANA vector store, schema-based routing
- `gen-ai-toolkit-hana` (port 8083) — Gen AI Toolkit, vllm-only
- `ai-core-pal` (port 8084) — ML analytics (PAL), vllm-only
- `data-cleaning-copilot` (port 8085) — Data cleaning with PII detection, vllm-only
- `elasticsearch` (port 8086) — Search integration, index-based routing
- `odata-vocabularies` (port 8087) — OData metadata, aicore-default
- `ui5-webcomponents-ngx` (port 8088) — Frontend AI assistance, aicore-default
- `world-monitor` (port 8089) — External data monitoring, content-based routing

Governance metadata: three frameworks (MGF-Agentic-AI, AI-Agent-Index, GDPR-Data-Processing), four autonomy levels L1–L4, audit enabled with 90-day retention, requests logged but responses not logged by default.

---

## Kubernetes Deployment

`deploy/k8s/` contains Kubernetes manifests for production deployment. The `Dockerfile` performs a two-stage build: a `debian:bookworm-slim` Zig builder stage installing Zig 0.14.0 directly from `ziglang.org`, followed by a `debian:bookworm-slim` runtime image. The runtime image: creates a non-root `pulsar:pulsar` user and group; creates `/opt/pulsar/{bin,conf,data,logs}` directories; copies compiled binaries from the builder; sets `PULSAR_HOME=/opt/pulsar`; exposes ports 6650, 6651, 8080, 8443; and runs a health check against `http://localhost:8080/health` at 30-second intervals with a 60-second start period. The default `CMD` is `bdc-aiprompt-streaming`.

The `deploy/aicore/` directory contains SAP AI Core deployment descriptors for hosting the Python MCP server (`mcp_server/server.py`) and OpenAI handler layer as a managed AI Core deployment, separate from the Zig broker which runs as a standalone BTP service or in Kubernetes.

---

## Data Product Registry (ODPS 4.1)

`data_products/registry.yaml` is an ODPS 4.1 catalog with catalog ID `aicore-streaming-catalog`. The SAP AI Experience metadata references tier `ai_core` and service `ai-shared-fabric`, linking to `sap-ai-experience-map.yaml`. Global policies set `defaultSecurityClass: public` and `defaultLLMRouting: external`. Two LLM backends are registered: `aicore` for security classes public and internal (models: `anthropic-claude-3`, `gpt-4`, endpoint `http://localhost:9190/mcp`), and `vllm` as fallback for confidential and restricted (model: `llama-3.1-70b`, endpoint `http://localhost:9180/mcp`).

`data_products/aicore_streaming_service.yaml` defines the single data product `aicore-streaming-service-v1` v1.0.0 with:
- **Data security class:** `public`, governance class: `infrastructure`
- **LLM routing policy:** security-based with four routing rules (public→aicore, internal→aicore, confidential→vllm, restricted→blocked)
- **Prompting policy:** system prompt instructing the model to redirect confidential data to on-premise systems; max_tokens 4096, temperature 0.7, streaming true
- **Regulatory compliance:** MGF-Agentic-AI and AI-Agent-Index frameworks; autonomy level L2 with human oversight required; three safety controls (guardrails, monitoring, audit-logging)
- **Output ports:** `streaming-inference` (public), `batch-inference` (internal)
- **Input port:** `prompts` (internal, `blockConfidential: true`)
- **Quality SLAs:** 99.9% availability, 500 ms p95 latency, 1,000 req/min throughput

---

## Software Bill of Materials (SBOM)

### Zig Runtime Dependencies

| Module / Dependency | Version | Source | Purpose |
|---|---|---|---|
| Zig compiler | 0.14.0 | ziglang.org | Build toolchain |
| `deps/llama` (llama.zig) | Bundled | Local `deps/` | Llama inference engine (Zig bindings) |
| `deps/cuda` | Bundled | Local `deps/` | CUDA kernel headers for GPU backend |
| `libssl3` | System | Debian bookworm | TLS for HANA Cloud connections |
| `libc6` | System | Debian bookworm | C stdlib (Zig `linkLibC()`) |
| NCCL | Via `nccl_bindings.zig` | Vendor | Multi-GPU collective operations |

All Zig modules are first-party source with no external package manager dependencies. The build system is the Zig build system (`build.zig`); there is no `zig.zon` package manifest.

### Python Runtime Dependencies

| Package | Purpose |
|---|---|
| PyYAML | Service registry YAML parsing in `mesh_coordinator.py` |
| Standard library: `http.server`, `json`, `urllib.request` | MCP server HTTP transport and AI Core OAuth |
| Standard library: `os`, `base64`, `time`, `datetime` | Configuration, token caching, timestamps |

The Python layer intentionally uses only the standard library plus PyYAML for the MCP server and agent, avoiding any heavy framework dependencies. The `openai/` handlers and `agent/` modules have no external pip dependencies beyond what is resolvable from the standard library.

### Mangle/Mojo Dependencies

| Component | Source | Purpose |
|---|---|---|
| Google Mangle interpreter | Bundled (implied by `mangle/` directory usage pattern) | Datalog rule evaluation |
| Mojo standard library (`memory`, `algorithm`, `tensor`, `utils.index`) | Mojo SDK | SIMD stream processing |
| `sentence-transformers` (optional) | pip | Local e5-small embedding model fallback |
| SAP AI Core embedding service | SAP managed | Primary embedding source |

---

## Security Posture

**Strengths:**

`zig/src/hana/hana_db.zig` applies SQL injection prevention at the language level: `validateIdentifier()` uses a strict whitelist that will `error.InvalidIdentifierCharacter` on any character outside `[a-zA-Z0-9_\-/:.]`, and `escapeString()` handles quote escaping. HANA credentials are read only from environment variables — the help text in `main.zig` explicitly lists `HANA_PASSWORD_FILE` as the preferred path. The Dockerfile runs the broker as a non-root `pulsar` user. The MCP server enforces a 1 MB request size ceiling (`MCP_MAX_REQUEST_BYTES`), an 8,192-token output limit, and a 1,000-event stream cap. The `AICoreStreamingAgent` stores only `hash(prompt)` and `len(prompt)` in the audit log, never raw prompt content.

**Issues requiring attention before production use:**

1. **`authentication_enabled=false` and `authorizationEnabled=false` in `conf/standalone.conf`.** Both broker-level authentication and authorization are disabled by default. Any client connecting to port 6650 can produce to or consume from any topic without credentials. This needs explicit opt-in hardening before BTP production deployment.

2. **Open CORS policy in MCP server.** `CORS_ALLOWED_ORIGINS` defaults to `http://localhost:3000,http://127.0.0.1:3000`. If the MCP server is deployed without setting this variable, it will accept cross-origin requests from localhost origins only, but no validation prevents a misconfigured deployment with wildcard override.

3. **`tlsEnabled=false` in `conf/standalone.conf`.** TLS is disabled by default on both the binary protocol port (6650) and HTTP admin port (8080). All message data transits in plaintext unless `AIPROMPT_TLS_ENABLED=true` is explicitly set.

4. **Content-based security classification is brittle.** Both `MeshRouter._contains_confidential()` and the Mangle keyword predicates in `routing_rules.mg` and `agents.mg` use string substring matching on message content. "customer" and "personal" are common English words; false positives will route non-sensitive prompts to vLLM unnecessarily, while a sophisticated prompt could avoid triggering classification by paraphrasing.

5. **OAuth token stored in module-level mutable dict.** `_cached_token = {"token": None, "expires_at": 0}` in `mcp_server/server.py` is a module-level mutable. In multi-threaded deployments (multiple threads calling `get_access_token()` concurrently during token expiry), there is a race condition where multiple threads may simultaneously issue token refresh requests before any caches the result. A `threading.Lock` is absent.

6. **Bare `except:` in `get_access_token()`.** Line 121 uses a bare `except:` that silently swallows all exceptions (including `KeyboardInterrupt`, `SystemExit`) and returns an empty string, causing all subsequent AI Core requests to fail with an opaque `{"error": "No AI Core token"}` response rather than surfacing the root cause.

7. **`kuzu/` vendored directory (2,073 items).** As in `mangle-query-service`, this large vendored artefact is present in the repository root without a corresponding build integration in `build.zig`. Its inclusion inflates the repository without contributing to any identifiable build path.

---

## Observability and Configuration

**Metrics:** `zig/src/metrics/prometheus.zig` implements a Prometheus metrics backend with a Prometheus HTTP endpoint in `zig/src/metrics/http_server.zig`. The `standalone.conf` enables `metricsEnabled=true` and `exposeTopicLevelMetricsInPrometheus=true` (producer and consumer level metrics are off by default to reduce cardinality). OTEL exporter is configured via `OTEL_EXPORTER_OTLP_ENDPOINT`.

**Configuration file format:** The broker uses Java-properties format (`key=value`) matching Apache Pulsar's configuration convention. Default search paths are `/opt/aiprompt/conf/broker.conf`, `/etc/aiprompt/broker.conf`, `conf/broker.conf`, `broker.conf`. A CLI `--config` flag overrides the search path.

**Ports exposed by the full deployment:**

| Port | Protocol | Purpose |
|---|---|---|
| 6650 | TCP (AIPrompt binary) | Producer/consumer binary protocol |
| 6651 | TCP + TLS | Binary protocol TLS |
| 8080 | HTTP | Admin REST API + WebSocket |
| 8443 | HTTPS | Admin REST API TLS |
| 8815 | gRPC (Arrow Flight) | Arrow Flight data exchange |
| 9190 | HTTP (JSON-RPC) | MCP server + OpenAI API gateway |

---

## Integration Topology

The service connects to four external systems at runtime:

1. **SAP HANA Cloud** (port 443, TLS) — Durable message storage via ODBC. BTP Destination Service (`btp-destination-hana`) provides credentials. Six HANA tables store broker state. Connection pool: 5–50 connections.

2. **SAP AI Core** — Inference target for public/internal requests. OAuth 2.0 client credentials flow via `AICORE_AUTH_URL`. `AI-Resource-Group` header selects the deployment group. Accessed from the Python MCP server layer, not the Zig broker.

3. **vLLM (on-premise)** at `http://localhost:9180` — Inference fallback for confidential data. Local deployment, not routed to external services.

4. **SAP BTP Object Store** (HTTPS, `objectstore.hana.ondemand.com`, eu10) — Tiered storage offload target for closed ledgers exceeding the 1 GB threshold.

5. **LLM Gateway** at `http://ai-core-privatellm:8080` (optional) — Internal private LLM for ML pipeline processing on topics with `mlProcessingEnabled=true`. Default model: `phi-2`.

6. **Other SAP OSS fabric services** — Arrow Flight on port 8815 for high-throughput data exchange; blackboard shared state via `fabric/blackboard.zig` and `fabric/rdma_channel.zig` for low-latency shared memory across co-located services.

---

## Assessment Summary

BDC AIPrompt Streaming is a technically ambitious, high-performance infrastructure service that re-engineers the Apache Pulsar streaming broker in Zig with SAP HANA Cloud as the storage backend. Its architecture is genuinely novel within the SAP OSS corpus: no other observed service combines Pulsar wire protocol compliance, Zig/Mojo/Python/Mangle polyglot implementation, GPU acceleration via CUDA/Metal/WebGPU backends, and declarative Datalog governance for routing decisions in a single deployable unit.

For SAP engineering evaluation, the following items require resolution before production readiness:

1. **Authentication and TLS must be explicitly enabled.** Both `authenticationEnabled` and `tlsEnabled` default to `false` and must be configured for any non-development deployment, as the service is designed to accept Pulsar producers and consumers over an unprotected binary protocol.

2. **Thread-safety of OAuth token cache** in `mcp_server/server.py` should be fixed with a `threading.Lock` before concurrent serving.

3. **Bare `except:` in token acquisition** should be replaced with specific exception handling and proper error propagation.

4. **Security classification accuracy** should be reviewed: content-based classification via keyword substring matching is insufficient for enterprise data governance at scale; integration with SAP's formal data classification service or the HANA data masking layer is recommended.

5. **`kuzu/` vendored artefact** should either be integrated into the build or removed from the repository.

6. **Mojo FFI linkage** (`libmojo_streaming.so`) requires a Mojo SDK installation path in the production build environment; this dependency is not captured in the Dockerfile, which only installs Zig. The Mojo build step should be added to the multi-stage Dockerfile or the FFI dependency should be made explicitly optional.
