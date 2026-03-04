//! ZoneMap
const std = @import("std");

pub const ZoneMap = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ZoneMap { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ZoneMap) void { _ = self; }
};

test "ZoneMap" {
    const allocator = std.testing.allocator;
    var instance = ZoneMap.init(allocator);
    defer instance.deinit();
}
