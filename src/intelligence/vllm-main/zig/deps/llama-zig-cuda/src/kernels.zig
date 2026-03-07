//! SIMD-Optimized Compute Kernels
//!
//! This module provides high-performance kernels for LLM inference.
//! Kernel specifications are defined in mangle/kernels.mg
//!
//! Features:
//! - Auto-vectorization using Zig SIMD
//! - Architecture-specific optimizations (NEON, AVX2)
//! - Quantized kernel variants

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// SIMD Configuration (from kernels.mg)
// ============================================================================

/// Suggested vector length for the current architecture
pub const VEC_LEN_F32 = std.simd.suggestVectorLength(f32) orelse 4;
pub const VEC_LEN_F16 = std.simd.suggestVectorLength(f16) orelse 8;

pub const VecF32 = @Vector(VEC_LEN_F32, f32);
pub const VecF16 = @Vector(VEC_LEN_F16, f16);

// ============================================================================
// Element-wise Operations (from kernels.mg: category="elementwise")
// ============================================================================

/// Element-wise vector addition: dst = a + b
/// kernel("vec_add", "elementwise", "Element-wise vector addition")
pub fn vecAdd(dst: []f32, a: []const f32, b: []const f32) void {
    std.debug.assert(dst.len == a.len and a.len == b.len);

    var i: usize = 0;
    while (i + VEC_LEN_F32 <= dst.len) : (i += VEC_LEN_F32) {
        const va: VecF32 = a[i..][0..VEC_LEN_F32].*;
        const vb: VecF32 = b[i..][0..VEC_LEN_F32].*;
        dst[i..][0..VEC_LEN_F32].* = va + vb;
    }

    // Scalar remainder
    while (i < dst.len) : (i += 1) {
        dst[i] = a[i] + b[i];
    }
}

/// In-place addition: a += b
pub fn vecAddInPlace(a: []f32, b: []const f32) void {
    vecAdd(a, a, b);
}

/// Element-wise vector multiplication: dst = a * b
/// kernel("vec_mul", "elementwise", "Element-wise vector multiplication")
pub fn vecMul(dst: []f32, a: []const f32, b: []const f32) void {
    std.debug.assert(dst.len == a.len and a.len == b.len);

    var i: usize = 0;
    while (i + VEC_LEN_F32 <= dst.len) : (i += VEC_LEN_F32) {
        const va: VecF32 = a[i..][0..VEC_LEN_F32].*;
        const vb: VecF32 = b[i..][0..VEC_LEN_F32].*;
        dst[i..][0..VEC_LEN_F32].* = va * vb;
    }

    while (i < dst.len) : (i += 1) {
        dst[i] = a[i] * b[i];
    }
}

/// Scale vector by constant: dst = a * scale
/// kernel("vec_scale", "elementwise", "Scale vector by constant")
pub fn vecScale(dst: []f32, a: []const f32, scale: f32) void {
    std.debug.assert(dst.len == a.len);

    const vs: VecF32 = @splat(scale);

    var i: usize = 0;
    while (i + VEC_LEN_F32 <= dst.len) : (i += VEC_LEN_F32) {
        const va: VecF32 = a[i..][0..VEC_LEN_F32].*;
        dst[i..][0..VEC_LEN_F32].* = va * vs;
    }

    while (i < dst.len) : (i += 1) {
        dst[i] = a[i] * scale;
    }
}

/// Fused multiply-add: dst = a * b + c
/// kernel("vec_fma", "elementwise", "Fused multiply-add: a * b + c")
pub fn vecFma(dst: []f32, a: []const f32, b: []const f32, c: []const f32) void {
    std.debug.assert(dst.len == a.len and a.len == b.len and b.len == c.len);

    var i: usize = 0;
    while (i + VEC_LEN_F32 <= dst.len) : (i += VEC_LEN_F32) {
        const va: VecF32 = a[i..][0..VEC_LEN_F32].*;
        const vb: VecF32 = b[i..][0..VEC_LEN_F32].*;
        const vc: VecF32 = c[i..][0..VEC_LEN_F32].*;
        dst[i..][0..VEC_LEN_F32].* = @mulAdd(VecF32, va, vb, vc);
    }

    while (i < dst.len) : (i += 1) {
        dst[i] = @mulAdd(f32, a[i], b[i], c[i]);
    }
}

// ============================================================================
// Activation Functions (from kernels.mg: category="activation")
// ============================================================================

