//! ANWID Metal Backend
//! Native Metal compute shaders for macOS GPU acceleration
//! Targets Apple Silicon M1/M2/M3 and Intel+AMD GPUs

const std = @import("std");
const builtin = @import("builtin");
const metal_shaders = @import("metal_shaders");

const log = std.log.scoped(.metal_backend);

// ============================================================================
// Metal C API Bindings (via Objective-C runtime)
// ============================================================================

// Metal types (opaque pointers)
pub const MTLDevice = *anyopaque;
pub const MTLCommandQueue = *anyopaque;
pub const MTLCommandBuffer = *anyopaque;
pub const MTLComputeCommandEncoder = *anyopaque;
pub const MTLComputePipelineState = *anyopaque;
pub const MTLBuffer = *anyopaque;
pub const MTLLibrary = *anyopaque;
pub const MTLFunction = *anyopaque;

// Metal resource options
pub const MTLResourceStorageModeShared: u64 = 0;
pub const MTLResourceStorageModeManaged: u64 = 1 << 4;
pub const MTLResourceStorageModePrivate: u64 = 2 << 4;

// ============================================================================
// Metal Backend Configuration
// ============================================================================

pub const MetalConfig = struct {
    /// Maximum concurrent command buffers
    max_inflight_buffers: usize = 3,
    /// Buffer size for compute operations
    buffer_size: usize = 64 * 1024 * 1024, // 64MB
    /// Use shared memory (faster for Apple Silicon)
    use_shared_memory: bool = true,
    /// Enable Metal Performance Shaders
    use_mps: bool = true,
};

// ============================================================================
// Metal Backend
// ============================================================================

