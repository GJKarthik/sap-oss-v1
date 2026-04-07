//! POD Scheduler — Prefill-Or-Decode Workload Manager
//!
//! Coordinates POD-Attention execution by:
//! - Classifying requests as prefill or decode
//! - Building hybrid batches with optimal composition
//! - Computing SM partition ratios
//! - Managing token budgets across workload types
//! - Integrating with chunked prefill for large prompts
//!
//! Reference: POD-Attention (ASPLOS 2025)

const std = @import("std");
const Allocator = std.mem.Allocator;
const chunked_prefill = @import("chunked_prefill.zig");
const batch_scheduler = @import("batch_scheduler.zig");

// ============================================================================
// T4 Hardware Constants
// ============================================================================

pub const T4_NUM_SMS: u32 = 40;
pub const T4_FP16_TFLOPS: f32 = 65.0;
pub const T4_BW_GBPS: f32 = 320.0;
pub const T4_SHMEM_KB: u32 = 48;

// ============================================================================
// Configuration
// ============================================================================

pub const PODConfig = struct {
    /// Maximum total tokens per POD batch
    max_batch_tokens: u32 = 8192,
    
    /// Maximum requests per batch
    max_batch_size: u32 = 64,
    
    /// Minimum SMs allocated to prefill (when both types present)
    min_prefill_sms: u32 = 4,
    
    /// Minimum SMs allocated to decode (when both types present)
    min_decode_sms: u32 = 4,
    
    /// Chunk size for large prefills (tokens)
    prefill_chunk_size: u32 = 512,
    
    /// Prioritize decode latency over prefill throughput
    decode_priority: bool = true,
    
    /// Enable adaptive SM partitioning based on workload
    adaptive_partition: bool = true,
    
    /// Target decode latency (ms) for partition decisions
    target_decode_latency_ms: f32 = 50.0,
};

// ============================================================================
// Request Types
// ============================================================================

pub const RequestPhase = enum(u8) {
    /// New request, needs full prompt processing
    prefill,
    /// Active request, generating tokens
    decode,
    /// Prefill split into chunks
    chunked_prefill,
};

pub const PODRequest = struct {
    /// Unique request identifier
    id: u64,
    
    /// Current phase
    phase: RequestPhase,
    
    /// Original prompt length
    prompt_len: u32,
    
    /// Tokens generated so far
    generated_len: u32,
    
    /// Maximum new tokens to generate
    max_new_tokens: u32,
    
    /// KV cache slot assignment
    kv_slot_id: u32,
    
    /// Priority (higher = more urgent)
    priority: u8,
    
    /// For chunked prefill: tokens already prefilled
    prefill_progress: u32,
    
    /// Submission timestamp (ns)
    submit_time_ns: i128,
    
    /// Start time (ns) - when first token was generated
    start_time_ns: ?i128,
    
    pub fn init(id: u64, prompt_len: u32, max_new_tokens: u32, kv_slot_id: u32) PODRequest {
        return .{
            .id = id,
            .phase = .prefill,
            .prompt_len = prompt_len,
            .generated_len = 0,
            .max_new_tokens = max_new_tokens,
            .kv_slot_id = kv_slot_id,
            .priority = 5,
            .prefill_progress = 0,
            .submit_time_ns = std.time.nanoTimestamp(),
            .start_time_ns = null,
        };
    }
    
    pub fn contextLen(self: *const PODRequest) u32 {
        return self.prompt_len + self.generated_len;
    }
    
    pub fn remainingPrefill(self: *const PODRequest) u32 {
        if (self.phase == .prefill or self.phase == .chunked_prefill) {
            return self.prompt_len - self.prefill_progress;
        }
        return 0;
    }
    
    pub fn isComplete(self: *const PODRequest) bool {
        return self.generated_len >= self.max_new_tokens;
    }
    
    /// Estimate compute FLOPs for attention
    pub fn estimateFlops(self: *const PODRequest, num_heads: u32, head_dim: u32, num_layers: u32) f64 {
        const seq_len: f64 = if (self.phase == .decode) 1.0 else @floatFromInt(self.remainingPrefill());
        const ctx_len: f64 = @floatFromInt(self.contextLen());
        const h: f64 = @floatFromInt(num_heads);
        const d: f64 = @floatFromInt(head_dim);
        const l: f64 = @floatFromInt(num_layers);
        
        // Attention: 2 * seq * ctx * dim * heads * layers (Q@K^T + attn@V)
        return 2.0 * seq_len * ctx_len * d * h * l;
    }
    
    /// Estimate memory bytes for KV cache access
    pub fn estimateMemoryBytes(self: *const PODRequest, num_heads: u32, head_dim: u32) u64 {
        const ctx_len: u64 = self.contextLen();
        // K + V, FP16
        return ctx_len * num_heads * head_dim * 2 * 2;
    }
};

