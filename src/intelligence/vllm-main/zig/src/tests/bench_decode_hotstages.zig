//! Decode Hot-Stage Microbenchmark
//!
//! Measures the dominant post-attention decode matmul shapes that now dominate
//! end-to-end throughput on the Metal GGUF runtime:
//!   - recurrent shortconv input projection   (dim -> 3*dim)
//!   - recurrent shortconv output projection  (dim -> dim)
//!   - FFN gate/up pair                       (dim -> ff, dim -> ff)
//!   - FFN down projection                    (ff -> dim)
//!   - LM head projection                     (dim -> vocab)
//!
//! Usage:
//!   zig build bench-decode-hotstages

const std = @import("std");
const builtin = @import("builtin");
const metal_bindings = @import("metal_bindings");
const metal_shaders = @import("metal_shaders");

const BenchResult = struct {
    label: []const u8,
    iterations: usize,
    elapsed_ns: u64,

    fn avgMs(self: BenchResult) f64 {
        if (self.iterations == 0) return 0.0;
        return @as(f64, @floatFromInt(self.elapsed_ns)) / 1e6 / @as(f64, @floatFromInt(self.iterations));
    }

    fn callsPerSecond(self: BenchResult) f64 {
        if (self.elapsed_ns == 0) return 0.0;
        return @as(f64, @floatFromInt(self.iterations)) / (@as(f64, @floatFromInt(self.elapsed_ns)) / 1e9);
    }
};

fn envUsize(allocator: std.mem.Allocator, name: []const u8, default_value: usize) usize {
    const raw = std.process.getEnvVarOwned(allocator, name) catch return default_value;
    defer allocator.free(raw);
    return std.fmt.parseUnsigned(usize, raw, 10) catch default_value;
}

fn fillDeterministic(data: []f32, seed: usize) void {
    for (data, 0..) |*value, idx| {
        const x = @as(f32, @floatFromInt(((idx + seed) % 127))) / 97.0;
        const y = @as(f32, @floatFromInt(((idx * 3 + seed * 7) % 89))) / 211.0;
        value.* = x - y;
    }
}

fn createSharedFloatBuffer(device: metal_bindings.MTLDevice, values: []const f32) !metal_bindings.MTLBuffer {
    const size = values.len * @sizeOf(f32);
    const buffer = metal_bindings.createSharedBuffer(device, @intCast(size)) orelse return error.BufferAllocationFailed;
    errdefer metal_bindings.release(buffer);
    const contents = metal_bindings.getBufferContents(buffer) orelse return error.BufferMapFailed;
    const dst: [*]f32 = @ptrCast(@alignCast(contents));
    @memcpy(dst[0..values.len], values);
    return buffer;
}

fn createSharedByteBuffer(device: metal_bindings.MTLDevice, values: []const u8) !metal_bindings.MTLBuffer {
    const buffer = metal_bindings.createSharedBuffer(device, @intCast(values.len)) orelse return error.BufferAllocationFailed;
    errdefer metal_bindings.release(buffer);
    const contents = metal_bindings.getBufferContents(buffer) orelse return error.BufferMapFailed;
    const dst: [*]u8 = @ptrCast(@alignCast(contents));
    @memcpy(dst[0..values.len], values);
    return buffer;
}

fn createZeroFloatBuffer(device: metal_bindings.MTLDevice, len: usize) !metal_bindings.MTLBuffer {
    const size = len * @sizeOf(f32);
    const buffer = metal_bindings.createSharedBuffer(device, @intCast(size)) orelse return error.BufferAllocationFailed;
    errdefer metal_bindings.release(buffer);
    const contents = metal_bindings.getBufferContents(buffer) orelse return error.BufferMapFailed;
    const dst: [*]f32 = @ptrCast(@alignCast(contents));
    @memset(dst[0..len], 0.0);
    return buffer;
}

fn floatBufferSlice(buffer: metal_bindings.MTLBuffer, len: usize) []f32 {
    const contents = metal_bindings.getBufferContents(buffer) orelse unreachable;
    const ptr: [*]f32 = @ptrCast(@alignCast(contents));
    return ptr[0..len];
}

