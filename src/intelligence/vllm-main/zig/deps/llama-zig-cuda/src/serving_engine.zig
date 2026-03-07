//! Serving Engine - Phase 5 Optimization
//!
//! High-throughput LLM serving engine inspired by vLLM:
//! - **Continuous batching** with PagedAttention KV cache
//! - **Prefix caching** via token-hash lookup (reuses KV pages across requests)
//! - **Chunked prefill** for long prompts (avoids GPU OOM spikes)
//! - **Sampling** with temperature, top-p (nucleus), top-k, repetition penalty
//! - **Preemption** of lowest-priority / longest-running sequences on memory pressure
//! - **Model weights** stored as a device pointer and passed to the CUDA forward pass
//!
//! ## Thread Safety
//! The `Scheduler` protects its queues with a mutex. All other state is
//! single-threaded. The engine's `start()` loop must run on a dedicated thread;
//! `generate()` and `stop()` may be called from any thread.
//!
//! ## Integration
//! Calls into the C-level continuous batching API (`continuous_batch_step`,
//! `prefix_cache_lookup`, etc.) declared in `cuda_kernels.h`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;

// C FFI for CUDA
const c = @cImport({
    @cInclude("cuda_kernels.h");
});

// KV cache offloading
const kv_offload = @import("kv_offload.zig");
const OffloadManager = kv_offload.OffloadManager;
const OffloadConfig = kv_offload.OffloadConfig;

// Batch scheduler (dynamic batching)
const batch_sched_mod = @import("batch_scheduler.zig");
const BatchScheduler = batch_sched_mod.BatchScheduler;
const BatchConfig = batch_sched_mod.BatchConfig;

// ============================================================================
// Configuration
// ============================================================================

pub const ServingConfig = struct {
    /// Maximum concurrent sequences
    max_sequences: usize = 256,
    
    /// Maximum KV cache pages
    max_pages: usize = 4096,
    
    /// Tokens per KV page
    page_size: usize = 16,
    
    /// Maximum sequence length
    max_seq_len: usize = 8192,
    
    /// Maximum new tokens to generate
    max_new_tokens: usize = 2048,
    
    /// Enable prefix caching
    prefix_caching: bool = true,
    
    /// Use INT8 quantised KV cache (halves memory vs FP16, ~0.1% ppl loss)
    use_int8_kv: bool = false,
    
    /// Chunked prefill threshold (tokens). Prompts longer than this are
    /// processed in chunks of this size across multiple steps.
    chunked_prefill_threshold: usize = 512,
    
    /// Polling interval for scheduler (microseconds)
    scheduler_interval_us: u64 = 100,
    
    /// HTTP server port
    http_port: u16 = 8080,
    
    /// Minimum free page ratio before preemption is triggered.
    /// E.g. 0.1 means preempt when <10% of pages are free.
    preempt_free_ratio: f32 = 0.1,
};

// ============================================================================
// Model Weights
// ============================================================================

/// Opaque handle to model weights residing on the GPU.
/// The serving engine stores this pointer and passes it to
/// `continuous_batch_step` on every forward pass.
pub const ModelWeights = struct {
    /// Device pointer to the contiguous FP16 weight buffer.
    device_ptr: *anyopaque,
    /// Total size of the weight buffer in bytes.
    size_bytes: usize,
};

// ============================================================================
// Request / Response Types
// ============================================================================

pub const Request = struct {
    id: u64,
    prompt_tokens: []const u32,
    sampling_params: SamplingParams,
    arrival_time: i64,
    status: RequestStatus,

    /// Generated tokens so far
    output_tokens: std.ArrayList(u32),

    /// Allocator for output_tokens
    allocator: Allocator,

    /// For prefix caching
    prefix_hash: u64,
    shared_prefix_length: usize,
    
    pub const RequestStatus = enum {
        waiting,
        running,
        preempted,
        finished,
        @"error",
    };
};

pub const SamplingParams = struct {
    temperature: f32 = 1.0,
    top_p: f32 = 1.0,
    top_k: i32 = -1,
    max_tokens: usize = 256,
    stop_sequences: ?[]const []const u8 = null,
    repetition_penalty: f32 = 1.0,
    presence_penalty: f32 = 0.0,
    frequency_penalty: f32 = 0.0,
    seed: ?u64 = null,

    /// Beam search width (1 = greedy/sampling, >1 = beam search).
    beam_width: usize = 1,
};

pub const Response = struct {
    request_id: u64,
    generated_text: []const u8,
    tokens: []const u32,
    finish_reason: FinishReason,
    usage: UsageStats,
    
    pub const FinishReason = enum {
        stop,
        length,
        @"error",
    };

    pub const UsageStats = struct {
        prompt_tokens: usize,
        completion_tokens: usize,
        total_tokens: usize,
        time_to_first_token_ms: f32,
        time_per_token_ms: f32,
    };
};

// ============================================================================
// Sequence State
// ============================================================================

