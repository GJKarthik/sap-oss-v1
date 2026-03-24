# Technical Assessment: `data-cleaning-copilot`

**Package:** `@sap/data-cleaning-copilot` v0.1.0  
**Author:** SAP SE  
**License:** Apache-2.0  
**Repository:** Internal SAP development  
**Runtime requirement:** Python ≥ 3.10, Node.js ≥ 18 (for MCP server)

---

## Purpose and Positioning

`data-cleaning-copilot` is an AI-powered data quality validation framework that leverages Large Language Models to automatically generate, validate, and maintain data quality checks across enterprise databases. Its primary purpose is to transform the traditionally manual and error-prone process of writing data validation rules into an automated, intelligent workflow that can adapt to schema changes, discover edge cases, and maintain comprehensive test coverage.

The system operates through a multi-agent architecture where LLM-based agents iterate through database schemas, profile data distributions, identify potential quality issues, and generate Python-based validation checks that execute in a sandboxed environment. The framework is designed for enterprise use cases including financial data reconciliation, regulatory compliance validation, and master data quality management.

The project is licensed under Apache-2.0 with SPDX headers on all source files. All API calls to SAP AI Core or third-party LLM providers are governed by separate service agreements.

---

## Repository Layout and Architecture

The repository is structured as a Python package with an embedded MCP (Model Context Protocol) server for LLM tool integration:

```
data-cleaning-copilot-main/
├── definition/                    # Core Python package
│   ├── agents/                    # LLM agent implementations
│   │   ├── base_agent.py          # Common agent base class
│   │   ├── check_generator_v1.py  # Non-iterative batch generator
│   │   ├── check_generator_v2.py  # Iterative generator with feedback
│   │   └── check_generator_v3.py  # Advanced iterative with query tools
│   ├── base/                      # Core data structures
│   │   ├── executable_code.py     # CheckLogic, CorruptionLogic classes
│   │   └── database.py            # Database abstraction
│   ├── llm/                       # LLM integration layer
│   │   ├── session_manager.py     # Session lifecycle management
│   │   └── models.py              # Pydantic models for LLM I/O
│   ├── observability.py           # Prometheus metrics + logging
│   ├── tracing.py                 # OpenTelemetry integration
│   └── rate_limiting.py           # Request rate limiting
├── mcp_server/                    # Model Context Protocol server
│   └── server.py                  # HTTP server with tool handlers
├── data_products/                 # ODPS data product contracts
│   └── data_cleaning_service.yaml # ODPS 4.1 descriptor
├── mangle/                        # Datalog governance rules
│   ├── domain/                    # Agent-specific rules
│   │   └── agents.mg              # Autonomy and routing rules
│   └── a2a/                       # Agent-to-agent protocols
│       └── routing.mg             # MCP mesh routing
├── docs/                          # Documentation
│   ├── API.md                     # REST/MCP API reference
│   ├── DEPLOYMENT.md              # Operations guide
│   └── openapi.yaml               # OpenAPI 3.1 specification
├── tests/                         # Test suites
│   ├── test_mcp_server_integration.py
│   ├── test_agent_workflow_integration.py
│   ├── test_e2e_workflow.py
│   └── load_test.py
├── sample_data/                   # Sample databases
├── CHANGELOG.md                   # Release history
├── CONTRIBUTING.md                # Contribution guidelines
├── CODE_OF_CONDUCT.md             # Community standards
└── pyproject.toml                 # Package configuration
```

---

## Core Validation Framework

### CheckLogic: The Validation Primitive

The fundamental unit of work in the framework is the `CheckLogic` class, which encapsulates a single data validation rule as an executable Python function. Each `CheckLogic` instance contains:

- **function_name**: A unique identifier following the convention `check_{table}_{column}_{rule_type}`
- **description**: Human-readable explanation of what the check validates
- **parameters**: Function signature, always `tables: Mapping[str, pd.DataFrame]`
- **scope**: List of (table, column) tuples that the check inspects
- **imports**: Additional Python imports required by the check body
- **body_lines**: The actual Python code that performs validation
- **return_statement**: Returns a violations dictionary mapping table names to violation indices
- **sql**: Optional SQL representation for documentation and portability

