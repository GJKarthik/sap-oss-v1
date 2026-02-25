//! Scheduler - Request Scheduling and Batch Formation
//!
//! Implements the vLLM scheduler that:
//! - Manages request queues (waiting, running, swapped)
//! - Forms batches for efficient GPU utilization
//! - Handles preemption and memory pressure
//! - Integrates with Mangle rules for policy decisions

const std = @import("std");
const logging = @import("../utils/logging.zig");
const types = @import("../engine/types.zig");
const config = @import("../utils/config.zig");
const block_manager = @import("../memory/block_manager.zig");

const Request = types.Request;
const RequestState = types.RequestState;
const BlockManager = block_manager.BlockManager;
const SchedulerConfig = config.SchedulerConfig;

const log = logging.scoped(.scheduler);

/// Scheduling output for a single step
pub const SchedulerOutput = struct {
    /// Sequences in prefill stage
    prefill_seq_ids: std.ArrayList(u64),
    /// Sequences in decode stage
    decode_seq_ids: std.ArrayList(u64),
    /// Block tables for each sequence
    block_tables: std.AutoHashMap(u64, []const u32),
    /// Number of tokens to process for each sequence
    num_tokens: std.AutoHashMap(u64, u32),
    /// Sequences that were preempted
    preempted_seq_ids: std.ArrayList(u64),
    /// Sequences that were swapped out
    swapped_out_seq_ids: std.ArrayList(u64),
    /// Whether any sequences are running
    is_empty: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .prefill_seq_ids = std.ArrayList(u64).init(allocator),
            .decode_seq_ids = std.ArrayList(u64).init(allocator),
            .block_tables = std.AutoHashMap(u64, []const u32).init(allocator),
            .num_tokens = std.AutoHashMap(u64, u32).init(allocator),
            .preempted_seq_ids = std.ArrayList(u64).init(allocator),
            .swapped_out_seq_ids = std.ArrayList(u64).init(allocator),
            .is_empty = true,
        };
    }

    pub fn deinit(self: *Self) void {
        self.prefill_seq_ids.deinit();
        self.decode_seq_ids.deinit();
        self.block_tables.deinit();
        self.num_tokens.deinit();
        self.preempted_seq_ids.deinit();
        self.swapped_out_seq_ids.deinit();
    }

    pub fn totalSequences(self: *const Self) usize {
        return self.prefill_seq_ids.items.len + self.decode_seq_ids.items.len;
    }
};

/// Sequence metadata for scheduling
pub const SequenceData = struct {
    /// Unique sequence ID
    seq_id: u64,
    /// Associated request
    request: *Request,
    /// Current state
    state: SequenceState,
    /// Number of tokens in the prompt
    prompt_len: u32,
    /// Number of tokens generated so far
    output_len: u32,
    /// Priority (higher = more important)
    priority: i32,
    /// Arrival time (for FCFS ordering)
    arrival_time: i64,
    /// Last scheduled time
    last_scheduled: i64,
    /// Number of times preempted
    preemption_count: u32,
    /// Whether this sequence can be preempted
    can_preempt: bool,

    const Self = @This();

    pub fn totalLen(self: *const Self) u32 {
        return self.prompt_len + self.output_len;
    }

    pub fn remainingTokens(self: *const Self) u32 {
        const max_tokens = self.request.sampling_params.max_tokens orelse 256;
        if (self.output_len >= max_tokens) return 0;
        return max_tokens - self.output_len;
    }

    pub fn isFinished(self: *const Self) bool {
        return self.remainingTokens() == 0 or self.state == .finished;
    }
};

/// State of a sequence in the scheduler
pub const SequenceState = enum {
    /// Waiting in queue (not yet started)
    waiting,
    /// Running (actively generating)
    running,
    /// Swapped out to CPU
    swapped,
    /// Finished generation
    finished,
    /// Failed or aborted
    aborted,
};

