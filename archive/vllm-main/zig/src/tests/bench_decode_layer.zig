//! Decode Layer Microbenchmark
//!
//! Measures decode attention plus the output projection (`wo`) so the next
//! bottleneck after fused attention is visible directly.
//!
//! Usage:
//!   zig build bench-decode-layer

const std = @import("std");
const builtin = @import("builtin");
const metal_bindings = @import("metal_bindings");
const metal_shaders = @import("metal_shaders");

const BenchCase = struct {
    label: []const u8,
    seq_len: usize,
    attn_iterations: usize,
    layer_iterations: usize,
};

const BenchResult = struct {
    label: []const u8,
    iterations: usize,
    elapsed_ns: u64,
    attn_max_abs_diff: f32,

    fn avgMs(self: BenchResult) f64 {
        if (self.iterations == 0) return 0.0;
        return @as(f64, @floatFromInt(self.elapsed_ns)) / 1e6 / @as(f64, @floatFromInt(self.iterations));
    }

    fn callsPerSecond(self: BenchResult) f64 {
        if (self.elapsed_ns == 0) return 0.0;
        return @as(f64, @floatFromInt(self.iterations)) / (@as(f64, @floatFromInt(self.elapsed_ns)) / 1e9);
    }
};

fn modeLabel(mode: metal_shaders.AttentionDecodeMode) []const u8 {
    return switch (mode) {
        .auto => "auto",
        .split => "split+wo",
        .fused_single => "fused-single+wo",
        .fused_heads => "fused-heads+wo",
    };
}

fn envUsize(allocator: std.mem.Allocator, name: []const u8, default_value: usize) usize {
    const raw = std.process.getEnvVarOwned(allocator, name) catch return default_value;
    defer allocator.free(raw);
    return std.fmt.parseUnsigned(usize, raw, 10) catch default_value;
}