/// Vectorized approximate exp using range reduction + polynomial.
/// Decomposes x = k*ln2 + r where |r| <= ln2/2, then exp(x) = 2^k * exp(r).
/// exp(r) is approximated with a 4th-order polynomial. Accurate to ~1e-4
/// over the clamped range, which is sufficient for softmax/sigmoid.
fn fastExp(x: VecF32) VecF32 {
    // Clamp input to avoid overflow/underflow in float arithmetic
    const clamped = @min(@max(x, @as(VecF32, @splat(-88.0))), @as(VecF32, @splat(88.0)));

    // Range reduction: k = round(x / ln2), r = x - k*ln2
    const log2e: VecF32 = @splat(1.4426950408889634); // 1/ln2
    const ln2: VecF32 = @splat(0.6931471805599453);
    const k_f = @round(clamped * log2e);
    const r = clamped - k_f * ln2;

    // Polynomial approximation of exp(r) for |r| <= ln2/2
    // exp(r) ≈ 1 + r + r²/2 + r³/6 + r⁴/24
    const one: VecF32 = @splat(1.0);
    const c2: VecF32 = @splat(0.5);
    const c3: VecF32 = @splat(1.0 / 6.0);
    const c4: VecF32 = @splat(1.0 / 24.0);
    const r2 = r * r;
    const exp_r = one + r + c2 * r2 + c3 * (r2 * r) + c4 * (r2 * r2);

    // Reconstruct: exp(x) = 2^k * exp(r)
    // Use integer SIMD: 2^k = bitcast((k_int + 127) << 23)
    const VecI32 = @Vector(VEC_LEN_F32, i32);
    const VecU32 = @Vector(VEC_LEN_F32, u32);
    const k_int: VecI32 = @intFromFloat(k_f);
    const biased: VecI32 = k_int + @as(VecI32, @splat(@as(i32, 127)));
    const shift: VecU32 = @bitCast(biased);
    const shifted: VecU32 = shift << @as(@Vector(VEC_LEN_F32, u5), @splat(23));
    const pow2k: VecF32 = @bitCast(shifted);
    return exp_r * pow2k;
}

/// Vectorized sigmoid: 1 / (1 + exp(-x))
/// Uses fastExp for full SIMD throughput.
fn sigmoid(x: VecF32) VecF32 {
    const one: VecF32 = @splat(1.0);
    const exp_neg_x = fastExp(-x);
    return one / (one + exp_neg_x);
}

/// SiLU/Swish activation: x * sigmoid(x)
/// kernel("vec_silu", "activation", "SiLU/Swish activation")
/// kernel_prop("vec_silu", "formula", "x * (1 / (1 + exp(-x)))")
pub fn vecSilu(dst: []f32, src: []const f32) void {
    std.debug.assert(dst.len == src.len);

    var i: usize = 0;
    while (i + VEC_LEN_F32 <= dst.len) : (i += VEC_LEN_F32) {
        const x: VecF32 = src[i..][0..VEC_LEN_F32].*;
        const sig = sigmoid(x);
        dst[i..][0..VEC_LEN_F32].* = x * sig;
    }

    // Scalar remainder
    while (i < dst.len) : (i += 1) {
        const x = src[i];
        const sig = 1.0 / (1.0 + @exp(-x));
        dst[i] = x * sig;
    }
}

/// In-place SiLU
pub fn vecSiluInPlace(data: []f32) void {
    vecSilu(data, data);
}

/// GELU activation (vectorized)
/// kernel("vec_gelu", "activation", "GELU activation")
/// kernel_prop("vec_gelu", "formula", "0.5 * x * (1 + tanh(sqrt(2/pi) * (x + 0.044715 * x^3)))")
/// Uses the identity tanh(z) = 2*sigmoid(2z) - 1 to reuse vectorized sigmoid.
pub fn vecGelu(dst: []f32, src: []const f32) void {
    std.debug.assert(dst.len == src.len);

    const sqrt_2_pi: VecF32 = @splat(0.7978845608);
    const coef: VecF32 = @splat(0.044715);
    const half: VecF32 = @splat(0.5);
    const one: VecF32 = @splat(1.0);
    const two: VecF32 = @splat(2.0);

    var i: usize = 0;
    while (i + VEC_LEN_F32 <= dst.len) : (i += VEC_LEN_F32) {
        const x: VecF32 = src[i..][0..VEC_LEN_F32].*;
        const x3 = x * x * x;
        const inner = sqrt_2_pi * (x + coef * x3);
        // tanh(z) = 2*sigmoid(2z) - 1
        const tanh_val = two * sigmoid(two * inner) - one;
        dst[i..][0..VEC_LEN_F32].* = half * x * (one + tanh_val);
    }

    // Scalar remainder
    while (i < dst.len) : (i += 1) {
        const x = src[i];
        const inner = 0.7978845608 * (x + 0.044715 * x * x * x);
        dst[i] = 0.5 * x * (1.0 + std.math.tanh(inner));
    }
}

