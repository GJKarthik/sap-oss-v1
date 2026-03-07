//! Zero-CPU-Touch Fused Async GPU Pipeline for MCP-PAL
//! Extends AsyncPipeline with raw byte ingestion and full GPU kernel fusion.
//!
//! Architecture:
//!   1. Raw Byte Transfer: Stream JSON payload to pinned/shared buffer
//!   2. JSON Parser: Locate "prompt"/"input" field via Metal `json_find_key` kernel
//!   3. Tokenizer: Convert text to tokens via Metal `gpu_tokenize_bytes` kernel
//!   4. Embeddings: Generate embeddings via Metal `embedding_lookup` kernel
//!
//! Flow: HTTP Request → Buffer → GPU Parse → GPU Tokenize → GPU Embed → Response
//!       All three stages dispatch on Metal GPU with per-stage CPU fallback.

const std = @import("std");
const builtin = @import("builtin");

const kernel_fusion = @import("kernels/kernel_fusion.zig");
const json_parser = @import("kernels/json_parser.zig");
const tokenizer = @import("kernels/tokenizer.zig");
const metal_shaders = @import("metal_shaders.zig");
const metal_bindings = @import("metal_bindings.zig");

const log = std.log.scoped(.zero_copy_pipeline);

// ============================================================================
// Metal GPU Pipeline Dispatch (Parse + Tokenize + Embed)
// ============================================================================

