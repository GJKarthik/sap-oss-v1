//! Tensor types and operations for LLM inference
//!
//! This module provides GGML-compatible tensor types with:
//! - Multiple data types (F32, F16, Q4_K, Q5_K, Q6_K, Q8_0, etc.)
//! - SIMD-optimized operations
//! - Memory-mapped storage support

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Data types supported by tensors (GGML-compatible)
pub const DataType = enum(u32) {
    F32 = 0,
    F16 = 1,
    Q4_0 = 2,
    Q4_1 = 3,
    Q5_0 = 6,
    Q5_1 = 7,
    Q8_0 = 8,
    Q8_1 = 9,
    Q2_K = 10,
    Q3_K = 11,
    Q4_K = 12,
    Q5_K = 13,
    Q6_K = 14,
    Q8_K = 15,
    IQ2_XXS = 16,
    IQ2_XS = 17,
    IQ3_XXS = 18,
    IQ1_S = 19,
    IQ4_NL = 20,
    IQ3_S = 21,
    IQ2_S = 22,
    IQ4_XS = 23,
    I8 = 24,
    I16 = 25,
    I32 = 26,
    I64 = 27,
    F64 = 28,
    BF16 = 30,

    /// Get the size in bytes for a single element (or block for quantized types)
    pub fn blockSize(self: DataType) usize {
        return switch (self) {
            .F32 => 4,
            .F16 => 2,
            .BF16 => 2,
            .F64 => 8,
            .I8 => 1,
            .I16 => 2,
            .I32 => 4,
            .I64 => 8,
            .Q4_0 => 18, // 32 values in 18 bytes (0.5 bits/value + scale)
            .Q4_1 => 20, // 32 values in 20 bytes
            .Q5_0 => 22,
            .Q5_1 => 24,
            .Q8_0 => 34, // 32 values in 34 bytes
            .Q8_1 => 36,
            .Q2_K => 84, // 256 values
            .Q3_K => 110,
            .Q4_K => 144,
            .Q5_K => 176,
            .Q6_K => 210,
            .Q8_K => 292,
            else => 4, // Default to F32 size
        };
    }

    /// Number of elements per block (for quantized types)
    pub fn blockElements(self: DataType) usize {
        return switch (self) {
            .Q4_0, .Q4_1, .Q5_0, .Q5_1, .Q8_0, .Q8_1 => 32,
            .Q2_K, .Q3_K, .Q4_K, .Q5_K, .Q6_K, .Q8_K => 256,
            else => 1,
        };
    }

    /// Calculate total bytes needed for n elements
    pub fn bytesFor(self: DataType, n_elements: usize) usize {
        const block_elems = self.blockElements();
        const n_blocks = (n_elements + block_elems - 1) / block_elems;
        return n_blocks * self.blockSize();
    }

    /// Check if this is a quantized type
    pub fn isQuantized(self: DataType) bool {
        return switch (self) {
            .F32, .F16, .BF16, .F64, .I8, .I16, .I32, .I64 => false,
            else => true,
        };
    }
};

/// Maximum number of dimensions for a tensor
pub const MAX_DIMS = 4;

/// Tensor shape (up to 4 dimensions)
pub const Shape = struct {
    dims: [MAX_DIMS]usize = .{ 1, 1, 1, 1 },
    n_dims: u8 = 1,

    pub fn init1D(n: usize) Shape {
        return .{ .dims = .{ n, 1, 1, 1 }, .n_dims = 1 };
    }

    pub fn init2D(rows: usize, cols: usize) Shape {
        return .{ .dims = .{ cols, rows, 1, 1 }, .n_dims = 2 };
    }

    pub fn init3D(d0: usize, d1: usize, d2: usize) Shape {
        return .{ .dims = .{ d0, d1, d2, 1 }, .n_dims = 3 };
    }

    pub fn init4D(d0: usize, d1: usize, d2: usize, d3: usize) Shape {
        return .{ .dims = .{ d0, d1, d2, d3 }, .n_dims = 4 };
    }

    /// Total number of elements
    pub fn numel(self: Shape) usize {
        var result: usize = 1;
        for (0..self.n_dims) |i| {
            result *= self.dims[i];
        }
        return result;
    }

    /// Get stride for each dimension (row-major)
    pub fn strides(self: Shape) [MAX_DIMS]usize {
        var result: [MAX_DIMS]usize = .{ 1, 1, 1, 1 };
        var stride: usize = 1;
        for (0..self.n_dims) |i| {
            result[i] = stride;
            stride *= self.dims[i];
        }
        return result;
    }

    pub fn eq(self: Shape, other: Shape) bool {
        if (self.n_dims != other.n_dims) return false;
        for (0..self.n_dims) |i| {
            if (self.dims[i] != other.dims[i]) return false;
        }
        return true;
    }
};

