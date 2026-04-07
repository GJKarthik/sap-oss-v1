//! Continuous Batching and Request Scheduling
//!
//! Implements vLLM-style continuous batching with:
//! - Dynamic request batching
//! - Priority-based scheduling  
//! - Paged KV cache management
//! - Preemption support

const std = @import("std");
const Allocator = std.mem.Allocator;
const deductive_db = @import("deductive_db.zig");

// ============================================================================
// Request Types
// ============================================================================

pub const Priority = enum(u8) {
    critical = 10,
    high = 7,
    normal = 5,
    low = 3,
    batch = 1,

    pub fn fromString(s: []const u8) Priority {
        if (std.mem.eql(u8, s, "critical")) return .critical;
        if (std.mem.eql(u8, s, "high")) return .high;
        if (std.mem.eql(u8, s, "normal")) return .normal;
        if (std.mem.eql(u8, s, "low")) return .low;
        if (std.mem.eql(u8, s, "batch")) return .batch;
        return .normal;
    }
};

pub const RequestStatus = enum {
    pending,
    running,
    preempted,
    completed,
    failed,
    cancelled,
};

pub const InferenceRequest = struct {
    id: u64,
    model_id: []const u8,
    prompt_tokens: []const u32,
    max_new_tokens: u32,
    temperature: f32,
    priority: Priority,
    user_id: ?[]const u8,
    
    // Timing
    submit_time: i64,
    start_time: ?i64,
    
    // State
    status: RequestStatus,
    generated_tokens: std.ArrayListUnmanaged(u32),
    kv_block_ids: std.ArrayListUnmanaged(u32),  // Allocated KV cache blocks
    
    // Output
    output_callback: ?*const fn (token: u32, is_final: bool) void,
    
    pub fn init(
        allocator: Allocator,
        id: u64,
        model_id: []const u8,
        prompt_tokens: []const u32,
        max_new_tokens: u32,
        priority: Priority,
    ) InferenceRequest {
        _ = allocator;
        return .{
            .id = id,
            .model_id = model_id,
            .prompt_tokens = prompt_tokens,
            .max_new_tokens = max_new_tokens,
            .temperature = 0.7,
            .priority = priority,
            .user_id = null,
            .submit_time = std.time.milliTimestamp(),
            .start_time = null,
            .status = .pending,
            .generated_tokens = std.ArrayListUnmanaged(u32){},
            .kv_block_ids = std.ArrayListUnmanaged(u32){},
            .output_callback = null,
        };
    }
    
    pub fn deinit(self: *InferenceRequest, allocator: Allocator) void {
        // Bug 4 fix: ArrayListUnmanaged.deinit requires the allocator parameter
        self.generated_tokens.deinit(allocator);
        self.kv_block_ids.deinit(allocator);
    }
    
    pub fn totalTokens(self: *const InferenceRequest) usize {
        return self.prompt_tokens.len + self.generated_tokens.items.len;
    }
    
    pub fn isComplete(self: *const InferenceRequest) bool {
        return self.generated_tokens.items.len >= self.max_new_tokens;
    }
};

// ============================================================================
// Paged KV Cache
// ============================================================================

pub const KvBlock = struct {
    id: u32,
    ref_count: u32,
    sequence_id: ?u64,  // Which request owns this block
    tokens_used: u16,
    max_tokens: u16,
    
    // Actual KV data would be in GPU memory
    // This is just the metadata
    key_offset: usize,
    value_offset: usize,
    
    pub fn init(id: u32, max_tokens: u16) KvBlock {
        return .{
            .id = id,
            .ref_count = 0,
            .sequence_id = null,
            .tokens_used = 0,
            .max_tokens = max_tokens,
            .key_offset = 0,
            .value_offset = 0,
        };
    }
    
    pub fn isFree(self: *const KvBlock) bool {
        return self.ref_count == 0;
    }
    
    pub fn hasSpace(self: *const KvBlock) bool {
        return self.tokens_used < self.max_tokens;
    }
};

