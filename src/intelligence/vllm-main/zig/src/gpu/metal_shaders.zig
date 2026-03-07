//! Metal Shader Compiler and Dispatcher
//! Compiles .metal source to .metallib and dispatches compute kernels
//! Requires macOS with Metal framework

const std = @import("std");
const builtin = @import("builtin");
const metal_bindings = @import("metal_bindings");

const log = std.log.scoped(.metal_shaders);

// ============================================================================
// Kernel Function Names (must match compute.metal)
// ============================================================================

pub const KernelName = enum {
    vector_add,
    vector_scale,
    vector_mul,
    embedding_lookup,
    matmul_naive,
    matmul_tiled,
    softmax_row,
    softmax_parallel,
    layer_norm,
    layer_norm_simple,
    cosine_similarity,
    cosine_similarity_batch,
    relu,
    gelu,
    attention_single_head,
    
    pub fn toString(self: KernelName) []const u8 {
        return switch (self) {
            .vector_add => "vector_add",
            .vector_scale => "vector_scale",
            .vector_mul => "vector_mul",
            .embedding_lookup => "embedding_lookup",
            .matmul_naive => "matmul_naive",
            .matmul_tiled => "matmul_tiled",
            .softmax_row => "softmax_row",
            .softmax_parallel => "softmax_parallel",
            .layer_norm => "layer_norm",
            .layer_norm_simple => "layer_norm_simple",
            .cosine_similarity => "cosine_similarity",
            .cosine_similarity_batch => "cosine_similarity_batch",
            .relu => "relu",
            .gelu => "gelu",
            .attention_single_head => "attention_single_head",
        };
    }
};

// ============================================================================
// Dispatch Configuration
// ============================================================================

pub const DispatchConfig = struct {
    /// Grid dimensions (total threads)
    grid_size: [3]u32 = .{ 1, 1, 1 },
    /// Threadgroup dimensions
    threadgroup_size: [3]u32 = .{ 256, 1, 1 },
    
    pub fn for1D(count: usize) DispatchConfig {
        const threads_per_group: u32 = 256;
        return .{
            .grid_size = .{ @intCast(count), 1, 1 },
            .threadgroup_size = .{ threads_per_group, 1, 1 },
        };
    }
    
    pub fn for2D(width: usize, height: usize) DispatchConfig {
        return .{
            .grid_size = .{ @intCast(width), @intCast(height), 1 },
            .threadgroup_size = .{ 16, 16, 1 },
        };
    }
    
    pub fn forMatmul(m: usize, n: usize) DispatchConfig {
        // Use 16x16 tiles for tiled matmul
        const tile_size: u32 = 16;
        return .{
            .grid_size = .{ @intCast(n), @intCast(m), 1 },
            .threadgroup_size = .{ tile_size, tile_size, 1 },
        };
    }
};

// ============================================================================
// Buffer Pool for reusing Metal buffers
// ============================================================================

const BufferPool = struct {
    device: *anyopaque,
    allocator: std.mem.Allocator,
    // Simple fixed-size buffer cache by bucket
    // Bucket 0: small (<8K), 1: medium (<64K), 2: large (<1MB), 3: xlarge
    cache: [4][8]?*anyopaque,
    cache_counts: [4]u8,
    
    fn init(allocator: std.mem.Allocator, device: *anyopaque) BufferPool {
        return BufferPool{
            .device = device,
            .allocator = allocator,
            .cache = .{.{null} ** 8} ** 4,
            .cache_counts = .{0} ** 4,
        };
    }
    
    fn deinit(self: *BufferPool) void {
        for (self.cache) |bucket| {
            for (bucket) |maybe_buf| {
                if (maybe_buf) |buf| {
                    metal_bindings.release(buf);
                }
            }
        }
    }
    
    fn sizeToBucket(size: usize) usize {
        if (size <= 8192) return 0;
        if (size <= 65536) return 1;
        if (size <= 1048576) return 2;
        return 3;
    }
    
    fn bucketToSize(bucket: usize) usize {
        return switch (bucket) {
            0 => 8192,
            1 => 65536,
            2 => 1048576,
            else => 16777216,
        };
    }
    
    pub fn acquire(self: *BufferPool, size: usize) ?*anyopaque {
        const bucket = sizeToBucket(size);
        const bucket_size = bucketToSize(bucket);
        
        // Try to get from cache
        if (self.cache_counts[bucket] > 0) {
            self.cache_counts[bucket] -= 1;
            const idx = self.cache_counts[bucket];
            const buf = self.cache[bucket][idx];
            self.cache[bucket][idx] = null;
            return buf;
        }
        
        // Create new buffer with bucket size
        if (comptime builtin.os.tag == .macos) {
            return metal_bindings.createSharedBuffer(self.device, @intCast(bucket_size));
        }
        return null;
    }
    
    pub fn release(self: *BufferPool, buffer: *anyopaque, size: usize) void {
        const bucket = sizeToBucket(size);
        // Keep at most 8 buffers per bucket
        if (self.cache_counts[bucket] < 8) {
            self.cache[bucket][self.cache_counts[bucket]] = buffer;
            self.cache_counts[bucket] += 1;
        } else {
            metal_bindings.release(buffer);
        }
    }
};

