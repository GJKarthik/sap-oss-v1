//! Hardware-Accelerated Tensor Operations
//!
//! Provides optimized implementations of tensor operations using:
//! - Apple Accelerate (vDSP, BLAS) on macOS
//! - SIMD vector intrinsics on all platforms
//! - Cache-optimized memory access patterns
//!
//! Performance targets:
//! - 4-8x speedup over scalar loops with SIMD
//! - 10-20x speedup on macOS with Accelerate BLAS

const std = @import("std");
const builtin = @import("builtin");
const math = std.math;

// ============================================================================
// Platform Detection
// ============================================================================

/// Check if Apple Accelerate framework is available
pub fn isAvailable() bool {
    return builtin.os.tag == .macos;
}

/// Check if ARM NEON SIMD is available
pub fn hasNEON() bool {
    return builtin.cpu.arch == .aarch64;
}

/// Check if x86 AVX2 is available
pub fn hasAVX2() bool {
    return switch (builtin.cpu.arch) {
        .x86_64 => std.Target.x86.featureSetHas(builtin.cpu.features, .avx2),
        else => false,
    };
}

// ============================================================================
// Apple Accelerate Framework (macOS)
// ============================================================================

const cblas = if (builtin.os.tag == .macos) struct {
    // BLAS Level 1
    pub extern "Accelerate" fn cblas_sdot(N: c_int, X: [*]const f32, incX: c_int, Y: [*]const f32, incY: c_int) f32;
    pub extern "Accelerate" fn cblas_snrm2(N: c_int, X: [*]const f32, incX: c_int) f32;
    pub extern "Accelerate" fn cblas_saxpy(N: c_int, alpha: f32, X: [*]const f32, incX: c_int, Y: [*]f32, incY: c_int) void;
    pub extern "Accelerate" fn cblas_sscal(N: c_int, alpha: f32, X: [*]f32, incX: c_int) void;

    // BLAS Level 2
    pub extern "Accelerate" fn cblas_sgemv(
        Order: c_int,
        TransA: c_int,
        M: c_int,
        N: c_int,
        alpha: f32,
        A: [*]const f32,
        lda: c_int,
        X: [*]const f32,
        incX: c_int,
        beta: f32,
        Y: [*]f32,
        incY: c_int,
    ) void;

    // BLAS Level 3
    pub extern "Accelerate" fn cblas_sgemm(
        Order: c_int,
        TransA: c_int,
        TransB: c_int,
        M: c_int,
        N: c_int,
        K: c_int,
        alpha: f32,
        A: [*]const f32,
        lda: c_int,
        B: [*]const f32,
        ldb: c_int,
        beta: f32,
        C: [*]f32,
        ldc: c_int,
    ) void;

    // vDSP
    pub extern "Accelerate" fn vDSP_dotpr(A: [*]const f32, IA: c_long, B: [*]const f32, IB: c_long, C: *f32, N: c_ulong) void;
    pub extern "Accelerate" fn vDSP_sve(A: [*]const f32, IA: c_long, C: *f32, N: c_ulong) void;
    pub extern "Accelerate" fn vDSP_svesq(A: [*]const f32, IA: c_long, C: *f32, N: c_ulong) void;
    pub extern "Accelerate" fn vDSP_vadd(A: [*]const f32, IA: c_long, B: [*]const f32, IB: c_long, C: [*]f32, IC: c_long, N: c_ulong) void;
    pub extern "Accelerate" fn vDSP_vmul(A: [*]const f32, IA: c_long, B: [*]const f32, IB: c_long, C: [*]f32, IC: c_long, N: c_ulong) void;
    pub extern "Accelerate" fn vDSP_vsmul(A: [*]const f32, IA: c_long, B: *const f32, C: [*]f32, IC: c_long, N: c_ulong) void;
    pub extern "Accelerate" fn vDSP_mmul(A: [*]const f32, IA: c_long, B: [*]const f32, IB: c_long, C: [*]f32, IC: c_long, M: c_ulong, N: c_ulong, P: c_ulong) void;

    pub const CblasRowMajor: c_int = 101;
    pub const CblasNoTrans: c_int = 111;
    pub const CblasTrans: c_int = 112;
} else struct {};

// ============================================================================
// SIMD Vector Types
// ============================================================================

/// 4-wide f32 vector (128-bit, works on both ARM NEON and x86 SSE)
const Vec4f = @Vector(4, f32);

