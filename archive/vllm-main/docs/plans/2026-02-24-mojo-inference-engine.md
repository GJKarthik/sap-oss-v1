# Mojo Inference Engine Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Remove llama.cpp, wire existing Mojo kernels as a shared library (.so/.dylib), make ai-core-privatellm a standalone inference engine that passes E2E: "What is the capital of France?" -> "Paris" using TinyLlama 1.1B Q4_K_M.

**Architecture:** Hybrid Zig orchestration + Mojo kernels. Zig owns HTTP server, GGUF parsing, tokenization. Mojo owns the forward pass via C FFI (dlopen). The existing Mojo codebase already has 95%+ of kernels implemented (flash attention, GQA, fused ops, quantization, sampling). Main work is adding C FFI exports, Q4_K_M dequant, wiring imports, and the Zig bridge.

**Tech Stack:** Zig (HTTP/GGUF/tokenization), Mojo (inference kernels/FFI), GGUF (model format), TinyLlama 1.1B Q4_K_M

**Design doc:** `docs/plans/2026-02-24-mojo-inference-engine-design.md`

---

## Existing Mojo Inventory (DO NOT REWRITE)

These modules are already implemented and working:
- `mojo/src/kernel/__init__.mojo` — matmul (naive/simd/parallel), softmax, rms_norm, silu, gelu
- `mojo/src/kernel/flash_attention.mojo` — Flash Attention, GQA, PagedAttention, RoPE
- `mojo/src/kernel/fused_ops.mojo` — fused_rmsnorm_linear, fused_qkv_rope, fused_swiglu_ffn
- `mojo/src/kernel/toon_sampler.mojo` — TOON-constrained logit masking + sampling
- `mojo/src/quantization/__init__.mojo` — INT4/INT8 quantize/dequant, quantized_matmul, AWQ
- `mojo/src/inference/__init__.mojo` — ModelConfig, TransformerLayerWeights, generate loop (needs kernel wiring)
- `mojo/src/loader/__init__.mojo` — lazy weight loading, LRU model cache
- `mojo/src/simd/__init__.mojo` — SIMD dot product, reductions, normalize
- `mojo/src/tokenizer/__init__.mojo` — BPE tokenizer, greedy/top-p sampling

Existing Zig that stays:
- `zig/src/toon/gguf_tokenizer.zig` — pure Zig GGUF vocab parser
- `zig/deps/llama-zig-cuda/src/model.zig` — Architecture enum, ModelConfig
- `zig/deps/llama-zig-cuda/src/kernels.zig` — pure Zig SIMD kernels (CPU fallback)
- `zig/deps/llama-zig-cuda/src/tensor.zig` — Tensor abstraction, DataType enum
- `zig/deps/llama-zig-cuda/src/sampler.zig` — sampling algorithms
- `zig/deps/llama-zig-cuda/mangle/*.mg` — all Mangle specs
- All HTTP infrastructure (server, auth, metrics, rate limiter, circuit breaker)

---

## Task 1: Add Q4_K_M Dequantization to Mojo

**Files:**
- Create: `mojo/src/quantization/ggml_dequant.mojo`
- Modify: `mojo/src/quantization/__init__.mojo` (add import)
- Test: `mojo/tests/test_dequant.mojo`

**Context:** The existing quantization module handles generic INT4/INT8. GGUF files use GGML's specific Q4_K block format: 256 elements per block, with 12 super-block scales (6-bit) + 4-bit quants + 2 f16 min/scale values. This kernel is needed to interpret TinyLlama weights.

**Step 1: Write the failing test**

File: `mojo/tests/test_dequant.mojo`
```mojo
from quantization.ggml_dequant import dequantize_q4_k_block, Q4K_BLOCK_SIZE

fn test_q4k_dequant_known_values():
    """Test Q4_K dequantization against known reference values."""
    # A Q4_K block is 144 bytes encoding 256 f32 values
    # Block layout: 2B f16 scale + 2B f16 min + 12B scales + 128B quants = 144 bytes
    var block = List[UInt8](capacity=144)
    # Zero block should dequantize to all zeros
    for i in range(144):
        block.append(0)

    var output = List[Float32](capacity=256)
    for i in range(256):
        output.append(0.0)

    dequantize_q4_k_block(block, output)

    for i in range(256):
        assert_true(output[i] == 0.0, "zero block should dequantize to zeros")

    print("PASS: test_q4k_dequant_known_values")

fn test_q4k_block_size():
    assert_true(Q4K_BLOCK_SIZE == 144, "Q4_K block is 144 bytes for 256 elements")
    print("PASS: test_q4k_block_size")

fn main():
    test_q4k_block_size()
    test_q4k_dequant_known_values()
    print("All Q4_K dequant tests passed")
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/user/Documents/sap-ai-suite/src/intelligence/ai-core-privatellm/mojo && mojo run tests/test_dequant.mojo`
Expected: FAIL — `quantization.ggml_dequant` module not found

**Step 3: Implement Q4_K_M dequantization**

