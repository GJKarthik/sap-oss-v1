# Technical Assessment: `data-cleaning-copilot`

**Package:** `data-cleaning-copilot` v0.1.0  
**Author:** SAP SE and data-cleaning-copilot contributors  
**License:** Apache-2.0  
**Repository:** `https://github.com/SAP/data-cleaning-copilot`  
**Runtime requirement:** Python ≥ 3.12, `uv` package manager

---

## Purpose and Positioning

The `data-cleaning-copilot` is an AI-assisted data quality and validation toolchain for relational databases. Its central purpose is to accept a database schema together with descriptive metadata — table semantics, entity relationships, and usage context — and help operators formulate, generate, and execute data quality checks that detect errors and inconsistencies. The system spans three distinct layers: a Python-native core framework for check definition and execution, a multi-version agentic loop that drives iterative LLM-assisted check generation, and two runtime surfaces — a Gradio web copilot for interactive exploration and a FastAPI REST server for programmatic integration. A separate Angular 21 frontend using SAP UI5 Web Components is present in `frontend/` and communicates with the FastAPI server, providing a production-oriented browser interface that replaces the Gradio surface.

The project is licensed under Apache-2.0 and carries REUSE 1.0 compliance metadata via `REUSE.toml`, governed by `ospo@sap.com`. Every source file carries an SPDX header. The ODPS 4.1 data product descriptor in `data_products/data_cleaning_service.yaml` classifies the service as `dataSecurityClass: confidential` and restricts all LLM routing to `vllm-only`, reflecting a deliberate policy that raw financial data must never leave on-premise infrastructure. The declared autonomy level is `L2` under the MGF-Agentic-AI framework, meaning the agent can reason and propose changes but certain categories of action — schema modification, record deletion, data export — require explicit human approval before execution.

---

## Repository Layout and Build Architecture

The repository has a flat top-level layout with no monorepo tooling. The Python package is defined entirely by `pyproject.toml`, which uses `uv` as the resolver and installer. There is no `setup.py` or legacy `setup.cfg`; the project relies on the `setuptools` build backend declared as a runtime dependency. The package installs as `data-cleaning-copilot` with an editable source layout, placing `data_cleaning_copilot.egg-info/` at the workspace root.

Source code is divided across four top-level Python namespaces. The `definition/` tree contains the entire framework: `base/` holds abstract base classes and utilities; `agents/` holds the three versioned check-generation agents and a corruption agent; `llm/` holds session management and Pydantic models; `impl/` holds concrete database schemas and check/corruption implementations; `odata/` holds the OData vocabulary parsing and table-generation subsystem; and `benchmark/` holds evaluation tooling. The `agent/` directory (singular, distinct from `definition/agents/`) contains `data_cleaning_agent.py`, which is an alternative orchestration module implementing the Mangle-plus-discovery architecture for S/4HANA Finance GL/subledger field classification. The `bin/` directory contains three executable entry points: `copilot.py` (Gradio interface), `agent_workflow.py` (batch pipeline), and `api.py` (FastAPI server), plus a `download_relbench_data.py` utility. The `mcp_server/server.py` implements the Model Context Protocol (MCP) server that makes the copilot's tools accessible to external AI agents over JSON-RPC. The `mangle/` directory contains Datalog rule files: `a2a/mcp.mg` for service registry and S/4HANA Finance field classification, and `domain/` for agent-governance rules.

The `frontend/` subdirectory is a fully independent Angular 21 workspace. Its `package.json` declares `@ui5/webcomponents` 2.19.x as its primary component library, alongside Angular 21.1.x and RxJS 7.8. The frontend is not bundled as part of the Python package and is built and deployed separately using the Angular CLI.

The `kuzu/` directory (2,073 items) contains a local Kùzu embedded graph database installation, indicating that graph-structured data and relationship queries are part of the runtime capability even though this is not prominently documented in the README.

---

## Core Framework: Database Abstraction and Table Schema Layer

The `Database` base class in `definition/base/database.py` is the largest single file in the project at 60 KB and forms the central spine of the framework. It provides a stateful container for a relational database whose tables are represented as in-memory Pandas DataFrames, alongside a registry of `CheckLogic` instances (validation functions) and `CorruptionLogic` instances (corruption strategies). Every database operation that could interact with LLM-generated code is decorated with `@with_timeout` and `@with_token_limit`. The timeout decorator uses `concurrent.futures.ThreadPoolExecutor` to enforce configurable wall-clock limits on operations, chosen over `signal.alarm` to be compatible with the non-main threads that Gradio uses. The token-limit decorator serialises each DataFrame row to JSON and truncates the result before it is returned to the LLM context, preventing runaway context expansion from large table scans.