The `to_validation_function()` method compiles the check into an executable callable. Critically, all execution occurs in a **subprocess sandbox** that:
- Blocks dangerous imports (`os`, `sys`, `subprocess`, `shutil`, etc.)
- Blocks dangerous calls (`exec`, `eval`, `compile`, `open`, etc.)
- Enforces memory limits (configurable, default 512MB)
- Enforces timeout limits (configurable, default 30 seconds)
- Runs with restricted builtins (no `__import__`, no `globals`, no `locals`)

This security model ensures that LLM-generated code cannot escape the sandbox or access system resources.

### CorruptionLogic: Adversarial Testing

The framework also supports `CorruptionLogic` instances, which are the inverse of checks: they deliberately introduce data quality issues to validate that checks can detect them. This enables mutation testing where each check is verified against synthetic corruptions that it should catch.

---

## Agent Architecture

The check generation process is driven by LLM agents that operate in a tool-use paradigm. The agent receives a database context and iteratively calls tools to explore schemas, profile data, and generate validation checks.

### Agent Versions

**V1 Agent (Non-Iterative)**
- Single-shot generation: receives schema, generates all checks at once
- Fastest but least accurate
- Best for small, well-understood datasets
- No feedback loop from validation results

**V2 Agent (Iterative with Validation)**
- Multi-turn conversation: generates checks, validates, refines
- Sees validation results and can fix failing checks
- Medium accuracy, medium cost
- Best for datasets with moderate complexity

**V3 Agent (Advanced Iterative)**
- Full tool access including custom queries
- Can execute ad-hoc SQL-like queries to investigate data patterns
- Highest accuracy, highest cost
- Best for complex datasets with unknown quality issues

### Common Tool Set

All agents have access to the following tools via the base agent class:

| Tool | Purpose |
|------|---------|
| `ListTableSchemas` | Retrieve schema definitions for all tables |
| `ListChecks` | List currently registered validation checks |
| `GetCheck` | Get details of a specific check |
| `GetValidationResult` | Retrieve violations for a specific check |
| `Validate` | Run all checks and return summary |
| `GetTableData` | Retrieve sample data from a table |
| `ProfileTableData` | Get statistical profile of a table |
| `ProfileTableColumnData` | Get detailed profile of a column |
| `GetTableColumnSchema` | Get schema for a specific column |
| `AddChecks` | Register new validation checks |
| `RemoveChecks` | Unregister validation checks |
| `GenerationFinished` | Signal completion of generation |

V3 agents additionally have:
| Tool | Purpose |
|------|---------|
| `ExecuteQuery` | Run custom queries on the data |

---

## MCP Server

The Model Context Protocol server (`mcp_server/server.py`) exposes the validation framework to LLM clients via JSON-RPC 2.0 over HTTP. It implements the standard MCP methods:

- `initialize`: Establish session and negotiate capabilities
- `tools/list`: Enumerate available tools
- `tools/call`: Execute a tool
- `resources/list`: Enumerate available resources
- `resources/read`: Read a resource

### Available MCP Tools

| Tool | Description |
|------|-------------|
| `data_quality_check` | Run data quality checks on a table |
| `schema_analysis` | Analyze schema for recommendations |
| `data_profiling` | Profile data distribution |
| `anomaly_detection` | Detect anomalies in a column |
| `generate_cleaning_query` | Generate SQL to fix issues |
| `ai_chat` | General AI assistance |
| `mangle_query` | Query Mangle fact store |
| `kuzu_index` | Index schema into graph DB |
| `kuzu_query` | Query relationship graph |

### Security Features

- **Bearer Token Authentication**: `MCP_AUTH_TOKEN` environment variable
- **Required Auth Mode**: `MCP_AUTH_REQUIRED=true` prevents running without token
- **Host Bypass**: Internal hosts can bypass auth for service mesh
- **Constant-Time Comparison**: Timing-attack resistant token validation
- **Write Operation Blocking**: Cypher queries cannot mutate graph data
- **Request Size Limits**: Configurable max request body size

### Rate Limiting

- Sliding window algorithm (fairer than token bucket)
- Per-endpoint limits (100/min for tools, 200/min for resources)
- Per-client limits (20/min per IP)
- Global limits (1000/min total)
- Standard `X-RateLimit-*` headers
- `Retry-After` header on 429 responses