fn fillDeterministic(data: []f32, seed: usize) void {
    for (data, 0..) |*value, idx| {
        const x = @as(f32, @floatFromInt(((idx + seed) % 127))) / 101.0;
        const y = @as(f32, @floatFromInt(((idx * 5 + seed * 11) % 79))) / 173.0;
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

fn createSharedHalfBuffer(device: metal_bindings.MTLDevice, values: []const f16) !metal_bindings.MTLBuffer {
    const size = values.len * @sizeOf(f16);
    const buffer = metal_bindings.createSharedBuffer(device, @intCast(size)) orelse return error.BufferAllocationFailed;
    errdefer metal_bindings.release(buffer);
    const contents = metal_bindings.getBufferContents(buffer) orelse return error.BufferMapFailed;
    const dst: [*]f16 = @ptrCast(@alignCast(contents));
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

fn cpuDecodeAttention(
    out: []f32,
    q: []const f32,
    k_cache: []const f32,
    v_cache: []const f32,
    seq_len: usize,
    head_dim: usize,
    n_heads: usize,
    heads_per_group: usize,
    kv_stride: usize,
    scale: f32,
) void {
    @memset(out, 0.0);
    var scores_buf = std.heap.page_allocator.alloc(f32, seq_len) catch unreachable;
    defer std.heap.page_allocator.free(scores_buf);

    for (0..n_heads) |h| {
        const kv_h = h / heads_per_group;
        const q_head = q[h * head_dim ..][0..head_dim];
        for (0..seq_len) |t| {
            const k_vec = k_cache[t * kv_stride + kv_h * head_dim ..][0..head_dim];
            var dot: f32 = 0.0;
            for (0..head_dim) |d| dot += q_head[d] * k_vec[d];
            scores_buf[t] = dot * scale;
        }

        var max_score = -std.math.inf(f32);
        for (scores_buf[0..seq_len]) |score| max_score = @max(max_score, score);

        var sum: f32 = 0.0;
        for (scores_buf[0..seq_len]) |*score| {
            score.* = @exp(score.* - max_score);
            sum += score.*;
        }
        const inv_sum: f32 = 1.0 / sum;
        for (scores_buf[0..seq_len]) |*score| score.* *= inv_sum;

        const out_head = out[h * head_dim ..][0..head_dim];
        for (0..seq_len) |t| {
            const v_vec = v_cache[t * kv_stride + kv_h * head_dim ..][0..head_dim];
            const weight = scores_buf[t];
            for (0..head_dim) |d| out_head[d] += weight * v_vec[d];
        }
    }
}

fn maxAbsDiff(a: []const f32, b: []const f32) f32 {
    var max_diff: f32 = 0.0;
    for (a, b) |lhs, rhs| max_diff = @max(max_diff, @abs(lhs - rhs));
    return max_diff;
}

fn runAttention(
    lib: *metal_shaders.MetalShaderLibrary,
    mode: metal_shaders.AttentionDecodeMode,
    q_buf: metal_bindings.MTLBuffer,
    attn_out_buf: metal_bindings.MTLBuffer,
    k_buf: metal_bindings.MTLBuffer,
    v_buf: metal_bindings.MTLBuffer,
    seq_len: usize,
    head_dim: usize,
    n_heads: usize,
    heads_per_group: usize,
    kv_stride: usize,
    scale: f32,
) !void {
    zeroFloatBuffer(attn_out_buf, n_heads * head_dim);
    if (!metal_shaders.dispatchAttentionDecodeHeads(lib, .{
        .q_buf = q_buf,
        .out_buf = attn_out_buf,
        .k_cache_buf = k_buf,
        .v_cache_buf = v_buf,
        .seq_len = seq_len,
        .head_dim = head_dim,
        .n_heads = n_heads,
        .heads_per_group = heads_per_group,
        .kv_stride = kv_stride,
        .scale = scale,
        .mode = mode,
    })) return error.AttentionDispatchFailed;
}

fn runProjectionQ4K(
    lib: *metal_shaders.MetalShaderLibrary,
    x: []const f32,
    x_buf: metal_bindings.MTLBuffer,
    wo_bytes: []const u8,
    wo_buf: metal_bindings.MTLBuffer,
    out: []f32,
    out_buf: metal_bindings.MTLBuffer,
    dim: usize,
) !void {
    zeroFloatBuffer(out_buf, dim);
    const result = metal_shaders.dispatchVecMatMulQ4K(
        lib,
        x,
        wo_bytes,
        wo_buf,
        out,
        x_buf,
        out_buf,
        dim,
        dim,
    );
    if (!result.success or !result.gpu_utilized) return error.ProjectionDispatchFailed;
}

fn runProjectionF16(
    lib: *metal_shaders.MetalShaderLibrary,
    x: []const f32,
    x_buf: metal_bindings.MTLBuffer,
    wo_f16: []const f16,
    wo_f16_buf: metal_bindings.MTLBuffer,
    out: []f32,
    out_buf: metal_bindings.MTLBuffer,
    dim: usize,
) !void {
    zeroFloatBuffer(out_buf, dim);
    const result = metal_shaders.dispatchVecMatMulF16ColMajor(
        lib,
        x,
        wo_f16,
        wo_f16_buf,
        out,
        x_buf,
        out_buf,
        dim,
        dim,
    );
    if (!result.success or !result.gpu_utilized) return error.ProjectionDispatchFailed;
}

fn runAttentionProjectionChain(
    lib: *metal_shaders.MetalShaderLibrary,
    q_buf: metal_bindings.MTLBuffer,
    attn_out_buf: metal_bindings.MTLBuffer,
    hidden_buf: metal_bindings.MTLBuffer,
    k_buf: metal_bindings.MTLBuffer,
    v_buf: metal_bindings.MTLBuffer,
    wo_buf: metal_bindings.MTLBuffer,
    seq_len: usize,
    head_dim: usize,
    n_heads: usize,
    heads_per_group: usize,
    kv_stride: usize,
    scale: f32,
) !void {
    if (!metal_shaders.dispatchAttentionDecodeHeadsQ4KAdd(lib, .{
        .q_buf = q_buf,
        .attn_out_buf = attn_out_buf,
        .k_cache_buf = k_buf,
        .v_cache_buf = v_buf,
        .weight_buf = wo_buf,
        .residual_buf = hidden_buf,
        .out_buf = hidden_buf,
        .seq_len = seq_len,
        .head_dim = head_dim,
        .n_heads = n_heads,
        .heads_per_group = heads_per_group,
        .kv_stride = kv_stride,
        .scale = scale,
        .k = n_heads * head_dim,
        .n = n_heads * head_dim,
    })) return error.AttentionDispatchFailed;
}

fn benchmarkProjectionOnly(
    lib: *metal_shaders.MetalShaderLibrary,
    x: []const f32,
    x_buf: metal_bindings.MTLBuffer,
    wo_bytes: []const u8,
    wo_buf: metal_bindings.MTLBuffer,
    out: []f32,
    out_buf: metal_bindings.MTLBuffer,
    dim: usize,
    iterations: usize,
) !BenchResult {
    try runProjectionQ4K(lib, x, x_buf, wo_bytes, wo_buf, out, out_buf, dim);
    const start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        try runProjectionQ4K(lib, x, x_buf, wo_bytes, wo_buf, out, out_buf, dim);
    }
    const elapsed = std.time.nanoTimestamp() - start;
    return .{
        .label = "wo-q4k",
        .iterations = iterations,
        .elapsed_ns = @intCast(@max(elapsed, 0)),
        .attn_max_abs_diff = 0.0,
    };
}

fn benchmarkProjectionOnlyF16(
    lib: *metal_shaders.MetalShaderLibrary,
    x: []const f32,
    x_buf: metal_bindings.MTLBuffer,
    wo_f16: []const f16,
    wo_f16_buf: metal_bindings.MTLBuffer,
    out: []f32,
    out_buf: metal_bindings.MTLBuffer,
    dim: usize,
    iterations: usize,
) !BenchResult {
    try runProjectionF16(lib, x, x_buf, wo_f16, wo_f16_buf, out, out_buf, dim);
    const start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        try runProjectionF16(lib, x, x_buf, wo_f16, wo_f16_buf, out, out_buf, dim);
    }
    const elapsed = std.time.nanoTimestamp() - start;
    return .{
        .label = "wo-f16",
        .iterations = iterations,
        .elapsed_ns = @intCast(@max(elapsed, 0)),
        .attn_max_abs_diff = 0.0,
    };
}

fn benchmarkLayerMode(
    lib: *metal_shaders.MetalShaderLibrary,
    mode: metal_shaders.AttentionDecodeMode,
    q_buf: metal_bindings.MTLBuffer,
    attn_out_buf: metal_bindings.MTLBuffer,
    proj_out_buf: metal_bindings.MTLBuffer,
    k_buf: metal_bindings.MTLBuffer,
    v_buf: metal_bindings.MTLBuffer,
    wo_bytes: []const u8,
    wo_buf: metal_bindings.MTLBuffer,
    expected_attention: []const f32,
    seq_len: usize,
    head_dim: usize,
    n_heads: usize,
    heads_per_group: usize,
    kv_stride: usize,
    scale: f32,
    iterations: usize,
) !BenchResult {
    const dim = n_heads * head_dim;
    const attn_out = floatBufferSlice(attn_out_buf, dim);
    const proj_out = floatBufferSlice(proj_out_buf, dim);

    try runAttention(lib, mode, q_buf, attn_out_buf, k_buf, v_buf, seq_len, head_dim, n_heads, heads_per_group, kv_stride, scale);
    const diff = maxAbsDiff(expected_attention, attn_out);
    try runProjectionQ4K(lib, attn_out, attn_out_buf, wo_bytes, wo_buf, proj_out, proj_out_buf, dim);

    const start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        try runAttention(lib, mode, q_buf, attn_out_buf, k_buf, v_buf, seq_len, head_dim, n_heads, heads_per_group, kv_stride, scale);
        try runProjectionQ4K(lib, attn_out, attn_out_buf, wo_bytes, wo_buf, proj_out, proj_out_buf, dim);
    }
    const elapsed = std.time.nanoTimestamp() - start;
    return .{
        .label = modeLabel(mode),
        .iterations = iterations,
        .elapsed_ns = @intCast(@max(elapsed, 0)),
        .attn_max_abs_diff = diff,
    };
}

