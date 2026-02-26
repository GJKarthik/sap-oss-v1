//! ANWID GPU Kernels
//! GPU compute kernels for inference workloads

const std = @import("std");
const builtin = @import("builtin");
const context = @import("context.zig");
const memory_pool = @import("memory_pool.zig");

const log = std.log.scoped(.gpu_kernels);

// ============================================================================
// Kernel Types
// ============================================================================

pub const KernelType = enum {
    /// Identity kernel (for testing pipeline)
    identity,
    /// Vector addition
    vector_add,
    /// Matrix multiplication
    matmul,
    /// Embedding lookup
    embedding,
    /// Cosine similarity search
    cosine_similarity,
    /// Softmax activation
    softmax,
    /// Layer normalization
    layer_norm,
};

pub const KernelParams = struct {
    batch_size: usize = 1,
    input_size: usize = 1024,
    output_size: usize = 1024,
    hidden_size: usize = 768,
    num_heads: usize = 12,
};

// ============================================================================
// Kernel Result
// ============================================================================

pub const KernelResult = struct {
    success: bool,
    execution_time_ns: i128,
    elements_processed: usize,
    output_size_bytes: usize,
    error_message: ?[]const u8,
    
    pub fn ok(exec_time: i128, elements: usize, output_size: usize) KernelResult {
        return .{
            .success = true,
            .execution_time_ns = exec_time,
            .elements_processed = elements,
            .output_size_bytes = output_size,
            .error_message = null,
        };
    }
    
    pub fn err(msg: []const u8) KernelResult {
        return .{
            .success = false,
            .execution_time_ns = 0,
            .elements_processed = 0,
            .output_size_bytes = 0,
            .error_message = msg,
        };
    }
};

// ============================================================================
// GPU Kernel Dispatcher
// ============================================================================

