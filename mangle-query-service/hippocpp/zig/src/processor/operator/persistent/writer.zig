//! Writer
const std = @import("std");

pub const Writer = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) Writer { return .{ .allocator = allocator }; }
    pub fn deinit(self: *Writer) void { _ = self; }
};

test "Writer" {
    const allocator = std.testing.allocator;
    var instance = Writer.init(allocator);
    defer instance.deinit();
}