/// 8-wide f32 vector (256-bit, for AVX2)
const Vec8f = @Vector(8, f32);

// ============================================================================
// Accelerated Operations
// ============================================================================

/// Dot product: sum(a[i] * b[i])
pub fn dot(a: []const f32, b: []const f32) f32 {
    const n = @min(a.len, b.len);
    if (n == 0) return 0.0;

    // Use Accelerate on macOS
    if (comptime isAvailable()) {
        var result: f32 = 0.0;
        cblas.vDSP_dotpr(a.ptr, 1, b.ptr, 1, &result, n);
        return result;
    }

    // SIMD fallback
    return dotSIMD(a[0..n], b[0..n]);
}

/// SIMD-optimized dot product
fn dotSIMD(a: []const f32, b: []const f32) f32 {
    const n = a.len;
    var sum: f32 = 0.0;

    // Process 4 elements at a time
    const vec_len = 4;
    const vec_count = n / vec_len;
    var acc: Vec4f = @splat(0.0);

    var i: usize = 0;
    while (i < vec_count * vec_len) : (i += vec_len) {
        const va: Vec4f = a[i..][0..vec_len].*;
        const vb: Vec4f = b[i..][0..vec_len].*;
        acc += va * vb;
    }

    // Reduce vector to scalar
    sum = @reduce(.Add, acc);

    // Handle remainder
    while (i < n) : (i += 1) {
        sum += a[i] * b[i];
    }

    return sum;
}

/// Sum of squares: sum(a[i] * a[i])
pub fn sumOfSquares(a: []const f32) f32 {
    if (a.len == 0) return 0.0;

    // Use Accelerate on macOS
    if (comptime isAvailable()) {
        var result: f32 = 0.0;
        cblas.vDSP_svesq(a.ptr, 1, &result, a.len);
        return result;
    }

    // SIMD fallback
    return dot(a, a);
}

/// Vector-matrix multiply: out[N] = x[K] @ W[K×N]
/// W is stored row-major: W[k, n] = W[k * N + n]
pub fn gemv(out: []f32, x: []const f32, W: []const f32, K: usize, N: usize) void {
    if (out.len < N or x.len < K) return;

    // Use Accelerate on macOS (BLAS sgemv is ~10x faster)
    if (comptime isAvailable()) {
        // cblas_sgemv does: y = alpha * A * x + beta * y
        // We want: out = W^T * x (since W is K×N and we want x[K] @ W = out[N])
        // This is equivalent to: y = W^T * x where W^T is N×K
        cblas.cblas_sgemv(
            cblas.CblasRowMajor,
            cblas.CblasTrans, // Transpose W
            @intCast(K), // M = rows of W (before transpose)
            @intCast(N), // N = cols of W (before transpose)
            1.0, // alpha
            W.ptr,
            @intCast(N), // lda = N (stride between rows)
            x.ptr,
            1, // incX
            0.0, // beta
            out.ptr,
            1, // incY
        );
        return;
    }

    // SIMD fallback with cache-optimized blocking
    gemvSIMD(out, x, W, K, N);
}

/// SIMD-optimized vector-matrix multiply with tiling
fn gemvSIMD(out: []f32, x: []const f32, W: []const f32, K: usize, N: usize) void {
    // Zero output
    @memset(out[0..N], 0.0);

    // Process in tiles for better cache utilization
    const TILE_K: usize = 64; // Tile size along K dimension
    const VEC_LEN: usize = 4;

    var k_start: usize = 0;
    while (k_start < K) : (k_start += TILE_K) {
        const k_end = @min(k_start + TILE_K, K);

        // Process N outputs
        var j: usize = 0;
        while (j + VEC_LEN <= N) : (j += VEC_LEN) {
            var acc: Vec4f = @splat(0.0);

            // Accumulate over K tile
            for (k_start..k_end) |k| {
                const x_k: Vec4f = @splat(x[k]);
                const w_slice = W[k * N + j ..][0..VEC_LEN];
                const w_vec: Vec4f = w_slice.*;
                acc += x_k * w_vec;
            }

            // Add to output
            const out_slice = out[j..][0..VEC_LEN];
            const out_vec: Vec4f = out_slice.*;
            const result = out_vec + acc;
            out[j..][0..VEC_LEN].* = result;
        }

        // Handle remainder
        while (j < N) : (j += 1) {
            var sum: f32 = 0.0;
            for (k_start..k_end) |k| {
                sum += x[k] * W[k * N + j];
            }
            out[j] += sum;
        }
    }
}