/// In-place GELU
pub fn vecGeluInPlace(data: []f32) void {
    vecGelu(data, data);
}

/// ReLU activation: max(0, x)
/// kernel("vec_relu", "activation", "ReLU activation")
pub fn vecRelu(dst: []f32, src: []const f32) void {
    std.debug.assert(dst.len == src.len);

    const zero: VecF32 = @splat(0.0);

    var i: usize = 0;
    while (i + VEC_LEN_F32 <= dst.len) : (i += VEC_LEN_F32) {
        const x: VecF32 = src[i..][0..VEC_LEN_F32].*;
        dst[i..][0..VEC_LEN_F32].* = @max(x, zero);
    }

    while (i < dst.len) : (i += 1) {
        dst[i] = @max(src[i], 0.0);
    }
}

// ============================================================================
// Reduction Operations (from kernels.mg: category="reduction")
// ============================================================================

/// Sum of vector elements
/// kernel("vec_sum", "reduction", "Sum of vector elements")
pub fn vecSum(data: []const f32) f32 {
    var vec_sum: VecF32 = @splat(0.0);

    var i: usize = 0;
    while (i + VEC_LEN_F32 <= data.len) : (i += VEC_LEN_F32) {
        const v: VecF32 = data[i..][0..VEC_LEN_F32].*;
        vec_sum += v;
    }

    var sum = @reduce(.Add, vec_sum);

    // Scalar remainder
    while (i < data.len) : (i += 1) {
        sum += data[i];
    }

    return sum;
}

/// Maximum of vector elements
/// kernel("vec_max", "reduction", "Maximum of vector elements")
pub fn vecMax(data: []const f32) f32 {
    if (data.len == 0) return -std.math.inf(f32);

    var vec_max: VecF32 = @splat(data[0]);

    var i: usize = 0;
    while (i + VEC_LEN_F32 <= data.len) : (i += VEC_LEN_F32) {
        const v: VecF32 = data[i..][0..VEC_LEN_F32].*;
        vec_max = @max(vec_max, v);
    }

    var max_val = @reduce(.Max, vec_max);

    while (i < data.len) : (i += 1) {
        if (data[i] > max_val) max_val = data[i];
    }

    return max_val;
}

/// Dot product of two vectors
/// kernel("vec_dot", "reduction", "Dot product of two vectors")
pub fn vecDot(a: []const f32, b: []const f32) f32 {
    std.debug.assert(a.len == b.len);

    var vec_sum: VecF32 = @splat(0.0);

    var i: usize = 0;
    while (i + VEC_LEN_F32 <= a.len) : (i += VEC_LEN_F32) {
        const va: VecF32 = a[i..][0..VEC_LEN_F32].*;
        const vb: VecF32 = b[i..][0..VEC_LEN_F32].*;
        vec_sum = @mulAdd(VecF32, va, vb, vec_sum);
    }

    var sum = @reduce(.Add, vec_sum);

    while (i < a.len) : (i += 1) {
        sum = @mulAdd(f32, a[i], b[i], sum);
    }

    return sum;
}

/// L2 norm of vector
/// kernel("vec_norm", "reduction", "L2 norm of vector")
pub fn vecNorm(data: []const f32) f32 {
    return @sqrt(vecDot(data, data));
}

// ============================================================================
// Normalization Kernels (from kernels.mg: category="norm")
// ============================================================================

/// RMS normalization (LLaMA style)
/// kernel("rms_norm", "norm", "RMS normalization (LLaMA style)")
/// kernel_prop("rms_norm", "params", ["eps"])
pub fn rmsNorm(dst: []f32, src: []const f32, weight: []const f32, eps: f32) void {
    std.debug.assert(dst.len == src.len and src.len == weight.len);

    // Compute sum of squares
    const sum_sq = vecDot(src, src);
    const n: f32 = @floatFromInt(src.len);

    // Compute inverse RMS
    const inv_rms = 1.0 / @sqrt(sum_sq / n + eps);

    // Normalize and apply weight
    var i: usize = 0;
    while (i + VEC_LEN_F32 <= dst.len) : (i += VEC_LEN_F32) {
        const x: VecF32 = src[i..][0..VEC_LEN_F32].*;
        const w: VecF32 = weight[i..][0..VEC_LEN_F32].*;
        const scale: VecF32 = @splat(inv_rms);
        dst[i..][0..VEC_LEN_F32].* = x * scale * w;
    }

    while (i < dst.len) : (i += 1) {
        dst[i] = src[i] * inv_rms * weight[i];
    }
}