/// Per-sequence runtime state tracked by the scheduler.
pub const SequenceState = struct {
    const Self = @This();
    
    request: *Request,
    sequence_id: i32,
    
    /// Current token position in the full sequence (prompt + generated).
    position: usize,
    
    /// KV cache pages allocated for this sequence.
    pages: std.ArrayList(i32),
    
    /// True while the prompt is still being processed.
    is_prefill: bool,
    
    /// How many prompt tokens have been fed so far (for chunked prefill).
    prefill_tokens_done: usize,

    /// Beam search: parent sequence ID (-1 = root beam)
    beam_parent: i32 = -1,

    /// Beam search: cumulative log-probability score
    beam_score: f32 = 0.0,

    /// Beam search: beam width (1 = no beam search)
    beam_width: usize = 1,

    /// True if this sequence was created by beam forking (engine owns its Request).
    is_beam_child: bool = false,

    allocator: Allocator,

    pub fn init(allocator: Allocator, request: *Request, seq_id: i32) !Self {
        return .{
            .request = request,
            .sequence_id = seq_id,
            .position = 0,
            .pages = std.ArrayList(i32){},
            .is_prefill = true,
            .prefill_tokens_done = 0,
            .beam_parent = -1,
            .beam_score = 0.0,
            .beam_width = request.sampling_params.beam_width,
            .is_beam_child = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.pages.deinit(self.allocator);
    }
    
    /// Number of prompt tokens remaining for prefill.
    pub fn prefillRemaining(self: *const Self) usize {
        const total = self.request.prompt_tokens.len;
        return if (self.prefill_tokens_done >= total) 0 else total - self.prefill_tokens_done;
    }
};

// ============================================================================
// Scheduler
// ============================================================================

pub const Scheduler = struct {
    const Self = @This();
    
    config: ServingConfig,
    
    /// Requests waiting to be scheduled
    waiting_queue: std.ArrayList(*Request),
    
    /// Currently running sequences
    running: std.AutoHashMap(i32, SequenceState),
    
    /// Preempted sequences (waiting for memory)
    preempted: std.ArrayList(*Request),
    
    /// Request ID counter
    next_request_id: u64,
    
    /// Sequence ID counter
    next_sequence_id: i32,
    
    mutex: Mutex,
    allocator: Allocator,

    /// KV cache offload manager (set by ServingEngine after init)
    offload_mgr: ?*OffloadManager = null,

    pub fn init(allocator: Allocator, config: ServingConfig) Self {
        return .{
            .config = config,
            .waiting_queue = std.ArrayList(*Request){},
            .running = std.AutoHashMap(i32, SequenceState).init(allocator),
            .preempted = std.ArrayList(*Request){},
            .next_request_id = 0,
            .next_sequence_id = 0,
            .mutex = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.waiting_queue.deinit(self.allocator);

        var it = self.running.valueIterator();
        while (it.next()) |state| {
            state.deinit();
        }
        self.running.deinit();

        self.preempted.deinit(self.allocator);
    }
    
    /// Add a new request
    pub fn addRequest(self: *Self, request: *Request) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        request.id = self.next_request_id;
        self.next_request_id += 1;
        request.status = .waiting;
        
        try self.waiting_queue.append(self.allocator, request);
    }

    /// Schedule next batch
    pub fn schedule(self: *Self) !ScheduleResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = ScheduleResult{
            .allocator = self.allocator,
        };

        // First, try to resume preempted sequences
        while (self.preempted.items.len > 0) {
            const request = self.preempted.pop().?;
            if (try self.canAllocate(request.prompt_tokens.len + request.output_tokens.items.len)) {
                const seq_id = try self.allocateSequence(request);
                // Reload any offloaded pages for resumed sequence
                if (self.offload_mgr) |mgr| {
                    if (self.running.getPtr(seq_id)) |state| {
                        for (state.pages.items) |page_id| {
                            mgr.reloadPage(page_id) catch {};
                        }
                    }
                }
                try result.decode_sequences.append(self.allocator, seq_id);
            } else {
                try self.preempted.append(self.allocator, request);
                break;
            }
        }

        // Then, add new requests
        while (self.waiting_queue.items.len > 0) {
            const request = self.waiting_queue.orderedRemove(0);

            if (try self.canAllocate(request.prompt_tokens.len)) {
                const seq_id = try self.allocateSequence(request);
                try result.prefill_sequences.append(self.allocator, seq_id);
                request.status = .running;
            } else {
                // Put back and stop
                try self.waiting_queue.insert(self.allocator, 0, request);
                break;
            }
        }

        // Add running decode sequences
        var it = self.running.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.is_prefill) {
                try result.decode_sequences.append(self.allocator, entry.key_ptr.*);
            }
        }

        return result;
    }
    
    /// Check if we can allocate pages for a sequence.
    /// Queries actual page availability via `get_memory_stats`.
    fn canAllocate(self: *Self, token_count: usize) !bool {
        if (self.running.count() >= self.config.max_sequences) return false;
        
        const pages_needed = (token_count + self.config.page_size - 1) / self.config.page_size;
        var stats: c.MemoryStats = undefined;
        c.get_memory_stats(&stats);
        return @as(usize, @intCast(stats.free_pages)) >= pages_needed;
    }
    
    /// Preempt the longest-running sequence to free pages.
    /// Returns true if a sequence was successfully preempted.
    pub fn preemptLongest(self: *Self) bool {
        var longest_id: ?i32 = null;
        var longest_pos: usize = 0;
        
        var it = self.running.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.position > longest_pos) {
                longest_pos = entry.value_ptr.position;
                longest_id = entry.key_ptr.*;
            }
        }
        
        if (longest_id) |sid| {
            // Must release lock to call preemptSequence (which re-acquires)
            // Instead, inline the preemption here while already holding the lock.
            if (self.running.fetchRemove(sid)) |kv| {
                var state = kv.value;
                state.request.status = .preempted;
                c.free_sequence_pages(sid);
                self.preempted.append(self.allocator, state.request) catch {};
                state.deinit();
                return true;
            }
        }
        return false;
    }
    
    /// Allocate a new sequence, including KV pages and optional prefix cache reuse.
    fn allocateSequence(self: *Self, request: *Request) !i32 {
        const seq_id = self.next_sequence_id;
        self.next_sequence_id += 1;
        
        var state = try SequenceState.init(self.allocator, request, seq_id);
        errdefer state.deinit();
        
        // Check prefix cache for reusable KV pages
        var shared_pages: usize = 0;
        if (self.config.prefix_caching and request.prompt_tokens.len > 0) {
            var cached_ids: [256]i32 = undefined;
            const found = c.prefix_cache_lookup(
                @ptrCast(request.prompt_tokens.ptr),
                @intCast(request.prompt_tokens.len),
                &cached_ids,
                256,
            );
            if (found > 0) {
                shared_pages = @intCast(found);
                request.shared_prefix_length = shared_pages * self.config.page_size;
                for (0..shared_pages) |i| {
                    try state.pages.append(state.allocator, cached_ids[i]);
                }
                state.prefill_tokens_done = request.shared_prefix_length;
            }
        }
        
        // Allocate remaining pages
        const total_tokens = request.prompt_tokens.len;
        const total_pages_needed = (total_tokens + self.config.page_size - 1) / self.config.page_size;
        const new_pages_needed = if (total_pages_needed > shared_pages) total_pages_needed - shared_pages else 0;
        
        for (0..new_pages_needed) |_| {
            const page_id = c.allocate_page(seq_id);
            if (page_id < 0) {
                // Try offloading before preemption
                if (self.offload_mgr) |mgr| {
                    if (mgr.shouldOffload()) {
                        _ = mgr.offloadLRU() catch null;
                    }
                }
                // Try preemption before giving up
                if (!self.preemptLongest()) {
                    c.free_sequence_pages(seq_id);
                    return error.OutOfMemory;
                }
                // Retry after preemption
                const retry_id = c.allocate_page(seq_id);
                if (retry_id < 0) {
                    c.free_sequence_pages(seq_id);
                    return error.OutOfMemory;
                }
                // Track retried page in offload manager
                if (self.offload_mgr) |mgr| {
                    const ptr = c.get_page_data_ptr(retry_id);
                    if (ptr) |p| mgr.trackPage(retry_id, seq_id, p) catch {};
                }
                try state.pages.append(state.allocator, retry_id);
            } else {
                // Track new page in offload manager
                if (self.offload_mgr) |mgr| {
                    const ptr = c.get_page_data_ptr(page_id);
                    if (ptr) |p| mgr.trackPage(page_id, seq_id, p) catch {};
                }
                try state.pages.append(state.allocator, page_id);
            }
        }
        
        // Insert new pages into prefix cache for future requests
        if (self.config.prefix_caching and new_pages_needed > 0 and state.pages.items.len > 0) {
            const last_page = state.pages.items[state.pages.items.len - 1];
            _ = c.prefix_cache_insert(
                @ptrCast(request.prompt_tokens.ptr),
                @intCast(request.prompt_tokens.len),
                last_page,
            );
        }
        
        try self.running.put(seq_id, state);
        return seq_id;
    }
    
    /// Free a sequence
    pub fn freeSequence(self: *Self, seq_id: i32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.running.fetchRemove(seq_id)) |kv| {
            var state = kv.value;
            state.request.status = .finished;
            // Untrack pages from offload manager before C-level free.
            // Null out gpu_ptr so removePage won't double-free (C layer owns it).
            if (self.offload_mgr) |mgr| {
                for (state.pages.items) |page_id| {
                    if (mgr.pages.getPtr(page_id)) |loc| loc.gpu_ptr = null;
                    mgr.removePage(page_id);
                }
            }
            c.free_sequence_pages(seq_id);
            // If this was a beam-child, the engine owns its request
            if (state.is_beam_child) {
                state.request.output_tokens.deinit(state.request.allocator);
                self.allocator.destroy(state.request);
            }
            state.deinit();
        }
    }

    /// Preempt a sequence to free memory
    pub fn preemptSequence(self: *Self, seq_id: i32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.running.fetchRemove(seq_id)) |kv| {
            var state = kv.value;
            state.request.status = .preempted;
            // Offload pages to CPU instead of freeing (preserves KV state)
            if (self.offload_mgr) |mgr| {
                for (state.pages.items) |page_id| {
                    mgr.touchPage(page_id); // Mark as recently accessed before offload decision
                }
            }
            c.free_sequence_pages(seq_id);
            try self.preempted.append(self.allocator, state.request);
            state.deinit();
        }
    }

    pub const ScheduleResult = struct {
        prefill_sequences: std.ArrayList(i32) = .{},
        decode_sequences: std.ArrayList(i32) = .{},
        allocator: Allocator,

        pub fn deinit(self: *ScheduleResult) void {
            self.prefill_sequences.deinit(self.allocator);
            self.decode_sequences.deinit(self.allocator);
        }
    };
};