The `Table` base class in `definition/base/table.py` extends Pandera's `DataFrameModel` to add primary-key and foreign-key annotations as class-level metadata. Subclasses declare columns as typed class attributes, and the `__init_subclass__` hook validates at class-creation time that every declared PK/FK column is present in the schema. The `Table.load_from_csv` method handles heterogeneous CSV inputs: it normalises column names by stripping underscores and lowercasing before matching against schema attributes, injects missing columns as `None`, and attempts typed coercion column by column, falling back silently to the original series if conversion fails. This permissive loading strategy prioritises ingestion over strict correctness, deferring Pandera validation to an optional `check_sanity` pass.

The `StructuredFunction` abstract Pydantic model in `definition/base/executable_code.py` is the critical artefact that bridges LLM output and executable Python. It contains `imports`, `function_name`, `description`, `parameters`, `body_lines`, and `return_statement` fields. The `to_code` method assembles these into a syntactically valid Python function string, automatically adding base indentation if the LLM omits it. `to_function` calls `ast.parse` for a syntax check before `exec`-ing the code into a controlled namespace that includes `pandas`, `numpy`, `random`, and standard typing imports. Three concrete subclasses specialise this model: `CheckLogic` (validates tables, returns `Dict[str, pd.Series]` of violation indices), `CorruptionLogic` (mutates tables at a given percentage, returns the modified mapping), and `QueryLogic` (queries tables, returns a `pd.DataFrame`). The `execute_sandboxed_function` utility provides subprocess-level isolation for executing these dynamically generated functions, serialising arguments and results via `pickle` and enforcing a configurable timeout via `subprocess.communicate`. The subprocess path is gated by `use_subprocess=True` and the `SANDBOXED_EXEC` environment variable to avoid recursion.

---

## Agentic Check Generation: Three-Version Architecture

The framework ships three progressively more capable agents for automated check generation, all of which consume the same `LLMSessionManager` and produce `Dict[str, CheckLogic]` outputs.

The `CheckGenerationAgentV1` in `definition/agents/check_generation_agent_v1.py` is the baseline: a single-shot LLM call that generates a `CheckBatch` structured output in one pass, with no tool access and no iteration. It is the simplest integration path and the reference benchmark for evaluation.

The `CheckGenerationAgentV2` in `definition/agents/check_generation_agent_v2.py` introduces iterative tool-augmented generation. The agent is given a full tool catalogue derived from Pydantic discriminated union types (`CheckAgentToolCall`) and is prompted to explore the database through multiple rounds of tool calls before converging on a final check set. Each iteration sends the accumulated conversation history back to the LLM and processes the returned tool call structure. The tool set exposed to the agent includes `ListTableSchemas`, `ListChecks`, `GetValidationResult`, `AddChecks`, `Validate`, `GetTableData`, `RemoveChecks`, `ExecuteQuery`, `GenerationFinished`, `ProfileTableData`, `ProfileTableColumnData`, and `GetTableColumnSchema`. The agent runs for up to `max_iterations` (default 100) before being terminated, and a `progress_callback` hook allows the Gradio layer to stream progress to the user.

The `CheckGenerationAgentV3` in `definition/agents/check_generation_agent_v3.py` adds intelligent tool routing. A `ToolRouter` class partitions the available tools into six `ToolCategory` buckets: `DATA_SCHEMA_RETRIEVAL`, `CHECK_RETRIEVAL`, `VALIDATION_RESULT_RETRIEVAL`, `CHECK_MODIFICATION`, `CHECK_EXECUTION`, and `LIFECYCLE_CONTROL`. After each tool call the router evaluates the current state and selects the appropriate next category, exposing only the tools relevant to that phase to the LLM in the next turn. This context-aware pruning reduces the LLM's decision space at each step while steering it through a structured exploration-generation-validation-refinement lifecycle.

The prompt strategy for all three agents is centralised in `definition/base/prompt_builder.py`. Every system prompt is assembled from three parts: an instruction section, a tool catalogue section (auto-derived from Pydantic union descriptions), and a guideline section containing critical constraints for the LLM. The most important constraint, repeated across all three prompt variants, is the serialisation contract for returned validation functions: keys must be table names only (never `TABLE.COLUMN`), values must be `pd.Series` of original row indices (never reset indices from merged DataFrames), and the series `.name` attribute must carry the column name. This contract reflects a hard-won correctness requirement that arose from incorrect LLM-generated index handling in merged DataFrame operations.

