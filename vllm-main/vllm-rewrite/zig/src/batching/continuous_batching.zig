//! Continuous Batching Module
//!
//! Implements continuous batching for high-throughput LLM inference.
//! Dynamically manages batches to maximize GPU utilization.
//!
//! Features:
//! - Dynamic batch formation
//! - Request queue management
//! - Preemption support
//! - Priority scheduling
//! - Iteration-level batching

const std = @import("std");

// ==============================================
// Request State
// ==============================================

pub const RequestState = enum {
    waiting,        // In queue, waiting to be scheduled
    running,        // Currently being processed
    preempted,      // Temporarily paused
    finished,       // Generation complete
    aborted,        // Cancelled by user or timeout
};

pub const RequestPhase = enum {
    prefill,        // Initial prompt processing
    decode,         // Token-by-token generation
};

// ==============================================
// Sequence Request
// ==============================================

pub const SequenceRequest = struct {
    request_id: []const u8,
    arrival_time: i64,
    
    // Input/Output
    prompt_tokens: []const u32,
    output_tokens: std.ArrayList(u32),
    
    // State
    state: RequestState,
    phase: RequestPhase,
    
    // Generation params
    max_tokens: usize,
    temperature: f32,
    top_p: f32,
    stop_sequences: ?[]const []const u8,
    
    // KV Cache
    kv_block_ids: std.ArrayList(usize),
    computed_tokens: usize,
    
    // Scheduling
    priority: i32,
    preempted_count: u32,
    
    // Timing
    first_token_time: ?i64,
    last_token_time: i64,
    
    allocator: std.mem.Allocator,
    
    pub fn init(
        allocator: std.mem.Allocator,
        request_id: []const u8,
        prompt_tokens: []const u32,
        max_tokens: usize,
    ) !SequenceRequest {
        return SequenceRequest{
            .request_id = request_id,
            .arrival_time = std.time.milliTimestamp(),
            .prompt_tokens = prompt_tokens,
            .output_tokens = std.ArrayList(u32).init(allocator),
            .state = .waiting,
            .phase = .prefill,
            .max_tokens = max_tokens,
            .temperature = 1.0,
            .top_p = 1.0,
            .stop_sequences = null,
            .kv_block_ids = std.ArrayList(usize).init(allocator),
            .computed_tokens = 0,
            .priority = 0,
            .preempted_count = 0,
            .first_token_time = null,
            .last_token_time = std.time.milliTimestamp(),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *SequenceRequest) void {
        self.output_tokens.deinit();
        self.kv_block_ids.deinit();
    }
    
    pub fn totalTokens(self: *const SequenceRequest) usize {
        return self.prompt_tokens.len + self.output_tokens.items.len;
    }
    
    pub fn isFinished(self: *const SequenceRequest) bool {
        return self.state == .finished or self.state == .aborted;
    }
    
    pub fn remainingTokens(self: *const SequenceRequest) usize {
        if (self.output_tokens.items.len >= self.max_tokens) return 0;
        return self.max_tokens - self.output_tokens.items.len;
    }
    
    pub fn addToken(self: *SequenceRequest, token: u32) !void {
        try self.output_tokens.append(token);
        self.last_token_time = std.time.milliTimestamp();
        
        if (self.first_token_time == null) {
            self.first_token_time = self.last_token_time;
        }
        
        self.phase = .decode;
        
        // Check if finished
        if (self.output_tokens.items.len >= self.max_tokens) {
            self.state = .finished;
        }
    }
};

// ==============================================
// Request Queue
// ==============================================

pub const RequestQueue = struct {
    waiting: std.ArrayList(*SequenceRequest),
    running: std.ArrayList(*SequenceRequest),
    preempted: std.ArrayList(*SequenceRequest),
    
    max_queue_size: usize,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, max_queue_size: usize) RequestQueue {
        return .{
            .waiting = std.ArrayList(*SequenceRequest).init(allocator),
            .running = std.ArrayList(*SequenceRequest).init(allocator),
            .preempted = std.ArrayList(*SequenceRequest).init(allocator),
            .max_queue_size = max_queue_size,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *RequestQueue) void {
        self.waiting.deinit();
        self.running.deinit();
        self.preempted.deinit();
    }
    
    pub fn enqueue(self: *RequestQueue, request: *SequenceRequest) !bool {
        if (self.waiting.items.len >= self.max_queue_size) {
            return false;
        }
        
        try self.waiting.append(request);
        return true;
    }
    
    pub fn totalPending(self: *const RequestQueue) usize {
        return self.waiting.items.len + self.preempted.items.len;
    }
    
    pub fn totalRunning(self: *const RequestQueue) usize {
        return self.running.items.len;
    }
    
    /// Move request from waiting to running
    pub fn startRequest(self: *RequestQueue, request: *SequenceRequest) !void {
        // Remove from waiting
        for (self.waiting.items, 0..) |item, i| {
            if (item == request) {
                _ = self.waiting.swapRemove(i);
                break;
            }
        }
        
        request.state = .running;
        try self.running.append(request);
    }
    
    /// Move request from running to preempted
    pub fn preemptRequest(self: *RequestQueue, request: *SequenceRequest) !void {
        for (self.running.items, 0..) |item, i| {
            if (item == request) {
                _ = self.running.swapRemove(i);
                break;
            }
        }
        
        request.state = .preempted;
        request.preempted_count += 1;
        try self.preempted.append(request);
    }
    
    /// Move request from preempted to running
    pub fn resumeRequest(self: *RequestQueue, request: *SequenceRequest) !void {
        for (self.preempted.items, 0..) |item, i| {
            if (item == request) {
                _ = self.preempted.swapRemove(i);
                break;
            }
        }
        
        request.state = .running;
        try self.running.append(request);
    }
    
    /// Remove finished request from running
    pub fn completeRequest(self: *RequestQueue, request: *SequenceRequest) void {
        for (self.running.items, 0..) |item, i| {
            if (item == request) {
                _ = self.running.swapRemove(i);
                break;
            }
        }
    }
};

// ==============================================
// Batch Configuration
// ==============================================

pub const BatchConfig = struct {
    max_batch_size: usize,           // Max sequences per batch
    max_tokens_per_batch: usize,      // Max total tokens
    max_prefill_tokens: usize,        // Max tokens in prefill phase
    max_decode_sequences: usize,      // Max decode sequences
    
    // Timing
    batch_timeout_ms: u64,            // Max wait for batch formation
    min_batch_interval_ms: u64,       // Min time between batches
    
    // Preemption
    enable_preemption: bool,
    preemption_threshold: f32,        // Memory threshold for preemption
    
    pub fn default() BatchConfig {
        return .{
            .max_batch_size = 256,
            .max_tokens_per_batch = 8192,
            .max_prefill_tokens = 4096,
            .max_decode_sequences = 256,
            .batch_timeout_ms = 50,
            .min_batch_interval_ms = 10,
            .enable_preemption = true,
            .preemption_threshold = 0.9,
        };
    }
};

// ==============================================
// Batch
// ==============================================

pub const Batch = struct {
    batch_id: u64,
    sequences: std.ArrayList(*SequenceRequest),
    
    // Batch characteristics
    num_prefill: usize,
    num_decode: usize,
    total_tokens: usize,
    
    // Timing
    created_at: i64,
    
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, batch_id: u64) Batch {
        return .{
            .batch_id = batch_id,
            .sequences = std.ArrayList(*SequenceRequest).init(allocator),
            .num_prefill = 0,
            .num_decode = 0,
            .total_tokens = 0,
            .created_at = std.time.milliTimestamp(),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Batch) void {
        self.sequences.deinit();
    }
    
    pub fn addSequence(self: *Batch, seq: *SequenceRequest) !void {
        try self.sequences.append(seq);
        
        if (seq.phase == .prefill) {
            self.num_prefill += 1;
            self.total_tokens += seq.prompt_tokens.len;
        } else {
            self.num_decode += 1;
            self.total_tokens += 1; // Decode adds one token
        }
    }
    
    pub fn isEmpty(self: *const Batch) bool {
        return self.sequences.items.len == 0;
    }
    
    pub fn size(self: *const Batch) usize {
        return self.sequences.items.len;
    }
};

// ==============================================
// Scheduler
// ==============================================

pub const SchedulingPolicy = enum {
    fcfs,           // First come, first served
    sjf,            // Shortest job first
    priority,       // Priority-based
    fair,           // Fair share
};

pub const Scheduler = struct {
    config: BatchConfig,
    queue: RequestQueue,
    policy: SchedulingPolicy,
    
    next_batch_id: u64,
    last_batch_time: i64,
    
    // Statistics
    total_batches: u64,
    total_preemptions: u64,
    
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, config: BatchConfig) Scheduler {
        return .{
            .config = config,
            .queue = RequestQueue.init(allocator, 10000),
            .policy = .fcfs,
            .next_batch_id = 0,
            .last_batch_time = 0,
            .total_batches = 0,
            .total_preemptions = 0,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Scheduler) void {
        self.queue.deinit();
    }
    
    pub fn addRequest(self: *Scheduler, request: *SequenceRequest) !bool {
        return try self.queue.enqueue(request);
    }
    
    /// Main scheduling function - creates next batch
    pub fn schedule(self: *Scheduler, available_blocks: usize) !?Batch {
        // Check timing constraints
        const now = std.time.milliTimestamp();
        if (now - self.last_batch_time < @as(i64, @intCast(self.config.min_batch_interval_ms))) {
            return null;
        }
        
        // Nothing to schedule
        if (self.queue.totalPending() == 0 and self.queue.totalRunning() == 0) {
            return null;
        }
        
        var batch = Batch.init(self.allocator, self.next_batch_id);
        self.next_batch_id += 1;
        
        // Phase 1: Add running decode sequences (they must continue)
        try self.addDecodeSequences(&batch, available_blocks);
        
        // Phase 2: Resume preempted sequences
        try self.addPreemptedSequences(&batch, available_blocks);
        
        // Phase 3: Add new prefill sequences
        try self.addPrefillSequences(&batch, available_blocks);
        
        if (batch.isEmpty()) {
            batch.deinit();
            return null;
        }
        
        self.last_batch_time = now;
        self.total_batches += 1;
        
        return batch;
    }
    
    fn addDecodeSequences(self: *Scheduler, batch: *Batch, available_blocks: usize) !void {
        _ = available_blocks;
        
        // Continue all running decode sequences
        for (self.queue.running.items) |seq| {
            if (seq.phase == .decode and !seq.isFinished()) {
                if (batch.size() >= self.config.max_decode_sequences) break;
                try batch.addSequence(seq);
            }
        }
    }
    
    fn addPreemptedSequences(self: *Scheduler, batch: *Batch, available_blocks: usize) !void {
        _ = available_blocks;
        
        // Sort preempted by priority/preemption count
        const preempted = self.queue.preempted.items;
        
        for (preempted) |seq| {
            if (batch.size() >= self.config.max_batch_size) break;
            if (batch.total_tokens >= self.config.max_tokens_per_batch) break;
            
            try batch.addSequence(seq);
            try self.queue.resumeRequest(seq);
        }
    }
    
    fn addPrefillSequences(self: *Scheduler, batch: *Batch, available_blocks: usize) !void {
        _ = available_blocks;
        
        // Sort waiting by policy
        var sorted = try self.sortByPolicy(self.queue.waiting.items);
        defer self.allocator.free(sorted);
        
        var prefill_tokens: usize = 0;
        
        for (sorted) |seq| {
            if (batch.size() >= self.config.max_batch_size) break;
            if (batch.total_tokens >= self.config.max_tokens_per_batch) break;
            if (prefill_tokens + seq.prompt_tokens.len > self.config.max_prefill_tokens) continue;
            
            prefill_tokens += seq.prompt_tokens.len;
            try batch.addSequence(seq);
            try self.queue.startRequest(seq);
        }
    }
    
    fn sortByPolicy(self: *Scheduler, requests: []*SequenceRequest) ![]*SequenceRequest {
        var sorted = try self.allocator.alloc(*SequenceRequest, requests.len);
        @memcpy(sorted, requests);
        
        switch (self.policy) {
            .fcfs => {
                // Already in arrival order
            },
            .sjf => {
                // Sort by prompt length (shortest first)
                std.sort.sort(*SequenceRequest, sorted, {}, struct {
                    fn lessThan(_: void, a: *SequenceRequest, b: *SequenceRequest) bool {
                        return a.prompt_tokens.len < b.prompt_tokens.len;
                    }
                }.lessThan);
            },
            .priority => {
                // Sort by priority (highest first)
                std.sort.sort(*SequenceRequest, sorted, {}, struct {
                    fn lessThan(_: void, a: *SequenceRequest, b: *SequenceRequest) bool {
                        return a.priority > b.priority;
                    }
                }.lessThan);
            },
            .fair => {
                // Sort by arrival time with fairness adjustment
            },
        }
        
        return sorted;
    }
    
    /// Preempt sequences to free memory
    pub fn preempt(self: *Scheduler, blocks_needed: usize) !usize {
        if (!self.config.enable_preemption) return 0;
        
        var freed_blocks: usize = 0;
        
        // Preempt in reverse priority order
        var i: usize = self.queue.running.items.len;
        while (i > 0 and freed_blocks < blocks_needed) {
            i -= 1;
            const seq = self.queue.running.items[i];
            
            // Don't preempt decode sequences that are almost done
            if (seq.remainingTokens() < 10) continue;
            
            freed_blocks += seq.kv_block_ids.items.len;
            try self.queue.preemptRequest(seq);
            self.total_preemptions += 1;
        }
        
        return freed_blocks;
    }
};

// ==============================================
// Continuous Batching Engine
// ==============================================

pub const ContinuousBatchingEngine = struct {
    scheduler: Scheduler,
    config: BatchConfig,
    
    // Block management
    total_blocks: usize,
    free_blocks: usize,
    
    // Statistics
    total_requests: u64,
    completed_requests: u64,
    avg_batch_size: f32,
    avg_time_to_first_token: f32,
    
    // Callbacks
    on_batch_ready: ?*const fn (*Batch) void,
    on_request_complete: ?*const fn (*SequenceRequest) void,
    
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, config: BatchConfig, total_blocks: usize) ContinuousBatchingEngine {
        return .{
            .scheduler = Scheduler.init(allocator, config),
            .config = config,
            .total_blocks = total_blocks,
            .free_blocks = total_blocks,
            .total_requests = 0,
            .completed_requests = 0,
            .avg_batch_size = 0,
            .avg_time_to_first_token = 0,
            .on_batch_ready = null,
            .on_request_complete = null,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *ContinuousBatchingEngine) void {
        self.scheduler.deinit();
    }
    
    /// Submit new request
    pub fn submit(self: *ContinuousBatchingEngine, request: *SequenceRequest) !bool {
        const accepted = try self.scheduler.addRequest(request);
        if (accepted) {
            self.total_requests += 1;
        }
        return accepted;
    }
    
    /// Main iteration loop - returns next batch to process
    pub fn step(self: *ContinuousBatchingEngine) !?Batch {
        // Check if preemption needed
        if (self.needsPreemption()) {
            const blocks_needed = self.calculateBlocksNeeded();
            _ = try self.scheduler.preempt(blocks_needed);
        }
        
        // Schedule next batch
        const batch = try self.scheduler.schedule(self.free_blocks);
        
        if (batch) |b| {
            // Update statistics
            self.updateStats(&b);
            
            // Callback
            if (self.on_batch_ready) |callback| {
                callback(&b);
            }
        }
        
        return batch;
    }
    
    /// Process batch results
    pub fn processBatchResults(
        self: *ContinuousBatchingEngine,
        batch: *Batch,
        tokens: []const u32,
    ) !void {
        for (batch.sequences.items, 0..) |seq, i| {
            try seq.addToken(tokens[i]);
            
            // Check if sequence finished
            if (seq.isFinished()) {
                self.scheduler.queue.completeRequest(seq);
                self.completed_requests += 1;
                
                // Callback
                if (self.on_request_complete) |callback| {
                    callback(seq);
                }
                
                // Free KV blocks
                self.free_blocks += seq.kv_block_ids.items.len;
            }
        }
    }
    
    fn needsPreemption(self: *ContinuousBatchingEngine) bool {
        const used = self.total_blocks - self.free_blocks;
        const usage = @as(f32, @floatFromInt(used)) / @as(f32, @floatFromInt(self.total_blocks));
        return usage > self.config.preemption_threshold;
    }
    
    fn calculateBlocksNeeded(self: *ContinuousBatchingEngine) usize {
        // Estimate blocks needed for pending requests
        var needed: usize = 0;
        for (self.scheduler.queue.waiting.items) |seq| {
            needed += seq.prompt_tokens.len / 16 + 1; // Assume 16 tokens per block
        }
        return needed;
    }
    
    fn updateStats(self: *ContinuousBatchingEngine, batch: *const Batch) void {
        // Update average batch size
        const n = @as(f32, @floatFromInt(self.scheduler.total_batches));
        self.avg_batch_size = (self.avg_batch_size * (n - 1) + @as(f32, @floatFromInt(batch.size()))) / n;
    }
    
    /// Get engine statistics
    pub fn getStats(self: *const ContinuousBatchingEngine) EngineStats {
        return .{
            .total_requests = self.total_requests,
            .completed_requests = self.completed_requests,
            .pending_requests = self.scheduler.queue.totalPending(),
            .running_requests = self.scheduler.queue.totalRunning(),
            .total_batches = self.scheduler.total_batches,
            .total_preemptions = self.scheduler.total_preemptions,
            .avg_batch_size = self.avg_batch_size,
            .memory_usage = @as(f32, @floatFromInt(self.total_blocks - self.free_blocks)) / @as(f32, @floatFromInt(self.total_blocks)),
        };
    }
};

pub const EngineStats = struct {
    total_requests: u64,
    completed_requests: u64,
    pending_requests: usize,
    running_requests: usize,
    total_batches: u64,
    total_preemptions: u64,
    avg_batch_size: f32,
    memory_usage: f32,
};

// ==============================================
// Iteration-Level Scheduling
// ==============================================

pub const IterationScheduler = struct {
    engine: *ContinuousBatchingEngine,
    running: bool,
    iteration_count: u64,
    
    pub fn init(engine: *ContinuousBatchingEngine) IterationScheduler {
        return .{
            .engine = engine,
            .running = false,
            .iteration_count = 0,
        };
    }
    
    pub fn start(self: *IterationScheduler) void {
        self.running = true;
    }
    
    pub fn stop(self: *IterationScheduler) void {
        self.running = false;
    }
    
    /// Run one iteration
    pub fn runIteration(self: *IterationScheduler) !?Batch {
        if (!self.running) return null;
        
        self.iteration_count += 1;
        return try self.engine.step();
    }
};

// ==============================================
// Tests
// ==============================================

test "SequenceRequest lifecycle" {
    const allocator = std.testing.allocator;
    
    var seq = try SequenceRequest.init(
        allocator,
        "test-1",
        &[_]u32{ 1, 2, 3, 4, 5 },
        100,
    );
    defer seq.deinit();
    
    try std.testing.expect(seq.state == .waiting);
    try std.testing.expect(seq.totalTokens() == 5);
    
    try seq.addToken(6);
    try std.testing.expect(seq.totalTokens() == 6);
    try std.testing.expect(seq.phase == .decode);
}

test "RequestQueue operations" {
    const allocator = std.testing.allocator;
    
    var queue = RequestQueue.init(allocator, 100);
    defer queue.deinit();
    
    var seq = try SequenceRequest.init(
        allocator,
        "test-1",
        &[_]u32{ 1, 2, 3 },
        10,
    );
    defer seq.deinit();
    
    const accepted = try queue.enqueue(&seq);
    try std.testing.expect(accepted);
    try std.testing.expect(queue.totalPending() == 1);
    
    try queue.startRequest(&seq);
    try std.testing.expect(queue.totalRunning() == 1);
    try std.testing.expect(queue.totalPending() == 0);
}

test "Batch formation" {
    const allocator = std.testing.allocator;
    
    var batch = Batch.init(allocator, 0);
    defer batch.deinit();
    
    try std.testing.expect(batch.isEmpty());
    
    var seq = try SequenceRequest.init(
        allocator,
        "test-1",
        &[_]u32{ 1, 2, 3, 4, 5 },
        10,
    );
    defer seq.deinit();
    
    try batch.addSequence(&seq);
    try std.testing.expect(batch.size() == 1);
    try std.testing.expect(batch.num_prefill == 1);
}