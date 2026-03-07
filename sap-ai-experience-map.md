# SAP AI Experience – Service Map

> 1:1 mapping of every codebase service to its AI experience tier.

---

## Tier 1 — SAP Analytics Cloud : Generative UI Experiences

### World Monitor

| | |
|---|---|
| **Path** | `src/generativeUI/world-monitor-main` |
| **Port** | 3000 |
| **Data Product** | `world-monitor-service-v1` |
| **Data Security** | internal / confidential |
| **Autonomy** | L2 |

Real-time global intelligence dashboard that aggregates 19 domain feeds including geopolitical conflict, market data, seismology, aviation, and cyber-threat intelligence into a unified AI-powered monitoring surface. Content-based routing classifies each feed by sensitivity and dispatches queries to either AI Core (public news) or vLLM (internal analysis). The Kuzu graph layer maintains entity relationships across events while Redis provides 24-hour TTL caching for high-frequency feed polling. Serves as the primary user-facing surface for the entire intelligence platform.

**Inputs**

| Source | Port | Purpose |
|--------|------|---------|
| agent-router | 8010 | Mangle-based query routing and data classification |
| enterprise-sovereign-llm | 8080 | LLM inference for confidential analysis |
| search | 9200 | Full-text and vector search across indexed events |
| redis | 6379 | Feed caching (24h TTL) |
| _External:_ GDELT, RSS, EONET, ACLED, USGS, FAA, MarineTraffic | — | Raw intelligence feeds |

**Outputs**

- REST API: 19 endpoints (earthquakes, news, markets, conflicts, climate, aviation, maritime, cyber, infrastructure, displacement, wildfire, unrest, military, predictions, research, intelligence, economic, audit)
- Data product: `world-monitor-service-v1`
- Kuzu graph: entity relationship updates

---

### UI5 Web Components (Angular)

| | |
|---|---|
| **Path** | `src/generativeUI/ui5-webcomponents-ngx-main` |
| **Port** | 4200 |
| **Data Product** | `ui5-angular-service-v1` |
| **Data Security** | public |
| **Autonomy** | L3 |

Angular wrapper library for SAP UI5 Web Components providing type-safe bindings, code generation, and AI-assisted component development. The agent routes all requests through Mangle classification — public documentation and code snippets go to AI Core while any detected user data falls back to vLLM for sovereign processing. Operates at autonomy level L3 since it primarily handles public component metadata and open-source documentation. Produces NPM packages consumed by all Angular-based UI surfaces.

**Inputs**

| Source | Port | Purpose |
|--------|------|---------|
| agent-router | 8010 | Query routing with user-data detection fallback to vLLM |

**Outputs**

- REST API: component generation, code completion, template generation, documentation lookup
- Data product: `ui5-angular-service-v1`
- NPM packages: Angular component wrappers

---

### Data Cleaning Copilot

| | |
|---|---|
| **Path** | `src/generativeUI/data-cleaning-copilot-main` |
| **Port** | 8002 |
| **Data Product** | `data-cleaning-service-v1` |
| **Data Security** | confidential |
| **Autonomy** | L2 |

AI-assisted data cleaning copilot that profiles, validates, and transforms raw enterprise datasets using schema-aware intelligence from OData Vocabularies and field classification from the Mangle Query Service. Processes confidential financial data exclusively through vLLM with data masking and a no-storage retention policy enforced by Mangle rules. Elasticsearch caches field mapping results to avoid repeated classification lookups across cleaning sessions. Provides PII detection and automated transformation code generation.

**Inputs**

| Source | Port | Purpose |
|--------|------|---------|
| agent-router | 8010 | Field classification via Mangle rules |
| odata-schema | 8003 | OData vocabulary discovery for schema understanding |
| search | 9200 | Cached field mappings and data profiling indices |
| _External:_ SAP AI Core | — | LLM backend via AICORE credentials |

**Outputs**

- REST API: data profiling, validation rules, transformation code, PII detection
- Data product: `data-cleaning-service-v1`
- Elasticsearch indices: field mapping cache

---

## Tier 2 — SAP CAP : Custom AI App & Agentic Governance Control Tower

### CAP LLM Plugin

| | |
|---|---|
| **Path** | `src/data/cap-llm-plugin-main` |
| **Port** | 4004 |
| **Data Product** | `cap-llm-service-v1` |
| **Data Security** | internal / confidential |
| **Autonomy** | L2 |

