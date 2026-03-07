//! Disaggregated Prefill/Decode Serving
//!
//! Separates prefill (compute-bound) and decode (memory-bound) phases onto
//! different compute resources for optimized hardware utilization.
//!
//! Architecture:
//!   [Prefill Nodes] ──► KV Cache Transfer ──► [Decode Nodes]
//!   (compute-heavy)                           (memory-heavy)

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Types
// ============================================================================

pub const NodeRole = enum { prefill, decode, mixed };

pub const KvTransferState = enum { pending, transferring, complete, failed };

pub const PrefillResult = struct {
    request_id: u64,
    kv_cache_handle: u64,
    prompt_length: u32,
    kv_size_bytes: u64,
    first_token: u32,
    state: KvTransferState,
    prefill_time_ns: i128,
};

pub const DisaggregatedConfig = struct {
    role: NodeRole,
    prefill_nodes: u32,
    decode_nodes: u32,
    kv_transfer_port: u16,
    max_pending_transfers: u32 = 64,
    transfer_timeout_ms: u64 = 5000,
};

pub const DisaggregatedStats = struct {
    total_prefills: u64,
    total_decodes: u64,
    total_transfers: u64,
    failed_transfers: u64,
    avg_transfer_time_ns: i128,
};

// ============================================================================
// Disaggregated Scheduler
// ============================================================================

