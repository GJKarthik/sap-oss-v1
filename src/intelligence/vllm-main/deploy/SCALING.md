# Scaling Guide for Local Models HPC Server

This guide covers strategies to scale the local-models service from single-node to enterprise-grade deployments.

## Current Baseline

| Metric | Single T4 | Single M3 Pro |
|--------|-----------|---------------|
| Throughput | 100 tok/s | 143 tok/s |
| Concurrent Requests | 4-8 | 8-32 |
| Queue Depth | 128 | 256 |

---

## 🚀 Scaling Strategies

### 1. Vertical Scaling (Single Node)

#### GPU Upgrade Path

| GPU | Memory | Throughput (7B) | Concurrent | Est. Monthly Cost |
|-----|--------|-----------------|------------|-------------------|
| T4 | 16GB | 100 tok/s | 8 | $200-300 |
| A10G | 24GB | 150 tok/s | 16 | $400-500 |
| L4 | 24GB | 200 tok/s | 16 | $350-450 |
| A100 40GB | 40GB | 300 tok/s | 32 | $1,500-2,000 |
| A100 80GB | 80GB | 350 tok/s | 64 | $2,500-3,500 |
| H100 | 80GB | 500+ tok/s | 64 | $4,000+ |

#### Memory Optimization

```bash
# Increase KV cache (T4 with 7B model)
export OLLAMA_KV_CACHE_TYPE=q4_0  # More aggressive quantization
export OLLAMA_NUM_PARALLEL=8      # Double concurrent requests
export OLLAMA_CONTEXT_SIZE=8192   # Larger context window
```

---

### 2. Horizontal Scaling (Multi-Node)

#### Docker Swarm Deployment

```yaml
# docker-compose.scale.yml
version: '3.8'

services:
  llama-server:
    image: ghcr.io/ggml-org/llama.cpp:server
    deploy:
      mode: replicated
      replicas: 4
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
      placement:
        constraints:
          - node.labels.gpu == true
    environment:
      - LLAMA_ARG_MODEL=/models/llm/phi-2.Q4_K_M.gguf
      - LLAMA_ARG_N_GPU_LAYERS=99

  openai-gateway:
    image: ainuc-openai-gateway:latest
    deploy:
      mode: replicated
      replicas: 2
    depends_on:
      - llama-server
```

Deploy:
```bash
docker stack deploy -c docker-compose.scale.yml ainuc-llm
```

#### Kubernetes Deployment

```yaml
# k8s/deployment-scaled.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: local-models-server
spec:
  replicas: 4
  selector:
    matchLabels:
      app: local-models
  template:
    metadata:
      labels:
        app: local-models
    spec:
      containers:
      - name: llama-server
        image: ghcr.io/ggml-org/llama.cpp:server
        resources:
          limits:
            nvidia.com/gpu: 1
            memory: "16Gi"
          requests:
            nvidia.com/gpu: 1
            memory: "8Gi"
        env:
        - name: LLAMA_ARG_MODEL
          value: /models/llm/phi-2.Q4_K_M.gguf
        - name: LLAMA_ARG_N_GPU_LAYERS
          value: "99"
        volumeMounts:
        - name: models
          mountPath: /models
          readOnly: true
      volumes:
      - name: models
        persistentVolumeClaim:
          claimName: models-pvc
      nodeSelector:
        cloud.google.com/gke-accelerator: nvidia-tesla-t4
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
---
apiVersion: v1
kind: Service
metadata:
  name: local-models-lb
spec:
  type: LoadBalancer
  selector:
    app: local-models
  ports:
  - port: 8080
    targetPort: 3000
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: local-models-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: local-models-server
  minReplicas: 2
  maxReplicas: 8
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Pods
    pods:
      metric:
        name: queue_depth
      target:
        type: AverageValue
        averageValue: "100"
```

---

### 3. Load Balancing

#### NGINX Load Balancer

```nginx
# deploy/nginx-lb.conf
upstream llm_backends {
    least_conn;  # Route to least busy server
    
    server llama-server-1:3000 weight=1;
    server llama-server-2:3000 weight=1;
    server llama-server-3:3000 weight=1;
    server llama-server-4:3000 weight=1;
    
    keepalive 32;
}

server {
    listen 8080;
    
    location / {
        proxy_pass http://llm_backends;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        
        # Streaming support
        proxy_buffering off;
        proxy_cache off;
        
        # Timeout for long generations
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
    
    location /health {
        access_log off;
        return 200 "OK\n";
    }
}
```

#### Traefik with Weighted Round-Robin

```yaml
# traefik/dynamic.yml
http:
  services:
    llm-service:
      loadBalancer:
        servers:
          - url: "http://llama-server-1:3000"
          - url: "http://llama-server-2:3000"
          - url: "http://llama-server-3:3000"
          - url: "http://llama-server-4:3000"
        healthCheck:
          path: /health
          interval: 10s
          timeout: 3s
        sticky:
          cookie:
            name: llm_session
            secure: true
```

---

### 4. Model Sharding (Tensor Parallelism)

For models larger than single-GPU memory:

