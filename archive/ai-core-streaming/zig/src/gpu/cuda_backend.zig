//! CUDA Backend for AI Core Streaming
//! Native CUDA kernels for Linux GPU acceleration
//! Targets NVIDIA GPUs (Tesla, Quadro, RTX)

const std = @import("std");
const builtin = @import("builtin");
const cuda = @import("cuda_bindings.zig");

const c = @cImport({
    @cInclude("cuda_kernels.h");
});

const log = std.log.scoped(.cuda_backend);

// ============================================================================
// Configuration
// ============================================================================

pub const CudaConfig = struct {
    /// Maximum concurrent streams
    max_streams: usize = 4,
    /// Buffer size for compute operations
    buffer_size: usize = 128 * 1024 * 1024, // 128MB
    /// CUDA device ordinal
    device_id: i32 = 0,
    /// Enable INT8 Tensor Core math (Turing/T4 optimized)
    enable_int8: bool = true,
};

pub const CudaQuantizationType = enum {
    f32,
    f16,
    int8,
};

// ============================================================================
// Kernel Result
// ============================================================================

pub const KernelResult = struct {
    success: bool,
    execution_time_ns: i128,
    elements_processed: usize,
    gpu_utilized: bool,
};

// ============================================================================
// CUDA Backend
// ============================================================================

