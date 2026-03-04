//! SimpleAggregate
const std = @import("std");

pub const SimpleAggregate = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) SimpleAggregate {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *SimpleAggregate) void {
        _ = self;
    }
};

test "SimpleAggregate" {
    const allocator = std.testing.allocator;
    var instance = SimpleAggregate.init(allocator);
    defer instance.deinit();
}