/// In-place RMS normalization
pub fn rmsNormInPlace(data: []f32, weight: []const f32, eps: f32) void {
    rmsNorm(data, data, weight, eps);
}

/// Layer normalization (with bias)
/// kernel("layer_norm", "norm", "Layer normalization (with bias)")
pub fn layerNorm(dst: []f32, src: []const f32, weight: []const f32, bias: []const f32, eps: f32) void {
    std.debug.assert(dst.len == src.len and src.len == weight.len and weight.len == bias.len);

    const n: f32 = @floatFromInt(src.len);

    // Compute mean
    const mean = vecSum(src) / n;

    // Compute variance (vectorized subtract-and-square)
    const mv: VecF32 = @splat(mean);
    var var_acc: VecF32 = @splat(0.0);
    var vi: usize = 0;
    while (vi + VEC_LEN_F32 <= src.len) : (vi += VEC_LEN_F32) {
        const x: VecF32 = src[vi..][0..VEC_LEN_F32].*;
        const diff = x - mv;
        var_acc = @mulAdd(VecF32, diff, diff, var_acc);
    }
    var variance = @reduce(.Add, var_acc);
    // Scalar remainder
    while (vi < src.len) : (vi += 1) {
        const diff = src[vi] - mean;
        variance += diff * diff;
    }
    variance /= n;

    // Normalize
    const inv_std = 1.0 / @sqrt(variance + eps);

    var i: usize = 0;
    while (i + VEC_LEN_F32 <= dst.len) : (i += VEC_LEN_F32) {
        const x: VecF32 = src[i..][0..VEC_LEN_F32].*;
        const w: VecF32 = weight[i..][0..VEC_LEN_F32].*;
        const b: VecF32 = bias[i..][0..VEC_LEN_F32].*;
        const m: VecF32 = @splat(mean);
        const s: VecF32 = @splat(inv_std);
        dst[i..][0..VEC_LEN_F32].* = (x - m) * s * w + b;
    }

    while (i < dst.len) : (i += 1) {
        dst[i] = (src[i] - mean) * inv_std * weight[i] + bias[i];
    }
}

/// Softmax along vector (fully SIMD-accelerated)
/// kernel("softmax", "norm", "Softmax along last dimension")
pub fn softmax(data: []f32) void {
    // Find max for numerical stability (vectorized)
    const max_val = vecMax(data);

    // Vectorized exp(x - max) and sum
    const mv: VecF32 = @splat(max_val);
    var vec_sum: VecF32 = @splat(0.0);

    var i: usize = 0;
    while (i + VEC_LEN_F32 <= data.len) : (i += VEC_LEN_F32) {
        const x: VecF32 = data[i..][0..VEC_LEN_F32].*;
        const exp_val = fastExp(x - mv);
        data[i..][0..VEC_LEN_F32].* = exp_val;
        vec_sum += exp_val;
    }

    var sum = @reduce(.Add, vec_sum);

    // Scalar remainder for exp+sum
    while (i < data.len) : (i += 1) {
        data[i] = @exp(data[i] - max_val);
        sum += data[i];
    }

    // Normalize (vectorized)
    const inv_sum = 1.0 / sum;
    vecScale(data, data, inv_sum);
}

// ============================================================================
// Attention Kernels (from kernels.mg: category="attention")
// ============================================================================

