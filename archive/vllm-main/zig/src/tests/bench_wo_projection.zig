//! WO Projection Microbenchmark
//!
//! Measures the isolated Metal output projection hot path used after decode
//! attention, without the rest of the model around it.
//!
//! Usage:
//!   zig build bench-wo-proj

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

fn createSharedHalfBuffer(device: metal_bindings.MTLDevice, values: []const f16) !metal_bindings.MTLBuffer {
    const size = values.len * @sizeOf(f16);
    const buffer = metal_bindings.createSharedBuffer(device, @intCast(size)) orelse return error.BufferAllocationFailed;
    errdefer metal_bindings.release(buffer);
    const contents = metal_bindings.getBufferContents(buffer) orelse return error.BufferMapFailed;
    const dst: [*]f16 = @ptrCast(@alignCast(contents));
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

fn addResidualInPlace(out: []f32, residual: []const f32) void {
    for (out, residual) |*dst, src| dst.* += src;
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

fn runProjectionQ4KAdd(
    lib: *metal_shaders.MetalShaderLibrary,
    x: []const f32,
    x_buf: metal_bindings.MTLBuffer,
    wo_bytes: []const u8,
    wo_buf: metal_bindings.MTLBuffer,
    residual: []const f32,
    residual_buf: metal_bindings.MTLBuffer,
    out: []f32,
    out_buf: metal_bindings.MTLBuffer,
    dim: usize,
) !void {
    const out_slice = floatBufferSlice(out_buf, dim);
    @memcpy(out_slice, residual[0..dim]);
    const result = metal_shaders.dispatchVecMatMulQ4KAdd(
        lib,
        x,
        wo_bytes,
        wo_buf,
        residual,
        x_buf,
        residual_buf,
        out,
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

fn benchmarkQ4K(
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
    for (0..iterations) |_| try runProjectionQ4K(lib, x, x_buf, wo_bytes, wo_buf, out, out_buf, dim);
    const elapsed = std.time.nanoTimestamp() - start;
    return .{ .label = "wo-q4k", .iterations = iterations, .elapsed_ns = @intCast(@max(elapsed, 0)) };
}

fn benchmarkQ4KPlusCpuAdd(
    lib: *metal_shaders.MetalShaderLibrary,
    x: []const f32,
    x_buf: metal_bindings.MTLBuffer,
    wo_bytes: []const u8,
    wo_buf: metal_bindings.MTLBuffer,
    residual: []const f32,
    out: []f32,
    out_buf: metal_bindings.MTLBuffer,
    dim: usize,
    iterations: usize,
) !BenchResult {
    try runProjectionQ4K(lib, x, x_buf, wo_bytes, wo_buf, out, out_buf, dim);
    addResidualInPlace(out, residual[0..dim]);
    const start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        try runProjectionQ4K(lib, x, x_buf, wo_bytes, wo_buf, out, out_buf, dim);
        addResidualInPlace(out, residual[0..dim]);
    }
    const elapsed = std.time.nanoTimestamp() - start;
    return .{ .label = "wo-q4k+cpu-add", .iterations = iterations, .elapsed_ns = @intCast(@max(elapsed, 0)) };
}

fn benchmarkQ4KAdd(
    lib: *metal_shaders.MetalShaderLibrary,
    x: []const f32,
    x_buf: metal_bindings.MTLBuffer,
    wo_bytes: []const u8,
    wo_buf: metal_bindings.MTLBuffer,
    residual: []const f32,
    residual_buf: metal_bindings.MTLBuffer,
    out: []f32,
    out_buf: metal_bindings.MTLBuffer,
    dim: usize,
    iterations: usize,
) !BenchResult {
    try runProjectionQ4KAdd(lib, x, x_buf, wo_bytes, wo_buf, residual, residual_buf, out, out_buf, dim);
    const start = std.time.nanoTimestamp();
    for (0..iterations) |_| try runProjectionQ4KAdd(lib, x, x_buf, wo_bytes, wo_buf, residual, residual_buf, out, out_buf, dim);
    const elapsed = std.time.nanoTimestamp() - start;
    return .{ .label = "wo-q4k+fused-add", .iterations = iterations, .elapsed_ns = @intCast(@max(elapsed, 0)) };
}

fn benchmarkF16(
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
    for (0..iterations) |_| try runProjectionF16(lib, x, x_buf, wo_f16, wo_f16_buf, out, out_buf, dim);
    const elapsed = std.time.nanoTimestamp() - start;
    return .{ .label = "wo-f16", .iterations = iterations, .elapsed_ns = @intCast(@max(elapsed, 0)) };
}

pub fn main() !void {
    if (builtin.os.tag != .macos) {
        std.debug.print("bench-wo-proj is only supported on macOS.\n", .{});
        return;
    }

    const allocator = std.heap.page_allocator;
    const dim = envUsize(allocator, "BENCH_WO_DIM", 2048);
    const iterations = envUsize(allocator, "BENCH_WO_ITERATIONS", 4000);

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

    const x = try allocator.alloc(f32, dim);
    defer allocator.free(x);
    const residual = try allocator.alloc(f32, dim);
    defer allocator.free(residual);
    fillDeterministic(x, 11);
    fillDeterministic(residual, 29);

    const x_buf = try createSharedFloatBuffer(device, x);
    defer metal_bindings.release(x_buf);
    const residual_buf = try createSharedFloatBuffer(device, residual);
    defer metal_bindings.release(residual_buf);
    const out_buf = try createZeroFloatBuffer(device, dim);
    defer metal_bindings.release(out_buf);
    const wo_buf = try createSharedByteBuffer(device, wo_bytes);
    defer metal_bindings.release(wo_buf);
    const wo_f16_buf = try createSharedHalfBuffer(device, wo_f16);
    defer metal_bindings.release(wo_f16_buf);
    const out = floatBufferSlice(out_buf, dim);

    const q4k = try benchmarkQ4K(lib, x, x_buf, wo_bytes, wo_buf, out, out_buf, dim, iterations);
    const q4k_cpu_add = try benchmarkQ4KPlusCpuAdd(lib, x, x_buf, wo_bytes, wo_buf, residual, out, out_buf, dim, iterations);
    const q4k_fused_add = try benchmarkQ4KAdd(lib, x, x_buf, wo_bytes, wo_buf, residual, residual_buf, out, out_buf, dim, iterations);
    const f16_proj = try benchmarkF16(lib, x, x_buf, wo_f16, wo_f16_buf, out, out_buf, dim, iterations);

    std.debug.print("WO Projection Microbenchmark\n", .{});
    std.debug.print("dim={} iterations={}\n", .{ dim, iterations });
    std.debug.print("weights use synthetic zeroed Q4_K/F16 matrices for stable projection timing.\n\n", .{});
    inline for (.{ q4k, q4k_cpu_add, q4k_fused_add, f16_proj }) |result| {
        std.debug.print("  {s:<18} {d:>8.3} ms/call  {d:>9.1} calls/s\n", .{
            result.label,
            result.avgMs(),
            result.callsPerSecond(),
        });
    }
}
