# vLLM Kubernetes Deployment Sample

This sample demonstrates deploying vLLM on Kubernetes using Helm.

## Prerequisites

- Kubernetes cluster with GPU nodes
- kubectl configured
- Helm 3.x installed
- NVIDIA GPU Operator installed on cluster

## Quick Start

### 1. Install NVIDIA GPU Operator (if not installed)

```bash
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update
helm install --wait gpu-operator nvidia/gpu-operator \
  -n gpu-operator --create-namespace
```

### 2. Deploy vLLM

```bash
# Basic deployment
helm install vllm ./helm/vllm

# With custom model
helm install vllm ./helm/vllm \
  --set model.name="meta-llama/Llama-3.1-70B-Instruct" \
  --set gpu.count=2

# With API key
helm install vllm ./helm/vllm \
  --set server.apiKey="your-secret-key"

# With HPA enabled
helm install vllm ./helm/vllm \
  --set autoscaling.enabled=true \
  --set autoscaling.minReplicas=1 \
  --set autoscaling.maxReplicas=5
```

### 3. Access the Service

```bash
# Port forward for local access
kubectl port-forward svc/vllm 8000:8000

# Or create an ingress (see values.yaml)
```

## Configuration

### GPU Nodes

Ensure your cluster has GPU nodes with proper taints:

```bash
# GKE
gcloud container node-pools create gpu-pool \
  --cluster=my-cluster \
  --accelerator=type=nvidia-tesla-a100,count=1 \
  --machine-type=a2-highgpu-1g

# AWS EKS
eksctl create nodegroup \
  --cluster=my-cluster \
  --node-type=p4d.24xlarge \
  --nodes=1 \
  --name=gpu-nodes
```

### Values Reference

| Parameter | Description | Default |
|-----------|-------------|---------|
| `replicaCount` | Number of replicas | `1` |
| `model.name` | Model identifier | `meta-llama/Llama-3.1-8B-Instruct` |
| `model.maxModelLen` | Max context length | `8192` |
| `model.quantization` | Quantization (awq/gptq) | `` |
| `gpu.enabled` | Enable GPU | `true` |
| `gpu.count` | GPU count per pod | `1` |
| `autoscaling.enabled` | Enable HPA | `false` |
| `persistence.enabled` | Enable model cache PVC | `true` |
| `persistence.size` | PVC size | `100Gi` |

### Examples

#### High-Performance Setup (70B model)

```bash
helm install vllm ./helm/vllm -f values-70b.yaml

# values-70b.yaml
model:
  name: "meta-llama/Llama-3.1-70B-Instruct"
  maxModelLen: 32768
gpu:
  count: 4
resources:
  requests:
    memory: "160Gi"
    cpu: "16"
  limits:
    memory: "200Gi"
    cpu: "32"
```

#### Multiple Models

```bash
# Deploy chat model
helm install vllm-chat ./helm/vllm \
  --set model.name="meta-llama/Llama-3.1-8B-Instruct"

# Deploy code model
helm install vllm-code ./helm/vllm \
  --set model.name="codellama/CodeLlama-34b-Instruct-hf"
```

#### With Hugging Face Token (for gated models)

```bash
# Create secret
kubectl create secret generic hf-token \
  --from-literal=token=hf_xxxxx

# Deploy with token
helm install vllm ./helm/vllm \
  --set huggingface.tokenSecretName=hf-token
```

## Monitoring

### View Logs

```bash
kubectl logs -f deploy/vllm
```

### Check Health

```bash
kubectl exec -it deploy/vllm -- curl localhost:8000/health
```

### Port Forward

```bash
kubectl port-forward svc/vllm 8000:8000
curl http://localhost:8000/v1/models
```

## Troubleshooting

### Pod Not Starting

```bash
# Check events
kubectl describe pod -l app.kubernetes.io/name=vllm

# Check GPU allocation
kubectl get pods -o yaml | grep -A5 resources
```

### Out of Memory

- Reduce `model.maxModelLen`
- Enable quantization: `--set model.quantization=awq`
- Use a smaller model

### GPU Not Found

- Verify NVIDIA GPU Operator is running
- Check node has GPU: `kubectl describe node | grep nvidia`
- Check tolerations match node taints

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Kubernetes Cluster                       │
│  ┌─────────────────────────────────────────────────────┐    │
│  │                    GPU Node Pool                     │    │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │    │
│  │  │  vLLM Pod   │  │  vLLM Pod   │  │  vLLM Pod   │  │    │
│  │  │  (GPU x1)   │  │  (GPU x1)   │  │  (GPU x1)   │  │    │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  │    │
│  └─────────────────────────────────────────────────────┘    │
│                            │                                 │
│                    ┌───────┴───────┐                        │
│                    │   Service     │                        │
│                    │   (ClusterIP) │                        │
│                    └───────┬───────┘                        │
│                            │                                 │
│                    ┌───────┴───────┐                        │
│                    │   Ingress     │ ← External traffic     │
│                    └───────────────┘                        │
└─────────────────────────────────────────────────────────────┘
```

## Directory Structure

```
vllm-k8s/
├── README.md
└── helm/
    └── vllm/
        ├── Chart.yaml
        ├── values.yaml
        └── templates/
            ├── _helpers.tpl
            ├── deployment.yaml
            ├── service.yaml
            └── hpa.yaml
```

## License

Apache-2.0