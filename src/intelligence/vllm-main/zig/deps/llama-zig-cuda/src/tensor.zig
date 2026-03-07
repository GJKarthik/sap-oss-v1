//! Tensor types and operations for LLM inference
//!
//! This module provides GGML-compatible tensor types with:
//! - Multiple data types (F32, F16, Q4_K, Q5_K, Q6_K, Q8_0, etc.)
//! - SIMD-optimized operations
//! - Memory-mapped storage support
//!
//! ## Memory Layout (GGML Convention)
//!
//! Dimensions are stored as `[ne0, ne1, ne2, ne3]` where `ne0` is the
//! **fastest-changing** (innermost/contiguous) dimension. For a matrix:
//!   - `ne0` = number of columns (contiguous in memory)
//!   - `ne1` = number of rows
//!
//! This matches GGML's `ggml_tensor.ne` layout. Strides are computed
//! with `stride[0] = 1` (element stride), `stride[1] = ne0`, etc.
//!
//! Example: `initMatrix(3, 4)` creates a 3-row × 4-column matrix
//! stored as `dims = [4, 3, 1, 1]` with row-major element order.

const std = @import("std");
const Allocator = std.mem.Allocator;
const kernels = @import("kernels.zig");

/// Errors returned by tensor operations
pub const TensorError = error{
    /// Shape mismatch between operands
    ShapeMismatch,
    /// Data type mismatch between operands
    DtypeMismatch,
    /// Tensor dimensions are incompatible for the operation
    IncompatibleDims,
    /// Data size does not match expected size for the type and shape
    InvalidSize,
    /// Operation not supported for this data type
    UnsupportedDtype,
};

/// Data types supported by tensors (GGML-compatible)
/// Values match GGML's `ggml_type` enum in ggml.h.
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

    /// Get the size in bytes for a single element (or block for quantized types).
    /// Values match GGML's type_traits table in ggml.c.
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
            .Q4_0 => 18,  // 1×f16 scale + 16×u8 nibbles = 2+16 = 18 bytes per 32 elems
            .Q4_1 => 20,  // 2×f16 (scale,min) + 16×u8 = 4+16 = 20 bytes per 32 elems
            .Q5_0 => 22,  // 1×f16 + 4×u8 mask + 16×u8 = 22 bytes per 32 elems
            .Q5_1 => 24,  // 2×f16 + 4×u8 mask + 16×u8 = 24 bytes per 32 elems
            .Q8_0 => 34,  // 1×f16 scale + 32×i8 = 2+32 = 34 bytes per 32 elems
            .Q8_1 => 36,  // 2×f16 (scale,sum) + 32×i8 = 4+32 = 36 bytes per 32 elems
            .Q2_K => 84,  // see ggml-quants.h: block_q2_K, 256 elems
            .Q3_K => 110, // see ggml-quants.h: block_q3_K, 256 elems
            .Q4_K => 144, // see ggml-quants.h: block_q4_K, 256 elems
            .Q5_K => 176, // see ggml-quants.h: block_q5_K, 256 elems
            .Q6_K => 210, // see ggml-quants.h: block_q6_K, 256 elems
            .Q8_K => 292, // see ggml-quants.h: block_q8_K, 256 elems
            else => 4,    // Default to F32 size for IQ types
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

    /// Validate that a byte slice has the correct size for n_elements of this type.
    /// Returns error.InvalidSize if the slice is too small.
    pub fn validateSize(self: DataType, data_len: usize, n_elements: usize) TensorError!void {
        const expected = self.bytesFor(n_elements);
        if (data_len < expected) return TensorError.InvalidSize;
    }
};

/// Maximum number of dimensions for a tensor
pub const MAX_DIMS = 4;

