# Training Review: SAP-OSS Text-to-SQL System

## Executive Summary

This document reviews the training infrastructure for domain-specific Text-to-SQL models designed for SAP HANA enterprise data.

---

## Model Architecture

### Supported Model Families

| Family | Models | Status | Use Case |
|--------|--------|--------|----------|
| **Qwen 3.5** | 0.8B, 4B, 9B, 35B | 🔜 Awaiting Release | Target models |
| **Qwen 2.5** | 0.5B-72B | ✅ Available | Current fallback |
| **NVIDIA Nemotron** | 3-8B, 4-15B, Nano-4B | ✅ Available | Alternative |
| **NVIDIA Minitron** | 4B, 8B | ✅ Available | Edge deployment |

### Specialist Model Architecture (4+1)

```
┌─────────────────────────────────────────────────────────────┐
│                    Semantic Router (0.8B-1.5B)              │
│  Classifies: Domain + Consolidation Level                   │
└─────────────┬───────────────┬───────────────┬───────────────┘
              │               │               │               │
              ▼               ▼               ▼               ▼
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│  Performance    │  │  Balance Sheet  │  │   Treasury/ALM  │  │   ESG/Carbon    │
│  Specialist     │  │   Specialist    │  │   Specialist    │  │   Specialist    │
│  (9B-14B)       │  │  (9B-14B)       │  │  (9B-14B)       │  │  (9B-14B)       │
└─────────────────┘  └─────────────────┘  └─────────────────┘  └─────────────────┘
```

---

## Training Scripts

### 1. Model Registry (`model_registry.py`)

Central registry for all supported models with auto-selection and fallback.

```bash
# List available models
python model_registry.py --list

# Get recommendation for GPU
python model_registry.py --gpu A100_40GB --tier specialist

# Generate training config
python model_registry.py --config qwen2.5-14b --vram 40
```

### 2. Qwen 3.5 Training (`train_qwen3.py`)

Forward-compatible training script with automatic Qwen 2.5 fallback.

```bash
# Auto-select model based on GPU
python train_qwen3.py --specialist performance --model auto

# Request Qwen 3.5 (falls back to 2.5 if unavailable)
python train_qwen3.py --specialist treasury --model qwen3.5-9b

# Specify exact model
python train_qwen3.py --specialist esg --model qwen2.5-14b --max-steps 1000
```

### 3. Nemotron Training (`train_nemotron.py`)

NVIDIA Nemotron-specific training for alternative deployment.

```bash
# Auto-select Nemotron based on VRAM
python train_nemotron.py --specialist performance --model auto

# Train with specific Nemotron model
python train_nemotron.py --specialist treasury --model nemotron-3-8b
```

---

## Evaluation Framework

### Metrics

| Metric | Description | Target |
|--------|-------------|--------|
| **Exact Match** | SQL matches ground truth | >70% |
| **Syntax Valid** | SQL parses correctly | >95% |
| **Execution Success** | Query runs without error | >85% |
| **Table Accuracy** | Correct tables used | >90% |
| **Column Accuracy** | Correct columns selected | >90% |
| **Condition Accuracy** | Correct WHERE clauses | >85% |
| **ROUGE-L** | Text similarity | >0.75 |
| **BLEU** | N-gram overlap | >0.60 |
| **Latency** | Inference time | <500ms |

### Evaluation Commands

```bash
# Evaluate single model
python benchmarks/evaluate_specialist.py evaluate \
    --model-path ./outputs/performance_qwen2.5-14b \
    --specialist performance \
    --num-samples 100

# A/B Comparison (baseline vs fine-tuned)
python benchmarks/evaluate_specialist.py compare \
    --model-a Qwen/Qwen2.5-14B-Instruct \
    --model-b ./outputs/performance_qwen2.5-14b \
    --name-a "Baseline" \
    --name-b "Fine-tuned" \
    --specialist performance \
    --output results.json
```

---

## GPU Requirements

### Recommended Configurations

| GPU | VRAM | Router Model | Specialist Model | Complex Model |
|-----|------|--------------|------------------|---------------|
| **T4** | 16GB | Qwen2.5-1.5B | Qwen2.5-7B (4-bit) | - |
| **L4** | 24GB | Qwen2.5-3B | Qwen2.5-14B (4-bit) | - |
| **A10** | 24GB | Qwen2.5-3B | Qwen2.5-14B (4-bit) | - |
| **A100 40GB** | 40GB | Qwen2.5-7B | Qwen2.5-14B (8-bit) | Nemotron-4-15B |
| **A100 80GB** | 80GB | Qwen2.5-7B | Qwen2.5-32B (8-bit) | Qwen2.5-72B (4-bit) |
| **H100** | 80GB | Qwen3.5-0.8B | Qwen3.5-9B | Qwen3.5-35B |
| **H200** | 141GB | Qwen3.5-0.8B | Qwen3.5-35B | Qwen2.5-72B (16-bit) |

### Memory Optimization

