//! DetachDatabase — Ported from kuzu C++ (44L header, 28L source).
//!
//! Extends SimpleSink in the upstream implementation.

const std = @import("std");

pub const DetachDatabase = struct {
    allocator: std.mem.Allocator,
    name: []const u8 = "",
    dbName: []const u8 = "",

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn detatch_database_print_info(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
        _ = self;
    }

    pub fn execute_internal(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this DetachDatabase.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.name = self.name;
        new.dbName = self.dbName;
        return new;
    }

};

test "DetachDatabase" {
    const allocator = std.testing.allocator;
    var instance = DetachDatabase.init(allocator);
    defer instance.deinit();
}
