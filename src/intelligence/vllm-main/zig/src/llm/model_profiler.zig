//! Model Auto-Profiler
//! Automatically benchmark quantization configurations on detected GPU hardware
//! and recommend optimal config (quant level, batch size, context length)

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// GPU Hardware Detection
// ============================================================================

pub const GpuInfo = struct {
    name: [64]u8,
    name_len: u8,
    compute_capability_major: u8,
    compute_capability_minor: u8,
    vram_bytes: u64,
    sm_count: u32,
    clock_mhz: u32,

    pub fn detect() GpuInfo {
        // Try to read from environment or return CPU fallback
        var gpu: GpuInfo = undefined;
        @memset(&gpu.name, 0);
        gpu.name_len = 0;
        gpu.compute_capability_major = 7;
        gpu.compute_capability_minor = 5;
        gpu.vram_bytes = 8 * 1024 * 1024 * 1024; // 8 GiB default
        gpu.sm_count = 40;
        gpu.clock_mhz = 1500;

        if (std.posix.getenv("GPU_NAME")) |name| {
            const len = @min(name.len, 63);
            @memcpy(gpu.name[0..len], name[0..len]);
            gpu.name_len = @intCast(len);
        } else {
            const fallback = "CPU Fallback";
            @memcpy(gpu.name[0..fallback.len], fallback);
            gpu.name_len = @intCast(fallback.len);
        }

        return gpu;
    }

    pub fn getName(self: *const GpuInfo) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn vramGiB(self: *const GpuInfo) f64 {
        return @as(f64, @floatFromInt(self.vram_bytes)) / (1024.0 * 1024.0 * 1024.0);
    }

    pub fn supportsFp8(self: *const GpuInfo) bool {
        return self.compute_capability_major > 8 or
            (self.compute_capability_major == 8 and self.compute_capability_minor >= 9);
    }

    pub fn supportsInt8(self: *const GpuInfo) bool {
        return self.compute_capability_major >= 7 and self.compute_capability_minor >= 5;
    }

    pub fn tflops(self: *const GpuInfo) f64 {
        const base_ops_per_clock = @as(f64, @floatFromInt(self.sm_count)) * 128.0; // Tensor ops
        return base_ops_per_clock * @as(f64, @floatFromInt(self.clock_mhz)) / 1000.0;
    }
};

// ============================================================================
// Quantization Configuration
// ============================================================================

pub const QuantConfig = struct {
    name: []const u8,
    bits_per_weight: f32,
};

pub const QUANT_CONFIGS = [_]QuantConfig{
    .{ .name = "FP16", .bits_per_weight = 16.0 },
    .{ .name = "FP8-E4M3", .bits_per_weight = 8.0 },
    .{ .name = "INT8", .bits_per_weight = 8.0 },
    .{ .name = "Q5_K_M", .bits_per_weight = 5.5 },
    .{ .name = "Q4_K_M", .bits_per_weight = 4.5 },
    .{ .name = "Q4_0", .bits_per_weight = 4.0 },
    .{ .name = "INT4-AWQ", .bits_per_weight = 4.0 },
};

// ============================================================================
// Profile Result
// ============================================================================

pub const ProfileResult = struct {
    quant_name: []const u8,
    estimated_vram_mb: u64,
    estimated_tokens_per_sec: f64,
    max_batch_size: u32,
    max_context_length: u32,
    fits_in_vram: bool,
    score: f64,
};

// ============================================================================
// Model Profiler
// ============================================================================