```bash
# vLLM with tensor parallelism (2x T4 for 13B model)
docker run --gpus all -p 8080:8000 \
  vllm/vllm-openai:latest \
  --model mistralai/Mistral-7B-Instruct-v0.2 \
  --tensor-parallel-size 2 \
  --max-model-len 4096
```

---

### 5. Request Queue Optimization

Update `mangle/batching_rules.mg`:

```mangle
# Increase queue depth for higher throughput
max_queue_depth(/phi3-lora, 512).      # Was 256
max_queue_depth(/llama3-8b, 256).      # Was 128
max_queue_depth(/mistral-7b, 256).     # Was 128

# Faster batch formation
min_batch_wait(/phi3-lora, 5).         # Was 10ms
min_batch_wait(/llama3-8b, 10).        # Was 20ms

# Larger batch sizes with more GPU memory
max_batch_size(/phi3-lora, 64).        # Was 32
max_batch_size(/llama3-8b, 32).        # Was 16

# Aggressive scaling
max_replicas(/phi3-lora, 16).          # Was 8
max_replicas(/llama3-8b, 8).           # Was 4
```

---

## 📊 Scaling Scenarios

### Scenario A: 100 Concurrent Users

**Setup:** 2x T4 GPUs, load-balanced

```bash
# Expected throughput
2 × 100 tok/s = 200 tok/s aggregate

# Concurrent capacity
2 × 8 requests = 16 concurrent (in-flight)
Queue: 256 additional pending

# Latency (7B model, 100 token response)
TTFT: 50-100ms
Total: 1-2 seconds
```

**Cost:** ~$500-600/month (GCP/AWS)

---

### Scenario B: 500 Concurrent Users

**Setup:** 4x A10G GPUs, Kubernetes HPA

```bash
# Expected throughput
4 × 150 tok/s = 600 tok/s aggregate

# Concurrent capacity
4 × 16 requests = 64 concurrent
Queue: 512 additional pending

# Latency
TTFT: 100-200ms (with queue)
Total: 2-5 seconds
```

**Cost:** ~$1,600-2,000/month

---

### Scenario C: 2,000+ Concurrent Users

**Setup:** 8x A100 40GB, multi-region

```bash
# Expected throughput
8 × 300 tok/s = 2,400 tok/s aggregate

# Concurrent capacity
8 × 32 requests = 256 concurrent
Queue: 2,048 additional pending

# Latency
TTFT: 100-500ms (priority-based)
Total: 1-10 seconds
```

**Cost:** ~$12,000-16,000/month

---

## 🔧 Implementation Checklist

### Phase 1: Single-Node Optimization (Week 1)
- [ ] Upgrade to A10G or L4 GPU
- [ ] Enable flash attention and INT8 KV cache
- [ ] Tune batch sizes in `batching_rules.mg`
- [ ] Increase `OLLAMA_NUM_PARALLEL` to 8

### Phase 2: Multi-Node Deployment (Week 2-3)
- [ ] Deploy Kubernetes cluster with GPU nodes
- [ ] Configure HPA with custom queue_depth metric
- [ ] Set up NGINX/Traefik load balancer
- [ ] Implement health checks and circuit breakers

### Phase 3: Advanced Scaling (Week 4+)
- [ ] Add Redis for distributed request queue
- [ ] Implement model caching across nodes
- [ ] Set up Prometheus + Grafana monitoring
- [ ] Configure auto-scaling policies

---

## 📈 Monitoring for Scale

### Prometheus Metrics to Watch

```promql
# Request throughput
rate(llm_tokens_generated_total[5m])

# Queue saturation
llm_queue_depth / llm_queue_max

# GPU utilization
nvidia_gpu_utilization_percent

# Latency percentiles
histogram_quantile(0.99, llm_request_duration_seconds_bucket)
```

### Alerts

```yaml
# alerts.yml
groups:
- name: llm-scaling
  rules:
  - alert: HighQueueDepth
    expr: llm_queue_depth > 200
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "Queue depth high, consider scaling up"
      
  - alert: LowThroughput
    expr: rate(llm_tokens_generated_total[5m]) < 50
    for: 10m
    labels:
      severity: critical
    annotations:
      summary: "Throughput degraded, check GPU health"
```

---

## 💰 Cost Optimization

| Strategy | Savings | Trade-off |
|----------|---------|-----------|
| Spot/Preemptible GPUs | 60-70% | Interruptions |
| Smaller models (3B) | 50% | Quality |
| Q4 quantization | 30% | Slight quality loss |
| Off-peak scaling | 20-40% | Variable capacity |
| Reserved instances | 30-50% | Commitment |

### Spot Instance Configuration (GKE)

```yaml
nodeSelector:
  cloud.google.com/gke-spot: "true"
tolerations:
- key: cloud.google.com/gke-spot
  operator: Equal
  value: "true"
  effect: NoSchedule
```

---

## Next Steps

1. **Benchmark Current Setup**: Run `./scripts/test_backends.sh` to establish baseline
2. **Choose Scaling Path**: Vertical (bigger GPU) or Horizontal (more nodes)
3. **Deploy Incrementally**: Start with 2x replicas, monitor, then scale
4. **Set Up Monitoring**: Prometheus + Grafana before scaling

For questions, see the [main README](../README.md) or run tests with `./zig-out/bin/test_runner`.