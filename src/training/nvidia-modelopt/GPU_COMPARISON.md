# GPU Comparison for Specialist Model Training

## Executive Summary

For training 4 specialist models (7B each) with 100K examples per domain, here's the GPU comparison:

## GPU Options

| GPU | VRAM | Compute | Memory BW | Price/hr (AWS) | Training Time (7B, 100K) |
|-----|------|---------|-----------|----------------|--------------------------|
| **Tesla T4** | 16 GB | 65 TFLOPS | 320 GB/s | ~$0.50 | ~20 hours |
| **A10G** | 24 GB | 125 TFLOPS | 600 GB/s | ~$1.00 | ~12 hours |
| **A100 40GB** | 40 GB | 312 TFLOPS | 1.6 TB/s | ~$3.50 | ~4 hours |
| **A100 80GB** | 80 GB | 312 TFLOPS | 2.0 TB/s | ~$5.00 | ~3.5 hours |
| **H100 80GB** | 80 GB | 989 TFLOPS | 3.35 TB/s | ~$8.00 | ~1.5 hours |
| **H200 141GB** | 141 GB | 989 TFLOPS | 4.8 TB/s | ~$12.00 | ~1.2 hours |

## Recommendation by Use Case

### POC/Development → **T4**
- Cost-effective for experimentation
- 4-bit quantization fits 7B models
- Already validated and working
- **Cost:** ~$10 for full POC

### Production Training → **H100 80GB** ⭐ Recommended
- 3x faster than A100
- FP8 native support for efficient training
- Can train without quantization (higher quality)
- **Cost:** ~$32 per specialist (4 hours)
- **Total for 4 specialists + router:** ~$160

### Enterprise Scale → **H200 141GB**
- Largest VRAM (141GB)
- Can train 70B+ models
- Fastest memory bandwidth
- **Use if:** Training larger models (14B+) or multi-GPU setup

## Training Configuration by GPU

### T4 (Current POC)
```yaml
model: Qwen/Qwen2.5-7B-Instruct
quantization: 4-bit NF4
batch_size: 1
gradient_accumulation: 16
effective_batch: 16
max_steps: 100
training_time: ~75 minutes (100 steps)
```

### H100 80GB (Recommended)
```yaml
model: Qwen/Qwen2.5-7B-Instruct
quantization: 8-bit (or FP8)
batch_size: 8
gradient_accumulation: 4
effective_batch: 32
epochs: 3 (over 100K examples)
training_time: ~4 hours per specialist
```

### H200 141GB (Premium)
```yaml
model: Qwen/Qwen2.5-14B-Instruct
quantization: none (full precision)
batch_size: 16
gradient_accumulation: 2
effective_batch: 32
epochs: 3
training_time: ~3 hours per specialist
```

## Cost Analysis (Full Training: 4 Specialists + Router)

| GPU | Time per Specialist | Total Time | AWS Cost |
|-----|---------------------|------------|----------|
| T4 | 20 hours | 100 hours | **$50** |
| A100 40GB | 4 hours | 20 hours | **$70** |
| A100 80GB | 3.5 hours | 17.5 hours | **$88** |
| **H100 80GB** | 1.5 hours | 7.5 hours | **$60** ⭐ |
| H200 141GB | 1.2 hours | 6 hours | **$72** |

### Recommendation: **H100 80GB**
- Best cost/performance ratio
- 3x faster than A100
- Native FP8 training
- Widely available on AWS/GCP

## AWS Instance Types

| Instance | GPU | VRAM | vCPUs | Price/hr |
|----------|-----|------|-------|----------|
| `g4dn.xlarge` | 1x T4 | 16 GB | 4 | $0.526 |
| `g5.xlarge` | 1x A10G | 24 GB | 4 | $1.006 |
| `p4d.24xlarge` | 8x A100 40GB | 320 GB | 96 | $32.77 |
| `p4de.24xlarge` | 8x A100 80GB | 640 GB | 96 | $40.96 |
| `p5.48xlarge` | 8x H100 80GB | 640 GB | 192 | $98.32 |

### Single GPU Options
- **H100 80GB:** `p5.48xlarge` (use 1 of 8 GPUs) or Lambda Labs ($2.49/hr)
- **A100 80GB:** `p4de.24xlarge` (use 1 of 8 GPUs) or Lambda Labs ($1.29/hr)
- **A100 40GB:** GCP `a2-highgpu-1g` ($3.67/hr)

## Model Size vs GPU

| Model Size | Min VRAM (4-bit) | Min VRAM (8-bit) | Min VRAM (FP16) | Recommended GPU |
|------------|------------------|------------------|-----------------|-----------------|
| 7B | 6 GB | 10 GB | 16 GB | T4 / A10G |
| 9B | 8 GB | 14 GB | 22 GB | A10G / A100 |
| 14B | 12 GB | 20 GB | 32 GB | A100 40GB |
| 32B | 24 GB | 40 GB | 70 GB | A100 80GB |
| 72B | 48 GB | 80 GB | 150 GB | H100 / H200 |

## Final Recommendation

### For Your Use Case (4 Specialist + 1 Router)

**Training Phase:** Use **H100 80GB** via Lambda Labs (~$2.49/hr)
- Total training: ~8 hours
- Total cost: ~$20-30

**Inference Phase:** Use **T4** for cost-effective serving
- Each specialist can run on T4 with 4-bit quantization
- vLLM can serve multiple LoRA adapters on single GPU

Would you like me to create the H100 training configuration?