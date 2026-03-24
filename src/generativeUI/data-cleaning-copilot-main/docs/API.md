# Data Cleaning Copilot API Documentation

This document describes the REST API and MCP (Model Context Protocol) interfaces provided by the Data Cleaning Copilot.

---

## Table of Contents

1. [REST API Endpoints](#rest-api-endpoints)
2. [MCP Protocol](#mcp-protocol)
3. [Authentication](#authentication)
4. [Error Handling](#error-handling)

---

## REST API Endpoints

The REST API is served by the FastAPI server (`bin/api.py`) on port 8000 by default.

### POST /api/chat

Send a message to the copilot for processing.

**Request:**
```json
{
  "message": "Generate validation checks for the Users table",
  "session_id": "optional-session-id"
}
```

**Response:**
```json
{
  "response": "I've analyzed the Users table and generated 3 validation checks...",
  "checks_generated": [
    "check_users_displayname_not_null",
    "check_users_email_format",
    "check_users_reputation_non_negative"
  ],
  "session_id": "uuid-123-456"
}
```

**Status Codes:**
- `200 OK` - Success
- `400 Bad Request` - Invalid request format
- `500 Internal Server Error` - Processing error

---

### POST /api/clear

Clear the current session history and reset the copilot state.

**Request:**
```json
{}
```

**Response:**
```json
{
  "status": "cleared",
  "message": "Session history cleared"
}
```

---

### GET /api/status

Get the current status of the copilot service.

**Response:**
```json
{
  "status": "healthy",
  "database": "rel-stack",
  "tables_loaded": 7,
  "checks_count": 15,
  "session_model": "claude-4",
  "agent_model": "claude-3.7"
}
```

---

### GET /api/checks

List all validation checks currently registered in the database.

**Response:**
```json
{
  "checks": {
    "check_users_displayname_not_null": {
      "function_name": "check_users_displayname_not_null",
      "description": "Validates that DisplayName is not null",
      "scope": [["Users", "DisplayName"]],
      "is_rule_based": false
    },
    "fk_Posts_OwnerUserId_Users_Id": {
      "function_name": "fk_Posts_OwnerUserId_Users_Id",
      "description": "Foreign key check: Posts.OwnerUserId -> Users.Id",
      "scope": [["Posts", "OwnerUserId"]],
      "is_rule_based": true
    }
  },
  "total_count": 15,
  "rule_based_count": 8,
  "generated_count": 7
}
```

---

### POST /api/validate

Run all validation checks and return the results.

**Request:**
```json
{
  "table_scopes": ["Users", "Posts"],  // optional, empty = all tables
  "include_rule_based": true           // optional, default true
}
```

**Response:**
```json
{
  "summary": {
    "total_violations": 42,
    "checks_with_violations": ["check_users_email_format", "fk_Posts_OwnerUserId"],
    "checks_without_violations": ["check_users_displayname_not_null"],
    "failed_checks": []
  },
  "results": {
    "check_users_email_format": {
      "status": "violations_found",
      "violation_count": 15,
      "sample_violations": [
        {"table": "Users", "column": "Email", "row_index": 42, "value": "invalid-email"}
      ]
    }
  }
}
```

---

### POST /api/evaluate

Evaluate check performance against a ground truth dataset.

**Request:**
```json
{
  "ground_truth_file": "/path/to/violations.csv"
}
```

**Response:**
```json
{
  "overall": {
    "precision": 0.92,
    "recall": 0.87,
    "f1_score": 0.89,
    "true_positives": 156,
    "false_positives": 14,
    "false_negatives": 24
  },
  "by_check": {
    "check_users_email_format": {
      "precision": 0.95,
      "recall": 0.88,
      "f1_score": 0.91
    }
  }
}
```

---

## MCP Protocol

The MCP (Model Context Protocol) server (`mcp_server/server.py`) exposes tools via JSON-RPC 2.0 on port 9110 by default.

### Base URL

```
http://localhost:9110/mcp
```

### Request Format

All MCP requests use JSON-RPC 2.0:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "tool_name",
    "arguments": { ... }
  }
}
```

---

### MCP Methods

#### initialize

Initialize the MCP session.

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {}
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2024-11-05",
    "capabilities": {
      "tools": {"listChanged": true},
      "resources": {"listChanged": true},
      "prompts": {"listChanged": true}
    },
    "serverInfo": {
      "name": "data-cleaning-copilot-mcp",
      "version": "1.0.0"
    }
  }
}
```

---

#### tools/list

List all available tools.

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/list",
  "params": {}
}
```

---

#### tools/call

Call a specific tool.

---

### MCP Tools

#### data_quality_check

Run data quality checks on a table.

**Arguments:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `table_name` | string | Yes | Name of the table to check |
| `checks` | string | No | JSON array of check types: `["completeness", "accuracy", "consistency"]` |

**Example:**
```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "data_quality_check",
    "arguments": {
      "table_name": "Users",
      "checks": "[\"completeness\", \"accuracy\"]"
    }
  }
}
```

**Response:**
```json
{
  "table": "Users",
  "checks": [
    {"check": "completeness", "table": "Users", "score": 97.5, "status": "PASS"},
    {"check": "accuracy", "table": "Users", "score": 99.2, "status": "PASS"}
  ],
  "overall_status": "PASS",
  "graph_context": [
    {"col_name": "Id", "col_type": "INTEGER", "relation": "own_column"},
    {"ref_table": "Posts", "ref_col": "OwnerUserId", "relation": "fk_reference"}
  ]
}
```

---

#### schema_analysis

Analyze a database schema for issues and recommendations.

**Arguments:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `schema_definition` | string | Yes | Schema definition as JSON or SQL DDL |

**Example:**
```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "tools/call",
  "params": {
    "name": "schema_analysis",
    "arguments": {
      "schema_definition": "{\"tables\": [{\"name\": \"Users\", \"columns\": [...]}]}"
    }
  }
}
```

---

#### data_profiling

Profile data to understand distributions and patterns.

**Arguments:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `table_name` | string | Yes | Name of the table to profile |
| `columns` | string | No | JSON array of column names to profile |

---

#### anomaly_detection

Detect anomalies in data using statistical methods.

**Arguments:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `table_name` | string | Yes | Name of the table |
| `column` | string | Yes | Column to analyze |
| `method` | string | No | Detection method: `zscore`, `iqr`, `isolation_forest` |

---

#### generate_cleaning_query

Generate SQL to fix data issues.

**Arguments:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `issue_description` | string | Yes | Description of the data issue |
| `table_name` | string | Yes | Target table name |
| `schema` | string | No | Table schema as JSON |

---

#### ai_chat

Chat with AI for data cleaning guidance.

**Arguments:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `messages` | string | Yes | JSON array of messages: `[{"role": "user", "content": "..."}]` |
| `context` | string | No | Additional context about the data |

---

#### mangle_query

Query the Mangle reasoning engine.

**Arguments:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `predicate` | string | Yes | Predicate to query |
| `args` | string | No | Arguments as JSON array |

**Example:**
```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "method": "tools/call",
  "params": {
    "name": "mangle_query",
    "arguments": {
      "predicate": "service_registry",
      "args": "[]"
    }
  }
}
```

---

#### kuzu_index

Index a database schema into KùzuDB for graph-based analysis.

**Arguments:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `schema_definition` | string | Yes | Schema as JSON (see format below) |
| `checks` | string | No | JSON array of quality checks to index |

**Schema Format:**
```json
{
  "tables": [
    {
      "name": "Users",
      "columns": [
        {"name": "Id", "type": "INTEGER"},
        {"name": "DisplayName", "type": "STRING"}
      ],
      "foreign_keys": [
        {"column": "ParentId", "ref_table": "Users", "ref_column": "Id"}
      ]
    }
  ]
}
```

---

#### kuzu_query

Execute a read-only Cypher query against KùzuDB.

**Arguments:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `cypher` | string | Yes | Cypher query (MATCH ... RETURN only) |
| `params` | string | No | Query parameters as JSON object |

**Example:**
```json
{
  "jsonrpc": "2.0",
  "id": 6,
  "method": "tools/call",
  "params": {
    "name": "kuzu_query",
    "arguments": {
      "cypher": "MATCH (t:DbTable)-[:HAS_COLUMN]->(c:Column) WHERE t.table_name = $name RETURN c.col_name",
      "params": "{\"name\": \"Users\"}"
    }
  }
}
```

**Note:** Write operations (CREATE, MERGE, DELETE, SET, REMOVE, DROP) are not permitted via this tool.

---

### MCP Resources

#### resources/list

List available resources.

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "method": "resources/list",
  "params": {}
}
```

