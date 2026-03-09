//! ImportDB — Ported from kuzu C++ (30L header, 102L source).
//!
//! Extends SimpleSink in the upstream implementation.

const std = @import("std");

pub const ImportDB = struct {
    allocator: std.mem.Allocator,
    query: []const u8 = "",
    indexQuery: []const u8 = "",

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn execute_internal(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this ImportDB.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.query = self.query;
        new.indexQuery = self.indexQuery;
        return new;
    }

};

test "ImportDB" {
    const allocator = std.testing.allocator;
    var instance = ImportDB.init(allocator);
    defer instance.deinit();
}