fn zeroFloatBuffer(buffer: metal_bindings.MTLBuffer, len: usize) void {
    @memset(floatBufferSlice(buffer, len), 0.0);
}

fn q4kRowBytes(k: usize) usize {
    const blocks_per_row = (k + 255) / 256;
    return blocks_per_row * 144;
}

fn createZeroQ4KWeights(allocator: std.mem.Allocator, k: usize, n: usize) ![]u8 {
    const bytes = try allocator.alloc(u8, n * q4kRowBytes(k));
    @memset(bytes, 0);
    return bytes;
}

fn runQ4K(
    lib: *metal_shaders.MetalShaderLibrary,
    x: []const f32,
    x_buf: metal_bindings.MTLBuffer,
    weights: []const u8,
    weight_buf: metal_bindings.MTLBuffer,
    out: []f32,
    out_buf: metal_bindings.MTLBuffer,
    k: usize,
    n: usize,
) !void {
    zeroFloatBuffer(out_buf, n);
    const result = metal_shaders.dispatchVecMatMulQ4K(
        lib,
        x,
        weights,
        weight_buf,
        out,
        x_buf,
        out_buf,
        k,
        n,
    );
    if (!result.success or !result.gpu_utilized) return error.StageDispatchFailed;
}

fn runQ4KForcedKernel(
    lib: *metal_shaders.MetalShaderLibrary,
    x: []const f32,
    x_buf: metal_bindings.MTLBuffer,
    weights: []const u8,
    weight_buf: metal_bindings.MTLBuffer,
    out: []f32,
    out_buf: metal_bindings.MTLBuffer,
    k: usize,
    n: usize,
    kernel: metal_shaders.VecMatKernel,
) !void {
    zeroFloatBuffer(out_buf, n);
    const result = metal_shaders.dispatchVecMatMulQ4KForcedKernel(
        lib,
        x,
        weights,
        weight_buf,
        out,
        x_buf,
        out_buf,
        k,
        n,
        kernel,
    );
    if (!result.success or !result.gpu_utilized) return error.StageDispatchFailed;
}

fn runQ4KAdd(
    lib: *metal_shaders.MetalShaderLibrary,
    x: []const f32,
    x_buf: metal_bindings.MTLBuffer,
    weights: []const u8,
    weight_buf: metal_bindings.MTLBuffer,
    residual: []f32,
    residual_buf: metal_bindings.MTLBuffer,
    k: usize,
    n: usize,
) !void {
    zeroFloatBuffer(residual_buf, n);
    const result = metal_shaders.dispatchVecMatMulQ4KAdd(
        lib,
        x,
        weights,
        weight_buf,
        residual,
        x_buf,
        residual_buf,
        residual,
        residual_buf,
        k,
        n,
    );
    if (!result.success or !result.gpu_utilized) return error.StageDispatchFailed;
}

fn runQ4KPair(
    lib: *metal_shaders.MetalShaderLibrary,
    x: []const f32,
    x_buf: metal_bindings.MTLBuffer,
    weight1: metal_bindings.MTLBuffer,
    out1: []f32,
    out1_buf: metal_bindings.MTLBuffer,
    n1: usize,
    weight2: metal_bindings.MTLBuffer,
    out2: []f32,
    out2_buf: metal_bindings.MTLBuffer,
    n2: usize,
    k: usize,
) !void {
    zeroFloatBuffer(out1_buf, n1);
    zeroFloatBuffer(out2_buf, n2);
    if (!metal_shaders.dispatchVecMatMulQ4KPair(lib, x, x_buf, .{
        .weight1 = weight1,
        .out1 = out1,
        .out1_buf = out1_buf,
        .n1 = n1,
        .weight2 = weight2,
        .out2 = out2,
        .out2_buf = out2_buf,
        .n2 = n2,
        .k = k,
    })) return error.StageDispatchFailed;
}