/// Preemption mode
pub const PreemptionMode = enum {
    /// Recompute KV-cache when resuming
    recompute,
    /// Swap KV-cache to CPU memory
    swap,
};

/// Scheduler for managing inference requests
pub const Scheduler = struct {
    /// Memory allocator
    allocator: std.mem.Allocator,
    /// Scheduler configuration
    config: SchedulerConfig,
    /// Block manager for KV-cache
    block_manager: *BlockManager,

    /// Waiting queue (FCFS order)
    waiting: std.ArrayList(*SequenceData),
    /// Running sequences
    running: std.ArrayList(*SequenceData),
    /// Swapped sequences
    swapped: std.ArrayList(*SequenceData),

    /// Sequence ID counter
    next_seq_id: u64,
    /// Sequence data storage
    sequences: std.AutoHashMap(u64, *SequenceData),

    /// Statistics
    stats: SchedulerStats,

    /// Mutex for thread safety
    mutex: std.Thread.Mutex = .{},

    const Self = @This();

    /// Initialize the scheduler
    pub fn init(
        allocator: std.mem.Allocator,
        scheduler_config: SchedulerConfig,
        blk_manager: *BlockManager,
    ) !*Self {
        log.info("Initializing Scheduler with max_num_seqs={d}", .{scheduler_config.max_num_seqs});

        var self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .config = scheduler_config,
            .block_manager = blk_manager,
            .waiting = std.ArrayList(*SequenceData).init(allocator),
            .running = std.ArrayList(*SequenceData).init(allocator),
            .swapped = std.ArrayList(*SequenceData).init(allocator),
            .next_seq_id = 1,
            .sequences = std.AutoHashMap(u64, *SequenceData).init(allocator),
            .stats = .{},
        };

        return self;
    }

    /// Deinitialize and free resources
    pub fn deinit(self: *Self) void {
        log.info("Shutting down Scheduler", .{});

        // Free all sequence data
        var iter = self.sequences.valueIterator();
        while (iter.next()) |seq| {
            self.allocator.destroy(seq.*);
        }
        self.sequences.deinit();

        self.waiting.deinit();
        self.running.deinit();
        self.swapped.deinit();

        self.allocator.destroy(self);
    }

    /// Add a new request to the scheduler
    pub fn addRequest(self: *Self, request: *Request) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const seq_id = self.next_seq_id;
        self.next_seq_id += 1;

        var seq_data = try self.allocator.create(SequenceData);
        seq_data.* = SequenceData{
            .seq_id = seq_id,
            .request = request,
            .state = .waiting,
            .prompt_len = request.prompt_len,
            .output_len = 0,
            .priority = request.priority,
            .arrival_time = std.time.nanoTimestamp(),
            .last_scheduled = 0,
            .preemption_count = 0,
            .can_preempt = true,
        };

        try self.sequences.put(seq_id, seq_data);
        try self.waiting.append(seq_data);

        self.stats.total_sequences += 1;

        log.debug("Added sequence {d} with {d} prompt tokens", .{ seq_id, request.prompt_len });

        return seq_id;
    }

    /// Abort a sequence
    pub fn abortSequence(self: *Self, seq_id: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const seq_data = self.sequences.get(seq_id) orelse return error.SequenceNotFound;
        seq_data.state = .aborted;

        // Remove from appropriate queue
        self.removeFromQueue(&self.waiting, seq_id);
        self.removeFromQueue(&self.running, seq_id);
        self.removeFromQueue(&self.swapped, seq_id);

        // Free blocks
        self.block_manager.free(seq_id);

        log.debug("Aborted sequence {d}", .{seq_id});
    }

    /// Schedule the next batch of sequences
    pub fn schedule(self: *Self) !SchedulerOutput {
        self.mutex.lock();
        defer self.mutex.unlock();

        var output = SchedulerOutput.init(self.allocator);
        errdefer output.deinit();

        // Phase 1: Try to continue running sequences
        try self.scheduleRunning(&output);

        // Phase 2: Try to start waiting sequences
        try self.scheduleWaiting(&output);

        // Phase 3: Try to swap in swapped sequences
        try self.scheduleSwapped(&output);

        output.is_empty = output.totalSequences() == 0;

        self.stats.batches_scheduled += 1;

        return output;
    }

    /// Schedule running sequences (decode phase)
    fn scheduleRunning(self: *Self, output: *SchedulerOutput) !void {
        var i: usize = 0;
        while (i < self.running.items.len) {
            const seq = self.running.items[i];

            // Check if sequence is finished
            if (seq.isFinished()) {
                seq.state = .finished;
                _ = self.running.orderedRemove(i);
                self.block_manager.free(seq.seq_id);
                self.stats.sequences_completed += 1;
                continue;
            }

            // Check if we can allocate a new block if needed
            const tokens_in_last_block = seq.totalLen() % self.block_manager.config.block_size;
            if (tokens_in_last_block == 0 and seq.output_len > 0) {
                // Need a new block
                if (!self.block_manager.canAllocate(1)) {
                    // Need to preempt
                    try self.preemptSequence(seq, output);
                    _ = self.running.orderedRemove(i);
                    continue;
                }
                _ = try self.block_manager.allocateBlock(seq.seq_id);
            }

            // Add to decode batch
            try output.decode_seq_ids.append(seq.seq_id);
            try output.num_tokens.put(seq.seq_id, 1);
            seq.last_scheduled = std.time.nanoTimestamp();

            i += 1;
        }
    }

    /// Schedule waiting sequences (prefill phase)
    fn scheduleWaiting(self: *Self, output: *SchedulerOutput) !void {
        // Calculate remaining budget
        const max_seqs = self.config.max_num_seqs;
        const current_seqs = output.totalSequences();
        if (current_seqs >= max_seqs) return;

        var budget = max_seqs - @as(u32, @intCast(current_seqs));
        const max_tokens = self.config.max_num_batched_tokens orelse 8192;

        var i: usize = 0;
        while (i < self.waiting.items.len and budget > 0) {
            const seq = self.waiting.items[i];

            // Check if we can allocate blocks for this sequence
            const blocks_needed = self.block_manager.tokensToBlocks(seq.prompt_len);
            if (!self.block_manager.canAllocate(blocks_needed)) {
                // Not enough memory - try preemption or skip
                i += 1;
                continue;
            }

            // Allocate blocks
            try self.block_manager.allocate(seq.seq_id, seq.prompt_len);

            // Move to running
            seq.state = .running;
            _ = self.waiting.orderedRemove(i);
            try self.running.append(seq);

            // Add to prefill batch
            try output.prefill_seq_ids.append(seq.seq_id);

            // For chunked prefill, we might limit tokens
            const tokens_to_process = if (self.config.enable_chunked_prefill)
                @min(seq.prompt_len, max_tokens)
            else
                seq.prompt_len;
            try output.num_tokens.put(seq.seq_id, tokens_to_process);

            seq.last_scheduled = std.time.nanoTimestamp();
            budget -= 1;

            self.stats.prefills_scheduled += 1;
        }
    }

    /// Schedule swapped sequences (swap in)
    fn scheduleSwapped(self: *Self, output: *SchedulerOutput) !void {
        const max_seqs = self.config.max_num_seqs;
        const current_seqs = output.totalSequences();
        if (current_seqs >= max_seqs) return;

        var budget = max_seqs - @as(u32, @intCast(current_seqs));

        var i: usize = 0;
        while (i < self.swapped.items.len and budget > 0) {
            const seq = self.swapped.items[i];

            // Try to swap in
            self.block_manager.swapIn(seq.seq_id) catch {
                i += 1;
                continue;
            };

            // Move to running
            seq.state = .running;
            _ = self.swapped.orderedRemove(i);
            try self.running.append(seq);

            // Add to decode batch
            try output.decode_seq_ids.append(seq.seq_id);
            try output.num_tokens.put(seq.seq_id, 1);

            seq.last_scheduled = std.time.nanoTimestamp();
            budget -= 1;

            self.stats.swaps_in += 1;
        }
    }

    /// Preempt a sequence
    fn preemptSequence(self: *Self, seq: *SequenceData, output: *SchedulerOutput) !void {
        if (self.config.preemption_mode == .swap) {
            // Swap to CPU
            try self.block_manager.swapOut(seq.seq_id);
            seq.state = .swapped;
            try self.swapped.append(seq);
            try output.swapped_out_seq_ids.append(seq.seq_id);
            self.stats.swaps_out += 1;
        } else {
            // Recompute - free blocks and move back to waiting
            self.block_manager.free(seq.seq_id);
            seq.state = .waiting;
            seq.output_len = 0; // Will need to regenerate
            try self.waiting.append(seq);
            try output.preempted_seq_ids.append(seq.seq_id);
        }

        seq.preemption_count += 1;
        self.stats.preemptions += 1;

        log.debug("Preempted sequence {d} (count: {d})", .{ seq.seq_id, seq.preemption_count });
    }

    /// Update sequence after token generation
    pub fn updateSequence(self: *Self, seq_id: u64, tokens_generated: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sequences.getPtr(seq_id)) |seq_ptr| {
            seq_ptr.*.output_len += tokens_generated;
            self.stats.tokens_generated += tokens_generated;
        }
    }

    /// Mark sequence as finished
    pub fn finishSequence(self: *Self, seq_id: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sequences.getPtr(seq_id)) |seq_ptr| {
            seq_ptr.*.state = .finished;
        }
    }

    /// Remove sequence from a queue
    fn removeFromQueue(self: *Self, queue: *std.ArrayList(*SequenceData), seq_id: u64) void {
        _ = self;
        for (queue.items, 0..) |seq, i| {
            if (seq.seq_id == seq_id) {
                _ = queue.orderedRemove(i);
                return;
            }
        }
    }

    /// Get number of waiting sequences
    pub fn getNumWaiting(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.waiting.items.len;
    }

    /// Get number of running sequences
    pub fn getNumRunning(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.running.items.len;
    }

    /// Get number of swapped sequences
    pub fn getNumSwapped(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.swapped.items.len;
    }

    /// Check if scheduler has unfinished work
    pub fn hasUnfinished(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.waiting.items.len > 0 or
            self.running.items.len > 0 or
            self.swapped.items.len > 0;
    }

    /// Get scheduler statistics
    pub fn getStats(self: *Self) SchedulerStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stats;
    }
};