pub const PagedKvCache = struct {
    allocator: Allocator,
    blocks: []KvBlock,
    num_blocks: u32,
    block_size: u16,  // Tokens per block
    free_blocks: std.ArrayListUnmanaged(u32),  // Free block IDs
    
    // Per-layer configuration
    num_layers: u32,
    num_heads: u32,
    head_dim: u32,
    
    // Memory tracking
    total_memory_mb: u32,
    used_memory_mb: u32,
    
    const Self = @This();
    
    pub fn init(
        allocator: Allocator,
        num_blocks: u32,
        block_size: u16,
        num_layers: u32,
        num_heads: u32,
        head_dim: u32,
    ) !Self {
        const blocks = try allocator.alloc(KvBlock, num_blocks);
        var free_blocks = std.ArrayListUnmanaged(u32){};
        
        for (0..num_blocks) |i| {
            blocks[i] = KvBlock.init(@intCast(i), block_size);
            try free_blocks.append(allocator, @intCast(i));
        }
        
        // Calculate memory (2 * layers * heads * head_dim * block_size * num_blocks * sizeof(f16))
        const bytes_per_block = @as(u64, 2) * num_layers * num_heads * head_dim * block_size * 2;
        const total_mb = @as(u32, @intCast((bytes_per_block * num_blocks) / (1024 * 1024)));
        
        return Self{
            .allocator = allocator,
            .blocks = blocks,
            .num_blocks = num_blocks,
            .block_size = block_size,
            .free_blocks = free_blocks,
            .num_layers = num_layers,
            .num_heads = num_heads,
            .head_dim = head_dim,
            .total_memory_mb = total_mb,
            .used_memory_mb = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.blocks);
        self.free_blocks.deinit(self.allocator);
    }
    
    /// Allocate a block for a sequence
    pub fn allocateBlock(self: *Self, sequence_id: u64) ?u32 {
        if (self.free_blocks.items.len == 0) return null;
        
        const block_id = self.free_blocks.pop() orelse return null;
        var block = &self.blocks[@intCast(block_id)];
        block.ref_count = 1;
        block.sequence_id = sequence_id;
        block.tokens_used = 0;
        
        self.used_memory_mb += self.memoryPerBlock();
        return block_id;
    }
    
    /// Free blocks for a sequence
    pub fn freeBlocksForSequence(self: *Self, sequence_id: u64) void {
        for (self.blocks) |*block| {
            if (block.sequence_id == sequence_id) {
                block.ref_count = 0;
                block.sequence_id = null;
                block.tokens_used = 0;
                // Bug 4 fix: ArrayListUnmanaged.append requires allocator
                self.free_blocks.append(self.allocator, block.id) catch {};
                self.used_memory_mb -|= self.memoryPerBlock();
            }
        }
    }
    
    /// Get number of free blocks
    pub fn numFreeBlocks(self: *const Self) u32 {
        return @intCast(self.free_blocks.items.len);
    }
    
    /// Get utilization percentage (returns 0 if no blocks configured)
    pub fn utilizationPercent(self: *const Self) f32 {
        if (self.num_blocks == 0) return 0.0;
        const used = self.num_blocks - @as(u32, @intCast(self.free_blocks.items.len));
        return @as(f32, @floatFromInt(used)) / @as(f32, @floatFromInt(self.num_blocks)) * 100.0;
    }

    fn memoryPerBlock(self: *const Self) u32 {
        if (self.num_blocks == 0) return 0;
        return self.total_memory_mb / self.num_blocks;
    }
};

// ============================================================================
// Batch Scheduler
// ============================================================================

pub const BatchConfig = struct {
    max_batch_size: u32 = 32,
    max_batch_tokens: u32 = 8192,
    min_batch_wait_ms: u32 = 10,
    max_queue_depth: u32 = 256,
    preemption_enabled: bool = true,
};

pub const RunningBatch = struct {
    requests: std.ArrayListUnmanaged(*InferenceRequest),
    total_tokens: u32,
    start_time: i64,
    iteration: u32,
};