// ============================================================================
// Metal Shader Library
// ============================================================================

pub const MetalShaderLibrary = struct {
    allocator: std.mem.Allocator,
    device: ?*anyopaque,
    library: ?*anyopaque,
    pipelines: std.AutoHashMap(KernelName, *anyopaque),
    compiled: bool,
    
    /// Cached command queue for reuse
    command_queue: ?*anyopaque,
    
    /// Buffer pool for reusing MTLBuffers
    buffer_pool: ?BufferPool,

    /// Pre-compiled metallib path
    metallib_path: ?[]const u8,
    
    pub fn init(allocator: std.mem.Allocator) !*MetalShaderLibrary {
        const lib = try allocator.create(MetalShaderLibrary);
        lib.* = .{
            .allocator = allocator,
            .device = null,
            .library = null,
            .pipelines = std.AutoHashMap(KernelName, *anyopaque).init(allocator),
            .compiled = false,
            .command_queue = null,
            .buffer_pool = null,
            .metallib_path = null,
        };
        
        // Initialize Metal device if available
        if (comptime builtin.os.tag == .macos and !builtin.is_test) {
            lib.device = metal_bindings.getDevice();
            // Create cached command queue and buffer pool
            if (lib.device) |device| {
                lib.command_queue = metal_bindings.createCommandQueue(device);
                lib.buffer_pool = BufferPool.init(allocator, device);
            }
        }
        
        return lib;
    }
    
    pub fn deinit(self: *MetalShaderLibrary) void {
        self.pipelines.deinit();
        if (self.metallib_path) |p| self.allocator.free(p);
        self.allocator.destroy(self);
    }
    
    /// Compile .metal source to .metallib
    pub fn compileFromSource(self: *MetalShaderLibrary, source_path: []const u8) !void {
        if (comptime builtin.os.tag != .macos) {
            log.warn("Metal shader compilation only supported on macOS", .{});
            return;
        }
        
        log.info("Compiling Metal shaders from: {s}", .{source_path});
        
        // Derive output paths
        const dir = std.fs.path.dirname(source_path) orelse ".";
        const air_path = try std.fmt.allocPrint(self.allocator, "{s}/compute.air", .{dir});
        defer self.allocator.free(air_path);
        
        const lib_path = try std.fmt.allocPrint(self.allocator, "{s}/compute.metallib", .{dir});
        
        // Step 1: Compile .metal to .air
        var compile_child = std.process.Child.init(&[_][]const u8{
            "xcrun",
            "-sdk", "macosx",
            "metal",
            "-c", source_path,
            "-o", air_path,
        }, self.allocator);
        compile_child.stderr_behavior = .Pipe;
        try compile_child.spawn();
        const compile_result = try compile_child.wait();
        
        if (compile_result.Exited != 0) {
            log.err("Metal compilation failed with exit code: {}", .{compile_result.Exited});
            return error.CompilationFailed;
        }
        
        // Step 2: Link .air to .metallib
        var link_child = std.process.Child.init(&[_][]const u8{
            "xcrun",
            "-sdk", "macosx",
            "metallib",
            air_path,
            "-o", lib_path,
        }, self.allocator);
        link_child.stderr_behavior = .Pipe;
        try link_child.spawn();
        const link_result = try link_child.wait();
        
        if (link_result.Exited != 0) {
            log.err("Metal library linking failed with exit code: {}", .{link_result.Exited});
            return error.LinkingFailed;
        }
        
        // Clean up .air file
        std.fs.deleteFileAbsolute(air_path) catch {};
        
        self.metallib_path = lib_path;
        log.info("Compiled Metal library: {s}", .{lib_path});
    }
    
    /// Load pre-compiled .metallib
    pub fn loadLibrary(self: *MetalShaderLibrary, path: []const u8) !void {
        if (self.device == null) {
            log.warn("No Metal device available", .{});
            return;
        }

        if (comptime builtin.os.tag == .macos and !builtin.is_test) {
            self.library = metal_bindings.newLibraryWithFile(self.device.?, path);
            if (self.library == null) {
                log.err("Failed to load Metal library from: {s}", .{path});
                return error.LibraryLoadFailed;
            }
            log.info("Loaded Metal library from: {s}", .{path});

            // Pre-create matmul pipeline
            try self.createPipeline(.matmul_tiled);
            try self.createPipeline(.matmul_naive);
            try self.createPipeline(.softmax_row);
            try self.createPipeline(.layer_norm);
            try self.createPipeline(.embedding_lookup);
        }

        self.compiled = true;
    }

    /// Create compute pipeline for a kernel
    fn createPipeline(self: *MetalShaderLibrary, kernel: KernelName) !void {
        if (self.device == null or self.library == null) return;

        if (comptime builtin.os.tag == .macos and !builtin.is_test) {
            const function = metal_bindings.newFunctionWithName(self.library.?, kernel.toString());
            if (function == null) {
                log.warn("Failed to get function: {s}", .{kernel.toString()});
                return;
            }

            const pipeline = metal_bindings.newComputePipelineStateWithFunction(self.device.?, function.?);
            if (pipeline == null) {
                log.warn("Failed to create pipeline for: {s}", .{kernel.toString()});
                return;
            }

            try self.pipelines.put(kernel, pipeline.?);
            log.info("Created Metal pipeline: {s}", .{kernel.toString()});
        }
    }

    /// Get or create a compute pipeline for a kernel
    pub fn getPipeline(self: *MetalShaderLibrary, kernel: KernelName) !?*anyopaque {
        if (self.device == null or !self.compiled) {
            return null;
        }

        if (self.pipelines.get(kernel)) |pipeline| {
            return pipeline;
        }

        // Try to create on demand
        try self.createPipeline(kernel);
        return self.pipelines.get(kernel);
    }
    
    /// Check if Metal is available and shaders are compiled
    pub fn isReady(self: *const MetalShaderLibrary) bool {
        return self.device != null and self.compiled;
    }
};

