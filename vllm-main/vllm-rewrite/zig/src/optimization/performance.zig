//! Performance Optimization Framework
//!
//! Provides tools and strategies for optimizing inference performance.
//! Includes profiling, auto-tuning, and CUDA graph support.
//!
//! Key Areas:
//! - Kernel launch optimization
//! - Memory access patterns
//! - Batch size tuning
//! - CUDA graph capture

const std = @import("std");
const gpu = @import("../device/gpu.zig");

// ==============================================
// Performance Configuration
// ==============================================

pub const PerformanceConfig = struct {
    /// Enable CUDA graphs for decode phase
    enable_cuda_graphs: bool = true,
    
    /// Maximum batch size for CUDA graph capture
    cuda_graph_max_batch_size: u32 = 256,
    
    /// Batch sizes to pre-capture graphs for
    cuda_graph_batch_sizes: []const u32 = &.{ 1, 2, 4, 8, 16, 32, 64, 128, 256 },
    
    /// Enable kernel fusion
    enable_kernel_fusion: bool = true,
    
    /// Memory alignment (bytes)
    memory_alignment: usize = 128,
    
    /// Enable async memory transfers
    enable_async_transfers: bool = true,
    
    /// Prefetch distance (number of batches)
    prefetch_distance: u32 = 2,
    
    /// Enable profiling
    enable_profiling: bool = false,
    
    /// Auto-tune on startup
    auto_tune_on_startup: bool = true,
};

// ==============================================
// Kernel Configuration
// ==============================================

pub const KernelConfig = struct {
    name: []const u8,
    block_size: u32 = 256,
    grid_size: u32 = 0,  // 0 = auto-compute
    shared_memory: usize = 0,
    stream_priority: i32 = 0,
    
    pub fn computeGridSize(self: KernelConfig, num_elements: usize) u32 {
        if (self.grid_size > 0) return self.grid_size;
        return @as(u32, @intCast((num_elements + self.block_size - 1) / self.block_size));
    }
};

pub const OptimalKernelConfigs = struct {
    // Attention kernels
    flash_attention: KernelConfig = .{
        .name = "flash_attention_v2",
        .block_size = 128,
        .shared_memory = 100 * 1024,
    },
    
    // GEMM kernels
    gemm_fp16: KernelConfig = .{
        .name = "gemm_fp16_tensor_core",
        .block_size = 256,
        .shared_memory = 32 * 1024,
    },
    
    // Element-wise kernels
    activation: KernelConfig = .{
        .name = "activation_silu",
        .block_size = 512,
    },
    
    // Normalization kernels
    layer_norm: KernelConfig = .{
        .name = "layer_norm_fused",
        .block_size = 256,
        .shared_memory = 16 * 1024,
    },
    
    // Softmax
    softmax: KernelConfig = .{
        .name = "online_softmax",
        .block_size = 256,
    },
};

// ==============================================
// Profiler
// ==============================================