The corruption agent in `definition/agents/corruption_generation_agent.py` follows the same architecture as V2, generating `CorruptorBatch` structured outputs that represent systematic data corruption strategies. These corruptors serve a dual purpose: they are used in benchmark evaluation to seed known defects into clean datasets, and they can be run interactively to demonstrate what a given check is designed to catch.

---

## LLM Session Management and SAP Gen AI Hub Integration

The `LLMSessionManager` in `definition/llm/session_manager.py` is the single entry point for all LLM interactions. It manages a registry of named `LLMSession` instances, each of which holds a conversation history and a boto3 Bedrock client. The Bedrock client is created by bridging through the `sap-ai-sdk-gen` proxy: a `get_proxy_client` call constructs a SAP Gen AI Hub proxy, which is then passed to `gen_ai_hub.proxy.native.amazon.clients.Session().client()` to produce a standard boto3 Bedrock client. This proxy approach means that all LLM calls are routed through the SAP Gen AI Hub infrastructure, which handles authentication (OAuth2 client credentials via `AICORE_AUTH_URL`), model dispatch to configured deployments, and usage metering, while the client code interacts with a standard boto3 surface.

The `instructor` library wraps the Bedrock client in `instructor.Mode.BEDROCK_JSON` mode for structured output extraction. All three agent versions rely on `instructor` to parse LLM responses into Pydantic models (`CheckBatch`, `CorruptorBatch`) by injecting the JSON schema into the request and coercing the response. The `LLMProvider` enum declares two supported models: `anthropic--claude-3.7-sonnet` and `anthropic--claude-4-sonnet`. The copilot binary allows independent model selection for the interactive session and the agent workers, enabling cost optimisation by using a faster or cheaper model for check generation while keeping a capable model for the interactive conversational interface.

Configuration is entirely environment-variable-driven: `AICORE_AUTH_URL`, `AICORE_BASE_URL`, `AICORE_CLIENT_ID`, `AICORE_CLIENT_SECRET`, and `AICORE_RESOURCE_GROUP` are consumed at session creation time. These are loaded from a `.env` file via `python-dotenv` in the CLI entry points. The `LLMSessionConfig` Pydantic model reads these variables via `default_factory=lambda: os.getenv(...)`, so they can also be overridden programmatically when constructing session configs.

---

## OData Vocabulary Integration Layer

The `definition/odata/` subsystem provides a bridge between SAP OData vocabulary definitions and the Pandera check framework. The `ODataVocabularyParser` (`vocabulary_parser.py`) parses OData XML/JSON vocabulary documents and extracts validation term definitions. The `ODataTermConverter` (`term_converter.py`) maps those vocabulary terms — such as `IsDigitSequence`, `IsUpperCase`, or `IsFiscalYear` — to Pandera checks. The `ODataTableGenerator` (`table_generator.py`) consumes OData `$metadata` documents, either from a URL or a local file, and dynamically generates `Table` subclasses with the appropriate column declarations, primary keys, and foreign keys. The `DatabaseIntegration` class (`database_integration.py`) ties these together, allowing a `Database` instance to be populated with table schemas and rule-based checks derived directly from OData metadata. This subsystem is the primary mechanism by which the copilot can be configured against SAP S/4HANA entities like `I_JournalEntryItem` (ACDOCA) without hand-coding Python schema definitions.

---

## Mangle Datalog: Service Registry and Field Classification

The project uses Mangle Datalog specifications in two distinct capacities. In `mangle/a2a/mcp.mg`, Mangle encodes the MCP service registry, tool routing, quality thresholds, and most critically, the S/4HANA Finance field classification rules. The service registry maps logical service identifiers (e.g., `dcc-quality`, `odata-vocab`) to their MCP endpoint URLs and capability names, and intent-routing rules derive which endpoint to call for a given action class. Quality thresholds define pass/fail criteria for completeness (95%), accuracy (99%), and consistency (98%).