/// Tensor shape (up to 4 dimensions)
pub const Shape = struct {
    dims: [MAX_DIMS]usize = .{ 1, 1, 1, 1 },
    n_dims: u8 = 1,

    /// Create a 1-D shape. `n` is the number of elements (ne0).
    pub fn init1D(n: usize) Shape {
        return .{ .dims = .{ n, 1, 1, 1 }, .n_dims = 1 };
    }

    /// Create a 2-D matrix shape.
    /// `rows` = ne1 (number of rows), `cols` = ne0 (number of columns, contiguous).
    /// Stored as dims = [cols, rows, 1, 1] following GGML convention.
    pub fn initMatrix(rows: usize, cols: usize) Shape {
        return .{ .dims = .{ cols, rows, 1, 1 }, .n_dims = 2 };
    }

    /// Deprecated: use `initMatrix` instead. Identical behavior.
    pub const init2D = initMatrix;

    /// Create a 3-D shape. Dimensions are ne0 (fastest), ne1, ne2 (slowest).
    pub fn init3D(ne0: usize, ne1: usize, ne2: usize) Shape {
        return .{ .dims = .{ ne0, ne1, ne2, 1 }, .n_dims = 3 };
    }

    /// Create a 4-D shape. Dimensions are ne0 (fastest) through ne3 (slowest).
    pub fn init4D(ne0: usize, ne1: usize, ne2: usize, ne3: usize) Shape {
        return .{ .dims = .{ ne0, ne1, ne2, ne3 }, .n_dims = 4 };
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
        std.debug.assert(self.dtype == .F32); // called asF32 on non-F32 tensor
        return std.mem.bytesAsSlice(f32, self.data);
    }

    /// Get data as F32 slice (const version)
    pub fn asF32Const(self: Self) []align(1) const f32 {
        std.debug.assert(self.dtype == .F32); // called asF32Const on non-F32 tensor
        return std.mem.bytesAsSlice(f32, self.data);
    }

    /// Get data as F16 slice
    pub fn asF16(self: Self) []align(1) f16 {
        std.debug.assert(self.dtype == .F16); // called asF16 on non-F16 tensor
        return std.mem.bytesAsSlice(f16, self.data);
    }

    /// Checked variant: get data as F32 slice, returning error if dtype is wrong
    pub fn tryAsF32(self: Self) TensorError![]align(1) f32 {
        if (self.dtype != .F32) return TensorError.UnsupportedDtype;
        return std.mem.bytesAsSlice(f32, self.data);
    }

    /// Checked variant: get data as F32 slice (const), returning error if dtype is wrong
    pub fn tryAsF32Const(self: Self) TensorError![]align(1) const f32 {
        if (self.dtype != .F32) return TensorError.UnsupportedDtype;
        return std.mem.bytesAsSlice(f32, self.data);
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

    /// Compute softmax along the last dimension (SIMD-accelerated)
    pub fn softmax(self: *Self) void {
        std.debug.assert(self.dtype == .F32);

        const data = self.asF32();
        const last_dim = self.shape.dims[0];
        const n_rows = self.numel() / last_dim;

        for (0..n_rows) |row| {
            const start = row * last_dim;
            const row_data = data[start .. start + last_dim];
            kernels.softmax(row_data);
        }
    }

    /// Layer normalization (SIMD-accelerated via kernels)
    pub fn layerNorm(self: *Self, eps: f32) void {
        std.debug.assert(self.dtype == .F32);

        const data = self.asF32();
        const last_dim = self.shape.dims[0];
        const n_rows = self.numel() / last_dim;
        const dim_f: f32 = @floatFromInt(last_dim);

        for (0..n_rows) |row| {
            const start = row * last_dim;
            const row_data = data[start .. start + last_dim];

            // SIMD-accelerated mean
            const mean = kernels.vecSum(row_data) / dim_f;

            // SIMD subtract-and-square variance reduction
            const mv: kernels.VecF32 = @splat(mean);
            var var_acc: kernels.VecF32 = @splat(0.0);
            var vi: usize = 0;
            while (vi + kernels.VEC_LEN_F32 <= last_dim) : (vi += kernels.VEC_LEN_F32) {
                const x: kernels.VecF32 = row_data[vi..][0..kernels.VEC_LEN_F32].*;
                const diff = x - mv;
                var_acc = @mulAdd(kernels.VecF32, diff, diff, var_acc);
            }
            var variance = @reduce(.Add, var_acc);
            // Scalar remainder
            while (vi < last_dim) : (vi += 1) {
                const diff = row_data[vi] - mean;
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

    /// RMS normalization (used by LLaMA, SIMD-accelerated via kernels)
    pub fn rmsNorm(self: *Self, eps: f32) void {
        std.debug.assert(self.dtype == .F32);

        const data = self.asF32();
        const last_dim = self.shape.dims[0];
        const n_rows = self.numel() / last_dim;
        const dim_f: f32 = @floatFromInt(last_dim);

        for (0..n_rows) |row| {
            const start = row * last_dim;
            const row_data = data[start .. start + last_dim];

            // SIMD-accelerated sum of squares via dot product
            const sum_sq = kernels.vecDot(row_data, row_data);

            // Normalize with SIMD scale
            const inv_rms = 1.0 / @sqrt(sum_sq / dim_f + eps);
            kernels.vecScale(row_data, row_data, inv_rms);
        }
    }
};

// ============================================================================
// Matrix operations
// ============================================================================

/// Matrix multiplication: C = A @ B (allocates result)
/// A is [M, K], B is [K, N], C is [M, N]
pub fn matmul(allocator: Allocator, a: Tensor, b: Tensor) !Tensor {
    std.debug.assert(a.dtype == .F32 and b.dtype == .F32);
    std.debug.assert(a.shape.n_dims == 2 and b.shape.n_dims == 2);

    const M = a.shape.dims[1];
    const K = a.shape.dims[0];
    const N = b.shape.dims[0];

    std.debug.assert(K == b.shape.dims[1]);

    var c = try Tensor.init(allocator, Shape.initMatrix(M, N), .F32, "matmul_result");
    matmulInto(&c, a, b);
    return c;
}

/// Matrix multiplication into pre-allocated output: C = A @ B
/// Avoids allocation; caller must ensure C has shape [M, N].
pub fn matmulInto(c: *Tensor, a: Tensor, b: Tensor) void {
    std.debug.assert(a.dtype == .F32 and b.dtype == .F32 and c.dtype == .F32);
    std.debug.assert(a.shape.n_dims == 2 and b.shape.n_dims == 2);

    const M = a.shape.dims[1];
    const K = a.shape.dims[0];
    const N = b.shape.dims[0];

    std.debug.assert(K == b.shape.dims[1]);
    std.debug.assert(c.shape.dims[0] == N and c.shape.dims[1] == M);

    kernels.matmul(c.asF32(), a.asF32Const(), b.asF32Const(), M, N, K);
}

/// Matrix-vector multiplication: y = A @ x (allocates result)
/// A is [M, K], x is [K], y is [M]
pub fn matvec(allocator: Allocator, a: Tensor, x: Tensor) !Tensor {
    std.debug.assert(a.dtype == .F32 and x.dtype == .F32);
    std.debug.assert(a.shape.n_dims == 2 and x.shape.n_dims == 1);

    const M = a.shape.dims[1];
    const K = a.shape.dims[0];

    std.debug.assert(K == x.shape.dims[0]);

    var y = try Tensor.init(allocator, Shape.init1D(M), .F32, "matvec_result");
    matvecInto(&y, a, x);
    return y;
}

/// Matrix-vector multiplication into pre-allocated output: y = A @ x
/// Avoids allocation; caller must ensure y has shape [M].
pub fn matvecInto(y: *Tensor, a: Tensor, x: Tensor) void {
    std.debug.assert(a.dtype == .F32 and x.dtype == .F32 and y.dtype == .F32);

    const M = a.shape.dims[1];
    const K = a.shape.dims[0];

    std.debug.assert(K == x.shape.dims[0]);
    std.debug.assert(y.shape.dims[0] == M);

    kernels.matvec(y.asF32(), a.asF32Const(), x.asF32Const(), M, K);
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

test "quantized type sizes" {
    // Verify all K-quant block sizes match GGML
    try std.testing.expectEqual(@as(usize, 84), DataType.Q2_K.blockSize());
    try std.testing.expectEqual(@as(usize, 110), DataType.Q3_K.blockSize());
    try std.testing.expectEqual(@as(usize, 176), DataType.Q5_K.blockSize());
    try std.testing.expectEqual(@as(usize, 210), DataType.Q6_K.blockSize());
    try std.testing.expectEqual(@as(usize, 292), DataType.Q8_K.blockSize());
    try std.testing.expectEqual(@as(usize, 34), DataType.Q8_0.blockSize());
    try std.testing.expectEqual(@as(usize, 36), DataType.Q8_1.blockSize());

    // Block elements
    try std.testing.expectEqual(@as(usize, 32), DataType.Q8_0.blockElements());
    try std.testing.expectEqual(@as(usize, 256), DataType.Q6_K.blockElements());

    // bytesFor
    try std.testing.expectEqual(@as(usize, 144), DataType.Q4_K.bytesFor(256));
    try std.testing.expectEqual(@as(usize, 288), DataType.Q4_K.bytesFor(512));

    // isQuantized
    try std.testing.expect(!DataType.F32.isQuantized());
    try std.testing.expect(!DataType.F16.isQuantized());
    try std.testing.expect(DataType.Q4_K.isQuantized());
    try std.testing.expect(DataType.Q8_0.isQuantized());
}

test "validateSize" {
    // Exact size should pass
    try DataType.F32.validateSize(16, 4);
    // Larger than needed should pass
    try DataType.F32.validateSize(20, 4);
    // Too small should fail
    try std.testing.expectError(TensorError.InvalidSize, DataType.F32.validateSize(12, 4));
    // Quantized type validation
    try DataType.Q4_K.validateSize(144, 256);
    try std.testing.expectError(TensorError.InvalidSize, DataType.Q4_K.validateSize(100, 256));
}

test "initMatrix dimension ordering" {
    // initMatrix(rows=3, cols=4) should store dims = [4, 3, 1, 1]
    const shape = Shape.initMatrix(3, 4);
    try std.testing.expectEqual(@as(usize, 4), shape.dims[0]); // ne0 = cols (fast)
    try std.testing.expectEqual(@as(usize, 3), shape.dims[1]); // ne1 = rows
    try std.testing.expectEqual(@as(usize, 12), shape.numel());

    // init2D is an alias for initMatrix
    const shape2 = Shape.init2D(3, 4);
    try std.testing.expect(shape.eq(shape2));
}

test "matmul correctness" {
    const allocator = std.testing.allocator;

    // A = [[1, 2, 3], [4, 5, 6]] (2x3)
    var a = try Tensor.init(allocator, Shape.initMatrix(2, 3), .F32, "a");
    defer a.deinit();
    const ad = a.asF32();
    ad[0] = 1; ad[1] = 2; ad[2] = 3;
    ad[3] = 4; ad[4] = 5; ad[5] = 6;

    // B = [[7, 8], [9, 10], [11, 12]] (3x2)
    var b = try Tensor.init(allocator, Shape.initMatrix(3, 2), .F32, "b");
    defer b.deinit();
    const bd = b.asF32();
    bd[0] = 7;  bd[1] = 8;
    bd[2] = 9;  bd[3] = 10;
    bd[4] = 11; bd[5] = 12;

    // C = A @ B = [[58, 64], [139, 154]] (2x2)
    var c = try matmul(allocator, a, b);
    defer c.deinit();

    const cd = c.asF32Const();
    try std.testing.expectApproxEqAbs(@as(f32, 58.0), cd[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 64.0), cd[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 139.0), cd[2], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 154.0), cd[3], 0.001);
}

test "matvec correctness" {
    const allocator = std.testing.allocator;

    // A = [[1, 2], [3, 4]] (2x2)
    var a = try Tensor.init(allocator, Shape.initMatrix(2, 2), .F32, "a");
    defer a.deinit();
    const ad = a.asF32();
    ad[0] = 1; ad[1] = 2;
    ad[2] = 3; ad[3] = 4;

    // x = [5, 6]
    var x = try Tensor.init(allocator, Shape.init1D(2), .F32, "x");
    defer x.deinit();
    const xd = x.asF32();
    xd[0] = 5; xd[1] = 6;

    // y = A @ x = [1*5+2*6, 3*5+4*6] = [17, 39]
    var y = try matvec(allocator, a, x);
    defer y.deinit();

    const yd = y.asF32Const();
    try std.testing.expectApproxEqAbs(@as(f32, 17.0), yd[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 39.0), yd[1], 0.001);
}

test "tryAsF32 error handling" {
    const allocator = std.testing.allocator;

    var t = try Tensor.init(allocator, Shape.init1D(4), .F16, "f16_tensor");
    defer t.deinit();

    // Should return error for wrong dtype
    try std.testing.expectError(TensorError.UnsupportedDtype, t.tryAsF32());

    // F32 tensor should succeed
    var t2 = try Tensor.init(allocator, Shape.init1D(4), .F32, "f32_tensor");
    defer t2.deinit();

    const slice = try t2.tryAsF32();
    try std.testing.expectEqual(@as(usize, 4), slice.len);
}