//! Batch Scheduler - Phase 1 Optimization
//!
//! Dynamic batching to maximize GPU utilization.
//! Collects requests over a time window, forms optimal batches.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Mutex = Thread.Mutex;

// ============================================================================
// Configuration
// ============================================================================

pub const BatchConfig = struct {
    /// Maximum batch size
    max_batch_size: usize = 64,
    
    /// Minimum batch size before processing (unless timeout)
    min_batch_size: usize = 1,
    
    /// Maximum wait time in milliseconds before processing partial batch
    max_wait_ms: u64 = 50,
    
    /// Maximum sequence length in batch
    max_seq_len: usize = 4096,
    
    /// Maximum total tokens per batch (for memory planning)
    max_batch_tokens: usize = 64 * 4096,
    
    /// Enable continuous batching (add/remove sequences mid-batch)
    continuous_batching: bool = true,
    
    /// Priority queue enabled
    priority_enabled: bool = false,
};

// ============================================================================
// Request
// ============================================================================

pub const Request = struct {
    /// Unique request ID
    id: u64,
    
    /// Input token IDs
    tokens: []const u32,
    
    /// Maximum tokens to generate
    max_new_tokens: usize,
    
    /// Current position in generation
    position: usize,
    
    /// Priority (lower = higher priority)
    priority: u8,
    
    /// Timestamp when request was received (ns)
    arrival_time: i128,
    
    /// Callback for streaming output
    callback: ?*const fn (u64, u32) void,
    
    /// Is this request complete?
    done: bool,
    
    pub fn init(id: u64, tokens: []const u32, max_new_tokens: usize) Request {
        return .{
            .id = id,
            .tokens = tokens,
            .max_new_tokens = max_new_tokens,
            .position = 0,
            .priority = 128, // default priority
            .arrival_time = std.time.nanoTimestamp(),
            .callback = null,
            .done = false,
        };
    }
    
    pub fn totalTokens(self: *const Request) usize {
        return self.tokens.len + self.position;
    }
    
    pub fn remainingTokens(self: *const Request) usize {
        if (self.position >= self.max_new_tokens) return 0;
        return self.max_new_tokens - self.position;
    }
};

// ============================================================================
// Batch
// ============================================================================