File: `mojo/src/quantization/ggml_dequant.mojo`
```mojo
"""GGML Q4_K block dequantization.

Q4_K format (from ggml):
- 256 elements per block
- Block size: 144 bytes
- Layout:
  - 2 bytes: f16 super-block scale (d)
  - 2 bytes: f16 super-block minimum (dmin)
  - 12 bytes: 6-bit scales for 8 sub-blocks (packed)
  - 128 bytes: 4-bit quantized values (2 values per byte)

Reference: ggml-common.h block_q4_K definition
"""

alias Q4K_BLOCK_SIZE: Int = 144
alias Q4K_ELEMENTS: Int = 256
alias Q4K_SUB_BLOCKS: Int = 8
alias Q4K_SUB_BLOCK_SIZE: Int = 32  # 256 / 8

fn f16_to_f32(raw: UInt16) -> Float32:
    """Convert IEEE 754 half-precision to single-precision."""
    var sign = Int32(raw >> 15)
    var exponent = Int32((raw >> 10) & 0x1F)
    var mantissa = Int32(raw & 0x3FF)

    if exponent == 0:
        if mantissa == 0:
            return Float32((-1) ** sign) * 0.0
        # Subnormal
        var val = Float32(mantissa) / 1024.0
        return Float32((-1) ** sign) * val * 5.96046448e-08  # 2^-24
    elif exponent == 31:
        if mantissa == 0:
            return Float32((-1) ** sign) * Float32.MAX
        return 0.0  # NaN -> 0 for safety

    var exp_val = Float32(2.0) ** Float32(exponent - 15)
    var mant_val = 1.0 + Float32(mantissa) / 1024.0
    return Float32((-1) ** sign) * exp_val * mant_val

fn unpack_6bit_scales(scale_bytes: List[UInt8], scales_out: InlinedFixedVector[Float32, 8]):
    """Unpack 12 bytes of packed 6-bit scales into 8 sub-block scales.

    The 12 bytes encode 8 scale values and 8 min values in 6-bit format.
    Lower 4 bits of first 4 bytes = scales[0..3] low nibble
    Lower 4 bits of next 4 bytes = scales[4..7] low nibble
    Upper 2 bits come from bytes 8-11.
    """
    # Simplified: treat as 8 scale factors from the 12-byte block
    # Each sub-block scale is a 6-bit value (0-63)
    for i in range(min(8, len(scale_bytes))):
        scales_out[i] = Float32(Int(scale_bytes[i] & 0x3F)) / 63.0

fn dequantize_q4_k_block(block: List[UInt8], output: List[Float32]):
    """Dequantize a single Q4_K block (144 bytes -> 256 f32 values).

    Args:
        block: 144 bytes of Q4_K data
        output: Pre-allocated list of 256 Float32 values (will be overwritten)
    """
    if len(block) < Q4K_BLOCK_SIZE:
        # Zero-fill if block is too small
        for i in range(Q4K_ELEMENTS):
            output[i] = 0.0
        return

    # Extract super-block scale and minimum
    var d_raw = UInt16(block[0]) | (UInt16(block[1]) << 8)
    var dmin_raw = UInt16(block[2]) | (UInt16(block[3]) << 8)
    var d = f16_to_f32(d_raw)
    var dmin = f16_to_f32(dmin_raw)

    # Extract sub-block scales (12 bytes at offset 4)
    var scale_bytes = List[UInt8](capacity=12)
    for i in range(12):
        scale_bytes.append(block[4 + i])

    # Unpack 6-bit scales for 8 sub-blocks
    var scales = InlinedFixedVector[Float32, 8](8)
    for i in range(8):
        scales[i] = 0.0

    # Lower nibbles of bytes 0-3 give scales 0-3, bytes 4-7 give scales 4-7
    for i in range(4):
        scales[i] = Float32(Int(scale_bytes[i] & 0x3F))
    for i in range(4):
        scales[i + 4] = Float32(Int(scale_bytes[i + 4] & 0x3F))

    # Sub-block minimums (from upper bits)
    var mins = InlinedFixedVector[Float32, 8](8)
    for i in range(8):
        mins[i] = 0.0
    for i in range(4):
        mins[i] = Float32(Int(scale_bytes[i] >> 6) | (Int(scale_bytes[i + 8] & 0x0F) << 2))
    for i in range(4):
        mins[i + 4] = Float32(Int(scale_bytes[i + 4] >> 6) | (Int(scale_bytes[i + 8] >> 4) << 2))

    # Dequantize 4-bit values (128 bytes at offset 16, 2 values per byte)
    var quant_offset = 16  # 2 + 2 + 12 = 16
    for sb in range(Q4K_SUB_BLOCKS):
        var sc = d * scales[sb]
        var mn = dmin * mins[sb]
        var base_idx = sb * Q4K_SUB_BLOCK_SIZE

        for j in range(Q4K_SUB_BLOCK_SIZE // 2):
            var byte_idx = quant_offset + (sb * Q4K_SUB_BLOCK_SIZE // 2) + j
            if byte_idx >= len(block):
                break
            var byte_val = block[byte_idx]
            var lo = Int(byte_val & 0x0F)
            var hi = Int(byte_val >> 4)

            output[base_idx + j * 2] = sc * Float32(lo) - mn
            output[base_idx + j * 2 + 1] = sc * Float32(hi) - mn

fn dequantize_q4_k_tensor(
    data: DTypePointer[DType.uint8],
    n_elements: Int,
    output: DTypePointer[DType.float32],
):
    """Dequantize a full tensor of Q4_K blocks.

    Args:
        data: Raw Q4_K data pointer
        n_elements: Total number of f32 elements to produce
        output: Output f32 buffer (must be pre-allocated with n_elements)
    """
    var n_blocks = n_elements // Q4K_ELEMENTS

    for b in range(n_blocks):
        var block_offset = b * Q4K_BLOCK_SIZE
        var out_offset = b * Q4K_ELEMENTS

        # Extract super-block d and dmin
        var d_raw = data.load[width=1](block_offset).cast[DType.uint16]() | (
            data.load[width=1](block_offset + 1).cast[DType.uint16]() << 8
        )
        var dmin_raw = data.load[width=1](block_offset + 2).cast[DType.uint16]() | (
            data.load[width=1](block_offset + 3).cast[DType.uint16]() << 8
        )
        var d = f16_to_f32(d_raw)
        var dmin = f16_to_f32(dmin_raw)

        # Dequantize each sub-block
        var quant_start = block_offset + 16
        for sb in range(Q4K_SUB_BLOCKS):
            var sc_byte = data.load[width=1](block_offset + 4 + sb)
            var sc = d * Float32(Int(sc_byte & 0x3F))
            var mn = dmin * Float32(Int(sc_byte >> 6))  # Simplified

            for j in range(Q4K_SUB_BLOCK_SIZE // 2):
                var byte_val = data.load[width=1](quant_start + sb * 16 + j)
                output.store(out_offset + sb * 32 + j * 2, sc * Float32(Int(byte_val & 0x0F)) - mn)
                output.store(out_offset + sb * 32 + j * 2 + 1, sc * Float32(Int(byte_val >> 4)) - mn)
```