CDS plugin that wires LLM capabilities directly into SAP CAP applications, providing chat completions, RAG search, and embedding generation through the HANA vector engine. Implements three anonymisation strategies — k-Anonymity, l-Diversity, and Differential Privacy — to protect sensitive business data before it reaches any LLM endpoint. Mangle rules classify each request so confidential HANA data routes to vLLM while general queries use external AI Core. Auto-registers as a CDS plugin in the CAP application context.

**Inputs**

| Source | Port | Purpose |
|--------|------|---------|
| agent-router | 8010 | Mangle-based data classification and routing |
| enterprise-sovereign-llm | 8080 | LLM inference for confidential HANA data |
| embedded-hana | 8050 | HANA vector similarity search for RAG |
| _External:_ SAP AI Core | — | External LLM for non-confidential queries |

**Outputs**

- REST API: `/chat/completions`, `/embeddings`, `/rag/search`, `/anonymize`
- Data product: `cap-llm-service-v1`
- CDS plugin: auto-registered in CAP application context

---

### AI SDK JS

| | |
|---|---|
| **Path** | `src/data/ai-sdk-js-main` |
| **Port** | — (library) |
| **Data Product** | `ai-core-inference-v1` |
| **Data Security** | hybrid |
| **Autonomy** | L2 |



Official TypeScript SDK for SAP AI Core that provides programmatic access to foundation models, orchestration workflows, document grounding, and prompt registry management. Ships six NPM packages covering the full AI Core API surface from scenario management (`@sap-ai-sdk/ai-api`) through to LangChain bindings (`@sap-ai-sdk/langchain`). Hybrid routing sends confidential financial data to vLLM while general inference uses the external AI Core endpoint. OData Vocabularies integration enables automatic type generation from annotated service metadata.

**Packages:** `@sap-ai-sdk/ai-api` · `@sap-ai-sdk/foundation-models` · `@sap-ai-sdk/langchain` · `@sap-ai-sdk/orchestration` · `@sap-ai-sdk/document-grounding` · `@sap-ai-sdk/prompt-registry`

**Inputs**

| Source | Port | Purpose |
|--------|------|---------|
| odata-schema | 8003 | OData type generation and annotation lookup |
| _External:_ SAP AI Core, Generative AI Hub, Orchestration Service, Document Grounding, Prompt Registry | — | Foundation model inference, orchestration, grounding |

**Outputs**

- NPM packages: 6 SDK modules for AI Core integration
- Data product: `ai-core-inference-v1`
- TypeScript types: auto-generated from OData vocabularies

---

## Tier 3 — AI Core

### Enterprise Sovereign LLM

| | |
|---|---|
| **Path** | `src/intelligence/vllm-main` |
| **Port** | 8080 |
| **Data Security** | on-premise only |

On-premise sovereign LLM serving engine that runs LLaMA 3.1 (70B/8B), Mistral 7B, Codellama 34B, Mixtral 8x7B, Gemma, and Phi-3 models in GGUF quantised format with Metal and CUDA GPU acceleration. Exposes a fully OpenAI-compatible API so every upstream service can swap between vLLM and external AI Core without code changes. Zig and Mojo performance layers handle tokenisation and batch scheduling for low-latency inference on air-gapped deployments. All confidential enterprise data is routed here by the agent-router — no data ever leaves the on-premise boundary.

**Inputs**

| Source | Port | Purpose |
|--------|------|---------|
| object-store-for-model | — | GGUF model files and embedding binaries from S3 or local storage |
| _Hardware:_ NVIDIA GPU (T4/A100/H100) or Apple Metal | — | GPU-accelerated inference |

**Outputs**

- OpenAI-compatible API: `POST /v1/chat/completions`, `/v1/completions`, `/v1/embeddings`, `GET /v1/models`
- Supported models: LLaMA 3.1 70B, LLaMA 3.1 8B, Mistral 7B, Codellama 34B, Mixtral 8x7B, Gemma, Phi-3

---

### Search

| | |
|---|---|
| **Path** | `src/intelligence/elasticsearch-main` |
| **Port** | 9200 |
| **Data Product** | `elasticsearch-search-v1` |
| **Data Security** | index-based |
| **Autonomy** | L2 |

