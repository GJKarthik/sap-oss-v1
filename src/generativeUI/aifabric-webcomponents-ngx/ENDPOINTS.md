# SAP AI Fabric Console — Endpoints

## Cluster: sap-ai-services (Kyma BTP, ap11)

| Endpoint | URL | Auth |
|----------|-----|------|
| **Web UI** (external) | `https://aifabric.c-054c570.kyma.ondemand.com` | JWT (login page) |
| **API Health** (external) | `https://aifabric.c-054c570.kyma.ondemand.com/api/v1/health` | None |
| **API** (in-cluster) | `http://aifabric-api-service.sap-ai-services.svc.cluster.local:8000` | JWT Bearer |
| **Web** (in-cluster) | `http://aifabric-web-service.sap-ai-services.svc.cluster.local:80` | None |

> JWT authentication is enforced inside FastAPI (not at the Kyma gateway).
> The Angular frontend handles login and attaches Bearer tokens to all API calls.

## Architecture

```
Browser
  └─► https://aifabric.c-054c570.kyma.ondemand.com   (Kyma APIRule → aifabric-web-service:80)
        └─► nginx (Angular SPA + /api/* proxy)
              └─► http://aifabric-api-service:8000     (FastAPI backend)
                    ├─► http://ai-core-pal-service:8084/mcp   (AI Core PAL — analytics tools)
                    ├─► http://es-mcp-service:9120/mcp         (Elasticsearch MCP — search/RAG)
                    ├─► HANA Cloud (hdbcli, port 443)          (vector store, session persistence)
                    └─► SAP AI Core (HTTPS, port 443)          (LLM deployments)
```

## MCP Upstream Services

| Service | In-cluster URL | Auth | Purpose |
|---------|---------------|------|---------|
| AI Core PAL | `http://ai-core-pal-service.sap-ai-services.svc.cluster.local:8084/mcp` | None | PAL analytics, forecasting, anomaly detection |
| Elasticsearch MCP | `http://es-mcp-service.sap-ai-services.svc.cluster.local:9120/mcp` | `ApiKey` (from `es-mcp-auth` secret) | Full-text + semantic search |

## Secrets Required

| Secret | Keys | Source |
|--------|------|--------|
| `aifabric-secrets` | `JWT_SECRET_KEY`, `BOOTSTRAP_ADMIN_USERNAME`, `BOOTSTRAP_ADMIN_PASSWORD` | Create before first deploy |
| `hana-credentials` | `HANA_HOST`, `HANA_PORT`, `HANA_USER`, `HANA_PASSWORD`, `HANA_SCHEMA` | Existing cluster secret |
| `sap-elasticsearch-aicore-secrets` | `AICORE_CLIENT_ID`, `AICORE_CLIENT_SECRET` | Existing cluster secret |
| `es-mcp-auth` | `MCP_API_KEY` | Existing cluster secret (used as ES MCP bearer) |

## First-time Secret Creation

```bash
# Generate a secure JWT secret
JWT_SECRET=$(openssl rand -base64 48)

kubectl create secret generic aifabric-secrets \
  -n sap-ai-services \
  --from-literal=JWT_SECRET_KEY="${JWT_SECRET}" \
  --from-literal=BOOTSTRAP_ADMIN_USERNAME='admin' \
  --from-literal=BOOTSTRAP_ADMIN_PASSWORD='<min-12-char-password>'
```

## Build & Deploy

```bash
cd src/generativeUI/aifabric-webcomponents-ngx

# Build images
docker build -f packages/api-server/Dockerfile  -t plturrell/aifabric-api:1.0.0 .
docker build -f apps/angular-shell/Dockerfile   -t plturrell/aifabric-web:1.0.0 .

# Push
docker push plturrell/aifabric-api:1.0.0
docker push plturrell/aifabric-web:1.0.0

# Create secret (first time only)
kubectl create secret generic aifabric-secrets -n sap-ai-services \
  --from-literal=JWT_SECRET_KEY="$(openssl rand -base64 48)" \
  --from-literal=BOOTSTRAP_ADMIN_USERNAME='admin' \
  --from-literal=BOOTSTRAP_ADMIN_PASSWORD='<your-password>'

# Deploy
kubectl apply -f deploy/kyma/deployment.yaml
kubectl apply -f deploy/kyma/apirule.yaml

# Verify
kubectl get pods -n sap-ai-services -l app.kubernetes.io/part-of=btp-ai-suite
kubectl logs -n sap-ai-services -l app=aifabric-api --tail=50
```

## Images

- `docker.io/plturrell/aifabric-api:1.0.0` — FastAPI backend
- `docker.io/plturrell/aifabric-web:1.0.0` — Angular + nginx frontend

## Namespace

`sap-ai-services` on Kyma cluster `c-054c570.kyma.ondemand.com`