# Technical Assessment: odata-vocabularies

**Repository:** `SAP/odata-vocabularies`
**Assessment Date:** 2025
**Assessed By:** SAP Engineering Review
**Version:** 3.0.0 (MCP server label; `package.json` carries `0.0.0` / `sap-vocabularies`)
**License:** Apache-2.0 (SPDX)
**Primary Language:** XML (vocabulary source), JavaScript (build toolchain), Python (MCP server, agent, generators, connectors)

---

## Table of Contents

1. [Purpose and Positioning](#1-purpose-and-positioning)
2. [Repository Layout](#2-repository-layout)
3. [Vocabulary Corpus](#3-vocabulary-corpus)
4. [Build Toolchain](#4-build-toolchain)
5. [MCP Server — Phase Evolution and Architecture](#5-mcp-server--phase-evolution-and-architecture)
6. [MCP Tool Catalogue](#6-mcp-tool-catalogue)
7. [MCP Resource Catalogue](#7-mcp-resource-catalogue)
8. [Semantic Search and Embedding Sub-system](#8-semantic-search-and-embedding-sub-system)
9. [Python Generator Library](#9-python-generator-library)
10. [OpenAI-Compatible Server Layer](#10-openai-compatible-server-layer)
11. [Storage Connectors](#11-storage-connectors)
12. [Governance Agent](#12-governance-agent)
13. [Mangle Datalog Governance Layer](#13-mangle-datalog-governance-layer)
14. [Audit and Personal Data Sub-systems](#14-audit-and-personal-data-sub-systems)
15. [Container Deployment](#15-container-deployment)
16. [Software Bill of Materials (SBOM)](#16-software-bill-of-materials-sbom)
17. [Integration Topology](#17-integration-topology)
18. [Security Profile](#18-security-profile)
19. [Licensing and Compliance](#19-licensing-and-compliance)
20. [Pre-Production Items](#20-pre-production-items)

---

## 1. Purpose and Positioning

The `odata-vocabularies` repository is the canonical source of SAP's OData vocabulary extensions — a structured, machine-readable corpus of semantic annotation terms that enriches OData 4.0 / CSDL services with meaning beyond what the base OData specification provides. Eighteen vocabularies covering UI presentation, analytics, personal data / GDPR, communication, hierarchies, information lifecycle management, and others are maintained as authoritative XML source files, from which JSON (CSDL JSON) and Markdown documentation are auto-generated.

Within the SAP AI experience map the project is positioned at the `ai_core` / `odata-schema` tier, acting as a **universal dictionary** for data and HANA discovery. Its role has expanded in this repository snapshot beyond static artefact maintenance: a three-phase Python MCP server has been implemented alongside a Python generator library, an OpenAI-compatible inference front-end, SAP HANA Cloud and Elasticsearch connectors, a Mangle Datalog governance layer, an ODPS 4.1 data product definition, and a governance-aware Python agent. These components together constitute the vocabulary service that other SAP AI platform components (including `cap-llm-plugin`, `mangle-query-service`, and `ai-core-streaming`) query to resolve OData annotations at reasoning time.

---

## 2. Repository Layout

The repository is a polyglot workspace. The top-level structure separates the canonical vocabulary artefacts from the tooling that serves, transforms, and governs them.

```
odata-vocabularies-main/
├── vocabularies/          # 18 SAP vocabularies — .xml (source), .json, .md
├── lib/                   # Python generators + JS build transform
├── mcp_server/            # Phase 3 Python MCP server (server.py, ~1 782 lines)
├── openai/                # OpenAI-compatible aiohttp server layer
├── connectors/            # HANA Cloud and Elasticsearch connectors + Python sub-pkg
├── agent/                 # Python governance agent
├── mangle/                # Mangle Datalog governance rules (a2a/, domain/)
├── data_products/         # ODPS 4.1 YAML definitions
├── _embeddings/           # Pre-computed vocabulary term embeddings (numpy + JSON)
├── _site/                 # Jekyll/pages output (empty at assessment time)
├── assets/                # Static assets
├── config/                # Configuration files
├── docs/                  # Annotation cheat sheets and documentation
├── examples/              # 29 example annotation files (.xml → auto-generated .json)
├── hana/                  # HANA-specific supplementary files
├── middleware/            # HTTP middleware
├── scripts/               # Embedding generation scripts
├── tests/                 # 8 test modules
├── kuzu/                  # Vendored Kuzu graph database (~2 073 files)
├── package.json           # JS build toolchain (npm package: sap-vocabularies)
├── Dockerfile             # Multi-stage production container
├── IMPROVEMENT-PLAN.md    # Phased improvement roadmap
└── REUSE.toml             # REUSE compliance manifest
```

The `package.json` `files` array limits the npm-published artefact to `lib/*` (specifically `lib/transform.js`), so the Python server, agent, Mangle rules, connectors, and `kuzu/` vendor directory are all **excluded from npm distribution**. The Python components have no `pyproject.toml` or `setup.py` at the repository root; they are intended to be executed directly or containerised via the provided `Dockerfile`.

---

## 3. Vocabulary Corpus

Eighteen SAP OData vocabularies are maintained in `vocabularies/`. Each vocabulary exists in three representations that are kept in sync: the `.xml` file is the authoritative source edited by contributors; `lib/transform.js` (`npm run build`) invokes `odata-csdl` to convert it to CSDL JSON (`.json`) and `odata-vocabularies` to render a GitHub-Flavored Markdown description (`.md`). The vocabularies complement the OASIS OData Vocabularies and fully replace the legacy SAP Annotations for OData Version 2.0.

| Vocabulary | Namespace | Status | Scope |
|---|---|---|---|
| Common | `com.sap.vocabularies.Common.v1` | Stable | Universal — labels, text, semantic objects, value lists, calendars, draft |
| UI | `com.sap.vocabularies.UI.v1` | Stable | Fiori Elements — LineItem, HeaderInfo, Facets, Charts, SelectionFields |
| Analytics | `com.sap.vocabularies.Analytics.v1` | Stable | Dimensions, Measures, aggregation |
| CodeList | `com.sap.vocabularies.CodeList.v1` | Stable | Code list references |
| Communication | `com.sap.vocabularies.Communication.v1` | Stable | vCard contact information |
| PersonalData | `com.sap.vocabularies.PersonalData.v1` | Stable | GDPR — PII/sensitive field classification |
| PDF | `com.sap.vocabularies.PDF.v1` | Stable | PDF response format |
| HTML5 | `com.sap.vocabularies.HTML5.v1` | Stable | UI5 rendering directives |
| ODM | `com.sap.vocabularies.ODM.v1` | Stable | One Domain Model identifiers |
| Session | `com.sap.vocabularies.Session.v1` | Stable | Sticky session management |
| DataIntegration | `com.sap.vocabularies.DataIntegration.v1` | Stable | Data integration semantics |
| Hierarchy | `com.sap.vocabularies.Hierarchy.v1` | Experimental | Recursive / levelled hierarchies |
| DirectEdit | `com.sap.vocabularies.DirectEdit.v1` | Experimental | Direct-edit UI terms |
| EntityRelationship | `com.sap.vocabularies.EntityRelationship.v1` | Experimental | Cross-API relationship documentation |
| Graph | `com.sap.vocabularies.Graph.v1` | Experimental | SAP Graph service annotations |
| ILM | `com.sap.vocabularies.ILM.v1` | Experimental | Information Lifecycle Management |
| Offline | `com.sap.vocabularies.Offline.v1` | Experimental | Offline OData terms |
| Support | `com.sap.vocabularies.Support.v1` | Experimental | Support tools annotations |

A nineteenth file, `vocabularies/HANACloud.xml`, provides HANA Cloud–specific calculation view annotations. It does not follow the standard `com.sap.vocabularies.*` namespace pattern and is referenced separately by the MCP server's Phase 2.1 HANA vocabulary support.

The two largest vocabularies by file size are `UI` (124 KB XML / 94 KB JSON / 87 KB Markdown) and `Common` (110 KB XML / 81 KB JSON / 62 KB Markdown), reflecting the density of Fiori Elements presentation terms and cross-cutting semantic constructs respectively.

---

## 4. Build Toolchain

The JavaScript build toolchain is intentionally minimal. `lib/transform.js` reads every `.xml` file in `vocabularies/`, parses it with `odata-csdl`'s `xml2json` in strict mode with line number tracking, swaps the `latest-version` and `alternate` link relations (so the published JSON always points back to the canonical GitHub URL as `latest-version`), and writes a Prettier-formatted JSON file and a Markdown file per vocabulary. The same script processes `examples/*.xml` files to produce `examples/*.json` equivalents. A `lineNumbers` stripping pass (`omitLineNumbers`) removes the parser metadata before serialising.

The `npm run pages` and `npm run serve-pages` scripts delegate to the `odata-vocabularies` package's own pages generation tooling to produce a Jekyll `_site/` for GitHub Pages hosting.

Contributors are required to install [Pandoc](https://pandoc.org) in addition to Node.js because the `odata-vocabularies` Markdown generator calls Pandoc for certain table formatting transforms.

---

## 5. MCP Server — Phase Evolution and Architecture

`mcp_server/server.py` is a self-contained Python HTTP server implementing the Model Context Protocol (`2024-11-05`) over JSON-RPC 2.0. The file is ~1 782 lines and documents an explicit three-phase evolution:

**Phase 1** introduced full dynamic XML vocabulary loading (`_load_vocabularies_from_xml`), automatic Mangle fact generation from vocabulary terms (`_generate_mangle_facts`), and OData entity extraction from natural language using regex patterns (`extract_entities`).

**Phase 2** added HANACloud vocabulary support, enhanced Elasticsearch index mapping integration, and analytical query routing rules to steer HANA-bound queries appropriately.

**Phase 3** added pre-computed vocabulary term embeddings for semantic search (`_load_embeddings`), a cosine-similarity–based semantic term search tool (`_handle_semantic_search`), and RAG context enrichment (`_handle_get_rag_context`) that combines entity extraction, semantic search, keyword-based vocabulary routing, and Mangle fact injection into a single structured context payload for LLM consumers.

The server is instantiated as a single `MCPServer` object at module startup. Startup performs five sequential operations: XML vocabulary loading, Mangle facts generation, embedding loading, tool registration, and resource registration. The server binds on port **9150** (configurable via `MCP_PORT` environment variable). It uses only Python standard library HTTP primitives (`http.server.HTTPServer` / `BaseHTTPRequestHandler`) with no external web framework dependency, making the MCP server itself dependency-free apart from the optional `numpy` import for faster vector arithmetic.

Input bounds are enforced through module-level constants: `MCP_MAX_REQUEST_BYTES` (default 1 MB), `MCP_MAX_SEARCH_RESULTS` (default 500), `MCP_MAX_QUERY_LENGTH` (default 500 characters), and `MCP_MAX_PROPERTIES_PER_REQUEST` (default 500). The `clamp_int` and `clamp_float` helpers enforce numeric parameter ranges across all tool handlers.

The server provides a fallback vocabulary set for the three most critical vocabularies (Common, UI, Analytics) if the `vocabularies/` XML directory is absent or empty at startup, ensuring the server starts in a degraded but functional state rather than crashing.

---

## 6. MCP Tool Catalogue

The MCP server registers 14 tools across vocabulary lookup, annotation generation/validation, entity extraction, Mangle reasoning, semantic search, and RAG enrichment:

| Tool | Description | Key Parameters |
|---|---|---|
| `list_vocabularies` | List all vocabularies with term counts (total/stable/experimental/deprecated) | `include_experimental` |
| `get_vocabulary` | Full vocabulary detail including terms, complex types, enum types, type definitions | `name`, `include_types` |
| `search_terms` | Cross-vocabulary full-text search on term name and description | `query`, `vocabulary`, `include_deprecated` |
| `get_term` | Single term detail with all metadata fields | `vocabulary`, `term` |
| `extract_entities` | Regex-based OData entity extraction from natural language | `query` |
| `get_mangle_facts` | Retrieve auto-generated Mangle facts, filterable by vocabulary and fact type | `vocabulary`, `fact_type` |
| `validate_annotations` | Validate JSON or XML annotation payloads against loaded vocabulary terms; detects deprecated usage | `annotations` |
| `generate_annotations` | Generate UI or Common vocabulary annotation stubs for an entity | `entity_type`, `properties`, `vocabulary` |
| `lookup_term` | Alias for `get_term`, retained for backward compatibility | `vocabulary`, `term` |
| `convert_annotations` | Convert annotations between JSON and XML formats | `input`, `from_format`, `to_format` |
| `mangle_query` | Query Mangle facts by predicate with optional argument filtering | `predicate`, `args` |
| `get_statistics` | Aggregate statistics: vocabulary count, total terms, Mangle facts count, entity configs, embeddings loaded | — |
| `semantic_search` | Cosine-similarity search across pre-computed term embeddings | `query`, `top_k`, `min_similarity`, `vocabulary` |
| `get_rag_context` | Composite RAG context: entities + semantic matches + relevant vocabularies + annotations + Mangle facts | `query`, `entity_type`, `include_annotations` |
| `suggest_annotations` | Annotation suggestions by use case (ui, analytics, personal_data, all) | `entity_type`, `properties`, `use_case` |

The `convert_annotations` tool's JSON-to-XML path is partially implemented; the XML-to-JSON path returns a stub status response. The `validate_annotations` XML path returns `valid: true` without performing structural validation. Both are documented issues in `IMPROVEMENT-PLAN.md`.

---

## 7. MCP Resource Catalogue

Seven MCP resources are registered under `odata://` and supporting URI schemes:

| URI | MIME Type | Description |
|---|---|---|
| `odata://vocabularies` | `application/json` | List of all loaded vocabularies |
| `odata://common` | `application/json` | Common vocabulary terms |
| `odata://ui` | `application/json` | UI vocabulary terms |
| `odata://analytics` | `application/json` | Analytics vocabulary terms |
| `mangle://facts` | `text/plain` | Auto-generated Mangle facts from vocabulary definitions |
| `odata://entity-configs` | `application/json` | OData entity type patterns for extraction |
| `embeddings://index` | `application/json` | Vocabulary embedding index metadata |

---

## 8. Semantic Search and Embedding Sub-system

The Phase 3 semantic search capability operates against pre-computed embeddings stored in `_embeddings/`. The server attempts to load two artefacts at startup: a numpy `.npy` array pair (`embedding_keys.npy`, `embedding_vectors.npy`) for fast matrix operations, and JSON files (`vocabulary_embeddings.json`, `vocabulary_index.json`) for term metadata. If numpy is available the fast path uses `np.dot` / `np.linalg.norm` for cosine similarity; the pure-Python fallback uses sum-of-products arithmetic.

The `_get_query_embedding` method provides a deterministic SHA-256 hash–based placeholder embedding (1 536 dimensions, normalised) for use when no live embedding API is configured. This allows the semantic search tool to function in development environments without an AI Core connection, but the placeholder produces random-walk similarities rather than genuine semantic proximity. The comment in the code acknowledges this: _"In production, this would call the embedding API."_ The embeddings must be pre-generated by running `scripts/generate_vocab_embeddings.py` against a live embedding endpoint.

The `semantic_search` tool applies a configurable minimum similarity threshold (default 0.3, range 0.0–1.0) and returns the top-k results (default 10, max `MCP_MAX_SEARCH_RESULTS`) sorted by descending cosine similarity with full term metadata.

---

## 9. Python Generator Library

`lib/` contains five Python modules providing code generation capabilities that extend the vocabulary corpus into other schema formats:

**`cds_generator.py`** (`CDSAnnotationGenerator`) generates SAP CAP CDS annotation files from OData vocabulary definitions. Given an entity name and a list of property definitions, it produces `annotate <entity> with { ... }` blocks for `@Common.Label`, `@Analytics.Dimension`, `@Analytics.Measure`, `@PersonalData.IsPotentiallyPersonal`, `@PersonalData.IsPotentiallySensitive`, `@PersonalData.FieldSemantics`, `@Measures.ISOCurrency`, and `@Measures.Unit` annotations. It supports three Fiori Elements page type modes: `list` (PresentationVariant + LineItem + Chart), `object` (Facets + FieldGroups), and `worklist` (SelectionVariant). Property classification uses heuristic naming patterns: properties whose names contain `id`, `code`, `key`, `type`, `category`, or `status` are classified as dimensions; numeric-typed properties containing `amount`, `quantity`, `value`, `price`, `count`, `sum`, or `total` are classified as measures.

**`graphql_generator.py`** (`GraphQLSchemaGenerator`) maps OData entity definitions to GraphQL SDL, including OData-to-GraphQL type mapping (all 17 `Edm.*` primitives plus CDS types), custom directive generation for OData annotations, Query/Mutation/Subscription type generation, and Relay-style connection-based pagination support.

**`personal_data.py`** (`PersonalDataClassifier`) performs automatic GDPR classification of entity properties using the `PersonalData` vocabulary. It exposes `DataSubjectRole`, `FieldSemantics`, and `PersonalDataClassification` dataclasses covering 17 `FieldSemantics` enum values (given name, family name, email, phone, postal address, date of birth, gender, nationality, bank account, tax ID, social security number, passport number, driver's licence, geo-location, IP address, photo, user ID).

**`audit.py`** (`AuditTrail`) provides vocabulary-contextual audit logging with 10 `AuditEventType` values (query, data access, personal data access, sensitive data access, tool invocation, entity extraction, annotation lookup, vocabulary search, data masking, data export). Events are written to JSON Lines files in `_audit_logs/` with SHA-256–hashed content identifiers for non-repudiation.

**`health.py`** provides health checker infrastructure consumed by the OpenAI-compatible server's `/health`, `/livez`, and `/readyz` endpoints.

**`transform.js`** is the Node.js build script described in §4.

---

## 10. OpenAI-Compatible Server Layer

`openai/` implements a drop-in OpenAI API–compatible server using `aiohttp`, enabling any OpenAI SDK client to query the vocabulary corpus as if it were an LLM. The module provides:

- `GET /v1/models` and `GET /models` — lists available vocabulary-specialised models (e.g., `text-embedding-odata`)
- `POST /v1/chat/completions` and `POST /chat/completions` — handles both streaming (SSE) and non-streaming chat completions; streaming uses `aiohttp.StreamResponse` with `text/event-stream`
- `POST /v1/embeddings` and `POST /embeddings` — generates vocabulary term embeddings via `create_embedding`; vocabulary embeddings are initialised on `app.on_startup`
- `GET /health`, `GET /livez`, `GET /readyz` — delegates to `lib.health` with Kubernetes probe semantics (503 on unhealthy, 200 on degraded)

The `create_app` factory accepts an optional middleware list and returns a configured `aiohttp.Application`. A standalone `run_server` coroutine binds on port **9150** by default, the same port as the MCP server. The two servers cannot run simultaneously on the same port without a multiplexing layer; they represent alternative deployment modes for the same host.

---

## 11. Storage Connectors

**`connectors/hana.py`** (`HANAConnector`) provides a production-pattern HANA Cloud integration with connection pooling, retry logic with exponential backoff, and a `CircuitBreaker` class (closed/open/half-open state machine, configurable failure threshold and reset timeout). The circuit breaker uses `threading.Lock` for thread safety. The HANA connector wraps `hdbcli` (the SAP HANA Python client) which is imported lazily; if `hdbcli` is not installed, HANA features are silently simulated. The connector exposes vocabulary-aware query building, annotating result columns with their `Common.Label` values where known.

**`connectors/elasticsearch.py`** (`ElasticsearchClient`) provides vocabulary-aware Elasticsearch integration for full-text and semantic vocabulary search with bulk indexing, index lifecycle management, and vocabulary-specific mapping configuration. The `elasticsearch` Python client is imported lazily; if absent, ES features are simulated. The client tracks request statistics (`ESStats`) and exposes query-building helpers that inject vocabulary context into ES queries.

**`connectors/python/`** contains a Python connector sub-package (2 items, not fully assessed in this review).

---

## 12. Governance Agent

`agent/odata_vocab_agent.py` implements `ODataVocabAgent`, the governance-aware Python client for the vocabulary MCP service. Its design mirrors the `CapLlmAgent` in `cap-llm-plugin` but is deliberately simplified for a public documentation service.

The `MangleEngine` inline stub loads six queryable facts at construction time: `agent_config` (4 key/value pairs), `agent_can_use` (6 permitted tools), `agent_requires_approval` (empty set — no approval required for public documentation), `data_keywords` (6 keywords that trigger vLLM routing), `prompting_policy` (max 2 048 tokens, temperature 0.5, OData expert system prompt).

`ODataVocabAgent.invoke()` follows a three-step pipeline: (1) routing decision — `route_to_vllm` fires if the prompt contains any `data_keyword` (customer data, real example, production data, actual values, trading, financial), otherwise `route_to_aicore` is applied; (2) safety check — blocks execution and logs an audit entry if the requested tool is not in `agent_can_use`; (3) prompting policy injection — the system prompt and generation parameters from the policy are prepended to the MCP call before dispatch.

The agent calls the MCP server via `urllib.request.urlopen` with a 120-second timeout, sending a standard JSON-RPC `tools/call` request. The `_call_mcp` method is defined as `async` but uses the synchronous `urllib.request` — calling it with `await` will not behave as intended because `urllib.request.urlopen` is blocking. This is a structural inconsistency: the `invoke` method must be driven by an event loop but the underlying HTTP call blocks the loop.

The `_log_audit` method records `hash(prompt)` as the content identifier. Python's built-in `hash()` is non-deterministic across interpreter invocations (randomised by `PYTHONHASHSEED`) and provides no non-repudiation guarantee. `lib/audit.py` uses `hashlib.sha256` correctly; `agent/odata_vocab_agent.py` should be updated to match.

---

## 13. Mangle Datalog Governance Layer

Three Mangle Datalog files govern the vocabulary service:

**`mangle/a2a/mcp.mg`** defines the MCP service registry. Three services are registered on `http://localhost:9150/mcp`: `odata-vocab` (vocabulary-engine model), `odata-annotate` (annotation-generator model), and `odata-validate` (validator model). Eight tool-to-service mappings connect the MCP tool names to their owning services. Three intent routing rules map `/vocabulary`, `/annotate`, and `/validate` intents to the corresponding registered service. Five static vocabulary facts seed the reasoning engine with the core namespace mappings.

**`mangle/domain/agents.mg`** defines the `odata-vocab-agent` configuration and governance rules. The agent is configured with autonomy level **L3** (higher than the L2 assigned to `cap-llm-agent`, reflecting that vocabulary queries operate on public documentation rather than customer data). The MCP endpoint is `http://localhost:9150/mcp`. Six tools are permitted; no tools require approval. The `route_to_vllm` rule fires on six `contains_actual_data` predicates (customer data, real example, production data, actual values, trading, financial); all other requests default to AI Core. Six `is_vocabulary_query` predicates cover vocabulary, annotation, odata, term, csdl, and edm keywords. Human review is unconditionally disabled (`requires_human_review(_) :- false`). All tools have guardrails active. Audit level is `basic`.

**`mangle/domain/vocabularies.mg`** is the most structurally significant Mangle file (232 lines). It declares 10 extensional predicates (`vocabulary`, `term`, `term_applies_to`, `term_experimental`, `term_deprecated`, `complex_type`, `type_property`, `enum_type`, `enum_member`, `entity_config`) and provides 30 derived predicates covering term classification (stable/experimental/deprecated), analytics terms (dimension/measure), UI presentation terms (chart/table/form), PersonalData/GDPR terms (PII/sensitive), Common vocabulary terms (semantic, display, value list, calendar, fiscal, draft), entity extraction helpers, vocabulary statistics, and integration routing rules (`should_route_to_hana`, `should_apply_gdpr_mask`, `should_route_to_vocabulary_service`). A section of example static facts seeds 7 vocabulary namespaces, 9 key terms across 4 vocabularies, and 6 SAP entity configurations (SalesOrder, BusinessPartner, Material, PurchaseOrder, Employee, CostCenter).

The `agents.mg` file includes `../../../regulations/mangle/rules.mg` — a path that references the `regulations/` module outside this repository. This import will silently fail or error at Mangle engine startup unless the regulations module is co-located in the parent directory tree.

**`mangle/domain/data_products.mg`** defines the ODPS 4.1 data product for the vocabulary service. The data product ID is `odata-vocabulary-service-v1`, owner is API Standards Team, version 1.0.0. Three output ports are defined (`vocabulary-lookup`, `annotation-generator`, `validation`), all with `public` security class and `aicore-ok` routing. Two input ports are defined: `csdl-schema` (internal) and `vocabulary-files` (public). The prompting policy sets `max_tokens: 2048`, `temperature: 0.5`, and a five-sentence OData expert system prompt. The regulatory framework is `MGF-Agentic-AI`. Autonomy level is L3 with no human oversight requirement. SLA targets: 99.9% availability, 1 000 ms p95 latency, 500 req/min throughput.

---

## 14. Audit and Personal Data Sub-systems

`lib/audit.py` implements a `VocabularyAuditTrail` class providing GDPR-aware audit logging with vocabulary context enrichment. Audit events carry a `vocabulary_context` string encoding the `Common.SemanticObject` value of the accessed entity, enabling post-hoc correlation of data access events to their OData semantic intent. Events are written to rotating JSON Lines files under `_audit_logs/` with SHA-256 content hashes and UTC ISO-8601 timestamps. Ten event types are classified, with `PERSONAL_DATA_ACCESS` and `SENSITIVE_DATA_ACCESS` triggering elevated audit detail including the full list of accessed fields.

`lib/personal_data.py` implements `PersonalDataClassifier`, which integrates with the `PersonalData` vocabulary to classify entity properties automatically. The classifier maps 17 `FieldSemantics` values against property name heuristics and annotation declarations, producing `PersonalDataClassification` objects that capture data subject role, potentially personal / potentially sensitive field lists, field-level semantics, end-of-business-date fields, data retention periods, legal basis, and consent requirements. This classification output is consumed by the CDS generator to inject `@PersonalData.*` annotations and by the audit trail to tag data access events.

---

## 15. Container Deployment

The `Dockerfile` implements a three-stage multi-stage build:

**Stage 1 (builder):** `python:3.11-slim`, installs `gcc` build dependencies, creates `/opt/venv`, installs from `requirements.txt` if present, installs `aiohttp` and `pytest`.

**Stage 2 (production):** `python:3.11-slim`, creates a non-root `odata:odata` user and group, copies the virtual environment from the builder, copies application code with `odata` ownership, creates `_audit_logs/` and `_embeddings/` directories, sets `MCP_PORT=9150`, `MCP_HOST=0.0.0.0`, `LOG_LEVEL=INFO`, exposes port 9150. The health check polls `http://localhost:9150/health` every 30 seconds with a 10-second timeout, 5-second start period, and 3 retries. The default `CMD` is `python -m mcp_server.server`.

**Stage 3 (development):** Extends production, installs `pytest`, `pytest-cov`, `pytest-asyncio`, `ruff`, `mypy`, `black`, and overrides the command with `--debug` flag.

The image label `org.opencontainers.image.version` is hardcoded to `"3.0.0"` and will diverge from the actual codebase version unless updated as part of the release process.

---

## 16. Software Bill of Materials (SBOM)

### JavaScript / npm (`package.json`)

| Package | Version | Role | Type |
|---|---|---|---|
| `colors` | `^1.4.0` | Terminal colouring for build error output | Dependency |
| `odata-csdl` | `^0.11.1` | XML→JSON CSDL conversion | Dependency |
| `odata-vocabularies` | `github:oasis-tcs/odata-vocabularies` | Markdown and pages generation | Dependency |
| `eslint` | `^8.56.0` | JavaScript linting | Dev dependency |
| `express` | `^4.22.1` | (Referenced in devDependencies — not used in published transform) | Dev dependency |
| `prettier` | `^3.2.5` | JSON formatting in build output | Dev dependency |

The `odata-vocabularies` dependency is resolved directly from the `oasis-tcs` GitHub repository (`github:oasis-tcs/odata-vocabularies`) rather than from the npm registry. This is a pinned GitHub source reference without a commit SHA, meaning `npm install` will pull the default branch HEAD at install time.

### Python Runtime

The MCP server and supporting modules use only Python standard library components for the core server (`http.server`, `json`, `os`, `glob`, `re`, `xml.etree.ElementTree`, `hashlib`, `math`, `time`). All third-party Python dependencies are **optional** with graceful degradation:

| Package | Graceful fallback when absent |
|---|---|
| `numpy` | Pure-Python cosine similarity via `math.sqrt` / sum-of-products |
| `hdbcli` | HANA connector logs a warning and simulates responses |
| `elasticsearch` | ES connector logs a warning and simulates responses |
| `aiohttp` | OpenAI-compatible server cannot start; MCP server is unaffected |

The `agent/` module depends on no third-party packages. The `lib/` modules (`cds_generator.py`, `graphql_generator.py`, `personal_data.py`, `audit.py`) use only the standard library. The `Dockerfile` installs `aiohttp` and `pytest` unconditionally at build time.

### Vendored Artefact

`kuzu/` contains ~2 073 files from the [Kuzu](https://kuzudb.com) embedded graph database (Apache-2.0). The directory is identical to that found in `cap-llm-plugin-main` and `mangle-query-service-main`. There is no import, build integration, or documentation linking `kuzu/` to any functionality in this repository. Its presence is an unreviewed transitive artefact that inflates the repository size and dependency surface without contributing to any implemented feature.

---

## 17. Integration Topology

The vocabulary service participates in five external integration points:

**SAP AI Core** (HTTPS, OAuth 2.0): The MCP server's `data_products/registry.yaml` lists AI Core at `http://localhost:9150/mcp` (the service's own endpoint — this is the inbound-facing reference used by the data product catalog, not an outbound call). The agent routes the majority of vocabulary queries to AI Core as the default backend for public documentation queries.

**vLLM** (`http://localhost:9180/mcp`): The agent and Mangle rules redirect requests to vLLM when the prompt contains actual entity data keywords (customer data, financial, trading, production data, etc.). vLLM is assumed to operate on-premise for confidential workloads.

**SAP HANA Cloud** (ODBC via `hdbcli`): The `connectors/hana.py` connector provides vocabulary-contextual HANA query execution. Analytical queries detected by `should_route_to_hana` in `vocabularies.mg` are directed to HANA. The circuit breaker and connection pool are designed for production deployment.

**Elasticsearch**: `connectors/elasticsearch.py` supports vocabulary-indexed full-text search as an alternative or complement to the embedded term search. Index mappings are vocabulary-aware, enabling semantic enrichment of ES query results.

**Mangle Query Service / regulations module**: `mangle/domain/agents.mg` imports `../../../regulations/mangle/rules.mg`, establishing a compile-time dependency on the `regulations/` sub-repository in the parent workspace. This dependency is unresolved in the standalone repository checkout.

---

## 18. Security Profile

### Strengths

**Input bounds enforcement.** All four MCP input bounds constants are configurable via environment variables and are applied consistently across tool handlers via `clamp_int` and `clamp_float`. Query length is hard-capped at 500 characters, search results at 500, properties per request at 500, and request body size at 1 MB. This protects against oversized payload attacks.

**Non-root container execution.** The production Docker image creates a dedicated `odata:odata` user and runs the server under that identity, limiting the blast radius of any container escape.

**No authentication dependencies on external secrets.** Unlike `cap-llm-plugin`'s MCP server, the vocabulary service does not handle OAuth tokens or AI Core credentials directly — it serves public vocabulary data, and the routing to AI Core is mediated by the agent layer. The server itself has no credential management surface.

**Graceful dependency degradation.** The absence of `numpy`, `hdbcli`, or `elasticsearch` does not crash the server; all three are imported under try/except with logged warnings and simulated fallbacks. This prevents dependency-chain supply chain issues from causing service outages.

### Findings

**(F-1) No MCP server authentication.** `mcp_server/server.py` has no authentication middleware. Any caller that can reach port 9150 can invoke all 14 tools and read all 7 resources, including `mangle://facts` (which exposes the full internal governance rule base) and `embeddings://index`. The server is intended to be deployed behind a service mesh or API gateway, but there is no enforcement of this at the application layer.

**(F-2) Async/blocking mismatch in agent.** `ODataVocabAgent._call_mcp` is declared `async` but uses `urllib.request.urlopen`, which is synchronous and will block the event loop. All MCP calls from the agent will stall the event loop for the full network round-trip (up to 120 seconds). The method should use `aiohttp.ClientSession` or Python 3.11's `asyncio.to_thread` for the blocking call.

**(F-3) Non-deterministic audit hash.** `agent/odata_vocab_agent.py:204` uses `hash(prompt)` as the `prompt_hash` audit field. Python's `hash()` is randomised by `PYTHONHASHSEED` at interpreter startup, producing different values for the same prompt across process restarts. This makes the audit log non-reproducible and unsuitable for forensic or compliance purposes. Replace with `hashlib.sha256(prompt.encode()).hexdigest()`.

**(F-4) Incomplete annotation conversion.** `_handle_convert_annotations` returns a partial XML stub for JSON→XML conversion and a `"not fully implemented"` status for XML→JSON. Callers that rely on round-trip conversion will receive silently incorrect or incomplete output without a clear error. The tool should return an explicit `error` field with code `-32001` rather than a `status` string.

**(F-5) Unresolved external Mangle import.** `mangle/domain/agents.mg` line 7 includes `../../../regulations/mangle/rules.mg`. In a standalone checkout of this repository the file does not exist, causing the Mangle engine to fail at compile time with an unresolved include. This is a hard runtime dependency on the workspace `regulations/` sub-repository.

**(F-6) `odata-vocabularies` dependency pinned to GitHub HEAD.** The npm dependency `"odata-vocabularies": "github:oasis-tcs/odata-vocabularies"` resolves to the OASIS repository's default branch at install time. There is no commit SHA pinning, meaning `npm install` is non-deterministic across time — the build output can change without any change to this repository.

---

## 19. Licensing and Compliance

The project is licensed under **Apache-2.0** (SPDX-FileCopyrightText: 2016–2025 SAP SE or an SAP affiliate company and SAP/odata-vocabularies contributors). The `REUSE.toml` covers all files via a single aggregate annotation with `path = ["**", "docs/**", "examples/**", "lib/**", "vocabularies/**"]`. The REUSE.toml includes the same API call disclaimer as `cap-llm-plugin`, noting that calls to SAP External Products (AI Core, HANA Cloud) are not covered by the Apache-2.0 license and are subject to separate SAP license agreements.

The `LICENSES/` directory contains the Apache-2.0 license text. The `[![REUSE status](...)]` badge in `README.md` links to the REUSE API for automated compliance verification.

The `odata-vocabularies` npm dependency is sourced from the OASIS Technical Committee's GitHub repository (`github:oasis-tcs/odata-vocabularies`). OASIS specifications and their accompanying tooling are typically published under the OASIS IPR Policy; the precise license of the referenced package should be confirmed before redistribution.

The `kuzu/` vendored directory is Apache-2.0 licensed (consistent with Kuzu's open-source terms). However, its 2 073-file inclusion without a corresponding `REUSE.toml` annotation, build integration, or documentation represents an unreviewed transitive dependency surface. A separate compliance assessment of the vendored Kuzu artefacts is required before any enterprise distribution.

---

## 20. Pre-Production Items

Six items require resolution before production deployment:

**(1) MCP server authentication (F-1).** Port 9150 accepts all connections with no authentication. JWT validation against XSUAA tokens, mTLS client certificate verification, or network-policy enforcement at the service mesh layer must be implemented before the server is reachable from outside a trusted namespace.

**(2) Async/blocking agent fix (F-2).** `ODataVocabAgent._call_mcp` blocks the event loop for up to 120 seconds per MCP call. Replace `urllib.request.urlopen` with `aiohttp.ClientSession.post` (preferred, since `aiohttp` is already a dependency for the OpenAI-compatible server) or wrap with `asyncio.to_thread`. Without this fix the agent cannot safely serve concurrent requests.

**(3) Audit hash non-determinism (F-3).** Replace `hash(prompt)` in `agent/odata_vocab_agent.py:204` with `hashlib.sha256(prompt.encode()).hexdigest()` to produce stable, reproducible, PYTHONHASHSEED-independent content identifiers. This is a one-line fix but is required for audit logs to serve any compliance purpose.

**(4) Annotation conversion completeness (F-4).** The `convert_annotations` tool advertises bidirectional JSON↔XML conversion but only partially implements the JSON→XML direction and returns a `status` string for unsupported directions rather than a JSON-RPC error. Consumers that depend on this tool for annotation round-tripping will silently receive incorrect output. Either fully implement both directions or return a structured `{"error": {"code": -32001, "message": "Not implemented"}}` response.

**(5) Mangle import path (F-5).** The `include "../../../regulations/mangle/rules.mg"` in `agents.mg` is unresolvable in a standalone checkout. Either bundle a copy of the required regulations rules or make the include conditional on file existence. The Mangle engine compile failure will prevent agent governance from initialising.

**(6) npm dependency pinning (F-6).** The `"odata-vocabularies": "github:oasis-tcs/odata-vocabularies"` dependency should be pinned to a specific commit SHA or Git tag (e.g., `"github:oasis-tcs/odata-vocabularies#v<tag>"`) to ensure reproducible builds. The current reference resolves to the OASIS repository default branch HEAD at install time.