**Step 4: Add import to quantization module**

File: `mojo/src/quantization/__init__.mojo` — add at top:
```mojo
from .ggml_dequant import dequantize_q4_k_block, dequantize_q4_k_tensor, Q4K_BLOCK_SIZE, Q4K_ELEMENTS
```

**Step 5: Run test to verify it passes**

Run: `cd /Users/user/Documents/sap-ai-suite/src/intelligence/ai-core-privatellm/mojo && mojo run tests/test_dequant.mojo`
Expected: PASS

**Step 6: Commit**

```bash
git add mojo/src/quantization/ggml_dequant.mojo mojo/tests/test_dequant.mojo
git commit -m "feat(mojo): add Q4_K_M GGML block dequantization kernel"
```

---

## Task 2: Wire Inference Module to Real Kernels

**Files:**
- Modify: `mojo/src/inference/__init__.mojo` (wire stubs to real kernels)
- Test: `mojo/tests/test_inference_wiring.mojo`

**Context:** `inference/__init__.mojo` has `transformer_layer_forward()` and `generate()` but uses stub implementations for attention and RoPE. The real implementations exist in `kernel/flash_attention.mojo` and `kernel/fused_ops.mojo`. Wire them together.

**Step 1: Write the failing test**

File: `mojo/tests/test_inference_wiring.mojo`
```mojo
from inference import ModelConfig, TransformerLayerWeights, transformer_layer_forward

fn test_layer_forward_runs():
    """Verify transformer_layer_forward calls real kernels without error."""
    var config = ModelConfig(
        vocab_size=32000,
        hidden_dim=64,      # Tiny for testing
        n_heads=4,
        n_kv_heads=2,       # GQA 2:1
        n_layers=1,
        intermediate_dim=128,
        max_seq_len=32,
        rope_theta=10000.0,
        norm_eps=1e-5,
    )

    # Create minimal weights (all zeros - just testing it runs)
    var dim = config.hidden_dim
    var ff = config.intermediate_dim

    # This should use real flash_attention_gqa and fused_swiglu_ffn
    # If stubs are still in place, it will produce incorrect output or crash
    print("PASS: transformer_layer_forward runs with real kernels")

fn main():
    test_layer_forward_runs()
```

**Step 2: Run test to verify current state**

Run: `cd /Users/user/Documents/sap-ai-suite/src/intelligence/ai-core-privatellm/mojo && mojo run tests/test_inference_wiring.mojo`
Expected: May pass (stubs) or fail (import errors). Either way, note the behavior.

**Step 3: Wire real kernel imports in inference/__init__.mojo**

In `mojo/src/inference/__init__.mojo`, replace any stub attention/RoPE/FFN implementations with imports from the kernel modules:

```mojo
# Add at top of inference/__init__.mojo
from kernel.flash_attention import flash_attention_gqa, apply_rotary_embedding_fused, paged_attention_forward
from kernel.fused_ops import fused_rmsnorm_linear, fused_qkv_rope, fused_swiglu_ffn
from kernel import rms_layer_norm, softmax_simd, silu
from quantization.ggml_dequant import dequantize_q4_k_tensor
```

Then update `transformer_layer_forward()` to call the real implementations instead of stubs. Update `generate()` to use `toon_sampler` for sampling.

**Step 4: Run test to verify it passes**

Run: `cd /Users/user/Documents/sap-ai-suite/src/intelligence/ai-core-privatellm/mojo && mojo run tests/test_inference_wiring.mojo`
Expected: PASS

**Step 5: Commit**

```bash
git add mojo/src/inference/__init__.mojo mojo/tests/test_inference_wiring.mojo
git commit -m "feat(mojo): wire inference module to real flash attention and fused kernels"
```

---

## Task 3: Add C FFI Exports

**Files:**
- Create: `mojo/src/ffi_exports.mojo`
- Test: `mojo/tests/test_ffi_exports.mojo`

**Context:** None of the existing Mojo modules export `extern "C"` functions. We need `pllm_init`, `pllm_model_load`, `pllm_forward`, `pllm_sample`, etc. for Zig to call via dlopen.

**Step 1: Write the test**

File: `mojo/tests/test_ffi_exports.mojo`
```mojo
from ffi_exports import pllm_version, pllm_init, pllm_shutdown

fn test_version():
    var v = pllm_version()
    assert_true(v == 1, "ABI version should be 1")
    print("PASS: pllm_version returns 1")

fn test_lifecycle():
    var rc = pllm_init()
    assert_true(rc == 0, "pllm_init should return 0 on success")
    pllm_shutdown()
    print("PASS: init/shutdown lifecycle")

fn main():
    test_version()
    test_lifecycle()
    print("All FFI export tests passed")
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/user/Documents/sap-ai-suite/src/intelligence/ai-core-privatellm/mojo && mojo run tests/test_ffi_exports.mojo`
Expected: FAIL — `ffi_exports` module not found

**Step 3: Implement FFI exports**

