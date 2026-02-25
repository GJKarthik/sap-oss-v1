//! Chunked Prefill Optimization
//!
//! Implements chunked prefill to improve throughput by:
//! - Breaking long prompts into smaller chunks
//! - Interleaving prefill with decode operations
//! - Reducing memory peaks during prompt processing
//!
//! This prevents long prompts from blocking the system and
//! enables better GPU utilization.

const std = @import("std");
const log = @import("../utils/logging.zig");

// ==============================================
// Chunked Prefill Configuration
// ==============================================

/// Configuration for chunked prefill
pub const ChunkedPrefillConfig = struct {
    /// Enable chunked prefill
    enabled: bool = true,
    
    /// Maximum tokens per prefill chunk
    max_chunk_size: u32 = 512,
    
    /// Minimum tokens to trigger chunking
    min_chunk_threshold: u32 = 256,
    
    /// Maximum prefill tokens per iteration
    max_prefill_tokens_per_iter: u32 = 4096,
    
    /// Allow interleaving prefill with decode
    enable_interleave: bool = true,
    
    /// Priority boost for prefill (vs decode)
    prefill_priority_boost: f32 = 1.0,
};

// ==============================================
// Prefill Chunk
// ==============================================

/// Represents a chunk of a prefill request
pub const PrefillChunk = struct {
    /// Original request ID
    request_id: []const u8,
    
    /// Chunk index (0, 1, 2, ...)
    chunk_idx: u32,
    
    /// Total number of chunks
    total_chunks: u32,
    
    /// Token positions [start, end)
    start_pos: u32,
    end_pos: u32,
    
    /// Token IDs for this chunk
    token_ids: []const i32,
    
    /// Is this the first chunk?
    is_first: bool,
    
    /// Is this the last chunk?
    is_last: bool,
    
    /// Computed KV cache for previous chunks
    kv_computed_tokens: u32,
    
    pub fn tokenCount(self: PrefillChunk) u32 {
        return self.end_pos - self.start_pos;
    }
};

// ==============================================
// Chunking Strategy
// ==============================================

/// Strategy for chunking prefill requests
pub const ChunkingStrategy = enum {
    /// Fixed size chunks
    fixed_size,
    
    /// Adaptive based on current load
    adaptive,
    
    /// Sentence-boundary aware (if possible)
    sentence_aware,
    
    /// Memory-pressure based
    memory_aware,
};

// ==============================================
// Chunked Prefill Manager
// ==============================================