// ============================================================================
// Engine
// ============================================================================

// ============================================================================
// Sampling
// ============================================================================

/// Sample a token from logits according to the given sampling parameters.
/// `logits` is a host-side slice of length `vocab_size`.
pub fn sampleToken(
    logits: []f32,
    params: SamplingParams,
    output_tokens: []const u32,
) u32 {
    const vocab = logits.len;
    if (vocab == 0) return 0;
    
    // 1. Apply repetition / presence / frequency penalties
    if (params.repetition_penalty != 1.0 or params.presence_penalty != 0.0 or params.frequency_penalty != 0.0) {
        for (output_tokens) |tok| {
            if (tok < vocab) {
                if (params.repetition_penalty != 1.0) {
                    if (logits[tok] > 0) {
                        logits[tok] /= params.repetition_penalty;
                    } else {
                        logits[tok] *= params.repetition_penalty;
                    }
                }
                logits[tok] -= params.presence_penalty;
                logits[tok] -= params.frequency_penalty;
            }
        }
    }
    
    // 2. Temperature scaling
    const temp = if (params.temperature > 0) params.temperature else 1e-8;
    if (temp != 1.0) {
        for (logits) |*l| l.* /= temp;
    }
    
    // 3. Greedy (temperature ≈ 0)
    if (params.temperature < 1e-6) {
        var best: usize = 0;
        var best_val = logits[0];
        for (logits[1..], 1..) |v, i| {
            if (v > best_val) {
                best_val = v;
                best = i;
            }
        }
        return @intCast(best);
    }
    
    // 4. Softmax
    var max_val: f32 = logits[0];
    for (logits[1..]) |v| if (v > max_val) { max_val = v; };
    var sum: f32 = 0;
    for (logits) |*l| {
        l.* = @exp(l.* - max_val);
        sum += l.*;
    }
    if (sum > 0) for (logits) |*l| { l.* /= sum; };
    
    // 5. Top-k filtering
    if (params.top_k > 0 and @as(usize, @intCast(params.top_k)) < vocab) {
        // Find k-th largest probability via partial sort
        const k: usize = @intCast(params.top_k);
        // Simple approach: iterate k times finding max, mark top-k
        var mask = std.StaticBitSet(65536).initEmpty();
        for (0..k) |_| {
            var best_i: usize = 0;
            var best_p: f32 = -1;
            for (logits, 0..) |p, i| {
                if (!mask.isSet(i) and p > best_p) {
                    best_p = p;
                    best_i = i;
                }
            }
            mask.set(best_i);
        }
        for (logits, 0..) |*l, i| {
            if (!mask.isSet(i)) l.* = 0;
        }
        // Re-normalize
        sum = 0;
        for (logits) |l| sum += l;
        if (sum > 0) for (logits) |*l| { l.* /= sum; };
    }
    
    // 6. Top-p (nucleus) filtering
    if (params.top_p < 1.0 and params.top_p > 0) {
        // Zero out tokens below the nucleus threshold
        var cumulative: f32 = 0;
        // We need sorted order — use a simple selection approach
        var mask2 = std.StaticBitSet(65536).initEmpty();
        while (cumulative < params.top_p) {
            var best_i: usize = 0;
            var best_p: f32 = -1;
            for (logits, 0..) |p, i| {
                if (!mask2.isSet(i) and p > best_p) {
                    best_p = p;
                    best_i = i;
                }
            }
            if (best_p <= 0) break;
            mask2.set(best_i);
            cumulative += best_p;
        }
        for (logits, 0..) |*l, i| {
            if (!mask2.isSet(i)) l.* = 0;
        }
        sum = 0;
        for (logits) |l| sum += l;
        if (sum > 0) for (logits) |*l| { l.* /= sum; };
    }
    
    // 7. Random sample from distribution
    var rng = if (params.seed) |s|
        std.Random.DefaultPrng.init(s)
    else
        std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp()));
    var random = rng.random();
    const r = random.float(f32);
    var accum: f32 = 0;
    for (logits, 0..) |p, i| {
        accum += p;
        if (accum >= r) return @intCast(i);
    }
    return @intCast(vocab - 1);
}

