//! GPU Kernel Fusion Engine for AIPrompt Streaming
//! Chains JSON Parser → Tokenizer → Embeddings in a single pipeline.
//!
//! When a GpuPipelineDispatch is attached, all three stages dispatch
//! on Metal GPU: json_find_key for parsing, gpu_tokenize_bytes for
//! tokenization, and embedding_lookup for embeddings. Each stage
//! independently falls back to CPU if GPU dispatch fails.

const std = @import("std");
const builtin = @import("builtin");

const json_parser = @import("json_parser.zig");
const tokenizer = @import("tokenizer.zig");

const log = std.log.scoped(.kernel_fusion);

/// Unified GPU dispatch interface for the entire fused pipeline.
/// Caller provides a context pointer and optional dispatch functions for each
/// stage. Any stage without a callback falls back to the CPU implementation.
pub const GpuPipelineDispatch = struct {
    ctx: *anyopaque,
    parse_fn: ?*const fn (
        ctx: *anyopaque,
        raw_json: []const u8,
        out_result: *json_parser.GpuParseResult,
    ) bool = null,
    tokenize_fn: ?*const fn (
        ctx: *anyopaque,
        text: []const u8,
        output_tokens: []u32,
        max_tokens: usize,
        out_token_count: *usize,
    ) bool = null,
    embed_fn: ?*const fn (
        ctx: *anyopaque,
        tokens: []const u32,
        output: []f32,
        embed_dim: usize,
    ) bool = null,
};

// ============================================================================
// Kernel Fusion Configuration
// ============================================================================

pub const FusionConfig = struct {
    enabled: bool = true,
    max_input_size: usize = 1024 * 1024,
    max_seq_len: usize = 2048,
    embedding_dim: usize = 4096,
    pipeline_depth: usize = 3,
    shared_memory_size: usize = 48 * 1024,
};

// ============================================================================
// Fused Result
// ============================================================================

/// Combined result from all three kernel stages.
/// Fields used by zero_copy_pipeline: error_stage, num_tokens, total_time_ns.
pub const FusedResult = extern struct {
    // Parse stage
    parse_status: u32,
    text_start: u32,
    text_end: u32,
    parse_error: u32,

    // Tokenizer stage
    num_tokens: u32,
    tokenize_status: u32,
    seq_len: u32,
    tokenize_error: u32,

    // Embedding stage
    embedding_ready: u32,
    embedding_dim: u32,
    embed_status: u32,
    embed_error: u32,

    // Timing (ns)
    parse_time_ns: u64,
    tokenize_time_ns: u64,
    embed_time_ns: u64,
    total_time_ns: u64,

    // Error tracking: 0 = success, 1 = parse, 2 = tokenize, 3 = embed
    error_stage: u32,
    _padding: u32,
};

pub const FusionStatus = enum(u32) {
    success = 0,
    parse_failed = 1,
    tokenize_failed = 2,
    embed_failed = 3,
    input_too_large = 4,
    gpu_error = 5,
};

// ============================================================================
// Kernel Fusion Pipeline
// ============================================================================