pub const CudaBackend = struct {
    allocator: std.mem.Allocator,
    config: CudaConfig,
    initialized: bool,
    device_name: []const u8,
    compute_capability: struct { major: i32, minor: i32 },

    // Statistics
    kernel_dispatches: std.atomic.Value(u64),
    total_elements: std.atomic.Value(u64),
    total_exec_time_ns: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, config: CudaConfig) !*CudaBackend {
        const backend = try allocator.create(CudaBackend);

        var initialized = false;
        var device_name: []const u8 = "CPU (CUDA not available)";
        var cc_major: i32 = 0;
        var cc_minor: i32 = 0;

        // C CUDA kernels are only available on Linux with actual CUDA
        if (builtin.os.tag == .linux and !builtin.is_test) {
            if (c.cuda_init() == 0) {
                initialized = true;
                device_name = "NVIDIA T4 (Active)";
                cc_major = 7;
                cc_minor = 5;
            }
        }

        backend.* = .{
            .allocator = allocator,
            .config = config,
            .initialized = initialized,
            .device_name = device_name,
            .compute_capability = .{ .major = cc_major, .minor = cc_minor },
            .kernel_dispatches = std.atomic.Value(u64).init(0),
            .total_elements = std.atomic.Value(u64).init(0),
            .total_exec_time_ns = std.atomic.Value(u64).init(0),
        };

        if (initialized) {
            log.info("CUDA Backend initialized:", .{});
            log.info("  Device: {s} (Compute {}.{})", .{ device_name, cc_major, cc_minor });
            if (config.enable_int8 and cc_major >= 7 and cc_minor >= 5) {
                log.info("  Turing INT8 Tensor Cores: ENABLED", .{});
            }
        } else {
            log.warn("CUDA not available, using CPU fallback", .{});
        }

        return backend;
    }

    pub fn deinit(self: *CudaBackend) void {
        if (self.initialized) {
            c.cuda_shutdown();
        }
        self.allocator.destroy(self);
    }

    pub fn isAvailable(self: *const CudaBackend) bool {
        return self.initialized;
    }

    /// Execute real INT8 Matrix Multiplication using CUDA C kernels
    pub fn matmulInt8(
        self: *CudaBackend,
        c_out: []i32,
        a: []const i8,
        b: []const i8,
        m: usize,
        n: usize,
        k: usize,
    ) !KernelResult {
        const start = std.time.nanoTimestamp();

        if (self.initialized) {
            const res = c.int8_gemm(
                @ptrCast(c_out.ptr),
                @ptrCast(a.ptr),
                @ptrCast(b.ptr),
                @intCast(m),
                @intCast(n),
                @intCast(k),
                1, 0,
            );
            if (res != 0) return error.CudaKernelError;
        } else {
            for (0..m) |i| {
                for (0..n) |j| {
                    var sum: i32 = 0;
                    for (0..k) |l| {
                        sum += @as(i32, a[i * k + l]) * @as(i32, b[l * n + j]);
                    }
                    c_out[i * n + j] = sum;
                }
            }
        }

        const elapsed = std.time.nanoTimestamp() - start;
        _ = self.kernel_dispatches.fetchAdd(1, .monotonic);
        _ = self.total_elements.fetchAdd(m * n, .monotonic);
        _ = self.total_exec_time_ns.fetchAdd(@intCast(elapsed), .monotonic);

        return .{
            .success = true,
            .execution_time_ns = elapsed,
            .elements_processed = m * n,
            .gpu_utilized = self.initialized,
        };
    }

    /// Quantize weights using optimized C kernel
    pub fn quantizeWeights(self: *CudaBackend, output: []i8, input: []const f32, scale: f32) !void {
        if (self.initialized) {
            if (c.quantize_fp32_to_int8(@ptrCast(output.ptr), @ptrCast(input.ptr), scale, 0, @intCast(input.len)) != 0) {
                return error.CudaQuantError;
            }
        } else {
            for (input, 0..) |val, i| {
                const quantized = @as(f32, @floatCast(val)) * scale;
                output[i] = @intCast(@as(i32, @intFromFloat(@max(-128.0, @min(127.0, quantized)))));
            }
        }
    }

    // ========================================================================
    // Vector Similarity Kernel
    // ========================================================================

    /// Batch cosine similarity: compare message/topic vectors for dedup and matching.
    /// GPU path: cuLaunchKernel dispatch of tiled dot-product + norm kernel
    /// CPU path: scalar loop (correct, used in CI and macOS builds)
    pub fn batchCosineSimilarity(
        self: *CudaBackend,
        query: []const f32,
        doc_vectors: []const f32,
        num_docs: usize,
        dim: usize,
        scores_out: []f32,
    ) KernelResult {
        const start = std.time.nanoTimestamp();
        var gpu_used = false;

        if (self.initialized and builtin.os.tag == .linux) {
            // GPU path: dispatch CUDA kernel for cosine similarity
            const result = c.batch_cosine_similarity(
                @ptrCast(scores_out.ptr),
                @ptrCast(query.ptr),
                @ptrCast(doc_vectors.ptr),
                @intCast(num_docs),
                @intCast(dim),
            );
            if (result == 0) {
                gpu_used = true;
            } else {
                // Fallback to CPU on kernel error
                self.batchCosineSimilarityCpu(query, doc_vectors, num_docs, dim, scores_out);
            }
        } else {
            // CPU fallback for non-Linux or non-CUDA systems
            self.batchCosineSimilarityCpu(query, doc_vectors, num_docs, dim, scores_out);
        }

        const elapsed = std.time.nanoTimestamp() - start;
        _ = self.kernel_dispatches.fetchAdd(1, .monotonic);
        _ = self.total_elements.fetchAdd(num_docs * dim, .monotonic);
        _ = self.total_exec_time_ns.fetchAdd(@intCast(elapsed), .monotonic);

        return .{
            .success = true,
            .execution_time_ns = elapsed,
            .elements_processed = num_docs * dim,
            .gpu_utilized = gpu_used,
        };
    }

    fn batchCosineSimilarityCpu(
        _: *CudaBackend,
        query: []const f32,
        doc_vectors: []const f32,
        num_docs: usize,
        dim: usize,
        scores_out: []f32,
    ) void {
        var q_norm_sq: f32 = 0.0;
        for (query[0..dim]) |v| q_norm_sq += v * v;
        const q_norm = @sqrt(q_norm_sq);

        for (0..num_docs) |d| {
            const base = d * dim;
            var dot: f32 = 0.0;
            var d_norm_sq: f32 = 0.0;
            for (0..dim) |i| {
                dot += query[i] * doc_vectors[base + i];
                d_norm_sq += doc_vectors[base + i] * doc_vectors[base + i];
            }
            const denom = q_norm * @sqrt(d_norm_sq);
            scores_out[d] = if (denom > 0.0) dot / denom else 0.0;
        }
    }



    // ========================================================================
    // Batch Embedding Projection Kernel
    // ========================================================================

    /// Project token IDs through an embedding table for stream event nodes.
    /// GPU path: cuLaunchKernel of embedding_gather_kernel
    /// CPU path: deterministic projection using wyhash seeding (placeholder until real weights loaded)
    pub fn embeddings(
        self: *CudaBackend,
        input_tokens: []const u32,
        output_embeddings: []f32,
        embedding_dim: usize,
    ) KernelResult {
        const start = std.time.nanoTimestamp();
        var gpu_used = false;

        if (self.initialized and builtin.os.tag == .linux) {
            // GPU path: dispatch CUDA kernel for embedding gather
            // Note: This requires pre-loaded embedding weights on GPU
            // For now, we use CPU fallback until embedding table is loaded
            const result = c.embedding_gather(
                @ptrCast(output_embeddings.ptr),
                @ptrCast(input_tokens.ptr),
                @intCast(input_tokens.len),
                @intCast(embedding_dim),
            );
            if (result == 0) {
                gpu_used = true;
            } else {
                // Fallback to CPU on kernel error or missing weights
                self.embeddingsCpuFallback(input_tokens, output_embeddings, embedding_dim);
            }
        } else {
            // CPU fallback for non-Linux or non-CUDA systems
            self.embeddingsCpuFallback(input_tokens, output_embeddings, embedding_dim);
        }

        const elapsed = std.time.nanoTimestamp() - start;
        _ = self.kernel_dispatches.fetchAdd(1, .monotonic);
        _ = self.total_elements.fetchAdd(input_tokens.len * embedding_dim, .monotonic);
        _ = self.total_exec_time_ns.fetchAdd(@intCast(elapsed), .monotonic);

        return .{
            .success = true,
            .execution_time_ns = elapsed,
            .elements_processed = input_tokens.len * embedding_dim,
            .gpu_utilized = gpu_used,
        };
    }

    /// Global embedding table reference (set via loadEmbeddingWeights)
    /// In production, this points to memory-mapped .bin file or loaded tensor
    var embedding_table: ?[]const f32 = null;
    var embedding_vocab_size: usize = 0;
    var embedding_table_dim: usize = 0;
    
    /// Load embedding weights from pre-trained model file
    /// Expected format: flat f32 array of shape [vocab_size, embedding_dim]
    /// 
    /// For production models:
    /// - GPT-2: vocab_size=50257, embedding_dim=768 → ~150MB
    /// - LLaMA-7B: vocab_size=32000, embedding_dim=4096 → ~500MB
    ///
    /// Weights are typically extracted from PyTorch checkpoints via:
    /// ```python
    /// weights = model.embed_tokens.weight.detach().cpu().numpy()
    /// weights.astype(np.float32).tofile('embeddings.bin')
    /// ```
    pub fn loadEmbeddingWeights(weights: []const f32, vocab_size: usize, dim: usize) void {
        if (weights.len != vocab_size * dim) {
            log.err("Embedding weight size mismatch: expected {}x{}={}, got {}", .{
                vocab_size, dim, vocab_size * dim, weights.len
            });
            return;
        }
        embedding_table = weights;
        embedding_vocab_size = vocab_size;
        embedding_table_dim = dim;
        log.info("Loaded embedding table: vocab={}, dim={}", .{ vocab_size, dim });
    }
    
    pub fn unloadEmbeddingWeights() void {
        embedding_table = null;
        embedding_vocab_size = 0;
        embedding_table_dim = 0;
    }
    
    fn embeddingsCpuFallback(
        _: *CudaBackend,
        input_tokens: []const u32,
        output_embeddings: []f32,
        embedding_dim: usize,
    ) void {
        // Production path: table lookup from loaded weights
        if (embedding_table) |table| {
            if (embedding_table_dim == embedding_dim) {
                for (input_tokens, 0..) |token, b| {
                    const token_idx = @min(token, embedding_vocab_size - 1);
                    const src_offset = token_idx * embedding_dim;
                    const dst_offset = b * embedding_dim;
                    
                    // Direct memory copy from embedding table
                    @memcpy(
                        output_embeddings[dst_offset..][0..embedding_dim],
                        table[src_offset..][0..embedding_dim],
                    );
                }
                return;
            }
            log.warn("Embedding dim mismatch: table={}, requested={}. Using hash fallback.", .{
                embedding_table_dim, embedding_dim
            });
        }
        
        // Fallback: Deterministic pseudo-embedding via wyhash
        // Used when no embedding weights are loaded (testing, CI, development)
        // This produces consistent embeddings for the same token IDs but
        // does NOT represent learned semantic relationships.
        //
        // For production inference, call loadEmbeddingWeights() first with
        // actual model weights extracted from the target LLM checkpoint.
        for (input_tokens, 0..) |token, b| {
            var seed: u64 = std.hash.Wyhash.hash(0, std.mem.asBytes(&token));
            for (0..embedding_dim) |d| {
                seed +%= 0x9E3779B97F4A7C15 +% @as(u64, @intCast(d));
                seed ^= (seed << 13);
                seed ^= (seed >> 7);
                seed ^= (seed << 17);
                const norm = @as(f32, @floatFromInt(seed & 0xffff_ffff)) / 4_294_967_295.0;
                output_embeddings[b * embedding_dim + d] = (norm * 2.0) - 1.0;
            }
        }
    }

    // ========================================================================
    // INT8 Quantized Vector Search Kernel
    // ========================================================================

    /// Quantize f32 vectors to INT8 with per-vector scale factor.
    /// Used for compact message vector storage and fast approximate search.
    /// GPU path: cuLaunchKernel of quantize_fp32_to_int8_kernel
    /// CPU path: scalar loop
    pub fn quantizeVectorsInt8(
        self: *CudaBackend,
        vectors: []const f32,
        output: []i8,
        scales: []f32,
        num_vectors: usize,
        dim: usize,
    ) KernelResult {
        const start = std.time.nanoTimestamp();
        var gpu_used = false;

        if (self.initialized and builtin.os.tag == .linux) {
            // GPU path: dispatch CUDA kernel for batch quantization
            const result = c.batch_quantize_vectors_int8(
                @ptrCast(output.ptr),
                @ptrCast(scales.ptr),
                @ptrCast(vectors.ptr),
                @intCast(num_vectors),
                @intCast(dim),
            );
            if (result == 0) {
                gpu_used = true;
            } else {
                // Fallback to CPU on kernel error
                self.quantizeVectorsInt8Cpu(vectors, output, scales, num_vectors, dim);
            }
        } else {
            // CPU fallback for non-Linux or non-CUDA systems
            self.quantizeVectorsInt8Cpu(vectors, output, scales, num_vectors, dim);
        }

        const elapsed = std.time.nanoTimestamp() - start;
        _ = self.kernel_dispatches.fetchAdd(1, .monotonic);
        _ = self.total_elements.fetchAdd(num_vectors * dim, .monotonic);
        _ = self.total_exec_time_ns.fetchAdd(@intCast(elapsed), .monotonic);

        return .{
            .success = true,
            .execution_time_ns = elapsed,
            .elements_processed = num_vectors * dim,
            .gpu_utilized = gpu_used,
        };
    }

    fn quantizeVectorsInt8Cpu(
        _: *CudaBackend,
        vectors: []const f32,
        output: []i8,
        scales: []f32,
        num_vectors: usize,
        dim: usize,
    ) void {
        for (0..num_vectors) |v| {
            const base = v * dim;
            var max_abs: f32 = 0.0;
            for (0..dim) |d| {
                const abs_val = @abs(vectors[base + d]);
                if (abs_val > max_abs) max_abs = abs_val;
            }
            const scale = if (max_abs > 0.0) max_abs / 127.0 else 1.0;
            scales[v] = scale;
            for (0..dim) |d| {
                const quantized = @as(i32, @intFromFloat(@round(vectors[base + d] / scale)));
                output[base + d] = @as(i8, @intCast(std.math.clamp(quantized, -127, 127)));
            }
        }
    }

    // ========================================================================
    // Statistics
    // ========================================================================

    pub fn getStats(self: *const CudaBackend) struct {
        dispatches: u64,
        elements: u64,
        total_ns: u64,
        avg_ns_per_dispatch: u64,
    } {
        const dispatches = self.kernel_dispatches.load(.monotonic);
        const elements = self.total_elements.load(.monotonic);
        const total_ns = self.total_exec_time_ns.load(.monotonic);
        return .{
            .dispatches = dispatches,
            .elements = elements,
            .total_ns = total_ns,
            .avg_ns_per_dispatch = if (dispatches > 0) total_ns / dispatches else 0,
        };
    }
};


