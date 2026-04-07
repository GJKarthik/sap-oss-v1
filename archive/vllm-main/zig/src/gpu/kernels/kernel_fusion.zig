//! ANWID Kernel Fusion Engine
//! Zero-CPU-Touch Pipeline: Fuses JSON Parsing → Tokenization → Inference
//! 
//! Architecture:
//!   Stage 1: JSON Parser kernel extracts prompt text bounds
//!   Stage 2: Tokenizer kernel converts text to tokens (no CPU roundtrip)
//!   Stage 3: Inference kernel generates output (no CPU roundtrip)
//!
//! All stages execute in GPU memory without returning to CPU

const std = @import("std");
const builtin = @import("builtin");

const json_parser = @import("json_parser.zig");
const tokenizer = @import("tokenizer.zig");

const log = std.log.scoped(.kernel_fusion);

// ============================================================================
// Kernel Fusion Configuration
// ============================================================================

pub const FusionConfig = struct {
    /// Enable JSON parser stage
    enable_json_parser: bool = true,
    /// Enable tokenizer stage
    enable_tokenizer: bool = true,
    /// Enable inference stage  
    enable_inference: bool = true,
    /// Maximum batch size
    max_batch_size: usize = 32,
    /// Maximum sequence length
    max_seq_len: usize = 2048,
    /// Embedding dimension
    embedding_dim: usize = 4096,
    /// Number of layers
    num_layers: usize = 32,
    /// Use async execution
    async_execution: bool = true,
};

// ============================================================================
// Fused Pipeline Result
// ============================================================================

/// Combined result from all fused kernels
pub const FusedResult = extern struct {
    // JSON Parser stage results
    json_status: u32,
    text_start: u32,
    text_end: u32,
    json_time_ns: u64,
    
    // Tokenizer stage results
    token_status: u32,
    num_tokens: u32,
    token_time_ns: u64,
    
    // Inference stage results
    inference_status: u32,
    output_tokens: u32,
    inference_time_ns: u64,
    
    // Total timing
    total_time_ns: u64,
    
    // Error information
    error_stage: u32, // 0 = none, 1 = parser, 2 = tokenizer, 3 = inference
    error_code: u32,
};

pub const FusionStage = enum(u32) {
    none = 0,
    json_parser = 1,
    tokenizer = 2,
    inference = 3,
};

// ============================================================================
// Kernel Fusion Pipeline
// ============================================================================