// ============================================================================
// Shader Dispatch Result
// ============================================================================

pub const DispatchResult = struct {
    success: bool,
    execution_time_ns: i128,
    elements_processed: usize,
    gpu_utilized: bool,
    error_message: ?[]const u8,
    
    pub fn ok(time_ns: i128, elements: usize, on_gpu: bool) DispatchResult {
        return .{
            .success = true,
            .execution_time_ns = time_ns,
            .elements_processed = elements,
            .gpu_utilized = on_gpu,
            .error_message = null,
        };
    }
    
    pub fn err(msg: []const u8) DispatchResult {
        return .{
            .success = false,
            .execution_time_ns = 0,
            .elements_processed = 0,
            .gpu_utilized = false,
            .error_message = msg,
        };
    }
};

// ============================================================================
// High-Level Kernel Dispatch Functions
// ============================================================================

/// Dispatch cosine similarity kernel
pub fn dispatchCosineSimilarity(
    lib: *MetalShaderLibrary,
    query: []const f32,
    documents: []const f32,
    scores: []f32,
    num_docs: usize,
    embedding_dim: usize,
) DispatchResult {
    const start = std.time.nanoTimestamp();
    
    if (lib.isReady()) {
        // Would dispatch GPU kernel here
        // For now, fall back to CPU
    }
    
    // CPU fallback
    for (0..num_docs) |doc_idx| {
        var dot: f32 = 0;
        var query_norm: f32 = 0;
        var doc_norm: f32 = 0;
        
        const doc_offset = doc_idx * embedding_dim;
        
        for (0..embedding_dim) |i| {
            const q = query[i];
            const d = documents[doc_offset + i];
            dot += q * d;
            query_norm += q * q;
            doc_norm += d * d;
        }
        
        const denom = @sqrt(query_norm) * @sqrt(doc_norm);
        scores[doc_idx] = if (denom > 0) dot / denom else 0;
    }
    
    const elapsed = std.time.nanoTimestamp() - start;
    return DispatchResult.ok(elapsed, num_docs, false);
}

