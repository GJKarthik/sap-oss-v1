//! Chunked Prefill Scheduler
//!
//! Splits long prompt prefills into configurable chunks to maintain decode latency:
//! - Breaks prompt into fixed-size chunks (e.g., 512 tokens)
//! - Interleaves decode steps between prefill chunks
//! - Tracks per-request prefill progress
//! - Priority: active decodes > prefill chunks

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Configuration
// ============================================================================

pub const ChunkedPrefillConfig = struct {
    max_chunk_size: u32 = 512,
    max_batch_tokens: u32 = 4096,
    decode_priority_ratio: f32 = 0.8, // 80% budget to decodes
    max_pending_prefills: u32 = 64,
    enable_prefix_caching: bool = true,
};

// ============================================================================
// Prefill Request Tracking
// ============================================================================

pub const PrefillStatus = enum { pending, chunking, completed, failed };

pub const PrefillRequest = struct {
    request_id: u64,
    prompt_tokens: []const u32,
    tokens_prefilled: u32,
    total_tokens: u32,
    status: PrefillStatus,
    priority: u8,
    submit_time_ns: i128,
    kv_slot_id: ?u32,

    pub fn init(id: u64, tokens: []const u32, priority: u8) PrefillRequest {
        return .{
            .request_id = id,
            .prompt_tokens = tokens,
            .tokens_prefilled = 0,
            .total_tokens = @intCast(tokens.len),
            .status = .pending,
            .priority = priority,
            .submit_time_ns = std.time.nanoTimestamp(),
            .kv_slot_id = null,
        };
    }

    pub fn remainingTokens(self: *const PrefillRequest) u32 {
        return self.total_tokens - self.tokens_prefilled;
    }

    pub fn isComplete(self: *const PrefillRequest) bool {
        return self.tokens_prefilled >= self.total_tokens;
    }

    /// Get the next chunk of tokens to prefill
    pub fn nextChunk(self: *const PrefillRequest, max_chunk: u32) []const u32 {
        const start = self.tokens_prefilled;
        const remaining = self.remainingTokens();
        const chunk_size = @min(remaining, max_chunk);
        return self.prompt_tokens[start .. start + chunk_size];
    }
};

// ============================================================================
// Chunk Schedule Output
// ============================================================================

pub const ScheduledChunk = struct {
    request_id: u64,
    tokens: []const u32,
    is_first_chunk: bool,
    is_last_chunk: bool,
    kv_slot_id: u32,
};

pub const ScheduleResult = struct {
    prefill_chunks: []ScheduledChunk,
    decode_budget: u32, // remaining token budget for decode steps
    total_prefill_tokens: u32,
};

// ============================================================================
// Chunked Prefill Scheduler
// ============================================================================