fn benchmarkFusedHeadsLayerF16(
    lib: *metal_shaders.MetalShaderLibrary,
    q_buf: metal_bindings.MTLBuffer,
    attn_out_buf: metal_bindings.MTLBuffer,
    proj_out_buf: metal_bindings.MTLBuffer,
    k_buf: metal_bindings.MTLBuffer,
    v_buf: metal_bindings.MTLBuffer,
    wo_f16: []const f16,
    wo_f16_buf: metal_bindings.MTLBuffer,
    expected_attention: []const f32,
    seq_len: usize,
    head_dim: usize,
    n_heads: usize,
    heads_per_group: usize,
    kv_stride: usize,
    scale: f32,
    iterations: usize,
) !BenchResult {
    const dim = n_heads * head_dim;
    const attn_out = floatBufferSlice(attn_out_buf, dim);
    const proj_out = floatBufferSlice(proj_out_buf, dim);

    try runAttention(lib, .fused_heads, q_buf, attn_out_buf, k_buf, v_buf, seq_len, head_dim, n_heads, heads_per_group, kv_stride, scale);
    const diff = maxAbsDiff(expected_attention, attn_out);
    try runProjectionF16(lib, attn_out, attn_out_buf, wo_f16, wo_f16_buf, proj_out, proj_out_buf, dim);

    const start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        try runAttention(lib, .fused_heads, q_buf, attn_out_buf, k_buf, v_buf, seq_len, head_dim, n_heads, heads_per_group, kv_stride, scale);
        try runProjectionF16(lib, attn_out, attn_out_buf, wo_f16, wo_f16_buf, proj_out, proj_out_buf, dim);
    }
    const elapsed = std.time.nanoTimestamp() - start;
    return .{
        .label = "fused-heads+wo-f16",
        .iterations = iterations,
        .elapsed_ns = @intCast(@max(elapsed, 0)),
        .attn_max_abs_diff = diff,
    };
}