/// Dispatch matrix multiplication using pre-created Metal buffer for weights (B matrix).
/// This avoids buffer allocation overhead on every call by reusing persistent weight buffers.
pub fn dispatchMatmulWithMtlBuffer(
    lib: *MetalShaderLibrary,
    a: []const f32,
    b_mtl: *anyopaque,  // Pre-created MTL buffer for weights
    c: []f32,
    m: usize,
    n: usize,
    k: usize,
) DispatchResult {
    const start = std.time.nanoTimestamp();

    if (lib.isReady()) gpu_dispatch: {
        const device = lib.device orelse break :gpu_dispatch;
        const queue = lib.command_queue orelse break :gpu_dispatch;
        var pool = &(lib.buffer_pool orelse break :gpu_dispatch);

        // Only create buffer for activation (a) - weights (b) already have persistent buffer
        const a_bytes = std.mem.sliceAsBytes(a);
        const c_size = c.len * @sizeOf(f32);

        const buf_a = metal_bindings.createBufferWithBytes(device, a_bytes, metal_bindings.MTLResourceStorageModeShared) orelse break :gpu_dispatch;
        defer metal_bindings.release(buf_a);

        // Use buffer pool for output buffer
        const buf_c = pool.acquire(c_size) orelse break :gpu_dispatch;
        defer pool.release(buf_c, c_size);

        // Get matmul pipeline
        const pipeline = lib.pipelines.get(.matmul_tiled) orelse break :gpu_dispatch;

        // Create command buffer and encoder
        const cmd_buffer = metal_bindings.createCommandBuffer(queue) orelse break :gpu_dispatch;
        defer metal_bindings.release(cmd_buffer);
        const encoder = metal_bindings.createComputeCommandEncoder(cmd_buffer) orelse break :gpu_dispatch;
        defer metal_bindings.release(encoder);

        // Set pipeline and buffers
        metal_bindings.setComputePipelineState(encoder, pipeline);
        metal_bindings.setBuffer(encoder, buf_a, 0, 0);
        metal_bindings.setBuffer(encoder, b_mtl, 0, 1);  // Use persistent buffer
        metal_bindings.setBuffer(encoder, buf_c, 0, 2);

        // Set dimensions as separate buffers
        var m_val: u32 = @intCast(m);
        var n_val: u32 = @intCast(n);
        var k_val: u32 = @intCast(k);
        metal_bindings.setBytes(encoder, @ptrCast(&m_val), @sizeOf(u32), 3);
        metal_bindings.setBytes(encoder, @ptrCast(&n_val), @sizeOf(u32), 4);
        metal_bindings.setBytes(encoder, @ptrCast(&k_val), @sizeOf(u32), 5);

        // Calculate threadgroups for tiled matmul (16x16 tiles)
        const tile_size: usize = 16;
        const grid = metal_bindings.MTLSize{
            .width = (n + tile_size - 1) / tile_size,
            .height = (m + tile_size - 1) / tile_size,
            .depth = 1,
        };
        const threadgroup = metal_bindings.MTLSize{
            .width = tile_size,
            .height = tile_size,
            .depth = 1,
        };

        // Dispatch compute kernel
        metal_bindings.dispatchThreadgroups(encoder, grid, threadgroup);
        metal_bindings.endEncoding(encoder);

        // Execute and wait
        metal_bindings.commitCommandBuffer(cmd_buffer);
        metal_bindings.waitUntilCompleted(cmd_buffer);

        // Copy result back
        if (metal_bindings.getBufferContents(buf_c)) |contents| {
            const result_ptr: [*]f32 = @ptrCast(@alignCast(contents));
            @memcpy(c, result_ptr[0..c.len]);
        } else {
            break :gpu_dispatch;
        }

        const elapsed = std.time.nanoTimestamp() - start;
        return DispatchResult.ok(elapsed, m * n, true);
    }

    // CPU fallback - this shouldn't happen if b_mtl was created
    return DispatchResult.err("GPU dispatch failed with persistent buffer");
}

