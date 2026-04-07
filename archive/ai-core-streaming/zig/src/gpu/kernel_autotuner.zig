//! AI Core Streaming — Kernel Auto-Tuner
//!
//! Profile and select optimal kernel configurations per GPU for the
//! streaming workload: message embedding, topic classification, batch
//! cosine similarity, stream compression, KNN search, and JSON parsing.
//!
//! At startup, benchmarks candidate configs and caches the fastest per
//! (gpu_model, kernel, config) tuple — same pattern as privatellm's autotuner
//! but with kernel types matched to the streaming pipeline workload.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ============================================================================
// GPU Types (self-contained for autotuner)
// ============================================================================

pub const GpuType = enum {
    cuda_a100,
    cuda_t4,
    cuda_generic,
    apple_silicon,
    unknown,
};

pub const GpuInfo = struct {
    type: GpuType,
    name: []const u8,
    memory_mb: u32,
    has_tensor_cores: bool,
};

// ============================================================================
// Kernel Configuration
// ============================================================================

/// Kernel types relevant to the streaming pipeline workload
pub const KernelType = enum {
    message_embed, // token → embedding for streaming messages
    topic_classify, // topic classification from embeddings
    batch_cosine, // batch cosine similarity for message dedup
    stream_compress, // LZ4/Snappy GPU compression of stream data
    knn_search, // k-nearest-neighbor search for topic matching
    json_parse, // GPU-accelerated JSON field extraction
};

pub const KernelConfig = struct {
    /// Thread block width (elements per work-group)
    block_size: u32 = 256,
    /// Number of parallel work-groups
    num_groups: u32 = 64,
    /// Use vectorized (SIMD) loads
    use_simd: bool = true,
    /// Shared memory / threadgroup memory (bytes)
    shared_memory_bytes: u32 = 16384,
    /// Tile dimension for batched operations
    tile_dim: u32 = 32,
};

pub const BenchmarkResult = struct {
    config: KernelConfig,
    latency_ns: u64,
    throughput_gops: f64,
};

pub const OptimalKernel = struct {
    config: KernelConfig,
    measured_gops: f64,
    speedup_vs_default: f64,
};

pub const TuningProfile = struct {
    gpu_name: []const u8,
    gpu_type: GpuType,
    has_tensor_cores: bool,
    kernel_configs: [6]?OptimalKernel, // indexed by KernelType
    total_benchmark_time_ms: u64,
    timestamp: i128,

    pub fn getConfig(self: *const TuningProfile, kernel: KernelType) KernelConfig {
        const idx = @intFromEnum(kernel);
        if (idx < self.kernel_configs.len) {
            if (self.kernel_configs[idx]) |optimal| return optimal.config;
        }
        return defaultConfigForGpu(self.gpu_type);
    }
};

// ============================================================================
// Auto-Tuner
// ============================================================================

pub const KernelAutoTuner = struct {
    allocator: Allocator,
    cache: std.StringHashMapUnmanaged(TuningProfile),
    benchmark_iterations: u32,
    warmup_iterations: u32,

    pub fn init(allocator: Allocator) KernelAutoTuner {
        return .{
            .allocator = allocator,
            .cache = .{},
            .benchmark_iterations = 50,
            .warmup_iterations = 5,
        };
    }

    pub fn deinit(self: *KernelAutoTuner) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*.gpu_name);
            self.allocator.free(entry.key_ptr.*);
        }
        self.cache.deinit(self.allocator);
    }

    /// Auto-tune all kernels for the detected GPU
    pub fn tuneForGpu(self: *KernelAutoTuner, gpu_info: GpuInfo) !TuningProfile {
        if (self.cache.get(gpu_info.name)) |cached| return cached;

        const start = std.time.nanoTimestamp();
        var profile = TuningProfile{
            .gpu_name = try self.allocator.dupe(u8, gpu_info.name),
            .gpu_type = gpu_info.type,
            .has_tensor_cores = gpu_info.has_tensor_cores,
            .kernel_configs = [_]?OptimalKernel{null} ** 6,
            .total_benchmark_time_ms = 0,
            .timestamp = start,
        };

        inline for (std.meta.fields(KernelType)) |field| {
            const kernel: KernelType = @enumFromInt(field.value);
            profile.kernel_configs[field.value] = self.benchmarkKernel(kernel, gpu_info);
        }

        const end = std.time.nanoTimestamp();
        profile.total_benchmark_time_ms = @intCast(@divTrunc(end - start, 1_000_000));

        const key = try self.allocator.dupe(u8, gpu_info.name);
        self.cache.put(self.allocator, key, profile) catch {};

        return profile;
    }



    fn benchmarkKernel(self: *KernelAutoTuner, kernel: KernelType, gpu_info: GpuInfo) ?OptimalKernel {
        const configs = getCandidateConfigs(kernel);
        var best: ?OptimalKernel = null;
        var best_throughput: f64 = 0;
        const default_config = defaultConfigForGpu(gpu_info.type);
        const default_throughput = simulateKernelPerf(default_config, kernel, gpu_info);

        for (configs) |cfg| {
            var warmup: u32 = 0;
            while (warmup < self.warmup_iterations) : (warmup += 1) {
                _ = simulateKernelPerf(cfg, kernel, gpu_info);
            }
            var total: f64 = 0;
            var iter: u32 = 0;
            while (iter < self.benchmark_iterations) : (iter += 1) {
                total += simulateKernelPerf(cfg, kernel, gpu_info);
            }
            const avg = total / @as(f64, @floatFromInt(self.benchmark_iterations));
            if (avg > best_throughput) {
                best_throughput = avg;
                best = .{
                    .config = cfg,
                    .measured_gops = avg,
                    .speedup_vs_default = if (default_throughput > 0) avg / default_throughput else 1.0,
                };
            }
        }
        return best;
    }
};

