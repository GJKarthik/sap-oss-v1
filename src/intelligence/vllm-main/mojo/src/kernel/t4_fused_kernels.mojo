"""
Fused Activation Kernels for T4 GPU

Implements fused operations to minimize memory bandwidth:
- RMSNorm (LayerNorm without mean subtraction)
- SiLU (Swish activation)
- RoPE (Rotary Position Embeddings)
- Residual connections

Optimized for Nemotron-Nano-8B architecture.
"""

from memory import LegacyUnsafePointer
comptime UnsafePointer = LegacyUnsafePointer[mut=True, ...]
from memory.unsafe_pointer import alloc
from algorithm.functional import vectorize
from math import sqrt, exp, cos, sin
from sys.info import simd_width_of

# SIMD width for vectorized operations
comptime SIMD_WIDTH = simd_width_of[DType.float32]()

# RoPE theta (Llama-style)
comptime ROPE_THETA: Float32 = 10000.0


# =============================================================================
# RMSNorm (Root Mean Square Layer Normalization)
# =============================================================================

fn rmsnorm_fp16[o_out: MutOrigin, o_in: MutOrigin, o_w: MutOrigin](
    output: UnsafePointer[Float16, origin=o_out],
    input: UnsafePointer[Float16, origin=o_in],
    weight: UnsafePointer[Float16, origin=o_w],
    size: Int,
    eps: Float32 = 1e-6
):
    """
    RMSNorm: output = input / sqrt(mean(input^2) + eps) * weight
    
    Used in Nemotron/Llama architectures instead of LayerNorm.
    No mean subtraction, making it faster.
    """
    # Compute sum of squares
    var sum_sq: Float32 = 0.0
    for i in range(size):
        var val = Float32(input[i])
        sum_sq += val * val
    
    # Compute RMS
    var rms = sqrt(sum_sq / Float32(size) + eps)
    var inv_rms = 1.0 / rms
    
    # Normalize and scale
    for i in range(size):
        var val = Float32(input[i]) * inv_rms
        output[i] = Float16(val * Float32(weight[i]))


fn rmsnorm_fp16_inplace[o_io: MutOrigin, o_w: MutOrigin](
    data: UnsafePointer[Float16, origin=o_io],
    weight: UnsafePointer[Float16, origin=o_w],
    size: Int,
    eps: Float32 = 1e-6
):
    """
    In-place RMSNorm to save memory bandwidth.
    """
    # Compute sum of squares
    var sum_sq: Float32 = 0.0
    for i in range(size):
        var val = Float32(data[i])
        sum_sq += val * val
    
    var rms = sqrt(sum_sq / Float32(size) + eps)
    var inv_rms = 1.0 / rms
    
    for i in range(size):
        var val = Float32(data[i]) * inv_rms
        data[i] = Float16(val * Float32(weight[i]))


fn rmsnorm_fp16_fused_residual[
    o_out: MutOrigin,
    o_in: MutOrigin,
    o_res: MutOrigin,
    o_w: MutOrigin
](
    output: UnsafePointer[Float16, origin=o_out],
    input: UnsafePointer[Float16, origin=o_in],
    residual: UnsafePointer[Float16, origin=o_res],
    weight: UnsafePointer[Float16, origin=o_w],
    size: Int,
    eps: Float32 = 1e-6
):
    """
    Fused RMSNorm with residual addition.
    
    output = RMSNorm(input + residual) * weight
    
    Saves one memory pass by computing residual in-line.
    """
    # First pass: add residual and compute sum of squares
    var sum_sq: Float32 = 0.0
    var temp = alloc[Float32](size)
    
    for i in range(size):
        var val = Float32(input[i]) + Float32(residual[i])
        temp[i] = val
        sum_sq += val * val
    
    var rms = sqrt(sum_sq / Float32(size) + eps)
    var inv_rms = 1.0 / rms
    
    # Second pass: normalize and scale
    for i in range(size):
        output[i] = Float16(temp[i] * inv_rms * Float32(weight[i]))
    
    temp.free()