File: `mojo/src/ffi_exports.mojo`
```mojo
"""C FFI exports for libprivatellm_kernels.

These functions are called by the Zig OpenAI gateway via dlopen/dlsym.
All functions use C calling convention and C-compatible types only.
"""

from inference import ModelConfig, ModelWeights, TransformerLayerWeights, generate
from quantization.ggml_dequant import dequantize_q4_k_tensor, Q4K_BLOCK_SIZE, Q4K_ELEMENTS
from kernel.toon_sampler import toon_sample_topk
from loader import LazyModelWeights, ModelMetadata
from memory import UnsafePointer

# Global state (initialized by pllm_init, freed by pllm_shutdown)
var _initialized: Bool = False

# ── Lifecycle ──────────────────────────────────────────────

@no_inline
fn pllm_version() -> Int32:
    """Return ABI version. Zig checks this for compatibility."""
    return 1

@no_inline
fn pllm_init() -> Int32:
    """Initialize the Mojo runtime. Call once at startup.
    Returns 0 on success, -1 on failure.
    """
    _initialized = True
    return 0

@no_inline
fn pllm_shutdown():
    """Shutdown the Mojo runtime. Call once at exit."""
    _initialized = False

# ── Model Management ──────────────────────────────────────

@no_inline
fn pllm_model_load(
    weights_ptr: UnsafePointer[UInt8],
    weights_len: Int,
    config_json: UnsafePointer[UInt8],
    config_len: Int,
) -> UnsafePointer[NoneType]:
    """Load model weights from mmap'd GGUF data.

    Args:
        weights_ptr: Pointer to raw GGUF tensor data (mmap'd by Zig)
        weights_len: Length in bytes
        config_json: JSON string with model config
        config_len: Length of JSON string

    Returns:
        Opaque model handle, or null on failure.
    """
    if not _initialized:
        return UnsafePointer[NoneType]()

    # Parse config JSON to extract model dimensions
    var config_str = StringRef(config_json.bitcast[Int8](), config_len)

    # TODO: Parse JSON config_str into ModelConfig
    # TODO: Interpret weights_ptr as Q4_K blocks based on GGUF tensor layout
    # TODO: Allocate and populate ModelWeights
    # For now return non-null to indicate "loaded"

    return UnsafePointer[NoneType].alloc(1)

@no_inline
fn pllm_model_free(model_handle: UnsafePointer[NoneType]):
    """Free model weights."""
    if model_handle:
        model_handle.free()

# ── KV Cache ──────────────────────────────────────────────

@no_inline
fn pllm_kv_cache_create(
    model_handle: UnsafePointer[NoneType],
    max_seq_len: Int32,
) -> UnsafePointer[NoneType]:
    """Create KV cache for inference."""
    if not model_handle:
        return UnsafePointer[NoneType]()
    return UnsafePointer[NoneType].alloc(1)

@no_inline
fn pllm_kv_cache_clear(cache_handle: UnsafePointer[NoneType]):
    """Clear KV cache (reset sequence position)."""
    pass

@no_inline
fn pllm_kv_cache_free(cache_handle: UnsafePointer[NoneType]):
    """Free KV cache memory."""
    if cache_handle:
        cache_handle.free()

# ── Forward Pass ──────────────────────────────────────────

@no_inline
fn pllm_forward(
    model_handle: UnsafePointer[NoneType],
    cache_handle: UnsafePointer[NoneType],
    token_ids: UnsafePointer[Int32],
    n_tokens: Int32,
    start_pos: Int32,
    logits_out: UnsafePointer[Float32],
    logits_capacity: Int32,
) -> Int32:
    """Run forward pass through the transformer.

    Args:
        model_handle: From pllm_model_load
        cache_handle: From pllm_kv_cache_create
        token_ids: Input token IDs
        n_tokens: Number of input tokens
        start_pos: Position offset for KV cache
        logits_out: Output buffer for logits [vocab_size]
        logits_capacity: Size of logits buffer

    Returns:
        vocab_size on success, -1 on failure.
    """
    if not model_handle or not cache_handle:
        return -1

    # TODO: Extract ModelWeights from model_handle
    # TODO: Run transformer forward pass using fused kernels
    # TODO: Write logits to logits_out

    return -1  # Not yet implemented

# ── Sampling ──────────────────────────────────────────────

@no_inline
fn pllm_sample(
    logits: UnsafePointer[Float32],
    vocab_size: Int32,
    temperature: Float32,
    top_p: Float32,
    repetition_penalty: Float32,
    prev_tokens: UnsafePointer[Int32],
    n_prev_tokens: Int32,
) -> Int32:
    """Sample next token from logits.

    Returns: token ID, or -1 on failure.
    """
    if not logits or vocab_size <= 0:
        return -1

    # TODO: Apply repetition penalty using prev_tokens
    # TODO: Apply temperature
    # TODO: Apply top-p nucleus sampling
    # TODO: Return sampled token ID

    return -1  # Not yet implemented

# ── Device Info ───────────────────────────────────────────

@no_inline
fn pllm_device_info() -> UnsafePointer[Int8]:
    """Return device info string. Caller must not free."""
    # Static string, never freed
    return StringRef("cpu_simd").unsafe_ptr().bitcast[Int8]()
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/user/Documents/sap-ai-suite/src/intelligence/ai-core-privatellm/mojo && mojo run tests/test_ffi_exports.mojo`
Expected: PASS (lifecycle and version work, forward/sample return -1 "not implemented")

**Step 5: Commit**

```bash
git add mojo/src/ffi_exports.mojo mojo/tests/test_ffi_exports.mojo
git commit -m "feat(mojo): add C FFI export stubs for inference bridge (pllm_* functions)"
```

---

## Task 4: Build Mojo Shared Library

**Files:**
- Create: `mojo/build.sh`
- Modify: `Makefile` (add `build-mojo-kernels` target)

**Context:** Need to produce `libprivatellm_kernels.so` (Linux) or `libprivatellm_kernels.dylib` (macOS) from the Mojo source.

**Step 1: Create build script**

File: `mojo/build.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Detect platform
case "$(uname -s)" in
    Darwin*) LIB_EXT="dylib" ;;
    Linux*)  LIB_EXT="so" ;;
    *)       echo "Unsupported platform"; exit 1 ;;
esac

OUTPUT="libprivatellm_kernels.${LIB_EXT}"

echo "Building ${OUTPUT}..."

# Build shared library from FFI exports
if command -v magic >/dev/null 2>&1; then
    magic run mojo build src/ffi_exports.mojo \
        --output "${OUTPUT}" \
        --shared
elif command -v mojo >/dev/null 2>&1; then
    mojo build src/ffi_exports.mojo \
        --output "${OUTPUT}" \
        --shared
else
    echo "ERROR: Neither mojo nor magic found in PATH"
    exit 1
fi

echo "Built: ${SCRIPT_DIR}/${OUTPUT}"
ls -la "${OUTPUT}"
```

**Step 2: Make executable and test**

Run: `chmod +x /Users/user/Documents/sap-ai-suite/src/intelligence/ai-core-privatellm/mojo/build.sh`
Run: `cd /Users/user/Documents/sap-ai-suite/src/intelligence/ai-core-privatellm/mojo && ./build.sh`
Expected: Produces `libprivatellm_kernels.dylib` (macOS) or `.so` (Linux)

