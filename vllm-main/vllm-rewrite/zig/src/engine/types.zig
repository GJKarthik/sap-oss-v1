//! Core Data Types for vLLM Engine
//!
//! This module defines the fundamental data structures used throughout
//! the vLLM inference engine, including requests, sequences, and sampling parameters.

const std = @import("std");

// ============================================
// Request Types
// ============================================

/// Unique identifier for requests
pub const RequestId = [36]u8; // UUID format

/// Generate a new random request ID
pub fn generateRequestId() RequestId {
    var id: RequestId = undefined;
    std.crypto.random.bytes(&id);

    // Format as UUID (8-4-4-4-12)
    const hex = "0123456789abcdef";
    for (&id, 0..) |*byte, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            byte.* = '-';
        } else {
            byte.* = hex[@as(usize, @intCast(byte.* & 0x0F))];
        }
    }

    return id;
}

/// State of a request in the inference pipeline
pub const RequestState = enum(u8) {
    /// Request is waiting in queue
    pending,
    /// Request is currently being processed (prefill or decode)
    running,
    /// Request was preempted for a higher priority request
    preempted,
    /// Request has completed successfully
    completed,
    /// Request failed due to an error
    failed,
    /// Request was cancelled by the client
    cancelled,

    pub fn isTerminal(self: RequestState) bool {
        return switch (self) {
            .completed, .failed, .cancelled => true,
            else => false,
        };
    }

    pub fn canPreempt(self: RequestState) bool {
        return self == .running;
    }
};

/// Reason for request completion
pub const FinishReason = enum {
    /// Reached end-of-sequence token
    end_of_sequence,
    /// Reached maximum token limit
    length,
    /// Hit a stop string
    stop,
    /// Request was cancelled
    cancelled,
    /// Error occurred
    error_occurred,
};

/// A single inference request
pub const Request = struct {
    // ---- Hot fields (first cache line) ----
    /// Current state of the request
    state: RequestState align(64) = .pending,
    /// Priority for scheduling (higher = more urgent)
    priority: i32 = 0,
    /// Number of tokens generated so far
    tokens_generated: u32 = 0,
    /// Most recently generated token ID
    last_token_id: u32 = 0,
    /// Number of prompt tokens
    prompt_len: u32 = 0,
    /// Current sequence length (prompt + generated)
    seq_len: u32 = 0,

    // ---- Cold fields ----
    /// Unique request identifier
    request_id: RequestId = undefined,
    /// Arrival timestamp (nanoseconds since epoch)
    arrival_time: i64 = 0,
    /// Start time of processing
    start_time: i64 = 0,
    /// Completion time
    end_time: i64 = 0,

    /// Input token IDs (prompt)
    prompt_token_ids: []const u32 = &[_]u32{},
    /// Output token IDs (generated)
    output_token_ids: std.ArrayList(u32) = undefined,

    /// Sampling parameters for this request
    sampling_params: SamplingParams = .{},

    /// Block table for KV-cache (logical -> physical mapping)
    block_table: []u32 = &[_]u32{},
    /// Number of blocks allocated
    num_blocks: u32 = 0,

    /// Optional LoRA adapter ID
    lora_id: ?u32 = null,

    /// Finish reason (set when completed)
    finish_reason: ?FinishReason = null,

    /// Allocator for dynamic memory
    allocator: std.mem.Allocator = undefined,

    const Self = @This();

    /// Initialize a new request
    pub fn init(alloc: std.mem.Allocator) Self {
        return Self{
            .request_id = generateRequestId(),
            .arrival_time = std.time.nanoTimestamp(),
            .output_token_ids = std.ArrayList(u32).init(alloc),
            .allocator = alloc,
        };
    }

    /// Deinitialize and free resources
    pub fn deinit(self: *Self) void {
        self.output_token_ids.deinit();
        if (self.block_table.len > 0) {
            self.allocator.free(self.block_table);
        }
    }

    /// Get total tokens (prompt + generated)
    pub fn getTotalTokens(self: *const Self) u32 {
        return self.prompt_len + self.tokens_generated;
    }

    /// Check if request has reached max tokens
    pub fn hasReachedMaxTokens(self: *const Self) bool {
        return self.tokens_generated >= self.sampling_params.max_tokens;
    }

    /// Get request ID as a string slice
    pub fn getRequestIdStr(self: *const Self) []const u8 {
        return &self.request_id;
    }

    /// Calculate time in queue (ms)
    pub fn getQueueTime(self: *const Self) i64 {
        if (self.start_time == 0) return 0;
        return @divFloor(self.start_time - self.arrival_time, std.time.ns_per_ms);
    }

    /// Calculate processing time (ms)
    pub fn getProcessingTime(self: *const Self) i64 {
        const end = if (self.end_time > 0) self.end_time else std.time.nanoTimestamp();
        if (self.start_time == 0) return 0;
        return @divFloor(end - self.start_time, std.time.ns_per_ms);
    }
};