pub const BatchScheduler = struct {
    allocator: Allocator,
    config: BatchConfig,
    
    // Request queues by priority
    pending_critical: std.ArrayListUnmanaged(*InferenceRequest),
    pending_high: std.ArrayListUnmanaged(*InferenceRequest),
    pending_normal: std.ArrayListUnmanaged(*InferenceRequest),
    pending_low: std.ArrayListUnmanaged(*InferenceRequest),
    pending_batch: std.ArrayListUnmanaged(*InferenceRequest),
    
    // Running batch
    running: RunningBatch,
    
    // Preempted requests (waiting to resume)
    preempted: std.ArrayListUnmanaged(*InferenceRequest),
    
    // KV Cache
    kv_cache: PagedKvCache,
    
    // Statistics
    total_requests: u64,
    completed_requests: u64,
    preempted_count: u64,
    rejected_count: u64,
    
    // Metrics callback (for deductive-db)
    metrics_callback: ?*const fn (batch_size: u32, tokens: u32, latency_ms: u64) void,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator, config: BatchConfig, kv_cache: PagedKvCache) Self {
        return Self{
            .allocator = allocator,
            .config = config,
            .pending_critical = std.ArrayListUnmanaged(*InferenceRequest){},
            .pending_high = std.ArrayListUnmanaged(*InferenceRequest){},
            .pending_normal = std.ArrayListUnmanaged(*InferenceRequest){},
            .pending_low = std.ArrayListUnmanaged(*InferenceRequest){},
            .pending_batch = std.ArrayListUnmanaged(*InferenceRequest){},
            .running = RunningBatch{
                .requests = std.ArrayListUnmanaged(*InferenceRequest){},
                .total_tokens = 0,
                .start_time = 0,
                .iteration = 0,
            },
            .preempted = std.ArrayListUnmanaged(*InferenceRequest){},
            .kv_cache = kv_cache,
            .total_requests = 0,
            .completed_requests = 0,
            .preempted_count = 0,
            .rejected_count = 0,
            .metrics_callback = null,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.pending_critical.deinit(self.allocator);
        self.pending_high.deinit(self.allocator);
        self.pending_normal.deinit(self.allocator);
        self.pending_low.deinit(self.allocator);
        self.pending_batch.deinit(self.allocator);
        self.running.requests.deinit(self.allocator);
        self.preempted.deinit(self.allocator);
        self.kv_cache.deinit();
    }
    
    /// Submit a new request
    pub fn submitRequest(self: *Self, request: *InferenceRequest) !void {
        // Check queue depth
        const total_pending = self.totalPending();
        if (total_pending >= self.config.max_queue_depth) {
            // Try to reject lowest priority
            if (self.config.preemption_enabled) {
                if (!self.rejectLowestPriority(request.priority)) {
                    self.rejected_count += 1;
                    return error.QueueFull;
                }
            } else {
                self.rejected_count += 1;
                return error.QueueFull;
            }
        }
        
        // Add to appropriate queue
        const queue = self.getQueueForPriority(request.priority);
        // Bug 4 fix: ArrayListUnmanaged.append requires allocator
        try queue.append(self.allocator, request);
        self.total_requests += 1;
    }
    
    /// Schedule next batch iteration
    pub fn scheduleIteration(self: *Self) ![]const *InferenceRequest {
        // First, try to add pending requests to running batch
        try self.fillBatch();
        
        // Check for preemption needs
        if (self.config.preemption_enabled) {
            try self.handlePreemption();
        }
        
        // Return current batch for inference
        return self.running.requests.items;
    }
    
    /// Complete a token for a request
    pub fn completeToken(self: *Self, request: *InferenceRequest, token: u32) !void {
        // Bug 4 fix: ArrayListUnmanaged.append requires allocator
        try request.generated_tokens.append(self.allocator, token);
        
        // Call output callback if set
        if (request.output_callback) |callback| {
            callback(token, request.isComplete());
        }
        
        // Check if request is complete
        if (request.isComplete()) {
            request.status = .completed;
            self.completed_requests += 1;
            
            // Free KV cache blocks
            self.kv_cache.freeBlocksForSequence(request.id);
            
            // Remove from running batch
            self.removeFromRunning(request);
        } else {
            // May need to allocate new KV block
            try self.ensureKvBlocks(request);
        }
    }
    
    /// Handle preemption of lower priority requests
    fn handlePreemption(self: *Self) !void {
        // Check if critical requests are waiting
        if (self.pending_critical.items.len > 0 and self.running.requests.items.len > 0) {
            // Find lowest priority running request
            var lowest: ?*InferenceRequest = null;
            var lowest_priority: u8 = 255;
            
            for (self.running.requests.items) |req| {
                const pri = @intFromEnum(req.priority);
                if (pri < lowest_priority) {
                    lowest_priority = pri;
                    lowest = req;
                }
            }
            
            // Check if we should preempt
            if (lowest) |req| {
                const critical_pri = @intFromEnum(Priority.critical);
                if (critical_pri - lowest_priority >= 3) {
                    try self.preemptRequest(req);
                }
            }
        }
    }
    
    /// Preempt a request
    fn preemptRequest(self: *Self, request: *InferenceRequest) !void {
        request.status = .preempted;
        self.preempted_count += 1;
        
        // Move to preempted queue (keep KV cache)
        // Bug 4 fix: ArrayListUnmanaged.append requires allocator
        try self.preempted.append(self.allocator, request);
        self.removeFromRunning(request);
    }
    
    /// Fill batch with pending requests
    fn fillBatch(self: *Self) !void {
        // First, try to resume preempted requests
        while (self.preempted.items.len > 0) {
            if (!self.canAddToBatch()) break;
            const req = self.preempted.pop();
            req.status = .running;
            // Bug 4 fix: ArrayListUnmanaged.append requires allocator
            try self.running.requests.append(self.allocator, req);
            self.running.total_tokens += @intCast(req.totalTokens());
        }

        // Then add new requests by priority
        const queues = [_]*std.ArrayListUnmanaged(*InferenceRequest){
            &self.pending_critical,
            &self.pending_high,
            &self.pending_normal,
            &self.pending_low,
            &self.pending_batch,
        };
        
        for (queues) |queue| {
            while (queue.items.len > 0) {
                if (!self.canAddToBatch()) break;
                const req = queue.orderedRemove(0);
                
                // Allocate KV cache blocks
                if (!self.allocateKvForRequest(req)) {
                    // No KV cache available, put back
                    queue.insert(self.allocator, 0, req) catch {};
                    break;
                }
                
                req.status = .running;
                req.start_time = std.time.milliTimestamp();
                // Bug 4 fix: ArrayListUnmanaged.append requires allocator
                try self.running.requests.append(self.allocator, req);
                self.running.total_tokens += @intCast(req.totalTokens());
            }
        }
        
        if (self.running.requests.items.len > 0 and self.running.start_time == 0) {
            self.running.start_time = std.time.milliTimestamp();
        }
    }
    
    fn canAddToBatch(self: *const Self) bool {
        if (self.running.requests.items.len >= self.config.max_batch_size) return false;
        if (self.running.total_tokens >= self.config.max_batch_tokens) return false;
        return true;
    }
    
    fn allocateKvForRequest(self: *Self, request: *InferenceRequest) bool {
        if (self.kv_cache.block_size == 0) return false;
        const num_blocks_needed = (request.prompt_tokens.len + self.kv_cache.block_size - 1) / self.kv_cache.block_size;
        
        if (self.kv_cache.numFreeBlocks() < num_blocks_needed) {
            return false;
        }
        
        for (0..num_blocks_needed) |_| {
            if (self.kv_cache.allocateBlock(request.id)) |block_id| {
                // Bug 4 fix: ArrayListUnmanaged.append requires allocator
                request.kv_block_ids.append(self.allocator, block_id) catch return false;
            } else {
                return false;
            }
        }
        
        return true;
    }
    
    fn ensureKvBlocks(self: *Self, request: *InferenceRequest) !void {
        const current_tokens = request.totalTokens();
        const current_blocks = request.kv_block_ids.items.len;
        const needed_blocks = (current_tokens + self.kv_cache.block_size - 1) / self.kv_cache.block_size;
        
        if (needed_blocks > current_blocks) {
            const new_blocks_needed = needed_blocks - current_blocks;
            for (0..new_blocks_needed) |_| {
                if (self.kv_cache.allocateBlock(request.id)) |block_id| {
                    try request.kv_block_ids.append(self.allocator, block_id);
                }
            }
        }
    }
    
    fn removeFromRunning(self: *Self, request: *InferenceRequest) void {
        for (self.running.requests.items, 0..) |req, i| {
            if (req.id == request.id) {
                _ = self.running.requests.orderedRemove(i);
                self.running.total_tokens -|= @intCast(req.totalTokens());
                break;
            }
        }
    }
    
    fn rejectLowestPriority(self: *Self, min_priority: Priority) bool {
        const min_pri = @intFromEnum(min_priority);
        
        // Try to reject from batch queue first
        if (self.pending_batch.items.len > 0 and @intFromEnum(Priority.batch) < min_pri) {
            const req = self.pending_batch.pop() orelse return false;
            req.status = .cancelled;
            return true;
        }
        
        if (self.pending_low.items.len > 0 and @intFromEnum(Priority.low) < min_pri) {
            const req = self.pending_low.pop() orelse return false;
            req.status = .cancelled;
            return true;
        }
        
        return false;
    }
    
    fn getQueueForPriority(self: *Self, priority: Priority) *std.ArrayListUnmanaged(*InferenceRequest) {
        return switch (priority) {
            .critical => &self.pending_critical,
            .high => &self.pending_high,
            .normal => &self.pending_normal,
            .low => &self.pending_low,
            .batch => &self.pending_batch,
        };
    }
    
    fn totalPending(self: *const Self) usize {
        return self.pending_critical.items.len +
            self.pending_high.items.len +
            self.pending_normal.items.len +
            self.pending_low.items.len +
            self.pending_batch.items.len;
    }
    
    // ========================================================================
    // Statistics
    // ========================================================================
    
    pub fn getStats(self: *const Self) BatchStats {
        return BatchStats{
            .total_requests = self.total_requests,
            .completed_requests = self.completed_requests,
            .preempted_count = self.preempted_count,
            .rejected_count = self.rejected_count,
            .pending_count = self.totalPending(),
            .running_count = self.running.requests.items.len,
            .kv_cache_utilization = self.kv_cache.utilizationPercent(),
        };
    }
};

