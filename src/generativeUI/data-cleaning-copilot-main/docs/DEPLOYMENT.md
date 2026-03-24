# Data Cleaning Copilot Deployment Guide

This guide covers deploying the Data Cleaning Copilot in various environments, from local development to production Kubernetes clusters.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Local Development](#local-development)
3. [Docker Deployment](#docker-deployment)
4. [Kubernetes Deployment](#kubernetes-deployment)
5. [Configuration Reference](#configuration-reference)
6. [Security Considerations](#security-considerations)
7. [Monitoring & Observability](#monitoring--observability)
8. [Troubleshooting](#troubleshooting)

---

## Prerequisites

### Required Software

| Software | Version | Purpose |
|----------|---------|---------|
| Python | ≥ 3.12 | Runtime |
| uv | Latest | Package manager |
| Docker | ≥ 24.0 | Containerization |
| kubectl | ≥ 1.28 | Kubernetes CLI |
| Helm | ≥ 3.12 | Kubernetes package manager |

### Required Credentials

- **SAP Gen AI Hub** credentials (for LLM access)
- **Container registry** credentials (for production images)

---

## Local Development

### 1. Clone and Install

```bash
# Clone the repository
git clone https://github.com/SAP/data-cleaning-copilot.git
cd data-cleaning-copilot

# Install uv if not already installed
curl -LsSf https://astral.sh/uv/install.sh | sh

# Install dependencies
uv sync
```

### 2. Configure Environment

Create a `.env` file from the example:

```bash
cp .env.example .env
```

Edit `.env` with your SAP Gen AI Hub credentials:

```bash
# SAP Gen AI Hub Configuration
AICORE_AUTH_URL=https://your-tenant.authentication.sap.hana.ondemand.com/oauth/token
AICORE_BASE_URL=https://api.ai.your-region.sap.hana.ondemand.com
AICORE_CLIENT_ID=your-client-id
AICORE_CLIENT_SECRET=your-client-secret
AICORE_RESOURCE_GROUP=default

# Optional: MCP Server Authentication
MCP_AUTH_TOKEN=your-secret-token
```

### 3. Run Services

**Interactive Copilot (Gradio UI):**
```bash
uv run python -m bin.copilot -d rel-stack --port 7860
```

**REST API Server:**
```bash
uv run python -m bin.api --port 8000
```

**MCP Server:**
```bash
python mcp_server/server.py --port=9110
```

---

## Docker Deployment

### Dockerfile

Create a `Dockerfile` in the project root:

```dockerfile
# syntax=docker/dockerfile:1.4
FROM python:3.12-slim AS base

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

# Install uv
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:$PATH"

WORKDIR /app

# Copy dependency files first for better caching
COPY pyproject.toml uv.lock ./

# Install dependencies
RUN uv sync --frozen --no-dev

# Copy application code
COPY . .

# Don't run as root
RUN useradd -m -u 1000 copilot
USER copilot

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

# Default command (can be overridden)
CMD ["uv", "run", "python", "-m", "bin.api", "--port", "8000"]
```

### Docker Compose

Create a `docker-compose.yml`:

```yaml
version: '3.8'

services:
  copilot-api:
    build:
      context: .
      dockerfile: Dockerfile
    ports:
      - "8000:8000"
    environment:
      - AICORE_AUTH_URL
      - AICORE_BASE_URL
      - AICORE_CLIENT_ID
      - AICORE_CLIENT_SECRET
      - AICORE_RESOURCE_GROUP=default
    env_file:
      - .env
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
    restart: unless-stopped

  copilot-mcp:
    build:
      context: .
      dockerfile: Dockerfile
    command: ["python", "mcp_server/server.py", "--port=9110"]
    ports:
      - "9110:9110"
    environment:
      - MCP_AUTH_TOKEN
      - MCP_AUTH_REQUIRED=true
      - MCP_AUTH_BYPASS_HOSTS=127.0.0.1,localhost,copilot-api
    env_file:
      - .env
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9110/health"]
      interval: 30s
      timeout: 10s
      retries: 3
    restart: unless-stopped

  copilot-ui:
    build:
      context: .
      dockerfile: Dockerfile
    command: ["uv", "run", "python", "-m", "bin.copilot", "-d", "rel-stack", "--port", "7860"]
    ports:
      - "7860:7860"
    environment:
      - AICORE_AUTH_URL
      - AICORE_BASE_URL
      - AICORE_CLIENT_ID
      - AICORE_CLIENT_SECRET
      - AICORE_RESOURCE_GROUP=default
    env_file:
      - .env
    depends_on:
      copilot-mcp:
        condition: service_healthy
    restart: unless-stopped

networks:
  default:
    name: copilot-network
```

### Build and Run

```bash
# Build images
docker compose build

# Start all services
docker compose up -d

# View logs
docker compose logs -f

# Stop services
docker compose down
```

---

## Kubernetes Deployment

### Namespace and Secrets

```yaml
# k8s/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: data-cleaning-copilot
  labels:
    app.kubernetes.io/name: data-cleaning-copilot
---
# k8s/secrets.yaml
apiVersion: v1
kind: Secret
metadata:
  name: aicore-credentials
  namespace: data-cleaning-copilot
type: Opaque
stringData:
  AICORE_AUTH_URL: "https://your-tenant.authentication.sap.hana.ondemand.com/oauth/token"
  AICORE_BASE_URL: "https://api.ai.your-region.sap.hana.ondemand.com"
  AICORE_CLIENT_ID: "your-client-id"
  AICORE_CLIENT_SECRET: "your-client-secret"
---
apiVersion: v1
kind: Secret
metadata:
  name: mcp-auth
  namespace: data-cleaning-copilot
type: Opaque
stringData:
  MCP_AUTH_TOKEN: "your-secure-random-token-here"
```

### ConfigMap

```yaml
# k8s/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: copilot-config
  namespace: data-cleaning-copilot
data:
  AICORE_RESOURCE_GROUP: "default"
  MCP_AUTH_REQUIRED: "true"
  MCP_AUTH_BYPASS_HOSTS: "127.0.0.1,localhost"
  MCP_MAX_REQUEST_BYTES: "1048576"
  MCP_MAX_TOP_K: "100"
```

### Deployment

```yaml
# k8s/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: copilot-api
  namespace: data-cleaning-copilot
  labels:
    app: copilot-api
spec:
  replicas: 2
  selector:
    matchLabels:
      app: copilot-api
  template:
    metadata:
      labels:
        app: copilot-api
    spec:
      serviceAccountName: copilot-sa
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
      containers:
      - name: api
        image: your-registry/data-cleaning-copilot:latest
        imagePullPolicy: Always
        command: ["uv", "run", "python", "-m", "bin.api", "--port", "8000"]
        ports:
        - containerPort: 8000
          name: http
        envFrom:
        - secretRef:
            name: aicore-credentials
        - configMapRef:
            name: copilot-config
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 5
          periodSeconds: 5
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop:
            - ALL
        volumeMounts:
        - name: tmp
          mountPath: /tmp
      volumes:
      - name: tmp
        emptyDir: {}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: copilot-mcp
  namespace: data-cleaning-copilot
  labels:
    app: copilot-mcp
spec:
  replicas: 1
  selector:
    matchLabels:
      app: copilot-mcp
  template:
    metadata:
      labels:
        app: copilot-mcp
    spec:
      serviceAccountName: copilot-sa
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
      containers:
      - name: mcp
        image: your-registry/data-cleaning-copilot:latest
        command: ["python", "mcp_server/server.py", "--port=9110"]
        ports:
        - containerPort: 9110
          name: mcp
        envFrom:
        - secretRef:
            name: mcp-auth
        - configMapRef:
            name: copilot-config
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        livenessProbe:
          httpGet:
            path: /health
            port: 9110
          initialDelaySeconds: 10
          periodSeconds: 10
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
```

### Service

```yaml
# k8s/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: copilot-api
  namespace: data-cleaning-copilot
spec:
  selector:
    app: copilot-api
  ports:
  - port: 8000
    targetPort: 8000
    name: http
  type: ClusterIP
---
apiVersion: v1
kind: Service
metadata:
  name: copilot-mcp
  namespace: data-cleaning-copilot
spec:
  selector:
    app: copilot-mcp
  ports:
  - port: 9110
    targetPort: 9110
    name: mcp
  type: ClusterIP
```

### Ingress

```yaml
# k8s/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: copilot-ingress
  namespace: data-cleaning-copilot
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - copilot.your-domain.com
    secretName: copilot-tls
  rules:
  - host: copilot.your-domain.com
    http:
      paths:
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: copilot-api
            port:
              number: 8000
      - path: /mcp
        pathType: Prefix
        backend:
          service:
            name: copilot-mcp
            port:
              number: 9110
```

### Deploy to Kubernetes

```bash
# Apply all manifests
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/secrets.yaml
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/ingress.yaml

# Check status
kubectl get pods -n data-cleaning-copilot
kubectl get svc -n data-cleaning-copilot

# View logs
kubectl logs -f deployment/copilot-api -n data-cleaning-copilot
```

---

## Configuration Reference

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `AICORE_AUTH_URL` | Yes | - | SAP Gen AI Hub OAuth2 token URL |
| `AICORE_BASE_URL` | Yes | - | SAP Gen AI Hub API base URL |
| `AICORE_CLIENT_ID` | Yes | - | OAuth2 client ID |
| `AICORE_CLIENT_SECRET` | Yes | - | OAuth2 client secret |
| `AICORE_RESOURCE_GROUP` | No | `default` | AI Core resource group |
| `MCP_AUTH_TOKEN` | No* | - | MCP server authentication token |
| `MCP_AUTH_REQUIRED` | No | `false` | Require auth even if token not set |
| `MCP_AUTH_BYPASS_HOSTS` | No | `127.0.0.1,localhost` | Hosts that bypass auth |
| `MCP_MAX_REQUEST_BYTES` | No | `1048576` | Max request body size |
| `MCP_MAX_TOP_K` | No | `100` | Max results per query |
| `CORS_ALLOWED_ORIGINS` | No | `http://localhost:3000` | Allowed CORS origins |

*Required for production deployments

### Port Reference

| Service | Default Port | Protocol |
|---------|--------------|----------|
| Gradio UI | 7860 | HTTP |
| REST API | 8000 | HTTP |
| MCP Server | 9110 | HTTP (JSON-RPC) |

---

## Security Considerations

### 1. Secrets Management

**DO NOT** commit secrets to version control. Use:

- **Kubernetes Secrets** with RBAC
- **HashiCorp Vault** for secret injection
- **AWS Secrets Manager** / **Azure Key Vault**
- **SAP Credential Store** on BTP

```bash
# Generate a secure MCP token
python -c "import secrets; print(secrets.token_urlsafe(32))"
```

### 2. Network Security

- Deploy MCP server on internal network only
- Use TLS/HTTPS for all external endpoints
- Configure network policies to restrict pod-to-pod communication

```yaml
# k8s/network-policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: copilot-network-policy
  namespace: data-cleaning-copilot
spec:
  podSelector:
    matchLabels:
      app: copilot-mcp
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: copilot-api
    ports:
    - protocol: TCP
      port: 9110
```

### 3. Sandbox Security

The copilot executes LLM-generated code in a subprocess sandbox with:

- **AST validation** before execution
- **Subprocess isolation** (never in-process exec)
- **Timeout enforcement** (default: 30 seconds)
- **Memory limits** (default: 512 MB)
- **Restricted imports** (only pandas, numpy, datetime, re, json)
- **Blocked system calls** (no file I/O, network, process spawning)

### 4. Audit Logging

All sandbox executions are logged:

```python
# Access audit log programmatically
from definition.base.executable_code import get_sandbox_audit_log

audit_entries = get_sandbox_audit_log()
for entry in audit_entries:
    print(f"{entry['timestamp']} - {entry['function_name']}: {entry['outcome']}")
```

---

## Monitoring & Observability

### Health Endpoints

| Service | Endpoint | Expected Response |
|---------|----------|-------------------|
| REST API | `GET /health` | `{"status": "healthy"}` |
| MCP Server | `GET /health` | `{"status": "healthy", "auth_enabled": true}` |

### Prometheus Metrics (Recommended)

Add prometheus-client to collect metrics:

```python
# Add to bin/api.py
from prometheus_client import Counter, Histogram, generate_latest

REQUEST_COUNT = Counter('copilot_requests_total', 'Total requests', ['method', 'status'])
REQUEST_LATENCY = Histogram('copilot_request_latency_seconds', 'Request latency')

@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type="text/plain")
```

### Logging

Configure structured logging with `loguru`:

```python
from loguru import logger
import sys

# JSON logging for production
logger.remove()
logger.add(
    sys.stdout,
    format="{time:YYYY-MM-DD HH:mm:ss} | {level} | {message}",
    level="INFO",
    serialize=True  # Output as JSON
)
```

---

## Troubleshooting

### Common Issues

#### 1. LLM Connection Failures

```
Error: Failed to get access token from AICORE_AUTH_URL
```

**Solution:** Verify credentials and network access to SAP Gen AI Hub.

```bash
# Test OAuth2 token endpoint
curl -X POST "$AICORE_AUTH_URL" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  -u "$AICORE_CLIENT_ID:$AICORE_CLIENT_SECRET"
```

#### 2. Sandbox Timeout Errors

```
Error: Function execution timed out after 30 seconds
```

**Solution:** Increase timeout for complex operations:

```python
from definition.base.database import Database

db = Database(
    database_id="my_db",
    max_execution_time=120  # 2 minutes
)
```

#### 3. Memory Limit Exceeded

```
Error: Function execution exceeded 512 MB memory limit
```

**Solution:** Increase memory limit or optimize the generated check:

```python
db = Database(
    database_id="my_db",
    max_sandbox_memory_mb=1024  # 1 GB
)
```

#### 4. MCP Authentication Errors

```
Error: Unauthorized: Missing Authorization header
```

**Solution:** Include Bearer token in requests:

```bash
curl -X POST http://localhost:9110/mcp \
  -H "Authorization: Bearer $MCP_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}'
```

### Debug Mode

Enable verbose logging:

```bash
# Gradio copilot
uv run python -m bin.copilot -d rel-stack --verbose

# API server
LOG_LEVEL=DEBUG uv run python -m bin.api
```

### Support

- **GitHub Issues:** https://github.com/SAP/data-cleaning-copilot/issues
- **Documentation:** See `docs/` directory
- **Security Issues:** Follow security policy at https://github.com/SAP/data-cleaning-copilot/security/policy

---

*Last updated: 2025*