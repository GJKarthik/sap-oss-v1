//! LogicalStandaloneCall
const std = @import("std");

pub const LogicalStandaloneCall = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LogicalStandaloneCall { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LogicalStandaloneCall) void { _ = self; }
};

test "LogicalStandaloneCall" {
    const allocator = std.testing.allocator;
    var instance = LogicalStandaloneCall.init(allocator);
    defer instance.deinit();
}
