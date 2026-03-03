# NVIDIA Model Optimizer Setup for T4 GPU

This project provides a ready-to-use setup for **NVIDIA Model Optimizer (ModelOpt)** specifically configured for **NVIDIA T4 GPUs** (16GB VRAM, Turing architecture).

## 🎯 Overview

NVIDIA Model Optimizer is a library for state-of-the-art model optimization including:
- **Quantization**: INT8, INT4 (AWQ), W4A16
- **Pruning**: Minitron structured pruning
- **Speculative Decoding**: Eagle-3 for faster inference

## ⚠️ T4 GPU Compatibility

| Feature | T4 Support | Notes |
|---------|------------|-------|
| **INT8** | ✅ Yes | **Recommended** - Best quality/performance balance |
| **INT4 (AWQ)** | ✅ Yes | Best compression (4x) |
| **W4A16** | ✅ Yes | Weight-only 4-bit |
| **Pruning** | ✅ Yes | Full Minitron support |
| **FP8** | ❌ No | Requires Ada Lovelace+ (RTX 40xx, L4, H100) |
| **NVFP4** | ❌ No | Requires Blackwell GPUs |

## 📁 Project Structure

```
nvidia-modelopt/
├── setup.sh                    # Automated setup script
├── requirements.txt            # Python dependencies
├── README.md                   # This file
├── configs/
│   └── qwen_int8.yaml          # T4-optimized configuration
├── scripts/
│   ├── verify_setup.py         # Verify installation
│   └── quantize_qwen.py        # Main quantization script
└── outputs/                    # Quantized models (created at runtime)
```

## 🚀 Quick Start

### 1. Run Setup Script

```bash
cd nvidia-modelopt
chmod +x setup.sh
./setup.sh
```

This will:
- Create a Python virtual environment
- Install all dependencies
- Install NVIDIA Model Optimizer
- Clone example repository
- Verify the installation

### 2. Activate Environment

```bash
source venv/bin/activate
```

### 3. Verify Installation

```bash
python scripts/verify_setup.py
```

### 4. Quantize a Model

```bash
# INT8 quantization (recommended for T4)
python scripts/quantize_qwen.py --model Qwen/Qwen3.5-1.8B --qformat int8

# INT4 AWQ quantization (best compression)
python scripts/quantize_qwen.py --model Qwen/Qwen3.5-4B --qformat int4_awq

# Using config file
python scripts/quantize_qwen.py --config configs/qwen_int8.yaml
```

## 📖 Usage Guide

### Command Line Options

```bash
python scripts/quantize_qwen.py --help
```

| Option | Default | Description |
|--------|---------|-------------|
| `--model` | `Qwen/Qwen3.5-1.8B` | Hugging Face model name or path |
| `--qformat` | `int8` | Quantization format: `int8`, `int4_awq`, `w4a16` |
| `--config` | - | Path to YAML configuration file |
| `--output` | `./outputs` | Output directory |
| `--calib-samples` | `512` | Number of calibration samples |
| `--calib-seq-len` | `2048` | Calibration sequence length |
| `--device` | `cuda:0` | Device to use |
| `--dtype` | `float16` | Model dtype: `float16`, `bfloat16` |
| `--export-format` | `hf` | Export format: `hf`, `tensorrt_llm`, `vllm` |
| `--skip-calibration` | - | Skip calibration (use defaults) |
| `--verbose` | - | Enable verbose output |

### Model Size Recommendations for T4 (16GB)

| Model | Unquantized | INT8 | INT4 | Recommended |
|-------|-------------|------|------|-------------|
| Qwen3.5-0.6B | 1.2 GB | 0.6 GB | 0.3 GB | No quantization needed |
| Qwen3.5-1.8B | 3.6 GB | 1.8 GB | 0.9 GB | INT8 |
| Qwen3.5-4B | 8 GB | 4 GB | 2 GB | INT8 |
| Qwen3.5-9B | 18 GB | 9 GB | 4.5 GB | INT4 + Pruning |
| Qwen3.5-14B | 28 GB | 14 GB | 7 GB | INT4 + Aggressive Pruning |

### Using Configuration Files

Create a YAML config file for reproducible workflows:

```yaml
# my_config.yaml
model:
  name: "Qwen/Qwen3.5-4B"
  trust_remote_code: true
  torch_dtype: "float16"

quantization:
  format: "int8_sq"
  calibration:
    dataset: "cnn_dailymail"
    num_samples: 512
    seq_length: 2048

export:
  format: "hf_checkpoint"
  output_dir: "./outputs/qwen4b_int8"
```

Then run:

```bash
python scripts/quantize_qwen.py --config my_config.yaml
```

## 🔧 Advanced Usage

### Pruning (Minitron)

For more aggressive optimization, enable pruning in your config:

```yaml
pruning:
  enabled: true
  method: "mcore_minitron"
  target_sparsity: 0.2  # Remove 20% of parameters
  
  prune_attention_heads: true
  prune_ffn_hidden: true
  prune_embedding: false
```

### Export to TensorRT-LLM

For production deployment:

```bash
python scripts/quantize_qwen.py \
  --model Qwen/Qwen3.5-1.8B \
  --qformat int8 \
  --export-format tensorrt_llm
```

### Export for vLLM

```bash
python scripts/quantize_qwen.py \
  --model Qwen/Qwen3.5-1.8B \
  --qformat int4_awq \
  --export-format vllm
```

## 🐛 Troubleshooting

### CUDA Not Available

```
✗ CUDA not available
```

**Solution**: Ensure NVIDIA drivers and CUDA are installed:
```bash
nvidia-smi  # Should show your GPU
```

### ModelOpt Import Error

```
ImportError: nvidia-modelopt is not installed
```

**Solution**: Install from NVIDIA PyPI:
```bash
pip install "nvidia-modelopt[all]" -U --extra-index-url https://pypi.nvidia.com
```

### Out of Memory (OOM)

```
CUDA out of memory
```

**Solutions**:
1. Use more aggressive quantization: `--qformat int4_awq`
2. Reduce calibration samples: `--calib-samples 128`
3. Reduce sequence length: `--calib-seq-len 512`
4. Use a smaller model

### FP8/NVFP4 Not Supported

```
Quantization format 'fp8' is NOT supported on Tesla T4
```

**Solution**: T4 doesn't support FP8 or NVFP4. Use `int8` or `int4_awq` instead.

## 📚 Resources

- [NVIDIA Model Optimizer GitHub](https://github.com/NVIDIA/TensorRT-Model-Optimizer)
- [ModelOpt Documentation](https://nvidia.github.io/TensorRT-Model-Optimizer)
- [Qwen3.5 Models on Hugging Face](https://huggingface.co/Qwen)
- [TensorRT-LLM](https://github.com/NVIDIA/TensorRT-LLM)

## 📄 License

This project setup is provided as-is. NVIDIA Model Optimizer is subject to NVIDIA's licensing terms.

## 🆘 Support

For issues with:
- **This setup**: Check the troubleshooting section above
- **NVIDIA ModelOpt**: [GitHub Issues](https://github.com/NVIDIA/TensorRT-Model-Optimizer/issues)
- **Qwen models**: [Qwen GitHub](https://github.com/QwenLM/Qwen)