/// Matrix multiply: C[M×N] = A[M×K] @ B[K×N]
pub fn gemm(C: []f32, A: []const f32, B: []const f32, M: usize, N: usize, K: usize) void {
    if (C.len < M * N) return;

    // Use Accelerate on macOS
    if (comptime isAvailable()) {
        cblas.cblas_sgemm(
            cblas.CblasRowMajor,
            cblas.CblasNoTrans,
            cblas.CblasNoTrans,
            @intCast(M),
            @intCast(N),
            @intCast(K),
            1.0, // alpha
            A.ptr,
            @intCast(K), // lda
            B.ptr,
            @intCast(N), // ldb
            0.0, // beta
            C.ptr,
            @intCast(N), // ldc
        );
        return;
    }

    // Tiled SIMD fallback
    gemmTiled(C, A, B, M, N, K);
}

/// Tiled matrix multiply for better cache utilization
fn gemmTiled(C: []f32, A: []const f32, B: []const f32, M: usize, N: usize, K: usize) void {
    const TILE: usize = 32; // L1 cache friendly tile size
    const VEC_LEN: usize = 4;

    // Zero output
    @memset(C[0 .. M * N], 0.0);

    // Tile over all dimensions
    var i_start: usize = 0;
    while (i_start < M) : (i_start += TILE) {
        const i_end = @min(i_start + TILE, M);

        var j_start: usize = 0;
        while (j_start < N) : (j_start += TILE) {
            const j_end = @min(j_start + TILE, N);

            var k_start: usize = 0;
            while (k_start < K) : (k_start += TILE) {
                const k_end = @min(k_start + TILE, K);

                // Micro-kernel: process tile
                for (i_start..i_end) |i| {
                    var j = j_start;
                    while (j + VEC_LEN <= j_end) : (j += VEC_LEN) {
                        var acc: Vec4f = @splat(0.0);

                        for (k_start..k_end) |k| {
                            const a_ik: Vec4f = @splat(A[i * K + k]);
                            const b_slice = B[k * N + j ..][0..VEC_LEN];
                            const b_vec: Vec4f = b_slice.*;
                            acc += a_ik * b_vec;
                        }

                        const c_slice = C[i * N + j ..][0..VEC_LEN];
                        const c_vec: Vec4f = c_slice.*;
                        C[i * N + j ..][0..VEC_LEN].* = c_vec + acc;
                    }

                    // Remainder
                    while (j < j_end) : (j += 1) {
                        var sum: f32 = 0.0;
                        for (k_start..k_end) |k| {
                            sum += A[i * K + k] * B[k * N + j];
                        }
                        C[i * N + j] += sum;
                    }
                }
            }
        }
    }
}

/// Vector addition: dst = a + b
pub fn vecAdd(dst: []f32, a: []const f32, b: []const f32) void {
    const n = @min(dst.len, @min(a.len, b.len));
    if (n == 0) return;

    // Use Accelerate on macOS
    if (comptime isAvailable()) {
        cblas.vDSP_vadd(a.ptr, 1, b.ptr, 1, dst.ptr, 1, n);
        return;
    }

    // SIMD fallback
    vecAddSIMD(dst[0..n], a[0..n], b[0..n]);
}

/// SIMD vector addition
fn vecAddSIMD(dst: []f32, a: []const f32, b: []const f32) void {
    const n = dst.len;
    const VEC_LEN: usize = 4;

    var i: usize = 0;
    while (i + VEC_LEN <= n) : (i += VEC_LEN) {
        const va: Vec4f = a[i..][0..VEC_LEN].*;
        const vb: Vec4f = b[i..][0..VEC_LEN].*;
        dst[i..][0..VEC_LEN].* = va + vb;
    }

    // Remainder
    while (i < n) : (i += 1) {
        dst[i] = a[i] + b[i];
    }
}

/// Vector multiply: dst = a * b (element-wise)
pub fn vecMul(dst: []f32, a: []const f32, b: []const f32) void {
    const n = @min(dst.len, @min(a.len, b.len));
    if (n == 0) return;

    // Use Accelerate on macOS
    if (comptime isAvailable()) {
        cblas.vDSP_vmul(a.ptr, 1, b.ptr, 1, dst.ptr, 1, n);
        return;
    }

    // SIMD fallback
    const VEC_LEN: usize = 4;
    var i: usize = 0;
    while (i + VEC_LEN <= n) : (i += VEC_LEN) {
        const va: Vec4f = a[i..][0..VEC_LEN].*;
        const vb: Vec4f = b[i..][0..VEC_LEN].*;
        dst[i..][0..VEC_LEN].* = va * vb;
    }
    while (i < n) : (i += 1) {
        dst[i] = a[i] * b[i];
    }
}