The field classification section is substantial: it encodes recognition patterns for ACDOCA (`I_JournalEntryItem`) fields across five semantic categories — dimensions (groupable fields such as `BUKRS`, `GJAHR`, `HKONT`, `KOSTL`), measures (aggregatable amounts such as `HSL`, `WSL`, `KSL`, `DMBTR`), currency reference fields (`RHCUR`, `RWCUR`, `WAERS`), semantic key fields (`BELNR`, `BUZEI`), and subledger fields (`KUNNR`, `LIFNR`, `ANLN1`). Each predicate matches against lowercase substrings of column names, covering both SAP technical names and common English-language aliases. A `suggest_finance_annotation` derived rule then produces the appropriate OData vocabulary annotation for any recognised field, e.g. `@Analytics.dimension: true, @Aggregation.groupable: true` for dimension fields and `@Semantics.currencyCode: true` for currency fields.

The `MangleEngine` class in `agent/data_cleaning_agent.py` provides a local in-process Mangle query interface for governance rules: it encodes the agent's `agent_can_use` and `agent_requires_approval` capability sets and returns them via a `query(predicate, *args)` method. The `MangleQueryClient` provides the remote variant, calling `mangle-query-service` at `http://localhost:9200/mcp` via JSON-RPC to resolve field classification predicates from the `.mg` files. The `domain/` subdirectory in `mangle/` contains additional Mangle files for agent governance rules referenced by the `DataCleaningAgent`.

---

## MCP Server and Agent-to-Agent Protocol

The `mcp_server/server.py` (31 KB) exposes the copilot's capabilities as a Model Context Protocol server. It is implemented as a raw `http.server.HTTPServer`/`BaseHTTPRequestHandler` rather than depending on an MCP SDK, keeping the runtime dependency footprint minimal. The server handles `tools/list` and `tools/call` JSON-RPC 2.0 methods. Exposed tools include data quality analysis, schema analysis, data profiling, anomaly detection, and `mangle_query` for evaluating Datalog predicates. The server is also capable of fan-out: it reads remote MCP endpoint addresses from environment variables and proxies unhandled tool calls downstream, implementing a lightweight A2A (agent-to-agent) mesh. Request sizes are capped at 1 MB (`MCP_MAX_REQUEST_BYTES`), top-K results are capped at 100, and remote endpoint fan-out is capped at 25 to prevent resource exhaustion. The `normalize_mcp_endpoint` utility ensures all outbound MCP URLs carry the `/mcp` path suffix regardless of how they are configured.

---

## Runtime Entry Points and Deployment Surfaces

Three distinct runtime surfaces are provided. The interactive copilot (`bin/copilot.py`) instantiates a database, loads data from either CSV files or the RelBench dataset download path, creates an `InteractiveSession`, and starts a Gradio web interface on a configurable port (default 7860). It supports two built-in database configurations: `rel-stack` (RelBench Stack Exchange, seven tables) and `finsight` (a FinSight machine-readable package, loaded from the SAP OSS docs archive). The `--table-scopes` flag restricts which tables the agent explores, enabling cost control for large schemas.

The batch agent workflow (`bin/agent_workflow.py`) runs the check generation pipeline non-interactively, iterating across all tables in the configured database, saving generated checks and evaluation metrics to a results directory. It supports all three agent versions via `--version v1/v2/v3` and accepts `--max-iterations` for V2/V3 runs.

The REST API (`bin/api.py`) is a FastAPI application that exposes the `InteractiveSession` as a `/api/chat` POST endpoint, a `/api/clear` endpoint to reset conversation history, and a `/api/status` endpoint. CORS is configured via the `CORS_ALLOWED_ORIGINS` environment variable (comma-separated origins); if a wildcard is present `allow_credentials` is forced off to comply with browser CORS policy. The session is initialised on server startup from the same environment variables as the copilot. The frontend Angular application communicates with this server.

---

## Frontend: Angular 21 with SAP UI5 Web Components

The `frontend/` workspace is an Angular 21.1 application built against the Angular CLI 21.1 toolchain and bundled with `@angular/build`. The UI component library is `@ui5/webcomponents` 2.19.x — the standard SAP Fiori Web Components implementation — covering layout, typography, form, and navigation components. This choice aligns the frontend with SAP Fiori design guidelines and Horizon theming without requiring a separate design system. The application communicates with the FastAPI backend over REST. Testing uses `vitest` 4.x rather than Karma/Jasmine, consistent with modern Angular project conventions. The `.snyk` policy file indicates that Snyk dependency scanning is configured for the frontend workspace.

---

## Software Bill of Materials

### Python Runtime Dependencies