pub const Batch = struct {
    /// Requests in this batch
    requests: std.ArrayList(*Request),
    
    /// Padded input tensor (batch_size x max_seq_len)
    input_ids: []u32,
    
    /// Attention mask (batch_size x max_seq_len)
    attention_mask: []u8,
    
    /// Position IDs (batch_size x max_seq_len)
    position_ids: []u32,
    
    /// Sequence lengths for each request
    seq_lens: []usize,
    
    /// Maximum sequence length in batch
    max_seq_len: usize,
    
    /// Allocator
    allocator: Allocator,
    
    pub fn init(allocator: Allocator, max_batch_size: usize, max_seq_len: usize) !Batch {
        const total_size = max_batch_size * max_seq_len;
        
        return .{
            .requests = std.ArrayList(*Request).init(allocator),
            .input_ids = try allocator.alloc(u32, total_size),
            .attention_mask = try allocator.alloc(u8, total_size),
            .position_ids = try allocator.alloc(u32, total_size),
            .seq_lens = try allocator.alloc(usize, max_batch_size),
            .max_seq_len = 0,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Batch) void {
        self.requests.deinit();
        self.allocator.free(self.input_ids);
        self.allocator.free(self.attention_mask);
        self.allocator.free(self.position_ids);
        self.allocator.free(self.seq_lens);
    }
    
    pub fn clear(self: *Batch) void {
        self.requests.clearRetainingCapacity();
        self.max_seq_len = 0;
    }
    
    pub fn size(self: *const Batch) usize {
        return self.requests.items.len;
    }
    
    /// Add a request to the batch
    pub fn addRequest(self: *Batch, request: *Request) !void {
        try self.requests.append(request);
        const seq_len = request.totalTokens();
        self.seq_lens[self.requests.items.len - 1] = seq_len;
        self.max_seq_len = @max(self.max_seq_len, seq_len);
    }
    
    /// Prepare batch tensors (pad sequences, create masks)
    pub fn prepare(self: *Batch) void {
        const batch_size = self.requests.items.len;
        
        // Zero out tensors
        @memset(self.input_ids[0..batch_size * self.max_seq_len], 0);
        @memset(self.attention_mask[0..batch_size * self.max_seq_len], 0);
        
        // Fill in data for each request
        for (self.requests.items, 0..) |request, batch_idx| {
            const offset = batch_idx * self.max_seq_len;
            const seq_len = request.tokens.len;
            
            // Copy tokens
            for (request.tokens, 0..) |token, i| {
                self.input_ids[offset + i] = token;
            }
            
            // Set attention mask (1 for real tokens)
            for (0..seq_len) |i| {
                self.attention_mask[offset + i] = 1;
            }
            
            // Set position IDs
            for (0..seq_len) |i| {
                self.position_ids[offset + i] = @intCast(i);
            }
        }
    }
    
    /// Remove completed requests
    pub fn removeCompleted(self: *Batch) usize {
        var removed: usize = 0;
        var i: usize = 0;
        
        while (i < self.requests.items.len) {
            if (self.requests.items[i].done) {
                _ = self.requests.orderedRemove(i);
                removed += 1;
            } else {
                i += 1;
            }
        }
        
        return removed;
    }
};

// ============================================================================
// Batch Scheduler
// ============================================================================

pub const BatchScheduler = struct {
    const Self = @This();
    
    /// Configuration
    config: BatchConfig,
    
    /// Pending requests queue
    pending: std.ArrayList(*Request),
    
    /// Active batch being processed
    active_batch: ?*Batch,
    
    /// Mutex for thread safety
    mutex: Mutex,
    
    /// Request ID counter
    next_id: u64,
    
    /// Statistics
    stats: SchedulerStats,
    
    /// Allocator
    allocator: Allocator,
    
    /// Last batch formation time
    last_batch_time: i128,
    
    pub const SchedulerStats = struct {
        total_requests: u64 = 0,
        total_batches: u64 = 0,
        total_tokens_processed: u64 = 0,
        avg_batch_size: f32 = 0.0,
        avg_wait_time_ms: f32 = 0.0,
        throughput_tokens_per_sec: f32 = 0.0,
    };
    
    pub fn init(allocator: Allocator, config: BatchConfig) !Self {
        return .{
            .config = config,
            .pending = std.ArrayList(*Request).init(allocator),
            .active_batch = null,
            .mutex = .{},
            .next_id = 1,
            .stats = .{},
            .allocator = allocator,
            .last_batch_time = std.time.nanoTimestamp(),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.pending.deinit();
        if (self.active_batch) |batch| {
            batch.deinit();
            self.allocator.destroy(batch);
        }
    }
    
    /// Submit a new request
    pub fn submit(self: *Self, tokens: []const u32, max_new_tokens: usize) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const id = self.next_id;
        self.next_id += 1;
        
        const request = try self.allocator.create(Request);
        request.* = Request.init(id, tokens, max_new_tokens);
        
        try self.pending.append(request);
        self.stats.total_requests += 1;
        
        return id;
    }
    
    /// Check if batch is ready to process
    pub fn batchReady(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Have enough requests?
        if (self.pending.items.len >= self.config.max_batch_size) {
            return true;
        }
        
        // Waited long enough?
        if (self.pending.items.len >= self.config.min_batch_size) {
            const now = std.time.nanoTimestamp();
            const elapsed_ms = @divFloor(now - self.last_batch_time, 1_000_000);
            if (elapsed_ms >= @as(i128, self.config.max_wait_ms)) {
                return true;
            }
        }
        
        return false;
    }
    
    /// Form a batch from pending requests
    pub fn formBatch(self: *Self) !?*Batch {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.pending.items.len == 0) return null;
        
        // Create batch
        var batch = try self.allocator.create(Batch);
        batch.* = try Batch.init(
            self.allocator,
            self.config.max_batch_size,
            self.config.max_seq_len,
        );
        
        // Select requests for batch (greedy by arrival time)
        var total_tokens: usize = 0;
        var i: usize = 0;
        
        while (i < self.pending.items.len and batch.size() < self.config.max_batch_size) {
            const request = self.pending.items[i];
            const request_tokens = request.totalTokens();
            
            // Check if adding this request exceeds token budget
            if (total_tokens + request_tokens > self.config.max_batch_tokens) {
                i += 1;
                continue;
            }
            
            // Add to batch
            try batch.addRequest(request);
            total_tokens += request_tokens;
            
            // Remove from pending
            _ = self.pending.orderedRemove(i);
        }
        
        // Prepare batch tensors
        batch.prepare();
        
        // Update stats
        self.stats.total_batches += 1;
        const batch_count = @as(f32, @floatFromInt(self.stats.total_batches));
        self.stats.avg_batch_size = (self.stats.avg_batch_size * (batch_count - 1) + @as(f32, @floatFromInt(batch.size()))) / batch_count;
        
        self.last_batch_time = std.time.nanoTimestamp();
        self.active_batch = batch;
        
        return batch;
    }
    
    /// Mark tokens as generated for continuous batching
    pub fn advanceBatch(self: *Self, generated_tokens: []const u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.active_batch) |batch| {
            for (batch.requests.items, 0..) |request, i| {
                if (i < generated_tokens.len) {
                    const token = generated_tokens[i];
                    request.position += 1;
                    
                    // Check if done (EOS or max tokens)
                    if (token == 2 or request.position >= request.max_new_tokens) { // EOS token = 2
                        request.done = true;
                    }
                    
                    // Callback for streaming
                    if (request.callback) |cb| {
                        cb(request.id, token);
                    }
                    
                    self.stats.total_tokens_processed += 1;
                }
            }
            
            // Remove completed requests if continuous batching
            if (self.config.continuous_batching) {
                _ = batch.removeCompleted();
                
                // Add new requests to batch if space available
                while (batch.size() < self.config.max_batch_size and self.pending.items.len > 0) {
                    const request = self.pending.orderedRemove(0);
                    batch.addRequest(request) catch break;
                }
            }
        }
    }
    
    /// Release the current batch
    pub fn releaseBatch(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.active_batch) |batch| {
            batch.deinit();
            self.allocator.destroy(batch);
            self.active_batch = null;
        }
    }
    
    /// Get scheduler statistics
    pub fn getStats(self: *const Self) SchedulerStats {
        return self.stats;
    }
    
    /// Get pending request count
    pub fn pendingCount(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.pending.items.len;
    }
};