/// Dispatch matrix multiplication kernel
pub fn dispatchMatmul(
    lib: *MetalShaderLibrary,
    a: []const f32,
    b: []const f32,
    c: []f32,
    m: usize,
    n: usize,
    k: usize,
) DispatchResult {
    const start = std.time.nanoTimestamp();

    // Try GPU dispatch if Metal is ready
    if (lib.isReady()) gpu_dispatch: {
        const device = lib.device orelse break :gpu_dispatch;
        const queue = lib.command_queue orelse break :gpu_dispatch;
        var pool = &(lib.buffer_pool orelse break :gpu_dispatch);

        // Create buffers - a and b with data, c from pool
        const a_bytes = std.mem.sliceAsBytes(a);
        const b_bytes = std.mem.sliceAsBytes(b);
        const c_size = c.len * @sizeOf(f32);

        const buf_a = metal_bindings.createBufferWithBytes(device, a_bytes, metal_bindings.MTLResourceStorageModeShared) orelse break :gpu_dispatch;
        defer metal_bindings.release(buf_a);

        const buf_b = metal_bindings.createBufferWithBytes(device, b_bytes, metal_bindings.MTLResourceStorageModeShared) orelse break :gpu_dispatch;
        defer metal_bindings.release(buf_b);

        // Use buffer pool for output buffer (frequently reused sizes)
        const buf_c = pool.acquire(c_size) orelse break :gpu_dispatch;
        defer pool.release(buf_c, c_size);

        // Get matmul pipeline
        const pipeline = lib.pipelines.get(.matmul_tiled) orelse break :gpu_dispatch;

        // Create command buffer and encoder
        const cmd_buffer = metal_bindings.createCommandBuffer(queue) orelse break :gpu_dispatch;
        defer metal_bindings.release(cmd_buffer);
        const encoder = metal_bindings.createComputeCommandEncoder(cmd_buffer) orelse break :gpu_dispatch;
        defer metal_bindings.release(encoder);

        // Set pipeline and buffers
        metal_bindings.setComputePipelineState(encoder, pipeline);
        metal_bindings.setBuffer(encoder, buf_a, 0, 0);
        metal_bindings.setBuffer(encoder, buf_b, 0, 1);
        metal_bindings.setBuffer(encoder, buf_c, 0, 2);

        // Set dimensions as separate buffers (shader expects M, N, K in buffers 3, 4, 5)
        var m_val: u32 = @intCast(m);
        var n_val: u32 = @intCast(n);
        var k_val: u32 = @intCast(k);
        metal_bindings.setBytes(encoder, @ptrCast(&m_val), @sizeOf(u32), 3);
        metal_bindings.setBytes(encoder, @ptrCast(&n_val), @sizeOf(u32), 4);
        metal_bindings.setBytes(encoder, @ptrCast(&k_val), @sizeOf(u32), 5);

        // Calculate threadgroups for tiled matmul (16x16 tiles)
        const tile_size: usize = 16;
        const grid = metal_bindings.MTLSize{
            .width = (n + tile_size - 1) / tile_size,
            .height = (m + tile_size - 1) / tile_size,
            .depth = 1,
        };
        const threadgroup = metal_bindings.MTLSize{
            .width = tile_size,
            .height = tile_size,
            .depth = 1,
        };

        // Dispatch compute kernel
        metal_bindings.dispatchThreadgroups(encoder, grid, threadgroup);
        metal_bindings.endEncoding(encoder);

        // Execute and wait
        metal_bindings.commitCommandBuffer(cmd_buffer);
        metal_bindings.waitUntilCompleted(cmd_buffer);

        // Copy result back
        if (metal_bindings.getBufferContents(buf_c)) |contents| {
            const result_ptr: [*]f32 = @ptrCast(@alignCast(contents));
            @memcpy(c, result_ptr[0..c.len]);
        } else {
            break :gpu_dispatch;
        }

        const elapsed = std.time.nanoTimestamp() - start;
        return DispatchResult.ok(elapsed, m * n, true); // GPU dispatch succeeded
    }

    // CPU fallback (naive)
    for (0..m) |i| {
        for (0..n) |j| {
            var sum: f32 = 0;
            for (0..k) |l| {
                sum += a[i * k + l] * b[l * n + j];
            }
            c[i * n + j] = sum;
        }
    }

    const elapsed = std.time.nanoTimestamp() - start;
    return DispatchResult.ok(elapsed, m * n, false);
}

/// Dispatch softmax kernel
pub fn dispatchSoftmax(
    lib: *MetalShaderLibrary,
    input: []const f32,
    output: []f32,
    batch_size: usize,
    seq_len: usize,
) DispatchResult {
    const start = std.time.nanoTimestamp();
    
    if (lib.isReady()) {
        // Would dispatch GPU kernel here
    }
    
    // CPU fallback
    for (0..batch_size) |b| {
        const offset = b * seq_len;
        
        var max_val: f32 = input[offset];
        for (1..seq_len) |i| {
            max_val = @max(max_val, input[offset + i]);
        }
        
        var sum: f32 = 0;
        for (0..seq_len) |i| {
            output[offset + i] = @exp(input[offset + i] - max_val);
            sum += output[offset + i];
        }
        
        const inv_sum = 1.0 / sum;
        for (0..seq_len) |i| {
            output[offset + i] *= inv_sum;
        }
    }
    
    const elapsed = std.time.nanoTimestamp() - start;
    return DispatchResult.ok(elapsed, batch_size * seq_len, false);
}