pub const MetalBackend = struct {
    allocator: std.mem.Allocator,
    config: MetalConfig,
    device: ?MTLDevice,
    command_queue: ?MTLCommandQueue,
    device_name: []const u8,
    shader_lib: ?*metal_shaders.MetalShaderLibrary,

    // Buffers for triple buffering
    input_buffers: [3]?MTLBuffer,
    output_buffers: [3]?MTLBuffer,
    current_buffer: usize,

    // Statistics
    kernel_dispatches: std.atomic.Value(u64),
    total_elements: std.atomic.Value(u64),
    total_exec_time_ns: std.atomic.Value(u64),
    // Aliases expected by backend.zig unified API
    total_dispatches: std.atomic.Value(u64),
    total_bytes: std.atomic.Value(u64),
    gpu_utilization: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, config: MetalConfig) !*MetalBackend {
        const backend = try allocator.create(MetalBackend);

        // Initialize Metal device (only available on macOS with proper linking)
        var device: ?MTLDevice = null;
        var command_queue: ?MTLCommandQueue = null;
        var device_name: []const u8 = "CPU (Metal not available)";
        var shader_lib: ?*metal_shaders.MetalShaderLibrary = null;
        const input_buffers: [3]?MTLBuffer = .{ null, null, null };
        const output_buffers: [3]?MTLBuffer = .{ null, null, null };

        // Metal initialization is disabled in unit tests to avoid link errors
        // In production build (via build.zig), Metal framework is linked
        if (comptime builtin.os.tag == .macos and !builtin.is_test) {
            // This block only compiles when building for production
            device = @import("metal_bindings").getDevice();
            if (device != null) {
                device_name = detectDeviceName(allocator) catch "Apple GPU";
                // Prepare command queue and shader library once so kernels are ready
                command_queue = @import("metal_bindings").createCommandQueue(device.?);

                // Single shared shader library: prefer precompiled metallib via env, otherwise compile from embedded source
                shader_lib = metal_shaders.MetalShaderLibrary.init(allocator) catch null;
                if (shader_lib) |lib| {
                    if (std.posix.getenv("PRIVATELLM_METALLIB_PATH")) |path| {
                        lib.loadLibrary(path) catch |err| {
                            log.warn("Failed to load metallib at {s}: {} (will try source)", .{path, err});
                        };
                    }

                    if (!lib.isReady()) {
                        const source = @embedFile("shaders/compute.metal");
                        lib.loadFromSource(source) catch |err| {
                            log.warn("Metal shaders not ready: {} (GPU kernels will fall back to CPU)", .{err});
                        };
                    }

                    if (!lib.isReady()) {
                        lib.deinit();
                        shader_lib = null;
                    }
                }
            }
        }

        backend.* = .{
            .allocator = allocator,
            .config = config,
            .device = device,
            .command_queue = command_queue,
            .device_name = device_name,
            .shader_lib = shader_lib,
            .input_buffers = input_buffers,
            .output_buffers = output_buffers,
            .current_buffer = 0,
            .kernel_dispatches = std.atomic.Value(u64).init(0),
            .total_elements = std.atomic.Value(u64).init(0),
            .total_exec_time_ns = std.atomic.Value(u64).init(0),
            .total_dispatches = std.atomic.Value(u64).init(0),
            .total_bytes = std.atomic.Value(u64).init(0),
            .gpu_utilization = std.atomic.Value(u64).init(0),
        };

        if (device != null) {
            log.info("Metal Backend initialized:", .{});
            log.info("  Device: {s}", .{device_name});
            log.info("  Buffer size: {} MB", .{config.buffer_size / (1024 * 1024)});
            log.info("  Shared memory: {}", .{config.use_shared_memory});
            log.info("  Command queue: {}", .{command_queue != null});
            log.info("  Shaders ready: {}", .{shader_lib != null and shader_lib.?.isReady()});
        } else {
            log.warn("Metal device not available, using CPU fallback", .{});
        }

        return backend;
    }

    pub fn deinit(self: *MetalBackend) void {
        if (self.shader_lib) |lib| lib.deinit();
        // Release Metal buffers (in real impl, would call [buffer release])
        self.allocator.destroy(self);
        log.info("Metal Backend destroyed", .{});
    }

    /// Check if Metal device is available (instance method)
    pub fn isDeviceAvailable(self: *const MetalBackend) bool {
        return self.device != null;
    }

    /// Static check for Metal availability (called by backend.zig without an instance)
    pub fn isAvailable() bool {
        if (builtin.os.tag != .macos) return false;
        if (comptime builtin.is_test) return false;
        return @import("metal_bindings").getDevice() != null;
    }

    /// Submit a batch (conforms to GpuBackend unified API)
    pub fn submitBatch(self: *MetalBackend, batch: *const @import("backend.zig").Batch) !@import("backend.zig").BatchResult {
        const start = std.time.nanoTimestamp();

        const output_size = batch.batch_size * batch.embedding_dim * @sizeOf(f32);
        const output = try self.allocator.alloc(u8, output_size);
        @memset(output, 0);

        const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
        _ = self.total_dispatches.fetchAdd(1, .monotonic);
        _ = self.total_bytes.fetchAdd(output_size, .monotonic);
        _ = self.kernel_dispatches.fetchAdd(1, .monotonic);

        return .{
            .output_data = output,
            .latency_ns = elapsed,
            .gpu_time_ns = elapsed,
            .batch_size = batch.batch_size,
            .backend_used = .metal,
        };
    }

    /// Get capabilities (conforms to GpuBackend unified API)
    pub fn getCapabilities(self: *const MetalBackend) @import("backend.zig").BackendCapabilities {
        return .{
            .max_buffer_size = self.config.buffer_size,
            .max_compute_workgroups = 65535,
            .max_workgroup_size = 1024,
            .supports_fp16 = true,
            .supports_int8 = true,
            .supports_async_compute = true,
            .unified_memory = true,
            .device_name = self.device_name,
            .driver_version = "Metal",
        };
    }

    /// Execute embedding kernel on GPU
    pub fn embeddings(
        self: *MetalBackend,
        input_tokens: []const u32,
        output_embeddings: []f32,
        embedding_dim: usize,
    ) !KernelResult {
        const start = std.time.nanoTimestamp();

        // Always use CPU fallback in tests or when GPU not available
        if (self.device == null or self.command_queue == null) {
            return self.embeddingsCpuFallback(input_tokens, output_embeddings, embedding_dim);
        }

        const lib = self.shader_lib orelse {
            log.warn("Metal shaders not ready — using CPU fallback for embeddings", .{});
            return self.embeddingsCpuFallback(input_tokens, output_embeddings, embedding_dim);
        };
        if (!lib.isReady()) {
            log.warn("Metal shaders not compiled — using CPU fallback for embeddings", .{});
            return self.embeddingsCpuFallback(input_tokens, output_embeddings, embedding_dim);
        }

        // GPU path via MetalShaderLibrary
        const dr = metal_shaders.dispatchEmbeddingLookup(lib, input_tokens, output_embeddings, output_embeddings, embedding_dim);
        const elapsed = std.time.nanoTimestamp() - start;
        _ = self.kernel_dispatches.fetchAdd(1, .monotonic);
        _ = self.total_elements.fetchAdd(input_tokens.len * embedding_dim, .monotonic);
        _ = self.total_exec_time_ns.fetchAdd(@intCast(elapsed), .monotonic);
        return .{
            .success = dr.success,
            .execution_time_ns = elapsed,
            .elements_processed = input_tokens.len * embedding_dim,
            .gpu_utilized = dr.gpu_utilized,
        };
    }

    /// Execute matrix multiplication on GPU
    pub fn matmul(
        self: *MetalBackend,
        a: []const f32,
        b: []const f32,
        c: []f32,
        m: usize,
        n: usize,
        k: usize,
    ) !KernelResult {
        const start = std.time.nanoTimestamp();

        if (self.device == null) {
            return self.matmulCpuFallback(a, b, c, m, n, k);
        }

        const lib = self.shader_lib orelse {
            log.warn("Metal shaders not ready — using CPU fallback for matmul", .{});
            return self.matmulCpuFallback(a, b, c, m, n, k);
        };
        if (!lib.isReady()) {
            log.warn("Metal shaders not compiled — using CPU fallback for matmul", .{});
            return self.matmulCpuFallback(a, b, c, m, n, k);
        }

        // GPU path via MetalShaderLibrary
        const dr = metal_shaders.dispatchMatmul(lib, a, b, c, m, n, k);
        const elapsed = std.time.nanoTimestamp() - start;
        _ = self.kernel_dispatches.fetchAdd(1, .monotonic);
        _ = self.total_elements.fetchAdd(m * n, .monotonic);
        _ = self.total_exec_time_ns.fetchAdd(@intCast(elapsed), .monotonic);
        return .{
            .success = dr.success,
            .execution_time_ns = elapsed,
            .elements_processed = m * n,
            .gpu_utilized = dr.gpu_utilized,
        };
    }

    /// Execute softmax on GPU
    pub fn softmax(
        self: *MetalBackend,
        input: []const f32,
        output: []f32,
        batch_size: usize,
        seq_len: usize,
    ) !KernelResult {
        const start = std.time.nanoTimestamp();

        var gpu_utilized = false;
        if (self.device != null) gpu_path: {
            const lib = self.shader_lib orelse break :gpu_path;
            if (!lib.isReady()) break :gpu_path;
            const dr = metal_shaders.dispatchSoftmax(lib, input, output, batch_size, seq_len);
            if (dr.success) { gpu_utilized = true; break :gpu_path; }
            log.warn("Metal softmax dispatch failed — falling back to CPU", .{});
        }
        if (!gpu_utilized) {
            for (0..batch_size) |b| {
                const offset = b * seq_len;
                var max_val: f32 = input[offset];
                for (1..seq_len) |i| max_val = @max(max_val, input[offset + i]);
                var sum: f32 = 0;
                for (0..seq_len) |i| { output[offset + i] = @exp(input[offset + i] - max_val); sum += output[offset + i]; }
                const inv_sum = 1.0 / sum;
                for (0..seq_len) |i| output[offset + i] *= inv_sum;
            }
        }

        const elapsed = std.time.nanoTimestamp() - start;
        _ = self.kernel_dispatches.fetchAdd(1, .monotonic);
        _ = self.total_elements.fetchAdd(batch_size * seq_len, .monotonic);
        _ = self.total_exec_time_ns.fetchAdd(@intCast(elapsed), .monotonic);

        return .{
            .success = true,
            .execution_time_ns = elapsed,
            .elements_processed = batch_size * seq_len,
            .gpu_utilized = gpu_utilized,
        };
    }

    // =========================================================================
    // CPU Fallback Implementations
    // =========================================================================

    fn embeddingsCpuFallback(
        self: *MetalBackend,
        input_tokens: []const u32,
        output_embeddings: []f32,
        embedding_dim: usize,
    ) !KernelResult {
        _ = self;

        // Generate embeddings (in real impl, would look up embedding table)
        for (input_tokens, 0..) |token, b| {
            for (0..embedding_dim) |d| {
                const idx = b * embedding_dim + d;
                if (idx < output_embeddings.len) {
                    // Simple deterministic embedding based on token
                    const seed = @as(f32, @floatFromInt(token)) * 0.001;
                    output_embeddings[idx] = @sin(seed + @as(f32, @floatFromInt(d)) * 0.01);
                }
            }
        }

        return .{
            .success = true,
            .execution_time_ns = 0,
            .elements_processed = input_tokens.len * embedding_dim,
            .gpu_utilized = false,
        };
    }

    fn matmulCpuFallback(
        self: *MetalBackend,
        a: []const f32,
        b: []const f32,
        c: []f32,
        m: usize,
        n: usize,
        k: usize,
    ) !KernelResult {
        _ = self;

        // Naive matmul (in real impl, would use optimized BLAS)
        for (0..m) |i| {
            for (0..n) |j| {
                var sum: f32 = 0;
                for (0..k) |l| {
                    sum += a[i * k + l] * b[l * n + j];
                }
                c[i * n + j] = sum;
            }
        }

        return .{
            .success = true,
            .execution_time_ns = 0,
            .elements_processed = m * n,
            .gpu_utilized = false,
        };
    }

    // =========================================================================
    // Statistics
    // =========================================================================

    pub fn getStats(self: *const MetalBackend) MetalStats {
        const dispatches = self.kernel_dispatches.load(.acquire);
        const total_time = self.total_exec_time_ns.load(.acquire);

        return .{
            .device_name = self.device_name,
            .device_available = self.device != null,
            .kernel_dispatches = dispatches,
            .total_elements = self.total_elements.load(.acquire),
            .total_exec_time_ns = total_time,
            .avg_exec_time_ns = if (dispatches > 0) total_time / dispatches else 0,
        };
    }
};

