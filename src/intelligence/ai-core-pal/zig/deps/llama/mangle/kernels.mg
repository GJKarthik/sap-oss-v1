# Compute Kernels Specification
# Declarative definition of SIMD-optimized compute kernels

# ============================================================================
# Kernel registry: kernel(name, category, description)
# ============================================================================

# Basic element-wise operations
kernel("vec_add", "elementwise", "Element-wise vector addition").
kernel("vec_mul", "elementwise", "Element-wise vector multiplication").
kernel("vec_scale", "elementwise", "Scale vector by constant").
kernel("vec_fma", "elementwise", "Fused multiply-add: a * b + c").
kernel("vec_silu", "activation", "SiLU/Swish activation: x * sigmoid(x)").
kernel("vec_gelu", "activation", "GELU activation").
kernel("vec_relu", "activation", "ReLU activation: max(0, x)").

# Reduction operations
kernel("vec_sum", "reduction", "Sum of vector elements").
kernel("vec_max", "reduction", "Maximum of vector elements").
kernel("vec_dot", "reduction", "Dot product of two vectors").
kernel("vec_norm", "reduction", "L2 norm of vector").

# Matrix operations
kernel("matmul", "matrix", "Matrix multiplication: C = A @ B").
kernel("matvec", "matrix", "Matrix-vector multiplication: y = A @ x").
kernel("matmul_q4k", "matrix", "Quantized Q4_K matmul").
kernel("matmul_q8k", "matrix", "Quantized Q8_K matmul").

# Normalization
kernel("rms_norm", "norm", "RMS normalization (LLaMA style)").
kernel("layer_norm", "norm", "Layer normalization (with bias)").
kernel("softmax", "norm", "Softmax along last dimension").

# Attention
kernel("rope", "attention", "Rotary position embedding").
kernel("flash_attn", "attention", "Flash attention (tiled)").
kernel("kv_cache_update", "attention", "Update KV cache").
kernel("causal_mask", "attention", "Apply causal attention mask").

# Quantization
kernel("dequant_q4k", "quant", "Dequantize Q4_K to F32").
kernel("dequant_q8k", "quant", "Dequantize Q8_K to F32").
kernel("quant_q8_0", "quant", "Quantize F32 to Q8_0").

# ============================================================================
# Kernel properties: kernel_prop(kernel, property, value)
# ============================================================================

# SiLU kernel
kernel_prop("vec_silu", "inputs", 1).
kernel_prop("vec_silu", "outputs", 1).
kernel_prop("vec_silu", "in_place", true).
kernel_prop("vec_silu", "simd_friendly", true).
kernel_prop("vec_silu", "formula", "x * (1 / (1 + exp(-x)))").

# GELU kernel
kernel_prop("vec_gelu", "inputs", 1).
kernel_prop("vec_gelu", "outputs", 1).
kernel_prop("vec_gelu", "in_place", true).
kernel_prop("vec_gelu", "simd_friendly", true).
kernel_prop("vec_gelu", "formula", "0.5 * x * (1 + tanh(sqrt(2/pi) * (x + 0.044715 * x^3)))").

# RMS norm
kernel_prop("rms_norm", "inputs", 2).  # input, weight
kernel_prop("rms_norm", "outputs", 1).
kernel_prop("rms_norm", "in_place", true).
kernel_prop("rms_norm", "simd_friendly", true).
kernel_prop("rms_norm", "params", ["eps"]).

# Layer norm
kernel_prop("layer_norm", "inputs", 3).  # input, weight, bias
kernel_prop("layer_norm", "outputs", 1).
kernel_prop("layer_norm", "in_place", true).
kernel_prop("layer_norm", "simd_friendly", true).
kernel_prop("layer_norm", "params", ["eps"]).

# Softmax
kernel_prop("softmax", "inputs", 1).
kernel_prop("softmax", "outputs", 1).
kernel_prop("softmax", "in_place", true).
kernel_prop("softmax", "simd_friendly", true).

# Matrix multiplication
kernel_prop("matmul", "inputs", 2).
kernel_prop("matmul", "outputs", 1).
kernel_prop("matmul", "in_place", false).
kernel_prop("matmul", "simd_friendly", true).
kernel_prop("matmul", "tiling_benefit", true).

# RoPE
kernel_prop("rope", "inputs", 3).  # q, k, positions
kernel_prop("rope", "outputs", 2).  # q_rotated, k_rotated
kernel_prop("rope", "in_place", true).
kernel_prop("rope", "simd_friendly", true).
kernel_prop("rope", "params", ["base_freq", "dim"]).

