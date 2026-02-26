//! ANWID Async GPU Pipeline
//! Overlaps CPU batch preparation, H2D transfer, GPU compute, and D2H transfer
//! Uses triple-buffered command buffers for continuous batching

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.async_pipeline);

// ============================================================================
// Async Pipeline Configuration
// ============================================================================

pub const AsyncPipelineConfig = struct {
    /// Number of command buffer slots (2-3 recommended)
    num_slots: usize = 3,
    /// Size of each slot's data buffer
    slot_buffer_size: usize = 4 * 1024 * 1024, // 4MB
    /// Max batch size per slot
    max_batch_size: usize = 512,
    /// Embedding dimension
    embedding_dim: usize = 768,
    /// Timeout for waiting on GPU completion (ms)
    completion_timeout_ms: u32 = 1000,
};

// ============================================================================
// Slot State
// ============================================================================

pub const SlotState = enum(u8) {
    /// Slot is free and can accept new work
    idle,
    /// CPU is filling the slot with input data
    cpu_filling,
    /// Data is being transferred host → device
    h2d_transfer,
    /// GPU is computing on this slot
    gpu_compute,
    /// Data is being transferred device → host
    d2h_transfer,
    /// Results are ready for CPU to read
    results_ready,
};

// ============================================================================
// Command Buffer Slot
// ============================================================================

pub const CommandSlot = struct {
    id: usize,
    state: std.atomic.Value(SlotState),
    
    // Input buffers (CPU-side)
    input_tokens: []u32,
    batch_size: std.atomic.Value(usize),
    
    // Output buffers (CPU-side)
    output_embeddings: []f32,
    
    // Timing for profiling
    submit_time_ns: std.atomic.Value(i64),
    complete_time_ns: std.atomic.Value(i64),
    h2d_time_ns: std.atomic.Value(i64),
    compute_time_ns: std.atomic.Value(i64),
    d2h_time_ns: std.atomic.Value(i64),
    
    // Completion signal
    completion_event: std.Thread.ResetEvent,
    
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, id: usize, config: AsyncPipelineConfig) !*CommandSlot {
        const slot = try allocator.create(CommandSlot);
        
        slot.* = .{
            .id = id,
            .state = std.atomic.Value(SlotState).init(.idle),
            .input_tokens = try allocator.alloc(u32, config.max_batch_size),
            .batch_size = std.atomic.Value(usize).init(0),
            .output_embeddings = try allocator.alloc(f32, config.max_batch_size * config.embedding_dim),
            .submit_time_ns = std.atomic.Value(i64).init(0),
            .complete_time_ns = std.atomic.Value(i64).init(0),
            .h2d_time_ns = std.atomic.Value(i64).init(0),
            .compute_time_ns = std.atomic.Value(i64).init(0),
            .d2h_time_ns = std.atomic.Value(i64).init(0),
            .completion_event = .{},
            .allocator = allocator,
        };
        
        return slot;
    }
    
    pub fn deinit(self: *CommandSlot) void {
        self.allocator.free(self.input_tokens);
        self.allocator.free(self.output_embeddings);
        self.allocator.destroy(self);
    }
    
    pub fn reset(self: *CommandSlot) void {
        self.state.store(.idle, .release);
        self.batch_size.store(0, .release);
        self.submit_time_ns.store(0, .release);
        self.complete_time_ns.store(0, .release);
        self.h2d_time_ns.store(0, .release);
        self.compute_time_ns.store(0, .release);
        self.d2h_time_ns.store(0, .release);
        self.completion_event.reset();
    }
    
    pub fn getLatency(self: *const CommandSlot) i64 {
        const submit = self.submit_time_ns.load(.acquire);
        const complete = self.complete_time_ns.load(.acquire);
        if (submit == 0 or complete == 0) return 0;
        return complete - submit;
    }
};

// ============================================================================
// Async Pipeline
// ============================================================================

