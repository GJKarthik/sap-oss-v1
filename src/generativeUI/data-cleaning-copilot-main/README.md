[![REUSE status](https://api.reuse.software/badge/github.com/SAP/data-cleaning-copilot)](https://api.reuse.software/info/github.com/SAP/data-cleaning-copilot)

# data-cleaning-copilot

## About this project

This is a tool that takes in database schema and meta data describing that schema (e.g. description of the data in the tables, how the elements in the tables are connected, how the data is used) and helps users to formulate queries that can find errors or inconsistencies in the data using generative AI.

## Requirements and Setup


### Project Structure

```
data-cleaning-copilot/
├── bin/                          # Executable scripts
│   ├── copilot.py               # Interactive web interface for data exploration
│   ├── agent_workflow.py        # Automated check generation workflow
│   └── download_relbench_data.py # Utility to download RelBench datasets
├── mcp_server/                   # MCP Server (Model Context Protocol)
│   └── server.py                # JSON-RPC server with data validation tools
├── llm/                          # LLM Integration
│   └── router.py                # PII-aware routing (vLLM/AI Core)
├── hana/                         # HANA Cloud Integration
│   └── client.py                # Persistence layer for validations & audit
├── odata/                        # OData Vocabulary
│   └── vocabulary.py            # Semantic type detection & validation rules
├── graph/                        # Graph-RAG
│   └── kuzu_store.py            # KùzuDB for schema lineage
├── mangle/                       # Mangle Governance Rules
│   ├── domain/agents.mg         # Agent autonomy & PII routing rules
│   └── a2a/routing.mg           # Cross-agent communication
├── definition/                   # Core framework
│   ├── base/                    
│   │   ├── database.py          # Database APIs
│   │   ├── table.py             # Pandera table schema definitions
│   │   ├── executable_code.py   # CheckLogic and CorruptorLogic
│   │   └── llm/                 # LLM integration utilities
│   ├── impl/                    # Implementations
│   │   ├── database/            # Database schemas
│   │   │   └── rel_stack.py     # RelBench Stack Exchange
│   │   ├── check/               # Validation check implementations
│   │   └── corruption/          # Data corruption strategies
│   ├── llm/                     # LLM integration layer
│   │   ├── interactive/         # Gradio interface components
│   │   │   ├── session.py       # Interactive session management
│   │   │   └── streaming_progress.py # Progress tracking
│   │   ├── models.py            # Pydantic models for LLM operations
│   │   ├── session_manager.py   # LLM session lifecycle
│   ├── agents/                  # Agent implementations
│   │   ├── __init__.py
│   │   ├── check_generation_agent_v1.py # Baseline agent
│   │   ├── check_generation_agent_v2.py # Agent with tool usages
│   │   └── check_generation_agent_v3.py # Experimental agent with routing rules after each tool call
│   └── benchmark/               # Benchmarking utilities
│       ├── gen/                 # Data generation scripts
│       └── eval/                # Evaluation metrics
├── pyproject.toml               # Project configuration
└── README.md                    # This file
```

### Prerequisites

### Python Environment
- Python 3.12 or higher
- [uv](https://github.com/astral-sh/uv) package manager

### SAP Gen AI Hub Configuration

To use the LLM capabilities, you need access to SAP Gen AI Hub. Set up the following environment variables in a `.env` file:

```bash
# SAP Gen AI Hub Configuration
AICORE_AUTH_URL=<your-auth-url>
AICORE_BASE_URL=<your-base-url>
AICORE_CLIENT_ID=<your-client-id>
AICORE_CLIENT_SECRET=<your-client-secret>
AICORE_RESOURCE_GROUP=<your-resource-group>
```

### Installation

1. Clone the repository:
```bash
git clone <repository-url>
cd data-cleaning-copilot
```

2. Install uv if not already installed:
```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

3. Install dependencies using uv:
```bash
uv sync
```

This will create a virtual environment and install all required dependencies from `pyproject.toml`.

### Usage

### Interactive Co-pilot Interface

The interactive co-pilot provides a web-based interface for data exploration and validation:

```bash
# Basic usage with RelStack database
uv run python -m bin.copilot -d rel-stack

# Basic usage with FinSight machine-readable package
uv run python -m bin.copilot -d finsight

# With explicit FinSight machine-readable directory
uv run python -m bin.copilot -d finsight \
  --data-dir /Users/user/Documents/sap-oss/docs/Archive/machine-readable

# With custom data directory
uv run python -m bin.copilot -d rel-stack \
  --data-dir <path-to-your-data>

# With specific models and deployment IDs
uv run python -m bin.copilot -d rel-stack \
  --data-dir <path-to-your-data> \
  --session-model claude-4 \
  --agent-model claude-3.7 \
  --session-deployment-id <deployment-id-1> \
  --agent-deployment-id <deployment-id-2>

# With table scope restrictions
uv run python -m bin.copilot -d rel-stack \
  --table-scopes "Users,Posts,Comments" \
  --timeout 120 \
  --max-tokens 10000
```

#### Parameters:
- `-d, --database`: Database type (`rel-stack`, `finsight`)
- `--data-dir`: Directory containing CSV data files (optional)
- `--session-model`: Model for interactive session (`claude-3.7` or `claude-4`)
- `--agent-model`: Model for agent operations (`claude-3.7` or `claude-4`)
- `--session-deployment-id`: AI Core deployment ID for session
- `--agent-deployment-id`: AI Core deployment ID for agents
- `--table-scopes`: Comma-separated list of tables to focus on
- `--timeout`: Database operation timeout in seconds
- `--max-tokens`: Maximum tokens for LLM responses
- `--port`: Port for web interface (default: 7860)

### Automated Agent Workflow

For batch processing and evaluation:

```bash
# Basic workflow
uv run python -m bin.agent_workflow --database rel_stack

# With custom configuration
uv run python -m bin.agent_workflow \
  --database rel_stack \
  --model claude-4 \
  --deployment-id <deployment-id> \
  --max-iterations 100 \
  --version v2 \
  --timeout 120

# Focus on specific tables
uv run python -m bin.agent_workflow \
  --database rel-stack \
  --model claude-3.7 \
  --version v2
```

#### Parameters:
- `--database`: Database to analyze (`rel_stack`, `rel_f1`, `rel_trial`)
- `--model`: LLM model to use (`claude-3.7` or `claude-4`)
- `--deployment-id`: AI Core deployment ID
- `--version`: Agent version (`v1`: baseline, `v2`: with tools, `v3`: intelligent routing)
- `--max-iterations`: Maximum iterations for iterative agents
- `--timeout`: Database operation timeout
- `--table-scopes`: Focus on specific tables
- `--no-uuid`: Don't append UUID to output directory

Results are saved to the configured result directory with evaluation metrics and generated checks.


### Adding New Database Schemas
1. Create a new class in `definition/impl/database/`
2. Inherit from `Database` base class
3. Define tables using Pandera schemas
4. Register in `bin/agent_workflow.py` DATABASE_CONFIGS


## MCP Server

The Data Cleaning Copilot exposes an MCP (Model Context Protocol) server for integration with SAP AI Fabric and other clients.

### Quick Start

```bash
# Start the MCP server
uv run python -m mcp_server.server --port=9110

# Or with authentication
MCP_AUTH_TOKEN=your-secret-token uv run python -m mcp_server.server
```

### Available Tools

| Tool | Description | Autonomy |
|------|-------------|----------|
| `data_quality_check` | Run quality checks (completeness, accuracy, consistency) | Auto |
| `schema_analysis` | Analyze schema for issues and recommendations | Auto |
| `data_profiling` | Profile data distributions and patterns | Auto |
| `anomaly_detection` | Detect anomalies using statistical/ML methods | Auto |
| `generate_cleaning_query` | Generate SQL to fix data issues | Requires Approval |
| `ai_chat` | Chat with AI (PII-aware routing) | Auto |
| `kuzu_index` | Index schema into KùzuDB graph | Auto |
| `kuzu_query` | Query the schema graph | Auto |
| `mangle_query` | Query Mangle governance rules | Auto |

### Docker Deployment

```bash
cd deploy
docker-compose -f docker-compose.tier2.yml up -d data-cleaning-copilot
```

## PII-Aware LLM Routing

The copilot automatically routes LLM requests based on data sensitivity:

```
┌─────────────────────────────────────────────┐
│               User Query                     │
└─────────────────┬───────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────┐
│        LLM Router (llm/router.py)           │
│  ┌─────────────────────────────────────┐    │
│  │ 1. Check PII keywords               │    │
│  │    (customer, ssn, email, salary)   │    │
│  │ 2. Check PII patterns               │    │
│  │    (SSN, credit card, email regex)  │    │
│  │ 3. Check data classification        │    │
│  │    (confidential, restricted)       │    │
│  └─────────────────────────────────────┘    │
└─────────────────┬───────────────────────────┘
                  │
        ┌─────────┴─────────┐
        ▼                   ▼
┌───────────────┐   ┌───────────────┐
│ vLLM (On-Prem)│   │ AI Core (Cloud)│
│ PII Data      │   │ Public Data    │
└───────────────┘   └───────────────┘
```

### Configuration

```bash
# Environment variables
VLLM_URL=http://localhost:8080        # On-premise vLLM endpoint
AICORE_BASE_URL=https://...           # SAP AI Core endpoint
ENFORCE_PII_ROUTING=true              # Enable/disable PII routing
DEFAULT_LLM_BACKEND=aicore            # Default backend
```

## HANA Cloud Persistence

Validation results, approval requests, and audit logs are persisted to SAP HANA Cloud.

### Schema

```sql
DCC_STORE.VALIDATION_RESULTS   -- Validation check results
DCC_STORE.CHECK_DEFINITIONS    -- Reusable check definitions
DCC_STORE.APPROVAL_REQUESTS    -- Query approval workflow
DCC_STORE.AUDIT_LOGS           -- Audit trail with routing info
```

### Configuration

```bash
HANA_HOST=your-instance.hanacloud.ondemand.com
HANA_PORT=443
HANA_USER=your-user
HANA_PASSWORD=your-password
HANA_SCHEMA=DCC_STORE
```

## OData Vocabulary Integration

Automatic semantic type detection based on column names and OData vocabularies:

```python
from odata.vocabulary import annotate_table, get_pii_columns_for_table

# Annotate a table
annotation = annotate_table("Users", [
    {"name": "Id", "type": "INTEGER"},
    {"name": "Email", "type": "VARCHAR"},
    {"name": "FirstName", "type": "VARCHAR"},
])

# Email and FirstName are detected as PII
pii_columns = get_pii_columns_for_table("Users", columns)
# ['Email', 'FirstName']
```

### Supported Semantic Types

| Type | PII | Validation Rules |
|------|-----|------------------|
| `email` | ✓ | format_email, max_length_254 |
| `phone` | ✓ | format_phone, min_length_7 |
| `person_name` | ✓ | not_empty, max_length_100 |
| `address` | ✓ | not_empty, max_length_256 |
| `amount` | - | numeric, non_negative |
| `currency` | - | format_currency_code, length_3 |
| `uuid` | - | format_uuid, length_36 |

## Running Tests

```bash
# Run all new module tests (111 tests)
uv run pytest tests/test_hana_client.py tests/test_odata_vocabulary.py tests/test_llm_router.py -v

# Run with coverage
uv run pytest tests/ --cov=. --cov-report=term-missing
```

## Support, Feedback, Contributing

This project is open to feature requests/suggestions, bug reports etc. via [GitHub issues](https://github.com/SAP/data-cleaning-copilot/issues). Contribution and feedback are encouraged and always welcome. For more information about how to contribute, the project structure, as well as additional contribution information, see our [Contribution Guidelines](CONTRIBUTING.md).

## Security / Disclosure
If you find any bug that may be a security problem, please follow our instructions at [in our security policy](https://github.com/SAP/data-cleaning-copilot/security/policy) on how to report it. Please do not create GitHub issues for security-related doubts or problems.

## Code of Conduct

We as members, contributors, and leaders pledge to make participation in our community a harassment-free experience for everyone. By participating in this project, you agree to abide by its [Code of Conduct](https://github.com/SAP/.github/blob/main/CODE_OF_CONDUCT.md) at all times.

## Licensing

Copyright 2025 SAP SE or an SAP affiliate company and data-cleaning-copilot contributors. Please see our [LICENSE](LICENSE) for copyright and license information. Detailed information including third-party components and their licensing/copyright information is available [via the REUSE tool](https://api.reuse.software/info/github.com/SAP/data-cleaning-copilot).