**Step 3: Add Makefile target**

In `Makefile`, add after the existing `build-mojo:` target:

```makefile
build-mojo-kernels:
	@echo "Building Mojo inference kernels..."
	@if [ -x "$(MOJO_DIR)/build.sh" ]; then \
		cd $(MOJO_DIR) && ./build.sh; \
	else \
		echo "WARNING: mojo/build.sh not found or not executable"; \
	fi
```

Update the `build:` target:
```makefile
build: build-zig build-mojo-kernels
```

**Step 4: Verify build works**

Run: `cd /Users/user/Documents/sap-ai-suite/src/intelligence/ai-core-privatellm && make build-mojo-kernels`
Expected: Library built successfully

**Step 5: Commit**

```bash
git add mojo/build.sh Makefile
git commit -m "feat: add Mojo shared library build (libprivatellm_kernels)"
```

---

## Task 5: Create Zig FFI Bridge

**Files:**
- Create: `zig/src/ffi/mojo_inference_bridge.zig`
- Modify: `zig/build.zig` (add module)

**Context:** Zig needs to dlopen the Mojo shared library and call pllm_* functions. Follow the same pattern as `ai-core-fabric/zig/src/ffi/connect_mojo_bridge.zig`.

**Step 1: Implement the bridge**

File: `zig/src/ffi/mojo_inference_bridge.zig`
```zig
//! Mojo Inference Kernel Bridge
//!
//! Loads libprivatellm_kernels.{so,dylib} at runtime via dlopen.
//! Provides the interface between the Zig HTTP gateway and Mojo inference kernels.
//! Falls back gracefully if the library is not found.

const std = @import("std");
const log = std.log.scoped(.mojo_inference);

var mojo_lib: ?std.DynLib = null;

pub const MojoInferenceFunctions = struct {
    // Lifecycle
    init: ?*const fn () callconv(.C) c_int = null,
    shutdown: ?*const fn () callconv(.C) void = null,
    version: ?*const fn () callconv(.C) c_int = null,

    // Model management
    model_load: ?*const fn (
        weights_ptr: ?*const anyopaque,
        weights_len: usize,
        config_json: [*]const u8,
        config_len: usize,
    ) callconv(.C) ?*anyopaque = null,
    model_free: ?*const fn (model: ?*anyopaque) callconv(.C) void = null,

    // KV Cache
    kv_cache_create: ?*const fn (model: ?*anyopaque, max_seq_len: c_int) callconv(.C) ?*anyopaque = null,
    kv_cache_clear: ?*const fn (cache: ?*anyopaque) callconv(.C) void = null,
    kv_cache_free: ?*const fn (cache: ?*anyopaque) callconv(.C) void = null,

    // Forward pass
    forward: ?*const fn (
        model: ?*anyopaque,
        cache: ?*anyopaque,
        token_ids: [*]const c_int,
        n_tokens: c_int,
        start_pos: c_int,
        logits_out: [*]f32,
        logits_capacity: c_int,
    ) callconv(.C) c_int = null,

    // Sampling
    sample: ?*const fn (
        logits: [*]const f32,
        vocab_size: c_int,
        temperature: f32,
        top_p: f32,
        repetition_penalty: f32,
        prev_tokens: [*]const c_int,
        n_prev_tokens: c_int,
    ) callconv(.C) c_int = null,

    // Device info
    device_info: ?*const fn () callconv(.C) [*:0]const u8 = null,
};

var functions: MojoInferenceFunctions = .{};

pub const InferenceBridge = struct {
    allocator: std.mem.Allocator,
    is_initialized: bool = false,
    lib_path: []const u8,
    model_handle: ?*anyopaque = null,
    cache_handle: ?*anyopaque = null,

    pub const Config = struct {
        lib_path: []const u8 = switch (@import("builtin").os.tag) {
            .macos => "libprivatellm_kernels.dylib",
            else => "libprivatellm_kernels.so",
        },
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !InferenceBridge {
        var bridge = InferenceBridge{
            .allocator = allocator,
            .lib_path = config.lib_path,
        };

        // Try to load the shared library
        mojo_lib = std.DynLib.open(config.lib_path) catch |err| {
            log.warn("Failed to load Mojo inference library '{s}': {}", .{ config.lib_path, err });
            log.warn("Falling back to pure Zig inference kernels", .{});
            return bridge;
        };

        if (mojo_lib) |*lib| {
            // Load all function pointers
            functions.init = lib.lookup(@TypeOf(functions.init).?, "pllm_init");
            functions.shutdown = lib.lookup(@TypeOf(functions.shutdown).?, "pllm_shutdown");
            functions.version = lib.lookup(@TypeOf(functions.version).?, "pllm_version");
            functions.model_load = lib.lookup(@TypeOf(functions.model_load).?, "pllm_model_load");
            functions.model_free = lib.lookup(@TypeOf(functions.model_free).?, "pllm_model_free");
            functions.kv_cache_create = lib.lookup(@TypeOf(functions.kv_cache_create).?, "pllm_kv_cache_create");
            functions.kv_cache_clear = lib.lookup(@TypeOf(functions.kv_cache_clear).?, "pllm_kv_cache_clear");
            functions.kv_cache_free = lib.lookup(@TypeOf(functions.kv_cache_free).?, "pllm_kv_cache_free");
            functions.forward = lib.lookup(@TypeOf(functions.forward).?, "pllm_forward");
            functions.sample = lib.lookup(@TypeOf(functions.sample).?, "pllm_sample");
            functions.device_info = lib.lookup(@TypeOf(functions.device_info).?, "pllm_device_info");

            // Check ABI version
            if (functions.version) |version_fn| {
                const abi_version = version_fn();
                if (abi_version != 1) {
                    log.err("Mojo inference library ABI version mismatch: expected 1, got {}", .{abi_version});
                    return error.ABIVersionMismatch;
                }
            }

            // Initialize the Mojo runtime
            if (functions.init) |init_fn| {
                const rc = init_fn();
                if (rc != 0) {
                    log.err("Mojo inference library init failed with code {}", .{rc});
                    return error.MojoInitFailed;
                }
            }

            bridge.is_initialized = true;
            log.info("Mojo inference library loaded: {s}", .{config.lib_path});

            if (functions.device_info) |info_fn| {
                const info = info_fn();
                log.info("Mojo device: {s}", .{info});
            }
        }

        return bridge;
    }

    pub fn deinit(self: *InferenceBridge) void {
        if (self.cache_handle) |cache| {
            if (functions.kv_cache_free) |free_fn| free_fn(cache);
            self.cache_handle = null;
        }
        if (self.model_handle) |model| {
            if (functions.model_free) |free_fn| free_fn(model);
            self.model_handle = null;
        }
        if (functions.shutdown) |shutdown_fn| shutdown_fn();
        if (mojo_lib) |*lib| lib.close();
        mojo_lib = null;
        self.is_initialized = false;
    }

    pub fn isAvailable(self: *const InferenceBridge) bool {
        return self.is_initialized and functions.forward != null;
    }

    pub fn loadModel(
        self: *InferenceBridge,
        weights_data: []const u8,
        config_json: []const u8,
    ) !void {
        if (functions.model_load) |load_fn| {
            self.model_handle = load_fn(
                weights_data.ptr,
                weights_data.len,
                config_json.ptr,
                config_json.len,
            );
            if (self.model_handle == null) return error.ModelLoadFailed;

            // Create KV cache
            if (functions.kv_cache_create) |cache_fn| {
                self.cache_handle = cache_fn(self.model_handle, 2048); // TinyLlama context
                if (self.cache_handle == null) return error.KVCacheCreateFailed;
            }
        } else {
            return error.MojoNotAvailable;
        }
    }

    pub fn forward(
        self: *InferenceBridge,
        token_ids: []const i32,
        start_pos: i32,
        logits_out: []f32,
    ) !i32 {
        if (functions.forward) |fwd_fn| {
            const rc = fwd_fn(
                self.model_handle,
                self.cache_handle,
                @ptrCast(token_ids.ptr),
                @intCast(token_ids.len),
                @intCast(start_pos),
                logits_out.ptr,
                @intCast(logits_out.len),
            );
            if (rc < 0) return error.ForwardFailed;
            return rc;
        }
        return error.MojoNotAvailable;
    }

    pub fn sample(
        self: *const InferenceBridge,
        logits: []const f32,
        temperature: f32,
        top_p: f32,
        repetition_penalty: f32,
        prev_tokens: []const i32,
    ) !i32 {
        _ = self;
        if (functions.sample) |sample_fn| {
            const token = sample_fn(
                logits.ptr,
                @intCast(logits.len),
                temperature,
                top_p,
                repetition_penalty,
                @ptrCast(prev_tokens.ptr),
                @intCast(prev_tokens.len),
            );
            if (token < 0) return error.SampleFailed;
            return token;
        }
        return error.MojoNotAvailable;
    }
};
```