/// Rotary Position Embedding
/// kernel("rope", "attention", "Rotary position embedding")
/// kernel_prop("rope", "params", ["base_freq", "dim"])
pub fn rope(
    q: []f32,
    k: []f32,
    pos: usize,
    head_dim: usize,
    base_freq: f32,
) void {
    // Apply rotary embedding to query and key vectors
    // For each pair of elements (x0, x1), rotate by angle theta
    // where theta = pos * freq for that dimension

    const half_dim = head_dim / 2;

    // Precompute cos/sin tables to eliminate repeated pow/sin/cos per element
    var cos_tab: [128]f32 = undefined; // max head_dim/2
    var sin_tab: [128]f32 = undefined;
    const pos_f: f32 = @floatFromInt(pos);
    const hd_f: f32 = @floatFromInt(head_dim);

    for (0..half_dim) |i| {
        const freq = 1.0 / std.math.pow(f32, base_freq, @as(f32, @floatFromInt(2 * i)) / hd_f);
        const theta = pos_f * freq;
        cos_tab[i] = @cos(theta);
        sin_tab[i] = @sin(theta);
    }

    // Apply rotation using precomputed tables
    // The interleaved layout (q[2i], q[2i+1]) makes full SIMD awkward,
    // but the major win is eliminating per-element transcendentals above.
    for (0..half_dim) |i| {
        const c = cos_tab[i];
        const s = sin_tab[i];

        // Rotate query
        if (2 * i + 1 < q.len) {
            const q0 = q[2 * i];
            const q1 = q[2 * i + 1];
            q[2 * i] = q0 * c - q1 * s;
            q[2 * i + 1] = q0 * s + q1 * c;
        }

        // Rotate key
        if (2 * i + 1 < k.len) {
            const k0 = k[2 * i];
            const k1 = k[2 * i + 1];
            k[2 * i] = k0 * c - k1 * s;
            k[2 * i + 1] = k0 * s + k1 * c;
        }
    }
}

/// Apply causal attention mask
/// kernel("causal_mask", "attention", "Apply causal attention mask")
pub fn causalMask(scores: []f32, seq_len: usize, query_pos: usize) void {
    // Mask future positions with -inf
    const neg_inf = -std.math.inf(f32);

    for (query_pos + 1..seq_len) |i| {
        if (i < scores.len) {
            scores[i] = neg_inf;
        }
    }
}

// ============================================================================
// Matrix Operations (from kernels.mg: category="matrix")
// ============================================================================

/// Matrix-vector multiplication: y = A @ x
/// kernel("matvec", "matrix", "Matrix-vector multiplication")
/// A is [M, K] row-major, x is [K], y is [M]
pub fn matvec(y: []f32, a: []const f32, x: []const f32, M: usize, K: usize) void {
    std.debug.assert(y.len == M);
    std.debug.assert(a.len == M * K);
    std.debug.assert(x.len == K);

    for (0..M) |i| {
        const row = a[i * K .. (i + 1) * K];
        y[i] = vecDot(row, x);
    }
}

/// Tiled matrix multiplication: C = A @ B (SIMD-accelerated inner loop)
/// kernel("matmul", "matrix", "Matrix multiplication")
/// kernel_prop("matmul", "tiling_benefit", true)
/// perf_hint("matmul", "tile_size_m", 64)
///
/// Uses tiling for cache locality and SIMD for the K-dimension dot product.
/// For each (i, j) output element, the inner K-loop uses vector accumulators
/// with @mulAdd for fused multiply-add throughput.
pub fn matmul(
    c: []f32,
    a: []const f32,
    b: []const f32,
    M: usize,
    N: usize,
    K: usize,
) void {
    std.debug.assert(c.len == M * N);
    std.debug.assert(a.len == M * K);
    std.debug.assert(b.len == K * N);

    // Zero output
    @memset(c, 0);

    // Tiled matmul for better cache locality
    // Tile sizes match mangle spec perf_hint: 64x64x32
    const TILE_M = 64;
    const TILE_N = 64;
    const TILE_K = 32;

    var ti: usize = 0;
    while (ti < M) : (ti += TILE_M) {
        const m_end = @min(ti + TILE_M, M);

        var tj: usize = 0;
        while (tj < N) : (tj += TILE_N) {
            const n_end = @min(tj + TILE_N, N);

            var tk: usize = 0;
            while (tk < K) : (tk += TILE_K) {
                const k_end = @min(tk + TILE_K, K);

                // For each row, process VEC_LEN_F32 output columns at once
                // by broadcasting A values and loading contiguous B rows
                for (ti..m_end) |ii| {
                    // SIMD path: process N dimension in VEC_LEN_F32 chunks
                    var tj_inner: usize = tj;
                    while (tj_inner + VEC_LEN_F32 <= n_end) : (tj_inner += VEC_LEN_F32) {
                        var vec_acc: VecF32 = @splat(0.0);
                        for (tk..k_end) |kk| {
                            const a_val: VecF32 = @splat(a[ii * K + kk]);
                            // Contiguous load: b[kk, tj_inner..tj_inner+VEC_LEN_F32]
                            const vb: VecF32 = b[kk * N + tj_inner ..][0..VEC_LEN_F32].*;
                            vec_acc = @mulAdd(VecF32, a_val, vb, vec_acc);
                        }
                        // Accumulate to output
                        const old: VecF32 = c[ii * N + tj_inner ..][0..VEC_LEN_F32].*;
                        c[ii * N + tj_inner ..][0..VEC_LEN_F32].* = old + vec_acc;
                    }
                    // Scalar remainder for N
                    while (tj_inner < n_end) : (tj_inner += 1) {
                        var sum: f32 = 0.0;
                        for (tk..k_end) |kk| {
                            sum = @mulAdd(f32, a[ii * K + kk], b[kk * N + tj_inner], sum);
                        }
                        c[ii * N + tj_inner] += sum;
                    }
                }
            }
        }
    }
}