/// Manages chunked prefill operations
pub const ChunkedPrefillManager = struct {
    config: ChunkedPrefillConfig,
    allocator: std.mem.Allocator,
    
    /// Pending chunks per request
    pending_chunks: std.StringHashMap(std.ArrayList(PrefillChunk)),
    
    /// Chunk progress tracking
    chunk_progress: std.StringHashMap(ChunkProgress),
    
    /// Statistics
    stats: ChunkedPrefillStats = .{},
    
    pub fn init(allocator: std.mem.Allocator, config: ChunkedPrefillConfig) ChunkedPrefillManager {
        return ChunkedPrefillManager{
            .config = config,
            .allocator = allocator,
            .pending_chunks = std.StringHashMap(std.ArrayList(PrefillChunk)).init(allocator),
            .chunk_progress = std.StringHashMap(ChunkProgress).init(allocator),
        };
    }
    
    pub fn deinit(self: *ChunkedPrefillManager) void {
        var it = self.pending_chunks.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.pending_chunks.deinit();
        self.chunk_progress.deinit();
    }
    
    /// Split a request into chunks
    pub fn chunkRequest(
        self: *ChunkedPrefillManager,
        request_id: []const u8,
        token_ids: []const i32,
    ) ![]PrefillChunk {
        const prompt_len: u32 = @intCast(token_ids.len);
        
        // Check if chunking is needed
        if (!self.config.enabled or prompt_len <= self.config.min_chunk_threshold) {
            // Return single chunk
            var chunks = try self.allocator.alloc(PrefillChunk, 1);
            chunks[0] = PrefillChunk{
                .request_id = request_id,
                .chunk_idx = 0,
                .total_chunks = 1,
                .start_pos = 0,
                .end_pos = prompt_len,
                .token_ids = token_ids,
                .is_first = true,
                .is_last = true,
                .kv_computed_tokens = 0,
            };
            return chunks;
        }
        
        // Calculate number of chunks
        const chunk_size = self.config.max_chunk_size;
        const num_chunks = (prompt_len + chunk_size - 1) / chunk_size;
        
        var chunks = try self.allocator.alloc(PrefillChunk, num_chunks);
        
        var pos: u32 = 0;
        for (0..num_chunks) |i| {
            const idx: u32 = @intCast(i);
            const start = pos;
            const end = @min(pos + chunk_size, prompt_len);
            
            chunks[i] = PrefillChunk{
                .request_id = request_id,
                .chunk_idx = idx,
                .total_chunks = num_chunks,
                .start_pos = start,
                .end_pos = end,
                .token_ids = token_ids[start..end],
                .is_first = idx == 0,
                .is_last = idx == num_chunks - 1,
                .kv_computed_tokens = start,
            };
            
            pos = end;
        }
        
        // Track progress
        try self.chunk_progress.put(request_id, ChunkProgress{
            .total_chunks = num_chunks,
            .completed_chunks = 0,
            .total_tokens = prompt_len,
            .completed_tokens = 0,
        });
        
        self.stats.requests_chunked += 1;
        self.stats.total_chunks_created += num_chunks;
        
        log.debug("Chunked request {s}: {d} tokens into {d} chunks", .{
            request_id,
            prompt_len,
            num_chunks,
        });
        
        return chunks;
    }
    
    /// Mark a chunk as completed
    pub fn completeChunk(
        self: *ChunkedPrefillManager,
        request_id: []const u8,
        chunk_idx: u32,
    ) void {
        if (self.chunk_progress.getPtr(request_id)) |progress| {
            progress.completed_chunks += 1;
            
            if (progress.completed_chunks == progress.total_chunks) {
                self.stats.requests_completed += 1;
            }
        }
        
        self.stats.chunks_completed += 1;
    }
    
    /// Get next chunks to process (up to token budget)
    pub fn getNextChunks(
        self: *ChunkedPrefillManager,
        max_tokens: u32,
    ) ![]PrefillChunk {
        var selected = std.ArrayList(PrefillChunk).init(self.allocator);
        var token_budget = max_tokens;
        
        var it = self.pending_chunks.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.items.len == 0) continue;
            
            // Get next chunk for this request
            const chunk = entry.value_ptr.items[0];
            const chunk_tokens = chunk.tokenCount();
            
            if (chunk_tokens <= token_budget) {
                try selected.append(chunk);
                _ = entry.value_ptr.orderedRemove(0);
                token_budget -= chunk_tokens;
            }
            
            if (token_budget == 0) break;
        }
        
        return selected.toOwnedSlice();
    }
    
    /// Check if a request is fully prefilled
    pub fn isRequestComplete(self: *ChunkedPrefillManager, request_id: []const u8) bool {
        if (self.chunk_progress.get(request_id)) |progress| {
            return progress.completed_chunks == progress.total_chunks;
        }
        return false;
    }
    
    /// Get progress for a request
    pub fn getProgress(self: *ChunkedPrefillManager, request_id: []const u8) ?ChunkProgress {
        return self.chunk_progress.get(request_id);
    }
    
    /// Get statistics
    pub fn getStats(self: *ChunkedPrefillManager) ChunkedPrefillStats {
        return self.stats;
    }
};

/// Progress tracking for chunked requests
pub const ChunkProgress = struct {
    total_chunks: u32,
    completed_chunks: u32,
    total_tokens: u32,
    completed_tokens: u32,
    
    pub fn percentComplete(self: ChunkProgress) f32 {
        if (self.total_chunks == 0) return 0.0;
        return @as(f32, @floatFromInt(self.completed_chunks)) /
            @as(f32, @floatFromInt(self.total_chunks)) * 100.0;
    }
};

/// Statistics for chunked prefill
pub const ChunkedPrefillStats = struct {
    requests_chunked: u64 = 0,
    requests_completed: u64 = 0,
    total_chunks_created: u64 = 0,
    chunks_completed: u64 = 0,
    tokens_prefilled: u64 = 0,
};

// ==============================================
// Interleaved Scheduler
// ==============================================