/// Dispatch layer normalization kernel  
pub fn dispatchLayerNorm(
    lib: *MetalShaderLibrary,
    input: []const f32,
    output: []f32,
    batch_size: usize,
    hidden_size: usize,
) DispatchResult {
    const start = std.time.nanoTimestamp();
    const eps: f32 = 1e-5;
    
    if (lib.isReady()) {
        // Would dispatch GPU kernel here
    }
    
    // CPU fallback
    for (0..batch_size) |b| {
        const offset = b * hidden_size;
        
        // Mean
        var mean: f32 = 0;
        for (0..hidden_size) |i| {
            mean += input[offset + i];
        }
        mean /= @as(f32, @floatFromInt(hidden_size));
        
        // Variance
        var variance: f32 = 0;
        for (0..hidden_size) |i| {
            const diff = input[offset + i] - mean;
            variance += diff * diff;
        }
        variance /= @as(f32, @floatFromInt(hidden_size));
        
        // Normalize
        const inv_std = 1.0 / @sqrt(variance + eps);
        for (0..hidden_size) |i| {
            output[offset + i] = (input[offset + i] - mean) * inv_std;
        }
    }
    
    const elapsed = std.time.nanoTimestamp() - start;
    return DispatchResult.ok(elapsed, batch_size * hidden_size, false);
}

// ============================================================================
// Batched Layer Dispatch - Single command buffer for all layer matmuls
// ============================================================================

/// Matmul operation descriptor for batching
pub const MatmulOp = struct {
    a_buf: *anyopaque,     // Input activation buffer
    b_mtl: *anyopaque,     // Weight buffer (persistent)
    c_buf: *anyopaque,     // Output buffer
    m: u32,
    n: u32,
    k: u32,
};

