//! StandaloneCall
const std = @import("std");

pub const StandaloneCall = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) StandaloneCall {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *StandaloneCall) void {
        _ = self;
    }
};

test "StandaloneCall" {
    const allocator = std.testing.allocator;
    var instance = StandaloneCall.init(allocator);
    defer instance.deinit();
}