Enterprise search and analytics engine providing full-text search, vector similarity search, and log aggregation with index-based governance routing. Mangle rules classify each index as public, internal, or confidential so queries against sensitive indices are automatically routed to vLLM rather than external AI Core. The middleware layer implements circuit breakers and rate limiters to protect cluster stability under high query load. Kuzu metadata tracks index lineage and cross-service field relationships.

**Inputs**

| Source | Port | Purpose |
|--------|------|---------|
| _All services_ | — | Index data (world-monitor events, field mappings, vocabulary embeddings) |
| agent-router, data-cleaning-copilot, odata-schema | — | Query requests |

**Outputs**

- REST API: full-text search, vector search, aggregations, cluster health
- Data product: `elasticsearch-search-v1`
- Index metadata: field mappings, governance classifications

---

### External News Engine

| | |
|---|---|
| **Path** | `src/generativeUI/world-monitor-main/server` |
| **Port** | 3001 |
| **Data Product** | `world-monitor-service-v1` |
| **Data Security** | public / internal |

Backend news aggregation service that polls 19 external intelligence feeds including GDELT documents, RSS news, EONET natural events, ACLED conflict data, USGS seismology, FAA aviation delays, and MarineTraffic vessel data. Each feed handler normalises raw data into a common event schema and publishes it to Elasticsearch for indexing and to Redis for short-term caching. Mangle classification tags each event by sensitivity level before it reaches any downstream consumer. Serves as the raw intelligence ingestion layer for the entire platform.

**Inputs**

| Source | Port | Purpose |
|--------|------|---------|
| _External:_ GDELT, RSS, EONET, ACLED, UCDP, USGS, FAA, MarineTraffic, CoinGecko, Polymarket, ArXiv, HackerNews, GitHub | — | Raw intelligence feeds |
| redis | 6379 | Feed polling cache |

**Outputs**

- REST API: 19 domain endpoints (conflict, market, seismology, aviation, maritime, cyber, climate, etc.)
- Elasticsearch indices: normalised event documents
- Redis cache: feed polling state

---

### Agent Router

| | |
|---|---|
| **Path** | `src/data/mangle-query-service` |
| **Port** | 8010 |
| **Data Security** | governance hub |

Central governance hub that evaluates Mangle Datalog rules to classify every field and query by data sensitivity, then routes to the appropriate LLM backend — AI Core for public/internal data, vLLM for confidential, blocked for restricted. Implements semantic caching via Elasticsearch to avoid redundant classification lookups and adaptive model routing that selects the optimal model based on query complexity and latency requirements. Connects to HANA for direct data access, OData Vocabularies for schema discovery, and LangChain for RAG pattern support. Exposes OpenAI-compatible endpoints plus admin controls including emergency-stop, emergency-reset, and emergency-status.

**Inputs**

| Source | Port | Purpose |
|--------|------|---------|
| search | 9200 | Semantic caching and metadata indices |
| enterprise-sovereign-llm | 8080 | LLM inference for confidential data |
| odata-schema | 8003 | OData vocabulary and schema discovery |
| _External:_ SAP HANA, SAP AI Core | — | Direct data access and external LLM fallback |

**Outputs**

- OpenAI-compatible API: `/v1/chat/completions`, `/v1/completions`, `/v1/embeddings`, `/v1/models`
- Admin API: `/admin/emergency-stop`, `/admin/emergency-reset`, `/admin/emergency-status`
- Data products: `mangle-query-completion`, `mangle-embeddings`, `mangle-model-router`, `mangle-vocabulary-service`
- Routing decisions: `public → AI Core` · `confidential → vLLM` · `restricted → blocked`

---

### OData Schema

| | |
|---|---|
| **Path** | `src/data/odata-vocabularies-main` |
| **Port** | 8003 |
| **Data Product** | `odata-vocabulary-service-v1` |
| **Data Security** | public |
| **Autonomy** | L3 |

Semantic schema service hosting 18+ SAP OData vocabularies including Analytics, UI, Common, Session, Communication, PersonalData, and Graph with full term lookup, annotation generation, and validation. Provides CDS and GraphQL generators that produce typed schemas from vocabulary annotations for downstream services like ai-sdk-js and cap-llm-plugin. Elasticsearch indexes vocabulary embeddings for semantic term search across the entire vocabulary corpus. Operates at autonomy level L3 since vocabularies are public documentation, falling back to vLLM only when actual entity data is detected.

**Inputs**

