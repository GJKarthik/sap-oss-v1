# AI Core PAL — MCP Server Endpoints

## Cluster: sap-ai-services (Kyma BTP, ap11)

| Endpoint | URL | Auth |
|----------|-----|------|
| **Health** (external) | `https://ai-core-pal.c-054c570.kyma.ondemand.com/health` | None |
| **MCP** (external) | `https://ai-core-pal.c-054c570.kyma.ondemand.com/mcp` | None |
| **MCP** (in-cluster) | `http://ai-core-pal-service.sap-ai-services.svc.cluster.local/mcp` | None |

> All routes use `noAuth: true` — the gateway passes through unauthenticated.
> Internal access control is handled at the HANA Cloud layer.

## MCP Tools

| Tool | Description |
|------|-------------|
| `pal_forecast` | Time series forecasting using SAP HANA PAL |
| `pal_anomaly` | Anomaly detection |
| `pal_clustering` | K-Means clustering |
| `pal_classification` | Random Forest classification |
| `pal_regression` | Linear regression |
| `hana_tables` | Discover available PAL tables in HANA Cloud |
| `execute_sql` | Execute SQL directly on HANA Cloud |

## Usage Examples

### List tools
```bash
curl -s -X POST https://ai-core-pal.c-054c570.kyma.ondemand.com/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1,"params":{}}'
```

### Discover HANA PAL tables
```bash
curl -s -X POST https://ai-core-pal.c-054c570.kyma.ondemand.com/mcp \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "tools/call",
    "id": 2,
    "params": {
      "name": "hana_tables",
      "arguments": {}
    }
  }'
```

### Time series forecast
```bash
curl -s -X POST https://ai-core-pal.c-054c570.kyma.ondemand.com/mcp \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "tools/call",
    "id": 3,
    "params": {
      "name": "pal_forecast",
      "arguments": {
        "data": [
          {"ts": "2024-01-01", "val": 100},
          {"ts": "2024-02-01", "val": 110},
          {"ts": "2024-03-01", "val": 105}
        ],
        "horizon": 3
      }
    }
  }'
```

### Anomaly detection
```bash
curl -s -X POST https://ai-core-pal.c-054c570.kyma.ondemand.com/mcp \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "tools/call",
    "id": 4,
    "params": {
      "name": "pal_anomaly",
      "arguments": {
        "data": [10, 11, 9, 10, 100, 10, 11]
      }
    }
  }'
```

### Execute SQL on HANA Cloud
```bash
curl -s -X POST https://ai-core-pal.c-054c570.kyma.ondemand.com/mcp \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "tools/call",
    "id": 5,
    "params": {
      "name": "execute_sql",
      "arguments": {
        "sql": "SELECT TOP 5 * FROM SYS.TABLES"
      }
    }
  }'
```

## Image

`docker.io/plturrell/ai-core-pal:1.0.1` (version from health endpoint)

## Namespace

`sap-ai-services` on Kyma cluster `c-054c570.kyma.ondemand.com`