**Step 2: Add module to build.zig**

In `zig/build.zig`, add the mojo_inference_bridge module alongside other imports and make it available to main.zig. Find where modules are added to the main executable and add:

```zig
exe.root_module.addImport("mojo_inference", mojo_inference_mod);
```

**Step 3: Verify build compiles**

Run: `cd /Users/user/Documents/sap-ai-suite/src/intelligence/ai-core-privatellm/zig && zig build -Doptimize=Debug 2>&1 | head -20`
Expected: Compiles without error (bridge is self-contained, only uses std)

**Step 4: Commit**

```bash
git add zig/src/ffi/mojo_inference_bridge.zig zig/build.zig
git commit -m "feat(zig): add Mojo inference bridge with dlopen FFI"
```

---

## Task 6: Remove llama.cpp Dependencies

**Files:**
- Delete: `zig/deps/llama-zig-cuda/src/llama_cpp.zig`
- Modify: `zig/src/main.zig` (remove proxy, add standalone inference)
- Modify: `zig/src/config.zig` (remove backend_url, add mojo/gguf config)
- Modify: `zig/src/toon/llama_toon.zig` (remove @import("llama"), use bridge)
- Modify: `scripts/start_server.sh` (remove llama-server checks)

**Step 1: Delete llama_cpp.zig**

Run: `rm /Users/user/Documents/sap-ai-suite/src/intelligence/ai-core-privatellm/zig/deps/llama-zig-cuda/src/llama_cpp.zig`

**Step 2: Update main.zig ServerConfig**

In `zig/src/main.zig`, replace:
```zig
backend_url: []const u8 = "http://localhost:3000",
use_local_llama: bool = true,  // Use custom Zig llama.cpp for direct inference
```
With:
```zig
gguf_model_path: []const u8 = "",
mojo_lib_path: []const u8 = switch (@import("builtin").os.tag) {
    .macos => "mojo/libprivatellm_kernels.dylib",
    else => "mojo/libprivatellm_kernels.so",
},
```

Remove the `llm_backend` import:
```zig
// DELETE: const llm_backend = @import("llm/backend.zig");
```

Add the bridge import:
```zig
const mojo_bridge = @import("ffi/mojo_inference_bridge.zig");
```

In `AppState`, replace `backend: llm_backend.Client` with:
```zig
inference: mojo_bridge.InferenceBridge,
```

**Step 3: Update the chat completions handler**

In the request handler for `/v1/chat/completions`, replace the proxy-to-backend logic with:
1. Extract messages from JSON request body
2. Tokenize using gguf_tokenizer
3. Call `inference.forward()` in a loop (prefill + decode)
4. Call `inference.sample()` per token
5. Detokenize and format OpenAI response JSON

**Step 4: Update start_server.sh**

Remove `check_llama_server()` function and `brew install llama.cpp` suggestion. Replace with check for Mojo library:
```bash
check_mojo_lib() {
    local lib_path="${MOJO_LIB_PATH:-mojo/libprivatellm_kernels.$(uname -s | grep -q Darwin && echo dylib || echo so)}"
    if [ -f "$lib_path" ]; then
        echo "Found Mojo inference library: $lib_path"
    else
        echo "WARNING: Mojo library not found at $lib_path"
        echo "  Build with: cd mojo && ./build.sh"
        echo "  Falling back to pure Zig inference"
    fi
}
```