// ============================================================================
// SM Partition
// ============================================================================

pub const SMPartition = struct {
    prefill_sms: u32,
    decode_sms: u32,
    prefill_start: u32,
    decode_start: u32,
    
    pub fn init(prefill_sms: u32, decode_sms: u32) SMPartition {
        return .{
            .prefill_sms = prefill_sms,
            .decode_sms = decode_sms,
            .prefill_start = 0,
            .decode_start = prefill_sms,
        };
    }
    
    pub fn allPrefill() SMPartition {
        return init(T4_NUM_SMS, 0);
    }
    
    pub fn allDecode() SMPartition {
        return init(0, T4_NUM_SMS);
    }
    
    pub fn balanced() SMPartition {
        return init(T4_NUM_SMS / 2, T4_NUM_SMS / 2);
    }
};

// ============================================================================
// POD Batch
// ============================================================================

pub const PODBatch = struct {
    allocator: Allocator,
    
    /// All requests in this batch
    requests: std.ArrayListUnmanaged(*PODRequest),
    
    /// Indices of prefill requests
    prefill_indices: std.ArrayListUnmanaged(usize),
    
    /// Indices of decode requests  
    decode_indices: std.ArrayListUnmanaged(usize),
    
    /// Total prefill tokens in batch
    total_prefill_tokens: u32,
    
    /// Total decode tokens (= num decode requests)
    total_decode_tokens: u32,
    
    /// Total KV cache tokens
    total_kv_tokens: u32,
    
    /// Computed SM partition
    partition: SMPartition,
    
    pub fn init(allocator: Allocator) PODBatch {
        return .{
            .allocator = allocator,
            .requests = .empty,
            .prefill_indices = .empty,
            .decode_indices = .empty,
            .total_prefill_tokens = 0,
            .total_decode_tokens = 0,
            .total_kv_tokens = 0,
            .partition = SMPartition.balanced(),
        };
    }
    
    pub fn deinit(self: *PODBatch) void {
        self.requests.deinit(self.allocator);
        self.prefill_indices.deinit(self.allocator);
        self.decode_indices.deinit(self.allocator);
    }
    
    pub fn clear(self: *PODBatch) void {
        self.requests.clearRetainingCapacity();
        self.prefill_indices.clearRetainingCapacity();
        self.decode_indices.clearRetainingCapacity();
        self.total_prefill_tokens = 0;
        self.total_decode_tokens = 0;
        self.total_kv_tokens = 0;
    }
    
    pub fn addRequest(self: *PODBatch, req: *PODRequest) !void {
        const idx = self.requests.items.len;
        try self.requests.append(self.allocator, req);
        
        switch (req.phase) {
            .prefill, .chunked_prefill => {
                try self.prefill_indices.append(self.allocator, idx);
                self.total_prefill_tokens += req.remainingPrefill();
            },
            .decode => {
                try self.decode_indices.append(self.allocator, idx);
                self.total_decode_tokens += 1;
            },
        }
        
        self.total_kv_tokens += req.contextLen();
    }
    
    pub fn numPrefill(self: *const PODBatch) usize {
        return self.prefill_indices.items.len;
    }
    
    pub fn numDecode(self: *const PODBatch) usize {
        return self.decode_indices.items.len;
    }
    
    pub fn getPrefillRequest(self: *const PODBatch, idx: usize) *PODRequest {
        return self.requests.items[self.prefill_indices.items[idx]];
    }
    
    pub fn getDecodeRequest(self: *const PODBatch, idx: usize) *PODRequest {
        return self.requests.items[self.decode_indices.items[idx]];
    }
};

