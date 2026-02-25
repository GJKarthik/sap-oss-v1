# vLLM Rewrite: Zig + Mojo + Mangle

[![Build Status](https://img.shields.io/badge/build-passing-brightgreen)]()
[![Zig](https://img.shields.io/badge/Zig-0.13+-orange)]()
[![Mojo](https://img.shields.io/badge/Mojo-24.x+-purple)]()
[![License](https://img.shields.io/badge/License-Apache%202.0-blue)]()

> A complete rewrite of vLLM's Python codebase in **Zig**, **Mojo**, and **Mangle** for maximum performance, memory safety, and declarative policy management.

## 🎯 Project Goals

1. **Performance**: 10-30% improvement in tokens/sec, 50% reduction in TTFT
2. **Memory Efficiency**: 93% reduction in system memory overhead
3. **Safety**: Memory-safe systems programming with Zig
4. **ML Optimization**: Leveraging Mojo's SIMD and ML-native features
5. **Declarative Policies**: Using Mangle for scheduling and validation rules

## 📊 Performance Targets

| Metric | Python vLLM | Zig/Mojo vLLM | Target Improvement |
|--------|-------------|---------------|-------------------|
| Tokens/sec (batch=32) | 800 | 960 | +20% |
| TTFT (ms) | 150 | 80 | -47% |
| Memory Overhead | 3GB | 200MB | -93% |
| P99 Latency | 250ms | 150ms | -40% |

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        API Layer (Zig)                          │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │ HTTP Server │  │ gRPC Server │  │ CLI Interface           │  │
│  └─────────────┘  └─────────────┘  └─────────────────────────┘  │
├─────────────────────────────────────────────────────────────────┤
│                     Rules Engine (Mangle)                       │
│  ┌──────────┐  ┌────────────┐  ┌──────────┐  ┌──────────────┐   │
│  │ Config   │  │ Scheduling │  │ Memory   │  │ Validation   │   │
│  │ Rules    │  │ Policies   │  │ Rules    │  │ Rules        │   │
│  └──────────┘  └────────────┘  └──────────┘  └──────────────┘   │
├─────────────────────────────────────────────────────────────────┤
│                    Engine Core (Zig)                            │
│  ┌───────────┐  ┌───────────┐  ┌────────────┐  ┌────────────┐   │
│  │ Scheduler │  │ Block Mgr │  │ Distributed │  │ Platform   │   │
│  └───────────┘  └───────────┘  └────────────┘  └────────────┘   │
├─────────────────────────────────────────────────────────────────┤
│                    Model Layer (Mojo)                           │
│  ┌──────────┐  ┌────────────┐  ┌────────────┐  ┌────────────┐   │
│  │ 200+     │  │ Layers     │  │ Quant      │  │ Multimodal │   │
│  │ Models   │  │ (Attn,MLP) │  │ (FP8,INT4) │  │ (Vision)   │   │
│  └──────────┘  └────────────┘  └────────────┘  └────────────┘   │
├─────────────────────────────────────────────────────────────────┤
│              CUDA/C++ Kernels (Unchanged)                       │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ Flash Attention │ GEMM │ LayerNorm │ Custom Kernels     │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

## 📁 Project Structure

```
vllm-rewrite/
├── zig/                    # Systems infrastructure (Zig)
│   ├── src/
│   │   ├── engine/         # Core inference engine
│   │   ├── scheduler/      # Request scheduling
│   │   ├── memory/         # KV-cache management
│   │   ├── distributed/    # Tensor/pipeline parallelism
│   │   ├── platform/       # CUDA/ROCm abstraction
│   │   ├── server/         # HTTP/gRPC servers
│   │   └── cli/            # Command-line interface
│   └── tests/
├── mojo/                   # ML computation layer (Mojo)
│   ├── src/
│   │   ├── layers/         # Neural network layers
│   │   ├── models/         # 200+ model implementations
│   │   ├── quantization/   # FP8, INT4, AWQ, GPTQ
│   │   ├── multimodal/     # Vision, audio encoders
│   │   └── lora/           # LoRA adapters
│   └── tests/
├── mangle/                 # Declarative rules (Mangle)
│   ├── config/             # Configuration validation
│   ├── scheduling/         # Scheduling policies
│   ├── memory/             # Memory management rules
│   └── validation/         # Request validation
├── csrc/                   # Existing CUDA/C++ (unchanged)
├── bindings/               # Cross-language FFI
├── docs/                   # Documentation
├── tracking/               # Progress tracking
└── tests/                  # Integration tests
```

## 🚀 Quick Start

### Prerequisites

```bash
# Install Zig
curl -L https://ziglang.org/download/0.13.0/zig-macos-aarch64-0.13.0.tar.xz | tar -xJ

# Install Mojo
curl -s https://get.modular.com | sh
modular install mojo

# Install Mangle (Google's implementation)
# See: https://github.com/google/mangle
```

### Build

```bash
# Build Zig components
cd zig && zig build -Doptimize=ReleaseFast

# Build Mojo components
cd mojo && mojo build src/

# Verify Mangle rules
cd mangle && mangle check *.mg
```

### Run

```bash
# Start the server
./zig/zig-out/bin/vllm serve --model meta-llama/Llama-3-8B --port 8000

# Or use the Python-compatible CLI
vllm serve --model meta-llama/Llama-3-8B
```

## 🗓️ Development Timeline

| Phase | Duration | Focus | Status |
|-------|----------|-------|--------|
| 1. Foundation | Weeks 1-4 | Project setup, type system | 🔄 In Progress |
| 2. Zig Infrastructure | Weeks 5-12 | Engine, scheduler, memory | ⏳ Planned |
| 3. Mojo Models | Weeks 13-36 | Layers, models, quantization | ⏳ Planned |
| 4. Mangle Rules | Weeks 37-44 | Policies, validation | ⏳ Planned |
| 5. API Layer | Weeks 45-48 | HTTP, gRPC, CLI | ⏳ Planned |
| 6. Testing | Weeks 49-52 | Integration, benchmarks | ⏳ Planned |

## 🤝 Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

### Daily Progress

Check `tracking/daily/` for daily progress reports.

### Code Style

- **Zig**: Follow [Zig Style Guide](https://ziglang.org/documentation/master/#Style-Guide)
- **Mojo**: Follow Modular's style guidelines
- **Mangle**: Use consistent predicate naming (snake_case)

## 📈 Metrics Dashboard

Track performance metrics in `tracking/metrics/`:

- Build times
- Test coverage
- Lines of code by language
- Performance benchmarks

## 📄 License

Apache 2.0 - See [LICENSE](LICENSE)

## 🔗 Links

- [Original vLLM](https://github.com/vllm-project/vllm)
- [Zig Documentation](https://ziglang.org/documentation)
- [Mojo Documentation](https://docs.modular.com/mojo)
- [Mangle (Google)](https://github.com/google/mangle)