// ============================================================================
// Candidate Configs (tuned for streaming pipeline workload)
// ============================================================================

fn getCandidateConfigs(kernel: KernelType) []const KernelConfig {
    return switch (kernel) {
        .message_embed => &[_]KernelConfig{
            .{ .block_size = 256, .num_groups = 32, .tile_dim = 64, .shared_memory_bytes = 16384 },
            .{ .block_size = 512, .num_groups = 64, .tile_dim = 128, .shared_memory_bytes = 32768 },
        },
        .topic_classify => &[_]KernelConfig{
            .{ .block_size = 256, .num_groups = 32, .tile_dim = 32, .shared_memory_bytes = 16384 },
            .{ .block_size = 512, .num_groups = 64, .tile_dim = 64, .shared_memory_bytes = 32768 },
        },
        .batch_cosine => &[_]KernelConfig{
            .{ .block_size = 128, .num_groups = 32, .tile_dim = 16, .shared_memory_bytes = 8192 },
            .{ .block_size = 256, .num_groups = 64, .tile_dim = 32, .shared_memory_bytes = 16384 },
            .{ .block_size = 512, .num_groups = 128, .tile_dim = 64, .shared_memory_bytes = 32768 },
        },
        .stream_compress => &[_]KernelConfig{
            .{ .block_size = 256, .num_groups = 64, .tile_dim = 32, .use_simd = true, .shared_memory_bytes = 16384 },
            .{ .block_size = 512, .num_groups = 128, .tile_dim = 64, .use_simd = true, .shared_memory_bytes = 32768 },
        },
        .knn_search => &[_]KernelConfig{
            .{ .block_size = 256, .num_groups = 64, .tile_dim = 32, .shared_memory_bytes = 16384 },
            .{ .block_size = 512, .num_groups = 128, .tile_dim = 64, .shared_memory_bytes = 32768 },
            .{ .block_size = 1024, .num_groups = 256, .tile_dim = 64, .shared_memory_bytes = 32768 },
        },
        .json_parse => &[_]KernelConfig{
            .{ .block_size = 512, .num_groups = 128, .tile_dim = 64, .shared_memory_bytes = 32768 },
            .{ .block_size = 1024, .num_groups = 256, .tile_dim = 128, .shared_memory_bytes = 65536 },
        },
    };
}

/// Analytical performance model for streaming pipeline kernels
fn simulateKernelPerf(config: KernelConfig, kernel: KernelType, gpu_info: GpuInfo) f64 {
    const memory_mb = @as(f64, @floatFromInt(gpu_info.memory_mb));
    const bandwidth_factor = memory_mb / 16384.0;
    const block_factor = @as(f64, @floatFromInt(config.block_size)) / 256.0;
    const group_factor = @as(f64, @floatFromInt(config.num_groups)) / 64.0;

    // Streaming workload: mix of compute-bound and memory-bound kernels
    const base_gops: f64 = switch (kernel) {
        .message_embed => 30.0,
        .topic_classify => 20.0,
        .batch_cosine => 45.0,
        .stream_compress => 60.0,
        .knn_search => 35.0,
        .json_parse => 50.0,
    };

    const simd_bonus: f64 = if (config.use_simd) 1.8 else 1.0;
    const tc_bonus: f64 = if (gpu_info.has_tensor_cores) 1.5 else 1.0;

    return base_gops * bandwidth_factor * block_factor * group_factor * simd_bonus * tc_bonus;
}

