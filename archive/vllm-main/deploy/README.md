# Deployment Guide

This directory contains deployment configurations for different target platforms.

## Directory Structure

```
deploy/
├── aicore/              # SAP BTP AI Core (PRIMARY)
│   ├── Dockerfile.aicore
│   ├── entrypoint-aicore.sh
│   ├── serving-template.yaml
│   └── deployment-config.json
├── nginx-lb.conf        # Load balancer for Docker Swarm/local
└── SCALING.md           # Scaling documentation
```

## Deployment Targets

### 1. SAP BTP AI Core (Recommended) ✅

**Use `deploy/aicore/`**

SAP AI Core provides managed Kubernetes with GPU support. Configuration is generated from Mangle rules.

```bash
# Generate deployment config from Mangle rules
./scripts/generate_aicore_config.sh --task chat --hardware t4 --format yaml

# List available models for T4
./scripts/generate_aicore_config.sh --list-models --hardware t4
```

**Steps:**
1. Build Docker image: `docker build -f deploy/aicore/Dockerfile.aicore -t ainuc-llm-server .`
2. Push to AI Core registry
3. Upload models to Object Store
4. Register artifacts via AI Core API
5. Apply serving template
6. Create deployment with generated config

### 2. Docker Swarm / Local Development

**Use `docker-compose.scale.yml`**

For local testing with multiple replicas:

```bash
docker compose -f docker-compose.scale.yml up --scale llm-server=4
```

## Platform Comparison

| Feature | SAP AI Core | Docker Swarm |
|---------|-------------|--------------|
| GPU Support | ✅ Managed T4/A10G | ⚠️ Manual setup |
| Auto-scaling | ✅ Built-in | ❌ Manual |
| Model Storage | ✅ Object Store | 📁 Local volumes |
| Endpoints | ✅ Managed URL | 🔧 nginx/traefik |
| Monitoring | ✅ AI Launchpad | 🔧 DIY |
| Mangle Config | ✅ Generated | ✅ Generated |

## Configuration Generation

All deployment configs should be generated from Mangle rules to avoid hardcoding:

```bash
# Generate AI Core config for chat task on T4 GPU
./scripts/generate_aicore_config.sh \
  --task chat \
  --hardware t4 \
  --format yaml \
  -o deploy/aicore/generated-chat-config.yaml

# Generate for specific model
./scripts/generate_aicore_config.sh \
  --model "TheBloke/Mistral-7B-Instruct-v0.2-GGUF" \
  --variant "mistral-7b-instruct-v0.2.Q4_K_M.gguf" \
  --hardware t4 \
  --format json
```

## Mangle Rules

Configuration parameters are derived from:

| Rule File | Parameters |
|-----------|------------|
| `mangle/model_store_rules.mg` | Model definitions, hardware profiles |
| `mangle/batching_rules.mg` | Batch sizes, scaling thresholds |
| `mangle/aicore_deployment.mg` | AI Core resource plans, context sizes |

See `docs/mangle-guide.md` for rule documentation.