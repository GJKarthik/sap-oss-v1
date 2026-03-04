//! LogicalInQueryCall
const std = @import("std");

pub const LogicalInQueryCall = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) LogicalInQueryCall {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *LogicalInQueryCall) void {
        _ = self;
    }
};

test "LogicalInQueryCall" {
    const allocator = std.testing.allocator;
    var instance = LogicalInQueryCall.init(allocator);
    defer instance.deinit();
}
