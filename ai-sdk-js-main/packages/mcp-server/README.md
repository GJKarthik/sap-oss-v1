# SAP AI SDK MCP Server

Model Context Protocol (MCP) server for SAP AI SDK with Mangle reasoning integration.

## Features

- **Full MCP Protocol Support** - Tools, Resources, Prompts
- **SAP AI Core Integration** - Chat, Embeddings, Deployments
- **Mangle Reasoning** - Rule-based routing and decision-making
- **Multiple Transports** - HTTP, SSE, WebSocket

## Quick Start

```bash
# Install dependencies
npm install

# Run the server
npm run dev -- --port=9090

# Or with ts-node
npx ts-node src/server.ts --port=9090
```

## Environment Variables

```bash
export AICORE_CLIENT_ID=your-client-id
export AICORE_CLIENT_SECRET=your-client-secret
export AICORE_AUTH_URL=https://xxx.authentication.xxx.hana.ondemand.com/oauth/token
export AICORE_BASE_URL=https://api.ai.xxx.aws.ml.hana.ondemand.com
export AICORE_RESOURCE_GROUP=default
export MCP_PORT=9090
```

## API Endpoints

### Transports

| Endpoint | Transport | Description |
|----------|-----------|-------------|
| `POST /mcp` | HTTP | JSON-RPC over HTTP |
| `GET /mcp/sse` | SSE | Server-Sent Events |
| `WS /mcp/ws` | WebSocket | Full-duplex communication |

### MCP Methods

| Method | Description |
|--------|-------------|
| `initialize` | Initialize MCP session |
| `tools/list` | List available tools |
| `tools/call` | Invoke a tool |
| `resources/list` | List available resources |
| `resources/read` | Read resource content |
| `prompts/list` | List available prompts |
| `prompts/get` | Get prompt messages |

## Tools

| Tool | Description |
|------|-------------|
| `ai_core_chat` | Chat completions via SAP AI Core |
| `ai_core_embed` | Embeddings via SAP AI Core |
| `hana_vector_search` | HANA Cloud vector similarity search |
| `list_deployments` | List AI Core deployments |
| `orchestration_run` | Run orchestration scenarios |
| `mangle_query` | Query Mangle reasoning engine |

## Resources

| URI | Description |
|-----|-------------|
| `deployment://list` | AI Core deployments |
| `mangle://facts` | Mangle fact store |
| `mangle://rules` | Mangle reasoning rules |

## Prompts

| Prompt | Description |
|--------|-------------|
| `rag_query` | RAG query template |
| `data_analysis` | Data analysis template |

## Usage with Claude Desktop

Add to `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "sap-ai-sdk": {
      "url": "http://localhost:9090/mcp",
      "transport": "http"
    }
  }
}
```

## Mangle Integration

The server integrates with Mangle reasoning rules in `../../mangle/`:

- `a2a/mcp.mg` - Service registry and routing
- `connectors/aicore.mg` - AI Core deployment rules
- `standard/rules.mg` - Audit, health, and quality rules

## Example Requests

### Initialize

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "clientInfo": { "name": "test-client", "version": "1.0" }
  }
}
```

### List Tools

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/list"
}
```

### Call Tool

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "ai_core_chat",
    "arguments": {
      "messages": "[{\"role\": \"user\", \"content\": \"Hello!\"}]"
    }
  }
}
```

## License

Apache-2.0