pub const BatchStats = struct {
    total_requests: u64,
    completed_requests: u64,
    preempted_count: u64,
    rejected_count: u64,
    pending_count: usize,
    running_count: usize,
    kv_cache_utilization: f32,
};

// ============================================================================
// Tests
// ============================================================================

test "paged kv cache allocation" {
    const allocator = std.testing.allocator;
    var cache = try PagedKvCache.init(allocator, 100, 16, 32, 8, 128);
    defer cache.deinit();
    
    try std.testing.expectEqual(@as(u32, 100), cache.numFreeBlocks());
    
    const block_id = cache.allocateBlock(1);
    try std.testing.expect(block_id != null);
    try std.testing.expectEqual(@as(u32, 99), cache.numFreeBlocks());
    
    cache.freeBlocksForSequence(1);
    try std.testing.expectEqual(@as(u32, 100), cache.numFreeBlocks());
}

test "batch scheduler submit" {
    const allocator = std.testing.allocator;
    const cache = try PagedKvCache.init(allocator, 100, 16, 32, 8, 128);
    var scheduler = BatchScheduler.init(allocator, BatchConfig{}, cache);
    defer scheduler.deinit();
    
    var prompt = [_]u32{ 1, 2, 3, 4, 5 };
    var request = InferenceRequest.init(
        allocator,
        1,
        "phi3-lora",
        &prompt,
        100,
        .normal,
    );
    defer request.deinit(allocator);

    try scheduler.submitRequest(&request);
    try std.testing.expectEqual(@as(u64, 1), scheduler.total_requests);
}

test "priority ordering" {
    try std.testing.expectEqual(@as(u8, 10), @intFromEnum(Priority.critical));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(Priority.batch));
    try std.testing.expect(@intFromEnum(Priority.critical) > @intFromEnum(Priority.normal));
}
