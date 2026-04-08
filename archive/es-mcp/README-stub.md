# ES MCP Server

MCP (Model Context Protocol) server for the Elasticsearch instance running on Kyma under `sap-ai-services`.  
Stripped of mangle, kuzu, hana, and OpenAI integrations — talks only to the existing ES cluster and SAP AI Core.

---

## Architecture

```
MCP Client (internal)
        │
        │  POST /mcp  Authorization: ApiKey <MCP_API_KEY>
        ▼
 es-mcp-service:9120   (ClusterIP — sap-ai-services namespace)
        │
        ├──▶ elasticsearch.sap-ai-services.svc.cluster.local:9200
        │         credentials: elasticsearch-credentials / ELASTIC_PASSWORD
        │
        └──▶ SAP AI Core  (embedding generation)
                  auth:    fin-analytical-svc-rnd.authentication.ap11.hana.ondemand.com
                  base:    api.ai.prod.ap11.aws.ml.hana.ondemand.com
                  secrets: sap-elasticsearch-aicore-secrets
```

---

## Deployed Resources

| Resource | Namespace | Notes |
|---|---|---|
| `Deployment/es-mcp` | `sap-ai-services` | `docker.io/plturrell/es-mcp:1.0.0` |
| `Service/es-mcp-service` | `sap-ai-services` | ClusterIP `:9120` |
| `ConfigMap/es-mcp-config` | `sap-ai-services` | es-mcp-specific tuning |
| `Secret/es-mcp-auth` | `sap-ai-services` | MCP API key (new) |
| `Secret/dockerhub-plturrell` | `sap-ai-services` | imagePullSecret (new) |

### Reused existing cluster resources

| Resource | Keys consumed |
|---|---|
| `Secret/elasticsearch-credentials` | `ELASTIC_PASSWORD` → mapped to `ES_PASSWORD` |
| `Secret/sap-elasticsearch-aicore-secrets` | `AICORE_CLIENT_ID`, `AICORE_CLIENT_SECRET` |
| `ConfigMap/sap-elasticsearch-config` | `ES_HOST`, `AICORE_AUTH_URL`, `AICORE_BASE_URL`, `AICORE_RESOURCE_GROUP` |

---

## Cluster Endpoint

```
http://es-mcp-service.sap-ai-services.svc.cluster.local:9120
```

### Authentication

All `/mcp` requests require a static API key header:

```
Authorization: ApiKey <MCP_API_KEY>
```

**Current MCP_API_KEY** (stored in `Secret/es-mcp-auth`):
```
7a6a727e33f799768ae3a3d54c5f3e84122d9302137314840396e7260e9df63f
```

To retrieve at any time:
```bash
kubectl get secret es-mcp-auth -n sap-ai-services \
  -o jsonpath='{.data.MCP_API_KEY}' | base64 -d
```

---

## MCP Tools

| Tool | Description |
|---|---|
| `es_search` | Query DSL search against any index (max 100 results) |
| `es_vector_search` | kNN dense_vector similarity search (max k=100) |
| `es_index` | Create or overwrite a document |
| `es_cluster_health` | Cluster status: green/yellow/red, node counts, shard counts |
| `es_index_info` | Mappings and settings for an index or pattern |
| `generate_embedding` | Text → embedding vector via SAP AI Core |
| `ai_semantic_search` | End-to-end: embed query → kNN search in one call |

---

## Current Elasticsearch Indices

| Index | Key Fields |
|---|---|
| `btp-ai-suite` | `title` (text), `description` (text), `service` (keyword) |
| `sap_mcp_audit` | `tool` (text/keyword), `index` (text/keyword), `timestamp` (float), `ts_iso` (date) |

---

## Quick Test

```bash
MCP_KEY="7a6a727e33f799768ae3a3d54c5f3e84122d9302137314840396e7260e9df63f"

# Port-forward
kubectl port-forward -n sap-ai-services svc/es-mcp-service 9120:9120 &

# Health
curl http://localhost:9120/health

# tools/list
curl -s -X POST http://localhost:9120/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: ApiKey $MCP_KEY" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'

# Cluster health
curl -s -X POST http://localhost:9120/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: ApiKey $MCP_KEY" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"es_cluster_health","arguments":{}}}'

# Semantic search (requires AICORE_EMBEDDING_DEPLOYMENT_ID set)
curl -s -X POST http://localhost:9120/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: ApiKey $MCP_KEY" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ai_semantic_search","arguments":{"index":"btp-ai-suite","query":"generative AI services"}}}'
```

---

## Redeploy / Update

```bash
# Rebuild and push
cd src/intelligence/es-mcp
docker build --platform linux/amd64 -t docker.io/plturrell/es-mcp:1.0.1 .
docker push docker.io/plturrell/es-mcp:1.0.1

# Update image in deployment.yaml, then:
kubectl apply -f deploy/kyma/deployment.yaml

# Force rollout
kubectl rollout restart deployment/es-mcp -n sap-ai-services
kubectl rollout status deployment/es-mcp -n sap-ai-services
```

---

## Rotate API Key

```bash
NEW_KEY=$(openssl rand -hex 32)
kubectl create secret generic es-mcp-auth \
  --namespace sap-ai-services \
  --from-literal=MCP_API_KEY="$NEW_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment/es-mcp -n sap-ai-services
echo "New key: $NEW_KEY"
```

---

## Verified Test Results (2026-04-01)

```
Pod: es-mcp-78957fc748-bhj2p  (2/2 Running, namespace sap-ai-services)

[1] HEALTH
{"status":"healthy","service":"es-mcp","es_host":"http://elasticsearch.sap-ai-services.svc.cluster.local:9200","aicore_config_ready":true}

[2] AUTH REJECT
HTTP status: 401 ✓

[3] es_cluster_health
{"cluster_name":"sap-elasticsearch","status":"yellow","number_of_nodes":1,"number_of_data_nodes":1,"active_primary_shards":2,"active_shards":2}

[4] es_index_info
Indices found: btp-ai-suite, sap_mcp_audit