//! Disaggregated Serving Module
//!
//! Implements prefill/decode separation for optimized inference.
//! Allows independent scaling of compute-heavy prefill and memory-bound decode.
//!
//! Features:
//! - Prefill/decode worker separation
//! - Remote KV cache transfer
//! - Load balancing across workers
//! - Network optimization

const std = @import("std");

// ==============================================
// Worker Types
// ==============================================

pub const WorkerRole = enum {
    prefill,        // Handles prompt processing
    decode,         // Handles token generation
    mixed,          // Handles both (traditional)
};

pub const WorkerState = enum {
    idle,
    busy,
    draining,       // Finishing current work
    offline,
};

// ==============================================
// Worker Node
// ==============================================

pub const WorkerNode = struct {
    id: []const u8,
    role: WorkerRole,
    state: WorkerState,
    
    // Network
    address: []const u8,
    port: u16,
    
    // Resources
    num_gpus: u8,
    gpu_memory_mb: usize,
    available_memory_mb: usize,
    
    // Load
    current_requests: usize,
    max_concurrent: usize,
    total_processed: u64,
    
    // Health
    last_heartbeat: i64,
    latency_ms: f32,
    
    pub fn init(id: []const u8, role: WorkerRole, address: []const u8, port: u16) WorkerNode {
        return .{
            .id = id,
            .role = role,
            .state = .idle,
            .address = address,
            .port = port,
            .num_gpus = 1,
            .gpu_memory_mb = 40960,
            .available_memory_mb = 40960,
            .current_requests = 0,
            .max_concurrent = 256,
            .total_processed = 0,
            .last_heartbeat = std.time.milliTimestamp(),
            .latency_ms = 0,
        };
    }
    
    pub fn isAvailable(self: *const WorkerNode) bool {
        return self.state == .idle and self.current_requests < self.max_concurrent;
    }
    
    pub fn loadFactor(self: *const WorkerNode) f32 {
        return @as(f32, @floatFromInt(self.current_requests)) / @as(f32, @floatFromInt(self.max_concurrent));
    }
    
    pub fn recordRequest(self: *WorkerNode) void {
        self.current_requests += 1;
        self.total_processed += 1;
        if (self.current_requests >= self.max_concurrent) {
            self.state = .busy;
        }
    }
    
    pub fn completeRequest(self: *WorkerNode) void {
        if (self.current_requests > 0) {
            self.current_requests -= 1;
        }
        if (self.state == .busy and self.current_requests < self.max_concurrent) {
            self.state = .idle;
        }
    }
};

// ==============================================
// KV Cache Transfer
// ==============================================

pub const KVTransferRequest = struct {
    request_id: []const u8,
    source_worker: []const u8,
    target_worker: []const u8,
    
    // Cache info
    num_blocks: usize,
    block_ids: []const usize,
    total_size_bytes: usize,
    
    // Timing
    created_at: i64,
    started_at: ?i64,
    completed_at: ?i64,
    
    pub fn init(
        request_id: []const u8,
        source: []const u8,
        target: []const u8,
        block_ids: []const usize,
        block_size_bytes: usize,
    ) KVTransferRequest {
        return .{
            .request_id = request_id,
            .source_worker = source,
            .target_worker = target,
            .num_blocks = block_ids.len,
            .block_ids = block_ids,
            .total_size_bytes = block_ids.len * block_size_bytes,
            .created_at = std.time.milliTimestamp(),
            .started_at = null,
            .completed_at = null,
        };
    }
    
    pub fn transferLatency(self: *const KVTransferRequest) ?i64 {
        if (self.started_at) |start| {
            if (self.completed_at) |end| {
                return end - start;
            }
        }
        return null;
    }
};

