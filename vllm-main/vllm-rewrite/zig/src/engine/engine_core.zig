//! Engine Core - Main Inference Engine
//!
//! This module implements the core inference engine that coordinates:
//! - Request scheduling
//! - Memory management (KV-cache)
//! - Model execution (via Mojo)
//! - Output processing

const std = @import("std");
const types = @import("types.zig");
const config = @import("../utils/config.zig");
const logging = @import("../utils/logging.zig");

const Request = types.Request;
const RequestState = types.RequestState;
const SamplingParams = types.SamplingParams;
const RequestOutput = types.RequestOutput;
const EngineConfig = config.EngineConfig;
const SchedulerConfig = config.SchedulerConfig;

const log = logging.scoped(.engine);

/// Engine statistics
pub const EngineStats = struct {
    /// Total requests processed
    total_requests: u64 = 0,
    /// Total tokens generated
    total_tokens: u64 = 0,
    /// Requests currently running
    running_requests: u32 = 0,
    /// Requests waiting in queue
    pending_requests: u32 = 0,
    /// Average tokens per second
    avg_tokens_per_sec: f32 = 0,
    /// Average time to first token (ms)
    avg_ttft_ms: f32 = 0,
    /// GPU memory used (bytes)
    gpu_memory_used: u64 = 0,
    /// GPU memory total (bytes)
    gpu_memory_total: u64 = 0,
};

/// Engine state
pub const EngineState = enum {
    /// Engine is initializing
    initializing,
    /// Engine is ready to accept requests
    ready,
    /// Engine is processing requests
    running,
    /// Engine is shutting down
    stopping,
    /// Engine has stopped
    stopped,
    /// Engine encountered an error
    error_state,
};