/// A multi-dimensional tensor with optional quantization
pub const Tensor = struct {
    /// Shape of the tensor
    shape: Shape,
    /// Data type
    dtype: DataType,
    /// Raw data storage
    data: []u8,
    /// Name (for debugging/GGUF)
    name: []const u8,
    /// Whether we own the data (should free on deinit)
    owns_data: bool,
    /// Allocator used (if owns_data)
    allocator: ?Allocator,

    const Self = @This();

    /// Create a new tensor with allocated storage
    pub fn init(allocator: Allocator, shape: Shape, dtype: DataType, name: []const u8) !Self {
        const n_bytes = dtype.bytesFor(shape.numel());
        const data = try allocator.alloc(u8, n_bytes);
        @memset(data, 0);

        return Self{
            .shape = shape,
            .dtype = dtype,
            .data = data,
            .name = name,
            .owns_data = true,
            .allocator = allocator,
        };
    }

    /// Create a tensor view over existing data (does not own data)
    pub fn view(data: []u8, shape: Shape, dtype: DataType, name: []const u8) Self {
        return Self{
            .shape = shape,
            .dtype = dtype,
            .data = data,
            .name = name,
            .owns_data = false,
            .allocator = null,
        };
    }

    /// Free tensor data if owned
    pub fn deinit(self: *Self) void {
        if (self.owns_data) {
            if (self.allocator) |alloc| {
                alloc.free(self.data);
            }
        }
        self.data = &.{};
    }

    /// Number of elements
    pub fn numel(self: Self) usize {
        return self.shape.numel();
    }

    /// Size in bytes
    pub fn sizeBytes(self: Self) usize {
        return self.data.len;
    }

    /// Get data as F32 slice (only valid for F32 tensors)
    pub fn asF32(self: Self) []align(1) f32 {
        std.debug.assert(self.dtype == .F32);
        return std.mem.bytesAsSlice(f32, self.data);
    }

    /// Get data as F32 slice (const version)
    pub fn asF32Const(self: Self) []align(1) const f32 {
        std.debug.assert(self.dtype == .F32);
        return std.mem.bytesAsSlice(f32, self.data);
    }

    /// Get data as F16 slice
    pub fn asF16(self: Self) []align(1) f16 {
        std.debug.assert(self.dtype == .F16);
        return std.mem.bytesAsSlice(f16, self.data);
    }

    /// Copy data from another tensor (must have same shape and dtype)
    pub fn copyFrom(self: *Self, other: Self) void {
        std.debug.assert(self.shape.eq(other.shape));
        std.debug.assert(self.dtype == other.dtype);
        @memcpy(self.data, other.data);
    }

    /// Fill with a constant value (F32 only)
    pub fn fill(self: *Self, value: f32) void {
        const slice = self.asF32();
        @memset(slice, value);
    }

    /// Element-wise addition: self = self + other
    pub fn add(self: *Self, other: Self) void {
        std.debug.assert(self.dtype == .F32 and other.dtype == .F32);
        std.debug.assert(self.shape.eq(other.shape));

        const a = self.asF32();
        const b = other.asF32Const();

        // SIMD-optimized addition
        const vec_len = std.simd.suggestVectorLength(f32) orelse 4;
        const Vec = @Vector(vec_len, f32);

        var i: usize = 0;
        while (i + vec_len <= a.len) : (i += vec_len) {
            const va: Vec = a[i..][0..vec_len].*;
            const vb: Vec = b[i..][0..vec_len].*;
            a[i..][0..vec_len].* = va + vb;
        }

        // Handle remainder
        while (i < a.len) : (i += 1) {
            a[i] += b[i];
        }
    }

    /// Element-wise multiplication: self = self * other
    pub fn mul(self: *Self, other: Self) void {
        std.debug.assert(self.dtype == .F32 and other.dtype == .F32);
        std.debug.assert(self.shape.eq(other.shape));

        const a = self.asF32();
        const b = other.asF32Const();

        const vec_len = std.simd.suggestVectorLength(f32) orelse 4;
        const Vec = @Vector(vec_len, f32);

        var i: usize = 0;
        while (i + vec_len <= a.len) : (i += vec_len) {
            const va: Vec = a[i..][0..vec_len].*;
            const vb: Vec = b[i..][0..vec_len].*;
            a[i..][0..vec_len].* = va * vb;
        }

        while (i < a.len) : (i += 1) {
            a[i] *= b[i];
        }
    }

    /// Scale by a constant: self = self * scale
    pub fn scale(self: *Self, s: f32) void {
        std.debug.assert(self.dtype == .F32);

        const a = self.asF32();
        const vec_len = std.simd.suggestVectorLength(f32) orelse 4;
        const Vec = @Vector(vec_len, f32);
        const sv: Vec = @splat(s);

        var i: usize = 0;
        while (i + vec_len <= a.len) : (i += vec_len) {
            const va: Vec = a[i..][0..vec_len].*;
            a[i..][0..vec_len].* = va * sv;
        }

        while (i < a.len) : (i += 1) {
            a[i] *= s;
        }
    }

    /// Compute softmax along the last dimension
    pub fn softmax(self: *Self) void {
        std.debug.assert(self.dtype == .F32);

        const data = self.asF32();
        const last_dim = self.shape.dims[0];
        const n_rows = self.numel() / last_dim;

        for (0..n_rows) |row| {
            const start = row * last_dim;
            const row_data = data[start .. start + last_dim];

            // Find max for numerical stability
            var max_val: f32 = row_data[0];
            for (row_data[1..]) |v| {
                if (v > max_val) max_val = v;
            }

            // Compute exp and sum
            var sum: f32 = 0;
            for (row_data) |*v| {
                v.* = @exp(v.* - max_val);
                sum += v.*;
            }

            // Normalize
            const inv_sum = 1.0 / sum;
            for (row_data) |*v| {
                v.* *= inv_sum;
            }
        }
    }

    /// Layer normalization
    pub fn layerNorm(self: *Self, eps: f32) void {
        std.debug.assert(self.dtype == .F32);

        const data = self.asF32();
        const last_dim = self.shape.dims[0];
        const n_rows = self.numel() / last_dim;
        const dim_f: f32 = @floatFromInt(last_dim);

        for (0..n_rows) |row| {
            const start = row * last_dim;
            const row_data = data[start .. start + last_dim];

            // Compute mean
            var mean: f32 = 0;
            for (row_data) |v| {
                mean += v;
            }
            mean /= dim_f;

            // Compute variance
            var variance: f32 = 0;
            for (row_data) |v| {
                const diff = v - mean;
                variance += diff * diff;
            }
            variance /= dim_f;

            // Normalize
            const inv_std = 1.0 / @sqrt(variance + eps);
            for (row_data) |*v| {
                v.* = (v.* - mean) * inv_std;
            }
        }
    }

    /// RMS normalization (used by LLaMA)
    pub fn rmsNorm(self: *Self, eps: f32) void {
        std.debug.assert(self.dtype == .F32);

        const data = self.asF32();
        const last_dim = self.shape.dims[0];
        const n_rows = self.numel() / last_dim;
        const dim_f: f32 = @floatFromInt(last_dim);

        for (0..n_rows) |row| {
            const start = row * last_dim;
            const row_data = data[start .. start + last_dim];

            // Compute sum of squares
            var sum_sq: f32 = 0;
            for (row_data) |v| {
                sum_sq += v * v;
            }

            // Normalize
            const inv_rms = 1.0 / @sqrt(sum_sq / dim_f + eps);
            for (row_data) |*v| {
                v.* *= inv_rms;
            }
        }
    }
};

