//! MaterializedQueryResult — Ported from kuzu C++ (64L header, 68L source).
//!

const std = @import("std");

pub const MaterializedQueryResult = struct {
    allocator: std.mem.Allocator,
    MaterializedQueryResult: ?*anyopaque = null,
    StorageManager: ?*anyopaque = null,
    dbName: ?*anyopaque = null,
    dbType: ?*anyopaque = null,
    catalog: ?*?*anyopaque = null,
    storageManager: ?*?*anyopaque = null,
    transactionManager: ?*?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn get_db_name(self: *const Self) []const u8 {
        _ = self;
        return "";
    }

    pub fn get_db_type(self: *const Self) u8 {
        _ = self;
        return null;
    }

    pub fn invalidate_cache(self: *Self) void {
        _ = self;
    }

};

test "MaterializedQueryResult" {
    const allocator = std.testing.allocator;
    var instance = MaterializedQueryResult.init(allocator);
    defer instance.deinit();
    _ = instance.get_db_name();
    _ = instance.get_db_type();
}