// ============================================================================
// Global Scheduler Instance
// ============================================================================

var g_scheduler: ?BatchScheduler = null;

pub fn getGlobalScheduler() !*BatchScheduler {
    if (g_scheduler == null) {
        g_scheduler = try BatchScheduler.init(std.heap.page_allocator, .{});
    }
    return &g_scheduler.?;
}

pub fn shutdownGlobalScheduler() void {
    if (g_scheduler) |*scheduler| {
        scheduler.deinit();
        g_scheduler = null;
    }
}

// ============================================================================
// Tests
// ============================================================================

test "batch scheduler basic" {
    var scheduler = try BatchScheduler.init(std.testing.allocator, .{
        .max_batch_size = 4,
        .min_batch_size = 2,
        .max_wait_ms = 10,
    });
    defer scheduler.deinit();
    
    // Submit requests
    const tokens = [_]u32{ 1, 2, 3, 4, 5 };
    _ = try scheduler.submit(&tokens, 10);
    _ = try scheduler.submit(&tokens, 10);
    
    try std.testing.expectEqual(@as(usize, 2), scheduler.pendingCount());
    
    // Wait for batch timeout
    std.time.sleep(15 * std.time.ns_per_ms);
    
    try std.testing.expect(scheduler.batchReady());
    
    // Form batch
    if (try scheduler.formBatch()) |batch| {
        try std.testing.expectEqual(@as(usize, 2), batch.size());
        scheduler.releaseBatch();
    }
}