// ============================================================================
// Matrix operations
// ============================================================================

/// Matrix multiplication: C = A @ B
/// A is [M, K], B is [K, N], C is [M, N]
pub fn matmul(allocator: Allocator, a: Tensor, b: Tensor) !Tensor {
    std.debug.assert(a.dtype == .F32 and b.dtype == .F32);
    std.debug.assert(a.shape.n_dims == 2 and b.shape.n_dims == 2);

    const M = a.shape.dims[1]; // rows of A
    const K = a.shape.dims[0]; // cols of A = rows of B
    const N = b.shape.dims[0]; // cols of B

    std.debug.assert(K == b.shape.dims[1]);

    var c = try Tensor.init(allocator, Shape.init2D(M, N), .F32, "matmul_result");

    const a_data = a.asF32Const();
    const b_data = b.asF32Const();
    const c_data = c.asF32();

    // Simple O(M*N*K) matmul - can be optimized with tiling/SIMD
    for (0..M) |i| {
        for (0..N) |j| {
            var sum: f32 = 0;
            for (0..K) |k| {
                sum += a_data[i * K + k] * b_data[k * N + j];
            }
            c_data[i * N + j] = sum;
        }
    }

    return c;
}

/// Matrix-vector multiplication: y = A @ x
/// A is [M, K], x is [K], y is [M]
pub fn matvec(allocator: Allocator, a: Tensor, x: Tensor) !Tensor {
    std.debug.assert(a.dtype == .F32 and x.dtype == .F32);
    std.debug.assert(a.shape.n_dims == 2 and x.shape.n_dims == 1);

    const M = a.shape.dims[1];
    const K = a.shape.dims[0];

    std.debug.assert(K == x.shape.dims[0]);

    var y = try Tensor.init(allocator, Shape.init1D(M), .F32, "matvec_result");

    const a_data = a.asF32Const();
    const x_data = x.asF32Const();
    const y_data = y.asF32();

    const vec_len = std.simd.suggestVectorLength(f32) orelse 4;
    const Vec = @Vector(vec_len, f32);

    for (0..M) |i| {
        var sum: f32 = 0;
        const row_start = i * K;

        // SIMD inner product
        var k: usize = 0;
        var vec_sum: Vec = @splat(0);
        while (k + vec_len <= K) : (k += vec_len) {
            const va: Vec = a_data[row_start + k ..][0..vec_len].*;
            const vx: Vec = x_data[k..][0..vec_len].*;
            vec_sum += va * vx;
        }
        sum = @reduce(.Add, vec_sum);

        // Handle remainder
        while (k < K) : (k += 1) {
            sum += a_data[row_start + k] * x_data[k];
        }

        y_data[i] = sum;
    }

    return y;
}