// ============================================
// Sampling Parameters
// ============================================

/// Parameters controlling the sampling/generation process
pub const SamplingParams = struct {
    /// Number of output sequences to generate
    n: u32 = 1,

    /// Maximum number of tokens to generate
    max_tokens: u32 = 16,

    /// Minimum number of tokens to generate
    min_tokens: u32 = 0,

    /// Temperature for sampling (0 = greedy, >1 = more random)
    temperature: f32 = 1.0,

    /// Top-p (nucleus) sampling threshold
    top_p: f32 = 1.0,

    /// Top-k sampling (0 = disabled)
    top_k: u32 = 0,

    /// Minimum probability for top-p sampling
    min_p: f32 = 0.0,

    /// Repetition penalty (1.0 = no penalty)
    repetition_penalty: f32 = 1.0,

    /// Frequency penalty
    frequency_penalty: f32 = 0.0,

    /// Presence penalty
    presence_penalty: f32 = 0.0,

    /// Random seed for reproducibility (null = random)
    seed: ?u64 = null,

    /// Stop sequences (token IDs)
    stop_token_ids: []const u32 = &[_]u32{},

    /// Whether to include stop token in output
    include_stop_token: bool = false,

    /// Skip special tokens in output
    skip_special_tokens: bool = true,

    /// Whether to return logprobs
    logprobs: ?u32 = null,

    /// Whether to return prompt logprobs
    prompt_logprobs: ?u32 = null,

    /// Use beam search instead of sampling
    use_beam_search: bool = false,

    /// Beam width for beam search
    beam_width: u32 = 1,

    /// Length penalty for beam search
    length_penalty: f32 = 1.0,

    /// Early stopping for beam search
    early_stopping: bool = false,

    const Self = @This();

    /// Validate sampling parameters
    pub fn validate(self: *const Self) !void {
        if (self.temperature < 0) {
            return error.InvalidTemperature;
        }
        if (self.top_p < 0 or self.top_p > 1) {
            return error.InvalidTopP;
        }
        if (self.max_tokens == 0) {
            return error.InvalidMaxTokens;
        }
        if (self.n == 0) {
            return error.InvalidN;
        }
        if (self.repetition_penalty < 0) {
            return error.InvalidRepetitionPenalty;
        }
    }

    /// Check if using greedy decoding
    pub fn isGreedy(self: *const Self) bool {
        return self.temperature == 0 or (self.temperature == 1.0 and self.top_k == 1);
    }

    /// Get effective temperature (handles edge cases)
    pub fn getEffectiveTemperature(self: *const Self) f32 {
        if (self.temperature <= 0) return 1e-6; // Avoid division by zero
        return self.temperature;
    }
};

// ============================================
// Sequence Group
// ============================================

