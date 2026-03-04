//! HashAggregate
const std = @import("std");

pub const HashAggregate = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) HashAggregate {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *HashAggregate) void {
        _ = self;
    }
};

test "HashAggregate" {
    const allocator = std.testing.allocator;
    var instance = HashAggregate.init(allocator);
    defer instance.deinit();
}
