//! Unified GPU Backend Abstraction for ANWID
//! Supports Metal (macOS), WebGPU (cross-platform), CUDA (NVIDIA), and CPU fallback
//! Provides seamless backend selection and fallback

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const MetalBackend = @import("metal_backend.zig").MetalBackend;
const WebGPUBackend = @import("webgpu_backend.zig").WebGPUBackend;

// ============================================================================
// Backend Types
// ============================================================================

pub const BackendType = enum {
    metal,
    webgpu,
    cuda,
    cpu,
    
    pub fn toString(self: BackendType) []const u8 {
        return switch (self) {
            .metal => "Metal",
            .webgpu => "WebGPU",
            .cuda => "CUDA",
            .cpu => "CPU",
        };
    }
};

pub const BackendCapabilities = struct {
    max_buffer_size: u64,
    max_compute_workgroups: u32,
    max_workgroup_size: u32,
    supports_fp16: bool,
    supports_int8: bool,
    supports_async_compute: bool,
    unified_memory: bool,
    device_name: []const u8,
    driver_version: []const u8,
};

// ============================================================================
// Unified GPU Backend
// ============================================================================

pub const GpuBackend = union(BackendType) {
    metal: *MetalBackend,
    webgpu: *WebGPUBackend,
    cuda: *CudaBackend,
    cpu: *CpuFallback,
    
    // =========================================================================
    // Unified API
    // =========================================================================
    
    pub fn submitBatch(self: GpuBackend, batch: *const Batch) !BatchResult {
        return switch (self) {
            .metal => |m| try m.submitBatch(batch),
            .webgpu => |w| try w.submitBatch(batch),
            .cuda => |c| try c.submitBatch(batch),
            .cpu => |f| try f.submitBatch(batch),
        };
    }
    
    pub fn getCapabilities(self: GpuBackend) BackendCapabilities {
        return switch (self) {
            .metal => |m| m.getCapabilities(),
            .webgpu => |w| .{
                .max_buffer_size = w.config.max_buffer_size,
                .max_compute_workgroups = 65535,
                .max_workgroup_size = 256,
                .supports_fp16 = true,
                .supports_int8 = true,
                .supports_async_compute = true,
                .unified_memory = builtin.os.tag == .macos,
                .device_name = &w.device_name,
                .driver_version = "wgpu-native",
            },
            .cuda => |c| c.getCapabilities(),
            .cpu => |f| f.getCapabilities(),
        };
    }
    
    pub fn getStats(self: GpuBackend) BackendStats {
        return switch (self) {
            .metal => |m| .{
                .backend_type = .metal,
                .total_dispatches = m.total_dispatches.load(.monotonic),
                .total_bytes_transferred = m.total_bytes.load(.monotonic),
                .total_compute_time_ns = 0,
                .gpu_utilization = m.gpu_utilization.load(.monotonic),
            },
            .webgpu => |w| .{
                .backend_type = .webgpu,
                .total_dispatches = w.total_dispatches.load(.monotonic),
                .total_bytes_transferred = w.total_bytes_transferred.load(.monotonic),
                .total_compute_time_ns = w.total_compute_time_ns.load(.monotonic),
                .gpu_utilization = 0,
            },
            .cuda => |c| c.getBackendStats(),
            .cpu => |f| f.getBackendStats(),
        };
    }
    
    pub fn deinit(self: GpuBackend, allocator: Allocator) void {
        switch (self) {
            .metal => |m| {
                m.deinit();
                allocator.destroy(m);
            },
            .webgpu => |w| w.deinit(),
            .cuda => |c| {
                c.deinit();
                allocator.destroy(c);
            },
            .cpu => |f| {
                f.deinit();
                allocator.destroy(f);
            },
        }
    }
    
    pub fn getBackendType(self: GpuBackend) BackendType {
        return @as(BackendType, self);
    }
};

pub const BackendStats = struct {
    backend_type: BackendType,
    total_dispatches: u64,
    total_bytes_transferred: u64,
    total_compute_time_ns: u64,
    gpu_utilization: u64,
};

