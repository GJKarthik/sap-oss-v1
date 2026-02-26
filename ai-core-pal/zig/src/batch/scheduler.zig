//! ANWID Batch Scheduler
//! Continuous batching for GPU inference with adaptive batch sizing

const std = @import("std");
const broker = @import("../broker/broker.zig");
const memory_pool = @import("../gpu/memory_pool.zig");
const kernels = @import("../gpu/kernels.zig");

const log = std.log.scoped(.batch_scheduler);

// ============================================================================
// Batch Configuration
// ============================================================================

pub const BatchConfig = struct {
    /// Maximum batch size
    max_batch_size: usize = 1024,
    /// Minimum batch size before forcing dispatch
    min_batch_size: usize = 1,
    /// Maximum wait time before dispatching partial batch (ms)
    max_wait_ms: u64 = 1,
    /// Enable adaptive batch sizing
    adaptive_sizing: bool = true,
    /// Target GPU utilization (0.0-1.0)
    target_gpu_utilization: f32 = 0.95,
};

// ============================================================================
// Request Item
// ============================================================================

pub const RequestItem = struct {
    /// Unique request ID
    id: u64,
    /// Request type
    request_type: RequestType,
    /// Input data pointer
    input_data: []const f32,
    /// Timestamp when request arrived
    arrival_time: i64,
    /// Correlation ID for response matching
    correlation_id: u64,
    
    pub const RequestType = enum {
        embed,
        chat,
        search,
        completion,
    };
};

// ============================================================================
// Batch
// ============================================================================

pub const Batch = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(RequestItem),
    created_at: i64,
    batch_id: u64,
    
    pub fn init(allocator: std.mem.Allocator, batch_id: u64) Batch {
        return .{
            .allocator = allocator,
            .items = .{},
            .created_at = std.time.milliTimestamp(),
            .batch_id = batch_id,
        };
    }
    
    pub fn deinit(self: *Batch) void {
        self.items.deinit(self.allocator);
    }
    
    pub fn add(self: *Batch, item: RequestItem) !void {
        try self.items.append(self.allocator, item);
    }
    
    pub fn size(self: *const Batch) usize {
        return self.items.items.len;
    }
    
    pub fn ageMs(self: *const Batch) i64 {
        return std.time.milliTimestamp() - self.created_at;
    }
    
    pub fn clear(self: *Batch) void {
        self.items.clearRetainingCapacity();
        self.created_at = std.time.milliTimestamp();
    }
};

// ============================================================================
// Batch Scheduler
// ============================================================================

