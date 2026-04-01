//! Decode Attention Microbenchmark
//!
//! Isolates the Metal decode-attention hot path and compares:
//!   - split score/softmax/value dispatches
//!   - per-head fused dispatch
//!   - multi-head fused dispatch
//!
//! Usage:
//!   zig build bench-decode-attn

const std = @import("std");
const builtin = @import("builtin");
const metal_bindings = @import("metal_bindings");
const metal_shaders = @import("metal_shaders");

const BenchCase = struct {
    label: []const u8,
    seq_len: usize,
    gpu_iterations: usize,
    cpu_iterations: usize,
};

const BenchResult = struct {
    label: []const u8,
    iterations: usize,
    elapsed_ns: u64,
    max_abs_diff: f32,

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
        .split => "split",
        .fused_single => "fused-single",
        .fused_heads => "fused-heads",
    };
}

fn envUsize(allocator: std.mem.Allocator, name: []const u8, default_value: usize) usize {
    const raw = std.process.getEnvVarOwned(allocator, name) catch return default_value;
    defer allocator.free(raw);
    return std.fmt.parseUnsigned(usize, raw, 10) catch default_value;
}

fn fillDeterministic(data: []f32, seed: usize) void {
    for (data, 0..) |*value, idx| {
        const x = @as(f32, @floatFromInt(((idx + seed) % 97))) / 97.0;
        const y = @as(f32, @floatFromInt(((idx * 7 + seed * 3) % 53))) / 211.0;
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

fn createZeroFloatBuffer(device: metal_bindings.MTLDevice, len: usize) !metal_bindings.MTLBuffer {
    const size = len * @sizeOf(f32);
    const buffer = metal_bindings.createSharedBuffer(device, @intCast(size)) orelse return error.BufferAllocationFailed;
    errdefer metal_bindings.release(buffer);
    const contents = metal_bindings.getBufferContents(buffer) orelse return error.BufferMapFailed;
    const dst: [*]f32 = @ptrCast(@alignCast(contents));
    @memset(dst[0..len], 0.0);
    return buffer;
}

fn bufferSlice(buffer: metal_bindings.MTLBuffer, len: usize) []f32 {
    const contents = metal_bindings.getBufferContents(buffer) orelse unreachable;
    const ptr: [*]f32 = @ptrCast(@alignCast(contents));
    return ptr[0..len];
}

fn zeroBuffer(buffer: metal_bindings.MTLBuffer, len: usize) void {
    @memset(bufferSlice(buffer, len), 0.0);
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
    for (a, b) |lhs, rhs| {
        max_diff = @max(max_diff, @abs(lhs - rhs));
    }
    return max_diff;
}

fn benchmarkCpu(
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
    iterations: usize,
) BenchResult {
    cpuDecodeAttention(out, q, k_cache, v_cache, seq_len, head_dim, n_heads, heads_per_group, kv_stride, scale);
    const start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        cpuDecodeAttention(out, q, k_cache, v_cache, seq_len, head_dim, n_heads, heads_per_group, kv_stride, scale);
    }
    const elapsed = std.time.nanoTimestamp() - start;
    return .{
        .label = "cpu",
        .iterations = iterations,
        .elapsed_ns = @intCast(@max(elapsed, 0)),
        .max_abs_diff = 0.0,
    };
}

fn benchmarkGpu(
    lib: *metal_shaders.MetalShaderLibrary,
    mode: metal_shaders.AttentionDecodeMode,
    q_buf: metal_bindings.MTLBuffer,
    out_buf: metal_bindings.MTLBuffer,
    k_buf: metal_bindings.MTLBuffer,
    v_buf: metal_bindings.MTLBuffer,
    out_len: usize,
    seq_len: usize,
    head_dim: usize,
    n_heads: usize,
    heads_per_group: usize,
    kv_stride: usize,
    scale: f32,
    expected: []const f32,
    iterations: usize,
) !BenchResult {
    zeroBuffer(out_buf, out_len);
    if (!metal_shaders.dispatchAttentionDecodeHeads(lib, .{
        .q_buf = q_buf,
        .out_buf = out_buf,
        .k_cache_buf = k_buf,
        .v_cache_buf = v_buf,
        .seq_len = seq_len,
        .head_dim = head_dim,
        .n_heads = n_heads,
        .heads_per_group = heads_per_group,
        .kv_stride = kv_stride,
        .scale = scale,
        .mode = mode,
    })) return error.DispatchFailed;

    const diff = maxAbsDiff(expected, bufferSlice(out_buf, out_len));

    const start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        zeroBuffer(out_buf, out_len);
        if (!metal_shaders.dispatchAttentionDecodeHeads(lib, .{
            .q_buf = q_buf,
            .out_buf = out_buf,
            .k_cache_buf = k_buf,
            .v_cache_buf = v_buf,
            .seq_len = seq_len,
            .head_dim = head_dim,
            .n_heads = n_heads,
            .heads_per_group = heads_per_group,
            .kv_stride = kv_stride,
            .scale = scale,
            .mode = mode,
        })) return error.DispatchFailed;
    }
    const elapsed = std.time.nanoTimestamp() - start;

    return .{
        .label = modeLabel(mode),
        .iterations = iterations,
        .elapsed_ns = @intCast(@max(elapsed, 0)),
        .max_abs_diff = diff,
    };
}