// ============================================================================
// POD Scheduler
// ============================================================================

pub const PODScheduler = struct {
    allocator: Allocator,
    config: PODConfig,
    
    /// Pending prefill requests
    pending_prefill: std.ArrayListUnmanaged(*PODRequest),
    
    /// Active decode requests
    active_decode: std.ArrayListUnmanaged(*PODRequest),
    
    /// Current batch being built
    current_batch: PODBatch,
    
    /// Next KV slot to assign
    next_kv_slot: u32,
    
    /// Model configuration (for FLOP/memory estimation)
    num_heads: u32,
    head_dim: u32,
    num_layers: u32,
    
    /// Statistics
    stats: PODStats,
    
    pub fn init(allocator: Allocator, config: PODConfig, num_heads: u32, head_dim: u32, num_layers: u32) PODScheduler {
        return .{
            .allocator = allocator,
            .config = config,
            .pending_prefill = .empty,
            .active_decode = .empty,
            .current_batch = PODBatch.init(allocator),
            .next_kv_slot = 0,
            .num_heads = num_heads,
            .head_dim = head_dim,
            .num_layers = num_layers,
            .stats = PODStats{},
        };
    }
    
    pub fn deinit(self: *PODScheduler) void {
        self.pending_prefill.deinit(self.allocator);
        self.active_decode.deinit(self.allocator);
        self.current_batch.deinit();
    }
    
    /// Submit a new request
    pub fn submitRequest(self: *PODScheduler, req: *PODRequest) !void {
        // Assign KV slot
        req.kv_slot_id = self.next_kv_slot;
        self.next_kv_slot += 1;
        
        // Check if this should be chunked
        if (req.prompt_len > self.config.prefill_chunk_size) {
            req.phase = .chunked_prefill;
        }
        
        try self.pending_prefill.append(self.allocator, req);
        self.stats.total_submitted += 1;
    }
    
    /// Build the next POD batch
    pub fn buildBatch(self: *PODScheduler) !*PODBatch {
        self.current_batch.clear();
        
        var token_budget = self.config.max_batch_tokens;
        var request_budget = self.config.max_batch_size;
        
        // 1. Prioritize decode requests (for latency)
        if (self.config.decode_priority) {
            var i: usize = 0;
            while (i < self.active_decode.items.len and request_budget > 0) {
                const req = self.active_decode.items[i];
                
                // Decode uses 1 token per request
                if (token_budget >= 1) {
                    try self.current_batch.addRequest(req);
                    token_budget -= 1;
                    request_budget -= 1;
                }
                i += 1;
            }
        }
        
        // 2. Add prefill requests with remaining budget
        var i: usize = 0;
        while (i < self.pending_prefill.items.len and request_budget > 0 and token_budget > 0) {
            const req = self.pending_prefill.items[i];
            var prefill_tokens = req.remainingPrefill();
            
            // Chunk if too large for remaining budget
            if (prefill_tokens > token_budget) {
                if (req.phase != .chunked_prefill) {
                    req.phase = .chunked_prefill;
                }
                prefill_tokens = @min(prefill_tokens, self.config.prefill_chunk_size);
                prefill_tokens = @min(prefill_tokens, token_budget);
            }
            
            if (prefill_tokens > 0) {
                try self.current_batch.addRequest(req);
                token_budget -= prefill_tokens;
                request_budget -= 1;
            }
            i += 1;
        }
        
        // 3. Compute optimal SM partition
        self.current_batch.partition = self.computePartition();
        
        self.stats.batches_scheduled += 1;
        return &self.current_batch;
    }
    
    /// Mark a prefill request as completed (transition to decode)
    pub fn completePrefill(self: *PODScheduler, req: *PODRequest) !void {
        // Update phase
        req.phase = .decode;
        req.prefill_progress = req.prompt_len;
        req.start_time_ns = std.time.nanoTimestamp();
        
        // Move from pending_prefill to active_decode
        for (self.pending_prefill.items, 0..) |r, i| {
            if (r.id == req.id) {
                _ = self.pending_prefill.orderedRemove(i);
                break;
            }
        }
        
        try self.active_decode.append(self.allocator, req);
        self.stats.prefills_completed += 1;
    }
    
    /// Update prefill progress for chunked prefill
    pub fn updatePrefillProgress(self: *PODScheduler, req: *PODRequest, tokens_processed: u32) !void {
        req.prefill_progress += tokens_processed;
        
        // Check if prefill is now complete
        if (req.prefill_progress >= req.prompt_len) {
            try self.completePrefill(req);
        }
    }
    
    /// Record a generated token for a decode request
    pub fn recordToken(self: *PODScheduler, req: *PODRequest) void {
        req.generated_len += 1;
        self.stats.tokens_generated += 1;
        
        // Check if request is complete
        if (req.isComplete()) {
            self.completeRequest(req);
        }
    }
    
    /// Mark a request as complete
    pub fn completeRequest(self: *PODScheduler, req: *PODRequest) void {
        // Remove from active_decode
        for (self.active_decode.items, 0..) |r, i| {
            if (r.id == req.id) {
                _ = self.active_decode.orderedRemove(i);
                break;
            }
        }
        
        self.stats.requests_completed += 1;
    }
    
    /// Compute optimal SM partition for current batch
    fn computePartition(self: *PODScheduler) SMPartition {
        const batch = &self.current_batch;
        
        if (batch.numPrefill() == 0) {
            return SMPartition.allDecode();
        }
        if (batch.numDecode() == 0) {
            return SMPartition.allPrefill();
        }
        
        if (!self.config.adaptive_partition) {
            return SMPartition.balanced();
        }
        
        // Estimate prefill compute time
        var total_prefill_flops: f64 = 0;
        for (batch.prefill_indices.items) |idx| {
            const req = batch.requests.items[idx];
            total_prefill_flops += req.estimateFlops(self.num_heads, self.head_dim, self.num_layers);
        }
        
        // Time on full T4 = FLOPs / (TFLOPS * 1e12)
        const prefill_time_full = total_prefill_flops / (T4_FP16_TFLOPS * 1e12);
        
        // Estimate decode memory time
        var total_decode_bytes: u64 = 0;
        for (batch.decode_indices.items) |idx| {
            const req = batch.requests.items[idx];
            total_decode_bytes += req.estimateMemoryBytes(self.num_heads, self.head_dim);
        }
        
        // Time on full T4 = bytes / (GB/s * 1e9)
        const decode_time_full = @as(f64, @floatFromInt(total_decode_bytes)) / (T4_BW_GBPS * 1e9);
        
        // Partition proportionally
        const total_time = prefill_time_full + decode_time_full;
        if (total_time == 0) {
            return SMPartition.balanced();
        }
        
        const prefill_fraction = prefill_time_full / total_time;
        var prefill_sms: u32 = @intFromFloat(@as(f32, @floatCast(prefill_fraction)) * @as(f32, @floatFromInt(T4_NUM_SMS)));
        
        // Enforce minimums
        prefill_sms = @max(self.config.min_prefill_sms, @min(prefill_sms, T4_NUM_SMS - self.config.min_decode_sms));
        const decode_sms = T4_NUM_SMS - prefill_sms;
        
        return SMPartition.init(prefill_sms, decode_sms);
    }
    
    /// Get scheduler statistics
    pub fn getStats(self: *const PODScheduler) PODStats {
        return self.stats;
    }
    
    /// Get current load info
    pub fn getLoad(self: *const PODScheduler) PODLoad {
        return .{
            .pending_prefill = @intCast(self.pending_prefill.items.len),
            .active_decode = @intCast(self.active_decode.items.len),
            .prefill_tokens_pending = blk: {
                var sum: u32 = 0;
                for (self.pending_prefill.items) |r| {
                    sum += r.remainingPrefill();
                }
                break :blk sum;
            },
            .decode_context_total = blk: {
                var sum: u32 = 0;
                for (self.active_decode.items) |r| {
                    sum += r.contextLen();
                }
                break :blk sum;
            },
        };
    }
};