---

## Observability Stack

### Prometheus Metrics

The framework exposes metrics at `/metrics` in Prometheus format:

| Metric | Type | Description |
|--------|------|-------------|
| `dcc_requests_total` | Counter | Total requests by service/method/status |
| `dcc_request_latency_seconds` | Histogram | Request latency distribution |
| `dcc_checks_generated_total` | Counter | Checks generated by agent version |
| `dcc_checks_executed_total` | Counter | Checks executed by status |
| `dcc_violations_found_total` | Counter | Violations by table/check type |
| `dcc_llm_calls_total` | Counter | LLM API calls by provider/model |
| `dcc_llm_latency_seconds` | Histogram | LLM call latency |
| `dcc_llm_tokens_total` | Counter | Tokens consumed by direction |
| `dcc_sandbox_executions_total` | Counter | Sandbox executions by outcome |
| `dcc_sandbox_latency_seconds` | Histogram | Sandbox execution time |
| `dcc_active_sessions` | Gauge | Active copilot sessions |
| `dcc_build` | Info | Build version info |

### OpenTelemetry Tracing

Distributed tracing with W3C Trace Context propagation:

- OTLP exporter support (Jaeger, Zipkin compatible)
- Automatic context propagation across HTTP boundaries
- Pre-configured spans for key operations:
  - `trace_llm_call` - LLM API interactions
  - `trace_sandbox_execution` - Sandboxed code execution
  - `trace_mcp_tool_call` - MCP tool invocations
  - `trace_database_operation` - Database operations
  - `trace_check_generation` - Agent check generation
- `@traced` decorator for custom function tracing

### Structured Logging

Loguru-based logging with:
- JSON format for production (cloud logging compatible)
- Human-readable format for development
- Log rotation and retention
- Request context binding
- Configurable log levels

---

## Data Governance Integration

### Mangle Datalog Rules

The `mangle/` directory contains Datalog specifications that govern agent behavior:

**domain/agents.mg** - Agent-specific rules:
```datalog
# Data Cleaning Copilot operates at autonomy level L2
# Requires human approval for data-mutating operations
agent_autonomy_level(data_cleaning_copilot, l2).

# Tools requiring human approval
requires_approval(data_cleaning_copilot, generate_cleaning_query).
requires_approval(data_cleaning_copilot, execute_cleaning_query).

# Tools allowed without approval
auto_approved(data_cleaning_copilot, data_quality_check).
auto_approved(data_cleaning_copilot, schema_analysis).
auto_approved(data_cleaning_copilot, data_profiling).
```

**a2a/routing.mg** - Agent-to-agent routing:
```datalog
# Route sensitive data queries through vLLM (on-premise)
route_to_vllm(Query) :- 
  contains_keywords(Query, [customer, personal, confidential]).

# Route public schema queries through AI Core
route_to_aicore(Query) :- 
  \+ contains_keywords(Query, [customer, personal, confidential]).
```

### ODPS 4.1 Data Product Contract

The `data_products/data_cleaning_service.yaml` defines the service as an ODPS 4.1 compliant data product:

- **Data Security Class**: `internal` (processes enterprise data)
- **Data Governance Class**: `data-quality-tools`
- **Autonomy Level**: L2 (requires human oversight for mutations)
- **Regulatory Compliance**: MGF-Agentic-AI framework

---

## Testing Architecture

### Test Pyramid

| Layer | Framework | Coverage |
|-------|-----------|----------|
| Unit Tests | pytest + unittest | MCP handlers, utility functions |
| Integration Tests | pytest | Agent workflows, sandbox security |
| E2E Tests | pytest | Complete validation pipelines |
| Load Tests | Custom + Locust | Scalability verification |

### Test Suites

**test_mcp_server_integration.py** (35+ tests)
- Tool handler validation
- Authentication scenarios
- Request/response parsing
- Fact management
- Cypher write blocking

**test_agent_workflow_integration.py** (25+ tests)
- Base agent tool handlers
- CheckLogic generation
- Sandbox security enforcement
- Corruption logic validation

**test_e2e_workflow.py** (30+ tests)
- Complete check generation workflow
- Known violation detection
- Data profiling accuracy
- Rate limiting behavior
- Observability integration