pub fn main() !void {
    if (builtin.os.tag != .macos) {
        std.debug.print("bench-decode-attn is only supported on macOS.\n", .{});
        return;
    }

    const allocator = std.heap.page_allocator;
    const n_heads = envUsize(allocator, "BENCH_ATTN_HEADS", 32);
    const head_dim = envUsize(allocator, "BENCH_ATTN_HEAD_DIM", 64);
    const heads_per_group = envUsize(allocator, "BENCH_ATTN_HEADS_PER_GROUP", 1);
    if (heads_per_group == 0 or n_heads % heads_per_group != 0) return error.InvalidHeadGrouping;
    const kv_heads = n_heads / heads_per_group;
    const kv_stride = kv_heads * head_dim;
    const q_len = n_heads * head_dim;
    const scale: f32 = 1.0 / @sqrt(@as(f32, @floatFromInt(head_dim)));

    var lib = try metal_shaders.MetalShaderLibrary.init(allocator);
    defer lib.deinit();
    try metal_shaders.loadBundledLibrary(lib);
    if (!lib.isReady()) return error.MetalUnavailable;

    const device = lib.device orelse return error.MetalUnavailable;

    const cases = [_]BenchCase{
        .{ .label = "lfm2-like-s32", .seq_len = 32, .gpu_iterations = 3000, .cpu_iterations = 500 },
        .{ .label = "lfm2-like-s128", .seq_len = 128, .gpu_iterations = 1000, .cpu_iterations = 200 },
        .{ .label = "lfm2-like-s256", .seq_len = 256, .gpu_iterations = 500, .cpu_iterations = 100 },
        .{ .label = "lfm2-like-s512", .seq_len = 512, .gpu_iterations = 250, .cpu_iterations = 50 },
    };

    std.debug.print("Decode Attention Microbenchmark\n", .{});
    std.debug.print("heads={} head_dim={} kv_heads={} kv_stride={} heads_per_group={}\n\n", .{
        n_heads, head_dim, kv_heads, kv_stride, heads_per_group,
    });

    for (cases) |bench_case| {
        const kv_len = bench_case.seq_len * kv_stride;
        const q = try allocator.alloc(f32, q_len);
        defer allocator.free(q);
        const k_cache = try allocator.alloc(f32, kv_len);
        defer allocator.free(k_cache);
        const v_cache = try allocator.alloc(f32, kv_len);
        defer allocator.free(v_cache);
        const cpu_out = try allocator.alloc(f32, q_len);
        defer allocator.free(cpu_out);

        fillDeterministic(q, bench_case.seq_len + 1);
        fillDeterministic(k_cache, bench_case.seq_len + 17);
        fillDeterministic(v_cache, bench_case.seq_len + 29);

        const q_buf = try createSharedFloatBuffer(device, q);
        defer metal_bindings.release(q_buf);
        const k_buf = try createSharedFloatBuffer(device, k_cache);
        defer metal_bindings.release(k_buf);
        const v_buf = try createSharedFloatBuffer(device, v_cache);
        defer metal_bindings.release(v_buf);
        const out_buf = try createZeroFloatBuffer(device, q_len);
        defer metal_bindings.release(out_buf);

        const cpu_result = benchmarkCpu(
            cpu_out,
            q,
            k_cache,
            v_cache,
            bench_case.seq_len,
            head_dim,
            n_heads,
            heads_per_group,
            kv_stride,
            scale,
            bench_case.cpu_iterations,
        );

        const split_result = try benchmarkGpu(
            lib,
            .split,
            q_buf,
            out_buf,
            k_buf,
            v_buf,
            q_len,
            bench_case.seq_len,
            head_dim,
            n_heads,
            heads_per_group,
            kv_stride,
            scale,
            cpu_out,
            bench_case.gpu_iterations,
        );
        const fused_single_result = try benchmarkGpu(
            lib,
            .fused_single,
            q_buf,
            out_buf,
            k_buf,
            v_buf,
            q_len,
            bench_case.seq_len,
            head_dim,
            n_heads,
            heads_per_group,
            kv_stride,
            scale,
            cpu_out,
            bench_case.gpu_iterations,
        );
        const fused_heads_result = try benchmarkGpu(
            lib,
            .fused_heads,
            q_buf,
            out_buf,
            k_buf,
            v_buf,
            q_len,
            bench_case.seq_len,
            head_dim,
            n_heads,
            heads_per_group,
            kv_stride,
            scale,
            cpu_out,
            bench_case.gpu_iterations,
        );

        std.debug.print("{s}  seq_len={}\n", .{ bench_case.label, bench_case.seq_len });
        std.debug.print("  {s:<12} {d:>8.3} ms/call  {d:>9.1} calls/s\n", .{
            cpu_result.label,
            cpu_result.avgMs(),
            cpu_result.callsPerSecond(),
        });
        std.debug.print("  {s:<12} {d:>8.3} ms/call  {d:>9.1} calls/s  diff={d:.6}\n", .{
            split_result.label,
            split_result.avgMs(),
            split_result.callsPerSecond(),
            split_result.max_abs_diff,
        });
        std.debug.print("  {s:<12} {d:>8.3} ms/call  {d:>9.1} calls/s  diff={d:.6}\n", .{
            fused_single_result.label,
            fused_single_result.avgMs(),
            fused_single_result.callsPerSecond(),
            fused_single_result.max_abs_diff,
        });
        std.debug.print("  {s:<12} {d:>8.3} ms/call  {d:>9.1} calls/s  diff={d:.6}\n\n", .{
            fused_heads_result.label,
            fused_heads_result.avgMs(),
            fused_heads_result.callsPerSecond(),
            fused_heads_result.max_abs_diff,
        });
    }
}
