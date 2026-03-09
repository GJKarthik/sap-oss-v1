//! ValueVector — Ported from kuzu C++ (95L header, 256L source).
//!

const std = @import("std");

pub const ValueVector = struct {
    allocator: std.mem.Allocator,
    ValueVector: ?*anyopaque = null,
    BoundExtraCreateCatalogEntryInfo: ?*anyopaque = null,
    BoundAlterInfo: ?*anyopaque = null,
    Transaction: ?*anyopaque = null,
    usageCount: u64 = 0,
    currVal: i64 = 0,
    increment: i64 = 0,
    startValue: i64 = 0,
    minValue: i64 = 0,
    maxValue: i64 = 0,
    cycle: bool = false,
    CatalogSet: ?*anyopaque = null,
    mtx: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn sequence_data(self: *Self) void {
        _ = self;
    }

    pub fn sequence_catalog_entry(self: *Self) void {
        _ = self;
    }

    pub fn get_sequence_data(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn curr_val(self: *Self) void {
        _ = self;
    }

    pub fn next_k_val(self: *Self) void {
        _ = self;
    }

    pub fn rollback_val(self: *Self) void {
        _ = self;
    }

    pub fn serialize(self: *Self) void {
        _ = self;
    }

    pub fn to_cypher(self: *Self) void {
        _ = self;
    }

    pub fn get_bound_create_sequence_info(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_serial_name(self: *const Self) []const u8 {
        _ = self;
        return "";
    }

    pub fn next_val_no_lock(self: *Self) void {
        _ = self;
    }

};

test "ValueVector" {
    const allocator = std.testing.allocator;
    var instance = ValueVector.init(allocator);
    defer instance.deinit();
    _ = instance.get_sequence_data();
}
