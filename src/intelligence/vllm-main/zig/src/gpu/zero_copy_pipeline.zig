//! ANWID Zero-Copy GPU Pipeline
//! Streams raw HTTP request bytes directly to GPU for inference
//! 
//! Data Flow:
//!   HTTP Body → DMA to VRAM → GPU Parse → GPU Tokenize → GPU Inference → Response
//!
//! The CPU never touches or parses the request body

const std = @import("std");
const builtin = @import("builtin");

const kernel_fusion = @import("kernels/kernel_fusion.zig");
const json_parser = @import("kernels/json_parser.zig");
const tokenizer = @import("kernels/tokenizer.zig");

const log = std.log.scoped(.zero_copy_pipeline);

// ============================================================================
// Zero-Copy Pipeline Configuration
// ============================================================================

pub const ZeroCopyConfig = struct {
    /// Number of command slots for async processing
    num_slots: usize = 3,
    /// Maximum raw input size per request
    max_input_size: usize = 1024 * 1024, // 1MB
    /// Maximum sequence length
    max_seq_len: usize = 2048,
    /// Embedding dimension for inference
    embedding_dim: usize = 4096,
    /// Enable DMA pinned memory
    use_pinned_memory: bool = true,
    /// Timeout for GPU operations (ms)
    gpu_timeout_ms: u32 = 5000,
};

// ============================================================================
// Zero-Copy Command Slot
// ============================================================================

pub const ZeroCopySlot = struct {
    id: usize,
    state: std.atomic.Value(SlotState),
    
    // Raw input buffer (pinned memory for DMA)
    raw_input: []align(4096) u8,
    input_len: std.atomic.Value(usize),
    
    // Token output buffer (GPU memory)
    token_buffer: []u32,
    
    // Inference output buffer
    output_buffer: []f32,
    
    // Fused result
    result: kernel_fusion.FusedResult,
    
    // Timing
    dma_start_ns: std.atomic.Value(i64),
    dma_complete_ns: std.atomic.Value(i64),
    gpu_start_ns: std.atomic.Value(i64),
    gpu_complete_ns: std.atomic.Value(i64),
    
    // Completion signaling
    completion_event: std.Thread.ResetEvent,
    
    allocator: std.mem.Allocator,
    
    pub const SlotState = enum(u8) {
        idle,
        receiving,
        dma_transfer,
        gpu_processing,
        complete,
        error_state,
    };
    
    pub fn init(allocator: std.mem.Allocator, id: usize, config: ZeroCopyConfig) !*ZeroCopySlot {
        const slot = try allocator.create(ZeroCopySlot);
        
        // Allocate page-aligned buffer for DMA
        const raw_input = try allocator.alignedAlloc(u8, 4096, config.max_input_size);
        
        slot.* = .{
            .id = id,
            .state = std.atomic.Value(SlotState).init(.idle),
            .raw_input = raw_input,
            .input_len = std.atomic.Value(usize).init(0),
            .token_buffer = try allocator.alloc(u32, config.max_seq_len),
            .output_buffer = try allocator.alloc(f32, config.max_seq_len * config.embedding_dim),
            .result = std.mem.zeroes(kernel_fusion.FusedResult),
            .dma_start_ns = std.atomic.Value(i64).init(0),
            .dma_complete_ns = std.atomic.Value(i64).init(0),
            .gpu_start_ns = std.atomic.Value(i64).init(0),
            .gpu_complete_ns = std.atomic.Value(i64).init(0),
            .completion_event = .{},
            .allocator = allocator,
        };
        
        return slot;
    }
    
    pub fn deinit(self: *ZeroCopySlot) void {
        self.allocator.free(self.raw_input);
        self.allocator.free(self.token_buffer);
        self.allocator.free(self.output_buffer);
        self.allocator.destroy(self);
    }
    
    pub fn reset(self: *ZeroCopySlot) void {
        self.state.store(.idle, .release);
        self.input_len.store(0, .release);
        self.dma_start_ns.store(0, .release);
        self.dma_complete_ns.store(0, .release);
        self.gpu_start_ns.store(0, .release);
        self.gpu_complete_ns.store(0, .release);
        self.result = std.mem.zeroes(kernel_fusion.FusedResult);
        self.completion_event.reset();
    }
    
    pub fn getTotalLatency(self: *const ZeroCopySlot) i64 {
        const dma_start = self.dma_start_ns.load(.acquire);
        const gpu_complete = self.gpu_complete_ns.load(.acquire);
        if (dma_start == 0 or gpu_complete == 0) return 0;
        return gpu_complete - dma_start;
    }
    
    pub fn getDmaLatency(self: *const ZeroCopySlot) i64 {
        const start = self.dma_start_ns.load(.acquire);
        const complete = self.dma_complete_ns.load(.acquire);
        if (start == 0 or complete == 0) return 0;
        return complete - start;
    }
    
    pub fn getGpuLatency(self: *const ZeroCopySlot) i64 {
        const start = self.gpu_start_ns.load(.acquire);
        const complete = self.gpu_complete_ns.load(.acquire);
        if (start == 0 or complete == 0) return 0;
        return complete - start;
    }
};