pub const KernelFusionPipeline = struct {
    allocator: std.mem.Allocator,
    config: FusionConfig,
    
    // Component kernels
    json_parser_kernel: *json_parser.GpuJsonParser,
    tokenizer_kernel: *tokenizer.GpuTokenizer,
    
    // GPU buffers (simulated)
    raw_input_buffer: []u8,
    token_buffer: []u32,
    output_buffer: []f32,
    
    // Statistics
    fusions_executed: std.atomic.Value(u64),
    total_fusion_time_ns: std.atomic.Value(u64),
    stage_failures: [4]std.atomic.Value(u64),
    
    pub fn init(allocator: std.mem.Allocator, config: FusionConfig) !*KernelFusionPipeline {
        const pipeline = try allocator.create(KernelFusionPipeline);
        
        // Initialize component kernels
        const parser = try json_parser.GpuJsonParser.init(allocator, .{});
        const tok = try tokenizer.GpuTokenizer.init(allocator, .{
            .max_seq_len = config.max_seq_len,
        });
        
        pipeline.* = .{
            .allocator = allocator,
            .config = config,
            .json_parser_kernel = parser,
            .tokenizer_kernel = tok,
            .raw_input_buffer = try allocator.alloc(u8, 1024 * 1024), // 1MB
            .token_buffer = try allocator.alloc(u32, config.max_seq_len),
            .output_buffer = try allocator.alloc(f32, config.max_seq_len * config.embedding_dim),
            .fusions_executed = std.atomic.Value(u64).init(0),
            .total_fusion_time_ns = std.atomic.Value(u64).init(0),
            .stage_failures = .{
                std.atomic.Value(u64).init(0),
                std.atomic.Value(u64).init(0),
                std.atomic.Value(u64).init(0),
                std.atomic.Value(u64).init(0),
            },
        };
        
        log.info("Kernel Fusion Pipeline initialized:", .{});
        log.info("  Max batch: {}", .{config.max_batch_size});
        log.info("  Max seq len: {}", .{config.max_seq_len});
        log.info("  Embedding dim: {}", .{config.embedding_dim});
        
        return pipeline;
    }
    
    pub fn deinit(self: *KernelFusionPipeline) void {
        self.json_parser_kernel.deinit();
        self.tokenizer_kernel.deinit();
        self.allocator.free(self.raw_input_buffer);
        self.allocator.free(self.token_buffer);
        self.allocator.free(self.output_buffer);
        self.allocator.destroy(self);
    }
    
    /// Execute the full fused pipeline on raw JSON bytes
    /// This is the main entry point for zero-CPU-touch processing
    pub fn executeFused(self: *KernelFusionPipeline, raw_json: []const u8) !FusedResult {
        const start_time = std.time.nanoTimestamp();
        defer {
            const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start_time);
            _ = self.total_fusion_time_ns.fetchAdd(elapsed, .monotonic);
            _ = self.fusions_executed.fetchAdd(1, .monotonic);
        }
        
        var result = FusedResult{
            .json_status = 0,
            .text_start = 0,
            .text_end = 0,
            .json_time_ns = 0,
            .token_status = 0,
            .num_tokens = 0,
            .token_time_ns = 0,
            .inference_status = 0,
            .output_tokens = 0,
            .inference_time_ns = 0,
            .total_time_ns = 0,
            .error_stage = 0,
            .error_code = 0,
        };
        
        // Stage 1: JSON Parsing (GPU)
        if (self.config.enable_json_parser) {
            const json_start = std.time.nanoTimestamp();
            const parse_result = self.json_parser_kernel.parse(raw_json);
            result.json_time_ns = @intCast(std.time.nanoTimestamp() - json_start);
            
            result.json_status = parse_result.status;
            result.text_start = parse_result.text_start;
            result.text_end = parse_result.text_end;
            
            if (parse_result.status != @intFromEnum(json_parser.ParseStatus.success)) {
                result.error_stage = @intFromEnum(FusionStage.json_parser);
                result.error_code = parse_result.error_code;
                _ = self.stage_failures[1].fetchAdd(1, .monotonic);
                result.total_time_ns = @intCast(std.time.nanoTimestamp() - start_time);
                return result;
            }
        }
        
        // Stage 2: Tokenization (GPU) - uses parse result directly
        if (self.config.enable_tokenizer) {
            const token_start = std.time.nanoTimestamp();
            
            const token_result = if (self.config.enable_json_parser)
                try self.tokenizer_kernel.tokenizeFromParseResult(
                    raw_json,
                    result.text_start,
                    result.text_end,
                    self.token_buffer,
                )
            else
                try self.tokenizer_kernel.tokenize(raw_json, self.token_buffer);
            
            result.token_time_ns = @intCast(std.time.nanoTimestamp() - token_start);
            result.token_status = token_result.status;
            result.num_tokens = token_result.num_tokens;
            
            if (token_result.status == @intFromEnum(tokenizer.TokenStatus.error_invalid_utf8) or
                token_result.status == @intFromEnum(tokenizer.TokenStatus.error_buffer_overflow))
            {
                result.error_stage = @intFromEnum(FusionStage.tokenizer);
                result.error_code = token_result.error_code;
                _ = self.stage_failures[2].fetchAdd(1, .monotonic);
                result.total_time_ns = @intCast(std.time.nanoTimestamp() - start_time);
                return result;
            }
        }
        
        // Stage 3: Inference (GPU) - uses token buffer directly
        if (self.config.enable_inference) {
            const inference_start = std.time.nanoTimestamp();
            
            // Simulate inference computation
            const num_tokens = result.num_tokens;
            try self.simulateInference(num_tokens);
            
            result.inference_time_ns = @intCast(std.time.nanoTimestamp() - inference_start);
            result.inference_status = 0; // Success
            result.output_tokens = num_tokens; // Echo for now
        }
        
        result.total_time_ns = @intCast(std.time.nanoTimestamp() - start_time);
        return result;
    }
    
    /// Simulate inference computation (placeholder for real GPU kernel)
    fn simulateInference(self: *KernelFusionPipeline, num_tokens: u32) !void {
        // In real implementation, this would launch CUDA/Metal kernel
        // For now, we just compute some embeddings
        const embedding_dim = self.config.embedding_dim;
        
        for (0..num_tokens) |t| {
            const token_id = self.token_buffer[t];
            for (0..embedding_dim) |d| {
                const idx = t * embedding_dim + d;
                if (idx < self.output_buffer.len) {
                    // Simple embedding computation
                    self.output_buffer[idx] = @sin(@as(f32, @floatFromInt(token_id)) * 0.001 + @as(f32, @floatFromInt(d)) * 0.0001);
                }
            }
        }
    }
    
    /// Get the token buffer (for reading results)
    pub fn getTokenBuffer(self: *const KernelFusionPipeline) []const u32 {
        return self.token_buffer;
    }
    
    /// Get the output buffer (for reading embeddings)
    pub fn getOutputBuffer(self: *const KernelFusionPipeline) []const f32 {
        return self.output_buffer;
    }
    
    /// Get pipeline statistics
    pub fn getStats(self: *const KernelFusionPipeline) FusionStats {
        const count = self.fusions_executed.load(.acquire);
        const time = self.total_fusion_time_ns.load(.acquire);
        
        return .{
            .fusions_executed = count,
            .total_fusion_time_ns = time,
            .avg_fusion_time_ns = if (count > 0) time / count else 0,
            .parser_failures = self.stage_failures[1].load(.acquire),
            .tokenizer_failures = self.stage_failures[2].load(.acquire),
            .inference_failures = self.stage_failures[3].load(.acquire),
            .parser_stats = self.json_parser_kernel.getStats(),
            .tokenizer_stats = self.tokenizer_kernel.getStats(),
        };
    }
};