pub const ChunkedPrefillScheduler = struct {
    allocator: Allocator,
    config: ChunkedPrefillConfig,
    pending: std.ArrayListUnmanaged(PrefillRequest),
    active: std.ArrayListUnmanaged(PrefillRequest),
    result_chunks: std.ArrayListUnmanaged(ScheduledChunk),
    next_kv_slot: u32,
    total_prefilled: u64,
    total_chunks: u64,

    pub fn init(allocator: Allocator, config: ChunkedPrefillConfig) ChunkedPrefillScheduler {
        return .{
            .allocator = allocator,
            .config = config,
            .pending = .empty,
            .active = .empty,
            .result_chunks = .empty,
            .next_kv_slot = 0,
            .total_prefilled = 0,
            .total_chunks = 0,
        };
    }

    pub fn deinit(self: *ChunkedPrefillScheduler) void {
        self.pending.deinit(self.allocator);
        self.active.deinit(self.allocator);
        self.result_chunks.deinit(self.allocator);
    }



    /// Submit a new prefill request
    pub fn submitRequest(self: *ChunkedPrefillScheduler, id: u64, tokens: []const u32, priority: u8) !void {
        if (self.pending.items.len >= self.config.max_pending_prefills) return error.PrefillQueueFull;
        var req = PrefillRequest.init(id, tokens, priority);
        req.kv_slot_id = self.next_kv_slot;
        self.next_kv_slot += 1;
        try self.pending.append(self.allocator, req);
    }

    /// Schedule next batch: returns prefill chunks and remaining decode budget
    pub fn scheduleBatch(self: *ChunkedPrefillScheduler, active_decode_count: u32) !ScheduleResult {
        // Calculate token budget
        const total_budget = self.config.max_batch_tokens;
        const decode_tokens = @min(active_decode_count, @as(u32, @intFromFloat(@as(f32, @floatFromInt(total_budget)) * self.config.decode_priority_ratio)));
        var prefill_budget = total_budget - decode_tokens;
        var total_prefill_tokens: u32 = 0;

        // Move pending → active if not already chunking
        while (self.pending.items.len > 0 and prefill_budget > 0) {
            const req = self.pending.items[0];
            if (req.remainingTokens() > 0) {
                var moved = self.pending.orderedRemove(0);
                moved.status = .chunking;
                try self.active.append(self.allocator, moved);
            } else {
                _ = self.pending.orderedRemove(0);
            }
        }

        // Create chunks from active requests (reuse buffer)
        self.result_chunks.clearRetainingCapacity();
        var i: usize = 0;
        while (i < self.active.items.len and prefill_budget > 0) {
            const req = &self.active.items[i];
            const chunk_size = @min(self.config.max_chunk_size, @min(req.remainingTokens(), prefill_budget));
            if (chunk_size == 0) { i += 1; continue; }
            const chunk_tokens = req.nextChunk(chunk_size);
            const is_first = req.tokens_prefilled == 0;
            req.tokens_prefilled += chunk_size;
            const is_last = req.isComplete();
            try self.result_chunks.append(self.allocator, .{
                .request_id = req.request_id,
                .tokens = chunk_tokens,
                .is_first_chunk = is_first,
                .is_last_chunk = is_last,
                .kv_slot_id = req.kv_slot_id orelse 0,
            });
            prefill_budget -= chunk_size;
            total_prefill_tokens += chunk_size;
            self.total_prefilled += chunk_size;
            self.total_chunks += 1;
            if (is_last) {
                req.status = .completed;
                _ = self.active.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        return .{
            .prefill_chunks = self.result_chunks.items,
            .decode_budget = decode_tokens,
            .total_prefill_tokens = total_prefill_tokens,
        };
    }

    pub fn pendingCount(self: *const ChunkedPrefillScheduler) u32 {
        return @intCast(self.pending.items.len);
    }

    pub fn activeCount(self: *const ChunkedPrefillScheduler) u32 {
        return @intCast(self.active.items.len);
    }

    pub fn stats(self: *const ChunkedPrefillScheduler) struct { total_prefilled: u64, total_chunks: u64 } {
        return .{ .total_prefilled = self.total_prefilled, .total_chunks = self.total_chunks };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "prefill request basics" {
    const tokens = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const req = PrefillRequest.init(42, &tokens, 5);
    try std.testing.expectEqual(@as(u32, 8), req.total_tokens);
    try std.testing.expectEqual(@as(u32, 8), req.remainingTokens());
    try std.testing.expect(!req.isComplete());
}

test "prefill request next chunk" {
    const tokens = [_]u32{ 10, 20, 30, 40, 50 };
    var req = PrefillRequest.init(1, &tokens, 5);
    const chunk1 = req.nextChunk(3);
    try std.testing.expectEqual(@as(usize, 3), chunk1.len);
    try std.testing.expectEqual(@as(u32, 10), chunk1[0]);
    req.tokens_prefilled = 3;
    const chunk2 = req.nextChunk(3);
    try std.testing.expectEqual(@as(usize, 2), chunk2.len);
    try std.testing.expectEqual(@as(u32, 40), chunk2[0]);
}

test "chunked prefill scheduler basic" {
    const allocator = std.testing.allocator;
    var sched = ChunkedPrefillScheduler.init(allocator, .{ .max_chunk_size = 4, .max_batch_tokens = 16 });
    defer sched.deinit();
    const tokens = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    try sched.submitRequest(1, &tokens, 5);
    try std.testing.expectEqual(@as(u32, 1), sched.pendingCount());
    const result = try sched.scheduleBatch(0);
    try std.testing.expect(result.prefill_chunks.len > 0);
    try std.testing.expect(result.total_prefill_tokens > 0);
}

test "chunked prefill scheduler decode priority" {
    const allocator = std.testing.allocator;
    var sched = ChunkedPrefillScheduler.init(allocator, .{
        .max_chunk_size = 4,
        .max_batch_tokens = 100,
        .decode_priority_ratio = 0.8,
    });
    defer sched.deinit();
    const tokens = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    try sched.submitRequest(1, &tokens, 5);
    const result = try sched.scheduleBatch(50);
    // With 50 active decodes, decode_budget = min(50, 80) = 50, prefill budget = 50
    try std.testing.expect(result.decode_budget <= 80);
}

test "chunked prefill scheduler queue full" {
    const allocator = std.testing.allocator;
    var sched = ChunkedPrefillScheduler.init(allocator, .{ .max_pending_prefills = 2 });
    defer sched.deinit();
    const tokens = [_]u32{1};
    try sched.submitRequest(1, &tokens, 5);
    try sched.submitRequest(2, &tokens, 5);
    const result = sched.submitRequest(3, &tokens, 5);
    try std.testing.expectError(error.PrefillQueueFull, result);
}