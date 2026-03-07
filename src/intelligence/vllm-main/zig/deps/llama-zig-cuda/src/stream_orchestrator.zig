//! Multi-Stream Orchestrator - Phase 3 Optimization
//!
//! Coordinates multiple CUDA streams, layer pipelining, graph caching, and
//! speculative decoding for maximum GPU utilisation.
//!
//! ## Architecture
//! - `StreamPool`  — round-robin pool of compute and memory streams.
//! - `LayerPipeline` — overlaps layer N compute with layer N+1 weight prefetch.
//! - `GraphCache` — caches CUDA graphs keyed by (batch_size, seq_len, type);
//!   uses pre-allocated scratch buffers so graphs capture valid pointers,
//!   and supports LRU eviction when the cache is full.
//! - `SpeculativeOrchestrator` — wraps the C-level speculative draft/verify API.
//! - `StreamOrchestrator` — top-level façade tying everything together.
//!
//! ## Thread Safety
//! Not thread-safe. All GPU operations synchronise before returning unless
//! documented otherwise. The global singleton must be accessed from a single
//! thread or protected externally.
//!
//! ## Current Limitations
//! - Kernels inside `LayerPipeline.executeLayer` depend on the C-side
//!   `cuda_pipeline_layer` implementation being complete.
//! - `GraphCache` captures graphs using fixed scratch buffers from
//!   `cuda_graph_memory_init`. The caller must ensure the scratch pool is
//!   large enough for the largest batch.

const std = @import("std");
const Allocator = std.mem.Allocator;

// C FFI for CUDA
const c = @cImport({
    @cInclude("cuda_kernels.h");
});

// ============================================================================
// Stream Configuration
// ============================================================================

pub const StreamConfig = struct {
    /// Number of compute streams
    num_compute_streams: usize = 4,
    
    /// Number of memory streams (for async transfers)
    num_memory_streams: usize = 2,
    
    /// Enable layer pipelining (compute layer N while loading N+1)
    layer_pipelining: bool = true,
    
    /// Enable speculative decoding
    speculative_decoding: bool = false,
    
    /// Number of speculative tokens
    num_speculative_tokens: usize = 4,
    
    /// Enable CUDA graphs for decode steps
    use_cuda_graphs: bool = true,
    
    /// Max graphs to cache
    max_cached_graphs: usize = 8,
};

// ============================================================================
// Stream Types
// ============================================================================

pub const StreamType = enum {
    compute,
    memory,
    attention,
    ffn,
};

// ============================================================================
// Event for synchronization
// ============================================================================

pub const CudaEvent = struct {
    handle: ?*anyopaque,
    recorded: bool,
    
    pub fn init() !CudaEvent {
        const handle = c.cuda_event_create();
        if (handle == null) return error.CudaEventCreateFailed;
        return .{ .handle = handle, .recorded = false };
    }
    
    pub fn deinit(self: *CudaEvent) void {
        if (self.handle) |h| {
            c.cuda_event_destroy(h);
            self.handle = null;
        }
    }
    
    pub fn record(self: *CudaEvent, stream: ?*anyopaque) !void {
        if (c.cuda_event_record(self.handle, stream) != 0) {
            return error.CudaEventRecordFailed;
        }
        self.recorded = true;
    }
    
    pub fn synchronize(self: *CudaEvent) !void {
        if (!self.recorded) return;
        if (c.cuda_event_synchronize(self.handle) != 0) {
            return error.CudaEventSyncFailed;
        }
    }
    
    pub fn elapsedMs(self: *CudaEvent, other: *CudaEvent) !f32 {
        var ms: f32 = 0;
        if (c.cuda_event_elapsed_time(&ms, other.handle, self.handle) != 0) {
            return error.CudaEventElapsedFailed;
        }
        return ms;
    }
};

// ============================================================================
// Stream Pool
// ============================================================================