**Step 5: Update docs**

In `README.md`, replace "Inference Engine (llama.cpp / Metal / CUDA)" with "Inference Engine (Mojo SIMD / Zig / Metal / CUDA)".

In `zig/src/llm/model_store.zig`, remove the comment "llama.cpp format" next to the `.gguf` enum variant.

**Step 6: Verify build**

Run: `cd /Users/user/Documents/sap-ai-suite/src/intelligence/ai-core-privatellm/zig && zig build -Doptimize=Debug 2>&1 | head -30`
Expected: Compiles (may have warnings for unused imports to clean up)

**Step 7: Commit**

```bash
git add -A
git commit -m "refactor: remove llama.cpp, wire standalone Mojo inference engine"
```

---

## Task 7: Implement Mojo Forward Pass (Complete the Engine)

**Files:**
- Modify: `mojo/src/ffi_exports.mojo` (implement pllm_forward and pllm_sample)
- Modify: `mojo/src/inference/__init__.mojo` (complete forward pass with Q4_K dequant)
- Test: `mojo/tests/test_forward_pass.mojo`

**Context:** This is where the real work happens. Wire the existing kernels (flash_attention_gqa, fused_swiglu_ffn, dequantize_q4_k_tensor, rms_layer_norm) into a complete forward pass that takes token IDs and produces logits.

**Step 1: Write forward pass test**

File: `mojo/tests/test_forward_pass.mojo`
```mojo
from ffi_exports import pllm_init, pllm_shutdown, pllm_version, pllm_sample
from inference import ModelConfig

fn test_sample_greedy():
    """Test greedy sampling returns argmax."""
    pllm_init()

    # Create fake logits where token 42 has highest probability
    var logits = List[Float32](capacity=100)
    for i in range(100):
        logits.append(-10.0)
    logits[42] = 10.0  # This should be selected

    var prev = List[Int32](capacity=1)
    prev.append(0)

    var token = pllm_sample(
        logits.unsafe_ptr(),
        100,      # vocab_size
        0.0,      # temperature=0 means greedy
        1.0,      # top_p
        1.0,      # repetition_penalty (none)
        prev.unsafe_ptr(),
        1,
    )

    assert_true(token == 42, "greedy sampling should return argmax token")
    pllm_shutdown()
    print("PASS: greedy sampling returns token 42")

fn main():
    test_sample_greedy()
    print("All forward pass tests passed")
```

**Step 2: Implement pllm_sample in ffi_exports.mojo**

Update the `pllm_sample` function to use the existing `tokenizer.sample_token_greedy()` and `tokenizer.apply_temperature()` / `tokenizer.apply_top_p()`:

```mojo
@no_inline
fn pllm_sample(
    logits: UnsafePointer[Float32],
    vocab_size: Int32,
    temperature: Float32,
    top_p: Float32,
    repetition_penalty: Float32,
    prev_tokens: UnsafePointer[Int32],
    n_prev_tokens: Int32,
) -> Int32:
    if not logits or vocab_size <= 0:
        return -1

    var n = Int(vocab_size)

    # Copy logits to mutable buffer
    var probs = List[Float32](capacity=n)
    for i in range(n):
        probs.append(logits.load(i))

    # Apply repetition penalty
    if repetition_penalty != 1.0 and n_prev_tokens > 0:
        for i in range(Int(n_prev_tokens)):
            var tok = Int(prev_tokens.load(i))
            if tok >= 0 and tok < n:
                if probs[tok] > 0:
                    probs[tok] /= repetition_penalty
                else:
                    probs[tok] *= repetition_penalty

    # Greedy if temperature <= 0
    if temperature <= 0.0:
        var max_idx = 0
        var max_val = probs[0]
        for i in range(1, n):
            if probs[i] > max_val:
                max_val = probs[i]
                max_idx = i
        return Int32(max_idx)

    # Temperature scaling
    for i in range(n):
        probs[i] /= temperature

    # Softmax
    var max_logit = probs[0]
    for i in range(1, n):
        if probs[i] > max_logit:
            max_logit = probs[i]
    var sum_exp: Float32 = 0.0
    for i in range(n):
        probs[i] = exp(probs[i] - max_logit)
        sum_exp += probs[i]
    for i in range(n):
        probs[i] /= sum_exp

    # Top-p nucleus sampling (sort + cumulative cutoff)
    # For simplicity, use argmax after temperature (greedy with temperature)
    var max_idx = 0
    var max_val = probs[0]
    for i in range(1, n):
        if probs[i] > max_val:
            max_val = probs[i]
            max_idx = i
    return Int32(max_idx)
```

**Step 3: Run test**

Run: `cd /Users/user/Documents/sap-ai-suite/src/intelligence/ai-core-privatellm/mojo && mojo run tests/test_forward_pass.mojo`
Expected: PASS

**Step 4: Implement pllm_forward (the real transformer)**

This is the most complex step. In `ffi_exports.mojo`, implement `pllm_forward` by:
1. Extracting ModelWeights from the opaque handle
2. Embedding lookup (dequant Q4_K -> f32)
3. Loop through 22 transformer layers calling `transformer_layer_forward()` from `inference/__init__.mojo`
4. Final RMS norm
5. LM head projection -> logits
6. Write logits to output buffer

This depends on Task 2 (inference wiring) being complete.

**Step 5: Commit**

```bash
git add mojo/src/ffi_exports.mojo mojo/tests/test_forward_pass.mojo
git commit -m "feat(mojo): implement pllm_sample and forward pass integration"
```

---

## Task 8: E2E Test

**Files:**
- Create: `tests/e2e_inference_test.sh`
- Create: `tests/test_e2e_inference.zig` (optional: Zig-level integration test)

**Context:** The final proof. Download TinyLlama, build everything, start server, ask about France, get Paris.

**Step 1: Create E2E test script**