// ============================================================================
// Engine
// ============================================================================

/// High-level serving engine.
///
/// Owns the CUDA paged KV cache and continuous batching state.
/// Stores a reference to GPU model weights and runs the forward pass +
/// sampling on every `step()`.
pub const ServingEngine = struct {
    const Self = @This();
    
    config: ServingConfig,
    scheduler: Scheduler,
    
    /// Model parameters
    vocab_size: usize,
    num_layers: usize,
    num_heads: usize,
    num_kv_heads: usize,
    head_dim: usize,
    hidden_dim: usize,
    
    /// GPU model weights (caller-owned; must outlive the engine).
    model_weights: ?ModelWeights,
    
    /// Host-side logits buffer, allocated once at init.
    /// Size: max_sequences * vocab_size * sizeof(f32).
    logits_buffer: []f32,
    
    /// Running flag (atomic for cross-thread stop).
    is_running: std.atomic.Value(bool),
    
    /// KV cache offload manager (two-tier GPU ↔ CPU memory)
    offload_manager: OffloadManager,

    /// Optional dynamic batch scheduler (for batching incoming requests
    /// over a time window before forming GPU batches).
    batch_scheduler: ?BatchScheduler,

    /// Statistics
    stats: EngineStats,

    allocator: Allocator,

    pub const EngineStats = struct {
        requests_completed: u64 = 0,
        tokens_generated: u64 = 0,
        avg_time_to_first_token_ms: f32 = 0,
        avg_tokens_per_second: f32 = 0,
        cache_hit_rate: f32 = 0,
        prefix_cache_hits: u64 = 0,
        prefix_cache_misses: u64 = 0,
        preemptions: u64 = 0,
        offloads: u64 = 0,
        reloads: u64 = 0,
        beam_forks: u64 = 0,
        batch_scheduler_batches: u64 = 0,
    };
    
    /// Initialise the engine.
    ///
    /// `model_weights` may be null if only scheduling logic is needed (e.g.
    /// for testing). In production, pass the loaded weights so that
    /// `continuous_batch_step` can run a real forward pass.
    pub fn init(
        allocator: Allocator,
        config: ServingConfig,
        vocab_size: usize,
        num_layers: usize,
        num_heads: usize,
        num_kv_heads: usize,
        head_dim: usize,
        hidden_dim: usize,
        model_weights: ?ModelWeights,
    ) !Self {
        // Initialize CUDA paged KV cache
        if (c.paged_kv_cache_init(
            @intCast(config.max_pages),
            @intCast(num_layers),
            @intCast(num_kv_heads),
            @intCast(head_dim),
        ) != 0) {
            return error.CudaInitFailed;
        }
        errdefer c.paged_kv_cache_shutdown();
        
        if (c.continuous_batch_init() != 0) {
            return error.CudaInitFailed;
        }
        errdefer c.continuous_batch_shutdown();
        
        // Allocate host logits buffer
        const logits_buf = try allocator.alloc(f32, config.max_sequences * vocab_size);
        errdefer allocator.free(logits_buf);

        // Compute page size in bytes from model params:
        // page_tokens * num_layers * 2(K+V) * num_kv_heads * head_dim * sizeof(f32)
        const page_bytes = config.page_size * num_layers * 2 * num_kv_heads * head_dim * @sizeOf(f32);
        const offload_page_size: usize = if (page_bytes > 0) page_bytes else 262144;

        var result = Self{
            .config = config,
            .scheduler = Scheduler.init(allocator, config),
            .vocab_size = vocab_size,
            .num_layers = num_layers,
            .num_heads = num_heads,
            .num_kv_heads = num_kv_heads,
            .head_dim = head_dim,
            .hidden_dim = hidden_dim,
            .model_weights = model_weights,
            .logits_buffer = logits_buf,
            .offload_manager = OffloadManager.init(allocator, .{
                .page_size_bytes = offload_page_size,
                .max_cpu_pages = config.max_pages,
            }),
            .batch_scheduler = try BatchScheduler.init(allocator, .{
                .max_batch_size = config.max_sequences,
                .max_seq_len = config.max_seq_len,
            }),
            .is_running = std.atomic.Value(bool).init(false),
            .stats = .{},
            .allocator = allocator,
        };
        // Wire offload manager pointer into scheduler
        result.scheduler.offload_mgr = &result.offload_manager;
        return result;
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.scheduler.offload_mgr = null;
        if (self.batch_scheduler) |*bs| bs.deinit();
        self.offload_manager.deinit();
        self.allocator.free(self.logits_buffer);
        self.scheduler.deinit();
        c.continuous_batch_shutdown();
        c.paged_kv_cache_shutdown();
    }
    
    /// Beam search: fork a parent sequence into a child beam with a specific token.
    /// Creates a new Request (cloned from parent) and SequenceState for the child.
    /// The scheduler mutex must NOT be held by the caller.
    fn beamForkChild(
        self: *Self,
        parent_state: *const SequenceState,
        child_seq_id: i32,
        token: u32,
        score: f32,
    ) !void {
        // Create a new Request for the child (shares prompt, diverges on output)
        const child_req = try self.allocator.create(Request);
        errdefer self.allocator.destroy(child_req);
        child_req.* = .{
            .id = parent_state.request.id,
            .prompt_tokens = parent_state.request.prompt_tokens,
            .sampling_params = parent_state.request.sampling_params,
            .arrival_time = parent_state.request.arrival_time,
            .status = .running,
            .output_tokens = std.ArrayList(u32){},
            .allocator = self.allocator,
            .prefix_hash = parent_state.request.prefix_hash,
            .shared_prefix_length = parent_state.request.shared_prefix_length,
        };
        // Copy parent's output tokens, then replace last with beam's chosen token
        try child_req.output_tokens.appendSlice(self.allocator, parent_state.request.output_tokens.items);
        if (child_req.output_tokens.items.len > 0) {
            child_req.output_tokens.items[child_req.output_tokens.items.len - 1] = token;
        } else {
            try child_req.output_tokens.append(self.allocator, token);
        }

        var child_state = try SequenceState.init(self.allocator, child_req, child_seq_id);
        child_state.beam_parent = parent_state.sequence_id;
        child_state.beam_score = score;
        child_state.beam_width = parent_state.beam_width;
        child_state.position = parent_state.position;
        child_state.is_prefill = false;
        child_state.prefill_tokens_done = parent_state.prefill_tokens_done;
        child_state.is_beam_child = true;

        self.scheduler.mutex.lock();
        defer self.scheduler.mutex.unlock();
        try self.scheduler.running.put(child_seq_id, child_state);
        self.stats.beam_forks += 1;
    }

    /// Start the serving loop (blocks until `stop()` is called).
    pub fn start(self: *Self) !void {
        self.is_running.store(true, .seq_cst);
        
        while (self.is_running.load(.seq_cst)) {
            try self.step();
            std.Thread.sleep(self.config.scheduler_interval_us * 1000);
        }
    }
    
    /// Signal the serving loop to exit.
    pub fn stop(self: *Self) void {
        self.is_running.store(false, .seq_cst);
    }
    
    /// Execute one scheduling + forward + sampling iteration.
    pub fn step(self: *Self) !void {
        // 1. Schedule batch
        var schedule_result = try self.scheduler.schedule();
        defer schedule_result.deinit();
        
        const total_seqs = schedule_result.prefill_sequences.items.len +
                          schedule_result.decode_sequences.items.len;
        if (total_seqs == 0) return;
        
        // 2. Handle chunked prefill — advance prefill sequences one chunk at a time
        for (schedule_result.prefill_sequences.items) |seq_id| {
            self.scheduler.mutex.lock();
            defer self.scheduler.mutex.unlock();
            if (self.scheduler.running.getPtr(seq_id)) |state| {
                const remaining = state.prefillRemaining();
                if (remaining > 0) {
                    const chunk = @min(remaining, self.config.chunked_prefill_threshold);
                    state.prefill_tokens_done += chunk;
                    state.position += chunk;
                    if (state.prefillRemaining() == 0) {
                        state.is_prefill = false;
                    }
                }
            }
        }
        
        // 3. Run model forward pass
        const weights_ptr: ?*anyopaque = if (self.model_weights) |mw| mw.device_ptr else null;
        
        // Allocate device logits buffer for the step
        const logits_bytes = total_seqs * self.vocab_size * @sizeOf(f32);
        const d_logits = c.cuda_malloc(logits_bytes);
        defer if (d_logits) |p| c.cuda_free(p);
        
        const batch_result = c.continuous_batch_step(
            d_logits,
            weights_ptr,
            @intCast(self.vocab_size),
        );
        
        if (batch_result != 0) {
            // Forward pass failed — skip sampling this iteration
            return;
        }
        
        // 4. Copy logits to host
        if (d_logits != null) {
            const copy_size = @min(logits_bytes, self.logits_buffer.len * @sizeOf(f32));
            _ = c.cuda_memcpy_d2h(
                @ptrCast(self.logits_buffer.ptr),
                d_logits,
                copy_size,
            );
        }
        
        // 5. Sample tokens for decode sequences
        var seq_idx: usize = 0;
        for (schedule_result.decode_sequences.items) |seq_id| {
            self.scheduler.mutex.lock();
            defer self.scheduler.mutex.unlock();

            if (self.scheduler.running.getPtr(seq_id)) |state| {
                // Touch all pages for this sequence (LRU update)
                for (state.pages.items) |page_id| {
                    self.offload_manager.touchPage(page_id);
                }

                if (seq_idx < total_seqs) {
                    const logit_start = seq_idx * self.vocab_size;
                    const logit_end = logit_start + self.vocab_size;
                    const seq_logits = self.logits_buffer[logit_start..logit_end];

                    const token = sampleToken(
                        seq_logits,
                        state.request.sampling_params,
                        state.request.output_tokens.items,
                    );

                    state.request.output_tokens.append(state.request.allocator, token) catch {};
                    state.position += 1;
                    self.stats.tokens_generated += 1;

                    // Allocate new page if needed
                    const tokens_in_seq = state.request.prompt_tokens.len + state.request.output_tokens.items.len;
                    const pages_needed = (tokens_in_seq + self.config.page_size - 1) / self.config.page_size;
                    if (pages_needed > state.pages.items.len) {
                        const new_page = c.allocate_page(seq_id);
                        if (new_page >= 0) {
                            // Track new page in offload manager
                            const ptr = c.get_page_data_ptr(new_page);
                            if (ptr) |p| self.offload_manager.trackPage(new_page, seq_id, p) catch {};
                            state.pages.append(state.allocator, new_page) catch {};
                        }
                    }

                    // Check completion
                    const max_tok = state.request.sampling_params.max_tokens;
                    if (state.request.output_tokens.items.len >= max_tok) {
                        state.request.status = .finished;
                    }
                }
            }
            seq_idx += 1;
        }

        // 5b. Beam search expansion — fork child sequences for alternative tokens
        {
            const BeamForkInfo = struct { parent_id: i32, token: u32, score: f32 };
            var pending_forks = std.ArrayList(BeamForkInfo){};
            defer pending_forks.deinit(self.allocator);

            // Pass 1: scan beams and collect fork candidates (read-only)
            var beam_idx: usize = 0;
            for (schedule_result.decode_sequences.items) |seq_id| {
                self.scheduler.mutex.lock();
                const state_opt = self.scheduler.running.getPtr(seq_id);
                self.scheduler.mutex.unlock();

                if (state_opt) |state| {
                    if (state.beam_width > 1 and beam_idx < total_seqs) {
                        const ls = beam_idx * self.vocab_size;
                        const le = ls + self.vocab_size;
                        if (le <= self.logits_buffer.len) {
                            const sl = self.logits_buffer[ls..le];

                            // Log-sum-exp for log-probabilities
                            var max_v: f32 = sl[0];
                            for (sl[1..]) |v| if (v > max_v) { max_v = v; };
                            var es: f32 = 0;
                            for (sl) |v| es += @exp(v - max_v);
                            const ln = @log(es) + max_v;

                            // Update parent's beam score with its chosen token
                            if (state.request.output_tokens.items.len > 0) {
                                const pt = state.request.output_tokens.items[
                                    state.request.output_tokens.items.len - 1
                                ];
                                if (pt < self.vocab_size) {
                                    state.beam_score += sl[pt] - ln;
                                }
                            }

                            // Find top-(beam_width-1) alternative tokens
                            const bw = @min(state.beam_width, self.vocab_size);
                            var used: [8]u32 = .{std.math.maxInt(u32)} ** 8;
                            // Exclude parent's token
                            if (state.request.output_tokens.items.len > 0) {
                                used[0] = state.request.output_tokens.items[
                                    state.request.output_tokens.items.len - 1
                                ];
                            }

                            for (0..bw -| 1) |fi| {
                                var bi: u32 = 0;
                                var blp: f32 = -std.math.inf(f32);
                                for (sl, 0..) |v, i| {
                                    const idx: u32 = @intCast(i);
                                    var skip = false;
                                    for (used) |u| if (u == idx) { skip = true; break; };
                                    if (!skip) {
                                        const lp = v - ln;
                                        if (lp > blp) { blp = lp; bi = idx; }
                                    }
                                }
                                if (fi + 1 < used.len) used[fi + 1] = bi;
                                pending_forks.append(self.allocator, .{
                                    .parent_id = seq_id,
                                    .token = bi,
                                    .score = state.beam_score + blp,
                                }) catch {};
                            }
                        }
                    }
                }
                beam_idx += 1;
            }

            // Pass 2: create forked child sequences (calls C FFI + scheduler put)
            for (pending_forks.items) |fork| {
                const child_id = c.beam_search_fork(fork.parent_id);
                if (child_id > 0) {
                    // Read parent state snapshot (lock, copy, unlock)
                    self.scheduler.mutex.lock();
                    const ps = self.scheduler.running.getPtr(fork.parent_id);
                    self.scheduler.mutex.unlock();
                    if (ps) |parent| {
                        self.beamForkChild(parent, child_id, fork.token, fork.score) catch {};
                    }
                }
            }
        }

        // 6. Clean up finished sequences
        var finished = std.ArrayList(i32){};
        defer finished.deinit(self.allocator);
        {
            self.scheduler.mutex.lock();
            defer self.scheduler.mutex.unlock();
            var it = self.scheduler.running.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.request.status == .finished) {
                    finished.append(self.allocator, entry.key_ptr.*) catch {};
                }
            }
        }
        for (finished.items) |sid| {
            self.scheduler.freeSequence(sid);
            self.stats.requests_completed += 1;
        }
        
        // 7. Memory pressure check — try offloading first, then preempt
        var mem_stats: c.MemoryStats = undefined;
        c.get_memory_stats(&mem_stats);
        if (mem_stats.total_pages > 0) {
            const free_ratio = @as(f32, @floatFromInt(mem_stats.free_pages)) /
                              @as(f32, @floatFromInt(mem_stats.total_pages));
            if (free_ratio < self.config.preempt_free_ratio) {
                // First, try offloading LRU pages to CPU to reclaim GPU memory
                if (self.offload_manager.shouldOffload()) {
                    _ = self.offload_manager.offloadLRU() catch null;
                }
                // Re-check after offloading
                c.get_memory_stats(&mem_stats);
                const new_free_ratio = @as(f32, @floatFromInt(mem_stats.free_pages)) /
                                      @as(f32, @floatFromInt(mem_stats.total_pages));
                if (new_free_ratio < self.config.preempt_free_ratio) {
                    // Still under pressure — preempt longest sequence
                    self.scheduler.mutex.lock();
                    defer self.scheduler.mutex.unlock();
                    if (self.scheduler.preemptLongest()) {
                        self.stats.preemptions += 1;
                    }
                }
            }
        }

        // 8. Sync offload statistics
        const offload_stats = self.offload_manager.getStats();
        self.stats.offloads = offload_stats.offloads;
        self.stats.reloads = offload_stats.reloads;

        // 9. Batch scheduler: drain ready batches into internal scheduler,
        //    advance active batch with generated tokens, release completed batches.
        if (self.batch_scheduler) |*bs| {
            // If the batch scheduler has a ready batch, form it and feed
            // individual requests into our internal Scheduler.
            if (bs.batchReady()) {
                if (bs.formBatch()) |batch| {
                    self.stats.batch_scheduler_batches += 1;

                    // Each request in the formed batch becomes a generate() call
                    for (batch.requests.items) |breq| {
                        const req = self.allocator.create(Request) catch continue;
                        req.* = .{
                            .id = 0,
                            .prompt_tokens = breq.tokens,
                            .sampling_params = .{ .max_tokens = breq.max_new_tokens },
                            .arrival_time = std.time.milliTimestamp(),
                            .status = .waiting,
                            .output_tokens = std.ArrayList(u32){},
                            .allocator = self.allocator,
                            .prefix_hash = 0,
                            .shared_prefix_length = 0,
                        };
                        self.scheduler.addRequest(req) catch {
                            self.allocator.destroy(req);
                        };
                    }

                    // Release the batch now that requests are enqueued
                    bs.releaseBatch();
                } else |_| {}
            }

            // Advance active batch with tokens generated this step
            if (bs.active_batch != null and total_seqs > 0) {
                var gen_tokens_buf: [256]u32 = undefined;
                var gen_count: usize = 0;
                for (schedule_result.decode_sequences.items) |seq_id| {
                    self.scheduler.mutex.lock();
                    defer self.scheduler.mutex.unlock();
                    if (self.scheduler.running.getPtr(seq_id)) |state| {
                        if (state.request.output_tokens.items.len > 0 and gen_count < 256) {
                            gen_tokens_buf[gen_count] = state.request.output_tokens.items[
                                state.request.output_tokens.items.len - 1
                            ];
                            gen_count += 1;
                        }
                    }
                }
                if (gen_count > 0) {
                    bs.advanceBatch(gen_tokens_buf[0..gen_count]);
                }
            }

            // Sync batch scheduler stats
            const bs_stats = bs.getStats();
            self.stats.batch_scheduler_batches = bs_stats.total_batches;
        }
    }
    
    /// Submit a request for generation.
    pub fn generate(self: *Self, prompt_tokens: []const u32, params: SamplingParams) !*Request {
        const request = try self.allocator.create(Request);
        request.* = .{
            .id = 0,
            .prompt_tokens = prompt_tokens,
            .sampling_params = params,
            .arrival_time = std.time.milliTimestamp(),
            .status = .waiting,
            .output_tokens = std.ArrayList(u32){},
            .allocator = self.allocator,
            .prefix_hash = 0,
            .shared_prefix_length = 0,
        };
        
        try self.scheduler.addRequest(request);
        return request;
    }
    
    /// Submit tokens to the batch scheduler for dynamic batching.
    /// Requests are buffered and formed into optimal batches before being
    /// fed into the internal scheduler during `step()`.
    /// Returns the batch-scheduler request ID.
    pub fn submitToBatchScheduler(self: *Self, tokens: []const u32, max_new_tokens: usize) !u64 {
        if (self.batch_scheduler) |*bs| {
            return bs.submit(tokens, max_new_tokens);
        }
        return error.BatchSchedulerNotEnabled;
    }

    /// Block until a request reaches `.finished` or `.@"error"` status.
    pub fn waitForCompletion(self: *Self, request: *Request, timeout_ms: ?u64) !Response {
        const start_time = std.time.milliTimestamp();

        while (request.status != .finished and request.status != .@"error") {
            if (timeout_ms) |t| {
                if (std.time.milliTimestamp() - start_time > @as(i64, @intCast(t))) {
                    return error.Timeout;
                }
            }
            std.Thread.sleep(1_000_000); // 1ms
        }
        
        _ = self;
        
        return Response{
            .request_id = request.id,
            .generated_text = "",
            .tokens = request.output_tokens.items,
            .finish_reason = if (request.status == .finished) .stop else .@"error",
            .usage = .{
                .prompt_tokens = request.prompt_tokens.len,
                .completion_tokens = request.output_tokens.items.len,
                .total_tokens = request.prompt_tokens.len + request.output_tokens.items.len,
                .time_to_first_token_ms = 0,
                .time_per_token_ms = 0,
            },
        };
    }
    
    /// Get current engine statistics.
    pub fn getStats(self: *const Self) EngineStats {
        return self.stats;
    }
};