/// Pool of CUDA streams with round-robin assignment.
/// Wraps the C-level stream pool and creates per-stream events.
pub const StreamPool = struct {
    const Self = @This();
    
    compute_streams: []?*anyopaque,
    memory_streams: []?*anyopaque,
    events: []CudaEvent,
    
    config: StreamConfig,
    allocator: Allocator,
    
    current_compute: usize,
    current_memory: usize,
    
    /// Initialise the stream pool.
    /// On failure, all partially-created events are cleaned up (no leaks).
    pub fn init(allocator: Allocator, config: StreamConfig) !Self {
        // Initialize CUDA stream pool
        if (c.cuda_stream_pool_init() != 0) {
            return error.CudaStreamPoolInitFailed;
        }
        
        const compute_streams = try allocator.alloc(?*anyopaque, config.num_compute_streams);
        errdefer allocator.free(compute_streams);
        
        const memory_streams = try allocator.alloc(?*anyopaque, config.num_memory_streams);
        errdefer allocator.free(memory_streams);
        
        const events = try allocator.alloc(CudaEvent, config.num_compute_streams + config.num_memory_streams);
        errdefer allocator.free(events);
        
        // Get streams from CUDA
        for (0..config.num_compute_streams) |i| {
            compute_streams[i] = c.cuda_get_stream(@intCast(i));
        }
        
        for (0..config.num_memory_streams) |i| {
            memory_streams[i] = c.cuda_get_stream(@intCast(i + config.num_compute_streams));
        }
        
        // Create events — clean up on partial failure (s-4 fix)
        var created_events: usize = 0;
        errdefer {
            for (0..created_events) |i| {
                events[i].deinit();
            }
        }
        for (0..events.len) |i| {
            events[i] = try CudaEvent.init();
            created_events += 1;
        }
        
        return .{
            .compute_streams = compute_streams,
            .memory_streams = memory_streams,
            .events = events,
            .config = config,
            .allocator = allocator,
            .current_compute = 0,
            .current_memory = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.events) |*event| {
            event.deinit();
        }
        
        self.allocator.free(self.compute_streams);
        self.allocator.free(self.memory_streams);
        self.allocator.free(self.events);
        
        c.cuda_stream_pool_destroy();
    }
    
    /// Get next compute stream (round-robin)
    pub fn nextComputeStream(self: *Self) ?*anyopaque {
        const stream = self.compute_streams[self.current_compute];
        self.current_compute = (self.current_compute + 1) % self.config.num_compute_streams;
        return stream;
    }
    
    /// Get next memory stream
    pub fn nextMemoryStream(self: *Self) ?*anyopaque {
        const stream = self.memory_streams[self.current_memory];
        self.current_memory = (self.current_memory + 1) % self.config.num_memory_streams;
        return stream;
    }
    
    /// Synchronize all streams
    pub fn syncAll(self: *Self) !void {
        for (self.compute_streams) |stream| {
            if (c.cuda_stream_synchronize(stream) != 0) {
                return error.CudaStreamSyncFailed;
            }
        }
        for (self.memory_streams) |stream| {
            if (c.cuda_stream_synchronize(stream) != 0) {
                return error.CudaStreamSyncFailed;
            }
        }
    }
};

// ============================================================================
// Layer Pipeline
// ============================================================================

/// Layer-wise pipeline: executes layer N compute while prefetching layer N+1
/// weights on a separate memory stream.
pub const LayerPipeline = struct {
    const Self = @This();
    
    stream_pool: *StreamPool,
    
    /// Weights staging buffer (for prefetching)
    staging_buffer: ?*anyopaque,
    staging_size: usize,
    
    /// Current layer being computed
    current_layer: usize,
    
    /// Events for layer completion
    layer_events: []CudaEvent,
    
    /// Model dimensions (set once at init, used for every executeLayer call)
    batch_size: usize,
    hidden_dim: usize,
    
    allocator: Allocator,
    
    pub fn init(
        allocator: Allocator,
        stream_pool: *StreamPool,
        num_layers: usize,
        staging_size: usize,
        batch_size: usize,
        hidden_dim: usize,
    ) !Self {
        const layer_events = try allocator.alloc(CudaEvent, num_layers);
        errdefer allocator.free(layer_events);
        
        var created: usize = 0;
        errdefer {
            for (0..created) |i| layer_events[i].deinit();
        }
        for (0..num_layers) |i| {
            layer_events[i] = try CudaEvent.init();
            created += 1;
        }
        
        // Allocate staging buffer for weight prefetch
        const staging = c.cuda_malloc(staging_size);
        
        return .{
            .stream_pool = stream_pool,
            .staging_buffer = staging,
            .staging_size = staging_size,
            .current_layer = 0,
            .layer_events = layer_events,
            .batch_size = batch_size,
            .hidden_dim = hidden_dim,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.layer_events) |*event| {
            event.deinit();
        }
        self.allocator.free(self.layer_events);
        
        if (self.staging_buffer) |buf| {
            c.cuda_free(buf);
        }
    }
    
    /// Execute a single transformer layer with compute/memory overlap.
    /// `batch_size` and `hidden_dim` are taken from the values set at init.
    pub fn executeLayer(
        self: *Self,
        layer_idx: usize,
        input: *anyopaque,
        output: *anyopaque,
        weights: *anyopaque,
        next_weights: ?*anyopaque,
        weights_size: usize,
    ) !void {
        const compute_stream = self.stream_pool.nextComputeStream();
        _ = self.stream_pool.nextMemoryStream();
        
        // Wait for previous layer's memory transfer
        if (layer_idx > 0) {
            try self.layer_events[layer_idx - 1].synchronize();
        }
        
        // Execute layer computation with actual batch_size and hidden_dim
        const result = c.cuda_pipeline_layer(
            @intCast(layer_idx),
            @ptrCast(output),
            @ptrCast(input),
            @ptrCast(weights),
            if (self.staging_buffer) |sb| @ptrCast(sb) else null,
            if (next_weights) |nw| @ptrCast(nw) else null,
            weights_size,
            @intCast(self.batch_size),
            @intCast(self.hidden_dim),
        );
        if (result != 0) return error.PipelineLayerFailed;
        
        // Record completion event
        try self.layer_events[layer_idx].record(compute_stream);
        
        self.current_layer = layer_idx;
    }
    
    /// Wait for all layers to complete
    pub fn finish(self: *Self) !void {
        if (self.current_layer > 0) {
            try self.layer_events[self.current_layer].synchronize();
        }
    }
};