# Flash attention
kernel_prop("flash_attn", "inputs", 4).  # Q, K, V, mask
kernel_prop("flash_attn", "outputs", 1).
kernel_prop("flash_attn", "in_place", false).
kernel_prop("flash_attn", "simd_friendly", true).
kernel_prop("flash_attn", "tiling_benefit", true).
kernel_prop("flash_attn", "params", ["head_dim", "scale"]).

# ============================================================================
# SIMD configurations per architecture
# ============================================================================

# simd_config(arch, extension, vec_len_f32, vec_len_f16)
simd_config("x86_64", "sse", 4, 8).
simd_config("x86_64", "avx", 8, 16).
simd_config("x86_64", "avx2", 8, 16).
simd_config("x86_64", "avx512", 16, 32).
simd_config("aarch64", "neon", 4, 8).
simd_config("aarch64", "sve", 16, 32).  # Variable, typically 512-bit

# Prefer SIMD extension: prefer_simd(target_arch, extension)
prefer_simd("x86_64", "avx2").
prefer_simd("aarch64", "neon").

# ============================================================================
# Kernel implementations per SIMD
# ============================================================================

# kernel_impl(kernel, simd_ext, impl_strategy)
kernel_impl("vec_add", "scalar", "loop").
kernel_impl("vec_add", "neon", "vector_128").
kernel_impl("vec_add", "avx2", "vector_256").
kernel_impl("vec_add", "avx512", "vector_512").

kernel_impl("vec_silu", "scalar", "loop_exp").
kernel_impl("vec_silu", "neon", "approx_exp_neon").
kernel_impl("vec_silu", "avx2", "approx_exp_avx2").

kernel_impl("matmul", "scalar", "naive_loop").
kernel_impl("matmul", "neon", "tiled_4x4").
kernel_impl("matmul", "avx2", "tiled_8x8").
kernel_impl("matmul", "avx512", "tiled_16x16").

kernel_impl("flash_attn", "scalar", "tiled_naive").
kernel_impl("flash_attn", "neon", "tiled_128").
kernel_impl("flash_attn", "avx2", "tiled_256").

# ============================================================================
# Memory access patterns
# ============================================================================

# access_pattern(kernel, pattern, description)
access_pattern("vec_add", "streaming", "Sequential read/write").
access_pattern("matmul", "tiled", "Block-wise access for cache locality").
access_pattern("flash_attn", "tiled", "Block-wise Q*K^T and softmax").
access_pattern("rms_norm", "row_wise", "Process one row at a time").
access_pattern("rope", "strided", "Interleaved sin/cos access").

# ============================================================================
# Kernel dependencies (for fusion optimization)
# ============================================================================

# can_fuse(kernel1, kernel2) - these kernels can be fused
can_fuse("rms_norm", "matmul").
can_fuse("matmul", "vec_silu").
can_fuse("matmul", "vec_gelu").
can_fuse("vec_silu", "vec_mul").  # SwiGLU = silu(gate) * up
can_fuse("softmax", "matvec").

# fused_kernel(name, kernels, description)
fused_kernel("swiglu", ["vec_silu", "vec_mul"], "SwiGLU activation: silu(gate) * up").
fused_kernel("norm_matmul", ["rms_norm", "matmul"], "Fused normalization and projection").
fused_kernel("attn_softmax_v", ["softmax", "matvec"], "Fused softmax and value projection").

# ============================================================================
# Quantized kernel configurations
# ============================================================================

# quant_kernel(base_kernel, quant_type, block_size)
quant_kernel("matmul", "Q4_K", 256).
quant_kernel("matmul", "Q5_K", 256).
quant_kernel("matmul", "Q6_K", 256).
quant_kernel("matmul", "Q8_K", 256).
quant_kernel("matmul", "Q4_0", 32).
quant_kernel("matmul", "Q8_0", 32).

# quant_dequant_cost(quant_type, ops_per_block)
quant_dequant_cost("Q4_K", 24).  # Scale + min + nibble unpack
quant_dequant_cost("Q8_K", 8).   # Scale only
quant_dequant_cost("Q4_0", 4).   # Simple scale
quant_dequant_cost("Q8_0", 2).   # Simple scale

# ============================================================================
# Performance hints
# ============================================================================

# perf_hint(kernel, hint, value)
perf_hint("matmul", "tile_size_m", 64).
perf_hint("matmul", "tile_size_n", 64).
perf_hint("matmul", "tile_size_k", 32).
perf_hint("flash_attn", "block_size", 128).
perf_hint("rms_norm", "unroll_factor", 4).
perf_hint("vec_silu", "batch_size", 8).