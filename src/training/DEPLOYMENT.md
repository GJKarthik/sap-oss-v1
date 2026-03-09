# Deployment Guide

## Prerequisites

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| Docker | 24.x | 25.x |
| Docker Compose | 2.20+ | 2.24+ |
| RAM | 4 GB | 16 GB (32 GB with GPU) |
| Disk | 10 GB | 50 GB (for model weights) |
| GPU (optional) | T4 (16 GB) | A10G/A100 |
| NVIDIA Driver | 535+ | 550+ |
| nvidia-container-toolkit | 1.14+ | Latest |

## Quick Start — Docker Compose

### CPU-only (Development)

```bash
# Clone and configure
cp .env.example .env
# Edit .env: set MODELOPT_API_KEY, ALLOWED_ORIGINS

# Start services
docker compose up -d

# Verify
curl http://localhost:8001/health
open http://localhost:8080          # UI
```

### GPU-enabled (Production)

```bash
# Install nvidia-container-toolkit
# See: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html

# Start with GPU profile
docker compose --profile gpu up -d

# Verify GPU access
curl http://localhost:8001/gpu/status
```

### Service URLs

| Service | URL | Purpose |
|---------|-----|---------|
| API | `http://localhost:8001` | REST API + OpenAI compat |
| API Docs | `http://localhost:8001/docs` | Swagger UI |
| UI | `http://localhost:8080` | Angular dashboard |
| Metrics | `http://localhost:8001/metrics` | Prometheus |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `8001` | API server port |
| `UI_PORT` | `8080` | UI nginx port |
| `WORKERS` | `1` | Uvicorn worker count |
| `LOG_LEVEL` | `info` | Python log level |
| `MODELOPT_API_KEY` | — | API authentication key |
| `MODELOPT_REQUIRE_AUTH` | `false` | Enforce bearer auth |
| `ALLOWED_ORIGINS` | `http://localhost:4200,...` | CORS origins (comma-sep) |
| `HF_TOKEN` | — | HuggingFace token for gated models |

## Docker Single-Node

### Build Images

```bash
# API
docker build -t modelopt-api:latest ./nvidia-modelopt

# UI (pass API URL at build time)
docker build -t modelopt-ui:latest \
  --build-arg API_URL=http://your-api-host:8001 \
  ./nvidia-modelopt/ui
```

### Run Containers

```bash
# API
docker run -d --name modelopt-api \
  -p 8001:8001 \
  -e MODELOPT_API_KEY=your-key \
  -e MODELOPT_REQUIRE_AUTH=true \
  -v modelopt-outputs:/app/outputs \
  modelopt-api:latest

# UI
docker run -d --name modelopt-ui \
  -p 8080:80 \
  modelopt-ui:latest
```

## Kubernetes Deployment

### Namespace & Secret

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: modelopt
---
apiVersion: v1
kind: Secret
metadata:
  name: modelopt-secrets
  namespace: modelopt
type: Opaque
stringData:
  api-key: "your-secure-api-key"
  hf-token: "hf_your_token"
```

### API Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: modelopt-api
  namespace: modelopt
spec:
  replicas: 1            # Single replica for GPU workloads
  selector:
    matchLabels:
      app: modelopt-api
  template:
    metadata:
      labels:
        app: modelopt-api
    spec:
      containers:
      - name: api
        image: modelopt-api:latest
        ports:
        - containerPort: 8001
        env:
        - name: MODELOPT_REQUIRE_AUTH
          value: "true"
        - name: MODELOPT_API_KEY
          valueFrom:
            secretKeyRef:
              name: modelopt-secrets
              key: api-key
        resources:
          requests:
            memory: "4Gi"
            cpu: "2"
          limits:
            memory: "16Gi"
            nvidia.com/gpu: "1"
        volumeMounts:
        - name: model-storage
          mountPath: /app/outputs
        livenessProbe:
          httpGet:
            path: /health
            port: 8001
          initialDelaySeconds: 15
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /health
            port: 8001
          initialDelaySeconds: 5
          periodSeconds: 10
      volumes:
      - name: model-storage
        persistentVolumeClaim:
          claimName: modelopt-pvc
      nodeSelector:
        nvidia.com/gpu.present: "true"
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
```

### Service & PVC

```yaml
apiVersion: v1
kind: Service
metadata:
  name: modelopt-api
  namespace: modelopt
spec:
  selector:
    app: modelopt-api
  ports:
  - port: 8001
    targetPort: 8001
  type: ClusterIP
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: modelopt-pvc
  namespace: modelopt
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 50Gi        # For model weights and outputs
```

## GPU Node Requirements

| GPU | VRAM | Max Model Size (INT8) | Max Model Size (INT4) |
|-----|------|----------------------|----------------------|
| T4 | 16 GB | ~7B parameters | ~13B parameters |
| A10G | 24 GB | ~13B parameters | ~25B parameters |
| A100 (40GB) | 40 GB | ~25B parameters | ~50B parameters |
| A100 (80GB) | 80 GB | ~50B parameters | ~100B parameters |

**Recommended:** NVIDIA T4 (16 GB) for models up to 7B parameters (e.g., Qwen 1.8B–7B).

## Model Storage

Model weights are stored in `/app/outputs` inside the container.

- **Docker**: Use a named volume (`model-outputs`)
- **Kubernetes**: Use a PVC with `ReadWriteOnce` access mode
- **Shared storage**: For multi-replica, use NFS or a CSI driver (e.g., EFS, GCS FUSE)

Pre-download models to avoid cold-start latency:

```bash
# Pre-populate model cache
docker exec modelopt-api python -c "
from transformers import AutoModelForCausalLM, AutoTokenizer
AutoModelForCausalLM.from_pretrained('Qwen/Qwen3.5-1.8B')
AutoTokenizer.from_pretrained('Qwen/Qwen3.5-1.8B')
"
```

## Scaling Considerations

| Component | Scaling Strategy |
|-----------|-----------------|
| **API (CPU)** | Horizontal — increase `WORKERS` or replica count |
| **API (GPU)** | Vertical — one GPU per replica; scale replicas per GPU node |
| **UI** | Horizontal — stateless nginx, scale freely |
| **Jobs** | Queue-based — one active job per GPU; queue excess |

**Production checklist:**
- [ ] Set `MODELOPT_REQUIRE_AUTH=true`
- [ ] Configure explicit `ALLOWED_ORIGINS`
- [ ] Set `HF_TOKEN` for gated models
- [ ] Mount persistent storage for model outputs
- [ ] Configure Prometheus scraping for `/metrics`
- [ ] Set up log aggregation (structured JSON logs to stdout)
- [ ] Configure health check alerts on `/health` endpoint
- [ ] Set resource limits (CPU, memory, GPU) per container