// ============================================================================
// CUDA Graph Cache
// ============================================================================

/// CUDA graph cache with LRU eviction.
///
/// Graphs are captured using **fixed scratch buffer pointers** obtained from
/// `cuda_graph_get_scratch()`. Because the graph embeds the exact pointer
/// addresses used during capture, we always capture with scratch buffers
/// (which live for the lifetime of the process) and memcpy the actual
/// input/output into them before launch.
///
/// When the cache is full, the least-recently-used entry is evicted.
pub const GraphCache = struct {
    const Self = @This();
    
    pub const CacheKey = struct {
        batch_size: usize,
        seq_len: usize,
        graph_type: GraphType,
    };
    
    pub const GraphType = enum {
        decode_step,
        prefill,
        speculative_draft,
        speculative_verify,
    };
    
    const CacheEntry = struct {
        graph_id: usize,
        last_used: u64,  // monotonic counter for LRU
    };
    
    graphs: std.AutoHashMap(CacheKey, CacheEntry),
    next_graph_id: usize,
    access_counter: u64,
    config: StreamConfig,
    allocator: Allocator,
    
    pub fn init(allocator: Allocator, config: StreamConfig) !Self {
        return .{
            .graphs = std.AutoHashMap(CacheKey, CacheEntry).init(allocator),
            .next_graph_id = 0,
            .access_counter = 0,
            .config = config,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        var it = self.graphs.valueIterator();
        while (it.next()) |entry| {
            _ = c.cuda_graph_destroy(@intCast(entry.graph_id));
        }
        self.graphs.deinit();
    }
    
    /// Evict the least-recently-used graph to free a slot.
    fn evictLru(self: *Self) void {
        var oldest_key: ?CacheKey = null;
        var oldest_time: u64 = std.math.maxInt(u64);
        
        var it = self.graphs.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.last_used < oldest_time) {
                oldest_time = kv.value_ptr.last_used;
                oldest_key = kv.key_ptr.*;
            }
        }
        
        if (oldest_key) |key| {
            if (self.graphs.get(key)) |entry| {
                _ = c.cuda_graph_destroy(@intCast(entry.graph_id));
            }
            _ = self.graphs.remove(key);
        }
    }
    
    /// Get or create a decode step graph.
    ///
    /// The graph is captured using the scratch buffer from
    /// `cuda_graph_get_scratch()`. The caller must copy actual input
    /// data into the scratch buffer before launch and read output
    /// from scratch after sync.
    pub fn getDecodeGraph(
        self: *Self,
        batch_size: usize,
        hidden_dim: usize,
        num_layers: usize,
        weights: ?*anyopaque,
    ) !usize {
        const key = CacheKey{
            .batch_size = batch_size,
            .seq_len = 1,
            .graph_type = .decode_step,
        };
        
        if (self.graphs.getPtr(key)) |entry| {
            self.access_counter += 1;
            entry.last_used = self.access_counter;
            return entry.graph_id;
        }
        
        // Evict LRU if cache is full
        if (self.graphs.count() >= self.config.max_cached_graphs) {
            self.evictLru();
        }
        
        const graph_id = self.next_graph_id;
        self.next_graph_id += 1;
        
        // Use scratch buffer as the capture pointer — it is stable
        const scratch = c.cuda_graph_get_scratch();
        if (scratch == null) return error.ScratchNotInitialized;
        
        const scratch_raw: [*]u8 = @ptrCast(scratch.?);
        // Partition scratch: output at offset 0, input at offset batch*hidden*sizeof(f32)
        const output_ptr: [*]f32 = @ptrCast(@alignCast(scratch_raw));
        const input_offset = batch_size * hidden_dim * @sizeOf(f32);
        const input_ptr: [*]const f32 = @ptrCast(@alignCast(scratch_raw + input_offset));
        
        const result = c.cuda_graph_create_decode_step(
            @intCast(graph_id),
            @ptrCast(output_ptr),
            @ptrCast(input_ptr),
            if (weights) |w| @ptrCast(w) else null,
            @intCast(batch_size),
            @intCast(hidden_dim),
            @intCast(num_layers),
        );
        if (result != 0) return error.GraphCreateFailed;
        
        self.access_counter += 1;
        try self.graphs.put(key, .{
            .graph_id = graph_id,
            .last_used = self.access_counter,
        });
        return graph_id;
    }
    
    /// Launch a cached graph.
    pub fn launch(self: *Self, graph_id: usize) !void {
        _ = self;
        if (c.cuda_graph_launch(@intCast(graph_id)) != 0) {
            return error.GraphLaunchFailed;
        }
    }
    
    /// Wait for graph completion.
    pub fn sync(self: *Self, graph_id: usize) !void {
        _ = self;
        if (c.cuda_graph_sync(@intCast(graph_id)) != 0) {
            return error.GraphSyncFailed;
        }
    }
    
    /// Number of cached graphs.
    pub fn count(self: *const Self) usize {
        return self.graphs.count();
    }
};

