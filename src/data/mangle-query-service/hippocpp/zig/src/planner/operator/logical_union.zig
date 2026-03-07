//! LogicalUnion
const std = @import("std");

pub const LogicalUnion = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) LogicalUnion {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *LogicalUnion) void {
        _ = self;
    }
};

test "LogicalUnion" {
    const allocator = std.testing.allocator;
    var instance = LogicalUnion.init(allocator);
    defer instance.deinit();
}