**Response:**
```json
{
  "resources": [
    {"uri": "data://schemas", "name": "Database Schemas", "mimeType": "application/json"},
    {"uri": "data://quality_rules", "name": "Data Quality Rules", "mimeType": "application/json"},
    {"uri": "mangle://facts", "name": "Mangle Facts", "mimeType": "application/json"}
  ]
}
```

#### resources/read

Read a specific resource.

```json
{
  "jsonrpc": "2.0",
  "id": 8,
  "method": "resources/read",
  "params": {"uri": "mangle://facts"}
}
```

---

## Authentication

### MCP Server Authentication

The MCP server supports Bearer token authentication for production deployments.

**Environment Variables:**
| Variable | Description |
|----------|-------------|
| `MCP_AUTH_TOKEN` | If set, all requests must include this token |
| `MCP_AUTH_REQUIRED` | If `true`, fails startup if `MCP_AUTH_TOKEN` is not set |
| `MCP_AUTH_BYPASS_HOSTS` | Comma-separated list of hosts that bypass auth (default: `127.0.0.1,localhost`) |

**Request with Authentication:**
```bash
curl -X POST http://localhost:9110/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_SECRET_TOKEN" \
  -d '{"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}'
```

**Generating a Secure Token:**
```bash
# Using Python
python -c "import secrets; print(secrets.token_urlsafe(32))"

# Using OpenSSL
openssl rand -base64 32
```

