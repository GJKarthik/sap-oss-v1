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

/// Fast approximate exp for vectors
fn fastExp(x: VecF32) VecF32 {
    // Polynomial approximation of exp(x) for small x
    // exp(x) ≈ 1 + x + x²/2 + x³/6 + x⁴/24
    const one: VecF32 = @splat(1.0);
    const half: VecF32 = @splat(0.5);
    const sixth: VecF32 = @splat(1.0 / 6.0);
    const twentyfourth: VecF32 = @splat(1.0 / 24.0);

    const x2 = x * x;
    const x3 = x2 * x;
    const x4 = x2 * x2;

    return one + x + half * x2 + sixth * x3 + twentyfourth * x4;
}

/// Sigmoid function: 1 / (1 + exp(-x))
fn sigmoid(x: VecF32) VecF32 {
    const neg_x = -x;

    // Clamp to avoid overflow
    const clamped = @min(@max(neg_x, @as(VecF32, @splat(-20.0))), @as(VecF32, @splat(20.0)));

    // For each element, compute exp and sigmoid
    var result: VecF32 = undefined;
    inline for (0..VEC_LEN_F32) |i| {
        const exp_val = @exp(clamped[i]);
        result[i] = 1.0 / (1.0 + exp_val);
    }
    return result;
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

/// GELU activation
/// kernel("vec_gelu", "activation", "GELU activation")
/// kernel_prop("vec_gelu", "formula", "0.5 * x * (1 + tanh(sqrt(2/pi) * (x + 0.044715 * x^3)))")
pub fn vecGelu(dst: []f32, src: []const f32) void {
    std.debug.assert(dst.len == src.len);

    const SQRT_2_PI: f32 = 0.7978845608; // sqrt(2/pi)
    const COEF: f32 = 0.044715;

    var i: usize = 0;
    while (i < dst.len) : (i += 1) {
        const x = src[i];
        const inner = SQRT_2_PI * (x + COEF * x * x * x);
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

    // Compute variance
    var variance: f32 = 0;
    for (src) |x| {
        const diff = x - mean;
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

/// Softmax along vector
/// kernel("softmax", "norm", "Softmax along last dimension")
pub fn softmax(data: []f32) void {
    // Find max for numerical stability
    const max_val = vecMax(data);

    // Compute exp(x - max) and sum
    var sum: f32 = 0;
    for (data) |*x| {
        x.* = @exp(x.* - max_val);
        sum += x.*;
    }

    // Normalize
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

    for (0..half_dim) |i| {
        const freq = 1.0 / std.math.pow(f32, base_freq, @as(f32, @floatFromInt(2 * i)) / @as(f32, @floatFromInt(head_dim)));
        const theta = @as(f32, @floatFromInt(pos)) * freq;

        const cos_theta = @cos(theta);
        const sin_theta = @sin(theta);

        // Rotate query
        if (2 * i + 1 < q.len) {
            const q0 = q[2 * i];
            const q1 = q[2 * i + 1];
            q[2 * i] = q0 * cos_theta - q1 * sin_theta;
            q[2 * i + 1] = q0 * sin_theta + q1 * cos_theta;
        }

        // Rotate key
        if (2 * i + 1 < k.len) {
            const k0 = k[2 * i];
            const k1 = k[2 * i + 1];
            k[2 * i] = k0 * cos_theta - k1 * sin_theta;
            k[2 * i + 1] = k0 * sin_theta + k1 * cos_theta;
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

/// Tiled matrix multiplication: C = A @ B
/// kernel("matmul", "matrix", "Matrix multiplication")
/// kernel_prop("matmul", "tiling_benefit", true)
/// perf_hint("matmul", "tile_size_m", 64)
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
    const TILE_M = 32;
    const TILE_N = 32;
    const TILE_K = 32;

    var i: usize = 0;
    while (i < M) : (i += TILE_M) {
        const m_end = @min(i + TILE_M, M);

        var j: usize = 0;
        while (j < N) : (j += TILE_N) {
            const n_end = @min(j + TILE_N, N);

            var kk: usize = 0;
            while (kk < K) : (kk += TILE_K) {
                const k_end = @min(kk + TILE_K, K);

                // Process tile
                for (i..m_end) |ii| {
                    for (j..n_end) |jj| {
                        var sum: f32 = c[ii * N + jj];
                        for (kk..k_end) |kkk| {
                            sum = @mulAdd(f32, a[ii * K + kkk], b[kkk * N + jj], sum);
                        }
                        c[ii * N + jj] = sum;
                    }
                }
            }
        }
    }
}

// ============================================================================
// Fused Kernels (from kernels.mg: fused_kernel)
// ============================================================================

/// SwiGLU activation: silu(gate) * up
/// fused_kernel("swiglu", ["vec_silu", "vec_mul"], "SwiGLU activation")
pub fn swiglu(dst: []f32, gate: []const f32, up: []const f32) void {
    std.debug.assert(dst.len == gate.len and gate.len == up.len);

    var i: usize = 0;
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

/// Dequantize Q8_0 block to F32
/// kernel("dequant_q8_0", "quant", "Dequantize Q8_0 to F32")
pub fn dequantQ8_0(dst: []f32, src: []const BlockQ8_0) void {
    var dst_idx: usize = 0;

    for (src) |block| {
        const scale: f32 = @floatCast(block.d);

        for (block.qs) |q| {
            dst[dst_idx] = @as(f32, @floatFromInt(q)) * scale;
            dst_idx += 1;
        }
    }
}

/// Q4_0 block structure (32 elements in 18 bytes)
pub const BlockQ4_0 = extern struct {
    d: f16, // scale
    qs: [16]u8, // quantized values (4 bits each, 2 per byte)
};

/// Dequantize Q4_0 block to F32
pub fn dequantQ4_0(dst: []f32, src: []const BlockQ4_0) void {
    var dst_idx: usize = 0;

    for (src) |block| {
        const scale: f32 = @floatCast(block.d);

        for (block.qs) |byte| {
            // Low nibble
            const lo: i8 = @intCast(byte & 0x0F);
            dst[dst_idx] = @as(f32, @floatFromInt(lo - 8)) * scale;
            dst_idx += 1;

            // High nibble
            const hi: i8 = @intCast(byte >> 4);
            dst[dst_idx] = @as(f32, @floatFromInt(hi - 8)) * scale;
            dst_idx += 1;
        }
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