// ============================================================================
// Fused Kernels (from kernels.mg: fused_kernel)
// ============================================================================

/// SwiGLU activation: silu(gate) * up (vectorized)
/// fused_kernel("swiglu", ["vec_silu", "vec_mul"], "SwiGLU activation")
pub fn swiglu(dst: []f32, gate: []const f32, up: []const f32) void {
    std.debug.assert(dst.len == gate.len and gate.len == up.len);

    var i: usize = 0;
    while (i + VEC_LEN_F32 <= dst.len) : (i += VEC_LEN_F32) {
        const g: VecF32 = gate[i..][0..VEC_LEN_F32].*;
        const u: VecF32 = up[i..][0..VEC_LEN_F32].*;
        const sig = sigmoid(g);
        dst[i..][0..VEC_LEN_F32].* = g * sig * u;
    }

    // Scalar remainder
    while (i < dst.len) : (i += 1) {
        const g = gate[i];
        const sig = 1.0 / (1.0 + @exp(-g));
        dst[i] = g * sig * up[i];
    }
}

// ============================================================================
// Quantization Kernels (from kernels.mg: category="quant")
// ============================================================================

/// Q8_0 block structure (32 elements)
pub const BlockQ8_0 = extern struct {
    d: f16, // scale
    qs: [32]i8, // quantized values
};

/// Dequantize Q8_0 block to F32 (SIMD-vectorized)
/// kernel("dequant_q8_0", "quant", "Dequantize Q8_0 to F32")
pub fn dequantQ8_0(dst: []f32, src: []const BlockQ8_0) void {
    var dst_idx: usize = 0;

    for (src) |block| {
        const scale: f32 = @floatCast(block.d);
        const vs: VecF32 = @splat(scale);

        var j: usize = 0;
        while (j + VEC_LEN_F32 <= 32) : (j += VEC_LEN_F32) {
            // Load VEC_LEN_F32 i8 values, widen to i32, convert to f32
            var int_vec: @Vector(VEC_LEN_F32, i32) = undefined;
            inline for (0..VEC_LEN_F32) |vi| {
                int_vec[vi] = block.qs[j + vi];
            }
            const float_vec: VecF32 = @floatFromInt(int_vec);
            dst[dst_idx + j ..][0..VEC_LEN_F32].* = float_vec * vs;
        }
        // Scalar remainder
        while (j < 32) : (j += 1) {
            dst[dst_idx + j] = @as(f32, @floatFromInt(block.qs[j])) * scale;
        }
        dst_idx += 32;
    }
}

/// Q4_0 block structure (32 elements in 18 bytes)
pub const BlockQ4_0 = extern struct {
    d: f16, // scale
    qs: [16]u8, // quantized values (4 bits each, 2 per byte)
};