/// Vector scale: dst = a * scalar
pub fn vecScale(dst: []f32, a: []const f32, scalar: f32) void {
    const n = @min(dst.len, a.len);
    if (n == 0) return;

    // Use Accelerate on macOS
    if (comptime isAvailable()) {
        cblas.vDSP_vsmul(a.ptr, 1, &scalar, dst.ptr, 1, n);
        return;
    }

    // SIMD fallback
    const VEC_LEN: usize = 4;
    const s_vec: Vec4f = @splat(scalar);

    var i: usize = 0;
    while (i + VEC_LEN <= n) : (i += VEC_LEN) {
        const va: Vec4f = a[i..][0..VEC_LEN].*;
        dst[i..][0..VEC_LEN].* = va * s_vec;
    }
    while (i < n) : (i += 1) {
        dst[i] = a[i] * scalar;
    }
}

/// Fused multiply-add: dst = a * b + c
pub fn fma(dst: []f32, a: []const f32, b: []const f32, c: []const f32) void {
    const n = @min(dst.len, @min(a.len, @min(b.len, c.len)));
    if (n == 0) return;

    const VEC_LEN: usize = 4;
    var i: usize = 0;
    while (i + VEC_LEN <= n) : (i += VEC_LEN) {
        const va: Vec4f = a[i..][0..VEC_LEN].*;
        const vb: Vec4f = b[i..][0..VEC_LEN].*;
        const vc: Vec4f = c[i..][0..VEC_LEN].*;
        // Use @mulAdd for potential FMA instruction on hardware that supports it
        dst[i..][0..VEC_LEN].* = @mulAdd(Vec4f, va, vb, vc);
    }
    while (i < n) : (i += 1) {
        dst[i] = @mulAdd(f32, a[i], b[i], c[i]);
    }
}

/// SIMD-optimized softmax (numerically stable)
pub fn softmax(data: []f32) void {
    if (data.len == 0) return;

    // Find max for numerical stability
    var max_val: f32 = data[0];
    for (data[1..]) |v| {
        if (v > max_val) max_val = v;
    }

    // exp(x - max) and sum
    var sum: f32 = 0.0;
    for (data) |*v| {
        v.* = @exp(v.* - max_val);
        sum += v.*;
    }

    // Normalize
    if (sum > 0.0) {
        const inv_sum = 1.0 / sum;
        vecScale(data, data, inv_sum);
    }
}

/// SIMD-optimized RMSNorm
pub fn rmsNorm(dst: []f32, src: []const f32, weight: []const f32, eps: f32) void {
    const n = @min(dst.len, @min(src.len, weight.len));
    if (n == 0) return;

    // Sum of squares
    const ss = sumOfSquares(src[0..n]);
    const rms = 1.0 / @sqrt(ss / @as(f32, @floatFromInt(n)) + eps);

    // Apply normalization with weight
    const VEC_LEN: usize = 4;
    const rms_vec: Vec4f = @splat(rms);

    var i: usize = 0;
    while (i + VEC_LEN <= n) : (i += VEC_LEN) {
        const vs: Vec4f = src[i..][0..VEC_LEN].*;
        const vw: Vec4f = weight[i..][0..VEC_LEN].*;
        dst[i..][0..VEC_LEN].* = vw * vs * rms_vec;
    }
    while (i < n) : (i += 1) {
        dst[i] = weight[i] * src[i] * rms;
    }
}

/// SIMD-optimized SiLU (Swish): x * sigmoid(x)
pub fn silu(dst: []f32, src: []const f32) void {
    const n = @min(dst.len, src.len);
    for (0..n) |i| {
        const x = src[i];
        dst[i] = x / (1.0 + @exp(-x));
    }
}

/// SIMD-optimized SwiGLU: silu(gate) * up
pub fn swiglu(dst: []f32, gate: []const f32, up: []const f32) void {
    const n = @min(dst.len, @min(gate.len, up.len));
    for (0..n) |i| {
        const g = gate[i];
        const silu_g = g / (1.0 + @exp(-g));
        dst[i] = silu_g * up[i];
    }
}

