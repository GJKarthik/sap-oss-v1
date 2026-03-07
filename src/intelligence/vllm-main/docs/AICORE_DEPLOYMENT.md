# SAP AI Core Deployment Guide

## Overview
Deploy the Pure Zig LLM inference engine to SAP AI Core with NVIDIA T4 GPU support.

## Prerequisites

1. **Docker Hub Access** - Push image to `docker.io/gjkarthik`
2. **SAP AI Core** - Configured with:
   - Object Store Secret: `default`
   - Docker Registry Secret: `ollamadocker`
   - Resource Plan: `infer.s` (T4 GPU)

## S3 Object Store Configuration

Your S3 is configured as:
- **Name**: `default`
- **Path Prefix**: `ai/default`
- **Bucket**: `hcp-4bf99a2c-376e-4f6b-b787-32d388b846de`
- **Region**: `ap-southeast-1`
- **Endpoint**: `s3-ap-southeast-1.amazonaws.com`

## Step 1: Upload TinyLlama Model to S3

```bash
# Download TinyLlama Q8_0 (1.1GB)
wget https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q8_0.gguf \
  -O tinyllama-1.1b-chat.Q8_0.gguf

# Upload to S3 (using AWS CLI configured with AI Core credentials)
aws s3 cp tinyllama-1.1b-chat.Q8_0.gguf \
  s3://hcp-4bf99a2c-376e-4f6b-b787-32d388b846de/ai/default/models/tinyllama/ \
  --endpoint-url https://s3-ap-southeast-1.amazonaws.com
```

## Step 2: Build and Push Docker Image

```bash
cd src/intelligence/ai-core-privatellm

# Build for linux/amd64 (AI Core runtime)
docker build --platform linux/amd64 -t gjkarthik/ai-core-privatellm:v1.0-tinyllama .

# Push to Docker Hub
docker push gjkarthik/ai-core-privatellm:v1.0-tinyllama
```

## Step 3: Register Artifact in AI Core

```bash
# Create artifact pointing to S3 model location
curl -X POST "https://<ai-core-url>/v2/lm/artifacts" \
  -H "Authorization: Bearer $TOKEN" \
  -H "AI-Resource-Group: default" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "tinyllama-model",
    "kind": "model",
    "url": "ai://default/models/tinyllama",
    "description": "TinyLlama 1.1B Chat Q8_0 GGUF model",
    "scenarioId": "privatellm"
  }'
```

## Step 4: Sync Serving Template

Push the `aicore-serving-template.yaml` to your AI Core connected git repository:

```bash
cp aicore-serving-template.yaml <your-aicore-repo>/
cd <your-aicore-repo>
git add aicore-serving-template.yaml
git commit -m "Add privatellm serving template"
git push
```

Wait for AI Core to sync (~1-2 minutes).

## Step 5: Create Deployment

```bash
curl -X POST "https://<ai-core-url>/v2/lm/deployments" \
  -H "Authorization: Bearer $TOKEN" \
  -H "AI-Resource-Group: default" \
  -H "Content-Type: application/json" \
  -d '{
    "configurationId": "<configuration-id>",
    "resourcePlanId": "infer.s"
  }'
```

Or use the AI Launchpad UI to create the deployment.

## Step 6: Test Deployment

```bash
# Get deployment URL from AI Core
DEPLOYMENT_URL="https://<deployment-url>"

# Health check
curl -s "$DEPLOYMENT_URL/health"

# Chat completion
curl -X POST "$DEPLOYMENT_URL/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "model": "tinyllama",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 100
  }'
```

## Files

| File | Description |
|------|-------------|
| `Dockerfile` | Multi-stage build with CUDA 12.4 + Zig |
| `docker-entrypoint.sh` | Entrypoint with S3 model mount support |
| `aicore-serving-template.yaml` | AI Core serving template |
| `zig/` | Pure Zig LLM inference engine |

## GPU Support

- **T4 (SM75)**: 16GB VRAM, INT8 Tensor Cores
- **A100 (SM80)**: 40/80GB VRAM, TF32 Tensor Cores
- **H100 (SM90)**: 80GB VRAM, FP8 Tensor Cores

## Troubleshooting

### Model not found
```
ERROR: No GGUF model found!
```
- Verify artifact is correctly registered
- Check S3 path matches: `ai://default/models/tinyllama/`
- Verify model file exists in S3

### GPU not detected
```
CUDA_ERROR_NO_DEVICE
```
- Ensure `resourcePlan: infer.s` is set (GPU plan)
- Check `nvidia.com/gpu: "1"` in resources

### Startup timeout
- TinyLlama loads in ~10-15 seconds
- Check logs for model loading progress