pub const FusionStats = struct {
    fusions_executed: u64,
    total_fusion_time_ns: u64,
    avg_fusion_time_ns: u64,
    parser_failures: u64,
    tokenizer_failures: u64,
    inference_failures: u64,
    parser_stats: json_parser.ParserStats,
    tokenizer_stats: tokenizer.TokenizerStats,
};

// ============================================================================
// Async Fusion Slot (for continuous batching)
// ============================================================================

pub const AsyncFusionSlot = struct {
    id: usize,
    state: std.atomic.Value(SlotState),
    
    // Input (raw JSON bytes)
    raw_input: []u8,
    input_len: std.atomic.Value(usize),
    
    // Output
    result: FusedResult,
    output_ready: std.atomic.Value(bool),
    
    // Timing
    submit_time_ns: std.atomic.Value(i64),
    complete_time_ns: std.atomic.Value(i64),
    
    allocator: std.mem.Allocator,
    
    pub const SlotState = enum(u8) {
        idle,
        filling,
        submitted,
        parsing,
        tokenizing,
        inferencing,
        complete,
    };
    
    pub fn init(allocator: std.mem.Allocator, id: usize, max_input_size: usize) !*AsyncFusionSlot {
        const slot = try allocator.create(AsyncFusionSlot);
        
        slot.* = .{
            .id = id,
            .state = std.atomic.Value(SlotState).init(.idle),
            .raw_input = try allocator.alloc(u8, max_input_size),
            .input_len = std.atomic.Value(usize).init(0),
            .result = std.mem.zeroes(FusedResult),
            .output_ready = std.atomic.Value(bool).init(false),
            .submit_time_ns = std.atomic.Value(i64).init(0),
            .complete_time_ns = std.atomic.Value(i64).init(0),
            .allocator = allocator,
        };
        
        return slot;
    }
    
    pub fn deinit(self: *AsyncFusionSlot) void {
        self.allocator.free(self.raw_input);
        self.allocator.destroy(self);
    }
    
    pub fn reset(self: *AsyncFusionSlot) void {
        self.state.store(.idle, .release);
        self.input_len.store(0, .release);
        self.output_ready.store(false, .release);
        self.submit_time_ns.store(0, .release);
        self.complete_time_ns.store(0, .release);
        self.result = std.mem.zeroes(FusedResult);
    }
    
    pub fn fill(self: *AsyncFusionSlot, data: []const u8) !void {
        if (data.len > self.raw_input.len) {
            return error.InputTooLarge;
        }
        
        self.state.store(.filling, .release);
        @memcpy(self.raw_input[0..data.len], data);
        self.input_len.store(data.len, .release);
        self.submit_time_ns.store(@intCast(std.time.nanoTimestamp()), .release);
        self.state.store(.submitted, .release);
    }
    
    pub fn getLatency(self: *const AsyncFusionSlot) i64 {
        const submit = self.submit_time_ns.load(.acquire);
        const complete = self.complete_time_ns.load(.acquire);
        if (submit == 0 or complete == 0) return 0;
        return complete - submit;
    }
};