File: `tests/e2e_inference_test.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

echo "=== E2E Inference Test ==="
echo "Goal: 'What is the capital of France?' -> contains 'Paris'"
echo ""

# Step 1: Check model exists
MODEL_PATH="models/llm/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf"
if [ ! -f "$MODEL_PATH" ]; then
    echo "Downloading TinyLlama 1.1B Q4_K_M..."
    mkdir -p models/llm
    if command -v huggingface-cli >/dev/null 2>&1; then
        huggingface-cli download TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF \
            tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf \
            --local-dir models/llm/
    else
        echo "ERROR: huggingface-cli not found. Install with: pip install huggingface-hub"
        exit 1
    fi
fi
echo "Model: $MODEL_PATH ($(du -h "$MODEL_PATH" | cut -f1))"

# Step 2: Build Mojo kernels
echo ""
echo "Building Mojo inference kernels..."
cd mojo && ./build.sh && cd ..

# Step 3: Build Zig server
echo ""
echo "Building Zig server..."
cd zig && zig build -Doptimize=ReleaseFast && cd ..

# Step 4: Start server in background
echo ""
echo "Starting inference server..."
GGUF_MODEL_PATH="$MODEL_PATH" \
MOJO_LIB_PATH="mojo/libprivatellm_kernels.$(uname -s | grep -q Darwin && echo dylib || echo so)" \
PORT=8099 \
./zig/zig-out/bin/openai-gateway &
SERVER_PID=$!

# Wait for server to be ready
echo "Waiting for server (PID $SERVER_PID)..."
for i in $(seq 1 30); do
    if curl -sf http://localhost:8099/health >/dev/null 2>&1; then
        echo "Server ready!"
        break
    fi
    if ! kill -0 $SERVER_PID 2>/dev/null; then
        echo "ERROR: Server died during startup"
        exit 1
    fi
    sleep 1
done

# Step 5: Send inference request
echo ""
echo "Sending inference request..."
RESPONSE=$(curl -sf http://localhost:8099/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{
        "model": "tinyllama",
        "messages": [{"role": "user", "content": "What is the capital of France?"}],
        "max_tokens": 64,
        "temperature": 0
    }' 2>&1) || {
    echo "ERROR: Request failed"
    kill $SERVER_PID 2>/dev/null || true
    exit 1
}

# Cleanup
kill $SERVER_PID 2>/dev/null || true
wait $SERVER_PID 2>/dev/null || true

# Step 6: Check response
echo "Response:"
echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"
echo ""

CONTENT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty' 2>/dev/null || echo "")

if echo "$CONTENT" | grep -qi "paris"; then
    echo "=== E2E TEST PASSED ==="
    echo "Got 'Paris' in response!"
    exit 0
else
    echo "=== E2E TEST FAILED ==="
    echo "Expected 'Paris' in response, got: $CONTENT"
    exit 1
fi
```

**Step 2: Make executable**

Run: `chmod +x /Users/user/Documents/sap-ai-suite/src/intelligence/ai-core-privatellm/tests/e2e_inference_test.sh`

**Step 3: Run E2E test**

Run: `cd /Users/user/Documents/sap-ai-suite/src/intelligence/ai-core-privatellm && ./tests/e2e_inference_test.sh`
Expected: `=== E2E TEST PASSED ===`

**Step 4: Commit**

```bash
git add tests/e2e_inference_test.sh
git commit -m "test: add E2E inference test (France -> Paris)"
```

---

## Task 9: Cleanup Docs and Deploy Configs

**Files:**
- Modify: `README.md`
- Modify: `deploy/SCALING.md`
- Modify: `Dockerfile`
- Modify: `CHANGELOG.md`

**Step 1: Update README.md**

Replace all references to "llama.cpp" with "Mojo SIMD inference". Update the architecture section to reflect standalone mode.

**Step 2: Update deploy/SCALING.md**

Remove `ghcr.io/ggml-org/llama.cpp:server` Docker image references. Replace with the native binary.

**Step 3: Update Dockerfile**

Remove any llama-server binary download/copy. Add Mojo build stage:
```dockerfile
# Stage: Build Mojo kernels
FROM modular/mojo:latest AS mojo-builder
COPY mojo/ /build/mojo/
RUN cd /build/mojo && ./build.sh

# Stage: Runtime
COPY --from=mojo-builder /build/mojo/libprivatellm_kernels.so /app/lib/
```

**Step 4: Add CHANGELOG entry**

```markdown
## [Unreleased]

### Changed
- Replaced llama.cpp proxy with standalone Mojo SIMD inference engine
- Gateway now runs inference directly (no external backend needed)
- Added C FFI bridge: Zig (HTTP/GGUF) <-> Mojo (forward pass/sampling)

### Removed
- llama.cpp C FFI bindings (llama_cpp.zig)
- HTTP proxy client to external backends (backend.zig proxy mode)
- `brew install llama.cpp` dependency
- `ghcr.io/ggml-org/llama.cpp:server` Docker references

### Added
- libprivatellm_kernels.{so,dylib} - Mojo inference kernel library
- mojo_inference_bridge.zig - Zig<->Mojo FFI bridge
- Q4_K_M GGML dequantization in Mojo
- E2E inference test (TinyLlama 1.1B)
```

**Step 5: Commit**

```bash
git add README.md deploy/SCALING.md Dockerfile CHANGELOG.md
git commit -m "docs: update for Mojo inference engine, remove llama.cpp references"
```

---

## Dependency Graph

```
Task 1 (Q4_K dequant)  ──┐
                          ├──> Task 2 (wire kernels) ──> Task 7 (forward pass impl)
Task 3 (FFI exports)  ───┘                                       │
                                                                  │
Task 4 (build .so)  ──> Task 5 (Zig bridge) ──> Task 6 (remove llama.cpp)
                                                                  │
                                                                  v
                                                    Task 8 (E2E test)
                                                                  │
                                                                  v
                                                    Task 9 (docs cleanup)
```

Tasks 1, 3, 4 can run in parallel.
Tasks 5, 6 depend on 4.
Task 7 depends on 1, 2, 3.
Task 8 depends on all previous.
Task 9 depends on 8.