/// Dequantize Q4_0 block to F32 (SIMD-vectorized)
pub fn dequantQ4_0(dst: []f32, src: []const BlockQ4_0) void {
    var dst_idx: usize = 0;

    for (src) |block| {
        const scale: f32 = @floatCast(block.d);
        const vs: VecF32 = @splat(scale);
        const eight: VecF32 = @splat(8.0);

        // Process VEC_LEN_F32 bytes at a time (each byte = 2 weights)
        var j: usize = 0;
        while (j + VEC_LEN_F32 <= 16) : (j += VEC_LEN_F32) {
            // Unpack low nibbles
            var lo_vec: @Vector(VEC_LEN_F32, i32) = undefined;
            var hi_vec: @Vector(VEC_LEN_F32, i32) = undefined;
            inline for (0..VEC_LEN_F32) |vi| {
                lo_vec[vi] = @intCast(block.qs[j + vi] & 0x0F);
                hi_vec[vi] = @intCast(block.qs[j + vi] >> 4);
            }
            const lo_f: VecF32 = @floatFromInt(lo_vec);
            const hi_f: VecF32 = @floatFromInt(hi_vec);

            // SIMD subtract and multiply, then interleave into output
            const lo_scaled = (lo_f - eight) * vs;
            const hi_scaled = (hi_f - eight) * vs;
            inline for (0..VEC_LEN_F32) |vi| {
                dst[dst_idx + j * 2 + vi * 2] = lo_scaled[vi];
                dst[dst_idx + j * 2 + vi * 2 + 1] = hi_scaled[vi];
            }
        }
        // Scalar remainder
        while (j < 16) : (j += 1) {
            const lo: i8 = @intCast(block.qs[j] & 0x0F);
            dst[dst_idx + j * 2] = @as(f32, @floatFromInt(lo - 8)) * scale;
            const hi: i8 = @intCast(block.qs[j] >> 4);
            dst[dst_idx + j * 2 + 1] = @as(f32, @floatFromInt(hi - 8)) * scale;
        }
        dst_idx += 32;
    }
}

// ============================================================================
// Tests
// ============================================================================

test "vec_add" {
    var a = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const b = [_]f32{ 8, 7, 6, 5, 4, 3, 2, 1 };
    var dst: [8]f32 = undefined;

    vecAdd(&dst, &a, &b);

    for (dst) |v| {
        try std.testing.expectApproxEqAbs(@as(f32, 9.0), v, 0.001);
    }
}

test "vec_dot" {
    const a = [_]f32{ 1, 2, 3, 4 };
    const b = [_]f32{ 4, 3, 2, 1 };

    const result = vecDot(&a, &b);
    // 1*4 + 2*3 + 3*2 + 4*1 = 4 + 6 + 6 + 4 = 20
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), result, 0.001);
}

test "vec_sum" {
    const data = [_]f32{ 1, 2, 3, 4, 5 };
    const result = vecSum(&data);
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), result, 0.001);
}

test "vec_max" {
    const data = [_]f32{ 1, 5, 3, 9, 2, 7 };
    const result = vecMax(&data);
    try std.testing.expectApproxEqAbs(@as(f32, 9.0), result, 0.001);
}

test "vec_silu" {
    var data = [_]f32{ 0, 1, -1, 2 };
    var result: [4]f32 = undefined;

    vecSilu(&result, &data);

    // silu(0) = 0 * sigmoid(0) = 0 * 0.5 = 0
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result[0], 0.001);
    // silu(1) ≈ 0.731
    try std.testing.expectApproxEqAbs(@as(f32, 0.731), result[1], 0.01);
}

test "softmax" {
    var data = [_]f32{ 1, 2, 3, 4 };
    softmax(&data);

    // Sum should be 1
    var sum: f32 = 0;
    for (data) |v| sum += v;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sum, 0.001);

    // Values should be in ascending order
    try std.testing.expect(data[0] < data[1]);
    try std.testing.expect(data[1] < data[2]);
    try std.testing.expect(data[2] < data[3]);
}

test "rms_norm" {
    var data = [_]f32{ 1, 2, 3, 4 };
    const weight = [_]f32{ 1, 1, 1, 1 };
    var result: [4]f32 = undefined;

    rmsNorm(&result, &data, &weight, 1e-5);

    // Check that norm is approximately 1
    const norm = vecNorm(&result);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), norm / @sqrt(4.0), 0.01);
}

test "vec_fma" {
    const a = [_]f32{ 1, 2, 3, 4 };
    const b = [_]f32{ 2, 3, 4, 5 };
    const c_in = [_]f32{ 10, 20, 30, 40 };
    var dst: [4]f32 = undefined;

    vecFma(&dst, &a, &b, &c_in);

    // a*b+c: 1*2+10=12, 2*3+20=26, 3*4+30=42, 4*5+40=60
    try std.testing.expectApproxEqAbs(@as(f32, 12.0), dst[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 26.0), dst[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), dst[2], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 60.0), dst[3], 0.001);
}

test "vec_gelu" {
    var src = [_]f32{ 0, 1, -1, 2 };
    var dst: [4]f32 = undefined;

    vecGelu(&dst, &src);

    // gelu(0) = 0
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dst[0], 0.01);
    // gelu(1) ≈ 0.841
    try std.testing.expectApproxEqAbs(@as(f32, 0.841), dst[1], 0.02);
    // gelu(-1) ≈ -0.159
    try std.testing.expectApproxEqAbs(@as(f32, -0.159), dst[2], 0.02);
    // gelu(2) ≈ 1.955
    try std.testing.expectApproxEqAbs(@as(f32, 1.955), dst[3], 0.02);
}