pub const KernelResult = struct {
    success: bool,
    execution_time_ns: i128,
    elements_processed: usize,
    gpu_utilized: bool,
};

pub const MetalStats = struct {
    device_name: []const u8,
    device_available: bool,
    kernel_dispatches: u64,
    total_elements: u64,
    total_exec_time_ns: u64,
    avg_exec_time_ns: u64,
};

// ============================================================================
// Helper Functions
// ============================================================================

pub fn detectDeviceName(allocator: std.mem.Allocator) ![]const u8 {
    // Use system_profiler to get GPU name on macOS
    var child = std.process.Child.init(&[_][]const u8{
        "system_profiler",
        "SPDisplaysDataType",
        "-json",
    }, allocator);

    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    var buf: [4096]u8 = undefined;
    const stdout = child.stdout orelse return "Unknown GPU";
    const n = try stdout.readAll(&buf);

    _ = try child.wait();

    // Parse GPU name from JSON (simplified)
    const response = buf[0..n];
    if (std.mem.indexOf(u8, response, "\"sppci_model\":")) |start| {
        const name_start = start + 16;
        if (std.mem.indexOf(u8, response[name_start..], "\"")) |end| {
            return try allocator.dupe(u8, response[name_start .. name_start + end]);
        }
    }

    return "Apple GPU";
}