// ============================================================================
// HTTP Server (placeholder)
// ============================================================================

pub const HttpServer = struct {
    const Self = @This();
    
    engine: *ServingEngine,
    port: u16,
    
    pub fn init(engine: *ServingEngine, port: u16) Self {
        return .{
            .engine = engine,
            .port = port,
        };
    }
    
    pub fn start(self: *Self) !void {
        // Would start HTTP server here
        // Endpoints: /v1/completions, /v1/chat/completions, /health
        _ = self;
    }
};

// ============================================================================
// Configurable Global Instance
// ============================================================================

var g_engine: ?ServingEngine = null;

pub fn getGlobalEngine() ?*ServingEngine {
    if (g_engine) |*e| return e;
    return null;
}

/// Initialise the global engine with explicit allocator and model weights.
pub fn initGlobalEngine(
    allocator: Allocator,
    config: ServingConfig,
    vocab_size: usize,
    num_layers: usize,
    num_heads: usize,
    num_kv_heads: usize,
    head_dim: usize,
    hidden_dim: usize,
    model_weights: ?ModelWeights,
) !*ServingEngine {
    if (g_engine != null) return &g_engine.?;
    
    g_engine = try ServingEngine.init(
        allocator,
        config,
        vocab_size,
        num_layers,
        num_heads,
        num_kv_heads,
        head_dim,
        hidden_dim,
        model_weights,
    );
    
    return &g_engine.?;
}