/// Batched command encoder for multiple matmuls in a single GPU submission
pub const BatchedLayerEncoder = struct {
    lib: *MetalShaderLibrary,
    device: *anyopaque,
    queue: *anyopaque,
    cmd_buffer: ?*anyopaque,
    encoder: ?*anyopaque,
    pipeline: *anyopaque,
    ops_encoded: usize,
    
    /// Initialize batched encoder for a layer
    pub fn init(lib: *MetalShaderLibrary) ?BatchedLayerEncoder {
        if (!lib.isReady()) return null;
        const device = lib.device orelse return null;
        const queue = lib.command_queue orelse return null;
        const pipeline = lib.pipelines.get(.matmul_tiled) orelse return null;
        
        const cmd_buffer = metal_bindings.createCommandBuffer(queue) orelse return null;
        const encoder = metal_bindings.createComputeCommandEncoder(cmd_buffer) orelse {
            metal_bindings.release(cmd_buffer);
            return null;
        };
        
        return BatchedLayerEncoder{
            .lib = lib,
            .device = device,
            .queue = queue,
            .cmd_buffer = cmd_buffer,
            .encoder = encoder,
            .pipeline = pipeline,
            .ops_encoded = 0,
        };
    }
    
    /// Encode a single matmul operation (no GPU submission yet)
    pub fn encodeMatmul(
        self: *BatchedLayerEncoder,
        a: []const f32,
        b_mtl: *anyopaque,
        c: []f32,
        m: usize,
        n: usize,
        k: usize,
    ) bool {
        const encoder = self.encoder orelse return false;
        var pool = &(self.lib.buffer_pool orelse return false);
        
        // Create activation buffer
        const a_bytes = std.mem.sliceAsBytes(a);
        const buf_a = metal_bindings.createBufferWithBytes(self.device, a_bytes, metal_bindings.MTLResourceStorageModeShared) orelse return false;
        
        // Get output buffer from pool
        const c_size = c.len * @sizeOf(f32);
        const buf_c = pool.acquire(c_size) orelse {
            metal_bindings.release(buf_a);
            return false;
        };
        
        // Set pipeline and buffers
        metal_bindings.setComputePipelineState(encoder, self.pipeline);
        metal_bindings.setBuffer(encoder, buf_a, 0, 0);
        metal_bindings.setBuffer(encoder, b_mtl, 0, 1);
        metal_bindings.setBuffer(encoder, buf_c, 0, 2);
        
        // Set dimensions
        var m_val: u32 = @intCast(m);
        var n_val: u32 = @intCast(n);
        var k_val: u32 = @intCast(k);
        metal_bindings.setBytes(encoder, @ptrCast(&m_val), @sizeOf(u32), 3);
        metal_bindings.setBytes(encoder, @ptrCast(&n_val), @sizeOf(u32), 4);
        metal_bindings.setBytes(encoder, @ptrCast(&k_val), @sizeOf(u32), 5);
        
        // Calculate threadgroups
        const tile_size: usize = 16;
        const grid = metal_bindings.MTLSize{
            .width = (n + tile_size - 1) / tile_size,
            .height = (m + tile_size - 1) / tile_size,
            .depth = 1,
        };
        const threadgroup = metal_bindings.MTLSize{
            .width = tile_size,
            .height = tile_size,
            .depth = 1,
        };
        
        // Dispatch (but don't wait)
        metal_bindings.dispatchThreadgroups(encoder, grid, threadgroup);
        
        // Release input buffer immediately (it's been copied to GPU)
        metal_bindings.release(buf_a);
        
        // Store output buffer info for later copy-back
        // Note: For proper batching, we'd need to track these and copy back after commit
        // For now, we release the buffer and let the caller handle the result
        pool.release(buf_c, c_size);
        
        self.ops_encoded += 1;
        return true;
    }
    
    /// Submit all encoded operations and wait for completion
    pub fn submitAndWait(self: *BatchedLayerEncoder) bool {
        const encoder = self.encoder orelse return false;
        const cmd_buffer = self.cmd_buffer orelse return false;
        
        metal_bindings.endEncoding(encoder);
        metal_bindings.commitCommandBuffer(cmd_buffer);
        metal_bindings.waitUntilCompleted(cmd_buffer);
        
        // Release resources
        metal_bindings.release(encoder);
        metal_bindings.release(cmd_buffer);
        
        self.encoder = null;
        self.cmd_buffer = null;
        
        return self.ops_encoded > 0;
    }
    
    /// Cleanup without submission (error path)
    pub fn abort(self: *BatchedLayerEncoder) void {
        if (self.encoder) |e| metal_bindings.release(e);
        if (self.cmd_buffer) |c| metal_bindings.release(c);
        self.encoder = null;
        self.cmd_buffer = null;
    }
};

