//! NodeVal — Ported from kuzu C++ (899L header, 1162L source).
//!

const std = @import("std");

pub const NodeVal = struct {
    allocator: std.mem.Allocator,
    isNull: bool = false,
    NodeVal: ?*anyopaque = null,
    RelVal: ?*anyopaque = null,
    FileInfo: ?*anyopaque = null,
    NestedVal: ?*anyopaque = null,
    RecursiveRelVal: ?*anyopaque = null,
    ArrowRowBatch: ?*anyopaque = null,
    ValueVector: ?*anyopaque = null,
    Serializer: ?*anyopaque = null,
    Deserializer: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn create_null_value(self: *Self) void {
        _ = self;
    }

    pub fn create_default_value(self: *Self) void {
        _ = self;
    }

    pub fn value(self: *Self) void {
        _ = self;
    }

};

test "NodeVal" {
    const allocator = std.testing.allocator;
    var instance = NodeVal.init(allocator);
    defer instance.deinit();
}