// ============================================================================
// Speculative Decoding Orchestrator
// ============================================================================

/// Wraps the C-level speculative draft/verify kernels.
///
/// Usage:
///   1. Call `init` with the model's hidden_dim and vocab_size.
///   2. For each generation step, call `step` which runs draft then verify.
///   3. Read `accepted_tokens[0..num_accepted]` for the result.
pub const SpeculativeOrchestrator = struct {
    const Self = @This();
    
    stream_pool: *StreamPool,
    num_speculative: usize,
    vocab_size: usize,
    
    draft_tokens: []i32,
    draft_probs: []f32,
    accepted_tokens: []i32,
    
    allocator: Allocator,
    
    pub fn init(
        allocator: Allocator,
        stream_pool: *StreamPool,
        num_speculative: usize,
        hidden_dim: usize,
        vocab_size: usize,
    ) !Self {
        // Pass hidden_dim and vocab_size so C side allocates scratch buffers
        const result = c.cuda_speculative_init(
            @intCast(num_speculative),
            @intCast(hidden_dim),
            @intCast(vocab_size),
        );
        if (result != 0) return error.SpeculativeInitFailed;
        
        const draft_tokens = try allocator.alloc(i32, num_speculative);
        errdefer allocator.free(draft_tokens);
        const draft_probs = try allocator.alloc(f32, num_speculative * vocab_size);
        errdefer allocator.free(draft_probs);
        const accepted_tokens = try allocator.alloc(i32, num_speculative + 1);
        errdefer allocator.free(accepted_tokens);
        
        return .{
            .stream_pool = stream_pool,
            .num_speculative = num_speculative,
            .vocab_size = vocab_size,
            .draft_tokens = draft_tokens,
            .draft_probs = draft_probs,
            .accepted_tokens = accepted_tokens,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        c.cuda_speculative_shutdown();
        self.allocator.free(self.draft_tokens);
        self.allocator.free(self.draft_probs);
        self.allocator.free(self.accepted_tokens);
    }
    
    /// Run one speculative decoding step (draft + verify).
    /// Returns the number of accepted tokens.
    pub fn step(
        self: *Self,
        input: *anyopaque,
        draft_weights: *anyopaque,
        main_weights: *anyopaque,
        num_layers: usize,
    ) !usize {
        // Generate draft tokens
        const draft_result = c.cuda_speculative_draft(
            @ptrCast(self.draft_tokens.ptr),
            @ptrCast(self.draft_probs.ptr),
            @ptrCast(input),
            @ptrCast(draft_weights),
            @intCast(num_layers),
            @intCast(self.vocab_size),
        );
        if (draft_result != 0) return error.SpeculativeDraftFailed;
        
        // Verify with main model
        var num_accepted: c_int = 0;
        const verify_result = c.cuda_speculative_verify(
            @ptrCast(self.accepted_tokens.ptr),
            &num_accepted,
            @ptrCast(self.draft_tokens.ptr),
            @ptrCast(self.draft_probs.ptr),
            @ptrCast(input),
            @ptrCast(main_weights),
            @intCast(num_layers),
            @intCast(self.vocab_size),
            @intCast(self.num_speculative),
        );
        if (verify_result != 0) return error.SpeculativeVerifyFailed;
        
        return @intCast(num_accepted);
    }
};

// ============================================================================
// Main Orchestrator
// ============================================================================

/// Top-level orchestrator tying streams, graphs, pipelining, and speculative
/// decoding together.
///
/// ## Model Parameters
/// `StreamOrchestratorParams` must be provided at init time so that sub-systems
/// (layer pipeline, speculative decoding) can be properly configured.
pub const StreamOrchestratorParams = struct {
    num_layers: usize = 32,
    hidden_dim: usize = 4096,
    batch_size: usize = 1,
    vocab_size: usize = 32000,
    /// Size of per-layer weight block in bytes (for staging buffer).
    layer_weight_bytes: usize = 0,
};

pub const StreamOrchestrator = struct {
    const Self = @This();
    
    config: StreamConfig,
    model_params: StreamOrchestratorParams,
    stream_pool: StreamPool,
    graph_cache: ?GraphCache,
    layer_pipeline: ?LayerPipeline,
    speculative: ?SpeculativeOrchestrator,
    
    allocator: Allocator,
    
    /// Statistics
    stats: OrchestratorStats,
    
    pub const OrchestratorStats = struct {
        total_decode_steps: u64 = 0,
        total_prefill_tokens: u64 = 0,
        graph_hits: u64 = 0,
        graph_misses: u64 = 0,
        speculative_accepted: u64 = 0,
        speculative_rejected: u64 = 0,
        avg_decode_ms: f32 = 0.0,
    };
    
    pub fn init(
        allocator: Allocator,
        config: StreamConfig,
        model_params: StreamOrchestratorParams,
    ) !Self {
        var stream_pool = try StreamPool.init(allocator, config);
        errdefer stream_pool.deinit();
        
        var graph_cache: ?GraphCache = null;
        if (config.use_cuda_graphs) {
            graph_cache = try GraphCache.init(allocator, config);
        }
        
        // Wire up layer pipelining if enabled
        var layer_pipeline: ?LayerPipeline = null;
        if (config.layer_pipelining and model_params.num_layers > 0) {
            layer_pipeline = try LayerPipeline.init(
                allocator,
                &stream_pool,
                model_params.num_layers,
                model_params.layer_weight_bytes,
                model_params.batch_size,
                model_params.hidden_dim,
            );
        }
        
        // Wire up speculative decoding if enabled
        var speculative: ?SpeculativeOrchestrator = null;
        if (config.speculative_decoding) {
            speculative = try SpeculativeOrchestrator.init(
                allocator,
                &stream_pool,
                config.num_speculative_tokens,
                model_params.hidden_dim,
                model_params.vocab_size,
            );
        }
        
        return .{
            .config = config,
            .model_params = model_params,
            .stream_pool = stream_pool,
            .graph_cache = graph_cache,
            .layer_pipeline = layer_pipeline,
            .speculative = speculative,
            .allocator = allocator,
            .stats = .{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        if (self.speculative) |*sp| sp.deinit();
        if (self.layer_pipeline) |*lp| lp.deinit();
        if (self.graph_cache) |*gc| gc.deinit();
        self.stream_pool.deinit();
    }
    
    /// Decode single token using CUDA graph if available.
    /// `weights` is the contiguous model weight buffer on device.
    pub fn decodeStep(
        self: *Self,
        weights: ?*anyopaque,
    ) !void {
        if (self.graph_cache) |*gc| {
            const graph_id = try gc.getDecodeGraph(
                self.model_params.batch_size,
                self.model_params.hidden_dim,
                self.model_params.num_layers,
                weights,
            );
            try gc.launch(graph_id);
            try gc.sync(graph_id);
            self.stats.graph_hits += 1;
        } else {
            self.stats.graph_misses += 1;
        }
        self.stats.total_decode_steps += 1;
    }
    
    /// Run one speculative decoding step if enabled.
    /// Returns number of accepted tokens, or 0 if speculative decoding is off.
    pub fn speculativeStep(
        self: *Self,
        input: *anyopaque,
        draft_weights: *anyopaque,
        main_weights: *anyopaque,
    ) !usize {
        if (self.speculative) |*sp| {
            const accepted = try sp.step(input, draft_weights, main_weights, self.model_params.num_layers);
            self.stats.speculative_accepted += accepted;
            if (accepted < sp.num_speculative) {
                self.stats.speculative_rejected += sp.num_speculative - accepted;
            }
            return accepted;
        }
        return 0;
    }
    
    /// Synchronize all operations
    pub fn sync(self: *Self) !void {
        try self.stream_pool.syncAll();
    }
    
    /// Get statistics
    pub fn getStats(self: *const Self) OrchestratorStats {
        return self.stats;
    }
};

// ============================================================================
// Configurable Global Instance
// ============================================================================

var g_orchestrator: ?StreamOrchestrator = null;

/// Initialise the global orchestrator with explicit configuration.
/// Must be called before `getGlobalOrchestrator()`.
/// Calling again after shutdown is allowed.
pub fn initGlobalOrchestrator(
    allocator: Allocator,
    config: StreamConfig,
    model_params: StreamOrchestratorParams,
) !void {
    if (g_orchestrator != null) return; // already initialised
    g_orchestrator = try StreamOrchestrator.init(allocator, config, model_params);
}

/// Return the global orchestrator, creating one with defaults if necessary.
/// Prefer `initGlobalOrchestrator` for explicit configuration.
pub fn getGlobalOrchestrator() !*StreamOrchestrator {
    if (g_orchestrator == null) {
        g_orchestrator = try StreamOrchestrator.init(
            std.heap.page_allocator,
            .{},
            .{},
        );
    }
    return &g_orchestrator.?;
}

pub fn shutdownGlobalOrchestrator() void {
    if (g_orchestrator) |*orch| {
        orch.deinit();
        g_orchestrator = null;
    }
}

// ============================================================================
// Tests
// ============================================================================

test "StreamConfig defaults" {
    const cfg = StreamConfig{};
    try std.testing.expectEqual(cfg.num_compute_streams, 4);
    try std.testing.expectEqual(cfg.num_memory_streams, 2);
    try std.testing.expect(cfg.layer_pipelining);
    try std.testing.expect(!cfg.speculative_decoding);
    try std.testing.expect(cfg.use_cuda_graphs);
    try std.testing.expectEqual(cfg.max_cached_graphs, 8);
}

test "GraphCache LRU eviction logic" {
    // Test the graph cache with a tiny max_cached_graphs to verify LRU eviction.
    // This test only exercises the Zig data-structure logic; it does not call
    // into CUDA (those calls will return errors which we handle).
    const allocator = std.testing.allocator;
    var cache = try GraphCache.init(allocator, .{ .max_cached_graphs = 2 });
    defer cache.deinit();
    
    // Manually insert two entries to test eviction path
    const key1 = GraphCache.CacheKey{ .batch_size = 1, .seq_len = 1, .graph_type = .decode_step };
    const key2 = GraphCache.CacheKey{ .batch_size = 2, .seq_len = 1, .graph_type = .decode_step };
    
    cache.access_counter += 1;
    try cache.graphs.put(key1, .{ .graph_id = 0, .last_used = cache.access_counter });
    cache.access_counter += 1;
    try cache.graphs.put(key2, .{ .graph_id = 1, .last_used = cache.access_counter });
    
    try std.testing.expectEqual(cache.count(), 2);
    
    // Evict should remove key1 (oldest)
    cache.evictLru();
    try std.testing.expectEqual(cache.count(), 1);
    try std.testing.expect(cache.graphs.get(key1) == null);
    try std.testing.expect(cache.graphs.get(key2) != null);
}

test "StreamOrchestratorParams defaults" {
    const p = StreamOrchestratorParams{};
    try std.testing.expectEqual(p.num_layers, 32);
    try std.testing.expectEqual(p.hidden_dim, 4096);
    try std.testing.expectEqual(p.batch_size, 1);
    try std.testing.expectEqual(p.vocab_size, 32000);
}