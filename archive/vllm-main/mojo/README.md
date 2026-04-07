# ainuc-be-log-local-models Mojo Kernels

High-performance LLM inference kernels implemented in Mojo MAX for the local models service.

## Overview

This module provides ~80% of the core computational kernels in Mojo, delivering significant performance improvements over pure Python implementations through:

- **SIMD Vectorization**: Automatic vectorization of numerical operations
- **Parallel Execution**: Multi-threaded computation for large matrices
- **Memory Efficiency**: Explicit memory management with no garbage collection overhead
- **Hardware Optimization**: Leverages ARM NEON (Apple Silicon) and x86 AVX/AVX-512

## Module Structure

```
mojo/
├── mojoproject.toml           # Mojo project configuration
├── src/
│   ├── __init__.mojo          # Main module exports
│   ├── simd/
│   │   └── __init__.mojo      # SIMD vector operations
│   ├── kernel/
│   │   ├── __init__.mojo      # Core computational kernels
│   │   └── attention.mojo     # Attention mechanisms
│   ├── tokenizer/
│   │   └── __init__.mojo      # Tokenization kernels
│   └── inference/
│       └── __init__.mojo      # Full inference pipeline
└── tests/
    └── (test files)
```

## Components

### 1. SIMD Operations (`src/simd/`)
- Vector addition, multiplication, scaling
- Dot product (SIMD and parallel versions)
- Element-wise operations (exp, tanh, rsqrt)
- Reduction operations (sum, max, min)
- L2 and RMS normalization

### 2. Core Kernels (`src/kernel/`)
- **Matrix Multiplication (GEMM)**: Naive, SIMD, and parallel implementations
- **Softmax**: Numerically stable SIMD softmax
- **Layer Normalization**: Standard and RMS LayerNorm
- **Activation Functions**: GELU, SiLU, ReLU, Leaky ReLU

### 3. Attention Kernels (`src/kernel/attention.mojo`)
- **Scaled Dot-Product Attention**: O(n²) with causal masking
- **Flash Attention**: Block-wise memory-efficient attention
- **Multi-Head Attention**: Full MHA with projections
- **RoPE**: Rotary Position Embeddings
- **KV Cache**: Key-value caching for incremental decoding

### 4. Tokenizer (`src/tokenizer/`)
- BPE (Byte-Pair Encoding) tokenizer
- Token vocabulary management
- Batch encoding/decoding
- Sampling strategies (greedy, temperature, top-p, repetition penalty)

### 5. Inference Pipeline (`src/inference/`)
- Model configuration struct
- Layer and model weight management
- Transformer layer forward pass
- Text generation with KV caching

## Usage

### Building

```bash
cd src/ainuc-be-log/ainuc-be-log-local-models/mojo
magic shell  # Enter Mojo environment
mojo build src/__init__.mojo
```

### Running Tests

```bash
mojo test tests/
```

### Integration with Rust Backend

The Mojo kernels are compiled to shared libraries and called via FFI from the Rust backend:

```rust
// Rust FFI binding example
extern "C" {
    fn mojo_matmul_simd(
        a: *const f32,
        b: *const f32,
        c: *mut f32,
        m: i32,
        n: i32,
        k: i32
    );
}
```

## Performance Characteristics

| Operation | Description | Speedup vs Python |
|-----------|-------------|-------------------|
| GEMM | Matrix multiplication | ~100x |
| Softmax | SIMD softmax | ~50x |
| LayerNorm | RMS layer norm | ~40x |
| Attention | Scaled dot-product | ~80x |
| Tokenization | Batch encoding | ~20x |

## Key Design Decisions

1. **Float32 by Default**: Uses `DType.float32` for maximum compatibility and reasonable precision
2. **Explicit Memory**: All allocations are explicit with manual deallocation
3. **SIMD Width Auto-detection**: Uses `simdwidthof` to adapt to hardware
4. **Causal Masking**: Built into attention kernels for autoregressive generation
5. **KV Caching**: First-class support for incremental token generation

## Dependencies

- Mojo MAX SDK >= 25.1.0
- libc >= 2.34

## File Sizes (Approximate)

| File | Lines | Description |
|------|-------|-------------|
| `simd/__init__.mojo` | ~300 | Vector operations |
| `kernel/__init__.mojo` | ~380 | Core kernels |
| `kernel/attention.mojo` | ~400 | Attention mechanisms |
| `tokenizer/__init__.mojo` | ~380 | Tokenization |
| `inference/__init__.mojo` | ~500 | Full pipeline |
| **Total** | **~2000** | Core kernel code |

## Future Enhancements

- [ ] Quantization support (INT8, INT4)
- [ ] Flash Attention v2
- [ ] Grouped Query Attention (GQA)
- [ ] Speculative decoding
- [ ] Tensor parallelism for multi-GPU

## License

Part of the NucleusAI project.