test "rope" {
    var q = [_]f32{ 1, 0, 1, 0 };
    var k = [_]f32{ 0, 1, 0, 1 };

    rope(&q, &k, 1, 4, 10000.0);

    // After rotation, vectors should have the same norm
    const q_norm = vecNorm(&q);
    const k_norm = vecNorm(&k);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), q_norm / @sqrt(2.0), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), k_norm / @sqrt(2.0), 0.01);
}

test "causal_mask" {
    var scores = [_]f32{ 1, 2, 3, 4, 5 };

    causalMask(&scores, 5, 2);

    // Positions 0..2 should be unchanged, 3+ should be -inf
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), scores[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), scores[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), scores[2], 0.001);
    try std.testing.expect(scores[3] == -std.math.inf(f32));
    try std.testing.expect(scores[4] == -std.math.inf(f32));
}

test "layer_norm" {
    const src = [_]f32{ 1, 2, 3, 4 };
    const weight = [_]f32{ 1, 1, 1, 1 };
    const bias = [_]f32{ 0, 0, 0, 0 };
    var dst: [4]f32 = undefined;

    layerNorm(&dst, &src, &weight, &bias, 1e-5);

    // Mean of result should be ~0 (since bias=0, weight=1)
    const result_mean = vecSum(&dst) / 4.0;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result_mean, 0.01);
}

test "swiglu" {
    const gate = [_]f32{ 0, 1, -1, 2 };
    const up_val = [_]f32{ 1, 1, 1, 1 };
    var dst: [4]f32 = undefined;

    swiglu(&dst, &gate, &up_val);

    // swiglu(0, 1) = silu(0) * 1 = 0
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dst[0], 0.001);
    // swiglu(1, 1) = silu(1) * 1 ≈ 0.731
    try std.testing.expectApproxEqAbs(@as(f32, 0.731), dst[1], 0.02);
}

test "dequant_q8_0" {
    // Create a Q8_0 block with scale=0.5, values=[1, 2, -1, ...]
    var block: BlockQ8_0 = undefined;
    block.d = @as(f16, 0.5);
    for (&block.qs, 0..) |*q, idx| {
        q.* = @intCast(@as(i32, @intCast(idx)) - 16);
    }
    var dst: [32]f32 = undefined;
    const src = [_]BlockQ8_0{block};
    dequantQ8_0(&dst, &src);

    // First element: (-16) * 0.5 = -8.0
    try std.testing.expectApproxEqAbs(@as(f32, -8.0), dst[0], 0.01);
    // Element 16: (0) * 0.5 = 0.0
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dst[16], 0.01);
}

test "odd_length_vec_add" {
    // Test with length not a multiple of vector size
    var a = [_]f32{ 1, 2, 3, 4, 5 };
    const b = [_]f32{ 10, 20, 30, 40, 50 };
    var dst: [5]f32 = undefined;

    vecAdd(&dst, &a, &b);

    try std.testing.expectApproxEqAbs(@as(f32, 11.0), dst[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 55.0), dst[4], 0.001);
}

test "softmax_large" {
    // Test softmax with values that could cause overflow without max subtraction
    var data = [_]f32{ 100, 101, 102, 103, 104 };
    softmax(&data);

    var sum: f32 = 0;
    for (data) |v| sum += v;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sum, 0.01);
    // Should still be ascending
    try std.testing.expect(data[0] < data[4]);
}

test "matmul" {
    // 2x3 @ 3x2 = 2x2
    const a = [_]f32{ 1, 2, 3, 4, 5, 6 }; // 2x3
    const b = [_]f32{ 7, 8, 9, 10, 11, 12 }; // 3x2
    var c: [4]f32 = undefined;

    matmul(&c, &a, &b, 2, 2, 3);

    // c[0,0] = 1*7 + 2*9 + 3*11 = 7 + 18 + 33 = 58
    try std.testing.expectApproxEqAbs(@as(f32, 58.0), c[0], 0.001);
    // c[0,1] = 1*8 + 2*10 + 3*12 = 8 + 20 + 36 = 64
    try std.testing.expectApproxEqAbs(@as(f32, 64.0), c[1], 0.001);
}