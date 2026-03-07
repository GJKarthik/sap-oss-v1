# Quick Start Guide

Get started with the OData Vocabularies Universal Dictionary in 5 minutes.

## Prerequisites

- Python 3.10+
- pip

## Installation

### 1. Clone and Setup

```bash
# Navigate to the project
cd odata-vocabularies-main

# Install dependencies (if any)
pip install aiohttp
```

### 2. Start the MCP Server

```bash
python -m mcp_server.server
```

Output:
```
OData Vocabulary MCP Server v3.0.0
Loaded 19 vocabularies with 398 terms
Listening on http://0.0.0.0:9150
```

### 3. Verify Installation

```bash
curl http://localhost:9150/health
```

Response:
```json
{
  "status": "healthy",
  "version": "3.0.0",
  "vocabularies": 19,
  "terms": 398,
  "embeddings_loaded": true
}
```

## Quick Examples

### Search for Terms

```bash
curl -X POST http://localhost:9150/mcp/tools/search_terms \
  -H "Content-Type: application/json" \
  -d '{"query": "LineItem"}'
```

### Get Term Definition

```bash
curl -X POST http://localhost:9150/mcp/tools/get_term_definition \
  -H "Content-Type: application/json" \
  -d '{"qualified_name": "UI.LineItem"}'
```

### Suggest Annotations

```bash
curl -X POST http://localhost:9150/mcp/tools/suggest_annotations \
  -H "Content-Type: application/json" \
  -d '{
    "entity": {
      "name": "Customer",
      "properties": [
        {"name": "CustomerID", "type": "Edm.String"},
        {"name": "CustomerName", "type": "Edm.String"},
        {"name": "Email", "type": "Edm.String"}
      ]
    }
  }'
```

### Classify Personal Data

```bash
curl -X POST http://localhost:9150/mcp/tools/classify_personal_data \
  -H "Content-Type: application/json" \
  -d '{
    "entity": {
      "name": "Employee",
      "properties": [
        {"name": "EmployeeID", "type": "Edm.String"},
        {"name": "FullName", "type": "Edm.String"},
        {"name": "Email", "type": "Edm.String"},
        {"name": "HealthStatus", "type": "Edm.String"}
      ]
    }
  }'
```

### Generate CDS

```bash
curl -X POST http://localhost:9150/mcp/tools/generate_cds \
  -H "Content-Type: application/json" \
  -d '{
    "entity": {
      "name": "Product",
      "properties": [
        {"name": "ProductID", "type": "Edm.String", "isKey": true},
        {"name": "ProductName", "type": "Edm.String"},
        {"name": "Price", "type": "Edm.Decimal"}
      ]
    }
  }'
```

## Using with Cline/Claude

Add to your MCP configuration:

```json
{
  "mcpServers": {
    "odata-vocabularies": {
      "command": "python",
      "args": ["-m", "mcp_server.server"],
      "cwd": "/path/to/odata-vocabularies-main"
    }
  }
}
```

Then ask:
- "Search for UI annotations for list reports"
- "What annotation should I use for a customer email field?"
- "Generate CDS for a SalesOrder entity"
- "Check if my entity has personal data"

## Docker Quick Start

```bash
# Build
docker build -t odata-vocab .

# Run
docker run -p 9150:9150 odata-vocab

# Test
curl http://localhost:9150/health
```

## Next Steps

- [Integration Guide](./integration.md) - Detailed integration patterns
- [API Reference](../api/openapi.yaml) - Complete API documentation
- [Vocabulary Reference](../vocabulary-reference.md) - All available terms