pub const AsyncPipeline = struct {
    allocator: std.mem.Allocator,
    config: AsyncPipelineConfig,
    
    // Command slots
    slots: []?*CommandSlot,
    current_write_slot: std.atomic.Value(usize),
    current_read_slot: std.atomic.Value(usize),
    
    // GPU worker thread
    gpu_thread: ?std.Thread,
    shutdown: std.atomic.Value(bool),
    
    // Statistics
    batches_submitted: std.atomic.Value(u64),
    batches_completed: std.atomic.Value(u64),
    total_requests: std.atomic.Value(u64),
    total_latency_ns: std.atomic.Value(u64),
    
    pub fn init(allocator: std.mem.Allocator, config: AsyncPipelineConfig) !*AsyncPipeline {
        const pipeline = try allocator.create(AsyncPipeline);
        
        // Initialize slots
        const slots = try allocator.alloc(?*CommandSlot, config.num_slots);
        for (slots, 0..) |*slot, i| {
            slot.* = try CommandSlot.init(allocator, i, config);
        }
        
        pipeline.* = .{
            .allocator = allocator,
            .config = config,
            .slots = slots,
            .current_write_slot = std.atomic.Value(usize).init(0),
            .current_read_slot = std.atomic.Value(usize).init(0),
            .gpu_thread = null,
            .shutdown = std.atomic.Value(bool).init(false),
            .batches_submitted = std.atomic.Value(u64).init(0),
            .batches_completed = std.atomic.Value(u64).init(0),
            .total_requests = std.atomic.Value(u64).init(0),
            .total_latency_ns = std.atomic.Value(u64).init(0),
        };
        
        log.info("Async Pipeline initialized:", .{});
        log.info("  Slots: {}", .{config.num_slots});
        log.info("  Buffer size: {} KB", .{config.slot_buffer_size / 1024});
        log.info("  Max batch: {}", .{config.max_batch_size});
        
        return pipeline;
    }
    
    pub fn deinit(self: *AsyncPipeline) void {
        // Signal shutdown
        self.shutdown.store(true, .release);
        
        // Wait for GPU thread
        if (self.gpu_thread) |thread| {
            thread.join();
        }
        
        // Free slots
        for (self.slots) |maybe_slot| {
            if (maybe_slot) |slot| slot.deinit();
        }
        self.allocator.free(self.slots);
        
        self.allocator.destroy(self);
        log.info("Async Pipeline destroyed", .{});
    }
    
    /// Start the GPU worker thread
    pub fn start(self: *AsyncPipeline) !void {
        self.gpu_thread = try std.Thread.spawn(.{}, gpuWorkerLoop, .{self});
        log.info("GPU worker thread started", .{});
    }
    
    /// Submit a batch for async processing
    pub fn submitBatch(self: *AsyncPipeline, tokens: []const u32) !*CommandSlot {
        const start_idx = self.current_write_slot.load(.acquire);
        var chosen: ?*CommandSlot = null;
        var chosen_idx: usize = start_idx;

        for (0..self.config.num_slots) |offset| {
            const idx = (start_idx + offset) % self.config.num_slots;
            const slot = self.slots[idx] orelse continue;
            const state = slot.state.load(.acquire);
            if (state == .idle or state == .results_ready) {
                chosen = slot;
                chosen_idx = idx;
                break;
            }
        }

        const slot = chosen orelse return error.SlotBusy;
        
        // Reset and fill slot
        slot.reset();
        slot.state.store(.cpu_filling, .release);
        
        const batch_size = @min(tokens.len, self.config.max_batch_size);
        @memcpy(slot.input_tokens[0..batch_size], tokens[0..batch_size]);
        slot.batch_size.store(batch_size, .release);
        
        slot.submit_time_ns.store(@intCast(std.time.nanoTimestamp()), .release);
        slot.state.store(.h2d_transfer, .release);
        
        // Advance write slot
        self.current_write_slot.store((chosen_idx + 1) % self.config.num_slots, .release);
        _ = self.batches_submitted.fetchAdd(1, .monotonic);
        
        return slot;
    }
    
    /// Wait for a specific slot to complete
    pub fn waitForSlot(self: *AsyncPipeline, slot: *CommandSlot) !void {
        // Wait with timeout
        const timeout_ns: u64 = @as(u64, self.config.completion_timeout_ms) * std.time.ns_per_ms;
        slot.completion_event.timedWait(timeout_ns) catch {
            return error.Timeout;
        };
        
        if (slot.state.load(.acquire) != .results_ready) {
            return error.SlotNotReady;
        }
    }
    
    /// GPU worker thread main loop
    fn gpuWorkerLoop(self: *AsyncPipeline) void {
        log.info("GPU worker entering main loop", .{});
        
        while (!self.shutdown.load(.acquire)) {
            // Process all ready slots
            var processed_any = false;
            
            for (self.slots) |maybe_slot| {
                if (maybe_slot) |slot| {
                    switch (slot.state.load(.acquire)) {
                        .h2d_transfer => {
                            // Simulate H2D transfer
                            const h2d_start = std.time.nanoTimestamp();

                            // In real impl, would use Metal blit encoder
                            std.atomic.spinLoopHint();

                            slot.h2d_time_ns.store(@intCast(std.time.nanoTimestamp() - h2d_start), .release);
                            slot.state.store(.gpu_compute, .release);
                            processed_any = true;
                        },
                        .gpu_compute => {
                            // Execute GPU kernel
                            const compute_start = std.time.nanoTimestamp();

                            const batch_size = slot.batch_size.load(.acquire);
                            const embedding_dim = self.config.embedding_dim;

                            // Compute embeddings (simplified)
                            for (0..batch_size) |b| {
                                const token = slot.input_tokens[b];
                                for (0..embedding_dim) |d| {
                                    const idx = b * embedding_dim + d;
                                    const seed = @as(f32, @floatFromInt(token)) * 0.001;
                                    slot.output_embeddings[idx] = @sin(seed + @as(f32, @floatFromInt(d)) * 0.01);
                                }
                            }

                            slot.compute_time_ns.store(@intCast(std.time.nanoTimestamp() - compute_start), .release);
                            slot.state.store(.d2h_transfer, .release);
                            processed_any = true;
                        },
                        .d2h_transfer => {
                            // Simulate D2H transfer
                            const d2h_start = std.time.nanoTimestamp();

                            // In real impl, would wait for Metal command buffer completion
                            std.atomic.spinLoopHint();

                            slot.d2h_time_ns.store(@intCast(std.time.nanoTimestamp() - d2h_start), .release);
                            slot.complete_time_ns.store(@intCast(std.time.nanoTimestamp()), .release);
                            slot.state.store(.results_ready, .release);

                            // Signal completion
                            slot.completion_event.set();

                            // Update stats
                            const completed_batch_size = slot.batch_size.load(.acquire);
                            _ = self.batches_completed.fetchAdd(1, .monotonic);
                            _ = self.total_requests.fetchAdd(completed_batch_size, .monotonic);
                            _ = self.total_latency_ns.fetchAdd(@intCast(slot.getLatency()), .monotonic);

                            processed_any = true;
                        },
                        else => {},
                    }
                }
            }
            
            if (!processed_any) {
                std.time.sleep(1 * std.time.ns_per_ms);
            }
        }
        
        log.info("GPU worker exiting", .{});
    }
    
    /// Get pipeline statistics
    pub fn getStats(self: *const AsyncPipeline) PipelineStats {
        const completed = self.batches_completed.load(.acquire);
        const latency = self.total_latency_ns.load(.acquire);
        
        return .{
            .batches_submitted = self.batches_submitted.load(.acquire),
            .batches_completed = completed,
            .total_requests = self.total_requests.load(.acquire),
            .total_latency_ns = latency,
            .avg_latency_ns = if (completed > 0) latency / completed else 0,
            .slots_in_use = blk: {
                var count: usize = 0;
                for (self.slots) |maybe_slot| {
                    if (maybe_slot) |slot| {
                        const state = slot.state.load(.acquire);
                        if (state != .idle) count += 1;
                    }
                }
                break :blk count;
            },
        };
    }
};

pub const PipelineStats = struct {
    batches_submitted: u64,
    batches_completed: u64,
    total_requests: u64,
    total_latency_ns: u64,
    avg_latency_ns: u64,
    slots_in_use: usize,
};

// ============================================================================
// Tests
// ============================================================================

test "AsyncPipeline init and deinit" {
    const pipeline = try AsyncPipeline.init(std.testing.allocator, .{});
    defer pipeline.deinit();
    
    const stats = pipeline.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.batches_submitted);
}

test "CommandSlot state transitions" {
    const slot = try CommandSlot.init(std.testing.allocator, 0, .{});
    defer slot.deinit();
    
    try std.testing.expectEqual(SlotState.idle, slot.state.load(.acquire));
    
    slot.state.store(.cpu_filling, .release);
    try std.testing.expectEqual(SlotState.cpu_filling, slot.state.load(.acquire));
    
    slot.reset();
    try std.testing.expectEqual(SlotState.idle, slot.state.load(.acquire));
}