fn runQ4KBatch2(
    lib: *metal_shaders.MetalShaderLibrary,
    x: []const f32,
    x_buf: metal_bindings.MTLBuffer,
    weight1: metal_bindings.MTLBuffer,
    out1: []f32,
    out1_buf: metal_bindings.MTLBuffer,
    n1: usize,
    weight2: metal_bindings.MTLBuffer,
    out2: []f32,
    out2_buf: metal_bindings.MTLBuffer,
    n2: usize,
    k: usize,
) !void {
    zeroFloatBuffer(out1_buf, n1);
    zeroFloatBuffer(out2_buf, n2);
    const ops = [_]metal_shaders.VecMatOp{
        .{
            .kernel = .q4_k,
            .weight_buf = weight1,
            .out = out1,
            .out_buf = out1_buf,
            .k = k,
            .n = n1,
        },
        .{
            .kernel = .q4_k,
            .weight_buf = weight2,
            .out = out2,
            .out_buf = out2_buf,
            .k = k,
            .n = n2,
        },
    };
    if (!metal_shaders.dispatchVecMatMulBatch(lib, x, x_buf, &ops)) return error.StageDispatchFailed;
}

fn runQ4KTriple(
    lib: *metal_shaders.MetalShaderLibrary,
    x: []const f32,
    x_buf: metal_bindings.MTLBuffer,
    weight1: metal_bindings.MTLBuffer,
    out1: []f32,
    out1_buf: metal_bindings.MTLBuffer,
    n1: usize,
    weight2: metal_bindings.MTLBuffer,
    out2: []f32,
    out2_buf: metal_bindings.MTLBuffer,
    n2: usize,
    weight3: metal_bindings.MTLBuffer,
    out3: []f32,
    out3_buf: metal_bindings.MTLBuffer,
    n3: usize,
    k: usize,
) !void {
    zeroFloatBuffer(out1_buf, n1);
    zeroFloatBuffer(out2_buf, n2);
    zeroFloatBuffer(out3_buf, n3);
    if (!metal_shaders.dispatchVecMatMulQ4KTriple(lib, x, x_buf, .{
        .weight1 = weight1,
        .out1 = out1,
        .out1_buf = out1_buf,
        .n1 = n1,
        .weight2 = weight2,
        .out2 = out2,
        .out2_buf = out2_buf,
        .n2 = n2,
        .weight3 = weight3,
        .out3 = out3,
        .out3_buf = out3_buf,
        .n3 = n3,
        .k = k,
    })) return error.StageDispatchFailed;
}

fn benchmarkQ4KStage(
    label: []const u8,
    lib: *metal_shaders.MetalShaderLibrary,
    x: []const f32,
    x_buf: metal_bindings.MTLBuffer,
    weights: []const u8,
    weight_buf: metal_bindings.MTLBuffer,
    out: []f32,
    out_buf: metal_bindings.MTLBuffer,
    k: usize,
    n: usize,
    iterations: usize,
) !BenchResult {
    try runQ4K(lib, x, x_buf, weights, weight_buf, out, out_buf, k, n);
    const start = std.time.nanoTimestamp();
    for (0..iterations) |_| try runQ4K(lib, x, x_buf, weights, weight_buf, out, out_buf, k, n);
    const elapsed = std.time.nanoTimestamp() - start;
    return .{ .label = label, .iterations = iterations, .elapsed_ns = @intCast(@max(elapsed, 0)) };
}

fn benchmarkQ4KForcedKernelStage(
    label: []const u8,
    lib: *metal_shaders.MetalShaderLibrary,
    x: []const f32,
    x_buf: metal_bindings.MTLBuffer,
    weights: []const u8,
    weight_buf: metal_bindings.MTLBuffer,
    out: []f32,
    out_buf: metal_bindings.MTLBuffer,
    k: usize,
    n: usize,
    iterations: usize,
    kernel: metal_shaders.VecMatKernel,
) !BenchResult {
    try runQ4KForcedKernel(lib, x, x_buf, weights, weight_buf, out, out_buf, k, n, kernel);
    const start = std.time.nanoTimestamp();
    for (0..iterations) |_| try runQ4KForcedKernel(lib, x, x_buf, weights, weight_buf, out, out_buf, k, n, kernel);
    const elapsed = std.time.nanoTimestamp() - start;
    return .{ .label = label, .iterations = iterations, .elapsed_ns = @intCast(@max(elapsed, 0)) };
}