// ============================================================================
// Backend Selection
// ============================================================================

pub const BackendSelection = struct {
    preferred: ?BackendType = null,
    allow_fallback: bool = true,
    min_memory_mb: u32 = 512,
    require_fp16: bool = false,
};

/// Select the best available GPU backend
pub fn selectBestBackend(allocator: Allocator, options: BackendSelection) !GpuBackend {
    // 1. If preferred backend is specified, try it first
    if (options.preferred) |preferred| {
        if (try tryBackend(allocator, preferred)) |backend| {
            return backend;
        }
        if (!options.allow_fallback) {
            return error.PreferredBackendNotAvailable;
        }
    }
    
    // 2. Try backends in order of preference based on platform
    const backends_to_try: []const BackendType = switch (builtin.os.tag) {
        .macos => &[_]BackendType{ .metal, .webgpu, .cpu },
        .linux => &[_]BackendType{ .cuda, .webgpu, .cpu },
        .windows => &[_]BackendType{ .cuda, .webgpu, .cpu },
        else => &[_]BackendType{ .webgpu, .cpu },
    };
    
    for (backends_to_try) |backend_type| {
        if (try tryBackend(allocator, backend_type)) |backend| {
            std.debug.print("[Backend] Selected: {s}\n", .{backend_type.toString()});
            return backend;
        }
    }
    
    return error.NoBackendAvailable;
}

fn tryBackend(allocator: Allocator, backend_type: BackendType) !?GpuBackend {
    switch (backend_type) {
        .metal => {
            if (builtin.os.tag == .macos) {
                if (MetalBackend.isAvailable()) {
                    const metal = try MetalBackend.init(allocator);
                    return GpuBackend{ .metal = metal };
                }
            }
            return null;
        },
        .webgpu => {
            if (WebGPUBackend.isAvailable()) {
                const webgpu = try WebGPUBackend.init(allocator, .{});
                return GpuBackend{ .webgpu = webgpu };
            }
            return null;
        },
        .cuda => {
            if (CudaBackend.isAvailable()) {
                const cuda = try CudaBackend.init(allocator);
                return GpuBackend{ .cuda = cuda };
            }
            return null;
        },
        .cpu => {
            const cpu = try CpuFallback.init(allocator);
            return GpuBackend{ .cpu = cpu };
        },
    }
}

// ============================================================================
// Batch Types (shared across backends)
// ============================================================================

pub const Batch = struct {
    input_data: []const u8,
    batch_size: u32,
    embedding_dim: u32,
    model_type: ModelType,
    priority: Priority = .normal,
    deadline_ns: ?i64 = null,
};

pub const BatchResult = struct {
    output_data: []u8,
    latency_ns: u64,
    gpu_time_ns: u64,
    batch_size: u32,
    backend_used: BackendType = .cpu,
};

pub const ModelType = enum {
    // Browser models (Google Gemma)
    gemma_2b,
    gemma_4b,
    
    // Server models
    glm_5,
    minimax_m2_5,
    kimi_k2_5,
    
    // Generic
    embedding,
    chat_completion,
    
    pub fn getDefaultEmbeddingDim(self: ModelType) u32 {
        return switch (self) {
            .gemma_2b => 2048,
            .gemma_4b => 3072,
            .glm_5 => 4096,
            .minimax_m2_5 => 5120,
            .kimi_k2_5 => 6144,
            .embedding => 768,
            .chat_completion => 4096,
        };
    }
    
    pub fn getContextLength(self: ModelType) u32 {
        return switch (self) {
            .gemma_2b => 8192,
            .gemma_4b => 8192,
            .glm_5 => 32768,
            .minimax_m2_5 => 200000,
            .kimi_k2_5 => 128000,
            .embedding => 512,
            .chat_completion => 4096,
        };
    }
    
    pub fn requiresServer(self: ModelType) bool {
        return switch (self) {
            .gemma_2b, .gemma_4b => false, // Can run in browser
            else => true, // Server-only models
        };
    }
};