| Technique | VRAM Reduction | Quality Impact |
|-----------|----------------|----------------|
| **4-bit NF4** | ~75% | Minimal |
| **8-bit INT8** | ~50% | Very Low |
| **LoRA (r=16)** | ~90% trainable | None |
| **Gradient Checkpointing** | ~30% | None |
| **Flash Attention 2** | ~20% | None |

---

## Training Data

### Specialist Domains

| Specialist | Tables | Metrics | Examples |
|------------|--------|---------|----------|
| **Performance** | BPC.ZFI_FIN_OVER_AFO_CP_FIN | Income, NII, Costs, Margins | 100K |
| **Balance Sheet** | GL.FAGLFLEXT, SKA1 | Assets, Liabilities, Ratios | 100K |
| **Treasury** | TREASURY.POSITION | MtM, PV01, Duration, Yield | 100K |
| **ESG** | ESG.SF_FLAT | Emissions, Net-Zero, Scope 1/2/3 | 100K |
| **Router** | All domains | Classification labels | 50K |

### Data Generation

```bash
# Generate training data
cd src/training/schema_pipeline
python specialist_data_generator.py \
    --output-dir data/specialist_training \
    --examples 100000
```

---

## Training Workflow

### Quick Start

```bash
# 1. Generate training data
python schema_pipeline/specialist_data_generator.py --examples 10000

# 2. Train router (small model)
python nvidia-modelopt/scripts/train_qwen3.py \
    --specialist router \
    --tier router \
    --max-steps 500

# 3. Train specialists (larger models)
for spec in performance treasury esg balance_sheet; do
    python nvidia-modelopt/scripts/train_qwen3.py \
        --specialist $spec \
        --tier specialist \
        --max-steps 2000
done

# 4. Evaluate
python benchmarks/evaluate_specialist.py evaluate \
    --model-path ./outputs/performance_* \
    --specialist performance
```

### Production Training (H100/H200)

```bash
# Full training with Qwen 3.5 (when available)
python nvidia-modelopt/scripts/train_qwen3.py \
    --specialist performance \
    --model qwen3.5-9b \
    --num-examples 100000 \
    --output-dir /models/production

# With Nemotron alternative
python nvidia-modelopt/scripts/train_nemotron.py \
    --specialist treasury \
    --model nemotron-4-15b \
    --output-dir /models/production
```

---

## Files Reference

| File | Purpose |
|------|---------|
| `nvidia-modelopt/scripts/model_registry.py` | Model definitions & selection |
| `nvidia-modelopt/scripts/train_qwen3.py` | Qwen 3.5/2.5 training |
| `nvidia-modelopt/scripts/train_nemotron.py` | Nemotron training |
| `nvidia-modelopt/scripts/train_t4.py` | T4-specific training |
| `nvidia-modelopt/scripts/train_l4.py` | L4-specific training |
| `nvidia-modelopt/scripts/train_h200.py` | H200-specific training |
| `benchmarks/evaluate_specialist.py` | Evaluation & A/B testing |
| `schema_pipeline/specialist_data_generator.py` | Training data generation |
| `schema_pipeline/sql_validator.py` | SQL syntax validation |

---

## Qwen 3.5 Readiness

The training infrastructure is **forward-compatible** with Qwen 3.5:

### When Qwen 3.5 Releases:

1. **Automatic Detection**: Scripts check HuggingFace for model availability
2. **Seamless Switch**: No code changes needed, just run with `--model qwen3.5-9b`
3. **Expected Benefits**:
   - Improved instruction following
   - Better code generation
   - Larger context windows
   - More efficient inference

### Current Fallback:
- Qwen3.5-0.8B → Qwen2.5-1.5B
- Qwen3.5-4B → Qwen2.5-7B
- Qwen3.5-9B → Qwen2.5-14B
- Qwen3.5-35B → Qwen2.5-32B

---

## Current Training Status

| Component | Model | GPU | Status |
|-----------|-------|-----|--------|
| Router | Qwen2.5-0.5B | T4 | ✅ Trained |
| SQL Specialist | Qwen2.5-0.5B | T4 | ✅ Trained |
| ESG Specialist | Qwen2.5-7B | L4 | 🔄 Training |
| Performance | - | - | ⏳ Pending |
   - Use langchain-integration-for-sap-hana-cloud
   - Execute generated SQL

---

## Files Reference

| File | Purpose |
|------|---------|
| `nvidia-modelopt/scripts/train_t4.py` | T4 GPU training script |
| `nvidia-modelopt/configs/t4_qwen_7b.yaml` | T4 configuration |
| `schema_pipeline/specialist_data_generator.py` | 100K data generator |
| `schema_pipeline/sql_validator.py` | HANA SQL validator |
| `data/Prompt_samples.xlsx` | Treasury prompts |
| `data/ESG_Prompt_samples.xlsx` | ESG prompts |
| `data/Performance (BPC) - sample prompts.xlsx` | P&L/BS prompts |

---

*Last Updated: March 19, 2026*