pub const DisaggregatedScheduler = struct {
    allocator: Allocator,
    config: DisaggregatedConfig,
    prefill_queue: std.ArrayListUnmanaged(PrefillResult),
    decode_queue: std.ArrayListUnmanaged(PrefillResult),
    stats: DisaggregatedStats,

    const Self = @This();

    pub fn init(allocator: Allocator, config: DisaggregatedConfig) Self {
        return Self{
            .allocator = allocator,
            .config = config,
            .prefill_queue = std.ArrayListUnmanaged(PrefillResult){},
            .decode_queue = std.ArrayListUnmanaged(PrefillResult){},
            .stats = DisaggregatedStats{
                .total_prefills = 0,
                .total_decodes = 0,
                .total_transfers = 0,
                .failed_transfers = 0,
                .avg_transfer_time_ns = 0,
            },
        };
    }

    pub fn deinit(self: *Self) void {
        self.prefill_queue.deinit();
        self.decode_queue.deinit();
    }

    pub fn submitPrefillResult(self: *Self, result: PrefillResult) !void {
        if (self.prefill_queue.items.len >= self.config.max_pending_transfers) {
            return error.QueueFull;
        }
        try self.prefill_queue.append(result);
        self.stats.total_prefills += 1;
    }

    pub fn nextForDecode(self: *Self) ?PrefillResult {
        if (self.prefill_queue.items.len == 0) return null;
        const result = self.prefill_queue.orderedRemove(0);
        self.decode_queue.append(result) catch return null;
        self.stats.total_transfers += 1;
        return result;
    }

    pub fn markTransferComplete(self: *Self, request_id: u64) bool {
        for (self.decode_queue.items, 0..) |*item, idx| {
            if (item.request_id == request_id) {
                item.state = .complete;
                _ = self.decode_queue.orderedRemove(idx);
                self.stats.total_decodes += 1;
                return true;
            }
        }
        return false;
    }

    pub fn routeRequest(_: *const Self, has_prompt: bool) NodeRole {
        return if (has_prompt) .prefill else .decode;
    }

    pub fn pendingTransfers(self: *const Self) u32 {
        return @intCast(self.prefill_queue.items.len + self.decode_queue.items.len);
    }

    pub fn getStats(self: *const Self) DisaggregatedStats {
        return self.stats;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "DisaggregatedScheduler init/deinit" {
    const allocator = std.testing.allocator;
    const config = DisaggregatedConfig{
        .role = .prefill,
        .prefill_nodes = 4,
        .decode_nodes = 8,
        .kv_transfer_port = 9000,
    };
    var scheduler = DisaggregatedScheduler.init(allocator, config);
    defer scheduler.deinit();

    try std.testing.expectEqual(@as(u32, 0), scheduler.pendingTransfers());
    try std.testing.expectEqual(@as(u64, 0), scheduler.stats.total_prefills);
}

test "submitPrefillResult and nextForDecode flow" {
    const allocator = std.testing.allocator;
    const config = DisaggregatedConfig{
        .role = .prefill,
        .prefill_nodes = 2,
        .decode_nodes = 2,
        .kv_transfer_port = 9001,
    };
    var scheduler = DisaggregatedScheduler.init(allocator, config);
    defer scheduler.deinit();

    const result = PrefillResult{
        .request_id = 42,
        .kv_cache_handle = 1000,
        .prompt_length = 128,
        .kv_size_bytes = 65536,
        .first_token = 512,
        .state = .pending,
        .prefill_time_ns = 1_000_000,
    };

    try scheduler.submitPrefillResult(result);
    try std.testing.expectEqual(@as(u32, 1), scheduler.pendingTransfers());
    try std.testing.expectEqual(@as(u64, 1), scheduler.stats.total_prefills);

    const retrieved = scheduler.nextForDecode();
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(u64, 42), retrieved.?.request_id);
    try std.testing.expectEqual(@as(u64, 1), scheduler.stats.total_transfers);
}

test "markTransferComplete" {
    const allocator = std.testing.allocator;
    const config = DisaggregatedConfig{
        .role = .decode,
        .prefill_nodes = 2,
        .decode_nodes = 2,
        .kv_transfer_port = 9002,
    };
    var scheduler = DisaggregatedScheduler.init(allocator, config);
    defer scheduler.deinit();

    const result = PrefillResult{
        .request_id = 99,
        .kv_cache_handle = 2000,
        .prompt_length = 256,
        .kv_size_bytes = 131072,
        .first_token = 1024,
        .state = .transferring,
        .prefill_time_ns = 2_000_000,
    };

    try scheduler.submitPrefillResult(result);
    _ = scheduler.nextForDecode();

    const completed = scheduler.markTransferComplete(99);
    try std.testing.expect(completed);
    try std.testing.expectEqual(@as(u64, 1), scheduler.stats.total_decodes);
}

test "routeRequest logic" {
    const allocator = std.testing.allocator;
    const config = DisaggregatedConfig{
        .role = .mixed,
        .prefill_nodes = 2,
        .decode_nodes = 2,
        .kv_transfer_port = 9003,
    };
    const scheduler = DisaggregatedScheduler.init(allocator, config);

    const prefill_route = scheduler.routeRequest(true);
    try std.testing.expectEqual(NodeRole.prefill, prefill_route);

    const decode_route = scheduler.routeRequest(false);
    try std.testing.expectEqual(NodeRole.decode, decode_route);
}

test "stats tracking" {
    const allocator = std.testing.allocator;
    const config = DisaggregatedConfig{
        .role = .prefill,
        .prefill_nodes = 1,
        .decode_nodes = 1,
        .kv_transfer_port = 9004,
    };
    var scheduler = DisaggregatedScheduler.init(allocator, config);
    defer scheduler.deinit();

    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const result = PrefillResult{
            .request_id = i,
            .kv_cache_handle = 1000 + i,
            .prompt_length = 100 + i,
            .kv_size_bytes = 50000 + i * 1000,
            .first_token = 500 + i,
            .state = .pending,
            .prefill_time_ns = 1_000_000 + i * 100_000,
        };
        try scheduler.submitPrefillResult(result);
    }

    try std.testing.expectEqual(@as(u64, 5), scheduler.stats.total_prefills);

    var j: u32 = 0;
    while (j < 3) : (j += 1) {
        _ = scheduler.nextForDecode();
    }

    try std.testing.expectEqual(@as(u64, 3), scheduler.stats.total_transfers);
}