pub const Profiler = struct {
    allocator: std.mem.Allocator,
    enabled: bool,
    
    // Timing data
    kernel_times: std.StringHashMap(TimingStats),
    memory_ops: std.ArrayList(MemoryOp),
    
    // Current profile
    profile_start: i64,
    current_kernel: ?[]const u8,
    kernel_start: i64,
    
    pub fn init(allocator: std.mem.Allocator, enabled: bool) Profiler {
        return .{
            .allocator = allocator,
            .enabled = enabled,
            .kernel_times = std.StringHashMap(TimingStats).init(allocator),
            .memory_ops = std.ArrayList(MemoryOp).init(allocator),
            .profile_start = 0,
            .current_kernel = null,
            .kernel_start = 0,
        };
    }
    
    pub fn deinit(self: *Profiler) void {
        self.kernel_times.deinit();
        self.memory_ops.deinit();
    }
    
    pub fn startProfile(self: *Profiler) void {
        if (!self.enabled) return;
        self.profile_start = std.time.microTimestamp();
    }
    
    pub fn startKernel(self: *Profiler, name: []const u8) void {
        if (!self.enabled) return;
        self.current_kernel = name;
        self.kernel_start = std.time.microTimestamp();
    }
    
    pub fn endKernel(self: *Profiler) void {
        if (!self.enabled or self.current_kernel == null) return;
        
        const elapsed = std.time.microTimestamp() - self.kernel_start;
        
        if (self.kernel_times.getPtr(self.current_kernel.?)) |stats| {
            stats.addSample(@as(f64, @floatFromInt(elapsed)));
        } else {
            var stats = TimingStats.init(self.current_kernel.?);
            stats.addSample(@as(f64, @floatFromInt(elapsed)));
            self.kernel_times.put(self.current_kernel.?, stats) catch {};
        }
        
        self.current_kernel = null;
    }
    
    pub fn recordMemoryOp(self: *Profiler, op_type: MemoryOpType, bytes: usize) void {
        if (!self.enabled) return;
        
        const timestamp = std.time.microTimestamp() - self.profile_start;
        self.memory_ops.append(.{
            .op_type = op_type,
            .bytes = bytes,
            .timestamp_us = @as(u64, @intCast(@max(timestamp, 0))),
        }) catch {};
    }
    
    pub fn getReport(self: *Profiler) ProfileReport {
        var total_kernel_time: f64 = 0;
        var kernel_breakdown = std.ArrayList(KernelTiming).init(self.allocator);
        
        var iter = self.kernel_times.iterator();
        while (iter.next()) |entry| {
            const stats = entry.value_ptr.*;
            total_kernel_time += stats.total;
            kernel_breakdown.append(.{
                .name = entry.key_ptr.*,
                .total_us = stats.total,
                .avg_us = stats.mean(),
                .count = stats.count,
                .percent = 0,  // Calculate after total known
            }) catch {};
        }
        
        // Calculate percentages
        for (kernel_breakdown.items) |*timing| {
            timing.percent = if (total_kernel_time > 0)
                timing.total_us / total_kernel_time * 100
            else
                0;
        }
        
        return ProfileReport{
            .total_time_us = @as(u64, @intCast(@max(std.time.microTimestamp() - self.profile_start, 0))),
            .kernel_time_us = @as(u64, @intCast(total_kernel_time)),
            .kernel_breakdown = kernel_breakdown.toOwnedSlice() catch &.{},
            .memory_ops = self.memory_ops.items.len,
        };
    }
};

pub const TimingStats = struct {
    name: []const u8,
    count: u64 = 0,
    total: f64 = 0,
    min: f64 = std.math.floatMax(f64),
    max: f64 = 0,
    sum_sq: f64 = 0,
    
    pub fn init(name: []const u8) TimingStats {
        return .{ .name = name };
    }
    
    pub fn addSample(self: *TimingStats, value: f64) void {
        self.count += 1;
        self.total += value;
        self.min = @min(self.min, value);
        self.max = @max(self.max, value);
        self.sum_sq += value * value;
    }
    
    pub fn mean(self: TimingStats) f64 {
        if (self.count == 0) return 0;
        return self.total / @as(f64, @floatFromInt(self.count));
    }
    
    pub fn stddev(self: TimingStats) f64 {
        if (self.count < 2) return 0;
        const n = @as(f64, @floatFromInt(self.count));
        const variance = (self.sum_sq - (self.total * self.total) / n) / (n - 1);
        return @sqrt(@max(variance, 0));
    }
};

pub const MemoryOp = struct {
    op_type: MemoryOpType,
    bytes: usize,
    timestamp_us: u64,
};

pub const MemoryOpType = enum {
    alloc,
    free,
    h2d_copy,
    d2h_copy,
    d2d_copy,
};

pub const ProfileReport = struct {
    total_time_us: u64,
    kernel_time_us: u64,
    kernel_breakdown: []KernelTiming,
    memory_ops: usize,
    
    pub fn print(self: ProfileReport) void {
        std.debug.print("\n╔════════════════════════════════════════════╗\n", .{});
        std.debug.print("║           PERFORMANCE PROFILE               ║\n", .{});
        std.debug.print("╚════════════════════════════════════════════╝\n\n", .{});
        
        std.debug.print("Total time:  {d:.2} ms\n", .{@as(f64, @floatFromInt(self.total_time_us)) / 1000});
        std.debug.print("Kernel time: {d:.2} ms ({d:.1}%)\n\n", .{
            @as(f64, @floatFromInt(self.kernel_time_us)) / 1000,
            if (self.total_time_us > 0) @as(f64, @floatFromInt(self.kernel_time_us)) / @as(f64, @floatFromInt(self.total_time_us)) * 100 else 0,
        });
        
        std.debug.print("Kernel Breakdown:\n", .{});
        for (self.kernel_breakdown) |timing| {
            std.debug.print("  {s}: {d:.2}ms ({d:.1}%) [n={d}, avg={d:.2}us]\n", .{
                timing.name,
                timing.total_us / 1000,
                timing.percent,
                timing.count,
                timing.avg_us,
            });
        }
        
        std.debug.print("\nMemory ops: {d}\n", .{self.memory_ops});
    }
};