| Package | Version Constraint | Role |
|---|---|---|
| `sap-ai-sdk-gen` | ≥ 5.4.5 | SAP Gen AI Hub proxy client |
| `instructor[bedrock]` | ≥ 1.10.0 | Structured output extraction from Bedrock |
| `boto3` / `aioboto3` | ≥ 1.38.27 / ≥ 15.0.0 | AWS Bedrock client (sync / async) |
| `langchain` | ≥ 0.3.27 | LLM orchestration utilities |
| `langchain-aws` | ≥ 0.2.27 | LangChain Bedrock integration |
| `langchain-community` | ≥ 0.3.27 | Community LangChain tools |
| `langchain-core` | ≥ 0.3.73 | LangChain core abstractions |
| `gradio` | ≥ 5.42.0 | Interactive web UI (copilot surface) |
| `pandera[pandas]` | ≥ 0.25.0 | DataFrame schema validation |
| `pandas` | ≥ 2.2.0, <2.3 | Tabular data engine |
| `pydantic` | (transitive via instructor) | Structured data models |
| `numpy` | ≥ 2.1.0 | Numeric operations in generated checks |
| `sqlalchemy` | ≥ 2.0.41 | Database abstraction for RelBench integration |
| `relbench` | ≥ 1.1.0 | Benchmark dataset provider |
| `frictionless` | ≥ 5.18.1 | Data package / schema validation |
| `networkx` | ≥ 3.3 | Graph operations (used in Kùzu / schema analysis) |
| `ydata-profiling` | == 4.15.1 | Data profiling engine |
| `loguru` | ≥ 0.7.3 | Structured logging |
| `python-dotenv` | ≥ 1.1.1 | `.env` file loading |
| `pyyaml` | ≥ 6.0.2 | YAML config parsing |
| `tabulate` | ≥ 0.9.0 | DataFrame pretty-printing |
| `black` | ≥ 25.1.0 | Code formatting (also used at runtime for generated code) |
| `ipykernel` | ≥ 6.30.0 | Jupyter kernel support |
| `setuptools` | ≥ 80.9.0 | Build backend |

### Frontend Runtime Dependencies

| Package | Version | Role |
|---|---|---|
| `@angular/core` et al. | 21.1.6 | Angular framework |
| `@ui5/webcomponents` | ^2.19.2 | SAP Fiori Web Components |
| `@ui5/webcomponents-fiori` | ^2.19.2 | Fiori-specific patterns (ShellBar, etc.) |
| `@ui5/webcomponents-icons` | ^2.19.2 | SAP icon library |
| `rxjs` | ~7.8.0 | Reactive programming |

### Dev / Tooling

| Tool | Role |
|---|---|
| `uv` | Python package resolver and virtual environment manager |
| `ruff` | Python linting and formatting (line-length 120) |
| `@angular/cli` 21.1.5 | Angular build and serve |
| `vitest` 4.x | Frontend unit testing |
| `snyk` | Frontend dependency vulnerability scanning (`.snyk` policy) |

---

## Benchmark and Evaluation Subsystem

The `definition/benchmark/` directory contains two sub-packages: `gen/` for generating synthetic corrupted datasets and `eval/` for computing evaluation metrics. The evaluation layer compares the set of checks generated by the agent against a reference set of known defects, computing precision, recall, and F1 metrics. The `CorruptionGenerationAgent` creates paired datasets (clean + corrupted) that serve as ground truth for benchmark runs. The `download_relbench_data.py` utility in `bin/` automates the acquisition of the RelBench Stack Exchange, Formula 1, and clinical trial datasets for local evaluation runs. This benchmark infrastructure allows the three agent versions to be compared quantitatively and supports regression detection as the LLM models or prompts evolve.

---

## Data Product Contract and Governance

The `data_products/data_cleaning_service.yaml` file is an ODPS 4.1 data product descriptor that governs how this service is exposed within an SAP data mesh. The service declares three output ports: a cleaning suggestions API, a validation rules API, and a transformation code generator — all marked `dataSecurityClass: internal`. The input ports are marked `confidential` because they receive raw financial or business data, and all ports carry `x-llm-policy: routing: vllm-only`, enforcing that no data crosses to cloud-hosted LLM endpoints. The `x-regulatory-compliance` extension lists `MGF-Agentic-AI`, `AI-Agent-Index`, and `GDPR-Data-Processing` as applicable frameworks, with `autonomyLevel: L2` and `requiresHumanOversight: true`. The `x-prompting-policy` extension embeds the system prompt directly in the YAML, specifying that the model must never expose raw data values in responses and that all processing must remain on-premise. The `registry.yaml` in `data_products/` registers this descriptor in the data product catalogue.