/// Scheduler statistics
pub const SchedulerStats = struct {
    /// Total sequences added
    total_sequences: u64 = 0,
    /// Sequences completed
    sequences_completed: u64 = 0,
    /// Batches scheduled
    batches_scheduled: u64 = 0,
    /// Prefills scheduled
    prefills_scheduled: u64 = 0,
    /// Tokens generated
    tokens_generated: u64 = 0,
    /// Number of preemptions
    preemptions: u64 = 0,
    /// Swaps out
    swaps_out: u64 = 0,
    /// Swaps in
    swaps_in: u64 = 0,
};

// ============================================
// Tests
// ============================================

test "Scheduler initialization" {
    const allocator = std.testing.allocator;

    const blk_config = block_manager.BlockManagerConfig{
        .num_gpu_blocks = 100,
        .num_cpu_blocks = 50,
    };
    var blk_mgr = try BlockManager.init(allocator, blk_config);
    defer blk_mgr.deinit();

    const sched_config = SchedulerConfig{};
    var scheduler = try Scheduler.init(allocator, sched_config, blk_mgr);
    defer scheduler.deinit();

    try std.testing.expectEqual(@as(usize, 0), scheduler.getNumWaiting());
    try std.testing.expectEqual(@as(usize, 0), scheduler.getNumRunning());
    try std.testing.expect(!scheduler.hasUnfinished());
}