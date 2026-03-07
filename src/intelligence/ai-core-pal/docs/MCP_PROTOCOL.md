# MCP Protocol Support

## Transport Mechanisms
- **stdio**: Local tool processes
- **HTTP/SSE**: Remote server streams
- **gRPC**: High-performance

## Tool Schema
```json
{
  "name": "calculate_embeddings",
  "description": "Generate embeddings",
  "inputSchema": { "type": "object" }
}
```

## GPU Acceleration
Tools with `gpu_accelerated: true` are automatically routed to GPU executors.