// ============================================================================
// Quantized Operations (INT4/INT8)
// ============================================================================

/// INT8 quantization parameters
pub const QuantParams = struct {
    scale: f32,
    zero_point: i32,
};

/// Quantize f32 to INT8
pub fn quantizeINT8(dst: []i8, src: []const f32, params: QuantParams) void {
    const n = @min(dst.len, src.len);
    const inv_scale = 1.0 / params.scale;

    for (0..n) |i| {
        const q = @as(i32, @intFromFloat(@round(src[i] * inv_scale))) + params.zero_point;
        dst[i] = @intCast(@max(-128, @min(127, q)));
    }
}

/// Dequantize INT8 to f32
pub fn dequantizeINT8(dst: []f32, src: []const i8, params: QuantParams) void {
    const n = @min(dst.len, src.len);
    for (0..n) |i| {
        dst[i] = @as(f32, @floatFromInt(@as(i32, src[i]) - params.zero_point)) * params.scale;
    }
}

/// Compute optimal quantization parameters from data
pub fn computeQuantParams(data: []const f32) QuantParams {
    if (data.len == 0) return .{ .scale = 1.0, .zero_point = 0 };

    var min_val: f32 = data[0];
    var max_val: f32 = data[0];
    for (data[1..]) |v| {
        if (v < min_val) min_val = v;
        if (v > max_val) max_val = v;
    }

    // Asymmetric quantization for INT8 range [-128, 127]
    const scale = (max_val - min_val) / 255.0;
    const zero_point = @as(i32, @intFromFloat(@round(-min_val / scale))) - 128;

    return .{
        .scale = if (scale == 0.0) 1.0 else scale,
        .zero_point = @max(-128, @min(127, zero_point)),
    };
}

// ============================================================================
// Tests
// ============================================================================

test "dot product correctness" {
    const a = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0 };
    const b = [_]f32{ 8.0, 7.0, 6.0, 5.0, 4.0, 3.0, 2.0, 1.0 };
    const result = dot(&a, &b);
    // 1*8 + 2*7 + 3*6 + 4*5 + 5*4 + 6*3 + 7*2 + 8*1 = 120
    try std.testing.expectApproxEqAbs(@as(f32, 120.0), result, 0.001);
}

test "gemv correctness" {
    // x[2] @ W[2×3] = out[3]
    const x = [_]f32{ 1.0, 2.0 };
    const W = [_]f32{
        1.0, 2.0, 3.0, // row 0
        4.0, 5.0, 6.0, // row 1
    };
    var out: [3]f32 = undefined;
    gemv(&out, &x, &W, 2, 3);
    // out[0] = 1*1 + 2*4 = 9
    // out[1] = 1*2 + 2*5 = 12
    // out[2] = 1*3 + 2*6 = 15
    try std.testing.expectApproxEqAbs(@as(f32, 9.0), out[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 12.0), out[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), out[2], 0.001);
}

test "vecAdd SIMD" {
    const a = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0 };
    const b = [_]f32{ 5.0, 4.0, 3.0, 2.0, 1.0 };
    var dst: [5]f32 = undefined;
    vecAdd(&dst, &a, &b);
    for (dst) |v| {
        try std.testing.expectApproxEqAbs(@as(f32, 6.0), v, 0.001);
    }
}

test "sumOfSquares" {
    const a = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    const result = sumOfSquares(&a);
    // 1 + 4 + 9 + 16 = 30
    try std.testing.expectApproxEqAbs(@as(f32, 30.0), result, 0.001);
}

test "softmax sums to 1" {
    var data = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    softmax(&data);
    var sum: f32 = 0.0;
    for (data) |v| sum += v;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sum, 0.001);
}

test "rmsNorm with unit weights" {
    var src = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
    var wt = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
    var dst: [4]f32 = undefined;
    rmsNorm(&dst, &src, &wt, 1e-5);
    for (dst) |v| {
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), v, 0.01);
    }
}

test "INT8 quantization roundtrip" {
    const src = [_]f32{ -1.0, 0.0, 0.5, 1.0 };
    const params = computeQuantParams(&src);

    var quantized: [4]i8 = undefined;
    quantizeINT8(&quantized, &src, params);

    var dequantized: [4]f32 = undefined;
    dequantizeINT8(&dequantized, &quantized, params);

    for (src, dequantized) |orig, deq| {
        try std.testing.expectApproxEqAbs(orig, deq, 0.02);
    }
}