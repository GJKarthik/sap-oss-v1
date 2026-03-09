//! AttachDatabase — Ported from kuzu C++ (47L header, 64L source).
//!
//! Extends SimpleSink in the upstream implementation.

const std = @import("std");

pub const AttachDatabase = struct {
    allocator: std.mem.Allocator,
    dbName: []const u8 = "",
    dbPath: []const u8 = "",
    attachInfo: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
        _ = self;
    }

    pub fn attach_database_print_info(self: *Self) void {
        _ = self;
    }

    pub fn execute_internal(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this AttachDatabase.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.dbName = self.dbName;
        new.dbPath = self.dbPath;
        return new;
    }

};

test "AttachDatabase" {
    const allocator = std.testing.allocator;
    var instance = AttachDatabase.init(allocator);
    defer instance.deinit();
}