# =============================================================================
# SiLU (Sigmoid Linear Unit / Swish)
# =============================================================================

fn silu_fp16[o_out: MutOrigin, o_in: MutOrigin](
    output: UnsafePointer[Float16, origin=o_out],
    input: UnsafePointer[Float16, origin=o_in],
    size: Int
):
    """
    SiLU activation: output = input * sigmoid(input)
    
    Also known as Swish activation.
    Used in SwiGLU FFN (Nemotron/Llama).
    """
    for i in range(size):
        var x = Float32(input[i])
        var sigmoid_x = 1.0 / (1.0 + exp(-x))
        output[i] = Float16(x * sigmoid_x)


fn silu_fp16_inplace[o_io: MutOrigin](
    data: UnsafePointer[Float16, origin=o_io],
    size: Int
):
    """In-place SiLU to save memory."""
    for i in range(size):
        var x = Float32(data[i])
        var sigmoid_x = 1.0 / (1.0 + exp(-x))
        data[i] = Float16(x * sigmoid_x)


fn silu_mul_fp16[o_out: MutOrigin, o_gate: MutOrigin, o_up: MutOrigin](
    output: UnsafePointer[Float16, origin=o_out],
    gate: UnsafePointer[Float16, origin=o_gate],
    up: UnsafePointer[Float16, origin=o_up],
    size: Int
):
    """
    Fused SiLU and element-wise multiply for SwiGLU.
    
    output = SiLU(gate) * up
    
    This is the core of SwiGLU FFN:
    - gate = x @ W_gate
    - up = x @ W_up
    - output = SiLU(gate) * up
    """
    for i in range(size):
        var g = Float32(gate[i])
        var sigmoid_g = 1.0 / (1.0 + exp(-g))
        var silu_g = g * sigmoid_g
        output[i] = Float16(silu_g * Float32(up[i]))


# =============================================================================
# GELU (Gaussian Error Linear Unit)
# =============================================================================

fn gelu_fp16[o_out: MutOrigin, o_in: MutOrigin](
    output: UnsafePointer[Float16, origin=o_out],
    input: UnsafePointer[Float16, origin=o_in],
    size: Int
):
    """
    GELU activation: output = x * Phi(x)
    
    Approximation: 0.5 * x * (1 + tanh(sqrt(2/pi) * (x + 0.044715 * x^3)))
    """
    comptime SQRT_2_PI: Float32 = 0.7978845608028654
    comptime COEFF: Float32 = 0.044715
    
    for i in range(size):
        var x = Float32(input[i])
        var x3 = x * x * x
        var inner = SQRT_2_PI * (x + COEFF * x3)
        # tanh approximation
        var exp_2x = exp(2.0 * inner)
        var tanh_val = (exp_2x - 1.0) / (exp_2x + 1.0)
        output[i] = Float16(0.5 * x * (1.0 + tanh_val))


# =============================================================================
# RoPE (Rotary Position Embeddings)
# =============================================================================

fn apply_rope_fp16[o_io: MutOrigin](
    data: UnsafePointer[Float16, origin=o_io],
    head_dim: Int,
    position: Int,
    theta: Float32 = ROPE_THETA
):
    """
    Apply Rotary Position Embeddings to a single head.
    
    For each pair (x[2i], x[2i+1]):
    - x'[2i]   = x[2i]   * cos(θ) - x[2i+1] * sin(θ)
    - x'[2i+1] = x[2i+1] * cos(θ) + x[2i]   * sin(θ)
    
    Where θ_i = position / (theta ^ (2i / head_dim))
    """
    var half_dim = head_dim // 2
    
    for i in range(half_dim):
        # Compute rotation angle
        var freq = 1.0 / (theta ** (Float32(2 * i) / Float32(head_dim)))
        var angle = Float32(position) * freq
        var cos_angle = cos(angle)
        var sin_angle = sin(angle)
        
        # Apply rotation
        var x0 = Float32(data[2 * i])
        var x1 = Float32(data[2 * i + 1])
        data[2 * i] = Float16(x0 * cos_angle - x1 * sin_angle)
        data[2 * i + 1] = Float16(x1 * cos_angle + x0 * sin_angle)