fn benchmarkFusedHeadsLayerChain(
    lib: *metal_shaders.MetalShaderLibrary,
    q_buf: metal_bindings.MTLBuffer,
    attn_out_buf: metal_bindings.MTLBuffer,
    hidden_buf: metal_bindings.MTLBuffer,
    k_buf: metal_bindings.MTLBuffer,
    v_buf: metal_bindings.MTLBuffer,
    wo_buf: metal_bindings.MTLBuffer,
    residual_seed: []const f32,
    expected_residual: []const f32,
    seq_len: usize,
    head_dim: usize,
    n_heads: usize,
    heads_per_group: usize,
    kv_stride: usize,
    scale: f32,
    iterations: usize,
) !BenchResult {
    const dim = n_heads * head_dim;
    const hidden = floatBufferSlice(hidden_buf, dim);

    @memcpy(hidden[0..dim], residual_seed[0..dim]);
    try runAttentionProjectionChain(lib, q_buf, attn_out_buf, hidden_buf, k_buf, v_buf, wo_buf, seq_len, head_dim, n_heads, heads_per_group, kv_stride, scale);
    const diff = maxAbsDiff(expected_residual, hidden);

    const start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        @memcpy(hidden[0..dim], residual_seed[0..dim]);
        try runAttentionProjectionChain(lib, q_buf, attn_out_buf, hidden_buf, k_buf, v_buf, wo_buf, seq_len, head_dim, n_heads, heads_per_group, kv_stride, scale);
    }
    const elapsed = std.time.nanoTimestamp() - start;
    return .{
        .label = "fused-heads+wo-chain",
        .iterations = iterations,
        .elapsed_ns = @intCast(@max(elapsed, 0)),
        .attn_max_abs_diff = diff,
    };
}