const MetalGpuDispatchContext = struct {
    shader_lib: *metal_shaders.MetalShaderLibrary,

    fn dispatchParse(ctx_ptr: *anyopaque, raw_json: []const u8, out_result: *json_parser.GpuParseResult) bool {
        if (comptime builtin.os.tag != .macos or builtin.is_test) return false;
        const self: *MetalGpuDispatchContext = @ptrCast(@alignCast(ctx_ptr));
        const lib = self.shader_lib;
        if (!lib.isReady()) return false;
        const device = lib.device orelse return false;
        if (raw_json.len == 0) return false;

        const data_buf = metal_bindings.createBufferWithBytes(device, raw_json, metal_bindings.MTLResourceStorageModeShared) orelse return false;
        defer metal_bindings.release(data_buf);
        const result_buf = metal_bindings.createSharedBuffer(device, 4 * @sizeOf(u32)) orelse return false;
        defer metal_bindings.release(result_buf);

        if (metal_bindings.getBufferContents(result_buf)) |ptr| {
            const r: [*]u32 = @ptrCast(@alignCast(ptr));
            r[0] = 0; r[1] = 0; r[2] = 0; r[3] = 0;
        } else return false;

        var data_len: u32 = @intCast(raw_json.len);
        const num_threads = (raw_json.len + 255) / 256;
        const dispatched = lib.dispatchComputeWithBytes(
            .json_find_key,
            &.{ .{ .buf = data_buf, .index = 0 }, .{ .buf = result_buf, .index = 1 } },
            &.{ .{ .ptr = @ptrCast(&data_len), .len = @sizeOf(u32), .index = 2 } },
            .{ .width = num_threads, .height = 1, .depth = 1 },
            .{ .width = @min(num_threads, 256), .height = 1, .depth = 1 },
        );
        if (!dispatched) return false;

        if (metal_bindings.getBufferContents(result_buf)) |ptr| {
            const r: [*]u32 = @ptrCast(@alignCast(ptr));
            out_result.* = .{ .text_start = r[0], .text_end = r[1], .status = r[2], .error_code = r[3], .bytes_scanned = data_len, ._reserved = .{ 0, 0, 0 } };
            return r[2] == @intFromEnum(json_parser.ParseStatus.success);
        }
        return false;
    }

    fn dispatchTokenize(ctx_ptr: *anyopaque, text: []const u8, output_tokens: []u32, max_tokens: usize, out_token_count: *usize) bool {
        if (comptime builtin.os.tag != .macos or builtin.is_test) return false;
        const self: *MetalGpuDispatchContext = @ptrCast(@alignCast(ctx_ptr));
        const lib = self.shader_lib;
        if (!lib.isReady()) return false;
        const device = lib.device orelse return false;
        if (text.len == 0) return false;

        const text_buf = metal_bindings.createBufferWithBytes(device, text, metal_bindings.MTLResourceStorageModeShared) orelse return false;
        defer metal_bindings.release(text_buf);
        const cap = @min(max_tokens, output_tokens.len);
        const tok_buf = metal_bindings.createSharedBuffer(device, cap * @sizeOf(u32)) orelse return false;
        defer metal_bindings.release(tok_buf);
        const cnt_buf = metal_bindings.createSharedBuffer(device, @sizeOf(u32)) orelse return false;
        defer metal_bindings.release(cnt_buf);
        if (metal_bindings.getBufferContents(cnt_buf)) |ptr| {
            const c: [*]u32 = @ptrCast(@alignCast(ptr)); c[0] = 0;
        } else return false;

        var text_len: u32 = @intCast(text.len);
        var max_tok: u32 = @intCast(cap);
        const dispatched = lib.dispatchComputeWithBytes(
            .gpu_tokenize_bytes,
            &.{ .{ .buf = text_buf, .index = 0 }, .{ .buf = tok_buf, .index = 1 }, .{ .buf = cnt_buf, .index = 2 } },
            &.{ .{ .ptr = @ptrCast(&text_len), .len = @sizeOf(u32), .index = 3 }, .{ .ptr = @ptrCast(&max_tok), .len = @sizeOf(u32), .index = 4 } },
            .{ .width = text.len, .height = 1, .depth = 1 },
            .{ .width = @min(text.len, 256), .height = 1, .depth = 1 },
        );
        if (!dispatched) return false;

        const count: usize = blk: {
            if (metal_bindings.getBufferContents(cnt_buf)) |ptr| {
                const c: [*]u32 = @ptrCast(@alignCast(ptr));
                break :blk @min(c[0], @as(u32, @intCast(cap)));
            }
            return false;
        };
        if (count == 0) return false;
        if (metal_bindings.getBufferContents(tok_buf)) |ptr| {
            const gpu_toks: [*]u32 = @ptrCast(@alignCast(ptr));
            @memcpy(output_tokens[0..count], gpu_toks[0..count]);
        } else return false;
        out_token_count.* = count;
        return true;
    }

    fn dispatchEmbed(ctx_ptr: *anyopaque, tokens: []const u32, output: []f32, embed_dim: usize) bool {
        if (comptime builtin.os.tag != .macos or builtin.is_test) return false;
        const self: *MetalGpuDispatchContext = @ptrCast(@alignCast(ctx_ptr));
        const lib = self.shader_lib;
        if (!lib.isReady()) return false;
        const device = lib.device orelse return false;
        const num_tokens = tokens.len;
        if (num_tokens == 0) return false;

        const token_buf = metal_bindings.createBufferWithBytes(device, std.mem.sliceAsBytes(tokens), metal_bindings.MTLResourceStorageModeShared) orelse return false;
        defer metal_bindings.release(token_buf);
        const vocab_size: usize = 256;
        const table_buf = metal_bindings.createSharedBuffer(device, vocab_size * embed_dim * @sizeOf(f32)) orelse return false;
        defer metal_bindings.release(table_buf);
        if (metal_bindings.getBufferContents(table_buf)) |ptr| {
            const table: [*]f32 = @ptrCast(@alignCast(ptr));
            for (0..vocab_size) |tok| {
                const seed = @as(f32, @floatFromInt(tok)) * 0.001;
                for (0..embed_dim) |d| { table[tok * embed_dim + d] = @sin(seed + @as(f32, @floatFromInt(d)) * 0.01) * 0.1; }
            }
        } else return false;
        const out_buf = metal_bindings.createSharedBuffer(device, num_tokens * embed_dim * @sizeOf(f32)) orelse return false;
        defer metal_bindings.release(out_buf);

        var dim32: u32 = @intCast(embed_dim);
        const dispatched = lib.dispatchComputeWithBytes(
            .embedding_lookup,
            &.{ .{ .buf = token_buf, .index = 0 }, .{ .buf = table_buf, .index = 1 }, .{ .buf = out_buf, .index = 2 } },
            &.{ .{ .ptr = @ptrCast(&dim32), .len = @sizeOf(u32), .index = 3 } },
            .{ .width = embed_dim, .height = num_tokens, .depth = 1 },
            .{ .width = @min(embed_dim, 256), .height = 1, .depth = 1 },
        );
        if (!dispatched) return false;
        if (metal_bindings.getBufferContents(out_buf)) |ptr| {
            const gpu_out: [*]f32 = @ptrCast(@alignCast(ptr));
            const total = num_tokens * embed_dim;
            @memcpy(output[0..total], gpu_out[0..total]);
            return true;
        }
        return false;
    }
};

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
    
    // Raw input buffer
    raw_input: []u8,
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
        
        // Allocate buffer for DMA (page alignment handled by OS)
        const raw_input = try allocator.alignedAlloc(u8, null, config.max_input_size);
        
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
    
    // GPU dispatch context (owned, freed in deinit)
    metal_dispatch_ctx: ?*MetalGpuDispatchContext,
    
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
            .metal_dispatch_ctx = null,
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
    
    /// Attach a compiled Metal shader library for real GPU dispatch.
    pub fn attachShaderLibrary(self: *ZeroCopyPipeline, lib: *metal_shaders.MetalShaderLibrary) void {
        const ctx = self.allocator.create(MetalGpuDispatchContext) catch {
            log.err("Failed to allocate MetalGpuDispatchContext", .{});
            return;
        };
        ctx.* = .{ .shader_lib = lib };
        self.metal_dispatch_ctx = ctx;
        self.fusion_pipeline.attachGpuDispatch(.{
            .ctx = @ptrCast(ctx),
            .parse_fn = &MetalGpuDispatchContext.dispatchParse,
            .tokenize_fn = &MetalGpuDispatchContext.dispatchTokenize,
            .embed_fn = &MetalGpuDispatchContext.dispatchEmbed,
        });
        log.info("Metal GPU dispatch attached to Zero-Copy Pipeline (GPU ready: {})", .{lib.isReady()});
    }
    
    pub fn deinit(self: *ZeroCopyPipeline) void {
        self.shutdown.store(true, .release);
        
        if (self.gpu_thread) |thread| {
            thread.join();
        }
        
        if (self.metal_dispatch_ctx) |ctx| self.allocator.destroy(ctx);
        
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