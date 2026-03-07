//! ZoneMapCheck
const std = @import("std");

pub const ZoneMapCheck = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ZoneMapCheck { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ZoneMapCheck) void { _ = self; }
};

test "ZoneMapCheck" {
    const allocator = std.testing.allocator;
    var instance = ZoneMapCheck.init(allocator);
    defer instance.deinit();
}