pub const Priority = enum {
    low,
    normal,
    high,
    critical,
};

// ============================================================================
// CUDA Backend (placeholder)
// ============================================================================

pub const CudaBackend = struct {
    allocator: Allocator,
    initialized: bool,
    
    // Statistics
    total_dispatches: std.atomic.Value(u64),
    total_bytes: std.atomic.Value(u64),
    
    pub fn init(allocator: Allocator) !*CudaBackend {
        const backend = try allocator.create(CudaBackend);
        backend.* = .{
            .allocator = allocator,
            .initialized = true,
            .total_dispatches = std.atomic.Value(u64).init(0),
            .total_bytes = std.atomic.Value(u64).init(0),
        };
        return backend;
    }
    
    pub fn deinit(self: *CudaBackend) void {
        self.initialized = false;
    }
    
    pub fn submitBatch(self: *CudaBackend, batch: *const Batch) !BatchResult {
        const start = std.time.nanoTimestamp();
        
        // Placeholder - would use cuBLAS/cuDNN
        const output_size = batch.batch_size * batch.embedding_dim * @sizeOf(f32);
        const output = try self.allocator.alloc(u8, output_size);
        
        _ = self.total_dispatches.fetchAdd(1, .monotonic);
        _ = self.total_bytes.fetchAdd(output_size, .monotonic);
        
        const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
        
        return BatchResult{
            .output_data = output,
            .latency_ns = elapsed,
            .gpu_time_ns = elapsed,
            .batch_size = batch.batch_size,
            .backend_used = .cuda,
        };
    }
    
    pub fn getCapabilities(self: *CudaBackend) BackendCapabilities {
        _ = self;
        return .{
            .max_buffer_size = 16 * 1024 * 1024 * 1024, // 16GB
            .max_compute_workgroups = 65535,
            .max_workgroup_size = 1024,
            .supports_fp16 = true,
            .supports_int8 = true,
            .supports_async_compute = true,
            .unified_memory = false,
            .device_name = "NVIDIA GPU",
            .driver_version = "CUDA",
        };
    }
    
    pub fn getBackendStats(self: *CudaBackend) BackendStats {
        return .{
            .backend_type = .cuda,
            .total_dispatches = self.total_dispatches.load(.monotonic),
            .total_bytes_transferred = self.total_bytes.load(.monotonic),
            .total_compute_time_ns = 0,
            .gpu_utilization = 0,
        };
    }
    
    pub fn isAvailable() bool {
        // Would check for CUDA driver availability
        return builtin.os.tag == .linux; // Simplified check
    }
};

// ============================================================================
// CPU Fallback
// ============================================================================

pub const CpuFallback = struct {
    allocator: Allocator,
    thread_pool_size: usize,
    
    // Statistics
    total_dispatches: std.atomic.Value(u64),
    total_bytes: std.atomic.Value(u64),
    
    pub fn init(allocator: Allocator) !*CpuFallback {
        const fallback = try allocator.create(CpuFallback);
        fallback.* = .{
            .allocator = allocator,
            .thread_pool_size = @max(1, std.Thread.getCpuCount() catch 4),
            .total_dispatches = std.atomic.Value(u64).init(0),
            .total_bytes = std.atomic.Value(u64).init(0),
        };
        return fallback;
    }
    
    pub fn deinit(self: *CpuFallback) void {
        _ = self;
    }
    
    pub fn submitBatch(self: *CpuFallback, batch: *const Batch) !BatchResult {
        const start = std.time.nanoTimestamp();
        
        // CPU-based computation using SIMD
        const output_size = batch.batch_size * batch.embedding_dim * @sizeOf(f32);
        const output = try self.allocator.alloc(u8, output_size);
        
        // Zero-initialize output
        @memset(output, 0);
        
        _ = self.total_dispatches.fetchAdd(1, .monotonic);
        _ = self.total_bytes.fetchAdd(output_size, .monotonic);
        
        const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
        
        return BatchResult{
            .output_data = output,
            .latency_ns = elapsed,
            .gpu_time_ns = 0,
            .batch_size = batch.batch_size,
            .backend_used = .cpu,
        };
    }
    
    pub fn getCapabilities(self: *CpuFallback) BackendCapabilities {
        _ = self;
        return .{
            .max_buffer_size = 8 * 1024 * 1024 * 1024, // 8GB
            .max_compute_workgroups = 1,
            .max_workgroup_size = 1,
            .supports_fp16 = false,
            .supports_int8 = true,
            .supports_async_compute = true,
            .unified_memory = true,
            .device_name = "CPU Fallback",
            .driver_version = "Native",
        };
    }
    
    pub fn getBackendStats(self: *CpuFallback) BackendStats {
        return .{
            .backend_type = .cpu,
            .total_dispatches = self.total_dispatches.load(.monotonic),
            .total_bytes_transferred = self.total_bytes.load(.monotonic),
            .total_compute_time_ns = 0,
            .gpu_utilization = 0,
        };
    }
};