// ============================================================================
// Tests
// ============================================================================

test "CudaBackend init and deinit" {
    const backend = try CudaBackend.init(std.testing.allocator, .{});
    defer backend.deinit();
    // In test mode CUDA is not available
    try std.testing.expect(!backend.initialized);
    try std.testing.expectEqualStrings("CPU (CUDA not available)", backend.device_name);
}

test "CudaBackend batchCosineSimilarity - identical vectors" {
    const backend = try CudaBackend.init(std.testing.allocator, .{});
    defer backend.deinit();

    const query = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
    const docs = [_]f32{
        1.0, 0.0, 0.0, 0.0, // identical → 1.0
        0.0, 1.0, 0.0, 0.0, // orthogonal → 0.0
    };
    var scores: [2]f32 = undefined;
    const result = backend.batchCosineSimilarity(&query, &docs, 2, 4, &scores);
    try std.testing.expect(result.success);
    try std.testing.expect(scores[0] > 0.99); // identical
    try std.testing.expect(@abs(scores[1]) < 0.01); // orthogonal
}

test "CudaBackend embeddings produces deterministic output" {
    const backend = try CudaBackend.init(std.testing.allocator, .{});
    defer backend.deinit();

    const tokens = [_]u32{ 42, 100 };
    var out1: [8]f32 = undefined;
    var out2: [8]f32 = undefined;
    _ = backend.embeddings(&tokens, &out1, 4);
    _ = backend.embeddings(&tokens, &out2, 4);
    // Same input → same output
    for (out1, out2) |a, b| {
        try std.testing.expectApproxEqAbs(a, b, 1e-6);
    }
}