fn apply_rope_batch_fp16[o_q: MutOrigin, o_k: MutOrigin](
    Q: UnsafePointer[Float16, origin=o_q],
    K: UnsafePointer[Float16, origin=o_k],
    num_heads: Int,
    num_kv_heads: Int,
    head_dim: Int,
    seq_len: Int,
    start_pos: Int,
    theta: Float32 = ROPE_THETA
):
    """
    Apply RoPE to all Q and K heads for a batch of positions.
    
    Layout:
    - Q: [seq_len, num_heads, head_dim]
    - K: [seq_len, num_kv_heads, head_dim]
    """
    for pos in range(seq_len):
        var abs_pos = start_pos + pos
        
        # Apply to Q heads
        for h in range(num_heads):
            var q_head = Q + (pos * num_heads + h) * head_dim
            apply_rope_fp16(q_head, head_dim, abs_pos, theta)
        
        # Apply to K heads (fewer with GQA)
        for h in range(num_kv_heads):
            var k_head = K + (pos * num_kv_heads + h) * head_dim
            apply_rope_fp16(k_head, head_dim, abs_pos, theta)


# =============================================================================
# Precomputed RoPE Cache (For Efficiency)
# =============================================================================

struct RoPECache:
    """
    Precomputed cosine and sine values for RoPE.
    
    Caches cos(m*θ_i) and sin(m*θ_i) for:
    - m ∈ [0, max_seq_len)
    - i ∈ [0, head_dim/2)
    """
    var cos_cache: UnsafePointer[Float32]
    var sin_cache: UnsafePointer[Float32]
    var max_seq_len: Int
    var half_head_dim: Int
    
    fn __init__(
        out self,
        max_seq_len: Int,
        head_dim: Int,
        theta: Float32 = ROPE_THETA
    ):
        self.max_seq_len = max_seq_len
        self.half_head_dim = head_dim // 2
        
        var cache_size = max_seq_len * self.half_head_dim
        self.cos_cache = alloc[Float32](cache_size)
        self.sin_cache = alloc[Float32](cache_size)
        
        # Precompute
        for pos in range(max_seq_len):
            for i in range(self.half_head_dim):
                var freq = 1.0 / (theta ** (Float32(2 * i) / Float32(head_dim)))
                var angle = Float32(pos) * freq
                self.cos_cache[pos * self.half_head_dim + i] = cos(angle)
                self.sin_cache[pos * self.half_head_dim + i] = sin(angle)
    
    fn apply[o_io: MutOrigin](
        self,
        data: UnsafePointer[Float16, origin=o_io],
        position: Int
    ):
        """Apply precomputed RoPE to a single head."""
        if position >= self.max_seq_len:
            return  # Out of range
        
        for i in range(self.half_head_dim):
            var cos_val = self.cos_cache[position * self.half_head_dim + i]
            var sin_val = self.sin_cache[position * self.half_head_dim + i]
            
            var x0 = Float32(data[2 * i])
            var x1 = Float32(data[2 * i + 1])
            data[2 * i] = Float16(x0 * cos_val - x1 * sin_val)
            data[2 * i + 1] = Float16(x1 * cos_val + x0 * sin_val)
    
    fn deinit(mut self):
        self.cos_cache.free()
        self.sin_cache.free()


# =============================================================================
# Fused Transformer Layer Operations
# =============================================================================

