//! ColumnWriter
const std = @import("std");

pub const ColumnWriter = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ColumnWriter { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ColumnWriter) void { _ = self; }
};

test "ColumnWriter" {
    const allocator = std.testing.allocator;
    var instance = ColumnWriter.init(allocator);
    defer instance.deinit();
}
