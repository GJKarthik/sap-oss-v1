//! OverflowFile
const std = @import("std");

pub const OverflowFile = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) OverflowFile { return .{ .allocator = allocator }; }
    pub fn deinit(self: *OverflowFile) void { _ = self; }
};

test "OverflowFile" {
    const allocator = std.testing.allocator;
    var instance = OverflowFile.init(allocator);
    defer instance.deinit();
}