// ============================================================================
// Tests
// ============================================================================

test "tensor creation" {
    const allocator = std.testing.allocator;

    var t = try Tensor.init(allocator, Shape.init2D(3, 4), .F32, "test");
    defer t.deinit();

    try std.testing.expectEqual(@as(usize, 12), t.numel());
    try std.testing.expectEqual(@as(usize, 48), t.sizeBytes());
}

test "tensor operations" {
    const allocator = std.testing.allocator;

    var a = try Tensor.init(allocator, Shape.init1D(4), .F32, "a");
    defer a.deinit();
    var b = try Tensor.init(allocator, Shape.init1D(4), .F32, "b");
    defer b.deinit();

    const a_data = a.asF32();
    const b_data = b.asF32();

    a_data[0] = 1.0;
    a_data[1] = 2.0;
    a_data[2] = 3.0;
    a_data[3] = 4.0;

    b_data[0] = 5.0;
    b_data[1] = 6.0;
    b_data[2] = 7.0;
    b_data[3] = 8.0;

    a.add(b);

    try std.testing.expectApproxEqAbs(@as(f32, 6.0), a_data[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), a_data[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), a_data[2], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 12.0), a_data[3], 0.001);
}

test "softmax" {
    const allocator = std.testing.allocator;

    var t = try Tensor.init(allocator, Shape.init1D(4), .F32, "t");
    defer t.deinit();

    const data = t.asF32();
    data[0] = 1.0;
    data[1] = 2.0;
    data[2] = 3.0;
    data[3] = 4.0;

    t.softmax();

    // Check that values sum to 1
    var sum: f32 = 0;
    for (data) |v| {
        sum += v;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sum, 0.001);

    // Check that values are in ascending order (since inputs were)
    try std.testing.expect(data[0] < data[1]);
    try std.testing.expect(data[1] < data[2]);
    try std.testing.expect(data[2] < data[3]);
}

test "data type sizes" {
    try std.testing.expectEqual(@as(usize, 4), DataType.F32.blockSize());
    try std.testing.expectEqual(@as(usize, 2), DataType.F16.blockSize());
    try std.testing.expectEqual(@as(usize, 144), DataType.Q4_K.blockSize());
    try std.testing.expectEqual(@as(usize, 256), DataType.Q4_K.blockElements());
}