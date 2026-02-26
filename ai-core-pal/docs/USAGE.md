# MCP PAL Mesh Gateway - Usage Guide

## Quick Start

```bash
cd src/ainuc-be-po/bdc/mcppal-be-po-mesh-gateway/zig
zig build -Doptimize=ReleaseFast -Dgpu=true
./zig-out/bin/mcp-mesh-gateway
```

## Register MCP Server

```python
from mcppal import MeshGateway, MCPServer

gateway = MeshGateway()

# Register local tool
@gateway.tool("calculate_embeddings")
def calculate_embeddings(text: str) -> list[float]:
    return embed(text)

# Register remote MCP server
gateway.add_server(MCPServer(
    name="weather",
    url="http://weather-mcp:8080",
    transport="http"
))
```

## Use Tools

```python
# Invoke tool
result = gateway.invoke("calculate_embeddings", {"text": "Hello"})

# List available tools
tools = gateway.list_tools()
```

## Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `MCP_GATEWAY_PORT` | Gateway port | `8080` |
| `GPU_ENABLED` | Enable GPU | `true` |