pub const KVTransferManager = struct {
    pending: std.ArrayList(KVTransferRequest),
    in_progress: std.ArrayList(KVTransferRequest),
    completed: std.ArrayList(KVTransferRequest),
    
    // Network config
    max_concurrent_transfers: usize,
    chunk_size_bytes: usize,
    
    // Statistics
    total_transfers: u64,
    total_bytes: u64,
    avg_latency_ms: f32,
    
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) KVTransferManager {
        return .{
            .pending = std.ArrayList(KVTransferRequest).init(allocator),
            .in_progress = std.ArrayList(KVTransferRequest).init(allocator),
            .completed = std.ArrayList(KVTransferRequest).init(allocator),
            .max_concurrent_transfers = 8,
            .chunk_size_bytes = 1024 * 1024, // 1MB chunks
            .total_transfers = 0,
            .total_bytes = 0,
            .avg_latency_ms = 0,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *KVTransferManager) void {
        self.pending.deinit();
        self.in_progress.deinit();
        self.completed.deinit();
    }
    
    pub fn queueTransfer(self: *KVTransferManager, request: KVTransferRequest) !void {
        try self.pending.append(request);
    }
    
    pub fn startPendingTransfers(self: *KVTransferManager) !void {
        while (self.in_progress.items.len < self.max_concurrent_transfers) {
            if (self.pending.items.len == 0) break;
            
            var transfer = self.pending.orderedRemove(0);
            transfer.started_at = std.time.milliTimestamp();
            try self.in_progress.append(transfer);
        }
    }
    
    pub fn completeTransfer(self: *KVTransferManager, request_id: []const u8) !void {
        for (self.in_progress.items, 0..) |*transfer, i| {
            if (std.mem.eql(u8, transfer.request_id, request_id)) {
                transfer.completed_at = std.time.milliTimestamp();
                
                // Update stats
                self.total_transfers += 1;
                self.total_bytes += transfer.total_size_bytes;
                if (transfer.transferLatency()) |lat| {
                    const n = @as(f32, @floatFromInt(self.total_transfers));
                    self.avg_latency_ms = (self.avg_latency_ms * (n - 1) + @as(f32, @floatFromInt(lat))) / n;
                }
                
                try self.completed.append(transfer.*);
                _ = self.in_progress.orderedRemove(i);
                break;
            }
        }
    }
};

// ==============================================
// Load Balancer
// ==============================================

pub const LoadBalanceStrategy = enum {
    round_robin,
    least_loaded,
    random,
    latency_aware,
    memory_aware,
};

pub const LoadBalancer = struct {
    prefill_workers: std.ArrayList(*WorkerNode),
    decode_workers: std.ArrayList(*WorkerNode),
    
    strategy: LoadBalanceStrategy,
    next_prefill: usize,
    next_decode: usize,
    
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) LoadBalancer {
        return .{
            .prefill_workers = std.ArrayList(*WorkerNode).init(allocator),
            .decode_workers = std.ArrayList(*WorkerNode).init(allocator),
            .strategy = .least_loaded,
            .next_prefill = 0,
            .next_decode = 0,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *LoadBalancer) void {
        self.prefill_workers.deinit();
        self.decode_workers.deinit();
    }
    
    pub fn addWorker(self: *LoadBalancer, worker: *WorkerNode) !void {
        switch (worker.role) {
            .prefill => try self.prefill_workers.append(worker),
            .decode => try self.decode_workers.append(worker),
            .mixed => {
                try self.prefill_workers.append(worker);
                try self.decode_workers.append(worker);
            },
        }
    }
    
    pub fn selectPrefillWorker(self: *LoadBalancer) ?*WorkerNode {
        return self.selectWorker(self.prefill_workers.items, &self.next_prefill);
    }
    
    pub fn selectDecodeWorker(self: *LoadBalancer) ?*WorkerNode {
        return self.selectWorker(self.decode_workers.items, &self.next_decode);
    }
    
    fn selectWorker(self: *LoadBalancer, workers: []*WorkerNode, next: *usize) ?*WorkerNode {
        if (workers.len == 0) return null;
        
        switch (self.strategy) {
            .round_robin => {
                const start = next.*;
                var i = start;
                while (true) {
                    const worker = workers[i % workers.len];
                    if (worker.isAvailable()) {
                        next.* = (i + 1) % workers.len;
                        return worker;
                    }
                    i += 1;
                    if (i % workers.len == start) break;
                }
                return null;
            },
            .least_loaded => {
                var best: ?*WorkerNode = null;
                var best_load: f32 = 1.0;
                
                for (workers) |worker| {
                    if (worker.isAvailable()) {
                        const load = worker.loadFactor();
                        if (load < best_load) {
                            best_load = load;
                            best = worker;
                        }
                    }
                }
                return best;
            },
            .latency_aware => {
                var best: ?*WorkerNode = null;
                var best_latency: f32 = std.math.floatMax(f32);
                
                for (workers) |worker| {
                    if (worker.isAvailable() and worker.latency_ms < best_latency) {
                        best_latency = worker.latency_ms;
                        best = worker;
                    }
                }
                return best;
            },
            .memory_aware => {
                var best: ?*WorkerNode = null;
                var best_memory: usize = 0;
                
                for (workers) |worker| {
                    if (worker.isAvailable() and worker.available_memory_mb > best_memory) {
                        best_memory = worker.available_memory_mb;
                        best = worker;
                    }
                }
                return best;
            },
            .random => {
                var available = std.ArrayList(*WorkerNode).init(self.allocator);
                defer available.deinit();
                
                for (workers) |worker| {
                    if (worker.isAvailable()) {
                        available.append(worker) catch continue;
                    }
                }
                
                if (available.items.len == 0) return null;
                
                var prng = std.rand.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
                const idx = prng.random().intRangeLessThan(usize, 0, available.items.len);
                return available.items[idx];
            },
        }
    }
};