pub const KernelFusionPipeline = struct {
    allocator: std.mem.Allocator,
    config: FusionConfig,

    json_parser_inst: *json_parser.GpuJsonParser,
    tokenizer_inst: *tokenizer.GpuTokenizer,

    gpu_dispatch: ?GpuPipelineDispatch,

    raw_input_buffer: []u8,
    token_buffer: []u32,
    embedding_buffer: []f32,

    // Pipeline state
    active_stage: std.atomic.Value(u32),

    // Statistics
    fusion_count: std.atomic.Value(u64),
    total_fusion_time_ns: std.atomic.Value(u64),
    successful_fusions: std.atomic.Value(u64),
    failed_fusions: std.atomic.Value(u64),
    gpu_dispatches: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, config: FusionConfig) !*KernelFusionPipeline {
        const pipeline = try allocator.create(KernelFusionPipeline);

        const parser = try json_parser.GpuJsonParser.init(allocator, .{
            .max_scan_bytes = config.max_input_size,
        });

        const tok = try tokenizer.GpuTokenizer.init(allocator, .{
            .max_seq_len = config.max_seq_len,
        });

        pipeline.* = .{
            .allocator = allocator,
            .config = config,
            .json_parser_inst = parser,
            .tokenizer_inst = tok,
            .gpu_dispatch = null,
            .raw_input_buffer = try allocator.alloc(u8, config.max_input_size),
            .token_buffer = try allocator.alloc(u32, config.max_seq_len),
            .embedding_buffer = try allocator.alloc(f32, config.max_seq_len * config.embedding_dim),
            .active_stage = std.atomic.Value(u32).init(0),
            .fusion_count = std.atomic.Value(u64).init(0),
            .total_fusion_time_ns = std.atomic.Value(u64).init(0),
            .successful_fusions = std.atomic.Value(u64).init(0),
            .failed_fusions = std.atomic.Value(u64).init(0),
            .gpu_dispatches = std.atomic.Value(u64).init(0),
        };

        log.info("Kernel Fusion Pipeline initialized:", .{});
        log.info("  Max input: {} KB", .{config.max_input_size / 1024});
        log.info("  Max seq len: {}", .{config.max_seq_len});
        log.info("  Embedding dim: {}", .{config.embedding_dim});

        return pipeline;
    }

    pub fn deinit(self: *KernelFusionPipeline) void {
        self.json_parser_inst.deinit();
        self.tokenizer_inst.deinit();
        self.allocator.free(self.raw_input_buffer);
        self.allocator.free(self.token_buffer);
        self.allocator.free(self.embedding_buffer);
        self.allocator.destroy(self);
    }

    /// Execute the complete fused pipeline: JSON → Tokens → Embeddings
    pub fn executeFused(
        self: *KernelFusionPipeline,
        raw_json: []const u8,
    ) !FusedResult {
        const start_time = std.time.nanoTimestamp();
        defer {
            const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start_time);
            _ = self.total_fusion_time_ns.fetchAdd(elapsed, .monotonic);
            _ = self.fusion_count.fetchAdd(1, .monotonic);
        }

        if (raw_json.len > self.config.max_input_size) {
            _ = self.failed_fusions.fetchAdd(1, .monotonic);
            var r = std.mem.zeroes(FusedResult);
            r.error_stage = @intFromEnum(FusionStatus.input_too_large);
            return r;
        }

        @memcpy(self.raw_input_buffer[0..raw_json.len], raw_json);

        // Stage 1: JSON Parsing (GPU when available, CPU fallback)
        self.active_stage.store(1, .release);
        const parse_start = std.time.nanoTimestamp();

        var parse_result: json_parser.GpuParseResult = undefined;
        var parse_used_gpu = false;

        if (self.gpu_dispatch) |dispatch| {
            if (dispatch.parse_fn) |parse_fn| {
                if (parse_fn(dispatch.ctx, self.raw_input_buffer[0..raw_json.len], &parse_result)) {
                    parse_used_gpu = true;
                    _ = self.gpu_dispatches.fetchAdd(1, .monotonic);
                }
            }
        }
        if (!parse_used_gpu) {
            parse_result = try self.json_parser_inst.parseInputField(
                self.raw_input_buffer[0..raw_json.len],
            );
        }

        const parse_time: u64 = @intCast(std.time.nanoTimestamp() - parse_start);

        if (parse_result.status != @intFromEnum(json_parser.ParseStatus.found)) {
            _ = self.failed_fusions.fetchAdd(1, .monotonic);
            var r = std.mem.zeroes(FusedResult);
            r.parse_status = parse_result.status;
            r.parse_error = parse_result.error_code;
            r.parse_time_ns = parse_time;
            r.total_time_ns = parse_time;
            r.error_stage = @intFromEnum(FusionStatus.parse_failed);
            return r;
        }

        // Stage 2: Tokenization (GPU when available, CPU fallback)
        self.active_stage.store(2, .release);
        const tokenize_start = std.time.nanoTimestamp();

        var token_result: tokenizer.GpuTokenResult = undefined;
        var tokenize_used_gpu = false;

        if (self.gpu_dispatch) |dispatch| {
            if (dispatch.tokenize_fn) |tokenize_fn| {
                const text_start = parse_result.text_start;
                const text_end = parse_result.text_end;
                if (text_end > text_start and text_end <= raw_json.len) {
                    const text_slice = self.raw_input_buffer[text_start..text_end];
                    var gpu_token_count: usize = 0;
                    if (tokenize_fn(dispatch.ctx, text_slice, self.token_buffer, self.config.max_seq_len, &gpu_token_count)) {
                        tokenize_used_gpu = true;
                        _ = self.gpu_dispatches.fetchAdd(1, .monotonic);
                        token_result = .{
                            .num_tokens = @intCast(gpu_token_count),
                            .status = @intFromEnum(tokenizer.TokenStatus.success),
                            .seq_len = @intCast(gpu_token_count),
                            .error_code = 0,
                        };
                    }
                }
            }
        }
        if (!tokenize_used_gpu) {
            token_result = try self.tokenizer_inst.tokenizeFromParseResult(
                self.raw_input_buffer[0..raw_json.len],
                parse_result.text_start,
                parse_result.text_end,
                self.token_buffer,
            );
        }

        const tokenize_time: u64 = @intCast(std.time.nanoTimestamp() - tokenize_start);

        if (token_result.status != @intFromEnum(tokenizer.TokenStatus.success) and
            token_result.status != @intFromEnum(tokenizer.TokenStatus.truncated))
        {
            _ = self.failed_fusions.fetchAdd(1, .monotonic);
            var r = std.mem.zeroes(FusedResult);
            r.parse_status = parse_result.status;
            r.text_start = parse_result.text_start;
            r.text_end = parse_result.text_end;
            r.num_tokens = token_result.num_tokens;
            r.tokenize_status = token_result.status;
            r.tokenize_error = token_result.error_code;
            r.parse_time_ns = parse_time;
            r.tokenize_time_ns = tokenize_time;
            r.total_time_ns = parse_time + tokenize_time;
            r.error_stage = @intFromEnum(FusionStatus.tokenize_failed);
            return r;
        }

        // Stage 3: Embedding generation (GPU when available, CPU fallback)
        self.active_stage.store(3, .release);
        const embed_start = std.time.nanoTimestamp();

        const num_tokens = token_result.num_tokens;
        const embed_dim = self.config.embedding_dim;

        self.generateEmbeddings(
            self.token_buffer[0..num_tokens],
            self.embedding_buffer,
            embed_dim,
        );

        const embed_time: u64 = @intCast(std.time.nanoTimestamp() - embed_start);

        self.active_stage.store(0, .release);
        _ = self.successful_fusions.fetchAdd(1, .monotonic);

        return FusedResult{
            .parse_status = parse_result.status,
            .text_start = parse_result.text_start,
            .text_end = parse_result.text_end,
            .parse_error = 0,
            .num_tokens = token_result.num_tokens,
            .tokenize_status = token_result.status,
            .seq_len = token_result.seq_len,
            .tokenize_error = 0,
            .embedding_ready = 1,
            .embedding_dim = @intCast(embed_dim),
            .embed_status = 0,
            .embed_error = 0,
            .parse_time_ns = parse_time,
            .tokenize_time_ns = tokenize_time,
            .embed_time_ns = embed_time,
            .total_time_ns = parse_time + tokenize_time + embed_time,
            .error_stage = 0,
            ._padding = 0,
        };
    }

    /// Attach GPU dispatch callbacks for all pipeline stages.
    pub fn attachGpuDispatch(self: *KernelFusionPipeline, dispatch: GpuPipelineDispatch) void {
        self.gpu_dispatch = dispatch;
        log.info("GPU dispatch attached to fusion pipeline (parse={} tokenize={} embed={})", .{
            dispatch.parse_fn != null,
            dispatch.tokenize_fn != null,
            dispatch.embed_fn != null,
        });
    }

    fn generateEmbeddings(
        self: *KernelFusionPipeline,
        tokens: []const u32,
        output: []f32,
        embed_dim: usize,
    ) void {
        if (self.gpu_dispatch) |dispatch| {
            if (dispatch.embed_fn) |embed_fn| {
                if (embed_fn(dispatch.ctx, tokens, output, embed_dim)) {
                    _ = self.gpu_dispatches.fetchAdd(1, .monotonic);
                    return;
                }
            }
        }

        // CPU fallback: deterministic embedding via wyhash
        for (tokens, 0..) |token, i| {
            const base_offset = i * embed_dim;
            var hash_seed: u64 = std.hash.Wyhash.hash(0, std.mem.asBytes(&token));
            for (0..embed_dim) |d| {
                if (base_offset + d < output.len) {
                    hash_seed +%= 0x9E3779B97F4A7C15 +% @as(u64, @intCast(d));
                    hash_seed ^= (hash_seed << 13);
                    hash_seed ^= (hash_seed >> 7);
                    hash_seed ^= (hash_seed << 17);
                    const norm = @as(f32, @floatFromInt(hash_seed & 0xffff_ffff)) / 4_294_967_295.0;
                    output[base_offset + d] = (norm * 2.0) - 1.0;
                }
            }
        }
    }

    pub fn getStats(self: *const KernelFusionPipeline) FusionStats {
        const count = self.fusion_count.load(.acquire);
        const time = self.total_fusion_time_ns.load(.acquire);
        return .{
            .fusion_count = count,
            .successful_fusions = self.successful_fusions.load(.acquire),
            .failed_fusions = self.failed_fusions.load(.acquire),
            .total_time_ns = time,
            .avg_time_ns = if (count > 0) time / count else 0,
            .gpu_dispatches = self.gpu_dispatches.load(.acquire),
            .parser_stats = self.json_parser_inst.getStats(),
            .tokenizer_stats = self.tokenizer_inst.getStats(),
        };
    }
};