pub const BatchScheduler = struct {
    allocator: std.mem.Allocator,
    config: BatchConfig,
    
    // Current batch being filled
    current_batch: ?*Batch,
    batch_lock: std.Thread.Mutex,
    
    // Batch ID generator
    next_batch_id: std.atomic.Value(u64),
    
    // Memory pool for GPU transfers
    memory_pool: ?*memory_pool.GpuMemoryPool,
    
    // Kernel dispatcher
    kernel_dispatcher: ?*kernels.KernelDispatcher,
    
    // Statistics
    batches_formed: std.atomic.Value(u64),
    batches_dispatched: std.atomic.Value(u64),
    requests_processed: std.atomic.Value(u64),
    total_wait_time_ms: std.atomic.Value(u64),
    
    // Adaptive sizing state
    current_optimal_batch_size: std.atomic.Value(usize),
    gpu_utilization_estimate: std.atomic.Value(u32), // Fixed-point 0-100
    
    pub fn init(
        allocator: std.mem.Allocator,
        config: BatchConfig,
        pool: ?*memory_pool.GpuMemoryPool,
        dispatcher: ?*kernels.KernelDispatcher,
    ) !*BatchScheduler {
        const scheduler = try allocator.create(BatchScheduler);
        scheduler.* = .{
            .allocator = allocator,
            .config = config,
            .current_batch = null,
            .batch_lock = .{},
            .next_batch_id = std.atomic.Value(u64).init(1),
            .memory_pool = pool,
            .kernel_dispatcher = dispatcher,
            .batches_formed = std.atomic.Value(u64).init(0),
            .batches_dispatched = std.atomic.Value(u64).init(0),
            .requests_processed = std.atomic.Value(u64).init(0),
            .total_wait_time_ms = std.atomic.Value(u64).init(0),
            .current_optimal_batch_size = std.atomic.Value(usize).init(config.max_batch_size / 2),
            .gpu_utilization_estimate = std.atomic.Value(u32).init(0),
        };
        
        log.info("Batch Scheduler initialized:", .{});
        log.info("  Max batch size: {}", .{config.max_batch_size});
        log.info("  Max wait: {}ms", .{config.max_wait_ms});
        log.info("  Adaptive sizing: {}", .{config.adaptive_sizing});
        
        return scheduler;
    }
    
    pub fn deinit(self: *BatchScheduler) void {
        self.batch_lock.lock();
        if (self.current_batch) |batch| {
            batch.deinit();
            self.allocator.destroy(batch);
        }
        self.batch_lock.unlock();
        
        self.allocator.destroy(self);
        log.info("Batch Scheduler destroyed", .{});
    }
    
    /// Submit a request to the scheduler
    pub fn submit(self: *BatchScheduler, item: RequestItem) !void {
        self.batch_lock.lock();
        defer self.batch_lock.unlock();
        
        // Create batch if needed
        if (self.current_batch == null) {
            const batch_id = self.next_batch_id.fetchAdd(1, .monotonic);
            const batch = try self.allocator.create(Batch);
            batch.* = Batch.init(self.allocator, batch_id);
            self.current_batch = batch;
        }
        
        try self.current_batch.?.add(item);
    }
    
    /// Check if current batch is ready for dispatch
    pub fn batchReady(self: *BatchScheduler) bool {
        self.batch_lock.lock();
        defer self.batch_lock.unlock();
        
        const batch = self.current_batch orelse return false;
        
        const optimal_size = if (self.config.adaptive_sizing)
            self.current_optimal_batch_size.load(.acquire)
        else
            self.config.max_batch_size;
        
        // Size threshold
        if (batch.size() >= optimal_size) {
            return true;
        }
        
        // Time threshold
        if (batch.size() >= self.config.min_batch_size and
            batch.ageMs() >= @as(i64, @intCast(self.config.max_wait_ms)))
        {
            return true;
        }
        
        return false;
    }
    
    /// Dispatch the current batch for processing
    pub fn dispatchBatch(self: *BatchScheduler) ?*Batch {
        self.batch_lock.lock();
        defer self.batch_lock.unlock();
        
        const batch = self.current_batch orelse return null;
        if (batch.size() == 0) return null;
        
        // Record stats
        _ = self.batches_formed.fetchAdd(1, .monotonic);
        _ = self.total_wait_time_ms.fetchAdd(@intCast(batch.ageMs()), .monotonic);
        
        // Create new batch for future requests
        const batch_id = self.next_batch_id.fetchAdd(1, .monotonic);
        const new_batch = self.allocator.create(Batch) catch return null;
        new_batch.* = Batch.init(self.allocator, batch_id);
        
        self.current_batch = new_batch;
        
        return batch;
    }
    
    /// Process a batch (CPU simulation or GPU dispatch)
    pub fn processBatch(self: *BatchScheduler, batch: *Batch) !void {
        const start = std.time.nanoTimestamp();
        
        // Get memory pool slot if available
        if (self.memory_pool) |pool| {
            if (pool.acquireWriteSlot()) |slot| {
                defer pool.releaseSlot(slot);
                
                // Serialize batch to slot
                if (slot.getWritePtr()) |write_buf| {
                    // Write batch data to buffer
                    const data_size = self.serializeBatchToBuffer(batch, write_buf);
                    slot.commitWrite(batch.size(), data_size);
                    
                    // Transfer to GPU
                    try pool.transferToGpu(slot);
                    
                    // Execute kernel
                    if (self.kernel_dispatcher) |dispatcher| {
                        const input = std.mem.bytesAsSlice(f32, write_buf[0..data_size]);
                        var output: [1024]f32 = undefined;
                        
                        const result = dispatcher.dispatch(
                            .embedding,
                            .{ .batch_size = batch.size(), .hidden_size = 768 },
                            input,
                            &output,
                        );
                        
                        if (result.success) {
                            log.debug("Kernel completed: {} elements in {}ns", .{
                                result.elements_processed,
                                result.execution_time_ns,
                            });
                        }
                    }
                    
                    slot.state = .gpu_complete;
                }
            }
        }
        
        const elapsed = std.time.nanoTimestamp() - start;
        _ = self.batches_dispatched.fetchAdd(1, .monotonic);
        _ = self.requests_processed.fetchAdd(batch.size(), .monotonic);
        
        // Update adaptive batch size
        if (self.config.adaptive_sizing) {
            self.updateAdaptiveBatchSize(batch.size(), elapsed);
        }
        
        log.debug("Batch {} processed: {} items in {}us", .{
            batch.batch_id,
            batch.size(),
            @divTrunc(elapsed, 1000),
        });
    }
    
    fn serializeBatchToBuffer(self: *BatchScheduler, batch: *Batch, buffer: []u8) usize {
        _ = self;
        // Simple serialization: pack f32 data sequentially
        var offset: usize = 0;
        const f32_buf = std.mem.bytesAsSlice(f32, buffer);
        
        for (batch.items.items) |item| {
            for (item.input_data) |val| {
                if (offset / @sizeOf(f32) < f32_buf.len) {
                    f32_buf[offset / @sizeOf(f32)] = val;
                    offset += @sizeOf(f32);
                }
            }
        }
        
        return offset;
    }
    
    fn updateAdaptiveBatchSize(self: *BatchScheduler, batch_size: usize, exec_time_ns: i128) void {
        // Estimate GPU utilization based on execution time
        const target_exec_ns: i128 = 1_000_000; // 1ms target
        const utilization_pct: u32 = @intCast(@min(100, @divTrunc(exec_time_ns * 100, target_exec_ns)));
        
        self.gpu_utilization_estimate.store(utilization_pct, .release);
        
        // Adjust batch size based on utilization
        const current_optimal = self.current_optimal_batch_size.load(.acquire);
        var new_optimal = current_optimal;
        
        if (utilization_pct < 80 and batch_size == current_optimal) {
            // GPU underutilized, increase batch size
            new_optimal = @min(self.config.max_batch_size, current_optimal + current_optimal / 4);
        } else if (utilization_pct > 95) {
            // GPU saturated, decrease batch size slightly
            new_optimal = @max(self.config.min_batch_size, current_optimal - current_optimal / 8);
        }
        
        if (new_optimal != current_optimal) {
            self.current_optimal_batch_size.store(new_optimal, .release);
            log.debug("Adaptive batch size: {} -> {} (GPU util {}%)", .{
                current_optimal,
                new_optimal,
                utilization_pct,
            });
        }
    }
    
    /// Get scheduler statistics
    pub fn getStats(self: *const BatchScheduler) SchedulerStats {
        const formed = self.batches_formed.load(.acquire);
        const wait_time = self.total_wait_time_ms.load(.acquire);
        
        return .{
            .batches_formed = formed,
            .batches_dispatched = self.batches_dispatched.load(.acquire),
            .requests_processed = self.requests_processed.load(.acquire),
            .avg_wait_time_ms = if (formed > 0) wait_time / formed else 0,
            .current_optimal_batch_size = self.current_optimal_batch_size.load(.acquire),
            .gpu_utilization_pct = self.gpu_utilization_estimate.load(.acquire),
        };
    }
};

