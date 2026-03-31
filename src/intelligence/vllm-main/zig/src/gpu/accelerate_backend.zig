//! Apple Accelerate Framework Backend
//! Provides SIMD-optimized BLAS operations for macOS
//! Uses vDSP and BLAS from the Accelerate framework

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.accelerate);

// ============================================================================
// Accelerate Framework C Bindings (macOS only)
// ============================================================================

const c = if (builtin.os.tag == .macos) struct {
    // cblas_sgemm: Single-precision General Matrix Multiply
    // C = alpha * A * B + beta * C
    extern "c" fn cblas_sgemm(
        Order: c_int, // CblasRowMajor = 101
        TransA: c_int, // CblasNoTrans = 111
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

    // cblas_sgemv: Single-precision General Matrix-Vector Multiply
    // y = alpha * A * x + beta * y
    extern "c" fn cblas_sgemv(
        Order: c_int,
        Trans: c_int,
        M: c_int,
        N: c_int,
        alpha: f32,
        A: [*]const f32,
        lda: c_int,
        x: [*]const f32,
        incx: c_int,
        beta: f32,
        y: [*]f32,
        incy: c_int,
    ) void;

    // vDSP functions for element-wise operations
    extern "c" fn vDSP_vadd(
        __A: [*]const f32,
        __IA: c_long,
        __B: [*]const f32,
        __IB: c_long,
        __C: [*]f32,
        __IC: c_long,
        __N: c_ulong,
    ) void;

    extern "c" fn vDSP_vmul(
        __A: [*]const f32,
        __IA: c_long,
        __B: [*]const f32,
        __IB: c_long,
        __C: [*]f32,
        __IC: c_long,
        __N: c_ulong,
    ) void;

    extern "c" fn vDSP_vdiv(
        __B: [*]const f32, // divisor
        __IB: c_long,
        __A: [*]const f32, // dividend
        __IA: c_long,
        __C: [*]f32,
        __IC: c_long,
        __N: c_ulong,
    ) void;

    extern "c" fn vDSP_dotpr(
        __A: [*]const f32,
        __IA: c_long,
        __B: [*]const f32,
        __IB: c_long,
        __C: *f32,
        __N: c_ulong,
    ) void;

    extern "c" fn vDSP_meanv(
        __A: [*]const f32,
        __IA: c_long,
        __C: *f32,
        __N: c_ulong,
    ) void;

    extern "c" fn vDSP_sve(
        __A: [*]const f32,
        __IA: c_long,
        __C: *f32,
        __N: c_ulong,
    ) void;

    extern "c" fn vDSP_svesq(
        __A: [*]const f32,
        __IA: c_long,
        __C: *f32,
        __N: c_ulong,
    ) void;

    extern "c" fn vDSP_maxv(
        __A: [*]const f32,
        __IA: c_long,
        __C: *f32,
        __N: c_ulong,
    ) void;

    extern "c" fn vDSP_vsmul(
        __A: [*]const f32,
        __IA: c_long,
        __B: *const f32,
        __C: [*]f32,
        __IC: c_long,
        __N: c_ulong,
    ) void;

    extern "c" fn vDSP_vsadd(
        __A: [*]const f32,
        __IA: c_long,
        __B: *const f32,
        __C: [*]f32,
        __IC: c_long,
        __N: c_ulong,
    ) void;

    // CBLAS constants
    const CblasRowMajor: c_int = 101;
    const CblasColMajor: c_int = 102;
    const CblasNoTrans: c_int = 111;
    const CblasTrans: c_int = 112;
} else struct {};

// ============================================================================
// High-Level API
// ============================================================================

/// Check if Accelerate is available
pub fn isAvailable() bool {
    return builtin.os.tag == .macos;
}

/// Matrix-Vector multiply: out[N] = x[K] @ W[K×N]
/// Uses cblas_sgemv which is highly optimized on Apple Silicon
pub fn gemv(out: []f32, x: []const f32, W: []const f32, K: usize, N: usize) void {
    if (comptime builtin.os.tag != .macos) {
        gemvCpu(out, x, W, K, N);
        return;
    }
    
    // cblas_sgemv: y = alpha * A * x + beta * y
    // A is K×N (row-major), x is K, y is N
    // We want out = W^T * x, so use Trans
    c.cblas_sgemv(
        c.CblasRowMajor,
        c.CblasTrans,
        @intCast(K), // M = rows of W
        @intCast(N), // N = cols of W
        1.0, // alpha
        W.ptr,
        @intCast(N), // lda = leading dimension = N
        x.ptr,
        1, // incx
        0.0, // beta
        out.ptr,
        1, // incy
    );
}

/// Row-major strided GEMV: y[M] = A[M x N] * x[N], where each row starts `lda` floats apart.
pub fn gemvStridedNoTrans(out: []f32, A: []const f32, M: usize, N: usize, lda: usize, x: []const f32) void {
    if (comptime builtin.os.tag != .macos) {
        for (0..M) |row| {
            var sum: f32 = 0.0;
            const base = row * lda;
            for (0..N) |col| sum += A[base + col] * x[col];
            out[row] = sum;
        }
        return;
    }

    c.cblas_sgemv(
        c.CblasRowMajor,
        c.CblasNoTrans,
        @intCast(M),
        @intCast(N),
        1.0,
        A.ptr,
        @intCast(lda),
        x.ptr,
        1,
        0.0,
        out.ptr,
        1,
    );
}

/// Row-major strided GEMV: y[N] = A[M x N]^T * x[M], where each row starts `lda` floats apart.
pub fn gemvStridedTrans(out: []f32, A: []const f32, M: usize, N: usize, lda: usize, x: []const f32) void {
    if (comptime builtin.os.tag != .macos) {
        for (0..N) |col| {
            var sum: f32 = 0.0;
            for (0..M) |row| sum += A[row * lda + col] * x[row];
            out[col] = sum;
        }
        return;
    }

    c.cblas_sgemv(
        c.CblasRowMajor,
        c.CblasTrans,
        @intCast(M),
        @intCast(N),
        1.0,
        A.ptr,
        @intCast(lda),
        x.ptr,
        1,
        0.0,
        out.ptr,
        1,
    );
}

/// Matrix multiply: C[M×N] = A[M×K] @ B[K×N]
/// Uses cblas_sgemm which is the gold standard for matmul
pub fn matmul(C: []f32, A: []const f32, B: []const f32, M: usize, N: usize, K: usize) void {
    if (comptime builtin.os.tag != .macos) {
        matmulCpu(C, A, B, M, N, K);
        return;
    }
    
    c.cblas_sgemm(
        c.CblasRowMajor,
        c.CblasNoTrans,
        c.CblasNoTrans,
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
}

/// Vector addition: C = A + B
pub fn vecAdd(C: []f32, A: []const f32, B: []const f32) void {
    if (comptime builtin.os.tag != .macos) {
        for (0..C.len) |i| C[i] = A[i] + B[i];
        return;
    }
    c.vDSP_vadd(A.ptr, 1, B.ptr, 1, C.ptr, 1, @intCast(C.len));
}

/// Vector multiplication: C = A * B (element-wise)
pub fn vecMul(C: []f32, A: []const f32, B: []const f32) void {
    if (comptime builtin.os.tag != .macos) {
        for (0..C.len) |i| C[i] = A[i] * B[i];
        return;
    }
    c.vDSP_vmul(A.ptr, 1, B.ptr, 1, C.ptr, 1, @intCast(C.len));
}

/// Dot product: result = sum(A * B)
pub fn dot(A: []const f32, B: []const f32) f32 {
    if (comptime builtin.os.tag != .macos) {
        var s: f32 = 0;
        for (0..A.len) |i| s += A[i] * B[i];
        return s;
    }
    var result: f32 = 0;
    c.vDSP_dotpr(A.ptr, 1, B.ptr, 1, &result, @intCast(A.len));
    return result;
}

/// Sum of elements
pub fn sum(A: []const f32) f32 {
    if (comptime builtin.os.tag != .macos) {
        var s: f32 = 0;
        for (A) |v| s += v;
        return s;
    }
    var result: f32 = 0;
    c.vDSP_sve(A.ptr, 1, &result, @intCast(A.len));
    return result;
}

/// Sum of squares: result = sum(A^2)
pub fn sumOfSquares(A: []const f32) f32 {
    if (comptime builtin.os.tag != .macos) {
        var s: f32 = 0;
        for (A) |v| s += v * v;
        return s;
    }
    var result: f32 = 0;
    c.vDSP_svesq(A.ptr, 1, &result, @intCast(A.len));
    return result;
}

/// Maximum value
pub fn max(A: []const f32) f32 {
    if (comptime builtin.os.tag != .macos) {
        var m = A[0];
        for (A[1..]) |v| if (v > m) { m = v; };
        return m;
    }
    var result: f32 = 0;
    c.vDSP_maxv(A.ptr, 1, &result, @intCast(A.len));
    return result;
}

/// Scale vector: C = A * scalar
pub fn scale(C: []f32, A: []const f32, scalar: f32) void {
    if (comptime builtin.os.tag != .macos) {
        for (0..C.len) |i| C[i] = A[i] * scalar;
        return;
    }
    c.vDSP_vsmul(A.ptr, 1, &scalar, C.ptr, 1, @intCast(C.len));
}

/// Add scalar: C = A + scalar
pub fn addScalar(C: []f32, A: []const f32, scalar: f32) void {
    if (comptime builtin.os.tag != .macos) {
        for (0..C.len) |i| C[i] = A[i] + scalar;
        return;
    }
    c.vDSP_vsadd(A.ptr, 1, &scalar, C.ptr, 1, @intCast(C.len));
}

// ============================================================================
// CPU Fallback implementations
// ============================================================================

fn gemvCpu(out: []f32, x: []const f32, W: []const f32, K: usize, N: usize) void {
    for (0..N) |j| {
        var s: f32 = 0;
        for (0..K) |k| s += x[k] * W[k * N + j];
        out[j] = s;
    }
}

fn matmulCpu(C: []f32, A: []const f32, B: []const f32, M: usize, N: usize, K: usize) void {
    for (0..M) |i| {
        for (0..N) |j| {
            var s: f32 = 0;
            for (0..K) |k| s += A[i * K + k] * B[k * N + j];
            C[i * N + j] = s;
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "accelerate availability" {
    if (builtin.os.tag == .macos) {
        try std.testing.expect(isAvailable());
    } else {
        try std.testing.expect(!isAvailable());
    }
}

test "gemv basic" {
    var out: [2]f32 = undefined;
    const x = [_]f32{ 1.0, 2.0 };
    const W = [_]f32{ 1.0, 0.0, 0.0, 1.0 }; // 2x2 identity
    gemv(&out, &x, &W, 2, 2);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), out[1], 0.001);
}

test "matmul basic" {
    var C: [4]f32 = undefined;
    const A = [_]f32{ 1.0, 2.0, 3.0, 4.0 }; // 2x2
    const B = [_]f32{ 1.0, 0.0, 0.0, 1.0 }; // 2x2 identity
    matmul(&C, &A, &B, 2, 2, 2);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), C[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), C[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), C[2], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), C[3], 0.001);
}

test "vecAdd basic" {
    var C: [3]f32 = undefined;
    const A = [_]f32{ 1.0, 2.0, 3.0 };
    const B = [_]f32{ 4.0, 5.0, 6.0 };
    vecAdd(&C, &A, &B);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), C[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), C[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 9.0), C[2], 0.001);
}

test "dot product" {
    const A = [_]f32{ 1.0, 2.0, 3.0 };
    const B = [_]f32{ 4.0, 5.0, 6.0 };
    const result = dot(&A, &B);
    try std.testing.expectApproxEqAbs(@as(f32, 32.0), result, 0.001); // 1*4 + 2*5 + 3*6 = 32
}

test "sumOfSquares" {
    const A = [_]f32{ 1.0, 2.0, 3.0 };
    const result = sumOfSquares(&A);
    try std.testing.expectApproxEqAbs(@as(f32, 14.0), result, 0.001); // 1 + 4 + 9 = 14
}
