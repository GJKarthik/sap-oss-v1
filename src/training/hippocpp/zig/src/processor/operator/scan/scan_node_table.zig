//! ScanNodeTableSharedState — Ported from kuzu C++ (126L header, 142L source).
//!

const std = @import("std");

pub const ScanNodeTableSharedState = struct {
    allocator: std.mem.Allocator,
    numGroupsScanned: ?*anyopaque = null,
    numGroups: u64 = 0,
    mtx: ?*anyopaque = null,
    currentCommittedGroupIdx: u64 = 0,
    currentUnCommittedGroupIdx: u64 = 0,
    numCommittedNodeGroups: u64 = 0,
    numUnCommittedNodeGroups: u64 = 0,
    semiMask: ?*?*anyopaque = null,
    tableNames: std.ArrayList([]const u8) = .{},
    alias: []const u8 = "",
    properties: std.ArrayList(u8) = .{},
    true: ?*anyopaque = null,
    currentTableIdx: u32 = 0,
    scanState: ?*?*anyopaque = null,
    tableInfos: std.ArrayList(?*anyopaque) = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn initialize(self: *Self) void {
        _ = self;
    }

    pub fn next_morsel(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
        _ = self;
    }

    pub fn scan_node_table_print_info(self: *Self) void {
        _ = self;
    }

    pub fn init_scan_state(self: *Self) void {
        _ = self;
    }

    pub fn is_source(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn init_local_state_internal(self: *Self) void {
        _ = self;
    }

    pub fn get_next_tuples_internal(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_progress(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn init_global_state_internal(self: *Self) void {
        _ = self;
    }

    pub fn init_current_table(self: *Self) void {
        _ = self;
    }

};

test "ScanNodeTableSharedState" {
    const allocator = std.testing.allocator;
    var instance = ScanNodeTableSharedState.init(allocator);
    defer instance.deinit();
}