// ============================================================================
// Statistics
// ============================================================================

pub const PODStats = struct {
    total_submitted: u64 = 0,
    prefills_completed: u64 = 0,
    tokens_generated: u64 = 0,
    requests_completed: u64 = 0,
    batches_scheduled: u64 = 0,
};

pub const PODLoad = struct {
    pending_prefill: u32,
    active_decode: u32,
    prefill_tokens_pending: u32,
    decode_context_total: u32,
};

// ============================================================================
// Performance Metrics
// ============================================================================

pub const PODMetrics = struct {
    /// Estimated prefill latency (ms)
    prefill_latency_ms: f32,
    
    /// Estimated decode latency (ms)
    decode_latency_ms: f32,
    
    /// Total batch latency (concurrent execution)
    total_latency_ms: f32,
    
    /// Speedup vs sequential execution
    speedup: f32,
    
    /// Prefill compute utilization (%)
    prefill_utilization: f32,
    
    /// Decode bandwidth utilization (%)
    decode_utilization: f32,
    
    pub fn estimate(batch: *const PODBatch, num_heads: u32, head_dim: u32, num_layers: u32) PODMetrics {
        var metrics = PODMetrics{
            .prefill_latency_ms = 0,
            .decode_latency_ms = 0,
            .total_latency_ms = 0,
            .speedup = 1.0,
            .prefill_utilization = 0,
            .decode_utilization = 0,
        };
        
        // Prefill time
        var total_flops: f64 = 0;
        for (batch.prefill_indices.items) |idx| {
            const req = batch.requests.items[idx];
            total_flops += req.estimateFlops(num_heads, head_dim, num_layers);
        }
        
        const prefill_tflops = T4_FP16_TFLOPS * @as(f32, @floatFromInt(batch.partition.prefill_sms)) / @as(f32, @floatFromInt(T4_NUM_SMS));
        if (prefill_tflops > 0) {
            metrics.prefill_latency_ms = @as(f32, @floatCast(total_flops / (prefill_tflops * 1e12))) * 1000.0;
        }
        
        // Decode time
        var total_bytes: u64 = 0;
        for (batch.decode_indices.items) |idx| {
            const req = batch.requests.items[idx];
            total_bytes += req.estimateMemoryBytes(num_heads, head_dim);
        }
        
        if (T4_BW_GBPS > 0) {
            metrics.decode_latency_ms = @as(f32, @floatCast(@as(f64, @floatFromInt(total_bytes)) / (T4_BW_GBPS * 1e9))) * 1000.0;
        }
        
        // POD: concurrent execution
        metrics.total_latency_ms = @max(metrics.prefill_latency_ms, metrics.decode_latency_ms);
        
        const sequential = metrics.prefill_latency_ms + metrics.decode_latency_ms;
        if (metrics.total_latency_ms > 0) {
            metrics.speedup = sequential / metrics.total_latency_ms;
        }
        
        return metrics;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "PODRequest init and classification" {
    var req = PODRequest.init(1, 100, 50, 0);
    try std.testing.expectEqual(RequestPhase.prefill, req.phase);
    try std.testing.expectEqual(@as(u32, 100), req.contextLen());
    try std.testing.expectEqual(@as(u32, 100), req.remainingPrefill());
}

test "PODRequest decode phase" {
    var req = PODRequest.init(1, 100, 50, 0);
    req.phase = .decode;
    req.prefill_progress = 100;
    req.generated_len = 10;
    
    try std.testing.expectEqual(@as(u32, 110), req.contextLen());
    try std.testing.expectEqual(@as(u32, 0), req.remainingPrefill());
    try std.testing.expect(!req.isComplete());
    
    req.generated_len = 50;
    try std.testing.expect(req.isComplete());
}

test "PODBatch building" {
    const allocator = std.testing.allocator;
    var batch = PODBatch.init(allocator);
    defer batch.deinit();
    
    var req1 = PODRequest.init(1, 100, 50, 0);
    var req2 = PODRequest.init(2, 50, 30, 1);
    req2.phase = .decode;
    req2.prefill_progress = 50;
    req2.generated_len = 5;
    
    try batch.addRequest(&req1);
    try batch.addRequest(&req2);
    
    try std.testing.expectEqual(@as(usize, 1), batch.numPrefill());
    try std.testing.expectEqual(@as(usize, 1), batch.numDecode());
    try std.testing.expectEqual(@as(u32, 100), batch.total_prefill_tokens);
    try std.testing.expectEqual(@as(u32, 1), batch.total_decode_tokens);
}

test "SM partition computation" {
    // All prefill
    const all_prefill = SMPartition.allPrefill();
    try std.testing.expectEqual(T4_NUM_SMS, all_prefill.prefill_sms);
    try std.testing.expectEqual(@as(u32, 0), all_prefill.decode_sms);
    
    // All decode
    const all_decode = SMPartition.allDecode();
    try std.testing.expectEqual(@as(u32, 0), all_decode.prefill_sms);
    try std.testing.expectEqual(T4_NUM_SMS, all_decode.decode_sms);
    
    // Balanced
    const balanced = SMPartition.balanced();
    try std.testing.expectEqual(T4_NUM_SMS / 2, balanced.prefill_sms);
    try std.testing.expectEqual(T4_NUM_SMS / 2, balanced.decode_sms);
}

test "PODScheduler basic flow" {
    const allocator = std.testing.allocator;
    var scheduler = PODScheduler.init(allocator, .{}, 32, 128, 32);
    defer scheduler.deinit();
    
    // Create and submit a request
    var req = PODRequest.init(1, 100, 50, 0);
    try scheduler.submitRequest(&req);
    
    try std.testing.expectEqual(@as(usize, 1), scheduler.pending_prefill.items.len);
    try std.testing.expectEqual(@as(u64, 1), scheduler.stats.total_submitted);
    
    // Build batch
    const batch = try scheduler.buildBatch();
    try std.testing.expectEqual(@as(usize, 1), batch.numPrefill());
    
    // Complete prefill
    try scheduler.completePrefill(&req);
    try std.testing.expectEqual(@as(usize, 0), scheduler.pending_prefill.items.len);
    try std.testing.expectEqual(@as(usize, 1), scheduler.active_decode.items.len);
    try std.testing.expectEqual(RequestPhase.decode, req.phase);
}

test "chunked prefill detection" {
    const allocator = std.testing.allocator;
    var scheduler = PODScheduler.init(allocator, .{ .prefill_chunk_size = 256 }, 32, 128, 32);
    defer scheduler.deinit();
    
    // Large prompt should be chunked
    var req = PODRequest.init(1, 1000, 50, 0);
    try scheduler.submitRequest(&req);
    
    try std.testing.expectEqual(RequestPhase.chunked_prefill, req.phase);
}