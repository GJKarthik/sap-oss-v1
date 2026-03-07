//! CopyRel
const std = @import("std");

pub const CopyRel = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) CopyRel { return .{ .allocator = allocator }; }
    pub fn deinit(self: *CopyRel) void { _ = self; }
};

test "CopyRel" {
    const allocator = std.testing.allocator;
    var instance = CopyRel.init(allocator);
    defer instance.deinit();
}
