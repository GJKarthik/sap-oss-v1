# Multi-GPU Training Strategy: T4 + L4 + H200

## Available Hardware

| GPU | VRAM | Compute | Best For |
|-----|------|---------|----------|
| **T4** | 16 GB | 65 TFLOPS | Router (0.5B), Inference |
| **L4** | 24 GB | 121 TFLOPS | 7B models, Inference |
| **H200** | 141 GB | 989 TFLOPS | 14B+ models, Production training |

## Optimal Strategy: Parallel Training

Train all specialists simultaneously on different GPUs!

```
┌─────────────────────────────────────────────────────────────────────┐
│                     PARALLEL TRAINING PLAN                          │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  H200 (141GB)          L4 (24GB)           T4 (16GB)               │
│  ┌──────────────┐     ┌──────────────┐    ┌──────────────┐         │
│  │ Performance  │     │  Treasury    │    │   Router     │         │
│  │ (14B model)  │     │  (7B model)  │    │ (0.5B model) │         │
│  │ 100K examples│     │ 100K examples│    │ 50K examples │         │
│  │ ~1.5 hours   │     │ ~3 hours     │    │ ~30 min      │         │
│  └──────────────┘     └──────────────┘    └──────────────┘         │
│         │                    │                   │                  │
│         ▼                    ▼                   ▼                  │
│  ┌──────────────┐     ┌──────────────┐    ┌──────────────┐         │
│  │Balance Sheet │     │     ESG      │    │  (Complete)  │         │
│  │ (14B model)  │     │  (7B model)  │    │   Inference  │         │
│  │ 100K examples│     │ 100K examples│    │   Testing    │         │
│  │ ~1.5 hours   │     │ ~3 hours     │    └──────────────┘         │
│  └──────────────┘     └──────────────┘                             │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## Time Comparison

| Strategy | Total Time | Cost Efficiency |
|----------|------------|-----------------|
| H200 only (sequential) | ~6.5 hours | ⭐⭐⭐ |
| **All 3 GPUs (parallel)** | **~3 hours** | ⭐⭐⭐⭐⭐ |

## Execution Plan

### Phase 1: Start All Training Simultaneously

**Terminal 1 (H200):**
```bash
# Train Performance and Balance Sheet (14B model)
CUDA_VISIBLE_DEVICES=0 python train_h200.py --specialist performance
CUDA_VISIBLE_DEVICES=0 python train_h200.py --specialist balance_sheet
```

**Terminal 2 (L4):**
```bash
# Train Treasury and ESG (7B model)
CUDA_VISIBLE_DEVICES=1 python train_l4.py --specialist treasury
CUDA_VISIBLE_DEVICES=1 python train_l4.py --specialist esg
```

**Terminal 3 (T4):**
```bash
# Train Router (0.5B model)
CUDA_VISIBLE_DEVICES=2 python train_t4.py --specialist router
```

### Phase 2: While Training, Test on T4

Once router finishes (~30 min), use T4 for inference testing:
```bash
CUDA_VISIBLE_DEVICES=2 python test_inference.py
```

## GPU Assignment

| Specialist | GPU | Model Size | Quantization | Time |
|------------|-----|------------|--------------|------|
| Performance | H200 | 14B | None (BF16) | 1.5h |
| Balance Sheet | H200 | 14B | None (BF16) | 1.5h |
| Treasury | L4 | 7B | 4-bit | 3h |
| ESG | L4 | 7B | 4-bit | 3h |
| Router | T4 | 0.5B | None | 0.5h |

## Memory Usage

| GPU | Model | Training Memory | Headroom |
|-----|-------|-----------------|----------|
| H200 (141GB) | 14B BF16 | ~80 GB | 60 GB |
| L4 (24GB) | 7B 4-bit | ~18 GB | 6 GB |
| T4 (16GB) | 0.5B | ~4 GB | 12 GB |

## Parallel Execution Script

Create this script to run everything:

```bash
#!/bin/bash
# run_parallel_training.sh

# Detect GPUs
echo "Available GPUs:"
nvidia-smi --query-gpu=index,name,memory.total --format=csv

# Generate training data first
echo "Generating training data..."
cd schema_pipeline
python specialist_data_generator.py --examples 100000
cd ..

# Start parallel training
echo "Starting parallel training..."

# H200: Performance (backgrounded)
CUDA_VISIBLE_DEVICES=0 nohup python scripts/train_h200.py --specialist performance > logs/perf.log 2>&1 &
PID_PERF=$!

# L4: Treasury (backgrounded)
CUDA_VISIBLE_DEVICES=1 nohup python scripts/train_l4.py --specialist treasury > logs/treas.log 2>&1 &
PID_TREAS=$!

# T4: Router (backgrounded)
CUDA_VISIBLE_DEVICES=2 nohup python scripts/train_t4.py --specialist router > logs/router.log 2>&1 &
PID_ROUTER=$!

echo "Training started:"
echo "  Performance (H200): PID $PID_PERF"
echo "  Treasury (L4): PID $PID_TREAS"
echo "  Router (T4): PID $PID_ROUTER"

# Wait for router (fastest)
wait $PID_ROUTER
echo "Router complete! Starting ESG on L4..."

# L4: ESG after Treasury
wait $PID_TREAS
CUDA_VISIBLE_DEVICES=1 nohup python scripts/train_l4.py --specialist esg > logs/esg.log 2>&1 &
PID_ESG=$!

# H200: Balance Sheet after Performance
wait $PID_PERF
CUDA_VISIBLE_DEVICES=0 nohup python scripts/train_h200.py --specialist balance_sheet > logs/bs.log 2>&1 &
PID_BS=$!

# Wait for all
wait $PID_ESG $PID_BS

echo "All training complete!"
```

## Inference Deployment

After training, deploy using all GPUs:

```
┌─────────────────────────────────────────────────────────────────┐
│                    INFERENCE DEPLOYMENT                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  User Query                                                      │
│       │                                                          │
│       ▼                                                          │
│  ┌──────────────┐                                                │
│  │   Router     │ (T4 - always available, <10ms)                 │
│  │   (0.5B)     │                                                │
│  └──────────────┘                                                │
│       │                                                          │
│   ┌───┴────┬────────┬────────┐                                  │
│   ▼        ▼        ▼        ▼                                  │
│ ┌────┐  ┌────┐  ┌────┐  ┌────┐                                  │
│ │Perf│  │ BS │  │Trea│  │ESG │                                  │
│ │H200│  │H200│  │ L4 │  │ L4 │                                  │
│ └────┘  └────┘  └────┘  └────┘                                  │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Cost Efficiency

| Resource | Usage | Purpose |
|----------|-------|---------|
| H200 | High compute jobs | 14B training, complex inference |
| L4 | Medium jobs | 7B training, batch inference |
| T4 | Always-on | Router, lightweight inference |

This setup maximizes utilization and minimizes total training time!