---

### REST API Authentication

The REST API uses SAP Gen AI Hub credentials configured via environment variables:

| Variable | Description |
|----------|-------------|
| `AICORE_AUTH_URL` | OAuth2 token endpoint URL |
| `AICORE_BASE_URL` | Gen AI Hub base URL |
| `AICORE_CLIENT_ID` | OAuth2 client ID |
| `AICORE_CLIENT_SECRET` | OAuth2 client secret |
| `AICORE_RESOURCE_GROUP` | AI Core resource group (default: `default`) |

---

## Error Handling

### JSON-RPC Error Codes

| Code | Message | Description |
|------|---------|-------------|
| `-32700` | Parse error | Invalid JSON was received |
| `-32600` | Invalid Request | JSON is not a valid request object |
| `-32601` | Method not found | The method does not exist |
| `-32602` | Invalid params | Invalid method parameters |
| `-32603` | Internal error | Internal JSON-RPC error |
| `-32000` | Unauthorized | Authentication failed |

### HTTP Status Codes

| Code | Description |
|------|-------------|
| `200` | Success |
| `400` | Bad Request - Invalid request format |
| `401` | Unauthorized - Authentication required or failed |
| `404` | Not Found - Endpoint not found |
| `413` | Payload Too Large - Request body exceeds limit |
| `500` | Internal Server Error |

---

## Rate Limits and Constraints

| Constraint | Value | Environment Variable |
|------------|-------|---------------------|
| Max request size | 1 MB | `MCP_MAX_REQUEST_BYTES` |
| Max results per query | 100 | `MCP_MAX_TOP_K` |
| Max columns to profile | 100 | `MCP_MAX_PROFILE_COLUMNS` |
| Max remote endpoints | 25 | `MCP_MAX_REMOTE_ENDPOINTS` |
| Remote MCP timeout | 3 seconds | `MCP_REMOTE_TIMEOUT_SECONDS` |

---

## Examples

### Complete Workflow Example

```python
import requests
import json

MCP_URL = "http://localhost:9110/mcp"

def mcp_call(method, params):
    response = requests.post(MCP_URL, json={
        "jsonrpc": "2.0",
        "id": 1,
        "method": method,
        "params": params
    })
    return response.json()

# 1. Initialize
result = mcp_call("initialize", {})
print(f"Server: {result['result']['serverInfo']['name']}")

# 2. Index a schema
schema = {
    "tables": [
        {
            "name": "Users",
            "columns": [
                {"name": "Id", "type": "INTEGER"},
                {"name": "Email", "type": "STRING"}
            ]
        }
    ]
}
result = mcp_call("tools/call", {
    "name": "kuzu_index",
    "arguments": {"schema_definition": json.dumps(schema)}
})
print(f"Indexed: {result['result']}")

# 3. Run quality check
result = mcp_call("tools/call", {
    "name": "data_quality_check",
    "arguments": {"table_name": "Users"}
})
print(f"Quality: {result['result']}")
```

---

*Last updated: 2025*