| Source | Port | Purpose |
|--------|------|---------|
| search | 9200 | Vocabulary embedding index for semantic term search |
| agent-router (OpenAI API) | 8010 | Annotation generation |

**Outputs**

- REST API: vocabulary listing, term search, annotation generation, validation
- 18+ vocabularies: Analytics, UI, Common, Session, Communication, DataIntegration, DirectEdit, EntityRelationship, Graph, HTML5, Hierarchy, ILM, ODM, Offline, PDF, PersonalData, Support
- Generators: CDS schema generator, GraphQL schema generator
- Data product: `odata-vocabulary-service-v1`

---

### MCP — PAL Probabilistic Deep Learning

| | |
|---|---|
| **Path** | `src/intelligence/ai-core-pal` |
| **Port** | 8020 |
| **Data Product** | `aicore-pal-service-v1` |
| **Data Security** | confidential |
| **Autonomy** | L2 |

MCP server that exposes SAP HANA Predictive Analysis Library algorithms as tool-invocable resources — classification, regression, clustering, time-series forecasting (ARIMA), and anomaly detection. Consumes training data products (treasury, ESG, performance BPC) from the FinSight tier and annotates results with OData Analytics vocabulary terms for downstream consumption. Kuzu graph metadata tracks model lineage and feature relationships across PAL algorithm executions. All HANA data is classified as confidential and routed exclusively through vLLM — no PAL data reaches external endpoints.

**Inputs**

| Source | Port | Purpose |
|--------|------|---------|
| agent-router | 8010 | Mangle-based data classification |
| enterprise-sovereign-llm | 8080 | LLM inference for confidential HANA data |
| odata-schema | 8003 | Analytics vocabulary annotations for PAL results |
| sap-datasphere | — | Training data products (treasury, ESG, performance BPC) |
| _External:_ SAP HANA PAL | — | Predictive algorithms |

**Outputs**

- MCP tools: `pal_classification`, `pal_regression`, `pal_clustering`, `pal_forecasting`, `pal_anomaly_detection`
- MCP tools: `analytics_annotation`, `kpi_annotation`, `vocabulary_lookup`
- Data product: `aicore-pal-service-v1`
- Kuzu graph: model lineage and feature relationship updates

---

### AI Shared Fabric

| | |
|---|---|
| **Path** | `src/data/ai-core-streaming` |
| **Port** | 8030 |
| **Data Product** | `aicore-streaming-service-v1` |
| **Data Security** | public / internal |
| **Autonomy** | L2 |

Streaming AI fabric that provides Server-Sent Events (SSE) for real-time prompt processing, mesh-based multi-agent coordination, and XSUAA-authenticated access to all AI Core services. The mesh layer (`routing_rules.mg` + `registry.yaml`) defines agent routing topology so requests flow through governance checks before reaching any LLM endpoint. Connects to HANA for context retrieval and supports both AI Core (public/internal) and vLLM (confidential) backends via Mangle classification. Serves as the shared transport layer that all Tier 1 and Tier 2 services use for streaming inference.

**Inputs**

| Source | Port | Purpose |
|--------|------|---------|
| agent-router | 8010 | Mangle-based routing and governance enforcement |
| enterprise-sovereign-llm | 8080 | Streaming LLM inference for confidential data |
| _External:_ SAP HANA, XSUAA, SAP AI Core | — | Context retrieval, authentication, external LLM fallback |

**Outputs**

- OpenAI-compatible streaming API: SSE `/v1/chat/completions`, `/v1/completions`, `/v1/embeddings`
- MCP protocol: agent coordination and tool invocation
- Data product: `aicore-streaming-service-v1`
- Mesh registry: agent routing topology

---

### AI Prompt Agent

| | |
|---|---|
| **Path** | `src/intelligence/generative-ai-toolkit-for-sap-hana-cloud-main` |
| **Port** | 8040 |
| **Data Product** | `gen-ai-hana-service-v1` |
| **Data Security** | confidential |
| **Autonomy** | L2 |

RAG and prompt engineering agent that combines HANA vector store retrieval with LLM text generation to produce grounded, context-aware responses from enterprise data. Generates and stores embeddings in HANA Cloud's vector engine, then uses LangChain retrieval patterns to find relevant context before prompting vLLM for generation. Kuzu metadata tracks prompt templates, retrieval chains, and generation quality metrics across agent executions. All data is classified as confidential since it accesses raw HANA enterprise content — exclusively routed through vLLM.