---

## Security Posture

Several properties of this system require careful assessment before production deployment. The most significant is the use of `exec()` in `StructuredFunction.to_function()` to execute LLM-generated Python code within the main process. The `execute_sandboxed_function` utility does provide subprocess isolation as an alternative path, but the default in `StructuredFunction.to_function` itself is in-process `exec`. This means that a malicious or adversarially-crafted LLM response could execute arbitrary Python code with the full privileges of the copilot process. The subprocess path with `use_subprocess=True` is the safer route and should be the enforced default in any deployment that accepts external or untrusted input.

The bearer-token-based authentication to SAP Gen AI Hub is handled via OAuth2 client credentials (`AICORE_CLIENT_ID` / `AICORE_CLIENT_SECRET`) stored in a `.env` file. In containerised deployments these should be injected as mounted secrets or a secrets manager rather than plain-text environment files. The `.env` file is not present in the repository (only referenced in documentation), which is correct, but the risk must be explicitly managed in deployment pipelines.

The MCP server (`mcp_server/server.py`) binds on a plain HTTP listener with no authentication mechanism. It is intended for internal service-mesh use only, but if exposed beyond the loopback interface it would allow unauthenticated tool invocation including `mangle_query` predicates and data profiling operations. Network-level controls must confine it to an internal service boundary.

The `ignoreIntegrity` consideration noted in the previous SAC assessment does not apply here, but analogously, the `data_products/data_cleaning_service.yaml` sets `retentionPolicy: no-storage` and `auditLevel: full`. Ensuring these policies are actually enforced in the deployed Gen AI Hub configuration — and not merely declared in the YAML descriptor — is a pre-production verification item.

---

## Integration Topology

In its reference deployment the system forms a four-node topology. The Python backend (copilot/API) is the central processing node, holding all data in memory and hosting the Gradio or FastAPI surface. The SAP Gen AI Hub (on BTP) is the LLM provider, reached via the `sap-ai-sdk-gen` proxy. The OData Vocabulary discovery service (`http://localhost:9150`) and the Mangle query service / Elasticsearch field cache (`http://localhost:9200`) are sidecar services that the `DataCleaningAgent` queries for field classification and schema discovery, with graceful fallback when either is unavailable. The Angular frontend communicates with the FastAPI server via REST, consuming the `/api/chat` endpoint to present a Fiori-compliant UI. The MCP server (`http://localhost:9110`) is an optional surface that exposes the copilot tools to external AI agents over the A2A JSON-RPC protocol.

For the benchmark use case the topology simplifies: the batch agent workflow runs entirely locally, loading data from CSV or RelBench, generating checks via the LLM, executing them against in-memory DataFrames, and writing evaluation output to the configured results directory with no web surface required.

---

## Assessment Summary

`data-cleaning-copilot` is a well-structured research and engineering tool that occupies a distinct position in the SAP OSS estate: it applies agentic AI to the unglamorous but high-value problem of automated data quality check generation for relational databases, with a clear path to integration with SAP S/4HANA Finance data via the OData vocabulary and Mangle field-classification subsystems. The three-version agent architecture provides a clear progression from single-shot generation through iterative tool use to context-aware routing, and the structured-function model that bridges LLM output to executable Python is an elegant design that reduces hallucination risk by constraining the LLM to produce structured JSON rather than free-form code strings.

The following items should be addressed before any production or customer-facing deployment. First, the in-process `exec()` path in `StructuredFunction.to_function` must be replaced with the subprocess-isolated `execute_sandboxed_function` as the default execution path; without this, any prompt-injection in LLM-generated check code executes with full process privileges. Second, the MCP server must have an authentication layer added before it is exposed beyond loopback; the current plain-HTTP, no-auth listener is appropriate only for local development. Third, the `pandas` pin at `<2.3` and the exact `ydata-profiling==4.15.1` pin indicate known compatibility constraints that should be documented and tracked against upstream release timelines. Fourth, the `langchain` dependency family (four packages) introduces a broad transitive dependency surface for functionality that is not yet heavily used in the framework proper; if LangChain usage grows, the scope of this surface should be consciously managed. Fifth, the `kuzu/` embedded graph database (2,073 files) is a large unexplained artefact; its role in the system should be documented or, if it is a vendored static asset, it should be excluded from the Python package distribution.

---

*Prepared for SAP engineering assessment. Document reflects codebase state as read from `src/generativeUI/data-cleaning-copilot-main`.*