fn benchmarkQ4KAddStage(
    label: []const u8,
    lib: *metal_shaders.MetalShaderLibrary,
    x: []const f32,
    x_buf: metal_bindings.MTLBuffer,
    weights: []const u8,
    weight_buf: metal_bindings.MTLBuffer,
    residual: []f32,
    residual_buf: metal_bindings.MTLBuffer,
    k: usize,
    n: usize,
    iterations: usize,
) !BenchResult {
    try runQ4KAdd(lib, x, x_buf, weights, weight_buf, residual, residual_buf, k, n);
    const start = std.time.nanoTimestamp();
    for (0..iterations) |_| try runQ4KAdd(lib, x, x_buf, weights, weight_buf, residual, residual_buf, k, n);
    const elapsed = std.time.nanoTimestamp() - start;
    return .{ .label = label, .iterations = iterations, .elapsed_ns = @intCast(@max(elapsed, 0)) };
}

fn benchmarkQ4KPairStage(
    label: []const u8,
    lib: *metal_shaders.MetalShaderLibrary,
    x: []const f32,
    x_buf: metal_bindings.MTLBuffer,
    weight1: metal_bindings.MTLBuffer,
    out1: []f32,
    out1_buf: metal_bindings.MTLBuffer,
    n1: usize,
    weight2: metal_bindings.MTLBuffer,
    out2: []f32,
    out2_buf: metal_bindings.MTLBuffer,
    n2: usize,
    k: usize,
    iterations: usize,
) !BenchResult {
    try runQ4KPair(lib, x, x_buf, weight1, out1, out1_buf, n1, weight2, out2, out2_buf, n2, k);
    const start = std.time.nanoTimestamp();
    for (0..iterations) |_| try runQ4KPair(lib, x, x_buf, weight1, out1, out1_buf, n1, weight2, out2, out2_buf, n2, k);
    const elapsed = std.time.nanoTimestamp() - start;
    return .{ .label = label, .iterations = iterations, .elapsed_ns = @intCast(@max(elapsed, 0)) };
}

fn benchmarkQ4KBatch2Stage(
    label: []const u8,
    lib: *metal_shaders.MetalShaderLibrary,
    x: []const f32,
    x_buf: metal_bindings.MTLBuffer,
    weight1: metal_bindings.MTLBuffer,
    out1: []f32,
    out1_buf: metal_bindings.MTLBuffer,
    n1: usize,
    weight2: metal_bindings.MTLBuffer,
    out2: []f32,
    out2_buf: metal_bindings.MTLBuffer,
    n2: usize,
    k: usize,
    iterations: usize,
) !BenchResult {
    try runQ4KBatch2(lib, x, x_buf, weight1, out1, out1_buf, n1, weight2, out2, out2_buf, n2, k);
    const start = std.time.nanoTimestamp();
    for (0..iterations) |_| try runQ4KBatch2(lib, x, x_buf, weight1, out1, out1_buf, n1, weight2, out2, out2_buf, n2, k);
    const elapsed = std.time.nanoTimestamp() - start;
    return .{ .label = label, .iterations = iterations, .elapsed_ns = @intCast(@max(elapsed, 0)) };
}

fn benchmarkQ4KTripleStage(
    label: []const u8,
    lib: *metal_shaders.MetalShaderLibrary,
    x: []const f32,
    x_buf: metal_bindings.MTLBuffer,
    weight1: metal_bindings.MTLBuffer,
    out1: []f32,
    out1_buf: metal_bindings.MTLBuffer,
    n1: usize,
    weight2: metal_bindings.MTLBuffer,
    out2: []f32,
    out2_buf: metal_bindings.MTLBuffer,
    n2: usize,
    weight3: metal_bindings.MTLBuffer,
    out3: []f32,
    out3_buf: metal_bindings.MTLBuffer,
    n3: usize,
    k: usize,
    iterations: usize,
) !BenchResult {
    try runQ4KTriple(lib, x, x_buf, weight1, out1, out1_buf, n1, weight2, out2, out2_buf, n2, weight3, out3, out3_buf, n3, k);
    const start = std.time.nanoTimestamp();
    for (0..iterations) |_| try runQ4KTriple(lib, x, x_buf, weight1, out1, out1_buf, n1, weight2, out2, out2_buf, n2, weight3, out3, out3_buf, n3, k);
    const elapsed = std.time.nanoTimestamp() - start;
    return .{ .label = label, .iterations = iterations, .elapsed_ns = @intCast(@max(elapsed, 0)) };
}