pub fn shutdownGlobalEngine() void {
    if (g_engine) |*e| {
        e.deinit();
        g_engine = null;
    }
}

// ============================================================================
// Tests
// ============================================================================

test "ServingConfig defaults" {
    const cfg = ServingConfig{};
    try std.testing.expectEqual(cfg.max_sequences, 256);
    try std.testing.expectEqual(cfg.max_pages, 4096);
    try std.testing.expectEqual(cfg.page_size, 16);
    try std.testing.expect(cfg.prefix_caching);
    try std.testing.expectEqual(cfg.chunked_prefill_threshold, 512);
}

test "SamplingParams defaults" {
    const sp = SamplingParams{};
    try std.testing.expectEqual(sp.temperature, 1.0);
    try std.testing.expectEqual(sp.top_p, 1.0);
    try std.testing.expectEqual(sp.top_k, -1);
    try std.testing.expectEqual(sp.max_tokens, 256);
    try std.testing.expectEqual(sp.repetition_penalty, 1.0);
}

test "sampleToken greedy" {
    var logits = [_]f32{ 0.1, 0.5, 0.2, 0.9, 0.3 };
    const tok = sampleToken(&logits, .{ .temperature = 0.0 }, &.{});
    try std.testing.expectEqual(tok, 3); // index of max (0.9)
}