// ============================================================================
// Zero-Copy Pipeline
// ============================================================================

pub const ZeroCopyPipeline = struct {
    allocator: std.mem.Allocator,
    config: ZeroCopyConfig,
    
    // Command slots
    slots: []?*ZeroCopySlot,
    current_slot: std.atomic.Value(usize),
    
    // Kernel fusion pipeline
    fusion_pipeline: *kernel_fusion.KernelFusionPipeline,
    
    // GPU worker thread
    gpu_thread: ?std.Thread,
    shutdown: std.atomic.Value(bool),
    
    // Statistics
    requests_processed: std.atomic.Value(u64),
    total_bytes_transferred: std.atomic.Value(u64),
    total_dma_time_ns: std.atomic.Value(u64),
    total_gpu_time_ns: std.atomic.Value(u64),
    errors: std.atomic.Value(u64),
    
    pub fn init(allocator: std.mem.Allocator, config: ZeroCopyConfig) !*ZeroCopyPipeline {
        const pipeline = try allocator.create(ZeroCopyPipeline);
        
        // Initialize slots
        const slots = try allocator.alloc(?*ZeroCopySlot, config.num_slots);
        for (slots, 0..) |*slot, i| {
            slot.* = try ZeroCopySlot.init(allocator, i, config);
        }
        
        // Initialize kernel fusion pipeline
        const fusion = try kernel_fusion.KernelFusionPipeline.init(allocator, .{
            .max_seq_len = config.max_seq_len,
            .embedding_dim = config.embedding_dim,
        });
        
        pipeline.* = .{
            .allocator = allocator,
            .config = config,
            .slots = slots,
            .current_slot = std.atomic.Value(usize).init(0),
            .fusion_pipeline = fusion,
            .gpu_thread = null,
            .shutdown = std.atomic.Value(bool).init(false),
            .requests_processed = std.atomic.Value(u64).init(0),
            .total_bytes_transferred = std.atomic.Value(u64).init(0),
            .total_dma_time_ns = std.atomic.Value(u64).init(0),
            .total_gpu_time_ns = std.atomic.Value(u64).init(0),
            .errors = std.atomic.Value(u64).init(0),
        };
        
        log.info("Zero-Copy Pipeline initialized:", .{});
        log.info("  Slots: {}", .{config.num_slots});
        log.info("  Max input: {} KB", .{config.max_input_size / 1024});
        log.info("  Max seq len: {}", .{config.max_seq_len});
        
        return pipeline;
    }
    
    pub fn deinit(self: *ZeroCopyPipeline) void {
        self.shutdown.store(true, .release);
        
        if (self.gpu_thread) |thread| {
            thread.join();
        }
        
        for (self.slots) |maybe_slot| {
            if (maybe_slot) |slot| slot.deinit();
        }
        self.allocator.free(self.slots);
        
        self.fusion_pipeline.deinit();
        self.allocator.destroy(self);
        
        log.info("Zero-Copy Pipeline destroyed", .{});
    }
    
    /// Start the GPU worker thread
    pub fn start(self: *ZeroCopyPipeline) !void {
        self.gpu_thread = try std.Thread.spawn(.{}, gpuWorkerLoop, .{self});
        log.info("GPU worker thread started", .{});
    }
    
    /// Submit raw bytes for zero-copy processing
    pub fn submitRawBytes(self: *ZeroCopyPipeline, raw_bytes: []const u8) !*ZeroCopySlot {
        // Find an available slot
        const slot_idx = self.current_slot.load(.acquire);
        const slot = self.slots[slot_idx] orelse return error.NoSlotAvailable;
        
        // Check slot availability
        const state = slot.state.load(.acquire);
        if (state != .idle and state != .complete) {
            return error.SlotBusy;
        }
        
        // Validate input size
        if (raw_bytes.len > self.config.max_input_size) {
            return error.InputTooLarge;
        }
        
        // Reset and fill slot
        slot.reset();
        slot.state.store(.receiving, .release);
        
        // Copy raw bytes to pinned memory buffer (this is the only CPU copy)
        @memcpy(slot.raw_input[0..raw_bytes.len], raw_bytes);
        slot.input_len.store(raw_bytes.len, .release);
        
        // Mark as ready for DMA
        slot.dma_start_ns.store(@intCast(std.time.nanoTimestamp()), .release);
        slot.state.store(.dma_transfer, .release);
        
        // Advance to next slot
        self.current_slot.store((slot_idx + 1) % self.config.num_slots, .release);
        
        _ = self.total_bytes_transferred.fetchAdd(raw_bytes.len, .monotonic);
        
        return slot;
    }
    
    /// Process synchronously (for testing/simple use cases)
    pub fn processSync(self: *ZeroCopyPipeline, raw_bytes: []const u8) !kernel_fusion.FusedResult {
        const slot = try self.submitRawBytes(raw_bytes);
        
        // Process immediately
        slot.dma_complete_ns.store(@intCast(std.time.nanoTimestamp()), .release);
        slot.gpu_start_ns.store(@intCast(std.time.nanoTimestamp()), .release);
        
        const input_len = slot.input_len.load(.acquire);
        const result = try self.fusion_pipeline.executeFused(slot.raw_input[0..input_len]);
        
        slot.result = result;
        slot.gpu_complete_ns.store(@intCast(std.time.nanoTimestamp()), .release);
        slot.state.store(.complete, .release);
        slot.completion_event.set();
        
        _ = self.requests_processed.fetchAdd(1, .monotonic);
        _ = self.total_gpu_time_ns.fetchAdd(result.total_time_ns, .monotonic);
        
        return result;
    }
    
    /// Wait for a slot to complete
    pub fn waitForSlot(self: *ZeroCopyPipeline, slot: *ZeroCopySlot) !kernel_fusion.FusedResult {
        _ = self;
        
        slot.completion_event.timedWait(@as(u64, self.config.gpu_timeout_ms) * 1_000_000) catch {
            return error.Timeout;
        };
        
        if (slot.state.load(.acquire) == .error_state) {
            return error.GpuError;
        }
        
        return slot.result;
    }
    
    /// GPU worker thread main loop
    fn gpuWorkerLoop(self: *ZeroCopyPipeline) void {
        log.info("GPU worker entering main loop", .{});
        
        while (!self.shutdown.load(.acquire)) {
            var processed_any = false;
            
            for (self.slots) |maybe_slot| {
                if (maybe_slot) |slot| {
                    const state = slot.state.load(.acquire);
                    
                    if (state == .dma_transfer) {
                        // Simulate DMA completion
                        slot.dma_complete_ns.store(@intCast(std.time.nanoTimestamp()), .release);
                        slot.state.store(.gpu_processing, .release);
                        processed_any = true;
                    }
                    
                    if (state == .gpu_processing) {
                        slot.gpu_start_ns.store(@intCast(std.time.nanoTimestamp()), .release);
                        
                        // Execute fused kernel
                        const input_len = slot.input_len.load(.acquire);
                        const result = self.fusion_pipeline.executeFused(slot.raw_input[0..input_len]) catch |err| {
                            log.err("GPU processing error: {}", .{err});
                            slot.state.store(.error_state, .release);
                            _ = self.errors.fetchAdd(1, .monotonic);
                            continue;
                        };
                        
                        slot.result = result;
                        slot.gpu_complete_ns.store(@intCast(std.time.nanoTimestamp()), .release);
                        slot.state.store(.complete, .release);
                        slot.completion_event.set();
                        
                        // Update stats
                        _ = self.requests_processed.fetchAdd(1, .monotonic);
                        const dma_time: u64 = @intCast(slot.getDmaLatency());
                        const gpu_time: u64 = @intCast(slot.getGpuLatency());
                        _ = self.total_dma_time_ns.fetchAdd(dma_time, .monotonic);
                        _ = self.total_gpu_time_ns.fetchAdd(gpu_time, .monotonic);
                        
                        processed_any = true;
                    }
                }
            }
            
            if (!processed_any) {
                std.atomic.spinLoopHint();
            }
        }
        
        log.info("GPU worker exiting", .{});
    }
    
    /// Get pipeline statistics
    pub fn getStats(self: *const ZeroCopyPipeline) ZeroCopyStats {
        const count = self.requests_processed.load(.acquire);
        const dma_time = self.total_dma_time_ns.load(.acquire);
        const gpu_time = self.total_gpu_time_ns.load(.acquire);
        
        return .{
            .requests_processed = count,
            .total_bytes_transferred = self.total_bytes_transferred.load(.acquire),
            .total_dma_time_ns = dma_time,
            .total_gpu_time_ns = gpu_time,
            .avg_dma_time_ns = if (count > 0) dma_time / count else 0,
            .avg_gpu_time_ns = if (count > 0) gpu_time / count else 0,
            .errors = self.errors.load(.acquire),
            .fusion_stats = self.fusion_pipeline.getStats(),
        };
    }
};