pub const FusionStats = struct {
    fusion_count: u64,
    successful_fusions: u64,
    failed_fusions: u64,
    total_time_ns: u64,
    avg_time_ns: u64,
    gpu_dispatches: u64,
    parser_stats: json_parser.ParserStats,
    tokenizer_stats: tokenizer.TokenizerStats,
};

// ============================================================================
// Tests
// ============================================================================

test "KernelFusionPipeline basic execution" {
    const pipeline = try KernelFusionPipeline.init(std.testing.allocator, .{});
    defer pipeline.deinit();

    const json_input =
        \\{"model": "streaming", "input": "Hello, world!", "encoding": "float"}
    ;

    const result = try pipeline.executeFused(json_input);

    try std.testing.expectEqual(@as(u32, 0), result.error_stage);
    try std.testing.expect(result.num_tokens > 0);
}

test "KernelFusionPipeline prompt field" {
    const pipeline = try KernelFusionPipeline.init(std.testing.allocator, .{});
    defer pipeline.deinit();

    const json_input =
        \\{"prompt": "Generate inference output."}
    ;

    const result = try pipeline.executeFused(json_input);

    try std.testing.expectEqual(@as(u32, 0), result.error_stage);
    try std.testing.expect(result.num_tokens > 0);
}

test "KernelFusionPipeline parse failure" {
    const pipeline = try KernelFusionPipeline.init(std.testing.allocator, .{});
    defer pipeline.deinit();

    const json_input =
        \\{"model": "text-embedding", "text": "No input field here"}
    ;

    const result = try pipeline.executeFused(json_input);

    try std.testing.expectEqual(@intFromEnum(FusionStatus.parse_failed), result.error_stage);
}

test "KernelFusionPipeline statistics" {
    const pipeline = try KernelFusionPipeline.init(std.testing.allocator, .{});
    defer pipeline.deinit();

    _ = try pipeline.executeFused("{\"input\": \"test1\"}");
    _ = try pipeline.executeFused("{\"prompt\": \"test2\"}");
    _ = try pipeline.executeFused("{\"other\": \"no input\"}");

    const stats = pipeline.getStats();
    try std.testing.expectEqual(@as(u64, 3), stats.fusion_count);
    try std.testing.expectEqual(@as(u64, 2), stats.successful_fusions);
    try std.testing.expectEqual(@as(u64, 1), stats.failed_fusions);
}