/// Scheduler that interleaves prefill and decode
pub const InterleavedScheduler = struct {
    config: ChunkedPrefillConfig,
    allocator: std.mem.Allocator,
    chunked_prefill: ChunkedPrefillManager,
    
    /// Pending decode requests
    pending_decodes: std.ArrayList(DecodeRequest),
    
    /// Pending prefill chunks
    pending_prefills: std.ArrayList(PrefillChunk),
    
    pub fn init(allocator: std.mem.Allocator, config: ChunkedPrefillConfig) InterleavedScheduler {
        return InterleavedScheduler{
            .config = config,
            .allocator = allocator,
            .chunked_prefill = ChunkedPrefillManager.init(allocator, config),
            .pending_decodes = std.ArrayList(DecodeRequest).init(allocator),
            .pending_prefills = std.ArrayList(PrefillChunk).init(allocator),
        };
    }
    
    pub fn deinit(self: *InterleavedScheduler) void {
        self.chunked_prefill.deinit();
        self.pending_decodes.deinit();
        self.pending_prefills.deinit();
    }
    
    /// Schedule next batch with interleaving
    pub fn scheduleNextBatch(
        self: *InterleavedScheduler,
        max_batch_tokens: u32,
    ) !ScheduledBatch {
        var batch = ScheduledBatch{
            .prefill_chunks = std.ArrayList(PrefillChunk).init(self.allocator),
            .decode_requests = std.ArrayList(DecodeRequest).init(self.allocator),
            .total_tokens = 0,
        };
        
        var token_budget = max_batch_tokens;
        
        // First, schedule some decode requests (they're waiting)
        if (self.config.enable_interleave) {
            const decode_budget = token_budget / 2; // Reserve half for decodes
            var decode_tokens: u32 = 0;
            
            while (self.pending_decodes.items.len > 0 and decode_tokens < decode_budget) {
                const decode = self.pending_decodes.orderedRemove(0);
                try batch.decode_requests.append(decode);
                decode_tokens += 1; // Each decode is 1 token
            }
            
            token_budget -= decode_tokens;
            batch.total_tokens += decode_tokens;
        }
        
        // Then, schedule prefill chunks with remaining budget
        const prefill_budget = @min(token_budget, self.config.max_prefill_tokens_per_iter);
        var prefill_tokens: u32 = 0;
        
        while (self.pending_prefills.items.len > 0 and prefill_tokens < prefill_budget) {
            const chunk = self.pending_prefills.items[0];
            const chunk_tokens = chunk.tokenCount();
            
            if (prefill_tokens + chunk_tokens <= prefill_budget) {
                _ = self.pending_prefills.orderedRemove(0);
                try batch.prefill_chunks.append(chunk);
                prefill_tokens += chunk_tokens;
            } else {
                break; // Chunk too large for remaining budget
            }
        }
        
        batch.total_tokens += prefill_tokens;
        
        return batch;
    }
    
    /// Add a new prefill request
    pub fn addPrefillRequest(
        self: *InterleavedScheduler,
        request_id: []const u8,
        token_ids: []const i32,
    ) !void {
        const chunks = try self.chunked_prefill.chunkRequest(request_id, token_ids);
        
        for (chunks) |chunk| {
            try self.pending_prefills.append(chunk);
        }
    }
    
    /// Add a decode request
    pub fn addDecodeRequest(self: *InterleavedScheduler, request: DecodeRequest) !void {
        try self.pending_decodes.append(request);
    }
};

/// A scheduled batch of work
pub const ScheduledBatch = struct {
    prefill_chunks: std.ArrayList(PrefillChunk),
    decode_requests: std.ArrayList(DecodeRequest),
    total_tokens: u32,
    
    pub fn deinit(self: *ScheduledBatch) void {
        self.prefill_chunks.deinit();
        self.decode_requests.deinit();
    }
    
    pub fn isEmpty(self: ScheduledBatch) bool {
        return self.prefill_chunks.items.len == 0 and
            self.decode_requests.items.len == 0;
    }
};

/// A decode request (single token generation)
pub const DecodeRequest = struct {
    request_id: []const u8,
    seq_len: u32,
    last_token_id: i32,
};

// ==============================================
// Tests
// ==============================================

test "ChunkedPrefillManager basic chunking" {
    const allocator = std.testing.allocator;
    var manager = ChunkedPrefillManager.init(allocator, .{
        .max_chunk_size = 256,
        .min_chunk_threshold = 128,
    });
    defer manager.deinit();
    
    // Create a long prompt
    var tokens: [1000]i32 = undefined;
    for (&tokens, 0..) |*t, i| {
        t.* = @intCast(i);
    }
    
    const chunks = try manager.chunkRequest("test-001", &tokens);
    defer allocator.free(chunks);
    
    // Should be 4 chunks: 256 + 256 + 256 + 232
    try std.testing.expectEqual(@as(usize, 4), chunks.len);
    try std.testing.expect(chunks[0].is_first);
    try std.testing.expect(chunks[3].is_last);
}

test "ChunkedPrefillManager small request no chunking" {
    const allocator = std.testing.allocator;
    var manager = ChunkedPrefillManager.init(allocator, .{
        .max_chunk_size = 256,
        .min_chunk_threshold = 128,
    });
    defer manager.deinit();
    
    var tokens: [100]i32 = undefined;
    for (&tokens, 0..) |*t, i| {
        t.* = @intCast(i);
    }
    
    const chunks = try manager.chunkRequest("test-002", &tokens);
    defer allocator.free(chunks);
    
    // Should be 1 chunk (below threshold)
    try std.testing.expectEqual(@as(usize, 1), chunks.len);
    try std.testing.expect(chunks[0].is_first and chunks[0].is_last);
}