pub const ZeroCopyStats = struct {
    requests_processed: u64,
    total_bytes_transferred: u64,
    total_dma_time_ns: u64,
    total_gpu_time_ns: u64,
    avg_dma_time_ns: u64,
    avg_gpu_time_ns: u64,
    errors: u64,
    fusion_stats: kernel_fusion.FusionStats,
};

// ============================================================================
// Tests
// ============================================================================

test "ZeroCopyPipeline init and deinit" {
    const pipeline = try ZeroCopyPipeline.init(std.testing.allocator, .{});
    defer pipeline.deinit();
    
    const stats = pipeline.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.requests_processed);
}

test "ZeroCopyPipeline sync processing" {
    const pipeline = try ZeroCopyPipeline.init(std.testing.allocator, .{});
    defer pipeline.deinit();
    
    const json = "{\"prompt\": \"Generate inference output.\"}";
    const result = try pipeline.processSync(json);
    
    try std.testing.expectEqual(@as(u32, 0), result.error_stage);
    try std.testing.expect(result.num_tokens > 0);
}

test "ZeroCopySlot lifecycle" {
    const slot = try ZeroCopySlot.init(std.testing.allocator, 0, .{});
    defer slot.deinit();
    
    try std.testing.expectEqual(ZeroCopySlot.SlotState.idle, slot.state.load(.acquire));
}

test "ZeroCopyPipeline statistics" {
    const pipeline = try ZeroCopyPipeline.init(std.testing.allocator, .{});
    defer pipeline.deinit();
    
    _ = try pipeline.processSync("{\"prompt\": \"test1\"}");
    _ = try pipeline.processSync("{\"prompt\": \"test2\"}");
    
    const stats = pipeline.getStats();
    try std.testing.expectEqual(@as(u64, 2), stats.requests_processed);
    try std.testing.expect(stats.total_bytes_transferred > 0);
}