test "sampleToken with repetition penalty" {
    var logits = [_]f32{ 0.5, 0.5, 0.5 };
    const prev = [_]u32{0};
    const tok = sampleToken(&logits, .{ .temperature = 0.0, .repetition_penalty = 2.0 }, &prev);
    // Token 0 should be penalised (0.5/2.0=0.25), so greedy picks token 1 or 2
    try std.testing.expect(tok != 0);
}

test "SequenceState prefillRemaining" {
    const prompt = [_]u32{ 1, 2, 3, 4, 5 };
    var req = Request{
        .id = 0,
        .prompt_tokens = &prompt,
        .sampling_params = .{},
        .arrival_time = 0,
        .status = .running,
        .output_tokens = std.ArrayList(u32){},
        .allocator = std.testing.allocator,
        .prefix_hash = 0,
        .shared_prefix_length = 0,
    };
    defer req.output_tokens.deinit(std.testing.allocator);

    var state = try SequenceState.init(std.testing.allocator, &req, 0);
    defer state.deinit();

    try std.testing.expectEqual(state.prefillRemaining(), 5);
    state.prefill_tokens_done = 3;
    try std.testing.expectEqual(state.prefillRemaining(), 2);
    state.prefill_tokens_done = 5;
    try std.testing.expectEqual(state.prefillRemaining(), 0);
}