**load_test.py**
- Configurable duration and concurrency
- Multiple test scenarios
- Latency percentile reporting
- Locust integration for distributed testing

---

## Software Bill of Materials

### Core Python Dependencies

| Package | Version | Role |
|---------|---------|------|
| `pandas` | ≥2.0.0 | DataFrame operations |
| `numpy` | ≥1.24.0 | Numerical computations |
| `pydantic` | ≥2.0.0 | Data validation models |
| `loguru` | ≥0.7.0 | Structured logging |
| `httpx` | ≥0.24.0 | Async HTTP client |

### Optional Dependencies

| Package | Version | Role |
|---------|---------|------|
| `prometheus_client` | ≥0.17.0 | Metrics collection |
| `opentelemetry-api` | ≥1.20.0 | Tracing API |
| `opentelemetry-sdk` | ≥1.20.0 | Tracing implementation |
| `opentelemetry-exporter-otlp` | ≥1.20.0 | OTLP export |
| `locust` | ≥2.15.0 | Load testing |

### Development Dependencies

| Package | Version | Role |
|---------|---------|------|
| `pytest` | ≥7.4.0 | Test framework |
| `pytest-asyncio` | ≥0.21.0 | Async test support |
| `pytest-cov` | ≥4.1.0 | Coverage reporting |
| `black` | ≥23.0.0 | Code formatting |
| `ruff` | ≥0.1.0 | Linting |
| `mypy` | ≥1.5.0 | Type checking |

### MCP Server Dependencies (Node.js)

| Package | Version | Role |
|---------|---------|------|
| `express` | ≥4.18.0 | HTTP server |
| `typescript` | ≥5.0.0 | TypeScript compiler |

---

## Security Posture

### Subprocess Sandbox

All LLM-generated code executes in a subprocess sandbox:
- **No in-process exec**: The `use_subprocess=False` option is deprecated and ignored
- **Import allowlist**: Only safe modules (pandas, numpy, re, datetime, etc.)
- **Call blocklist**: No eval, exec, compile, open, __import__
- **Resource limits**: Memory and CPU time constraints
- **Network isolation**: No network access from sandbox

### Authentication

- Bearer token authentication with constant-time comparison
- Configurable required mode prevents accidental deployment without auth
- Host bypass list for internal service mesh communication
- Health endpoint remains unauthenticated for monitoring

### Input Validation

- JSON-RPC request validation
- Parameter type checking via Pydantic
- Maximum request size limits
- Cypher query write operation blocking

---

## Integration Topology

### Standalone Mode
```
[User] → [Gradio UI] → [Agent] → [Database]
                          ↓
                    [LLM Provider]
```

### Service Mode
```
[Client] → [MCP Server:9110] → [Agent] → [Database]
                ↓                  ↓
         [Prometheus]       [LLM Provider]
                ↓
          [Grafana]
```

### Full Enterprise Mode
```
[SAP Joule] → [AG-UI Protocol]
                    ↓
            [MCP Gateway]
                    ↓
    ┌───────────────┼───────────────┐
    ↓               ↓               ↓
[data-cleaning]  [ui5-ngx]    [other agents]
[copilot MCP]    [MCP]              
    ↓               ↓
[SAP AI Core / vLLM routing via Mangle]
```

---

## Assessment Summary

`data-cleaning-copilot` is a well-engineered framework for AI-powered data quality validation. The architecture demonstrates several mature patterns:

**Strengths:**
- Clean separation between agent logic and tool handlers
- Robust subprocess sandbox for LLM-generated code
- Comprehensive observability (metrics, tracing, logging)
- Enterprise-ready security (auth, rate limiting, input validation)
- Extensive test coverage across all layers
- OpenAPI specification for API documentation

**Areas for Production Hardening:**
1. Mangle governance rules should be validated against production policy requirements
2. ODPS data product contract should be reviewed by data governance team
3. Rate limits should be tuned based on actual production load patterns
4. OpenTelemetry sampling should be configured for high-volume deployments

The framework is production-ready for internal enterprise deployment with appropriate configuration of authentication tokens, rate limits, and governance policies.

---

*Prepared for SAP engineering assessment. Document reflects codebase state as of March 2026.*