pub fn main() !void {
    if (builtin.os.tag != .macos) {
        std.debug.print("bench-decode-hotstages is only supported on macOS.\n", .{});
        return;
    }

    const allocator = std.heap.page_allocator;
    const dim = envUsize(allocator, "BENCH_HOT_DIM", 2048);
    const ff = envUsize(allocator, "BENCH_HOT_FF", dim * 4);
    const vocab = envUsize(allocator, "BENCH_HOT_VOCAB", 65536);
    const base_iterations = envUsize(allocator, "BENCH_HOT_ITERATIONS", 1200);
    const pair_iterations = @max(base_iterations / 2, 1);
    const lm_iterations = @max(base_iterations / 8, 1);

    var lib = try metal_shaders.MetalShaderLibrary.init(allocator);
    defer lib.deinit();
    try metal_shaders.loadBundledLibrary(lib);
    if (!lib.isReady()) return error.MetalUnavailable;

    const device = lib.device orelse return error.MetalUnavailable;

    const x_dim = try allocator.alloc(f32, dim);
    defer allocator.free(x_dim);
    const x_ff = try allocator.alloc(f32, ff);
    defer allocator.free(x_ff);
    fillDeterministic(x_dim, 11);
    fillDeterministic(x_ff, 29);

    const x_dim_buf = try createSharedFloatBuffer(device, x_dim);
    defer metal_bindings.release(x_dim_buf);
    const x_ff_buf = try createSharedFloatBuffer(device, x_ff);
    defer metal_bindings.release(x_ff_buf);

    const shortconv_in_weights = try createZeroQ4KWeights(allocator, dim, 3 * dim);
    defer allocator.free(shortconv_in_weights);
    const shortconv_row_bytes = q4kRowBytes(dim);
    const shortconv_b_weights = shortconv_in_weights[0 .. dim * shortconv_row_bytes];
    const shortconv_c_weights = shortconv_in_weights[dim * shortconv_row_bytes .. 2 * dim * shortconv_row_bytes];
    const shortconv_x_weights = shortconv_in_weights[2 * dim * shortconv_row_bytes .. 3 * dim * shortconv_row_bytes];
    const shortconv_out_weights = try createZeroQ4KWeights(allocator, dim, dim);
    defer allocator.free(shortconv_out_weights);
    const gate_weights = try createZeroQ4KWeights(allocator, dim, ff);
    defer allocator.free(gate_weights);
    const up_weights = try createZeroQ4KWeights(allocator, dim, ff);
    defer allocator.free(up_weights);
    const ffn_down_weights = try createZeroQ4KWeights(allocator, ff, dim);
    defer allocator.free(ffn_down_weights);
    const lm_head_weights = try createZeroQ4KWeights(allocator, dim, vocab);
    defer allocator.free(lm_head_weights);

    const shortconv_in_buf = try createSharedByteBuffer(device, shortconv_in_weights);
    defer metal_bindings.release(shortconv_in_buf);
    const shortconv_b_buf = try createSharedByteBuffer(device, shortconv_b_weights);
    defer metal_bindings.release(shortconv_b_buf);
    const shortconv_c_buf = try createSharedByteBuffer(device, shortconv_c_weights);
    defer metal_bindings.release(shortconv_c_buf);
    const shortconv_x_buf = try createSharedByteBuffer(device, shortconv_x_weights);
    defer metal_bindings.release(shortconv_x_buf);
    const shortconv_out_buf = try createSharedByteBuffer(device, shortconv_out_weights);
    defer metal_bindings.release(shortconv_out_buf);
    const gate_buf = try createSharedByteBuffer(device, gate_weights);
    defer metal_bindings.release(gate_buf);
    const up_buf = try createSharedByteBuffer(device, up_weights);
    defer metal_bindings.release(up_buf);
    const ffn_down_buf = try createSharedByteBuffer(device, ffn_down_weights);
    defer metal_bindings.release(ffn_down_buf);
    const lm_head_buf = try createSharedByteBuffer(device, lm_head_weights);
    defer metal_bindings.release(lm_head_buf);

    const shortconv_in_out_buf = try createZeroFloatBuffer(device, 3 * dim);
    defer metal_bindings.release(shortconv_in_out_buf);
    const shortconv_in_b_buf = try createZeroFloatBuffer(device, dim);
    defer metal_bindings.release(shortconv_in_b_buf);
    const shortconv_in_c_buf = try createZeroFloatBuffer(device, dim);
    defer metal_bindings.release(shortconv_in_c_buf);
    const shortconv_in_x_buf = try createZeroFloatBuffer(device, dim);
    defer metal_bindings.release(shortconv_in_x_buf);
    const shortconv_out_out_buf = try createZeroFloatBuffer(device, dim);
    defer metal_bindings.release(shortconv_out_out_buf);
    const shortconv_out_add_buf = try createZeroFloatBuffer(device, dim);
    defer metal_bindings.release(shortconv_out_add_buf);
    const gate_out_buf = try createZeroFloatBuffer(device, ff);
    defer metal_bindings.release(gate_out_buf);
    const up_out_buf = try createZeroFloatBuffer(device, ff);
    defer metal_bindings.release(up_out_buf);
    const ffn_down_out_buf = try createZeroFloatBuffer(device, dim);
    defer metal_bindings.release(ffn_down_out_buf);
    const ffn_down_add_buf = try createZeroFloatBuffer(device, dim);
    defer metal_bindings.release(ffn_down_add_buf);
    const lm_head_out_buf = try createZeroFloatBuffer(device, vocab);
    defer metal_bindings.release(lm_head_out_buf);

    const shortconv_in_out = floatBufferSlice(shortconv_in_out_buf, 3 * dim);
    const shortconv_in_b = floatBufferSlice(shortconv_in_b_buf, dim);
    const shortconv_in_c = floatBufferSlice(shortconv_in_c_buf, dim);
    const shortconv_in_x = floatBufferSlice(shortconv_in_x_buf, dim);
    const shortconv_out_out = floatBufferSlice(shortconv_out_out_buf, dim);
    const shortconv_out_add = floatBufferSlice(shortconv_out_add_buf, dim);
    const gate_out = floatBufferSlice(gate_out_buf, ff);
    const up_out = floatBufferSlice(up_out_buf, ff);
    const ffn_down_out = floatBufferSlice(ffn_down_out_buf, dim);
    const ffn_down_add = floatBufferSlice(ffn_down_add_buf, dim);
    const lm_head_out = floatBufferSlice(lm_head_out_buf, vocab);

    const shortconv_in = try benchmarkQ4KStage(
        "shortconv-in-q4k",
        lib,
        x_dim,
        x_dim_buf,
        shortconv_in_weights,
        shortconv_in_buf,
        shortconv_in_out,
        shortconv_in_out_buf,
        dim,
        3 * dim,
        base_iterations,
    );
    const shortconv_in_triple = try benchmarkQ4KTripleStage(
        "shortconv-in-triple",
        lib,
        x_dim,
        x_dim_buf,
        shortconv_b_buf,
        shortconv_in_b,
        shortconv_in_b_buf,
        dim,
        shortconv_c_buf,
        shortconv_in_c,
        shortconv_in_c_buf,
        dim,
        shortconv_x_buf,
        shortconv_in_x,
        shortconv_in_x_buf,
        dim,
        dim,
        base_iterations,
    );
    const shortconv_out = try benchmarkQ4KStage(
        "shortconv-out-q4k",
        lib,
        x_dim,
        x_dim_buf,
        shortconv_out_weights,
        shortconv_out_buf,
        shortconv_out_out,
        shortconv_out_out_buf,
        dim,
        dim,
        base_iterations,
    );
    const shortconv_out_add_stage = try benchmarkQ4KAddStage(
        "shortconv-out+add",
        lib,
        x_dim,
        x_dim_buf,
        shortconv_out_weights,
        shortconv_out_buf,
        shortconv_out_add,
        shortconv_out_add_buf,
        dim,
        dim,
        base_iterations,
    );
    const gate_up_pair = try benchmarkQ4KPairStage(
        "ffn-gateup-pair",
        lib,
        x_dim,
        x_dim_buf,
        gate_buf,
        gate_out,
        gate_out_buf,
        ff,
        up_buf,
        up_out,
        up_out_buf,
        ff,
        dim,
        pair_iterations,
    );
    const gate_up_batch = try benchmarkQ4KBatch2Stage(
        "ffn-gateup-batch",
        lib,
        x_dim,
        x_dim_buf,
        gate_buf,
        gate_out,
        gate_out_buf,
        ff,
        up_buf,
        up_out,
        up_out_buf,
        ff,
        dim,
        pair_iterations,
    );
    const ffn_down = try benchmarkQ4KStage(
        "ffn-down-q4k",
        lib,
        x_ff,
        x_ff_buf,
        ffn_down_weights,
        ffn_down_buf,
        ffn_down_out,
        ffn_down_out_buf,
        ff,
        dim,
        pair_iterations,
    );
    const ffn_down_pair = try benchmarkQ4KForcedKernelStage(
        "ffn-down-pair",
        lib,
        x_ff,
        x_ff_buf,
        ffn_down_weights,
        ffn_down_buf,
        ffn_down_out,
        ffn_down_out_buf,
        ff,
        dim,
        pair_iterations,
        .q4_k_pair,
    );
    const ffn_down_rows2 = try benchmarkQ4KForcedKernelStage(
        "ffn-down-rows2",
        lib,
        x_ff,
        x_ff_buf,
        ffn_down_weights,
        ffn_down_buf,
        ffn_down_out,
        ffn_down_out_buf,
        ff,
        dim,
        pair_iterations,
        .q4_k_rows2,
    );
    const ffn_down_add_stage = try benchmarkQ4KAddStage(
        "ffn-down+add",
        lib,
        x_ff,
        x_ff_buf,
        ffn_down_weights,
        ffn_down_buf,
        ffn_down_add,
        ffn_down_add_buf,
        ff,
        dim,
        pair_iterations,
    );
    const lm_head = try benchmarkQ4KStage(
        "lm-head-q4k",
        lib,
        x_dim,
        x_dim_buf,
        lm_head_weights,
        lm_head_buf,
        lm_head_out,
        lm_head_out_buf,
        dim,
        vocab,
        lm_iterations,
    );
    const lm_head_pair = try benchmarkQ4KForcedKernelStage(
        "lm-head-q4k-pair",
        lib,
        x_dim,
        x_dim_buf,
        lm_head_weights,
        lm_head_buf,
        lm_head_out,
        lm_head_out_buf,
        dim,
        vocab,
        lm_iterations,
        .q4_k_pair,
    );

    std.debug.print("Decode Hot-Stage Microbenchmark\n", .{});
    std.debug.print("dim={} ff={} vocab={} base_iterations={}\n", .{ dim, ff, vocab, base_iterations });
    std.debug.print("weights use synthetic zeroed Q4_K matrices for stable shape timing.\n\n", .{});
    inline for (.{ shortconv_in, shortconv_in_triple, shortconv_out, shortconv_out_add_stage, gate_up_pair, gate_up_batch, ffn_down, ffn_down_pair, ffn_down_rows2, ffn_down_add_stage, lm_head, lm_head_pair }) |result| {
        std.debug.print("  {s:<18} {d:>8.3} ms/call  {d:>9.1} calls/s  (iters={})\n", .{
            result.label,
            result.avgMs(),
            result.callsPerSecond(),
            result.iterations,
        });
    }
}