/// A group of sequences sharing the same prompt (for n > 1)
pub const SequenceGroup = struct {
    /// Group ID (same as first request ID)
    group_id: RequestId,

    /// All sequences in this group
    sequences: std.ArrayList(*Request),

    /// Shared prompt tokens
    prompt_token_ids: []const u32,

    /// Whether prefill is complete for this group
    prefill_complete: bool = false,

    /// Sampling parameters (shared)
    sampling_params: SamplingParams,

    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator, prompt: []const u32, params: SamplingParams) !Self {
        return Self{
            .group_id = generateRequestId(),
            .sequences = std.ArrayList(*Request).init(alloc),
            .prompt_token_ids = prompt,
            .sampling_params = params,
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.sequences.items) |seq| {
            seq.deinit();
            self.allocator.destroy(seq);
        }
        self.sequences.deinit();
    }

    pub fn addSequence(self: *Self) !*Request {
        const seq = try self.allocator.create(Request);
        seq.* = Request.init(self.allocator);
        seq.prompt_token_ids = self.prompt_token_ids;
        seq.prompt_len = @intCast(self.prompt_token_ids.len);
        seq.sampling_params = self.sampling_params;
        try self.sequences.append(seq);
        return seq;
    }

    pub fn getNumRunning(self: *const Self) usize {
        var count: usize = 0;
        for (self.sequences.items) |seq| {
            if (seq.state == .running) count += 1;
        }
        return count;
    }

    pub fn isFinished(self: *const Self) bool {
        for (self.sequences.items) |seq| {
            if (!seq.state.isTerminal()) return false;
        }
        return true;
    }
};

// ============================================
// Output Types
// ============================================

/// Output for a single generated sequence
pub const SequenceOutput = struct {
    /// Index within the request (for n > 1)
    index: u32,
    /// Generated text
    text: []const u8,
    /// Generated token IDs
    token_ids: []const u32,
    /// Finish reason
    finish_reason: ?FinishReason,
    /// Log probabilities (if requested)
    logprobs: ?[]const TokenLogprob = null,
};

/// Log probability for a single token
pub const TokenLogprob = struct {
    /// Token ID
    token_id: u32,
    /// Log probability
    logprob: f32,
    /// Top alternative tokens
    top_logprobs: ?[]const struct {
        token_id: u32,
        logprob: f32,
    } = null,
};

/// Complete output for a request
pub const RequestOutput = struct {
    /// Request ID
    request_id: RequestId,
    /// Original prompt
    prompt: []const u8,
    /// Prompt token IDs
    prompt_token_ids: []const u32,
    /// Generated outputs (one per n)
    outputs: []const SequenceOutput,
    /// Whether this is the final output
    finished: bool,
    /// Metrics
    metrics: ?RequestMetrics = null,
};

/// Performance metrics for a request
pub const RequestMetrics = struct {
    /// Time in queue (ms)
    queue_time_ms: i64,
    /// Time to first token (ms)
    ttft_ms: i64,
    /// Total processing time (ms)
    total_time_ms: i64,
    /// Tokens per second
    tokens_per_sec: f32,
    /// Prompt tokens
    prompt_tokens: u32,
    /// Generated tokens
    generated_tokens: u32,
};

// ============================================
// Tests
// ============================================

test "Request initialization" {
    const alloc = std.testing.allocator;
    var req = Request.init(alloc);
    defer req.deinit();

    try std.testing.expectEqual(RequestState.pending, req.state);
    try std.testing.expectEqual(@as(u32, 0), req.tokens_generated);
    try std.testing.expect(req.arrival_time > 0);
}

test "SamplingParams validation" {
    var params = SamplingParams{};
    try params.validate();

    params.temperature = -1;
    try std.testing.expectError(error.InvalidTemperature, params.validate());

    params.temperature = 1.0;
    params.top_p = 1.5;
    try std.testing.expectError(error.InvalidTopP, params.validate());
}

test "RequestState terminal check" {
    try std.testing.expect(RequestState.completed.isTerminal());
    try std.testing.expect(RequestState.failed.isTerminal());
    try std.testing.expect(RequestState.cancelled.isTerminal());
    try std.testing.expect(!RequestState.pending.isTerminal());
    try std.testing.expect(!RequestState.running.isTerminal());
}

test "SamplingParams greedy detection" {
    var params = SamplingParams{ .temperature = 0 };
    try std.testing.expect(params.isGreedy());

    params.temperature = 1.0;
    params.top_k = 1;
    try std.testing.expect(params.isGreedy());

    params.top_k = 50;
    try std.testing.expect(!params.isGreedy());
}