// ==============================================
// Disaggregated Request
// ==============================================

pub const RequestPhase = enum {
    queued,
    prefilling,
    transferring,
    decoding,
    completed,
    failed,
};

pub const DisaggregatedRequest = struct {
    request_id: []const u8,
    phase: RequestPhase,
    
    // Worker assignments
    prefill_worker: ?*WorkerNode,
    decode_worker: ?*WorkerNode,
    
    // Tokens
    prompt_tokens: []const u32,
    output_tokens: std.ArrayList(u32),
    max_tokens: usize,
    
    // KV cache
    kv_block_ids: std.ArrayList(usize),
    
    // Timing
    created_at: i64,
    prefill_start: ?i64,
    prefill_end: ?i64,
    transfer_start: ?i64,
    transfer_end: ?i64,
    decode_start: ?i64,
    decode_end: ?i64,
    
    allocator: std.mem.Allocator,
    
    pub fn init(
        allocator: std.mem.Allocator,
        request_id: []const u8,
        prompt_tokens: []const u32,
        max_tokens: usize,
    ) DisaggregatedRequest {
        return .{
            .request_id = request_id,
            .phase = .queued,
            .prefill_worker = null,
            .decode_worker = null,
            .prompt_tokens = prompt_tokens,
            .output_tokens = std.ArrayList(u32).init(allocator),
            .max_tokens = max_tokens,
            .kv_block_ids = std.ArrayList(usize).init(allocator),
            .created_at = std.time.milliTimestamp(),
            .prefill_start = null,
            .prefill_end = null,
            .transfer_start = null,
            .transfer_end = null,
            .decode_start = null,
            .decode_end = null,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *DisaggregatedRequest) void {
        self.output_tokens.deinit();
        self.kv_block_ids.deinit();
    }
    
    pub fn timeToFirstToken(self: *const DisaggregatedRequest) ?i64 {
        if (self.decode_start) |start| {
            return start - self.created_at;
        }
        return null;
    }
    
    pub fn totalLatency(self: *const DisaggregatedRequest) ?i64 {
        if (self.decode_end) |end| {
            return end - self.created_at;
        }
        return null;
    }
};

// ==============================================
// Disaggregated Serving Coordinator
// ==============================================

pub const DisaggregatedCoordinator = struct {
    load_balancer: LoadBalancer,
    transfer_manager: KVTransferManager,
    
    // Requests by phase
    queued: std.ArrayList(*DisaggregatedRequest),
    prefilling: std.ArrayList(*DisaggregatedRequest),
    transferring: std.ArrayList(*DisaggregatedRequest),
    decoding: std.ArrayList(*DisaggregatedRequest),
    
    // Configuration
    enable_transfer_overlap: bool,  // Start transfer before prefill complete
    block_size_bytes: usize,
    
    // Statistics
    total_requests: u64,
    completed_requests: u64,
    avg_ttft_ms: f32,
    avg_total_ms: f32,
    
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) DisaggregatedCoordinator {
        return .{
            .load_balancer = LoadBalancer.init(allocator),
            .transfer_manager = KVTransferManager.init(allocator),
            .queued = std.ArrayList(*DisaggregatedRequest).init(allocator),
            .prefilling = std.ArrayList(*DisaggregatedRequest).init(allocator),
            .transferring = std.ArrayList(*DisaggregatedRequest).init(allocator),
            .decoding = std.ArrayList(*DisaggregatedRequest).init(allocator),
            .enable_transfer_overlap = true,
            .block_size_bytes = 8 * 1024 * 1024, // 8MB
            .total_requests = 0,
            .completed_requests = 0,
            .avg_ttft_ms = 0,
            .avg_total_ms = 0,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *DisaggregatedCoordinator) void {
        self.load_balancer.deinit();
        self.transfer_manager.deinit();
        self.queued.deinit();
        self.prefilling.deinit();
        self.transferring.deinit();
        self.decoding.deinit();
    }
    
    /// Submit new request
    pub fn submit(self: *DisaggregatedCoordinator, request: *DisaggregatedRequest) !void {
        self.total_requests += 1;
        try self.queued.append(request);
    }
    
    /// Main scheduling loop
    pub fn step(self: *DisaggregatedCoordinator) !void {
        // 1. Schedule queued requests to prefill workers
        try self.scheduleQueuedRequests();
        
        // 2. Check for completed prefills, initiate transfers
        try self.checkPrefillComplete();
        
        // 3. Process transfers
        try self.transfer_manager.startPendingTransfers();
        
        // 4. Check for completed transfers, start decode
        try self.checkTransferComplete();
        
        // 5. Check for completed decodes
        try self.checkDecodeComplete();
    }
    
    fn scheduleQueuedRequests(self: *DisaggregatedCoordinator) !void {
        var i: usize = 0;
        while (i < self.queued.items.len) {
            const request = self.queued.items[i];
            
            // Select prefill worker
            if (self.load_balancer.selectPrefillWorker()) |worker| {
                request.prefill_worker = worker;
                request.phase = .prefilling;
                request.prefill_start = std.time.milliTimestamp();
                
                worker.recordRequest();
                
                // Move to prefilling
                _ = self.queued.orderedRemove(i);
                try self.prefilling.append(request);
            } else {
                i += 1;
            }
        }
    }
    
    fn checkPrefillComplete(self: *DisaggregatedCoordinator) !void {
        var i: usize = 0;
        while (i < self.prefilling.items.len) {
            const request = self.prefilling.items[i];
            
            // Check if prefill is done (would be signaled by worker)
            // For now, simulate completion
            if (request.prefill_start) |start| {
                const elapsed = std.time.milliTimestamp() - start;
                const prefill_time = @as(i64, @intCast(request.prompt_tokens.len * 10)); // ~10ms per 100 tokens
                
                if (elapsed >= prefill_time) {
                    request.prefill_end = std.time.milliTimestamp();
                    request.prefill_worker.?.completeRequest();
                    
                    // Initiate KV transfer if different workers
                    if (request.prefill_worker != null and request.decode_worker == null) {
                        // Select decode worker
                        if (self.load_balancer.selectDecodeWorker()) |decode_worker| {
                            request.decode_worker = decode_worker;
                            
                            if (request.prefill_worker.?.id.ptr != decode_worker.id.ptr) {
                                // Need transfer
                                request.phase = .transferring;
                                request.transfer_start = std.time.milliTimestamp();
                                
                                const transfer = KVTransferRequest.init(
                                    request.request_id,
                                    request.prefill_worker.?.id,
                                    decode_worker.id,
                                    request.kv_block_ids.items,
                                    self.block_size_bytes,
                                );
                                try self.transfer_manager.queueTransfer(transfer);
                                
                                _ = self.prefilling.orderedRemove(i);
                                try self.transferring.append(request);
                                continue;
                            } else {
                                // Same worker, skip transfer
                                request.phase = .decoding;
                                request.decode_start = std.time.milliTimestamp();
                                decode_worker.recordRequest();
                                
                                _ = self.prefilling.orderedRemove(i);
                                try self.decoding.append(request);
                                continue;
                            }
                        }
                    }
                }
            }
            i += 1;
        }
    }
    
    fn checkTransferComplete(self: *DisaggregatedCoordinator) !void {
        var i: usize = 0;
        while (i < self.transferring.items.len) {
            const request = self.transferring.items[i];
            
            // Check if transfer complete (would be signaled)
            if (request.transfer_start) |start| {
                const elapsed = std.time.milliTimestamp() - start;
                const transfer_time: i64 = 50; // ~50ms for transfer
                
                if (elapsed >= transfer_time) {
                    request.transfer_end = std.time.milliTimestamp();
                    try self.transfer_manager.completeTransfer(request.request_id);
                    
                    // Start decode
                    request.phase = .decoding;
                    request.decode_start = std.time.milliTimestamp();
                    request.decode_worker.?.recordRequest();
                    
                    _ = self.transferring.orderedRemove(i);
                    try self.decoding.append(request);
                    continue;
                }
            }
            i += 1;
        }
    }
    
    fn checkDecodeComplete(self: *DisaggregatedCoordinator) !void {
        var i: usize = 0;
        while (i < self.decoding.items.len) {
            const request = self.decoding.items[i];
            
            // Check if decode complete
            if (request.output_tokens.items.len >= request.max_tokens) {
                request.phase = .completed;
                request.decode_end = std.time.milliTimestamp();
                request.decode_worker.?.completeRequest();
                
                // Update stats
                self.completed_requests += 1;
                if (request.timeToFirstToken()) |ttft| {
                    const n = @as(f32, @floatFromInt(self.completed_requests));
                    self.avg_ttft_ms = (self.avg_ttft_ms * (n - 1) + @as(f32, @floatFromInt(ttft))) / n;
                }
                if (request.totalLatency()) |total| {
                    const n = @as(f32, @floatFromInt(self.completed_requests));
                    self.avg_total_ms = (self.avg_total_ms * (n - 1) + @as(f32, @floatFromInt(total))) / n;
                }
                
                _ = self.decoding.orderedRemove(i);
                continue;
            }
            i += 1;
        }
    }
    
    /// Get coordinator statistics
    pub fn getStats(self: *const DisaggregatedCoordinator) CoordinatorStats {
        return .{
            .total_requests = self.total_requests,
            .completed_requests = self.completed_requests,
            .queued_count = self.queued.items.len,
            .prefilling_count = self.prefilling.items.len,
            .transferring_count = self.transferring.items.len,
            .decoding_count = self.decoding.items.len,
            .avg_ttft_ms = self.avg_ttft_ms,
            .avg_total_ms = self.avg_total_ms,
            .transfer_avg_ms = self.transfer_manager.avg_latency_ms,
        };
    }
};

pub const CoordinatorStats = struct {
    total_requests: u64,
    completed_requests: u64,
    queued_count: usize,
    prefilling_count: usize,
    transferring_count: usize,
    decoding_count: usize,
    avg_ttft_ms: f32,
    avg_total_ms: f32,
    transfer_avg_ms: f32,
};

// ==============================================
// Tests
// ==============================================

test "WorkerNode availability" {
    var worker = WorkerNode.init("worker-1", .prefill, "localhost", 8000);
    
    try std.testing.expect(worker.isAvailable());
    try std.testing.expect(worker.loadFactor() == 0.0);
    
    worker.recordRequest();
    try std.testing.expect(worker.current_requests == 1);
    try std.testing.expect(worker.loadFactor() > 0);
    
    worker.completeRequest();
    try std.testing.expect(worker.current_requests == 0);
}

test "LoadBalancer round robin" {
    const allocator = std.testing.allocator;
    var lb = LoadBalancer.init(allocator);
    defer lb.deinit();
    
    var w1 = WorkerNode.init("w1", .prefill, "host1", 8000);
    var w2 = WorkerNode.init("w2", .prefill, "host2", 8000);
    
    try lb.addWorker(&w1);
    try lb.addWorker(&w2);
    
    try std.testing.expect(lb.prefill_workers.items.len == 2);
}