pub fn main() !void {
    if (builtin.os.tag != .macos) {
        std.debug.print("bench-decode-layer is only supported on macOS.\n", .{});
        return;
    }

    const allocator = std.heap.page_allocator;
    const n_heads = envUsize(allocator, "BENCH_LAYER_HEADS", 32);
    const head_dim = envUsize(allocator, "BENCH_LAYER_HEAD_DIM", 64);
    const heads_per_group = envUsize(allocator, "BENCH_LAYER_HEADS_PER_GROUP", 1);
    if (heads_per_group == 0 or n_heads % heads_per_group != 0) return error.InvalidHeadGrouping;
    const kv_heads = n_heads / heads_per_group;
    const kv_stride = kv_heads * head_dim;
    const dim = n_heads * head_dim;
    const scale: f32 = 1.0 / @sqrt(@as(f32, @floatFromInt(head_dim)));

    var lib = try metal_shaders.MetalShaderLibrary.init(allocator);
    defer lib.deinit();
    try metal_shaders.loadBundledLibrary(lib);
    if (!lib.isReady()) return error.MetalUnavailable;

    const device = lib.device orelse return error.MetalUnavailable;
    const blocks_per_row = (dim + 255) / 256;
    const wo_row_bytes = blocks_per_row * 144;
    const wo_bytes = try allocator.alloc(u8, dim * wo_row_bytes);
    defer allocator.free(wo_bytes);
    @memset(wo_bytes, 0);
    const wo_f16 = try allocator.alloc(f16, dim * dim);
    defer allocator.free(wo_f16);
    @memset(wo_f16, @as(f16, 0.0));

    const cases = [_]BenchCase{
        .{ .label = "lfm2-layer-s32", .seq_len = 32, .attn_iterations = 3000, .layer_iterations = 1500 },
        .{ .label = "lfm2-layer-s128", .seq_len = 128, .attn_iterations = 1000, .layer_iterations = 750 },
        .{ .label = "lfm2-layer-s256", .seq_len = 256, .attn_iterations = 500, .layer_iterations = 400 },
        .{ .label = "lfm2-layer-s512", .seq_len = 512, .attn_iterations = 250, .layer_iterations = 200 },
    };

    std.debug.print("Decode Layer Microbenchmark\n", .{});
    std.debug.print("heads={} head_dim={} kv_heads={} kv_stride={} dim={}\n", .{
        n_heads, head_dim, kv_heads, kv_stride, dim,
    });
    std.debug.print("wo projection uses synthetic zeroed Q4_K weights to measure kernel cost directly.\n\n", .{});

    for (cases) |bench_case| {
        const kv_len = bench_case.seq_len * kv_stride;
        const q = try allocator.alloc(f32, dim);
        defer allocator.free(q);
        const k_cache = try allocator.alloc(f32, kv_len);
        defer allocator.free(k_cache);
        const v_cache = try allocator.alloc(f32, kv_len);
        defer allocator.free(v_cache);
        const expected_attention = try allocator.alloc(f32, dim);
        defer allocator.free(expected_attention);
        const residual_seed = try allocator.alloc(f32, dim);
        defer allocator.free(residual_seed);

        fillDeterministic(q, bench_case.seq_len + 3);
        fillDeterministic(k_cache, bench_case.seq_len + 31);
        fillDeterministic(v_cache, bench_case.seq_len + 47);
        fillDeterministic(residual_seed, bench_case.seq_len + 59);
        cpuDecodeAttention(expected_attention, q, k_cache, v_cache, bench_case.seq_len, head_dim, n_heads, heads_per_group, kv_stride, scale);

        const q_buf = try createSharedFloatBuffer(device, q);
        defer metal_bindings.release(q_buf);
        const k_buf = try createSharedFloatBuffer(device, k_cache);
        defer metal_bindings.release(k_buf);
        const v_buf = try createSharedFloatBuffer(device, v_cache);
        defer metal_bindings.release(v_buf);
        const attn_out_buf = try createZeroFloatBuffer(device, dim);
        defer metal_bindings.release(attn_out_buf);
        const proj_out_buf = try createZeroFloatBuffer(device, dim);
        defer metal_bindings.release(proj_out_buf);
        const hidden_buf = try createSharedFloatBuffer(device, residual_seed);
        defer metal_bindings.release(hidden_buf);
        const wo_buf = try createSharedByteBuffer(device, wo_bytes);
        defer metal_bindings.release(wo_buf);
        const wo_f16_buf = try createSharedHalfBuffer(device, wo_f16);
        defer metal_bindings.release(wo_f16_buf);

        const projection_only = try benchmarkProjectionOnly(
            lib,
            q,
            q_buf,
            wo_bytes,
            wo_buf,
            floatBufferSlice(proj_out_buf, dim),
            proj_out_buf,
            dim,
            bench_case.layer_iterations,
        );
        const projection_only_f16 = try benchmarkProjectionOnlyF16(
            lib,
            q,
            q_buf,
            wo_f16,
            wo_f16_buf,
            floatBufferSlice(proj_out_buf, dim),
            proj_out_buf,
            dim,
            bench_case.layer_iterations,
        );
        const split_layer = try benchmarkLayerMode(
            lib,
            .split,
            q_buf,
            attn_out_buf,
            proj_out_buf,
            k_buf,
            v_buf,
            wo_bytes,
            wo_buf,
            expected_attention,
            bench_case.seq_len,
            head_dim,
            n_heads,
            heads_per_group,
            kv_stride,
            scale,
            bench_case.layer_iterations,
        );
        const fused_single_layer = try benchmarkLayerMode(
            lib,
            .fused_single,
            q_buf,
            attn_out_buf,
            proj_out_buf,
            k_buf,
            v_buf,
            wo_bytes,
            wo_buf,
            expected_attention,
            bench_case.seq_len,
            head_dim,
            n_heads,
            heads_per_group,
            kv_stride,
            scale,
            bench_case.layer_iterations,
        );
        const fused_heads_layer = try benchmarkLayerMode(
            lib,
            .fused_heads,
            q_buf,
            attn_out_buf,
            proj_out_buf,
            k_buf,
            v_buf,
            wo_bytes,
            wo_buf,
            expected_attention,
            bench_case.seq_len,
            head_dim,
            n_heads,
            heads_per_group,
            kv_stride,
            scale,
            bench_case.layer_iterations,
        );
        const fused_heads_layer_f16 = try benchmarkFusedHeadsLayerF16(
            lib,
            q_buf,
            attn_out_buf,
            proj_out_buf,
            k_buf,
            v_buf,
            wo_f16,
            wo_f16_buf,
            expected_attention,
            bench_case.seq_len,
            head_dim,
            n_heads,
            heads_per_group,
            kv_stride,
            scale,
            bench_case.layer_iterations,
        );
        const fused_heads_layer_chain = try benchmarkFusedHeadsLayerChain(
            lib,
            q_buf,
            attn_out_buf,
            hidden_buf,
            k_buf,
            v_buf,
            wo_buf,
            residual_seed,
            residual_seed,
            bench_case.seq_len,
            head_dim,
            n_heads,
            heads_per_group,
            kv_stride,
            scale,
            bench_case.layer_iterations,
        );

        std.debug.print("{s}  seq_len={}\n", .{ bench_case.label, bench_case.seq_len });
        std.debug.print("  {s:<18} {d:>8.3} ms/call  {d:>9.1} calls/s\n", .{
            projection_only.label,
            projection_only.avgMs(),
            projection_only.callsPerSecond(),
        });
        std.debug.print("  {s:<18} {d:>8.3} ms/call  {d:>9.1} calls/s\n", .{
            projection_only_f16.label,
            projection_only_f16.avgMs(),
            projection_only_f16.callsPerSecond(),
        });
        std.debug.print("  {s:<18} {d:>8.3} ms/call  {d:>9.1} calls/s  attn_diff={d:.6}\n", .{
            split_layer.label,
            split_layer.avgMs(),
            split_layer.callsPerSecond(),
            split_layer.attn_max_abs_diff,
        });
        std.debug.print("  {s:<18} {d:>8.3} ms/call  {d:>9.1} calls/s  attn_diff={d:.6}\n", .{
            fused_single_layer.label,
            fused_single_layer.avgMs(),
            fused_single_layer.callsPerSecond(),
            fused_single_layer.attn_max_abs_diff,
        });
        std.debug.print("  {s:<18} {d:>8.3} ms/call  {d:>9.1} calls/s  attn_diff={d:.6}\n\n", .{
            fused_heads_layer.label,
            fused_heads_layer.avgMs(),
            fused_heads_layer.callsPerSecond(),
            fused_heads_layer.attn_max_abs_diff,
        });
        std.debug.print("  {s:<18} {d:>8.3} ms/call  {d:>9.1} calls/s  attn_diff={d:.6}\n\n", .{
            fused_heads_layer_f16.label,
            fused_heads_layer_f16.avgMs(),
            fused_heads_layer_f16.callsPerSecond(),
            fused_heads_layer_f16.attn_max_abs_diff,
        });
        std.debug.print("  {s:<18} {d:>8.3} ms/call  {d:>9.1} calls/s  attn_diff={d:.6}\n\n", .{
            fused_heads_layer_chain.label,
            fused_heads_layer_chain.avgMs(),
            fused_heads_layer_chain.callsPerSecond(),
            fused_heads_layer_chain.attn_max_abs_diff,
        });
    }
}