pub const KernelTiming = struct {
    name: []const u8,
    total_us: f64,
    avg_us: f64,
    count: u64,
    percent: f64,
};

// ==============================================
// CUDA Graph Manager
// ==============================================

pub const CudaGraphManager = struct {
    allocator: std.mem.Allocator,
    device: gpu.DeviceId,
    
    // Captured graphs by batch size
    decode_graphs: std.AutoHashMap(u32, CapturedGraph),
    prefill_graphs: std.AutoHashMap(u32, CapturedGraph),
    
    // Graph capture state
    is_capturing: bool,
    capture_stream: ?gpu.Stream,
    
    pub fn init(allocator: std.mem.Allocator, device: gpu.DeviceId) CudaGraphManager {
        return .{
            .allocator = allocator,
            .device = device,
            .decode_graphs = std.AutoHashMap(u32, CapturedGraph).init(allocator),
            .prefill_graphs = std.AutoHashMap(u32, CapturedGraph).init(allocator),
            .is_capturing = false,
            .capture_stream = null,
        };
    }
    
    pub fn deinit(self: *CudaGraphManager) void {
        self.decode_graphs.deinit();
        self.prefill_graphs.deinit();
    }
    
    pub fn startCapture(self: *CudaGraphManager, batch_size: u32) !void {
        _ = batch_size;
        if (self.is_capturing) return error.AlreadyCapturing;
        
        self.is_capturing = true;
        // Would call cudaStreamBeginCapture
    }
    
    pub fn endCapture(self: *CudaGraphManager, batch_size: u32, is_decode: bool) !void {
        if (!self.is_capturing) return error.NotCapturing;
        
        self.is_capturing = false;
        // Would call cudaStreamEndCapture and cudaGraphInstantiate
        
        const graph = CapturedGraph{
            .batch_size = batch_size,
            .graph_handle = null,
            .exec_handle = null,
            .is_valid = true,
        };
        
        if (is_decode) {
            try self.decode_graphs.put(batch_size, graph);
        } else {
            try self.prefill_graphs.put(batch_size, graph);
        }
    }
    
    pub fn execute(self: *CudaGraphManager, batch_size: u32, is_decode: bool) !void {
        const graphs = if (is_decode) &self.decode_graphs else &self.prefill_graphs;
        
        if (graphs.get(batch_size)) |graph| {
            if (graph.is_valid) {
                // Would call cudaGraphLaunch
                return;
            }
        }
        
        return error.GraphNotCaptured;
    }
    
    pub fn hasGraph(self: *CudaGraphManager, batch_size: u32, is_decode: bool) bool {
        const graphs = if (is_decode) &self.decode_graphs else &self.prefill_graphs;
        return graphs.contains(batch_size);
    }
};

pub const CapturedGraph = struct {
    batch_size: u32,
    graph_handle: ?*anyopaque,
    exec_handle: ?*anyopaque,
    is_valid: bool,
};

// ==============================================
// Auto-Tuner
// ==============================================

pub const AutoTuner = struct {
    allocator: std.mem.Allocator,
    device: gpu.DeviceId,
    
    // Tuned configurations
    tuned_configs: std.StringHashMap(KernelConfig),
    
    // Tuning state
    current_best: ?TuningResult,
    tuning_iterations: u32,
    
    pub fn init(allocator: std.mem.Allocator, device: gpu.DeviceId) AutoTuner {
        return .{
            .allocator = allocator,
            .device = device,
            .tuned_configs = std.StringHashMap(KernelConfig).init(allocator),
            .current_best = null,
            .tuning_iterations = 100,
        };
    }
    
    pub fn deinit(self: *AutoTuner) void {
        self.tuned_configs.deinit();
    }
    
    /// Tune a kernel's configuration
    pub fn tuneKernel(
        self: *AutoTuner,
        name: []const u8,
        candidates: []const KernelConfig,
        benchmark_fn: *const fn (config: KernelConfig) f64,
    ) !KernelConfig {
        var best_config: ?KernelConfig = null;
        var best_time: f64 = std.math.floatMax(f64);
        
        for (candidates) |config| {
            // Warmup
            for (0..10) |_| {
                _ = benchmark_fn(config);
            }
            
            // Benchmark
            var total_time: f64 = 0;
            for (0..self.tuning_iterations) |_| {
                total_time += benchmark_fn(config);
            }
            const avg_time = total_time / @as(f64, @floatFromInt(self.tuning_iterations));
            
            if (avg_time < best_time) {
                best_time = avg_time;
                best_config = config;
            }
        }
        
        if (best_config) |config| {
            try self.tuned_configs.put(name, config);
            return config;
        }
        
        return candidates[0];
    }
    
    /// Get tuned config for a kernel
    pub fn getConfig(self: *AutoTuner, name: []const u8) ?KernelConfig {
        return self.tuned_configs.get(name);
    }
    
    /// Auto-tune batch size for optimal throughput
    pub fn tuneBatchSize(
        self: *AutoTuner,
        min_batch: u32,
        max_batch: u32,
        benchmark_fn: *const fn (batch_size: u32) f64,
    ) u32 {
        _ = self;
        var best_batch: u32 = min_batch;
        var best_throughput: f64 = 0;
        
        var batch_size = min_batch;
        while (batch_size <= max_batch) : (batch_size *= 2) {
            const throughput = benchmark_fn(batch_size);
            
            if (throughput > best_throughput) {
                best_throughput = throughput;
                best_batch = batch_size;
            }
        }
        
        return best_batch;
    }
};

