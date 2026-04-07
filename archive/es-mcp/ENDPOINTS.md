# ES MCP Server — Endpoints

## Cluster: sap-ai-services (Kyma BTP, ap11)

| Endpoint | URL | Auth |
|----------|-----|------|
| **Health** (external) | `https://es-mcp.c-054c570.kyma.ondemand.com/health` | None |
| **MCP** (external) | `https://es-mcp.c-054c570.kyma.ondemand.com/mcp` | `Authorization: ApiKey <MCP_API_KEY>` |
| **MCP** (in-cluster) | `http://es-mcp-service.sap-ai-services.svc.cluster.local:9120/mcp` | `Authorization: ApiKey <MCP_API_KEY>` |
| **Health** (in-cluster) | `http://es-mcp-service.sap-ai-services.svc.cluster.local:9120/health` | None |
| **Elasticsearch** (in-cluster only) | `http://elasticsearch.sap-ai-services.svc.cluster.local:9200` | None (xpack.security=false) |

## MCP Tools

| Tool | Description |
|------|-------------|
| `es_search` | Full-text search across any ES index |
| `es_vector_search` | kNN semantic search using dense_vector field |
| `es_index` | Index a document (create or update) |
| `es_cluster_health` | Get ES cluster health and index stats |
| `es_index_info` | Get mapping/settings for an index |
| `generate_embedding` | Generate text embedding via SAP AI Core |
| `ai_semantic_search` | End-to-end: embed query → kNN search → return results |

## Usage example (external)

```bash
# Health check
curl https://es-mcp.c-054c570.kyma.ondemand.com/health

# MCP call (requires API key)
MCP_API_KEY=$(kubectl get secret es-mcp-auth -n sap-ai-services -o jsonpath='{.data.MCP_API_KEY}' | base64 -d)

curl -s -X POST https://es-mcp.c-054c570.kyma.ondemand.com/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: ApiKey ${MCP_API_KEY}" \
  -d '{
    "jsonrpc": "2.0",
    "method": "tools/call",
    "id": 1,
    "params": {
      "name": "es_cluster_health",
      "arguments": {}
    }
  }'
```

## Image

`docker.io/plturrell/es-mcp:1.0.2`

## Namespace

`sap-ai-services` on Kyma cluster `c-054c570.kyma.ondemand.com`