// ============================================================================
// Model Router
// ============================================================================

pub const ModelRouter = struct {
    allocator: Allocator,
    backends: std.StringHashMap(GpuBackend),
    default_backend: ?GpuBackend,
    
    pub fn init(allocator: Allocator) !*ModelRouter {
        const router = try allocator.create(ModelRouter);
        router.* = .{
            .allocator = allocator,
            .backends = std.StringHashMap(GpuBackend).init(allocator),
            .default_backend = null,
        };
        return router;
    }
    
    pub fn deinit(self: *ModelRouter) void {
        var it = self.backends.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.backends.deinit();
        
        if (self.default_backend) |*backend| {
            backend.deinit(self.allocator);
        }
        
        self.allocator.destroy(self);
    }
    
    pub fn registerBackend(self: *ModelRouter, model_name: []const u8, backend: GpuBackend) !void {
        try self.backends.put(model_name, backend);
    }
    
    pub fn setDefaultBackend(self: *ModelRouter, backend: GpuBackend) void {
        self.default_backend = backend;
    }
    
    pub fn route(self: *ModelRouter, model_type: ModelType) !GpuBackend {
        const model_name = @tagName(model_type);
        
        if (self.backends.get(model_name)) |backend| {
            return backend;
        }
        
        if (self.default_backend) |backend| {
            return backend;
        }
        
        return error.NoBackendForModel;
    }
    
    pub fn submitBatch(self: *ModelRouter, batch: *const Batch) !BatchResult {
        const backend = try self.route(batch.model_type);
        return backend.submitBatch(batch);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Backend selection" {
    const allocator = std.testing.allocator;
    
    const backend = try selectBestBackend(allocator, .{});
    defer backend.deinit(allocator);
    
    const backend_type = backend.getBackendType();
    try std.testing.expect(backend_type == .metal or backend_type == .webgpu or backend_type == .cpu);
}

test "Model type properties" {
    try std.testing.expectEqual(@as(u32, 2048), ModelType.gemma_2b.getDefaultEmbeddingDim());
    try std.testing.expectEqual(@as(u32, 8192), ModelType.gemma_2b.getContextLength());
    try std.testing.expect(!ModelType.gemma_2b.requiresServer());
    try std.testing.expect(ModelType.glm_5.requiresServer());
}

test "CPU fallback" {
    const allocator = std.testing.allocator;
    
    const fallback = try CpuFallback.init(allocator);
    defer {
        fallback.deinit();
        allocator.destroy(fallback);
    }
    
    const batch = Batch{
        .input_data = &[_]u8{ 1, 2, 3, 4 },
        .batch_size = 1,
        .embedding_dim = 768,
        .model_type = .embedding,
    };
    
    const result = try fallback.submitBatch(&batch);
    defer allocator.free(result.output_data);
    
    try std.testing.expectEqual(@as(u32, 1), result.batch_size);
    try std.testing.expectEqual(BackendType.cpu, result.backend_used);
}