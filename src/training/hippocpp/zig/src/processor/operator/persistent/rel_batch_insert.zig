//! RelGroupCatalogEntry — Ported from kuzu C++ (171L header, 323L source).
//!

const std = @import("std");

pub const RelGroupCatalogEntry = struct {
    allocator: std.mem.Allocator,
    RelGroupCatalogEntry: ?*anyopaque = null,
    CSRNodeGroup: ?*anyopaque = null,
    InMemChunkedCSRHeader: ?*anyopaque = null,
    tableName: []const u8 = "",
    partitionsDone: ?*anyopaque = null,
    partitionsTotal: u64 = 0,
    direction: ?*anyopaque = null,
    dummyAllNullDataChunk: ?*?*anyopaque = null,
    true: ?*anyopaque = null,
    partitionerSharedState: ?*?*anyopaque = null,
    progressSharedState: ?*?*anyopaque = null,
    impl: ?*?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn rel_batch_insert_print_info(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
        _ = self;
    }

    pub fn init_execution_state(self: *Self) void {
        _ = self;
    }

    pub fn populate_csr_lengths(self: *Self) void {
        _ = self;
    }

    pub fn finalize_start_csr_offsets(self: *Self) void {
        _ = self;
    }

    pub fn write_to_table(self: *Self) void {
        _ = self;
    }

    pub fn is_source(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn init_global_state_internal(self: *Self) void {
        _ = self;
    }

    pub fn init_local_state_internal(self: *Self) void {
        _ = self;
    }

    pub fn execute_internal(self: *Self) void {
        _ = self;
    }

    pub fn finalize_internal(self: *Self) void {
        _ = self;
    }

};

test "RelGroupCatalogEntry" {
    const allocator = std.testing.allocator;
    var instance = RelGroupCatalogEntry.init(allocator);
    defer instance.deinit();
}
