//! LogicalDistinct
const std = @import("std");

pub const LogicalDistinct = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) LogicalDistinct {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *LogicalDistinct) void {
        _ = self;
    }
};

test "LogicalDistinct" {
    const allocator = std.testing.allocator;
    var instance = LogicalDistinct.init(allocator);
    defer instance.deinit();
}
