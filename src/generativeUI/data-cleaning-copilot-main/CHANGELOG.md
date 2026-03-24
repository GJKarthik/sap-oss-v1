# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- OpenTelemetry distributed tracing support (`definition/tracing.py`)
- Rate limiting module with sliding window algorithm (`definition/rate_limiting.py`)
- Load testing suite with Locust integration (`tests/load_test.py`)
- OpenAPI 3.1 specification (`docs/openapi.yaml`)
- ODPS 4.1 data product descriptor (`data_products/data_cleaning_service.yaml`)
- Mangle Datalog governance rules (`mangle/domain/agents.mg`, `mangle/a2a/routing.mg`)

## [0.1.0] - 2026-03-25

### Added

#### Core Framework
- `CheckLogic` class for defining validation rules as executable Python code
- `CorruptionLogic` class for adversarial testing of validation checks
- Subprocess sandbox for secure execution of LLM-generated code
- Database abstraction layer with table data management
- Check result store for tracking validation outcomes

#### Agent Architecture
- V1 Agent: Non-iterative batch check generation
- V2 Agent: Iterative generation with validation feedback
- V3 Agent: Advanced iterative with custom query capabilities
- Base agent class with common tool handlers
- Progress callback support for UI integration

#### MCP Server
- JSON-RPC 2.0 compliant MCP protocol implementation
- 9 MCP tools: data_quality_check, schema_analysis, data_profiling, anomaly_detection, generate_cleaning_query, ai_chat, mangle_query, kuzu_index, kuzu_query
- 3 MCP resources: mangle://facts, kuzu://schema, data://profile
- Bearer token authentication with constant-time comparison
- Host bypass for internal service mesh communication
- Health endpoint at `/health`
- Metrics endpoint at `/metrics`

#### Observability
- Prometheus metrics collection with 12 metric types
- Structured logging with Loguru (JSON + human-readable formats)
- Health check utilities for database, LLM, and MCP components

#### Security
- Subprocess isolation for all LLM-generated code execution
- Import allowlist (pandas, numpy, re, datetime, etc.)
- Call blocklist (exec, eval, compile, open, __import__)
- Memory and timeout limits for sandbox execution
- MCP authentication with `MCP_AUTH_TOKEN` environment variable
- `MCP_AUTH_REQUIRED` mode to prevent accidental unauthenticated deployment

#### Documentation
- Comprehensive API documentation (`docs/API.md`)
- Deployment guide with Docker and Kubernetes examples (`docs/DEPLOYMENT.md`)
- Environment configuration template (`.env.example`)
- Technical assessment document (`TECHNICAL-ASSESSMENT.md`)

#### Testing
- MCP server integration tests (35+ test cases)
- Agent workflow integration tests (25+ test cases)
- End-to-end workflow tests (30+ test cases)
- Mock LLM response generator for testing
- Sandbox security enforcement tests

### Security

- All code execution isolated in subprocess sandbox
- No in-process exec fallback (deprecated and ignored)
- Bearer token authentication for MCP server
- Cypher query write operations blocked
- Request size limits enforced

## [0.0.1] - 2026-01-15

### Added
- Initial project structure
- Basic check generation prototype
- Gradio UI for interactive sessions
- SAP AI Core integration for LLM access

---

## Upgrade Guide

### From 0.0.1 to 0.1.0

#### Breaking Changes

1. **Subprocess Isolation Enforced**
   
   The `use_subprocess=False` parameter is now deprecated and ignored. All LLM-generated code executes in a subprocess sandbox. If you were relying on in-process execution for debugging, use the new `DEBUG_SANDBOX=true` environment variable to enable verbose sandbox logging instead.

2. **MCP Authentication Required in Production**
   
   Set `MCP_AUTH_TOKEN` environment variable before deployment. For development, authentication is optional but recommended.

3. **Agent Base Class**
   
   Custom agents should now extend `BaseCheckGenerationAgent` instead of implementing tool handlers directly.

#### Migration Steps

```python
# Before (0.0.1)
from definition.agents.check_generator_v3 import CheckGeneratorV3
agent = CheckGeneratorV3(database, session_manager, config)

# After (0.1.0) - same interface, but base class provides common handlers
from definition.agents.check_generator_v3 import CheckGeneratorV3
agent = CheckGeneratorV3(database, session_manager, config)
# Now inherits handle_list_table_schemas(), handle_validate(), etc.
```

#### New Environment Variables

```bash
# Required for production
MCP_AUTH_TOKEN=your-secret-token
MCP_AUTH_REQUIRED=true

# Optional observability
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
LOG_FORMAT=json
LOG_LEVEL=INFO

# Optional rate limiting
RATE_LIMITING_ENABLED=true
RATE_LIMIT_GLOBAL=1000,60
```

---

[Unreleased]: https://github.com/SAP/data-cleaning-copilot/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/SAP/data-cleaning-copilot/compare/v0.0.1...v0.1.0
[0.0.1]: https://github.com/SAP/data-cleaning-copilot/releases/tag/v0.0.1