// ============================================================================
// GPU Kernel Launch Configuration
// ============================================================================

pub const KernelLaunchConfig = struct {
    grid_dim_x: u32,
    grid_dim_y: u32,
    grid_dim_z: u32,
    block_dim_x: u32,
    block_dim_y: u32,
    block_dim_z: u32,
    shared_mem_bytes: u32,
    stream: u64, // CUDA stream or Metal command queue
    
    pub fn forBatchSize(batch_size: usize, max_seq_len: usize) KernelLaunchConfig {
        return .{
            .grid_dim_x = @intCast(batch_size),
            .grid_dim_y = 1,
            .grid_dim_z = 1,
            .block_dim_x = @intCast(@min(256, max_seq_len)),
            .block_dim_y = 1,
            .block_dim_z = 1,
            .shared_mem_bytes = 0,
            .stream = 0,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "KernelFusionPipeline basic execution" {
    const pipeline = try KernelFusionPipeline.init(std.testing.allocator, .{});
    defer pipeline.deinit();
    
    const json = "{\"prompt\": \"Generate a story about a cat.\"}";
    const result = try pipeline.executeFused(json);
    
    try std.testing.expectEqual(@as(u32, 0), result.error_stage);
    try std.testing.expect(result.num_tokens > 0);
}

test "KernelFusionPipeline parser failure" {
    const pipeline = try KernelFusionPipeline.init(std.testing.allocator, .{});
    defer pipeline.deinit();
    
    // JSON without target field
    const json = "{\"model\": \"test\", \"other\": \"value\"}";
    const result = try pipeline.executeFused(json);
    
    try std.testing.expectEqual(@as(u32, @intFromEnum(FusionStage.json_parser)), result.error_stage);
}

test "KernelFusionPipeline statistics" {
    const pipeline = try KernelFusionPipeline.init(std.testing.allocator, .{});
    defer pipeline.deinit();
    
    _ = try pipeline.executeFused("{\"prompt\": \"test1\"}");
    _ = try pipeline.executeFused("{\"prompt\": \"test2\"}");
    
    const stats = pipeline.getStats();
    try std.testing.expectEqual(@as(u64, 2), stats.fusions_executed);
}

test "AsyncFusionSlot lifecycle" {
    const slot = try AsyncFusionSlot.init(std.testing.allocator, 0, 4096);
    defer slot.deinit();
    
    try std.testing.expectEqual(AsyncFusionSlot.SlotState.idle, slot.state.load(.acquire));
    
    try slot.fill("{\"prompt\": \"test\"}");
    try std.testing.expectEqual(AsyncFusionSlot.SlotState.submitted, slot.state.load(.acquire));
    
    slot.reset();
    try std.testing.expectEqual(AsyncFusionSlot.SlotState.idle, slot.state.load(.acquire));
}

test "KernelLaunchConfig calculation" {
    const config = KernelLaunchConfig.forBatchSize(32, 512);
    
    try std.testing.expectEqual(@as(u32, 32), config.grid_dim_x);
    try std.testing.expectEqual(@as(u32, 256), config.block_dim_x);
}