**Inputs**

| Source | Port | Purpose |
|--------|------|---------|
| agent-router | 8010 | Mangle-based data classification |
| enterprise-sovereign-llm | 8080 | Text generation from retrieved context |
| embedded-hana | 8050 | HANA vector store retrieval for RAG |
| _External:_ SAP HANA Cloud | — | Vector embedding storage and retrieval |

**Outputs**

- REST API: `/chat` (RAG), `/embeddings`, `/rag/search`, `/agent/execute`
- Data product: `gen-ai-hana-service-v1`
- HANA vector store: embedding writes
- Kuzu graph: prompt lineage and quality metrics

---

### Embedded HANA

| | |
|---|---|
| **Path** | `src/data/langchain-integration-for-sap-hana-cloud-main` |
| **Port** | 8050 |
| **Data Product** | `hana-vector-store-v1` |
| **Data Security** | confidential |
| **Autonomy** | L2 |

LangChain integration layer that provides vector similarity search, knowledge graph traversal (RDF/SPARQL-QA), and schema-aware query execution against SAP HANA Cloud. Implements HanaDB as a LangChain VectorStore with cosine, L2, and inner-product distance metrics for embedding-based retrieval. The knowledge graph component supports RDF triple stores and SPARQL question-answering for structured enterprise knowledge extraction. All HANA data access is classified as confidential — Mangle rules ensure queries route exclusively through vLLM with no external leakage.

**Inputs**

| Source | Port | Purpose |
|--------|------|---------|
| agent-router | 8010 | Mangle-based schema classification |
| enterprise-sovereign-llm | 8080 | LLM inference for SPARQL-QA and query generation |
| _External:_ SAP HANA Cloud | — | Vector engine, knowledge graph (RDF), SQL execution |

**Outputs**

- REST API: `/vector/search`, `/vector/similarity`, `/sparql/qa`, `/schema/info`, `/tables/list`
- LangChain VectorStore: HanaDB with cosine/L2/inner-product metrics
- Data product: `hana-vector-store-v1`
- Knowledge graph: RDF triple traversal and SPARQL results

---

## Tier 4 — FinSight SAP BTP / Business Data Cloud

### SAP Datasphere

| | |
|---|---|
| **Path** | `src/training` |
| **Data Security** | confidential |
| **Components** | `pipeline/` · `hippocpp/` · `nvidia-modelopt/` · `mangle/` |

Multi-component data preparation platform that runs a 7-stage Text-to-SQL generation pipeline against banking schemas covering treasury capital markets, ESG sustainability metrics, and performance BPC fact tables. HippoCPP (a Zig+Mojo port of Kuzu) provides the graph engine for schema relationship traversal during SQL generation, while Mangle rules validate each generated query against governance constraints. NVIDIA ModelOpt handles post-training quantisation (4-bit, 8-bit GGUF) and optimisation before models are deployed to the vLLM serving layer. Produces four core data products consumed by mcp-pal and ai-prompt-agent for downstream analytics and RAG.

**Data Products:** `treasury-capital-markets-v1` · `esg-sustainability-v1` · `performance-bpc-v1` · `staging-schema-v1`

**Inputs**

| Source | Port | Purpose |
|--------|------|---------|
| _External:_ SAP HANA | — | Source banking schemas (treasury, ESG, performance BPC) |
| enterprise-sovereign-llm | 8080 | Base models for fine-tuning and quantisation |
| _Hardware:_ NVIDIA GPU (T4/A100) | — | Model optimisation and quantisation |

**Outputs**

- Data products: `treasury-capital-markets-v1`, `esg-sustainability-v1`, `performance-bpc-v1`, `staging-schema-v1`
- Enrichment overlays: 11 enrichment YAMLs in `data_products/enriched/`
- Quantised models: GGUF checkpoints for vLLM deployment
- Text-to-SQL training pairs: validated by Mangle governance rules

---

### Data Products

| | |
|---|---|
| **Registries** | 13 services × `data_products/registry.yaml` |
| **Enrichment** | `src/training/data_products/enriched/` |