pub const ModelProfiler = struct {
    allocator: Allocator,
    gpu: GpuInfo,
    results: std.ArrayListUnmanaged(ProfileResult),

    pub fn init(allocator: Allocator) ModelProfiler {
        return .{
            .allocator = allocator,
            .gpu = GpuInfo.detect(),
            .results = .{},
        };
    }

    pub fn deinit(self: *ModelProfiler) void {
        self.results.deinit();
    }

    pub fn profileModel(self: *ModelProfiler, model_params_b: f64) !void {
        self.results.clearRetainingCapacity();

        for (QUANT_CONFIGS) |config| {
            const vram_mb = estimateVram(&self.gpu, model_params_b, config.bits_per_weight, 32, 2048);
            const fits = vram_mb < @as(u64, @intCast(@as(i64, @intFromFloat(self.gpu.vramGiB() * 1024.0))));
            const throughput = estimateThroughput(&self.gpu, model_params_b, config.bits_per_weight);
            const score = if (fits) throughput else 0.0;

            try self.results.append(.{
                .quant_name = config.name,
                .estimated_vram_mb = vram_mb,
                .estimated_tokens_per_sec = throughput,
                .max_batch_size = if (fits) 32 else 1,
                .max_context_length = if (fits) 2048 else 512,
                .fits_in_vram = fits,
                .score = score,
            });
        }
    }

    pub fn bestConfig(self: *const ModelProfiler) ?ProfileResult {
        var best: ?ProfileResult = null;
        var best_score: f64 = -1.0;

        for (self.results.items) |result| {
            if (result.score > best_score) {
                best_score = result.score;
                best = result;
            }
        }

        return best;
    }

    pub fn fittingConfigs(self: *const ModelProfiler) []const ProfileResult {
        return self.results.items;
    }

    pub fn estimateVram(_: *const GpuInfo, model_params_b: f64, bits_per_weight: f32, batch_size: u32, context_len: u32) u64 {
        const model_bytes = (model_params_b * 1_000_000_000.0 * @as(f64, bits_per_weight)) / 8.0;
        const kv_cache_bytes = @as(f64, @floatFromInt(batch_size)) * @as(f64, @floatFromInt(context_len)) * 128.0;
        const total_bytes = model_bytes + kv_cache_bytes;
        return @intCast(@as(i64, @intFromFloat(total_bytes / (1024.0 * 1024.0))));
    }

    pub fn estimateThroughput(gpu: *const GpuInfo, model_params_b: f64, bits_per_weight: f32) f64 {
        const model_ops = model_params_b * 2.0; // 2 ops per param (matmul)
        const effective_tflops = gpu.tflops() * (16.0 / bits_per_weight); // Speedup from quantization
        return (model_ops * 1_000_000_000.0) / (effective_tflops * 1_000_000_000_000.0);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "GpuInfo.detect returns reasonable defaults" {
    const gpu = GpuInfo.detect();
    try std.testing.expect(gpu.name_len > 0);
    try std.testing.expect(gpu.vram_bytes > 0);
    try std.testing.expect(gpu.compute_capability_major >= 7);
}

test "GpuInfo.supportsFp8 for different compute capabilities" {
    var gpu = GpuInfo.detect();
    gpu.compute_capability_major = 8;
    gpu.compute_capability_minor = 9;
    try std.testing.expect(gpu.supportsFp8());

    gpu.compute_capability_major = 7;
    gpu.compute_capability_minor = 5;
    try std.testing.expect(!gpu.supportsFp8());
}

test "ModelProfiler.estimateVram calculation" {
    var gpu = GpuInfo.detect();
    const vram_mb = ModelProfiler.estimateVram(&gpu, 7.0, 4.0, 32, 2048);
    try std.testing.expect(vram_mb > 0);
    try std.testing.expect(vram_mb < 100000); // Sanity check
}

test "ModelProfiler.profileModel with 7B model" {
    var profiler = ModelProfiler.init(std.testing.allocator);
    defer profiler.deinit();

    try profiler.profileModel(7.0);
    try std.testing.expect(profiler.results.items.len == QUANT_CONFIGS.len);
}

test "ModelProfiler.bestConfig returns fitting config" {
    var profiler = ModelProfiler.init(std.testing.allocator);
    defer profiler.deinit();

    try profiler.profileModel(7.0);
    const best = profiler.bestConfig();
    try std.testing.expect(best != null);
    if (best) |b| {
        try std.testing.expect(b.fits_in_vram);
    }
}