pub const KernelDispatcher = struct {
    allocator: std.mem.Allocator,
    gpu_ctx: ?*context.GpuContext,
    
    // Statistics
    kernel_dispatches: std.atomic.Value(u64),
    total_elements: std.atomic.Value(u64),
    total_exec_time_ns: std.atomic.Value(u64),
    
    pub fn init(allocator: std.mem.Allocator, gpu_ctx: ?*context.GpuContext) !*KernelDispatcher {
        const dispatcher = try allocator.create(KernelDispatcher);
        dispatcher.* = .{
            .allocator = allocator,
            .gpu_ctx = gpu_ctx,
            .kernel_dispatches = std.atomic.Value(u64).init(0),
            .total_elements = std.atomic.Value(u64).init(0),
            .total_exec_time_ns = std.atomic.Value(u64).init(0),
        };
        
        log.info("Kernel Dispatcher initialized", .{});
        return dispatcher;
    }
    
    pub fn deinit(self: *KernelDispatcher) void {
        self.allocator.destroy(self);
        log.info("Kernel Dispatcher destroyed", .{});
    }
    
    /// Dispatch a kernel for execution
    pub fn dispatch(
        self: *KernelDispatcher,
        kernel_type: KernelType,
        params: KernelParams,
        input: []const f32,
        output: []f32,
    ) KernelResult {
        const start = std.time.nanoTimestamp();
        
        const result = switch (kernel_type) {
            .identity => self.executeIdentity(input, output),
            .vector_add => self.executeVectorAdd(input, output, params),
            .matmul => self.executeMatmul(input, output, params),
            .embedding => self.executeEmbedding(input, output, params),
            .cosine_similarity => self.executeCosineSimilarity(input, output, params),
            .softmax => self.executeSoftmax(input, output, params),
            .layer_norm => self.executeLayerNorm(input, output, params),
        };
        
        const elapsed = std.time.nanoTimestamp() - start;
        
        if (result.success) {
            _ = self.kernel_dispatches.fetchAdd(1, .monotonic);
            _ = self.total_elements.fetchAdd(result.elements_processed, .monotonic);
            _ = self.total_exec_time_ns.fetchAdd(@intCast(elapsed), .monotonic);
        }
        
        return .{
            .success = result.success,
            .execution_time_ns = elapsed,
            .elements_processed = result.elements_processed,
            .output_size_bytes = result.output_size_bytes,
            .error_message = result.error_message,
        };
    }
    
    // =========================================================================
    // Kernel Implementations (CPU fallback for now)
    // =========================================================================
    
    fn executeIdentity(self: *KernelDispatcher, input: []const f32, output: []f32) KernelResult {
        _ = self;
        const len = @min(input.len, output.len);
        @memcpy(output[0..len], input[0..len]);
        return KernelResult.ok(0, len, len * @sizeOf(f32));
    }
    
    fn executeVectorAdd(self: *KernelDispatcher, input: []const f32, output: []f32, params: KernelParams) KernelResult {
        _ = self;
        _ = params;
        const len = @min(input.len, output.len);
        for (output[0..len], input[0..len]) |*o, i| {
            o.* = i + 1.0; // Simple add constant for testing
        }
        return KernelResult.ok(0, len, len * @sizeOf(f32));
    }
    
    fn executeMatmul(self: *KernelDispatcher, input: []const f32, output: []f32, params: KernelParams) KernelResult {
        _ = self;
        // Simple matrix-vector multiply simulation
        const m = params.batch_size;
        const k = params.input_size;
        const n = params.output_size;
        
        if (input.len < m * k or output.len < m * n) {
            return KernelResult.err("Input/output size mismatch");
        }
        
        // Simulate matmul by filling output with input average
        var sum: f32 = 0;
        for (input[0..@min(k, input.len)]) |v| sum += v;
        const avg = sum / @as(f32, @floatFromInt(@min(k, input.len)));
        
        for (output[0..@min(m * n, output.len)]) |*o| {
            o.* = avg;
        }
        
        return KernelResult.ok(0, m * n, m * n * @sizeOf(f32));
    }
    
    fn executeEmbedding(self: *KernelDispatcher, input: []const f32, output: []f32, params: KernelParams) KernelResult {
        _ = self;
        // Simulate embedding lookup
        const batch_size = params.batch_size;
        const embedding_dim = params.hidden_size;
        const output_elements = batch_size * embedding_dim;
        
        if (output.len < output_elements) {
            return KernelResult.err("Output buffer too small");
        }
        
        // Generate mock embeddings
        for (0..batch_size) |b| {
            for (0..embedding_dim) |d| {
                const idx = b * embedding_dim + d;
                if (idx < output.len) {
                    const seed = if (b < input.len) input[b] else @as(f32, @floatFromInt(b));
                    output[idx] = @sin(seed + @as(f32, @floatFromInt(d)) * 0.01);
                }
            }
        }
        
        return KernelResult.ok(0, output_elements, output_elements * @sizeOf(f32));
    }
    
    fn executeCosineSimilarity(self: *KernelDispatcher, input: []const f32, output: []f32, params: KernelParams) KernelResult {
        _ = self;
        // Cosine similarity between input vectors
        const vec_size = params.input_size;
        const num_vectors = params.batch_size;
        
        if (input.len < num_vectors * vec_size or output.len < num_vectors) {
            return KernelResult.err("Buffer size mismatch");
        }
        
        // Compute norms and similarities (against first vector)
        var norm0: f32 = 0;
        for (0..vec_size) |i| {
            norm0 += input[i] * input[i];
        }
        norm0 = @sqrt(norm0);
        
        for (0..num_vectors) |v| {
            var dot: f32 = 0;
            var norm: f32 = 0;
            for (0..vec_size) |i| {
                const val = input[v * vec_size + i];
                dot += input[i] * val;
                norm += val * val;
            }
            norm = @sqrt(norm);
            output[v] = if (norm0 > 0 and norm > 0) dot / (norm0 * norm) else 0;
        }
        
        return KernelResult.ok(0, num_vectors, num_vectors * @sizeOf(f32));
    }
    
    fn executeSoftmax(self: *KernelDispatcher, input: []const f32, output: []f32, params: KernelParams) KernelResult {
        _ = self;
        const batch_size = params.batch_size;
        const seq_len = params.input_size;
        
        if (input.len < batch_size * seq_len or output.len < batch_size * seq_len) {
            return KernelResult.err("Buffer size mismatch");
        }
        
        for (0..batch_size) |b| {
            const offset = b * seq_len;
            
            // Find max for numerical stability
            var max_val: f32 = input[offset];
            for (1..seq_len) |i| {
                max_val = @max(max_val, input[offset + i]);
            }
            
            // Compute exp and sum
            var sum: f32 = 0;
            for (0..seq_len) |i| {
                output[offset + i] = @exp(input[offset + i] - max_val);
                sum += output[offset + i];
            }
            
            // Normalize
            for (0..seq_len) |i| {
                output[offset + i] /= sum;
            }
        }
        
        return KernelResult.ok(0, batch_size * seq_len, batch_size * seq_len * @sizeOf(f32));
    }
    
    fn executeLayerNorm(self: *KernelDispatcher, input: []const f32, output: []f32, params: KernelParams) KernelResult {
        _ = self;
        const batch_size = params.batch_size;
        const hidden_size = params.hidden_size;
        const eps: f32 = 1e-5;
        
        if (input.len < batch_size * hidden_size or output.len < batch_size * hidden_size) {
            return KernelResult.err("Buffer size mismatch");
        }
        
        for (0..batch_size) |b| {
            const offset = b * hidden_size;
            
            // Compute mean
            var mean: f32 = 0;
            for (0..hidden_size) |i| {
                mean += input[offset + i];
            }
            mean /= @as(f32, @floatFromInt(hidden_size));
            
            // Compute variance
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
        
        return KernelResult.ok(0, batch_size * hidden_size, batch_size * hidden_size * @sizeOf(f32));
    }
    
    // =========================================================================
    // Statistics
    // =========================================================================
    
    pub fn getStats(self: *const KernelDispatcher) KernelStats {
        const dispatches = self.kernel_dispatches.load(.acquire);
        const total_time = self.total_exec_time_ns.load(.acquire);
        
        return .{
            .kernel_dispatches = dispatches,
            .total_elements = self.total_elements.load(.acquire),
            .total_exec_time_ns = total_time,
            .avg_exec_time_ns = if (dispatches > 0) total_time / dispatches else 0,
        };
    }
};

pub const KernelStats = struct {
    kernel_dispatches: u64,
    total_elements: u64,
    total_exec_time_ns: u64,
    avg_exec_time_ns: u64,
};

// ============================================================================
// Tests
// ============================================================================

test "Identity kernel" {
    const dispatcher = try KernelDispatcher.init(std.testing.allocator, null);
    defer dispatcher.deinit();
    
    var input = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    var output: [4]f32 = undefined;
    
    const result = dispatcher.dispatch(.identity, .{}, &input, &output);
    
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 4), result.elements_processed);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), output[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), output[3], 0.001);
}

test "Softmax kernel" {
    const dispatcher = try KernelDispatcher.init(std.testing.allocator, null);
    defer dispatcher.deinit();
    
    var input = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    var output: [4]f32 = undefined;
    
    const result = dispatcher.dispatch(.softmax, .{ .batch_size = 1, .input_size = 4 }, &input, &output);
    
    try std.testing.expect(result.success);
    
    // Softmax should sum to 1
    var sum: f32 = 0;
    for (output) |v| sum += v;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sum, 0.001);
}

test "LayerNorm kernel" {
    const dispatcher = try KernelDispatcher.init(std.testing.allocator, null);
    defer dispatcher.deinit();
    
    var input = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    var output: [4]f32 = undefined;
    
    const result = dispatcher.dispatch(.layer_norm, .{ .batch_size = 1, .hidden_size = 4 }, &input, &output);
    
    try std.testing.expect(result.success);
    
    // Layer norm should have mean ~0
    var mean: f32 = 0;
    for (output) |v| mean += v;
    mean /= 4.0;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), mean, 0.001);
}