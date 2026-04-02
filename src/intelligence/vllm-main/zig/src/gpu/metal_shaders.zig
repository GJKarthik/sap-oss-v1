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
    rms_norm,
    embedding_lookup,
    vecmat_f16_colmajor,
    vecmat_q4_k,
    vecmat_q4_k_rows2,
    vecmat_q4_k_pair,
    vecmat_q4_k_add,
    vecmat_q4_k_dual,
    vecmat_q4_k_dual_rmsnorm,
    vecmat_q4_k_triple,
    vecmat_q4_k_triple_rmsnorm,
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
    attention_decode_scores_single_head,
    attention_decode_values_single_head,
    attention_decode_fused_single_head,
    attention_decode_fused_heads,
    
    pub fn toString(self: KernelName) []const u8 {
        return switch (self) {
            .vector_add => "vector_add",
            .vector_scale => "vector_scale",
            .vector_mul => "vector_mul",
            .rms_norm => "rms_norm",
            .embedding_lookup => "embedding_lookup",
            .vecmat_f16_colmajor => "vecmat_f16_colmajor",
            .vecmat_q4_k => "vecmat_q4_k",
            .vecmat_q4_k_rows2 => "vecmat_q4_k_rows2",
            .vecmat_q4_k_pair => "vecmat_q4_k_pair",
            .vecmat_q4_k_add => "vecmat_q4_k_add",
            .vecmat_q4_k_dual => "vecmat_q4_k_dual",
            .vecmat_q4_k_dual_rmsnorm => "vecmat_q4_k_dual_rmsnorm",
            .vecmat_q4_k_triple => "vecmat_q4_k_triple",
            .vecmat_q4_k_triple_rmsnorm => "vecmat_q4_k_triple_rmsnorm",
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
            .attention_decode_scores_single_head => "attention_decode_scores_single_head",
            .attention_decode_values_single_head => "attention_decode_values_single_head",
            .attention_decode_fused_single_head => "attention_decode_fused_single_head",
            .attention_decode_fused_heads => "attention_decode_fused_heads",
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

pub fn bundledComputeSource() []const u8 {
    return @embedFile("shaders/compute.metal");
}

pub fn loadBundledLibrary(self: *MetalShaderLibrary) !void {
    const candidate_paths = [_]?[]const u8{
        blk: {
            const exe_path = try std.fs.selfExePathAlloc(self.allocator);
            defer self.allocator.free(exe_path);

            const bin_dir = std.fs.path.dirname(exe_path) orelse break :blk null;
            const zig_out_dir = std.fs.path.dirname(bin_dir) orelse break :blk null;
            const project_dir = std.fs.path.dirname(zig_out_dir) orelse break :blk null;
            break :blk try std.fs.path.join(self.allocator, &.{ project_dir, "src", "gpu", "shaders", "compute.metallib" });
        },
        std.fs.cwd().realpathAlloc(self.allocator, "src/gpu/shaders/compute.metallib") catch null,
    };
    defer {
        for (candidate_paths) |candidate| {
            if (candidate) |path| self.allocator.free(path);
        }
    }

    if (std.posix.getenv("PRIVATELLM_METALLIB_PATH")) |path| {
        try self.loadLibrary(path);
        return;
    }

    for (candidate_paths) |candidate| {
        const bundled_path = candidate orelse continue;
        const bundled_file = std.fs.openFileAbsolute(bundled_path, .{}) catch null;
        if (bundled_file) |file| {
            file.close();
            self.loadLibrary(bundled_path) catch |err| {
                log.warn("Bundled compute.metallib failed to load ({}) ; recompiling from source", .{err});
                break;
            };
            if (self.pipelines.get(.vecmat_f16_colmajor) != null and
                self.pipelines.get(.vecmat_q4_k) != null and
                self.pipelines.get(.vecmat_q4_k_rows2) != null and
                self.pipelines.get(.vecmat_q4_k_pair) != null and
                self.pipelines.get(.vecmat_q4_k_add) != null and
                self.pipelines.get(.vecmat_q4_k_dual) != null and
                self.pipelines.get(.vecmat_q4_k_dual_rmsnorm) != null and
                self.pipelines.get(.vecmat_q4_k_triple) != null and
                self.pipelines.get(.vecmat_q4_k_triple_rmsnorm) != null and
                self.pipelines.get(.attention_decode_fused_single_head) != null and
                self.pipelines.get(.attention_decode_fused_heads) != null)
            {
                return;
            }
            log.warn("Bundled compute.metallib is missing fused GGUF or decode-attention kernels; recompiling from source", .{});
            break;
        }
    }

    try self.loadFromSource(bundledComputeSource());
}

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
        const stem = std.fs.path.stem(source_path);
        const air_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.air", .{ dir, stem });
        defer self.allocator.free(air_path);
        
        const lib_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.metallib", .{ dir, stem });
        
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

    /// Compile and load Metal shaders from embedded source text.
    pub fn loadFromSource(self: *MetalShaderLibrary, source: []const u8) !void {
        if (comptime builtin.os.tag != .macos) return error.UnsupportedPlatform;

        const ts: u64 = @intCast(std.time.milliTimestamp());
        const base_name = try std.fmt.allocPrint(self.allocator, "privatellm_compute_{d}.metal", .{ts});
        defer self.allocator.free(base_name);

        const source_path = try std.fs.path.join(self.allocator, &.{ "/tmp", base_name });
        defer self.allocator.free(source_path);

        var tmp_dir = try std.fs.openDirAbsolute("/tmp", .{});
        defer tmp_dir.close();
        try tmp_dir.writeFile(.{ .sub_path = base_name, .data = source });
        defer std.fs.deleteFileAbsolute(source_path) catch {};

        try self.compileFromSource(source_path);
        const lib_path = self.metallib_path orelse return error.LibraryLoadFailed;
        try self.loadLibrary(lib_path);

        std.fs.deleteFileAbsolute(lib_path) catch {};
        self.allocator.free(lib_path);
        self.metallib_path = null;
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
            try self.createPipeline(.vecmat_f16_colmajor);
            try self.createPipeline(.vecmat_q4_k);
            try self.createPipeline(.vecmat_q4_k_rows2);
            try self.createPipeline(.vecmat_q4_k_pair);
            try self.createPipeline(.vecmat_q4_k_add);
            try self.createPipeline(.vecmat_q4_k_dual);
            try self.createPipeline(.vecmat_q4_k_dual_rmsnorm);
            try self.createPipeline(.vecmat_q4_k_triple);
            try self.createPipeline(.vecmat_q4_k_triple_rmsnorm);
            try self.createPipeline(.vector_add);
            try self.createPipeline(.rms_norm);
            try self.createPipeline(.matmul_tiled);
            try self.createPipeline(.matmul_naive);
            try self.createPipeline(.softmax_row);
            try self.createPipeline(.softmax_parallel);
            try self.createPipeline(.layer_norm);
            try self.createPipeline(.embedding_lookup);
            try self.createPipeline(.attention_decode_scores_single_head);
            try self.createPipeline(.attention_decode_values_single_head);
            try self.createPipeline(.attention_decode_fused_single_head);
            try self.createPipeline(.attention_decode_fused_heads);
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

pub const VecMatKernel = enum {
    f16_colmajor,
    q4_k,
    q4_k_rows2,
    q4_k_pair,
};

pub const VecMatOp = struct {
    kernel: VecMatKernel,
    weight_buf: *anyopaque,
    out: []f32,
    out_buf: ?*anyopaque = null,
    k: usize,
    n: usize,
};

pub const VecMatQ4KPairOp = struct {
    weight1: *anyopaque,
    out1: []f32,
    out1_buf: ?*anyopaque = null,
    n1: usize,
    weight2: *anyopaque,
    out2: []f32,
    out2_buf: ?*anyopaque = null,
    n2: usize,
    k: usize,
};

pub const VecMatQ4KPairRmsNormOp = struct {
    norm_weight: *anyopaque,
    inv_rms: f32,
    weight1: *anyopaque,
    out1: []f32,
    out1_buf: ?*anyopaque = null,
    n1: usize,
    weight2: *anyopaque,
    out2: []f32,
    out2_buf: ?*anyopaque = null,
    n2: usize,
    k: usize,
};

pub const VecMatQ4KTripleOp = struct {
    weight1: *anyopaque,
    out1: []f32,
    out1_buf: ?*anyopaque = null,
    out1_offset_bytes: usize = 0,
    n1: usize,
    weight2: *anyopaque,
    out2: []f32,
    out2_buf: ?*anyopaque = null,
    out2_offset_bytes: usize = 0,
    n2: usize,
    weight3: *anyopaque,
    out3: []f32,
    out3_buf: ?*anyopaque = null,
    out3_offset_bytes: usize = 0,
    n3: usize,
    k: usize,
};

pub const VecMatQ4KTripleRmsNormOp = struct {
    norm_weight: *anyopaque,
    inv_rms: f32,
    weight1: *anyopaque,
    out1: []f32,
    out1_buf: ?*anyopaque = null,
    out1_offset_bytes: usize = 0,
    n1: usize,
    weight2: *anyopaque,
    out2: []f32,
    out2_buf: ?*anyopaque = null,
    out2_offset_bytes: usize = 0,
    n2: usize,
    weight3: *anyopaque,
    out3: []f32,
    out3_buf: ?*anyopaque = null,
    out3_offset_bytes: usize = 0,
    n3: usize,
    k: usize,
};

pub const AttentionDecodeSingleHeadOp = struct {
    q: []const f32,
    q_buf: ?*anyopaque = null,
    q_offset_bytes: usize = 0,
    k_cache: []const f32,
    k_cache_buf: ?*anyopaque = null,
    v_cache: []const f32,
    v_cache_buf: ?*anyopaque = null,
    out: []f32,
    out_buf: ?*anyopaque = null,
    out_offset_bytes: usize = 0,
    seq_len: usize,
    head_dim: usize,
    kv_stride: usize,
    head_offset: usize,
    scale: f32,
};

pub const AttentionDecodeMode = enum {
    auto,
    split,
    fused_single,
    fused_heads,
};

pub const AttentionDecodeHeadsOp = struct {
    q_buf: *anyopaque,
    out_buf: *anyopaque,
    k_cache_buf: *anyopaque,
    v_cache_buf: *anyopaque,
    seq_len: usize,
    head_dim: usize,
    n_heads: usize,
    heads_per_group: usize,
    kv_stride: usize,
    scale: f32,
    mode: AttentionDecodeMode = .auto,
};

pub const AttentionDecodeHeadsQ4KAddOp = struct {
    q_buf: *anyopaque,
    attn_out_buf: *anyopaque,
    k_cache_buf: *anyopaque,
    v_cache_buf: *anyopaque,
    weight_buf: *anyopaque,
    residual_buf: *anyopaque,
    out_buf: *anyopaque,
    seq_len: usize,
    head_dim: usize,
    n_heads: usize,
    heads_per_group: usize,
    kv_stride: usize,
    scale: f32,
    k: usize,
    n: usize,
};

fn acquireUploadBuffer(pool: *BufferPool, bytes: []const u8) ?*anyopaque {
    const buf = pool.acquire(bytes.len) orelse return null;
    if (metal_bindings.getBufferContents(buf)) |contents| {
        const dst: [*]u8 = @ptrCast(@alignCast(contents));
        @memcpy(dst[0..bytes.len], bytes);
        return buf;
    }
    pool.release(buf, bytes.len);
    return null;
}

fn dispatchVecMatGeometry(kernel: VecMatKernel, n: usize) struct { grid: metal_bindings.MTLSize, threadgroup: metal_bindings.MTLSize } {
    return switch (kernel) {
        .f16_colmajor => blk: {
            const threads_per_group: usize = 256;
            const threadgroup_width = @min(threads_per_group, @max(n, 1));
            break :blk .{
                .grid = .{
                    .width = (n + threadgroup_width - 1) / threadgroup_width,
                    .height = 1,
                    .depth = 1,
                },
                .threadgroup = .{
                    .width = threadgroup_width,
                    .height = 1,
                    .depth = 1,
                },
            };
        },
        .q4_k => .{
            .grid = .{
                .width = n,
                .height = 1,
                .depth = 1,
            },
            .threadgroup = .{
                .width = 32,
                .height = 1,
                .depth = 1,
            },
        },
        .q4_k_rows2 => .{
            .grid = .{
                .width = (n + 1) / 2,
                .height = 1,
                .depth = 1,
            },
            .threadgroup = .{
                .width = 32,
                .height = 1,
                .depth = 1,
            },
        },
        .q4_k_pair => .{
            .grid = .{
                .width = n,
                .height = 1,
                .depth = 1,
            },
            .threadgroup = .{
                .width = 16,
                .height = 1,
                .depth = 1,
            },
        },
    };
}

fn vecMatPipeline(lib: *MetalShaderLibrary, kernel: VecMatKernel) ?*anyopaque {
    return switch (kernel) {
        .f16_colmajor => lib.pipelines.get(.vecmat_f16_colmajor),
        .q4_k => lib.pipelines.get(.vecmat_q4_k),
        .q4_k_rows2 => lib.pipelines.get(.vecmat_q4_k_rows2),
        .q4_k_pair => lib.pipelines.get(.vecmat_q4_k_pair),
    };
}

fn useQ4KRows2Kernel(k: usize, n: usize) bool {
    const raw = std.posix.getenv("PLLM_ENABLE_Q4K_ROWS2_KERNEL") orelse return false;
    if (raw.len != 1 or raw[0] != '1') return false;
    return k % 256 == 0 and n >= 16384;
}

fn useQ4KPairKernel(k: usize, n: usize) bool {
    _ = n;
    if (std.posix.getenv("PLLM_DISABLE_Q4K_PAIR_KERNEL")) |raw| {
        if (raw.len == 1 and raw[0] == '1') return false;
    }
    if (std.posix.getenv("PLLM_ENABLE_Q4K_PAIR_KERNEL")) |raw| {
        if (raw.len == 1 and raw[0] == '1') return k % 64 == 0 and k >= 64;
    }
    return false;
}

fn dispatchVecMatMulQ4KKernel(
    lib: *MetalShaderLibrary,
    x: []const f32,
    w: []const u8,
    w_mtl: ?*anyopaque,
    out: []f32,
    x_mtl: ?*anyopaque,
    out_mtl: ?*anyopaque,
    k: usize,
    n: usize,
    kernel: VecMatKernel,
) DispatchResult {
    const start = std.time.nanoTimestamp();
    if (n == 0 or out.len == 0) return DispatchResult.ok(0, 0, false);

    if (lib.isReady()) gpu_dispatch: {
        _ = w;
        const weight_buf = w_mtl orelse break :gpu_dispatch;
        const queue = lib.command_queue orelse break :gpu_dispatch;
        var pool = &(lib.buffer_pool orelse break :gpu_dispatch);

        const x_bytes = std.mem.sliceAsBytes(x);
        const out_size = out.len * @sizeOf(f32);

        const buf_x = x_mtl orelse blk: {
            const uploaded = acquireUploadBuffer(pool, x_bytes) orelse break :gpu_dispatch;
            break :blk uploaded;
        };
        defer if (x_mtl == null) pool.release(buf_x, x_bytes.len);

        const buf_out = out_mtl orelse blk: {
            const acquired = pool.acquire(out_size) orelse break :gpu_dispatch;
            break :blk acquired;
        };
        defer if (out_mtl == null) pool.release(buf_out, out_size);

        const pipeline = vecMatPipeline(lib, kernel) orelse break :gpu_dispatch;

        const cmd_buffer = metal_bindings.createCommandBuffer(queue) orelse break :gpu_dispatch;
        defer metal_bindings.release(cmd_buffer);
        const encoder = metal_bindings.createComputeCommandEncoder(cmd_buffer) orelse break :gpu_dispatch;
        defer metal_bindings.release(encoder);

        metal_bindings.setComputePipelineState(encoder, pipeline);
        metal_bindings.setBuffer(encoder, buf_x, 0, 0);
        metal_bindings.setBuffer(encoder, weight_buf, 0, 1);
        metal_bindings.setBuffer(encoder, buf_out, 0, 2);

        var k_val: u32 = @intCast(k);
        var n_val: u32 = @intCast(n);
        metal_bindings.setBytes(encoder, @ptrCast(&k_val), @sizeOf(u32), 3);
        metal_bindings.setBytes(encoder, @ptrCast(&n_val), @sizeOf(u32), 4);

        const geometry = dispatchVecMatGeometry(kernel, n);
        metal_bindings.dispatchThreadgroups(encoder, geometry.grid, geometry.threadgroup);
        metal_bindings.endEncoding(encoder);
        metal_bindings.commitCommandBuffer(cmd_buffer);
        metal_bindings.waitUntilCompleted(cmd_buffer);

        if (out_mtl == null) {
            if (metal_bindings.getBufferContents(buf_out)) |contents| {
                const result_ptr: [*]f32 = @ptrCast(@alignCast(contents));
                @memcpy(out, result_ptr[0..out.len]);
            } else {
                break :gpu_dispatch;
            }
        } else if (metal_bindings.getBufferContents(buf_out)) |_| {
            // Results are already visible through the shared output buffer.
        } else {
            break :gpu_dispatch;
        }

        const elapsed = std.time.nanoTimestamp() - start;
        return DispatchResult.ok(elapsed, n, true);
    }

    return DispatchResult.err("Metal vecmat_q4_k unavailable");
}

pub fn dispatchVecMatMulQ4KForcedKernel(
    lib: *MetalShaderLibrary,
    x: []const f32,
    w: []const u8,
    w_mtl: ?*anyopaque,
    out: []f32,
    x_mtl: ?*anyopaque,
    out_mtl: ?*anyopaque,
    k: usize,
    n: usize,
    kernel: VecMatKernel,
) DispatchResult {
    return dispatchVecMatMulQ4KKernel(lib, x, w, w_mtl, out, x_mtl, out_mtl, k, n, kernel);
}

pub fn dispatchVectorAdd(
    lib: *MetalShaderLibrary,
    a: []const f32,
    b: []const f32,
    out: []f32,
    a_mtl: ?*anyopaque,
    b_mtl: ?*anyopaque,
    out_mtl: ?*anyopaque,
) DispatchResult {
    const start = std.time.nanoTimestamp();
    if (a.len != b.len or out.len != a.len) return DispatchResult.err("vector_add shape mismatch");

    if (lib.isReady()) gpu_dispatch: {
        const queue = lib.command_queue orelse break :gpu_dispatch;
        var pool = &(lib.buffer_pool orelse break :gpu_dispatch);
        const pipeline = lib.getPipeline(.vector_add) catch null orelse break :gpu_dispatch;

        const a_bytes = std.mem.sliceAsBytes(a);
        const b_bytes = std.mem.sliceAsBytes(b);
        const out_size = out.len * @sizeOf(f32);

        const buf_a = a_mtl orelse blk: {
            const uploaded = acquireUploadBuffer(pool, a_bytes) orelse break :gpu_dispatch;
            break :blk uploaded;
        };
        defer if (a_mtl == null) pool.release(buf_a, a_bytes.len);

        const buf_b = b_mtl orelse blk: {
            const uploaded = acquireUploadBuffer(pool, b_bytes) orelse break :gpu_dispatch;
            break :blk uploaded;
        };
        defer if (b_mtl == null) pool.release(buf_b, b_bytes.len);

        const buf_out = out_mtl orelse blk: {
            const acquired = pool.acquire(out_size) orelse break :gpu_dispatch;
            break :blk acquired;
        };
        defer if (out_mtl == null) pool.release(buf_out, out_size);

        const cmd_buffer = metal_bindings.createCommandBuffer(queue) orelse break :gpu_dispatch;
        defer metal_bindings.release(cmd_buffer);
        const encoder = metal_bindings.createComputeCommandEncoder(cmd_buffer) orelse break :gpu_dispatch;
        defer metal_bindings.release(encoder);

        metal_bindings.setComputePipelineState(encoder, pipeline);
        metal_bindings.setBuffer(encoder, buf_a, 0, 0);
        metal_bindings.setBuffer(encoder, buf_b, 0, 1);
        metal_bindings.setBuffer(encoder, buf_out, 0, 2);

        var n_val: u32 = @intCast(out.len);
        metal_bindings.setBytes(encoder, @ptrCast(&n_val), @sizeOf(u32), 3);

        const threads_per_group: usize = 256;
        const grid = metal_bindings.MTLSize{
            .width = (out.len + threads_per_group - 1) / threads_per_group,
            .height = 1,
            .depth = 1,
        };
        const threadgroup = metal_bindings.MTLSize{
            .width = threads_per_group,
            .height = 1,
            .depth = 1,
        };
        metal_bindings.dispatchThreadgroups(encoder, grid, threadgroup);
        metal_bindings.endEncoding(encoder);
        metal_bindings.commitCommandBuffer(cmd_buffer);
        metal_bindings.waitUntilCompleted(cmd_buffer);

        if (out_mtl == null) {
            if (metal_bindings.getBufferContents(buf_out)) |contents| {
                const result_ptr: [*]f32 = @ptrCast(@alignCast(contents));
                @memcpy(out, result_ptr[0..out.len]);
            } else break :gpu_dispatch;
        } else if (metal_bindings.getBufferContents(buf_out) == null) break :gpu_dispatch;

        const elapsed = std.time.nanoTimestamp() - start;
        return DispatchResult.ok(elapsed, out.len, true);
    }

    for (0..out.len) |i| out[i] = a[i] + b[i];
    const elapsed = std.time.nanoTimestamp() - start;
    return DispatchResult.ok(elapsed, out.len, false);
}

pub fn dispatchRmsNorm(
    lib: *MetalShaderLibrary,
    input: []const f32,
    weight: []const f32,
    output: []f32,
    input_mtl: ?*anyopaque,
    weight_mtl: ?*anyopaque,
    output_mtl: ?*anyopaque,
    batch_size: usize,
    hidden_size: usize,
) DispatchResult {
    const start = std.time.nanoTimestamp();
    if (input.len < batch_size * hidden_size or output.len < batch_size * hidden_size or weight.len < hidden_size) {
        return DispatchResult.err("rms_norm shape mismatch");
    }

    if (lib.isReady()) gpu_dispatch: {
        const queue = lib.command_queue orelse break :gpu_dispatch;
        var pool = &(lib.buffer_pool orelse break :gpu_dispatch);
        const pipeline = lib.getPipeline(.rms_norm) catch null orelse break :gpu_dispatch;

        const input_bytes = std.mem.sliceAsBytes(input[0 .. batch_size * hidden_size]);
        const weight_bytes = std.mem.sliceAsBytes(weight[0..hidden_size]);
        const output_size = batch_size * hidden_size * @sizeOf(f32);

        const buf_input = input_mtl orelse blk: {
            const uploaded = acquireUploadBuffer(pool, input_bytes) orelse break :gpu_dispatch;
            break :blk uploaded;
        };
        defer if (input_mtl == null) pool.release(buf_input, input_bytes.len);

        const buf_weight = weight_mtl orelse blk: {
            const uploaded = acquireUploadBuffer(pool, weight_bytes) orelse break :gpu_dispatch;
            break :blk uploaded;
        };
        defer if (weight_mtl == null) pool.release(buf_weight, weight_bytes.len);

        const buf_output = output_mtl orelse blk: {
            const acquired = pool.acquire(output_size) orelse break :gpu_dispatch;
            break :blk acquired;
        };
        defer if (output_mtl == null) pool.release(buf_output, output_size);

        const cmd_buffer = metal_bindings.createCommandBuffer(queue) orelse break :gpu_dispatch;
        defer metal_bindings.release(cmd_buffer);
        const encoder = metal_bindings.createComputeCommandEncoder(cmd_buffer) orelse break :gpu_dispatch;
        defer metal_bindings.release(encoder);

        metal_bindings.setComputePipelineState(encoder, pipeline);
        metal_bindings.setBuffer(encoder, buf_input, 0, 0);
        metal_bindings.setBuffer(encoder, buf_weight, 0, 1);
        metal_bindings.setBuffer(encoder, buf_output, 0, 2);

        var hidden_val: u32 = @intCast(hidden_size);
        metal_bindings.setBytes(encoder, @ptrCast(&hidden_val), @sizeOf(u32), 3);

        const threads_per_group: usize = 256;
        const grid = metal_bindings.MTLSize{
            .width = 1,
            .height = batch_size,
            .depth = 1,
        };
        const threadgroup = metal_bindings.MTLSize{
            .width = @min(threads_per_group, @max(hidden_size, 1)),
            .height = 1,
            .depth = 1,
        };
        metal_bindings.dispatchThreadgroups(encoder, grid, threadgroup);
        metal_bindings.endEncoding(encoder);
        metal_bindings.commitCommandBuffer(cmd_buffer);
        metal_bindings.waitUntilCompleted(cmd_buffer);

        if (output_mtl == null) {
            if (metal_bindings.getBufferContents(buf_output)) |contents| {
                const result_ptr: [*]f32 = @ptrCast(@alignCast(contents));
                @memcpy(output[0 .. batch_size * hidden_size], result_ptr[0 .. batch_size * hidden_size]);
            } else break :gpu_dispatch;
        } else if (metal_bindings.getBufferContents(buf_output) == null) break :gpu_dispatch;

        const elapsed = std.time.nanoTimestamp() - start;
        return DispatchResult.ok(elapsed, batch_size * hidden_size, true);
    }

    for (0..batch_size) |row| {
        const offset = row * hidden_size;
        var ss: f32 = 0.0;
        for (input[offset .. offset + hidden_size]) |v| ss += v * v;
        const rms = 1.0 / @sqrt(ss / @as(f32, @floatFromInt(hidden_size)) + 1e-5);
        for (0..hidden_size) |i| output[offset + i] = input[offset + i] * weight[i] * rms;
    }
    const elapsed = std.time.nanoTimestamp() - start;
    return DispatchResult.ok(elapsed, batch_size * hidden_size, false);
}

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

/// Dispatch vector-matrix multiply for GGUF f16 weights.
/// Uses the provided persistent Metal buffer when available and falls back to CPU otherwise.
pub fn dispatchVecMatMulF16ColMajor(
    lib: *MetalShaderLibrary,
    x: []const f32,
    w: []const f16,
    w_mtl: ?*anyopaque,
    out: []f32,
    x_mtl: ?*anyopaque,
    out_mtl: ?*anyopaque,
    k: usize,
    n: usize,
) DispatchResult {
    const start = std.time.nanoTimestamp();

    if (lib.isReady()) gpu_dispatch: {
        const weight_buf = w_mtl orelse break :gpu_dispatch;
        const queue = lib.command_queue orelse break :gpu_dispatch;
        var pool = &(lib.buffer_pool orelse break :gpu_dispatch);

        const x_bytes = std.mem.sliceAsBytes(x);
        const out_size = out.len * @sizeOf(f32);

        const buf_x = x_mtl orelse blk: {
            const uploaded = acquireUploadBuffer(pool, x_bytes) orelse break :gpu_dispatch;
            break :blk uploaded;
        };
        defer if (x_mtl == null) pool.release(buf_x, x_bytes.len);

        const buf_out = out_mtl orelse blk: {
            const acquired = pool.acquire(out_size) orelse break :gpu_dispatch;
            break :blk acquired;
        };
        defer if (out_mtl == null) pool.release(buf_out, out_size);

        const pipeline = vecMatPipeline(lib, .f16_colmajor) orelse break :gpu_dispatch;

        const cmd_buffer = metal_bindings.createCommandBuffer(queue) orelse break :gpu_dispatch;
        defer metal_bindings.release(cmd_buffer);
        const encoder = metal_bindings.createComputeCommandEncoder(cmd_buffer) orelse break :gpu_dispatch;
        defer metal_bindings.release(encoder);

        metal_bindings.setComputePipelineState(encoder, pipeline);
        metal_bindings.setBuffer(encoder, buf_x, 0, 0);
        metal_bindings.setBuffer(encoder, weight_buf, 0, 1);
        metal_bindings.setBuffer(encoder, buf_out, 0, 2);

        var k_val: u32 = @intCast(k);
        var n_val: u32 = @intCast(n);
        metal_bindings.setBytes(encoder, @ptrCast(&k_val), @sizeOf(u32), 3);
        metal_bindings.setBytes(encoder, @ptrCast(&n_val), @sizeOf(u32), 4);

        const geometry = dispatchVecMatGeometry(.f16_colmajor, n);
        metal_bindings.dispatchThreadgroups(encoder, geometry.grid, geometry.threadgroup);
        metal_bindings.endEncoding(encoder);
        metal_bindings.commitCommandBuffer(cmd_buffer);
        metal_bindings.waitUntilCompleted(cmd_buffer);

        if (out_mtl == null) {
            if (metal_bindings.getBufferContents(buf_out)) |contents| {
                const result_ptr: [*]f32 = @ptrCast(@alignCast(contents));
                @memcpy(out, result_ptr[0..out.len]);
            } else {
                break :gpu_dispatch;
            }
        } else if (metal_bindings.getBufferContents(buf_out)) |_| {
            // Results are already visible through the shared output buffer.
        } else {
            break :gpu_dispatch;
        }

        const elapsed = std.time.nanoTimestamp() - start;
        return DispatchResult.ok(elapsed, n, true);
    }

    for (0..n) |j| {
        var sum: f32 = 0.0;
        for (0..k) |idx| {
            sum += x[idx] * @as(f32, w[j * k + idx]);
        }
        out[j] = sum;
    }

    const elapsed = std.time.nanoTimestamp() - start;
    return DispatchResult.ok(elapsed, n, false);
}

/// Dispatch vector-matrix multiply for GGUF Q4_K row-major weights.
/// Requires a persistent Metal buffer for the raw quantized bytes.
pub fn dispatchVecMatMulQ4K(
    lib: *MetalShaderLibrary,
    x: []const f32,
    w: []const u8,
    w_mtl: ?*anyopaque,
    out: []f32,
    x_mtl: ?*anyopaque,
    out_mtl: ?*anyopaque,
    k: usize,
    n: usize,
) DispatchResult {
    const kernel: VecMatKernel = if (useQ4KRows2Kernel(k, n))
        .q4_k_rows2
    else if (useQ4KPairKernel(k, n))
        .q4_k_pair
    else
        .q4_k;
    return dispatchVecMatMulQ4KKernel(lib, x, w, w_mtl, out, x_mtl, out_mtl, k, n, kernel);
}

pub fn dispatchVecMatMulQ4KAdd(
    lib: *MetalShaderLibrary,
    x: []const f32,
    w: []const u8,
    w_mtl: ?*anyopaque,
    residual: []const f32,
    x_mtl: ?*anyopaque,
    residual_mtl: ?*anyopaque,
    out: []f32,
    out_mtl: ?*anyopaque,
    k: usize,
    n: usize,
) DispatchResult {
    const start = std.time.nanoTimestamp();
    if (n == 0 or out.len == 0 or residual.len < n) return DispatchResult.ok(0, 0, false);

    if (lib.isReady()) gpu_dispatch: {
        _ = w;
        const weight_buf = w_mtl orelse break :gpu_dispatch;
        const queue = lib.command_queue orelse break :gpu_dispatch;
        var pool = &(lib.buffer_pool orelse break :gpu_dispatch);

        const x_bytes = std.mem.sliceAsBytes(x);
        const residual_bytes = std.mem.sliceAsBytes(residual[0..n]);
        const out_size = out.len * @sizeOf(f32);

        const buf_x = x_mtl: {
            if (x_mtl) |buffer| break :x_mtl buffer;
            const uploaded = acquireUploadBuffer(pool, x_bytes) orelse break :gpu_dispatch;
            break :x_mtl uploaded;
        };
        defer if (x_mtl == null) pool.release(buf_x, x_bytes.len);

        const buf_residual = residual_buf: {
            if (residual_mtl) |buffer| break :residual_buf buffer;
            const uploaded = acquireUploadBuffer(pool, residual_bytes) orelse break :gpu_dispatch;
            break :residual_buf uploaded;
        };
        defer if (residual_mtl == null) pool.release(buf_residual, residual_bytes.len);

        const buf_out = out_mtl orelse blk: {
            const acquired = pool.acquire(out_size) orelse break :gpu_dispatch;
            break :blk acquired;
        };
        defer if (out_mtl == null) pool.release(buf_out, out_size);

        const pipeline = lib.pipelines.get(.vecmat_q4_k_add) orelse break :gpu_dispatch;

        const cmd_buffer = metal_bindings.createCommandBuffer(queue) orelse break :gpu_dispatch;
        defer metal_bindings.release(cmd_buffer);
        const encoder = metal_bindings.createComputeCommandEncoder(cmd_buffer) orelse break :gpu_dispatch;
        defer metal_bindings.release(encoder);

        metal_bindings.setComputePipelineState(encoder, pipeline);
        metal_bindings.setBuffer(encoder, buf_x, 0, 0);
        metal_bindings.setBuffer(encoder, weight_buf, 0, 1);
        metal_bindings.setBuffer(encoder, buf_residual, 0, 2);
        metal_bindings.setBuffer(encoder, buf_out, 0, 3);

        var k_val: u32 = @intCast(k);
        var n_val: u32 = @intCast(n);
        metal_bindings.setBytes(encoder, @ptrCast(&k_val), @sizeOf(u32), 4);
        metal_bindings.setBytes(encoder, @ptrCast(&n_val), @sizeOf(u32), 5);

        const geometry = dispatchVecMatGeometry(.q4_k, n);
        metal_bindings.dispatchThreadgroups(encoder, geometry.grid, geometry.threadgroup);
        metal_bindings.endEncoding(encoder);
        metal_bindings.commitCommandBuffer(cmd_buffer);
        metal_bindings.waitUntilCompleted(cmd_buffer);

        if (out_mtl == null) {
            if (metal_bindings.getBufferContents(buf_out)) |contents| {
                const result_ptr: [*]f32 = @ptrCast(@alignCast(contents));
                @memcpy(out, result_ptr[0..out.len]);
            } else {
                break :gpu_dispatch;
            }
        } else if (metal_bindings.getBufferContents(buf_out)) |_| {
            // Results are already visible through the shared output buffer.
        } else {
            break :gpu_dispatch;
        }

        const elapsed = std.time.nanoTimestamp() - start;
        return DispatchResult.ok(elapsed, n, true);
    }

    return DispatchResult.err("Metal vecmat_q4_k_add unavailable");
}

pub fn dispatchVecMatMulBatch(
    lib: *MetalShaderLibrary,
    x: []const f32,
    x_mtl: ?*anyopaque,
    ops: []const VecMatOp,
) bool {
    if (!lib.isReady() or ops.len == 0) return false;
    if (ops.len > 8) return false;

    const queue = lib.command_queue orelse return false;
    var pool = &(lib.buffer_pool orelse return false);
    const x_bytes = std.mem.sliceAsBytes(x);
    const x_buf = x_mtl orelse acquireUploadBuffer(pool, x_bytes) orelse return false;
    defer if (x_mtl == null) pool.release(x_buf, x_bytes.len);

    const cmd_buffer = metal_bindings.createCommandBuffer(queue) orelse return false;
    defer metal_bindings.release(cmd_buffer);
    const encoder = metal_bindings.createComputeCommandEncoder(cmd_buffer) orelse return false;
    defer metal_bindings.release(encoder);

    var out_bufs: [8]?*anyopaque = .{null} ** 8;
    var out_sizes: [8]usize = .{0} ** 8;
    var out_dests: [8][]f32 = undefined;

    for (ops, 0..) |op, i| {
        const pipeline = vecMatPipeline(lib, op.kernel) orelse {
            for (out_bufs, out_sizes) |maybe_buf, out_size| {
                if (maybe_buf) |buf| pool.release(buf, out_size);
            }
            return false;
        };
        const out_size = op.out.len * @sizeOf(f32);
        const out_buf = op.out_buf orelse pool.acquire(out_size) orelse {
            for (out_bufs, out_sizes, ops[0..i]) |maybe_buf, prev_size, prev_op| {
                if (maybe_buf) |buf| if (prev_op.out_buf == null) pool.release(buf, prev_size);
            }
            return false;
        };
        out_bufs[i] = out_buf;
        out_sizes[i] = out_size;
        out_dests[i] = op.out;

        metal_bindings.setComputePipelineState(encoder, pipeline);
        metal_bindings.setBuffer(encoder, x_buf, 0, 0);
        metal_bindings.setBuffer(encoder, op.weight_buf, 0, 1);
        metal_bindings.setBuffer(encoder, out_buf, 0, 2);

        var k_val: u32 = @intCast(op.k);
        var n_val: u32 = @intCast(op.n);
        metal_bindings.setBytes(encoder, @ptrCast(&k_val), @sizeOf(u32), 3);
        metal_bindings.setBytes(encoder, @ptrCast(&n_val), @sizeOf(u32), 4);

        const geometry = dispatchVecMatGeometry(op.kernel, op.n);
        metal_bindings.dispatchThreadgroups(encoder, geometry.grid, geometry.threadgroup);
    }

    metal_bindings.endEncoding(encoder);
    metal_bindings.commitCommandBuffer(cmd_buffer);
    metal_bindings.waitUntilCompleted(cmd_buffer);

    for (out_bufs, out_sizes, 0..) |maybe_buf, out_size, i| {
        if (maybe_buf) |buf| {
            if (ops[i].out_buf == null) {
                if (metal_bindings.getBufferContents(buf)) |contents| {
                    const result_ptr: [*]f32 = @ptrCast(@alignCast(contents));
                    @memcpy(out_dests[i], result_ptr[0..out_dests[i].len]);
                } else {
                    pool.release(buf, out_size);
                    return false;
                }
                pool.release(buf, out_size);
            } else if (metal_bindings.getBufferContents(buf) == null) {
                return false;
            }
        }
    }

    return true;
}

pub fn dispatchVecMatMulQ4KPair(lib: *MetalShaderLibrary, x: []const f32, x_mtl: ?*anyopaque, op: VecMatQ4KPairOp) bool {
    if (!lib.isReady()) return false;
    const queue = lib.command_queue orelse return false;
    var pool = &(lib.buffer_pool orelse return false);
    const pipeline = lib.pipelines.get(.vecmat_q4_k_dual) orelse return false;
    const x_bytes = std.mem.sliceAsBytes(x);
    const x_buf = x_mtl orelse acquireUploadBuffer(pool, x_bytes) orelse return false;
    defer if (x_mtl == null) pool.release(x_buf, x_bytes.len);

    const out1_size = op.out1.len * @sizeOf(f32);
    const out2_size = op.out2.len * @sizeOf(f32);
    const out1_buf = op.out1_buf orelse pool.acquire(out1_size) orelse return false;
    defer if (op.out1_buf == null) pool.release(out1_buf, out1_size);
    const out2_buf = op.out2_buf orelse pool.acquire(out2_size) orelse return false;
    defer if (op.out2_buf == null) pool.release(out2_buf, out2_size);

    const cmd_buffer = metal_bindings.createCommandBuffer(queue) orelse return false;
    defer metal_bindings.release(cmd_buffer);
    const encoder = metal_bindings.createComputeCommandEncoder(cmd_buffer) orelse return false;
    defer metal_bindings.release(encoder);

    metal_bindings.setComputePipelineState(encoder, pipeline);
    metal_bindings.setBuffer(encoder, x_buf, 0, 0);
    metal_bindings.setBuffer(encoder, op.weight1, 0, 1);
    metal_bindings.setBuffer(encoder, out1_buf, 0, 2);
    metal_bindings.setBuffer(encoder, op.weight2, 0, 5);
    metal_bindings.setBuffer(encoder, out2_buf, 0, 6);

    var k_val: u32 = @intCast(op.k);
    var n1_val: u32 = @intCast(op.n1);
    var n2_val: u32 = @intCast(op.n2);
    metal_bindings.setBytes(encoder, @ptrCast(&k_val), @sizeOf(u32), 3);
    metal_bindings.setBytes(encoder, @ptrCast(&n1_val), @sizeOf(u32), 4);
    metal_bindings.setBytes(encoder, @ptrCast(&n2_val), @sizeOf(u32), 7);

    const max_n = @max(op.n1, op.n2);
    const geometry = dispatchVecMatGeometry(.q4_k, max_n);
    metal_bindings.dispatchThreadgroups(encoder, geometry.grid, geometry.threadgroup);
    metal_bindings.endEncoding(encoder);
    metal_bindings.commitCommandBuffer(cmd_buffer);
    metal_bindings.waitUntilCompleted(cmd_buffer);

    if (op.out1_buf == null) {
        if (metal_bindings.getBufferContents(out1_buf)) |contents1| {
            const result_ptr1: [*]f32 = @ptrCast(@alignCast(contents1));
            @memcpy(op.out1, result_ptr1[0..op.out1.len]);
        } else return false;
    } else if (metal_bindings.getBufferContents(out1_buf) == null) return false;

    if (op.out2_buf == null) {
        if (metal_bindings.getBufferContents(out2_buf)) |contents2| {
            const result_ptr2: [*]f32 = @ptrCast(@alignCast(contents2));
            @memcpy(op.out2, result_ptr2[0..op.out2.len]);
        } else return false;
    } else if (metal_bindings.getBufferContents(out2_buf) == null) return false;

    return true;
}

pub fn dispatchVecMatMulQ4KPairRmsNorm(lib: *MetalShaderLibrary, x: []const f32, x_mtl: ?*anyopaque, op: VecMatQ4KPairRmsNormOp) bool {
    if (!lib.isReady()) return false;
    const queue = lib.command_queue orelse return false;
    var pool = &(lib.buffer_pool orelse return false);
    const pipeline = lib.pipelines.get(.vecmat_q4_k_dual_rmsnorm) orelse return false;
    const x_bytes = std.mem.sliceAsBytes(x);
    const x_buf = x_mtl orelse acquireUploadBuffer(pool, x_bytes) orelse return false;
    defer if (x_mtl == null) pool.release(x_buf, x_bytes.len);

    const out1_size = op.out1.len * @sizeOf(f32);
    const out2_size = op.out2.len * @sizeOf(f32);
    const out1_buf = op.out1_buf orelse pool.acquire(out1_size) orelse return false;
    defer if (op.out1_buf == null) pool.release(out1_buf, out1_size);
    const out2_buf = op.out2_buf orelse pool.acquire(out2_size) orelse return false;
    defer if (op.out2_buf == null) pool.release(out2_buf, out2_size);

    const cmd_buffer = metal_bindings.createCommandBuffer(queue) orelse return false;
    defer metal_bindings.release(cmd_buffer);
    const encoder = metal_bindings.createComputeCommandEncoder(cmd_buffer) orelse return false;
    defer metal_bindings.release(encoder);

    metal_bindings.setComputePipelineState(encoder, pipeline);
    metal_bindings.setBuffer(encoder, x_buf, 0, 0);
    metal_bindings.setBuffer(encoder, op.norm_weight, 0, 1);
    metal_bindings.setBuffer(encoder, op.weight1, 0, 2);
    metal_bindings.setBuffer(encoder, out1_buf, 0, 3);
    metal_bindings.setBuffer(encoder, op.weight2, 0, 6);
    metal_bindings.setBuffer(encoder, out2_buf, 0, 7);

    var k_val: u32 = @intCast(op.k);
    var n1_val: u32 = @intCast(op.n1);
    var n2_val: u32 = @intCast(op.n2);
    var inv_rms = op.inv_rms;
    metal_bindings.setBytes(encoder, @ptrCast(&k_val), @sizeOf(u32), 4);
    metal_bindings.setBytes(encoder, @ptrCast(&n1_val), @sizeOf(u32), 5);
    metal_bindings.setBytes(encoder, @ptrCast(&n2_val), @sizeOf(u32), 8);
    metal_bindings.setBytes(encoder, @ptrCast(&inv_rms), @sizeOf(f32), 9);

    const max_n = @max(op.n1, op.n2);
    const geometry = dispatchVecMatGeometry(.q4_k, max_n);
    metal_bindings.dispatchThreadgroups(encoder, geometry.grid, geometry.threadgroup);
    metal_bindings.endEncoding(encoder);
    metal_bindings.commitCommandBuffer(cmd_buffer);
    metal_bindings.waitUntilCompleted(cmd_buffer);

    if (op.out1_buf == null) {
        if (metal_bindings.getBufferContents(out1_buf)) |contents1| {
            const result_ptr1: [*]f32 = @ptrCast(@alignCast(contents1));
            @memcpy(op.out1, result_ptr1[0..op.out1.len]);
        } else return false;
    } else if (metal_bindings.getBufferContents(out1_buf) == null) return false;
    if (op.out2_buf == null) {
        if (metal_bindings.getBufferContents(out2_buf)) |contents2| {
            const result_ptr2: [*]f32 = @ptrCast(@alignCast(contents2));
            @memcpy(op.out2, result_ptr2[0..op.out2.len]);
        } else return false;
    } else if (metal_bindings.getBufferContents(out2_buf) == null) return false;

    return true;
}

pub fn dispatchVecMatMulQ4KTriple(lib: *MetalShaderLibrary, x: []const f32, x_mtl: ?*anyopaque, op: VecMatQ4KTripleOp) bool {
    if (!lib.isReady()) return false;
    const queue = lib.command_queue orelse return false;
    var pool = &(lib.buffer_pool orelse return false);
    const pipeline = lib.pipelines.get(.vecmat_q4_k_triple) orelse return false;
    const x_bytes = std.mem.sliceAsBytes(x);
    const x_buf = x_mtl orelse acquireUploadBuffer(pool, x_bytes) orelse return false;
    defer if (x_mtl == null) pool.release(x_buf, x_bytes.len);

    const out1_size = op.out1.len * @sizeOf(f32);
    const out2_size = op.out2.len * @sizeOf(f32);
    const out3_size = op.out3.len * @sizeOf(f32);
    const out1_buf = op.out1_buf orelse pool.acquire(out1_size) orelse return false;
    defer if (op.out1_buf == null) pool.release(out1_buf, out1_size);
    const out2_buf = op.out2_buf orelse pool.acquire(out2_size) orelse return false;
    defer if (op.out2_buf == null) pool.release(out2_buf, out2_size);
    const out3_buf = op.out3_buf orelse pool.acquire(out3_size) orelse return false;
    defer if (op.out3_buf == null) pool.release(out3_buf, out3_size);

    const cmd_buffer = metal_bindings.createCommandBuffer(queue) orelse return false;
    defer metal_bindings.release(cmd_buffer);
    const encoder = metal_bindings.createComputeCommandEncoder(cmd_buffer) orelse return false;
    defer metal_bindings.release(encoder);

    metal_bindings.setComputePipelineState(encoder, pipeline);
    metal_bindings.setBuffer(encoder, x_buf, 0, 0);
    metal_bindings.setBuffer(encoder, op.weight1, 0, 1);
    metal_bindings.setBuffer(encoder, out1_buf, op.out1_offset_bytes, 2);
    metal_bindings.setBuffer(encoder, op.weight2, 0, 5);
    metal_bindings.setBuffer(encoder, out2_buf, op.out2_offset_bytes, 6);
    metal_bindings.setBuffer(encoder, op.weight3, 0, 8);
    metal_bindings.setBuffer(encoder, out3_buf, op.out3_offset_bytes, 9);

    var k_val: u32 = @intCast(op.k);
    var n1_val: u32 = @intCast(op.n1);
    var n2_val: u32 = @intCast(op.n2);
    var n3_val: u32 = @intCast(op.n3);
    metal_bindings.setBytes(encoder, @ptrCast(&k_val), @sizeOf(u32), 3);
    metal_bindings.setBytes(encoder, @ptrCast(&n1_val), @sizeOf(u32), 4);
    metal_bindings.setBytes(encoder, @ptrCast(&n2_val), @sizeOf(u32), 7);
    metal_bindings.setBytes(encoder, @ptrCast(&n3_val), @sizeOf(u32), 10);

    const max_n = @max(op.n1, @max(op.n2, op.n3));
    const geometry = dispatchVecMatGeometry(.q4_k, max_n);
    metal_bindings.dispatchThreadgroups(encoder, geometry.grid, geometry.threadgroup);
    metal_bindings.endEncoding(encoder);
    metal_bindings.commitCommandBuffer(cmd_buffer);
    metal_bindings.waitUntilCompleted(cmd_buffer);

    if (op.out1_buf == null) {
        if (metal_bindings.getBufferContents(out1_buf)) |contents1| {
            const result_ptr1: [*]f32 = @ptrCast(@alignCast(contents1));
            @memcpy(op.out1, result_ptr1[0..op.out1.len]);
        } else return false;
    } else if (metal_bindings.getBufferContents(out1_buf) == null) return false;

    if (op.out2_buf == null) {
        if (metal_bindings.getBufferContents(out2_buf)) |contents2| {
            const result_ptr2: [*]f32 = @ptrCast(@alignCast(contents2));
            @memcpy(op.out2, result_ptr2[0..op.out2.len]);
        } else return false;
    } else if (metal_bindings.getBufferContents(out2_buf) == null) return false;

    if (op.out3_buf == null) {
        if (metal_bindings.getBufferContents(out3_buf)) |contents3| {
            const result_ptr3: [*]f32 = @ptrCast(@alignCast(contents3));
            @memcpy(op.out3, result_ptr3[0..op.out3.len]);
        } else return false;
    } else if (metal_bindings.getBufferContents(out3_buf) == null) return false;

    return true;
}

pub fn dispatchVecMatMulQ4KTripleRmsNorm(lib: *MetalShaderLibrary, x: []const f32, x_mtl: ?*anyopaque, op: VecMatQ4KTripleRmsNormOp) bool {
    if (!lib.isReady()) return false;
    const queue = lib.command_queue orelse return false;
    var pool = &(lib.buffer_pool orelse return false);
    const pipeline = lib.pipelines.get(.vecmat_q4_k_triple_rmsnorm) orelse return false;
    const x_bytes = std.mem.sliceAsBytes(x);
    const x_buf = x_mtl orelse acquireUploadBuffer(pool, x_bytes) orelse return false;
    defer if (x_mtl == null) pool.release(x_buf, x_bytes.len);

    const out1_size = op.out1.len * @sizeOf(f32);
    const out2_size = op.out2.len * @sizeOf(f32);
    const out3_size = op.out3.len * @sizeOf(f32);
    const out1_buf = op.out1_buf orelse pool.acquire(out1_size) orelse return false;
    defer if (op.out1_buf == null) pool.release(out1_buf, out1_size);
    const out2_buf = op.out2_buf orelse pool.acquire(out2_size) orelse return false;
    defer if (op.out2_buf == null) pool.release(out2_buf, out2_size);
    const out3_buf = op.out3_buf orelse pool.acquire(out3_size) orelse return false;
    defer if (op.out3_buf == null) pool.release(out3_buf, out3_size);

    const cmd_buffer = metal_bindings.createCommandBuffer(queue) orelse return false;
    defer metal_bindings.release(cmd_buffer);
    const encoder = metal_bindings.createComputeCommandEncoder(cmd_buffer) orelse return false;
    defer metal_bindings.release(encoder);

    metal_bindings.setComputePipelineState(encoder, pipeline);
    metal_bindings.setBuffer(encoder, x_buf, 0, 0);
    metal_bindings.setBuffer(encoder, op.norm_weight, 0, 1);
    metal_bindings.setBuffer(encoder, op.weight1, 0, 2);
    metal_bindings.setBuffer(encoder, out1_buf, op.out1_offset_bytes, 3);
    metal_bindings.setBuffer(encoder, op.weight2, 0, 6);
    metal_bindings.setBuffer(encoder, out2_buf, op.out2_offset_bytes, 7);
    metal_bindings.setBuffer(encoder, op.weight3, 0, 9);
    metal_bindings.setBuffer(encoder, out3_buf, op.out3_offset_bytes, 10);

    var k_val: u32 = @intCast(op.k);
    var n1_val: u32 = @intCast(op.n1);
    var n2_val: u32 = @intCast(op.n2);
    var n3_val: u32 = @intCast(op.n3);
    var inv_rms = op.inv_rms;
    metal_bindings.setBytes(encoder, @ptrCast(&k_val), @sizeOf(u32), 4);
    metal_bindings.setBytes(encoder, @ptrCast(&n1_val), @sizeOf(u32), 5);
    metal_bindings.setBytes(encoder, @ptrCast(&n2_val), @sizeOf(u32), 8);
    metal_bindings.setBytes(encoder, @ptrCast(&n3_val), @sizeOf(u32), 11);
    metal_bindings.setBytes(encoder, @ptrCast(&inv_rms), @sizeOf(f32), 12);

    const max_n = @max(op.n1, @max(op.n2, op.n3));
    const geometry = dispatchVecMatGeometry(.q4_k, max_n);
    metal_bindings.dispatchThreadgroups(encoder, geometry.grid, geometry.threadgroup);
    metal_bindings.endEncoding(encoder);
    metal_bindings.commitCommandBuffer(cmd_buffer);
    metal_bindings.waitUntilCompleted(cmd_buffer);

    if (op.out1_buf == null) {
        if (metal_bindings.getBufferContents(out1_buf)) |contents1| {
            const result_ptr1: [*]f32 = @ptrCast(@alignCast(contents1));
            @memcpy(op.out1, result_ptr1[0..op.out1.len]);
        } else return false;
    } else if (metal_bindings.getBufferContents(out1_buf) == null) return false;
    if (op.out2_buf == null) {
        if (metal_bindings.getBufferContents(out2_buf)) |contents2| {
            const result_ptr2: [*]f32 = @ptrCast(@alignCast(contents2));
            @memcpy(op.out2, result_ptr2[0..op.out2.len]);
        } else return false;
    } else if (metal_bindings.getBufferContents(out2_buf) == null) return false;
    if (op.out3_buf == null) {
        if (metal_bindings.getBufferContents(out3_buf)) |contents3| {
            const result_ptr3: [*]f32 = @ptrCast(@alignCast(contents3));
            @memcpy(op.out3, result_ptr3[0..op.out3.len]);
        } else return false;
    } else if (metal_bindings.getBufferContents(out3_buf) == null) return false;

    return true;
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

pub fn dispatchAttentionDecodeSingleHead(
    lib: *MetalShaderLibrary,
    op: AttentionDecodeSingleHeadOp,
) bool {
    if (!lib.isReady()) return false;
    if (op.seq_len == 0 or op.head_dim == 0 or op.out.len < op.head_dim) return false;

    const queue = lib.command_queue orelse return false;
    var pool = &(lib.buffer_pool orelse return false);

    const score_pipeline = lib.getPipeline(.attention_decode_scores_single_head) catch null orelse return false;
    const softmax_pipeline = lib.getPipeline(.softmax_parallel) catch null orelse return false;
    const value_pipeline = lib.getPipeline(.attention_decode_values_single_head) catch null orelse return false;

    const q_bytes = std.mem.sliceAsBytes(op.q);
    const q_buf = op.q_buf orelse acquireUploadBuffer(pool, q_bytes) orelse return false;
    defer if (op.q_buf == null) pool.release(q_buf, q_bytes.len);

    const k_bytes = std.mem.sliceAsBytes(op.k_cache);
    const k_buf = op.k_cache_buf orelse acquireUploadBuffer(pool, k_bytes) orelse return false;
    defer if (op.k_cache_buf == null) pool.release(k_buf, k_bytes.len);

    const v_bytes = std.mem.sliceAsBytes(op.v_cache);
    const v_buf = op.v_cache_buf orelse acquireUploadBuffer(pool, v_bytes) orelse return false;
    defer if (op.v_cache_buf == null) pool.release(v_buf, v_bytes.len);

    const out_size = op.out.len * @sizeOf(f32);
    const out_buf = op.out_buf orelse pool.acquire(out_size) orelse return false;
    defer if (op.out_buf == null) pool.release(out_buf, out_size);

    const scores_size = op.seq_len * @sizeOf(f32);
    const scores_buf = pool.acquire(scores_size) orelse return false;
    defer pool.release(scores_buf, scores_size);

    const cmd_buffer = metal_bindings.createCommandBuffer(queue) orelse return false;
    defer metal_bindings.release(cmd_buffer);
    const encoder = metal_bindings.createComputeCommandEncoder(cmd_buffer) orelse return false;
    defer metal_bindings.release(encoder);

    var seq_len_val: u32 = @intCast(op.seq_len);
    var head_dim_val: u32 = @intCast(op.head_dim);
    var kv_stride_val: u32 = @intCast(op.kv_stride);
    var head_offset_val: u32 = @intCast(op.head_offset);
    var scale_val = op.scale;

    metal_bindings.setComputePipelineState(encoder, score_pipeline);
    metal_bindings.setBuffer(encoder, q_buf, @intCast(op.q_offset_bytes), 0);
    metal_bindings.setBuffer(encoder, k_buf, 0, 1);
    metal_bindings.setBuffer(encoder, scores_buf, 0, 2);
    metal_bindings.setBytes(encoder, @ptrCast(&seq_len_val), @sizeOf(u32), 3);
    metal_bindings.setBytes(encoder, @ptrCast(&head_dim_val), @sizeOf(u32), 4);
    metal_bindings.setBytes(encoder, @ptrCast(&kv_stride_val), @sizeOf(u32), 5);
    metal_bindings.setBytes(encoder, @ptrCast(&head_offset_val), @sizeOf(u32), 6);
    metal_bindings.setBytes(encoder, @ptrCast(&scale_val), @sizeOf(f32), 7);

    const score_tg: usize = 64;
    metal_bindings.dispatchThreadgroups(encoder, .{
        .width = (op.seq_len + score_tg - 1) / score_tg,
        .height = 1,
        .depth = 1,
    }, .{
        .width = score_tg,
        .height = 1,
        .depth = 1,
    });

    metal_bindings.setComputePipelineState(encoder, softmax_pipeline);
    metal_bindings.setBuffer(encoder, scores_buf, 0, 0);
    metal_bindings.setBuffer(encoder, scores_buf, 0, 1);
    metal_bindings.setBytes(encoder, @ptrCast(&seq_len_val), @sizeOf(u32), 2);
    metal_bindings.dispatchThreadgroups(encoder, .{
        .width = 1,
        .height = 1,
        .depth = 1,
    }, .{
        .width = 256,
        .height = 1,
        .depth = 1,
    });

    metal_bindings.setComputePipelineState(encoder, value_pipeline);
    metal_bindings.setBuffer(encoder, scores_buf, 0, 0);
    metal_bindings.setBuffer(encoder, v_buf, 0, 1);
    metal_bindings.setBuffer(encoder, out_buf, @intCast(op.out_offset_bytes), 2);
    metal_bindings.setBytes(encoder, @ptrCast(&seq_len_val), @sizeOf(u32), 3);
    metal_bindings.setBytes(encoder, @ptrCast(&head_dim_val), @sizeOf(u32), 4);
    metal_bindings.setBytes(encoder, @ptrCast(&kv_stride_val), @sizeOf(u32), 5);
    metal_bindings.setBytes(encoder, @ptrCast(&head_offset_val), @sizeOf(u32), 6);

    const value_tg: usize = 64;
    metal_bindings.dispatchThreadgroups(encoder, .{
        .width = (op.head_dim + value_tg - 1) / value_tg,
        .height = 1,
        .depth = 1,
    }, .{
        .width = value_tg,
        .height = 1,
        .depth = 1,
    });

    metal_bindings.endEncoding(encoder);
    metal_bindings.commitCommandBuffer(cmd_buffer);
    metal_bindings.waitUntilCompleted(cmd_buffer);

    if (op.out_buf == null) {
        if (metal_bindings.getBufferContents(out_buf)) |contents| {
            const result_ptr: [*]f32 = @ptrCast(@alignCast(contents));
            @memcpy(op.out[0..op.head_dim], result_ptr[0..op.head_dim]);
        } else return false;
    } else if (metal_bindings.getBufferContents(out_buf) == null) return false;

    return true;
}

pub fn dispatchAttentionDecodeHeads(lib: *MetalShaderLibrary, op: AttentionDecodeHeadsOp) bool {
    if (!lib.isReady()) return false;
    if (op.seq_len == 0 or op.head_dim == 0 or op.n_heads == 0 or op.heads_per_group == 0) return false;

    const queue = lib.command_queue orelse return false;
    var pool = &(lib.buffer_pool orelse return false);

    const fused_heads_pipeline = lib.getPipeline(.attention_decode_fused_heads) catch null;
    const fused_pipeline = lib.getPipeline(.attention_decode_fused_single_head) catch null;
    const score_pipeline = lib.getPipeline(.attention_decode_scores_single_head) catch null orelse return false;
    const softmax_pipeline = lib.getPipeline(.softmax_parallel) catch null orelse return false;
    const value_pipeline = lib.getPipeline(.attention_decode_values_single_head) catch null orelse return false;

    const max_fused_decode_seq_len: usize = 512;
    const fused_supported = op.seq_len <= max_fused_decode_seq_len;
    const allow_fused_heads = op.mode == .auto or op.mode == .fused_heads;
    const allow_fused_single = op.mode == .auto or op.mode == .fused_single;
    const use_fused_heads = allow_fused_heads and fused_heads_pipeline != null and fused_supported;
    const use_fused = !use_fused_heads and allow_fused_single and fused_pipeline != null and fused_supported;
    if (op.mode == .fused_heads and !use_fused_heads) return false;
    if (op.mode == .fused_single and !use_fused) return false;

    const scores_size = op.seq_len * @sizeOf(f32);
    const scores_buf = if (!use_fused_heads and !use_fused) pool.acquire(scores_size) orelse return false else null;
    defer if (scores_buf) |buf| pool.release(buf, scores_size);

    const cmd_buffer = metal_bindings.createCommandBuffer(queue) orelse return false;
    defer metal_bindings.release(cmd_buffer);
    const encoder = metal_bindings.createComputeCommandEncoder(cmd_buffer) orelse return false;
    defer metal_bindings.release(encoder);

    var seq_len_val: u32 = @intCast(op.seq_len);
    var head_dim_val: u32 = @intCast(op.head_dim);
    var kv_stride_val: u32 = @intCast(op.kv_stride);
    var n_heads_val: u32 = @intCast(op.n_heads);
    var heads_per_group_val: u32 = @intCast(op.heads_per_group);
    var scale_val = op.scale;

    const score_tg: usize = 64;
    const value_tg: usize = 64;
    const fused_tg: usize = 64;
    if (use_fused_heads) {
        metal_bindings.setComputePipelineState(encoder, fused_heads_pipeline.?);
        metal_bindings.setBuffer(encoder, op.q_buf, 0, 0);
        metal_bindings.setBuffer(encoder, op.k_cache_buf, 0, 1);
        metal_bindings.setBuffer(encoder, op.v_cache_buf, 0, 2);
        metal_bindings.setBuffer(encoder, op.out_buf, 0, 3);
        metal_bindings.setBytes(encoder, @ptrCast(&seq_len_val), @sizeOf(u32), 4);
        metal_bindings.setBytes(encoder, @ptrCast(&head_dim_val), @sizeOf(u32), 5);
        metal_bindings.setBytes(encoder, @ptrCast(&kv_stride_val), @sizeOf(u32), 6);
        metal_bindings.setBytes(encoder, @ptrCast(&n_heads_val), @sizeOf(u32), 7);
        metal_bindings.setBytes(encoder, @ptrCast(&heads_per_group_val), @sizeOf(u32), 8);
        metal_bindings.setBytes(encoder, @ptrCast(&scale_val), @sizeOf(f32), 9);
        metal_bindings.dispatchThreadgroups(encoder, .{
            .width = op.n_heads,
            .height = 1,
            .depth = 1,
        }, .{
            .width = fused_tg,
            .height = 1,
            .depth = 1,
        });
        metal_bindings.endEncoding(encoder);
        metal_bindings.commitCommandBuffer(cmd_buffer);
        metal_bindings.waitUntilCompleted(cmd_buffer);
        return metal_bindings.getBufferContents(op.out_buf) != null;
    }

    for (0..op.n_heads) |h| {
        var head_offset_val: u32 = @intCast((h / op.heads_per_group) * op.head_dim);
        const q_offset_bytes = h * op.head_dim * @sizeOf(f32);
        const out_offset_bytes = q_offset_bytes;

        if (use_fused) {
            metal_bindings.setComputePipelineState(encoder, fused_pipeline.?);
            metal_bindings.setBuffer(encoder, op.q_buf, @intCast(q_offset_bytes), 0);
            metal_bindings.setBuffer(encoder, op.k_cache_buf, 0, 1);
            metal_bindings.setBuffer(encoder, op.v_cache_buf, 0, 2);
            metal_bindings.setBuffer(encoder, op.out_buf, @intCast(out_offset_bytes), 3);
            metal_bindings.setBytes(encoder, @ptrCast(&seq_len_val), @sizeOf(u32), 4);
            metal_bindings.setBytes(encoder, @ptrCast(&head_dim_val), @sizeOf(u32), 5);
            metal_bindings.setBytes(encoder, @ptrCast(&kv_stride_val), @sizeOf(u32), 6);
            metal_bindings.setBytes(encoder, @ptrCast(&head_offset_val), @sizeOf(u32), 7);
            metal_bindings.setBytes(encoder, @ptrCast(&scale_val), @sizeOf(f32), 8);
            metal_bindings.dispatchThreadgroups(encoder, .{
                .width = 1,
                .height = 1,
                .depth = 1,
            }, .{
                .width = fused_tg,
                .height = 1,
                .depth = 1,
            });
        } else {
            metal_bindings.setComputePipelineState(encoder, score_pipeline);
            metal_bindings.setBuffer(encoder, op.q_buf, @intCast(q_offset_bytes), 0);
            metal_bindings.setBuffer(encoder, op.k_cache_buf, 0, 1);
            metal_bindings.setBuffer(encoder, scores_buf.?, 0, 2);
            metal_bindings.setBytes(encoder, @ptrCast(&seq_len_val), @sizeOf(u32), 3);
            metal_bindings.setBytes(encoder, @ptrCast(&head_dim_val), @sizeOf(u32), 4);
            metal_bindings.setBytes(encoder, @ptrCast(&kv_stride_val), @sizeOf(u32), 5);
            metal_bindings.setBytes(encoder, @ptrCast(&head_offset_val), @sizeOf(u32), 6);
            metal_bindings.setBytes(encoder, @ptrCast(&scale_val), @sizeOf(f32), 7);
            metal_bindings.dispatchThreadgroups(encoder, .{
                .width = (op.seq_len + score_tg - 1) / score_tg,
                .height = 1,
                .depth = 1,
            }, .{
                .width = score_tg,
                .height = 1,
                .depth = 1,
            });

            metal_bindings.setComputePipelineState(encoder, softmax_pipeline);
            metal_bindings.setBuffer(encoder, scores_buf.?, 0, 0);
            metal_bindings.setBuffer(encoder, scores_buf.?, 0, 1);
            metal_bindings.setBytes(encoder, @ptrCast(&seq_len_val), @sizeOf(u32), 2);
            metal_bindings.dispatchThreadgroups(encoder, .{
                .width = 1,
                .height = 1,
                .depth = 1,
            }, .{
                .width = 256,
                .height = 1,
                .depth = 1,
            });

            metal_bindings.setComputePipelineState(encoder, value_pipeline);
            metal_bindings.setBuffer(encoder, scores_buf.?, 0, 0);
            metal_bindings.setBuffer(encoder, op.v_cache_buf, 0, 1);
            metal_bindings.setBuffer(encoder, op.out_buf, @intCast(out_offset_bytes), 2);
            metal_bindings.setBytes(encoder, @ptrCast(&seq_len_val), @sizeOf(u32), 3);
            metal_bindings.setBytes(encoder, @ptrCast(&head_dim_val), @sizeOf(u32), 4);
            metal_bindings.setBytes(encoder, @ptrCast(&kv_stride_val), @sizeOf(u32), 5);
            metal_bindings.setBytes(encoder, @ptrCast(&head_offset_val), @sizeOf(u32), 6);
            metal_bindings.dispatchThreadgroups(encoder, .{
                .width = (op.head_dim + value_tg - 1) / value_tg,
                .height = 1,
                .depth = 1,
            }, .{
                .width = value_tg,
                .height = 1,
                .depth = 1,
            });
        }
    }

    metal_bindings.endEncoding(encoder);
    metal_bindings.commitCommandBuffer(cmd_buffer);
    metal_bindings.waitUntilCompleted(cmd_buffer);

    return metal_bindings.getBufferContents(op.out_buf) != null;
}

pub fn dispatchAttentionDecodeHeadsQ4KAdd(lib: *MetalShaderLibrary, op: AttentionDecodeHeadsQ4KAddOp) bool {
    if (!lib.isReady()) return false;
    if (op.seq_len == 0 or op.head_dim == 0 or op.n_heads == 0 or op.heads_per_group == 0) return false;
    if (op.k == 0 or op.n == 0) return false;

    const queue = lib.command_queue orelse return false;
    const fused_heads_pipeline = lib.getPipeline(.attention_decode_fused_heads) catch null orelse return false;
    const q4k_add_pipeline = lib.pipelines.get(.vecmat_q4_k_add) orelse return false;
    if (op.seq_len > 512) return false;

    const cmd_buffer = metal_bindings.createCommandBuffer(queue) orelse return false;
    defer metal_bindings.release(cmd_buffer);
    const encoder = metal_bindings.createComputeCommandEncoder(cmd_buffer) orelse return false;
    defer metal_bindings.release(encoder);

    var seq_len_val: u32 = @intCast(op.seq_len);
    var head_dim_val: u32 = @intCast(op.head_dim);
    var kv_stride_val: u32 = @intCast(op.kv_stride);
    var n_heads_val: u32 = @intCast(op.n_heads);
    var heads_per_group_val: u32 = @intCast(op.heads_per_group);
    var scale_val = op.scale;
    const fused_tg: usize = 64;

    metal_bindings.setComputePipelineState(encoder, fused_heads_pipeline);
    metal_bindings.setBuffer(encoder, op.q_buf, 0, 0);
    metal_bindings.setBuffer(encoder, op.k_cache_buf, 0, 1);
    metal_bindings.setBuffer(encoder, op.v_cache_buf, 0, 2);
    metal_bindings.setBuffer(encoder, op.attn_out_buf, 0, 3);
    metal_bindings.setBytes(encoder, @ptrCast(&seq_len_val), @sizeOf(u32), 4);
    metal_bindings.setBytes(encoder, @ptrCast(&head_dim_val), @sizeOf(u32), 5);
    metal_bindings.setBytes(encoder, @ptrCast(&kv_stride_val), @sizeOf(u32), 6);
    metal_bindings.setBytes(encoder, @ptrCast(&n_heads_val), @sizeOf(u32), 7);
    metal_bindings.setBytes(encoder, @ptrCast(&heads_per_group_val), @sizeOf(u32), 8);
    metal_bindings.setBytes(encoder, @ptrCast(&scale_val), @sizeOf(f32), 9);
    metal_bindings.dispatchThreadgroups(encoder, .{
        .width = op.n_heads,
        .height = 1,
        .depth = 1,
    }, .{
        .width = fused_tg,
        .height = 1,
        .depth = 1,
    });

    metal_bindings.setComputePipelineState(encoder, q4k_add_pipeline);
    metal_bindings.setBuffer(encoder, op.attn_out_buf, 0, 0);
    metal_bindings.setBuffer(encoder, op.weight_buf, 0, 1);
    metal_bindings.setBuffer(encoder, op.residual_buf, 0, 2);
    metal_bindings.setBuffer(encoder, op.out_buf, 0, 3);

    var k_val: u32 = @intCast(op.k);
    var n_val: u32 = @intCast(op.n);
    metal_bindings.setBytes(encoder, @ptrCast(&k_val), @sizeOf(u32), 4);
    metal_bindings.setBytes(encoder, @ptrCast(&n_val), @sizeOf(u32), 5);

    const geometry = dispatchVecMatGeometry(.q4_k, op.n);
    metal_bindings.dispatchThreadgroups(encoder, geometry.grid, geometry.threadgroup);
    metal_bindings.endEncoding(encoder);
    metal_bindings.commitCommandBuffer(cmd_buffer);
    metal_bindings.waitUntilCompleted(cmd_buffer);

    return metal_bindings.getBufferContents(op.out_buf) != null;
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

test "dispatchVecMatMulF16ColMajor CPU fallback" {
    const lib = try MetalShaderLibrary.init(std.testing.allocator);
    defer lib.deinit();

    const x = [_]f32{ 1.0, 2.0, 3.0 };
    const w = [_]f16{
        @as(f16, 1.0), @as(f16, 2.0), @as(f16, 3.0),
        @as(f16, 4.0), @as(f16, 5.0), @as(f16, 6.0),
    };
    var out: [2]f32 = undefined;

    const result = dispatchVecMatMulF16ColMajor(lib, &x, &w, null, &out, 3, 2);

    try std.testing.expect(result.success);
    try std.testing.expect(!result.gpu_utilized);
    try std.testing.expectApproxEqAbs(@as(f32, 14.0), out[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 32.0), out[1], 0.001);
}