Federated data product registry spanning all 13 services, each exposing an ODPS 4.1-compliant `registry.yaml` with structured contracts, SLAs, ownership, and lineage metadata. Enrichment overlays in `src/training/data_products/enriched/` layer additional context (treasury, ESG, performance dimensions) onto base data products for downstream analytics. Every registry now carries an `sap_ai_experience` tier reference linking it back to this manifest for full traceability. The SBOM pipeline (Makefile) audits all data products for licence compliance, vulnerability exposure, and Mangle policy conformance.

**Inputs**

| Source | Port | Purpose |
|--------|------|---------|
| All 13 services | — | `data_products/registry.yaml` files |
| SBOM pipeline | — | CycloneDX BOMs, SPDX exports, Mangle audit results |

**Outputs**

- 13 ODPS 4.1 registry contracts with tier references
- 11 enrichment overlay YAMLs
- SBOM artefacts: CycloneDX, SPDX, SARIF, SLSA provenance

---

### HANA Vector & Knowledge Engine

| | |
|---|---|
| **Components** | `langchain-integration-for-sap-hana-cloud-main` · `ai-core-pal/kuzu` · `ai-core-pal/src` |
| **Data Security** | confidential |

Composite capability combining HANA Cloud's vector engine for embedding-based similarity search with the Kuzu knowledge engine for graph-based entity relationship traversal and RDF/SPARQL question-answering. The vector store (via embedded-hana) supports cosine, L2, and inner-product distance metrics for high-dimensional retrieval. The knowledge engine (via ai-core-pal/kuzu) maintains entity lineage graphs that connect PAL algorithm outputs to their source schemas and training data products. All access is classified as confidential — Mangle rules enforce vLLM-only routing for any query touching HANA vector or knowledge data.

**Inputs**

| Source | Port | Purpose |
|--------|------|---------|
| embedded-hana | 8050 | HANA vector similarity search |
| mcp-pal-deep-learning | 8020 | PAL algorithm execution and Kuzu graph queries |
| _External:_ SAP HANA Cloud | — | Vector engine and knowledge graph storage |

**Outputs**

- Vector search: cosine/L2/inner-product similarity results
- Knowledge graph: RDF triple traversal, SPARQL-QA answers
- Entity lineage: Kuzu graph relationships across PAL outputs

---

### Object Store for Model

| | |
|---|---|
| **Components** | `vllm-main/models/` · `training/nvidia-modelopt/` · `vllm-main/upload-model-to-s3.sh` |
| **Data Security** | confidential |

Model artefact storage layer managing GGUF model files, embedding binaries, and quantised checkpoints with S3 upload/download and local volume caching. NVIDIA ModelOpt produces optimised checkpoints (4-bit/8-bit GGUF) from base models, which are then stored in S3 and pulled by vLLM at serving time. The `upload-model-to-s3.sh` script handles model lifecycle — uploading new checkpoints and managing model inventory across deployments. Docker volume `model-cache` provides local persistence so vLLM can serve models without network dependency in air-gapped environments.

**Inputs**

| Source | Port | Purpose |
|--------|------|---------|
| sap-datasphere | — | Base models and fine-tuned checkpoints from training pipeline |
| _Hardware:_ NVIDIA GPU | — | Quantisation and optimisation via ModelOpt |

**Outputs**

- GGUF model files: quantised LLaMA, Mistral, Phi-3 checkpoints
- Embedding binaries: all-MiniLM-L6-v2 and similar
- S3 artefacts: versioned model uploads
- Docker volume: `model-cache` for air-gapped serving

---

## Cross-Cutting Governance Fabric

| Layer | Description | Location |
|-------|-------------|----------|
| **Mangle** | Datalog rules engine — data classification & routing decisions | `*/mangle/` across all services; central hub: `src/data/mangle-query-service` |
| **Kuzu** | Graph database for entity lineage & metadata relationships | `*/kuzu/` across all services |
| **MCP Agents** | Model Context Protocol — standardised agent interface (autonomy L1–L3) | `*/agent/` and `*/mcp_server/` across all services |

### Routing Policy

| Classification | Routing Target |
|----------------|----------------|
| **Confidential** | vLLM only (on-premise) |
| **Internal** | AI Core with restrictions |
| **Public** | AI Core (external) |
| **Restricted** | Blocked entirely |

---

## Dependency Flow

```
External Feeds ──→ T1 Gen UI ──→ T3 AI Core (agent-router governs all) ──→ T4 FinSight (data + models)
                                       │                                         │
                                       ↓                                         ↓
                                  T2 CAP Apps ←──────────────────────── vLLM ←── Model Store
```