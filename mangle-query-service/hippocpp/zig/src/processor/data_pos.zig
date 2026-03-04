//! DataPos
const std = @import("std");

pub const DataPos = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) DataPos { return .{ .allocator = allocator }; }
    pub fn deinit(self: *DataPos) void { _ = self; }
};

test "DataPos" {
    const allocator = std.testing.allocator;
    var instance = DataPos.init(allocator);
    defer instance.deinit();
}