fn fused_attention_prenorm[
    o_out: MutOrigin,
    o_hidden: MutOrigin,
    o_residual: MutOrigin,
    o_norm_w: MutOrigin
](
    output: UnsafePointer[Float16, origin=o_out],
    hidden: UnsafePointer[Float16, origin=o_hidden],
    residual: UnsafePointer[Float16, origin=o_residual],
    norm_weight: UnsafePointer[Float16, origin=o_norm_w],
    hidden_size: Int,
    eps: Float32 = 1e-6
):
    """
    Fused pre-attention normalization with residual.
    
    output = RMSNorm(hidden + residual, norm_weight)
    
    This is the input to QKV projection.
    """
    rmsnorm_fp16_fused_residual(
        output, hidden, residual, norm_weight,
        hidden_size, eps
    )


fn fused_ffn_swiglu[
    o_out: MutOrigin,
    o_gate: MutOrigin,
    o_up: MutOrigin,
    o_down_in: MutOrigin
](
    output: UnsafePointer[Float16, origin=o_out],
    gate: UnsafePointer[Float16, origin=o_gate],
    up: UnsafePointer[Float16, origin=o_up],
    ff_dim: Int
):
    """
    Fused SwiGLU activation: output = SiLU(gate) * up
    
    This is part of the FFN block:
    1. gate = x @ W_gate
    2. up = x @ W_up
    3. hidden = SiLU(gate) * up  ← This function
    4. output = hidden @ W_down
    """
    silu_mul_fp16(output, gate, up, ff_dim)


fn fused_residual_add[o_io: MutOrigin, o_res: MutOrigin](
    data: UnsafePointer[Float16, origin=o_io],
    residual: UnsafePointer[Float16, origin=o_res],
    size: Int
):
    """
    Fused residual addition: data = data + residual
    """
    for i in range(size):
        data[i] = Float16(Float32(data[i]) + Float32(residual[i]))


# =============================================================================
# INT8 Activation Quantization (For Mixed-Precision)
# =============================================================================

fn quantize_activation_int8[o_out: MutOrigin, o_in: MutOrigin](
    output: UnsafePointer[Int8, origin=o_out],
    input: UnsafePointer[Float16, origin=o_in],
    size: Int
) -> Float32:
    """
    Dynamic INT8 quantization for activations.
    
    Per-tensor symmetric: scale = max(|input|) / 127
    Returns the scale for dequantization.
    """
    # Find max absolute value
    var max_abs: Float32 = 0.0
    for i in range(size):
        var val = Float32(input[i])
        if val < 0:
            val = -val
        if val > max_abs:
            max_abs = val
    
    # Compute scale
    var scale = max_abs / 127.0 if max_abs > 0 else 1.0
    var inv_scale = 1.0 / scale
    
    # Quantize
    for i in range(size):
        var val = Float32(input[i]) * inv_scale
        if val > 127.0:
            val = 127.0
        elif val < -127.0:
            val = -127.0
        output[i] = Int8(val)
    
    return scale


fn dequantize_activation_fp16[o_out: MutOrigin, o_in: MutOrigin](
    output: UnsafePointer[Float16, origin=o_out],
    input: UnsafePointer[Int32, origin=o_in],  # INT32 accumulator output
    scale: Float32,
    size: Int
):
    """
    Dequantize INT32 accumulator to FP16.
    """
    for i in range(size):
        output[i] = Float16(Float32(input[i]) * scale)


# =============================================================================
# Performance Estimation
# =============================================================================

fn estimate_rmsnorm_bandwidth_gb(hidden_size: Int, batch_size: Int) -> Float32:
    """Estimate memory bandwidth for RMSNorm (memory-bound)."""
    # Read input + weight, write output (all FP16)
    var bytes = batch_size * hidden_size * 2 * 3  # 3 = in + weight + out
    return Float32(bytes) / 1e9


fn estimate_swiglu_bandwidth_gb(ff_dim: Int, batch_size: Int) -> Float32:
    """Estimate memory bandwidth for SwiGLU."""
    # Read gate + up, write output (all FP16)
    var bytes = batch_size * ff_dim * 2 * 3
    return Float32(bytes) / 1e9