/// Core inference engine
pub const EngineCore = struct {
    /// Memory allocator
    allocator: std.mem.Allocator,

    /// Engine configuration
    config: EngineConfig,

    /// Scheduler configuration
    scheduler_config: SchedulerConfig,

    /// Current engine state
    state: EngineState = .initializing,

    /// Engine statistics
    stats: EngineStats = .{},

    /// Request queue (pending requests)
    request_queue: std.ArrayList(*Request),

    /// Currently running requests
    running_requests: std.ArrayList(*Request),

    /// Completed requests awaiting output retrieval
    completed_requests: std.AutoHashMap(types.RequestId, *Request),

    /// Mutex for thread-safe access
    mutex: std.Thread.Mutex = .{},

    /// Model handle (FFI to Mojo)
    model_handle: ?*anyopaque = null,

    /// Block manager for KV-cache
    // block_manager: ?*BlockManager = null,

    const Self = @This();

    /// Initialize the engine
    pub fn init(allocator: std.mem.Allocator, engine_config: EngineConfig) !*Self {
        return initWithScheduler(allocator, engine_config, .{});
    }

    /// Initialize the engine with custom scheduler config
    pub fn initWithScheduler(allocator: std.mem.Allocator, engine_config: EngineConfig, sched_config: SchedulerConfig) !*Self {
        log.info("Initializing EngineCore with max_running_requests={}...", .{sched_config.max_running_requests});

        // Validate configuration
        try engine_config.validate();
        try sched_config.validate();

        var self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .config = engine_config,
            .scheduler_config = sched_config,
            .request_queue = std.ArrayList(*Request).init(allocator),
            .running_requests = std.ArrayList(*Request).init(allocator),
            .completed_requests = std.AutoHashMap(types.RequestId, *Request).init(allocator),
        };

        // Initialize model (placeholder - will call Mojo FFI)
        // self.model_handle = try loadModel(engine_config.model_path);

        // Initialize block manager
        // self.block_manager = try BlockManager.init(allocator, cache_config);

        self.state = .ready;
        log.info("EngineCore initialized successfully", .{});

        return self;
    }

    /// Deinitialize and free resources
    pub fn deinit(self: *Self) void {
        log.info("Shutting down EngineCore...", .{});

        self.state = .stopping;

        // Clean up pending requests
        for (self.request_queue.items) |req| {
            req.deinit();
            self.allocator.destroy(req);
        }
        self.request_queue.deinit();

        // Clean up running requests
        for (self.running_requests.items) |req| {
            req.deinit();
            self.allocator.destroy(req);
        }
        self.running_requests.deinit();

        // Clean up completed requests
        var iter = self.completed_requests.valueIterator();
        while (iter.next()) |req| {
            req.*.deinit();
            self.allocator.destroy(req.*);
        }
        self.completed_requests.deinit();

        // Unload model
        // if (self.model_handle) |handle| {
        //     unloadModel(handle);
        // }

        self.state = .stopped;
        log.info("EngineCore shutdown complete", .{});

        self.allocator.destroy(self);
    }

    /// Add a new request to the engine
    pub fn addRequest(
        self: *Self,
        request_id: ?types.RequestId,
        prompt_token_ids: []const u32,
        sampling_params: SamplingParams,
    ) !types.RequestId {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.state != .ready and self.state != .running) {
            return error.EngineNotReady;
        }

        // Validate sampling params
        try sampling_params.validate();

        // Create new request
        var request = try self.allocator.create(Request);
        request.* = Request.init(self.allocator);

        if (request_id) |id| {
            request.request_id = id;
        }

        request.prompt_token_ids = prompt_token_ids;
        request.prompt_len = @intCast(prompt_token_ids.len);
        request.sampling_params = sampling_params;
        request.state = .pending;

        // Add to queue
        try self.request_queue.append(request);
        self.stats.pending_requests += 1;

        log.debug("Added request {s} with {d} prompt tokens", .{
            request.getRequestIdStr(),
            prompt_token_ids.len,
        });

        return request.request_id;
    }

    /// Abort a request
    pub fn abortRequest(self: *Self, request_id: types.RequestId) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check pending queue
        for (self.request_queue.items, 0..) |req, i| {
            if (std.mem.eql(u8, &req.request_id, &request_id)) {
                req.state = .cancelled;
                req.finish_reason = .cancelled;
                _ = self.request_queue.orderedRemove(i);
                self.stats.pending_requests -= 1;

                // Move to completed
                try self.completed_requests.put(request_id, req);
                return;
            }
        }

        // Check running requests
        for (self.running_requests.items, 0..) |req, i| {
            if (std.mem.eql(u8, &req.request_id, &request_id)) {
                req.state = .cancelled;
                req.finish_reason = .cancelled;
                _ = self.running_requests.orderedRemove(i);
                self.stats.running_requests -= 1;

                // Move to completed
                try self.completed_requests.put(request_id, req);
                return;
            }
        }

        return error.RequestNotFound;
    }

    /// Execute one step of the engine (process one iteration)
    pub fn step(self: *Self) ![]RequestOutput {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.state != .ready and self.state != .running) {
            return &[_]RequestOutput{};
        }

        self.state = .running;

        // 1. Schedule pending requests
        try self.scheduleRequests();

        // 2. Execute forward pass on running requests
        // This will call Mojo model via FFI
        // const model_outputs = try self.executeForwardPass();

        // 3. Process outputs and update request states
        var outputs = std.ArrayList(RequestOutput).init(self.allocator);
        defer outputs.deinit();

        // 4. Move completed requests
        var i: usize = 0;
        while (i < self.running_requests.items.len) {
            const req = self.running_requests.items[i];
            if (req.state.isTerminal()) {
                // Generate output
                const output = RequestOutput{
                    .request_id = req.request_id,
                    .prompt = "",
                    .prompt_token_ids = req.prompt_token_ids,
                    .outputs = &[_]types.SequenceOutput{},
                    .finished = true,
                    .metrics = types.RequestMetrics{
                        .queue_time_ms = req.getQueueTime(),
                        .ttft_ms = 0,
                        .total_time_ms = req.getProcessingTime(),
                        .tokens_per_sec = 0,
                        .prompt_tokens = req.prompt_len,
                        .generated_tokens = req.tokens_generated,
                    },
                };
                try outputs.append(output);

                _ = self.running_requests.orderedRemove(i);
                self.stats.running_requests -= 1;
                try self.completed_requests.put(req.request_id, req);
            } else {
                i += 1;
            }
        }

        // Update stats
        self.stats.total_requests += outputs.items.len;

        if (self.running_requests.items.len == 0 and self.request_queue.items.len == 0) {
            self.state = .ready;
        }

        return try outputs.toOwnedSlice();
    }

    /// Schedule pending requests to run
    fn scheduleRequests(self: *Self) !void {
        // Simple FCFS scheduling for now
        // TODO: Integrate with Mangle rules for priority scheduling

        const max_running = self.scheduler_config.max_running_requests;

        while (self.request_queue.items.len > 0 and
            self.running_requests.items.len < max_running)
        {
            const req = self.request_queue.orderedRemove(0);
            self.stats.pending_requests -= 1;

            req.state = .running;
            req.start_time = std.time.nanoTimestamp();

            try self.running_requests.append(req);
            self.stats.running_requests += 1;
        }
    }

    /// Get the number of unfinished requests
    pub fn getNumUnfinishedRequests(self: *Self) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.stats.pending_requests + self.stats.running_requests;
    }

    /// Check if there are unfinished requests
    pub fn hasUnfinishedRequests(self: *Self) bool {
        return self.getNumUnfinishedRequests() > 0;
    }

    /// Get engine statistics
    pub fn getStats(self: *Self) EngineStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.stats;
    }

    /// Get engine state
    pub fn getState(self: *Self) EngineState {
        return self.state;
    }
};

// ============================================
// Tests
// ============================================

test "EngineCore initialization" {
    const allocator = std.testing.allocator;

    const engine_config = EngineConfig{
        .model_path = "test-model",
    };

    var engine = try EngineCore.init(allocator, engine_config);
    defer engine.deinit();

    try std.testing.expectEqual(EngineState.ready, engine.getState());
    try std.testing.expectEqual(@as(u32, 0), engine.getNumUnfinishedRequests());
}

test "EngineCore addRequest" {
    const allocator = std.testing.allocator;

    const engine_config = EngineConfig{
        .model_path = "test-model",
    };

    var engine = try EngineCore.init(allocator, engine_config);
    defer engine.deinit();

    const prompt_tokens = [_]u32{ 1, 2, 3, 4, 5 };
    const params = SamplingParams{};

    _ = try engine.addRequest(null, &prompt_tokens, params);

    try std.testing.expectEqual(@as(u32, 1), engine.getNumUnfinishedRequests());
}