/// Dispatch multiple matmuls in a single command buffer (reduces overhead)
/// Returns true if GPU was used, false if fell back to CPU
pub fn dispatchBatchedMatmuls(
    lib: *MetalShaderLibrary,
    ops: []const struct {
        a: []const f32,
        b_mtl: *anyopaque,
        c: []f32,
        m: usize,
        n: usize,
        k: usize,
    },
) bool {
    if (!lib.isReady() or ops.len == 0) return false;
    
    const device = lib.device orelse return false;
    const queue = lib.command_queue orelse return false;
    var pool = &(lib.buffer_pool orelse return false);
    const pipeline = lib.pipelines.get(.matmul_tiled) orelse return false;
    
    // Create single command buffer for all operations
    const cmd_buffer = metal_bindings.createCommandBuffer(queue) orelse return false;
    defer metal_bindings.release(cmd_buffer);
    
    const encoder = metal_bindings.createComputeCommandEncoder(cmd_buffer) orelse return false;
    defer metal_bindings.release(encoder);
    
    // Track output buffers for copy-back
    var out_bufs: [16]?*anyopaque = .{null} ** 16;
    var out_sizes: [16]usize = .{0} ** 16;
    var out_dests: [16][]f32 = undefined;
    
    // Encode all matmuls
    for (ops, 0..) |op, i| {
        if (i >= 16) break; // Max ops per batch
        
        const a_bytes = std.mem.sliceAsBytes(op.a);
        const buf_a = metal_bindings.createBufferWithBytes(device, a_bytes, metal_bindings.MTLResourceStorageModeShared) orelse continue;
        defer metal_bindings.release(buf_a);
        
        const c_size = op.c.len * @sizeOf(f32);
        const buf_c = pool.acquire(c_size) orelse continue;
        out_bufs[i] = buf_c;
        out_sizes[i] = c_size;
        out_dests[i] = op.c;
        
        metal_bindings.setComputePipelineState(encoder, pipeline);
        metal_bindings.setBuffer(encoder, buf_a, 0, 0);
        metal_bindings.setBuffer(encoder, op.b_mtl, 0, 1);
        metal_bindings.setBuffer(encoder, buf_c, 0, 2);
        
        var m_val: u32 = @intCast(op.m);
        var n_val: u32 = @intCast(op.n);
        var k_val: u32 = @intCast(op.k);
        metal_bindings.setBytes(encoder, @ptrCast(&m_val), @sizeOf(u32), 3);
        metal_bindings.setBytes(encoder, @ptrCast(&n_val), @sizeOf(u32), 4);
        metal_bindings.setBytes(encoder, @ptrCast(&k_val), @sizeOf(u32), 5);
        
        const tile_size: usize = 16;
        const grid = metal_bindings.MTLSize{
            .width = (op.n + tile_size - 1) / tile_size,
            .height = (op.m + tile_size - 1) / tile_size,
            .depth = 1,
        };
        const threadgroup = metal_bindings.MTLSize{
            .width = tile_size,
            .height = tile_size,
            .depth = 1,
        };
        
        metal_bindings.dispatchThreadgroups(encoder, grid, threadgroup);
    }
    
    // Submit all at once
    metal_bindings.endEncoding(encoder);
    metal_bindings.commitCommandBuffer(cmd_buffer);
    metal_bindings.waitUntilCompleted(cmd_buffer);
    
    // Copy results back
    for (out_bufs, out_sizes, 0..) |maybe_buf, size, i| {
        if (maybe_buf) |buf| {
            if (metal_bindings.getBufferContents(buf)) |contents| {
                const result_ptr: [*]f32 = @ptrCast(@alignCast(contents));
                @memcpy(out_dests[i], result_ptr[0..out_dests[i].len]);
            }
            pool.release(buf, size);
        }
    }
    
    return true;
}

// ============================================================================
// Tests
// ============================================================================

test "MetalShaderLibrary init/deinit" {
    const lib = try MetalShaderLibrary.init(std.testing.allocator);
    defer lib.deinit();
    
    // In test mode, device should be null
    try std.testing.expect(!lib.isReady());
}

test "DispatchConfig for1D" {
    const config = DispatchConfig.for1D(1000);
    try std.testing.expectEqual(@as(u32, 1000), config.grid_size[0]);
    try std.testing.expectEqual(@as(u32, 256), config.threadgroup_size[0]);
}

test "dispatchSoftmax CPU fallback" {
    const lib = try MetalShaderLibrary.init(std.testing.allocator);
    defer lib.deinit();
    
    var input = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    var output: [4]f32 = undefined;
    
    const result = dispatchSoftmax(lib, &input, &output, 1, 4);
    
    try std.testing.expect(result.success);
    try std.testing.expect(!result.gpu_utilized);
    
    // Check softmax sums to 1
    var sum: f32 = 0;
    for (output) |v| sum += v;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sum, 0.001);
}

test "dispatchCosineSimilarity CPU fallback" {
    const lib = try MetalShaderLibrary.init(std.testing.allocator);
    defer lib.deinit();
    
    const query = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
    const docs = [_]f32{
        1.0, 0.0, 0.0, 0.0, // doc 0: identical
        0.0, 1.0, 0.0, 0.0, // doc 1: orthogonal
    };
    var scores: [2]f32 = undefined;
    
    const result = dispatchCosineSimilarity(lib, &query, &docs, &scores, 2, 4);
    
    try std.testing.expect(result.success);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), scores[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), scores[1], 0.001);
}

test "dispatchMatmul CPU fallback" {
    const lib = try MetalShaderLibrary.init(std.testing.allocator);
    defer lib.deinit();
    
    const a = [_]f32{ 1, 2, 3, 4 }; // 2x2
    const b = [_]f32{ 5, 6, 7, 8 }; // 2x2
    var c: [4]f32 = undefined;
    
    const result = dispatchMatmul(lib, &a, &b, &c, 2, 2, 2);
    
    try std.testing.expect(result.success);
    // [1,2] @ [5,6]   = 1*5+2*7=19, 1*6+2*8=22
    // [3,4]   [7,8]   = 3*5+4*7=43, 3*6+4*8=50
    try std.testing.expectApproxEqAbs(@as(f32, 19.0), c[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 22.0), c[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 43.0), c[2], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), c[3], 0.001);
}