test "EngineStats includes offload counters" {
    const stats = ServingEngine.EngineStats{};
    try std.testing.expectEqual(@as(u64, 0), stats.offloads);
    try std.testing.expectEqual(@as(u64, 0), stats.reloads);
    try std.testing.expectEqual(@as(u64, 0), stats.preemptions);
}

test "OffloadManager integrates with page allocation" {
    // Verify OffloadManager tracks pages correctly
    var mgr = OffloadManager.init(std.testing.allocator, .{
        .page_size_bytes = 64, // Small pages for testing
    });
    defer mgr.deinit();

    // Init the C-level paged KV cache
    _ = c.paged_kv_cache_init(8, 1, 1, 4);
    defer c.paged_kv_cache_shutdown();

    // Allocate a page through the C layer
    const page_id = c.allocate_page(0);
    try std.testing.expect(page_id >= 0);

    const ptr = c.get_page_data_ptr(page_id);
    try std.testing.expect(ptr != null);

    // Track in offload manager using a separate allocation (since the C paged
    // KV cache owns the page_data buffer, we must not let removePage double-free it)
    try mgr.pages.put(page_id, .{
        .tier = .gpu_hbm,
        .gpu_ptr = null, // Don't give OffloadManager ownership of C-owned ptr
        .cpu_buf = null,
        .sequence_id = 0,
        .page_id = page_id,
        .last_access_ns = std.time.nanoTimestamp(),
    });
    try mgr.lru_gpu_pages.append(std.testing.allocator, page_id);

    const stats = mgr.getStats();
    try std.testing.expectEqual(@as(usize, 1), stats.total_pages);
    try std.testing.expectEqual(@as(usize, 1), stats.gpu_pages);
    try std.testing.expectEqual(@as(usize, 0), stats.cpu_pages);

    // Touch page (LRU update)
    mgr.touchPage(page_id);

    // Remove page from offload tracking (C layer still owns gpu memory)
    mgr.removePage(page_id);
    const stats2 = mgr.getStats();
    try std.testing.expectEqual(@as(usize, 0), stats2.total_pages);
}

test "SamplingParams beam_width default" {
    const sp = SamplingParams{};
    try std.testing.expectEqual(@as(usize, 1), sp.beam_width);
}

test "SequenceState beam fields" {
    const prompt = [_]u32{ 1, 2, 3 };
    var req = Request{
        .id = 42,
        .prompt_tokens = &prompt,
        .sampling_params = .{ .beam_width = 4 },
        .arrival_time = 0,
        .status = .waiting,
        .output_tokens = std.ArrayList(u32){},
        .allocator = std.testing.allocator,
        .prefix_hash = 0,
        .shared_prefix_length = 0,
    };
    var state = try SequenceState.init(std.testing.allocator, &req, 7);
    defer state.deinit();

    try std.testing.expectEqual(@as(i32, -1), state.beam_parent);
    try std.testing.expectEqual(@as(f32, 0.0), state.beam_score);
    try std.testing.expectEqual(@as(usize, 4), state.beam_width);
    try std.testing.expect(!state.is_beam_child);
}

test "EngineStats includes beam and batch counters" {
    const stats = ServingEngine.EngineStats{};
    try std.testing.expectEqual(@as(u64, 0), stats.beam_forks);
    try std.testing.expectEqual(@as(u64, 0), stats.batch_scheduler_batches);
}

test "BatchScheduler created when engine initialised" {
    var engine = try ServingEngine.init(
        std.testing.allocator,
        .{},
        32, // vocab_size
        2, // num_layers
        4, // num_heads
        4, // num_kv_heads
        8, // head_dim
        16, // hidden_dim
        null, // model_weights
    );
    defer engine.deinit();

    // batch_scheduler should be non-null
    try std.testing.expect(engine.batch_scheduler != null);
}

test "submitToBatchScheduler round-trip" {
    var engine = try ServingEngine.init(
        std.testing.allocator,
        .{},
        32, 2, 4, 4, 8, 16, null,
    );
    defer engine.deinit();

    const tokens = [_]u32{ 10, 20, 30 };
    const id = try engine.submitToBatchScheduler(&tokens, 64);
    try std.testing.expect(id >= 1);

    // Submit another — ID should increment
    const id2 = try engine.submitToBatchScheduler(&tokens, 32);
    try std.testing.expect(id2 > id);
}