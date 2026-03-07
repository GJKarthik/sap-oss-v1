//! LogicalFlatten
const std = @import("std");

pub const LogicalFlatten = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) LogicalFlatten {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *LogicalFlatten) void {
        _ = self;
    }
};

test "LogicalFlatten" {
    const allocator = std.testing.allocator;
    var instance = LogicalFlatten.init(allocator);
    defer instance.deinit();
}
