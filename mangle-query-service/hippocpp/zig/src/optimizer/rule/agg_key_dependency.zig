//! AggKeyDependency
const std = @import("std");

pub const AggKeyDependency = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) AggKeyDependency {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *AggKeyDependency) void {
        _ = self;
    }
};

test "AggKeyDependency" {
    const allocator = std.testing.allocator;
    var instance = AggKeyDependency.init(allocator);
    defer instance.deinit();
}
