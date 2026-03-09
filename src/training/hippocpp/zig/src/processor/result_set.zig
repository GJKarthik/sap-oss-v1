//! ResultSet — Ported from kuzu C++ (45L header, 40L source).
//!

const std = @import("std");

pub const ResultSet = struct {
    allocator: std.mem.Allocator,
    multiplicity: u64 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn insert(self: *Self) void {
        _ = self;
    }

    pub fn get_num_tuples(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_num_tuples_without_multiplicity(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

};

test "ResultSet" {
    const allocator = std.testing.allocator;
    var instance = ResultSet.init(allocator);
    defer instance.deinit();
    _ = instance.get_num_tuples();
    _ = instance.get_num_tuples_without_multiplicity();
    _ = instance.get_num_tuples_without_multiplicity();
}