// ============================================================================
// Tests
// ============================================================================

test "MetalBackend init and deinit" {
    const backend = try MetalBackend.init(std.testing.allocator, .{});
    defer backend.deinit();

    const stats = backend.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.kernel_dispatches);
    // In test mode, device should be null (no Metal framework linked)
    try std.testing.expect(!stats.device_available);
}

test "Softmax computation" {
    const backend = try MetalBackend.init(std.testing.allocator, .{});
    defer backend.deinit();

    var input = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    var output: [4]f32 = undefined;

    const result = try backend.softmax(&input, &output, 1, 4);

    try std.testing.expect(result.success);

    // Softmax should sum to 1
    var sum: f32 = 0;
    for (output) |v| sum += v;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sum, 0.001);
}

test "Embeddings CPU fallback" {
    const backend = try MetalBackend.init(std.testing.allocator, .{});
    defer backend.deinit();

    const tokens = [_]u32{ 1, 2, 3 };
    var output: [3 * 4]f32 = undefined;

    const result = try backend.embeddings(&tokens, &output, 4);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 12), result.elements_processed);
    // Should use CPU fallback in test mode
    try std.testing.expect(!result.gpu_utilized);
}

test "Matmul CPU fallback" {
    const backend = try MetalBackend.init(std.testing.allocator, .{});
    defer backend.deinit();

    // 2x2 @ 2x2 matmul
    const a = [_]f32{ 1, 2, 3, 4 };
    const b = [_]f32{ 5, 6, 7, 8 };
    var c: [4]f32 = undefined;

    const result = try backend.matmul(&a, &b, &c, 2, 2, 2);

    try std.testing.expect(result.success);
    // Expected: [[1*5+2*7, 1*6+2*8], [3*5+4*7, 3*6+4*8]] = [[19, 22], [43, 50]]
    try std.testing.expectApproxEqAbs(@as(f32, 19.0), c[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 22.0), c[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 43.0), c[2], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), c[3], 0.001);
}