pub const SchedulerStats = struct {
    batches_formed: u64,
    batches_dispatched: u64,
    requests_processed: u64,
    avg_wait_time_ms: u64,
    current_optimal_batch_size: usize,
    gpu_utilization_pct: u32,
};

// ============================================================================
// Tests
// ============================================================================

test "Batch init and add" {
    var batch = Batch.init(std.testing.allocator, 1);
    defer batch.deinit();
    
    try batch.add(.{
        .id = 1,
        .request_type = .embed,
        .input_data = &[_]f32{ 1.0, 2.0 },
        .arrival_time = std.time.milliTimestamp(),
        .correlation_id = 100,
    });
    
    try std.testing.expectEqual(@as(usize, 1), batch.size());
}

test "BatchScheduler init and deinit" {
    const scheduler = try BatchScheduler.init(std.testing.allocator, .{}, null, null);
    defer scheduler.deinit();
    
    const stats = scheduler.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.batches_formed);
}

test "BatchScheduler submit and dispatch" {
    const scheduler = try BatchScheduler.init(std.testing.allocator, .{
        .max_batch_size = 2,
        .max_wait_ms = 100,
    }, null, null);
    defer scheduler.deinit();
    
    try scheduler.submit(.{
        .id = 1,
        .request_type = .embed,
        .input_data = &[_]f32{ 1.0 },
        .arrival_time = std.time.milliTimestamp(),
        .correlation_id = 1,
    });
    
    try std.testing.expect(!scheduler.batchReady());
    
    try scheduler.submit(.{
        .id = 2,
        .request_type = .embed,
        .input_data = &[_]f32{ 2.0 },
        .arrival_time = std.time.milliTimestamp(),
        .correlation_id = 2,
    });
    
    try std.testing.expect(scheduler.batchReady());
    
    if (scheduler.dispatchBatch()) |batch| {
        defer {
            batch.deinit();
            scheduler.allocator.destroy(batch);
        }
        try std.testing.expectEqual(@as(usize, 2), batch.size());
    }
}