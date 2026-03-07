//! ColumnReader
const std = @import("std");

pub const ColumnReader = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ColumnReader { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ColumnReader) void { _ = self; }
};

test "ColumnReader" {
    const allocator = std.testing.allocator;
    var instance = ColumnReader.init(allocator);
    defer instance.deinit();
}