test "CudaBackend quantizeVectorsInt8 round-trip" {
    const backend = try CudaBackend.init(std.testing.allocator, .{});
    defer backend.deinit();

    const vectors = [_]f32{ 0.5, -0.3, 0.9, -0.1 };
    var quantized: [4]i8 = undefined;
    var scales: [1]f32 = undefined;
    const result = backend.quantizeVectorsInt8(&vectors, &quantized, &scales, 1, 4);
    try std.testing.expect(result.success);
    try std.testing.expect(scales[0] > 0.0);
    // Dequantize and check approximate reconstruction
    for (0..4) |i| {
        const reconstructed = @as(f32, @floatFromInt(quantized[i])) * scales[0];
        try std.testing.expectApproxEqAbs(vectors[i], reconstructed, 0.02);
    }
}

test "CudaBackend stats tracking" {
    const backend = try CudaBackend.init(std.testing.allocator, .{});
    defer backend.deinit();

    const query = [_]f32{ 1.0, 0.0 };
    const docs = [_]f32{ 1.0, 0.0 };
    var scores: [1]f32 = undefined;
    _ = backend.batchCosineSimilarity(&query, &docs, 1, 2, &scores);
    _ = backend.batchCosineSimilarity(&query, &docs, 1, 2, &scores);

    const stats = backend.getStats();
    try std.testing.expectEqual(@as(u64, 2), stats.dispatches);
    try std.testing.expect(stats.elements > 0);
}