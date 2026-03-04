//! HashJoinProbe
const std = @import("std");

pub const HashJoinProbe = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) HashJoinProbe {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *HashJoinProbe) void {
        _ = self;
    }
};

test "HashJoinProbe" {
    const allocator = std.testing.allocator;
    var instance = HashJoinProbe.init(allocator);
    defer instance.deinit();
}
