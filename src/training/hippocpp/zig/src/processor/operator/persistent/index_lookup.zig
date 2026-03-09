//! Transaction — Ported from kuzu C++ (89L header, 203L source).
//!

const std = @import("std");

pub const Transaction = struct {
    allocator: std.mem.Allocator,
    Transaction: ?*anyopaque = null,
    NodeTable: ?*anyopaque = null,
    BatchInsertSharedState: ?*anyopaque = null,
    keyEvaluator: ?*?*anyopaque = null,
    resultVectorPos: ?*anyopaque = null,
    expressions: std.ArrayList(u8) = .{},
    errorHandler: ?*?*anyopaque = null,
    warningDataVectors: std.ArrayList(?*anyopaque) = .{},
    infos: std.ArrayList(?*anyopaque) = .{},
    warningDataVectorPos: std.ArrayList(?*anyopaque) = .{},
    localState: ?*?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn index_lookup_print_info(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
        _ = self;
    }

    pub fn index_lookup_local_state(self: *Self) void {
        _ = self;
    }

    pub fn init_local_state_internal(self: *Self) void {
        _ = self;
    }

    pub fn get_next_tuples_internal(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn lookup(self: *Self) void {
        _ = self;
    }

};

test "Transaction" {
    const allocator = std.testing.allocator;
    var instance = Transaction.init(allocator);
    defer instance.deinit();
}
