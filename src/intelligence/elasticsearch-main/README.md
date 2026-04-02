# Elasticsearch for SAP AI Services

Deployment infrastructure for `elasticsearch-0` — the Elasticsearch StatefulSet
running in the `sap-ai-services` namespace on Kyma BTP.

**In-cluster URL:** `http://elasticsearch.sap-ai-services.svc.cluster.local:9200`  
**Image:** `ie-coe-team.common.repositories.cloud.sap/vanilla-elasticsearch:8.19.3`  
**Cluster name:** `sap-elasticsearch`

---

## Repository structure

```
elasticsearch-main/
├── Dockerfile                   # SAP ES image wrapper
├── docker-compose.yml           # Local development
├── config/
│   └── elasticsearch.yml        # ES cluster config (also in configmap.yaml)
├── es_mappings/                 # Index schema definitions
│   ├── odata_entity_index.json  # SAP OData entity index (with vector field)
│   ├── entity_metadata_indices.json
│   └── query_cache_index.json
└── deploy/
    └── kyma/
        ├── statefulset.yaml     # StatefulSet + headless Service + ClusterIP Service
        ├── configmap.yaml       # elasticsearch-config + sap-elasticsearch-config
        ├── secret.yaml          # elasticsearch-credentials template
        └── networkpolicy.yaml   # NetworkPolicy + Istio PeerAuthentication
```

---

## Deploy to Kyma

### First-time setup

```bash
# 1. Create credentials secret (once)
kubectl create secret generic elasticsearch-credentials \
  --namespace sap-ai-services \
  --from-literal=ELASTIC_PASSWORD="$(openssl rand -hex 16)"

# 2. Apply ConfigMaps
kubectl apply -f deploy/kyma/configmap.yaml

# 3. Apply network policies
kubectl apply -f deploy/kyma/networkpolicy.yaml

# 4. Deploy the StatefulSet
kubectl apply -f deploy/kyma/statefulset.yaml
```

### Verify

```bash
# Check pod status
kubectl get pod elasticsearch-0 -n sap-ai-services

# Check cluster health
kubectl exec -n sap-ai-services elasticsearch-0 -- \
  curl -s http://localhost:9200/_cluster/health | python3 -m json.tool

# List indices
kubectl exec -n sap-ai-services elasticsearch-0 -- \
  curl -s http://localhost:9200/_cat/indices?v
```

---

## Index mappings (`es_mappings/`)

Pre-defined index schemas to apply after deployment:

```bash
# Create the OData entity index (used by es-mcp for SAP business data)
kubectl exec -n sap-ai-services elasticsearch-0 -- \
  curl -s -X PUT http://localhost:9200/odata-entities \
  -H 'Content-Type: application/json' \
  -d @es_mappings/odata_entity_index.json
```

| File | Index | Purpose |
|------|-------|---------|
| `odata_entity_index.json` | `odata-entities` | SAP OData entities with vector embeddings (1536-dim) |
| `entity_metadata_indices.json` | `entity-metadata` | Property-level SAP metadata |
| `query_cache_index.json` | `query-cache` | Cached query results |

> **Note:** The vector field `display_text_embedding` uses 1536 dims (text-embedding-3-small).
> If using `ai_semantic_search` from `es-mcp` (which generates 3072-dim vectors via
> text-embedding-3-large), update `dims` to `3072` before creating the index.

---

## Local development

```bash
# Start ES locally
docker compose up -d

# Check health
curl http://localhost:9200/_cluster/health

# Stop
docker compose down
```

---

## Istio / mTLS

`elasticsearch-0` has the Istio sidecar injected (`istio.io/rev: default`).
The global Kyma mesh policy is **STRICT** mTLS.

The `networkpolicy.yaml` includes a `PeerAuthentication` resource that sets
**PERMISSIVE** mode on ports 9200/9300, allowing plain HTTP from non-Istio pods
(e.g. `es-mcp` which has `sidecar.istio.io/inject: "false"`).

Istio-injected pods (e.g. `ai-core-pal-agent`) will still use mTLS automatically.

---

## Cluster state (as of 2026-04-02)

| Resource | Details |
|----------|---------|
| StatefulSet | `elasticsearch` (1 replica) |
| Pod | `elasticsearch-0` |
| PVC | `elasticsearch-data-elasticsearch-0` (10Gi, storageClass: default) |
| Services | `elasticsearch` (ClusterIP :9200/:9300), `elasticsearch-headless` (None) |
| Indices | `btp-ai-suite` (5 docs), `sap_vec_test` (3 docs), `sap_mcp_audit` (9 docs) |