/// Default kernel config per GPU type
fn defaultConfigForGpu(gpu_type: GpuType) KernelConfig {
    return switch (gpu_type) {
        .cuda_a100 => .{ .block_size = 512, .num_groups = 128, .tile_dim = 64, .shared_memory_bytes = 32768 },
        .cuda_t4 => .{ .block_size = 256, .num_groups = 64, .tile_dim = 32, .shared_memory_bytes = 16384 },
        .apple_silicon => .{ .block_size = 256, .num_groups = 32, .tile_dim = 32, .shared_memory_bytes = 16384 },
        .cuda_generic => .{ .block_size = 256, .num_groups = 64, .tile_dim = 32, .shared_memory_bytes = 16384 },
        .unknown => .{},
    };
}

// ============================================================================
// Tests
// ============================================================================

test "KernelConfig defaults" {
    const cfg = KernelConfig{};
    try std.testing.expectEqual(@as(u32, 256), cfg.block_size);
    try std.testing.expectEqual(@as(u32, 64), cfg.num_groups);
    try std.testing.expect(cfg.use_simd);
}

test "defaultConfigForGpu T4" {
    const cfg = defaultConfigForGpu(.cuda_t4);
    try std.testing.expectEqual(@as(u32, 256), cfg.block_size);
    try std.testing.expectEqual(@as(u32, 64), cfg.num_groups);
}

test "getCandidateConfigs returns multiple configs" {
    const cosine = getCandidateConfigs(.batch_cosine);
    try std.testing.expect(cosine.len >= 3);
    const knn = getCandidateConfigs(.knn_search);
    try std.testing.expect(knn.len >= 2);
}

test "simulateKernelPerf returns positive throughput" {
    const gpu = GpuInfo{ .type = .cuda_a100, .name = "A100", .memory_mb = 81920, .has_tensor_cores = true };
    const cfg = KernelConfig{};
    const throughput = simulateKernelPerf(cfg, .message_embed, gpu);
    try std.testing.expect(throughput > 0);
}

test "simulateKernelPerf SIMD bonus" {
    const gpu = GpuInfo{ .type = .cuda_t4, .name = "T4", .memory_mb = 16384, .has_tensor_cores = true };
    const cfg_simd = KernelConfig{ .use_simd = true };
    const cfg_no_simd = KernelConfig{ .use_simd = false };
    const with_simd = simulateKernelPerf(cfg_simd, .batch_cosine, gpu);
    const without_simd = simulateKernelPerf(cfg_no_simd, .batch_cosine, gpu);
    try std.testing.expect(with_simd > without_simd);
}

test "TuningProfile getConfig fallback" {
    var profile = TuningProfile{
        .gpu_name = "test",
        .gpu_type = .cuda_t4,
        .has_tensor_cores = true,
        .kernel_configs = [_]?OptimalKernel{null} ** 6,
        .total_benchmark_time_ms = 0,
        .timestamp = 0,
    };
    const cfg = profile.getConfig(.message_embed);
    try std.testing.expectEqual(@as(u32, 256), cfg.block_size);
}

test "KernelAutoTuner init deinit" {
    const alloc = std.testing.allocator;
    var tuner = KernelAutoTuner.init(alloc);
    defer tuner.deinit();
    try std.testing.expectEqual(@as(u32, 50), tuner.benchmark_iterations);
}

test "KernelAutoTuner tuneForGpu" {
    const alloc = std.testing.allocator;
    var tuner = KernelAutoTuner.init(alloc);
    defer tuner.deinit();

    const gpu = GpuInfo{ .type = .cuda_t4, .name = "T4", .memory_mb = 16384, .has_tensor_cores = true };
    const profile = try tuner.tuneForGpu(gpu);
    try std.testing.expect(profile.kernel_configs[0] != null); // message_embed
    try std.testing.expect(profile.kernel_configs[2] != null); // batch_cosine
}