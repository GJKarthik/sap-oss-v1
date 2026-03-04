//! LogicalAggregate
const std = @import("std");

pub const LogicalAggregate = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) LogicalAggregate {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *LogicalAggregate) void {
        _ = self;
    }
};

test "LogicalAggregate" {
    const allocator = std.testing.allocator;
    var instance = LogicalAggregate.init(allocator);
    defer instance.deinit();
}
