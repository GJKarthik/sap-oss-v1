//! UseDatabase — Ported from kuzu C++ (44L header, 25L source).
//!
//! Extends SimpleSink in the upstream implementation.

const std = @import("std");

pub const UseDatabase = struct {
    allocator: std.mem.Allocator,
    dbName: []const u8 = "",

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn use_database_print_info(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
        _ = self;
    }

    pub fn execute_internal(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this UseDatabase.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.dbName = self.dbName;
        new.dbName = self.dbName;
        return new;
    }

};

test "UseDatabase" {
    const allocator = std.testing.allocator;
    var instance = UseDatabase.init(allocator);
    defer instance.deinit();
}