pub const TuningResult = struct {
    kernel_name: []const u8,
    config: KernelConfig,
    latency_us: f64,
};

// ==============================================
// Memory Optimization
// ==============================================

pub const MemoryOptimizer = struct {
    config: PerformanceConfig,
    
    pub fn init(config: PerformanceConfig) MemoryOptimizer {
        return .{ .config = config };
    }
    
    /// Compute aligned size
    pub fn alignSize(self: *MemoryOptimizer, size: usize) usize {
        return std.mem.alignForward(usize, size, self.config.memory_alignment);
    }
    
    /// Check if memory access is coalesced
    pub fn isCoalesced(self: *MemoryOptimizer, address: usize, access_size: usize) bool {
        _ = access_size;
        return address % self.config.memory_alignment == 0;
    }
    
    /// Compute optimal tile size for matrix operations
    pub fn computeTileSize(
        self: *MemoryOptimizer,
        m: usize,
        n: usize,
        k: usize,
        element_size: usize,
    ) TileConfig {
        _ = self;
        // Heuristic: fit tiles in L2 cache (~40MB on modern GPUs)
        const l2_cache_size: usize = 40 * 1024 * 1024;
        
        // Each tile needs: tile_m * tile_k + tile_k * tile_n + tile_m * tile_n
        // Start with default and adjust
        var tile_m: usize = 128;
        var tile_n: usize = 128;
        var tile_k: usize = 32;
        
        while (true) {
            const tile_bytes = (tile_m * tile_k + tile_k * tile_n + tile_m * tile_n) * element_size;
            if (tile_bytes <= l2_cache_size / 4) break;
            
            // Reduce tile sizes
            if (tile_m > 32) {
                tile_m /= 2;
            } else if (tile_n > 32) {
                tile_n /= 2;
            } else {
                break;
            }
        }
        
        return .{
            .tile_m = @min(tile_m, m),
            .tile_n = @min(tile_n, n),
            .tile_k = @min(tile_k, k),
        };
    }
};

pub const TileConfig = struct {
    tile_m: usize,
    tile_n: usize,
    tile_k: usize,
};

// ==============================================
// Tests
// ==============================================

test "Profiler basic" {
    const allocator = std.testing.allocator;
    var profiler = Profiler.init(allocator, true);
    defer profiler.deinit();
    
    profiler.startProfile();
    profiler.startKernel("test_kernel");
    std.time.sleep(1000);
    profiler.endKernel();
    
    const report = profiler.getReport();
    try std.testing.expect(report.total_time_us > 0);
}

test "TimingStats" {
    var stats = TimingStats.init("test");
    stats.addSample(100);
    stats.addSample(200);
    stats.addSample(150);
    
    try std.testing.expectEqual(@as(u64, 3), stats.count);
    try std.testing.expectEqual(@as(f64, 150), stats.mean());
}

test "CudaGraphManager" {
    const allocator = std.testing.allocator;
    var manager = CudaGraphManager.init(allocator, gpu.DeviceId.cuda(0));
    defer manager.deinit();
    
    try std.testing.expect(!manager.hasGraph(1, true));
}

test "MemoryOptimizer alignment" {
    var optimizer = MemoryOptimizer.init(.{});
    try std.testing.expectEqual(@as(usize, 128), optimizer.alignSize(100));
    try std.testing.expectEqual(@as(usize, 256), optimizer.alignSize(200));
}